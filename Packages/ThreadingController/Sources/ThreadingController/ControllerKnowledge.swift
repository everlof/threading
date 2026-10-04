import Foundation

public enum KnowledgeSpaceTag: Sendable {}
public typealias KnowledgeSpaceID = ControllerID<KnowledgeSpaceTag>
public enum KnowledgeAccess: String, Codable, Sendable { case none, read, write }
public struct KnowledgeGrant: Codable, Equatable, Sendable {
    public let spaceID: KnowledgeSpaceID
    public let workerID: WorkerID
    public let revision: Int
    public let access: KnowledgeAccess
}
public struct KnowledgeEntry: Codable, Equatable, Sendable {
    public let spaceID: KnowledgeSpaceID
    public let key: String
    public let revision: Int
    public let content: String
    public let executionID: ExecutionID?
    /// Nil on legacy rows, which are active. Shares memory's tombstone states.
    public var state: MemoryEntryState? = nil
    public var provenance: ControllerProvenance? = nil
}

extension ControllerStore {
    /// Owner-only grants. A space is an opaque identity; creating/revoking a grant is separate
    /// from agent-authored content. Current grants are checked in the same transaction as use.
    public func grantKnowledge(spaceID: KnowledgeSpaceID, workerID: WorkerID,
                               expectedRevision: Int, access: KnowledgeAccess) throws -> KnowledgeGrant {
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            let id = "\(spaceID)/\(workerID)"
            let prior: KnowledgeGrant? = try optional("knowledgeGrant", id)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let grant = KnowledgeGrant(spaceID: spaceID, workerID: workerID, revision: expectedRevision + 1, access: access)
            if prior == nil { try insert("knowledgeGrant", id, parent: workerID.description, key: spaceID.description, value: grant) }
            else { try update("knowledgeGrant", id, value: grant) }
            try event("knowledge.granted", id)
            return grant
        }
    }
    public func knowledge(spaceID: KnowledgeSpaceID, key: String) throws -> KnowledgeEntry? {
        try Limits.text(key, field: "key", maximum: 256)
        return try optional("knowledge", "\(spaceID)/\(key)")
    }
    public func knowledgeHistory(spaceID: KnowledgeSpaceID, key: String, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<KnowledgeEntry> {
        try Limits.text(key, field: "key", maximum: 256)
        return try page("knowledgeRevision", parent: "\(spaceID)/\(key)", after: after, limit: limit)
    }
    /// Owner write. Agent writes below carry their actual execution provenance instead.
    public func putKnowledge(spaceID: KnowledgeSpaceID, key: String, expectedRevision: Int, content: String) throws -> KnowledgeEntry {
        try saveKnowledge(spaceID: spaceID, key: key, expectedRevision: expectedRevision, content: content, executionID: nil)
    }
    func requireKnowledgeAccess(spaceID: KnowledgeSpaceID, workerID: WorkerID, writing: Bool) throws {
        let grant: KnowledgeGrant? = try optional("knowledgeGrant", "\(spaceID)/\(workerID)")
        guard let grant, grant.access == .write || (!writing && grant.access == .read) else { throw ControllerError.forbidden }
    }
    func saveKnowledge(spaceID: KnowledgeSpaceID, key: String, expectedRevision: Int,
                       content: String, executionID: ExecutionID?) throws -> KnowledgeEntry {
        try Limits.text(key, field: "key", maximum: 256)
        try Limits.text(content, field: "knowledge")
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let id = "\(spaceID)/\(key)"
            let prior = try knowledge(spaceID: spaceID, key: key)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let active = prior.map { ($0.state ?? .active) == .active } ?? false
            try spendContent(knowledgeUsageScope(spaceID), keys: active ? 0 : 1,
                             bytes: content.utf8.count - (active ? prior?.content.utf8.count ?? 0 : 0))
            let value = KnowledgeEntry(spaceID: spaceID, key: key, revision: expectedRevision + 1, content: content,
                                       executionID: executionID, state: .active,
                                       provenance: executionID.map(ControllerProvenance.agent) ?? .owner())
            if prior == nil { try insert("knowledge", id, parent: spaceID.description, key: key, value: value) }
            else { try update("knowledge", id, value: value) }
            try insert("knowledgeRevision", "\(id)/\(value.revision)", parent: id, value: value)
            try event("knowledge.updated", id)
            return value
        }
    }
    /// Owner erasure of shared context, with the same contract as `forgetMemory`.
    public func forgetKnowledge(spaceID: KnowledgeSpaceID, key: String) throws -> KnowledgeEntry {
        try Limits.text(key, field: "key", maximum: 256)
        let id = "\(spaceID)/\(key)"
        return try erasing {
            try db.transaction {
                guard let prior = try knowledge(spaceID: spaceID, key: key) else { throw ControllerError.notFound }
                if prior.state == .forgotten { return prior }
                if (prior.state ?? .active) == .active {
                    try spendContent(knowledgeUsageScope(spaceID), keys: -1, bytes: -prior.content.utf8.count)
                }
                try eraseRevisionBodies(kind: "knowledgeRevision", parent: id)
                let tombstone = KnowledgeEntry(spaceID: spaceID, key: key, revision: prior.revision + 1, content: "",
                                               executionID: nil, state: .forgotten, provenance: .owner())
                try update("knowledge", id, state: MemoryEntryState.forgotten.rawValue, value: tombstone)
                try insert("knowledgeRevision", "\(id)/\(tombstone.revision)", parent: id, value: tombstone)
                try event("knowledge.forgotten", id)
                return tombstone
            }
        }
    }
    func knowledgeUsageScope(_ spaceID: KnowledgeSpaceID) -> ContentScope {
        ContentScope(usageKind: "knowledgeUsage", id: spaceID.description, entryKind: "knowledge",
                     maximumKeys: ContentQuota.knowledgeKeysPerSpace, maximumBytes: ContentQuota.knowledgeBytesPerSpace)
    }
}
