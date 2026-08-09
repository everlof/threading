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

    private func makeStore(takesCustody: Bool = true) -> SessionAttachmentStore {
        SessionAttachmentStore(
            loadPayload: { [weak self] in self?.payloads[$0] },
            savePayload: { [weak self] payload, id in self?.payloads[id] = payload },
            retainPersisted: { [weak self] ids in
                self?.payloads = self?.payloads.filter { ids.contains($0.key) } ?? [:]
            },
            copiesDirectory: takesCustody ? { [copies] in copies! } : nil,
            allowsFilesOutsideProject: { [weak self] in self?.allowsFilesOutsideProject ?? false }
        )
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
    /// This is the main thread's work: the observer scans on the same queue the window draws on,
    /// so the scan's cost is a stall's cost. Two things about the scope change made it worth a
    /// deterministic number rather than an argument. Containment used to be answered *before*
    /// the filesystem, so an outside path was rejected on a string comparison; reporting one
    /// costs a `stat`, which puts the filesystem in the path of text an agent merely printed.
    /// And the wide scope copies bytes, on that same thread. `maximumCandidatesPerScan` is what
    /// bounds the first; the per-session cap bounds the second.
    ///
    /// The buffer is generated before the clock starts, so the measurements cover the regex
    /// pass, the resolution, the admission and — where the workload asks for it — the copies.
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

        let buffer = try makeStressBuffer(shape: shape, pathCount: pathCount)
        let store = makeStore()
        let session = SessionID()

        // A cold scan, then a repeat of the identical buffer: the second is the one a repainting
        // terminal actually pays, since every path in it has been seen and admitted already.
        let baselineMemory = Self.physicalFootprintBytes()
        let coldStarted = DispatchTime.now().uptimeNanoseconds
        let admitted = store.recordReferences(
            in: buffer.text,
            sessionID: session,
            projectRoot: checkout
        )
        let coldEnded = DispatchTime.now().uptimeNanoseconds
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        store.recordReferences(in: buffer.text, sessionID: session, projectRoot: checkout)
        let warmEnded = DispatchTime.now().uptimeNanoseconds

        // And the read every pane, tool and remote fetch goes through, which re-proves each
        // stored row against the filesystem and applies the scope gate.
        let readStarted = DispatchTime.now().uptimeNanoseconds
        let listed = store.attachments(for: session)
        let readEnded = DispatchTime.now().uptimeNanoseconds
        let countStarted = DispatchTime.now().uptimeNanoseconds
        let outside = store.countOfFilesOutsideProject(for: session)
        let countEnded = DispatchTime.now().uptimeNanoseconds

        XCTAssertLessThanOrEqual(listed.count, SessionAttachmentDefaults.maximumPerSession)
        XCTAssertLessThanOrEqual(
            store.withheldReferences(for: session).count,
            SessionAttachmentDefaults.maximumWithheldPerSession
        )

        let copiedBytes = Self.directoryBytes(copies)
        let memoryDelta = Self.physicalFootprintBytes().saturatingSubtract(baselineMemory)
        print(
            "THREADING_PERF attachment-scan "
                + "shape=\(shape.rawValue) scope=\(allowsFilesOutsideProject ? "wide" : "narrow") "
                + "paths=\(pathCount) buffer_kb=\(buffer.text.utf8.count / 1024) "
                + "inside_on_disk=\(buffer.insideCount) outside_on_disk=\(buffer.outsideCount) "
                + "admitted=\(admitted.count) listed=\(listed.count) "
                + "withheld=\(store.withheldReferences(for: session).count) outside_count=\(outside) "
                + "cold_scan_ms=\(Self.milliseconds(coldEnded - coldStarted)) "
                + "warm_scan_ms=\(Self.milliseconds(warmEnded - warmStarted)) "
                + "read_ms=\(Self.milliseconds(readEnded - readStarted)) "
                + "count_ms=\(Self.milliseconds(countEnded - countStarted)) "
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
