import AppKit
import Foundation
import Dispatch
@testable import CoreSlice
@testable import TerminalRuntime
#if os(Linux)
import Glibc
import LinuxWindowBridge
#endif

// Diagnostic platform harness, not a second product sidebar. It reuses the existing specimen
// drawing and the production font while the native window/event transport is brought up.
struct ProjectSnapshot: Sendable {
    struct SavedRuntime: Sendable {
        let id: String
        let title: String
    }
    let id: String
    let name: String
    let path: String
    var sessions: Int
    let terminalCount: Int
    var recentAgents: [SavedRuntime]
    let recentTerminals: [SavedRuntime]
}
struct WindowSnapshot: Sendable {
    let projects: [ProjectSnapshot]
    let selectedProjectIndex: Int
    let restoreAgentID: String?
    let restoreAgentActivity: Date?
    let restoreAgentProjectID: ProjectID?
}
struct WindowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

@MainActor
func render(_ root: NSView, scale: CGFloat = 2, background: NSColor, to path: String) throws {
    let bitmap = Bitmap(width: Int(root.frame.width * scale), height: Int(root.frame.height * scale),
                        background: background.components)
    let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = nil }
    root.render(in: context)
    try PNGWriter.write(bitmap, to: URL(fileURLWithPath: path))
}

@main
struct WindowHarness {
    private static let maximumOpenRuntimes = 8
    private static let maximumSelectableAgentsPerProject = 512
    private static let maximumSelectableTerminalsPerProject = 512
    private static let maximumPersistedRuntimeTitleScalars = 256
    private static let navigatorRowHeight: CGFloat = 22
    private static let navigatorRowStride: CGFloat = 24
    #if os(Linux)
    private static let terminalCellWidth = Int(TW_TERMINAL_CELL_WIDTH)
    private static let terminalCellHeight = Int(TW_TERMINAL_CELL_HEIGHT)
    #endif

    @MainActor private static func navigatorRowRect(_ index: Int, width: Int, height: Int) -> NSRect {
        let top = Specimen.Window.titleHeight + 2 + CGFloat(index) * navigatorRowStride
        // The diagnostic root uses integer half-size bounds, even for an odd SDL pixel size.
        return NSRect(x: 6, y: CGFloat(height / 2) - top - navigatorRowHeight,
                      width: CGFloat(width / 2) - 12, height: navigatorRowHeight)
    }
    @MainActor private static func navigatorRowPixels(_ index: Int, width: Int, height: Int)
        -> (x: Int32, y: Int32, width: Int32, height: Int32) {
        let row = navigatorRowRect(index, width: width, height: height)
        return (Int32(row.minX * 2), Int32((CGFloat(height / 2) - row.maxY) * 2),
                Int32(row.width * 2), Int32(row.height * 2))
    }

    private struct NavigatorTextRow {
        let text: String
        let x: Int32
        let y: Int32
        let width: Int32
        let height: Int32
        let inset: Int32
        let selected: Bool
    }

