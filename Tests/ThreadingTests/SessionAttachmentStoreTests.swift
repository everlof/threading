import XCTest
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

    private func makeStore(takesCustody: Bool = true) -> SessionAttachmentStore {
        SessionAttachmentStore(
            loadPayload: { [weak self] in self?.payloads[$0] },
            savePayload: { [weak self] payload, id in self?.payloads[id] = payload },
            retainPersisted: { [weak self] ids in
                self?.payloads = self?.payloads.filter { ids.contains($0.key) } ?? [:]
            },
            copiesDirectory: takesCustody ? { [copies] in copies! } : nil
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
}
