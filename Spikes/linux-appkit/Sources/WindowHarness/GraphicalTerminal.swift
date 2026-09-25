#if os(Linux)
@testable import CoreSlice
@testable import TerminalRuntime
import Foundation
import Dispatch
import Glibc
import LinuxWindowBridge
import ThreadingPTYHostKit

/// Experimental host-only terminal surface. Threading retains store identity, process ownership,
/// input and exit truth. This is not a new extension component or a shipping theme boundary.
final class GraphicalTerminal: @unchecked Sendable {
    private static let cellWidth = Int(TW_TERMINAL_CELL_WIDTH)
    private static let cellHeight = Int(TW_TERMINAL_CELL_HEIGHT)
    static let maximumPasteBytes = 64 * 1024
    static let maximumCopyBytes = 1024 * 1024
    private static let exitWaitSeconds: Double = 5
    private static let maximumReplayBytes = 4 * 1024 * 1024
    private static let maximumAttachColumns = 128
    private static let maximumAttachRows = 40
    struct TextRun: Sendable {
        let offset: Int32
        let characters: Int32
        let column: Int32
        let row: Int32
        let cells: Int32
    }
    struct Frame: Sendable {
        let pixels: Data
        let width: Int
        let height: Int
        let title: String
        let cursorColumn: Int
        let cursorRow: Int
        let accessibleText: String
        let accessibleCaret: Int
        let accessibleRuns: [TextRun]
        let drawMilliseconds: Double
    }
    private struct Preedit: Equatable, Sendable {
        let text: String
        let cursor: Int
        let selectionLength: Int
    }
    private let worker = DispatchQueue(label: "linux.terminal", qos: .userInteractive)
    private let drawing = DispatchQueue(label: "linux.terminal.drawing", qos: .userInteractive)
    private let lock = NSLock()
    // Lock-owned publication/admission. One snapshot/render request and one published frame.
    private var pendingFrame = false
    private var pendingInputCount = 0
    private enum Input: Sendable {
        case text(Data)
        case paste(Data)
        case key(PTYEmulator.Key, PTYEmulator.Modifiers, PTYEmulator.KeyAction)
        case mouseButton(Int, Int, Int, Bool, PTYEmulator.Modifiers)
        case mouseWheel(Int, Int, Int, PTYEmulator.Modifiers)
        case copySelection
    }
    private var frame: Frame?
    private var copyResult: PTYEmulator.CopyResult?
    private var pendingSelectionMotion: (x: Int, y: Int)?
    private var selectionMotionScheduled = false
    private var failure: String?
    private var running = false
    private var closed = false
    private var createdTerminal = false
    private var createdAgent = false
    private var spawnMayBeLive = false
    private var finished = false
    private var initialViewport: (Int, Int)?
    // Worker-owned runtime. Every emulator operation stays off the UI actor.
    private var emulator: PTYEmulator?
    private var client: PTYHostClient?
    private var connectionGeneration = 0
    private var identity: PTYHostSessionIdentity?
    private var dirty = true
    // Worker-owned, uncommitted IME text. Preedit never enters the PTY queue.
    private var preedit: Preedit?
    private var lastWidth = 0, lastHeight = 0
    private var exitStatus: Int32?
    private var waitingForExit = false
    private var attaching = false
    private var replayRemaining: Int?
    private var replayLabel = ""
    private var attachmentViewportApplied = false
    private var codexDiscovery: (store: String, directory: String, home: String, sessionID: SessionID, launchedAt: Date)?
    private var agentResume: (store: String, socket: String, shell: String, codex: String?,
                              claude: String?, sessionID: SessionID, width: Int, height: Int)?

