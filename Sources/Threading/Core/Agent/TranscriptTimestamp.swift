import Foundation
import os

/// When a transcript record was written.
///
/// Claude stamps records at the top level and Codex stamps its rollout envelope the same way;
/// both write ISO 8601, with and without fractional seconds depending on version. Two readers
/// need this — replay, which orders a conversation, and import, which asks when a conversation
/// last moved — so the pair of parsers lives here rather than being written again per caller.
enum TranscriptTimestamp {

    /// The moment a record carries, or nil for the records that carry none. Both CLIs write
    /// bookkeeping records without one: Claude's `last-prompt`, `summary` and `bridge-session`
    /// lines, Codex's rollout header.
    static func of(_ record: [String: Any]) -> Date? {
        guard let raw = record["timestamp"] as? String else { return nil }
        return date(from: raw)
    }

    static func date(from raw: String) -> Date? {
        parsers.withLock { parsers in
            parsers.fractional.date(from: raw) ?? parsers.plain.date(from: raw)
        }
    }

    /// Foundation formatters are reference types with mutable configuration and lack an
    /// available Sendable conformance on the app's deployment target. The wrapper's only escape
    /// is as the state of `parsers`; every read is therefore protected by that lock.
    private final class Parsers: @unchecked Sendable {
        let fractional: ISO8601DateFormatter = {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser
        }()
        let plain: ISO8601DateFormatter = {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            return parser
        }()
    }

    private static let parsers = OSAllocatedUnfairLock(initialState: Parsers())
}
