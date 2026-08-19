import XCTest
@testable import Threading

/// The bound on position-only continuity records, and the keystroke latency that depends on it.
///
/// Every mutation of this store rewrites, re-reads and re-verifies the whole file, so its size
/// is a typing-latency property rather than a disk-usage one: a composer draft and an image
/// annotation note are both written per keystroke. On a real machine the file had reached 7,163
/// records — 7,159 of them a reading position for a session that no longer existed — and 2.2 MB,
/// which put one keystroke at 47 ms.
@MainActor
final class SessionContinuityPruningTests: XCTestCase {

    private var testDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
        testDirectory = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> SessionContinuityStore {
        SessionContinuityStore(directory: testDirectory)
    }

    // MARK: - The bound

    func testPositionOnlyRecordsAreBoundedToTheRetainedCount() {
        let store = makeStore()
        let bound = SessionContinuityDefaults.retainedPositionCount

        var ids: [SessionID] = []
        for index in 0..<(bound + 50) {
            let id = SessionID()
            ids.append(id)
            store.setConversationViewport(
                progress: Double(index % 10) / 10,
                followsBottom: false,
                for: id
            )
        }

        let surviving = ids.filter { store.state(for: $0).conversationViewportProgress != nil }
        XCTAssertEqual(
            surviving.count,
            bound,
            "position-only records should be bounded to the retained count"
        )
        XCTAssertEqual(
            Set(surviving),
            Set(ids.suffix(bound)),
            "the newest positions are the ones kept"
        )
    }

    func testADraftIsNeverPrunedByLaterPositions() {
        let store = makeStore()
        let authored = SessionID()
        store.setConversationDraft("half a sentence nobody sent", for: authored)

        for _ in 0..<(SessionContinuityDefaults.retainedPositionCount + 200) {
            store.setConversationViewport(progress: 0.5, followsBottom: false, for: SessionID())
        }

        XCTAssertEqual(
            store.state(for: authored).conversationDraft,
            "half a sentence nobody sent",
            "unsent words are not disposable history"
        )
    }

    func testAnAnnotationDocumentIsNeverPrunedByLaterPositions() {
        let store = makeStore()
        let marked = SessionID()
        store.setImageAnnotations(
            [ImageAnnotation(point: CGPoint(x: 0.25, y: 0.75), note: "this corner")],
            assetKeys: ["file:/tmp/shot.png"],
            sourceAttachmentID: nil,
            sourcePath: "/tmp/shot.png",
            title: "shot",
            in: marked
        )

        for _ in 0..<(SessionContinuityDefaults.retainedPositionCount + 200) {
            store.setConversationViewport(progress: 0.5, followsBottom: false, for: SessionID())
        }

        XCTAssertEqual(
            store.imageAnnotationDocuments(in: marked).first?.annotations.first?.note,
            "this corner",
            "an editable annotation document is user-authored work, not a reading position"
        )
    }

    /// A file written before the bound existed shrinks on the way in, so the first keystroke
    /// after launch is already cheap rather than paying for the whole grown file once.
    func testAnAlreadyGrownFileIsPrunedOnLoad() throws {
        let seeded = try seedPositionOnlyFile(
            count: SessionContinuityDefaults.retainedPositionCount + 500
        )

        let store = makeStore()
        let surviving = seeded.filter { store.state(for: $0).conversationViewportProgress != nil }
        XCTAssertEqual(surviving.count, SessionContinuityDefaults.retainedPositionCount)
    }

    /// Writes the store's file directly with `count` position-only records, standing in for one
    /// that grew over months without paying for one whole-file write per record.
    @discardableResult
    private func seedPositionOnlyFile(count: Int) throws -> [SessionID] {
        var ids: [SessionID] = []
        var states: [String: Any] = [:]
        for _ in 0..<count {
            let id = SessionID()
            ids.append(id)
            states[id.uuidString] = [
                "conversationDraft": "",
                "conversationContext": [],
                "conversationViewportProgress": 0.5,
                "conversationFollowsBottom": false,
                "imageAnnotationDocuments": [String: Any](),
                "updatedAt": 774_000_000.0
            ] as [String: Any]
        }
        let envelope: [String: Any] = ["formatVersion": 1, "value": ["states": states]]
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: testDirectory.appendingPathComponent(SessionContinuityDefaults.fileName))
        return ids
    }

    // MARK: - Latency

    /// The [Scaling Gate](../../CLAUDE.md#scaling-gate) boundary this file exists to hold: one
    /// keystroke's persistence stays frame-cheap however many sessions have ever been scrolled.
    func testAKeystrokeStaysCheapAfterThousandsOfSessionsHaveBeenScrolled() throws {
        // Seeded as a file rather than 7,163 writes, because that is the shape the bug had: the
        // app launches onto a file that grew over months, and the first thing it must do is type.
        try seedPositionOnlyFile(count: 7_163)
        let store = makeStore()

        let typing = SessionID()
        var draft = ""
        // Warm, so the measurement is the steady state rather than the first encode.
        for _ in 0..<5 {
            draft += "a"
            store.setConversationDraft(draft, for: typing)
        }

        var samples: [Double] = []
        for _ in 0..<40 {
            draft += "a"
            let started = CFAbsoluteTimeGetCurrent()
            store.setConversationDraft(draft, for: typing)
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]

        // Unbounded this measured 47 ms per character on a real 2.2 MB file; bounded it is ~2 ms.
        // The gate is deliberately loose so a slow machine does not fail it, and still an order
        // of magnitude below the behaviour it exists to catch.
        XCTAssertLessThan(
            median,
            15,
            "a keystroke rewrites the continuity file, so the file has to stay bounded"
        )
    }
}
