import Foundation
import ThreadingExtensionKit

/// A semantic input the native sidebar currently uses to draw or arrange a row.
///
/// The parity checker recognizes these typed cases in the catalog and independently recognizes
/// their production reads. A dependency belongs to exactly one public fact descriptor, so adding
/// a native input cannot be hidden in an unstructured allowlist.
enum NativeSidebarFactDependency: String, CaseIterable, Sendable {
    case sessionProjectMembership
    case sessionTitle
    case sessionProvider
    case sessionAccount
    case sessionActivity
    case sessionBranch
    case sessionParent
    case sessionArchived
    case sessionNativeUI
    case sessionPinned
    case sessionSnoozed
    case sessionWake
    case sessionCreated
    case sessionLastActive
    case sessionLastTurn
    case sessionManualOrder
    case sessionModel
    case sessionManagerRelationship
    case sessionManagerRole
    case sessionConduct
    case sessionScheduledStart
    case projectName
    case projectManualOrder
    case projectScratchpad
    case projectCreated
    case projectBranch
    case terminalProjectMembership
    case terminalTitle
    case terminalBranch
    case terminalManualOrder
    case terminalCreated
}

/// A source-model spelling that deliberately differs from its public fact projection.
///
/// The parity checker validates each raw value against the named Swift model member, then uses
/// the typed case from the descriptor inventory. This keeps derivations such as
/// `displayTitle -> session.title` explicit without making the fact catalog main-actor isolated.
enum NativeSidebarMemberAlias: String, CaseIterable, Sendable {
    case sessionDisplayTitle = "AgentSession.displayTitle"
    case sessionProvider = "AgentSession.kind"
    case sessionAccount = "AgentSession.accountHandle"
    case sessionParentFork = "AgentSession.forkedFrom"
    case sessionParentSideChat = "AgentSession.isSideChat"
    case projectScratchpad = "Project.isTheScratchpad"
    case projectSessions = "Project.sessions"
    case projectTerminals = "Project.terminals"
}

/// A provider method whose result supplies a catalog-owned fact to the native sidebar.
enum NativeSidebarProviderAlias: String, CaseIterable, Sendable {
    case managerOverview = "ControlGrantStore.overview"
    case managerRole = "ControlGrantStore.isManager"
    case managerSessionTitle = "ProjectStore.session"
}

/// A non-model input whose value is projected as a published fact by the native navigator.
enum NativeSidebarFactInputAlias: String, CaseIterable, Sendable {
    case rowActivity = "SessionRowView.configure.activity"
    case rowConduct = "SessionRowView.configure.conduct"
    case rowScheduledStart = "SessionRowView.configure.isScheduledStart"
    case rootProjects = "SidebarTreeBuilder.rootNodes.projects"
    case projectNodeProjects = "SidebarTreeBuilder.projectNode.projects"
}

/// The session values shared by the host fact publisher and, later, the native navigator.
/// Presentation-only state such as selection, hover, loading and theme is deliberately absent.
struct NativeSidebarSessionFacts: Equatable, Sendable {
    let id: String
    let projectID: String
    let title: String
    let providerID: String
    let accountID: String
    let activity: SessionActivity
    let branch: String?
    let parentID: String?
    let isArchived: Bool
    let usesNativeUI: Bool
    let isPinned: Bool
    let isSnoozed: Bool
    let snoozedAt: Date?
    let snoozedUntil: Date?
    let wake: SessionWake?
    let createdAt: Date
    let lastActiveAt: Date
    let lastTurnAt: Date?
    let manualOrder: Int
    let model: String?
    let managerID: String?
    let isManager: Bool
    let hasCustomConduct: Bool
    let hasScheduledStart: Bool
    let scheduledStartAt: Date?
}

/// A repository identity that can only originate from a parsed remote and has passed the
/// extension contract's boundary validation. Local checkout paths have no initializer here.
struct HostFactRepositoryIdentity: Equatable, Sendable {
    let key: ExtensionRepositoryKey

    var host: String { key.host }
    var path: String { key.path }

    init?(remote: String) {
        guard let identity = ExtensionRepositoryIdentity(remote: remote) else { return nil }
        let key = ExtensionRepositoryKey(host: identity.host, path: identity.path)
        guard ExtensionFactSubject.repository(key).validationIssues().isEmpty else { return nil }
        self.key = key
    }
}

