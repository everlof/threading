import Foundation

public struct AgentIdentity: Codable, Equatable, Sendable {
    public let authorityID: HostID
    public let agentID: WorkerID
}

public struct WorkerMemoryKey: Codable, Equatable, Sendable {
    public let key: String
    public let revision: Int
}

/// Per-owner ceilings on stored text. They bound what new writes may add; an entry over them
/// stays readable, and a write that shrinks usage is always accepted.
public enum ContentQuota {
    public static let memoryKeysPerWorker = 1_000
    public static let memoryBytesPerWorker = 4_194_304
    public static let knowledgeKeysPerSpace = 1_000
    public static let knowledgeBytesPerSpace = 4_194_304
}

/// Active keys and body bytes for one worker's memory or one knowledge space, maintained in the
/// same transaction as every write so a quota check reads one row.
struct ContentUsage: Codable, Equatable {
    var keys: Int
    var bytes: Int
}

extension ControllerStore {
    public func agentIdentity(_ worker: WorkerID) throws -> AgentIdentity {
        let _: ControllerWorker = try required("worker", worker.description)
        return AgentIdentity(authorityID: try host().id, agentID: worker)
    }
    /// Read keys before loading content: bounded startup context regardless of memory size.
    /// Lists active entries only; tombstones keep their own state value out of the scanned range,
    /// so deleted keys never make a page sparse.
    public func memoryKeys(workerID: WorkerID, after: Int64 = 0, limit: Int = 20) throws -> ControllerPage<WorkerMemoryKey> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,key,json_extract(payload,'$.revision') FROM record INDEXED BY record_ready
            WHERE kind='memory' AND parent=? AND state IS NULL AND sequence>? ORDER BY sequence LIMIT ?
            """, [.text(workerID.description), .integer(after), .integer(Int64(limit))])
        return ControllerPage(items: try rows.map { WorkerMemoryKey(key: try $0.text(1), revision: Int($0.integers[2])) },
                              next: rows.last?.integers[0] ?? after)
    }

    /// Memory belongs to a stable worker, not the last provider session that happened to run it.
    /// A deleted or forgotten key returns its content-free tombstone and revision.
    public func memory(workerID: WorkerID, key: String) throws -> WorkerMemory? {
        try Limits.text(key, field: "key", maximum: 256)
        return try optional("memory", memoryID(workerID, key))
    }
    /// Owner write.
    public func putMemory(workerID: WorkerID, key: String, expectedRevision: Int, content: String) throws -> WorkerMemory {
        try putMemory(workerID: workerID, key: key, expectedRevision: expectedRevision, content: content, provenance: .owner())
    }
    /// Owner tombstone: hides the entry and keeps its reviewable history.
    public func deleteMemory(workerID: WorkerID, key: String, expectedRevision: Int) throws -> WorkerMemory {
        try deleteMemory(workerID: workerID, key: key, expectedRevision: expectedRevision, provenance: .owner())
    }

    func putMemory(workerID: WorkerID, key: String, expectedRevision: Int, content: String,
                   provenance: ControllerProvenance) throws -> WorkerMemory {
        try Limits.text(key, field: "key", maximum: 256)
        try Limits.text(content, field: "memory")
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            let id = memoryID(workerID, key)
            let prior: WorkerMemory? = try optional("memory", id)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let active = prior.map { ($0.state ?? .active) == .active } ?? false
            try spendContent(memoryUsageScope(workerID), keys: active ? 0 : 1,
                             bytes: content.utf8.count - (active ? prior?.content.utf8.count ?? 0 : 0))
            let memory = WorkerMemory(workerID: workerID, key: key, revision: expectedRevision + 1, content: content,
                                      state: .active, provenance: provenance)
            if prior == nil { try insert("memory", id, parent: workerID.description, key: key, value: memory) }
            else { try update("memory", id, value: memory) }
            try insert("memoryRevision", "\(id)/\(memory.revision)", parent: id, value: memory)
            try event("memory.updated", id)
            return memory
        }
    }
    func deleteMemory(workerID: WorkerID, key: String, expectedRevision: Int,
                      provenance: ControllerProvenance) throws -> WorkerMemory {
        try Limits.text(key, field: "key", maximum: 256)
        return try db.transaction {
            let id = memoryID(workerID, key)
            let prior: WorkerMemory = try required("memory", id)
            guard prior.revision == expectedRevision, expectedRevision < Int.max else { throw ControllerError.conflict }
            // Repeating a delete returns the tombstone it already wrote.
            guard (prior.state ?? .active) == .active else { return prior }
            try spendContent(memoryUsageScope(workerID), keys: -1, bytes: -prior.content.utf8.count)
            let tombstone = WorkerMemory(workerID: workerID, key: key, revision: prior.revision + 1, content: "",
                                         state: .deleted, provenance: provenance)
            try update("memory", id, state: MemoryEntryState.deleted.rawValue, value: tombstone)
            try insert("memoryRevision", "\(id)/\(tombstone.revision)", parent: id, value: tombstone)
            try event("memory.deleted", id)
            return tombstone
        }
    }
    /// Owner erasure: removes the body from the current entry and from every stored revision,
    /// leaving a content-free tombstone whose revision a delayed write at zero cannot reuse.
    /// Freed pages are zeroed and the WAL is checkpointed, so the text is gone from the live
    /// database files; earlier backups and provider transcripts are outside this store.
    public func forgetMemory(workerID: WorkerID, key: String) throws -> WorkerMemory {
        try Limits.text(key, field: "key", maximum: 256)
        let id = memoryID(workerID, key)
        return try erasing {
            try db.transaction {
                let prior: WorkerMemory = try required("memory", id)
                if prior.state == .forgotten { return prior }
                if (prior.state ?? .active) == .active {
                    try spendContent(memoryUsageScope(workerID), keys: -1, bytes: -prior.content.utf8.count)
                }
                try eraseRevisionBodies(kind: "memoryRevision", parent: id)
                let tombstone = WorkerMemory(workerID: workerID, key: key, revision: prior.revision + 1, content: "",
                                             state: .forgotten, provenance: .owner())
                try update("memory", id, state: MemoryEntryState.forgotten.rawValue, value: tombstone)
                try insert("memoryRevision", "\(id)/\(tombstone.revision)", parent: id, value: tombstone)
                try event("memory.forgotten", id)
                return tombstone
            }
        }
    }
    public func memoryHistory(workerID: WorkerID, key: String, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkerMemory> {
        try Limits.text(key, field: "key", maximum: 256)
        return try page("memoryRevision", parent: memoryID(workerID, key), after: after, limit: limit)
    }
    func memoryID(_ workerID: WorkerID, _ key: String) -> String { "\(workerID)/\(key)" }

    // MARK: - Shared content bookkeeping (memory and knowledge)

    struct ContentScope {
        let usageKind: String
        let id: String
        let entryKind: String
        let maximumKeys: Int
        let maximumBytes: Int
    }
    func memoryUsageScope(_ workerID: WorkerID) -> ContentScope {
        ContentScope(usageKind: "memoryUsage", id: workerID.description, entryKind: "memory",
                     maximumKeys: ContentQuota.memoryKeysPerWorker, maximumBytes: ContentQuota.memoryBytesPerWorker)
    }
    /// Applies a change in active keys/bytes, refusing one that grows usage past a quota.
    func spendContent(_ scope: ContentScope, keys: Int, bytes: Int) throws {
        let stored: ContentUsage? = try optional(scope.usageKind, scope.id)
        let prior = try stored ?? legacyUsage(scope)
        let next = ContentUsage(keys: max(0, prior.keys + keys), bytes: max(0, prior.bytes + bytes))
        if keys > 0, next.keys > scope.maximumKeys { throw ControllerError.invalidInput("\(scope.entryKind)_key_quota") }
        if bytes > 0, next.bytes > scope.maximumBytes { throw ControllerError.invalidInput("\(scope.entryKind)_byte_quota") }
        if stored == nil { try insert(scope.usageKind, scope.id, value: next) }
        else { try update(scope.usageKind, scope.id, value: next) }
    }
    /// Entries written before usage was tracked are counted once, then maintained incrementally.
    private func legacyUsage(_ scope: ContentScope) throws -> ContentUsage {
        let row = try db.rows("""
            SELECT COUNT(*), COALESCE(SUM(length(CAST(json_extract(payload,'$.content') AS BLOB))),0)
            FROM record INDEXED BY record_ready WHERE kind=? AND parent=? AND state IS NULL
            """, [.text(scope.entryKind), .text(scope.id)]).first
        return ContentUsage(keys: Int(row?.integers[0] ?? 0), bytes: Int(row?.integers[1] ?? 0))
    }
    /// Blanks the body of every stored revision of one entry and marks it forgotten. One
    /// statement over that entry's revisions, read through the parent index.
    func eraseRevisionBodies(kind: String, parent: String) throws {
        try db.run("""
            UPDATE record SET payload=json_set(payload,'$.content','','$.state','forgotten')
            WHERE kind=? AND parent=?
            """, [.text(kind), .text(parent)])
    }
    /// Runs an erasing mutation with SQLite's full secure delete (freed pages too, not only the
    /// in-page cells the connection's default `FAST` mode zeroes), then checkpoints the WAL so
    /// erased page images do not linger in it. A checkpoint blocked by a concurrent reader
    /// leaves the remainder to SQLite's next automatic checkpoint.
    func erasing<T>(_ body: () throws -> T) throws -> T {
        try db.run("PRAGMA secure_delete=ON")
        defer { _ = try? db.run("PRAGMA secure_delete=FAST") }
        let result = try body()
        _ = try? db.rows("PRAGMA wal_checkpoint(TRUNCATE)")
        return result
    }
}
