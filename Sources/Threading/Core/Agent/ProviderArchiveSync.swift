import AppKit
import Foundation

// MARK: - Provider State

enum ProviderArchiveLocation: Equatable, Sendable {
    case active
    case archived
    case absent
    case ambiguous

    var archivedValue: Bool? {
        switch self {
        case .active: return false
        case .archived: return true
        case .absent, .ambiguous: return nil
        }
    }
}

/// One account's observable archive state, read from the two stores the provider itself moves
/// rollouts between. The filename carries the UUID; the transcript body is never opened.
struct ProviderArchiveSnapshot: Sendable {
    let locations: [TranscriptID: ProviderArchiveLocation]

    subscript(sessionID: TranscriptID) -> ProviderArchiveLocation {
        locations[sessionID] ?? .absent
    }

    static func read(
        account: AgentAccount,
        sessionIDs: Set<TranscriptID>,
        fileManager: FileManager = FileManager()
    ) -> ProviderArchiveSnapshot? {
        let root = URL(fileURLWithPath: account.configPath)
        guard let active = rolloutIDs(
            beneath: root.appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory),
            matching: sessionIDs,
            fileManager: fileManager
        ), let archived = rolloutIDs(
            beneath: root.appendingPathComponent(ProviderArchiveDefaults.archivedDirectory),
            matching: sessionIDs,
            fileManager: fileManager
        ) else { return nil }

        let locations = Dictionary(uniqueKeysWithValues: sessionIDs.map { sessionID in
            let location: ProviderArchiveLocation
            switch (active.contains(sessionID), archived.contains(sessionID)) {
            case (true, false): location = .active
            case (false, true): location = .archived
            case (false, false): location = .absent
            case (true, true): location = .ambiguous
            }
            return (sessionID, location)
        })
        return ProviderArchiveSnapshot(locations: locations)
    }

    private static func rolloutIDs(
        beneath root: URL,
        matching sessionIDs: Set<TranscriptID>,
        fileManager: FileManager
    ) -> Set<TranscriptID>? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return nil }

        // Transcript ids are UUIDs and therefore case-insensitive. Build this defensively rather
        // than using `uniqueKeysWithValues`: an imported record that differs only in UUID casing
        // must not be able to trap a launch-time reconciliation.
        var wanted: [String: TranscriptID] = [:]
        for sessionID in sessionIDs {
            wanted[sessionID.rawValue.lowercased()] = sessionID
        }
        var found = Set<TranscriptID>()
        for case let url as URL in enumerator {
            guard url.pathExtension == CodexDiscoveryDefaults.rolloutExtension,
                  url.lastPathComponent.hasPrefix(CodexDiscoveryDefaults.rolloutPrefix)
            else { continue }

            let stem = url.deletingPathExtension().lastPathComponent
            let rawID = String(stem.suffix(ProviderArchiveDefaults.uuidLength)).lowercased()
            guard UUID(uuidString: rawID) != nil, let sessionID = wanted[rawID] else { continue }
            found.insert(sessionID)
        }
        return found
    }
}

// MARK: - Three-Way Reconciliation

struct ProviderArchiveReconciliationPlan: Equatable, Sendable {
    /// A provider command is needed only when its observed value is not the target.
    let providerTarget: Bool?
    /// The value both sides record once that command, if any, succeeds.
    let synchronizedState: Bool

    static func make(local: Bool, provider: Bool, lastSynchronized: Bool?) -> Self {
        let target: Bool
        if let lastSynchronized {
            if local == provider {
                target = local
            } else if local == lastSynchronized {
                // Only the provider moved since the last agreement: mirror its external action.
                target = provider
            } else {
                // Only Threading moved: carry its local action out to the provider.
                target = local
            }
        } else {
            // Migration has no chronological base. Archive is reversible; resurfacing a filed
            // conversation is surprising. Preserve either side's existing archive intent.
            target = local || provider
        }

        return Self(
            providerTarget: provider == target ? nil : target,
            synchronizedState: target
        )
    }
}

