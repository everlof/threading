//
//  ParserProgress.swift
//  TimberLineParser
//
//  Progress information during parsing.
//

import Foundation

/// Progress information during parsing
public struct ParserProgress: Sendable {
    /// Number of bytes processed so far
    public let bytesProcessed: UInt64
    
    /// Total bytes to process
    public let totalBytes: UInt64
    
    /// Number of lines processed so far
    public let linesProcessed: Int
    
    /// Percentage complete (0-100)
    public var percentComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesProcessed) / Double(totalBytes) * 100
    }
    
    /// Public initializer
    /// - Parameters:
    ///   - bytesProcessed: Number of bytes processed so far
    ///   - totalBytes: Total bytes to process
    ///   - linesProcessed: Number of lines processed so far
    public init(bytesProcessed: UInt64, totalBytes: UInt64, linesProcessed: Int) {
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
        self.linesProcessed = linesProcessed
    }
}
