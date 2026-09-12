import Foundation

struct TriggerReferenceArguments: Codable, Sendable {
    let triggerID: String?
    let revisionID: String?

    private enum CodingKeys: String, CodingKey {
        case triggerID = "trigger_id"
        case revisionID = "revision_id"
    }
}

struct TriggerConditionArguments: Codable, Sendable {
    let attribute: String?
    let comparison: String?
    let stringValue: String?
    let integerValue: Int64?
    let decimalValue: Double?
    let booleanValue: Bool?
    let timestampValue: Date?

    private enum CodingKeys: String, CodingKey {
        case attribute, comparison
        case stringValue = "string_value"
        case integerValue = "integer_value"
        case decimalValue = "decimal_value"
        case booleanValue = "boolean_value"
        case timestampValue = "timestamp_value"
    }

    func condition() throws -> TriggerCondition {
        guard let attribute = attribute?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attribute.isEmpty,
              let comparison,
              let comparison = TriggerComparison(rawValue: comparison) else {
            throw TriggerStore.StoreError.invalidRecord("condition attribute or comparison")
        }
        let values: [TriggerAttributeValue] = [
            stringValue.map(TriggerAttributeValue.string),
            integerValue.map(TriggerAttributeValue.integer),
            decimalValue.map(TriggerAttributeValue.decimal),
            booleanValue.map(TriggerAttributeValue.boolean),
            timestampValue.map(TriggerAttributeValue.timestamp),
        ].compactMap { $0 }
        if comparison == .exists {
            guard values.isEmpty else {
                throw TriggerStore.StoreError.invalidRecord("exists condition has a value")
            }
            return TriggerCondition(attribute: attribute, comparison: comparison, value: nil)
        }
        guard values.count == 1 else {
            throw TriggerStore.StoreError.invalidRecord("condition must have exactly one value")
        }
        return TriggerCondition(attribute: attribute, comparison: comparison, value: values[0])
    }
}

struct CreateTriggerDraftArguments: Codable, Sendable {
    let name: String?
    let sourceID: String?
    let eventKind: String?
    let projectID: String?
    let instructions: String?
    let agent: String?
    let account: String?
    let model: String?
    let reasoningEffort: String?
    let executionMode: String?
    let checkoutPolicy: String?
    let conditions: [TriggerConditionArguments]?

    private enum CodingKeys: String, CodingKey {
        case name, instructions, agent, account, model, conditions
        case sourceID = "source_id"
        case eventKind = "event_kind"
        case projectID = "project_id"
        case reasoningEffort = "reasoning_effort"
        case executionMode = "execution_mode"
        case checkoutPolicy = "checkout_policy"
    }
}

struct TriggerRunReferenceArguments: Codable, Sendable {
    let runID: String?

    private enum CodingKeys: String, CodingKey { case runID = "run_id" }
}

struct ReportTriggerAssessmentArguments: Codable, Sendable {
    let runID: String?
    let disposition: String?
    let summary: String?

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case disposition, summary
    }
}

struct ReportTriggerResultArguments: Codable, Sendable {
    let runID: String?
    let disposition: String?
    let summary: String?
    let changedPaths: [String]?
    let tests: [String]?

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case disposition, summary, tests
        case changedPaths = "changed_paths"
    }
}

struct TriggerAssessmentDidFinish: AppEvent {
    static let name = Notification.Name("triggerAssessmentDidFinish")
    let run: TriggerRun
    let revision: TriggerRevision
}

struct TriggerFixDidFinish: AppEvent {
    static let name = Notification.Name("triggerFixDidFinish")
    let run: TriggerRun
}
