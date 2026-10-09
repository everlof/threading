#if os(Linux)
import AppKit
import Foundation
import Glibc
import ThreadingPTYClient
import ThreadingPTYHostKit
@testable import CoreSlice

/// A saved native conversation in the ordinary workspace. File/account/replay work and durable
/// updates use one serial worker per retained runtime, within the workspace's eight-runtime cap.
@MainActor
final class NativeWorkspaceSession {
    private struct Prepared: Sendable {
        let session: AgentSession
        let projectID: ProjectID
        let directory: String
        let plan: AgentLaunchPlan
        var events: [StreamEvent]
        let truncated: Bool
    }

    let id: SessionID
    private let store: String
    private let socket: String
    private let worker: DispatchQueue
    private var prepared: Prepared?
    private var stream: (any ConversationStreamSession)?
    private var timeline: ConversationTimeline
    private(set) var revision = 0
    private(set) var status = "Loading conversation…"
    private(set) var failure: String?
    private(set) var stopped = false
    var onRow: ((Int, ConversationTimeline.Row, [String]?) -> Void)?
    var onStreaming: ((String?) -> Void)?
    var onChange: (() -> Void)?
    private var pendingRenderBytes = 0
    private var pendingRenderCount = 0
    private var launching = false
    private var replaying = true
    private var launchRecordedAt: Date?
    private(set) var completedTurns = 0
    var rowsPrepared: Bool { !replaying && pendingRenderCount == 0 }
    // Rows are an immutable value snapshot; none of the worker's copies is mutated by the UI.
    private struct RowSnapshot: @unchecked Sendable { let rows: [ConversationTimeline.Row] }
    var canSend: Bool { !stopped && !launching && !replaying && failure == nil && prepared != nil && (stream?.canSend ?? true) }
    var canInterrupt: Bool { stream?.canInterrupt ?? false }
    var rootProcessIdentifier: Int32? { stream?.rootProcessIdentifier }

    init(store: String, socket: String, id: SessionID, shell: String,
         codex: String?, claude: String?) {
        self.store = store
        self.socket = socket
        self.id = id
        worker = DispatchQueue(label: "codes.threading.linux.native-workspace.\(id.uuidString)", qos: .userInitiated)
        timeline = ConversationTimeline(sessionID: id, chartDecoder: { _, _ in nil })
        worker.async { [weak self] in
            let result = Result { try Self.prepare(store: store, id: id, shell: shell, codex: codex, claude: claude) }
            NativeConversationDelivery.callbacks.receive { self?.loaded(result) }
        }
    }