// MARK: - Command

struct ProviderArchiveCommand: Equatable, Sendable {
    let shellPath: String
    let source: String
    let providerName: String
    let archives: Bool

    @MainActor
    static func make(
        archives: Bool,
        session: AgentSession,
        transcriptID: TranscriptID,
        account: AgentAccount
    ) -> Self {
        var command = AgentAccountRouting.prefix(for: session.kind, account: account)
        command.append(word: session.kind.executableName)
        command.append(word: archives ? "archive" : "unarchive")
        command.append(word: transcriptID.rawValue)
        return Self(
            shellPath: AgentLauncher.loginShellPath,
            source: command.source,
            providerName: session.kind.displayName,
            archives: archives
        )
    }
}

enum ProviderArchiveFailure: LocalizedError, Equatable, Sendable {
    case alreadyChanging
    case sessionNotFound
    case persistenceUnavailable(processStopped: Bool)
    case accountUnavailable(String)
    case commandCouldNotLaunch(provider: String, archives: Bool, detail: String)
    case commandRejected(provider: String, archives: Bool, detail: String)

    /// Whether an archive failure happened after the running writer had to be stopped.
    /// Presentation uses this instead of inferring from "the session used to be running": known
    /// persistence and account refusals happen before teardown, while provider command failures
    /// happen after it.
    var stoppedAgentBeforeFailure: Bool {
        switch self {
        case .persistenceUnavailable(let processStopped): return processStopped
        case .commandCouldNotLaunch(_, let archives, _),
             .commandRejected(_, let archives, _): return archives
        case .alreadyChanging, .sessionNotFound, .accountUnavailable: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .alreadyChanging:
            return L10n.string("This conversation’s archive state is already changing.")
        case .sessionNotFound:
            return L10n.string("This conversation no longer exists.")
        case .persistenceUnavailable:
            return L10n.string("The archive state could not be saved.")
        case .accountUnavailable(let provider):
            return L10n.format("%@ could not find the account that owns this conversation.", provider)
        case .commandCouldNotLaunch(let provider, _, let detail):
            return L10n.format("%@ could not start its archive command: %@", provider, detail)
        case .commandRejected(let provider, let archives, let detail):
            return archives
                ? L10n.format("%@ could not archive this conversation: %@", provider, detail)
                : L10n.format("%@ could not restore this conversation: %@", provider, detail)
        }
    }
}

private enum ProviderArchiveCommandRunner {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "codes.threading.provider-archive.commands"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = ProviderArchiveDefaults.maximumConcurrentCommands
        return queue
    }()

    static func run(
        _ command: ProviderArchiveCommand,
        completion: @escaping @MainActor @Sendable (Result<Void, ProviderArchiveFailure>) -> Void
    ) {
        queue.addOperation {
            let result = runSynchronously(command)
            Task { @MainActor in completion(result) }
        }
    }

    private static func runSynchronously(
        _ command: ProviderArchiveCommand
    ) -> Result<Void, ProviderArchiveFailure> {
        let started = DispatchTime.now().uptimeNanoseconds
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: command.shellPath,
                arguments: ["-l", "-c", command.source],
                environment: AgentEnvironment.launchEnvironment(),
                timeout: ProviderArchiveDefaults.commandTimeout,
                maximumOutputBytes: ProviderArchiveDefaults.maximumCommandOutputBytes
            )
        } catch {
            ThreadingLogger.session.error(
                "Provider archive command launch failed provider=\(command.providerName, privacy: .private(mask: .hash)) archives=\(command.archives, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .failure(.commandCouldNotLaunch(
                provider: command.providerName,
                archives: command.archives,
                detail: error.localizedDescription
            ))
        }
        guard result.termination == .exited(0) else {
            let elapsedMilliseconds = (
                DispatchTime.now().uptimeNanoseconds - started
            ) / 1_000_000
            let resultCode: String
            let status: Int32
            switch result.termination {
            case .timedOut:
                resultCode = "timed_out"
                status = -1
            case .exited(let exitStatus):
                resultCode = "exited"
                status = exitStatus
            }
            ThreadingLogger.session.warning(
                "Provider archive command rejected provider=\(command.providerName, privacy: .private(mask: .hash)) archives=\(command.archives, privacy: .public) result=\(resultCode, privacy: .public) status=\(status, privacy: .public) output_bytes=\(result.output.count, privacy: .public) duration_ms=\(elapsedMilliseconds, privacy: .public)"
            )
            let reported = String(decoding: result.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if !reported.isEmpty {
                detail = String(reported.prefix(ProviderArchiveDefaults.maximumErrorLength))
            } else {
                switch result.termination {
                case .timedOut:
                    detail = L10n.string("the command took too long to answer")
                case .exited(let status):
                    detail = L10n.format("the command exited with status %lld", Int64(status))
                }
            }
            return .failure(.commandRejected(
                provider: command.providerName,
                archives: command.archives,
                detail: detail
            ))
        }
        let elapsedMilliseconds = (
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000
        ThreadingLogger.session.info(
            "Provider archive command completed provider=\(command.providerName, privacy: .private(mask: .hash)) archives=\(command.archives, privacy: .public) duration_ms=\(elapsedMilliseconds, privacy: .public)"
        )
        return .success(())
    }
}

