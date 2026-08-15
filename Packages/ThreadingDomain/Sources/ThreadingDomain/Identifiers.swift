import Foundation

/// A lossless persisted identifier is not automatically a safe child of a filesystem URL.
/// Stores use this one rule at their boundary instead of each inventing a partial slash check.
public enum StoredPathComponent {
    public static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 255
            && (value as NSString).lastPathComponent == value
            && !value.contains("\0")
    }
}

/// A project's stable identity.
///
/// The custom `Codable` implementation deliberately encodes the wrapped UUID as a single
/// value, preserving the JSON shape used before project and session identifiers had distinct
/// Swift types.
public struct ProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A session's stable identity, intentionally incompatible with `ProjectID` at compile time.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A standalone project's terminal identity, intentionally separate from chat sessions.
public struct TerminalID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    public var uuidString: String { rawValue.uuidString }
    public var description: String { uuidString }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The semantic owner of one live terminal process.
///
/// A project terminal and an agent session may both happen to use UUIDs, but that does not put
/// them in the same identity domain. Keeping the variants distinct prevents terminal-only code
/// from manufacturing a `SessionID` merely to reuse history or interaction APIs.
public enum TerminalInstanceIdentity: Hashable, Sendable {
    case agentSession(SessionID)
    case projectTerminal(TerminalID)
    case sessionShell(SessionID)
    case ephemeral(UUID)

    public var ownerSessionID: SessionID? {
        switch self {
        case .agentSession(let id), .sessionShell(let id): return id
        case .projectTerminal, .ephemeral: return nil
        }
    }

    /// Agent sessions retain their historical filenames. Every other terminal domain is
    /// namespaced so coincident UUIDs cannot share history.
    public var historyFileStem: String {
        switch self {
        case .agentSession(let id): return id.uuidString
        case .projectTerminal(let id): return "terminal-\(id.uuidString)"
        case .sessionShell(let id): return "shell-\(id.uuidString)"
        case .ephemeral(let id): return "ephemeral-\(id.uuidString)"
        }
    }

    public static func recognizesHistoryFileStem(_ stem: String) -> Bool {
        if UUID(uuidString: stem) != nil { return true }
        for prefix in ["terminal-", "shell-", "ephemeral-"] where stem.hasPrefix(prefix) {
            return UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil
        }
        return false
    }
}

/// The provider-issued identifier used to locate and resume a CLI transcript.
///
/// Unlike `SessionID`, this value belongs to the agent CLI's identity space. Encoding it as a
/// single string preserves the projects file written before the distinction was represented in
/// Swift's type system.
public struct TranscriptID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public var isSafePathComponent: Bool { StoredPathComponent.isValid(rawValue) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which provider login a session belongs to.
///
/// The standard login is a real value rather than an absent string, so callers cannot confuse
/// "use the standard account" with "an account has not been chosen".
public enum AccountHandle: Hashable, Sendable, CustomStringConvertible {
    case standard
    case named(String)

    public static let standardName = "default"

    public init(storedName: String?) {
        guard let storedName, storedName != Self.standardName else {
            self = .standard
            return
        }
        self = .named(storedName)
    }

    /// The directory/discovery spelling. Session persistence deliberately uses
    /// `persistedSessionName` instead so the standard account remains an omitted key.
    public var name: String {
        switch self {
        case .standard: return Self.standardName
        case .named(let name): return name
        }
    }

    public var persistedSessionName: String? {
        switch self {
        case .standard: return nil
        case .named(let name): return name
        }
    }

    public var isStandard: Bool { self == .standard }
    public var description: String { name }
}
