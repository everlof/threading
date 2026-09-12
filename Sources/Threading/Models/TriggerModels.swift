import Foundation

// MARK: - Identity

struct TriggerID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
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

struct TriggerRevisionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
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

struct TriggerSourceInstallationID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
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

struct TriggerRunID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
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

// MARK: - Source events

enum TriggerAttributeValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case timestamp(Date)

    private enum CodingKeys: String, CodingKey { case type, string, integer, decimal, boolean, timestamp }
    private enum Kind: String, Codable { case string, integer, decimal, boolean, timestamp }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try container.decode(String.self, forKey: .string))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .decimal: self = .decimal(try container.decode(Double.self, forKey: .decimal))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .timestamp: self = .timestamp(try container.decode(Date.self, forKey: .timestamp))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .integer)
        case .decimal(let value):
            try container.encode(Kind.decimal, forKey: .type)
            try container.encode(value, forKey: .decimal)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .type)
            try container.encode(value, forKey: .boolean)
        case .timestamp(let value):
            try container.encode(Kind.timestamp, forKey: .type)
            try container.encode(value, forKey: .timestamp)
        }
    }
}

struct TriggerResourceReference: Codable, Equatable, Sendable {
    let kind: String
    let identifier: String
    let displayName: String
    let byteCount: Int64?
}

struct TriggerEvent: Codable, Equatable, Sendable {
    let sourceInstallationID: TriggerSourceInstallationID
    let externalID: String
    let revision: String
    let kind: String
    let occurredAt: Date
    let receivedAt: Date
    let title: String
    let attributes: [String: TriggerAttributeValue]
    let deepLink: URL?
    let resources: [TriggerResourceReference]

    var storageKey: String {
        [sourceInstallationID.uuidString, externalID, revision]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }
}

// MARK: - Source installations

enum TriggerSourceHealth: String, Codable, Sendable {
    case disconnected
    case healthy
    case checking
    case backingOff
    case authenticationRequired
    case failed
}

struct TriggerSourceInstallation: Codable, Equatable, Sendable {
    let id: TriggerSourceInstallationID
    var sourceType: String
    var displayName: String
    var configuration: [String: TriggerAttributeValue]
    var credentialReference: String?
    var enabled: Bool
    var health: TriggerSourceHealth
    var lastCheckedAt: Date?
    var lastEventAt: Date?
    var boundedDiagnostic: String?
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Matching

enum TriggerComparison: String, Codable, CaseIterable, Sendable {
    case equals
    case notEquals
    case contains
    case greaterThan
    case lessThan
    case exists
}

struct TriggerCondition: Codable, Equatable, Sendable {
    var attribute: String
    var comparison: TriggerComparison
    var value: TriggerAttributeValue?
}

enum TriggerMatcher {
    static func matches(_ event: TriggerEvent, conditions: [TriggerCondition]) -> Bool {
        conditions.allSatisfy { condition in
            let candidate = event.attributes[condition.attribute]
            switch condition.comparison {
            case .exists:
                return candidate != nil
            case .equals:
                return candidate == condition.value
            case .notEquals:
                return candidate != condition.value
            case .contains:
                guard case .string(let haystack)? = candidate,
                      case .string(let needle)? = condition.value else { return false }
                return haystack.localizedCaseInsensitiveContains(needle)
            case .greaterThan:
                return ordered(candidate, isGreaterThan: condition.value)
            case .lessThan:
                return ordered(condition.value, isGreaterThan: candidate)
            }
        }
    }

    private static func ordered(
        _ lhs: TriggerAttributeValue?,
        isGreaterThan rhs: TriggerAttributeValue?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.integer(let left)?, .integer(let right)?): return left > right
        case (.decimal(let left)?, .decimal(let right)?): return left > right
        case (.integer(let left)?, .decimal(let right)?): return Double(left) > right
        case (.decimal(let left)?, .integer(let right)?): return left > Double(right)
        case (.timestamp(let left)?, .timestamp(let right)?): return left > right
        default: return false
        }
    }
}

