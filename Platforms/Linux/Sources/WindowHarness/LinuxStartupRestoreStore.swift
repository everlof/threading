#if os(Linux)
import Foundation
@testable import CoreSlice

/// Durable half of Linux startup restoration. Every database pass runs on a bounded worker;
/// the native event loop receives only the chosen identities and their recorded outcomes.
enum LinuxStartupRestoreStore {
    private static let worker = DispatchQueue(label: "threading.linux.startup-restore",
                                              qos: .utility)
    private static let pendingQuits = DispatchGroup()

    struct Launch: Sendable {
        let session: AgentSession
        let projectID: ProjectID
    }

    struct Preparation: Sendable {
        let recorded: [SessionID]
        let plan: StartupSessionRelaunch.Plan
        let launches: [Launch]
        let stoppedNativeIDs: Set<SessionID>
        let hostSurveySucceeded: Bool
    }

    final class ConsumeReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Bool, Error>?
        private var delivered = false

        fileprivate func finish(_ value: Result<Bool, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<Bool, Error>? {
            lock.lock(); defer { lock.unlock() }
            guard !delivered, let result else { return nil }
            delivered = true
            return result
        }
        fileprivate var succeeded: Bool {
            lock.lock(); defer { lock.unlock() }
            if case .success(true) = result { return true }
            return false
        }
    }

    struct PendingConsume: Sendable {
        let receipt: ConsumeReceipt
        let owed: Set<SessionID>
    }

