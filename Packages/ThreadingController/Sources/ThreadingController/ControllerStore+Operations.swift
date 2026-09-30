import Foundation

extension ControllerStore {
    public func question(_ id: QuestionID) throws -> WorkQuestion { try required("question", id.description) }
    public func workDeliveries(workID: WorkID, after: Int64 = 0, limit: Int = 8) throws -> ControllerPage<WorkDelivery> {
        try page("delivery", parent: workID.description, after: after, limit: limit)
    }
    /// Owner projection. The authenticated adapter must authorize the worker before returning
    /// questions; recipients constrain who may answer, not visibility of this owner API.
    public func openQuestions(workerID: WorkerID, after: Int64 = 0, limit: Int = 8) throws -> ControllerPage<WorkQuestion> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record INDEXED BY record_scope_state
            WHERE kind='question' AND scope=? AND state='open' AND sequence>?
            ORDER BY sequence LIMIT ?
            """, [.text(workerID.description), .integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }

    /// Cursor bounds unresolved work examined, including unsupported destinations. Consumers
    /// advance past failures and wrap only after an empty page; closed history is never scanned.
    public func pendingDeliveries(after: Int64 = 0, limit: Int = 8) throws -> ControllerPage<WorkDelivery> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record INDEXED BY unresolved_delivery
            WHERE kind='delivery' AND state IN ('pending','sending','uncertain') AND sequence>?
            ORDER BY sequence LIMIT ?
            """, [.integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }
}
