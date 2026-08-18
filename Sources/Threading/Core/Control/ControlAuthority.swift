import Foundation

enum SessionRole: String, Codable, CaseIterable, Sendable {
    case chat
    case manager

    var displayName: String {
        switch self {
        case .chat: L10n.string("Chat")
        case .manager: L10n.string("Manager")
        }
    }
}

// MARK: - Grant Identity

/// A durable control grant's stable identity.
///
/// Kept incompatible with session and project identifiers so no adapter can accidentally use a
/// target identity as authority. The UUID is opaque on every user-facing surface.
struct ControlGrantID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
    }

    var uuidString: String { rawValue.uuidString.lowercased() }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Authority

/// One closed operation the session control plane can authorize.
///
/// These are intentionally not read/write tiers. Adding a capability requires adding a case and
/// deciding its scope, tool exposure, refusal wording and tests.
enum ControlOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case listSessions
    case sendMessage
    case steer
    case watch
    case archiveSession
    case renameSession
    case resumeSession
    case spawnSession
    case readAccounts
    case readUsage
    case moveSessionToAccount
    case finishWorkspace
    case adoptSession
    case releaseSession
    case subscribeToChildren
    case respondToPermission

    static let regularProjectOperations: Set<Self> = [
        .listSessions, .sendMessage, .steer, .watch,
    ]

    static let regularSelfOperations: Set<Self> = [
        .archiveSession, .renameSession,
    ]

    static let managerOperations: Set<Self> = Set(allCases)

    /// The complete manager role before permission responses became a manager capability.
    ///
    /// Persisted grants store exact operations rather than a role name. `ControlGrantStore`
    /// recognizes only this exact historical set when upgrading an active full-manager grant;
    /// a deliberately narrower grant must never grow because the role did.
    static let prePermissionResponseManagerOperations: Set<Self> = [
        .listSessions, .sendMessage, .steer, .watch,
        .archiveSession, .renameSession, .resumeSession, .spawnSession,
        .readAccounts, .readUsage, .moveSessionToAccount, .finishWorkspace,
        .adoptSession, .releaseSession, .subscribeToChildren,
    ]

    /// Manager-only tools are advertised from the exact operations a grant carries.
    var supervisionToolName: String? {
        switch self {
        case .archiveSession, .renameSession:
            // These extend existing self tools through their optional target argument.
            return nil
        case .resumeSession: return "resume_session"
        case .spawnSession: return "spawn_session"
        case .readAccounts: return "list_accounts"
        case .readUsage: return "session_cost"
        case .moveSessionToAccount: return "move_session_to_account"
        case .finishWorkspace: return "finish_workspace"
        case .adoptSession: return "adopt_session"
        case .releaseSession: return "release_session"
        case .subscribeToChildren: return "subscribe_to_children"
        case .respondToPermission: return "respond_to_permission"
        case .listSessions, .sendMessage, .steer, .watch:
            return nil
        }
    }
}

/// An optional enforceable line on work a granted actor starts.
///
/// The account-limit system remains the owner of window semantics. A ceiling says which account
/// and fraction to apply at admission; an absent account follows the actor's routed account and
/// an absent window applies to the deciding window reported by the usage service.
struct SpendCeiling: Codable, Equatable, Sendable {
    let accountID: AccountID?
    let maximumFraction: Double
    let windowIdentifier: String?

    init(
        accountID: AccountID? = nil,
        maximumFraction: Double,
        windowIdentifier: String? = nil
    ) {
        self.accountID = accountID
        self.maximumFraction = min(max(maximumFraction, 0), 1)
        self.windowIdentifier = windowIdentifier
    }
}

/// The user action that conferred a grant. There is deliberately no agent-authored case.
enum GrantOrigin: Codable, Equatable, Sendable {
    case user(command: String)
    case newManagerTemplate
}

/// Durable, revocable authority for one actor over one scope.
struct ControlGrant: Codable, Equatable, Sendable, Identifiable {
    let id: ControlGrantID
    let actor: ControlActor
    let scope: ControlScope
    var operations: Set<ControlOperation>
    let ceiling: SpendCeiling?
    let maximumPermissionMode: AgentPermissionMode
    let allowedDeliveries: Set<ManagedWorkspaceDelivery>
    let conferredAt: Date
    let conferredBy: GrantOrigin
    var revokedAt: Date?

    var isActive: Bool { revokedAt == nil }