struct NativeSidebarProjectFacts: Equatable, Sendable {
    let id: String
    let name: String
    let manualOrder: Int
    let isScratchpad: Bool
    let createdAt: Date
    let repository: HostFactRepositoryIdentity?
    let branch: String?
}

struct NativeSidebarTerminalFacts: Equatable, Sendable {
    let id: String
    let projectID: String
    let title: String
    let branch: String?
    let manualOrder: Int
    let createdAt: Date
}

enum HostFactProjection: Equatable, Sendable {
    case session(NativeSidebarSessionFacts)
    case project(NativeSidebarProjectFacts)
    case terminal(NativeSidebarTerminalFacts)

    var subject: ExtensionFactSubject {
        switch self {
        case .session(let facts): .session(facts.id)
        case .project(let facts): .project(facts.id)
        case .terminal(let facts): .terminal(facts.id)
        }
    }

    var subjectKind: ExtensionFactSubjectKind { subject.kind }
}

/// One canonical definition, its extraction rule, and the native dependency it satisfies.
struct HostFactDescriptor: Sendable {
    let definition: ExtensionFactDefinition
    let nativeDependencies: Set<NativeSidebarFactDependency>
    let nativeAliases: Set<NativeSidebarMemberAlias>
    let providerAliases: Set<NativeSidebarProviderAlias>
    private let extractValue: @Sendable (HostFactProjection) -> ExtensionFactValue?

    init(
        definition: ExtensionFactDefinition,
        nativeDependencies: Set<NativeSidebarFactDependency>,
        nativeAliases: Set<NativeSidebarMemberAlias> = [],
        providerAliases: Set<NativeSidebarProviderAlias> = [],
        extractValue: @escaping @Sendable (HostFactProjection) -> ExtensionFactValue?
    ) {
        self.definition = definition
        self.nativeDependencies = nativeDependencies
        self.nativeAliases = nativeAliases
        self.providerAliases = providerAliases
        self.extractValue = extractValue
    }

    func fact(
        from projection: HostFactProjection,
        observedAt: Date
    ) -> ExtensionFact? {
        guard definition.subjectKinds.contains(projection.subjectKind),
              let value = extractValue(projection) else { return nil }
        return ExtensionFact(
            key: definition.key,
            subject: projection.subject,
            value: value,
            observedAt: observedAt
        )
    }
}

/// Sole authority for Threading's navigator fact definitions and extraction semantics.
enum HostFactCatalog {
    static let nativeInputOwnership: [
        NativeSidebarFactInputAlias: NativeSidebarFactDependency
    ] = [
        .rowActivity: .sessionActivity,
        .rowConduct: .sessionConduct,
        .rowScheduledStart: .sessionScheduledStart,
        .rootProjects: .projectManualOrder,
        .projectNodeProjects: .projectManualOrder,
    ]

    private static let identityUsages: Set<ExtensionFactUsage> = [
        .filterable, .sortable, .groupable, .presentable,
    ]
    private static let textUsages: Set<ExtensionFactUsage> = [
        .filterable, .sortable, .groupable, .searchable, .presentable,
    ]
    private static let stateUsages: Set<ExtensionFactUsage> = [
        .filterable, .sortable, .groupable, .presentable,
    ]
    private static let dateUsages: Set<ExtensionFactUsage> = [
        .filterable, .sortable, .groupable, .presentable,
    ]