    func start(store: String, socket: String, directory: String, executable: String, arguments: [String]) {
        worker.async { [self] in
            do {
                let link = try connect(socket: socket)
                let id = try Self.createTerminal(store: store, directory: directory, executable: executable)
                identity = id
                lock.lock(); createdTerminal = true; lock.unlock()
                // Once send is attempted, failure cannot prove that the daemon did not spawn.
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                try link.spawn(PTYHostSpawnRequest(id: id, channel: .pty(grid: PTYHostGrid(cols: 80, rows: 24)),
                    executable: executable, arguments: arguments,
                    environment: Self.launchEnvironment(), cwd: directory))
            } catch { fail(error) }
        }
    }
    func startAgent(store: String, socket: String, directory: String, shell: String,
                    kind: AgentKind, executable: String, accountHandle: AccountHandle, id: SessionID,
                    width: Int, height: Int) {
        worker.async { [self] in
            do {
                let columns = max(2, width / Self.cellWidth), rows = max(1, height / Self.cellHeight)
                let link = try connect(socket: socket, columns: columns, rows: rows)
                let accountPath = try Self.accountPath(for: kind, handle: accountHandle)
                let plan = try Self.createAgent(store: store, directory: directory,
                                                shell: shell, kind: kind, executable: executable,
                                                accountHandle: accountHandle,
                                                accountPath: accountPath, id: id)
                let environment = Self.launchEnvironment()
                let identity = PTYHostSessionIdentity.agentSession(id)
                self.identity = identity
                if kind == .codex { codexDiscovery = (store, directory, accountPath, id, Date()) }
                lastWidth = width; lastHeight = height
                lock.lock(); createdAgent = true; spawnMayBeLive = true; lock.unlock()
                try link.spawn(PTYHostSpawnRequest(id: identity,
                    channel: .pty(grid: PTYHostGrid(cols: columns, rows: rows)),
                    executable: plan.executable, arguments: plan.arguments,
                    environment: environment, cwd: directory))
            } catch { fail(error) }
        }
    }
    private static func launchEnvironment() -> [String] {
        var environment = AgentEnvironment.removingInheritedIdentity(from: ProcessInfo.processInfo.environment)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "C.UTF-8"
        return environment.map { "\($0.key)=\($0.value)" }
    }
    private static func accountPath(for kind: AgentKind, handle: AccountHandle) throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            throw WindowFailure("an absolute HOME is required for agent account routing")
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        if kind == .claude {
            guard handle.isStandard else { throw WindowFailure("named Claude accounts are not available in this window") }
            return homeURL.appendingPathComponent(AgentAccountDefaults.claudeDefaultDirectory,
                                                 isDirectory: true).path
        }
        guard kind == .codex else { throw WindowFailure("unsupported agent kind") }
        guard let location = CodexAccountLocations.resolve(
            handle, home: homeURL) else {
            throw WindowFailure("saved Codex account is unavailable: \(handle.name)")
        }
        return location.configPath
    }
    private func connect(socket: String, columns: Int = 80, rows: Int = 24) throws -> PTYHostClient {
        connectionGeneration += 1
        let generation = connectionGeneration
        emulator = try PTYEmulator(columns: columns, rows: rows) { [weak self] data in
            do { try self?.client?.sendInput(data) } catch { self?.fail(error) }
        }
        let link = PTYHostClient(socketPath: socket, build: "linux-native-window", events: .init(
            frame: { [weak self] frame in
                guard let self, self.connectionGeneration == generation else { return }
                self.received(frame)
            },
            output: { [weak self] data in
                guard let self, self.connectionGeneration == generation else { return }
                self.receiveOutput(data)
            },
            closed: { [weak self] error in
                guard let self, self.connectionGeneration == generation else { return }
                if let error { self.fail(error) }
                else if self.exitStatus == nil { self.fail(WindowFailure("PTY connection closed")) }
            }), journal: { _, _ in }, queue: worker)
        client = link
        try link.connect()
        return link
    }
    func attach(store: String, socket: String, terminalID: String) {
        attach(store: store, socket: socket, savedID: terminalID, kind: .terminal)
    }
    func attachAgent(store: String, socket: String, sessionID: String) {
        attach(store: store, socket: socket, savedID: sessionID, kind: .agent)
    }
    func openAgent(store: String, socket: String, sessionID: String, shell: String,
                   codex: String?, claude: String?, width: Int, height: Int) {
        attach(store: store, socket: socket, savedID: sessionID, kind: .agent,
               resume: (shell, codex, claude, width, height))
    }
    private enum SavedKind { case terminal, agent }
    /// Navigation is durable before the UI enters a runtime. Keep the exact-row membership
    /// check and scalar write off the UI actor; terminal selection clears a prior agent as on
    /// macOS. The window keeps a failed choice in its picker or project list; a new shell still
    /// reports its own launch failure if the same store refusal prevents it from starting.
    static func selectRuntime(store: String, agentID: String?) throws {
        let id: SessionID?
        if let agentID {
            guard let uuid = UUID(uuidString: agentID) else { throw WindowFailure("invalid session UUID") }
            id = SessionID(uuid)
        } else {
            id = nil
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        if let id {
            guard try database.sessionRecord(id: id) != nil else {
                throw WindowFailure("session is not in this store")
            }
        }
        try database.saveSelectedSessionID(id)
    }
    private func attach(store: String, socket: String, savedID: String, kind: SavedKind,
                        resume: (String, String?, String?, Int, Int)? = nil) {
        worker.async { [self] in
            do {
                attaching = true
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                let id = try Self.storedIdentity(store: store, savedID: savedID, kind: kind)
                identity = id
                if let resume, let uuid = UUID(uuidString: savedID) {
                    agentResume = (store, socket, resume.0, resume.1, resume.2,
                                   SessionID(uuid), resume.3, resume.4)
                }
                let link = try connect(socket: socket)
                try link.attach(PTYHostAttach(id: id))
                worker.asyncAfter(deadline: .now() + Self.exitWaitSeconds) { [weak self] in
                    guard let self, self.replayRemaining != 0 else { return }
                    self.fail(WindowFailure("timed out waiting for terminal replay"))
                }
            } catch { fail(error) }
        }
    }
    private static func storedIdentity(store: String, savedID: String, kind: SavedKind) throws -> PTYHostSessionIdentity {
        guard let uuid = UUID(uuidString: savedID) else {
            throw WindowFailure(kind == .agent ? "invalid session UUID" : "invalid terminal identity")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        switch kind {
        case .terminal:
            let projects = try database.load().state.projects
            let id = TerminalID(uuid)
            guard projects.contains(where: { $0.terminals.contains(where: { $0.id == id }) }) else {
                throw WindowFailure("terminal is not in this store")
            }
            return PTYHostSessionIdentity(.projectTerminal(id))
        case .agent:
            let id = SessionID(uuid)
            guard try database.sessionRecord(id: id) != nil else {
                throw WindowFailure("session is not in this store")
            }
            return .agentSession(id)
        }
    }
    private func receiveOutput(_ data: Data) {
        if attaching {
            guard let remaining = replayRemaining else { fail(WindowFailure("output before attach boundary")); return }
            let count = min(remaining, data.count)
            if count > 0 { emulator?.feed(data.prefix(count), replaying: true) }
            if count < data.count { emulator?.feed(data.dropFirst(count)) }
            replayRemaining = remaining - count
            if replayRemaining == 0 {
                lock.lock(); if !finished && !closed && failure == nil { running = true }; lock.unlock()
            }
        } else { emulator?.feed(data) }
        dirty = true
    }
    private static func createTerminal(store: String, directory: String, executable: String) throws -> PTYHostSessionIdentity {
        guard let folder = ProjectDirectory.existing(at: directory) else {
            throw WindowFailure("project directory does not exist")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        var state = try database.load().state
        let index: Int
        let addedProject: Bool
        if let found = state.projects.firstIndex(where: { $0.folderPath == folder.path }) {
            index = found
            addedProject = false
        } else {
            state.projects.append(Project(name: folder.lastPathComponent, folderURL: folder))
            index = state.projects.count - 1
            addedProject = true
        }
        let terminal = ProjectTerminal(id: TerminalID(), title: URL(fileURLWithPath: executable).lastPathComponent,
            customTitle: nil, currentDirectory: folder.path, branch: nil, themeID: nil,
            soundOverrides: nil, createdAt: Date())
        state.projects[index].terminals.append(terminal)
        if addedProject {
            try database.addProject(state.projects[index], position: index)
        } else {
            try database.saveProject(state.projects[index], position: index)
        }
        return PTYHostSessionIdentity(.projectTerminal(terminal.id))
    }
    private static func createAgent(store: String, directory: String, shell: String,
                                    kind: AgentKind, executable: String, accountHandle: AccountHandle,
                                    accountPath: String, id: SessionID) throws -> AgentLaunchPlan {
        guard shell.hasPrefix("/"), executable.hasPrefix("/") else {
            throw WindowFailure("shell and agent executable must be absolute paths")
        }
        guard let folder = ProjectDirectory.existing(at: directory) else {
            throw WindowFailure("project directory does not exist")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        // The 5,100-session stress fixture for navigation establishes this bound: a fresh
        // launch needs counts and one project identity, not every retained session payload.
        let catalog = try database.navigationSnapshot(recentSessionLimit: 0, recentTerminalLimit: 0)
        guard let project = catalog.projects.first(where: { $0.folderPath == folder.path }) else {
            throw WindowFailure("project is not in this store")
        }
        guard try database.sessionRecord(id: id) == nil else {
            throw WindowFailure("session identity already exists")
        }
        guard var session = AgentSessionCreation.makeRecord(kind: kind,
                                                            accountHandle: accountHandle,
                                                            permissionMode: .manual, id: id) else {
            throw WindowFailure("unsupported session configuration")
        }
        let agentCommand: ShellCommand
        let resumeState: ResumeState
        switch kind {
        case .codex:
            (agentCommand, resumeState) = CodexLaunchCommand.terminal(executable: executable,
                model: nil, permissionMode: session.permissionMode,
                resumeState: session.resumeState, prompt: nil)
        case .claude:
            let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: executable,
                permissionMode: session.permissionMode, prompt: nil)
            agentCommand = pair.fresh
            resumeState = .resumable(pair.transcriptID)
        case .grok, .openCode, .cursor:
            throw WindowFailure("unsupported agent kind")
        }
        var command = AgentAccountRoute.prefix(for: kind, handle: session.accountHandle,
                                               configPath: accountPath)
        command.append(contentsOf: agentCommand)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: folder.path,
            shellPath: shell, resumeState: resumeState)
        AgentLaunchRecording.apply(plan, to: &session, at: Date())
        try database.addSession(session, to: project.id, position: project.sessionCount,
                                selectNewSession: true)
        return plan
    }
    private func received(_ frame: PTYHostFrame) {
        switch frame {
        case .attached(let value):
            guard attaching, value.id == identity, replayRemaining == nil else {
                fail(WindowFailure("unexpected attach identity or duplicate reply")); return
            }
            guard let count = value.replayByteCount, (0...Self.maximumReplayBytes).contains(count) else {
                fail(WindowFailure("daemon did not provide a valid replay boundary")); return
            }
            guard value.grid.cols <= Self.maximumAttachColumns, value.grid.rows <= Self.maximumAttachRows else {
                fail(WindowFailure("saved terminal grid exceeds current window bounds")); return
            }
            do { try emulator?.resize(columns: value.grid.cols, rows: value.grid.rows) }
            catch { fail(error); return }
            switch value.replay {
            case .cut: replayLabel = " [history cut]"
            case .exact: replayLabel = " [restored]"
            case .none:
                guard count == 0 else { fail(WindowFailure("nonempty replay marked as none")); return }
                replayLabel = " [no history]"
            }
            // Adopt the daemon grid by sizing the window; attachment itself never sends resize.
            lastWidth = max(320, value.grid.cols * Self.cellWidth)
            lastHeight = max(180, value.grid.rows * Self.cellHeight)
            replayRemaining = count
            lock.lock(); initialViewport = (lastWidth, lastHeight); running = count == 0; lock.unlock()
            agentResume = nil
            dirty = true
        case .spawned(let value):
            guard !attaching, value.id == identity else { fail(WindowFailure("spawn identity mismatch")); return }
            lock.lock(); running = true; lock.unlock(); dirty = true
            if let discovery = codexDiscovery {
                codexDiscovery = nil
                Self.discoverCodexSession(discovery)
            }
        case .exited(let value):
            guard value.id == identity else { fail(WindowFailure("exit identity mismatch")); return }
            guard !attaching || replayRemaining == 0 else { fail(WindowFailure("exit before completed replay")); return }
            exitStatus = value.signalled ? 128 + value.status : value.status
            lock.lock(); running = false; spawnMayBeLive = false; finished = true; lock.unlock(); dirty = true
        case .spawnRefused(let value):
            guard value.id == identity else { fail(WindowFailure("spawn refusal identity mismatch")); return }
            if value.reason != .alreadyExists {
                lock.lock(); spawnMayBeLive = false; lock.unlock()
            }
            fail(WindowFailure("spawn refused: \(value.reason)"))
        case .error(let value) where value.code == .sessionExited && value.detail == "input":
            // Input can cross child exit. Its refusal is not the child's exit status.
            lock.lock(); running = false; lock.unlock()
            guard exitStatus == nil, !waitingForExit else { return }
            waitingForExit = true
            worker.asyncAfter(deadline: .now() + Self.exitWaitSeconds) { [weak self] in
                guard let self, self.exitStatus == nil else { return }
                self.fail(WindowFailure("timed out waiting for child exit after input refusal"))
            }
        case .error(let value) where value.code == .unknownSession && value.detail == "attach" && attaching:
            guard let resume = agentResume else { fail(WindowFailure("PTY: \(value)")); return }
            agentResume = nil
            do {
                let (plan, directory) = try Self.resumeAgent(store: resume.store,
                    sessionID: resume.sessionID, shell: resume.shell,
                    codex: resume.codex, claude: resume.claude)
                let columns = max(2, resume.width / Self.cellWidth), rows = max(1, resume.height / Self.cellHeight)
                connectionGeneration += 1
                client?.close()
                client = nil
                let link = try connect(socket: resume.socket, columns: columns, rows: rows)
                lastWidth = resume.width; lastHeight = resume.height
                attaching = false
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                try link.spawn(PTYHostSpawnRequest(id: .agentSession(resume.sessionID),
                    channel: .pty(grid: PTYHostGrid(cols: columns, rows: rows)),
                    executable: plan.executable, arguments: plan.arguments,
                    environment: Self.launchEnvironment(), cwd: directory))
            } catch { fail(error) }
        case .error(let value): fail(WindowFailure("PTY: \(value)"))
        default: break
        }
    }
    private static func discoverCodexSession(
        _ launch: (store: String, directory: String, home: String, sessionID: SessionID, launchedAt: Date)
    ) {
        DispatchQueue.global(qos: .utility).async {
            let sessions = URL(fileURLWithPath: launch.home, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
            for _ in 0..<CodexDiscoveryDefaults.maxAttempts {
                if let id = CodexRolloutIdentity.find(projectPath: launch.directory,
                    sessionsDirectory: sessions, launchedAt: launch.launchedAt) {
                    do {
                        if try persistCodexID(id, in: launch.store, for: launch.sessionID) {
                            print("CODEX_SESSION_ID \(launch.sessionID) \(id)"); fflush(nil)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("Codex session discovery: \(error)\n".utf8))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: CodexDiscoveryDefaults.pollInterval)
            }
        }
    }
    private static func persistCodexID(_ id: TranscriptID, in store: String, for sessionID: SessionID) throws -> Bool {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID),
              record.session.resumeState == .awaitingIdentifier else { return false }
        var session = record.session
        session.resumeState = .resumable(id)
        try database.saveSession(session, in: record.project.id, position: record.position)
        return true
    }
    private static func resumeAgent(store: String, sessionID: SessionID, shell: String,
                                    codex: String?, claude: String?) throws -> (AgentLaunchPlan, String) {
        guard shell.hasPrefix("/") else { throw WindowFailure("shell must be an absolute path") }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID),
              record.session.resumeState.isResumable else {
            throw WindowFailure("saved agent has no resumable conversation")
        }
        let project = record.project
        var session = record.session
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WindowFailure("project directory does not exist") }
        guard let id = session.resumeState.transcriptID else {
            throw WindowFailure("saved agent has no conversation identifier")
        }
        let accountPath = try accountPath(for: session.kind, handle: session.accountHandle)
        let agentCommand: ShellCommand
        let resumeState: ResumeState
        switch session.kind {
        case .codex:
            guard let codex, codex.hasPrefix("/") else {
                throw WindowFailure("Codex executable is unavailable")
            }
            let home = URL(fileURLWithPath: accountPath, isDirectory: true)
            guard let rollout = CodexRolloutIdentity.rolloutURL(for: id, projectPath: project.folderPath,
                sessionsDirectory: home.appendingPathComponent(
                    AgentAccountDefaults.sessionsSubdirectory, isDirectory: true),
                launchedAt: session.createdAt) else {
                throw WindowFailure("saved Codex conversation is missing from its account")
            }
            guard !CodexRolloutNumbering.isMixed(at: rollout) else {
                throw WindowFailure("saved Codex conversation has broken record numbering")
            }
            (agentCommand, resumeState) = CodexLaunchCommand.terminal(executable: codex,
                model: session.model, permissionMode: session.permissionMode,
                resumeState: session.resumeState, prompt: nil)
        case .claude:
            guard let claude, claude.hasPrefix("/") else {
                throw WindowFailure("Claude executable is unavailable")
            }
            guard let transcript = ClaudeTranscriptPath.storageURL(sessionID: id,
                configPath: accountPath, projectPath: project.folderPath),
                FileManager.default.fileExists(atPath: transcript.path) else {
                throw WindowFailure("saved Claude conversation is missing from its account")
            }
            let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: claude,
                permissionMode: session.permissionMode, prompt: nil)
            agentCommand = pair.resume
            resumeState = .resumable(pair.transcriptID)
        case .grok, .openCode, .cursor:
            throw WindowFailure("saved agent kind is unavailable in this window")
        }
        var command = AgentAccountRoute.prefix(for: session.kind, handle: session.accountHandle,
                                               configPath: accountPath)
        command.append(contentsOf: agentCommand)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: project.folderPath,
            shellPath: shell, resumeState: resumeState)
        AgentLaunchRecording.apply(plan, to: &session, at: Date())
        try database.saveSession(session, in: project.id, position: record.position)
        return (plan, project.folderPath)
    }
    private func fail(_ error: Error) {
        lock.lock(); if !closed && failure == nil { failure = String(describing: error) }; lock.unlock()
    }
    func send(_ bytes: Data) {
        guard bytes.count <= 32 else { fail(WindowFailure("input event exceeds byte budget")); return }
        submit(.text(bytes))
    }
    func paste(_ bytes: Data) {
        guard !bytes.isEmpty && bytes.count <= Self.maximumPasteBytes else { return }
        submit(.paste(bytes))
    }
    func key(_ key: PTYEmulator.Key, modifiers: PTYEmulator.Modifiers, action: PTYEmulator.KeyAction) {
        submit(.key(key, modifiers, action))
    }
    func mouseButton(x: Int, y: Int, button: Int, release: Bool, modifiers: PTYEmulator.Modifiers) {
        submit(.mouseButton(x, y, button, release, modifiers))
    }
    // Pointer motion can arrive faster than frames. Keep only its latest position and one
    // worker hop; press/release and copy remain ordered in the ordinary input queue.
    func mouseMotion(x: Int, y: Int) {
        lock.lock()
        guard !closed && failure == nil && (running || finished) else { lock.unlock(); return }
        pendingSelectionMotion = (x, y)
        guard !selectionMotionScheduled else { lock.unlock(); return }
        selectionMotionScheduled = true
        worker.async { [self] in
            lock.lock()
            let point = pendingSelectionMotion
            pendingSelectionMotion = nil
            selectionMotionScheduled = false
            let admitted = !closed && failure == nil && (running || finished)
            lock.unlock()
            if admitted, let point, emulator?.mouseMotion(x: point.x, y: point.y) == true {
                dirty = true
            }
        }
        lock.unlock()
    }
    func mouseWheel(x: Int, y: Int, steps: Int, modifiers: PTYEmulator.Modifiers) {
        submit(.mouseWheel(x, y, steps, modifiers))
    }
    func requestCopySelection() { submit(.copySelection) }
    func takeCopyResult() -> PTYEmulator.CopyResult? {
        lock.lock(); defer { lock.unlock() }
        let result = copyResult
        copyResult = nil
        return result
    }
    private func submit(_ input: Input) {
        let localWhenFinished: Bool
        switch input {
        case .mouseButton, .mouseWheel, .copySelection: localWhenFinished = true
        default: localWhenFinished = false
        }
        lock.lock()
        guard !closed && failure == nil && (running || (finished && localWhenFinished)) else {
            lock.unlock(); return
        }
        // Text and functional events share one ordered worker hop. Native key repeat cannot
        // create an unbounded queue while output parsing is busy; overflow is explicit.
        guard pendingInputCount < 256 else {
            failure = "terminal input queue overflow"; lock.unlock(); return
        }
        pendingInputCount += 1
        worker.async { [self] in
            lock.lock()
            pendingInputCount -= 1
            let admitted = !closed && failure == nil && (running || (finished && localWhenFinished))
            let childFinished = finished
            lock.unlock()
            guard admitted else { return }
            switch input {
            case .text(let bytes): emulator?.input(bytes)
            case .paste(let bytes): emulator?.paste(bytes)
            case .key(let key, let modifiers, let action): emulator?.key(key, modifiers: modifiers, action: action)
            case .mouseButton(let x, let y, let button, let release, let modifiers):
                if emulator?.mouseButton(x: x, y: y, button: button, release: release,
                                         modifiers: modifiers, forceLocal: childFinished) == true {
                    dirty = true
                }
            case .mouseWheel(let x, let y, let steps, let modifiers):
                if emulator?.mouseWheel(x: x, y: y, steps: steps, modifiers: modifiers,
                                        forceLocal: childFinished) == true {
                    dirty = true
                }
            case .copySelection:
                let result = emulator?.copySelection(maximumBytes: Self.maximumCopyBytes) ?? .empty
                lock.lock(); copyResult = result; lock.unlock()
            }
        }
        lock.unlock()
    }
    func stop() {
        lock.lock(); closed = true; running = false; frame = nil; lock.unlock()
        worker.async { [self] in client?.close() }
    }
    func takeFrame() throws -> Frame? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw WindowFailure(failure) }
        let value = frame; frame = nil; return value
    }
    var hasCreatedTerminal: Bool {
        lock.lock(); defer { lock.unlock() }
        return createdTerminal
    }
    var hasCreatedAgent: Bool {
        lock.lock(); defer { lock.unlock() }
        return createdAgent
    }
    var canReplace: Bool {
        lock.lock(); defer { lock.unlock() }
        return !spawnMayBeLive && (finished || failure != nil)
    }
    func takeInitialViewport() -> (Int, Int)? {
        lock.lock(); defer { lock.unlock() }
        let value = initialViewport; initialViewport = nil
        if value != nil { worker.async { [self] in attachmentViewportApplied = true } }
        return value
    }
    func invalidateFrame() {
        worker.async { [self] in dirty = true }
    }
    func setPreedit(_ text: String?, cursor: Int = 0, selectionLength: Int = 0) {
        worker.async { [self] in
            let bounded = text.flatMap { value -> Preedit? in
                guard !value.isEmpty else { return nil }
                let visible = value.utf8.count <= 1023 ? value : "[composition exceeds 1 KiB]"
                return Preedit(text: visible, cursor: cursor, selectionLength: selectionLength)
            }
            guard preedit != bounded else { return }
            preedit = bounded
            dirty = true
        }
    }
    func requestFrame(width: Int, height: Int) {
        lock.lock()
        guard !pendingFrame && !closed else { lock.unlock(); return }
        pendingFrame = true; lock.unlock()
        worker.async { [self] in
            guard let emulator, !attaching || (replayRemaining == 0 && attachmentViewportApplied) else { finish(nil); return }
            do {
                if lastWidth != width || lastHeight != height {
                    let columns = max(2, width / Self.cellWidth), rows = max(1, height / Self.cellHeight)
                    try emulator.resize(columns: columns, rows: rows)
                    if let identity, exitStatus == nil {
                        try client?.resize(PTYHostResize(id: identity, grid: PTYHostGrid(cols: columns, rows: rows)))
                    }
                    lastWidth = width; lastHeight = height; dirty = true
                }
                guard dirty else { finish(nil); return }
                dirty = false
                let snapshot = emulator.snapshot()
                let title = (exitStatus.map { "Threading terminal - exited \($0)" }
                    ?? "Threading terminal - \(snapshot.title.isEmpty ? "running" : snapshot.title)")
                    + replayLabel + (snapshot.atLiveEnd ? "" : " [scrollback]")
                let preedit = self.preedit
                drawing.async { [self] in
                    do { finish(try Self.draw(snapshot, width: width, height: height,
                                              title: title, preedit: preedit)) }
                    catch { fail(error); finish(nil) }
                }
            } catch { fail(error); finish(nil) }
        }
    }
    private func finish(_ value: Frame?) {
        lock.lock(); if !closed, let value { frame = value }; pendingFrame = false; lock.unlock()
    }
    private static func draw(_ snapshot: PTYEmulator.Snapshot, width: Int, height: Int,
                             title: String, preedit: Preedit?) throws -> Frame {
        let started = DispatchTime.now().uptimeNanoseconds
        let (accessibleText, accessibleCaret, accessibleRuns) = accessibleScreen(snapshot)
        var text = Data(), cells: [TWCell] = []
        cells.reserveCapacity(snapshot.cells.count)
        for cell in snapshot.cells {
            let bytes = Data(cell.text.utf8)
            guard text.count + bytes.count <= 4 * 1024 * 1024 else { throw WindowFailure("visible text budget exceeded") }
            cells.append(TWCell(offset: Int32(text.count), length: Int32(bytes.count), width: Int32(cell.width),
                foreground: cell.foregroundRGB, background: cell.backgroundRGB,
                bold: cell.attribute.style.contains(.bold) ? 1 : 0,
                underline: cell.attribute.style.contains(.underline) ? 1 : 0))
            text.append(bytes)
        }
        var pixels = Data(count: width * height * 4)
        let preeditBytes = Data(preedit?.text.utf8 ?? "".utf8)
        let result = pixels.withUnsafeMutableBytes { pixels in
            text.withUnsafeBytes { text in
                cells.withUnsafeBufferPointer { cells in
                    preeditBytes.withUnsafeBytes { preeditBytes in
                        tw_render_terminal(pixels.bindMemory(to: UInt8.self).baseAddress, Int32(width), Int32(height),
                            cells.baseAddress, Int32(snapshot.columns), Int32(snapshot.rows),
                            text.bindMemory(to: CChar.self).baseAddress, Int32(text.count),
                            Int32(snapshot.cursorColumn), Int32(snapshot.cursorRow),
                            preeditBytes.bindMemory(to: CChar.self).baseAddress, Int32(preeditBytes.count),
                            Int32(preedit?.cursor ?? 0), Int32(preedit?.selectionLength ?? 0))
                    }
                }
            }
        }
        guard result == 0 else { throw WindowFailure("terminal rasterization failed") }
        return Frame(pixels: pixels, width: width, height: height, title: title,
                     cursorColumn: snapshot.cursorColumn, cursorRow: snapshot.cursorRow,
                     accessibleText: accessibleText, accessibleCaret: accessibleCaret,
                     accessibleRuns: accessibleRuns,
                     drawMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    /// Project the already-copied visible grid on the drawing worker. Keep terminal whitespace
    /// through the cursor, but omit unused columns and trailing blank rows. Conceal style must
    /// mask content here independently of the renderer's foreground/background colors.
    private static func accessibleScreen(_ snapshot: PTYEmulator.Snapshot) -> (String, Int, [TextRun]) {
        var lines: [String] = []
        var lineRuns: [[TextRun]] = []
        lines.reserveCapacity(snapshot.rows)
        lineRuns.reserveCapacity(snapshot.rows)
        var caret = -1, characters = 0, bytes = 0
        for row in 0..<snapshot.rows {
            var parts: [String] = []
            var runs: [TextRun] = []
            parts.reserveCapacity(snapshot.columns)
            runs.reserveCapacity(snapshot.columns)
            var nonblank = 0, cursorEnd = 0, columnCharacters = 0
            for column in 0..<snapshot.columns {
                if row == snapshot.cursorRow && column == snapshot.cursorColumn {
                    cursorEnd = parts.count
                    caret = characters + columnCharacters
                }
                let cell = snapshot.cells[row * snapshot.columns + column]
                guard cell.width != 0 else { continue }
                let value = cell.attribute.style.contains(.invisible) ? " " : cell.text
                let scalarCount = value.unicodeScalars.count
                guard scalarCount > 0 else { continue }
                parts.append(value)
                runs.append(TextRun(offset: Int32(columnCharacters), characters: Int32(scalarCount),
                                    column: Int32(column), row: Int32(row), cells: Int32(cell.width)))
                columnCharacters += scalarCount
                if value != " " { nonblank = parts.count }
            }
            if row == snapshot.cursorRow && snapshot.cursorColumn == snapshot.columns {
                cursorEnd = parts.count
                caret = characters + columnCharacters
            }
            let kept = max(nonblank, cursorEnd)
            let line = parts.prefix(kept).joined()
            lines.append(line)
            lineRuns.append(Array(runs.prefix(kept)))
            bytes += line.utf8.count + (row == 0 ? 0 : 1)
            if bytes > 64 * 1024 { return ("[visible terminal text exceeds 64 KiB]", -1, []) }
            characters += line.unicodeScalars.count + 1
        }
        let last = max(lines.lastIndex(where: { !$0.isEmpty }) ?? -1,
                       snapshot.cursorColumn >= 0 ? snapshot.cursorRow : -1)
        let screen = last >= 0 ? lines.prefix(last + 1).joined(separator: "\n") : ""
        var mapped: [TextRun] = []
        mapped.reserveCapacity(min(snapshot.cells.count, 128 * 40) + snapshot.rows)
        var offset = 0
        if last >= 0 {
            for row in 0...last {
                for run in lineRuns[row] {
                    mapped.append(TextRun(offset: Int32(offset) + run.offset,
                                          characters: run.characters, column: run.column,
                                          row: run.row, cells: run.cells))
                }
                offset += lines[row].unicodeScalars.count
                if row < last {
                    let lastCell = lineRuns[row].last
                    let endColumn = (lastCell?.column ?? 0) + (lastCell?.cells ?? 0)
                    mapped.append(TextRun(offset: Int32(offset), characters: 1,
                                          column: endColumn, row: Int32(row), cells: 0))
                    offset += 1
                }
            }
        }
        return (screen, caret, mapped)
    }
}
#endif
