//
//  LogLevel.swift
//  TimberLineParser
//
//  Log severity level detected from line content.
//

import Foundation

/// Log severity level detected from line content
public enum LogLevel: String, CaseIterable, Sendable, Codable {

    // Apple's unified log and the syslog severities it is relayed through. Added because the
    // vocabulary was a strict subset before: `Notice`, `Fault`, `Critical`, `Alert` and
    // `Emergency` all arrived as `unknown`, so a fault read as no level at all — and a level
    // filter that cannot see a fault is worse than no filter.
    case emergency
    case alert
    case critical
    case fault
    case error
    case warning
    case notice
    case info
    case debug
    case verbose
    case trace
    case unknown

    /// Ordering, most severe first. Two vocabularies meet here — `log` says Default and Fault,
    /// the relay says Notice and Emergency — so a comparison has one answer rather than one per
    /// caller.
    public var severity: Int {
        switch self {
        case .emergency, .alert: return 6
        case .critical, .fault: return 5
        case .error: return 4
        case .warning: return 3
        case .notice, .info: return 2
        case .debug: return 1
        case .verbose, .trace: return 0
        case .unknown: return -1
        }
    }
}
