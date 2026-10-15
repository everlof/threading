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
    /// The action holding each worker; its deadline bounds how long a queued command waits.
    private var busy: [SessionID: WebExtensionRequest.Action] = [:]
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
        if request.action.isRead {
            if let refusal = await waitForReadTurn(sessionID) { return refusal }
        } else if let refusal = await waitForCommandTurn(sessionID) {
            return refusal
        }
        if projects[sessionID].map({ $0.standardizedFileURL != project.standardizedFileURL }) == true { release(sessionID) }
        let worker: WebExtensionProcess
        if let existing = workers[sessionID] { worker = existing }
        else {
            guard workers.count < WebExtensionDefaults.maximumWorkers else {
                return .failure("\(WebExtensionDefaults.maximumWorkers) chats already have extension workbenches. Close one before opening another.")
            }
            worker = WebExtensionProcess(project: project, configuration: configuration(sessionID))
            workers[sessionID] = worker
            projects[sessionID] = project
        }
        busy[sessionID] = request.action
        let reply = await worker.call(request)
        guard workers[sessionID] === worker else { return .failure("This development session has ended.") }
        busy.removeValue(forKey: sessionID)
        if !request.action.isRead {
            NotificationCenter.default.post(WebExtensionDidChange(sessionID: sessionID))
        }
        return reply
    }

    func isBusy(_ sessionID: SessionID) -> Bool { busy[sessionID] != nil || waiting[sessionID] != nil }

    func release(_ sessionID: SessionID) {
        workers.removeValue(forKey: sessionID)?.cancel()
        projects.removeValue(forKey: sessionID)
        busy.removeValue(forKey: sessionID)
        waiting.removeValue(forKey: sessionID)
    }

    /// A read waits briefly behind another operation, so an agent's read does not fail just
    /// because the panel's poll is in flight. It never takes the queued-command slot and yields
    /// to a queued command; behind a long operation it is refused rather than held.
    private func waitForReadTurn(_ sessionID: SessionID) async -> WebExtensionReply? {
        guard isBusy(sessionID) else { return nil }
        let current = workers[sessionID]
        let deadline = Date().addingTimeInterval(WebExtensionDefaults.readWaitTimeout)
        while isBusy(sessionID), workers[sessionID] === current, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: WebExtensionDefaults.queuePollNanoseconds)
        }
        guard !isBusy(sessionID), workers[sessionID] === current, !Task.isCancelled else {
            return .failure("A development operation is running. Read events again when it finishes.")
        }
        return nil
    }

    /// One command may wait behind an in-flight operation, so a background event poll can never
    /// make the user's Start/Reload click fail. The wait is bounded by the deadline of the action
    /// it is waiting behind (setup runs longest). Further commands are refused.
    private func waitForCommandTurn(_ sessionID: SessionID) async -> WebExtensionReply? {
        guard waiting[sessionID] == nil else { return .failure("A development operation is already queued. Wait for it to finish.") }
        guard let running = busy[sessionID], let current = workers[sessionID] else { return nil }
        let reservation = UUID()
        waiting[sessionID] = reservation
        defer { if waiting[sessionID] == reservation { waiting.removeValue(forKey: sessionID) } }
        let deadline = Date().addingTimeInterval(WebExtensionDefaults.timeout(for: running))
        while busy[sessionID] != nil, workers[sessionID] === current, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: WebExtensionDefaults.queuePollNanoseconds)
        }
        guard !Task.isCancelled, busy[sessionID] == nil, workers[sessionID] === current else {
            return .failure("The queued development operation was cancelled or timed out.")
        }
        // The command now runs; the slot is free for the next one to queue behind it.
        waiting.removeValue(forKey: sessionID)
        return nil
    }
}