    static let all: [HostFactDescriptor] = [
        session(
            ExtensionHostFactKey.sessionProjectID, "Project", .string, identityUsages,
            parity: [.sessionProjectMembership],
            nativeAliases: [.projectSessions]
        ) { .string($0.projectID) },
        session(
            ExtensionHostFactKey.sessionCheckoutID, "Checkout", .string, identityUsages
        ) { .string($0.projectID) },
        session(
            ExtensionHostFactKey.sessionTitle, "Title", .string, textUsages,
            parity: [.sessionTitle],
            nativeAliases: [.sessionDisplayTitle],
            providerAliases: [.managerSessionTitle]
        ) { .string($0.title) },
        session(
            ExtensionHostFactKey.sessionProviderID, "Provider", .string, identityUsages,
            parity: [.sessionProvider],
            nativeAliases: [.sessionProvider]
        ) { .string($0.providerID) },
        session(
            ExtensionHostFactKey.sessionAccountID, "Account", .string, identityUsages,
            parity: [.sessionAccount],
            nativeAliases: [.sessionAccount]
        ) { .string($0.accountID) },
        session(
            ExtensionHostFactKey.sessionActivity, "Activity", .string, stateUsages
        ) { .string(legacyActivity($0.activity)) },
        session(
            ExtensionHostFactKey.sessionDetailedActivity,
            "Detailed Activity",
            .string,
            stateUsages,
            parity: [.sessionActivity]
        ) { .string(detailedActivity($0.activity)) },
        session(
            ExtensionHostFactKey.sessionBranch, "Branch", .string, textUsages,
            parity: [.sessionBranch]
        ) { $0.branch.map(ExtensionFactValue.string) },
        session(
            ExtensionHostFactKey.sessionParentID, "Parent Session", .string, identityUsages,
            parity: [.sessionParent],
            nativeAliases: [.sessionParentFork, .sessionParentSideChat]
        ) { $0.parentID.map(ExtensionFactValue.string) },
        session(
            ExtensionHostFactKey.sessionIsSideChat, "Side Chat", .boolean, stateUsages
        ) { .boolean($0.parentID != nil) },
        session(
            ExtensionHostFactKey.sessionIsArchived, "Archived", .boolean, stateUsages,
            parity: [.sessionArchived]
        ) { .boolean($0.isArchived) },
        session(
            ExtensionHostFactKey.sessionUsesNativeUI, "Native UI", .boolean, stateUsages,
            parity: [.sessionNativeUI]
        ) { .boolean($0.usesNativeUI) },
        session(
            ExtensionHostFactKey.sessionIsPinned, "Pinned", .boolean, stateUsages,
            parity: [.sessionPinned]
        ) { .boolean($0.isPinned) },
        session(
            ExtensionHostFactKey.sessionIsSnoozed, "Snoozed", .boolean, stateUsages,
            parity: [.sessionSnoozed]
        ) { .boolean($0.isSnoozed) },
        session(
            ExtensionHostFactKey.sessionSnoozedAt, "Snoozed At", .date, dateUsages
        ) { $0.snoozedAt.map(ExtensionFactValue.date) },
        session(
            ExtensionHostFactKey.sessionSnoozedUntil, "Snoozed Until", .date, dateUsages
        ) { $0.snoozedUntil.map(ExtensionFactValue.date) },
        session(
            ExtensionHostFactKey.sessionWakeReason, "Wake Reason", .string, stateUsages,
            parity: [.sessionWake]
        ) { $0.wake.map { .string(wakeReason($0.reason)) } },
        session(
            ExtensionHostFactKey.sessionWokeAt, "Woke At", .date, dateUsages
        ) { $0.wake.map { .date($0.wokeAt) } },
        session(
            ExtensionHostFactKey.sessionCreatedAt, "Created At", .date, dateUsages,
            parity: [.sessionCreated]
        ) { .date($0.createdAt) },
        session(
            ExtensionHostFactKey.sessionLastActiveAt, "Last Active At", .date, dateUsages,
            parity: [.sessionLastActive]
        ) { .date($0.lastActiveAt) },
        session(
            ExtensionHostFactKey.sessionLastTurnAt, "Last Turn At", .date, dateUsages,
            parity: [.sessionLastTurn]
        ) { $0.lastTurnAt.map(ExtensionFactValue.date) },
        session(
            ExtensionHostFactKey.sessionLastUsedAt, "Last Used At", .date, dateUsages
        ) { .date($0.lastTurnAt ?? $0.lastActiveAt) },
        session(
            ExtensionHostFactKey.sessionManualOrder, "Manual Order", .integer, [.sortable],
            parity: [.sessionManualOrder],
            nativeAliases: [.projectSessions]
        ) { .integer(Int64($0.manualOrder)) },
        session(
            ExtensionHostFactKey.sessionModel, "Model", .string, textUsages,
            parity: [.sessionModel]
        ) { $0.model.map(ExtensionFactValue.string) },
        session(
            ExtensionHostFactKey.sessionManagerID, "Manager", .string, identityUsages,
            parity: [.sessionManagerRelationship],
            providerAliases: [.managerOverview]
        ) { $0.managerID.map(ExtensionFactValue.string) },
        session(
            ExtensionHostFactKey.sessionIsManager, "Manager Role", .boolean, stateUsages,
            parity: [.sessionManagerRole],
            providerAliases: [.managerRole]
        ) { .boolean($0.isManager) },
        session(
            ExtensionHostFactKey.sessionHasCustomConduct,
            "Custom Conduct",
            .boolean,
            stateUsages,
            parity: [.sessionConduct]
        ) { .boolean($0.hasCustomConduct) },
        session(
            ExtensionHostFactKey.sessionHasScheduledStart,
            "Scheduled Start",
            .boolean,
            stateUsages,
            parity: [.sessionScheduledStart]
        ) { .boolean($0.hasScheduledStart) },
        session(
            ExtensionHostFactKey.sessionScheduledStartAt,
            "Scheduled Start At",
            .date,
            dateUsages
        ) { $0.scheduledStartAt.map(ExtensionFactValue.date) },

        project(
            ExtensionHostFactKey.projectName, "Project Name", .string, textUsages,
            parity: [.projectName]
        ) { .string($0.name) },
        project(
            ExtensionHostFactKey.projectManualOrder, "Project Order", .integer, [.sortable],
            parity: [.projectManualOrder]
        ) { .integer(Int64($0.manualOrder)) },
        project(
            ExtensionHostFactKey.projectIsScratchpad, "Scratchpad", .boolean, stateUsages,
            parity: [.projectScratchpad],
            nativeAliases: [.projectScratchpad]
        ) { .boolean($0.isScratchpad) },
        project(
            ExtensionHostFactKey.projectCreatedAt, "Project Created At", .date, dateUsages,
            parity: [.projectCreated]
        ) { .date($0.createdAt) },
        project(
            ExtensionHostFactKey.projectRepositoryHost,
            "Repository Host",
            .string,
            textUsages
        ) { $0.repository.map { .string($0.host) } },
        project(
            ExtensionHostFactKey.projectRepositoryPath,
            "Repository Path",
            .string,
            textUsages
        ) { $0.repository.map { .string($0.path) } },
        project(
            ExtensionHostFactKey.projectBranch, "Project Branch", .string, textUsages,
            parity: [.projectBranch]
        ) { $0.branch.map(ExtensionFactValue.string) },

        terminal(
            ExtensionHostFactKey.terminalProjectID, "Terminal Project", .string, identityUsages,
            parity: [.terminalProjectMembership],
            nativeAliases: [.projectTerminals]
        ) { .string($0.projectID) },
        terminal(
            ExtensionHostFactKey.terminalTitle, "Terminal Title", .string, textUsages,
            parity: [.terminalTitle]
        ) { .string($0.title) },
        terminal(
            ExtensionHostFactKey.terminalBranch, "Terminal Branch", .string, textUsages,
            parity: [.terminalBranch]
        ) { $0.branch.map(ExtensionFactValue.string) },
        terminal(
            ExtensionHostFactKey.terminalManualOrder, "Terminal Order", .integer, [.sortable],
            parity: [.terminalManualOrder],
            nativeAliases: [.projectTerminals]
        ) { .integer(Int64($0.manualOrder)) },
        terminal(
            ExtensionHostFactKey.terminalCreatedAt, "Terminal Created At", .date, dateUsages,
            parity: [.terminalCreated]
        ) { .date($0.createdAt) },
    ]

