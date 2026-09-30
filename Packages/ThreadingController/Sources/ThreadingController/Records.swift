import Foundation

public struct ControllerID<Tag>: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ value: UUID = UUID()) { rawValue = value }
    public init(_ text: String) throws {
        guard let value = UUID(uuidString: text) else { throw ControllerError.invalidInput("identifier") }
        rawValue = value
    }
    public var description: String { rawValue.uuidString.lowercased() }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
public enum WorkerTag: Sendable {}
public enum WorkTag: Sendable {}
public enum ExecutionTag: Sendable {}
public enum QuestionTag: Sendable {}
public enum DeliveryTag: Sendable {}
public enum AttemptTag: Sendable {}
public typealias WorkerID = ControllerID<WorkerTag>
public typealias WorkID = ControllerID<WorkTag>
public typealias ExecutionID = ControllerID<ExecutionTag>
public typealias QuestionID = ControllerID<QuestionTag>
public typealias DeliveryID = ControllerID<DeliveryTag>
public typealias DeliveryAttemptID = ControllerID<AttemptTag>

public enum ControllerError: Error, Equatable, CustomStringConvertible {
    case invalidInput(String), notFound, conflict, forbidden, unsupportedSchema
    case storage(Int32)
    public var description: String {
        switch self {
        case .invalidInput(let field): return "invalid_input: \(field)"
        case .notFound: return "not_found"
        case .conflict: return "conflict"
        case .forbidden: return "forbidden"
        case .unsupportedSchema: return "unsupported_schema"
        case .storage(let code): return "storage_error: \(code)"
        }
    }
}

public struct ControllerWorker: Codable, Equatable, Sendable {
    public let id: WorkerID
    public let name: String
}
public enum WorkState: String, Codable, Sendable { case queued, running, waiting, completed, interrupted }
public struct WorkItem: Codable, Equatable, Sendable {
    public let id: WorkID
    public let workerID: WorkerID
    public let key: String
    public let instruction: String
    public internal(set) var state: WorkState
    public internal(set) var checkpoint: String
    public internal(set) var executionID: ExecutionID?
}
public enum ExecutionState: String, Codable, Sendable { case running, yielded, completed, interrupted }
public struct ControllerExecution: Codable, Equatable, Sendable {
    public let id: ExecutionID
    public let workID: WorkID
    public internal(set) var state: ExecutionState
}
public struct WorkClaim: Codable, Equatable, Sendable {
    public let work: WorkItem
    public let execution: ControllerExecution
}

/// Recipient strings are namespaced identities (person:…, group:…). They never confer authority.
public struct WorkQuestion: Codable, Equatable, Sendable {
    public let id: QuestionID
    public let workID: WorkID
    public let executionID: ExecutionID
    public let recipients: [String]
    public let text: String
    public let checkpoint: String
    public internal(set) var answer: String?
    public internal(set) var answeredBy: String?
}

/// Constructed by a trusted authentication adapter, never decoded from an agent request.
/// The owner-only CLI can attest an answer on someone's behalf. This is not a network login.
public struct AnswerPrincipal: Sendable {
    public let person: String
    public let groups: Set<String>
    public init(person: String, groups: Set<String> = []) throws {
        try Limits.recipient(person, prefix: "person:")
        guard groups.count <= 32 else { throw ControllerError.invalidInput("groups") }
        for group in groups { try Limits.recipient(group, prefix: "group:") }
        self.person = person
        self.groups = groups
    }
}

public enum DeliveryState: String, Codable, Sendable { case pending, sending, delivered, uncertain }
public struct WorkDelivery: Codable, Equatable, Sendable {
    public let id: DeliveryID
    public let workID: WorkID
    public let destination: String
    public let payload: String
    public internal(set) var state: DeliveryState
    public internal(set) var attemptID: DeliveryAttemptID?
    public internal(set) var receipt: String?
}
public struct WorkerMemory: Codable, Equatable, Sendable {
    public let workerID: WorkerID
    public let key: String
    public let revision: Int
    public let content: String
}
public struct ControllerEvent: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let kind: String
    public let subject: String
    public let at: String
}
public struct ControllerPage<T: Codable & Sendable>: Codable, Sendable {
    public let items: [T]
    /// Pass this cursor back even when this page is empty. Rows are never deleted in this slice.
    public let next: Int64
}

enum Limits {
    static func text(_ value: String, field: String, maximum: Int = 32_768, empty: Bool = false) throws {
        guard (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              value.utf8.count <= maximum, !value.contains("\0") else {
            throw ControllerError.invalidInput(field)
        }
    }
    static func recipient(_ value: String, prefix: String? = nil) throws {
        try text(value, field: "recipient", maximum: 256)
        let accepted = prefix.map { value.hasPrefix($0) } ??
            (value.hasPrefix("person:") || value.hasPrefix("group:"))
        guard accepted, let colon = value.firstIndex(of: ":"),
              value.index(after: colon) < value.endIndex,
              !value.contains(where: { $0.isWhitespace }) else {
            throw ControllerError.invalidInput("recipient")
        }
    }
    static func page(_ after: Int64, _ limit: Int) throws {
        guard after >= 0, (1...100).contains(limit) else { throw ControllerError.invalidInput("page") }
    }
}
