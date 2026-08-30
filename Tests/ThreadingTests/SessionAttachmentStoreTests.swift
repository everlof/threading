import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The two doors into the attachment list, and the custody rule that lets the second one exist.
///
/// The bug these were written against: the containment rule — a real rule, about what the remote
/// endpoint may serve — was enforced at *admission*, so a file an agent declared from `$TMPDIR`
/// was dropped on the floor with the panel already showing it.
@MainActor
final class SessionAttachmentStoreTests: XCTestCase {

    private var directory: URL!
    private var checkout: URL!
    private var elsewhere: URL!
    private var copies: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-store-\(UUID().uuidString)", isDirectory: true)
        checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        elsewhere = directory.appendingPathComponent("scratch", isDirectory: true)
        copies = directory.appendingPathComponent("Attachments", isDirectory: true)
        for url in [checkout, elsewhere, copies] {
            try FileManager.default.createDirectory(at: url!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private var payloads: [SessionID: String] = [:]

    /// The scope answer is read on every admission and every read, so the double is a box the
    /// test can flip mid-case — which is the interesting half: the rule is configurable, and
    /// what happens *at the moment it changes* is what these assert.
    private var allowsFilesOutsideProject = false

    private func makeStore(
        takesCustody: Bool = true,
        stageCopy: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager().copyItem(at: $0, to: $1)
        }
    ) -> SessionAttachmentStore {
        SessionAttachmentStore(
            loadPayload: { [weak self] in self?.payloads[$0] },
            savePayload: { [weak self] payload, id in self?.payloads[id] = payload },
            retainPersisted: { [weak self] ids in
                self?.payloads = self?.payloads.filter { ids.contains($0.key) } ?? [:]
            },
            removePersisted: { [weak self] id in self?.payloads.removeValue(forKey: id) },
            copiesDirectory: takesCustody ? { [copies] in copies! } : nil,
            referenceRoot: { [checkout] _ in checkout },
            allowsFilesOutsideProject: { [weak self] in self?.allowsFilesOutsideProject ?? false },
            stageCopy: stageCopy
        )
    }

    func testRemovingOneSessionLeavesEveryOtherAttachmentDocumentAlone() throws {
        let removed = SessionID()
        let kept = SessionID()
        let removedFile = elsewhere.appendingPathComponent("removed.png")
        let keptFile = elsewhere.appendingPathComponent("kept.png")
        try Data("removed".utf8).write(to: removedFile)
        try Data("kept".utf8).write(to: keptFile)

        let store = makeStore()
        XCTAssertNotNil(store.record(
            declared: removedFile,
            sessionID: removed,
            projectRoot: checkout,
            origin: .agent
        ))
        XCTAssertNotNil(store.record(
            declared: keptFile,
            sessionID: kept,
            projectRoot: checkout,
            origin: .agent
        ))
        XCTAssertNotNil(payloads[removed])
        XCTAssertNotNil(payloads[kept])

        store.removeSession(removed)

        XCTAssertTrue(store.attachments(for: removed).isEmpty)
        XCTAssertEqual(store.attachments(for: kept).map(\.name), ["kept.png"])
        XCTAssertNil(payloads[removed])
        XCTAssertNotNil(payloads[kept])
    }

    private final class CopyGate: @unchecked Sendable {
        private let started = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        func copy(_ source: URL, to destination: URL) throws {
            started.signal()
            release.wait()
            try FileManager().copyItem(at: source, to: destination)
        }

        func waitUntilStarted() async {
            await Task.detached { [started] in
                started.wait()
            }.value
        }

        func proceed() {
            release.signal()
        }
    }

    private func waitForAttachmentScan(
        _ observer: TerminalAttachmentObserver,
        timeout: TimeInterval = 2
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while observer.isScanInFlight, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        XCTAssertFalse(observer.isScanInFlight, "attachment resolution did not finish")
    }

    @discardableResult
    private func write(_ bytes: [UInt8], to url: URL) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - The Declared Door

    /// The heart of it: agents write to one-off places, and the pane could never show any of it.
    func testADeclaredFileOutsideTheCheckoutIsKeptRatherThanRefused() throws {
        let store = makeStore()
        let session = SessionID()
        let chart = try write([0x89, 0x50, 0x01], to: elsewhere.appendingPathComponent("chart.png"))

        let recorded = try XCTUnwrap(
            store.record(declared: chart, sessionID: session, projectRoot: checkout, origin: .agent)
        )

        XCTAssertEqual(recorded.name, "chart.png")
        XCTAssertEqual(store.attachments(for: session).map(\.name), ["chart.png"])
        XCTAssertEqual(
            try Data(contentsOf: recorded.url),
            Data([0x89, 0x50, 0x01]),
            "the row does not resolve to the bytes that were declared"
        )
    }

    /// Custody, not a reference: the list is persisted and outlives the turn, so a row pointing
    /// into a directory the system reaps is a row that empties itself.
    func testACopyOutlivesTheFileItWasTakenFrom() throws {
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89, 0x50], to: elsewhere.appendingPathComponent("shot.png"))

        store.record(declared: shot, sessionID: session, projectRoot: checkout, origin: .user)
        try FileManager.default.removeItem(at: shot)

