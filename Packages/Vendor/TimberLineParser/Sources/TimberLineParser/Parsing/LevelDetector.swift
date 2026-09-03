//
//  LevelDetector.swift
//  TimberLineParser
//
//  High-performance log level detection using byte pattern matching.
//  Optimized for minimal bounds checking and early termination.
//
//  Performance notes (benchmarked Dec 2025):
//  - UnsafeBufferPointer eliminates array bounds checking overhead
//  - First-char switch provides fast rejection without full keyword scan
//  - Delimiter-based scanning finds levels quickly (~25 bytes typical)
//
//  Approaches that did NOT help:
//  - UInt32 word comparison: Added complexity, marginal gain, lost flexibility
//  - Position hints (stateful): 2x slower - hint overhead exceeds scan savings
//    because the base algorithm already finds levels quickly
//  - SIMD: Bad fit - variable keyword lengths, early termination, small scan window
//

import Foundation

/// High-performance log level detector using byte pattern matching
public enum LevelDetector {

    // MARK: - Byte constants for delimiters
    private static let OPEN_BRACKET: UInt8 = 0x5B   // [
    private static let OPEN_ANGLE: UInt8 = 0x3C    // <
    private static let SPACE: UInt8 = 0x20         // space
    private static let COLON: UInt8 = 0x3A         // :
    private static let PIPE: UInt8 = 0x7C          // |

    // MARK: - Public API

    /// Detect log level from raw bytes using unsafe buffer pointer for speed
    /// - Parameter bytes: The raw bytes of the log line
    /// - Returns: Detected log level
    public static func detectLevel(bytes: [UInt8]) -> LogLevel {
        guard !bytes.isEmpty else { return .unknown }

        return bytes.withUnsafeBufferPointer { buffer in
            detectLevelUnsafe(buffer: buffer)
        }
    }

    /// Detect log level directly from an UnsafeBufferPointer (zero-copy from Data)
    /// - Parameter buffer: Unsafe buffer pointer to the bytes
    /// - Returns: Detected log level
    public static func detectLevel(buffer: UnsafeBufferPointer<UInt8>) -> LogLevel {
        guard !buffer.isEmpty else { return .unknown }
        return detectLevelUnsafe(buffer: buffer)
    }

    // MARK: - Core Implementation

    @inline(__always)
    private static func detectLevelUnsafe(buffer: UnsafeBufferPointer<UInt8>) -> LogLevel {
        let ptr = buffer.baseAddress!
        let count = buffer.count
        let scanLimit = min(count, 80)  // Most log formats have level in first 80 chars

        // Quick check at start (skip leading spaces)
        var start = 0
        while start < min(count, 12) && ptr[start] == SPACE { start += 1 }

        // Check if level is right at the start (common: "ERROR: ...", "[INFO] ...")
        if start < scanLimit {
            if let level = checkKeywordAt(ptr: ptr, pos: start, limit: count) {
                return level
            }
            // Check after opening bracket at start
            if ptr[start] == OPEN_BRACKET && start + 1 < scanLimit {
                if let level = checkKeywordAt(ptr: ptr, pos: start + 1, limit: count) {
                    return level
                }
            }
        }

        // Single pass: find delimiters and check keyword after each
        var i = start
        while i < scanLimit {
            let b = ptr[i]

            // Check if this is a delimiter that often precedes log level
            if b == OPEN_BRACKET || b == SPACE || b == COLON || b == PIPE || b == OPEN_ANGLE {
                let nextPos = i + 1
                if nextPos < scanLimit {
                    // Skip any spaces after delimiter
                    var checkPos = nextPos
                    while checkPos < scanLimit && ptr[checkPos] == SPACE { checkPos += 1 }

                    if let level = checkKeywordAt(ptr: ptr, pos: checkPos, limit: count) {
                        return level
                    }
                }
            }
            i += 1
        }

        return .unknown
    }

    /// Check for any log level keyword at the given position
    /// Returns immediately on first match for early termination
    @inline(__always)
    private static func checkKeywordAt(ptr: UnsafePointer<UInt8>, pos: Int, limit: Int) -> LogLevel? {
        let remaining = limit - pos
        guard remaining >= 4 else { return nil }  // Minimum keyword length is 4 (INFO, WARN)

        // Get first char (lowercased via OR 0x20)
        let c0 = ptr[pos] | 0x20

        // Branch on first character for fast rejection
        switch c0 {
        case 0x65: // 'e' - error, or the syslog severity emergency
            if remaining >= 5 && matchesError(ptr: ptr, at: pos) { return .error }
            if remaining >= 9 && matchesEmergency(ptr: ptr, at: pos) { return .emergency }
        case 0x66: // 'f' - fatal (maps to error), or Apple's fault
            if remaining >= 5 && matchesFatal(ptr: ptr, at: pos) { return .error }
            if remaining >= 5 && matchesFault(ptr: ptr, at: pos) { return .fault }
        case 0x6E: // 'n' - notice
            if remaining >= 6 && matchesNotice(ptr: ptr, at: pos) { return .notice }
        case 0x63: // 'c' - critical
            if remaining >= 8 && matchesCritical(ptr: ptr, at: pos) { return .critical }
        case 0x61: // 'a' - alert
            if remaining >= 5 && matchesAlert(ptr: ptr, at: pos) { return .alert }
        case 0x77: // 'w' - warn/warning
            if remaining >= 4 && matchesWarn(ptr: ptr, at: pos) { return .warning }
        case 0x69: // 'i' - info
            if remaining >= 4 && matchesInfo(ptr: ptr, at: pos) { return .info }
        case 0x64: // 'd' - debug
            if remaining >= 5 && matchesDebug(ptr: ptr, at: pos) { return .debug }
        case 0x76: // 'v' - verbose
            if remaining >= 7 && matchesVerbose(ptr: ptr, at: pos) { return .verbose }
        case 0x74: // 't' - trace
            if remaining >= 5 && matchesTrace(ptr: ptr, at: pos) { return .trace }
        default:
            break
        }

        return nil
    }

