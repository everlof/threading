import Foundation

/// A value-only description of one provider transcript. Filesystem authority remains in this
/// host-side snapshot; neither the FTS database nor a search result persists its absolute URL.
struct TranscriptSearchSource: Hashable, Sendable {
    let sourceID: SearchSourceID
    let url: URL
    let kind: AgentKind
    let projectID: ProjectID
    let projectName: String
    let sessionID: SessionID
    let sessionTitle: String
    let providerName: String
    let isArchived: Bool
    let updatedAt: Date
}

@MainActor
enum TranscriptSearchProjection {
    static func sources(projects: [Project]) -> [TranscriptSearchSource] {
        projects.flatMap { project in
            project.sessions.compactMap { session in
                guard TranscriptReplayFormat(kind: session.kind) != nil,
                      let transcriptID = session.resumeState.transcriptID,
                      let account = AgentAccountDiscovery.account(
                          for: session.kind,
                          handle: session.accountHandle
                      ),
                      let url = SessionTranscript.url(
                          sessionID: transcriptID,
                          for: session,
                          in: project,
                          account: account
                      ) else { return nil }

                let sourceKey = [
                    session.kind.rawValue,
                    account.handle.name,
                    transcriptID.rawValue,
                    project.id.uuidString,
                    session.id.uuidString,
                ].joined(separator: ":")
                return TranscriptSearchSource(
                    sourceID: SearchSourceID(rawValue: sourceKey),
                    url: url,
                    kind: session.kind,
                    projectID: project.id,
                    projectName: project.name,
                    sessionID: session.id,
                    sessionTitle: session.displayTitle,
                    providerName: session.kind.displayName,
                    isArchived: session.isArchived,
                    updatedAt: session.lastUsedAt
                )
            }
        }
    }
}

struct TranscriptSearchIndexResult: Sendable {
    let hits: [SearchHit]
    let coverage: SearchCoverage
    let isCapped: Bool
}