// MARK: - Synchronizer

/// Keeps Threading's filing flag and a capable runtime's reversible archive in agreement.
///
/// User actions are committed locally only after the provider command succeeds. External changes
/// are reconciled at launch and whenever Threading becomes active again — the natural edge after
/// archiving from another app — using the persisted last agreement to infer which side moved.
@MainActor
final class ProviderArchiveSync {
    static let shared = ProviderArchiveSync()

    typealias Completion = @MainActor @Sendable (Result<Void, ProviderArchiveFailure>) -> Void
    typealias ProcessStopper = @MainActor (
        _ sessionID: SessionID,
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> Void
    typealias ReconciliationProcessStopper = @MainActor (
        _ sessionIDs: [SessionID],
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private struct Candidate: Sendable {
        let sessionID: SessionID
        let transcriptID: TranscriptID
        let account: AgentAccount
    }

    private struct Batch: Sendable {
        let account: AgentAccount
        var candidates: [Candidate]
    }

    private let store: ProjectStore
    private let center: NotificationCenter
    private let processStopper: ProcessStopper
    private let reconciliationProcessStopper: ReconciliationProcessStopper
    private var observations: AppEventObservations?
    private var pending = Set<SessionID>()
    private var reconciliationGeneration = 0
    private var hasStarted = false

    init(
        store: ProjectStore = .shared,
        center: NotificationCenter = .default,
        processStopper: @escaping ProcessStopper = { sessionID, completion in
            PTYHostArchiveStop.run(sessionID: sessionID, completion: completion)
        },
        reconciliationProcessStopper: @escaping ReconciliationProcessStopper = { sessionIDs, completion in
            PTYHostArchiveStop.run(sessionIDs: sessionIDs, completion: completion)
        }
    ) {
        self.store = store
        self.center = center
        self.processStopper = processStopper
        self.reconciliationProcessStopper = reconciliationProcessStopper
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        ThreadingLogger.session.info("Provider archive reconciliation started")

        let observations = AppEventObservations(center: center)
        observations.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.reconcile()
        }
        self.observations = observations
        reconcile()
    }

    /// Files or restores one session. Completion is always delivered on the main actor.
    func setArchived(
        _ archived: Bool,
        for sessionID: SessionID,
        completion: @escaping Completion
    ) {
        reconciliationGeneration += 1
        ThreadingLogger.session.info(
            "Provider archive change requested session=\(sessionID.uuidString, privacy: .public) archived=\(archived, privacy: .public)"
        )
        guard let session = store.session(withID: sessionID) else {
            completion(.failure(.sessionNotFound))
            return
        }
        guard pending.insert(sessionID).inserted else {
            completion(.failure(.alreadyChanging))
            return
        }

        guard session.kind.supports(.providerArchive),
              let transcriptID = session.resumeState.transcriptID else {
            switch store.setArchived(archived, for: sessionID) {
            case .applied, .unchanged:
                let wasArchived = session.isArchived
                if archived {
                    // A local-only provider can still be running in `threading-ptyd`. The row is
                    // already durable, so start the same stop as an in-process surface without
                    // keeping the pane and pending state behind the daemon's bounded I/O.
                    processStopper(sessionID) {}
                }
                pending.remove(sessionID)
                announceIfLocalStateChanged(
                    sessionID: sessionID,
                    from: wasArchived,
                    to: archived
                )
                completion(.success(()))
            case .targetNotFound:
                pending.remove(sessionID)
                completion(.failure(.sessionNotFound))
            case .persistenceRefused, .unsupportedValue:
                pending.remove(sessionID)
                completion(.failure(.persistenceUnavailable(processStopped: false)))
            }
            return
        }
        // Provider archive is a two-system transaction. Do not stop a live process or move its
        // rollout when this store already knows it cannot record the matching local state.
        guard store.acceptsDurableMutations else {
            pending.remove(sessionID)
            completion(.failure(.persistenceUnavailable(processStopped: false)))
            return
        }
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else {
            pending.remove(sessionID)
            completion(.failure(.accountUnavailable(session.kind.displayName)))
            return
        }

        // Codex moves the rollout file, so every writer must be gone before the provider command.
        // That includes a controller cached by this process and a child `threading-ptyd` kept
        // alive across a restart. The latter is invisible to `AgentRuntime`, so the asynchronous
        // stop is a barrier in front of both the provider snapshot and the command.
        if archived {
            processStopper(sessionID) { [weak self] in
                self?.continueUserChange(
                    archives: archived,
                    sessionID: sessionID,
                    transcriptID: transcriptID,
                    account: account,
                    completion: completion
                )
            }
            return
        }
        continueUserChange(
            archives: archived,
            sessionID: sessionID,
            transcriptID: transcriptID,
            account: account,
            completion: completion
        )
    }

    private func continueUserChange(
        archives: Bool,
        sessionID: SessionID,
        transcriptID: TranscriptID,
        account: AgentAccount,
        completion: @escaping Completion
    ) {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = ProviderArchiveSnapshot.read(
                account: account,
                sessionIDs: [transcriptID]
            )
            Task { @MainActor [weak self] in
                guard let self, pending.contains(sessionID) else { return }
                if snapshot?[transcriptID].archivedValue == archives {
                    finishUserChange(
                        sessionID: sessionID,
                        archived: archives,
                        completion: completion
                    )
                    return
                }
                runUserCommand(
                    archives: archives,
                    sessionID: sessionID,
                    transcriptID: transcriptID,
                    account: account,
                    completion: completion
                )
            }
        }
    }

