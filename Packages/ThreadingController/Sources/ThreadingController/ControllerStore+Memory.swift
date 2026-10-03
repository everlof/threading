import Foundation

public struct AgentIdentity: Codable, Equatable, Sendable {
    public let authorityID: HostID
    public let agentID: WorkerID
}

public struct WorkerMemoryKey: Codable, Equatable, Sendable {
    public let key: String
    public let revision: Int
}

extension ControllerStore {
    public func agentIdentity(_ worker: WorkerID) throws -> AgentIdentity {
        let _: ControllerWorker = try required("worker", worker.description)
        return AgentIdentity(authorityID: try host().id, agentID: worker)
    }
    /// Read keys before loading content: bounded startup context regardless of memory size.
    public func memoryKeys(workerID: WorkerID, after: Int64 = 0, limit: Int = 20) throws -> ControllerPage<WorkerMemoryKey> {
        try Limits.page(after, limit)
        let rows = try db.rows("SELECT sequence,key,json_extract(payload,'$.revision') FROM record WHERE kind='memory' AND parent=? AND sequence>? ORDER BY sequence LIMIT ?",
                               [.text(workerID.description), .integer(after), .integer(Int64(limit))])
        return ControllerPage(items: try rows.map { WorkerMemoryKey(key: try $0.text(1), revision: Int($0.integers[2])) },
                              next: rows.last?.integers[0] ?? after)
    }

    /// Memory belongs to a stable worker, not the last provider session that happened to run it.
    public func memory(workerID: WorkerID, key: String) throws -> WorkerMemory? {
        try Limits.text(key, field: "key", maximum: 256)
        return try optional("memory", memoryID(workerID, key))
    }
    public func putMemory(workerID: WorkerID, key: String, expectedRevision: Int, content: String) throws -> WorkerMemory {
        try Limits.text(key, field: "key", maximum: 256)
        try Limits.text(content, field: "memory")
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            let id = memoryID(workerID, key)
            let prior: WorkerMemory? = try optional("memory", id)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let memory = WorkerMemory(workerID: workerID, key: key, revision: expectedRevision + 1, content: content)
            if prior == nil { try insert("memory", id, parent: workerID.description, key: key, value: memory) }
            else { try update("memory", id, value: memory) }
            try insert("memoryRevision", "\(id)/\(memory.revision)", parent: id, value: memory)
            try event("memory.updated", id)
            return memory
        }
    }
    public func memoryHistory(workerID: WorkerID, key: String, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<WorkerMemory> {
        try Limits.text(key, field: "key", maximum: 256)
        return try page("memoryRevision", parent: memoryID(workerID, key), after: after, limit: limit)
    }
    func memoryID(_ workerID: WorkerID, _ key: String) -> String { "\(workerID)/\(key)" }
}
