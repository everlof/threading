import Foundation
import os

/// What tells one write of a provider's own settings file from the next without reading it.
///
/// Shared by every reader of a CLI-owned file. `codexCatalog` proved the shape first; the Claude
/// readers now use it for the same reason.
struct ProviderSettingsFileIdentity: Equatable, Sendable {
    let modified: Date?
    let size: Int?

    init?(of url: URL) {
        guard let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return nil }
        modified = values.contentModificationDate
        size = values.fileSize
    }
}

enum ProviderSettingsCacheDefaults {
    /// One entry per file per login. The real population is a handful — four Claude directories
    /// and two Codex ones, two or three files each — so this is a refusal boundary rather than an
    /// expected size, and reaching it means a path is being generated rather than discovered.
    static let rememberedFiles = 32
}

/// Remembers what one of a provider's own files parsed to, and re-reads it only when the file
/// itself moves.
///
/// The agent CLIs own these files. Claude rewrites `.claude.json` whenever it pleases and never
/// tells us, so a lifetime-based cache has to choose between serving a stale model list and
/// re-reading constantly — and re-reading constantly is what shipped. Checking identity is both
/// cheaper *and* exact, so there is no trade to make. Measured here on a 96 KB `.claude.json`:
///
/// | `stat` (mtime + size) | read | `JSONSerialization` |
/// |---|---|---|
/// | 0.0017 ms | 0.0125 ms | 0.7024 ms |
///
/// The parse is 96% of the cost and the stat is ~430x cheaper than it, so every call still asks
/// the filesystem whether the file moved and only the parse is skipped. The answer is never
/// stale, and an unchanged file is never parsed twice.
///
/// This is the shape `rememberedCodexCatalogs` already used for `models_cache.json`, for the
/// reason its own comment gives: it "stops a catalogue build decoding the same 200 KB once per
/// model option". The Claude readers had no such guard, and one of them sat on the terminal
/// output path — `AgentWorkloadMonitor.recordActivity` re-derived the model list for every 200
/// bytes an agent printed. That measured 62% of all main-queue work and produced 1.4-2.0 s
/// main-thread stalls while an agent was streaming.
///
/// The cached value is the *derived* one, not the raw JSON: the decode closure returns whatever
/// the caller actually wanted, so building it is skipped along with parsing it, and the stored
/// type stays `Sendable` rather than an `[String: Any]` shared across threads.
final class ProviderSettingsFileCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let identity: ProviderSettingsFileIdentity
        let value: Value
    }

    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private let limit: Int

    init(limit: Int = ProviderSettingsCacheDefaults.rememberedFiles) {
        self.limit = limit
    }

    /// The file's current value, decoding only when its identity has moved since the last read.
    ///
    /// `decode` runs outside the lock: it performs disk I/O, and holding an unfair lock across a
    /// read would serialize every account's first look at its own files behind one slow disk.
    /// Two callers can race into the same first decode; either complete result is valid, and
    /// every later read is lock-cheap.
    ///
    /// The stat happens *before* the decode, and that order is the safe one. A write landing
    /// between the two stores newer content under an older identity — so the next call stats a
    /// third identity, disagrees, and decodes again. The entry is corrected on the very next
    /// read, and the content held is never older than the identity recorded beside it. Decoding
    /// first and stat'ing afterwards would invert both of those.
    func value(at url: URL, decode: (URL) -> Value?) -> Value? {
        let key = url.path

        // A file that cannot be stat'd is gone or unreadable. Forget what it used to say rather
        // than answering from a former login that happened to live at the same path.
        guard let identity = ProviderSettingsFileIdentity(of: url) else {
            entries.withLock { _ = $0.removeValue(forKey: key) }
            return nil
        }

        if let remembered = entries.withLock({ $0[key] }), remembered.identity == identity {
            return remembered.value
        }

        guard let decoded = decode(url) else {
            entries.withLock { _ = $0.removeValue(forKey: key) }
            return nil
        }

        entries.withLock {
            // Bounded: the key set is derived from discovered accounts, so overflow means paths
            // are being generated. Start again rather than growing without limit.
            if $0[key] == nil, $0.count >= limit { $0.removeAll() }
            $0[key] = Entry(identity: identity, value: decoded)
        }
        return decoded
    }

    /// Drops everything. Not needed for freshness — identity already guarantees that — but tests
    /// need a defined starting point.
    func invalidate() {
        entries.withLock { $0.removeAll() }
    }
}