    static var definitions: [ExtensionFactDefinition] { all.map(\.definition) }

    static func facts(
        from projection: HostFactProjection,
        observedAt: Date
    ) -> [ExtensionFact] {
        all.compactMap { $0.fact(from: projection, observedAt: observedAt) }
    }

    private static func session(
        _ key: ExtensionFactKey,
        _ displayName: String,
        _ valueType: ExtensionFactValueType,
        _ usages: Set<ExtensionFactUsage>,
        parity: Set<NativeSidebarFactDependency> = [],
        nativeAliases: Set<NativeSidebarMemberAlias> = [],
        providerAliases: Set<NativeSidebarProviderAlias> = [],
        extract: @escaping @Sendable (NativeSidebarSessionFacts) -> ExtensionFactValue?
    ) -> HostFactDescriptor {
        return descriptor(
            key,
            displayName,
            valueType,
            subjectKind: .session,
            usages: usages,
            parity: parity,
            nativeAliases: nativeAliases,
            providerAliases: providerAliases
        ) { projection in
            guard case .session(let facts) = projection else { return nil }
            return extract(facts)
        }
    }

    private static func project(
        _ key: ExtensionFactKey,
        _ displayName: String,
        _ valueType: ExtensionFactValueType,
        _ usages: Set<ExtensionFactUsage>,
        parity: Set<NativeSidebarFactDependency> = [],
        nativeAliases: Set<NativeSidebarMemberAlias> = [],
        providerAliases: Set<NativeSidebarProviderAlias> = [],
        extract: @escaping @Sendable (NativeSidebarProjectFacts) -> ExtensionFactValue?
    ) -> HostFactDescriptor {
        return descriptor(
            key,
            displayName,
            valueType,
            subjectKind: .project,
            usages: usages,
            parity: parity,
            nativeAliases: nativeAliases,
            providerAliases: providerAliases
        ) { projection in
            guard case .project(let facts) = projection else { return nil }
            return extract(facts)
        }
    }