/// Rebuildable, append-resumable conversation index. One actor owns the SQLite connection, so a
/// query can interleave between bounded ingestion batches without a second mutable owner.
actor TranscriptSearchIndex {
    /// How this app reads a transcript. A change here invalidates every ledger row, because the
    /// normalized text a previous version produced can no longer be trusted to match.
    static let parserVersion = 1

    /// The shape of the database, which moves independently of `parserVersion`. Version 2 adds
    /// `metadata_signature` to the ledger; the indexed text it stands beside is unchanged, so
    /// bumping the two together would have re-ingested every transcript to add one column.
    static let schemaVersion = 2

    static let ingestionScanBytes = 4 * 1024 * 1024
    static let maximumQueryRows = UniversalSearchDefaults.maximumHitsPerGroup + 1
    static let maximumWindowRowUTF8Bytes = 1024

    private struct LedgerRow {
        let indexedOffset: UInt64
        let sourceGeneration: UInt64
        let prefixSignature: String
        let parserVersion: Int
    }

    private enum RefreshState {
        case idle
        case indexing(indexed: Int, total: Int)
    }

    private enum Binding {
        case text(String)
        case integer(Int)
        case double(Double)
    }

    private let database: SQLiteDatabase
    private var currentSourcesByID: [SearchSourceID: TranscriptSearchSource] = [:]
    private var refreshState: RefreshState = .idle
    private var unavailableSourceCount = 0
    private var containsTruncatedBody = false

    /// How many times the metadata rewrite below has actually run.
    ///
    /// The guard in `updateMetadata` is a performance contract, and a performance contract that
    /// nothing asserts is one refactor away from being gone. This is the cheapest honest way to
    /// see it hold: the rewrite is a full scan of the FTS table, and the count says whether one
    /// happened, without a test having to time anything.
    private(set) var metadataRewriteCount = 0

    init(databaseURL: URL) throws {
        let database = try SQLiteDatabase(
            path: databaseURL.path,
            maximumSchemaVersion: Self.schemaVersion
        )
        try database.migrate(to: Self.schemaVersion) { version in
            if version == 2 {
                try database.execute("""
                ALTER TABLE transcript_search_sources ADD COLUMN metadata_signature TEXT
                """)
                return
            }
            guard version == 1 else { return }
            try database.execute("""
            CREATE TABLE transcript_search_sources (
                source_id TEXT PRIMARY KEY NOT NULL,
                indexed_offset INTEGER NOT NULL,
                source_generation INTEGER NOT NULL,
                prefix_signature TEXT NOT NULL,
                parser_version INTEGER NOT NULL,
                body_was_truncated INTEGER NOT NULL DEFAULT 0
            )
            """)
            try database.execute("""
            CREATE VIRTUAL TABLE transcript_search_fts USING fts5(
                source_id UNINDEXED,
                record_id UNINDEXED,
                source_generation UNINDEXED,
                project_id UNINDEXED,
                project_name,
                session_id UNINDEXED,
                session_title,
                provider,
                archived UNINDEXED,
                kind UNINDEXED,
                author UNINDEXED,
                title,
                body,
                timestamp UNINDEXED,
                start_offset UNINDEXED,
                end_offset UNINDEXED,
                ordinal UNINDEXED,
                has_error UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        }
        self.database = database
    }

    /// Reconciles a complete source snapshot. Cancellation takes effect between sources and
    /// bounded JSONL passes; every accepted pass and its resume cursor commit atomically.
    func refresh(sources: [TranscriptSearchSource]) async {
        currentSourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        let ordered = sources.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.sourceID.rawValue < $1.sourceID.rawValue
        }
        refreshState = .indexing(indexed: 0, total: ordered.count)
        unavailableSourceCount = 0

        do {
            try deleteSourcesAbsent(from: Set(ordered.map(\.sourceID.rawValue)))
            containsTruncatedBody = try persistedTruncationState()
        } catch {
            unavailableSourceCount = ordered.count
            refreshState = .idle
            return
        }

        var indexed = 0
        for source in ordered {
            guard !Task.isCancelled else { return }
            do {
                guard FileManager.default.fileExists(atPath: source.url.path) else {
                    unavailableSourceCount += 1
                    indexed += 1
                    refreshState = .indexing(indexed: indexed, total: ordered.count)
                    continue
                }
                try await reconcile(source)
            } catch {
                unavailableSourceCount += 1
            }
            indexed += 1
            refreshState = .indexing(indexed: indexed, total: ordered.count)
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        refreshState = .idle
    }

    func search(_ query: SearchQuery) -> TranscriptSearchIndexResult {
        guard !query.expression.positiveTerms.isEmpty else {
            return TranscriptSearchIndexResult(
                hits: [], coverage: coverage(), isCapped: false
            )
        }
        guard scopePermitsTranscript(query.scope), filtersPermitTranscript(query.expression.filters)
        else {
            return TranscriptSearchIndexResult(
                hits: [], coverage: coverage(), isCapped: false
            )
        }

        do {
            let sql = querySQL(for: query)
            let statement = try database.prepare(sql.sql)
            defer { statement.finalize() }
            for (offset, binding) in sql.bindings.enumerated() {
                let index = Int32(offset + 1)
                switch binding {
                case let .text(value): statement.bind(index, value)
                case let .integer(value): statement.bind(index, value)
                case let .double(value): statement.bind(index, value)
                }
            }

            var hits: [SearchHit] = []
            while try statement.step() {
                guard let hit = hit(from: statement, query: query) else { continue }
                hits.append(hit)
            }
            let capped = hits.count > UniversalSearchDefaults.maximumHitsPerGroup
            hits.sort { $0.stableOrder < $1.stableOrder }
            return TranscriptSearchIndexResult(
                hits: Array(hits.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
                coverage: coverage(),
                isCapped: capped
            )
        } catch {
            return TranscriptSearchIndexResult(
                hits: [],
                coverage: .unavailable(reason: L10n.string(
                    "Conversation history search is unavailable."
                )),
                isCapped: false
            )
        }
    }

    /// Loads a bounded, source-validated window around one search result. The index row only
    /// chooses the candidate: the exact provider record is parsed again at its byte offset before
    /// any text is shown, so a transcript rewrite cannot land on stale or merely nearby content.
    func conversationWindow(
        centeredOn locator: SearchConversationLocator,
        radius requestedRadius: Int
    ) throws -> ConversationWindow {
        let radius = min(max(requestedRadius, 1), 100)
        guard let source = currentSourcesByID[locator.sourceID],
              source.projectID == locator.projectID,
              source.sessionID == locator.sessionID,
              let ledger = try ledgerRow(sourceID: locator.sourceID.rawValue),
              ledger.sourceGeneration == locator.sourceGeneration
        else { throw ConversationWindowLoadError.resultNoLongerAvailable }

        let anchorStatement = try database.prepare("""
        SELECT record_id, kind, author, title, body, timestamp,
               start_offset, end_offset, ordinal, has_error
        FROM transcript_search_fts
        WHERE source_id = ? AND source_generation = ? AND record_id = ?
        LIMIT 1
        """)
        defer { anchorStatement.finalize() }
        anchorStatement.bind(1, locator.sourceID.rawValue)
        anchorStatement.bind(2, Int64(locator.sourceGeneration))
        anchorStatement.bind(3, locator.recordID.rawValue)
        guard try anchorStatement.step(),
              let anchor = conversationWindowRow(from: anchorStatement)
        else { throw ConversationWindowLoadError.resultNoLongerAvailable }

        let storedAnchorStart = anchorStatement.int(6)
        let storedAnchorEnd = anchorStatement.int(7)
        guard storedAnchorStart >= 0, storedAnchorEnd >= 0 else {
            throw ConversationWindowLoadError.resultNoLongerAvailable
        }
        let anchorStart = UInt64(storedAnchorStart)
        let anchorEnd = UInt64(storedAnchorEnd)
        let anchorOrdinal = anchorStatement.int(8)
        guard anchorEnd >= anchorStart,
              anchorEnd <= ledger.indexedOffset,
              revalidates(
                  anchor,
                  at: source.url,
                  kind: source.kind,
                  startOffset: anchorStart,
                  endOffset: anchorEnd
              )
        else { throw ConversationWindowLoadError.resultNoLongerAvailable }

        var earlier = try conversationRows(
            sourceID: locator.sourceID,
            generation: locator.sourceGeneration,
            relativeToStart: anchorStart,
            ordinal: anchorOrdinal,
            before: true,
            limit: radius + 1
        )
        let hasEarlier = earlier.count > radius
        if hasEarlier { earlier.removeLast(earlier.count - radius) }
        earlier.reverse()

        var later = try conversationRows(
            sourceID: locator.sourceID,
            generation: locator.sourceGeneration,
            relativeToStart: anchorStart,
            ordinal: anchorOrdinal,
            before: false,
            limit: radius + 1
        )
        let hasLater = later.count > radius
        if hasLater { later.removeLast(later.count - radius) }

        let boundedAnchor = boundedWindowRow(anchor, around: locator.match)
        return ConversationWindow(
            projectID: locator.projectID,
            sessionID: locator.sessionID,
            sourceID: locator.sourceID,
            sourceGeneration: locator.sourceGeneration,
            rows: earlier.map { boundedWindowRow($0, around: nil).row }
                + [boundedAnchor.row]
                + later.map { boundedWindowRow($0, around: nil).row },
            anchorRowID: locator.recordID,
            anchorMatch: boundedAnchor.match,
            hasEarlier: hasEarlier,
            hasLater: hasLater,
            isArchived: source.isArchived
        )
    }

    private func conversationRows(
        sourceID: SearchSourceID,
        generation: UInt64,
        relativeToStart start: UInt64,
        ordinal: Int,
        before: Bool,
        limit: Int
    ) throws -> [ConversationWindowRow] {
        let comparison = before
            ? "(start_offset < ? OR (start_offset = ? AND ordinal < ?))"
            : "(start_offset > ? OR (start_offset = ? AND ordinal > ?))"
        let order = before ? "DESC" : "ASC"
        let statement = try database.prepare("""
        SELECT record_id, kind, author, title, body, timestamp,
               start_offset, end_offset, ordinal, has_error
        FROM transcript_search_fts
        WHERE source_id = ? AND source_generation = ? AND \(comparison)
        ORDER BY start_offset \(order), ordinal \(order)
        LIMIT ?
        """)
        defer { statement.finalize() }
        statement.bind(1, sourceID.rawValue)
        statement.bind(2, Int64(generation))
        statement.bind(3, Int64(start))
        statement.bind(4, Int64(start))
        statement.bind(5, ordinal)
        statement.bind(6, limit)
        var rows: [ConversationWindowRow] = []
        while try statement.step() {
            if let row = conversationWindowRow(from: statement) { rows.append(row) }
        }
        return rows
    }

    private func conversationWindowRow(
        from statement: SQLiteDatabase.Statement
    ) -> ConversationWindowRow? {
        guard let recordID = statement.text(0),
              let kindText = statement.text(1),
              let body = statement.text(4)
        else { return nil }
        let author = statement.text(2).flatMap(SearchAuthor.init(rawValue:))
        guard let kind = searchKind(kindText, author: author) else { return nil }
        let timestamp = statement.text(5).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return ConversationWindowRow(
            id: SearchSourceRecordID(rawValue: recordID),
            kind: kind,
            author: author,
            title: statement.text(3) ?? "",
            body: body,
            timestamp: timestamp,
            hasError: statement.int(9) != 0
        )
    }

    /// Keeps a historical landing bounded even when one normalized message reached the search
    /// index's larger ingestion allowance. The anchor is clipped around the exact matched UTF-16
    /// range; neighbouring context keeps its beginning. Ellipses are part of the presented value,
    /// so the returned match is translated to the clipped string rather than left source-relative.
    private func boundedWindowRow(
        _ row: ConversationWindowRow,
        around match: SearchTextRange?
    ) -> (row: ConversationWindowRow, match: SearchTextRange?) {
        guard row.body.utf8.count > Self.maximumWindowRowUTF8Bytes else {
            return (row, match)
        }

        let source = row.body as NSString
        // Four UTF-8 bytes is the largest one UTF-16 code unit can occupy, so this also keeps
        // the byte bound true for emoji and non-Latin scripts rather than only for ASCII.
        let maximumUTF16 = Self.maximumWindowRowUTF8Bytes / 4
        let validMatch: NSRange? = match.flatMap { candidate in
            let range = NSRange(
                location: candidate.utf16Location,
                length: candidate.utf16Length
            )
            guard candidate.isValid, NSMaxRange(range) <= source.length else { return nil }
            return range
        }
        let start: Int
        if let validMatch {
            let leadingContext = maximumUTF16 / 3
            start = min(
                max(validMatch.location - leadingContext, 0),
                max(source.length - maximumUTF16, 0)
            )
        } else {
            start = 0
        }
        let length = min(maximumUTF16, source.length - start)
        let hasPrefix = start > 0
        let hasSuffix = start + length < source.length
        let prefix = hasPrefix ? "…\n" : ""
        let suffix = hasSuffix ? "\n…" : ""
        let body = prefix + source.substring(with: NSRange(location: start, length: length)) + suffix
        let translatedMatch = validMatch.map {
            SearchTextRange(
                utf16Location: (prefix as NSString).length + $0.location - start,
                utf16Length: $0.length
            )
        }
        return (
            ConversationWindowRow(
                id: row.id,
                kind: row.kind,
                author: row.author,
                title: row.title,
                body: body,
                timestamp: row.timestamp,
                hasError: row.hasError
            ),
            translatedMatch
        )
    }

    private func revalidates(
        _ anchor: ConversationWindowRow,
        at url: URL,
        kind: AgentKind,
        startOffset: UInt64,
        endOffset: UInt64
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), endOffset > startOffset else {
            return false
        }
        let byteCount = endOffset - startOffset
        guard byteCount < UInt64(Int.max - JSONLDefaults.chunkBytes) else { return false }
        let normalization = TranscriptReplay.searchRecords(
            at: url,
            kind: kind,
            from: startOffset,
            scanLimit: Int(byteCount) + JSONLDefaults.chunkBytes
        )
        return normalization.records.contains {
            $0.recordID == anchor.id.rawValue
                && $0.kind == anchor.kind
                && $0.author == anchor.author
                && $0.title == anchor.title
                && $0.body == anchor.body
                && $0.hasError == anchor.hasError
        }
    }

    // MARK: Ingestion

    private func reconcile(_ source: TranscriptSearchSource) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
        guard let sizeNumber = attributes[.size] as? NSNumber else { return }
        let fileSize = sizeNumber.uint64Value
        var ledger = try ledgerRow(sourceID: source.sourceID.rawValue)
        var offset = ledger?.indexedOffset ?? 0
        var generation = ledger?.sourceGeneration ?? 1

        let needsRebuild: Bool
        if let ledger {
            let currentSignature = try sourceSignature(
                at: source.url,
                through: min(ledger.indexedOffset, fileSize)
            )
            needsRebuild = ledger.parserVersion != Self.parserVersion
                || fileSize < ledger.indexedOffset
                || currentSignature != ledger.prefixSignature
        } else {
            needsRebuild = false
        }

        if needsRebuild {
            generation &+= 1
            offset = 0
            try database.transaction {
                try deleteIndexedRows(sourceID: source.sourceID.rawValue)
                let deletion = try database.prepare(
                    "DELETE FROM transcript_search_sources WHERE source_id = ?"
                )
                deletion.bind(1, source.sourceID.rawValue)
                try deletion.run()
                try upsertLedger(
                    sourceID: source.sourceID.rawValue,
                    offset: 0,
                    generation: generation,
                    signature: sourceSignature(at: source.url, through: 0),
                    bodyWasTruncated: false
                )
            }
            ledger = nil
        }

        if ledger == nil, offset == 0 {
            try upsertLedger(
                sourceID: source.sourceID.rawValue,
                offset: 0,
                generation: generation,
                signature: sourceSignature(at: source.url, through: 0),
                bodyWasTruncated: false
            )
        }

        var sourceContainsTruncation = false
        while offset < fileSize {
            guard !Task.isCancelled else { return }
            let normalization = TranscriptReplay.searchRecords(
                at: source.url,
                kind: source.kind,
                from: offset,
                scanLimit: Self.ingestionScanBytes
            )
            guard normalization.endOffset > offset else { break }
            let signature = try sourceSignature(at: source.url, through: normalization.endOffset)
            sourceContainsTruncation = sourceContainsTruncation
                || normalization.containsTruncatedBody
            try database.transaction {
                try insert(
                    normalization.records,
                    source: source,
                    sourceGeneration: generation
                )
                try upsertLedger(
                    sourceID: source.sourceID.rawValue,
                    offset: normalization.endOffset,
                    generation: generation,
                    signature: signature,
                    bodyWasTruncated: sourceContainsTruncation
                )
            }
            offset = normalization.endOffset
            containsTruncatedBody = containsTruncatedBody || sourceContainsTruncation
            await Task.yield()
        }

        // Metadata can change without transcript bytes changing. Rewriting bounded rows keeps
        // project/session labels and archive filtering current without rebuilding normalized text.
        try updateMetadata(for: source, sourceGeneration: generation)
    }

    private func insert(
        _ records: [TranscriptSearchNormalizedRecord],
        source: TranscriptSearchSource,
        sourceGeneration: UInt64
    ) throws {
        guard !records.isEmpty else { return }
        let statement = try database.prepare("""
        INSERT INTO transcript_search_fts (
            source_id, record_id, source_generation, project_id, project_name,
            session_id, session_title, provider, archived, kind, author, title, body,
            timestamp, start_offset, end_offset, ordinal, has_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        defer { statement.finalize() }
        for (index, record) in records.enumerated() {
            if index > 0 { try statement.reset() }
            statement.bind(1, source.sourceID.rawValue)
            statement.bind(2, record.recordID)
            statement.bind(3, Int64(sourceGeneration))
            statement.bind(4, source.projectID.uuidString)
            statement.bind(5, source.projectName)
            statement.bind(6, source.sessionID.uuidString)
            statement.bind(7, source.sessionTitle)
            statement.bind(8, source.providerName)
            statement.bind(9, source.isArchived ? 1 : 0)
            statement.bind(10, persistedKind(record.kind))
            statement.bind(11, record.author?.rawValue)
            statement.bind(12, record.title)
            statement.bind(13, record.body)
            statement.bind(14, record.timestamp?.timeIntervalSince1970)
            statement.bind(15, Int64(record.sourceStartOffset))
            statement.bind(16, Int64(record.sourceEndOffset))
            statement.bind(17, record.ordinal)
            statement.bind(18, record.hasError ? 1 : 0)
            _ = try statement.step()
        }
    }

    /// The six metadata values the indexed rows carry, as one comparable string.
    ///
    /// The generation belongs in it because the `UPDATE` below is scoped to one, so metadata
    /// that has already been written into generation 3's rows says nothing about generation 4's.
    /// Unit separators rather than a plain join: a title may contain anything, and two different
    /// pairs of fields must never run together into the same string.
    private func metadataSignature(
        for source: TranscriptSearchSource,
        sourceGeneration: UInt64
    ) -> String {
        [
            source.projectID.uuidString,
            source.projectName,
            source.sessionID.uuidString,
            source.sessionTitle,
            source.providerName,
            source.isArchived ? "1" : "0",
            String(sourceGeneration)
        ].joined(separator: "\u{1f}")
    }

    /// The metadata last written into this source's indexed rows, or nil when it has never been
    /// recorded — which is how a row written before this column existed asks to be rewritten once.
    private func storedMetadataSignature(sourceID: String) throws -> String? {
        let statement = try database.prepare("""
        SELECT metadata_signature FROM transcript_search_sources WHERE source_id = ?
        """)
        defer { statement.finalize() }
        statement.bind(1, sourceID)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    /// Rewrites this source's rows to carry the project and session labels they are filtered and
    /// displayed by — but only when those labels have actually moved since they were last written.
    ///
    /// The guard is the whole point. `transcript_search_fts` is an FTS5 virtual table, so it has
    /// no index on `source_id`: SQLite answers the `WHERE` below with
    /// `SCAN transcript_search_fts VIRTUAL TABLE INDEX 0`, walking every indexed row in the
    /// database, and each row it matches has its tokens deleted and reinserted. Measured against a
    /// real 138 MB index of 82,688 rows across 350 sources, that is 40-90 ms **per source** with a
    /// warm cache and no contention — and `reconcile` used to call it for every source on every
    /// refresh, so a pass in which nothing had changed still cost 15-30 s of CPU and a `pread`
    /// storm. `ProjectsDidChange` restarts a refresh, and an agent renaming a session posts one,
    /// so this ran more or less continuously.
    ///
    /// `transcript_search_sources` is an ordinary table keyed by `source_id`, so the comparison
    /// that avoids all of that is a single primary-key lookup. The scan still happens when a
    /// project or session is genuinely renamed, archived, or rebuilt, which is rare and is the
    /// only time the rows are actually wrong.
    private func updateMetadata(
        for source: TranscriptSearchSource,
        sourceGeneration: UInt64
    ) throws {
        let signature = metadataSignature(for: source, sourceGeneration: sourceGeneration)
        guard try storedMetadataSignature(sourceID: source.sourceID.rawValue) != signature else {
            return
        }

        let statement = try database.prepare("""
        UPDATE transcript_search_fts
        SET project_id = ?, project_name = ?, session_id = ?, session_title = ?,
            provider = ?, archived = ?
        WHERE source_id = ? AND source_generation = ?
        """)
        statement.bind(1, source.projectID.uuidString)
        statement.bind(2, source.projectName)
        statement.bind(3, source.sessionID.uuidString)
        statement.bind(4, source.sessionTitle)
        statement.bind(5, source.providerName)
        statement.bind(6, source.isArchived ? 1 : 0)
        statement.bind(7, source.sourceID.rawValue)
        statement.bind(8, Int64(sourceGeneration))
        try statement.run()
        metadataRewriteCount += 1

        try recordMetadataSignature(signature, sourceID: source.sourceID.rawValue)
    }

    /// Records what the rows now say, so the next refresh can skip them.
    ///
    /// Written after the rewrite, never before: a failure between the two leaves the signature
    /// standing at its old value, and the next pass repeats an idempotent update rather than
    /// believing labels were applied that were not.
    private func recordMetadataSignature(_ signature: String, sourceID: String) throws {
        let statement = try database.prepare("""
        UPDATE transcript_search_sources SET metadata_signature = ? WHERE source_id = ?
        """)
        statement.bind(1, signature)
        statement.bind(2, sourceID)
        try statement.run()
    }

    private func ledgerRow(sourceID: String) throws -> LedgerRow? {
        let statement = try database.prepare("""
        SELECT indexed_offset, source_generation, prefix_signature, parser_version
        FROM transcript_search_sources WHERE source_id = ?
        """)
        defer { statement.finalize() }
        statement.bind(1, sourceID)
        guard try statement.step(), let signature = statement.text(2) else { return nil }
        let storedOffset = statement.int(0)
        let storedGeneration = statement.int(1)
        guard storedOffset >= 0, storedGeneration >= 0 else { return nil }
        return LedgerRow(
            indexedOffset: UInt64(storedOffset),
            sourceGeneration: UInt64(storedGeneration),
            prefixSignature: signature,
            parserVersion: statement.int(3)
        )
    }

    private func upsertLedger(
        sourceID: String,
        offset: UInt64,
        generation: UInt64,
        signature: String,
        bodyWasTruncated: Bool
    ) throws {
        let statement = try database.prepare("""
        INSERT INTO transcript_search_sources (
            source_id, indexed_offset, source_generation, prefix_signature,
            parser_version, body_was_truncated
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
            indexed_offset = excluded.indexed_offset,
            source_generation = excluded.source_generation,
            prefix_signature = excluded.prefix_signature,
            parser_version = excluded.parser_version,
            body_was_truncated = body_was_truncated OR excluded.body_was_truncated
        """)
        statement.bind(1, sourceID)
        statement.bind(2, Int64(offset))
        statement.bind(3, Int64(generation))
        statement.bind(4, signature)
        statement.bind(5, Self.parserVersion)
        statement.bind(6, bodyWasTruncated ? 1 : 0)
        try statement.run()
    }

    private func deleteSourcesAbsent(from retained: Set<String>) throws {
        let statement = try database.prepare("SELECT source_id FROM transcript_search_sources")
        defer { statement.finalize() }
        var removed: [String] = []
        while try statement.step() {
            if let sourceID = statement.text(0), !retained.contains(sourceID) {
                removed.append(sourceID)
            }
        }
        for sourceID in removed {
            try database.transaction {
                try deleteIndexedRows(sourceID: sourceID)
                let deletion = try database.prepare(
                    "DELETE FROM transcript_search_sources WHERE source_id = ?"
                )
                deletion.bind(1, sourceID)
                try deletion.run()
            }
        }
    }

    private func deleteIndexedRows(sourceID: String) throws {
        let statement = try database.prepare(
            "DELETE FROM transcript_search_fts WHERE source_id = ?"
        )
        statement.bind(1, sourceID)
        try statement.run()
    }

    private func persistedTruncationState() throws -> Bool {
        let statement = try database.prepare("""
        SELECT 1 FROM transcript_search_sources WHERE body_was_truncated = 1 LIMIT 1
        """)
        defer { statement.finalize() }
        return try statement.step()
    }

    /// Fingerprints the already-indexed prefix only. Growth therefore appends, while a rewrite or
    /// truncation invalidates the ledger even when a filesystem timestamp is coarse or preserved.
    private func sourceSignature(at url: URL, through offset: UInt64) throws -> String {
        guard offset > 0 else { return "0" }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let sampleBytes: UInt64 = 16 * 1024
        var hash: UInt64 = 14_695_981_039_346_656_037

        func fold(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        try file.seek(toOffset: 0)
        if let head = try file.read(upToCount: Int(min(offset, sampleBytes))) { fold(head) }
        if offset > sampleBytes {
            let tailStart = offset > sampleBytes ? offset - sampleBytes : 0
            try file.seek(toOffset: tailStart)
            if let tail = try file.read(upToCount: Int(sampleBytes)) { fold(tail) }
        }
        hash ^= offset
        hash &*= 1_099_511_628_211
        return String(hash, radix: 16)
    }

    // MARK: Query

    private func querySQL(for query: SearchQuery) -> (sql: String, bindings: [Binding]) {
        var clauses = ["transcript_search_fts MATCH ?"]
        var bindings: [Binding] = [.text(ftsExpression(query.expression))]

        func add(_ clause: String, _ binding: Binding? = nil) {
            clauses.append(clause)
            if let binding { bindings.append(binding) }
        }

        switch query.scope {
        case .everywhere:
            break
        case let .project(projectID):
            add("project_id = ?", .text(projectID.uuidString))
        case let .view(.conversation(_, sessionID)):
            add("session_id = ?", .text(sessionID.uuidString))
        case .view:
            add("0")
        }

        for filter in query.expression.filters {
            let negation = filter.isExcluded ? "NOT " : ""
            switch filter.predicate {
            case .kind(.conversation):
                add("\(negation)(kind = 'message' OR kind = 'tool')")
            case .kind:
                add(filter.isExcluded ? "1" : "0")
            case let .author(author):
                add("\(negation)(author = ?)", .text(author.rawValue))
            case let .project(value):
                add("\(negation)(project_name LIKE ? ESCAPE '\\')", .text(like(value)))
            case let .provider(value):
                add("\(negation)(provider LIKE ? ESCAPE '\\')", .text(like(value)))
            case .archived:
                add("\(negation)(archived = 1)")
            case .error:
                add("\(negation)(has_error = 1)")
            case let .before(date):
                add("\(negation)(timestamp < ?)", .double(date.timeIntervalSince1970))
            case let .after(date):
                add("\(negation)(timestamp > ?)", .double(date.timeIntervalSince1970))
            }
        }

        bindings.append(.integer(Self.maximumQueryRows))
        return (
            """
            SELECT source_id, record_id, source_generation, project_id, project_name,
                   session_id, session_title, provider, archived, kind, author, title,
                   snippet(transcript_search_fts, 12, '\u{f0000}', '\u{f0001}', ' … ', 24),
                   timestamp, start_offset, end_offset, ordinal, has_error, body
            FROM transcript_search_fts
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY bm25(transcript_search_fts), timestamp DESC
            LIMIT ?
            """,
            bindings
        )
    }

    private func hit(
        from statement: SQLiteDatabase.Statement,
        query: SearchQuery
    ) -> SearchHit? {
        guard let sourceID = statement.text(0),
              let recordID = statement.text(1),
              let projectIDText = statement.text(3),
              let projectID = ProjectID(uuidString: projectIDText),
              let projectName = statement.text(4),
              let sessionIDText = statement.text(5),
              let sessionID = SessionID(uuidString: sessionIDText),
              let sessionTitle = statement.text(6),
              let provider = statement.text(7),
              let kindText = statement.text(9),
              let snippetText = statement.text(12)
        else { return nil }

        let sourceGeneration = UInt64(statement.int(2))
        let author = statement.text(10).flatMap(SearchAuthor.init(rawValue:))
        guard let kind = searchKind(kindText, author: author) else { return nil }
        let toolTitle = statement.text(11) ?? ""
        let timestamp = statement.text(13).flatMap(Double.init).map {
            Date(timeIntervalSince1970: $0)
        }
        let snippet = markedSnippet(snippetText)
        let body = statement.text(18) ?? ""
        let normalizedSession = normalized(sessionTitle)
        let normalizedTool = normalized(toolTitle)
        let terms = query.expression.positiveTerms.map { normalized($0.text) }
        let tier: SearchScoreTier
        if terms.contains(normalizedSession) || (!normalizedTool.isEmpty && terms.contains(normalizedTool)) {
            tier = .exactMetadata
        } else if terms.contains(where: normalizedSession.hasPrefix)
            || (!normalizedTool.isEmpty && terms.contains(where: normalizedTool.hasPrefix))
        {
            tier = .metadataPrefix
        } else {
            tier = .literalText
        }
        let hitID = SearchHitID(
            rawValue: "transcript:\(sourceID):\(recordID):\(sourceGeneration)"
        )
        return SearchHit(
            id: hitID,
            provider: .transcript,
            kind: kind,
            title: sessionTitle,
            snippet: snippet,
            provenance: SearchProvenance(
                projectID: projectID,
                projectName: projectName,
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                provider: provider,
                author: author,
                timestamp: timestamp,
                isArchived: statement.int(8) != 0
            ),
            stableOrder: SearchStableOrder(
                group: .conversations,
                scoreTier: tier,
                recency: timestamp,
                title: sessionTitle,
                stableID: hitID
            ),
            locator: .conversation(SearchConversationLocator(
                projectID: projectID,
                sessionID: sessionID,
                sourceID: SearchSourceID(rawValue: sourceID),
                recordID: SearchSourceRecordID(rawValue: recordID),
                sourceGeneration: sourceGeneration,
                match: firstBodyMatch(in: body, query: query)
            ))
        )
    }

    private func firstBodyMatch(in body: String, query: SearchQuery) -> SearchTextRange? {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let source = body as NSString
        var earliest: NSRange?
        for term in query.expression.positiveTerms {
            let range = source.range(
                of: term.text,
                options: options,
                range: NSRange(location: 0, length: source.length)
            )
            guard range.location != NSNotFound else { continue }
            if earliest == nil || range.location < earliest!.location { earliest = range }
        }
        guard let earliest else { return nil }
        return SearchTextRange(
            utf16Location: earliest.location,
            utf16Length: earliest.length
        )
    }

    private func coverage() -> SearchCoverage {
        switch refreshState {
        case let .indexing(indexed, total):
            return .indexing(indexed: indexed, total: total)
        case .idle where unavailableSourceCount > 0:
            return .partial(reason: L10n.string(
                "Some conversation history is unavailable."
            ))
        case .idle where containsTruncatedBody:
            return .partial(reason: L10n.string(
                "Some long conversation entries were shortened for search."
            ))
        case .idle:
            return .complete
        }
    }

    private func scopePermitsTranscript(_ scope: SearchScope) -> Bool {
        switch scope {
        case .everywhere, .project, .view(.conversation): return true
        case .view: return false
        }
    }

    private func filtersPermitTranscript(_ filters: [SearchFilter]) -> Bool {
        filters.allSatisfy { filter in
            guard case let .kind(kind) = filter.predicate else { return true }
            let matches = kind == .conversation
            return filter.isExcluded ? !matches : matches
        }
    }

    private func ftsExpression(_ expression: SearchExpression) -> String {
        let positive = expression.positiveTerms.map(ftsAtom)
        let excluded = expression.excludedTerms.map(ftsAtom)
        return positive.joined(separator: " AND ")
            + excluded.map { " NOT \($0)" }.joined()
    }

    private func ftsAtom(_ term: SearchTextTerm) -> String {
        let escaped = term.text.replacingOccurrences(of: "\"", with: "\"\"")
        switch term.match {
        case .phrase: return "\"\(escaped)\""
        case .token: return "\"\(escaped)\"*"
        }
    }

    private func like(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func markedSnippet(_ marked: String) -> SearchSnippet {
        let opening = "\u{f0000}"
        let closing = "\u{f0001}"
        var remainder = marked[...]
        var text = ""
        var matches: [SearchTextRange] = []
        while let start = remainder.range(of: opening) {
            text += remainder[..<start.lowerBound]
            remainder = remainder[start.upperBound...]
            guard let end = remainder.range(of: closing) else {
                text += opening
                break
            }
            let value = String(remainder[..<end.lowerBound])
            let location = (text as NSString).length
            text += value
            matches.append(SearchTextRange(
                utf16Location: location,
                utf16Length: (value as NSString).length
            ))
            remainder = remainder[end.upperBound...]
        }
        text += remainder
        return SearchSnippet(text: text, matches: matches)
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private func persistedKind(_ kind: SearchHitKind) -> String {
        switch kind {
        case .conversationMessage: return "message"
        case .toolSummary: return "tool"
        default: return "unknown"
        }
    }

    private func searchKind(_ value: String, author: SearchAuthor?) -> SearchHitKind? {
        switch value {
        case "message": return .conversationMessage(author ?? .system)
        case "tool": return .toolSummary
        default: return nil
        }
    }
}
