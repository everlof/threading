import Foundation
import XCTest
@testable import DeviceLogsPlugin

final class LogMessageHighlighterTests: XCTestCase {
    private func styled(_ message: String, _ kind: LogMessageHighlighter.Kind,
                        highlights: [String: BluetoothHighlightColor] = [:]) -> [(String, LogMessageStyle)] {
        let text = message as NSString
        return LogMessageHighlighter.spans(message, kind: kind, highlights: highlights)
            .map { (text.substring(with: $0.range), $0.style) }
    }

    private func style(of word: String, in spans: [(String, LogMessageStyle)]) -> LogMessageStyle? {
        spans.first { $0.0 == word }?.1
    }

    func testADecodedRowShowsItsRouteCharacteristicValuesAndTail() {
        let message = "RX Pulse 4F2A → iPhone · Messages notify · LOCATION #412 "
            + "{lat=59.3293° lon=-18.0686° accuracy=4.5 m flags=precise} · 14 bytes | 01 9c 01"
        let spans = styled(message, .bluetoothApp, highlights: ["accuracy": .orange, "precise": .yellow])
        XCTAssertEqual(style(of: "RX", in: spans), .direction(received: true))
        XCTAssertEqual(style(of: "Pulse 4F2A → iPhone", in: spans), .route)
        XCTAssertEqual(style(of: "Messages", in: spans), .characteristic)
        XCTAssertEqual(style(of: "notify", in: spans), .verb)
        XCTAssertEqual(style(of: "LOCATION", in: spans), .constant)
        XCTAssertEqual(style(of: "#412", in: spans), .number)
        XCTAssertEqual(style(of: "lat", in: spans), .key)
        XCTAssertEqual(style(of: "59.3293°", in: spans), .number)
        XCTAssertEqual(style(of: "-18.0686°", in: spans), .number)
        XCTAssertEqual(style(of: "accuracy", in: spans), .custom(.orange), "a highlighted field id")
        XCTAssertEqual(style(of: "4.5", in: spans), .custom(.orange), "and its value")
        XCTAssertEqual(style(of: "precise", in: spans), .custom(.yellow), "a highlighted word")
        XCTAssertEqual(style(of: "{", in: spans), .punctuation)
        XCTAssertEqual(style(of: " · 14 bytes | 01 9c 01", in: spans), .preview)
    }

    func testStringsBytesWarningsAndProtocolRows() {
        let app = styled(#"TX iPhone → Strap · Control write · STATUS #2 {name="a \"b\" c" raw=<dead…+4>} ⚠ 3 trailing bytes not described · 9 bytes | 02"#, .bluetoothApp)
        XCTAssertEqual(style(of: "TX", in: app), .direction(received: false))
        XCTAssertEqual(style(of: #""a \"b\" c""#, in: app), .string, "escaped quotes stay inside the string")
        XCTAssertEqual(style(of: "<dead…+4>", in: app), .number)
        XCTAssertEqual(style(of: "⚠ 3 trailing bytes not described", in: app), .warning)

        let att = styled("RX ACL handle=0x0040 ATT Read Request attribute=0x0030 uuid=6E400003-B5A3-F393-E0A9-E50E24DCCA9E · 11 bytes | 40", .bluetooth)
        XCTAssertNil(style(of: "ACL", in: att), "protocol names stay in the row's ink")
        XCTAssertEqual(style(of: "0x0040", in: att), .number)
        XCTAssertEqual(style(of: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", in: att), .uuid)
        XCTAssertNil(style(of: "Read", in: att), "ordinary words stay in the row's ink")
    }

    func testPlainLogLinesGetGrammarButNoBluetoothFraming() {
        let spans = styled(#"RX queue drained count=12 state="idle" err=-3 | done"#, .plain)
        XCTAssertNil(style(of: "RX", in: spans), "only a packet row has a direction")
        XCTAssertEqual(style(of: "count", in: spans), .key)
        XCTAssertEqual(style(of: "12", in: spans), .number)
        XCTAssertEqual(style(of: #""idle""#, in: spans), .string)
        XCTAssertEqual(style(of: "-3", in: spans), .number)
        XCTAssertEqual(style(of: "|", in: spans), .punctuation, "no preview tail outside Bluetooth")
        XCTAssertNil(style(of: "4F2A", in: styled("device 4F2A ok", .plain)), "an identifier with digits is not a number")
    }

    func testSpansStayInsideTheScannedPrefixAndDoNotOverlap() {
        let message = String(repeating: "key=\"value\" 0x12 WORD · ", count: 400)
        let spans = LogMessageHighlighter.spans(message, kind: .bluetoothApp, highlights: ["WORD": .red])
        var end = 0
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, end, "overlap at \(span.range)")
            end = NSMaxRange(span.range)
        }
        XCTAssertLessThanOrEqual(end, LogMessageHighlighter.Limits.scannedUnits)
        XCTAssertTrue(LogMessageHighlighter.spans("", kind: .bluetoothApp).isEmpty)
        XCTAssertTrue(LogMessageHighlighter.spans("RX", kind: .bluetoothApp).count == 1)
    }

    /// The per-cell cost: a reload styles the viewport's rows, so one full-length row must be
    /// far below a frame.
    func testOneViewportOfLongRowsIsCheap() {
        let row = "RX Pulse 4F2A → iPhone · Messages notify · STATUS #413 {name=\"strap\" readings=[21.5, -3.4, 18.75]} · 256 bytes | "
            + String(repeating: "ab ", count: 256)
        let started = Date()
        for _ in 0..<60 { _ = LogMessageHighlighter.spans(row, kind: .bluetoothApp) }
        let elapsed = Date().timeIntervalSince(started)
        print("LogMessageHighlighter: 60 rows in \(elapsed * 1_000) ms")
        // Debug build, possibly under load: this catches a quadratic scan, not a few milliseconds.
        XCTAssertLessThan(elapsed, 0.25)
    }

    func testHighlightMapCompilesAndRejectsUnknownColours() throws {
        let definitions = try BluetoothPacketDefinitions.compile(BluetoothDefinitionsGuide.example)
        XCTAssertEqual(definitions.highlights["LOCATION"], .green)
        XCTAssertThrowsError(try BluetoothPacketDefinitions.compile("highlight: { LOCATION: crimson }")) { error in
            let failure = error as? BluetoothDefinitionError
            XCTAssertEqual(failure?.line, 1)
            XCTAssertTrue(failure?.message.contains("unknown colour 'crimson' — use red, orange") == true, "\(String(describing: failure))")
        }
    }
}
