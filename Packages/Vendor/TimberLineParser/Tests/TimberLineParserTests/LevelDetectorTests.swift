//
//  LevelDetectorTests.swift
//  TimberLineParserTests
//

import XCTest
@testable import TimberLineParser

final class LevelDetectorTests: XCTestCase {
    
    // MARK: - Error Level Tests
    
    func testErrorLevel() {
        let testCases = [
            "[ERROR] Something failed",
            "ERROR: Connection lost",
            "ERROR Something went wrong",
            "[FATAL] System crash",
            "FATAL: Out of memory",
        ]

        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .error, "Expected .error for: \(line)")
        }
    }
    
    // MARK: - Warning Level Tests
    
    func testWarningLevel() {
        let testCases = [
            "[WARN] Deprecated API",
            "WARN: Low memory",
            "WARNING: Resource running low",
            "[WARNING] Check config",
        ]
        
        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .warning, "Expected .warning for: \(line)")
        }
    }
    
    // MARK: - Info Level Tests
    
    func testInfoLevel() {
        let testCases = [
            "[INFO] Server started",
            "INFO: Connected to database",
            "INFO Starting application",
        ]

        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .info, "Expected .info for: \(line)")
        }
    }
    
    // MARK: - Debug Level Tests
    
    func testDebugLevel() {
        let testCases = [
            "[DEBUG] Variable x = 5",
            "DEBUG: Entering function",
            "DEBUG Processing item",
        ]

        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .debug, "Expected .debug for: \(line)")
        }
    }
    
    // MARK: - Verbose Level Tests
    
    func testVerboseLevel() {
        let testCases = [
            "[VERBOSE] Detailed info",
            "VERBOSE: Full trace",
        ]
        
        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .verbose, "Expected .verbose for: \(line)")
        }
    }
    
    // MARK: - Trace Level Tests
    
    func testTraceLevel() {
        let testCases = [
            "[TRACE] Method entry",
            "TRACE: Stack frame",
        ]
        
        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .trace, "Expected .trace for: \(line)")
        }
    }
    
    // MARK: - Unknown Level Tests
    
    func testUnknownLevel() {
        let testCases = [
            "Just a plain message",
            "2024-01-15 Started server",
            "Connection established",
        ]
        
        for line in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, .unknown, "Expected .unknown for: \(line)")
        }
    }
    
    // MARK: - Case Insensitivity Tests
    
    func testCaseInsensitivity() {
        let testCases: [(String, LogLevel)] = [
            ("error: test", .error),
            ("Error: test", .error),
            ("ERROR: test", .error),
            ("warn: test", .warning),
            ("Warn: test", .warning),
            ("WARN: test", .warning),
            ("info: test", .info),
            ("Info: test", .info),
            ("INFO: test", .info),
            ("debug: test", .debug),
            ("Debug: test", .debug),
            ("DEBUG: test", .debug),
        ]
        
        for (line, expectedLevel) in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, expectedLevel, "Expected \(expectedLevel) for: \(line)")
        }
    }
    
    // MARK: - Level in Middle of Line Tests
    
    func testLevelInMiddle() {
        let testCases: [(String, LogLevel)] = [
            ("2024-01-15 10:30:45 [ERROR] Failed", .error),
            ("2024-01-15 10:30:45 | WARN | Check this", .warning),
            ("timestamp INFO: Starting", .info),
        ]
        
        for (line, expectedLevel) in testCases {
            let bytes = Array(line.utf8)
            let level = LevelDetector.detectLevel(bytes: bytes)
            XCTAssertEqual(level, expectedLevel, "Expected \(expectedLevel) for: \(line)")
        }
    }
    
    // MARK: - Empty/Short Line Tests
    
    func testEmptyLine() {
        let bytes: [UInt8] = []
        let level = LevelDetector.detectLevel(bytes: bytes)
        XCTAssertEqual(level, .unknown)
    }
    
    func testShortLine() {
        let line = "abc"
        let bytes = Array(line.utf8)
        let level = LevelDetector.detectLevel(bytes: bytes)
        XCTAssertEqual(level, .unknown)
    }
}
