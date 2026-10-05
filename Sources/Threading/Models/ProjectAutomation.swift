import Foundation

/// Portable, project-owned configuration. Machine identities and activation never enter it.
struct ProjectAutomation: Codable, Equatable, Sendable {
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
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

struct AutomationWorkspace: Codable, Equatable, Sendable {
    let automationID: String
    let checkoutPath: String

    init(automationID: String, checkoutPath: String) {
        self.automationID = automationID
        self.checkoutPath = checkoutPath
    }

    private enum CodingKeys: String, CodingKey { case automationID, checkoutPath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automationID = try container.decode(String.self, forKey: .automationID)
        checkoutPath = try container.decode(String.self, forKey: .checkoutPath)
        guard ProjectAutomation.validID(automationID), checkoutPath.hasPrefix("/"), !checkoutPath.contains("\0") else {
            throw DecodingError.dataCorruptedError(forKey: .automationID, in: container, debugDescription: "Invalid automation workspace")
        }
    }

    var executionPath: String {
        URL(fileURLWithPath: checkoutPath).appendingPathComponent(
            ".threading/local/automations/\(automationID)", isDirectory: true).path
    }
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
