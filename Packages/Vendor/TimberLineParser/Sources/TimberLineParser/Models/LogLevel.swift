//
//  LogLevel.swift
//  TimberLineParser
//
//  Log severity level detected from line content.
//

import Foundation

/// Log severity level detected from line content
public enum LogLevel: String, CaseIterable, Sendable, Codable {
    case error
    case warning
    case info
    case debug
    case verbose
    case trace
    case unknown
}