    /// Re-reads every retained provider-backed session and applies changes made in either app.
    ///
    /// Scaling boundary: ordinary use is tens to low hundreds of retained Codex sessions across
    /// 1–4 accounts; the stress case is 1,000 retained sessions among 10,000 provider rollouts.
    /// The directory walk and command waits stay on a utility queue, one snapshot is built per
    /// account rather than per session, one daemon survey covers every archiving candidate, and
    /// at most four provider commands run at once. The main actor receives only the retained
    /// candidates plus one batched store write. The callback runs at launch/activation frequency,
    /// not per provider filesystem event.
    func reconcile() {
        reconciliationGeneration += 1
        let generation = reconciliationGeneration

        // Reconciliation may launch provider commands. A read-only or poisoned store cannot
        // durably record their result, so observing is safer than creating a new disagreement.
        guard store.acceptsDurableMutations else { return }

        var batches: [String: Batch] = [:]
        for project in store.projects {
            for session in project.sessions where session.kind.supports(.providerArchive) {
                guard let transcriptID = session.resumeState.transcriptID,
                      let account = AgentAccountDiscovery.account(
                          for: session.kind,
                          handle: session.accountHandle
                      ) else { continue }
                let candidate = Candidate(
                    sessionID: session.id,
                    transcriptID: transcriptID,
                    account: account
                )
                if var batch = batches[account.configPath] {
                    batch.candidates.append(candidate)
                    batches[account.configPath] = batch
                } else {
                    batches[account.configPath] = Batch(
                        account: account,
                        candidates: [candidate]
                    )
                }
            }
        }

        let work = Array(batches.values)
        guard !work.isEmpty else { return }
        ThreadingLogger.session.info(
            "Provider archive reconciliation pass started accounts=\(work.count, privacy: .public) sessions=\(work.reduce(0) { $0 + $1.candidates.count }, privacy: .public)"
        )
        DispatchQueue.global(qos: .utility).async {
            let readings: [(Batch, ProviderArchiveSnapshot?)] = work.map { batch in
                let ids = Set(batch.candidates.map(\.transcriptID))
                return (batch, ProviderArchiveSnapshot.read(
                    account: batch.account,
                    sessionIDs: ids
                ))
            }
            Task { @MainActor [weak self] in
                self?.apply(readings, generation: generation)
            }
        }
    }

