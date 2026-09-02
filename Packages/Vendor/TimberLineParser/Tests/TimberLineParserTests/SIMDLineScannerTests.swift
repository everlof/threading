//
//  SIMDLineScannerTests.swift
//  TimberLineParserTests
//

import XCTest
@testable import TimberLineParser

final class SIMDLineScannerTests: XCTestCase {
    
    // MARK: - Basic Tests
    
    func testEmptyData() {
        let data = Data()
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [])
    }
    
    func testNoNewlines() {
        let data = "Hello World".data(using: .utf8)!
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [])
    }
    
    func testSingleNewline() {
        let data = "Hello\nWorld".data(using: .utf8)!
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [5])
    }
    
    func testMultipleNewlines() {
        let data = "Line1\nLine2\nLine3\n".data(using: .utf8)!
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [5, 11, 17])
    }
    
    func testConsecutiveNewlines() {
        let data = "A\n\n\nB".data(using: .utf8)!
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [1, 2, 3])
    }
    
    // MARK: - Large Data Tests
    
    func testLargeData() {
        let line = "This is a test log line with some content\n"
        let data = String(repeating: line, count: 1000).data(using: .utf8)!
        
        let positions = SIMDLineScanner.findNewlines(in: data)
        
        XCTAssertEqual(positions.count, 1000)
        // Check first few positions
        XCTAssertEqual(positions[0], 41)
        XCTAssertEqual(positions[1], 83)
        XCTAssertEqual(positions[2], 125)
    }
    
    // MARK: - Data Near SIMD Boundary Tests
    
    func testDataExactly32Bytes() {
        // 31 chars + 1 newline = 32 bytes
        let data = "0123456789012345678901234567890\n".data(using: .utf8)!
        XCTAssertEqual(data.count, 32)
        
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [31])
    }
    
    func testDataLessThan32Bytes() {
        let data = "Short\nline\n".data(using: .utf8)!
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [5, 10])
    }
    
    func testDataMultipleOf32() {
        // Create data that's exactly 64 bytes with newlines
        let data = "0123456789012345678901234567890\n0123456789012345678901234567890\n".data(using: .utf8)!
        XCTAssertEqual(data.count, 64)
        
        let positions = SIMDLineScanner.findNewlines(in: data)
        XCTAssertEqual(positions, [31, 63])
    }
    
    // MARK: - Ranges Conversion Tests
    
    func testNewlinesToRangesEmpty() {
        let ranges = SIMDLineScanner.newlinesToRanges([], totalLength: 0)
        XCTAssertEqual(ranges.count, 0)
    }
    
    func testNewlinesToRangesNoNewlines() {
        let ranges = SIMDLineScanner.newlinesToRanges([], totalLength: 10)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 10)
    }
    
    func testNewlinesToRangesSingleLine() {
        let ranges = SIMDLineScanner.newlinesToRanges([5], totalLength: 6)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 5)
    }
    
    func testNewlinesToRangesMultipleLines() {
        // "Line1\nLine2\nLine3\n" -> positions [5, 11, 17], totalLength 18
        let ranges = SIMDLineScanner.newlinesToRanges([5, 11, 17], totalLength: 18)
        
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 5)
        XCTAssertEqual(ranges[1].start, 6)
        XCTAssertEqual(ranges[1].end, 11)
        XCTAssertEqual(ranges[2].start, 12)
        XCTAssertEqual(ranges[2].end, 17)
    }
    
    func testNewlinesToRangesNoTrailingNewline() {
        // "Line1\nLine2" -> positions [5], totalLength 11
        let ranges = SIMDLineScanner.newlinesToRanges([5], totalLength: 11)
        
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 5)
        XCTAssertEqual(ranges[1].start, 6)
        XCTAssertEqual(ranges[1].end, 11)
    }
    
    // MARK: - Integration Test
    
    func testFindAndConvert() {
        let data = "2024-01-15 INFO Hello\n2024-01-15 WARN World\n".data(using: .utf8)!
        
        let positions = SIMDLineScanner.findNewlines(in: data)
        let ranges = SIMDLineScanner.newlinesToRanges(positions, totalLength: data.count)
        
        XCTAssertEqual(ranges.count, 2)
        
        // Extract and verify lines
        let line1 = String(decoding: data[ranges[0].start..<ranges[0].end], as: UTF8.self)
        let line2 = String(decoding: data[ranges[1].start..<ranges[1].end], as: UTF8.self)
        
        XCTAssertEqual(line1, "2024-01-15 INFO Hello")
        XCTAssertEqual(line2, "2024-01-15 WARN World")
    }
}
