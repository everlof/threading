import Foundation
import ThreadingController

struct AutomationToolArguments: Codable, Sendable {
    var operation: String
    var id: String?
    var expectedRevision: String?
    var requestKey: String?
    var configuration: AutomationConfiguration?
    var remote: RemoteAutomationEndpoint?
    var remoteSpec: ControllerAutomationSpec?
    var cursor: Int64?
    /// `addProject` only: the absolute path of an existing folder.
    var folder: String?
}

struct AutomationSnapshot: Codable, Sendable {
    let id: TriggerID
    let revision: TriggerRevisionID
    let enabled: Bool
    let configuration: AutomationConfiguration
    let nextRunAt: Date?
}

/// Enabling or running an automation starts unattended work. When an agent asks for either,
/// the person approves the exact revision in a host sheet: an agent's report that they wanted it
/// is not the authority, whatever the conversation says. Host UI paths pass no approver, because
/// there the person is already the one acting.
enum AutomationApprovalRequest: Sendable {
    enum Operation: String, Sendable { case enable, run }
    case local(Operation, name: String, revision: TriggerRevision)
    case remote(Operation, automation: ControllerAutomation, hostName: String)

    var operation: Operation {
        switch self {
        case .local(let operation, _, _), .remote(let operation, _, _): operation
        }
    }
}

typealias AutomationApprover = @MainActor @Sendable (AutomationApprovalRequest) async -> Bool

enum AutomationCommandError: LocalizedError {
    case notApproved
    case remoteRevisionChanged
    case remoteSpecTooLarge

    var errorDescription: String? {
        switch self {
        case .notApproved: L10n.string("The user did not approve this automation.")
        case .remoteRevisionChanged: L10n.string("The remote automation changed. Inspect it again before retrying.")
        case .remoteSpecTooLarge: L10n.string("The name or instructions are too long for a remote automation.")
        }
    }
}

/// The UI and MCP call these exact operations. Persistence and revision checks stay in the
/// store; presentation never implements its own scheduling or permission rules.
enum AutomationCommands {
    /// The controller's own bounds, checked here so an oversized spec fails with a reason.
    private static let remoteInstructionBytes = 32_768
    private static let remoteNameBytes = 160