        XCTAssertEqual(
            store.attachments(for: session).map(\.name),
            ["shot.png"],
            "the row went with the temporary file it was taken from"
        )
    }

    /// A file already in the checkout stays a reference — the project file is authoritative, and
    /// a copy beside it would be a second thing to keep in step.
    func testADeclaredFileInsideTheCheckoutIsStillAReference() throws {
        let store = makeStore()
        let session = SessionID()
        let plan = try write([0x89, 0x50], to: checkout.appendingPathComponent("plan.png"))

        let recorded = try XCTUnwrap(
            store.record(declared: plan, sessionID: session, projectRoot: checkout, origin: .agent)
        )

        XCTAssertEqual(recorded.url.resolvingSymlinksInPath(), plan.resolvingSymlinksInPath())
        XCTAssertEqual(recorded.relativePath, "plan.png")
    }

    /// A regenerated chart is the same row with new bytes, not a second row — which is what the
    /// source path is kept for, since the copy's own path is minted per attachment.
    func testASecondDeclarationOfTheSameSourceRefreshesItInPlace() throws {
        let store = makeStore()
        let session = SessionID()
        let chart = elsewhere.appendingPathComponent("chart.png")

        try write([0x01], to: chart)
        let first = try XCTUnwrap(
            store.record(declared: chart, sessionID: session, projectRoot: checkout, origin: .agent)
        )

        try FileManager.default.removeItem(at: chart)
        try write([0x02], to: chart)
        let second = try XCTUnwrap(
            store.record(declared: chart, sessionID: session, projectRoot: checkout, origin: .agent)
        )

        XCTAssertEqual(store.attachments(for: session).count, 1, "the same source made two rows")
        XCTAssertEqual(second.relativePath, first.relativePath, "the row lost its identity")
        XCTAssertEqual(try Data(contentsOf: second.url), Data([0x02]), "the copy is stale")
    }

    /// Batch admission has the same last-mention-wins chronology as sequential admission. This
    /// pins the linear reducer that replaced repeated whole-list scans in full generations.
    func testABatchDeduplicatesByItsLastSourceWithoutReorderingOtherRows() throws {
        let store = makeStore()
        let session = SessionID()
        let first = try write([0x01], to: elsewhere.appendingPathComponent("first.png"))
        let other = try write([0x02], to: elsewhere.appendingPathComponent("other.png"))

        let offered = store.record(
            declared: [first, other, first],
            sessionID: session,
            projectRoot: checkout,
            origin: .agent
        )
        let listed = store.attachments(for: session)

        XCTAssertEqual(offered.count, 3)
        XCTAssertEqual(listed.map(\.name), ["first.png", "other.png"])
        XCTAssertEqual(listed.first?.id, offered.last?.id)
        XCTAssertNil(store.attachment(for: session, id: offered[0].id))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: copies.appendingPathComponent(session.uuidString, isDirectory: true),
                includingPropertiesForKeys: nil
            ).count,
            2,
            "the batch's losing source slot was not removed"
        )
    }

    /// A generated name is right for a file that only has to outlive the turn and unreadable in a
    /// list, so the composer may hand over a name — but not a different extension, which is what
    /// the preview and the remote content type are chosen from.
    func testAPreferredNameIsUsedWithoutChangingTheExtension() throws {
        let store = makeStore()
        let session = SessionID()
        let pasted = try write(
            [0x89],
            to: elsewhere.appendingPathComponent("threading-attachment-\(UUID().uuidString).png")
        )

        let recorded = try XCTUnwrap(
            store.record(
                declared: pasted,
                sessionID: session,
                projectRoot: checkout,
                origin: .user,
                preferredName: "Pasted image"
            )
        )

        XCTAssertEqual(recorded.name, "Pasted image.png")
    }

    func testDisplayedSnapshotsKeepEachAnnouncedRevisionAndOpaqueIdentity() throws {
        let store = makeStore()
        let session = SessionID()
        let progress = elsewhere.appendingPathComponent("progress.png")
        try write([0x01], to: progress)

        let first = try XCTUnwrap(store.recordSnapshot(
            of: progress,
            sessionID: session,
            origin: .agent
        ))
        try write([0x02], to: progress)
        let second = try XCTUnwrap(store.recordSnapshot(
            of: progress,
            sessionID: session,
            origin: .agent
        ))

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(try Data(contentsOf: first.url), Data([0x01]))
        XCTAssertEqual(try Data(contentsOf: second.url), Data([0x02]))
        XCTAssertTrue(first.isImmutableSnapshot)
        XCTAssertTrue(second.isImmutableSnapshot)
        XCTAssertEqual(store.attachment(for: session, id: first.id), first)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.attachment(for: session, id: first.id)?.id, first.id)
        XCTAssertEqual(relaunched.attachment(for: session, id: second.id)?.id, second.id)
    }

    func testDisplayedSnapshotStoresTheValidatedBytesNotALaterSourceRevision() throws {
        let store = makeStore()
        let session = SessionID()
        let progress = elsewhere.appendingPathComponent("progress.png")
        let validated = Data([0x01, 0x02])
        try Data([0x09, 0x09]).write(to: progress)

        let snapshot = try XCTUnwrap(store.recordSnapshot(
            validated,
            of: progress,
            sessionID: session,
            origin: .agent
        ))

        XCTAssertEqual(try Data(contentsOf: snapshot.url), validated)
        XCTAssertEqual(try Data(contentsOf: progress), Data([0x09, 0x09]))
    }

    func testGeneratedHTMLIsAnInspectableAttachmentRatherThanAPanelOnlyValue() throws {
        let store = makeStore()
        let session = SessionID()
        let html = "<main><h1>Step 2</h1><progress value='2' max='3'></progress></main>"

        let attachment = try XCTUnwrap(store.recordGeneratedHTML(
            html,
            title: "Progress / Step: 2",
            sessionID: session
        ))

        XCTAssertEqual(attachment.kind, .html)
        XCTAssertTrue(attachment.name.hasSuffix(".html"))
        XCTAssertFalse(attachment.name.contains("/"))
        XCTAssertEqual(String(decoding: try Data(contentsOf: attachment.url), as: UTF8.self), html)
        XCTAssertEqual(makeStore().attachment(for: session, id: attachment.id)?.id, attachment.id)
    }

    func testNotificationTargetReferencesAreScopedOpaqueAndExpiring() throws {
        var instant = Date(timeIntervalSince1970: 1_000)
        let registry = NotificationTargetRegistry(now: { instant })
        let session = SessionID()
        let otherSession = SessionID()
        let destination = RemoteNotificationDestinationDTO.attachment(id: "attachment-1")

        let reference = try XCTUnwrap(registry.issue(destination, for: session))

        XCTAssertFalse(reference.contains("attachment-1"))
        XCTAssertEqual(registry.resolve(reference, for: session), destination)
        XCTAssertNil(registry.resolve(reference, for: otherSession))

        instant.addTimeInterval(NotificationTargetDefaults.lifetime + 1)
        XCTAssertNil(registry.resolve(reference, for: session))
    }

    /// Without somewhere to put a copy the store may only hold references, so it refuses rather
    /// than listing a path it knows will rot.
    func testAStoreThatCannotTakeCustodyRefusesTheFileInstead() throws {
        let store = makeStore(takesCustody: false)
        let session = SessionID()
        let chart = try write([0x89], to: elsewhere.appendingPathComponent("chart.png"))

        XCTAssertNil(
            store.record(declared: chart, sessionID: session, projectRoot: checkout, origin: .agent)
        )
        XCTAssertEqual(store.attachments(for: session), [])
    }

    // MARK: - The Scanned Door

    /// Unchanged, and deliberately: text is not a handoff. This list is what the paired phone
    /// serves, so a path merely *printed* may not leave the checkout.
    func testAScannedPathOutsideTheCheckoutIsStillRefused() throws {
        let store = makeStore()
        let session = SessionID()
        let secret = try write([0x89], to: elsewhere.appendingPathComponent("private.png"))

        store.recordReferences(
            in: "wrote \(secret.path)",
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(
            store.attachments(for: session),
            [],
            "scanning admitted a path from outside the checkout"
        )
    }

    func testAScannedPathInsideTheCheckoutIsRecordedAsTheAgentsOwn() throws {
        let store = makeStore()
        let session = SessionID()
        try write([0x89], to: checkout.appendingPathComponent("diagram.png"))

        store.recordReferences(
            in: "see `diagram.png`",
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(store.attachments(for: session).map(\.origin), [.agent])
    }

    // MARK: - The Scope The Scanned Door Is Held To

    /// The refusal is not silence: the pane has to be able to say what the rule cost, or the
    /// setting is one nobody can find from the place it applies.
    func testARefusedPathIsCountedEvenThoughItIsNotListed() throws {
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("private.png"))

        store.recordReferences(in: "wrote \(shot.path)", sessionID: session, projectRoot: checkout)

        XCTAssertEqual(store.attachments(for: session), [])
        XCTAssertEqual(store.countOfFilesOutsideProject(for: session), 1)
        XCTAssertEqual(
            store.withheldReferences(for: session).map(\.path),
            [shot.resolvingSymlinksInPath().path]
        )
    }

    /// Nothing to say when the rule costs nothing — which is what lets the pane stay quiet.
    func testASessionThatNamesNothingOutsideItsProjectCountsNothing() throws {
        let store = makeStore()
        let session = SessionID()
        try write([0x89], to: checkout.appendingPathComponent("diagram.png"))

        store.recordReferences(in: "see `diagram.png`", sessionID: session, projectRoot: checkout)

        XCTAssertEqual(store.attachments(for: session).count, 1)
        XCTAssertEqual(store.countOfFilesOutsideProject(for: session), 0)
    }

    /// Widening takes custody rather than pointing outside: the property the containment rule
    /// was really providing — every listed file somewhere the app controls — has to survive the
    /// rule being relaxed, because it is what the remote endpoint stands on.
    func testWideningTheScopeCopiesTheFileInRatherThanReferencingIt() throws {
        allowsFilesOutsideProject = true
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89, 0x50], to: elsewhere.appendingPathComponent("shot.png"))

        store.recordReferences(in: "wrote \(shot.path)", sessionID: session, projectRoot: checkout)

        let listed = try XCTUnwrap(store.attachments(for: session).first)
        XCTAssertEqual(listed.name, "shot.png")
        XCTAssertTrue(listed.isOutsideProject)
        XCTAssertTrue(
            listed.url.path.hasPrefix(copies.path),
            "a widened scope listed a file the app has no custody of: \(listed.url.path)"
        )
        XCTAssertEqual(try Data(contentsOf: listed.url), Data([0x89, 0x50]))
        XCTAssertEqual(store.countOfFilesOutsideProject(for: session), 1)
    }

    /// A scope answer can change while worker custody is in progress. An unpublished slot may
    /// be discarded, but it may never leak into the list after the gate has closed.
    func testAsyncScannedAdmissionRechecksScopeAfterWorkerCustody() async throws {
        allowsFilesOutsideProject = true
        let gate = CopyGate()
        let store = makeStore(stageCopy: gate.copy)
        let session = SessionID()
        let shot = try write([0x89, 0x50], to: elsewhere.appendingPathComponent("slow.png"))
        let resolution = AttachmentReferenceDetector.Resolution(outsideProject: [shot])

        let admission = Task { @MainActor in
            await store.recordScanned(
                resolved: resolution,
                sessionID: session,
                projectRoot: checkout
            )
        }
        await gate.waitUntilStarted()
        allowsFilesOutsideProject = false
        gate.proceed()
        let result = await admission.value

        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertTrue(store.attachments(for: session).isEmpty)
        XCTAssertEqual(store.withheldReferences(for: session).map(\.path), [shot.path])

        let sessionRoot = copies.appendingPathComponent(session.uuidString, isDirectory: true)
        // A bound on the reclaim hanging, not a measurement of how quickly it runs: it is
        // filesystem work on a background executor, and a second is marginal in a full run of
        // the target even though it is generous alone.
        let deadline = Date().addingTimeInterval(5)
        while (try? FileManager.default.contentsOfDirectory(atPath: sessionRoot.path).isEmpty) == false,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(
            try? FileManager.default.contentsOfDirectory(atPath: sessionRoot.path),
            [],
            "a scope change left unpublished custody bytes behind"
        )
    }

    /// State may also advance while the worker copies. The later finisher must fold into the row
    /// that won rather than publish a duplicate or replace its opaque remote identity.
    func testAsyncScannedAdmissionKeepsTheSameSourceWinnerIdentity() async throws {
        allowsFilesOutsideProject = true
        let gate = CopyGate()
        let store = makeStore(stageCopy: gate.copy)
        let session = SessionID()
        let chart = try write([0x01], to: elsewhere.appendingPathComponent("race.png"))
        let resolution = AttachmentReferenceDetector.Resolution(outsideProject: [chart])

        let admission = Task { @MainActor in
            await store.recordScanned(
                resolved: resolution,
                sessionID: session,
                projectRoot: checkout
            )
        }
        await gate.waitUntilStarted()
        let winner = try XCTUnwrap(store.record(
            declared: chart,
            sessionID: session,
            projectRoot: checkout,
            origin: .agent
        ))
        gate.proceed()
        _ = await admission.value

        let listed = try XCTUnwrap(store.attachments(for: session).first)
        XCTAssertEqual(store.attachments(for: session).count, 1)
        XCTAssertEqual(listed.id, winner.id)
        XCTAssertEqual(listed.relativePath, winner.relativePath)
        XCTAssertEqual(try Data(contentsOf: listed.url), Data([0x01]))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: copies.appendingPathComponent(session.uuidString, isDirectory: true),
                includingPropertiesForKeys: nil
            ).count,
            1,
            "the losing unpublished slot was not removed"
        )
    }

    /// The answer the user gave is the answer the pane shows, not the answer it shows the next
    /// time an agent happens to print the path again: nothing re-reads the terminal's buffer on
    /// a settings change, so what was refused has to be admittable from what was remembered.
    func testWhatWasRefusedIsAdmittedTheMomentTheScopeWidens() throws {
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("late.png"))
        store.recordReferences(in: "wrote \(shot.path)", sessionID: session, projectRoot: checkout)
        XCTAssertEqual(store.attachments(for: session), [])

        allowsFilesOutsideProject = true
        XCTAssertEqual(store.admitWithheldFilesOutsideProject(for: session).map(\.name), ["late.png"])
        XCTAssertEqual(store.attachments(for: session).map(\.name), ["late.png"])
        XCTAssertTrue(
            store.withheldReferences(for: session).isEmpty,
            "a file that has been admitted is still being counted as withheld"
        )
    }

    /// The interactive form returns control while custody is still on its worker, then publishes
    /// only after the staged bytes are complete. This is the pane's Show-button contract.
    func testAsyncWithheldAdmissionStagesBeforePublishing() async throws {
        let gate = CopyGate()
        let store = makeStore(stageCopy: gate.copy)
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("late-async.png"))
        store.recordReferences(in: "wrote \(shot.path)", sessionID: session, projectRoot: checkout)
        allowsFilesOutsideProject = true

        let admission = Task { @MainActor in
            await store.admitWithheldFilesOutsideProjectAsync(for: session)
        }
        await gate.waitUntilStarted()

        XCTAssertTrue(store.attachments(for: session).isEmpty)
        XCTAssertEqual(store.withheldReferences(for: session).map(\.path), [shot.path])

        gate.proceed()
        let result = await admission.value
        XCTAssertEqual(result.attachments.map(\.name), ["late-async.png"])
        XCTAssertEqual(store.attachments(for: session).map(\.name), ["late-async.png"])
        XCTAssertTrue(store.withheldReferences(for: session).isEmpty)
    }

    /// Async scans may replace a full list, but their evicted private slots are cleanup work,
    /// not admission work. The old rows lose addressability before that deletion is allowed to
    /// trail on its utility worker.
    func testAsyncFullListReplacementDefersOwnedSlotCleanupSafely() async throws {
        allowsFilesOutsideProject = true
        let store = makeStore()
        let session = SessionID()
        let first = try (0..<SessionAttachmentDefaults.maximumPerSession).map { index in
            try write([UInt8(index % 251)], to: elsewhere.appendingPathComponent("old-\(index).png"))
        }
        let oldRows = store.record(
            declared: first,
            sessionID: session,
            projectRoot: checkout,
            origin: .agent
        )
        XCTAssertEqual(oldRows.count, SessionAttachmentDefaults.maximumPerSession)

        let second = try (0..<SessionAttachmentDefaults.maximumPerSession).map { index in
            try write([UInt8((index + 1) % 251)], to: elsewhere.appendingPathComponent("new-\(index).png"))
        }
        let result = await store.recordScanned(
            resolved: .init(outsideProject: second),
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(result.attachments.count, SessionAttachmentDefaults.maximumPerSession)
        XCTAssertEqual(store.attachments(for: session).count, SessionAttachmentDefaults.maximumPerSession)
        for row in oldRows {
            XCTAssertNil(store.attachment(for: session, id: row.id))
        }

        let sessionRoot = copies.appendingPathComponent(session.uuidString, isDirectory: true)
        // Bounds a hang in the same background reclaim, for the same reason as above.
        let deadline = Date().addingTimeInterval(5)
        var slotCount = try FileManager.default.contentsOfDirectory(atPath: sessionRoot.path).count
        while slotCount > SessionAttachmentDefaults.maximumPerSession, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            slotCount = try FileManager.default.contentsOfDirectory(atPath: sessionRoot.path).count
        }
        XCTAssertEqual(
            slotCount,
            SessionAttachmentDefaults.maximumPerSession,
            "evicted private slots were left behind after deferred cleanup"
        )
    }

    /// Narrowing again is immediate and total, and it does not depend on anything being open to
    /// notice: everything that can serve an attachment reads through the one gate.
    func testNarrowingTheScopeHidesThoseRowsEverywhereWithoutDestroyingThem() throws {
        allowsFilesOutsideProject = true
        let store = makeStore()
        let session = SessionID()
        let outside = try write([0x89], to: elsewhere.appendingPathComponent("outside.png"))
        try write([0x89], to: checkout.appendingPathComponent("inside.png"))
        store.recordReferences(
            in: "both \(outside.path) and `inside.png`",
            sessionID: session,
            projectRoot: checkout
        )
        XCTAssertEqual(store.attachments(for: session).count, 2)
        let kept = try XCTUnwrap(
            store.attachments(for: session).first(where: \.isOutsideProject)
        )

        allowsFilesOutsideProject = false

        XCTAssertEqual(store.attachments(for: session).map(\.name), ["inside.png"])
        XCTAssertNil(
            store.attachment(for: session, relativePath: kept.relativePath),
            "a row hidden by the scope is still addressable by relative path — the phone's key"
        )
        XCTAssertEqual(store.countOfFilesOutsideProject(for: session), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: kept.url.path),
            "narrowing the scope destroyed bytes it had already taken custody of"
        )

        allowsFilesOutsideProject = true
        XCTAssertEqual(store.attachments(for: session).count, 2, "the row did not come back")
    }

    /// A handoff was never governed by the rule, so the setting may not touch it. This is the
    /// bug in the other direction: the pane blaming a setting for something it does not control.
    func testTheScopeDoesNotGovernAFileTheUserOrTheAgentHandedOver() throws {
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("declared.png"))

        store.record(declared: shot, sessionID: session, projectRoot: checkout, origin: .user)

        XCTAssertEqual(store.attachments(for: session).map(\.name), ["declared.png"])
        XCTAssertEqual(
            store.countOfFilesOutsideProject(for: session),
            0,
            "a declared file was counted as something the scope setting is deciding about"
        )
    }

    /// A later transcript mention refreshes an explicit handoff; it does not retroactively make
    /// that row subject to the discovery scope merely because both doors name the same source.
    func testAScanPreservesTheAuthorityOfAnExistingDeclaredRow() async throws {
        allowsFilesOutsideProject = true
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("declared-then-scanned.png"))
        let declared = try XCTUnwrap(
            store.record(
                declared: shot,
                sessionID: session,
                projectRoot: checkout,
                origin: .user
            )
        )

        _ = await store.recordScanned(
            resolved: .init(outsideProject: [shot]),
            sessionID: session,
            projectRoot: checkout
        )
        let refreshed = try XCTUnwrap(store.attachments(for: session).first)

        XCTAssertEqual(refreshed.id, declared.id)
        XCTAssertEqual(refreshed.origin, .user)
        XCTAssertFalse(refreshed.isOutsideProject)
        allowsFilesOutsideProject = false
        XCTAssertEqual(store.attachments(for: session).map(\.id), [declared.id])
    }

    /// Persisted like the rest, and read back as what it is: the gate has to still find these
    /// after a relaunch, or a narrow scope would silently serve what a wide one admitted.
    func testTheOutsideMarkSurvivesARelaunch() throws {
        allowsFilesOutsideProject = true
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("kept.png"))
        makeStore().recordReferences(
            in: "wrote \(shot.path)",
            sessionID: session,
            projectRoot: checkout
        )

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.attachments(for: session).map(\.isOutsideProject), [true])

        allowsFilesOutsideProject = false
        XCTAssertEqual(makeStore().attachments(for: session), [])
    }

    /// A listener may only ever see a finished store.
    ///
    /// The change is announced synchronously, and the pane answers it by refreshing — which
    /// admits whatever is still withheld. Announcing before clearing the withheld list therefore
    /// handed the listener the same work again, and the pane and the store recursed until the
    /// stack ran out: a segmentation fault, from turning a setting on.
    func testAdmittingAnnouncesOnlyAfterTheWithheldListIsCleared() throws {
        allowsFilesOutsideProject = true
        let store = makeStore()
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("reentrant.png"))
        allowsFilesOutsideProject = false
        store.recordReferences(in: "wrote \(shot.path)", sessionID: session, projectRoot: checkout)
        allowsFilesOutsideProject = true

        var reentries = 0
        let observer = NotificationCenter.default.addObserver(
            forName: SessionAttachmentsDidChange.name,
            object: nil,
            queue: nil
        ) { _ in
            reentries += 1
            // What the pane does, and may keep doing safely however deep the reply arrives.
            guard reentries < 8 else { return }
            MainActor.assumeIsolated {
                store.admitWithheldFilesOutsideProject(for: session)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.admitWithheldFilesOutsideProject(for: session)

        XCTAssertEqual(reentries, 1, "the store announced a change it had not finished making")
        XCTAssertEqual(store.attachments(for: session).map(\.name), ["reentrant.png"])
    }

    /// The hint is a hint, not a queue: the count may not grow with an afternoon of output.
    func testWhatIsRememberedAboutRefusedPathsIsBounded() throws {
        let store = makeStore()
        let session = SessionID()
        var text = ""
        for index in 0...(SessionAttachmentDefaults.maximumWithheldPerSession + 8) {
            let file = try write(
                [UInt8(index % 251)],
                to: elsewhere.appendingPathComponent("noise-\(index).png")
            )
            text += "\(file.path)\n"
        }

        store.recordReferences(in: text, sessionID: session, projectRoot: checkout)

        XCTAssertEqual(
            store.withheldReferences(for: session).count,
            SessionAttachmentDefaults.maximumWithheldPerSession
        )
    }

    // MARK: - Provenance

    func testProvenanceSurvivesARelaunch() throws {
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("shot.png"))
        try write([0x89], to: checkout.appendingPathComponent("made.png"))

        let store = makeStore()
        store.record(declared: shot, sessionID: session, projectRoot: checkout, origin: .user)
        store.recordReferences(in: "`made.png`", sessionID: session, projectRoot: checkout)

        let relaunched = makeStore()
        XCTAssertEqual(
            relaunched.attachments(for: session).map { [$0.name: $0.origin] },
            [["made.png": .agent], ["shot.png": .user]]
        )
    }

    func testTurnAssociationSurvivesARelaunch() throws {
        let session = SessionID()
        let shot = try write([0x89], to: elsewhere.appendingPathComponent("turn.png"))
        let store = makeStore()
        let attachment = try XCTUnwrap(store.record(
            declared: shot,
            sessionID: session,
            projectRoot: checkout,
            origin: .user,
            turnPlacement: .next
        ))

        store.associate(
            attachmentIDs: [attachment.id],
            withTurnID: "queued-turn",
            for: session
        )

        let relaunched = try XCTUnwrap(makeStore().attachments(for: session).first)
        XCTAssertEqual(relaunched.turnID, "queued-turn")
        XCTAssertEqual(relaunched.turnPlacement, .next)
        XCTAssertTrue(payloads[session]?.contains(#""formatVersion":3"#) == true)
    }

    func testLegacyUserAttachmentPointsToTheNextTurn() throws {
        let session = SessionID()
        _ = try write([0x89], to: checkout.appendingPathComponent("legacy-user.png"))
        payloads[session] = """
        [{"projectRoot":"\(checkout.path)","relativePath":"legacy-user.png",\
        "kind":"image","origin":"user","referencedAt":0}]
        """

        XCTAssertEqual(
            makeStore().attachments(for: session).map(\.turnPlacement),
            [.next]
        )
    }

    /// A payload written before provenance existed still decodes, and reads as the only kind it
    /// could have held.
    func testAPayloadWrittenBeforeProvenanceReadsAsTheAgents() throws {
        let session = SessionID()
        let file = try write([0x89], to: checkout.appendingPathComponent("old.png"))
        payloads[session] = """
        [{"projectRoot":"\(checkout.path)","relativePath":"old.png",\
        "kind":"image","referencedAt":0}]
        """

        let attachments = makeStore().attachments(for: session)

        XCTAssertEqual(attachments.map(\.origin), [.agent])
        XCTAssertEqual(attachments.map(\.url).map { $0.resolvingSymlinksInPath() },
                       [file.resolvingSymlinksInPath()])
    }

    func testAPersistedRootCannotGrantReadAuthorityOutsideTheSession() throws {
        let session = SessionID()
        let outside = try write([0x89], to: elsewhere.appendingPathComponent("private.png"))
        let relativeToFilesystemRoot = String(outside.path.dropFirst())
        payloads[session] = """
        [{"projectRoot":"/","relativePath":"\(relativeToFilesystemRoot)",\
        "kind":"image","referencedAt":0}]
        """

        XCTAssertEqual(
            makeStore().attachments(for: session),
            [],
            "a persisted absolute root outside the checkout became remote-readable authority"
        )
    }

    /// A payload from a *newer* build may name a kind this build has no case for. `Array`
    /// decoding is all-or-nothing and `loadIfNeeded` swallows the throw, so a strict decode
    /// cost the session its whole list — and the next admission persisted the fresh rows over
    /// a payload that still held every older one. One unknown row costs one row.
    func testAPayloadNamingAnUnknownKindKeepsEveryOtherRow() throws {
        let session = SessionID()
        let kept = try write([0x89], to: checkout.appendingPathComponent("kept.png"))
        try write([0x01], to: checkout.appendingPathComponent("mystery.hologram"))
        payloads[session] = """
        [{"projectRoot":"\(checkout.path)","relativePath":"mystery.hologram",\
        "kind":"hologram","referencedAt":1},\
        {"projectRoot":"\(checkout.path)","relativePath":"kept.png",\
        "kind":"image","referencedAt":0}]
        """

        let attachments = makeStore().attachments(for: session)

        XCTAssertEqual(
            attachments.map(\.name),
            ["kept.png"],
            "a kind this build does not know took the rest of the list with it"
        )
        XCTAssertEqual(attachments.map(\.url).map { $0.resolvingSymlinksInPath() },
                       [kept.resolvingSymlinksInPath()])
    }

    /// The same tolerance, the useful way round: a kind this build does not know over an
    /// extension it does re-derives from the file, the authority every read already trusts.
    func testAnUnknownKindOverAKnownExtensionReDerivesFromTheFile() throws {
        let session = SessionID()
        try write([0x89], to: checkout.appendingPathComponent("chart.png"))
        payloads[session] = """
        [{"projectRoot":"\(checkout.path)","relativePath":"chart.png",\
        "kind":"picture-but-newer","referencedAt":0}]
        """

        XCTAssertEqual(
            makeStore().attachments(for: session).map(\.kind),
            [.image],
            "a known file behind an unknown label was dropped instead of re-derived"
        )
    }

    // MARK: - Kinds

    /// The detector's explicit map: one extension per kind family, and never the old
    /// fall-through that read anything unclaimed as an image.
    func testTheDetectorNamesArchivesAndDocuments() {
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.zip")), .archive)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.tar")), .archive)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.tar.gz")), .archive)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.7z")), .archive)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.docx")), .document)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.odt")), .document)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.rtf")), .document)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.dot")), .diagram)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.gv")), .diagram)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.mmd")), .diagram)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.mermaid")), .diagram)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.png")), .image)
        XCTAssertEqual(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
        XCTAssertNil(AttachmentReferenceDetector.kind(for: URL(fileURLWithPath: "/a/b.swift")))
    }

    /// A Mermaid file named in output is filed like any other supported reference.
    func testAScannedDiagramInsideTheCheckoutIsRecorded() throws {
        let store = makeStore()
        let session = SessionID()
        try write(Array("graph TD; A-->B".utf8), to: checkout.appendingPathComponent("flow.mmd"))

        store.recordReferences(
            in: "sketched the flow in `flow.mmd`",
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(store.attachments(for: session).map { [$0.name: $0.kind] },
                       [["flow.mmd": .diagram]])
    }

    /// An archive named in output is filed like any other supported reference.
    func testAScannedArchiveInsideTheCheckoutIsRecorded() throws {
        let store = makeStore()
        let session = SessionID()
        try write([0x50, 0x4B, 0x05, 0x06], to: checkout.appendingPathComponent("dist.zip"))

        store.recordReferences(
            in: "wrote the release to `dist.zip`",
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(store.attachments(for: session).map { [$0.name: $0.kind] },
                       [["dist.zip": .archive]])
    }

    /// The alternation is ordered longest-first, and this is why: with `tif` offered before
    /// `tiff` and no boundary after the group, `shot.tiff` matched as `shot.tif` — a file that
    /// does not exist — and the real one was never recorded.
    func testALongerExtensionIsNotShadowedByItsPrefix() throws {
        let store = makeStore()
        let session = SessionID()
        try write([0x4D, 0x4D], to: checkout.appendingPathComponent("shot.tiff"))

        store.recordReferences(
            in: "saved shot.tiff",
            sessionID: session,
            projectRoot: checkout
        )

        XCTAssertEqual(store.attachments(for: session).map(\.name), ["shot.tiff"])
    }

    /// Full-screen TUIs paint pre-wrapped grid rows, so their terminal buffer cannot reconstruct
    /// the provider's original prose. The completed-turn transcript route must carry an intact
    /// long path through the same detector and store, including the hook-vs-writer flush retry.
    func testTranscriptObserverRecoversALongPathWrittenAfterTheTurnHook() throws {
        let session = SessionID()
        let image = checkout.appendingPathComponent(
            "managed-workspace-a-very-long-name-that-the-terminal-ui-would-wrap.png"
        )
        try write([0x89, 0x50], to: image)
        let transcript = checkout.appendingPathComponent("rollout.jsonl")
        try Data().write(to: transcript)

        let observer = TerminalTranscriptAttachmentObserver(
            sessionID: session,
            kind: .codex,
            projectRoot: { [checkout] in checkout },
            currentDirectory: { [checkout] in checkout },
            transcriptURL: { transcript }
        )
        observer.noteTurnFinished()

        // The zero-delay read intentionally sees an empty file. The first stability retry must
        // see the final provider record once its writer catches up with the lifecycle hook.
        let record = """
        {"type":"event_msg","payload":{"type":"agent_message","message":"Saved \(image.path)"}}
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            try? Data((record + "\n").utf8).write(to: transcript)
        }

        let deadline = Date().addingTimeInterval(1.5)
        while SessionAttachmentStore.shared.attachments(for: session).isEmpty,
              Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.025)))
        }

        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: session).map(\.name),
            [image.lastPathComponent]
        )
        _ = observer // Keep the retry generation alive through the assertion.
    }

    // MARK: - Custody Ends

    /// Bytes nobody else owns are the store's to remove: a row pushed out by the cap leaves
    /// nothing behind, and a referenced project file is never touched.
    func testEvictedAndForgottenRowsTakeTheirCopiesWithThem() throws {
        let store = makeStore()
        let session = SessionID()

        var kept: [String] = []
        for index in 0...SessionAttachmentDefaults.maximumPerSession {
            let file = try write(
                [UInt8(index % 251)],
                to: elsewhere.appendingPathComponent("shot-\(index).png")
            )
            let recorded = try XCTUnwrap(
                store.record(
                    declared: file,
                    sessionID: session,
                    projectRoot: checkout,
                    origin: .agent
                )
            )
            kept.append(recorded.relativePath)
        }

        let onDisk = try FileManager.default.contentsOfDirectory(
            at: copies.appendingPathComponent(session.uuidString, isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            onDisk.count,
            SessionAttachmentDefaults.maximumPerSession,
            "the copy of the row the cap evicted is still on disk"
        )

        store.retainOnly(sessionIDs: [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: copies.appendingPathComponent(session.uuidString).path
            ),
            "a forgotten session kept its copies"
        )
    }

    // MARK: - Stress

    /// Opt-in scan workload against a terminal-sized buffer of paths.
    ///
    /// This separates the event-loop cost from the worker cost: capturing the bounded terminal
    /// buffer and scheduling resolution must stay cheap even when regex and filesystem work do
    /// not. Two things about the scope change made it worth a deterministic number rather than
    /// an argument. Reporting an outside path costs a `stat`; the wide scope also takes custody
    /// of bytes when a newly visible file is admitted. `maximumCandidatesPerScan` bounds the
    /// worker half, and the per-session cap bounds worker custody plus main-actor publication.
    ///
    /// The buffer is generated before the clock starts. The production observer reports main-
    /// actor scheduling separately from worker resolution, main-actor admission and end-to-end
    /// readiness; a lower wall time is useful, but event-loop ownership is the invariant.
    func testStressAttachmentScanWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_ATTACHMENT_STRESS"] == "1",
            "Set THREADING_ATTACHMENT_STRESS=1 to run the attachment-scan sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let pathCount = environment["THREADING_ATTACHMENT_STRESS_PATHS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 1_000
        let shape = StressShape(
            rawValue: environment["THREADING_ATTACHMENT_STRESS_SHAPE"] ?? "mixed"
        ) ?? .mixed
        allowsFilesOutsideProject = environment["THREADING_ATTACHMENT_STRESS_SCOPE"] == "wide"
        let startedWide = allowsFilesOutsideProject

        let buffer = try makeStressBuffer(shape: shape, pathCount: pathCount)
        let rolloverURLs: [URL] = if shape == .outside, startedWide {
            try (0..<SessionAttachmentDefaults.maximumPerSession).map { index in
                try write(
                    [0x89, 0x50, 0x4E, UInt8(index % 255)],
                    to: elsewhere.appendingPathComponent("rollover-\(index).png")
                )
            }
        } else {
            []
        }
        let store = makeStore()
        let session = SessionID()
        let observer = TerminalAttachmentObserver(
            sessionID: session,
            projectRoot: { [checkout] in checkout },
            currentDirectory: { [checkout] in checkout },
            text: { _ in TerminalScanRead(text: buffer.text, nextAbsoluteRow: 0) },
            record: { resolution, sessionID, root, shouldAdmit in
                await store.recordScanned(
                    resolved: resolution,
                    sessionID: sessionID,
                    projectRoot: root,
                    shouldAdmit: shouldAdmit
                )
            }
        )

        // A cold scan, then a repeat of the identical buffer: the second is the one a repainting
        // terminal actually pays, since every path in it has been seen and admitted already.
        let baselineMemory = Self.physicalFootprintBytes()
        let coldStarted = DispatchTime.now().uptimeNanoseconds
        observer.scanNow()
        let coldScheduled = DispatchTime.now().uptimeNanoseconds
        waitForAttachmentScan(observer)
        let coldReady = DispatchTime.now().uptimeNanoseconds
        let coldMetrics = try XCTUnwrap(observer.lastScanMetrics)
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        observer.scanNow()
        let warmScheduled = DispatchTime.now().uptimeNanoseconds
        waitForAttachmentScan(observer)
        let warmReady = DispatchTime.now().uptimeNanoseconds
        let warmMetrics = try XCTUnwrap(observer.lastScanMetrics)

        // A full new generation proves whether evicting a full standing list returns filesystem
        // cleanup to the main actor. This is the cold edge after ordinary first admission.
        let rolloverStarted = DispatchTime.now().uptimeNanoseconds
        var rolloverResult: SessionAttachmentStore.ScannedRecordResult?
        if rolloverURLs.isEmpty {
            rolloverResult = .empty
        } else {
            Task { @MainActor in
                rolloverResult = await store.recordScanned(
                    resolved: .init(outsideProject: rolloverURLs),
                    sessionID: session,
                    projectRoot: checkout
                )
            }
            let deadline = Date().addingTimeInterval(2)
            while rolloverResult == nil, Date() < deadline {
                RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
            }
        }
        let rolloverReady = DispatchTime.now().uptimeNanoseconds
        let measuredRollover = try XCTUnwrap(rolloverResult)

        // And the one snapshot a pane refresh consumes: visible rows plus its scope-band count,
        // from one filesystem validation rather than two identical passes over the capped list.
        let snapshotStarted = DispatchTime.now().uptimeNanoseconds
        let listSnapshot = store.listSnapshot(for: session)
        let snapshotEnded = DispatchTime.now().uptimeNanoseconds
        let listed = listSnapshot.attachments
        let outside = listSnapshot.countOfFilesOutsideProject

        // Keep the pane's Show action separate from scanning so a fast observer cannot conceal
        // a slow settings interaction, and split its event-loop work from worker custody too.
        let widenStarted = DispatchTime.now().uptimeNanoseconds
        var widenScheduled = widenStarted
        var widenResult: SessionAttachmentStore.ScannedRecordResult?
        if !startedWide, !store.withheldReferences(for: session).isEmpty {
            allowsFilesOutsideProject = true
            Task { @MainActor in
                widenResult = await store.admitWithheldFilesOutsideProjectAsync(for: session)
            }
            widenScheduled = DispatchTime.now().uptimeNanoseconds
            let deadline = Date().addingTimeInterval(2)
            while widenResult == nil, Date() < deadline {
                RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
            }
        } else {
            widenResult = .empty
        }
        let widenEnded = DispatchTime.now().uptimeNanoseconds
        let measuredWiden = try XCTUnwrap(widenResult)

        XCTAssertLessThanOrEqual(listed.count, SessionAttachmentDefaults.maximumPerSession)
        XCTAssertLessThanOrEqual(
            store.withheldReferences(for: session).count,
            SessionAttachmentDefaults.maximumWithheldPerSession
        )

        let copiedBytes = Self.directoryBytes(copies)
        let memoryDelta = Self.physicalFootprintBytes().saturatingSubtract(baselineMemory)
        print(
            "THREADING_PERF attachment-scan "
                + "shape=\(shape.rawValue) scope=\(startedWide ? "wide" : "narrow") "
                + "paths=\(pathCount) buffer_kb=\(buffer.text.utf8.count / 1024) "
                + "inside_on_disk=\(buffer.insideCount) outside_on_disk=\(buffer.outsideCount) "
                + "admitted=\(coldMetrics.recorded) listed=\(listed.count) "
                + "withheld=\(store.withheldReferences(for: session).count) outside_count=\(outside) "
                + "cold_schedule_ms=\(Self.milliseconds(coldScheduled - coldStarted)) "
                + "cold_worker_ms=\(Self.milliseconds(coldMetrics.workerNanoseconds)) "
                + "cold_custody_worker_ms=\(Self.milliseconds(coldMetrics.custodyWorkerNanoseconds)) "
                + "cold_apply_ms=\(Self.milliseconds(coldMetrics.applyNanoseconds)) "
                + "cold_ready_ms=\(Self.milliseconds(coldReady - coldStarted)) "
                + "warm_schedule_ms=\(Self.milliseconds(warmScheduled - warmStarted)) "
                + "warm_worker_ms=\(Self.milliseconds(warmMetrics.workerNanoseconds)) "
                + "warm_custody_worker_ms=\(Self.milliseconds(warmMetrics.custodyWorkerNanoseconds)) "
                + "warm_apply_ms=\(Self.milliseconds(warmMetrics.applyNanoseconds)) "
                + "warm_ready_ms=\(Self.milliseconds(warmReady - warmStarted)) "
                + "rollover_recorded=\(measuredRollover.attachments.count) "
                + "rollover_custody_worker_ms=\(Self.milliseconds(measuredRollover.custodyWorkerNanoseconds)) "
                + "rollover_apply_ms=\(Self.milliseconds(measuredRollover.mainActorNanoseconds)) "
                + "rollover_ready_ms=\(Self.milliseconds(rolloverReady - rolloverStarted)) "
                + "widened=\(measuredWiden.attachments.count) "
                + "widen_schedule_ms=\(Self.milliseconds(widenScheduled - widenStarted)) "
                + "widen_custody_worker_ms=\(Self.milliseconds(measuredWiden.custodyWorkerNanoseconds)) "
                + "widen_apply_ms=\(Self.milliseconds(measuredWiden.mainActorNanoseconds)) "
                + "widen_ready_ms=\(Self.milliseconds(widenEnded - widenStarted)) "
                + "snapshot_ms=\(Self.milliseconds(snapshotEnded - snapshotStarted)) "
                + "copied_mb=\(Self.megabytes(copiedBytes)) "
                + "footprint_delta_mb=\(Self.megabytes(memoryDelta))"
        )
    }

    /// What the scanned text is made of. Each is a real afternoon in a terminal.
    private enum StressShape: String {
        /// Paths to files that exist, half in the checkout and half outside it.
        case mixed
        /// Every path outside the checkout — `find ~ -name '*.png'`, the case the rule exists for.
        case outside
        /// Path-*shaped* prose naming nothing that exists: the cheapest to refuse and the most
        /// common, since a build log is mostly words.
        case absent
    }

    private struct StressBuffer {
        let text: String
        let insideCount: Int
        let outsideCount: Int
    }

    private func makeStressBuffer(shape: StressShape, pathCount: Int) throws -> StressBuffer {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        var lines: [String] = []
        var insideCount = 0
        var outsideCount = 0

        for index in 0..<pathCount {
            let isInside = shape == .mixed && index.isMultiple(of: 2)
            switch shape {
            case .absent:
                lines.append("could not open /Users/nobody/missing-\(index).png: no such file")
            case .mixed, .outside:
                let file = isInside
                    ? checkout.appendingPathComponent("render-\(index).png")
                    : elsewhere.appendingPathComponent("shot-\(index).png")
                try bytes.write(to: file)
                if isInside {
                    insideCount += 1
                    lines.append("wrote `render-\(index).png` in 12ms")
                } else {
                    outsideCount += 1
                    lines.append("wrote \(file.path) in 12ms")
                }
            }
            // Prose between the paths, because a scan reads a terminal rather than a manifest,
            // and the regex pass is over all of it.
            lines.append("  \(index) files considered, 0 errors, 12 warnings — continuing")
        }
        return StressBuffer(
            text: lines.joined(separator: "\n"),
            insideCount: insideCount,
            outsideCount: outsideCount
        )
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func directoryBytes(_ directory: URL) -> UInt64 {
        let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        var total: UInt64 = 0
        while let url = files?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += UInt64(size)
        }
        return total
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
