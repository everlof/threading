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
        case folderRequired
        case projectNotSaved

        var errorDescription: String? {
            switch self {
            case .automatedRun: "Automated runs cannot reconfigure automations."
            case .noApprovalWindow: "No Threading window is available for approval."
            case .unknownProject:
                "projectID is not a current Threading project. The projects operation lists them, and list_sessions prints this session's own in its heading."
            case .folderRequired:
                "addProject needs folder: the absolute path of an existing directory."
            case .projectNotSaved: "The project could not be saved."
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
                if arguments.operation == "projects" {
                    let page = projectsPage(projects.projects, cursor: arguments.cursor)
                    let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(page) }.value
                    completion(.success(String(decoding: data, as: UTF8.self))); return
                }
                let mutating = !["list", "get", "runs", "workers"].contains(arguments.operation)
                if mutating, let run = try await TriggerStore.shared.run(sessionID: sessionID),
                   [.received, .assessing, .fixQueued, .fixing, .running, .finishing].contains(run.state) {
                    throw Refusal.automatedRun
                }
                if arguments.operation == "addProject" {
                    let added = try await addProject(folder: arguments.folder, to: projects)
                    let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(added) }.value
                    completion(.success(String(decoding: data, as: UTF8.self))); return
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
                    var resolved = arguments
                    if let config = arguments.configuration {
                        let existing = arguments.id.flatMap(TriggerID.init(uuidString:))
                        let alreadySaved: Bool
                        if let existing { alreadySaved = try await TriggerStore.shared.trigger(id: existing) != nil }
                        else { alreadySaved = false }
                        if !alreadySaved {
                            resolved.folder = projects.project(withID: config.projectID)?.folderPath
                        }
                    }
                    completion(.success(try await AutomationCommands.execute(resolved, proposedBy: sessionID, approve: approve)))
                }
            } catch { completion(.failure(error.localizedDescription)) }
        }
    }

    struct ProjectEntry: Encodable, Sendable {
        let id: String
        let name: String
        let folder: String
        let scratchpad: Bool

        init(_ project: Project) {
            id = project.id.uuidString.lowercased()
            name = project.name
            folder = project.folderPath
            scratchpad = project.isScratchpad == true
        }
    }

    struct ProjectsPage: Encodable, Sendable {
        let items: [ProjectEntry]
        let next: Int?
    }

    struct AddedProject: Encodable, Sendable {
        let project: ProjectEntry
        /// False when the folder already was a project; adding is idempotent.
        let added: Bool
    }

    /// Every project's id, so an agent can name where an automation runs without the person
    /// reading an id out of the app. The same 25-row page as `hosts`.
    static func projectsPage(_ projects: [Project], cursor: Int64?) -> ProjectsPage {
        let offset = Int(max(0, min(cursor ?? 0, Int64(projects.count))))
        let items = projects.dropFirst(offset).prefix(25).map(ProjectEntry.init)
        let next = offset + items.count
        return ProjectsPage(items: items, next: next < projects.count ? next : nil)
    }

    /// Adds an existing folder through the sidebar's own `ProjectStore.addProject`, which
    /// returns the existing project for a folder already added. A project starts nothing: work
    /// in it still needs a configured automation whose enable or run the person approves.
    static func addProject(folder: String?, to store: ProjectStore) async throws -> AddedProject {
        let path = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard path.hasPrefix("/") else { throw Refusal.folderRequired }
        // The directory check and symlink resolution touch the filesystem, so they run on a
        // worker; the main actor receives only the resolved path.
        let resolved: String? = await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        }.value
        guard let resolved else { throw Refusal.folderRequired }
        let existed = store.projects.contains { $0.folderPath == resolved }
        guard let project = store.addProject(folderURL: URL(fileURLWithPath: resolved, isDirectory: true)) else {
            throw Refusal.projectNotSaved
        }
        return AddedProject(project: ProjectEntry(project), added: !existed)
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