// MARK: - Rules and authority

enum TriggerExecutionMode: String, Codable, CaseIterable, Sendable {
    case assessOnly
    case assessThenFix
}

enum TriggerCheckoutPolicy: String, Codable, CaseIterable, Sendable {
    case projectCheckout
    case managedWorktree
}

struct TriggerLimits: Codable, Equatable, Sendable {
    var maximumConcurrentRuns: Int
    var maximumRuntimeMinutes: Int

    static let conservative = TriggerLimits(maximumConcurrentRuns: 1, maximumRuntimeMinutes: 60)
}

struct TriggerNotificationPolicy: Codable, Equatable, Sendable {
    var onCompletion: Bool
    var onNeedsAttention: Bool
    var onFailure: Bool

    static let standard = TriggerNotificationPolicy(
        onCompletion: true,
        onNeedsAttention: true,
        onFailure: true
    )
}

struct TriggerQuietHours: Codable, Equatable, Sendable {
    var startMinute: Int
    var endMinute: Int
    var timeZoneIdentifier: String

    func contains(_ date: Date) -> Bool {
        guard (0 ..< 1_440).contains(startMinute),
              (0 ..< 1_440).contains(endMinute),
              startMinute != endMinute,
              let zone = TimeZone(identifier: timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

struct TriggerRevision: Codable, Equatable, Sendable {
    let id: TriggerRevisionID
    let triggerID: TriggerID
    let sequence: Int
    var sourceInstallationID: TriggerSourceInstallationID
    var eventKind: String
    var conditions: [TriggerCondition]
    var projectID: ProjectID
    var instructions: String
    var agentKind: AgentKind
    var accountHandleName: String?
    var model: String?
    var reasoningEffort: String?
    var executionMode: TriggerExecutionMode
    var checkoutPolicy: TriggerCheckoutPolicy
    var limits: TriggerLimits
    var quietHours: TriggerQuietHours?
    var notifications: TriggerNotificationPolicy
    var allowSourceResources: Bool
    var proposedBySessionID: SessionID?
    let createdAt: Date
}

struct TriggerDefinition: Codable, Equatable, Sendable {
    let id: TriggerID
    var name: String
    var enabled: Bool
    var activeRevisionID: TriggerRevisionID?
    var draftRevisionID: TriggerRevisionID?
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Runs

enum TriggerRunState: String, Codable, CaseIterable, Sendable {
    case received
    case suppressed
    case queued
    case assessing
    case fixQueued
    case fixing
    case needsAttention
    case completed
    case failed
    case cancelled
}

enum TriggerRunHoldReason: String, Codable, Sendable {
    case quietHours
    case concurrencyLimit
    case backgroundUnavailable
    case dirtyCheckout
}

enum TriggerAssessmentDisposition: String, Codable, CaseIterable, Sendable {
    case noChangeNeeded
    case straightforwardFix
    case fixed
    case needsHuman
    case failed
}

struct TriggerRunResult: Codable, Equatable, Sendable {
    var disposition: TriggerAssessmentDisposition
    var summary: String
    var changedPaths: [String]
    var tests: [String]
}

struct TriggerRun: Codable, Equatable, Sendable {
    let id: TriggerRunID
    let triggerID: TriggerID
    let triggerRevisionID: TriggerRevisionID
    let eventKey: String
    var state: TriggerRunState
    let queuedAt: Date
    var startedAt: Date?
    var settledAt: Date?
    var sessionID: SessionID?
    var managedWorkspaceID: UUID?
    var holdReason: TriggerRunHoldReason?
    var result: TriggerRunResult?
    var boundedDiagnostic: String?
}

extension Notification.Name {
    static let triggersDidChange = Notification.Name("ThreadingTriggersDidChange")
}
