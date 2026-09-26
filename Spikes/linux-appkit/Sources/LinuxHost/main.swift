// Experimental headless host. The native app remains the goal; this exercises its storage/PTY seam.
@testable import CoreSlice
import Foundation
import ThreadingPTYClient
import ThreadingPTYHostKit
#if os(Linux)
import Glibc

enum HostFailure: Error { case refused(String) }
func check(_ value: Bool, _ message: String) throws {
    if !value { throw HostFailure.refused(message) }
}

/// Host facts are resolved here; the run-identity policy is the production macOS policy.
/// Preserve the Linux caller's PATH, HOME, login locations and credentials. No Mac settings or
/// environment are forwarded into this host. Terminal colour/pager policy remains caller-owned
/// until this host owns a graphical emulator and can state its capabilities.
func launchEnvironment() -> [String] {
    var environment = AgentEnvironment.removingInheritedIdentity(from: ProcessInfo.processInfo.environment)
    if environment[EnvironmentKeys.path] == nil { environment[EnvironmentKeys.path] = "/usr/local/bin:/usr/bin:/bin" }
    if environment[EnvironmentKeys.term] == nil { environment[EnvironmentKeys.term] = "xterm-256color" }
    if environment[EnvironmentKeys.lang] == nil { environment[EnvironmentKeys.lang] = "C.UTF-8" }
    return environment.map { "\($0.key)=\($0.value)" }
}

func projectDirectory(_ path: String) throws -> URL {
    guard let folder = ProjectDirectory.existing(at: path) else {
        throw HostFailure.refused("project directory does not exist")
    }
    return folder
}

