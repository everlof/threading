import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Usage Line Marker

/// The substring gate every usage reader puts in front of `JSONSerialization`.
public enum UsageLineMarker {
    /// Whether `needle` appears in `haystack`, through `memmem`.
    ///
    /// `Data.range(of:)` is the obvious way to write this and is far too slow to run once per
    /// line across a gigabyte — this gate is the only thing standing between the scan and
    /// parsing every record in every transcript, so it has to cost almost nothing.
    public static func contains(_ needle: [UInt8], in haystack: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }

        return haystack.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return needle.withUnsafeBytes { pattern -> Bool in
                guard let patternBase = pattern.baseAddress else { return false }
                return memmem(base, raw.count, patternBase, pattern.count) != nil
            }
        }
    }
}

// MARK: - Usage Index Defaults

public enum UsageIndexDefaults {
    /// The substring that makes a line worth parsing. Every priced record carries it, and
    /// almost nothing else does, so this is what keeps a 250 MB transcript cheap to read.
    public static let usageMarker = "\"usage\""

    public static let messageKey = "message"
    public static let usageKey = "usage"
    public static let idKey = "id"
    public static let requestKey = "requestId"
    public static let timestampKey = "timestamp"
    public static let modelKey = "model"
    public static let cwdKey = "cwd"

    public static let inputKey = "input_tokens"
    public static let outputKey = "output_tokens"
    public static let cacheWriteKey = "cache_creation_input_tokens"
    public static let cacheWriteDetailKey = "cache_creation"
    public static let cacheWrite1hKey = "ephemeral_1h_input_tokens"
    public static let cacheReadKey = "cache_read_input_tokens"

    public static let unknownModel = "unknown"
}

// MARK: - Usage Adapter Defaults

/// Provider directory and file names the adapters rely on. They mirror the app's `AgentDefaults`
/// and `CodexBackfillDefaults`, which stay where they are because the rest of the app uses them.
public enum UsageAdapterDefaults {
    /// A Claude child transcript lives in `<parent-session>/subagents/<child>.jsonl`.
    public static let claudeSubagentsSubdirectory = "subagents"
    public static let transcriptExtension = "jsonl"
    /// Codex keeps its rollouts under `<CODEX_HOME>/sessions`.
    public static let codexSessionsDirectory = "sessions"
}
