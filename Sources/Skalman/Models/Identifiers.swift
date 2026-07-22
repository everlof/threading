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

/// Keeps `AgentSession.accountHandle` source-level non-optional while retaining its legacy
/// JSON: a named account is a string and the standard account omits the key entirely.
@propertyWrapper
struct PersistedAccountHandle: Codable {
    var wrappedValue: AccountHandle

    init(wrappedValue: AccountHandle) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil()
            ? .standard
            : AccountHandle(storedName: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let name = wrappedValue.persistedSessionName {
            try container.encode(name)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: PersistedAccountHandle.Type, forKey key: Key) throws -> PersistedAccountHandle {
        guard contains(key) else { return PersistedAccountHandle(wrappedValue: .standard) }
        return try decodeIfPresent(type, forKey: key)
            ?? PersistedAccountHandle(wrappedValue: .standard)
    }
}

extension KeyedEncodingContainer {
    mutating func encode(_ value: PersistedAccountHandle, forKey key: Key) throws {
        guard let name = value.wrappedValue.persistedSessionName else { return }
        try encode(name, forKey: key)
    }
}
