import XCTest
@testable import Threading

final class DraftStoreTests: XCTestCase {

    private var testDirectory: URL!

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

    // MARK: - Helpers

    private func makeStore() -> DraftStore {
        DraftStore(directory: testDirectory)
    }
}
