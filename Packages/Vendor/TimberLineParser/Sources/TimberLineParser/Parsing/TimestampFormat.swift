//
//  TimestampFormat.swift
//  TimberLineParser
//
//  Detected timestamp format for optimized parsing.
//

import Foundation

/// Detected timestamp format for optimized parsing
public enum TimestampFormat: UInt8, Sendable {
    case unknown = 0
    case iso8601 = 1         // 2024-01-15T10:30:45Z or 2024-01-15T10:30:45.123+02:00
    case simple = 2          // 2024-01-15 10:30:45.123
    case bracketed = 3       // [2024-01-15 10:30:45]
    case apacheCLF = 4       // 21/Nov/2024:10:30:45 +0000
    case androidLogcat = 5   // 01-15 10:30:45.123
    case usDatetime = 6      // 01/15/2024 10:30:45
    case syslog = 7          // Nov 21 10:30:45
}
