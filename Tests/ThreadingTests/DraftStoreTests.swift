import XCTest
@testable import Threading

@MainActor
final class DraftStoreTests: XCTestCase {

    nonisolated(unsafe) private var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-draft-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        try super.tearDownWithError()
    }

    /// The whole point of the store: what was typed outlives the process that took it.
    func testDraftSurvivesANewStore() {
        let projectID = ProjectID()
        makeStore().setDraft("half a thought", for: projectID)

        XCTAssertEqual(makeStore().draft(for: projectID), "half a thought")
    }

    func testDraftsAreKeptPerProject() {
        let store = makeStore()
        let first = ProjectID()
        let second = ProjectID()

        store.setDraft("for the first", for: first)
        store.setDraft("for the second", for: second)

        XCTAssertEqual(store.draft(for: first), "for the first")
        XCTAssertEqual(store.draft(for: second), "for the second")
    }

    func testUnknownProjectHasAnEmptyDraft() {
        XCTAssertEqual(makeStore().draft(for: ProjectID()), "")
    }

    /// Emptying the field is not a draft worth keeping — and must not resurrect the old one.
    func testClearingTheFieldRemovesTheDraft() {
        let projectID = ProjectID()
        let store = makeStore()

        store.setDraft("typed then deleted", for: projectID)
        store.setDraft("   ", for: projectID)

        XCTAssertEqual(store.draft(for: projectID), "")
        XCTAssertEqual(makeStore().draft(for: projectID), "")
    }

    /// Starting the session is what drops the draft, so returning to the project is a fresh
    /// composer rather than the prompt that has already been sent.
    func testClearRemovesTheDraft() {
        let projectID = ProjectID()
        let store = makeStore()

        store.setDraft("about to be started", for: projectID)
        store.clear(for: projectID)

        XCTAssertEqual(makeStore().draft(for: projectID), "")
    }

    /// Leading and trailing space is only used to decide whether a draft exists: the text is
    /// stored as typed, since a prompt may deliberately end mid-sentence.
    func testDraftIsStoredVerbatim() {
        let projectID = ProjectID()
        makeStore().setDraft("  indented, and unfinished ", for: projectID)

        XCTAssertEqual(makeStore().draft(for: projectID), "  indented, and unfinished ")
    }

    func testUnreadableDraftFileIsPreservedBeforeNewTypingIsSaved() throws {
        let original = Data("{ damaged".utf8)
        let liveURL = testDirectory.appendingPathComponent(DraftDefaults.fileName)
        try original.write(to: liveURL)

        let store = makeStore()
        let projectID = ProjectID()
        XCTAssertEqual(store.draft(for: projectID), "")

        let quarantine = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: testDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("\(DraftDefaults.fileName).unreadable-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), original)

        store.setDraft("new work", for: projectID)
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
        XCTAssertEqual(makeStore().draft(for: projectID), "new work")
    }

    func testInvalidProjectIdentifierFailsTheWholeDraftLoad() throws {
        let original = Data(#"{"drafts":{"not-a-project-id":"do not silently skip me"}}"#.utf8)
        let liveURL = testDirectory.appendingPathComponent(DraftDefaults.fileName)
        try original.write(to: liveURL)

        _ = makeStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path))
        let quarantine = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: testDirectory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("\(DraftDefaults.fileName).unreadable-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), original)
    }

    func testSessionContinuitySurvivesANewStoreAndStaysPerSession() {
        let first = SessionID()
        let second = SessionID()
        let store = makeContinuityStore()

        store.setConversationDraft("unfinished answer", for: first)
        store.setConversationDraft("other session", for: second)
        store.setConversationViewport(progress: 0.37, followsBottom: false, for: first)

        let reloaded = makeContinuityStore()
        XCTAssertEqual(reloaded.state(for: first).conversationDraft, "unfinished answer")
        XCTAssertEqual(reloaded.state(for: second).conversationDraft, "other session")
        XCTAssertEqual(reloaded.state(for: first).conversationViewportProgress, 0.37)
        XCTAssertFalse(reloaded.state(for: first).conversationFollowsBottom)
    }

    func testSessionContinuityClearsOnlyTheAcceptedDraft() {
        let sessionID = SessionID()
        let store = makeContinuityStore()
        store.setConversationDraft("sent", for: sessionID)
        store.setConversationViewport(progress: 0.5, followsBottom: false, for: sessionID)

        store.setConversationDraft("", for: sessionID)

        XCTAssertEqual(store.state(for: sessionID).conversationDraft, "")
        XCTAssertEqual(store.state(for: sessionID).conversationViewportProgress, 0.5)
    }

    func testSessionContinuityClampsViewportProgress() {
        let sessionID = SessionID()
        let store = makeContinuityStore()

        store.setConversationViewport(progress: 2, followsBottom: false, for: sessionID)
        XCTAssertEqual(store.state(for: sessionID).conversationViewportProgress, 1)

        store.setConversationViewport(progress: -1, followsBottom: false, for: sessionID)
        XCTAssertEqual(store.state(for: sessionID).conversationViewportProgress, 0)
    }

    // MARK: - Helpers

    private func makeStore() -> DraftStore {
        DraftStore(directory: testDirectory)
    }

    private func makeContinuityStore() -> SessionContinuityStore {
        SessionContinuityStore(directory: testDirectory)
    }
}
