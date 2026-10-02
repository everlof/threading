import Foundation

public enum CodexDiscoveryDefaults {
    public static let rolloutPrefix = "rollout-"
    public static let rolloutExtension = "jsonl"
    public static let sessionMetaType = "session_meta"
    public static let sessionIndexFile = "session_index.jsonl"

    /// Bound for Codex's one-record-per-thread title index.
    public static let sessionIndexScanLimit = 64 * 1024 * 1024
    public static let userMessageType = "user_message"
    public static let pollInterval: TimeInterval = 0.25
    public static let maxAttempts = 40
    public static let clockSlack: TimeInterval = 5.0
    public static let headerReadLimit = 64 * 1024
    public static let maximumDailyFiles = 4096
}