func run() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    let addingProject = args.first == "--add-project"
    let initializingStore = args.first == "--init-store"
    try check(initializingStore ? args.count == 2 : (addingProject ? args.count == 3 : args.count >= 3),
        "usage: LinuxHost --init-store STORE | --add-project STORE DIRECTORY | STORE SOCKET list | run DIRECTORY EXECUTABLE [ARG ...] | login-run DIRECTORY SHELL EXECUTABLE [ARG ...] | attach TERMINAL_UUID | codex DIRECTORY SHELL CODEX_EXECUTABLE PROMPT [ACCOUNT_HANDLE] | claude DIRECTORY SHELL CLAUDE_EXECUTABLE PROMPT [ACCOUNT_HANDLE] | resume-claude SESSION_UUID SHELL CLAUDE_EXECUTABLE | attach-agent SESSION_UUID")
    let importFolder = addingProject ? try projectDirectory(args[2]) : nil
    // Establish the signal mask before database decoding can create worker threads.
    let terminalControl: LocalTerminal? = initializingStore || addingProject || args[2] == "list" ? nil : try LocalTerminal()
    let root = URL(fileURLWithPath: args[initializingStore || addingProject ? 1 : 0], isDirectory: true)
    if !initializingStore && !addingProject && args[2] == "resume-claude" {
        try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("threading.db").path),
                  "saved session store does not exist")
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    // One CLI writer per store; never silently reconcile against a concurrent host.
    let lock = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    try check(lock >= 0, "cannot open store lock")
    defer { Glibc.close(lock) }
    try check(flock(lock, LOCK_EX | LOCK_NB) == 0, "store is already owned by another host")
    let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
    defer { database.close() }
    if initializingStore { return 0 }
    if let folder = importFolder {
        let projects = try database.navigationSnapshot(recentSessionLimit: 0,
                                                       recentTerminalLimit: 0).projects
        if !projects.contains(where: { $0.folderPath == folder.path }) {
            try database.addProject(Project(name: folder.lastPathComponent, folderURL: folder),
                                    position: projects.count)
        }
        print(folder.path)
        return 0
    }
    if args[2] == "list" {
        let state = try database.load().state
        for project in state.projects {
            print("\(project.id)\t\(project.folderPath)")
            for session in project.sessions { print("  agent \(session.id)\t\(session.kind.rawValue)\t\(session.title)") }
            for terminal in project.terminals { print("  \(terminal.id)\t\(terminal.title)") }
        }
        return 0
    }
    let localTerminal = terminalControl!
    let identity: PTYHostSessionIdentity
    let inbox = try HostEventInbox()
    let link = PTYHostClient(socketPath: args[1], build: "linux-host-spike", events: inbox.events,
                             journal: { _, _ in })
    defer { link.close() }
    try link.connect()
    var pendingResumeRecording: (session: AgentSession, projectID: ProjectID,
                                 position: Int, plan: AgentLaunchPlan)? = nil
    if args[2] == "codex" || args[2] == "claude" {
        let state = try database.load().state
        let isCodex = args[2] == "codex"
        try check(args.count == 7 || args.count == 8,
                  "managed agent requires DIRECTORY SHELL EXECUTABLE PROMPT [ACCOUNT_HANDLE]")
        try check(args[4].hasPrefix("/") && args[5].hasPrefix("/"),
                  "shell and agent executable must be absolute paths")
        let folder = try projectDirectory(args[3])
        let handle = args.count == 8 ? AccountHandle(storedName: args[7]) : .standard
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            throw HostFailure.refused("an absolute HOME is required for agent account routing")
        }
        let accountPath: String
        if isCodex {
            guard let account = CodexAccountLocations.resolve(handle,
                home: URL(fileURLWithPath: home, isDirectory: true)) else {
                throw HostFailure.refused("Codex account is unavailable")
            }
            accountPath = account.configPath
        } else {
            guard let account = ClaudeAccountLocations.resolve(handle,
                home: URL(fileURLWithPath: home, isDirectory: true)) else {
                throw HostFailure.refused("Claude account is unavailable")
            }
            accountPath = account.configPath
        }
        // The same fresh-record admission/defaults as macOS. This host has no model/effort
        // override and starts in Manual rather than inheriting a permissive CLI default.
        let kind: AgentKind = isCodex ? .codex : .claude
        guard var session = AgentSessionCreation.makeRecord(kind: kind,
                                                            accountHandle: handle,
                                                            permissionMode: .manual) else {
            throw HostFailure.refused("unsupported session configuration")
        }
        let agentCommand: ShellCommand
        let resumeState: ResumeState
        if isCodex {
            (agentCommand, resumeState) = CodexLaunchCommand.terminal(executable: args[5], model: nil,
                permissionMode: session.permissionMode, resumeState: session.resumeState, prompt: args[6])
        } else {
            let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: args[5],
                permissionMode: session.permissionMode, prompt: args[6])
            agentCommand = pair.fresh
            resumeState = .resumable(pair.transcriptID)
        }
        var command = AgentAccountRoute.prefix(for: kind, handle: session.accountHandle,
                                               configPath: accountPath)
        command.append(contentsOf: agentCommand)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: folder.path,
            shellPath: args[4], resumeState: resumeState)
        AgentLaunchRecording.apply(plan, to: &session, at: Date())
        if let existing = state.projects.firstIndex(where: { $0.folderPath == folder.path }) {
            let project = state.projects[existing]
            try database.addSession(session, to: project.id, position: project.sessions.count,
                                    selectNewSession: true)
        } else {
            let project = Project(name: folder.lastPathComponent, folderURL: folder)
            try database.addProjectAndSession(project, session: session, position: state.projects.count,
                                              selectNewSession: true)
        }
        identity = .agentSession(session.id)
        try link.send(.spawn(PTYHostSpawnRequest(id: identity,
            channel: .pty(grid: localTerminal.grid ?? PTYHostGrid(cols: 80, rows: 24)),
            executable: plan.executable, arguments: plan.arguments, environment: launchEnvironment(), cwd: folder.path)))
    } else if args[2] == "resume-claude" {
        try check(args.count == 6, "resume-claude requires SESSION_UUID SHELL CLAUDE_EXECUTABLE")
        guard let uuid = UUID(uuidString: args[3]) else { throw HostFailure.refused("invalid session UUID") }
        try check(args[4].hasPrefix("/") && args[5].hasPrefix("/"),
                  "shell and Claude executable must be absolute paths")
        let sessionID = SessionID(uuid)
        guard let record = try database.sessionRecord(id: sessionID),
              record.session.kind == .claude,
              let transcriptID = record.session.resumeState.transcriptID,
              record.session.resumeState.isResumable else {
            throw HostFailure.refused("saved Claude conversation is unavailable")
        }
        let folder = record.project.folderPath
        _ = try projectDirectory(folder)
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/"),
              let account = ClaudeAccountLocations.resolve(record.session.accountHandle,
                  home: URL(fileURLWithPath: home, isDirectory: true)) else {
            throw HostFailure.refused("saved Claude account is unavailable")
        }
        guard let transcript = ClaudeTranscriptPath.storageURL(sessionID: transcriptID,
            configPath: account.configPath, projectPath: folder) else {
            throw HostFailure.refused("saved Claude conversation has an invalid identifier")
        }
        var isDirectory: ObjCBool = false
        try check(FileManager.default.fileExists(atPath: transcript.path, isDirectory: &isDirectory)
                  && !isDirectory.boolValue,
                  "saved Claude conversation is missing from its account")
        let session = record.session
        let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: args[5],
            permissionMode: session.permissionMode, prompt: nil)
        var command = AgentAccountRoute.prefix(for: .claude, handle: session.accountHandle,
                                               configPath: account.configPath)
        command.append(contentsOf: pair.resume)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: folder,
            shellPath: args[4], resumeState: .resumable(pair.transcriptID))
        // This row already exists. Wait for daemon admission so a live-child refusal does not
        // rewrite its activity or exit status; persist before forwarding any input.
        pendingResumeRecording = (session, record.project.id, record.position, plan)
        identity = .agentSession(sessionID)
        try link.send(.spawn(PTYHostSpawnRequest(id: identity,
            channel: .pty(grid: localTerminal.grid ?? PTYHostGrid(cols: 80, rows: 24)),
            executable: plan.executable, arguments: plan.arguments,
            environment: launchEnvironment(), cwd: folder)))
    } else if args[2] == "attach-agent" {
        try check(args.count == 4, "attach-agent requires a stored session UUID")
        guard let uuid = UUID(uuidString: args[3]) else { throw HostFailure.refused("invalid session UUID") }
        let sessionID = SessionID(uuid)
        try check(try database.sessionRecord(id: sessionID) != nil, "session is not in this store")
        identity = .agentSession(sessionID)
        try link.send(.attach(PTYHostAttach(id: identity, replayBudget: 512 * 1024)))
    } else if args[2] == "attach" {
        let state = try database.load().state
        try check(args.count == 4, "attach requires a stored terminal UUID")
        guard let uuid = UUID(uuidString: args[3]) else { throw HostFailure.refused("invalid terminal UUID") }
        let terminalID = TerminalID(uuid)
        try check(state.projects.contains { $0.terminals.contains { $0.id == terminalID } },
                  "terminal is not in this store")
        identity = PTYHostSessionIdentity(.projectTerminal(terminalID))
        try link.send(.attach(PTYHostAttach(id: identity, replayBudget: 512 * 1024)))
    } else {
        var state = try database.load().state
        let login = args[2] == "login-run"
        try check((args[2] == "run" && args.count >= 5) || (login && args.count >= 6),
                  "run requires DIRECTORY EXECUTABLE; login-run requires DIRECTORY SHELL EXECUTABLE")
        let executableIndex = login ? 5 : 4
        let folder = try projectDirectory(args[3])
        try check(args[4].hasPrefix("/"), "direct executable or login shell must be an absolute path")
        let plan: AgentLaunchPlan
        if login {
            var command = ShellCommand(word: args[executableIndex])
            command.append(words: Array(args.dropFirst(executableIndex + 1)))
            plan = AgentLaunchPlan.inLoginShell(command: command, in: folder.path,
                shellPath: args[4], resumeState: .unavailable)
        } else {
            plan = AgentLaunchPlan(executable: args[4], arguments: Array(args.dropFirst(5)), resumeState: .unavailable)
        }
        let index: Int
        let addedProject: Bool
        if let existing = state.projects.firstIndex(where: { $0.folderPath == folder.path }) {
            index = existing
            addedProject = false
        } else {
            state.projects.append(Project(name: folder.lastPathComponent, folderURL: folder))
            index = state.projects.count - 1
            addedProject = true
        }
        let terminal = ProjectTerminal(id: TerminalID(), title: URL(fileURLWithPath: args[executableIndex]).lastPathComponent,
            customTitle: nil, currentDirectory: folder.path, branch: nil, themeID: nil,
            soundOverrides: nil, createdAt: Date())
        state.projects[index].terminals.append(terminal)
        if addedProject {
            try database.addProject(state.projects[index], position: index)
        } else {
            try database.saveProject(state.projects[index], position: index)
        }
        identity = PTYHostSessionIdentity(.projectTerminal(terminal.id))
        try link.send(.spawn(PTYHostSpawnRequest(id: identity, channel: .pty(grid: localTerminal.grid ?? PTYHostGrid(cols: 80, rows: 24)),
            executable: plan.executable, arguments: plan.arguments,
            environment: launchEnvironment(), cwd: folder.path)))
    }
    var spawned = false
    var inputOpen = true
    var pendingResize = false
    var exitDeadline: Date?
    let spawnDeadline = Date().addingTimeInterval(5)
    while true {
        var polls = [pollfd(fd: inbox.descriptor, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: spawned && inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
                     pollfd(fd: localTerminal.signalFD, events: Int16(POLLIN), revents: 0)]
        let timeout: Int32
        if let exitDeadline {
            let remaining = exitDeadline.timeIntervalSinceNow
            try check(remaining > 0, "daemon did not report child exit after refusing late input")
            timeout = Int32(max(1, (remaining * 1000).rounded(.up)))
        } else if !spawned {
            let remaining = spawnDeadline.timeIntervalSinceNow
            try check(remaining > 0, "spawn deadline expired")
            timeout = Int32(max(1, (remaining * 1000).rounded(.up)))
        } else { timeout = -1 }
        let count = poll(&polls, 3, timeout)
        if count < 0 && errno == EINTR { continue }
        try check(count > 0, "spawn deadline expired or poll failed")
        if polls[2].revents != 0 {
            while let value = localTerminal.nextSignal() {
                if value == SIGWINCH { pendingResize = true }
                else { return 128 + value }
            }
        }
        if polls[0].revents != 0 {
            for event in try inbox.take() {
                let delivery: HostEventInbox.Delivery
                switch event {
                case .delivery(let value): delivery = value
                case .closed(let error):
                    throw HostFailure.refused("daemon connection closed: \(String(describing: error))")
                }
                let control: PTYHostFrame
                switch delivery {
                case .output(let bytes, let standardError):
                    try (standardError ? FileHandle.standardError : FileHandle.standardOutput).write(contentsOf: bytes)
                    continue
                case .control(let value): control = value
                }
                switch control {
                case .spawned(let value):
                    try check(value.id == identity, "spawn identity mismatch")
                    if var pending = pendingResumeRecording {
                        AgentLaunchRecording.apply(pending.plan, to: &pending.session, at: Date())
                        try database.saveSession(pending.session, in: pending.projectID,
                                                 position: pending.position)
                        pendingResumeRecording = nil
                    }
                    spawned = true
                case .attached(let value):
                    try check(value.id == identity, "attach identity mismatch")
                    spawned = true
                    pendingResize = true
                    // A raw terminal bridge cannot reconstruct a screen from a cut history.
                    // Surface the replay status instead of presenting it as an exact screen restore.
                    FileHandle.standardError.write(Data("LinuxHost replay: \(value.replay)\n".utf8))
                case .spawnRefused(let value): throw HostFailure.refused("spawn refused: \(value.reason)")
                case .exited(let value):
                    try check(value.id == identity, "exit identity mismatch")
                    return value.signalled ? 128 + value.status : value.status
                case .error(let value) where value.code == .sessionExited && value.detail == "input":
                    // EOF/input can cross the child's exit on the wire. The refusal is not the
                    // exit status; stop input and wait for the authoritative exited frame.
                    inputOpen = false
                    if exitDeadline == nil { exitDeadline = Date().addingTimeInterval(5) }
                case .error(let value): throw HostFailure.refused("daemon: \(value)")
                default: break
                }
            }
        }
        if spawned && pendingResize {
            if let grid = localTerminal.grid { try link.send(.resize(PTYHostResize(id: identity, grid: grid))) }
            pendingResize = false
        }
        if inputOpen && polls[1].revents != 0 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let n = Glibc.read(STDIN_FILENO, &bytes, bytes.count)
            if n > 0 { try link.sendInput(Data(bytes.prefix(n))) }
            else if n == 0 { inputOpen = false; try link.sendInput(Data([4])) }
            else if errno != EINTR { throw HostFailure.refused("stdin read: \(errno)") }
        }
    }
}

do { exit(try run()) }
catch { FileHandle.standardError.write(Data("LinuxHost: \(error)\n".utf8)); exit(1) }
#else
FileHandle.standardError.write(Data("LinuxHost currently requires Linux\n".utf8))
exit(64)
#endif
