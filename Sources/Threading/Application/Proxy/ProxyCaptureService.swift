import Foundation
import ThreadingExtensionKit

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
    typealias ApprovalPresenter = @MainActor (ProxyClientRequest, ProxyLaunchScope, SessionID,
        @escaping @MainActor (ProxyClientDecision) -> Void) -> (@MainActor () -> Void)?
    var presentClientApproval: ApprovalPresenter?
    private let clientGrants: ProxyClientGrantStore
    private struct PendingApproval {
        let token = UUID()
        let owner: SessionID
        let worker: ProxyProcess
        let request: ProxyClientRequest
    }
    private var approvals: [PendingApproval] = []
    private var activeApproval: UUID?
    private var resolvingApprovals: Set<UUID> = []
    private var dismissApproval: (@MainActor () -> Void)?
    private var accessRevision = 0
    private var revokingClientAccess = false
    private var clientSnapshotRevisions: [SessionID: UInt64] = [:]
    private var clientLeases: [SessionID: UUID] = [:]

    init(configuration: ProxyProcess.Configuration, center: NotificationCenter = .default, clientGrants: ProxyClientGrantStore = .shared) {
        self.configuration = configuration
        self.clientGrants = clientGrants
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
        observations.observe(ExtensionsDidChange.self) { [weak self] _ in self?.releaseChangedMockCaptures() }
    }

    func call(_ request: TrafficRequest, for sessionID: SessionID) async -> MCPToolResult {
        guard !shuttingDown else { return .failure("Threading is shutting down.") }
        guard pending[sessionID, default: 0] < 4 else { return .failure("This capture already has four pending operations. Retry after one finishes.") }
        let worker: ProxyProcess
        do {
            if case .start(let arguments) = request {
                guard !revokingClientAccess else { return .failure("Client access is being revoked. Retry after it finishes.") }
                let scope = try ProxyLaunchScope(arguments)
                let mockRules: [ExtensionTrafficMock]
                if let identifier = scope.mockExtension {
                    guard let declared = ExtensionManager.shared.trafficMocks(for: identifier) else {
                        return .failure("mock_extension must name an enabled extension with declared response fixtures.")
                    }
                    mockRules = declared
                } else {
                    mockRules = []
                }
                if let existing = workers[sessionID] {
                    guard existing.scope == scope else {
                        return .failure("A capture with a different scope is retained in this session. Call traffic_stop with release=true before creating a new scope; retained exchanges are not silently discarded.")
                    }
                    guard existing.mockRules == mockRules else {
                        return .failure("This extension's response fixtures changed. Release this capture and start it again.")
                    }
                    worker = existing
                } else {
                    guard workers.count + draining.count < 4 else { return .failure("Four sessions already own captures. Release one capture with traffic_stop(release=true).") }
                    let lease = UUID()
                    clientLeases[sessionID] = lease
                    worker = ProxyProcess(scope: scope, configuration: configuration, mockRules: mockRules) { [weak self] requests in
                        Task { @MainActor in self?.receiveClients(requests, owner: sessionID, lease: lease) }
                    }
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
        } else if worker.isCancelled, workers[sessionID] === worker { release(sessionID) }
        return result
    }

    func release(_ sessionID: SessionID) {
        clientLeases.removeValue(forKey: sessionID)
        clientSnapshotRevisions.removeValue(forKey: sessionID)
        removeApprovals(for: sessionID)
        guard let worker = workers.removeValue(forKey: sessionID) else { return }
        let identity = ObjectIdentifier(worker)
        draining[identity] = worker
        worker.cancel { [weak self] in
            Task { @MainActor in self?.draining.removeValue(forKey: identity) }
        }
    }

    private func releaseChangedMockCaptures() {
        let affected = workers.compactMap { sessionID, worker -> SessionID? in
            guard let identifier = worker.scope.mockExtension,
                  ExtensionManager.shared.trafficMocks(for: identifier) != worker.mockRules else {
                return nil
            }
            return sessionID
        }
        for sessionID in affected { release(sessionID) }
    }

    private func receiveClients(_ snapshot: ProxyClientSnapshot, owner: SessionID, lease: UUID) {
        guard !revokingClientAccess, clientLeases[owner] == lease, let worker = workers[owner],
              snapshot.revision > clientSnapshotRevisions[owner, default: 0] else { return }
        guard !worker.isCancelled else { release(owner); return }
        clientSnapshotRevisions[owner] = snapshot.revision
        let requests = snapshot.requests
        let removed = approvals.filter { $0.owner == owner && !requests.contains($0.request) }
        approvals.removeAll { $0.owner == owner && !requests.contains($0.request) }
        if let active = activeApproval, removed.contains(where: { $0.token == active }),
           !resolvingApprovals.contains(active) { retirePresentation() }
        for request in requests where !approvals.contains(where: { $0.owner == owner && $0.request == request }) {
            guard approvals.count < ProxyClientLimits.pendingAcrossCaptures else { break }
            let pending = PendingApproval(owner: owner, worker: worker, request: request)
            approvals.append(pending)
            admitRememberedClientWithoutWaitingForOtherPrompts(pending)
        }
        presentNextApproval()
    }

    private func removeApprovals(for owner: SessionID) {
        let removesActive = approvals.contains { $0.owner == owner && $0.token == activeApproval }
        approvals.removeAll { $0.owner == owner }
        if removesActive { retirePresentation() }
        presentNextApproval()
    }

    private func retirePresentation() {
        activeApproval = nil
        let dismiss = dismissApproval
        dismissApproval = nil
        dismiss?()
    }

    private func presentNextApproval() {
        guard activeApproval == nil, !shuttingDown, !revokingClientAccess,
              let next = approvals.first(where: { !resolvingApprovals.contains($0.token) }) else { return }
        activeApproval = next.token
        Task {
            let grant = await clientGrants.lookup(address: next.request.address, scope: next.worker.scope)
            guard activeApproval == next.token, workers[next.owner] === next.worker else { return }
            if grant.remembered { resolveClient(next, decision: .capture, grantRevision: grant.revision); return }
            dismissApproval = presentClientApproval?(next.request, next.worker.scope, next.owner) { [weak self] decision in
                self?.resolveClient(next, decision: decision, grantRevision: grant.revision)
            }
            if dismissApproval == nil { resolveClient(next, decision: .deny, grantRevision: grant.revision) }
        }
    }

    private func admitRememberedClientWithoutWaitingForOtherPrompts(_ pending: PendingApproval) {
        Task {
            // The active candidate already performs this lookup in presentNextApproval.
            guard activeApproval != pending.token else { return }
            let grant = await clientGrants.lookup(address: pending.request.address, scope: pending.worker.scope)
            guard grant.remembered, !shuttingDown, !revokingClientAccess,
                  activeApproval != pending.token, workers[pending.owner] === pending.worker,
                  approvals.contains(where: { $0.token == pending.token }) else { return }
            applyClientDecision(pending, decision: .capture, grantRevision: grant.revision)
        }
    }

    private func resolveClient(_ pending: PendingApproval, decision: ProxyClientDecision, grantRevision: UInt64) {
        guard activeApproval == pending.token else { return }
        applyClientDecision(pending, decision: decision, grantRevision: grantRevision)
    }

    private func applyClientDecision(_ pending: PendingApproval, decision: ProxyClientDecision, grantRevision: UInt64) {
        guard resolvingApprovals.insert(pending.token).inserted else { return }
        // Keep this item as a tombstone until the helper settles. Saving an Always answer must
        // finish before the next prompt checks that grant; other remembered IPs proceed freely.
        if activeApproval == pending.token {
            retirePresentation()
            activeApproval = pending.token
        }
        let revision = accessRevision
        Task {
            let applied = await pending.worker.decideClient(pending.request, decision: decision)
            if applied, decision == .always, workers[pending.owner] === pending.worker, revision == accessRevision {
                await clientGrants.remember(address: pending.request.address, scope: pending.worker.scope, revision: grantRevision)
            }
            resolvingApprovals.remove(pending.token)
            approvals.removeAll { $0.token == pending.token }
            if activeApproval == pending.token { retirePresentation() }
            presentNextApproval()
        }
    }

    /// Stop forwarding and retire pending questions while preserving debugging history.
    /// The store's revision also refuses an older save that resumes after revocation.
    func revokeSavedClientAccess() async {
        guard !revokingClientAccess else { return }
        revokingClientAccess = true
        accessRevision += 1
        let captures = workers.filter { $0.value.scope.asksClients }
        for owner in captures.keys { removeApprovals(for: owner) }
        await clientGrants.removeAll()
        await withTaskGroup(of: SessionID.self) { group in
            for (owner, worker) in captures {
                group.addTask {
                    _ = await worker.call(.stop(TrafficStopArguments(release: false)))
                    return owner
                }
            }
            for await owner in group {
                if let worker = captures[owner], worker.isCancelled, workers[owner] === worker { release(owner) }
            }
        }
        revokingClientAccess = false
        presentNextApproval()
    }

    func stopAll() {
        shuttingDown = true
        for sessionID in Array(workers.keys) { release(sessionID) }
    }
}
