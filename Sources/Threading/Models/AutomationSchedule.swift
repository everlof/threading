import Foundation
import ThreadingDomain

typealias AutomationSchedule = ThreadingDomain.AutomationSchedule

extension AutomationSchedule {
    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .interval: return L10n.format("Every %lld minutes", Int64(intervalMinutes))
        case .daily: return L10n.format("Daily at %@ · %@", time, timeZone)
        case .weekdays, .weekly:
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = .current
            let names = days.sorted().map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            return "\(names) \(time) · \(timeZone)"
        }
    }
}

struct AutomationOptions: Codable, Equatable, Sendable {
    enum MissedRunPolicy: String, Codable, CaseIterable, Sendable { case skip, latest }
    var schedule: AutomationSchedule?
    var missedRunPolicy: MissedRunPolicy
    var archiveOnSuccess: Bool
}

/// Both the editor and MCP use this complete replacement value. Updates name the revision
/// being edited, so stale agent calls and stale forms cannot overwrite a newer configuration.
struct AutomationConfiguration: Codable, Equatable, Sendable {
    var name: String
    var projectID: ProjectID
    var instructions: String
    var agent: AgentKind
    var account: String?
    var model: String?
    var reasoningEffort: String?
    var executionMode: TriggerExecutionMode
    var checkoutPolicy: TriggerCheckoutPolicy
    var maximumRuntimeMinutes: Int
    var options: AutomationOptions
    var sourceID: TriggerSourceInstallationID?
    var eventKind: String?
    var conditions: [TriggerCondition]
    /// What unattended runs may do without asking. Omitted means read-only, and is saved as
    /// that explicit policy.
    var permissions: AutomationPermissionPolicy?

    init(projectID: ProjectID) {
        self.projectID = projectID; name = ""; instructions = ""; agent = .codex
        executionMode = .taskReadOnly; checkoutPolicy = .projectCheckout; maximumRuntimeMinutes = 60
        options = .init(schedule: .init(kind: .daily, timeZone: TimeZone.current.identifier), missedRunPolicy: .skip, archiveOnSuccess: true)
        conditions = []
    }

    init(definition: TriggerDefinition, revision: TriggerRevision) {
        name = definition.name
        projectID = revision.projectID
        instructions = revision.instructions
        agent = revision.agentKind
        account = revision.accountHandleName
        model = revision.model
        reasoningEffort = revision.reasoningEffort
        executionMode = revision.executionMode
        checkoutPolicy = revision.checkoutPolicy
        maximumRuntimeMinutes = revision.limits.maximumRuntimeMinutes
        options = revision.automation ?? .init(schedule: nil, missedRunPolicy: .skip, archiveOnSuccess: false)
        sourceID = options.schedule == nil ? revision.sourceInstallationID : nil
        eventKind = options.schedule == nil ? revision.eventKind : nil
        conditions = revision.conditions
        permissions = revision.permissions
    }
}
