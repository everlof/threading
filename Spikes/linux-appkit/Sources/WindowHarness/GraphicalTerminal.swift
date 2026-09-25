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
    static let maximumPasteBytes = 64 * 1024
    static let maximumCopyBytes = 1024 * 1024
    private static let exitWaitSeconds: Double = 5
    private static let maximumReplayBytes = 4 * 1024 * 1024
    private static let maximumAttachColumns = 128
    private static let maximumAttachRows = 40
    struct Frame: Sendable {
        let pixels: Data
        let width: Int
        let height: Int
        let title: String
        let drawMilliseconds: Double
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
    private var lastWidth = 0, lastHeight = 0
    private var exitStatus: Int32?
    private var waitingForExit = false
    private var attaching = false
    private var replayRemaining: Int?
    private var replayLabel = ""
    private var attachmentViewportApplied = false
    private var codexDiscovery: (store: String, directory: String, home: String, sessionID: SessionID, launchedAt: Date)?
    private var codexResume: (store: String, socket: String, shell: String, executable: String, sessionID: SessionID,
                              width: Int, height: Int)?

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
                    codex: String, id: SessionID, width: Int, height: Int) {
        worker.async { [self] in
            do {
                let columns = max(2, width / 10), rows = max(1, height / 22)
                let link = try connect(socket: socket, columns: columns, rows: rows)
                let home = try Self.standardCodexHome()
                let plan = try Self.createAgent(store: store, directory: directory,
                                                shell: shell, codex: codex, id: id)
                let environment = Self.launchEnvironment()
                let identity = PTYHostSessionIdentity.agentSession(id)
                self.identity = identity
                codexDiscovery = (store, directory, home.path, id, Date())
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
    private static func standardCodexHome() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            throw WindowFailure("an absolute HOME is required for the default Codex account")
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
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
                   codex: String, width: Int, height: Int) {
        attach(store: store, socket: socket, savedID: sessionID, kind: .agent,
               resume: (shell, codex, width, height))
    }
    private enum SavedKind { case terminal, agent }
    private func attach(store: String, socket: String, savedID: String, kind: SavedKind,
                        resume: (String, String, Int, Int)? = nil) {
        worker.async { [self] in
            do {
                attaching = true
                lock.lock(); spawnMayBeLive = true; lock.unlock()
                let id = try Self.storedIdentity(store: store, savedID: savedID, kind: kind)
                identity = id
                if let resume, let uuid = UUID(uuidString: savedID) {
                    codexResume = (store, socket, resume.0, resume.1, SessionID(uuid), resume.2, resume.3)
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
                                    codex: String, id: SessionID) throws -> AgentLaunchPlan {
        guard shell.hasPrefix("/"), codex.hasPrefix("/") else {
            throw WindowFailure("shell and Codex executable must be absolute paths")
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
        let state = try database.load().state
        guard let projectIndex = state.projects.firstIndex(where: { $0.folderPath == folder.path }) else {
            throw WindowFailure("project is not in this store")
        }
        guard !state.projects.contains(where: { $0.sessions.contains(where: { $0.id == id }) }) else {
            throw WindowFailure("session identity already exists")
        }
        guard var session = AgentSessionCreation.makeRecord(kind: .codex,
                                                            permissionMode: .manual, id: id) else {
            throw WindowFailure("unsupported session configuration")
        }
        let (codexCommand, resumeState) = CodexLaunchCommand.terminal(executable: codex, model: nil,
            permissionMode: session.permissionMode, resumeState: session.resumeState, prompt: nil)
        var command = AgentAccountRoute.prefix(for: .codex, handle: session.accountHandle, configPath: "")
        command.append(contentsOf: codexCommand)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: folder.path,
            shellPath: shell, resumeState: resumeState)
        AgentLaunchRecording.apply(plan, to: &session, at: Date())
        let project = state.projects[projectIndex]
        try database.addSession(session, to: project.id, position: project.sessions.count,
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
            lastWidth = max(320, value.grid.cols * 10)
            lastHeight = max(180, value.grid.rows * 22)
            replayRemaining = count
            lock.lock(); initialViewport = (lastWidth, lastHeight); running = count == 0; lock.unlock()
            codexResume = nil
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
            guard let resume = codexResume else { fail(WindowFailure("PTY: \(value)")); return }
            codexResume = nil
            do {
                let (plan, directory) = try Self.resumeAgent(store: resume.store,
                    sessionID: resume.sessionID, shell: resume.shell, codex: resume.executable)
                let columns = max(2, resume.width / 10), rows = max(1, resume.height / 22)
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
                                    codex: String) throws -> (AgentLaunchPlan, String) {
        guard shell.hasPrefix("/"), codex.hasPrefix("/") else {
            throw WindowFailure("shell and Codex executable must be absolute paths")
        }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let fd = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned") }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID),
              record.session.kind == .codex,
              record.session.resumeState.isResumable else {
            throw WindowFailure("saved agent has no resumable Codex conversation")
        }
        let project = record.project
        var session = record.session
        guard session.accountHandle.isStandard else {
            throw WindowFailure("this Linux window cannot route a named Codex account")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.folderPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WindowFailure("project directory does not exist") }
        guard let id = session.resumeState.transcriptID,
              let rollout = CodexRolloutIdentity.rolloutURL(for: id, projectPath: project.folderPath,
                  sessionsDirectory: try Self.standardCodexHome().appendingPathComponent("sessions", isDirectory: true),
                  launchedAt: session.createdAt) else {
            throw WindowFailure("saved Codex conversation is missing from the default account")
        }
        guard !CodexRolloutNumbering.isMixed(at: rollout) else {
            throw WindowFailure("saved Codex conversation has broken record numbering")
        }
        let (codexCommand, resumeState) = CodexLaunchCommand.terminal(executable: codex,
            model: session.model, permissionMode: session.permissionMode,
            resumeState: session.resumeState, prompt: nil)
        var command = AgentAccountRoute.prefix(for: .codex, handle: session.accountHandle, configPath: "")
        command.append(contentsOf: codexCommand)
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
    func requestFrame(width: Int, height: Int) {
        lock.lock()
        guard !pendingFrame && !closed else { lock.unlock(); return }
        pendingFrame = true; lock.unlock()
        worker.async { [self] in
            guard let emulator, !attaching || (replayRemaining == 0 && attachmentViewportApplied) else { finish(nil); return }
            do {
                if lastWidth != width || lastHeight != height {
                    let columns = max(2, width / 10), rows = max(1, height / 22)
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
                drawing.async { [self] in
                    do { finish(try Self.draw(snapshot, width: width, height: height, title: title)) }
                    catch { fail(error); finish(nil) }
                }
            } catch { fail(error); finish(nil) }
        }
    }
    private func finish(_ value: Frame?) {
        lock.lock(); if !closed, let value { frame = value }; pendingFrame = false; lock.unlock()
    }
    private static func draw(_ snapshot: PTYEmulator.Snapshot, width: Int, height: Int, title: String) throws -> Frame {
        let started = DispatchTime.now().uptimeNanoseconds
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
        let result = pixels.withUnsafeMutableBytes { pixels in
            text.withUnsafeBytes { text in
                cells.withUnsafeBufferPointer { cells in
                    tw_render_terminal(pixels.bindMemory(to: UInt8.self).baseAddress, Int32(width), Int32(height),
                        cells.baseAddress, Int32(snapshot.columns), Int32(snapshot.rows),
                        text.bindMemory(to: CChar.self).baseAddress, Int32(text.count),
                        Int32(snapshot.cursorColumn), Int32(snapshot.cursorRow))
                }
            }
        }
        guard result == 0 else { throw WindowFailure("terminal rasterization failed") }
        return Frame(pixels: pixels, width: width, height: height, title: title,
                     drawMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }
}
#endif
