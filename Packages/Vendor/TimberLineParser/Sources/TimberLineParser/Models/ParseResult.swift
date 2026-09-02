//
//  ParseResult.swift
//  TimberLineParser
//
//  Output container for parsed log data.
//

import Foundation

/// Statistics about parsed log data
public struct LogStatistics: Equatable, Sendable {
    /// Total number of lines parsed
    public var totalLines: Int

    /// Number of lines after filtering (same as totalLines if no filter applied)
    public var filteredLines: Int

    /// Count of lines by log level
    public var countsByLevel: [LogLevel: Int]

    /// Timestamp of the earliest log entry
    public var firstTimestamp: Date?

    /// Timestamp of the latest log entry
    public var lastTimestamp: Date?

    /// Default initializer with zero values
    public init() {
        self.totalLines = 0
        self.filteredLines = 0
        self.countsByLevel = [:]
        self.firstTimestamp = nil
        self.lastTimestamp = nil
    }

    /// Full initializer
    /// - Parameters:
    ///   - totalLines: Total number of lines parsed
    ///   - filteredLines: Number of lines after filtering
    ///   - countsByLevel: Count of lines by log level
    ///   - firstTimestamp: Timestamp of the earliest log entry
    ///   - lastTimestamp: Timestamp of the latest log entry
    public init(
        totalLines: Int,
        filteredLines: Int = 0,
        countsByLevel: [LogLevel: Int],
        firstTimestamp: Date?,
        lastTimestamp: Date?
    ) {
        self.totalLines = totalLines
        self.filteredLines = filteredLines == 0 ? totalLines : filteredLines
        self.countsByLevel = countsByLevel
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
    }

    /// Get count for a specific log level
    public func count(for level: LogLevel) -> Int {
        countsByLevel[level] ?? 0
    }
}

/// Result of a complete parse operation
public struct ParseResult: Sendable {
    /// All parsed log lines
    public let lines: [LogLine]
    
    /// Statistics about the parsed data
    public let statistics: LogStatistics
    
    /// Public initializer
    /// - Parameters:
    ///   - lines: All parsed log lines
    ///   - statistics: Statistics about the parsed data
    public init(lines: [LogLine], statistics: LogStatistics) {
        self.lines = lines
        self.statistics = statistics
    }
}
