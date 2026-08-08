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
    case accountUnavailable(String)
    case commandCouldNotLaunch(provider: String, detail: String)
    case commandRejected(provider: String, archives: Bool, detail: String)

    var errorDescription: String? {
        switch self {
        case .alreadyChanging:
            return L10n.string("This conversation’s archive state is already changing.")
        case .accountUnavailable(let provider):
            return L10n.format("%@ could not find the account that owns this conversation.", provider)
        case .commandCouldNotLaunch(let provider, let detail):
            return L10n.format("%@ could not start its archive command: %@", provider, detail)
        case .commandRejected(let provider, let archives, let detail):
            return archives
                ? L10n.format("%@ could not archive this conversation: %@", provider, detail)
                : L10n.format("%@ could not restore this conversation: %@", provider, detail)
        }
    }
}

private enum ProviderArchiveCommandRunner {
    static func run(
        _ command: ProviderArchiveCommand,
        completion: @escaping @MainActor @Sendable (Result<Void, ProviderArchiveFailure>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = runSynchronously(command)
            Task { @MainActor in completion(result) }
        }
    }

    private static func runSynchronously(
        _ command: ProviderArchiveCommand
    ) -> Result<Void, ProviderArchiveFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.shellPath)
        process.arguments = ["-l", "-c", command.source]
        process.environment = AgentEnvironment.launchEnvironment()

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return .failure(.commandCouldNotLaunch(
                provider: command.providerName,
                detail: error.localizedDescription
            ))
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let reported = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reported.isEmpty
                ? L10n.format("the command exited with status %lld", Int64(process.terminationStatus))
                : String(reported.prefix(ProviderArchiveDefaults.maximumErrorLength))
            return .failure(.commandRejected(
                provider: command.providerName,
                archives: command.archives,
                detail: detail
            ))
        }
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
    private var observations: AppEventObservations?
    private var pending = Set<SessionID>()
    private var reconciliationGeneration = 0
    private var hasStarted = false

    init(
        store: ProjectStore = .shared,
        center: NotificationCenter = .default
    ) {
        self.store = store
        self.center = center
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

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
        guard let session = store.session(withID: sessionID) else {
            completion(.success(()))
            return
        }
        guard pending.insert(sessionID).inserted else {
            completion(.failure(.alreadyChanging))
            return
        }

        if archived {
            AgentRuntime.shared.discard(sessionID: sessionID)
        }

        guard session.kind.supports(.providerArchive),
              let transcriptID = session.resumeState.transcriptID else {
            store.setArchived(archived, for: sessionID)
            pending.remove(sessionID)
            announceIfLocalStateChanged(sessionID: sessionID, from: session.isArchived, to: archived)
            completion(.success(()))
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

        DispatchQueue.global(qos: .utility).async {
            let snapshot = ProviderArchiveSnapshot.read(
                account: account,
                sessionIDs: [transcriptID]
            )
            Task { @MainActor [weak self] in
                guard let self, pending.contains(sessionID) else { return }
                if snapshot?[transcriptID].archivedValue == archived {
                    finishUserChange(
                        sessionID: sessionID,
                        archived: archived,
                        completion: completion
                    )
                    return
                }
                runUserCommand(
                    archives: archived,
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
    /// account rather than per session, and the main actor receives only the retained candidates
    /// plus one batched store write. The callback runs at launch/activation frequency, not per
    /// provider filesystem event.
    func reconcile() {
        reconciliationGeneration += 1
        let generation = reconciliationGeneration

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
        for (candidate, archives) in commands {
            runAutomaticCommand(
                archives: archives,
                candidate: candidate,
                generation: generation
            )
        }
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
        applySynchronized([sessionID: archived])
        completion(.success(()))
    }

    private func runAutomaticCommand(
        archives: Bool,
        candidate: Candidate,
        generation: Int
    ) {
        guard pending.insert(candidate.sessionID).inserted,
              let session = store.session(withID: candidate.sessionID) else { return }
        if archives {
            AgentRuntime.shared.discard(sessionID: candidate.sessionID)
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
                EventLog.shared.record(.session, "Provider archive reconciliation failed", [
                    "session": candidate.sessionID.uuidString,
                    "provider": command.providerName,
                    "action": archives ? "archive" : "restore",
                    "error": failure.localizedDescription
                ])
            }
        }
    }

    private func applySynchronized(_ states: [SessionID: Bool]) {
        guard !states.isEmpty else { return }
        var localChanges: [(SessionID, Bool)] = []
        for (sessionID, archived) in states {
            guard let session = store.session(withID: sessionID),
                  session.isArchived != archived else { continue }
            if archived {
                AgentRuntime.shared.discard(sessionID: sessionID)
            }
            localChanges.append((sessionID, archived))
        }

        store.synchronizeArchiveStates(states)
        for (sessionID, archived) in localChanges {
            center.post(SessionArchivedStateDidChange(
                sessionID: sessionID,
                isArchived: archived
            ))
        }
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
}
