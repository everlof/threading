//
//  ParserPerformanceTests.swift
//  TimberLineParserTests
//
//  Performance tests for LazyLogDocument parsing

import XCTest
@testable import TimberLineParser

final class ParserPerformanceTests: XCTestCase {

    // MARK: - Helper

    /// Parse a file using LazyLogDocument and wait for completion
    private func parseBenchmarkFile(name: String, timeout: TimeInterval = 30.0) throws -> ([LogLine], LogStatistics) {
        guard let url = Bundle.module.url(forResource: name, withExtension: "log", subdirectory: "Resources") else {
            throw XCTSkip("Benchmark file not found: \(name)")
        }

        let doc = LazyLogDocument(url: url)

        let expectation = XCTestExpectation(description: "Parsing complete")
        var result: ([LogLine], LogStatistics)?

        doc.onParsingComplete = {
            result = doc.getLogLinesAndStatistics()
            expectation.fulfill()
        }

        doc.startFullBackgroundLoad()

        wait(for: [expectation], timeout: timeout)
        return result ?? ([], LogStatistics())
    }

    // MARK: - Benchmark File Tests

    func testParseSmallBenchmarkFile() throws {
        measure {
            _ = try? parseBenchmarkFile(name: "benchmark-100kb")
        }
    }

    func testParseMediumBenchmarkFile() throws {
        measure {
            _ = try? parseBenchmarkFile(name: "benchmark-1mb")
        }
    }

    func testParseLargeBenchmarkFile() throws {
        measure {
            _ = try? parseBenchmarkFile(name: "benchmark-5mb", timeout: 60.0)
        }
    }

    // MARK: - Component Benchmarks

    func testSIMDLineScannerPerformance() throws {
        guard let url = Bundle.module.url(forResource: "benchmark-5mb", withExtension: "log", subdirectory: "Resources") else {
            throw XCTSkip("Benchmark file not found")
        }

        let data = try Data(contentsOf: url)

        measure {
            _ = SIMDLineScanner.findNewlines(in: data)
        }
    }

    func testTimestampParserPerformance() {
        // Test with various timestamp formats
        let lines = [
            "2024-01-15T10:30:45.123Z INFO Test message with ISO8601 timestamp",
            "2024-01-15 10:30:45.123 INFO Test message with simple timestamp",
            "[2024-01-15 10:30:45] INFO Test message with bracketed timestamp",
            "Nov 21 10:30:45 hostname INFO Test message with syslog timestamp",
        ]

        let bytesArrays = lines.map { Array($0.utf8) }

        measure {
            for _ in 0..<10000 {
                for bytes in bytesArrays {
                    _ = TimestampParser.tryAllTimestampFormats(bytes: bytes)
                }
            }
        }
    }

    func testLevelDetectorPerformance() {
        let lines = [
            "[ERROR] Something failed badly",
            "[WARN] Warning message here",
            "[INFO] Information message",
            "[DEBUG] Debug output",
            "Plain message without level",
        ]

        let bytesArrays = lines.map { Array($0.utf8) }

        measure {
            for _ in 0..<100000 {
                for bytes in bytesArrays {
                    _ = LevelDetector.detectLevel(bytes: bytes)
                }
            }
        }
    }

    // MARK: - Synthetic Data Tests

    func testParseSyntheticData10KLines() throws {
        let data = generateSyntheticLogData(lineCount: 10_000)

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-10k.log")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        measure {
            let doc = LazyLogDocument(url: tempURL)
            let expectation = XCTestExpectation(description: "Parsing complete")
            doc.onParsingComplete = { expectation.fulfill() }
            doc.startFullBackgroundLoad()
            wait(for: [expectation], timeout: 30.0)
        }
    }

    func testParseSyntheticData100KLines() throws {
        let data = generateSyntheticLogData(lineCount: 100_000)

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-100k.log")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        measure {
            let doc = LazyLogDocument(url: tempURL)
            let expectation = XCTestExpectation(description: "Parsing complete")
            doc.onParsingComplete = { expectation.fulfill() }
            doc.startFullBackgroundLoad()
            wait(for: [expectation], timeout: 60.0)
        }
    }

    // MARK: - Helpers

    private func generateSyntheticLogData(lineCount: Int) -> Data {
        let levels = ["INFO", "DEBUG", "WARN", "ERROR"]
        var lines: [String] = []
        lines.reserveCapacity(lineCount)

        for i in 0..<lineCount {
            let second = i % 60
            let minute = (i / 60) % 60
            let hour = (i / 3600) % 24
            let level = levels[i % levels.count]
            let line = String(format: "2024-01-15 %02d:%02d:%02d.%03d %@ Processing request #%d with some additional context data",
                            hour, minute, second, i % 1000, level, i)
            lines.append(line)
        }

        return lines.joined(separator: "\n").data(using: .utf8)!
    }
}