    private func apply(
        _ readings: [(Batch, ProviderArchiveSnapshot?)],
        generation: Int
    ) {
        guard generation == reconciliationGeneration else { return }

        var immediate: [SessionID: Bool] = [:]
        var commands: [(Candidate, Bool)] = []
        for (batch, snapshot) in readings {
            guard let snapshot else {
                ThreadingLogger.session.error(
                    "Could not read provider archive state for \(batch.account.configPath, privacy: .private(mask: .hash))"
                )
                continue
            }
            for candidate in batch.candidates where !pending.contains(candidate.sessionID) {
                guard let provider = snapshot[candidate.transcriptID].archivedValue,
                      let current = store.session(withID: candidate.sessionID) else { continue }
                let plan = ProviderArchiveReconciliationPlan.make(
                    local: current.isArchived,
                    provider: provider,
                    lastSynchronized: current.lastSynchronizedArchiveState
                )
                if let providerTarget = plan.providerTarget {
                    commands.append((candidate, providerTarget))
                } else {
                    immediate[candidate.sessionID] = plan.synchronizedState
                }
            }
        }

        applySynchronized(immediate)
        ThreadingLogger.session.info(
            "Provider archive reconciliation evaluated immediate=\(immediate.count, privacy: .public) commands=\(commands.count, privacy: .public)"
        )
        runAutomaticCommands(commands, generation: generation)
    }

