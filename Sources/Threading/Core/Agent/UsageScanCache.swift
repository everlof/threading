import Foundation

/// Per-source cache for usage adapters.
///
/// A cached file retains every response identity, not just its totals. Global deduplication can
/// therefore run after cached and newly parsed files are joined and produce exactly the same
/// answer as a cold scan. Each source has its own cache file so changing one transcript rewrites
/// one small value rather than a machine-wide cache containing millions of records.
final class UsageScanCache {
    struct Result {
        let records: [UsageLedgerRecord]
        let wasCacheHit: Bool
    }

    private struct Fingerprint: Codable, Equatable {
        let size: Int64
        let modifiedAt: TimeInterval
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let parserID: String
        let sourcePath: String
        let fingerprint: Fingerprint
        let records: [UsageLedgerRecord]
    }

    private let directory: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var usedFiles = Set<String>()

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func beginScan() {
        usedFiles.removeAll(keepingCapacity: true)
        prepareDirectory()
    }

    func records(
        for source: URL,
        parserID: String,
        parse: () -> [UsageLedgerRecord]
    ) -> Result {
        guard let fingerprint = fingerprint(of: source) else {
            return Result(records: parse(), wasCacheHit: false)
        }

        let cacheURL = url(forSourcePath: source.path, parserID: parserID)
        usedFiles.insert(cacheURL.lastPathComponent)

        if let data = try? BoundedFileReader.read(
            cacheURL,
            maximumBytes: UsageScanCacheDefaults.maximumEntryBytes
        ),
           let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.schemaVersion == UsageScanCacheDefaults.schemaVersion,
           envelope.parserID == parserID,
           envelope.sourcePath == source.path,
           envelope.fingerprint == fingerprint {
            return Result(records: envelope.records, wasCacheHit: true)
        }

        let parsed = parse()
        let envelope = Envelope(
            schemaVersion: UsageScanCacheDefaults.schemaVersion,
            parserID: parserID,
            sourcePath: source.path,
            fingerprint: fingerprint,
            records: parsed
        )
        if let data = try? encoder.encode(envelope),
           data.count <= UsageScanCacheDefaults.maximumEntryBytes {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return Result(records: parsed, wasCacheHit: false)
    }

    /// Cache for a supported CLI export. `revision` is the session's durable last-activity
    /// stamp, so a dormant OpenCode session costs no process launch on a warm rebuild.
    func records(
        forKey key: String,
        revision: Date,
        parserID: String,
        parse: () throws -> [UsageLedgerRecord]
    ) throws -> Result {
        let fingerprint = Fingerprint(size: 0, modifiedAt: revision.timeIntervalSince1970)
        let cacheURL = url(forSourcePath: key, parserID: parserID)
        usedFiles.insert(cacheURL.lastPathComponent)

        if let data = try? BoundedFileReader.read(
            cacheURL,
            maximumBytes: UsageScanCacheDefaults.maximumEntryBytes
        ),
           let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.schemaVersion == UsageScanCacheDefaults.schemaVersion,
           envelope.parserID == parserID,
           envelope.sourcePath == key,
           envelope.fingerprint == fingerprint {
            return Result(records: envelope.records, wasCacheHit: true)
        }

        let parsed = try parse()
        let envelope = Envelope(
            schemaVersion: UsageScanCacheDefaults.schemaVersion,
            parserID: parserID,
            sourcePath: key,
            fingerprint: fingerprint,
            records: parsed
        )
        if let data = try? encoder.encode(envelope),
           data.count <= UsageScanCacheDefaults.maximumEntryBytes {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return Result(records: parsed, wasCacheHit: false)
    }

    /// Removes entries for transcript files no longer offered by any adapter. Cache deletion is
    /// recoverable and deliberately scoped to this private directory.
    func finishScan() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.pathExtension == UsageScanCacheDefaults.extensionName {
            guard !usedFiles.contains(entry.lastPathComponent) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func prepareDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    private func fingerprint(of source: URL) -> Fingerprint? {
        // `URL.resourceValues` may reuse values cached on the URL instance. A refresh can keep
        // the same URL while atomically replacing its file, so read fresh filesystem metadata.
        guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Fingerprint(size: size.int64Value, modifiedAt: modifiedAt.timeIntervalSince1970)
    }

    private func url(forSourcePath path: String, parserID: String) -> URL {
        let hash = stableHash("\(parserID)|\(path)")
        return directory
            .appendingPathComponent(String(format: "%016llx", hash))
            .appendingPathExtension(UsageScanCacheDefaults.extensionName)
    }

    /// Stable FNV-1a rather than Swift's randomized `hashValue`, so cache names survive launch.
    private func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

enum UsageScanCacheDefaults {
    static let directoryName = "UsageScanCache"
    static let schemaVersion = 1
    static let extensionName = "usagecache"
    static let maximumEntryBytes = 64 * 1024 * 1024
    static let claudeParserID = "claude-v2"
    static let codexParserID = "codex-v1"
    static let openCodeParserID = "opencode-export-v1"
}
