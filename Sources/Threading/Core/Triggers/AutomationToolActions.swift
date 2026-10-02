import Foundation

@MainActor
enum AutomationToolActions {
    enum Refusal: LocalizedError {
        case automatedRun
        case noApprovalWindow
        case remoteNotConnected
        case remotePathsDiffer
        case unknownProject
        case unknownHost

        var errorDescription: String? {
            switch self {
            case .automatedRun: "Automated runs cannot reconfigure automations."
            case .noApprovalWindow: "No Threading window is available for approval."
            case .unknownProject:
                "projectID is not a current Threading project. list_sessions prints this project's id in its heading."
            case .unknownHost:
                "hostID is not a configured remote host. The hosts operation lists the configured ones."
            case .remoteNotConnected:
                "This host has no saved controller connection. Ask the user to connect it under Automations ▸ Remote first."
            case .remotePathsDiffer:
                "The controller paths differ from this host's saved connection. Omit them to use the saved ones."
            }
        }
    }

    /// `approve` is the host's sheet, or nil when no window can show one — in which case enabling
    /// and running are refused rather than performed unasked.
    static func manage(_ arguments: AutomationToolArguments, for sessionID: SessionID,
                       projects: ProjectStore, approve: AutomationApprover?, completion: @escaping TriggerToolCompletion) {
        Task { @MainActor in
            do {
                if arguments.operation == "hosts" {
                    let records = RemoteHostStore.shared.ordered
                    struct Page: Encodable, Sendable { let items: [RemoteHostRecord]; let next: Int? }
                    let offset = Int(max(0, min(arguments.cursor ?? 0, Int64(records.count))))
                    let items = Array(records.dropFirst(offset).prefix(25))
                    let next = offset + items.count
                    let page = Page(items: items, next: next < records.count ? next : nil)
                    let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(page) }.value
                    completion(.success(String(decoding: data, as: UTF8.self))); return
                }
                let mutating = !["list", "get", "runs", "workers"].contains(arguments.operation)
                if mutating, let run = try await TriggerStore.shared.run(sessionID: sessionID),
                   [.received, .assessing, .fixQueued, .fixing, .running, .finishing].contains(run.state) {
                    throw Refusal.automatedRun
                }
                let needsApproval = AutomationApprovalRequest.Operation(rawValue: arguments.operation) != nil
                if needsApproval, approve == nil { throw Refusal.noApprovalWindow }
                let approve: AutomationApprover = approve ?? { _ in false }
                if let remote = arguments.remote {
                    guard let host = RemoteHostStore.shared.host(withID: remote.hostID) else { throw Refusal.unknownHost }
                    var resolved = arguments
                    resolved.remote = try endpoint(for: host, requested: remote)
                    completion(.success(try await AutomationCommands.remote(resolved, destination: host.sshDestination,
                        hostName: host.displayName, approve: approve)))
                } else {
                    try requireKnownProject(arguments.configuration) { projects.project(withID: $0) != nil }
                    completion(.success(try await AutomationCommands.execute(arguments, proposedBy: sessionID, approve: approve)))
                }
            } catch { completion(.failure(error.localizedDescription)) }
        }
    }

    /// An unknown project is the caller's mistake, not a vanished record: saying "no longer
    /// exists" sent agents hunting for an automation they had never created.
    static func requireKnownProject(_ configuration: AutomationConfiguration?,
                                    exists: (ProjectID) -> Bool) throws {
        if let configuration, !exists(configuration.projectID) { throw Refusal.unknownProject }
    }

    /// The controller an agent reaches is the one the person connected from the Remote page,
    /// never a path the agent supplies: otherwise any conversation could have the Mac execute an
    /// arbitrary program on that host over the person's SSH identity.
    static func endpoint(for host: RemoteHostRecord, requested: RemoteAutomationEndpoint) throws -> RemoteAutomationEndpoint {
        guard let executable = host.controllerExecutable, let database = host.controllerDatabase else {
            throw Refusal.remoteNotConnected
        }
        guard requested.executable.isEmpty || requested.executable == executable,
              requested.database.isEmpty || requested.database == database else {
            throw Refusal.remotePathsDiffer
        }
        return RemoteAutomationEndpoint(hostID: host.id, executable: executable, database: database)
    }
}
