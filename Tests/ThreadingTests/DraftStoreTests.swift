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

    func testDraftMemoryDoesNotClaimAWriteTheFileSystemRefused() {
        let projectID = ProjectID()
        let store = makeStore(fileManager: RefusingDraftFileManager())

        store.setDraft("not durable", for: projectID)

        XCTAssertEqual(store.draft(for: projectID), "")
        XCTAssertEqual(makeStore().draft(for: projectID), "")
    }

    func testDraftClearFailsClosedWhenTheFileCannotBeRewritten() {
        let projectID = ProjectID()
        makeStore().setDraft("still on disk", for: projectID)
        let store = makeStore(fileManager: RefusingDraftFileManager())

        store.clear(for: projectID)

        XCTAssertEqual(store.draft(for: projectID), "still on disk")
        XCTAssertEqual(makeStore().draft(for: projectID), "still on disk")
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

    func testSessionContinuityPreservesStructuredWorkspaceReferences() {
        let sessionID = SessionID()
        let reference = ConversationContextAttachment(
            id: UUID(uuidString: "6DFCC50B-180A-4E20-A601-B139DF88078E")!,
            kind: .reference,
            source: .workspaceFile,
            title: "PromptView.swift",
            locator: "Sources/Threading/UI/Design/PromptView.swift"
        )
        makeContinuityStore().setConversationDraft(
            "Please review this",
            context: [reference],
            for: sessionID
        )

        let reloaded = makeContinuityStore().state(for: sessionID)
        XCTAssertEqual(reloaded.conversationDraft, "Please review this")
        XCTAssertEqual(reloaded.conversationContext, [reference])
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

    func testSessionContinuityMemoryDoesNotAdvancePastARefusedWrite() {
        let sessionID = SessionID()
        let store = makeContinuityStore(fileManager: RefusingDraftFileManager())

        store.setConversationDraft("not durable", for: sessionID)

        let standing = store.state(for: sessionID)
        let reloaded = makeContinuityStore().state(for: sessionID)
        XCTAssertEqual(standing.conversationDraft, "")
        XCTAssertNil(standing.conversationViewportProgress)
        XCTAssertEqual(reloaded.conversationDraft, "")
        XCTAssertNil(reloaded.conversationViewportProgress)
    }

    func testImageAnnotationDocumentSurvivesReopenWithIdentityAndRevision() throws {
        let sessionID = SessionID()
        let source = URL(fileURLWithPath: "/tmp/layout.png")
        let attachmentKey = ImageAnnotationAssetKey.attachment("asset-1")
        let annotations = [
            ImageAnnotation(point: CGPoint(x: 0.2, y: 0.3), note: "too close"),
            ImageAnnotation(point: CGPoint(x: 0.8, y: 0.6), note: "wrong colour")
        ]
        let document = try XCTUnwrap(makeContinuityStore().setImageAnnotations(
            annotations,
            assetKeys: [ImageAnnotationAssetKey.file(source), attachmentKey],
            sourceAttachmentID: "asset-1",
            sourcePath: source.path,
            title: "layout.png",
            in: sessionID
        ))

        let reopened = try XCTUnwrap(makeContinuityStore().imageAnnotationDocument(
            forAssetKey: attachmentKey,
            in: sessionID
        ))
        XCTAssertEqual(reopened.id, document.id)
        XCTAssertEqual(reopened.contextAttachmentID, document.contextAttachmentID)
        XCTAssertEqual(reopened.annotations, annotations)
        XCTAssertEqual(reopened.revision, 1)
    }

    func testAnnotationAliasesDoNotCreateAnotherDocumentOrRevision() throws {
        let sessionID = SessionID()
        let store = makeContinuityStore()
        let annotations = [ImageAnnotation(point: CGPoint(x: 0.5, y: 0.5), note: "here")]
        let first = try XCTUnwrap(store.setImageAnnotations(
            annotations,
            assetKeys: ["file:/tmp/source.png"],
            sourceAttachmentID: nil,
            sourcePath: "/tmp/source.png",
            title: "source.png",
            in: sessionID
        ))
        let aliased = try XCTUnwrap(store.setImageAnnotations(
            annotations,
            assetKeys: ["file:/tmp/source.png", "attachment:stable"],
            sourceAttachmentID: "stable",
            sourcePath: "/tmp/custody/source.png",
            title: "source.png",
            in: sessionID
        ))

        XCTAssertEqual(aliased.id, first.id)
        XCTAssertEqual(aliased.revision, first.revision)
        XCTAssertEqual(store.imageAnnotationDocuments(in: sessionID).count, 1)
    }

    // MARK: - Helpers

    private func makeStore(fileManager: FileManager = .default) -> DraftStore {
        DraftStore(directory: testDirectory, fileManager: fileManager)
    }

    private func makeContinuityStore(fileManager: FileManager = .default) -> SessionContinuityStore {
        SessionContinuityStore(directory: testDirectory, fileManager: fileManager)
    }
}

/// `RecoverableFileStore` creates the parent before every atomic save. Refusing that operation
/// exercises the store's durable commit edge without relying on host-specific permissions.
private final class RefusingDraftFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