    private func loaded(_ result: Result<Prepared, Error>) {
        guard !stopped else { return }
        switch result {
        case .failure(let error): report(String(describing: error))
        case .success(let prepared):
            var retained = prepared
            retained.events = []
            self.prepared = retained
            for event in prepared.events { _ = timeline.apply(event) }
            let snapshot = RowSnapshot(rows: timeline.rows)
            let truncated = prepared.truncated
            worker.async { [weak self] in
                for (index, row) in snapshot.rows.enumerated() {
                    let blocks = Self.markdownBlocks(for: row)
                    let single = RowSnapshot(rows: [row])
                    NativeConversationDelivery.callbacks.receive {
                        guard let self, !self.stopped else { return }
                        self.onRow?(index, single.rows[0], blocks)
                        self.changed()
                    }
                }
                NativeConversationDelivery.callbacks.receive {
                    guard let self, !self.stopped else { return }
                    if truncated {
                        self.onRow?(Int.max, .notice("Earlier transcript content was truncated.", kind: .muted), nil)
                    }
                    self.replaying = false
                    self.status = "Ready"
                    self.changed()
                }
            }
            changed()
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend, let prepared, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.prefix(65_537).count <= 65_536 else { return false }
        if stream == nil {
            apply(.userMessage(text))
            launching = true
            status = "Starting agent…"
            changed()
            let store = store, socket = socket
            worker.async { [weak self] in
                let result = Result {
                    let child = try ConversationPreparedChild(plan: prepared.plan, sessionID: prepared.session.id,
                        host: Self.hostPlan(prepared, socket: socket))
                    let date = Date()
                    try Self.withDatabase(store: store) { database in
                        guard let record = try database.sessionRecord(id: prepared.session.id),
                              record.project.id == prepared.projectID,
                              record.session.usesNativeUI,
                              record.session.kind == prepared.session.kind,
                              record.session.accountHandle == prepared.session.accountHandle,
                              record.session.lastActiveAt == prepared.session.lastActiveAt else {
                            throw WindowFailure("Saved conversation changed before launch admission.")
                        }
                        var session = record.session
                        AgentLaunchRecording.apply(prepared.plan, to: &session, at: date)
                        try database.saveSession(session, in: record.project.id, position: record.position)
                    }
                    return Started(child: child, recordedAt: date)
                }
                NativeConversationDelivery.callbacks.receive {
                    self?.started(result, prepared: prepared, prompt: text)
                }
            }
            return true
        }
        guard stream?.send(text) == true else { changed(); return false }
        apply(.userMessage(text))
        status = "Working"
        changed()
        return true
    }

    private struct Started: Sendable {
        let child: ConversationPreparedChild
        let recordedAt: Date
    }

    private func started(_ result: Result<Started, Error>, prepared: Prepared, prompt: String) {
        guard !stopped else { return }
        launching = false
        switch result {
        case .failure(let error):
            apply(.turnFinished(text: nil, outcome: .failed, metrics: .empty))
            report(String(describing: error))
        case .success(let started):
            launchRecordedAt = started.recordedAt
            let stream = makeStream(prepared, child: started.child)
            self.stream = stream
            stream.onEvent = { [weak self] in self?.apply($0) }
            stream.onInteractionAvailabilityChange = { [weak self] in self?.changed() }
            stream.onLaunchFailure = { [weak self] in self?.report(String(describing: $0)) }
            stream.onExit = { [weak self] status in
                guard let self else { return }
                self.status = "Agent exited (\(status))"
                self.changed()
                self.persist { session in session.lastExitCode = status; session.lastActiveAt = Date() }
            }
            stream.start()
            if stream.send(prompt) { status = "Working"; changed() }
            else { report("The agent refused the opening message.") }
        }
    }

    func interrupt() {
        guard let stream, stream.canInterrupt else { return }
        stream.interrupt { [weak self] receipt in
            if case .failed(let reason) = receipt { self?.report(reason) }
            else { self?.changed() }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stream?.terminate()
        stream = nil
        changed()
    }

    func closeForQuit(by deadline: Date) {
        guard !stopped else { return }
        if stream?.detachFromBackgroundHost(by: deadline) != true { stream?.terminate() }
        stopped = true
        stream = nil
    }

    private nonisolated static func hostPlan(_ prepared: Prepared, socket: String) -> PTYHostChildPlan {
        PTYHostChildPlan(identity: .agentSession(prepared.session.id), factory: { events in
            let client = PTYHostClient(socketPath: socket, build: "linux-native-workspace",
                events: events, journal: { _, _ in })
            try client.connect()
            return client
        }, workingDirectory: prepared.directory)
    }

    private func makeStream(_ prepared: Prepared, child: ConversationPreparedChild) -> any ConversationStreamSession {
        let session = prepared.session
        let plan = prepared.plan
        let directory = prepared.directory
        switch session.kind {
        case .claude:
            return ClaudeStreamSession(sessionID: session.id, callbackDelivery: NativeConversationDelivery.callbacks,
                preparedChild: child, effort: session.reasoningEffort, plan: { plan })
        case .codex:
            return CodexStreamSession(sessionID: session.id, callbackDelivery: NativeConversationDelivery.callbacks,
                preparedChild: child, workingDirectory: directory, configurationProvider: {
                    CodexTurnConfiguration(model: session.model, effort: session.reasoningEffort,
                        serviceTier: session.fastMode.map { $0 ? AgentDefaults.codexFastServiceTier : AgentDefaults.codexStandardServiceTier })
                }, plan: { plan })
        case .grok, .cursor, .openCode:
            // Preparation currently admits the two workspace executables. Other native profiles
            // retain their saved surface and present an explicit availability failure.
            preconditionFailure("unsupported workspace native preparation")
        }
    }

    private func apply(_ event: StreamEvent) {
        let changes = timeline.apply(event)
        for change in changes {
            switch change {
            case .appended(let index), .resultAttached(let index):
                guard timeline.rows.indices.contains(index) else { continue }
                prepareRow(timeline.rows[index], at: index)
            case .streaming(let text): onStreaming?(text)
            case .turnSettled:
                completedTurns += 1
                status = "Ready"
            case .adoptedSessionID(let id):
                persist { $0.resumeState = .resumable(id) }
            default: break
            }
        }
        changed()
    }

    /// Markdown partitioning stays off the actor. All row jobs use one ordered, paced lane;
    /// parsed values awaiting it have explicit byte/count admission rather than an unbounded queue.
    private func prepareRow(_ row: ConversationTimeline.Row, at index: Int) {
        let source: String?
        switch row {
        case .assistant(let text), .thinking(let text): source = text
        default: source = nil
        }
        let bytes = source?.utf8.count ?? 0
        guard pendingRenderCount < 64, bytes <= 32 * 1_024 * 1_024 - pendingRenderBytes else {
            stream?.terminate()
            report("The conversation exceeded its row preparation budget.")
            return
        }
        pendingRenderCount += 1
        pendingRenderBytes += bytes
        let snapshot = RowSnapshot(rows: [row])
        worker.async { [weak self] in
            let blocks = source.map(Markdown.sourceBlocks)
            NativeConversationDelivery.callbacks.receive {
                guard let self else { return }
                self.pendingRenderCount -= 1
                self.pendingRenderBytes -= bytes
                guard !self.stopped else { return }
                self.onRow?(index, snapshot.rows[0], blocks)
                self.changed()
            }
        }
    }

    private func changed() { revision += 1; onChange?() }
    private func report(_ message: String) { failure = message; status = message; changed() }

    private nonisolated static func markdownBlocks(for row: ConversationTimeline.Row) -> [String]? {
        switch row {
        case .assistant(let text), .thinking(let text): return Markdown.sourceBlocks(text)
        default: return nil
        }
    }

    private func persist(_ mutate: @escaping @Sendable (inout AgentSession) -> Void) {
        guard let prepared else { return }
        let store = store, id = id
        let launchedAt = launchRecordedAt
        worker.async { [weak self] in
            do {
                try Self.withDatabase(store: store) { database in
                    guard let record = try database.sessionRecord(id: id), record.session.usesNativeUI,
                          record.project.id == prepared.projectID,
                          record.session.kind == prepared.session.kind,
                          record.session.accountHandle == prepared.session.accountHandle,
                          record.session.lastActiveAt == prepared.session.lastActiveAt
                            || launchedAt.map({ record.session.lastActiveAt == $0 }) == true else {
                        throw WindowFailure("Saved conversation changed before update.")
                    }
                    var session = record.session
                    mutate(&session)
                    try database.saveSession(session, in: record.project.id, position: record.position)
                }
            } catch {
                let message = "Could not save conversation state: \(error)"
                NativeConversationDelivery.callbacks.receive { self?.report(message) }
            }
        }
    }

    private nonisolated static func withDatabase<T>(store: String, body: (ProjectDatabase) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("Cannot open store lock.") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("Store is already owned.") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        return try body(database)
    }

    private nonisolated static func prepare(store: String, id: SessionID, shell: String,
                                            codex: String?, claude: String?) throws -> Prepared {
        let record = try withDatabase(store: store) { database in
            guard let record = try database.sessionRecord(id: id), record.session.usesNativeUI,
                  record.session.kind.supportsNativeUI else { throw WindowFailure("Saved native conversation is unavailable.") }
            return record
        }
        let session = record.session
        guard let directory = ProjectDirectory.existing(at: session.workingDirectory(in: record.project)),
              shell.hasPrefix("/") else { throw WindowFailure("Conversation checkout or login shell is unavailable.") }
        let accountPath = try GraphicalTerminal.accountPath(for: session.kind, handle: session.accountHandle)
        let account = AgentAccount(provider: session.kind, handle: session.accountHandle, configPath: accountPath)
        let url: URL?
        switch session.kind {
        case .claude:
            url = session.resumeState.transcriptID.flatMap {
                ClaudeTranscript.storageSlot(sessionID: $0, account: account, in: record.project)?.resolve()
            }
        case .codex: url = session.resumeState.transcriptID.flatMap { CodexTranscript.url(sessionID: $0, account: account) }
        default: throw WindowFailure("This provider's native workspace launch is not available yet.")
        }
        if session.hasLaunched {
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                throw WindowFailure("Saved conversation history is missing from its account.")
            }
        }
        let agentCommand: ShellCommand
        let resumeState: ResumeState
        switch session.kind {
        case .claude:
            guard let claude, claude.hasPrefix("/") else { throw WindowFailure("Claude executable is unavailable.") }
            let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: claude,
                permissionMode: session.permissionMode, prompt: nil,
                integrationFlags: ClaudeLaunchCommand.streamProtocolFlags())
            agentCommand = session.hasLaunched ? pair.resume : pair.fresh
            resumeState = .resumable(pair.transcriptID)
        case .codex:
            guard let codex, codex.hasPrefix("/") else { throw WindowFailure("Codex executable is unavailable.") }
            agentCommand = CodexLaunchCommand.appServer(executable: codex, model: session.model,
                permissionMode: session.permissionMode)
            resumeState = session.resumeState
        default: throw WindowFailure("This provider's native workspace launch is not available yet.")
        }
        var command = AgentAccountRoute.prefix(for: session.kind, handle: session.accountHandle, configPath: accountPath)
        command.append(contentsOf: agentCommand)
        let replay = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? TranscriptReplay.read(at: $0, kind: session.kind) : nil }
            ?? ([], false)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: directory.path,
            shellPath: shell, resumeState: resumeState)
        return Prepared(session: session, projectID: record.project.id, directory: directory.path,
            plan: plan, events: replay.0, truncated: replay.1)
    }
}
#endif
