import Foundation

/// A project's stable identity.
///
/// The custom `Codable` implementation deliberately encodes the wrapped UUID as a single
/// value, preserving the JSON shape used before project and session identifiers had distinct
/// Swift types.
struct ProjectID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A session's stable identity, intentionally incompatible with `ProjectID` at compile time.
struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A standalone project's terminal identity, intentionally separate from chat sessions.
struct TerminalID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The semantic owner of one live terminal process.
///
/// A project terminal and an agent session may both happen to use UUIDs, but that does not put
/// them in the same identity domain. Keeping the variants distinct prevents terminal-only code
/// from manufacturing a `SessionID` merely to reuse history or interaction APIs.
enum TerminalInstanceIdentity: Hashable, Sendable {
    case agentSession(SessionID)
    case projectTerminal(TerminalID)
    case sessionShell(SessionID)
    case ephemeral(UUID)

    var ownerSessionID: SessionID? {
        switch self {
        case .agentSession(let id), .sessionShell(let id): return id
        case .projectTerminal, .ephemeral: return nil
        }
    }

    /// Agent sessions retain their historical filenames. Every other terminal domain is
    /// namespaced so coincident UUIDs cannot share history.
    var historyFileStem: String {
        switch self {
        case .agentSession(let id): return id.uuidString
        case .projectTerminal(let id): return "terminal-\(id.uuidString)"
        case .sessionShell(let id): return "shell-\(id.uuidString)"
        case .ephemeral(let id): return "ephemeral-\(id.uuidString)"
        }
    }

    static func recognizesHistoryFileStem(_ stem: String) -> Bool {
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
struct TranscriptID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which provider login a session belongs to.
///
/// The standard login is a real value rather than an absent string, so callers cannot confuse
/// "use the standard account" with "an account has not been chosen".
enum AccountHandle: Hashable, Sendable, CustomStringConvertible {
    case standard
    case named(String)

    static let standardName = "default"

    init(storedName: String?) {
        guard let storedName, storedName != Self.standardName else {
            self = .standard
            return
        }
        self = .named(storedName)
    }

    /// The directory/discovery spelling. Session persistence deliberately uses
    /// `persistedSessionName` instead so the standard account remains an omitted key.
    var name: String {
        switch self {
        case .standard: return Self.standardName
        case .named(let name): return name
        }
    }

    var persistedSessionName: String? {
        switch self {
        case .standard: return nil
        case .named(let name): return name
        }
    }

    var isStandard: Bool { self == .standard }
    var description: String { name }
}

/// A provider-qualified account identity.
struct AccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    let provider: AgentKind
    let handle: AccountHandle

    init(provider: AgentKind, handle: AccountHandle) {
        self.provider = provider
        self.handle = handle
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = AgentKind(rawValue: String(parts[0])) else {
            return nil
        }
        self.provider = provider
        self.handle = AccountHandle(storedName: String(parts[1]))
    }

    var rawValue: String { "\(provider.rawValue):\(handle.name)" }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = AccountID(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid account id")
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
