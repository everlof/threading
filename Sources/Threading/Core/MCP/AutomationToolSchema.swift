import Foundation

enum AutomationToolSchema {
    private static func string(_ text: String) -> MCPPropertySchema { .init(type: .string, description: text) }
    private static func integer(_ text: String) -> MCPPropertySchema { .init(type: .integer, description: text) }
    static let schedule = MCPPropertySchema(type: .object, description: "Timezone-aware recurrence. Calendar schedules keep local time across DST.", properties: [
        "kind": string("daily, weekdays, weekly, or interval"),
        "timeZone": string("IANA timezone, e.g. Europe/Stockholm or UTC"),
        "hour": integer("0–23; default 9"), "minute": integer("0–59; default 0"),
        "days": .init(type: .array, description: "Selected weekdays, Sunday=1 through Saturday=7. weekly requires one.", items: .init(type: .integer)),
        "intervalMinutes": integer("1–525600; default 60"),
        "anchor": string("ISO-8601 interval anchor. Optional; defaults to the Unix epoch.")
    ], required: ["kind", "timeZone"])
    static let options = MCPPropertySchema(type: .object, description: "Timing and successful-run behavior", properties: [
        "schedule": schedule,
        "missedRunPolicy": string("skip or latest (run once on return); no backlog replay"),
        "archiveOnSuccess": .init(type: .boolean, description: "Archive only after successful completion; preserve history")
    ], required: ["missedRunPolicy", "archiveOnSuccess"])
    static let configuration = MCPPropertySchema(type: .object, description: "Complete local automation replacement. Configure leaves it paused; enable the returned revision when requested by the user.", properties: [
        "name": string("Short name"), "projectID": string("Existing Threading project UUID"),
        "instructions": string("Saved task instructions; no credentials"), "agent": string("Native agent kind, e.g. codex or claude"),
        "account": string("Optional account handle"), "model": string("Optional model"), "reasoningEffort": string("Optional effort"),
        "executionMode": string("taskReadOnly, taskLocalEdits, assessOnly, or assessThenFix"),
        "checkoutPolicy": string("projectCheckout or managedWorktree"), "maximumRuntimeMinutes": integer("1–1440"),
        "options": options, "sourceID": string("Event source UUID; omit for schedules"), "eventKind": string("Source event kind; omit for schedules"),
        "conditions": .init(type: .array, description: "Event match conditions. Empty array for schedules.", items: .init(type: .object, properties: [
            "attribute": string("Attribute name"), "comparison": string("equals, notEquals, contains, exists, greaterThan, lessThan"),
            "value": .init(type: .object, description: "Typed event attribute; omit for exists", properties: [
                "type": string("string, integer, decimal, boolean, or timestamp"), "string": string("String value"),
                "integer": integer("Integer value"), "decimal": .init(type: .number, description: "Decimal value"),
                "boolean": .init(type: .boolean, description: "Boolean value"),
                "timestamp": .init(type: .number, description: "Seconds since 2001-01-01 UTC, matching get results")
            ], required: ["type"])
        ]))
    ], required: ["name", "projectID", "instructions", "agent", "executionMode", "checkoutPolicy", "maximumRuntimeMinutes", "options", "conditions"])
    static let remoteSpec = MCPPropertySchema(type: .object, description: "Complete remote automation replacement. Uses an already configured worker on the target host.", properties: [
        "name": string("Short name"), "workerID": string("Target controller worker UUID"), "instruction": string("Task instructions"),
        "schedule": schedule, "missedPolicy": string("skip or latest"),
        "archiveOnSuccess": .init(type: .boolean, description: "Archive after work completion, confirmed delivery and stopped process")
    ], required: ["name", "workerID", "instruction", "missedPolicy", "archiveOnSuccess"])
    static let input = MCPInputSchema(properties: [
        "operation": string("hosts, workers (remote), list, get, configure, enable, pause, delete, run, or runs"),
        "id": string("Automation UUID. Supply a new UUID for remote configure."),
        "expectedRevision": string("Current local revision UUID or remote integer revision as a string. Remote creation uses 0."),
        "requestKey": string("Stable unique request key for run; reuse on retry"),
        "cursor": integer("Next page cursor from list/runs"), "configuration": configuration,
        "remote": .init(type: .object, description: "Omit for this Mac. Remote operations execute through the controller the user connected for that host, over existing SSH.", properties: [
            "hostID": string("Configured Threading remote host UUID"),
            "executable": string("Optional; must match the host's saved controller executable"),
            "database": string("Optional; must match the host's saved controller database")
        ], required: ["hostID"]),
        "remoteSpec": remoteSpec
    ], required: ["operation"])
}
