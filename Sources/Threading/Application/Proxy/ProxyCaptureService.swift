import Foundation

/// The app owns capture authority and lifecycle; the C worker owns forwarding and payloads.
/// Four processes and four queued calls per owner bound memory and blocking worker threads.
@MainActor
final class ProxyCaptureService {
    static let shared = ProxyCaptureService(configuration: .bundled)
    private let configuration: ProxyProcess.Configuration
    private let observations: AppEventObservations
    private var workers: [SessionID: ProxyProcess] = [:]
    private var draining: [ObjectIdentifier: ProxyProcess] = [:]
    private var pending: [SessionID: Int] = [:]
    private var shuttingDown = false

    init(configuration: ProxyProcess.Configuration, center: NotificationCenter = .default) {
        self.configuration = configuration
        observations = AppEventObservations(center: center)
        observations.observe(TerminalSessionDidEnd.self) { [weak self] in self?.release($0.sessionID) }
        observations.observe(SessionArchivedStateDidChange.self) { [weak self] in
            if $0.isArchived { self?.release($0.sessionID) }
        }
        observations.observe(ProjectsDidChange.self) { [weak self] event in
            switch event.sidebarImpact {
            case .sessionRemoved(_, let sessionID): self?.release(sessionID)
            case .projectRemoved(_, let sessionIDs, _): for sessionID in sessionIDs { self?.release(sessionID) }
            default: break
            }
        }
        observations.observe(SessionProjectDidChange.self) { [weak self] in self?.release($0.sessionID) }
    }

    func call(_ request: TrafficRequest, for sessionID: SessionID) async -> MCPToolResult {
        guard !shuttingDown else { return .failure("Threading is shutting down.") }
        guard pending[sessionID, default: 0] < 4 else { return .failure("This capture already has four pending operations. Retry after one finishes.") }
        let worker: ProxyProcess
        do {
            if case .start(let arguments) = request {
                let scope = try ProxyLaunchScope(arguments)
                if let existing = workers[sessionID] {
                    guard existing.scope == scope else {
                        return .failure("A capture with a different scope is retained in this session. Call traffic_stop with release=true before creating a new scope; retained exchanges are not silently discarded.")
                    }
                    worker = existing
                } else {
                    guard workers.count + draining.count < 4 else { return .failure("Four sessions already own captures. Release one capture with traffic_stop(release=true).") }
                    worker = ProxyProcess(scope: scope, configuration: configuration)
                    workers[sessionID] = worker
                }
            } else if let existing = workers[sessionID] {
                worker = existing
            } else {
                if case .status = request { return .success("{\"running\":false,\"retained_flows\":0,\"capture\":\"not_started\"}") }
                if case .stop = request { return .success("{\"running\":false}") }
                return .failure("No capture belongs to this session. Call traffic_start first.")
            }
        } catch { return .failure(error.localizedDescription) }
        pending[sessionID, default: 0] += 1
        defer {
            let count = pending[sessionID, default: 1] - 1
            if count == 0 { pending.removeValue(forKey: sessionID) } else { pending[sessionID] = count }
        }
        let result = await worker.call(request)
        if case .stop(let arguments) = request, arguments.release == true, workers[sessionID] === worker {
            release(sessionID)
        } else if worker.isCancelled, workers[sessionID] === worker { workers.removeValue(forKey: sessionID) }
        return result
    }

    func release(_ sessionID: SessionID) {
        guard let worker = workers.removeValue(forKey: sessionID) else { return }
        let identity = ObjectIdentifier(worker)
        draining[identity] = worker
        worker.cancel { [weak self] in
            Task { @MainActor in self?.draining.removeValue(forKey: identity) }
        }
    }

    func stopAll() {
        shuttingDown = true
        for sessionID in Array(workers.keys) { release(sessionID) }
    }
}