    private static func readableNavigatorText(_ text: String) -> String {
        text.unicodeScalars.prefix(256).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) ||
                scalar.properties.generalCategory == .format { return "�" }
            return String(scalar)
        }.joined()
    }

    @MainActor private static func addNavigatorRow(
        _ text: String, index: Int, width: Int, height: Int,
        accent: NSColor, selected: Bool, root: Specimen.Window,
        textRows: inout [NavigatorTextRow]
    ) {
        let frame = navigatorRowRect(index, width: width, height: height)
        root.addSubview(Specimen.Row(frame: frame, text: "", accent: accent, selected: selected))
        let pixels = navigatorRowPixels(index, width: width, height: height)
        textRows.append(NavigatorTextRow(text: readableNavigatorText(text), x: pixels.x, y: pixels.y,
                                         width: pixels.width, height: pixels.height,
                                         inset: 52,
                                         selected: selected))
    }

    @MainActor private static func drawNavigatorText(_ rows: [NavigatorTextRow],
                                                     into bitmap: Bitmap) throws {
        var bytes: [UInt8] = []
        var labels: [TWNavigatorLabel] = []
        labels.reserveCapacity(rows.count)
        for row in rows {
            let encoded = Array(row.text.utf8)
            guard encoded.count <= 1024, bytes.count <= 32768 - encoded.count else {
                throw WindowFailure("navigator label exceeds text budget")
            }
            labels.append(TWNavigatorLabel(x: row.x, y: row.y,
                                           width: row.width, height: row.height,
                                           inset: row.inset,
                                           offset: Int32(bytes.count), length: Int32(encoded.count),
                                           selected: row.selected ? 1 : 0))
            bytes.append(contentsOf: encoded)
        }
        let result = bitmap.withMutablePixels { pixels in
            bytes.withUnsafeBufferPointer { content in
                labels.withUnsafeBufferPointer { descriptors in
                    tw_draw_navigator_labels(pixels.baseAddress, Int32(bitmap.width), Int32(bitmap.height),
                                             content.baseAddress, Int32(content.count),
                                             descriptors.baseAddress, Int32(descriptors.count))
                }
            }
        }
        guard result == 0 else { throw WindowFailure("navigator text renderer refused a frame") }
    }

    private enum SavedPicker {
        case agents(Int)
        case terminals(Int)

        var projectIndex: Int {
            switch self { case .agents(let index), .terminals(let index): return index }
        }
        var isAgent: Bool {
            if case .agents = self { return true }
            return false
        }
    }

    private enum SavedRuntimeKey: Hashable {
        case agent(String)
        case terminal(String)
    }

    private struct PendingAgent {
        let projectIndex: Int
        let kind: AgentKind
        let accountHandle: AccountHandle
    }

    private static func savedAgentTitle(_ title: String, accountHandle: AccountHandle) -> String {
        let account = accountHandle.isStandard ? "" :
            " [\(String(accountHandle.name.unicodeScalars.prefix(64)))]"
        let visibleTitle = String(title.unicodeScalars.prefix(
            max(0, maximumPersistedRuntimeTitleScalars - account.unicodeScalars.count)))
        return visibleTitle + account
    }

    private static func savedAgent(_ session: AgentSession) -> ProjectSnapshot.SavedRuntime {
        let title = session.title.isEmpty ? session.kind.rawValue : session.title
        return .init(id: session.id.uuidString,
                     title: savedAgentTitle(title, accountHandle: session.accountHandle))
    }

    @MainActor static func main() async {
        do {
            #if os(Linux)
            let mode = CommandLine.arguments.dropFirst().first
            if mode == "--attach" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach STORE SOCKET TERMINAL_UUID") }
                try showAttachment(args)
                return
            }
            if mode == "--attach-agent" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach-agent STORE SOCKET SESSION_UUID") }
                try showAttachment(args, agent: true)
                return
            }
            if mode == "--terminal" {
                try showTerminal(Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if mode == "--app" || mode == "--app-project" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                let targeted = mode == "--app-project"
                guard (targeted ? args.count == 4 : args.count >= 3), args[2].hasPrefix("/") else {
                    throw WindowFailure("usage: WindowHarness --app EXISTING_STORE SOCKET ABS_SHELL [ARG ...] | --app-project EXISTING_STORE SOCKET ABS_SHELL PROJECT")
                }
                let requestedProject = targeted ? args[3] : nil
                let snapshot = try await Task.detached {
                    try loadSnapshot(args[0], selectingProjectAt: requestedProject, socket: args[1])
                }.value
                try show(snapshot, launch: targeted ? Array(args.prefix(3)) : args)
                return
            }
            if mode == "--app-codex" || mode == "--app-codex-project"
                || mode == "--app-claude" || mode == "--app-claude-project"
                || mode == "--app-agents" || mode == "--app-agents-project" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                let targeted = mode!.hasSuffix("-project")
                let combined = mode!.hasPrefix("--app-agents")
                guard args.count == (combined ? (targeted ? 6 : 5) : (targeted ? 5 : 4)),
                      args[2].hasPrefix("/") else {
                    throw WindowFailure("usage: WindowHarness --app-{codex|claude} STORE SOCKET ABS_SHELL ABS_AGENT [PROJECT] | --app-agents STORE SOCKET ABS_SHELL CODEX_OR_- CLAUDE_OR_- [PROJECT]")
                }
                let codex = combined ? (args[3] == "-" ? nil : args[3])
                    : (mode!.hasPrefix("--app-codex") ? args[3] : nil)
                let claude = combined ? (args[4] == "-" ? nil : args[4])
                    : (mode!.hasPrefix("--app-claude") ? args[3] : nil)
                guard (codex != nil || claude != nil),
                      codex.map({ $0.hasPrefix("/") }) ?? true,
                      claude.map({ $0.hasPrefix("/") }) ?? true else {
                    throw WindowFailure("configured agent executables must be absolute paths")
                }
                let requestedProject = targeted ? args.last : nil
                let prepared = try await Task.detached {
                    (try loadSnapshot(args[0], selectingProjectAt: requestedProject, socket: args[1]),
                     codex == nil ? [.standard] : discoverAccounts(for: .codex),
                     claude == nil ? [.standard] : discoverAccounts(for: .claude))
                }.value
                try show(prepared.0, launch: Array(args.prefix(3)), agentExecutable: codex,
                         claudeExecutable: claude, codexAccounts: prepared.1,
                         claudeAccounts: prepared.2)
                return
            }
            guard CommandLine.arguments.count == 2 else { throw WindowFailure("usage: WindowHarness EXISTING_STORE") }
            let path = CommandLine.arguments[1]
            // Database open, recovery and graph decoding never run on the UI actor. Only immutable
            // values cross back. The snapshot is deliberately fixed for this window's lifetime.
            let snapshot = try await Task.detached { try loadSnapshot(path) }.value
            try show(snapshot)
            #else
            throw WindowFailure("WindowHarness requires Linux")
            #endif
        } catch {
            FileHandle.standardError.write(Data("WindowHarness: \(error)\n".utf8))
            exit(1)
        }
    }

    #if os(Linux)
    /// Inspect the home once on a worker. The picker and input loop only touch this bounded
    /// value, and the shared resolver still validates the selected home at launch time.
    private static func discoverAccounts(for kind: AgentKind) -> [AccountHandle] {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") else {
            return [.standard]
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        guard let directory = Glibc.opendir(home) else { return [.standard] }
        defer { Glibc.closedir(directory) }
        let prefix = kind == .codex ? AgentAccountDefaults.codexDirectoryPrefix
            : AgentAccountDefaults.claudeDirectoryPrefix
        var names: [String] = []
        while let entry = Glibc.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix), name.utf8.count <= 129 else { continue }
            // Unverified directories must not consume the bound and hide a real login.
            let handle = AccountHandle.named(String(name.dropFirst()))
            let admitted = kind == .codex
                ? CodexAccountLocations.resolve(handle, home: homeURL) != nil
                : ClaudeAccountLocations.resolve(handle, home: homeURL) != nil
            guard admitted else { continue }
            // Keep 31 lexical accounts plus standard without building an unbounded home listing.
            names.append(name)
            names.sort()
            if names.count > 31 { names.removeLast() }
        }
        let candidates = names.map { homeURL.appendingPathComponent($0, isDirectory: true) }
        let found = kind == .codex
            ? CodexAccountLocations.discover(home: homeURL, candidates: candidates,
                                             verified: []).map(\.handle)
            : ClaudeAccountLocations.discover(home: homeURL, candidates: candidates,
                                              verified: []).map(\.handle)
        return [.standard] + found.filter { !$0.isStandard }
            .sorted { $0.name < $1.name }
    }

    /// SDL owns its renderer on the thread that opened it. Do not suspend the window loop across
    /// a store write: Swift's Linux main-actor executor can resume it on another native thread.
    /// The worker publishes one result, and the native loop polls only while that write is live.
    private final class SelectionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func finish(_ value: Result<Void, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<Void, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    /// The GTK dialog and store import run away from SDL's owning thread. Only one bounded
    /// snapshot crosses back to the navigator; closing the window closes a pending dialog.
    private final class FolderImportGate: @unchecked Sendable {
        private let lock = NSLock()
        private var chooser: Process?
        private var cancelled = false
        private var result: Result<WindowSnapshot?, Error>?

        func opened(_ process: Process) {
            lock.lock()
            chooser = process
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel && process.isRunning { process.terminate() }
        }
        func closed() {
            lock.lock(); chooser = nil; lock.unlock()
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = chooser
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func isCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func finish(_ value: Result<WindowSnapshot?, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<WindowSnapshot?, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private static func beginFolderImport(store: String, socket: String) -> FolderImportGate {
        let gate = FolderImportGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result { try importFolder(store: store, socket: socket, gate: gate) })
        }
        return gate
    }

    private static func importFolder(store: String, socket: String,
                                     gate: FolderImportGate) throws -> WindowSnapshot? {
        let chooser = Process()
        chooser.executableURL = URL(fileURLWithPath: "/usr/bin/zenity")
        chooser.arguments = ["--file-selection", "--directory", "--title=Add project folder"]
        let output = Pipe()
        // A launcher may be reading commands from stdin (including bash -s smoke runs).
        // Neither child may consume those commands while the window remains open.
        chooser.standardInput = FileHandle.nullDevice
        chooser.standardOutput = output
        chooser.standardError = FileHandle.nullDevice
        try chooser.run()
        gate.opened(chooser)
        var bytes = Data()
        var tooLong = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if bytes.count + chunk.count > 4096 { tooLong = true }
            else if !tooLong { bytes.append(chunk) }
        }
        chooser.waitUntilExit()
        gate.closed()
        if gate.isCancelled() || chooser.terminationStatus == 1 { return nil }
        guard chooser.terminationStatus == 0 else { throw WindowFailure("folder picker failed") }
        guard !tooLong, bytes.last == 10 else { throw WindowFailure("folder picker returned an invalid path") }
        bytes.removeLast()
        guard let path = String(data: bytes, encoding: .utf8),
              let folder = ProjectDirectory.existing(at: path) else {
            throw WindowFailure("selected project directory does not exist")
        }
        guard !gate.isCancelled() else { return nil }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LinuxHost"),
            FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WindowFailure("LinuxHost executable is unavailable")
        }
        let host = Process()
        host.executableURL = executable
        host.arguments = ["--add-project", store, folder.path]
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        host.waitUntilExit()
        guard host.terminationStatus == 0 else { throw WindowFailure("could not import project directory") }
        return try loadSnapshot(store, selectingProjectAt: folder.path, socket: socket)
    }

    private struct PendingSelection {
        let event: TWEvent
        let continuesOnRefusal: Bool
        let gate: SelectionGate
    }

    private static func recordSelection(_ agentID: String?, store: String,
                                        after event: TWEvent,
                                        continuesOnRefusal: Bool = false) -> PendingSelection {
        let gate = SelectionGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result { try GraphicalTerminal.selectRuntime(store: store, agentID: agentID) })
        }
        return PendingSelection(event: event, continuesOnRefusal: continuesOnRefusal, gate: gate)
    }

    static func loadSnapshot(_ path: String, selectingProjectAt requestedPath: String? = nil,
                             socket: String? = nil) throws -> WindowSnapshot {
        let snapshot = try loadStoredSnapshot(path, selectingProjectAt: requestedPath)
        guard let socket, let idText = snapshot.restoreAgentID,
              let uuid = UUID(uuidString: idText) else { return snapshot }
        switch GraphicalTerminal.agentPresence(socket: socket, id: SessionID(uuid)) {
        case .running, .unavailable: return snapshot
        case .absent: break
        case .exited(let status):
            do {
                try GraphicalTerminal.recordAgentExit(store: path, id: SessionID(uuid),
                    status: status, observedNow: false,
                    expectedActivity: snapshot.restoreAgentActivity,
                    expectedProject: snapshot.restoreAgentProjectID)
            } catch {
                FileHandle.standardError.write(Data("Agent exit reconciliation: \(error)\n".utf8))
            }
        }
        // No daemon-held live child means startup must not open an unavailable terminal. A
        // missing summary gives no exit status; explicit selection remains the resume route.
        return WindowSnapshot(projects: snapshot.projects,
            selectedProjectIndex: snapshot.selectedProjectIndex, restoreAgentID: nil,
            restoreAgentActivity: nil, restoreAgentProjectID: nil)
    }

    private static func loadStoredSnapshot(_ path: String,
                                           selectingProjectAt requestedPath: String?) throws -> WindowSnapshot {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned by another host") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        let catalog = try database.navigationSnapshot(
            recentSessionLimit: maximumSelectableAgentsPerProject,
            recentTerminalLimit: maximumSelectableTerminalsPerProject
        )
        // A normal relaunch follows the saved agent to its owning project. Reuse a session in
        // the bounded navigator snapshot; one indexed read covers a selection older than that
        // window. An explicit project argument remains authoritative.
        var selectedAgent: (projectID: ProjectID, session: AgentSession)?
        if let selectedID = catalog.selectedSessionID {
            for project in catalog.projects {
                if let session = project.recentSessions.first(where: { $0.id == selectedID }) {
                    selectedAgent = (project.id, session)
                    break
                }
            }
            if selectedAgent == nil, let record = try database.sessionRecord(id: selectedID) {
                selectedAgent = (record.project.id, record.session)
            }
        }
        let selectedIndex: Int
        if let requestedPath {
            guard let folder = ProjectDirectory.existing(at: requestedPath),
                  let index = catalog.projects.firstIndex(where: { $0.folderPath == folder.path }) else {
                throw WindowFailure("requested project is not in this store")
            }
            selectedIndex = index
        } else {
            selectedIndex = selectedAgent.flatMap { agent in
                catalog.projects.firstIndex(where: { $0.id == agent.projectID })
            } ?? 0
        }
        var projects = catalog.projects.map { project in
            let agents = project.recentSessions.map(savedAgent)
            let terminals = project.recentTerminals.map {
                ProjectSnapshot.SavedRuntime(id: String(describing: $0.id),
                    title: String($0.displayTitle.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)))
            }
            return ProjectSnapshot(id: String(describing: project.id), name: project.name,
                path: project.folderPath, sessions: project.sessionCount,
                terminalCount: project.terminalCount, recentAgents: agents, recentTerminals: terminals)
        }
        // Restore only a selected, launched agent in the chosen project. Attach never starts a
        // process. An older selected agent joins the picker without increasing its row ceiling.
        let restoreAgentID: String?
        let restoreAgentActivity: Date?
        let restoreAgentProjectID: ProjectID?
        if let selectedAgent,
           catalog.projects.indices.contains(selectedIndex),
           selectedAgent.projectID == catalog.projects[selectedIndex].id {
            let selected = selectedAgent.session
            if selected.hasLaunched, !selected.isArchived,
               selected.lastExitCode == nil {
                if !projects[selectedIndex].recentAgents.contains(where: {
                    $0.id == selected.id.uuidString
                }) {
                    projects[selectedIndex].recentAgents.insert(savedAgent(selected), at: 0)
                    if projects[selectedIndex].recentAgents.count > maximumSelectableAgentsPerProject {
                        projects[selectedIndex].recentAgents.removeLast()
                    }
                }
                restoreAgentID = selected.id.uuidString
                restoreAgentActivity = selected.lastActiveAt
                restoreAgentProjectID = catalog.projects[selectedIndex].id
            } else {
                restoreAgentID = nil
                restoreAgentActivity = nil
                restoreAgentProjectID = nil
            }
        } else {
            restoreAgentID = nil
            restoreAgentActivity = nil
            restoreAgentProjectID = nil
        }
        return WindowSnapshot(projects: projects, selectedProjectIndex: selectedIndex,
                              restoreAgentID: restoreAgentID,
                              restoreAgentActivity: restoreAgentActivity,
                              restoreAgentProjectID: restoreAgentProjectID)
    }

    static func modifiers(_ event: TWEvent) -> PTYEmulator.Modifiers {
        var result: PTYEmulator.Modifiers = []
        if event.modifiers & 1 != 0 { result.insert(.shift) }
        if event.modifiers & 2 != 0 { result.insert(.alt) }
        if event.modifiers & 4 != 0 { result.insert(.ctrl) }
        if event.modifiers & 8 != 0 { result.insert(.super) }
        if event.modifiers & 16 != 0 { result.insert(.capsLock) }
        if event.modifiers & 32 != 0 { result.insert(.numLock) }
        return result
    }

    @MainActor static func sendFunctional(_ event: TWEvent, to session: GraphicalTerminal) {
        let key: PTYEmulator.Key
        switch event.key {
        case Int32(TW_KEY_ESCAPE): key = .escape
        case Int32(TW_KEY_ENTER): key = .enter
        case Int32(TW_KEY_TAB): key = .tab
        case Int32(TW_KEY_BACKSPACE): key = .backspace
        case Int32(TW_KEY_DELETE): key = .delete
        case Int32(TW_KEY_UP): key = .up
        case Int32(TW_KEY_DOWN): key = .down
        case Int32(TW_KEY_LEFT): key = .left
        case Int32(TW_KEY_RIGHT): key = .right
        case Int32(TW_KEY_HOME): key = .home
        case Int32(TW_KEY_END): key = .end
        case Int32(TW_KEY_PAGE_UP): key = .pageUp
        case Int32(TW_KEY_PAGE_DOWN): key = .pageDown
        case Int32(TW_KEY_F1): key = .f1
        case Int32(TW_KEY_F2): key = .f2
        case Int32(TW_KEY_F3): key = .f3
        case Int32(TW_KEY_F4): key = .f4
        case Int32(TW_KEY_F5): key = .f5
        case Int32(TW_KEY_F6): key = .f6
        case Int32(TW_KEY_F7): key = .f7
        case Int32(TW_KEY_F8): key = .f8
        case Int32(TW_KEY_F9): key = .f9
        case Int32(TW_KEY_F10): key = .f10
        case Int32(TW_KEY_F11): key = .f11
        case Int32(TW_KEY_F12): key = .f12
        default: return
        }
        guard let action = PTYEmulator.KeyAction(rawValue: Int(event.action)) else { return }
        session.key(key, modifiers: modifiers(event), action: action)
    }

    @MainActor static func pasteClipboard(into session: GraphicalTerminal, window: OpaquePointer) {
        var bytes = [UInt8](repeating: 0, count: GraphicalTerminal.maximumPasteBytes)
        let length = bytes.withUnsafeMutableBufferPointer {
            tw_clipboard_read($0.baseAddress, Int32($0.count))
        }
        guard length >= 0 else {
            let reason = length == -1 ? "clipboard exceeds 64 KiB" : "clipboard is unavailable"
            tw_title(window, "Threading terminal - \(reason)")
            print("CLIPBOARD_REFUSED \(reason)"); fflush(nil)
            return
        }
        guard length > 0 else { return }
        let payload = Data(bytes.prefix(Int(length)))
        guard String(data: payload, encoding: .utf8) != nil else {
            tw_title(window, "Threading terminal - clipboard is not UTF-8")
            print("CLIPBOARD_REFUSED invalid UTF-8"); fflush(nil)
            return
        }
        session.paste(payload)
    }

    @MainActor static func showTerminal(_ args: [String]) throws {
        guard args.count >= 4, args[3].hasPrefix("/") else {
            throw WindowFailure("usage: WindowHarness --terminal STORE SOCKET DIRECTORY ABS_EXECUTABLE [ARG ...]")
        }
        guard let window = tw_open("Threading terminal - starting", 800, 528) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        let session = GraphicalTerminal()
        defer { session.stop() }
        session.start(store: args[0], socket: args[1], directory: args[2], executable: args[3], arguments: Array(args.dropFirst(4)))
        _ = try runTerminal(session, window: window, width: 800, height: 528, allowsProjects: false)
    }

    @MainActor static func showAttachment(_ args: [String], agent: Bool = false) throws {
        guard let window = tw_open("Threading terminal - attaching", 800, 528) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        let session = GraphicalTerminal()
        defer { session.stop() }
        if agent { session.attachAgent(store: args[0], socket: args[1], sessionID: args[2]) }
        else { session.attach(store: args[0], socket: args[1], terminalID: args[2]) }
        _ = try runTerminal(session, window: window, width: 800, height: 528, allowsProjects: false)
    }

    // Reuses the native window and live emulator. Returning to projects does not detach a child.
    @MainActor static func runTerminal(_ session: GraphicalTerminal, window: OpaquePointer,
                                      width initialWidth: Int, height initialHeight: Int,
                                      allowsProjects: Bool) throws -> (Int, Int)? {
        tw_terminal_mode(window)
        tw_project_navigation(window, allowsProjects ? 1 : 0)
        tw_accessibility_show_terminal(window, "Terminal starting")
        tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
        session.setPreedit(nil)
        defer { session.setPreedit(nil) }
        session.invalidateFrame()
        var width = initialWidth, height = initialHeight
        var nextFrame: UInt64 = 0
        var failure: String?
        var failureNeedsDisplay = false
        while true {
            if let copy = session.takeCopyResult() {
                switch copy {
                case .text(let bytes):
                    let wrote = bytes.withUnsafeBytes {
                        tw_clipboard_write($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
                    }
                    if wrote == 0 { print("CLIPBOARD_COPIED \(bytes.count)") }
                    else { print("CLIPBOARD_REFUSED native write failed") }
                case .empty: print("CLIPBOARD_REFUSED no selection")
                case .oversized: print("CLIPBOARD_REFUSED selection exceeds 1 MiB")
                }
                fflush(nil)
            }
            if let size = session.takeInitialViewport() {
                width = size.0; height = size.1
                guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
            }
            var prepared: GraphicalTerminal.Frame?
            if failure == nil {
                do { prepared = try session.takeFrame() }
                catch {
                    guard allowsProjects else { throw error }
                    failure = String(describing: error)
                    failureNeedsDisplay = true
                    session.stop()
                }
            }
            if let failure, failureNeedsDisplay {
                try showTerminalFailure(failure, window: window, width: width, height: height)
                failureNeedsDisplay = false
            }
            if let frame = prepared, frame.width == width && frame.height == height {
                let presentStarted = DispatchTime.now().uptimeNanoseconds
                let result = frame.pixels.withUnsafeBytes {
                    tw_present(window, $0.bindMemory(to: UInt8.self).baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                frame.title.withCString { tw_accessibility_show_terminal(window, $0) }
                let accessibleRuns = frame.accessibleRuns.map {
                    TWTextRun(offset: $0.offset, characters: $0.characters,
                              column: $0.column, row: $0.row, cells: $0.cells)
                }
                frame.accessibleText.withCString { text in
                    accessibleRuns.withUnsafeBufferPointer { runs in
                        tw_accessibility_terminal_text(window, text, Int32(frame.accessibleText.utf8.count),
                                                       Int32(frame.accessibleCaret), runs.baseAddress,
                                                       Int32(runs.count))
                    }
                }
                let caretX = frame.cursorColumn >= 0 ? frame.cursorColumn * terminalCellWidth : 8
                let caretY = frame.cursorColumn >= 0 ? frame.cursorRow * terminalCellHeight : height - terminalCellHeight
                tw_text_input_rect(window, Int32(max(0, min(width - terminalCellWidth, caretX))),
                                   Int32(max(0, min(height - terminalCellHeight, caretY))),
                                   Int32(terminalCellWidth), Int32(terminalCellHeight))
                tw_title(window, frame.title)
                print("TERMINAL_FRAME \(width)x\(height) \(frame.title) drawMs=\(frame.drawMilliseconds) presentMs=\(Double(DispatchTime.now().uptimeNanoseconds - presentStarted) / 1_000_000)"); fflush(nil)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if failure == nil && now >= nextFrame {
                session.requestFrame(width: width, height: height)
                nextFrame = now + 33_000_000
            }
            var event = TWEvent()
            if tw_next_timeout(window, &event, failure == nil ? 33 : -1) == 1 {
                if event.kind == 5 { return nil }
                if event.kind == 8 && allowsProjects { return (width, height) }
                if event.kind == 1 {
                    _ = tw_repaint(window)
                    width = max(320, min(1280, Int(event.width)))
                    height = max(180, min(900, Int(event.height)))
                    failureNeedsDisplay = failure != nil
                }
                guard failure == nil else { continue }
                if event.kind == 19 {
                    let value = String(validatingCString: tw_event_text(&event)) ?? "[invalid composition]"
                    session.setPreedit(value, cursor: Int(event.textCursor),
                                       selectionLength: Int(event.textSelectionLength))
                    print("IME_PREEDIT bytes=\(value.utf8.count)"); fflush(nil)
                }
                if event.kind == 6 {
                    session.setPreedit(nil)
                    if let value = String(validatingCString: tw_event_text(&event)) {
                        session.send(Data(value.utf8))
                        if event.action == 1 {
                            print("IME_COMMIT bytes=\(value.utf8.count)"); fflush(nil)
                        }
                    } else {
                        print("IME_REFUSED invalid UTF-8 commit"); fflush(nil)
                    }
                }
                if event.kind == 7 { sendFunctional(event, to: session) }
                if event.kind == 14 { pasteClipboard(into: session, window: window) }
                if event.kind == 15 {
                    session.mouseButton(x: Int(event.x), y: Int(event.y), button: Int(event.key),
                        release: event.action == 3, modifiers: modifiers(event))
                }
                if event.kind == 16 {
                    session.mouseWheel(x: Int(event.x), y: Int(event.y), steps: Int(event.key),
                        modifiers: modifiers(event))
                }
                if event.kind == 17 { session.mouseMotion(x: Int(event.x), y: Int(event.y)) }
                if event.kind == 18 { session.requestCopySelection() }
            }
        }
    }

    @MainActor static func showTerminalFailure(_ message: String, window: OpaquePointer,
                                              width: Int, height: Int) throws {
        let accessible = "Terminal unavailable: \(boundedAccessibilityLabel(message))"
        accessible.withCString { tw_accessibility_show_terminal(window, $0) }
        tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: width / 2, height: height / 2))
        root.title = "Terminal unavailable"
        root.addSubview(Specimen.Message(frame: NSRect(x: 12, y: 8,
            width: root.frame.width - 24, height: root.frame.height - 42),
            text: "Ctrl+Shift+P: projects\n\n" + message))
        let bitmap = Bitmap(width: width, height: height, background: (0.87, 0.87, 0.87, 1))
        let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
        NSGraphicsContext.current = context
        root.render(in: context)
        NSGraphicsContext.current = nil
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present(window, $0.baseAddress, Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        tw_title(window, "Threading terminal - unavailable")
        print("FAILURE_FRAME \(width)x\(height)"); fflush(nil)
    }

    @MainActor private static func reconcilePendingAgents(
        projects: inout [ProjectSnapshot],
        runtimes: inout [SavedRuntimeKey: GraphicalTerminal],
        pending: inout [String: PendingAgent],
        retainedProjects: inout Set<String>
    ) -> Bool {
        var changed = false
        for (id, launch) in Array(pending) {
            let key = SavedRuntimeKey.agent(id)
            guard let runtime = runtimes[key] else { pending.removeValue(forKey: id); continue }
            if runtime.hasCreatedAgent {
                projects[launch.projectIndex].sessions += 1
                projects[launch.projectIndex].recentAgents.insert(
                    .init(id: id, title: savedAgentTitle(launch.kind.rawValue,
                                                       accountHandle: launch.accountHandle)),
                    at: 0)
                if projects[launch.projectIndex].recentAgents.count > maximumSelectableAgentsPerProject {
                    projects[launch.projectIndex].recentAgents.removeLast()
                }
                retainedProjects.insert(projects[launch.projectIndex].id)
                pending.removeValue(forKey: id)
                changed = true
            } else if runtime.canReplace {
                runtime.stop()
                runtimes.removeValue(forKey: key)
                pending.removeValue(forKey: id)
                changed = true
            }
        }
        return changed
    }

    @MainActor static func show(_ snapshot: WindowSnapshot, launch: [String]? = nil,
                                agentExecutable: String? = nil,
                                claudeExecutable: String? = nil,
                                codexAccounts: [AccountHandle] = [],
                                claudeAccounts: [AccountHandle] = []) throws {
        var codexAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CODEX_ACCOUNT"])
        var claudeAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CLAUDE_ACCOUNT"])
        var projects = snapshot.projects
        guard let window = tw_open("Threading Linux window experiment", 800, 480) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        var terminals: [String: GraphicalTerminal] = [:]
        var restoredRuntimes: [SavedRuntimeKey: GraphicalTerminal] = [:]
        var pendingAgentProjects: [String: PendingAgent] = [:]
        var restoredProjectIDs: Set<String> = []
        var previousTerminalCounts: [String: Int] = [:]
        defer {
            for terminal in terminals.values { terminal.stop() }
            for terminal in restoredRuntimes.values { terminal.stop() }
        }
        var width = 800, height = 480, selected = snapshot.selectedProjectIndex, first = 0
        var savedPicker: SavedPicker?
        var savedSelected = 0, savedFirst = 0
        var accountPicker: AgentKind?
        var accountSelected = 0, accountFirst = 0
        var pendingSelection: PendingSelection?
        var pendingFolderImport: FolderImportGate?
        defer { pendingFolderImport?.cancel() }
        var dirty = true
        if let id = snapshot.restoreAgentID, let launch,
           let row = projects[selected].recentAgents.firstIndex(where: { $0.id == id }) {
            let session = GraphicalTerminal()
            restoredRuntimes[.agent(id)] = session
            restoredProjectIDs.insert(projects[selected].id)
            savedPicker = .agents(selected)
            savedSelected = row
            session.attachAgent(store: launch[0], socket: launch[1], sessionID: id)
            guard let size = try runTerminal(session, window: window, width: width, height: height,
                                             allowsProjects: true) else { return }
            width = size.0; height = size.1
            tw_project_mode(window)
        }
        while true {
            if let gate = pendingFolderImport, let result = gate.take() {
                pendingFolderImport = nil
                switch result {
                case .success(let imported?):
                    projects = imported.projects
                    selected = imported.selectedProjectIndex
                    first = 0
                    dirty = true
                    print("PROJECT_IMPORTED \(projects[selected].path)"); fflush(nil)
                case .success(nil):
                    print("PROJECT_IMPORT_CANCELLED"); fflush(nil)
                case .failure(let error):
                    print("PROJECT_IMPORT_REFUSED \(error)"); fflush(nil)
                    tw_title(window, "Threading experiment - project import failed")
                }
            }
            let pickerAccounts = accountPicker == .claude ? claudeAccounts : codexAccounts
            if reconcilePendingAgents(projects: &projects, runtimes: &restoredRuntimes,
                                      pending: &pendingAgentProjects,
                                      retainedProjects: &restoredProjectIDs) { dirty = true }
            let count = max(1, (height / 2 - 32) / Int(navigatorRowStride))
            if accountPicker != nil {
                accountSelected = max(0, min(pickerAccounts.count - 1, accountSelected))
                if accountSelected < accountFirst { accountFirst = accountSelected }
                if accountSelected >= accountFirst + count { accountFirst = accountSelected - count + 1 }
            } else if let savedPicker {
                let project = projects[savedPicker.projectIndex]
                let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                savedSelected = max(0, min(savedCount - 1, savedSelected))
                if savedSelected < savedFirst { savedFirst = savedSelected }
                if savedSelected >= savedFirst + count { savedFirst = savedSelected - count + 1 }
            } else {
                selected = max(0, min(projects.count - 1, selected))
                if selected < first { first = selected }
                if selected >= first + count { first = selected - count + 1 }
            }
            if dirty {
                // At most viewport/count row objects, even for a large persisted catalogue.
                let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: width / 2, height: height / 2))
                let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
                var textRows: [NavigatorTextRow] = []
                textRows.reserveCapacity(min(count, 32))
                let end: Int
                if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    root.title = "\(provider) login - Enter: choose; Esc: back"
                    end = min(pickerAccounts.count, accountFirst + count)
                    for index in accountFirst..<end {
                        let handle = pickerAccounts[index]
                        let name = handle.isStandard ? "Default \(provider)" :
                            "\(provider) [\(String(handle.name.prefix(48)))]"
                        let text = name + (handle == active ? " *" : "")
                        addNavigatorRow(text, index: index - accountFirst, width: width,
                                        height: height, accent: accent,
                                        selected: index == accountSelected,
                                        root: root, textRows: &textRows)
                    }
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    root.title = savedPicker.isAgent
                        ? (width >= 700 ? "Saved agents - Enter: open; Left/Esc: back" : "Saved agents - Enter: open")
                        : (width >= 700 ? "Saved terminals - Enter: open; Left/Esc: back" : "Saved terminals - Enter: open")
                    end = min(saved.count, savedFirst + count)
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let display = String(runtime.title.unicodeScalars.prefix(68))
                        let identity = String(runtime.id.prefix(8))
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let text = "\(display) [\(identity)]\(restoredRuntimes[key] == nil ? "" : " *")"
                        addNavigatorRow(text, index: index - savedFirst, width: width,
                                        height: height, accent: accent,
                                        selected: index == savedSelected,
                                        root: root, textRows: &textRows)
                    }
                } else {
                    let codexName = codexAccount.isStandard ? "Codex" :
                        "Codex \(String(codexAccount.name.prefix(12)))"
                    let claudeName = claudeAccount.isStandard ? "Claude" :
                        "Claude \(String(claudeAccount.name.prefix(12)))"
                    var agentActions: [String] = []
                    if agentExecutable != nil {
                        agentActions.append("C-S-A/I: \(codexName)/login")
                    }
                    if claudeExecutable != nil {
                        agentActions.append("C-S-L/O: \(claudeName)/login")
                    }
                    if launch != nil {
                        root.title = width >= 700 ? "Projects - Enter: shell; Left: agents; Right: terminals" : "Projects - Enter: shell"
                    }
                    if !agentActions.isEmpty {
                        root.title = width >= 700
                            ? "Enter: shell; " + agentActions.joined(separator: "; ")
                            : agentActions.joined(separator: "; ")
                    }
                    if !projects.isEmpty, terminals[projects[selected].id]?.canReplace == true {
                        root.title = agentActions.isEmpty
                            ? (width >= 700 ? "Enter: view; Ctrl+Shift+N: new; Left/Right: saved" : "Ctrl+Shift+N: new")
                            : (width >= 700 ? "Enter: view; " + agentActions.joined(separator: "; ")
                                            : agentActions.joined(separator: "; "))
                    }
                    if projects.isEmpty, launch != nil {
                        root.title = "Projects - Ctrl+Shift+P: add folder"
                        end = 1
                        addNavigatorRow("Add project folder…", index: 0, width: width,
                                        height: height, accent: accent, selected: true,
                                        root: root, textRows: &textRows)
                    } else {
                        end = min(projects.count, first + count)
                        for index in first..<end {
                            let project = projects[index]
                            let display = String(project.name.unicodeScalars.prefix(80))
                            let opened = terminals[project.id]
                            let terminalCount = project.terminalCount + (previousTerminalCounts[project.id] ?? 0)
                                + ((opened?.hasCreatedTerminal ?? false) ? 1 : 0)
                            let retained = opened != nil || restoredProjectIDs.contains(project.id)
                            let text = "\(display) [\(project.sessions) agents, \(terminalCount) terminals]\(retained ? " *" : "")"
                            addNavigatorRow(text, index: index - first, width: width,
                                            height: height, accent: accent,
                                            selected: index == selected,
                                            root: root, textRows: &textRows)
                        }
                    }
                }
                let title = root.title
                root.title = ""
                textRows.append(NavigatorTextRow(text: readableNavigatorText(title), x: 0, y: 0,
                                                 width: Int32(width),
                                                 height: Int32(Specimen.Window.titleHeight * 2),
                                                 inset: 24, selected: false))
                let bitmap = Bitmap(width: width, height: height, background: (0.87, 0.87, 0.87, 1))
                let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
                NSGraphicsContext.current = context
                root.render(in: context)
                NSGraphicsContext.current = nil
                let textStarted = DispatchTime.now().uptimeNanoseconds
                try drawNavigatorText(textRows, into: bitmap)
                let textMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - textStarted) / 1_000_000
                print("NAVIGATOR_TEXT mounted=\(textRows.count) drawMs=\(textMilliseconds)")
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    tw_present(window, $0.baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    let listY = Int32(Specimen.Window.titleHeight * 2)
                    tw_accessibility_begin_list(window, "\(provider) accounts", Int32(accountFirst),
                                                Int32(pickerAccounts.count), 1, 0, listY,
                                                Int32(width), Int32(height) - listY)
                    for index in accountFirst..<end {
                        let handle = pickerAccounts[index]
                        let name = handle.isStandard ? "Default \(provider)" : "\(provider) \(handle.name)"
                        let label = name + (handle == active ? " active" : "")
                        try publishAccessibleRow(window, id: handle.name, label: label,
                                                 selected: index == accountSelected,
                                                 visibleIndex: index - accountFirst,
                                                 width: width, height: height)
                    }
                    tw_accessibility_end_list(window)
                    tw_title(window, "Threading \(provider) accounts - \(projects[selected].path)")
                    print("ACCOUNT_PICKER_FRAME \(width)x\(height) provider=\(provider.lowercased()) mounted=\(end - accountFirst) selected=\(pickerAccounts[accountSelected].name) total=\(pickerAccounts.count)")
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    let total = savedPicker.isAgent ? project.sessions : project.terminalCount
                    let listName = "Saved \(savedPicker.isAgent ? "agents" : "terminals") (\(saved.count) of \(total))"
                    let listY = Int32(Specimen.Window.titleHeight * 2)
                    listName.withCString {
                        tw_accessibility_begin_list(window, $0, Int32(savedFirst), Int32(saved.count),
                                                    launch == nil ? 0 : 1, 0, listY,
                                                    Int32(width), Int32(height) - listY)
                    }
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let label = "\(boundedAccessibilityLabel(runtime.title)) [\(String(runtime.id.prefix(8)))]\(restoredRuntimes[key] == nil ? "" : " retained")"
                        try publishAccessibleRow(window, id: runtime.id, label: label,
                                                 selected: index == savedSelected,
                                                 visibleIndex: index - savedFirst, width: width, height: height)
                    }
                    tw_accessibility_end_list(window)
                    tw_title(window, "Threading \(savedPicker.isAgent ? "agents" : "terminals") - \(project.path)")
                    let selectedID = saved.isEmpty ? "none" : saved[savedSelected].id
                    let capped = total > saved.count ? 1 : 0
                    let label = savedPicker.isAgent ? "AGENT_PICKER_FRAME" : "TERMINAL_PICKER_FRAME"
                    print("\(label) \(width)x\(height) mounted=\(end - savedFirst) selected=\(selectedID) total=\(total) capped=\(capped)")
                } else {
                    let listY = Int32(Specimen.Window.titleHeight * 2)
                    let hasAddRow = projects.isEmpty && launch != nil
                    tw_accessibility_begin_list(window, "Projects", Int32(first),
                                                Int32(hasAddRow ? 1 : projects.count),
                                                launch == nil ? 0 : 1, 0, listY,
                                                Int32(width), Int32(height) - listY)
                    if hasAddRow {
                        try publishAccessibleRow(window, id: "add-project", label: "Add project folder",
                                                 selected: true, visibleIndex: 0,
                                                 width: width, height: height)
                    } else {
                        for index in first..<end {
                            let project = projects[index]
                            let opened = terminals[project.id]
                            let terminalCount = project.terminalCount + (previousTerminalCounts[project.id] ?? 0)
                                + ((opened?.hasCreatedTerminal ?? false) ? 1 : 0)
                            let retained = opened != nil || restoredProjectIDs.contains(project.id)
                            let label = "\(boundedAccessibilityLabel(project.name)) [\(project.sessions) agents, \(terminalCount) terminals]\(retained ? " retained" : "")"
                            try publishAccessibleRow(window, id: project.id, label: label,
                                                     selected: index == selected,
                                                     visibleIndex: index - first, width: width, height: height)
                        }
                    }
                    tw_accessibility_end_list(window)
                    let title = projects.isEmpty ? "Threading experiment - empty store" : "Threading experiment - \(projects[selected].path)"
                    tw_title(window, title)
                    print("FRAME \(width)x\(height) mounted=\(end - first) selected=\(projects.isEmpty ? "none" : projects[selected].id)")
                }
                fflush(nil)
                dirty = false
            }
            var event = TWEvent()
            var selectionWasCommitted = false
            if let pending = pendingSelection {
                if let result = pending.gate.take() {
                    pendingSelection = nil
                    switch result {
                    case .success:
                        event = pending.event
                        selectionWasCommitted = true
                    case .failure(let error):
                        print("SELECTION_REFUSED \(error)"); fflush(nil)
                        if !pending.continuesOnRefusal {
                            tw_title(window, "Threading experiment - could not save runtime selection")
                            continue
                        }
                        // A new shell still owns its launch result. It can report the store
                        // refusal on the existing unavailable surface instead of hiding it
                        // at the project picker. Reusing a runtime requires a durable clear.
                        event = pending.event
                        selectionWasCommitted = true
                    }
                } else {
                    if tw_next_timeout(window, &event, 33) == 1 {
                        if event.kind == 5 { return }
                        if event.kind == 1 {
                            width = max(320, min(1280, Int(event.width)))
                            height = max(180, min(900, Int(event.height)))
                            dirty = true
                        }
                    }
                    continue
                }
            } else if pendingFolderImport != nil {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { return }
                    if event.kind == 1 {
                        width = max(320, min(1280, Int(event.width)))
                        height = max(180, min(900, Int(event.height)))
                        dirty = true
                    }
                }
                continue
            } else {
                guard tw_next(window, &event) == 1 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
            }
            switch event.kind {
            case 5: return
            case 12:
                if accountPicker != nil {
                    accountPicker = nil
                    dirty = true
                } else if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else { return }
            case 1:
                width = max(320, min(1280, Int(event.width)))
                height = max(180, min(900, Int(event.height)))
                dirty = true
            case 2:
                let listFirst = accountPicker != nil ? accountFirst : (savedPicker == nil ? first : savedFirst)
                let listCount: Int
                if accountPicker != nil {
                    listCount = pickerAccounts.count
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    listCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                } else { listCount = projects.isEmpty && launch != nil ? 1 : projects.count }
                let visibleCount = max(0, min(listCount - listFirst, count))
                if let mounted = (0..<visibleCount).first(where: { index in
                    let row = navigatorRowPixels(index, width: width, height: height)
                    return event.x >= row.x && event.x < row.x + row.width
                        && event.y >= row.y && event.y < row.y + row.height
                }) {
                    if projects.isEmpty, let launch, accountPicker == nil, savedPicker == nil {
                        if event.action != 1 {
                            pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                        }
                        break
                    }
                    let candidate = listFirst + mounted
                    if accountPicker != nil { accountSelected = candidate }
                    else if savedPicker == nil { selected = candidate }
                    else { savedSelected = candidate }
                    dirty = true
                }
            case 8:
                guard let launch else { break }
                if projects.isEmpty {
                    pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                    break
                }
                if let pickerKind = accountPicker {
                    if pickerKind == .claude {
                        claudeAccount = pickerAccounts[accountSelected]
                    } else {
                        codexAccount = pickerAccounts[accountSelected]
                    }
                    accountPicker = nil
                    dirty = true
                    break
                }
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    guard !saved.isEmpty else { break }
                    let runtime = saved[savedSelected]
                    let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                    let session: GraphicalTerminal
                    let mayResume = savedPicker.isAgent && (agentExecutable != nil || claudeExecutable != nil)
                    let existing = restoredRuntimes[key]
                    let reuses = existing.map { !(mayResume && $0.canReplace) } ?? false
                    guard reuses || existing != nil
                            || terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    if !selectionWasCommitted {
                        pendingSelection = recordSelection(savedPicker.isAgent ? runtime.id : nil,
                                                           store: launch[0], after: event)
                        break
                    }
                    if reuses, let existing { session = existing }
                    else {
                        if let existing = restoredRuntimes.removeValue(forKey: key) { existing.stop() }
                        session = GraphicalTerminal()
                        restoredRuntimes[key] = session
                        restoredProjectIDs.insert(project.id)
                        if savedPicker.isAgent {
                            if mayResume {
                                session.openAgent(store: launch[0], socket: launch[1], sessionID: runtime.id,
                                    shell: launch[2], codex: agentExecutable, claude: claudeExecutable,
                                    width: width, height: height)
                            } else {
                                session.attachAgent(store: launch[0], socket: launch[1], sessionID: runtime.id)
                            }
                        } else {
                            session.attach(store: launch[0], socket: launch[1], terminalID: runtime.id)
                        }
                    }
                    guard let size = try runTerminal(session, window: window, width: width, height: height,
                                                     allowsProjects: true) else { return }
                    width = size.0; height = size.1
                    tw_project_mode(window)
                    dirty = true
                    break
                }
                let project = projects[selected]
                guard terminals[project.id] != nil
                        || terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                if !selectionWasCommitted {
                    pendingSelection = recordSelection(nil, store: launch[0], after: event,
                                                       continuesOnRefusal: terminals[project.id] == nil)
                    break
                }
                let session: GraphicalTerminal
                if let existing = terminals[project.id] { session = existing }
                else {
                    guard terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    session = GraphicalTerminal()
                    terminals[project.id] = session
                    session.start(store: launch[0], socket: launch[1], directory: project.path,
                                  executable: launch[2], arguments: Array(launch.dropFirst(3)))
                }
                guard let size = try runTerminal(session, window: window, width: width, height: height,
                                                 allowsProjects: true) else { return }
                width = size.0; height = size.1
                tw_project_mode(window)
                dirty = true
            case 9:
                guard accountPicker == nil, savedPicker == nil, let launch, !projects.isEmpty else { break }
                let project = projects[selected]
                if let existing = terminals[project.id], !existing.canReplace {
                    tw_title(window, "Threading experiment - terminal may still be running")
                    break
                }
                guard terminals.count + restoredRuntimes.count
                        - (terminals[project.id] == nil ? 0 : 1) < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                if !selectionWasCommitted {
                    pendingSelection = recordSelection(nil, store: launch[0], after: event,
                                                       continuesOnRefusal: true)
                    break
                }
                if let existing = terminals[project.id] {
                    if existing.hasCreatedTerminal { previousTerminalCounts[project.id, default: 0] += 1 }
                    existing.stop()
                    terminals.removeValue(forKey: project.id)
                }
                let session = GraphicalTerminal()
                terminals[project.id] = session
                session.start(store: launch[0], socket: launch[1], directory: project.path,
                              executable: launch[2], arguments: Array(launch.dropFirst(3)))
                guard let size = try runTerminal(session, window: window, width: width, height: height,
                                                 allowsProjects: true) else { return }
                width = size.0; height = size.1
                tw_project_mode(window)
                dirty = true
            case 23:
                guard accountPicker == nil, savedPicker == nil, let launch else { break }
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
            case 13, 21:
                guard accountPicker == nil, savedPicker == nil, let launch, !projects.isEmpty else { break }
                let kind: AgentKind = event.kind == 13 ? .codex : .claude
                guard let executable = event.kind == 13 ? agentExecutable : claudeExecutable else { break }
                let accountHandle: AccountHandle = event.kind == 13 ? codexAccount : claudeAccount
                guard terminals.count + restoredRuntimes.count < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                let id = SessionID()
                let savedID = String(describing: id)
                let session = GraphicalTerminal()
                restoredRuntimes[.agent(savedID)] = session
                pendingAgentProjects[savedID] = PendingAgent(projectIndex: selected,
                                                             kind: kind, accountHandle: accountHandle)
                session.startAgent(store: launch[0], socket: launch[1], directory: projects[selected].path,
                                   shell: launch[2], kind: kind, executable: executable,
                                   accountHandle: accountHandle, id: id,
                                   width: width, height: height)
                guard let size = try runTerminal(session, window: window, width: width, height: height,
                                                 allowsProjects: true) else { return }
                width = size.0; height = size.1
                tw_project_mode(window)
                dirty = true
            case 3, 4:
                if accountPicker != nil {
                    let next = max(0, min(pickerAccounts.count - 1,
                                          accountSelected + (event.kind == 3 ? -1 : 1)))
                    if next != accountSelected { accountSelected = next; dirty = true }
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                    let next = max(0, min(savedCount - 1, savedSelected + (event.kind == 3 ? -1 : 1)))
                    if next != savedSelected { savedSelected = next; dirty = true }
                } else {
                    let next = max(0, min(projects.count - 1, selected + (event.kind == 3 ? -1 : 1)))
                    if next != selected { selected = next; dirty = true }
                }
            case 10:
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      !projects.isEmpty else { break }
                guard !projects[selected].recentTerminals.isEmpty else {
                    tw_title(window, "Threading experiment - no saved terminals")
                    break
                }
                savedPicker = .terminals(selected)
                savedSelected = 0
                savedFirst = 0
                dirty = true
            case 11:
                if accountPicker != nil {
                    accountPicker = nil
                    dirty = true
                } else if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else if launch != nil, !projects.isEmpty {
                    if reconcilePendingAgents(projects: &projects, runtimes: &restoredRuntimes,
                                              pending: &pendingAgentProjects,
                                              retainedProjects: &restoredProjectIDs) { dirty = true }
                    guard !projects[selected].recentAgents.isEmpty else {
                        let pending = pendingAgentProjects.values.contains {
                            $0.projectIndex == selected
                        }
                        tw_title(window, pending ? "Threading experiment - agent starting"
                                                 : "Threading experiment - no saved agents")
                        break
                    }
                    savedPicker = .agents(selected)
                    savedSelected = 0
                    savedFirst = 0
                    dirty = true
                }
            case 20, 22:
                let kind: AgentKind = event.kind == 20 ? .codex : .claude
                let available = kind == .codex ? codexAccounts : claudeAccounts
                let active = kind == .codex ? codexAccount : claudeAccount
                let executable = kind == .codex ? agentExecutable : claudeExecutable
                guard accountPicker == nil, savedPicker == nil, executable != nil,
                      !projects.isEmpty, !available.isEmpty else { break }
                accountPicker = kind
                accountSelected = available.firstIndex(of: active) ?? 0
                accountFirst = 0
                dirty = true
            default: break
            }
        }
    }

    // The accessibility bridge receives the same viewport rows as the renderer. Stop at a byte
    // boundary so a long grapheme or externally supplied title cannot expand its C projection.
    private static func boundedAccessibilityLabel(_ value: String) -> String {
        var result = "", bytes = 0
        for scalar in value.unicodeScalars {
            let part = String(scalar)
            let length = part.utf8.count
            if bytes + length > 400 { break }
            result.append(part)
            bytes += length
        }
        return result
    }

    @MainActor private static func publishAccessibleRow(_ window: OpaquePointer, id: String,
                                                         label: String, selected: Bool,
                                                         visibleIndex: Int, width: Int, height: Int) throws {
        let bounds = navigatorRowPixels(visibleIndex, width: width, height: height)
        let result = id.withCString { identifier in
            label.withCString { name in
                tw_accessibility_add_row(window, identifier, name, selected ? 1 : 0,
                                         bounds.x, bounds.y, bounds.width, bounds.height)
            }
        }
        guard result == 0 else { throw WindowFailure("native accessibility row exceeds its bound") }
    }
    #endif
}
