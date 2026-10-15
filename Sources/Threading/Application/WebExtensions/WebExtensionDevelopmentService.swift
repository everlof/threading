import Foundation

/// The UI and MCP share the same session-owned workers. A tab move never creates a second runner.
@MainActor
protocol WebExtensionServicing: AnyObject {
    func call(_ request: WebExtensionRequest, sessionID: SessionID, project: URL) async -> WebExtensionReply
    func isBusy(_ sessionID: SessionID) -> Bool
    func release(_ sessionID: SessionID)
}

@MainActor
final class WebExtensionDevelopmentService: WebExtensionServicing {
    static let shared = WebExtensionDevelopmentService()
    private var workers: [SessionID: WebExtensionProcess] = [:]
    private var projects: [SessionID: URL] = [:]
    private var busy: Set<SessionID> = []
    private var waiting: [SessionID: UUID] = [:]
    private let observations = AppEventObservations()
    private let currentProject: (SessionID) -> URL?
    private let configuration: (SessionID) -> WebExtensionProcess.Configuration

    init(currentProject: @escaping (SessionID) -> URL? = { id in
        let store = ProjectStore.shared
        guard let session = store.session(withID: id), !session.isArchived,
              !store.sessionRunsOnRemoteHost(id), let directory = store.workingDirectory(forSessionID: id) else { return nil }
        return URL(fileURLWithPath: directory)
    }, configuration: @escaping (SessionID) -> WebExtensionProcess.Configuration = { .bundled(sessionID: $0) }) {
        self.currentProject = currentProject
        self.configuration = configuration
        observations.observe(SessionArchivedStateDidChange.self) { [weak self] event in
            if event.isArchived { self?.release(event.sessionID) }
        }
        observations.observe(SessionProjectDidChange.self) { [weak self] in self?.release($0.sessionID) }
        observations.observe(ProjectsDidChange.self) { [weak self] event in
            switch event.sidebarImpact {
            case .sessionRemoved(_, let id): self?.release(id)
            case .projectRemoved(_, let ids, _): ids.forEach { self?.release($0) }
            default: break
            }
        }
    }

    func call(_ request: WebExtensionRequest, sessionID: SessionID, project: URL) async -> WebExtensionReply {
        guard currentProject(sessionID)?.standardizedFileURL == project.standardizedFileURL else {
            return .failure("This checkout is no longer active for this chat. Reopen Web Extensions from the current checkout.")
        }
        guard waiting[sessionID] == nil else { return .failure("A development operation is already queued. Wait for it to finish.") }
        if busy.contains(sessionID) {
            guard request.action != .events, request.action != .inspect, let current = workers[sessionID] else {
                return .failure("A development operation is already running. Wait for it to finish.")
            }
            // Reserve one command behind the active operation. A background event poll must
            // never make the user's Start/Reload click fail just because its reply is in flight.
            let reservation = UUID()
            waiting[sessionID] = reservation
            defer { if waiting[sessionID] == reservation { waiting.removeValue(forKey: sessionID) } }
            let deadline = Date().addingTimeInterval(180)
            while busy.contains(sessionID), workers[sessionID] === current,
                  !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled, !busy.contains(sessionID), workers[sessionID] === current else {
                return .failure("The queued development operation was cancelled or timed out.")
            }
        }
        if projects[sessionID].map({ $0 != project }) == true { release(sessionID) }
        let worker: WebExtensionProcess
        if let existing = workers[sessionID] { worker = existing }
        else {
            guard workers.count < 4 else { return .failure("Four chats already have extension workbenches. Close one before opening another.") }
            worker = WebExtensionProcess(project: project, configuration: configuration(sessionID))
            workers[sessionID] = worker
            projects[sessionID] = project
        }
        busy.insert(sessionID)
        let reply = await worker.call(request)
        guard workers[sessionID] === worker else { return .failure("This development session has ended.") }
        busy.remove(sessionID)
        if request.action != .events && request.action != .inspect {
            NotificationCenter.default.post(WebExtensionDidChange(sessionID: sessionID))
        }
        return reply
    }

    func isBusy(_ sessionID: SessionID) -> Bool { busy.contains(sessionID) || waiting[sessionID] != nil }

    func release(_ sessionID: SessionID) {
        workers.removeValue(forKey: sessionID)?.cancel()
        projects.removeValue(forKey: sessionID)
        busy.remove(sessionID)
        waiting.removeValue(forKey: sessionID)
    }
}