    init(
        id: ControlGrantID = ControlGrantID(),
        actor: ControlActor,
        scope: ControlScope,
        operations: Set<ControlOperation>,
        ceiling: SpendCeiling? = nil,
        maximumPermissionMode: AgentPermissionMode,
        allowedDeliveries: Set<ManagedWorkspaceDelivery> = [.keepForReview],
        conferredAt: Date = Date(),
        conferredBy: GrantOrigin,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.actor = actor
        self.scope = scope
        self.operations = operations
        self.ceiling = ceiling
        self.maximumPermissionMode = maximumPermissionMode
        self.allowedDeliveries = allowedDeliveries
        self.conferredAt = conferredAt
        self.conferredBy = conferredBy
        self.revokedAt = revokedAt
    }

    static func manager(
        sessionID: SessionID,
        projectID: ProjectID,
        maximumPermissionMode: AgentPermissionMode,
        origin: GrantOrigin,
        at date: Date = Date()
    ) -> ControlGrant {
        ControlGrant(
            actor: .agentSession(sessionID),
            scope: .project(projectID),
            operations: ControlOperation.managerOperations,
            maximumPermissionMode: maximumPermissionMode,
            conferredAt: date,
            conferredBy: origin
        )
    }

    /// Advances an active grant that is provably the complete historical manager role.
    /// Deliberately exact: partial grants and revoked audit rows remain unchanged.
    @discardableResult
    mutating func upgradeManagerRoleIfNeeded() -> Bool {
        guard isActive,
              operations == ControlOperation.prePermissionResponseManagerOperations else {
            return false
        }
        operations = ControlOperation.managerOperations
        return true
    }
}

// MARK: - Supervision

struct SupervisionID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
    }
    var uuidString: String { rawValue.uuidString.lowercased() }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SupervisionState: String, Codable, Equatable, Sendable {
    case active
    case released
    case archived
    case completed
}

struct Supervision: Codable, Equatable, Sendable, Identifiable {
    let id: SupervisionID
    let managerID: SessionID
    let childID: SessionID
    var brief: String
    let assignedAt: Date
    var state: SupervisionState
    var closedAt: Date?
    var outcome: String?

    init(
        id: SupervisionID = SupervisionID(),
        managerID: SessionID,
        childID: SessionID,
        brief: String,
        assignedAt: Date = Date(),
        state: SupervisionState = .active,
        closedAt: Date? = nil,
        outcome: String? = nil
    ) {
        self.id = id
        self.managerID = managerID
        self.childID = childID
        self.brief = String(brief.prefix(SupervisionDefaults.maximumBriefLength))
        self.assignedAt = assignedAt
        self.state = state
        self.closedAt = closedAt
        self.outcome = outcome
    }
}

enum SupervisionEventKind: String, Codable, CaseIterable, Sendable {
    case assigned
    case settled
    case exited
    case needsAttention
    case limitNearing
    case limitReached
    case archived
    case moved
    case workspaceFinished
    case reportReceived
    case revoked
    case released
    case eventsDropped
}

struct SupervisionEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let supervisionID: SupervisionID
    let at: Date
    let kind: SupervisionEventKind
    let detail: String?

    init(
        id: UUID = UUID(),
        supervisionID: SupervisionID,
        at: Date = Date(),
        kind: SupervisionEventKind,
        detail: String? = nil
    ) {
        self.id = id
        self.supervisionID = supervisionID
        self.at = at
        self.kind = kind
        self.detail = detail.map { String($0.prefix(SupervisionDefaults.maximumEventDetailLength)) }
    }
}

enum SupervisionDefaults {
    static let maximumLiveChildren = 8
    static let maximumEvents = 128
    static let maximumSendsPerMinute = 20
    static let maximumAccountMovesPerDay = 3
    static let maximumBriefLength = 16_384
    static let maximumEventDetailLength = 2_048
}

/// Presentation-safe supervision state returned by `list_sessions` and the Chats host tab.
struct ControlSupervisionOverview: Equatable, Sendable {
    let managedBy: SessionID?
    let children: [SessionID]
    let brief: String?
    let lastEvent: SupervisionEvent?
}

// MARK: - Change Event

struct ControlGrantsDidChange: AppEvent {
    static let name = Notification.Name("controlGrantsDidChange")
    let sessionID: SessionID
}

struct SupervisionDidChange: AppEvent {
    static let name = Notification.Name("supervisionDidChange")
    let managerID: SessionID
    let childID: SessionID
}