    private func runUserCommand(
        archives: Bool,
        sessionID: SessionID,
        transcriptID: TranscriptID,
        account: AgentAccount,
        completion: @escaping Completion
    ) {
        guard let session = store.session(withID: sessionID) else {
            pending.remove(sessionID)
            completion(.success(()))
            return
        }
        let command = ProviderArchiveCommand.make(
            archives: archives,
            session: session,
            transcriptID: transcriptID,
            account: account
        )
        ProviderArchiveCommandRunner.run(command) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                finishUserChange(
                    sessionID: sessionID,
                    archived: archives,
                    completion: completion
                )
            case .failure(let failure):
                pending.remove(sessionID)
                ThreadingLogger.session.error(
                    "Provider archive change failed session=\(sessionID.uuidString, privacy: .public) archives=\(archives, privacy: .public) provider=\(command.providerName, privacy: .private(mask: .hash)): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
                EventLog.shared.record(.session, "Provider archive command failed", [
                    "session": sessionID.uuidString,
                    "provider": command.providerName,
                    "action": archives ? "archive" : "restore",
                    "error": failure.localizedDescription
                ])
                completion(.failure(failure))
            }
        }
    }

    private func finishUserChange(
        sessionID: SessionID,
        archived: Bool,
        completion: @escaping Completion
    ) {
        pending.remove(sessionID)
        switch applySynchronized([sessionID: archived]) {
        case .applied, .unchanged:
            completion(.success(()))
        case .targetNotFound:
            completion(.failure(.sessionNotFound))
        case .persistenceRefused, .unsupportedValue:
            completion(.failure(.persistenceUnavailable(processStopped: archived)))
        }
    }

    /// Starts every automatic provider change with two explicit bounds: archiving candidates
    /// share one daemon survey, and the command runner admits only a fixed number of login shells.
    private func runAutomaticCommands(
        _ commands: [(Candidate, Bool)],
        generation: Int
    ) {
        var archiving: [Candidate] = []
        for (candidate, archives) in commands {
            guard pending.insert(candidate.sessionID).inserted else { continue }
            guard store.session(withID: candidate.sessionID) != nil else {
                pending.remove(candidate.sessionID)
                continue
            }
            if archives {
                archiving.append(candidate)
            } else {
                continueAutomaticCommand(
                    archives: false,
                    candidate: candidate,
                    generation: generation
                )
            }
        }

        guard !archiving.isEmpty else { return }
        reconciliationProcessStopper(archiving.map(\.sessionID)) { [weak self] in
            guard let self else { return }
            for candidate in archiving {
                continueAutomaticCommand(
                    archives: true,
                    candidate: candidate,
                    generation: generation
                )
            }
        }
    }

    private func continueAutomaticCommand(
        archives: Bool,
        candidate: Candidate,
        generation: Int
    ) {
        guard pending.contains(candidate.sessionID) else { return }
        guard let session = store.session(withID: candidate.sessionID) else {
            pending.remove(candidate.sessionID)
            return
        }
        let command = ProviderArchiveCommand.make(
            archives: archives,
            session: session,
            transcriptID: candidate.transcriptID,
            account: candidate.account
        )
        ProviderArchiveCommandRunner.run(command) { [weak self] result in
            guard let self else { return }
            pending.remove(candidate.sessionID)
            switch result {
            case .success where generation == reconciliationGeneration:
                applySynchronized([candidate.sessionID: archives])
            case .success:
                reconcile()
            case .failure(let failure):
                ThreadingLogger.session.warning(
                    "Provider archive reconciliation failed session=\(candidate.sessionID.uuidString, privacy: .public) archives=\(archives, privacy: .public) provider=\(command.providerName, privacy: .private(mask: .hash)): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
                EventLog.shared.record(.session, "Provider archive reconciliation failed", [
                    "session": candidate.sessionID.uuidString,
                    "provider": command.providerName,
                    "action": archives ? "archive" : "restore",
                    "error": failure.localizedDescription
                ])
            }
        }
    }

    @discardableResult
    private func applySynchronized(_ states: [SessionID: Bool]) -> ProjectMutationResult {
        guard !states.isEmpty else { return .unchanged }
        var localChanges: [(SessionID, Bool)] = []
        for (sessionID, archived) in states {
            guard let session = store.session(withID: sessionID),
                  session.isArchived != archived else { continue }
            localChanges.append((sessionID, archived))
        }

        let result = store.synchronizeArchiveStates(states)
        guard result == .applied || result == .unchanged else {
            ThreadingLogger.session.error(
                "Could not persist provider archive reconciliation"
            )
            return result
        }
        for (sessionID, archived) in localChanges {
            if archived {
                AgentRuntime.shared.discard(sessionID: sessionID)
            }
            center.post(SessionArchivedStateDidChange(
                sessionID: sessionID,
                isArchived: archived
            ))
        }
        return result
    }

    private func announceIfLocalStateChanged(
        sessionID: SessionID,
        from oldValue: Bool,
        to newValue: Bool
    ) {
        guard oldValue != newValue else { return }
        center.post(SessionArchivedStateDidChange(
            sessionID: sessionID,
            isArchived: newValue
        ))
    }
}

private enum ProviderArchiveDefaults {
    static let archivedDirectory = "archived_sessions"
    static let uuidLength = 36
    static let maximumErrorLength = 800
    static let maximumCommandOutputBytes = 64 * 1024
    static let commandTimeout: TimeInterval = 30
    static let maximumConcurrentCommands = 4
}
