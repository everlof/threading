import Foundation

/// Portable, project-owned configuration. Machine identities and activation never enter it.
struct ProjectAutomation: Codable, Equatable, Sendable {
    static func validID(_ id: String) -> Bool {
        ProjectAutomationIdentifier.isValid(id)
    }

    var formatVersion = 1
    var id: String
    var name: String
    var instructions = "instructions.md"
    var resources: [String] = []
    var agent: AgentKind
    var model: String?
    var reasoningEffort: String?
    var executionMode: TriggerExecutionMode
    var checkoutPolicy: TriggerCheckoutPolicy
    var maximumRuntimeMinutes: Int
    var options: AutomationOptions
    var source: String?
    var eventKind: String?
    var conditions: [TriggerCondition]
    var permissions: ProjectAutomationPermissions
    /// Omitted means chat, so a file written before the choice existed reads as it always did.
    var surface: AutomationSurface?

    init(id: String, configuration: AutomationConfiguration, source: String?) {
        self.id = id
        name = configuration.name
        agent = configuration.agent
        model = configuration.model
        reasoningEffort = configuration.reasoningEffort
        executionMode = configuration.executionMode
        checkoutPolicy = configuration.checkoutPolicy
        maximumRuntimeMinutes = configuration.maximumRuntimeMinutes
        options = configuration.options
        self.source = source
        eventKind = configuration.eventKind
        conditions = configuration.conditions
        permissions = ProjectAutomationPermissions(configuration.permissions ?? .readOnly)
        surface = configuration.surface
    }
}

/// Local binding; one checkout's import and login/source choices survive app restarts.
struct ProjectAutomationBinding: Codable, Equatable, Sendable {
    let triggerID: TriggerID
    let projectID: ProjectID
    let automationID: String
    let checkoutPath: String
    let repositoryIdentity: String
    var fingerprint: String
    var account: String?
    var sourceID: TriggerSourceInstallationID?
    var sourceName: String? = nil
    var diagnostic: String?
}

/// Frozen paths named by the reviewed revision, and used by its ordinary conversation.
struct ProjectAutomationRevision: Codable, Equatable, Sendable {
    let automationID: String
    let checkoutPath: String
    let fingerprint: String
    let resourcesPath: String
    let workspacePath: String
    let resources: [String]
}

/// Raw portable rules are resolved and parsed at the host boundary, before becoming authority.
struct ProjectAutomationPermissions: Codable, Equatable, Sendable {
    enum Mode: String, Codable { case allowList, full }
    var mode: Mode
    var rules: [String]?

    init(_ policy: AutomationPermissionPolicy) {
        mode = policy.isFull ? .full : .allowList
        rules = policy.isFull ? nil : policy.rules.map(\.text)
    }
}