    private static func terminal(
        _ key: ExtensionFactKey,
        _ displayName: String,
        _ valueType: ExtensionFactValueType,
        _ usages: Set<ExtensionFactUsage>,
        parity: Set<NativeSidebarFactDependency> = [],
        nativeAliases: Set<NativeSidebarMemberAlias> = [],
        providerAliases: Set<NativeSidebarProviderAlias> = [],
        extract: @escaping @Sendable (NativeSidebarTerminalFacts) -> ExtensionFactValue?
    ) -> HostFactDescriptor {
        return descriptor(
            key,
            displayName,
            valueType,
            subjectKind: .terminal,
            usages: usages,
            parity: parity,
            nativeAliases: nativeAliases,
            providerAliases: providerAliases
        ) { projection in
            guard case .terminal(let facts) = projection else { return nil }
            return extract(facts)
        }
    }

    private static func descriptor(
        _ key: ExtensionFactKey,
        _ displayName: String,
        _ valueType: ExtensionFactValueType,
        subjectKind: ExtensionFactSubjectKind,
        usages: Set<ExtensionFactUsage>,
        parity: Set<NativeSidebarFactDependency>,
        nativeAliases: Set<NativeSidebarMemberAlias>,
        providerAliases: Set<NativeSidebarProviderAlias>,
        extract: @escaping @Sendable (HostFactProjection) -> ExtensionFactValue?
    ) -> HostFactDescriptor {
        HostFactDescriptor(
            definition: ExtensionFactDefinition(
                key: key,
                displayName: displayName,
                valueType: valueType,
                subjectKinds: [subjectKind],
                usages: usages
            ),
            nativeDependencies: parity,
            nativeAliases: nativeAliases,
            providerAliases: providerAliases,
            extractValue: extract
        )
    }

    private static func legacyActivity(_ activity: SessionActivity) -> String {
        switch activity {
        case .dormant: "dormant"
        case .idle: "idle"
        case .working: "working"
        case .awaitingUser, .needsAttention, .limitReached: "needs-attention"
        }
    }

    private static func detailedActivity(_ activity: SessionActivity) -> String {
        switch activity {
        case .dormant: "dormant"
        case .idle: "idle"
        case .working: "working"
        case .awaitingUser: "awaiting-user"
        case .needsAttention: "needs-attention"
        case .limitReached: "limit-reached"
        }
    }

    private static func wakeReason(_ reason: SessionWakeReason) -> String {
        switch reason {
        case .timeReached: "time-reached"
        case .approvalRequested: "approval-requested"
        case .inputRequested: "input-requested"
        case .failed: "failed"
        case .turnCompleted: "turn-completed"
        case .requestedUpdate: "requested-update"
        }
    }
}
