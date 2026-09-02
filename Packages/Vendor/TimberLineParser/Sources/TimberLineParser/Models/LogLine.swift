//
//  LogLine.swift
//  TimberLineParser
//
//  Core log line model with pre-parsed metadata for efficient filtering.
//

import Foundation

/// Represents a single line in a log file with pre-parsed metadata for efficient filtering
public struct LogLine: Identifiable, Sendable {
    /// Line index (0-based)
    public let id: Int
    
    /// The text content of the log line
    public let content: String
    
    /// Detected log level (error, warning, info, etc.)
    public let level: LogLevel
    
    /// Parsed timestamp, if present in the line
    public let timestamp: Date?
    
    /// Byte offset in the original file (for potential memory-mapped access later)
    public let byteOffset: UInt64
    
    /// Public initializer for creating LogLine instances
    /// - Parameters:
    ///   - id: Line index (0-based)
    ///   - content: The text content of the log line
    ///   - byteOffset: Byte offset in the original file
    ///   - level: Detected log level
    ///   - timestamp: Parsed timestamp, if present
    public init(id: Int, content: String, byteOffset: UInt64, level: LogLevel, timestamp: Date?) {
        self.id = id
        self.content = content
        self.byteOffset = byteOffset
        self.level = level
        self.timestamp = timestamp
    }
}