    /// Read, but do not yet spend, the last quit's record. The UI commits the consume only when
    /// it is ready to use the plan; an immediate open-and-quit must preserve the previous list.
    static func prepare(store: String, socket: String, excluding selected: SessionID?,
                        stopSelectedHeldNative: Bool = false) throws
        -> Preparation {
        let (recorded, members) = try LinuxStoreMutation.withDatabase(at: store) { database in
            let recorded = try database.runningSessionIDs()
            let members = try database.load().state.projects.flatMap { project in
                project.sessions.map { Launch(session: $0, projectID: project.id) }
            }
            return (recorded, members)
        }
        let summaries = GraphicalTerminal.agentSummaries(socket: socket)
        let known = Set(members.filter { !$0.session.isArchived }.map { $0.session.id })
        var held: Set<SessionID> = []
        var stoppedNativeIDs: Set<SessionID> = []
        for summary in summaries ?? [] {
            guard case .agentSession(let id) = summary.id.identity,
                  known.contains(id) else { continue }
            switch PTYHostHeldDisposition.classify(summary, isKnown: true) {
            case .adopt:
                held.insert(id)
            case .ended:
                if id == selected, stopSelectedHeldNative { stoppedNativeIDs.insert(id) }
                else { held.insert(id) }
            case .resumeFromTranscript:
                if id == selected, !stopSelectedHeldNative {
                    held.insert(id)
                    continue
                }
                let stopped = PTYHostSessionStop.run(summary.id, socketPath: socket,
                                                     build: "linux-native-window")
                if stopped {
                    stoppedNativeIDs.insert(id)
                } else {
                    switch GraphicalTerminal.agentPresence(socket: socket, id: id) {
                    case .absent, .exited: stoppedNativeIDs.insert(id)
                    case .running, .unavailable: held.insert(id)
                    }
                }
            case .orphan: break
            }
        }
        // The selected pipe child can exit between the window's initial survey and this
        // preparation pass. Its absence is also a safe handoff: no old writer remains.
        if stopSelectedHeldNative, summaries != nil, let selected,
           known.contains(selected), !held.contains(selected) {
            stoppedNativeIDs.insert(selected)
        }
        let plan = StartupSessionRelaunch.plan(
            policy: LinuxGeneralSettings.sessionRestorePolicy,
            recorded: recorded,
            sessions: members.map(\.session),
            windowDays: LinuxGeneralSettings.sessionRestoreWindowDays,
            limit: LinuxGeneralSettings.sessionRestoreLimit,
            excluding: selected,
            heldByHost: held
        )
        let byID = Dictionary(members.map { ($0.session.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let launches = plan.sessionIDs.compactMap { byID[$0] }
        return Preparation(recorded: recorded, plan: plan, launches: launches,
                           stoppedNativeIDs: stoppedNativeIDs,
                           hostSurveySucceeded: summaries != nil)
    }

    static func prepareLater(store: String, socket: String, excluding selected: SessionID?,
                             stopSelectedHeldNative: Bool = false,
                             completion: @escaping @Sendable (Result<Preparation, Error>) -> Void) {
        worker.async {
            completion(Result { try prepare(store: store, socket: socket,
                                            excluding: selected,
                                            stopSelectedHeldNative: stopSelectedHeldNative) })
        }
    }

    /// Consume only the record whose plan was applied. A changed record belongs to another
    /// writer and cannot be silently discarded by this launch.
    static func consume(store: String, expected recorded: [SessionID]) throws -> Bool {
        return try LinuxStoreMutation.withDatabase(at: store) { database in
            guard try database.runningSessionIDs() == recorded else { return false }
            try database.saveRunningSessionIDs([])
            return true
        }
    }

    static func consumeLater(store: String, expected recorded: [SessionID],
                             completion: @escaping @Sendable () -> Void) -> ConsumeReceipt {
        let receipt = ConsumeReceipt()
        worker.async {
            receipt.finish(Result { try consume(store: store, expected: recorded) })
            completion()
        }
        return receipt
    }

    /// A clean quit replaces the spent record with the agents this window was still running.
    /// An empty launch that never consumed its predecessor leaves that predecessor intact.
    static func recordCleanQuit(store: String, running: [SessionID], consumed: Bool) throws -> Bool {
        guard !running.isEmpty || consumed else { return false }
        return try LinuxStoreMutation.withDatabase(at: store) { database in
            // A daemon can serve several stores. Only identities in this store may replace its
            // last-quit record, even if another app instance left children in that daemon.
            var local: [SessionID] = []
            for id in running {
                if let record = try database.sessionRecord(id: id), !record.session.isArchived {
                    local.append(id)
                }
            }
            // A consume request that lost an exact-record race cannot erase the newer record
            // when the window closes before its worker receipt reaches the UI.
            let recordWasSpent: Bool
            if consumed { recordWasSpent = try database.runningSessionIDs().isEmpty }
            else { recordWasSpent = false }
            guard !local.isEmpty || recordWasSpent else { return false }
            try database.saveRunningSessionIDs(local)
            return true
        }
    }

    /// The window hands us its bounded in-memory live set before closing clients. The daemon
    /// list adds children inherited from an earlier launch; the captured set covers a socket
    /// failure or a spawn whose first reply has not reached the UI yet.
    static func recordCleanQuitLater(store: String, socket: String,
                                     captured: Set<SessionID>, consumed: Bool,
                                     retired: Set<SessionID> = [],
                                     pendingConsume: PendingConsume? = nil) {
        pendingQuits.enter()
        worker.async {
            defer { pendingQuits.leave() }
            let daemon = GraphicalTerminal.runningAgentIDs(socket: socket) ?? []
            // The serial lane completes an exact consume before this quit task. A refused
            // consume must not let its stale unlaunched plan replace another writer's record.
            let owed = pendingConsume?.receipt.succeeded == true
                ? pendingConsume?.owed ?? [] : []
            let running = Array(daemon.union(captured).union(owed).subtracting(retired)).sorted {
                $0.uuidString < $1.uuidString
            }
            do {
                let wrote = try recordCleanQuit(store: store, running: running, consumed: consumed)
                print("STARTUP_RESTORE_QUIT surveyed=\(running.count) recordWritten=\(wrote)")
            } catch {
                FileHandle.standardError.write(Data("Startup restore quit record: \(error)\n".utf8))
            }
        }
    }

    static func finishPendingQuits() async {
        let completed = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: pendingQuits.wait(timeout: .now() + 3) == .success)
            }
        }
        if !completed {
            FileHandle.standardError.write(Data("STARTUP_RESTORE_QUIT_TIMEOUT\n".utf8))
        }
    }
}
#endif