    // MARK: - Keyword Matchers (all use raw pointer arithmetic, no bounds checks)

    @inline(__always)
    private static func matchesError(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "error" = 0x65 0x72 0x72 0x6F 0x72
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        let b4 = ptr[i+4] | 0x20
        return b1 == 0x72 && b2 == 0x72 && b3 == 0x6F && b4 == 0x72
    }

    @inline(__always)
    private static func matchesFault(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "fault" = 0x66 0x61 0x75 0x6C 0x74
        return (ptr[i+1] | 0x20) == 0x61 && (ptr[i+2] | 0x20) == 0x75
            && (ptr[i+3] | 0x20) == 0x6C && (ptr[i+4] | 0x20) == 0x74
    }

    private static func matchesNotice(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "notice"
        return (ptr[i+1] | 0x20) == 0x6F && (ptr[i+2] | 0x20) == 0x74
            && (ptr[i+3] | 0x20) == 0x69 && (ptr[i+4] | 0x20) == 0x63 && (ptr[i+5] | 0x20) == 0x65
    }

    private static func matchesCritical(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "critical"
        return (ptr[i+1] | 0x20) == 0x72 && (ptr[i+2] | 0x20) == 0x69
            && (ptr[i+3] | 0x20) == 0x74 && (ptr[i+4] | 0x20) == 0x69
            && (ptr[i+5] | 0x20) == 0x63 && (ptr[i+6] | 0x20) == 0x61 && (ptr[i+7] | 0x20) == 0x6C
    }

    private static func matchesAlert(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "alert"
        return (ptr[i+1] | 0x20) == 0x6C && (ptr[i+2] | 0x20) == 0x65
            && (ptr[i+3] | 0x20) == 0x72 && (ptr[i+4] | 0x20) == 0x74
    }

    private static func matchesEmergency(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "emergency"
        return (ptr[i+1] | 0x20) == 0x6D && (ptr[i+2] | 0x20) == 0x65
            && (ptr[i+3] | 0x20) == 0x72 && (ptr[i+4] | 0x20) == 0x67
            && (ptr[i+5] | 0x20) == 0x65 && (ptr[i+6] | 0x20) == 0x6E
            && (ptr[i+7] | 0x20) == 0x63 && (ptr[i+8] | 0x20) == 0x79
    }

    private static func matchesFatal(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "fatal" = 0x66 0x61 0x74 0x61 0x6C
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        let b4 = ptr[i+4] | 0x20
        return b1 == 0x61 && b2 == 0x74 && b3 == 0x61 && b4 == 0x6C
    }

    @inline(__always)
    private static func matchesWarn(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "warn" = 0x77 0x61 0x72 0x6E
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        return b1 == 0x61 && b2 == 0x72 && b3 == 0x6E
    }

    @inline(__always)
    private static func matchesInfo(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "info" = 0x69 0x6E 0x66 0x6F
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        return b1 == 0x6E && b2 == 0x66 && b3 == 0x6F
    }

    @inline(__always)
    private static func matchesDebug(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "debug" = 0x64 0x65 0x62 0x75 0x67
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        let b4 = ptr[i+4] | 0x20
        return b1 == 0x65 && b2 == 0x62 && b3 == 0x75 && b4 == 0x67
    }

    @inline(__always)
    private static func matchesVerbose(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "verbose" = 0x76 0x65 0x72 0x62 0x6F 0x73 0x65
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        let b4 = ptr[i+4] | 0x20
        let b5 = ptr[i+5] | 0x20
        let b6 = ptr[i+6] | 0x20
        return b1 == 0x65 && b2 == 0x72 && b3 == 0x62 && b4 == 0x6F && b5 == 0x73 && b6 == 0x65
    }

    @inline(__always)
    private static func matchesTrace(ptr: UnsafePointer<UInt8>, at i: Int) -> Bool {
        // "trace" = 0x74 0x72 0x61 0x63 0x65
        let b1 = ptr[i+1] | 0x20
        let b2 = ptr[i+2] | 0x20
        let b3 = ptr[i+3] | 0x20
        let b4 = ptr[i+4] | 0x20
        return b1 == 0x72 && b2 == 0x61 && b3 == 0x63 && b4 == 0x65
    }

}