    static func execute(_ args: AutomationToolArguments, store: TriggerStore = .shared,
                        proposedBy: SessionID? = nil, approve: AutomationApprover? = nil) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let id = args.id.flatMap(TriggerID.init(uuidString:))
        let expected = args.expectedRevision.flatMap(TriggerRevisionID.init(uuidString:))
        guard args.id == nil || id != nil, args.expectedRevision == nil || expected != nil else {
            throw TriggerStore.StoreError.invalidRecord("invalid automation or revision UUID")
        }
        switch args.operation {
        case "list":
            let pairs = try await store.triggers()
            let offset = Int(max(0, min(args.cursor ?? 0, Int64(pairs.count))))
            var snapshots: [AutomationSnapshot] = []
            for pair in pairs.dropFirst(offset).prefix(25) {
                snapshots.append(AutomationSnapshot(id: pair.definition.id, revision: pair.revision.id,
                    enabled: pair.definition.enabled,
                    configuration: .init(definition: pair.definition, revision: pair.revision),
                    nextRunAt: try await store.nextAutomationDate(pair.definition.id)))
            }
            struct Page: Encodable { let items: [AutomationSnapshot]; let next: Int? }
            let next = offset + snapshots.count
            return try json(Page(items: snapshots, next: next < pairs.count ? next : nil))
        case "get":
            guard let id, let pair = try await store.trigger(id: id) else { throw TriggerStore.StoreError.missing }
            return try json(AutomationSnapshot(id: id, revision: pair.revision.id, enabled: pair.definition.enabled,
                configuration: .init(definition: pair.definition, revision: pair.revision),
                nextRunAt: try await store.nextAutomationDate(id)))
        case "configure":
            guard let config = args.configuration else { throw TriggerStore.StoreError.invalidRecord("configuration required") }
            let actualID = id ?? TriggerID()
            let revision = try await store.configureAutomation(config, id: actualID,
                expectedRevision: expected, proposedBy: proposedBy)
            return try json(AutomationSnapshot(id: actualID, revision: revision.id, enabled: false,
                configuration: config, nextRunAt: nil))
        case "enable", "pause", "delete", "run":
            guard let id, let expected, let pair = try await store.trigger(id: id), pair.revision.id == expected else {
                throw TriggerStore.StoreError.invalidRecord("id and current expectedRevision required")
            }
            if args.operation == "run", args.requestKey == nil {
                throw TriggerStore.StoreError.invalidRecord("requestKey required for retry-safe run")
            }
            // The store re-checks the revision after the sheet, so approval names what runs.
            if let approve, let operation = AutomationApprovalRequest.Operation(rawValue: args.operation) {
                guard await approve(.local(operation, name: pair.definition.name, revision: pair.revision)) else {
                    throw AutomationCommandError.notApproved
                }
            }
            switch args.operation {
            case "enable": try await store.activate(triggerID: id, revisionID: expected)
            case "pause": try await store.setEnabled(false, triggerID: id, expectedRevision: expected)
            case "delete": try await store.removeAutomation(id, expectedRevision: expected)
            default:
                guard let key = args.requestKey else { throw TriggerStore.StoreError.invalidRecord("requestKey required for retry-safe run") }
                let dispatch = try await store.runAutomationNow(id, expectedRevision: expected, requestKey: key)
                if dispatch.run.state == .received { try await TriggerRuntime.shared.publish([dispatch]) }
                return try json(dispatch.run)
            }
            return "{\"ok\":true}"
        case "runs":
            guard let id else { throw TriggerStore.StoreError.invalidRecord("id required") }
            return try json(try await store.runPage(triggerID: id, before: args.cursor))
        default: throw TriggerStore.StoreError.invalidRecord("unknown automation operation")
        }
    }

    static func remote(_ args: AutomationToolArguments, destination: RemoteHostDestination,
                       hostName: String = "", approve: AutomationApprover? = nil) async throws -> String {
        guard let endpoint = args.remote else { throw TriggerStore.StoreError.missing }
        var arguments: [RemoteAutomationClient.Argument] = []
        let command: String
        switch args.operation {
        case "workers": command = "workers"; arguments = [.init(value: String(args.cursor ?? 0))]
        case "list": command = "automations"; arguments = [.init(value: String(args.cursor ?? 0))]
        case "get", "runs":
            guard let id = args.id else { throw TriggerStore.StoreError.invalidRecord("id required") }
            command = args.operation == "get" ? "automation" : "automation-runs"
            arguments = [.init(value: id)]
            if args.operation == "runs" { arguments.append(.init(value: String(args.cursor ?? 0))) }
        case "configure", "enable", "pause", "delete", "run":
            guard let id = args.id, let revision = args.expectedRevision else { throw TriggerStore.StoreError.invalidRecord("id and expectedRevision required") }
            command = "automation-" + args.operation
            arguments = [.init(value: id), .init(value: revision)]
            if args.operation == "configure" {
                guard let spec = args.remoteSpec else { throw TriggerStore.StoreError.invalidRecord("remoteSpec required") }
                guard spec.instruction.utf8.count <= remoteInstructionBytes, spec.name.utf8.count <= remoteNameBytes else {
                    throw AutomationCommandError.remoteSpecTooLarge
                }
                arguments.append(.init(text: String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)))
            }
            if args.operation == "run" {
                guard let key = args.requestKey else { throw TriggerStore.StoreError.invalidRecord("requestKey required") }
                arguments.append(.init(value: key))
            }
            if let approve, let operation = AutomationApprovalRequest.Operation(rawValue: args.operation) {
                // Show the person what the controller holds now, at the revision being enabled.
                let current = try await RemoteAutomationClient.shared.request(endpoint: endpoint, destination: destination,
                    command: "automation", arguments: [.init(value: id)])
                let automation = try JSONDecoder().decode(ControllerAutomation.self, from: Data(current.utf8))
                guard String(automation.revision) == revision, !automation.deleted else {
                    throw AutomationCommandError.remoteRevisionChanged
                }
                guard await approve(.remote(operation, automation: automation, hostName: hostName)) else {
                    throw AutomationCommandError.notApproved
                }
            }
        default: throw TriggerStore.StoreError.invalidRecord("unknown automation operation")
        }
        return try await RemoteAutomationClient.shared.request(endpoint: endpoint, destination: destination,
            command: command, arguments: arguments)
    }
}
