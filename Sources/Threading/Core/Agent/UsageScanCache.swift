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

    private enum FailureStage: String, CaseIterable {
        case directory
        case backupExclusion = "backup_exclusion"
        case read
        case decode
        case encode
        case oversized
        case write
        case enumerate
        case remove
        case prune
    }

    private let directory: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let maximumTotalBytes: Int64
    private var usedFiles = Set<String>()
    private var failureCounts: [FailureStage: Int] = [:]

    init(
        directory: URL,
        fileManager: FileManager = .default,
        maximumTotalBytes: Int64 = UsageScanCacheDefaults.maximumTotalBytes
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumTotalBytes = maximumTotalBytes

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func beginScan() {
        usedFiles.removeAll(keepingCapacity: true)
        failureCounts.removeAll(keepingCapacity: true)
        prepareDirectory()
    }

    /// One source is one unit of transient memory.
    ///
    /// A scan walks every transcript this machine has ever produced, and both halves of a source
    /// allocate through Objective-C: the cache read hands back autoreleased `NSData` chunks, and
    /// `JSONDecoder` leaves an autoreleased `_NSJSONReader` per decode. Nothing in the scan loop
    /// drained a pool, so all of it stayed resident until the whole scan returned. With 2,824
    /// sources behind a 4.4 GB cache directory that reached 4.4 GB of live `NSData` in one pass,
    /// which is most of a 14 GB peak. Returned records are Swift values and are unaffected by the
    /// pool, so the bound costs the scan nothing.
    func records(
        for source: URL,
        parserID: String,
        parse: () throws -> [UsageLedgerRecord]
    ) rethrows -> Result {
        try autoreleasepool {
            try resolveRecords(for: source, parserID: parserID, parse: parse)
        }
    }

    private func resolveRecords(
        for source: URL,
        parserID: String,
        parse: () throws -> [UsageLedgerRecord]
    ) rethrows -> Result {
        guard let fingerprint = fingerprint(of: source) else {
            return Result(records: try parse(), wasCacheHit: false)
        }

        let cacheURL = url(forSourcePath: source.path, parserID: parserID)
        usedFiles.insert(cacheURL.lastPathComponent)

        if let envelope = cachedEnvelope(at: cacheURL),
           envelope.schemaVersion == UsageScanCacheDefaults.schemaVersion,
           envelope.parserID == parserID,
           envelope.sourcePath == source.path,
           envelope.fingerprint == fingerprint {
            return Result(records: envelope.records, wasCacheHit: true)
        }

        let parsed = try parse()
        let envelope = Envelope(
            schemaVersion: UsageScanCacheDefaults.schemaVersion,
            parserID: parserID,
            sourcePath: source.path,
            fingerprint: fingerprint,
            records: parsed
        )
        persist(envelope, at: cacheURL)
        return Result(records: parsed, wasCacheHit: false)
    }

    /// Cache for a supported CLI export. The caller supplies a work revision for settled sources
    /// and a new sample revision for live or explicitly refreshed exports. Row age alone cannot
    /// version output that is still being appended inside the same turn.
    func records(
        forKey key: String,
        revision: Date,
        parserID: String,
        forceRefresh: Bool = false,
        parse: () throws -> [UsageLedgerRecord]
    ) throws -> Result {
        try autoreleasepool {
            try resolveRecords(forKey: key, revision: revision, parserID: parserID, forceRefresh: forceRefresh, parse: parse)
        }
    }

    private func resolveRecords(
        forKey key: String,
        revision: Date,
        parserID: String,
        forceRefresh: Bool = false,
        parse: () throws -> [UsageLedgerRecord]
    ) throws -> Result {
        let fingerprint = Fingerprint(size: 0, modifiedAt: revision.timeIntervalSince1970)
        let cacheURL = url(forSourcePath: key, parserID: parserID)
        usedFiles.insert(cacheURL.lastPathComponent)

        if !forceRefresh, let envelope = cachedEnvelope(at: cacheURL),
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
        persist(envelope, at: cacheURL)
        return Result(records: parsed, wasCacheHit: false)
    }

    /// Removes entries for transcript files no longer offered by any adapter. Cache deletion is
    /// recoverable and deliberately scoped to this private directory.
    func finishScan() {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            recordFailure(.enumerate)
            reportFailures()
            return
        }

        for entry in entries where entry.pathExtension == UsageScanCacheDefaults.extensionName {
            guard !usedFiles.contains(entry.lastPathComponent) else { continue }
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                recordFailure(.remove)
            }
        }
        enforceAggregateBound()
        reportFailures()
    }

    /// Per-entry safety did not stop 2,824 individually valid files from reaching 4.4 GB. The
    /// source cache is rebuildable and the SQLite ledger below is the warm authority now, so its
    /// oldest envelopes are discarded until the directory has one real machine-wide bound.
    private func enforceAggregateBound() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let entries: [(url: URL, bytes: Int64, modifiedAt: Date)]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys)
            ).compactMap { url in
                guard url.pathExtension == UsageScanCacheDefaults.extensionName else { return nil }
                let values = try url.resourceValues(forKeys: keys)
                return (
                    url,
                    Int64(values.fileSize ?? 0),
                    values.contentModificationDate ?? .distantPast
                )
            }
        } catch {
            recordFailure(.enumerate)
            return
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maximumTotalBytes else { return }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            do {
                try fileManager.removeItem(at: entry.url)
                total -= entry.bytes
                if total <= maximumTotalBytes { return }
            } catch {
                recordFailure(.prune)
            }
        }
    }

    private func prepareDirectory() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            recordFailure(.directory)
            return
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        do {
            try mutable.setResourceValues(values)
        } catch {
            recordFailure(.backupExclusion)
        }
    }

    private func cachedEnvelope(at url: URL) -> Envelope? {
        let data: Data
        do {
            data = try BoundedFileReader.read(
                url,
                maximumBytes: UsageScanCacheDefaults.maximumEntryBytes
            )
        } catch {
            // A cache that has never been written is the ordinary cold path, not a failure.
            if fileManager.fileExists(atPath: url.path) {
                recordFailure(.read)
            }
            return nil
        }

        do {
            return try decoder.decode(Envelope.self, from: data)
        } catch {
            recordFailure(.decode)
            return nil
        }
    }

    private func persist(_ envelope: Envelope, at url: URL) {
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            recordFailure(.encode)
            return
        }
        guard data.count <= UsageScanCacheDefaults.maximumEntryBytes else {
            recordFailure(.oversized)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            recordFailure(.write)
        }
    }

    private func recordFailure(_ stage: FailureStage) {
        failureCounts[stage, default: 0] += 1
    }

    private func reportFailures() {
        for stage in FailureStage.allCases {
            guard let count = failureCounts[stage], count > 0 else { continue }
            ThreadingLogger.usage.warning(
                "Usage scan cache degraded stage=\(stage.rawValue, privacy: .public) count=\(count, privacy: .public)"
            )
        }
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

// MARK: - Incremental global ledger

/// A source-fingerprinted, globally deduplicated ledger.
///
/// `UsageScanCache` made parsing incremental but still decoded every cached envelope and joined
/// every record in RAM once an hour. This index moves the unchanged-source decision in front of
/// decoding and stores one payload per response identity. A warm scan is filesystem metadata plus
/// one indexed lookup per source; report aggregation streams distinct rows one at a time.
final class UsageLedgerIndex {
    struct Update {
        let recordCount: Int
        let routedRecordCount: Int
        let wasCacheHit: Bool
    }

    private struct Revision: Equatable {
        let size: Int64
        let modifiedAt: TimeInterval
    }

    private struct GenerationManifest: Codable, Equatable {
        let schemaVersion: Int
        let parserGenerationID: String
        let databaseFileName: String
    }

    private let database: SQLiteDatabase
    private let directory: URL
    private let databaseURL: URL
    private let parserGenerationID: String
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var usedSources = Set<String>()

    init(
        directory: URL,
        fileManager: FileManager = .default,
        parserGenerationID: String = UsageLedgerIndexDefaults.parserGenerationID
    ) throws {
        self.directory = directory
        self.parserGenerationID = parserGenerationID
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent(
            UsageLedgerIndexDefaults.fileName(forParserGenerationID: parserGenerationID)
        )
        database = try SQLiteDatabase(
            path: databaseURL.path,
            maximumSchemaVersion: UsageLedgerIndexDefaults.schemaVersion
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try database.migrate(to: UsageLedgerIndexDefaults.schemaVersion) { version in
            guard version == 1 else { return }
            try database.execute(
                """
                CREATE TABLE usage_source (
                    source_key TEXT PRIMARY KEY,
                    parser_id TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    revision_size INTEGER NOT NULL,
                    revision_modified_at REAL NOT NULL,
                    record_count INTEGER NOT NULL,
                    routed_record_count INTEGER NOT NULL
                );
                CREATE TABLE usage_record (
                    identity TEXT PRIMARY KEY,
                    data BLOB NOT NULL
                );
                CREATE TABLE usage_source_record (
                    source_key TEXT NOT NULL REFERENCES usage_source(source_key) ON DELETE CASCADE,
                    identity TEXT NOT NULL REFERENCES usage_record(identity) ON DELETE CASCADE,
                    PRIMARY KEY (source_key, identity)
                );
                CREATE INDEX usage_source_record_identity
                    ON usage_source_record(identity);
                CREATE TABLE usage_metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )
        }

        try establishParserGeneration()
    }

    func beginScan() {
        usedSources.removeAll(keepingCapacity: true)
    }

    func update(
        source: URL,
        parserID: String,
        load: () throws -> UsageScanCache.Result
    ) throws -> Update {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw UsageLedgerIndexError.missingRevision(source.path)
        }
        return try update(
            key: source.path,
            revision: Revision(
                size: size.int64Value,
                modifiedAt: modifiedAt.timeIntervalSince1970
            ),
            parserID: parserID,
            load: load
        )
    }

    func update(
        key: String,
        revision: Date,
        parserID: String,
        forceRefresh: Bool = false,
        load: () throws -> UsageScanCache.Result
    ) throws -> Update {
        try update(
            key: key,
            revision: Revision(size: 0, modifiedAt: revision.timeIntervalSince1970),
            parserID: parserID,
            forceRefresh: forceRefresh,
            load: load
        )
    }

    /// Deletes sources no adapter offered this pass and returns the raw record total represented
    /// by the surviving source set. Orphaned response rows are reclaimed in the same transaction.
    func finishScan() throws -> Int {
        var storedKeys: [String] = []
        let select = try database.prepare("SELECT source_key FROM usage_source")
        while try select.step() {
            if let key = select.text(0) { storedKeys.append(key) }
        }
        select.finalize()

        try database.transaction {
            let remove = try database.prepare(
                "DELETE FROM usage_source WHERE source_key = ?"
            )
            defer { remove.finalize() }
            for key in storedKeys where !usedSources.contains(key) {
                _ = try remove.bind(1, key).step()
                try remove.reset()
            }
            try database.execute(
                """
                DELETE FROM usage_record
                WHERE NOT EXISTS (
                    SELECT 1 FROM usage_source_record
                    WHERE usage_source_record.identity = usage_record.identity
                )
                """
            )
        }
        return try database.scalar("SELECT COALESCE(SUM(record_count), 0) FROM usage_source") ?? 0
    }

    /// Makes this complete generation the durable warm authority, then retires prior physical
    /// generations by unlinking their rebuildable SQLite files. A parser change never shares a
    /// database with its predecessor, so it cannot create millions of old/new edges and later
    /// reclaim them through foreign-key cascades.
    ///
    /// The manifest write is atomic and happens before retirement. A crash before it leaves the
    /// previous generation and persisted report untouched while this database remains resumable;
    /// a crash after it leaves either both files or only the committed one. Both states are safe
    /// for the next scan.
    func commitGeneration() throws {
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let manifestURL = directory.appendingPathComponent(
            UsageLedgerIndexDefaults.manifestFileName
        )
        let manifest = GenerationManifest(
            schemaVersion: UsageLedgerIndexDefaults.schemaVersion,
            parserGenerationID: parserGenerationID,
            databaseFileName: databaseURL.lastPathComponent
        )
        if !shouldPreserveFutureManifest(at: manifestURL) {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        }
        retireObsoleteGenerationFiles()
    }

    /// Streams globally distinct records. The callback returns before the next SQLite row is
    /// decoded, so peak transient memory is one compact record rather than the whole history.
    func forEachRecord(_ body: (UsageLedgerRecord) -> Void) throws {
        let statement = try database.prepare(
            """
            SELECT data FROM usage_record
            WHERE EXISTS (
                SELECT 1 FROM usage_source_record
                WHERE usage_source_record.identity = usage_record.identity
            )
            ORDER BY identity
            """
        )
        defer { statement.finalize() }
        while try statement.step() {
            guard let data = statement.data(0) else { continue }
            try autoreleasepool {
                body(try decoder.decode(UsageLedgerRecord.self, from: data))
            }
        }
    }

    private func update(
        key: String,
        revision: Revision,
        parserID: String,
        forceRefresh: Bool = false,
        load: () throws -> UsageScanCache.Result
    ) throws -> Update {
        let sourceKey = Self.sourceKey(path: key, parserID: parserID)
        usedSources.insert(sourceKey)
        if !forceRefresh, let stored = try storedSource(
            sourceKey: sourceKey,
            parserID: parserID,
            revision: revision
        ) {
            return Update(
                recordCount: stored.records,
                routedRecordCount: stored.routed,
                wasCacheHit: true
            )
        }

        let loaded: UsageScanCache.Result
        do {
            loaded = try load()
        } catch {
            usedSources.remove(sourceKey)
            throw error
        }
        let routed = loaded.records.reduce(into: 0) { count, record in
            if record.origin.billingProviderID == UsageReportDefaults.openRouterCoverageID {
                count += 1
            }
        }
        try replace(
            sourceKey: sourceKey,
            sourcePath: key,
            parserID: parserID,
            revision: revision,
            records: loaded.records,
            routedRecordCount: routed
        )
        return Update(
            recordCount: loaded.records.count,
            routedRecordCount: routed,
            wasCacheHit: loaded.wasCacheHit
        )
    }

    private func storedSource(
        sourceKey: String,
        parserID: String,
        revision: Revision
    ) throws -> (records: Int, routed: Int)? {
        let statement = try database.prepare(
            """
            SELECT record_count, routed_record_count
            FROM usage_source
            WHERE source_key = ? AND parser_id = ?
              AND revision_size = ? AND revision_modified_at = ?
            """
        )
        defer { statement.finalize() }
        statement.bind(1, sourceKey)
            .bind(2, parserID)
            .bind(3, revision.size)
            .bind(4, revision.modifiedAt)
        guard try statement.step() else { return nil }
        return (statement.int(0), statement.int(1))
    }

    private func replace(
        sourceKey: String,
        sourcePath: String,
        parserID: String,
        revision: Revision,
        records: [UsageLedgerRecord],
        routedRecordCount: Int
    ) throws {
        try database.transaction {
            let source = try database.prepare(
                """
                INSERT INTO usage_source (
                    source_key, parser_id, source_path, revision_size,
                    revision_modified_at, record_count, routed_record_count
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key) DO UPDATE SET
                    parser_id = excluded.parser_id,
                    source_path = excluded.source_path,
                    revision_size = excluded.revision_size,
                    revision_modified_at = excluded.revision_modified_at,
                    record_count = excluded.record_count,
                    routed_record_count = excluded.routed_record_count
                """
            )
            source.bind(1, sourceKey)
                .bind(2, parserID)
                .bind(3, sourcePath)
                .bind(4, revision.size)
                .bind(5, revision.modifiedAt)
                .bind(6, records.count)
                .bind(7, routedRecordCount)
            try source.run()

            let remove = try database.prepare(
                "DELETE FROM usage_source_record WHERE source_key = ?"
            )
            try remove.bind(1, sourceKey).run()

            let insertRecord = try database.prepare(
                """
                INSERT INTO usage_record(identity, data) VALUES (?, ?)
                ON CONFLICT(identity) DO UPDATE SET data = excluded.data
                """
            )
            let associate = try database.prepare(
                """
                INSERT OR IGNORE INTO usage_source_record(source_key, identity)
                VALUES (?, ?)
                """
            )
            defer {
                insertRecord.finalize()
                associate.finalize()
            }
            for record in records {
                let data = try autoreleasepool { try encoder.encode(record) }
                _ = try insertRecord.bind(1, record.identity).bind(2, data).step()
                try insertRecord.reset()
                _ = try associate.bind(1, sourceKey).bind(2, record.identity).step()
                try associate.reset()
            }
        }
    }

    private static func sourceKey(path: String, parserID: String) -> String {
        // This key stays inside SQLite, so there is no filesystem-name constraint that would
        // justify a lossy hash. A length prefix makes the pair unambiguous and collision-free.
        "\(parserID.utf8.count):\(parserID)\(path)"
    }

    private func establishParserGeneration() throws {
        let select = try database.prepare(
            "SELECT value FROM usage_metadata WHERE key = ?"
        )
        defer { select.finalize() }
        select.bind(1, UsageLedgerIndexDefaults.parserGenerationMetadataKey)
        if try select.step(), let stored = select.text(0) {
            guard stored == parserGenerationID else {
                throw UsageLedgerIndexError.parserGenerationCollision
            }
            return
        }

        let insert = try database.prepare(
            "INSERT INTO usage_metadata(key, value) VALUES (?, ?)"
        )
        defer { insert.finalize() }
        try insert
            .bind(1, UsageLedgerIndexDefaults.parserGenerationMetadataKey)
            .bind(2, parserGenerationID)
            .run()
    }

    private func shouldPreserveFutureManifest(at url: URL) -> Bool {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: UsageLedgerIndexDefaults.maximumManifestBytes
        ),
        let manifest = try? JSONDecoder().decode(GenerationManifest.self, from: data) else {
            return false
        }
        return manifest.schemaVersion > UsageLedgerIndexDefaults.schemaVersion
    }

    private func retireObsoleteGenerationFiles() {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            ThreadingLogger.usage.warning(
                "Usage ledger generation cleanup could not enumerate files: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return
        }

        let currentNames = Set(
            [databaseURL.lastPathComponent]
                + UsageLedgerIndexDefaults.sidecarSuffixes.map {
                    databaseURL.lastPathComponent + $0
                }
        )
        for name in names {
            guard UsageLedgerIndexDefaults.isRetirableLedgerDatabaseArtifact(name),
                  !currentNames.contains(name) else { continue }
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                ThreadingLogger.usage.warning(
                    "Usage ledger generation cleanup could not remove artifact: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }
}

private enum UsageLedgerIndexError: LocalizedError {
    case missingRevision(String)
    case parserGenerationCollision

    var errorDescription: String? {
        switch self {
        case .missingRevision: return "A transcript source had no stable filesystem revision"
        case .parserGenerationCollision:
            return "A usage ledger filename resolved to a different parser generation"
        }
    }
}

enum UsageLedgerIndexDefaults {
    static let legacyFileName = "usage-ledger-index.sqlite"
    static let fileNamePrefix = "usage-ledger-index-v"
    static let manifestFileName = "usage-ledger-index-current.json"
    static let maximumManifestBytes = 64 * 1024
    static let parserGenerationMetadataKey = "parser_generation_id"
    static let sidecarSuffixes = ["-wal", "-shm"]
    static let schemaVersion = 1

    /// Every parser whose records can share one report is part of the physical generation.
    /// Changing any member opens a fresh, resumable database instead of mixing old and new rows.
    static let parserGenerationID = [
        UsageScanCacheDefaults.claudeParserID,
        UsageScanCacheDefaults.codexParserID,
        UsageScanCacheDefaults.openCodeParserID
    ].joined(separator: "|")

    static func fileName(forParserGenerationID parserGenerationID: String) -> String {
        let hash = parserGenerationID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return "\(fileNamePrefix)\(schemaVersion)-\(String(format: "%016llx", hash)).sqlite"
    }

    /// Returns true only for artifacts this running schema can safely supersede.
    ///
    /// A newer app may leave a future-schema ledger behind before the user launches an older
    /// build. The older build cannot prove that file is rebuildable on its terms, so retirement
    /// must parse the version rather than accepting every generated ledger prefix.
    static func isRetirableLedgerDatabaseArtifact(_ name: String) -> Bool {
        let baseName: String
        if let suffix = sidecarSuffixes.first(where: { name.hasSuffix($0) }) {
            baseName = String(name.dropLast(suffix.count))
        } else {
            baseName = name
        }
        guard baseName.hasSuffix(".sqlite") else { return false }
        if baseName == legacyFileName { return true }
        guard baseName.hasPrefix(fileNamePrefix) else { return false }

        let versionAndGeneration = baseName
            .dropFirst(fileNamePrefix.count)
            .dropLast(".sqlite".count)
        guard let separator = versionAndGeneration.firstIndex(of: "-") else { return false }
        let versionText = versionAndGeneration[..<separator]
        let generationText = versionAndGeneration[versionAndGeneration.index(after: separator)...]
        guard !generationText.isEmpty,
              let artifactSchemaVersion = Int(versionText),
              artifactSchemaVersion > 0 else { return false }
        return artifactSchemaVersion <= schemaVersion
    }
}

enum UsageScanCacheDefaults {
    static let directoryName = "UsageScanCache"
    static let schemaVersion = 1
    static let extensionName = "usagecache"
    static let maximumEntryBytes = 64 * 1024 * 1024
    /// The cache is only a migration/fallback layer once `UsageLedgerIndex` has a source. It may
    /// use enough room to avoid reparsing a recent working set, but never several gigabytes.
    static let maximumTotalBytes: Int64 = 512 * 1024 * 1024
    static let claudeParserID = "claude-v4-strict-provenance"
    static let codexParserID = "codex-v2-strict-child-boundary"
    static let openCodeParserID = "opencode-export-v1"
}

enum UsageScanDefaults {
    /// The floor between two progress reports leaving the scan queue.
    ///
    /// Roughly six frames: fast enough that a bar moves rather than steps, slow enough that a
    /// warm scan reading thousands of cached transcripts a second cannot flood the main actor
    /// with work that outweighs the scan itself.
    static let progressInterval: CFTimeInterval = 0.1
}
