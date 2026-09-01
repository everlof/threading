import XCTest
@testable import Threading

/// Covers the one thing a repainting terminal makes the attachment scanner do over and over:
/// resolve text it has already resolved.
///
/// A TUI agent rewrites its screen in place rather than appending, so `noteOutput` fires
/// continuously while the bytes under the read window stay exactly what they were. One four
/// minute trace held 736 scans, most of them over unchanged text, each running the reference
/// regex again on a background thread for an answer that could not differ.
///
/// What matters here is that the skip is only ever taken when the answer genuinely cannot have
/// moved. A scanner that is fast because it stopped noticing new paths is a worse scanner.
@MainActor
final class TerminalAttachmentScanReuseTests: XCTestCase {

    // MARK: - Fixtures

    private var checkout: URL!

    /// Boxed so the observer's `text` closure and the test can both see the same buffer.
    private final class Buffer {
        var text: String
        var nextAbsoluteRow: Int
        init(text: String, nextAbsoluteRow: Int = 0) {
            self.text = text
            self.nextAbsoluteRow = nextAbsoluteRow
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-scan-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let checkout { try? FileManager.default.removeItem(at: checkout) }
        super.tearDown()
    }

    private func waitForScan(_ observer: TerminalAttachmentObserver, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while observer.isScanInFlight, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        XCTAssertFalse(observer.isScanInFlight, "attachment resolution did not finish")
    }

    private func makeObserver(buffer: Buffer) -> TerminalAttachmentObserver {
        TerminalAttachmentObserver(
            sessionID: SessionID(),
            projectRoot: { [checkout] in checkout },
            currentDirectory: { [checkout] in checkout },
            text: { _ in
                TerminalScanRead(text: buffer.text, nextAbsoluteRow: buffer.nextAbsoluteRow)
            },
            record: { _, _, _, _ in SessionAttachmentStore.ScannedRecordResult.empty }
        )
    }

    /// Whether the scan just asked for actually ran a detection pass.
    ///
    /// `isScanInFlight` is the structural answer rather than a proxy for one: a real scan sets it
    /// synchronously as it hands the text to the detached detector, and the skip returns before
    /// that task is ever created. Counting recorded attachments would not do — the recorder is
    /// only reached when something was found, so it cannot tell "scanned and found nothing" from
    /// "did not scan".
    private func didResolve(_ observer: TerminalAttachmentObserver) -> Bool {
        let started = observer.isScanInFlight
        waitForScan(observer)
        return started
    }

    // MARK: - Reuse

    func testAnUnchangedBufferIsNotResolvedAgain() throws {
        let file = checkout.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        let buffer = Buffer(text: "wrote \(file.path)\n")
        let observer = makeObserver(buffer: buffer)

        observer.scanNow()
        XCTAssertTrue(didResolve(observer), "the first sighting of a buffer is resolved")
        XCTAssertEqual(observer.lastScanMetrics?.wasUnchanged, false)

        observer.scanNow()
        XCTAssertFalse(didResolve(observer), "identical text cannot resolve differently")
        XCTAssertEqual(
            observer.lastScanMetrics?.wasUnchanged,
            true,
            "a skipped scan still reports itself, so the stress fixture can measure it"
        )
    }

    /// The half that makes the skip safe: new text is still detected.
    func testAChangedBufferIsResolved() throws {
        let first = checkout.appendingPathComponent("first.txt")
        let second = checkout.appendingPathComponent("second.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        let buffer = Buffer(text: "wrote \(first.path)\n")
        let observer = makeObserver(buffer: buffer)

        observer.scanNow()
        XCTAssertTrue(didResolve(observer))

        buffer.text += "wrote \(second.path)\n"
        observer.scanNow()
        XCTAssertTrue(didResolve(observer), "changed text must be resolved")
        XCTAssertEqual(observer.lastScanMetrics?.wasUnchanged, false)
    }

    /// Text can repeat while the buffer advances — a spinner, a progress line rewritten in
    /// place. The row position is part of the fingerprint so the read window cannot stall behind
    /// output that happens to look the same.
    func testAnAdvancingBufferIsResolvedEvenWhenTheTextRepeats() throws {
        let file = checkout.appendingPathComponent("only.txt")
        try Data("x".utf8).write(to: file)

        let buffer = Buffer(text: "wrote \(file.path)\n", nextAbsoluteRow: 1)
        let observer = makeObserver(buffer: buffer)

        observer.scanNow()
        XCTAssertTrue(didResolve(observer))

        buffer.nextAbsoluteRow = 2
        observer.scanNow()
        XCTAssertTrue(didResolve(observer), "an advanced buffer is scanned even if the text matches")
    }
}
