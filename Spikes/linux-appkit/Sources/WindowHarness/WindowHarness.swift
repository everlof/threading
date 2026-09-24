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
    let sessions: Int
    let terminalCount: Int
    let recentAgents: [SavedRuntime]
    let recentTerminals: [SavedRuntime]
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
    private static let maximumOpenTerminals = 8
    private static let maximumSelectableAgentsPerProject = 512
    private static let maximumSelectableTerminalsPerProject = 512
    private static let maximumPersistedRuntimeTitleScalars = 256

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

    @MainActor static func main() async {
        do {
            #if os(Linux)
            if CommandLine.arguments.dropFirst().first == "--attach" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach STORE SOCKET TERMINAL_UUID") }
                try showAttachment(args)
                return
            }
            if CommandLine.arguments.dropFirst().first == "--attach-agent" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count == 3 else { throw WindowFailure("usage: WindowHarness --attach-agent STORE SOCKET SESSION_UUID") }
                try showAttachment(args, agent: true)
                return
            }
            if CommandLine.arguments.dropFirst().first == "--terminal" {
                try showTerminal(Array(CommandLine.arguments.dropFirst(2)))
                return
            }
            if CommandLine.arguments.dropFirst().first == "--app" {
                let args = Array(CommandLine.arguments.dropFirst(2))
                guard args.count >= 3, args[2].hasPrefix("/") else {
                    throw WindowFailure("usage: WindowHarness --app EXISTING_STORE SOCKET ABS_SHELL [ARG ...]")
                }
                let projects = try await Task.detached { try loadSnapshot(args[0]) }.value
                try show(projects, launch: args)
                return
            }
            guard CommandLine.arguments.count == 2 else { throw WindowFailure("usage: WindowHarness EXISTING_STORE") }
            let path = CommandLine.arguments[1]
            // Database open, recovery and graph decoding never run on the UI actor. Only immutable
            // values cross back. The snapshot is deliberately fixed for this window's lifetime.
            let projects = try await Task.detached { try loadSnapshot(path) }.value
            try show(projects)
            #else
            throw WindowFailure("WindowHarness requires Linux")
            #endif
        } catch {
            FileHandle.standardError.write(Data("WindowHarness: \(error)\n".utf8))
            exit(1)
        }
    }

    #if os(Linux)
    static func loadSnapshot(_ path: String) throws -> [ProjectSnapshot] {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let file = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: file.path) else { throw WindowFailure("store does not exist") }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw WindowFailure("store is already owned by another host") }
        let database = try ProjectDatabase(url: file)
        defer { database.close() }
        return try database.load().state.projects.map { project in
            let agents = project.sessions.suffix(maximumSelectableAgentsPerProject).reversed().map {
                ProjectSnapshot.SavedRuntime(id: String(describing: $0.id),
                    title: String(($0.title.isEmpty ? $0.kind.rawValue : $0.title).unicodeScalars
                        .prefix(maximumPersistedRuntimeTitleScalars)))
            }
            let terminals = project.terminals.suffix(maximumSelectableTerminalsPerProject).reversed().map {
                ProjectSnapshot.SavedRuntime(id: String(describing: $0.id),
                    title: String($0.displayTitle.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)))
            }
            return ProjectSnapshot(id: String(describing: project.id), name: project.name,
                path: project.folderPath, sessions: project.sessions.count,
                terminalCount: project.terminals.count, recentAgents: agents, recentTerminals: terminals)
        }
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
        var modifiers: PTYEmulator.Modifiers = []
        if event.modifiers & 1 != 0 { modifiers.insert(.shift) }
        if event.modifiers & 2 != 0 { modifiers.insert(.alt) }
        if event.modifiers & 4 != 0 { modifiers.insert(.ctrl) }
        if event.modifiers & 8 != 0 { modifiers.insert(.super) }
        if event.modifiers & 16 != 0 { modifiers.insert(.capsLock) }
        if event.modifiers & 32 != 0 { modifiers.insert(.numLock) }
        guard let action = PTYEmulator.KeyAction(rawValue: Int(event.action)) else { return }
        session.key(key, modifiers: modifiers, action: action)
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
        session.invalidateFrame()
        var width = initialWidth, height = initialHeight
        var nextFrame: UInt64 = 0
        var failure: String?
        var failureNeedsDisplay = false
        while true {
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
                if event.kind == 6 { session.send(Data(String(cString: tw_event_text(&event)).utf8)) }
                if event.kind == 7 { sendFunctional(event, to: session) }
            }
        }
    }

    @MainActor static func showTerminalFailure(_ message: String, window: OpaquePointer,
                                              width: Int, height: Int) throws {
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

    @MainActor static func show(_ projects: [ProjectSnapshot], launch: [String]? = nil) throws {
        guard let window = tw_open("Threading Linux window experiment", 800, 480) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(window) }
        var terminals: [String: GraphicalTerminal] = [:]
        var restoredRuntimes: [SavedRuntimeKey: GraphicalTerminal] = [:]
        var restoredProjectIDs: Set<String> = []
        var previousTerminalCounts: [String: Int] = [:]
        defer {
            for terminal in terminals.values { terminal.stop() }
            for terminal in restoredRuntimes.values { terminal.stop() }
        }
        var width = 800, height = 480, selected = 0, first = 0
        var savedPicker: SavedPicker?
        var savedSelected = 0, savedFirst = 0
        var dirty = true
        while true {
            let count = max(1, (height / 2 - 32) / 24)
            if let savedPicker {
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
                let end: Int
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    root.title = savedPicker.isAgent
                        ? (width >= 700 ? "Saved agents - Enter: open; Left/Esc: back" : "Saved agents - Enter: open")
                        : (width >= 700 ? "Saved terminals - Enter: open; Left/Esc: back" : "Saved terminals - Enter: open")
                    end = min(saved.count, savedFirst + count)
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        // The specimen face is ASCII. Make unsupported text visibly explicit rather
                        // than silently drawing a blank; real shaping remains a platform requirement.
                        let display = String(runtime.title.prefix(68)).unicodeScalars.map {
                            $0.value >= 32 && $0.value <= 126 ? String($0) : "?"
                        }.joined()
                        let identity = String(runtime.id.prefix(8))
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let text = "\(display) [\(identity)]\(restoredRuntimes[key] == nil ? "" : " *")"
                        root.addSubview(Specimen.Row(frame: NSRect(x: 6,
                            y: root.frame.height - 50 - CGFloat(index - savedFirst) * 24,
                            width: root.frame.width - 12, height: 22),
                            text: text, accent: accent, selected: index == savedSelected))
                    }
                } else {
                    if launch != nil {
                        root.title = width >= 700 ? "Projects - Enter: shell; Left: agents; Right: terminals" : "Projects - Enter: shell"
                    }
                    if !projects.isEmpty, terminals[projects[selected].id]?.canReplace == true {
                        root.title = width >= 700 ? "Enter: view; Ctrl+Shift+N: new; Left/Right: saved" : "Ctrl+Shift+N: new"
                    }
                    end = min(projects.count, first + count)
                    for index in first..<end {
                        let project = projects[index]
                        let display = String(project.name.prefix(80)).unicodeScalars.map {
                            $0.value >= 32 && $0.value <= 126 ? String($0) : "?"
                        }.joined()
                        let opened = terminals[project.id]
                        let terminalCount = project.terminalCount + (previousTerminalCounts[project.id] ?? 0)
                            + ((opened?.hasCreatedTerminal ?? false) ? 1 : 0)
                        let retained = opened != nil || restoredProjectIDs.contains(project.id)
                        let text = "\(display) [\(project.sessions) agents, \(terminalCount) terminals]\(retained ? " *" : "")"
                        root.addSubview(Specimen.Row(frame: NSRect(x: 6,
                            y: root.frame.height - 50 - CGFloat(index - first) * 24,
                            width: root.frame.width - 12, height: 22),
                            text: text, accent: accent, selected: index == selected))
                    }
                }
                let bitmap = Bitmap(width: width, height: height, background: (0.87, 0.87, 0.87, 1))
                let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
                NSGraphicsContext.current = context
                root.render(in: context)
                NSGraphicsContext.current = nil
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    tw_present(window, $0.baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    let total = savedPicker.isAgent ? project.sessions : project.terminalCount
                    tw_title(window, "Threading \(savedPicker.isAgent ? "agents" : "terminals") - \(project.path)")
                    let selectedID = saved.isEmpty ? "none" : saved[savedSelected].id
                    let capped = total > saved.count ? 1 : 0
                    let label = savedPicker.isAgent ? "AGENT_PICKER_FRAME" : "TERMINAL_PICKER_FRAME"
                    print("\(label) \(width)x\(height) mounted=\(end - savedFirst) selected=\(selectedID) total=\(total) capped=\(capped)")
                } else {
                    let title = projects.isEmpty ? "Threading experiment - empty store" : "Threading experiment - \(projects[selected].path)"
                    tw_title(window, title)
                    print("FRAME \(width)x\(height) mounted=\(end - first) selected=\(projects.isEmpty ? "none" : projects[selected].id)")
                }
                fflush(nil)
                dirty = false
            }
            var event = TWEvent()
            guard tw_next(window, &event) == 1 else { throw WindowFailure(String(cString: tw_error())) }
            switch event.kind {
            case 5: return
            case 12:
                if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else { return }
            case 1:
                width = max(320, min(1280, Int(event.width)))
                height = max(180, min(900, Int(event.height)))
                dirty = true
            case 2:
                let y = Int(event.y) / 2
                let listFirst = savedPicker == nil ? first : savedFirst
                let listCount: Int
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    listCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                } else { listCount = projects.count }
                let candidate = listFirst + (y - 28) / 24
                if event.x >= 12 && event.x < width - 12 && y >= 28 && (y - 28) % 24 < 22
                    && candidate < listCount && candidate < listFirst + count {
                    if savedPicker == nil { selected = candidate }
                    else { savedSelected = candidate }
                    dirty = true
                }
            case 8:
                guard let launch, !projects.isEmpty else { break }
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    guard !saved.isEmpty else { break }
                    let runtime = saved[savedSelected]
                    let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                    let session: GraphicalTerminal
                    if let existing = restoredRuntimes[key] { session = existing }
                    else {
                        guard terminals.count + restoredRuntimes.count < maximumOpenTerminals else {
                            tw_title(window, "Threading experiment - limit of \(maximumOpenTerminals) open terminals")
                            break
                        }
                        session = GraphicalTerminal()
                        restoredRuntimes[key] = session
                        restoredProjectIDs.insert(project.id)
                        if savedPicker.isAgent {
                            session.attachAgent(store: launch[0], socket: launch[1], sessionID: runtime.id)
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
                let session: GraphicalTerminal
                if let existing = terminals[project.id] { session = existing }
                else {
                    guard terminals.count + restoredRuntimes.count < maximumOpenTerminals else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenTerminals) open terminals")
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
                guard savedPicker == nil, let launch, !projects.isEmpty else { break }
                let project = projects[selected]
                if let existing = terminals[project.id] {
                    guard existing.canReplace else {
                        tw_title(window, "Threading experiment - terminal may still be running")
                        break
                    }
                    if existing.hasCreatedTerminal { previousTerminalCounts[project.id, default: 0] += 1 }
                    existing.stop()
                    terminals.removeValue(forKey: project.id)
                }
                guard terminals.count + restoredRuntimes.count < maximumOpenTerminals else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenTerminals) open terminals")
                    break
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
            case 3, 4:
                if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                    let next = max(0, min(savedCount - 1, savedSelected + (event.kind == 3 ? -1 : 1)))
                    if next != savedSelected { savedSelected = next; dirty = true }
                } else {
                    let next = max(0, min(projects.count - 1, selected + (event.kind == 3 ? -1 : 1)))
                    if next != selected { selected = next; dirty = true }
                }
            case 10:
                guard savedPicker == nil, launch != nil, !projects.isEmpty else { break }
                guard !projects[selected].recentTerminals.isEmpty else {
                    tw_title(window, "Threading experiment - no saved terminals")
                    break
                }
                savedPicker = .terminals(selected)
                savedSelected = 0
                savedFirst = 0
                dirty = true
            case 11:
                if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else if launch != nil, !projects.isEmpty {
                    guard !projects[selected].recentAgents.isEmpty else {
                        tw_title(window, "Threading experiment - no saved agents")
                        break
                    }
                    savedPicker = .agents(selected)
                    savedSelected = 0
                    savedFirst = 0
                    dirty = true
                }
            default: break
            }
        }
    }
    #endif
}
