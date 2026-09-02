//
//  LazyLogDocumentTests.swift
//  TimberLineParserTests
//
//  Tests for LazyLogDocument parsing

import XCTest
@testable import TimberLineParser

final class LazyLogDocumentTests: XCTestCase {

    // MARK: - Helper

    /// Parse data using LazyLogDocument and return the results synchronously
    private func parseData(_ data: Data, multilineOptions: MultilineMergeOptions = .default) -> ([LogLine], LogStatistics) {
        // Write data to a temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try! data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let doc = LazyLogDocument(url: tempURL, multilineOptions: multilineOptions)

        let expectation = XCTestExpectation(description: "Parsing complete")
        var result: ([LogLine], LogStatistics)?

        doc.onParsingComplete = {
            result = doc.getLogLinesAndStatistics()
            expectation.fulfill()
        }

        doc.startFullBackgroundLoad()

        wait(for: [expectation], timeout: 30.0)
        return result ?? ([], LogStatistics())
    }

    // MARK: - Basic Parsing Tests

    func testParseEmptyData() {
        let data = Data()
        let (lines, _) = parseData(data)
        XCTAssertEqual(lines.count, 0)
    }

    func testParseSingleLine() {
        let data = "2024-01-15 10:30:45 INFO Hello World".data(using: .utf8)!
        let (lines, _) = parseData(data)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].id, 0)
        XCTAssertEqual(lines[0].content, "2024-01-15 10:30:45 INFO Hello World")
        XCTAssertEqual(lines[0].level, .info)
        XCTAssertNotNil(lines[0].timestamp)
    }

    func testParseMultipleLines() {
        let logContent = """
        2024-01-15 10:30:45 INFO Starting server
        2024-01-15 10:30:46 DEBUG Loading config
        2024-01-15 10:30:47 ERROR Connection failed
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].level, .info)
        XCTAssertEqual(lines[1].level, .debug)
        XCTAssertEqual(lines[2].level, .error)
    }

    // MARK: - Timestamp Inheritance Tests

    func testTimestampInheritance() {
        // Use parser with merging disabled to test timestamp inheritance specifically
        let logContent = """
        2024-01-15 10:30:45 ERROR Exception occurred:
        java.lang.NullPointerException
            at com.example.Main.process(Main.java:42)
            at com.example.Main.main(Main.java:10)
        2024-01-15 10:30:46 INFO Recovery successful
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data, multilineOptions: .disabled)

        XCTAssertEqual(lines.count, 5)

        // First line has its own timestamp
        XCTAssertNotNil(lines[0].timestamp)

        // Stack trace lines inherit timestamp
        XCTAssertNotNil(lines[1].timestamp)
        XCTAssertNotNil(lines[2].timestamp)
        XCTAssertNotNil(lines[3].timestamp)
        XCTAssertEqual(lines[1].timestamp, lines[0].timestamp)
        XCTAssertEqual(lines[2].timestamp, lines[0].timestamp)
        XCTAssertEqual(lines[3].timestamp, lines[0].timestamp)

        // Last line has new timestamp
        XCTAssertNotNil(lines[4].timestamp)
        XCTAssertNotEqual(lines[4].timestamp, lines[0].timestamp)
    }

    // MARK: - Byte Offset Tests

    func testByteOffsets() {
        let logContent = "Line1\nLine2\nLine3\n"
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data, multilineOptions: .disabled)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].byteOffset, 0)
        XCTAssertEqual(lines[1].byteOffset, 6)  // "Line1\n" = 6 bytes
        XCTAssertEqual(lines[2].byteOffset, 12) // "Line1\nLine2\n" = 12 bytes
    }

    // MARK: - Windows Line Endings Tests

    func testWindowsLineEndings() {
        let logContent = "Line1\r\nLine2\r\nLine3"
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data, multilineOptions: .disabled)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].content, "Line1")
        XCTAssertEqual(lines[1].content, "Line2")
        XCTAssertEqual(lines[2].content, "Line3")
    }

    // MARK: - No Trailing Newline Tests

    func testNoTrailingNewline() {
        let logContent = "Line1\nLine2"
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data, multilineOptions: .disabled)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].content, "Line1")
        XCTAssertEqual(lines[1].content, "Line2")
    }

    // MARK: - Statistics Tests

    func testParseWithStats() {
        let logContent = """
        2024-01-15 10:30:45 INFO Starting
        2024-01-15 10:30:46 INFO Running
        2024-01-15 10:30:47 WARN Check this
        2024-01-15 10:30:48 ERROR Failed
        2024-01-15 10:30:49 DEBUG Details
        """
        let data = logContent.data(using: .utf8)!
        let (lines, statistics) = parseData(data)

        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(statistics.totalLines, 5)
        XCTAssertEqual(statistics.countsByLevel[.info], 2)
        XCTAssertEqual(statistics.countsByLevel[.warning], 1)
        XCTAssertEqual(statistics.countsByLevel[.error], 1)
        XCTAssertEqual(statistics.countsByLevel[.debug], 1)
        XCTAssertNotNil(statistics.firstTimestamp)
        XCTAssertNotNil(statistics.lastTimestamp)
    }

    // MARK: - Format Detection Tests

    func testFormatDetectionLocking() {
        // All lines have the same format, parser should lock onto it
        var lineStrings: [String] = []
        for i in 0..<100 {
            lineStrings.append("2024-01-15 10:30:\(String(format: "%02d", i % 60)) INFO Message \(i)")
        }
        let data = lineStrings.joined(separator: "\n").data(using: .utf8)!

        let (lines, _) = parseData(data)

        XCTAssertEqual(lines.count, 100)
        // All lines should have timestamps
        for line in lines {
            XCTAssertNotNil(line.timestamp, "Line \(line.id) missing timestamp")
        }
    }

    // MARK: - Multiline Merging Tests

    func testMultilineMergeEnabledByDefault() {
        // Default parser should merge continuation lines
        let logContent = """
        2024-01-15 10:30:45 ERROR Exception occurred:
            at com.example.Main.process(Main.java:42)
            at com.example.Main.main(Main.java:10)
        2024-01-15 10:30:46 INFO Recovery successful
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        // Should be 2 merged entries (default behavior)
        XCTAssertEqual(lines.count, 2)
    }

    func testMultilineMergeCanBeDisabled() {
        // Parser with merging disabled should NOT merge lines
        let logContent = """
        2024-01-15 10:30:45 ERROR Exception occurred:
            at com.example.Main.process(Main.java:42)
            at com.example.Main.main(Main.java:10)
        2024-01-15 10:30:46 INFO Recovery successful
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data, multilineOptions: .disabled)

        // Should be 4 separate lines (no merging)
        XCTAssertEqual(lines.count, 4)
    }

    func testMultilineMergeBasic() {
        let logContent = """
        2024-01-15 10:30:45 ERROR Exception occurred:
            at com.example.Main.process(Main.java:42)
            at com.example.Main.main(Main.java:10)
        2024-01-15 10:30:46 INFO Recovery successful
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        // Should be 2 merged entries
        XCTAssertEqual(lines.count, 2)

        // First entry should contain all stack trace lines
        XCTAssertTrue(lines[0].content.contains("Exception occurred:"))
        XCTAssertTrue(lines[0].content.contains("at com.example.Main.process"))
        XCTAssertTrue(lines[0].content.contains("at com.example.Main.main"))
        XCTAssertEqual(lines[0].level, .error)

        // Second entry should be the recovery message
        XCTAssertTrue(lines[1].content.contains("Recovery successful"))
        XCTAssertEqual(lines[1].level, .info)
    }

    func testMultilineMergeNumberedList() {
        // This tests the user's specific format with numbered list continuations
        let logContent = """
        2024-12-12 08:44:26.844000 [LogLevel.VERBOSE] [Verbose] [watchLib.CommandCenter:0]  >0: map_cmd
        1: map_settings
        2: map_fitness_metrics
        3: map_error
        2024-12-12 08:44:26.845000 [LogLevel.VERBOSE] [Verbose] [KronabyDevice.swift:818] Got command map
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        // Should be 2 merged entries
        XCTAssertEqual(lines.count, 2)

        // First entry should contain all the numbered items
        XCTAssertTrue(lines[0].content.contains("0: map_cmd"))
        XCTAssertTrue(lines[0].content.contains("1: map_settings"))
        XCTAssertTrue(lines[0].content.contains("2: map_fitness_metrics"))
        XCTAssertTrue(lines[0].content.contains("3: map_error"))

        // Second entry should be the next log line
        XCTAssertTrue(lines[1].content.contains("Got command map"))
    }

    func testMultilineMergePreservesNewlines() {
        let logContent = """
        2024-01-15 10:30:45 ERROR Stack trace:
            Line 1
            Line 2
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        XCTAssertEqual(lines.count, 1)
        // Content should preserve newlines between merged lines
        let newlineCount = lines[0].content.filter { $0 == "\n" }.count
        XCTAssertEqual(newlineCount, 2, "Should have 2 newlines separating the 3 merged lines")
    }

    func testMultilineMergeMaxContinuationLimit() {
        // Test that max continuation limit is respected
        let logContent = """
        2024-01-15 10:30:45 ERROR Error with many lines:
            Continuation 1
            Continuation 2
            Continuation 3
            Continuation 4
        2024-01-15 10:30:46 INFO Next entry
        """
        let data = logContent.data(using: .utf8)!
        let limitedOptions = MultilineMergeOptions(enabled: true, maxContinuationLines: 2)
        let (lines, _) = parseData(data, multilineOptions: limitedOptions)

        // First entry has content + 2 continuations
        XCTAssertTrue(lines[0].content.contains("Continuation 1"))
        XCTAssertTrue(lines[0].content.contains("Continuation 2"))

        // Continuations 3 and 4 should be separate (exceeded limit)
        // They become new entries without timestamps
    }

    func testMultilineMergeEmptyLines() {
        // Empty lines should NOT be treated as continuation (they don't start with whitespace)
        let logContent = """
        2024-01-15 10:30:45 INFO First message

        2024-01-15 10:30:46 INFO Second message
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        // Empty line has no timestamp but also doesn't start with whitespace,
        // so it becomes a separate entry
        XCTAssertEqual(lines.count, 3)
    }

    func testMultilineMergeNoTimestampAtStart() {
        // Lines without any timestamp context should still work
        let logContent = """
        Just some text
            Indented continuation
        More text
        """
        let data = logContent.data(using: .utf8)!
        let (lines, _) = parseData(data)

        // First line + continuation merged, then separate "More text"
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].content.contains("Just some text"))
        XCTAssertTrue(lines[0].content.contains("Indented continuation"))
    }
}
