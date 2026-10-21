import AppKit
import Foundation
import Dispatch
@testable import CoreSlice
@testable import TerminalRuntime
#if os(Linux)
import Glibc
import LinuxWindowBridge
#endif

/// SDL's opaque window is owned by the one UI event loop. This wrapper only lets its
/// main-actor drawing helper capture the handle; it never moves SDL calls to a worker.
private struct SidebarActivityWindow: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Provider callbacks carry only a bounded event into the owning UI loop. The loop checks the
/// current row and durable snooze before spending the event, so callbacks never capture its
/// mutable navigator model across an actor boundary.
@MainActor
private final class SnoozeWakeInbox {
    struct Event {
        let id: String
        let projectID: String
        let reason: SessionWakeReason
        let at: Date
    }

    private var events: [String: Event] = [:]

    func record(_ reason: SessionWakeReason, id: String, projectID: String) {
        guard events[id] == nil, events.count < 8 else { return }
        events[id] = Event(id: id, projectID: projectID, reason: reason, at: Date())
    }

    func take() -> Event? {
        guard let event = events.first else { return nil }
        events[event.key] = nil
        return event.value
    }
}

// Diagnostic platform harness, not a second product sidebar. It reuses the existing specimen
// drawing and the production font while the native window/event transport is brought up.
struct ProjectSnapshot: Sendable {
    struct SavedRuntime: Sendable {
        let id: String
        var title: String
        var customTitle: String? = nil
        var kind: AgentKind? = nil
        var account: String? = nil
        var usesNativeUI = false
        var isPinned = false
        var agentSessionID: String? = nil
        var attention: AgentSessionRowPresentation.Attention? = nil

        var snoozedUntil: Date? = nil

        func attention(at date: Date) -> AgentSessionRowPresentation.Attention? {
            AgentSessionRowPresentation.Attention.resolve(
                isScheduled: attention == .scheduled, hasWoken: attention == .woke,
                isSnoozed: snoozedUntil.map { date < $0 } ?? false)
        }

        func attentionTitle(at date: Date) -> String? {
            switch attention(at: date) {
            case .scheduled: return "Scheduled"
            case .woke: return "Woke"
            case .snoozed: return "Snoozed"
            case nil: return nil
            }
        }

        var identityTitle: String {
            let provider = kind.map { "[\($0.displayName)] " } ?? ""
            let suffix = account.map { " [\($0)]" } ?? ""
            return provider + title + suffix
        }
    }
    let id: String
    let name: String
    let path: String
    let isScratchpad: Bool
    let lastKnownRepositoryIdentity: String?
    var isExpanded: Bool
    var sessions: Int
    var terminalCount: Int
    var recentAgents: [SavedRuntime]
    var recentTerminals: [SavedRuntime]
}
struct WindowSnapshot: Sendable {
    let projects: [ProjectSnapshot]
    let selectedProjectIndex: Int
    let restoreAgentID: String?
    let restoreAgentActivity: Date?
    let restoreAgentProjectID: ProjectID?
    let restoreTerminalID: String?
}
struct WindowFailure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

@MainActor
private final class NavigatorMouseEvent: NSEvent {
    private let point: NSPoint
    init(locationInWindow point: NSPoint) {
        self.point = point
        super.init()
    }
    override var locationInWindow: NSPoint { point }
}

@MainActor
private final class NavigatorKeyEvent: NSEvent {
    private let code: UInt16
    init(keyCode: UInt16) {
        code = keyCode
        super.init()
    }
    nonisolated override var type: NSEvent.EventType { .keyDown }
    override var keyCode: UInt16 { code }
    override var charactersIgnoringModifiers: String? {
        String(UnicodeScalar(code == 126 ? 0xF700 : 0xF701)!)
    }
}

/// Stable outline identity survives a project reorder or a newly prepended saved runtime.
/// Position is carried only to avoid searching the catalogue while mounting visible cells.
@MainActor
private final class WorkspacePageRevealRequest { var target: NavigatorOutlineItem? }


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
    @MainActor private static let terminalMark: NSImage = {
        guard let image = Design.Symbol.image("terminal", slot: SidebarRowDefaults.iconSlotWidth,
                                              pointSize: SidebarRowDefaults.iconSize,
                                              weight: .regular)
        else { preconditionFailure("terminal identity glyph is unavailable") }
        return image
    }()

    private static let maximumOpenRuntimes = 8
    private static let maximumSelectableAgentsPerProject = 512
    private static let maximumSelectableTerminalsPerProject = 512
    private static let maximumPersistedRuntimeTitleScalars = 256
    // Saved-runtime rows use the same outer height as the production outline's session cells.
    // The host still assigns viewport frames; the row's contents solve shared constraints.
    private static let navigatorRowHeight: CGFloat = SidebarDefaults.rowHeight
    private static let navigatorRowStride: CGFloat = SidebarDefaults.rowHeight
    @MainActor private static var navigatorHeaderHeight: CGFloat { PaneHeaderView.bandHeight }
    @MainActor private static var navigatorRowsTop: Int32 { Int32((navigatorHeaderHeight + 2) * WorkspaceDisplay.scale) }
    #if os(Linux)
    static let terminalCellWidth = Int(TW_TERMINAL_CELL_WIDTH)
    static let terminalCellHeight = Int(TW_TERMINAL_CELL_HEIGHT)
    #endif

    @MainActor private static func navigatorRowRect(_ index: Int, width: Int, height: Int,
                                                    indent: CGFloat = 0) -> NSRect {
        let top = navigatorHeaderHeight + 2 + CGFloat(index) * navigatorRowStride
        return NSRect(x: 6 + indent, y: CGFloat(height) / WorkspaceDisplay.scale - top - navigatorRowHeight,
                      width: CGFloat(width) / WorkspaceDisplay.scale - 12 - indent, height: navigatorRowHeight)
    }
    @MainActor private static func navigatorRowPixels(_ index: Int, width: Int, height: Int,
                                                      indent: CGFloat = 0)
        -> (x: Int32, y: Int32, width: Int32, height: Int32) {
        let row = navigatorRowRect(index, width: width, height: height, indent: indent)
        return (Int32(row.minX * WorkspaceDisplay.scale), Int32((CGFloat(height) / WorkspaceDisplay.scale - row.maxY) * WorkspaceDisplay.scale),
                Int32(row.width * WorkspaceDisplay.scale), Int32(row.height * WorkspaceDisplay.scale))
    }

    @MainActor private static func menuRowPixels(_ slot: Int, in root: Specimen.Window,
                                                   scale: CGFloat)
        -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
        guard let view = root.mountedMenuRow(at: slot) else { return nil }
        let row = view.convert(view.bounds, to: root)
        return (Int32(row.minX * scale), Int32((root.bounds.height - row.maxY) * scale),
                Int32(row.width * scale), Int32(row.height * scale))
    }

    private static func readableNavigatorText(_ text: String) -> String {
        text.unicodeScalars.prefix(256).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) ||
                scalar.properties.generalCategory == .format { return "�" }
            return String(scalar)
        }.joined()
    }

    private static func repositoryAccessibilityID(_ identity: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "repository:" + String(hash, radix: 16)
    }

    /// The production session content draws the title and provider mark in a bounded row slot.
    /// The host keeps identity, retained/attention status and its complete accessible label.
    @MainActor private static func addSavedAgentRow(
        _ runtime: ProjectSnapshot.SavedRuntime, retained: Bool, at date: Date,
        index: Int, width: Int, height: Int, accent: NSColor, selected: Bool,
        selectedInk: Specimen.Ink, root: Specimen.Window, image: NSImage?,
        activity: NativeSessionActivity, activityPhase: CGFloat,
        indent: CGFloat = 0
    ) {
        let frame = navigatorRowRect(index, width: width, height: height, indent: indent)
        let ink = selected ? selectedInk : root.bodyInk
        root.mountNavigatorRow(frame: frame, accent: accent,
                               selected: selected, ink: ink, showsMark: image == nil)
        let attention = runtime.attention(at: date)
        let dormant = !retained && attention != .scheduled
        root.mountSessionContent(title: readableNavigatorText(runtime.title), icon: image,
                                 selected: selected, dormant: dormant)
        root.mountSessionStatus(runtime.attentionTitle(at: date).map(readableNavigatorText),
                                color: selected ? ink.secondary : Design.Text.tertiary)
        root.mountSessionActivity(activity, phase: activityPhase)
    }

    /// A visible saved shell uses the Mac terminal row's icon and title composition. The
    /// host retains exact runtime identity, selection, activation and accessibility labels.
    @MainActor private static func addSavedTerminalRow(
        _ runtime: ProjectSnapshot.SavedRuntime, running: Bool, index: Int,
        width: Int, height: Int, accent: NSColor, selected: Bool,
        selectedInk: Specimen.Ink, root: Specimen.Window, indent: CGFloat = 0
    ) {
        let frame = navigatorRowRect(index, width: width, height: height, indent: indent)
        let ink = selected ? selectedInk : root.bodyInk
        root.mountNavigatorRow(frame: frame, accent: accent, selected: selected,
                               ink: ink, showsMark: false)
        root.mountTerminalContent(title: readableNavigatorText(runtime.title), icon: terminalMark,
                                  selected: selected, running: running)
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
    private enum RuntimeOwner {
        case project(String)
        case saved(SavedRuntimeKey)
    }

    private static func savedAgent(_ session: AgentSession) -> ProjectSnapshot.SavedRuntime {
        var saved = savedAgent(agentRow(session))
        saved.usesNativeUI = session.usesNativeUI
        saved.isPinned = session.isPinned
        saved.agentSessionID = session.resumeState.transcriptID?.rawValue
        saved.customTitle = session.customTitle.map {
            String($0.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars))
        }
        // Retain durable facts, not a clock-derived state which can expire while the picker
        // stays open. Invalid/archived snooze records follow AgentSession.isSnoozed semantics.
        if !session.isArchived, let start = session.snoozedAt,
           let end = session.snoozedUntil, start < end {
            saved.snoozedUntil = end
        }
        return saved
    }

    private static func agentRow(_ session: AgentSession) -> AgentSessionRowPresentation {
        // The preview has no title preference yet; follow agent titles, as the Mac default does.
        AgentSessionRowPresentation(session: session, usesAgentTitle: true,
            untitledTitle: AgentDefaults.untitledSessionName,
            attention: AgentSessionRowPresentation.Attention.resolve(
                // The preview has no scheduler. Snooze is resolved from the snapshot deadline at paint.
                isScheduled: false, hasWoken: session.wake != nil,
                isSnoozed: false
            ))
    }

    private static func savedAgent(_ row: AgentSessionRowPresentation) -> ProjectSnapshot.SavedRuntime {
        .init(id: row.id.uuidString,
              title: String(row.title.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)),
              kind: row.kind,
              account: row.accountHandle.isStandard ? nil : String(row.accountHandle.name.unicodeScalars.prefix(64)),
              attention: row.attention)
    }

    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            #if os(Linux)
            await GraphicalTerminal.waitForPendingStops()
            #endif
            FileHandle.standardError.write(Data("WindowHarness: \(error)\n".utf8))
            exit(1)
        }
        #if os(Linux)
        await GraphicalTerminal.waitForPendingStops()
        #endif
    }

    @MainActor private static func run() async throws {
        #if os(Linux)
        let mode = CommandLine.arguments.dropFirst().first
        if mode == "--settings-row-contract" {
            SettingsAdaptiveControlRowFixture.run()
            return
        }
        if mode == "--session-archive-fixture" {
            try SessionArchiveActionFixture.run()
            return
        }
        if mode == "--text-prompt" {
            if CommandLine.arguments.count == 3, CommandLine.arguments[2] == "worktree" {
                guard let branch = try LinuxTextPrompt.runWorktree() else { exit(2) }
                FileHandle.standardOutput.write(Data("\(branch)\n".utf8))
                return
            }
            if CommandLine.arguments.count == 5,
               CommandLine.arguments[2] == "confirm-close-session",
               CommandLine.arguments[3].utf8.count <= 4_096,
               CommandLine.arguments[4] == "resume" || CommandLine.arguments[4] == "shell" {
                let title = "Close “\(CommandLine.arguments[3])”?"
                let message = CommandLine.arguments[4] == "resume"
                    ? "The agent will stop. The session stays in the sidebar and can be resumed."
                    : "The shell will stop. The session stays in the sidebar."
                guard try LinuxTextPrompt.runConfirmation(title: title, message: message,
                                                          confirmTitle: "Close Session") else { exit(2) }
                return
            }
            guard CommandLine.arguments.count == 5,
                  CommandLine.arguments[2] == "rename-session",
                  CommandLine.arguments[3].utf8.count <= 4_096,
                  CommandLine.arguments[4].utf8.count <= 4_096 else {
                throw WindowFailure("usage: WindowHarness --text-prompt rename-session <display> <current>")
            }
            guard let title = try LinuxTextPrompt.runRename(
                displayTitle: CommandLine.arguments[3], currentTitle: CommandLine.arguments[4]
            ) else { exit(2) }
            let encoded = try JSONEncoder().encode(title)
            FileHandle.standardOutput.write(encoded + Data([10]))
            return
        }
        if mode == "--snooze-picker" {
            guard CommandLine.arguments.count == 2 else {
                throw WindowFailure("usage: WindowHarness --snooze-picker")
            }
            guard let deadline = try LinuxScheduleMomentPicker.runSnooze() else { exit(2) }
            FileHandle.standardOutput.write(Data("\(deadline.timeIntervalSince1970)\n".utf8))
            return
        }
        let decodedMarks = await Task.detached(priority: .utility) {
            NSFont.prepareSystemFonts()
            return ProviderMarks.decode()
        }.value
        ProviderMarks.install(decodedMarks)
        if mode == "--app-event-contract" {
            try await AppEventContract.run()
            return
        }
        if mode == "--native-conversation-delivery-contract" {
            guard CommandLine.arguments.count == 3 else { throw WindowFailure("usage: WindowHarness --native-conversation-delivery-contract PROVIDER_SCRIPT") }
            try NativeConversationDeliveryContract.run(script: CommandLine.arguments[2])
            return
        }
        if mode == "--ui-worker-contract" {
            try NativeUIWorkerContract.run()
            return
        }
        if mode == "--stream-ui-fixture" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            guard args.count >= 2 else {
                throw WindowFailure("usage: WindowHarness --stream-ui-fixture OUTPUT AGENT [ARGUMENTS...]")
            }
            try await DocumentUIFixture.run(output: args[0], automaticRows: true,
                                            streamAgent: Array(args.dropFirst()),
                                            keyEvent: composerKeyEvent)
            return
        }
        if mode == "--document-ui-fixture" || mode == "--automatic-rows-ui-fixture" || mode == "--diff-ui-fixture" || mode == "--user-bubble-ui-fixture" || mode == "--short-user-bubble-ui-fixture" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            guard args.count == 1 else { throw WindowFailure("usage: WindowHarness --document-ui-fixture OUTPUT") }
            try await DocumentUIFixture.run(output: args[0], automaticRows: mode == "--automatic-rows-ui-fixture",
                                            diffMode: mode == "--diff-ui-fixture",
                                            userBubbleMode: mode == "--user-bubble-ui-fixture" || mode == "--short-user-bubble-ui-fixture",
                                            userBubbleText: mode == "--short-user-bubble-ui-fixture" ? "Short prompt é 日本語 👩🏽‍🚀" : nil,
                                            keyEvent: composerKeyEvent)
            return
        }
        if mode == "--project-row-layout-fixture" {
            ProjectRowLayoutFixture.run()
            return
        }
        if mode == "--prompt-completion-layout-fixture" {
            guard CommandLine.arguments.count == 3 else {
                throw WindowFailure("usage: WindowHarness --prompt-completion-layout-fixture OUTPUT_PREFIX")
            }
            try PromptCompletionLayoutFixture.run(output: CommandLine.arguments[2])
            return
        }
        if mode == "--session-row-layout-fixture" {
            SessionRowLayoutFixture.run()
            return
        }
        if mode == "--terminal-row-layout-fixture" {
            TerminalRowLayoutFixture.run()
            return
        }
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

    private final class ArchiveGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SessionArchiveAction.Result, Error>?

        func finish(_ value: Result<SessionArchiveAction.Result, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<SessionArchiveAction.Result, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class PinGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SessionPinAction.Result, Error>?

        func finish(_ value: Result<SessionPinAction.Result, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<SessionPinAction.Result, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class RenameGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SessionRenameAction.Result, Error>?

        func finish(_ value: Result<SessionRenameAction.Result, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<SessionRenameAction.Result, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class RenamePromptGate: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var result: Result<String?, Error>?

        func opened(_ child: Process) {
            lock.lock(); process = child; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel && child.isRunning { child.terminate() }
        }
        func closed() { lock.lock(); process = nil; lock.unlock() }
        func cancel() {
            lock.lock(); cancelled = true; let child = process; lock.unlock()
            if let child, child.isRunning { child.terminate() }
        }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func finish(_ value: Result<String?, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<String?, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private static func beginRenamePrompt(displayTitle: String, currentTitle: String,
                                          dark: Bool) -> RenamePromptGate {
        let gate = RenamePromptGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/proc/self/exe")
                child.arguments = ["--text-prompt", "rename-session", displayTitle, currentTitle]
                var environment = ProcessInfo.processInfo.environment
                environment["THREADING_LINUX_PROMPT_DARK"] = dark ? "1" : "0"
                child.environment = environment
                child.standardInput = FileHandle.nullDevice
                let output = Pipe()
                child.standardOutput = output
                child.standardError = FileHandle.nullDevice
                try child.run()
                gate.opened(child)
                var bytes = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    guard bytes.count + chunk.count <= 16_384 else {
                        gate.cancel()
                        throw WindowFailure("Session name is too long")
                    }
                    bytes.append(chunk)
                }
                child.waitUntilExit()
                gate.closed()
                if gate.isCancelled() || child.terminationStatus == 2 { return nil }
                guard child.terminationStatus == 0, bytes.last == 10 else {
                    throw WindowFailure("Rename prompt failed")
                }
                return try JSONDecoder().decode(String.self, from: bytes.dropLast())
            })
        }
        return gate
    }

    private final class ClosePromptGate: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var result: Result<Bool, Error>?

        func opened(_ child: Process) {
            lock.lock(); process = child; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel && child.isRunning { child.terminate() }
        }
        func closed() { lock.lock(); process = nil; lock.unlock() }
        func cancel() {
            lock.lock(); cancelled = true; let child = process; lock.unlock()
            if let child, child.isRunning { child.terminate() }
        }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func finish(_ value: Result<Bool, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<Bool, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private static func beginCloseConfirmation(displayTitle: String,
                                               canResume: Bool, dark: Bool) -> ClosePromptGate {
        let gate = ClosePromptGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/proc/self/exe")
                child.arguments = ["--text-prompt", "confirm-close-session", displayTitle,
                                   canResume ? "resume" : "shell"]
                var environment = ProcessInfo.processInfo.environment
                environment["THREADING_LINUX_PROMPT_DARK"] = dark ? "1" : "0"
                child.environment = environment
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                try child.run()
                gate.opened(child)
                child.waitUntilExit()
                gate.closed()
                if gate.isCancelled() || child.terminationStatus == 2 { return false }
                guard child.terminationStatus == 0 else {
                    throw WindowFailure("Close Session confirmation failed")
                }
                return true
            })
        }
        return gate
    }

    private final class CloseGate: @unchecked Sendable {
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

    private final class SessionPresenceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: GraphicalTerminal.RuntimePresence?

        func finish(_ value: GraphicalTerminal.RuntimePresence) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> GraphicalTerminal.RuntimePresence? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class SnoozeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SessionSnoozeAction.Result, Error>?

        func finish(_ value: Result<SessionSnoozeAction.Result, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<SessionSnoozeAction.Result, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class SnoozePickerGate: @unchecked Sendable {
        private let lock = NSLock()
        private var picker: Process?
        private var cancelled = false
        private var result: Result<Date?, Error>?

        func opened(_ process: Process) {
            lock.lock()
            picker = process
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel && process.isRunning { process.terminate() }
        }
        func closed() {
            lock.lock(); picker = nil; lock.unlock()
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let process = picker
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
        func isCancelled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func finish(_ value: Result<Date?, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<Date?, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private static func beginSnoozePicker(dark: Bool) -> SnoozePickerGate {
        let gate = SnoozePickerGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result {
                let picker = Process()
                picker.executableURL = URL(fileURLWithPath: "/proc/self/exe")
                picker.arguments = ["--snooze-picker"]
                var environment = ProcessInfo.processInfo.environment
                environment["THREADING_LINUX_PROMPT_DARK"] = dark ? "1" : "0"
                picker.environment = environment
                picker.standardInput = FileHandle.nullDevice
                let output = Pipe()
                picker.standardOutput = output
                picker.standardError = output
                try picker.run()
                gate.opened(picker)
                var bytes = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    guard bytes.count + chunk.count <= 4_096 else {
                        gate.cancel()
                        throw WindowFailure("Snooze picker returned too much data")
                    }
                    bytes.append(chunk)
                }
                picker.waitUntilExit()
                gate.closed()
                if gate.isCancelled() || picker.terminationStatus == 2 { return nil }
                if picker.terminationStatus != 0 {
                    let detail = String(data: bytes, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                    throw WindowFailure("Snooze picker failed: \(detail)")
                }
                guard picker.terminationStatus == 0, bytes.last == 10,
                      let value = String(data: bytes.dropLast(), encoding: .utf8),
                      let seconds = Double(value), seconds.isFinite else {
                    throw WindowFailure("Snooze picker returned an invalid time")
                }
                return Date(timeIntervalSince1970: seconds)
            })
        }
        return gate
    }

    private final class SnoozeScanGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SessionSnoozeAction.Deadlines, Error>?

        func finish(_ value: Result<SessionSnoozeAction.Deadlines, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<SessionSnoozeAction.Deadlines, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class SnoozeExpiryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[SessionID: SessionSnoozeAction.Result], Error>?

        func finish(_ value: Result<[SessionID: SessionSnoozeAction.Result], Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<[SessionID: SessionSnoozeAction.Result], Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class NativeCreationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<ComposerNativeCreation.Receipt, Error>?

        func finish(_ value: Result<ComposerNativeCreation.Receipt, Error>) {
            lock.lock(); result = value; lock.unlock()
        }
        func take() -> Result<ComposerNativeCreation.Receipt, Error>? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    private final class CheckoutDiscoveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (LinuxGitCheckoutCatalog, [LinuxGitHeadMonitor.Entry])?

        func finish(_ catalogue: LinuxGitCheckoutCatalog,
                    entries: [LinuxGitHeadMonitor.Entry]) {
            lock.lock(); result = (catalogue, entries); lock.unlock()
        }
        func take() -> (LinuxGitCheckoutCatalog, [LinuxGitHeadMonitor.Entry])? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    /// GIO may read the desktop registry; publish one immutable result back to SDL's owner.
    private final class OpenInCatalogueGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: LinuxExternalApps.Catalogue?

        func finish(_ catalogue: LinuxExternalApps.Catalogue) {
            lock.lock(); result = catalogue; lock.unlock()
        }

        func take() -> LinuxExternalApps.Catalogue? {
            lock.lock(); defer { lock.unlock() }
            let value = result
            result = nil
            return value
        }
    }

    /// One selected desktop icon is decoded off SDL's thread. A completed miss is distinct
    /// from work still in flight, so an unavailable icon does not queue itself every frame.
    private final class OpenInIconGate: @unchecked Sendable {
        private let lock = NSLock()
        private var result: LinuxExternalApps.IconPixels??

        func finish(_ pixels: LinuxExternalApps.IconPixels?) {
            lock.lock(); result = .some(pixels); lock.unlock()
        }

        func take() -> LinuxExternalApps.IconPixels?? {
            lock.lock(); defer { lock.unlock() }
            let ready = result
            result = nil
            return ready
        }
    }

    /// SDL's owner keeps the small image cache and in-flight request together. The worker sees
    /// only a Sendable desktop entry and its result gate, never captured window-loop locals.
    @MainActor private final class OpenInIconState {
        private struct Pending {
            let id: String
            let hint: String
            let gate: OpenInIconGate
        }

        private struct Cached {
            let hint: String
            let image: NSImage?
        }

        private var pending: Pending?
        private var cache: [String: Cached] = [:]
        private var order: [String] = []

        var isLoading: Bool { pending != nil }

        func selectedImage(for app: LinuxExternalApp) -> NSImage? {
            guard let hint = app.iconHint else { return nil }
            if let cached = cache[app.id], cached.hint == hint { return cached.image }
            guard pending == nil else { return nil }
            let gate = OpenInIconGate()
            pending = Pending(id: app.id, hint: hint, gate: gate)
            DispatchQueue.global(qos: .utility).async {
                gate.finish(LinuxExternalApps.icon(for: app))
            }
            return nil
        }

        func retainAvailable(_ catalogue: LinuxExternalApps.Catalogue) {
            cache = cache.filter { id, cached in
                cached.image != nil && catalogue.apps.contains {
                    $0.id == id && $0.iconHint == cached.hint
                }
            }
            order.removeAll { cache[$0] == nil }
        }

        /// Nil means the worker has not finished. A completed missing icon is cached as a miss,
        /// so a failing desktop entry cannot launch another decode on every render poll.
        func takeCompleted() -> Bool {
            guard let pending, let pixels = pending.gate.take() else { return false }
            self.pending = nil
            let image = pixels.flatMap { decoded -> NSImage? in
                guard let image = NSImage(rgba: decoded.rgba, width: decoded.width,
                                          height: decoded.height) else { return nil }
                image.isTemplate = decoded.isTemplate
                return image
            }
            cache[pending.id] = Cached(hint: pending.hint, image: image)
            order.removeAll { $0 == pending.id }
            order.append(pending.id)
            if order.count > 4 { cache.removeValue(forKey: order.removeFirst()) }
            return true
        }
    }

    /// The prompt or GTK folder picker and store import run away from SDL's owning thread. One bounded
    /// snapshot crosses back to the navigator; closing the window closes a pending dialog.
    private final class FolderImportGate: @unchecked Sendable {
        let blocksParentInput: Bool
        private let lock = NSLock()
        private var chooser: Process?
        private var cancelled = false
        private var result: Result<WindowSnapshot?, Error>?

        init(blocksParentInput: Bool) { self.blocksParentInput = blocksParentInput }

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

    private enum ProjectFolderChoice: Equatable {
        case existing, new, scratchpad
        case worktree(sourcePath: String, dark: Bool)
    }

    private static func beginFolderImport(store: String, socket: String,
                                          choice: ProjectFolderChoice = .existing,
                                          droppedPath: String? = nil) -> FolderImportGate {
        let blocksParentInput: Bool
        if case .worktree = choice { blocksParentInput = true }
        else { blocksParentInput = false }
        let gate = FolderImportGate(blocksParentInput: blocksParentInput)
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result { try importFolder(store: store, socket: socket,
                                                  choice: choice, droppedPath: droppedPath, gate: gate) })
        }
        return gate
    }

    private static func importFolder(store: String, socket: String, choice: ProjectFolderChoice,
                                     droppedPath: String?, gate: FolderImportGate) throws -> WindowSnapshot? {
        var bytes = Data()
        var tooLong = false
        if case .worktree(let sourcePath, let dark) = choice {
            let chooser = Process()
            chooser.executableURL = URL(fileURLWithPath: "/proc/self/exe")
            chooser.arguments = ["--text-prompt", "worktree"]
            var environment = ProcessInfo.processInfo.environment
            environment["THREADING_LINUX_PROMPT_DARK"] = dark ? "1" : "0"
            chooser.environment = environment
            let output = Pipe()
            chooser.standardInput = FileHandle.nullDevice
            chooser.standardOutput = output
            chooser.standardError = FileHandle.nullDevice
            try chooser.run()
            gate.opened(chooser)
            var branchBytes = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                guard branchBytes.count + chunk.count <= 1024 else {
                    gate.cancel()
                    throw WindowFailure("Branch name is too long.")
                }
                branchBytes.append(chunk)
            }
            chooser.waitUntilExit()
            gate.closed()
            if gate.isCancelled() || chooser.terminationStatus == 2 { return nil }
            guard chooser.terminationStatus == 0, branchBytes.last == 10,
                  let branch = String(data: branchBytes.dropLast(), encoding: .utf8) else {
                throw WindowFailure("Worktree prompt returned an invalid branch name.")
            }
            bytes = Data(try LinuxWorktreeCreation.create(branch: branch, from: sourcePath).utf8)
        } else if let droppedPath {
            bytes = Data(droppedPath.utf8)
        } else if choice != .scratchpad {
            let chooser = Process()
            chooser.executableURL = URL(fileURLWithPath: "/usr/bin/zenity")
            chooser.arguments = choice == .new
                ? ["--file-selection", "--save", "--filename=New Project",
                   "--title=New Project"]
                : ["--file-selection", "--directory", "--title=Add project folder"]
            let output = Pipe()
            // A launcher may be reading commands from stdin (including bash -s smoke runs).
            // Neither child may consume those commands while the window remains open.
            chooser.standardInput = FileHandle.nullDevice
            chooser.standardOutput = output
            chooser.standardError = FileHandle.nullDevice
            try chooser.run()
            gate.opened(chooser)
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
        }
        let folder: URL?
        if choice == .scratchpad { folder = nil }
        else {
            guard let path = String(data: bytes, encoding: .utf8), path.hasPrefix("/"),
                  path.utf8.count <= 4096, path != "/" else {
                throw WindowFailure("folder picker returned an invalid path")
            }
            guard !gate.isCancelled() else { return nil }
            if choice == .new {
                let destination = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
            }
            guard let existing = ProjectDirectory.existing(at: path) else {
                throw WindowFailure("selected project directory does not exist")
            }
            folder = existing
        }
        guard !gate.isCancelled() else { return nil }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("LinuxHost"),
            FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WindowFailure("LinuxHost executable is unavailable")
        }
        let host = Process()
        host.executableURL = executable
        host.arguments = choice == .scratchpad ? ["--ensure-scratchpad", store]
            : ["--add-project", store, folder!.path]
        let hostOutput = Pipe()
        host.standardInput = FileHandle.nullDevice
        host.standardOutput = hostOutput
        host.standardError = hostOutput
        try host.run()
        var hostBytes = Data()
        var hostTooLong = false
        while true {
            let chunk = hostOutput.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if hostBytes.count + chunk.count > 4096 { hostTooLong = true }
            else if !hostTooLong { hostBytes.append(chunk) }
        }
        host.waitUntilExit()
        guard host.terminationStatus == 0 else {
            let detail = String(data: hostBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "project host failed"
            throw WindowFailure(hostTooLong ? "project host refusal exceeded its bound" : detail)
        }
        guard !hostTooLong, hostBytes.last == 10 else {
            throw WindowFailure("project host returned an invalid path")
        }
        hostBytes.removeLast()
        guard let hostPath = String(data: hostBytes, encoding: .utf8),
              hostPath.hasPrefix("/"), ProjectDirectory.existing(at: hostPath) != nil,
              choice == .scratchpad || hostPath == folder!.path else {
            throw WindowFailure("project host returned a mismatched path")
        }
        return try loadSnapshot(store, selectingProjectAt: hostPath, socket: socket)
    }

    private struct PendingSelection {
        let event: TWEvent
        let continuesOnRefusal: Bool
        let gate: SelectionGate
    }

    private static func recordSelection(_ agentID: String?, terminalID: String? = nil,
                                        terminalProjectID: String? = nil, store: String,
                                        after event: TWEvent,
                                        continuesOnRefusal: Bool = false) -> PendingSelection {
        let gate = SelectionGate()
        DispatchQueue.global(qos: .userInitiated).async {
            gate.finish(Result {
                try GraphicalTerminal.selectRuntime(store: store, agentID: agentID,
                                                    terminalID: terminalID,
                                                    terminalProjectID: terminalProjectID)
            })
        }
        return PendingSelection(event: event, continuesOnRefusal: continuesOnRefusal, gate: gate)
    }

    static func loadSnapshot(_ path: String, selectingProjectAt requestedPath: String? = nil,
                             socket: String? = nil) throws -> WindowSnapshot {
        let snapshot = try loadStoredSnapshot(path, selectingProjectAt: requestedPath)
        if let socket, let idText = snapshot.restoreTerminalID,
           let uuid = UUID(uuidString: idText) {
            switch GraphicalTerminal.terminalPresence(socket: socket, id: TerminalID(uuid)) {
            case .running, .unavailable: break
            case .absent, .exited:
                return WindowSnapshot(projects: snapshot.projects,
                    selectedProjectIndex: snapshot.selectedProjectIndex,
                    restoreAgentID: nil, restoreAgentActivity: nil,
                    restoreAgentProjectID: nil, restoreTerminalID: nil)
            }
        }
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
            restoreAgentActivity: nil, restoreAgentProjectID: nil,
            restoreTerminalID: snapshot.restoreTerminalID)
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
        // A normal relaunch follows the saved runtime to its owning project. Reuse a session in
        // the bounded navigator snapshot; one indexed read covers a selection older than that
        // window. Standalone terminals are already decoded with their owning project payload.
        // An explicit project argument remains authoritative.
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
            } ?? catalog.selectedTerminal.flatMap { terminal in
                catalog.projects.firstIndex(where: { $0.id == terminal.projectID })
            } ?? 0
        }
        var projects = catalog.projects.map { project in
            let agents = project.recentSessions.map(savedAgent)
            let terminals = project.recentTerminals.map {
                ProjectSnapshot.SavedRuntime(id: String(describing: $0.id),
                    title: String($0.displayTitle.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars)))
            }
            return ProjectSnapshot(id: String(describing: project.id), name: project.name,
                path: project.folderPath, isScratchpad: project.isScratchpad,
                lastKnownRepositoryIdentity: project.lastKnownRepositoryIdentity,
                isExpanded: project.isExpanded,
                sessions: project.sessionCount,
                terminalCount: project.terminalCount, recentAgents: agents, recentTerminals: terminals)
        }
        // Restore only a selected live runtime in the chosen project. An older selected row
        // joins its bounded picker without increasing the mounted-row ceiling.
        let restoreAgentID: String?
        let restoreAgentActivity: Date?
        let restoreAgentProjectID: ProjectID?
        let restoreTerminalID: String?
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
        if let selectedTerminal = catalog.selectedTerminal,
           catalog.projects.indices.contains(selectedIndex),
           selectedTerminal.projectID == catalog.projects[selectedIndex].id,
           restoreAgentID == nil {
            let id = selectedTerminal.terminal.id.uuidString
            if !projects[selectedIndex].recentTerminals.contains(where: { $0.id == id }) {
                let saved = ProjectSnapshot.SavedRuntime(id: id,
                    title: String(selectedTerminal.terminal.displayTitle.unicodeScalars.prefix(
                        maximumPersistedRuntimeTitleScalars)))
                projects[selectedIndex].recentTerminals.insert(saved, at: 0)
                if projects[selectedIndex].recentTerminals.count > maximumSelectableTerminalsPerProject {
                    projects[selectedIndex].recentTerminals.removeLast()
                }
            }
            restoreTerminalID = id
        } else {
            restoreTerminalID = nil
        }
        let selectedProjectID = projects.indices.contains(selectedIndex) ? projects[selectedIndex].id : nil
        // Mac pins the scratchpad above projects while preserving the user's remaining order.
        // Partition once per store snapshot; pointer and paint still touch only visible rows.
        let pinned = projects.filter(\.isScratchpad)
        let ordinary = projects.filter { !$0.isScratchpad }
        projects = pinned + ordinary
        let displayedSelectedIndex = selectedProjectID.flatMap { id in
            projects.firstIndex { $0.id == id }
        } ?? 0
        return WindowSnapshot(projects: projects, selectedProjectIndex: displayedSelectedIndex,
                              restoreAgentID: restoreAgentID,
                              restoreAgentActivity: restoreAgentActivity,
                              restoreAgentProjectID: restoreAgentProjectID,
                              restoreTerminalID: restoreTerminalID)
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

    @MainActor static func composerKeyEvent(_ input: TWEvent) -> NSEvent {
        let keyCode: UInt16
        let characters: String
        switch Int(input.key) {
        case TW_KEY_ESCAPE: keyCode = 53; characters = "\u{1b}"
        case TW_KEY_ENTER: keyCode = 36; characters = "\r"
        case 32: keyCode = 49; characters = " "
        case TW_KEY_TAB: keyCode = 48; characters = "\t"
        case TW_KEY_BACKSPACE: keyCode = 51; characters = "\u{7f}"
        case TW_KEY_DELETE: keyCode = 117; characters = ""
        case TW_KEY_LEFT: keyCode = 123; characters = ""
        case TW_KEY_RIGHT: keyCode = 124; characters = ""
        case TW_KEY_DOWN: keyCode = 125; characters = ""
        case TW_KEY_UP: keyCode = 126; characters = ""
        case TW_KEY_HOME: keyCode = 115; characters = ""
        case TW_KEY_END: keyCode = 119; characters = ""
        case TW_KEY_PAGE_UP: keyCode = 116; characters = ""
        case TW_KEY_PAGE_DOWN: keyCode = 121; characters = ""
        default:
            keyCode = 0
            // Functional protocol codes are not text. Only actual native letter/digit
            // shortcut keys and the control's Space activation carry characters.
            let code = Int(input.key)
            let isTextKey = code == 32 || (48...57).contains(code) || (97...122).contains(code)
            characters = isTextKey ? UnicodeScalar(code).map(String.init) ?? "" : ""
        }
        var modifiers: NSEvent.ModifierFlags = []
        if input.modifiers & 1 != 0 { modifiers.insert(.shift) }
        if input.modifiers & 2 != 0 { modifiers.insert(.option) }
        if input.modifiers & 4 != 0 { modifiers.insert(.control) }
        if input.modifiers & 8 != 0 { modifiers.insert(.command) }
        return NSEvent(type: .keyDown, modifierFlags: modifiers, keyCode: keyCode,
                       charactersIgnoringModifiers: characters)
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
        NativeCursorBoundary.install(for: window)
        defer { NativeCursorBoundary.uninstall() }
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
        NativeCursorBoundary.install(for: window)
        defer { NativeCursorBoundary.uninstall() }
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
                                              width: Int, height: Int, workspace: Bool = false,
                                              focused: Bool = true) throws {
        let accessible = "Terminal unavailable: \(boundedAccessibilityLabel(message))"
        accessible.withCString { tw_accessibility_show_terminal(window, $0) }
        tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
        let scale = WorkspaceDisplay.scale
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0,
            width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        root.title = "Terminal unavailable"
        root.addSubview(Specimen.Message(frame: NSRect(x: 12, y: 8,
            width: root.frame.width - 24, height: root.frame.height - 42),
            text: "Ctrl+Shift+P: projects\n\n" + message, ink: root.bodyInk.label))
        let bitmap = Bitmap(width: width, height: height, background: Specimen.bodyGround.components)
        let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
        NSGraphicsContext.current = context
        root.render(in: context)
        NSGraphicsContext.current = nil
        let result = bitmap.pixels.withUnsafeBufferPointer {
            workspace ? tw_present_pane(window, $0.baseAddress, Int32(width), Int32(height), 0)
                : tw_present(window, $0.baseAddress, Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused { tw_title(window, "Threading terminal - unavailable") }
        print("FAILURE_FRAME \(width)x\(height)"); fflush(nil)
    }

    @MainActor private static func reconcilePendingAgents(
        projects: inout [ProjectSnapshot],
        projectIndexes: [String: Int],
        runtimes: inout [SavedRuntimeKey: GraphicalTerminal],
        pending: inout [String: ProjectID],
        publishedCounts: inout [String: Int],
        retainedProjects: inout Set<String>,
        preserving selection: (projectID: String, agentID: String)? = nil,
        onCommitted: (GraphicalTerminal.AgentCreation) -> Void = { _ in },
        onFailed: (String) -> Void = { _ in }
    ) -> Bool {
        var changed = false
        var admitted: [GraphicalTerminal.AgentCreation] = []
        publishedCounts = publishedCounts.filter { runtimes[.agent($0.key)] != nil }
        // At most eight runtime receipts; no store reads or archive walk on the UI actor.
        for id in Array(pending.keys) {
            let key = SavedRuntimeKey.agent(id)
            guard let runtime = runtimes[key] else {
                pending.removeValue(forKey: id)
                onFailed(id)
                continue
            }
            if let receipt = runtime.takeAgentCreation() {
                admitted.append(receipt)
                pending.removeValue(forKey: id)
            } else if runtime.canReplace, !runtime.hasPendingAgentCreation {
                // A receipt can arrive between the take and the failure check. Never discard
                // a committed row just because its later spawn failed.
                runtime.stop()
                runtimes.removeValue(forKey: key)
                pending.removeValue(forKey: id)
                onFailed(id)
                changed = true
            }
        }
        // Keep commit order across batches too: a worker can publish just after this iteration
        // inspected it, while a newer admission is already consumed from a different runtime.
        for receipt in admitted.sorted(by: { $0.sessionCount < $1.sessionCount }) {
            onCommitted(receipt)
            guard let index = projectIndexes[receipt.projectID.uuidString],
                  projects.indices.contains(index),
                  projects[index].id == receipt.projectID.uuidString else { continue }
            let id = receipt.row.id.uuidString
            publishedCounts[id] = receipt.sessionCount
            if !projects[index].recentAgents.contains(where: { $0.id == id }) {
                let newer = projects[index].recentAgents.lastIndex {
                    (publishedCounts[$0.id] ?? 0) > receipt.sessionCount
                }
                projects[index].recentAgents.insert(savedAgent(receipt.row), at: newer.map { $0 + 1 } ?? 0)
                if projects[index].recentAgents.count > maximumSelectableAgentsPerProject {
                    let last = projects[index].recentAgents.count - 1
                    let preservesLast = selection?.projectID == projects[index].id
                        && selection?.agentID == projects[index].recentAgents[last].id
                    projects[index].recentAgents.remove(at: preservesLast ? last - 1 : last)
                }
            }
            // Import may already include this admission, even outside its recent-row window.
            // Keep its newer row presentation/order and never count the same commit twice.
            projects[index].sessions = max(projects[index].sessions, receipt.sessionCount)
            retainedProjects.insert(receipt.projectID.uuidString)
            changed = true
        }
        return changed
    }

    /// At most eight creation receipts, with at most 512 value rows in each affected picker.
    /// A persisted count is authoritative even when selection or process admission then failed.
    @MainActor private static func reconcileCreatedTerminals(
        projects: inout [ProjectSnapshot], projectIndexes: [String: Int],
        runtimes: [String: GraphicalTerminal],
        preserving selection: (projectID: String, terminalID: String)?
    ) -> Bool {
        var changed = false
        for runtime in runtimes.values {
            guard let receipt = runtime.takeTerminalCreation(),
                  let index = projectIndexes[receipt.projectID.uuidString],
                  projects.indices.contains(index),
                  projects[index].id == receipt.projectID.uuidString else { continue }
            let id = receipt.terminalID.uuidString
            projects[index].recentTerminals.removeAll { $0.id == id }
            projects[index].recentTerminals.insert(.init(id: id, title: receipt.title), at: 0)
            if projects[index].recentTerminals.count > maximumSelectableTerminalsPerProject {
                let last = projects[index].recentTerminals.count - 1
                let preservesLast = selection?.projectID == projects[index].id
                    && selection?.terminalID == projects[index].recentTerminals[last].id
                projects[index].recentTerminals.remove(at: preservesLast ? last - 1 : last)
            }
            // A concurrent folder-import snapshot may already include this exact admission.
            projects[index].terminalCount = max(projects[index].terminalCount, receipt.terminalCount)
            changed = true
        }
        return changed
    }

    @MainActor static func show(_ snapshot: WindowSnapshot, launch: [String]? = nil,
                                agentExecutable: String? = nil,
                                claudeExecutable: String? = nil,
                                codexAccounts: [AccountHandle] = [],
                                claudeAccounts: [AccountHandle] = []) throws {
        if launch != nil { try WorkspaceDisplay.configureForApp() }
        let scale = WorkspaceDisplay.scale
        var traceFirstFrame = ProcessInfo.processInfo.environment["THREADING_LINUX_STARTUP_TRACE"] == "1"
        let traceNavigation = ProcessInfo.processInfo.environment["THREADING_LINUX_NAVIGATION_TRACE"] == "1"
        let maximumTraceRecords = 256
        var traceRecords = 0
        let traceStarted = traceFirstFrame || traceNavigation ? DispatchTime.now().uptimeNanoseconds : 0
        func trace(_ stage: @autoclosure () -> String) {
            guard (traceFirstFrame || traceNavigation), traceRecords < maximumTraceRecords else { return }
            traceRecords += 1
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - traceStarted) / 1_000_000
            // Direct stderr writes survive a stall before the ordinary frame log is flushed.
            let label = traceFirstFrame ? "STARTUP_TRACE" : "NAVIGATION_TRACE"
            FileHandle.standardError.write(Data(
                "\(label) scope=navigator stage=\(stage()) elapsedMs=\(elapsed)\n".utf8))
        }
        trace("open.begin")
        var codexAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CODEX_ACCOUNT"])
        var claudeAccount = AccountHandle(storedName:
            ProcessInfo.processInfo.environment["THREADING_LINUX_CLAUDE_ACCOUNT"])
        // Saved native conversations reach every provider this host can launch. The ACP CLIs
        // come from the launcher's environment, beside its Codex and Claude arguments.
        var nativeExecutables: [AgentKind: String] = [:]
        nativeExecutables[.codex] = agentExecutable
        nativeExecutables[.claude] = claudeExecutable
        for (kind, key) in [(AgentKind.grok, "THREADING_LINUX_GROK"), (.cursor, "THREADING_LINUX_CURSOR")] {
            if let path = ProcessInfo.processInfo.environment[key], path.hasPrefix("/") {
                nativeExecutables[kind] = path
            }
        }
        var projects = snapshot.projects
        var projectIndexes = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
        let sidebarWidth = WorkspaceDisplay.sidebarPixels
        print("WORKSPACE_GEOMETRY scale=\(Int(scale)) sidebar=\(sidebarWidth) header=\(WorkspacePaneChrome.headerPixelHeight)")
        let openedWindow: OpaquePointer?
        if launch != nil {
            openedWindow = tw_open_workspace("Threading Linux window experiment",
                Int32(1120 * scale), Int32(480 * scale), Int32(sidebarWidth))
        } else {
            openedWindow = tw_open("Threading Linux window experiment", 800, 480)
        }
        guard let window = openedWindow else {
            throw WindowFailure(String(cString: tw_error()))
        }
        let activityWindow = SidebarActivityWindow(pointer: window)
        var initialX: Int32 = 0, initialY: Int32 = 0, initialWidth: Int32 = 0, initialHeight: Int32 = 0
        tw_window_geometry(window, &initialX, &initialY, &initialWidth, &initialHeight)
        print("WORKSPACE_WINDOW pixels=\(initialWidth)x\(initialHeight) scale=\(Int(scale))")
        trace("open.end")
        defer { tw_close(window) }
        let uiWork = NativeUIWorkLoop(window: window)
        defer { uiWork.close() }
        NSPasteboard.general.writeString = { value in
            let bytes = Array(value.utf8)
            guard bytes.count <= 1_048_576 else { return false }
            return bytes.withUnsafeBufferPointer { tw_clipboard_write($0.baseAddress, Int32($0.count)) == 0 }
        }
        NSPasteboard.general.readString = {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBufferPointer { tw_clipboard_read($0.baseAddress, Int32($0.count)) }
            return count > 0 ? String(bytes: bytes.prefix(Int(count)), encoding: .utf8) : nil
        }
        defer { NSPasteboard.general.writeString = nil; NSPasteboard.general.readString = nil }
        NativeCursorBoundary.install(for: window)
        defer { NativeCursorBoundary.uninstall() }
        // Native panes present permission cards; without this every request is refused.
        PermissionBroker.install()
        LinuxSymbols.install()
        // The window shares one pixel/point scale across painting and input. Keep one content owner and
        // root for the native window's lifetime so attachment callbacks describe that lifetime.
        let contentWindow = NSWindow(backingScaleFactor: scale)
        contentWindow.isKeyWindow = tw_window_has_focus(window) != 0
        let navigatorRoot = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        contentWindow.contentView = navigatorRoot
        navigatorRoot.installWorkspaceBackdrop()
        navigatorRoot.setThemeAppearance()
        navigatorRoot.headerHeight = navigatorHeaderHeight
        navigatorRoot.hasMountedHeader = true
        // Retain the real production pane band and its controls for the window lifetime.
        // The title yields before either action; the band owns margins, spacing and its rule.
        let headerBrand = SidebarBrandView(frame: .zero)
        headerBrand.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let addProjectButton = ThemedIconButton(
            symbolName: "plus", accessibility: "Add Project", target: .inline,
            inkSource: .chrome)
        addProjectButton.toolTip = "Add Project"
        addProjectButton.presentsMenu = true
        var addProjectActivated = false
        var addProjectControlVisualChanged = false
        addProjectButton.onPress = { addProjectActivated = true }
        addProjectButton.surfaceStateDidChange = { addProjectControlVisualChanged = true }
        let actionsButton = ThemedIconButton(
            symbolName: "ellipsis", accessibility: "Actions", target: .inline,
            inkSource: .chrome)
        actionsButton.toolTip = "Actions (Ctrl+Shift+Space)"
        var actionsActivated = false
        var actionsControlVisualChanged = false
        actionsButton.onPress = { actionsActivated = true }
        actionsButton.surfaceStateDidChange = { actionsControlVisualChanged = true }
        let header = PaneHeaderView(
            leading: [headerBrand], trailing: [addProjectButton, actionsButton], margin: .paneEdge)
        navigatorRoot.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: navigatorRoot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: navigatorRoot.trailingAnchor),
            header.topAnchor.constraint(equalTo: navigatorRoot.topAnchor)
        ])
        // The workspace owns one structural seam. It follows the theme rather than borrowing
        // the standalone specimen's frame, which also outlined the window's other three edges.
        let sidebarDivider = SeparatorView(.vertical)
        navigatorRoot.addSubview(sidebarDivider)
        NSLayoutConstraint.activate([
            sidebarDivider.trailingAnchor.constraint(equalTo: navigatorRoot.trailingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: navigatorRoot.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: navigatorRoot.bottomAnchor)
        ])
        let outlineSource = NavigatorOutlineSource()
        let outline = NSOutlineView(frame: .zero)
        outline.style = .inset
        outline.rowHeight = SidebarDefaults.rowHeight
        outline.intercellSpacing = .zero
        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Projects"))
        outline.addTableColumn(outlineColumn)
        outline.outlineTableColumn = outlineColumn
        outline.dataSource = outlineSource
        outline.delegate = outlineSource
        let outlineScroll = ThemedScrollView(frame: .zero)
        outlineScroll.verticalLineScroll = SidebarDefaults.rowHeight
            + outline.intercellSpacing.height
        outlineScroll.contentBreathing = NSEdgeInsets(
            top: SidebarDefaults.contentTopInset, left: 0, bottom: 0, right: 0)
        outlineScroll.documentView = outline
        navigatorRoot.setNavigatorOutline(outlineScroll, below: header, visible: false)
        var emptyStateView: NSStackView?
        func setEmptyStateVisible(_ visible: Bool) {
            guard visible else { emptyStateView?.isHidden = true; return }
            if let emptyStateView { emptyStateView.isHidden = false; return }
            let message = SidebarEmptyState.makeView()
            emptyStateView = message
            navigatorRoot.addSubview(message)
            NSLayoutConstraint.activate([
                message.centerXAnchor.constraint(equalTo: outlineScroll.centerXAnchor),
                message.centerYAnchor.constraint(equalTo: outlineScroll.centerYAnchor),
                message.leadingAnchor.constraint(greaterThanOrEqualTo: navigatorRoot.leadingAnchor,
                    constant: SidebarDefaults.emptyStateInset),
                message.trailingAnchor.constraint(lessThanOrEqualTo: navigatorRoot.trailingAnchor,
                    constant: -SidebarDefaults.emptyStateInset)
            ])
        }
        func headerPixels(_ view: NSView) -> (x: Int32, y: Int32, width: Int32, height: Int32) {
            let rect = view.convert(view.bounds, to: navigatorRoot)
            let scale = contentWindow.backingScaleFactor
            return (Int32(rect.minX * scale),
                    Int32((navigatorRoot.bounds.height - rect.maxY) * scale),
                    Int32(rect.width * scale), Int32(rect.height * scale))
        }
        func projectControlPixels(_ rowIndex: Int, create: Bool)
            -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
            guard let row = outline.view(atColumn: 0, row: rowIndex,
                                         makeIfNecessary: false) as? Specimen.Row,
                  let control = row.productionProjectControl(create: create) else {
                return nil
            }
            let viewport = outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot)
            let rowBounds = row.convert(row.bounds, to: navigatorRoot).intersection(viewport)
            let visible = control.convert(control.bounds, to: navigatorRoot).intersection(rowBounds)
            guard !visible.isEmpty else { return nil }
            let scale = contentWindow.backingScaleFactor
            return (Int32(visible.minX * scale),
                    Int32((navigatorRoot.bounds.height - visible.maxY) * scale),
                    Int32(visible.width * scale), Int32(visible.height * scale))
        }
        func outlineRowPixels(_ rowIndex: Int)
            -> (x: Int32, y: Int32, width: Int32, height: Int32)? {
            guard let cell = outline.view(atColumn: 0, row: rowIndex,
                                          makeIfNecessary: false) else { return nil }
            let viewport = outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot)
            let rect = cell.convert(cell.bounds, to: navigatorRoot).intersection(viewport)
            guard !rect.isEmpty else { return nil }
            let scale = contentWindow.backingScaleFactor
            return (Int32(rect.minX * scale),
                    Int32((navigatorRoot.bounds.height - rect.maxY) * scale),
                    Int32(rect.width * scale), Int32(rect.height * scale))
        }
        func outlineRowIndex(at event: TWEvent) -> Int? {
            let scale = contentWindow.backingScaleFactor
            let point = NSPoint(x: CGFloat(event.x) / scale,
                                y: navigatorRoot.bounds.height - CGFloat(event.y) / scale)
            guard outlineScroll.convert(outlineScroll.bounds, to: navigatorRoot).contains(point)
            else { return nil }
            let index = outline.row(at: outline.convert(point, from: navigatorRoot))
            return index >= 0 ? index : nil
        }
        func publishOutlineAccessibleRow(_ rowIndex: Int, id: String, label: String,
                                         selected: Bool) throws {
            guard let bounds = outlineRowPixels(rowIndex) else {
                throw WindowFailure("accessible outline row has no mounted cell")
            }
            let result = id.withCString { identifier in
                label.withCString { name in
                    tw_accessibility_add_row(window, identifier, name, selected ? 1 : 0,
                        bounds.x, bounds.y, bounds.width, bounds.height)
                }
            }
            guard result == 0 else { throw WindowFailure("native outline row exceeds its bound") }
        }
        var laidOutHeaderSize: NSSize?
        var laidOutAddProjectHidden: Bool?
        var laidOutActionsHidden: Bool?
        func publishHeaderGeometry() {
            // A recycled outline cell can invalidate its own constraints on every wheel tick.
            // The brand header changes geometry only with its containing size or control
            // visibility, so a scroll must not lay out the entire document to republish it.
            if laidOutHeaderSize != navigatorRoot.bounds.size ||
               laidOutAddProjectHidden != addProjectButton.isHidden ||
               laidOutActionsHidden != actionsButton.isHidden {
                contentWindow.layoutIfNeeded()
                laidOutHeaderSize = navigatorRoot.bounds.size
                laidOutAddProjectHidden = addProjectButton.isHidden
                laidOutActionsHidden = actionsButton.isHidden
            }
            let actionsRect = headerPixels(actionsButton)
            tw_actions_button(window, actionsButton.isSelected ? "Close actions" : "Actions",
                              actionsButton.isEnabled ? 1 : 0, actionsRect.x, actionsRect.y,
                              actionsRect.width, launch == nil ? 0 : actionsRect.height)
            let addRect = headerPixels(addProjectButton)
            tw_add_project_button(window, addProjectButton.isEnabled ? 1 : 0,
                                  addRect.x, addRect.y, addRect.width,
                                  launch == nil ? 0 : addRect.height)
        }
        tw_navigator_pointer_route(window, 1)
        defer { contentWindow.contentView = nil }
        var pendingMountedRowSlot: Int?
        func mountedRowPressed(by event: TWEvent) -> Int? {
            if let slot = pendingMountedRowSlot {
                pendingMountedRowSlot = nil
                return slot
            }
            activatedOutlineItem = nil
            let scale = contentWindow.backingScaleFactor
            let point = NSPoint(x: CGFloat(event.x) / scale,
                                y: navigatorRoot.bounds.height - CGFloat(event.y) / scale)
            guard let delivered = contentWindow.dispatch(NavigatorMouseEvent(locationInWindow: point))
            else { return nil }
            navigatorRoot.hitTest(point)?.mouseDown(with: delivered)
            if actions == nil, accountPicker == nil, savedPicker == nil,
               !projects.isEmpty, let index = outlineRowIndex(at: event),
               let activatedOutlineItem,
               outline.row(forItem: activatedOutlineItem) == index {
                return index - first
            }
            return navigatorRoot.takeActivatedRowSlot()
        }
        func navigatorStep(for event: TWEvent) -> Int? {
            let direction = event.kind == 3 ? -1 : 1
            if event.action == 1 {
                return actions == nil && accountPicker == nil && savedPicker == nil
                    ? nil : direction
            }
            guard sidebarFocused else { return nil }
            if actions == nil && accountPicker == nil && savedPicker == nil { return direction }
            if accountPicker != nil { return direction }
            _ = contentWindow.dispatchToContent(NavigatorKeyEvent(
                keyCode: event.kind == 3 ? 126 : 125))
            return navigatorRoot.takeNavigationStep()
        }
        var terminals: [String: GraphicalTerminal] = [:]
        var restoredRuntimes: [SavedRuntimeKey: GraphicalTerminal] = [:]
        var nativeRuntimes: [SavedRuntimeKey: WorkspaceConversationPane] = [:]
        var composerCreationPending = false
        var pendingAgentProjects: [String: ProjectID] = [:]
        // At most one commit count per retained agent runtime, within the shared eight-slot cap.
        var publishedAgentCounts: [String: Int] = [:]
        var restoredProjectIDs: Set<String> = []
        // A fresh project shell keeps one owner even when selected through its saved row.
        // These lookups never add aliases, so the sum of cache counts stays the eight-slot bound.
        func owner(of key: SavedRuntimeKey, projectID: String) -> RuntimeOwner {
            if case .terminal(let id) = key, terminals[projectID]?.terminalID == id {
                return .project(projectID)
            }
            return .saved(key)
        }
        func retainedRuntime(for owner: RuntimeOwner) -> GraphicalTerminal? {
            switch owner {
            case .project(let id): return terminals[id]
            case .saved(let key): return restoredRuntimes[key]
            }
        }
        func hasActiveRuntime(_ key: SavedRuntimeKey, projectID: String) -> Bool {
            if let runtime = retainedRuntime(for: owner(of: key, projectID: projectID)) {
                return !runtime.canReplace
            }
            if case .agent = key {
                return nativeRuntimes[key]?.runtime.presentsActiveAgent == true
            }
            return false
        }
        func retain(_ runtime: GraphicalTerminal, for owner: RuntimeOwner) {
            switch owner {
            case .project(let id): terminals[id] = runtime
            case .saved(let key): restoredRuntimes[key] = runtime
            }
        }
        defer {
            for terminal in terminals.values { terminal.stop() }
            for terminal in restoredRuntimes.values { terminal.stop() }
            let deadline = Date().addingTimeInterval(1)
            for pane in nativeRuntimes.values { pane.runtime.closeForQuit(by: deadline) }
        }
        var width = Int(initialWidth), height = Int(initialHeight),
            selected = snapshot.selectedProjectIndex, first = 0
        var inlineSelection: NavigatorOutlineItem?
        var pendingImportedProjectID: String?
        var outlineRevealTarget: NavigatorOutlineItem?
        var savedPicker: SavedPicker?
        var savedSelected = 0, savedFirst = 0
        var accountPicker: AgentKind?
        let retainedMenuRows = RetainedMenuRows()
        var accountSelected = 0, accountFirst = 0
        var activatedAccountHandle: AccountHandle?
        var pendingSelection: PendingSelection?
        var pendingFolderImport: FolderImportGate?
        var pendingArchive: (id: String, projectID: String, gate: ArchiveGate)?
        var pendingPin: (id: String, projectID: String, gate: PinGate)?
        var pendingRename: (id: String, projectID: String, gate: RenameGate)?
        var pendingRenamePrompt: (id: String, projectID: String,
                                  displayedCurrentTitle: String?, gate: RenamePromptGate)?
        var pendingClosePrompt: (id: String, projectID: String, gate: ClosePromptGate)?
        var pendingClose: (id: String, projectID: String, gate: CloseGate)?
        var pendingSessionMenuPresence: (id: String, projectID: String,
                                         gate: SessionPresenceGate)?
        let snoozeWorker = DispatchQueue(label: "threading.linux.session-snooze", qos: .utility)
        var pendingSnoozeScan: SnoozeScanGate?
        var pendingSnooze: (id: String, projectID: String, gate: SnoozeGate)?
        var pendingSnoozePicker: (id: String, projectID: String,
                                  hadTurnInFlight: Bool, gate: SnoozePickerGate)?
        var pendingSnoozeExpiry: (ids: [SessionID], gate: SnoozeExpiryGate)?
        var snoozeDeadlines: [SessionID: Date] = [:]
        var nextSnoozeDeadline: Date?
        var nextSnoozeScanAttempt = Date.distantPast
        let snoozeWakeInbox = SnoozeWakeInbox()
        var pendingSnoozeAcknowledgements: [String: String] = [:]
        var actions: NavigatorActions.Presentation?
        var sessionMenu: SidebarSessionMenu?
        let sessionMenuSurface = SessionMenuSurface(frame: .zero)
        let retainedSessionMenuRows = RetainedMenuRows()
        var sessionMenuSeparators: [SeparatorView] = []
        var sessionMenuFrame = NSRect.zero
        var sessionMenuVisibleEntries: [Int] = []
        var activatedSessionMenuEntry: Int?
        var activatedMenuEntry: Int?
        var actionsEnabled = true
        var dismissedActionGesture: Int32?
        var hoveredOutlineItem: NavigatorOutlineItem?
        var dirty = true
        func refreshSnoozeDeadline() {
            nextSnoozeDeadline = snoozeDeadlines.values.min()
        }
        func updateSnoozeRow(_ id: String, projectID: String,
                             result: SessionSnoozeAction.Result) {
            guard let index = projectIndexes[projectID], projects.indices.contains(index),
                  let row = projects[index].recentAgents.firstIndex(where: { $0.id == id }) else {
                return
            }
            projects[index].recentAgents[row].snoozedUntil = result.deadline
            projects[index].recentAgents[row].attention = result.hasWake ? .woke : nil
            dirty = true
        }
        func startSnoozeScan() {
            guard pendingSnoozeScan == nil, let launch else { return }
            let gate = SnoozeScanGate()
            pendingSnoozeScan = gate
            nextSnoozeScanAttempt = Date.distantFuture
            snoozeWorker.async {
                gate.finish(Result {
                    try SessionSnoozeAction.reconcileAtStartup(store: launch[0], now: Date())
                })
            }
        }
        startSnoozeScan()
        func makeObservedTerminal() -> GraphicalTerminal {
            GraphicalTerminal(onActivityChange: {
                NativeConversationDelivery.callbacks.receive { navigatorRoot.needsDisplay = true }
            })
        }
        var collapsedRepositoryIdentities = Set(PreferenceStore.shared.stringArray(
            forKey: SidebarDefaults.collapsedRepositoriesKey) ?? [])
        var pendingExpansion: (projectID: String, expanded: Bool, selection: NavigatorOutlineItem?, gate: SelectionGate)?
        var pendingRepositoryExpansion: (identity: String, expanded: Bool,
            previous: Set<String>, gate: SelectionGate)?
        var quitAfterExpansion = false
        outlineSource.canChangeExpansion = {
            pendingExpansion == nil && pendingRepositoryExpansion == nil
        }
        outlineSource.expansionChanged = { item, expanded in
            if item.kind == .repository {
                let previous = collapsedRepositoryIdentities
                if expanded { collapsedRepositoryIdentities.remove(item.id) }
                else { collapsedRepositoryIdentities.insert(item.id) }
                let saved = Array(collapsedRepositoryIdentities)
                let gate = SelectionGate()
                pendingRepositoryExpansion = (item.id, expanded, previous, gate)
                DispatchQueue.global(qos: .userInitiated).async {
                    let defaults = PreferenceStore.shared
                    defaults.set(saved, forKey: SidebarDefaults.collapsedRepositoriesKey)
                    gate.finish(defaults.synchronize() ? .success(())
                        : .failure(WindowFailure("repository fold preference was not saved")))
                }
                dirty = true
                return
            }
            guard item.kind == .project, let index = projectIndexes[item.projectID] else { return }
            projects[index].isExpanded = expanded
            guard let launch else { return }
            precondition(pendingExpansion == nil, "navigation waits for the standing disclosure write")
            let gate = SelectionGate()
            pendingExpansion = (item.projectID, expanded, inlineSelection, gate)
            print("OUTLINE_EXPANSION_PENDING project=\(item.projectID) expanded=\(expanded)")
            fflush(nil)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(Result {
                    try NavigatorExpansionStore.save(store: launch[0], projectID: item.projectID,
                                                     expanded: expanded)
                })
            }
        }
        var outlineNeedsReload = true
        var outlineScrollSelection = true
        var activatedOutlineItem: NavigatorOutlineItem?
        var activatedOutlineProjectActionID: String?
        var activatedOutlineProjectCreateID: String?
        var activatedOutlineSessionActionID: String?
        var activatedOutlineSessionArchiveID: String?
        var rowActionMenuGesture = false
        var rowActionMenuSource: NSRect = .zero
        var rowActionMenuEntered = false
        func toggleProjectExpansion(projectID: String, projectIndex: Int) {
            let item = NavigatorOutlineItem(projectID: projectID, projectIndex: projectIndex)
            if outline.isItemExpanded(item) { outline.collapseItem(item) }
            else { outline.expandItem(item) }
            print("OUTLINE_EXPANSION project=\(projectID) expanded=\(outline.isItemExpanded(item))")
            fflush(nil)
        }
        func actionState(for targetID: ProjectID? = nil) -> NavigatorActions.State {
            let project: ProjectSnapshot?
            if let targetID, let index = projectIndexes[targetID.uuidString],
               projects.indices.contains(index), projects[index].id == targetID.uuidString {
                project = projects[index]
            } else if targetID != nil {
                project = nil
            } else {
                project = projects.indices.contains(selected) ? projects[selected] : nil
            }
            let shell = project.flatMap { terminals[$0.id] }
            let runtimeCount = terminals.count + restoredRuntimes.count + nativeRuntimes.count
                + (composerCreationPending ? 1 : 0)
            return .init(projectID: project.flatMap { ProjectID(uuidString: $0.id) },
                canOpenShell: shell != nil || runtimeCount < maximumOpenRuntimes,
                canCreateShell: (shell == nil || shell!.canReplace)
                    && runtimeCount - (shell == nil ? 0 : 1) < maximumOpenRuntimes,
                shellMayBeRunning: shell != nil && shell?.canReplace != true,
                canCreateAgent: runtimeCount < maximumOpenRuntimes,
                canCreateWorktree: project.flatMap { outlineSource.checkoutCatalog.checkouts[$0.id] } != nil,
                hasCodex: agentExecutable != nil, hasClaude: claudeExecutable != nil,
                hasAgents: project?.recentAgents.isEmpty == false,
                hasTerminals: project?.recentTerminals.isEmpty == false)
        }
        defer { pendingFolderImport?.cancel() }
        defer { pendingSnoozePicker?.gate.cancel() }
        defer { pendingRenamePrompt?.gate.cancel() }
        defer { pendingClosePrompt?.gate.cancel() }
        var navigatorDisplayRevision: UInt64 = 0
        var nextVisibleAttentionExpiry: Date?
        var visibleWorkingActivity = false
        var activityPhase: CGFloat = 0
        var nextActivityFrame = Date.distantPast
        var workingMarks: [ThemedSessionActivityMark] = []
        var workingPatches: [(mark: ThemedSessionActivityMark, x: Int, y: Int,
                              width: Int, height: Int, background: [UInt8])] = []
        func paintWorkingPatches() throws {
            guard !workingPatches.isEmpty else { return }
            activityPhase = Design.Motion.reducesStatusMotion ? 0 : CGFloat(
                Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9)
            for patch in workingPatches {
                let tile = Bitmap(width: patch.width, height: patch.height)
                tile.withMutablePixels { pixels in
                    for index in patch.background.indices { pixels[index] = patch.background[index] }
                }
                let context = NSGraphicsContext(bitmap: tile, scale: scale)
                NSGraphicsContext.current = context
                patch.mark.updatePhase(activityPhase)
                patch.mark.effectiveAppearance.performAsCurrentDrawingAppearance {
                    patch.mark.draw(patch.mark.bounds)
                }
                NSGraphicsContext.current = nil
                let result = tile.pixels.withUnsafeBufferPointer {
                    tw_update_sidebar_region(activityWindow.pointer, $0.baseAddress,
                        Int32(patch.x), Int32(patch.y), Int32(patch.width), Int32(patch.height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
            }
            guard tw_repaint(activityWindow.pointer) == 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            nextActivityFrame = Date().addingTimeInterval(1.0 / 24)
        }
        func configureOutlineRow(_ row: Specimen.Row, item: NavigatorOutlineItem,
                                 frame: NSRect) {
            guard let model = item.resolvedRow(in: projects, indexes: projectIndexes) else {
                return
            }
            let accent = Design.Surface.selectionFill
            let selectedInk = LinuxTheme.neutralInk(on: accent, dark: LinuxTheme.isDark)
            let selectedItem = inlineSelection
                ?? (projects.indices.contains(selected)
                    ? NavigatorOutlineItem(projectID: projects[selected].id, projectIndex: selected) : nil)
            let isSelected = selectedItem == item
            let ink = isSelected ? selectedInk : navigatorRoot.bodyInk
            row.configure(frame: frame, accent: accent, selected: isSelected, ink: ink,
                          image: nil, showsMark: false, disclosure: nil,
                          preserveProductionContent: true)
            row.drawsSelectionBackground = false
            let density = SidebarDensity(width: outline.bounds.width,
                floor: min(SidebarDefaults.tightDensityWidth, outline.bounds.width))
            let hasChildren = outline.isExpandable(item)
            row.configureProductionOutline(density: density, level: outline.level(forItem: item),
                expanded: hasChildren ? outline.isItemExpanded(item) : nil)
            row.onPress = { activatedOutlineItem = item }
            row.onNavigation = nil
            row.onProjectAction = { activatedOutlineProjectActionID = $0 }
            row.onProjectCreate = { activatedOutlineProjectCreateID = $0 }
            row.onProjectControlVisualChange = { dirty = true }
            row.onSessionAction = { activatedOutlineSessionActionID = $0 }
            row.onSessionArchive = { activatedOutlineSessionArchiveID = $0 }
            row.onSessionControlVisualChange = { dirty = true }

            switch model {
            case .repository(let identity, let representativeIndex, let representativeID):
                guard let group = outlineSource.repositoryGroups[identity] else { return }
                let title = String(group.name.unicodeScalars.prefix(80))
                row.configureProductionProject(
                    presentation: .repository(name: title,
                        hasRepresentative: representativeIndex >= 0),
                    icon: GeneratedProjectIcon.image(for: representativeIndex >= 0
                        ? projects[representativeIndex].name : group.name), count: 0,
                    projectID: launch == nil || representativeID.isEmpty ? nil : representativeID,
                    revealed: hoveredOutlineItem == item, enabled: actionsEnabled)
                row.configureProductionStatus(nil, color: ink.secondary)
            case .project(let projectIndex, _):
                let project = projects[projectIndex]
                let total = project.sessions.addingReportingOverflow(project.terminalCount)
                let totalRuntimes = total.overflow ? Int.max : total.partialValue
                let visibleChildren = min(project.recentAgents.count,
                    SidebarVisibleRows.maximumChildrenPerKind)
                    + min(project.recentTerminals.count, SidebarVisibleRows.maximumChildrenPerKind)
                let collapsedCount = outline.isItemExpanded(item)
                    ? max(0, totalRuntimes - visibleChildren) : totalRuntimes
                let title = String(project.name.unicodeScalars.prefix(80))
                let checkout = outlineSource.checkoutCatalog.checkouts[project.id]
                let isGrouped = outlineSource.repositoryIdentityByProject[project.id] != nil
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let abbreviatedPath = project.path == home ? "~" :
                    (project.path.hasPrefix(home + "/")
                        ? "~" + project.path.dropFirst(home.count) : project.path)
                let presentation: NavigatorProjectRowPresentation = isGrouped
                    ? .checkout(branch: checkout == nil ? nil : outlineSource.branch(for: project.id),
                                fallbackName: title,
                                abbreviatedPath: abbreviatedPath)
                    : .project(name: title)
                row.configureProductionProject(
                    presentation: presentation,
                    icon: GeneratedProjectIcon.image(for: project.name), count: collapsedCount,
                    projectID: launch == nil ? nil : project.id,
                    revealed: hoveredOutlineItem == item, enabled: actionsEnabled,
                    path: isGrouped ? project.path : nil,
                    unavailable: isGrouped && checkout == nil)
                row.configureProductionStatus(nil, color: ink.secondary)
            case .agent(let projectIndex, let childIndex, _):
                let project = projects[projectIndex]
                let runtime = project.recentAgents[childIndex]
                let retained = hasActiveRuntime(.agent(runtime.id), projectID: project.id)
                let activity = nativeRuntimes[.agent(runtime.id)]?.activity ?? .idle
                if activity.showsWorkingMark { visibleWorkingActivity = true }
                let now = Date()
                let attention = runtime.attention(at: now)
                if attention == .snoozed, let expiry = runtime.snoozedUntil {
                    nextVisibleAttentionExpiry = min(nextVisibleAttentionExpiry ?? expiry, expiry)
                }
                row.configureProductionSession(title: readableNavigatorText(runtime.title),
                    icon: ProviderMarks.image(for: runtime.kind, selected: isSelected),
                    selected: isSelected, dormant: !retained && attention != .scheduled,
                    isPinned: runtime.isPinned,
                    sessionID: runtime.id,
                    revealsActions: (hoveredOutlineItem == item || sessionMenu?.sessionID == runtime.id)
                        && attention != .scheduled,
                    actionSelected: sessionMenu?.sessionID == runtime.id,
                    archiveEnabled: actionsEnabled && pendingArchive == nil && pendingPin == nil)
                row.configureProductionStatus(runtime.attentionTitle(at: now),
                    color: isSelected ? ink.secondary : Design.Text.tertiary)
                row.configureProductionActivity(activity, phase: activityPhase)
                if let mark = row.productionWorkingMark { workingMarks.append(mark) }
            case .terminal(let projectIndex, let childIndex, _):
                let project = projects[projectIndex]
                let runtime = project.recentTerminals[childIndex]
                let retained = hasActiveRuntime(.terminal(runtime.id), projectID: project.id)
                row.configureProductionTerminal(title: readableNavigatorText(runtime.title),
                    icon: terminalMark, selected: isSelected, running: retained)
                row.configureProductionStatus(nil, color: ink.secondary)
            }
        }
        func configureOutlineChrome(_ row: SidebarHoverRowView, in view: NSOutlineView) {
            row.isHoverEnabled = true
            row.showsGroupRule = false
            row.applySidebarDensity(SidebarDensity(width: view.bounds.width,
                floor: min(SidebarDefaults.tightDensityWidth, view.bounds.width)))
            row.setActivityBeam(workload: .none)
        }
        outlineSource.makeRow = { view, item in
            let rowIndex = view.row(forItem: item)
            guard rowIndex >= 0 else { return nil }
            let frame = view.rect(ofRow: rowIndex)
            let identifier = NSUserInterfaceItemIdentifier("NavigatorOutlineRow")
            let row = (view.makeView(withIdentifier: identifier, owner: nil) as? Specimen.Row)
                ?? Specimen.Row(frame: frame, text: "", accent: .clear, selected: false,
                                ink: navigatorRoot.bodyInk, showsMark: false)
            row.identifier = identifier
            configureOutlineRow(row, item: item, frame: frame)
            return row
        }
        outlineSource.makeChrome = { view, _ in
            let identifier = NSUserInterfaceItemIdentifier("SidebarHoverRow")
            let row = (view.makeView(withIdentifier: identifier, owner: nil)
                as? SidebarHoverRowView) ?? SidebarHoverRowView(frame: .zero)
            row.identifier = identifier
            configureOutlineChrome(row, in: view)
            return row
        }
        var composerSubmitRequested = false
        let composerCreationWorker = DispatchQueue(label: "threading.linux.composer-creation",
                                                   qos: .userInitiated)
        var pendingNativeCreation: (gate: NativeCreationGate, request: ComposerNativeCreation.Request,
                                    prompt: String, pane: WorkspacePlaceholderPane?)?
        var composerAccount: AccountID?
        var composerPermissionMode: AgentPermissionMode?
        var composerFastMode: Bool?
        var composerUsesNativeUI = false
        var composerModel: String?
        var composerEffort: String?
        var composerShouldRestoreRunChoice = false
        var composerModelAccount: AccountID?
        var composerModelDirectory: String?
        var composerModels = ComposerModelCatalog.empty
        var composerHiddenModels: Set<String> = []
        var composerVisibilityPending = false
        let composerModelLoader = ComposerModelCatalogLoader()
        var pendingComposerRunChoices: [String: (AccountID, ComposerNewSessionRunChoice)] = [:]
        var composerDisplayedProjectID = ""
        var composerProjectChoices = projects.map { (id: $0.id, name: $0.name) }
        var composerCheckoutCatalog = LinuxGitCheckoutCatalog.empty
        var checkoutBranchOverrides: [String: CheckoutBranchDisplay] = [:]
        var checkoutHeadMonitor: LinuxGitHeadMonitor?
        defer { checkoutHeadMonitor?.stop() }
        var composerCheckoutProjectID: String?
        var pendingCheckoutDiscovery: CheckoutDiscoveryGate?
        var checkoutDiscoveryWanted = false
        var pendingComposerProjectID: String?
        func discoverCheckouts() {
            guard pendingCheckoutDiscovery == nil else {
                checkoutDiscoveryWanted = true
                return
            }
            checkoutDiscoveryWanted = false
            let paths = projects.map { (id: $0.id, path: $0.path) }
            let gate = CheckoutDiscoveryGate()
            pendingCheckoutDiscovery = gate
            DispatchQueue.global(qos: .utility).async {
                let catalogue = LinuxGitCheckout.discover(paths)
                let entries = paths.compactMap { project -> LinuxGitHeadMonitor.Entry? in
                    guard let checkout = catalogue.checkouts[project.id] else { return nil }
                    return .init(id: project.id, path: project.path,
                                 gitDirectory: checkout.identity)
                }
                gate.finish(catalogue, entries: entries)
            }
        }
        discoverCheckouts()
        var idlePane = launch.map { _ in
            WorkspacePlaceholderPane(onSubmit: {
                guard pendingFolderImport == nil, pendingSelection == nil else { return }
                composerSubmitRequested = true
            })
        }
        idlePane?.setThemeAppearance()
        func loadComposerModels() {
            guard let account = composerAccount else { composerModelLoader.cancel(); return }
            let targetID = composerCheckoutProjectID
                ?? (projects.indices.contains(selected) ? projects[selected].id : "")
            let directory = projectIndexes[targetID].flatMap {
                projects.indices.contains($0) ? projects[$0].path : nil
            }
            composerModelLoader.load(account, projectDirectory: directory) { catalogue, hidden, remembered in
                guard composerAccount == account,
                      (composerCheckoutProjectID
                          ?? (projects.indices.contains(selected) ? projects[selected].id : "")) == targetID
                else { return }
                composerModels = catalogue
                composerHiddenModels = hidden
                if composerShouldRestoreRunChoice {
                    composerShouldRestoreRunChoice = false
                    let restored = remembered.flatMap { choice -> ComposerNewSessionRunChoice? in
                        guard catalogue.admits(model: choice.model, effort: choice.reasoningEffort),
                              choice.model.map({ !hidden.contains($0) }) ?? true else { return nil }
                        return choice
                    }
                    composerModel = restored?.model
                    composerEffort = restored?.reasoningEffort
                }
                refreshComposerChoices()
                dirty = true
            }
        }
        func changeComposerVisibility(_ change: ComposerModelVisibilityStore.Change) {
            guard !composerVisibilityPending, let account = composerAccount else { return }
            composerVisibilityPending = true
            composerModelLoader.changeVisibility(change, for: account) { hidden in
                composerVisibilityPending = false
                guard composerAccount == account else { return }
                if let hidden {
                    composerHiddenModels = hidden
                } else {
                    print("MODEL_VISIBILITY_REFUSED account=\(account.rawValue)")
                }
                refreshComposerChoices()
                dirty = true
            }
        }
        func refreshComposerChoices() {
            guard let pane = idlePane, pane.isComposing else { return }
            let projectID = projects.indices.contains(selected) ? projects[selected].id : ""
            if composerDisplayedProjectID != projectID { composerCheckoutProjectID = nil }
            composerDisplayedProjectID = projectID
            let currentCheckout = composerCheckoutCatalog.checkouts[projectID]
            let siblingIDs = currentCheckout.flatMap {
                composerCheckoutCatalog.projectIDsByRepository[$0.repositoryIdentity]
            } ?? []
            func branch(_ checkout: LinuxGitCheckout, for id: String) -> String? {
                if let override = checkoutBranchOverrides[id] { return override.name }
                return checkout.branch
            }
            let siblingCheckouts = siblingIDs.compactMap { siblingID -> ComposerCheckoutChoice? in
                guard let index = projectIndexes[siblingID], projects.indices.contains(index),
                      let currentCheckout,
                      let checkout = composerCheckoutCatalog.checkouts[siblingID] else { return nil }
                let project = projects[index]
                guard !project.isScratchpad,
                      checkout.repositoryIdentity == currentCheckout.repositoryIdentity,
                      (project.id == projectID || checkout.identity != currentCheckout.identity),
                      project.id == projectID || checkout.root == project.path else { return nil }
                let title = branch(checkout, for: siblingID) ?? project.name
                return ComposerCheckoutChoice(id: project.id,
                    title: project.id == projectID ? "\(title) (this checkout)" : title,
                    detail: project.path)
            }
            if let targetID = composerCheckoutProjectID,
               !siblingCheckouts.contains(where: { $0.id == targetID }) {
                composerCheckoutProjectID = nil
            }
            let targetID = composerCheckoutProjectID ?? projectID
            let targetIndex = projectIndexes[targetID]
            let targetBranch = composerCheckoutCatalog.checkouts[targetID].flatMap {
                branch($0, for: targetID)
            }
            let projectName = projects.indices.contains(selected) ? projects[selected].name : nil
            let locationTitle = [projectName, targetBranch].compactMap { $0 }.joined(separator: " › ")
            let executionDirectory = targetIndex.flatMap {
                projects.indices.contains($0) ? projects[$0].path : nil
            }
            let locationDetail = executionDirectory.map { path in
                targetBranch.map { "\(path) › \($0)" } ?? path
            }
            var identityChoices: [ComposerIdentityChoice] = []
            var identityBindings: [(token: String, identity: AccountID)] = []
            for (kind, executable, accounts) in [
                (AgentKind.codex, agentExecutable, codexAccounts),
                (AgentKind.claude, claudeExecutable, claudeAccounts)
            ] where executable != nil {
                let mark = ProviderMarks.image(for: kind, selected: false)
                for (index, handle) in accounts.enumerated() {
                    let token = "\(kind.rawValue):\(index)"
                    let identity = AccountID(provider: kind, handle: handle)
                    identityBindings.append((token, identity))
                    identityChoices.append(ComposerIdentityChoice(
                        id: token, providerName: kind.displayName,
                        accountName: handle.isStandard ? "" : readableNavigatorText(handle.name),
                        icon: mark))
                }
            }
            if !identityBindings.contains(where: { $0.identity == composerAccount }) {
                let preferred = identityBindings.first { binding in
                    binding.identity.handle == (binding.identity.provider == .codex ? codexAccount : claudeAccount)
                }
                composerAccount = preferred?.identity ?? identityBindings.first?.identity
            }
            if composerModelAccount != composerAccount {
                composerModelAccount = composerAccount
                composerModel = nil
                composerEffort = nil
                composerShouldRestoreRunChoice = true
                composerFastMode = nil
                composerModels = .empty
                composerHiddenModels = []
                loadComposerModels()
            } else if composerModelDirectory != executionDirectory {
                loadComposerModels()
            }
            composerModelDirectory = executionDirectory
            let selectedToken = identityBindings.first { $0.identity == composerAccount }?.token ?? ""
            pane.configureComposerChoices(projects: composerProjectChoices,
                selectedProjectID: projectID,
                checkouts: siblingCheckouts, selectedCheckoutID: targetID,
                locationTitle: locationTitle, locationDetail: locationDetail,
                identities: identityChoices,
                selectedIdentityID: selectedToken,
                onProjectChoice: { projectID in
                    guard pane.isComposing,
                          let index = projectIndexes[projectID], projects.indices.contains(index),
                          projects[index].id == projectID else { return }
                    selected = index
                    composerCheckoutProjectID = nil
                    inlineSelection = NavigatorOutlineItem(projectID: projectID, projectIndex: index)
                    outlineScrollSelection = true
                    refreshComposerChoices()
                    dirty = true
                },
                onCheckoutChoice: { checkoutID in
                    guard pane.isComposing,
                          siblingCheckouts.contains(where: { $0.id == checkoutID }) else { return }
                    composerCheckoutProjectID = checkoutID == projectID ? nil : checkoutID
                    refreshComposerChoices()
                    dirty = true
                },
                onNewWorktree: {
                    guard pane.isComposing, currentCheckout != nil,
                          pendingFolderImport == nil, pendingSelection == nil,
                          let launch,
                          let index = projectIndexes[projectID], projects.indices.contains(index),
                          projects[index].id == projectID else { return }
                    pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1],
                        choice: .worktree(sourcePath: projects[index].path,
                                          dark: LinuxTheme.isDark))
                },
                onIdentityChoice: { token in
                    guard pane.isComposing,
                          let identity = identityBindings.first(where: { $0.token == token })?.identity,
                          (identity.provider == .codex ? codexAccounts : claudeAccounts)
                            .contains(identity.handle),
                          (identity.provider == .codex ? agentExecutable : claudeExecutable) != nil
                    else { return }
                    composerAccount = identity
                    if identity.provider == .codex { codexAccount = identity.handle }
                    else { claudeAccount = identity.handle }
                    refreshComposerChoices()
                    dirty = true
                })
            let defaultName = composerModels.defaultOption?.displayName
                ?? composerModels.defaultModel.map { ModelName.display(for: $0) } ?? "Default model"
            let visibleOptions = composerModels.options.filter { option in
                !composerHiddenModels.contains(option.identifier)
                    || option.identifier == composerModels.defaultModel
                    || option.identifier == composerModel
            }
            let hiddenCount = composerModels.options.reduce(0) { count, option in
                count + (composerHiddenModels.contains(option.identifier)
                    && option.identifier != composerModels.defaultModel ? 1 : 0)
            }
            let modelPresentation = ModelEffortPickerPresentation.make(options: visibleOptions,
                defaultModelID: composerModels.defaultModel, defaultModelName: defaultName,
                defaultModelDetail: "Account default", defaultOption: composerModels.defaultOption,
                selectedModel: composerModel, selectedEffort: composerEffort)
            let currentOption = composerModels.options.first {
                $0.identifier == (composerModel ?? composerModels.defaultModel)
            }
            let modelName = currentOption?.displayName
                ?? composerModel.map { ModelName.display(for: $0) } ?? defaultName
            let inheritedEffort = currentOption.flatMap { option in
                composerModels.defaultEffort.flatMap { option.supports(reasoningEffort: $0) ? $0 : nil }
                    ?? option.defaultReasoningLevel
            }
            let effortTitle = (composerEffort ?? inheritedEffort).map {
                AgentReasoningLevel(effort: $0, description: "").displayName
            } ?? "Default effort"
            let modelTitle = currentOption?.reasoningLevels.isEmpty == false
                ? "\(modelName) · \(effortTitle)" : modelName
            pane.configureModelChoices(modelPresentation, title: modelTitle,
                selectionValid: composerModels.admits(model: composerModel, effort: composerEffort),
                hiddenModelCount: hiddenCount,
                onRefresh: { loadComposerModels() },
                onHideModel: { modelID in
                    guard composerModels.options.contains(where: { $0.identifier == modelID }),
                          modelID != composerModels.defaultModel, modelID != composerModel else { return }
                    changeComposerVisibility(.hide(modelID))
                },
                onShowHiddenModels: { changeComposerVisibility(.showAll) },
                onChoose: { model, effort in
                    guard pane.isComposing, composerModels.admits(model: model, effort: effort) else { return }
                    composerModel = model
                    composerEffort = effort
                    if let kind = composerAccount?.provider,
                       !composerModels.supportsFastMode(kind: kind, model: model) {
                        composerFastMode = nil
                    }
                    refreshComposerChoices()
                    dirty = true
                })
            let speedKind = composerAccount?.provider
            let supportsSpeed = speedKind.map {
                composerModels.supportsFastMode(kind: $0, model: composerModel)
            } ?? false
            if !supportsSpeed { composerFastMode = nil }
            pane.configureSpeedChoice(available: supportsSpeed,
                title: speedKind.map { composerModels.speedTitle(selected: composerFastMode, kind: $0) }
                    ?? "Agent's Setting",
                fastMode: composerFastMode,
                onChoose: { value in
                    guard pane.isComposing, let kind = composerAccount?.provider,
                          composerModels.supportsFastMode(kind: kind, model: composerModel) else { return }
                    composerFastMode = value
                    refreshComposerChoices()
                    dirty = true
                })
            let permissionChoices: [ComposerPermissionChoice]
            let inheritedPermissionMode = composerModels.inheritedPermissionMode
            let lastUsedPermissionMode = composerModels.lastUsedPermissionMode
            if let kind = composerAccount?.provider, kind.supportsPermissionModes {
                let inheritRow = inheritedPermissionMode == nil
                    ? [ComposerPermissionChoice(id: "inherit",
                        title: PermissionModeLabels.agentSettingRowTitle, detail: "")]
                    : []
                permissionChoices = inheritRow + AgentPermissionMode.allCases.map { mode in
                    ComposerPermissionChoice(id: mode == inheritedPermissionMode ? "inherit" : mode.rawValue,
                        title: mode.displayName(for: kind)
                            + (mode == inheritedPermissionMode ? "  (default)"
                               : mode == lastUsedPermissionMode ? "  (last used)" : ""),
                        detail: [mode.menuDescription(for: kind), mode.caveat(for: kind)]
                            .compactMap { $0 }.joined(separator: " "))
                }
            } else { permissionChoices = [] }
            let permissionTitle = composerAccount.map { identity in
                (composerPermissionMode ?? inheritedPermissionMode)?.displayName(for: identity.provider)
                    ?? PermissionModeLabels.agentSettingTitle
            } ?? PermissionModeLabels.agentSettingTitle
            pane.configurePermissionChoices(permissionChoices,
                selectedID: composerPermissionMode == inheritedPermissionMode
                    ? "inherit" : composerPermissionMode?.rawValue ?? "inherit",
                title: permissionTitle,
                onChoose: { value in
                    guard pane.isComposing, composerAccount?.provider.supportsPermissionModes == true,
                          value == "inherit" || AgentPermissionMode(rawValue: value) != nil else { return }
                    composerPermissionMode = AgentPermissionMode(rawValue: value)
                    refreshComposerChoices()
                    dirty = true
                })
            let surfaceKind = composerAccount?.provider
            composerUsesNativeUI = surfaceKind.map {
                AgentSession.resolvedNativeSurface(composerUsesNativeUI, for: $0)
            } ?? false
            pane.configureSurfaceChoice(kind: surfaceKind, usesNativeUI: composerUsesNativeUI,
                onChoose: { isNative in
                    guard let kind = composerAccount?.provider,
                          kind.supportsNativeUI && kind.supports(.terminalUI) else { return }
                    composerUsesNativeUI = isNative
                    refreshComposerChoices()
                    dirty = true
                })
        }
        func composerTarget() -> (projectID: String, identity: AccountID)? {
            guard idlePane?.isComposing == true, projects.indices.contains(selected),
                  let identity = composerAccount else { return nil }
            let projectID = composerCheckoutProjectID ?? projects[selected].id
            guard projectIndexes[projectID] != nil else { return nil }
            return (projectID, identity)
        }
        refreshComposerChoices()
        var activePane: (any WorkspacePane)?
        var activePageTarget: NavigatorOutlineItem?
        var settingsPane: WorkspaceSettingsPane?
        var settingsReturnPane: (any WorkspacePane)?
        var settingsReturnIdlePane: WorkspacePlaceholderPane?
        var settingsReturnSidebarFocus = true
        func beginArchive(_ id: String, projectID: String) {
            guard pendingArchive == nil, let launch,
                  let sessionID = SessionID(uuidString: id),
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == id }) else { return }
            let key = SavedRuntimeKey.agent(id)
            // A provider archive must first stop an in-process writer, as on macOS. The
            // worker performs the daemon stop and durable/provider transaction.
            nativeRuntimes[key]?.runtime.stop()
            let gate = ArchiveGate()
            pendingArchive = (id, projectID, gate)
            hoveredOutlineItem = nil
            dirty = true
            DispatchQueue.global(qos: .utility).async {
                gate.finish(Result {
                    try SessionArchiveAction.run(store: launch[0], socket: launch[1],
                        shell: launch[2], sessionID: sessionID, archived: true)
                })
            }
        }
        func beginPin(_ id: String, projectID: String, pinned: Bool) {
            guard pendingPin == nil, let launch,
                  let sessionID = SessionID(uuidString: id),
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == id }) else { return }
            let gate = PinGate()
            pendingPin = (id, projectID, gate)
            dirty = true
            DispatchQueue.global(qos: .utility).async {
                gate.finish(Result {
                    try SessionPinAction.run(store: launch[0], sessionID: sessionID,
                        pinned: pinned)
                })
            }
        }
        func beginRename(_ id: String, projectID: String, title: String,
                         displayedCurrentTitle: String?) {
            guard pendingRename == nil, let launch,
                  let sessionID = SessionID(uuidString: id),
                  let targetProjectID = ProjectID(uuidString: projectID),
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == id }) else { return }
            let gate = RenameGate()
            pendingRename = (id, projectID, gate)
            dirty = true
            DispatchQueue.global(qos: .utility).async {
                gate.finish(Result {
                    try SessionRenameAction.run(store: launch[0], sessionID: sessionID,
                        projectID: targetProjectID, title: title,
                        displayedCurrentTitle: displayedCurrentTitle)
                })
            }
        }
        func beginClose(_ id: String, projectID: String) {
            guard pendingClose == nil, let launch,
                  let sessionID = SessionID(uuidString: id),
                  let targetProjectID = ProjectID(uuidString: projectID),
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == id }) else { return }
            let key = SavedRuntimeKey.agent(id)
            let hosted = restoredRuntimes[key] != nil
                || nativeRuntimes[key]?.runtime.presentsActiveAgent != true
            let gate = CloseGate()
            pendingClose = (id, projectID, gate)
            dirty = true
            DispatchQueue.global(qos: .utility).async {
                gate.finish(Result {
                    try SessionCloseAction.run(store: launch[0], socket: launch[1],
                        sessionID: sessionID, projectID: targetProjectID,
                        stopHostedChild: hosted)
                })
            }
        }
        func beginSnooze(_ id: String, projectID: String,
                         change: SessionSnoozeAction.Change) {
            guard pendingSnooze == nil, pendingSnoozePicker == nil,
                  pendingSnoozeScan == nil,
                  pendingSnoozeExpiry == nil, let launch,
                  let sessionID = SessionID(uuidString: id),
                  let targetProjectID = ProjectID(uuidString: projectID),
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == id }) else { return }
            let gate = SnoozeGate()
            pendingSnooze = (id, projectID, gate)
            dirty = true
            snoozeWorker.async {
                gate.finish(Result {
                    try SessionSnoozeAction.run(store: launch[0], sessionID: sessionID,
                        projectID: targetProjectID, change: change)
                })
            }
        }
        func dismissSessionMenu() {
            guard sessionMenu != nil else { return }
            sessionMenu = nil
            pendingSessionMenuPresence = nil
            sessionMenuVisibleEntries.removeAll(keepingCapacity: true)
            activatedSessionMenuEntry = nil
            retainedSessionMenuRows.reset()
            dirty = true
        }
        func openSessionMenu(_ id: String, projectID: String,
                             openInApps: [LinuxExternalApp]) {
            guard let launch, actions == nil, accountPicker == nil, savedPicker == nil,
                  pendingArchive == nil, pendingPin == nil, pendingSnooze == nil,
                  pendingSnoozePicker == nil,
                  pendingRename == nil, pendingRenamePrompt == nil,
                  pendingClose == nil, pendingClosePrompt == nil,
                  pendingSnoozeScan == nil, pendingSnoozeExpiry == nil,
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  let runtime = projects[index].recentAgents.first(where: { $0.id == id }) else {
                return
            }
            if sessionMenu?.sessionID == id { dismissSessionMenu(); return }
            pendingSessionMenuPresence = nil
            let isRunning = hasActiveRuntime(.agent(id), projectID: projectID)
            sessionMenu = SidebarSessionMenu(sessionID: id, projectID: projectID,
                worktreePath: projects[index].path, agentSessionID: runtime.agentSessionID,
                customTitle: runtime.customTitle, displayTitle: runtime.title,
                openInApps: Array(openInApps.prefix(64)), isPinned: runtime.isPinned,
                isSnoozed: runtime.attention(at: Date()) == .snoozed,
                isRunning: isRunning,
                canResume: runtime.kind?.supportsResume ?? true,
                snoozeMoments: SnoozeWallClockMoments.future(from: Date()))
            if !isRunning, let sessionID = SessionID(uuidString: id) {
                let gate = SessionPresenceGate()
                pendingSessionMenuPresence = (id, projectID, gate)
                let socket = launch[1]
                let wakeIdentity = tw_worker_wake_identity(window)
                DispatchQueue.global(qos: .utility).async {
                    gate.finish(GraphicalTerminal.agentPresence(socket: socket, id: sessionID))
                    _ = tw_worker_wake(wakeIdentity)
                }
            }
            dirty = true
        }
        func chooseSessionMenu(_ command: SidebarSessionMenu.Command) {
            guard var menu = sessionMenu,
                  let index = projectIndexes[menu.projectID], projects.indices.contains(index),
                  projects[index].recentAgents.contains(where: { $0.id == menu.sessionID })
            else { dismissSessionMenu(); return }
            switch command {
            case .copy:
                menu.openCopy()
                sessionMenu = menu
                dirty = true
                return
            case .openIn:
                menu.openIn()
                sessionMenu = menu
                dirty = true
                return
            case .snooze:
                menu.openSnooze()
                sessionMenu = menu
                dirty = true
                return
            case .back:
                menu.returnToActions()
                sessionMenu = menu
                dirty = true
                return
            case .pin:
                dismissSessionMenu()
                beginPin(menu.sessionID, projectID: menu.projectID, pinned: !menu.isPinned)
                return
            case .unsnooze:
                dismissSessionMenu()
                beginSnooze(menu.sessionID, projectID: menu.projectID, change: .unsnooze)
                return
            case .snoozeChoice:
                guard let deadline = menu.snoozeDeadline(at: menu.selected),
                      deadline > Date() else { return }
                let sessionID = menu.sessionID
                let projectID = menu.projectID
                let hasPendingOutcome = nativeRuntimes[.agent(sessionID)]?.runtime.hasPendingOutcome
                    ?? false
                dismissSessionMenu()
                beginSnooze(sessionID, projectID: projectID,
                    change: .snooze(until: deadline, at: Date(),
                                    hadTurnInFlight: hasPendingOutcome))
                return
            case .customSnooze:
                let hasPendingOutcome = nativeRuntimes[.agent(menu.sessionID)]?
                    .runtime.hasPendingOutcome ?? false
                dismissSessionMenu()
                pendingSnoozePicker = (menu.sessionID, menu.projectID,
                    hasPendingOutcome, beginSnoozePicker(dark: LinuxTheme.isDark))
                dirty = true
                return
            case .archive:
                dismissSessionMenu()
                beginArchive(menu.sessionID, projectID: menu.projectID)
                return
            case .close:
                guard menu.isRunning else { return }
                dismissSessionMenu()
                if LinuxConfirmationSettings.asks(before: .closeRunningSession) {
                    pendingClosePrompt = (menu.sessionID, menu.projectID,
                        Self.beginCloseConfirmation(displayTitle: menu.displayTitle,
                            canResume: menu.canResume, dark: LinuxTheme.isDark))
                } else {
                    beginClose(menu.sessionID, projectID: menu.projectID)
                }
                dirty = true
                return
            case .rename:
                dismissSessionMenu()
                pendingRenamePrompt = (menu.sessionID, menu.projectID, menu.customTitle,
                    beginRenamePrompt(displayTitle: menu.displayTitle,
                        currentTitle: menu.customTitle ?? "", dark: LinuxTheme.isDark))
                dirty = true
                return
            case .openInChoice:
                guard let app = menu.openInApp(at: menu.selected) else { return }
                dismissSessionMenu()
                launchOpenInForProject(app.id, projectID: menu.projectID, remember: false)
                return
            case .copyAgentID, .copyThreadingID, .copyWorktreePath:
                let value: String?
                switch command {
                case .copyAgentID: value = menu.agentSessionID
                case .copyThreadingID: value = menu.sessionID.lowercased()
                case .copyWorktreePath: value = projects[index].path
                default: value = nil
                }
                guard let value,
                      NSPasteboard.general.setString(value, forType: .string) else {
                    tw_title(window, "Threading - could not copy session value")
                    return
                }
                print("SESSION_VALUE_COPIED \(command.rawValue) id=\(menu.sessionID)")
                fflush(nil)
                dismissSessionMenu()
            }
        }
        var pendingTerminalReveal: GraphicalTerminal?
        let pageReveal = WorkspacePageRevealRequest()
        var openInCatalogue = LinuxExternalApps.Catalogue(apps: [], defaultID: nil)
        var pendingOpenInCatalogue: OpenInCatalogueGate?
        var pendingOpenInMenuPage: String?
        var pendingOpenInLaunch: (gate: SelectionGate, appID: String, remember: Bool)?
        let openInIcons = OpenInIconState()
        let openInPreferenceKey = "externalApp.preferred"
        func preferredOpenInID() -> String? {
            let stored = PreferenceStore.shared.string(forKey: openInPreferenceKey)
            if let stored, openInCatalogue.apps.contains(where: { $0.id == stored }) {
                return stored
            }
            if let fallback = openInCatalogue.defaultID,
               openInCatalogue.apps.contains(where: { $0.id == fallback }) {
                return fallback
            }
            return openInCatalogue.apps.first?.id
        }
        func configureOpenInPane() {
            guard let pane = activePane else { return }
            guard let target = activePageTarget, target.id == pane.chrome.pageIdentity,
                  let index = projectIndexes[target.projectID], projects.indices.contains(index),
                  projects[index].id == target.projectID else {
                pane.chrome.configureOpenIn(preferredID: nil, icon: nil, choices: [])
                return
            }
            let choices = openInCatalogue.apps.map {
                WorkspacePaneChrome.OpenInChoice(id: $0.id, name: $0.name)
            }
            let preferredID = preferredOpenInID()
            let selected = openInCatalogue.apps.first { $0.id == preferredID }
            let icon = selected.flatMap { openInIcons.selectedImage(for: $0) }
            pane.chrome.configureOpenIn(preferredID: preferredID, icon: icon, choices: choices)
        }
        func startOpenInDiscovery() {
            guard pendingOpenInCatalogue == nil else { return }
            let gate = OpenInCatalogueGate()
            pendingOpenInCatalogue = gate
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(LinuxExternalApps.discover())
            }
        }
        func launchOpenIn(_ appID: String, remember: Bool) {
            guard pendingOpenInLaunch == nil, let pane = activePane,
                  let target = activePageTarget,
                  pane.chrome.pageIdentity == target.id else {
                print("OPEN_IN_REFUSED stale page or app"); fflush(nil)
                return
            }
            launchOpenInForProject(appID, projectID: target.projectID, remember: remember)
        }
        func launchOpenInForProject(_ appID: String, projectID: String, remember: Bool) {
            guard pendingOpenInLaunch == nil,
                  let index = projectIndexes[projectID], projects.indices.contains(index),
                  projects[index].id == projectID,
                  openInCatalogue.apps.contains(where: { $0.id == appID }) else {
                print("OPEN_IN_REFUSED stale project or app"); fflush(nil)
                return
            }
            let directory = projects[index].path
            let gate = SelectionGate()
            pendingOpenInLaunch = (gate, appID, remember)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.finish(Result {
                    guard let folder = ProjectDirectory.existing(at: directory) else {
                        throw LinuxExternalApps.LaunchFailure(message: "The checkout no longer exists.")
                    }
                    try LinuxExternalApps.launch(appID: appID, directory: folder.path)
                })
            }
        }
        func drainOpenInRequests(_ pane: any WorkspacePane) {
            if let appID = pane.chrome.takeOpenInPressRequest() {
                launchOpenIn(appID, remember: false)
            }
            if pane.chrome.takeOpenInChooserToggleRequest() {
                if pane.chrome.hasOpenInMenu {
                    pane.chrome.toggleOpenInMenu(window: window, paneWidth: terminalWidth)
                } else if pendingOpenInMenuPage == pane.chrome.pageIdentity {
                    pendingOpenInMenuPage = nil
                } else {
                    pendingOpenInMenuPage = pane.chrome.pageIdentity
                    startOpenInDiscovery()
                }
            }
            if let appID = pane.chrome.takeOpenInChoiceRequest() {
                launchOpenIn(appID, remember: true)
                pane.chrome.dismissMenu(window: window)
            }
        }
        startOpenInDiscovery()
        var sidebarFocused = true
        var navigatorTitle = "Threading Linux window experiment"
        var hasSplitPane: Bool { idlePane != nil || activePane != nil }
        var navigatorWidth: Int { hasSplitPane ? sidebarWidth : width }
        var terminalWidth: Int { hasSplitPane ? width - sidebarWidth : width }
        if idlePane != nil {
            tw_workspace_mode(window, Int32(sidebarWidth), 1)
            tw_workspace_placeholder_mode(window, 1)
        }
        func setNavigatorTitle(_ title: String) {
            navigatorTitle = title
            if sidebarFocused { tw_title(window, title) }
        }
        func focusSidebar(_ focus: Bool) {
            guard hasSplitPane else { return }
            if focus { pendingTerminalReveal = nil }
            // Native sidebar focus cancels terminal gestures, including their queued release.
            // Mirror that cancellation even if a native press moved focus before Swift saw it.
            if focus { dismissedActionGesture = nil }
            let changed = sidebarFocused != focus
            sidebarFocused = focus
            tw_workspace_focus(window, focus ? 1 : 0)
            if !focus { contentWindow.makeFirstResponder(nil) }
            guard changed else { return }
            activePane?.focus(!focus, window: window)
            if activePane == nil {
                idlePane?.focus(!focus)
                if !focus, idlePane?.isComposing == true {
                    idlePane?.focusEditor()
                    _ = tw_workspace_editor_focus(window, 1)
                }
            }
            if focus { tw_title(window, navigatorTitle) }
            dirty = true
        }
        func toggleSettings() {
            if let shown = settingsPane {
                shown.focus(false, window: window)
                activePane = settingsReturnPane
                idlePane = settingsReturnIdlePane
                settingsReturnPane = nil
                settingsReturnIdlePane = nil
                settingsPane = nil
                if !hasSplitPane { tw_workspace_mode(window, 0, 1) }
                tw_workspace_placeholder_mode(window, idlePane == nil ? 0 : 1)
                sidebarFocused = settingsReturnSidebarFocus
                tw_workspace_focus(window, sidebarFocused ? 1 : 0)
                if sidebarFocused { tw_title(window, navigatorTitle) }
                else if let activePane { activePane.focus(true, window: window) }
                else { idlePane?.focus(true) }
                print("SETTINGS_CLOSED")
            } else {
                settingsReturnPane = activePane
                settingsReturnIdlePane = idlePane
                settingsReturnSidebarFocus = sidebarFocused
                activePane?.focus(false, window: window)
                idlePane?.focus(false)
                let pane = WorkspaceSettingsPane()
                pane.onDone = { toggleSettings() }
                settingsPane = pane
                activePane = pane
                idlePane = nil
                tw_workspace_mode(window, Int32(sidebarWidth), 0)
                tw_workspace_placeholder_mode(window, 0)
                sidebarFocused = false
                pane.focus(true, window: window)
                print("SETTINGS_OPENED")
            }
            dirty = true
            fflush(nil)
        }
        func dismissActions(returnToParent: Bool = true) {
            guard let presentation = actions else { return }
            if returnToParent, presentation.kind == .chatProviders,
               let target = presentation.projectID,
               actionState(for: target).projectID == target {
                let state = actionState(for: target)
                let repository = presentation.returnsToRepositoryCreate
                actions = .init(kind: repository ? .repositoryCreate : .projectCreate,
                    projectID: target,
                    returnToSidebar: presentation.returnToSidebar,
                    commands: repository ? NavigatorActions.repositoryCreateCommands(state)
                                         : NavigatorActions.projectCreateCommands(state))
                dirty = true
                return
            }
            actions = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            focusSidebar(presentation.returnToSidebar)
            dirty = true
        }
        func openActions(for targetID: ProjectID?, returnToSidebar: Bool) {
            guard actionsEnabled else { return }
            let state = actionState(for: targetID)
            guard targetID == nil || state.projectID == targetID else { return }
            // Menu content replaces the project rows. A later keyboard dismissal must not
            // restore an old row's hover reveal at coordinates that may now mean something else.
            hoveredOutlineItem = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            actions = .init(kind: .projectActions, projectID: state.projectID,
                            returnToSidebar: returnToSidebar,
                            commands: NavigatorActions.projectCommands(state))
            focusSidebar(true)
            dirty = true
        }
        func openAddProjectMenu() {
            guard actionsEnabled, pendingFolderImport == nil, pendingSelection == nil,
                  addProjectButton.isEnabled else { return }
            if actions != nil { dismissActions(returnToParent: false) }
            hoveredOutlineItem = nil
            actions = .init(kind: .addProject, projectID: nil,
                            returnToSidebar: sidebarFocused,
                            commands: NavigatorActions.addProjectMenuCommands())
            focusSidebar(true)
            dirty = true
        }
        func openProjectCreateMenu(for targetID: ProjectID, returnToSidebar: Bool,
                                   repository: Bool = false) {
            guard actionsEnabled, actionState(for: targetID).projectID == targetID else { return }
            hoveredOutlineItem = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            let state = actionState(for: targetID)
            actions = .init(kind: repository ? .repositoryCreate : .projectCreate,
                projectID: targetID,
                returnToSidebar: returnToSidebar,
                commands: repository ? NavigatorActions.repositoryCreateCommands(state)
                                     : NavigatorActions.projectCreateCommands(state))
            focusSidebar(true)
            dirty = true
        }
        func openChatProvidersMenu(for targetID: ProjectID, returnToSidebar: Bool) {
            guard actionsEnabled, actionState(for: targetID).projectID == targetID else { return }
            var menu = NavigatorActions.Presentation(kind: .chatProviders, projectID: targetID,
                returnToSidebar: returnToSidebar,
                commands: NavigatorActions.chatProviderCommands(actionState(for: targetID)))
            menu.returnsToRepositoryCreate = actions?.kind == .repositoryCreate
            actions = menu
            focusSidebar(true)
            dirty = true
        }
        func invokeSessionMenuCommand(_ command: SessionMenuCommand) {
            guard let pane = activePane, let target = activePageTarget,
                  target.kind == .agent, pane.chrome.pageIdentity == target.id,
                  let projectIndex = projectIndexes[target.projectID],
                  projects.indices.contains(projectIndex),
                  projects[projectIndex].id == target.projectID,
                  projects[projectIndex].recentAgents.contains(where: { $0.id == target.id })
            else {
                print("SESSION_ACTION_REFUSED stale page identity"); fflush(nil)
                return
            }
            let value: String
            switch command {
            case .copySessionID: value = target.id
            case .copyProjectPath: value = projects[projectIndex].path
            }
            let bytes = Data(value.utf8)
            guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
                print("SESSION_ACTION_REFUSED clipboard payload exceeds bound"); fflush(nil)
                return
            }
            let result = bytes.withUnsafeBytes {
                tw_clipboard_write($0.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
            }
            if result == 0 {
                print("SESSION_ACTION_COPIED \(command.rawValue) \(target.id)")
            } else {
                print("SESSION_ACTION_REFUSED clipboard unavailable")
            }
            fflush(nil)
        }
        func routeTerminalInput(_ event: TWEvent) -> Bool {
            if event.kind == 48, let pane = activePane as? WorkspaceSettingsPane {
                pane.handle(event, window: window)
                return true
            }
            if event.kind == 60 {
                var request = event
                guard let id = String(validatingCString: tw_event_text(&request)) else { return true }
                let removed: Bool
                if event.action == 1, activePane == nil {
                    removed = idlePane?.removeAttachment(id: id) == true
                } else if event.action == 2,
                          let pane = activePane as? WorkspaceConversationPane {
                    removed = pane.removeAttachment(id: id)
                } else {
                    removed = false
                }
                if removed { dirty = true }
                return true
            }
            if (56...59).contains(event.kind) {
                guard let pane = activePane as? WorkspaceConversationPane else { return true }
                var actionEvent = event
                let identity = String(validatingCString: tw_event_text(&actionEvent)) ?? ""
                let accepted: Bool
                switch event.kind {
                case 56: accepted = pane.pressSpeed(identity: identity)
                case 57: accepted = pane.chooseSpeed(index: Int(event.key), identity: identity)
                case 58: accepted = pane.pressConfiguration(kind: Int(event.action), identity: identity)
                default: accepted = pane.chooseConfiguration(kind: Int(event.action),
                    index: Int(event.key), identity: identity)
                }
                if accepted { focusSidebar(false) }
                _ = tw_workspace_editor_focus(window,
                    pane.hasOpenSpeedChoice || pane.hasOpenConfigurationChoice ? 1 : 0)
                dirty = true
                return true
            }
            if let pane = activePane as? WorkspaceConversationPane, [46, 47, 48, 49].contains(event.kind) {
                pane.handle(event, window: window)
                return true
            }
            if event.kind == 50 || event.kind == 51 {
                guard activePane == nil, let idlePane, idlePane.isComposing,
                      let identity = idlePane.composerIdentity else { return true }
                var actionEvent = event
                let value = String(validatingCString: tw_event_text(&actionEvent)) ?? ""
                let accepted: Bool
                if event.kind == 50, value == identity {
                    accepted = idlePane.pressComposerChoice(kind: Int(event.action), identity: identity)
                } else if event.kind == 51 {
                    accepted = idlePane.chooseComposerChoice(kind: Int(event.action),
                        index: Int(event.key), id: value, identity: identity)
                } else { accepted = false }
                if accepted { focusSidebar(false) }
                _ = tw_workspace_editor_focus(window,
                    idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                dirty = true
                return true
            }
            if event.kind == 49 {
                var operation: Int32 = 0
                var start: Int32 = 0
                var end: Int32 = 0
                var identity = [CChar](repeating: 0, count: 128)
                var payload = [CChar](repeating: 0, count: 65_537)
                let count = tw_accessibility_take_composer_edit(window, event.key,
                    &operation, &start, &end, &identity, Int32(identity.count),
                    &payload, Int32(payload.count))
                guard count >= 0, activePane == nil, let idlePane, idlePane.isComposing,
                      let currentID = idlePane.composerIdentity,
                      let queuedID = String(bytes: identity.prefix(while: { $0 != 0 })
                          .map(UInt8.init(bitPattern:)), encoding: .utf8),
                      queuedID == currentID,
                      let value = String(bytes: payload.prefix(Int(count)).map(UInt8.init(bitPattern:)),
                                         encoding: .utf8)
                else { return true }
                _ = idlePane.applyAccessibilityEdit(operation: operation, start: start,
                                                     end: end, text: value)
                return true
            }
            if event.kind == 46 || event.kind == 47 || event.kind == 48 {
                guard activePane == nil, let idlePane, idlePane.isComposing else { return true }
                if event.kind == 46 {
                    var committed = event
                    if let value = String(validatingCString: tw_event_text(&committed)) {
                        if idlePane.hasOpenComposerChoice {
                            _ = idlePane.handleComposerChoiceKey(NSEvent(type: .keyDown,
                                keyCode: value == " " ? 49 : 0, charactersIgnoringModifiers: value))
                        } else {
                            idlePane.insertCommittedText(value)
                        }
                    }
                } else if event.kind == 47 {
                    guard idlePane.editorHasFocus, !idlePane.hasOpenComposerChoice else { return true }
                    var preedit = event
                    if let value = String(validatingCString: tw_event_text(&preedit)) {
                        let units = value.unicodeScalars.map { String($0).utf16.count }
                        let start = min(max(0, Int(event.textCursor)), units.count)
                        let end = min(start + max(0, Int(event.textSelectionLength)), units.count)
                        let range = NSRange(location: units.prefix(start).reduce(0, +),
                            length: units[start..<end].reduce(0, +))
                        idlePane.updatePreedit(value, selectedRange: range)
                    }
                } else if event.action != 3 {
                    let keyEvent = composerKeyEvent(event)
                    if idlePane.hasOpenComposerChoice {
                        if idlePane.handleComposerChoiceKey(keyEvent) {
                            _ = tw_workspace_editor_focus(window,
                                idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                            dirty = true
                            return true
                        }
                    }
                    if Int(event.key) == TW_KEY_ESCAPE {
                        if idlePane.cancelMarkedText() { return true }
                        _ = tw_workspace_editor_focus(window, 0)
                        focusSidebar(true)
                        return true
                    }
                    let modifierShortcut = event.modifiers & (4 | 8) != 0
                    if idlePane.editorHasFocus, modifierShortcut,
                       let letter = UnicodeScalar(Int(event.key)) {
                        switch letter {
                        case "a": idlePane.selectAllText(); return true
                        case "c", "x":
                            if let selected = idlePane.selectedText {
                                let bytes = Array(selected.utf8)
                                if bytes.count <= 1_048_576 {
                                    let wrote = bytes.withUnsafeBufferPointer {
                                        tw_clipboard_write($0.baseAddress, Int32($0.count))
                                    }
                                    if letter == "x", wrote == 0 { idlePane.deleteSelection() }
                                }
                            }
                            return true
                        case "v":
                            idlePane.pasteClipboard(wakeIdentity: tw_worker_wake_identity(window))
                            return true
                        default: break
                        }
                    }
                    if Int(event.key) == TW_KEY_TAB {
                        idlePane.advanceFocus(backward: event.modifiers & 1 != 0)
                        _ = tw_workspace_editor_focus(window,
                            idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                    } else {
                        idlePane.handleComposerKey(keyEvent)
                        _ = tw_workspace_editor_focus(window,
                            idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                    }
                }
                return true
            }
            if event.kind == 41 || event.kind == 42 || event.kind == 43 {
                guard let pane = activePane else { return true }
                switch event.kind {
                case 41: pane.chrome.handleMenu(event, window: window)
                case 42:
                    _ = pane.chrome.pressSessionActions()
                default:
                    var identityEvent = event
                    let identity = String(validatingCString: tw_event_text(&identityEvent)) ?? ""
                    pane.chrome.chooseMenuRow(Int(event.key), identity: identity)
                }
                if pane.chrome.takeMenuToggleRequest() {
                    focusSidebar(false)
                    pane.chrome.toggleMenu(window: window, paneWidth: terminalWidth)
                }
                if let command = pane.chrome.takeMenuCommand() {
                    invokeSessionMenuCommand(command)
                    pane.chrome.dismissMenu(window: window)
                }
                drainOpenInRequests(pane)
                dirty = true
                return true
            }
            if event.kind == 14, activePane == nil {
                idlePane?.pasteClipboard(wakeIdentity: tw_worker_wake_identity(window))
                return true
            }
            if event.kind == 2 { focusSidebar(true) }
            if event.kind == 15 && event.action == 1 { focusSidebar(false) }
            if event.kind == 39 || event.kind == 40 {
                if event.kind == 40, let dormant = activePane as? WorkspaceDormantPane {
                    _ = dormant.pressAction()
                    return true
                }
                guard activePane == nil, let idlePane else { return true }
                if event.kind == 39 {
                    if event.action == 1 { focusSidebar(false) }
                    idlePane.handle(event)
                    if idlePane.isComposing {
                        _ = tw_workspace_editor_focus(window,
                            idlePane.editorHasFocus || idlePane.hasOpenComposerChoice ? 1 : 0)
                    }
                } else {
                    let pressed = idlePane.pressAction()
                    trace("composer.action pressed=\(pressed) submit=\(composerSubmitRequested) native=\(composerUsesNativeUI) selection=\(pendingSelection != nil) import=\(pendingFolderImport != nil)")
                }
                return true
            }
            if event.kind == 37 || event.kind == 38 {
                if event.kind == 37 {
                    if event.action == 1 { focusSidebar(false) }
                    activePane?.chrome.handleHeader(event)
                } else {
                    _ = activePane?.chrome.pressPageTitle()
                }
                if let pane = activePane, pane.chrome.takeMenuToggleRequest() {
                    focusSidebar(false)
                    pane.chrome.toggleMenu(window: window, paneWidth: terminalWidth)
                    dirty = true
                }
                if let pane = activePane { drainOpenInRequests(pane) }
                if let target = pageReveal.target {
                    pageReveal.target = nil
                    guard let projectIndex = projectIndexes[target.projectID],
                          projects.indices.contains(projectIndex) else { return true }
                    selected = projectIndex
                    if target.kind != .project {
                        outline.expandItem(NavigatorOutlineItem(projectID: target.projectID,
                            projectIndex: projectIndex))
                    }
                    inlineSelection = target
                    savedPicker = nil
                    accountPicker = nil
                    actions = nil
                    outlineScrollSelection = true
                    focusSidebar(true)
                    dirty = true
                }
                return true
            }
            guard [6, 7, 14, 15, 16, 17, 18, 19].contains(event.kind) else { return false }
            activePane?.handle(event, window: window)
            if activePane is WorkspaceDormantPane { dirty = true }
            return true
        }
        @MainActor func activate(_ session: GraphicalTerminal, pageName: String,
                      pageIdentity: String, pageIcon: NSImage? = nil,
                      pageTarget: NavigatorOutlineItem) throws {
            let pane = WorkspaceTerminalPane(session, pageName: pageName,
                pageIdentity: pageIdentity, icon: pageIcon,
                showsSessionActions: pageTarget.kind == .agent && pageTarget.childIndex >= 0,
                onReveal: { pageReveal.target = pageTarget })
            try activatePane(pane, pageTarget: pageTarget)
        }
        func projectTerminalPage(_ session: GraphicalTerminal, project: ProjectSnapshot,
                                 projectIndex: Int) -> (name: String, target: NavigatorOutlineItem) {
            guard let page = session.terminalPage else {
                return ("Terminal", NavigatorOutlineItem(projectID: project.id, projectIndex: projectIndex))
            }
            let childIndex = project.recentTerminals.firstIndex(where: { $0.id == page.id }) ?? -1
            return (readableNavigatorText(page.title), NavigatorOutlineItem(kind: .terminal,
                projectID: project.id, id: page.id, projectIndex: projectIndex, childIndex: childIndex))
        }
        func activateProjectTerminal(_ session: GraphicalTerminal, project: ProjectSnapshot,
                                     projectIndex: Int) throws {
            let page = projectTerminalPage(session, project: project, projectIndex: projectIndex)
            try activate(session, pageName: page.name, pageIdentity: page.target.id,
                         pageTarget: page.target)
            if page.target.kind == .terminal {
                revealTerminalInOutline(page.target)
            } else {
                pendingTerminalReveal = session
            }
        }
        func revealTerminalInOutline(_ target: NavigatorOutlineItem) {
            inlineSelection = target
            outlineRevealTarget = target
            outlineScrollSelection = true
            dirty = true
        }
        @MainActor func activatePane(_ pane: any WorkspacePane, pageTarget: NavigatorOutlineItem) throws {
            if settingsPane != nil { toggleSettings() }
            // Standalone coordinates become a bounded sidebar when the terminal appears. Clear
            // any held control gesture and hover before those same pixels name another pane.
            contentWindow.cancelPointerGesture()
            hoveredOutlineItem = nil
            rowActionMenuGesture = false
            rowActionMenuEntered = false
            activePane?.focus(false, window: window)
            pendingTerminalReveal = nil
            if !hasSplitPane {
                width += sidebarWidth
            }
            idlePane?.focus(false)
            idlePane = nil
            activePane = pane
            activePane?.setThemeAppearance()
            activePageTarget = pageTarget
            if pageTarget.kind == .agent,
               let index = projectIndexes[pageTarget.projectID], projects.indices.contains(index),
               let row = projects[index].recentAgents.first(where: { $0.id == pageTarget.id }),
               row.attention(at: Date()) == .woke {
                pendingSnoozeAcknowledgements[pageTarget.id] = pageTarget.projectID
            }
            configureOpenInPane()
            tw_workspace_placeholder_mode(window, 0)
            sidebarFocused = false
            contentWindow.makeFirstResponder(nil)
            tw_terminal_mode(window)
            tw_project_navigation(window, 1)
            tw_workspace_mode(window, Int32(sidebarWidth), 0)
            tw_workspace_terminal_top_inset(window,
                Int32(WorkspaceTerminalPane.headerPixelHeight))
            guard tw_workspace_reset_terminal(window) == 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            tw_accessibility_show_terminal(window, "Terminal starting")
            tw_accessibility_terminal_text(window, nil, 0, -1, nil, 0)
            pane.focus(true, window: window)
            tw_title(window, pane.title)
            dirty = true
        }
        @MainActor func activateNative(_ runtime: ProjectSnapshot.SavedRuntime,
                                       projectIndex: Int, childIndex: Int) throws {
            guard let launch, let id = SessionID(uuidString: runtime.id) else {
                throw WindowFailure("Saved conversation identity is invalid.")
            }
            let key = SavedRuntimeKey.agent(runtime.id)
            let target = NavigatorOutlineItem(kind: .agent, projectID: projects[projectIndex].id,
                id: runtime.id, projectIndex: projectIndex, childIndex: childIndex)
            let pane: WorkspaceConversationPane
            if let existing = nativeRuntimes[key] { pane = existing }
            else {
                guard terminals.count + restoredRuntimes.count + nativeRuntimes.count
                        + (composerCreationPending ? 1 : 0) < maximumOpenRuntimes else {
                    throw WindowFailure("The workspace's open-runtime limit was reached.")
                }
                let session = NativeWorkspaceSession(store: launch[0], socket: launch[1], id: id,
                    shell: launch[2], executables: nativeExecutables)
                pane = WorkspaceConversationPane(runtime: session, pageName: readableNavigatorText(runtime.title),
                    icon: ProviderMarks.image(for: runtime.kind, selected: false),
                    onReveal: { pageReveal.target = target })
                pane.onAgentActivityChange = { navigatorRoot.needsDisplay = true }
                pane.onSnoozeWakeReason = { reason in
                    snoozeWakeInbox.record(reason, id: runtime.id,
                                           projectID: target.projectID)
                }
                nativeRuntimes[key] = pane
            }
            try activatePane(pane, pageTarget: target)
        }
        func beginAgent(_ kind: AgentKind, prompt: String?,
                        accountOverride: AccountHandle? = nil,
                        permissionMode: AgentPermissionMode? = nil,
                        model: String? = nil, reasoningEffort: String? = nil,
                        fastMode: Bool? = nil,
                        composerProjectID: String? = nil) throws {
            guard let launch, !projects.isEmpty else { return }
            if let composerProjectID, projectIndexes[composerProjectID] == nil {
                throw WindowFailure("Selected checkout is no longer in the workspace.")
            }
            let targetIndex = composerProjectID.flatMap { projectIndexes[$0] } ?? selected
            guard projects.indices.contains(targetIndex) else { return }
            let executable = kind == .codex ? agentExecutable : claudeExecutable
            guard let executable else { return }
            let accountHandle = accountOverride ?? (kind == .codex ? codexAccount : claudeAccount)
            guard terminals.count + restoredRuntimes.count + nativeRuntimes.count
                    + (composerCreationPending ? 1 : 0) < maximumOpenRuntimes else {
                tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                return
            }
            guard let projectID = ProjectID(uuidString: projects[targetIndex].id) else {
                throw WindowFailure("invalid project identity")
            }
            let id = SessionID()
            let savedID = String(describing: id)
            let session = makeObservedTerminal()
            restoredRuntimes[.agent(savedID)] = session
            pendingAgentProjects[savedID] = projectID
            if prompt != nil {
                pendingComposerRunChoices[savedID] = (
                    AccountID(provider: kind, handle: accountHandle),
                    ComposerNewSessionRunChoice(model: model, reasoningEffort: reasoningEffort)
                )
            }
            session.startAgent(store: launch[0], socket: launch[1], directory: projects[targetIndex].path,
                               shell: launch[2], kind: kind, executable: executable,
                               accountHandle: accountHandle, id: id,
                               width: terminalWidth,
                               height: max(1, height - WorkspaceTerminalPane.headerPixelHeight),
                               prompt: prompt, permissionMode: permissionMode,
                               model: model, reasoningEffort: reasoningEffort,
                               fastMode: fastMode,
                               expectedCheckout: composerProjectID.flatMap {
                                   composerCheckoutCatalog.checkouts[$0]
                               })
            selected = targetIndex
            try activate(session, pageName: kind.displayName, pageIdentity: savedID,
                pageIcon: ProviderMarks.image(for: kind, selected: false),
                pageTarget: NavigatorOutlineItem(kind: .agent,
                    projectID: projects[targetIndex].id, id: savedID,
                    projectIndex: targetIndex, childIndex: -1))
            dirty = true
        }
        func beginNativeAgent(_ choice: (projectID: String, identity: AccountID),
                              prompt: String) {
            guard let launch, !composerCreationPending,
                  let targetIndex = projectIndexes[choice.projectID],
                  projects.indices.contains(targetIndex) else { return }
            guard terminals.count + restoredRuntimes.count + nativeRuntimes.count
                    < maximumOpenRuntimes else {
                tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                return
            }
            guard prompt.utf8.count <= 65_536 else {
                tw_title(window, "Threading composer - brief is too long")
                return
            }
            let request = ComposerNativeCreation.Request(store: launch[0],
                directory: projects[targetIndex].path, kind: choice.identity.provider,
                accountHandle: choice.identity.handle, permissionMode: composerPermissionMode,
                model: composerModel, reasoningEffort: composerEffort,
                fastMode: composerFastMode,
                expectedCheckout: composerCheckoutCatalog.checkouts[choice.projectID],
                id: SessionID())
            let gate = NativeCreationGate()
            pendingNativeCreation = (gate, request, prompt, idlePane)
            composerCreationPending = true
            composerCreationWorker.async {
                gate.finish(Result { try ComposerNativeCreation.create(request) })
            }
            dirty = true
        }
        func finishNativeCreation(_ receipt: ComposerNativeCreation.Receipt,
                                  request: ComposerNativeCreation.Request, prompt: String,
                                  composingPane: WorkspacePlaceholderPane?) throws {
            composerModelLoader.remember(
                ComposerNewSessionRunChoice(model: request.model,
                                            reasoningEffort: request.reasoningEffort),
                for: AccountID(provider: request.kind, handle: request.accountHandle)
            )
            guard let launch, let index = projectIndexes[receipt.projectID.uuidString],
                  projects.indices.contains(index), projects[index].id == receipt.projectID.uuidString else {
                throw WindowFailure("Committed native conversation's project is unavailable in the window.")
            }
            let projectID = receipt.projectID.uuidString
            let savedID = receipt.row.id.uuidString
            var saved = savedAgent(receipt.row)
            saved.usesNativeUI = true
            let selectedSavedID: String?
            if let picker = savedPicker, picker.isAgent, picker.projectIndex == index,
               projects[index].recentAgents.indices.contains(savedSelected) {
                selectedSavedID = projects[index].recentAgents[savedSelected].id
            } else if let inlineSelection, inlineSelection.kind == .agent,
                      inlineSelection.projectID == projectID {
                selectedSavedID = inlineSelection.id
            } else { selectedSavedID = nil }
            let newer = projects[index].recentAgents.lastIndex {
                (publishedAgentCounts[$0.id] ?? 0) > receipt.sessionCount
            }
            let row = newer.map { $0 + 1 } ?? 0
            projects[index].recentAgents.insert(saved, at: row)
            publishedAgentCounts[savedID] = receipt.sessionCount
            projects[index].sessions = max(projects[index].sessions, receipt.sessionCount)
            if projects[index].recentAgents.count > maximumSelectableAgentsPerProject {
                let last = projects[index].recentAgents.count - 1
                let preservesLast = projects[index].recentAgents[last].id == selectedSavedID
                projects[index].recentAgents.remove(at: preservesLast ? last - 1 : last)
            }
            if let selectedSavedID,
               let selectedRow = projects[index].recentAgents.firstIndex(where: { $0.id == selectedSavedID }) {
                savedSelected = selectedRow
            }
            let target = NavigatorOutlineItem(kind: .agent, projectID: projectID,
                id: savedID, projectIndex: index, childIndex: row)
            let session = NativeWorkspaceSession(store: launch[0], socket: launch[1],
                id: request.id, shell: launch[2], executables: nativeExecutables,
                initialPrompt: prompt)
            let pane = WorkspaceConversationPane(runtime: session,
                pageName: readableNavigatorText(saved.title),
                icon: ProviderMarks.image(for: saved.kind, selected: false),
                onReveal: { pageReveal.target = target })
            pane.onAgentActivityChange = { navigatorRoot.needsDisplay = true }
            pane.onSnoozeWakeReason = { reason in
                snoozeWakeInbox.record(reason, id: savedID, projectID: projectID)
            }
            nativeRuntimes[.agent(savedID)] = pane
            outlineNeedsReload = true
            let stillSubmitting = idlePane === composingPane
                && (composerCheckoutProjectID ?? projects[selected].id) == projectID
                && composerAccount == AccountID(provider: request.kind, handle: request.accountHandle)
                && composerUsesNativeUI && idlePane?.composedPrompt == prompt
            if stillSubmitting {
                selected = index
                inlineSelection = target
                outlineRevealTarget = target
                outlineScrollSelection = true
                try activatePane(pane, pageTarget: target)
            }
            print("NATIVE_CREATION_COMMITTED \(savedID) project=\(projectID)")
            fflush(nil)
            dirty = true
        }
        func rememberCommittedComposerChoice(_ receipt: GraphicalTerminal.AgentCreation) {
            guard let (account, choice) = pendingComposerRunChoices.removeValue(
                forKey: receipt.row.id.uuidString) else { return }
            composerModelLoader.remember(choice, for: account)
        }
        func forgetFailedComposerChoice(_ id: String) {
            pendingComposerRunChoices.removeValue(forKey: id)
        }
        func reconcileTerminals() -> Bool {
            let selection: (projectID: String, terminalID: String)?
            if let picker = savedPicker, !picker.isAgent,
               projects.indices.contains(picker.projectIndex),
               projects[picker.projectIndex].recentTerminals.indices.contains(savedSelected) {
                selection = (projects[picker.projectIndex].id,
                             projects[picker.projectIndex].recentTerminals[savedSelected].id)
            } else if let inlineSelection, inlineSelection.kind == .terminal {
                selection = (inlineSelection.projectID, inlineSelection.id)
            } else { selection = nil }
            let changed = reconcileCreatedTerminals(projects: &projects, projectIndexes: projectIndexes,
                                                    runtimes: terminals, preserving: selection)
            // Prepending changes positions, never the selected destination. The selected row
            // keeps a slot even at the 512 cap, including while its durable selection is pending.
            if changed, let selection, let index = projectIndexes[selection.projectID],
               projects.indices.contains(index), projects[index].id == selection.projectID,
               let row = projects[index].recentTerminals.firstIndex(where: { $0.id == selection.terminalID }) {
                savedSelected = row
            }
            if changed, let pane = activePane as? WorkspaceTerminalPane,
               let target = activePageTarget, target.kind == .project,
               let index = projectIndexes[target.projectID],
               terminals[target.projectID] === pane.session {
                let page = projectTerminalPage(pane.session, project: projects[index], projectIndex: index)
                if page.target.kind == .terminal {
                    pane.chrome.updateTerminalPage(name: page.name, identity: page.target.id, window: window,
                        onReveal: { pageReveal.target = page.target })
                    activePageTarget = page.target
                    pendingOpenInMenuPage = nil
                    configureOpenInPane()
                    if pendingTerminalReveal === pane.session {
                        pendingTerminalReveal = nil
                        revealTerminalInOutline(page.target)
                    }
                }
            }
            return changed
        }
        func updateSurface(_ event: TWEvent) throws {
            let nextWidth = max(hasSplitPane ? sidebarWidth + 320 : 320,
                                min(hasSplitPane ? sidebarWidth + 1280 : 1280, Int(event.width)))
            let nextHeight = max(180, min(900, Int(event.height)))
            if nextWidth == width, nextHeight == height {
                // Exposure invalidates the native drawable, not the unchanged row models.
                // The initial frame and every terminal-to-project transition render before
                // this loop waits, so the retained texture already describes the current UI.
                trace("repaint.begin")
                guard tw_repaint(window) == 0 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
                trace("repaint.end")
            } else {
                width = nextWidth
                height = nextHeight
                dirty = true
            }
        }
        if let id = snapshot.restoreAgentID, let launch,
           projects.indices.contains(selected),
           let row = projects[selected].recentAgents.firstIndex(where: { $0.id == id }) {
            let runtime = projects[selected].recentAgents[row]
            let target = NavigatorOutlineItem(kind: .agent, projectID: projects[selected].id,
                id: id, projectIndex: selected, childIndex: row)
            inlineSelection = target
            outlineRevealTarget = target
            if runtime.usesNativeUI {
                try activateNative(runtime, projectIndex: selected, childIndex: row)
            } else {
                let session = makeObservedTerminal()
                restoredRuntimes[.agent(id)] = session
                restoredProjectIDs.insert(projects[selected].id)
                session.attachAgent(store: launch[0], socket: launch[1], sessionID: id)
                try activate(session, pageName: readableNavigatorText(runtime.title),
                    pageIdentity: id, pageIcon: ProviderMarks.image(for: runtime.kind, selected: false),
                    pageTarget: target)
            }
        } else if let id = snapshot.restoreTerminalID, let launch,
                  projects.indices.contains(selected),
                  let row = projects[selected].recentTerminals.firstIndex(where: { $0.id == id }) {
            let session = makeObservedTerminal()
            restoredRuntimes[.terminal(id)] = session
            restoredProjectIDs.insert(projects[selected].id)
            let target = NavigatorOutlineItem(kind: .terminal, projectID: projects[selected].id,
                id: id, projectIndex: selected, childIndex: row)
            inlineSelection = target
            outlineRevealTarget = target
            session.attach(store: launch[0], socket: launch[1], terminalID: id,
                           projectID: projects[selected].id)
            let runtime = projects[selected].recentTerminals[row]
            try activate(session, pageName: readableNavigatorText(runtime.title),
                pageIdentity: id, pageTarget: target)
        }
        while true {
            _ = uiWork.drain()
            if pendingSnoozeScan == nil, Date() >= nextSnoozeScanAttempt {
                startSnoozeScan()
            }
            if pendingSnoozeScan == nil, pendingSnooze == nil,
               pendingSnoozeExpiry == nil, let event = snoozeWakeInbox.take(),
               let index = projectIndexes[event.projectID], projects.indices.contains(index),
               let runtime = projects[index].recentAgents.first(where: { $0.id == event.id }),
               runtime.attention(at: Date()) == .snoozed {
                beginSnooze(event.id, projectID: event.projectID,
                    change: .wake(event.reason, at: event.at))
            }
            if pendingSnoozeScan == nil, pendingSnooze == nil,
               pendingSnoozeExpiry == nil,
               let deadline = nextSnoozeDeadline, Date() >= deadline,
               let launch {
                let now = Date()
                let due = snoozeDeadlines.compactMap { $0.value <= now ? $0.key : nil }
                if !due.isEmpty {
                    let gate = SnoozeExpiryGate()
                    pendingSnoozeExpiry = (due, gate)
                    snoozeWorker.async {
                        gate.finish(Result {
                            try SessionSnoozeAction.expire(store: launch[0], due: due,
                                                           now: now)
                        })
                    }
                }
            }
            if contentWindow.displayRevision != navigatorDisplayRevision { dirty = true }
            if visibleWorkingActivity, !Design.Motion.reducesStatusMotion,
               Date() >= nextActivityFrame { try paintWorkingPatches() }
            if let changes = checkoutHeadMonitor?.takeChanges(), !changes.isEmpty {
                var changedBranch = false
                var needsDiscovery = false
                for (id, reading) in changes {
                    guard projectIndexes[id] != nil else { continue }
                    switch reading {
                    case .unavailable:
                        needsDiscovery = true
                    case .checkout(let checkout):
                        guard let previous = composerCheckoutCatalog.checkouts[id],
                              previous.root == checkout.root,
                              previous.identity == checkout.identity,
                              previous.repositoryIdentity == checkout.repositoryIdentity else {
                            needsDiscovery = true
                            continue
                        }
                        let override: CheckoutBranchDisplay? = previous.branch == checkout.branch
                            ? nil : checkout.branch.map(CheckoutBranchDisplay.named) ?? .detached
                        if checkoutBranchOverrides[id] != override {
                            checkoutBranchOverrides[id] = override
                            changedBranch = true
                            print("CHECKOUT_HEAD_CHANGED id=\(id) branch=\(checkout.branch ?? "(detached)")")
                        }
                    }
                }
                if changedBranch {
                    outlineSource.branchOverrides = checkoutBranchOverrides
                    refreshComposerChoices()
                    dirty = true
                    fflush(nil)
                }
                if needsDiscovery { discoverCheckouts() }
            }
            if let gate = pendingCheckoutDiscovery, let (catalogue, entries) = gate.take() {
                pendingCheckoutDiscovery = nil
                composerCheckoutCatalog = catalogue
                checkoutBranchOverrides.removeAll(keepingCapacity: true)
                outlineSource.branchOverrides = checkoutBranchOverrides
                if entries.isEmpty {
                    checkoutHeadMonitor?.stop()
                    checkoutHeadMonitor = nil
                } else {
                    if checkoutHeadMonitor == nil {
                        checkoutHeadMonitor = LinuxGitHeadMonitor(
                            wakeIdentity: tw_worker_wake_identity(window))
                    }
                    checkoutHeadMonitor?.configure(entries: entries,
                                                   baseline: catalogue.checkouts)
                }
                outlineNeedsReload = true
                refreshComposerChoices()
                if checkoutDiscoveryWanted { discoverCheckouts() }
                dirty = true
            }
            if let gate = pendingOpenInCatalogue, let catalogue = gate.take() {
                pendingOpenInCatalogue = nil
                openInCatalogue = catalogue
                openInIcons.retainAvailable(catalogue)
                configureOpenInPane()
                if let requestedPage = pendingOpenInMenuPage {
                    pendingOpenInMenuPage = nil
                    if let pane = activePane, pane.chrome.pageIdentity == requestedPage {
                        pane.chrome.toggleOpenInMenu(window: window, paneWidth: terminalWidth)
                    }
                }
                dirty = true
            }
            if openInIcons.takeCompleted() {
                configureOpenInPane()
                dirty = true
            }
            if let pending = pendingOpenInLaunch, let result = pending.gate.take() {
                pendingOpenInLaunch = nil
                switch result {
                case .success:
                    if pending.remember {
                        PreferenceStore.shared.set(pending.appID, forKey: openInPreferenceKey)
                        configureOpenInPane()
                    }
                    print("OPEN_IN_OPENED \(pending.appID)")
                case .failure(let error):
                    print("OPEN_IN_REFUSED \(error.localizedDescription)")
                }
                fflush(nil)
                dirty = true
            }
            if let gate = pendingFolderImport, let result = gate.take() {
                pendingFolderImport = nil
                switch result {
                case .success(let imported?):
                    projects = imported.projects
                    composerCheckoutProjectID = nil
                    composerProjectChoices = projects.map { (id: $0.id, name: $0.name) }
                    projectIndexes = Dictionary(uniqueKeysWithValues: projects.enumerated().map { ($0.element.id, $0.offset) })
                    selected = imported.selectedProjectIndex
                    pendingImportedProjectID = projects[selected].id
                    first = 0
                    inlineSelection = nil
                    outlineNeedsReload = true
                    outlineScrollSelection = true
                    dirty = true
                    print("PROJECT_IMPORTED \(projects[selected].path)"); fflush(nil)
                    discoverCheckouts()
                case .success(nil):
                    print("PROJECT_IMPORT_CANCELLED"); fflush(nil)
                case .failure(let error):
                    print("PROJECT_IMPORT_REFUSED \(error)"); fflush(nil)
                    tw_title(window, "Threading experiment - project import failed")
                }
            }
            if let pending = pendingNativeCreation, let result = pending.gate.take() {
                pendingNativeCreation = nil
                composerCreationPending = false
                switch result {
                case .success(let receipt):
                    do {
                        try finishNativeCreation(receipt, request: pending.request,
                                                 prompt: pending.prompt, composingPane: pending.pane)
                    } catch {
                        print("NATIVE_CREATION_MOUNT_REFUSED \(error)"); fflush(nil)
                        tw_title(window, "Threading composer - conversation saved, but could not open")
                    }
                case .failure(let error):
                    print("NATIVE_CREATION_REFUSED \(error)"); fflush(nil)
                    tw_title(window, "Threading composer - could not start conversation")
                }
                dirty = true
            }
            if composerSubmitRequested {
                composerSubmitRequested = false
                if let choice = composerTarget(), let idlePane, idlePane.isComposing,
                   projectIndexes[choice.projectID] != nil {
                    let prompt = idlePane.composedPrompt
                    if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tw_title(window, "Threading composer - write a brief first")
                    } else {
                        let accounts = choice.identity.provider == .codex
                            ? codexAccounts : claudeAccounts
                        if accounts.contains(choice.identity.handle) {
                            if composerUsesNativeUI {
                                beginNativeAgent(choice, prompt: prompt)
                            } else if !composerCreationPending {
                                try beginAgent(choice.identity.provider, prompt: prompt,
                                               accountOverride: choice.identity.handle,
                                               permissionMode: composerPermissionMode,
                                               model: composerModel, reasoningEffort: composerEffort,
                                               fastMode: composerFastMode,
                                               composerProjectID: choice.projectID)
                            }
                        } else {
                            tw_title(window, "Threading composer - account no longer available")
                        }
                    }
                } else {
                    tw_title(window, "Threading composer - selected project changed")
                }
            }
            let selectedComposerProjectID = projects.indices.contains(selected) ? projects[selected].id : ""
            if idlePane != nil, composerDisplayedProjectID != selectedComposerProjectID {
                refreshComposerChoices()
                dirty = true
            }
            idlePane?.setLaunchBlocked(pendingFolderImport != nil || pendingSelection != nil
                || composerCreationPending)
            (activePane as? WorkspaceConversationPane)?.drainAttachments()
            idlePane?.drainAttachments()
            if let activePane {
                if let adopted = activePane.takeInitialViewport() {
                    width = adopted.0 + sidebarWidth
                    height = min(900, adopted.1 + WorkspaceTerminalPane.headerPixelHeight)
                    guard tw_resize(window, Int32(width), Int32(height)) == 0 else {
                        throw WindowFailure(String(cString: tw_error()))
                    }
                    dirty = true
                }
                try activePane.refresh(window: window, width: terminalWidth, height: height,
                                       originX: sidebarWidth, focused: !sidebarFocused)
            } else if let idlePane {
                try idlePane.present(nativeWindow: window, width: terminalWidth,
                                     height: height, originX: sidebarWidth)
            }
            let pickerAccounts = accountPicker == .claude ? claudeAccounts : codexAccounts
            // Consume after import installs its snapshot, and after a pending selection has
            // replayed its committed action. Neither operation may observe shifted row indices.
            if pendingFolderImport == nil, pendingSelection == nil,
               reconcileTerminals() { outlineNeedsReload = true; dirty = true }
            if pendingFolderImport == nil, pendingSelection == nil {
                let selection: (projectID: String, agentID: String)?
                if let picker = savedPicker, picker.isAgent,
                   projects[picker.projectIndex].recentAgents.indices.contains(savedSelected) {
                    selection = (projects[picker.projectIndex].id,
                                 projects[picker.projectIndex].recentAgents[savedSelected].id)
                } else if let inlineSelection, inlineSelection.kind == .agent {
                    selection = (inlineSelection.projectID, inlineSelection.id)
                } else { selection = nil }
                if reconcilePendingAgents(projects: &projects, projectIndexes: projectIndexes,
                                          runtimes: &restoredRuntimes,
                                          pending: &pendingAgentProjects,
                                          publishedCounts: &publishedAgentCounts,
                                          retainedProjects: &restoredProjectIDs, preserving: selection,
                                          onCommitted: rememberCommittedComposerChoice,
                                          onFailed: forgetFailedComposerChoice) {
                    if let selection, let project = projectIndexes[selection.projectID],
                       let row = projects[project].recentAgents.firstIndex(where: { $0.id == selection.agentID }) {
                        savedSelected = row
                    }
                    outlineNeedsReload = true
                    dirty = true
                }
            }
            let enabled = pendingFolderImport == nil && pendingSelection == nil
            if actionsEnabled != enabled { actionsEnabled = enabled; dirty = true }
            let visibleRowHeight = actions == nil && accountPicker == nil
                ? navigatorRowStride : ThemedMenuMetrics.rowHeight
            let count = min(Int(TW_NAVIGATOR_MAX_ROWS),
                max(1, Int((CGFloat(height) / scale - navigatorHeaderHeight - 2) / visibleRowHeight)))
            let projectsMode = actions == nil && accountPicker == nil && savedPicker == nil
            if dirty {
                navigatorRoot.prepareNavigatorFrame(NSRect(x: 0, y: 0,
                    width: CGFloat(navigatorWidth) / scale, height: CGFloat(height) / scale))
                navigatorRoot.setNavigatorOutline(outlineScroll, below: header,
                    visible: projectsMode && !projects.isEmpty)
                setEmptyStateVisible(projectsMode && projects.isEmpty && launch != nil)
            }
            outlineSource.projects = projects
            outlineSource.projectIndexes = projectIndexes
            let sidebarRows = SidebarVisibleRows(outline: outline, projects: projects,
                                                  projectIndexes: projectIndexes)
            func actionMenuIndex(at x: Int32, y: Int32) -> Int? {
                guard let menu = actions, y >= navigatorRowsTop else { return nil }
                let stride = Int32(ThemedMenuMetrics.rowHeight * contentWindow.backingScaleFactor)
                let slot = Int((y - navigatorRowsTop) / stride)
                let index = menu.first + slot
                guard slot >= 0, slot < count, index < menu.commands.count else { return nil }
                guard let row = menuRowPixels(slot, in: navigatorRoot,
                                              scale: contentWindow.backingScaleFactor) else { return nil }
                return x >= row.x && x < row.x + row.width &&
                       y >= row.y && y < row.y + row.height ? index : nil
            }
            if var menu = actions {
                let commands: [HostCommandDescriptor]
                switch menu.kind {
                case .addProject:
                    commands = NavigatorActions.addProjectMenuCommands()
                case .projectActions:
                    commands = NavigatorActions.projectCommands(actionState(for: menu.projectID))
                case .projectCreate:
                    commands = NavigatorActions.projectCreateCommands(actionState(for: menu.projectID))
                case .repositoryCreate:
                    commands = NavigatorActions.repositoryCreateCommands(actionState(for: menu.projectID))
                case .chatProviders:
                    commands = NavigatorActions.chatProviderCommands(actionState(for: menu.projectID))
                }
                if menu.commands != commands { menu.commands = commands; dirty = true }
                menu.selected = max(0, min(menu.commands.count - 1, menu.selected))
                if menu.selected < menu.first { menu.first = menu.selected }
                if menu.selected >= menu.first + count { menu.first = menu.selected - count + 1 }
                actions = menu
            } else if accountPicker != nil {
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
                if outlineNeedsReload {
                    trace("outline.reload.begin")
                    outlineSource.rebuildRepositories(catalogue: composerCheckoutCatalog)
                    var expandedItems = outlineSource.roots.filter {
                        $0.kind == .repository && !collapsedRepositoryIdentities.contains($0.id)
                    }
                    expandedItems += projects.enumerated().compactMap { index, project -> NavigatorOutlineItem? in
                        guard project.isExpanded else { return nil }
                        return NavigatorOutlineItem(projectID: project.id, projectIndex: index)
                    }
                    outline.restoreExpandedItems(expandedItems)
                    trace("outline.reload.end")
                    outlineNeedsReload = false
                }
                // Restoration and explicit shell activation reveal the selected runtime, as on Mac.
                // Apply after the standing projection so the source can resolve a newly admitted child.
                // A collapsed parent is one real disclosure mutation; other branches stay put.
                if let target = outlineRevealTarget {
                    outlineRevealTarget = nil
                    outline.expandItem(NavigatorOutlineItem(projectID: target.projectID,
                        projectIndex: target.projectIndex))
                }
                if let importedID = pendingImportedProjectID,
                   let importedIndex = projectIndexes[importedID],
                   projects.indices.contains(importedIndex),
                   projects[importedIndex].id == importedID {
                    if let repository = outlineSource.repositoryItem(for: importedID),
                       !outline.isItemExpanded(repository) {
                        outline.expandItem(repository)
                    }
                    inlineSelection = NavigatorOutlineItem(projectID: importedID,
                        projectIndex: importedIndex)
                    pendingImportedProjectID = nil
                }
                let selectedIndex = inlineSelection.flatMap { sidebarRows.index(of: $0) }
                    ?? inlineSelection.flatMap {
                        sidebarRows.index(of: NavigatorOutlineItem(projectID: $0.projectID,
                            projectIndex: $0.projectIndex))
                    } ?? sidebarRows.index(of: selected)
                    ?? (projects.indices.contains(selected)
                        ? outlineSource.repositoryItem(for: projects[selected].id)
                            .flatMap { sidebarRows.index(of: $0) } : nil)
                    ?? 0
                inlineSelection = outline.item(atRow: selectedIndex) as? NavigatorOutlineItem
                if let inlineSelection, let current = projectIndexes[inlineSelection.projectID] {
                    selected = current
                }
                if outline.numberOfRows > 0 {
                    trace("outline.selection.begin")
                    outline.selectRowIndexes(IndexSet(integer: selectedIndex),
                                             byExtendingSelection: false)
                    if outlineScrollSelection {
                        outline.scrollRowToVisible(selectedIndex)
                        outlineScrollSelection = false
                    }
                    trace("outline.selection.end")
                }
                first = outline.visibleRowIndexes.first ?? 0
            }
            let selectedInlineIndex = inlineSelection.flatMap { sidebarRows.index(of: $0) }
                ?? sidebarRows.index(of: selected) ?? 0
            let presentationDate = Date()
            if let expiry = nextVisibleAttentionExpiry, presentationDate >= expiry {
                dirty = true
            }
            if dirty {
                nextVisibleAttentionExpiry = nil
                visibleWorkingActivity = false
                workingMarks.removeAll(keepingCapacity: true)
                workingPatches.removeAll(keepingCapacity: true)
                activityPhase = Design.Motion.reducesStatusMotion ? 0 : CGFloat(
                    Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9)
                let width = navigatorWidth
                trace(traceFirstFrame ? "first-frame.begin" : "frame.begin")
                // At most viewport/count row objects, even for a large persisted catalogue.
                let root = navigatorRoot
                root.prepareNavigatorFrame(NSRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale))
                let accent = Design.Surface.selectionFill
                let selectedInk = LinuxTheme.neutralInk(on: accent, dark: LinuxTheme.isDark)
                var menuRows: [NSView] = []
                let end: Int
                if let menu = actions {
                    end = min(menu.commands.count, menu.first + count)
                    let entries: [ThemedMenuEntry] = menu.commands.map { command in
                        .item(ThemedMenuItem(
                            title: readableNavigatorText(command.title),
                            help: command.availability.disabledReason,
                            representedValue: command.id,
                            isEnabled: command.availability.isAvailable
                        ))
                    }
                    let plan = ThemedMenuRowPlan(entries: entries)
                    retainedMenuRows.prepare(menu: "actions:\(menu.kind)", entries: entries,
                                             visible: menu.first..<end)
                    var top = navigatorHeaderHeight + 2
                    for index in menu.first..<end {
                        guard let row = retainedMenuRows.row(at: index, plan: plan) else {
                            throw WindowFailure("host command was not a menu item")
                        }
                        let rowHeight = plan.heights[index]
                        row.frame = NSRect(x: 6, y: root.bounds.height - top - rowHeight,
                                           width: root.bounds.width - 12, height: rowHeight)
                        row.isKeyboardHighlighted = index == menu.selected
                        row.onChoose = { entry, _ in activatedMenuEntry = entry }
                        row.onHighlight = { entry in
                            guard var current = actions, current.commands.indices.contains(entry),
                                  current.selected != entry else { return }
                            current.selected = entry
                            actions = current
                            dirty = true
                        }
                        menuRows.append(row)
                        top += rowHeight
                    }
                } else if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    end = min(pickerAccounts.count, accountFirst + count)
                    // Discovery admits at most 32 handles. Measure the common check column
                    // once, then materialize only the visible page as native menu rows.
                    let entries: [ThemedMenuEntry] = pickerAccounts.map { handle in
                        let name = handle.isStandard ? "Default \(provider)" :
                            "\(provider) [\(readableNavigatorText(handle.name))]"
                        return .item(ThemedMenuItem(title: name, representedValue: handle,
                                                    isSelected: handle == active))
                    }
                    let plan = ThemedMenuRowPlan(entries: entries)
                    retainedMenuRows.prepare(menu: "accounts:\(provider)", entries: entries,
                                             visible: accountFirst..<end)
                    var top = navigatorHeaderHeight + 2
                    for index in accountFirst..<end {
                        guard let row = retainedMenuRows.row(at: index, plan: plan) else {
                            throw WindowFailure("account choice was not a menu item")
                        }
                        let rowHeight = plan.heights[index]
                        row.frame = NSRect(x: 6, y: root.bounds.height - top - rowHeight,
                                           width: root.bounds.width - 12, height: rowHeight)
                        row.isKeyboardHighlighted = index == accountSelected
                        row.onChoose = { _, item in
                            activatedAccountHandle = item.representedValue as? AccountHandle
                        }
                        row.onHighlight = { entry in
                            guard pickerAccounts.indices.contains(entry), accountSelected != entry
                            else { return }
                            accountSelected = entry
                            dirty = true
                        }
                        menuRows.append(row)
                        top += rowHeight
                    }
                } else if let savedPicker {
                    retainedMenuRows.reset()
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    end = min(saved.count, savedFirst + count)
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let retained = hasActiveRuntime(key, projectID: project.id)
                        if savedPicker.isAgent {
                            let mark = ProviderMarks.image(for: runtime.kind, selected: index == savedSelected)
                            let activity = nativeRuntimes[.agent(runtime.id)]?.activity ?? .idle
                            if activity.showsWorkingMark { visibleWorkingActivity = true }
                            if runtime.attention(at: presentationDate) == .snoozed,
                               let expiry = runtime.snoozedUntil {
                                nextVisibleAttentionExpiry = min(nextVisibleAttentionExpiry ?? expiry, expiry)
                            }
                            addSavedAgentRow(runtime, retained: retained, at: presentationDate,
                                index: index - savedFirst,
                                width: width, height: height, accent: accent,
                                selected: index == savedSelected, selectedInk: selectedInk, root: root,
                                image: mark, activity: activity, activityPhase: activityPhase)
                            if let mark = root.mountedRow(at: index - savedFirst)?.productionWorkingMark {
                                workingMarks.append(mark)
                            }
                        } else {
                            addSavedTerminalRow(runtime, running: retained, index: index - savedFirst,
                                width: width, height: height, accent: accent,
                                selected: index == savedSelected, selectedInk: selectedInk, root: root)
                        }
                    }
                } else {
                    retainedMenuRows.reset()
                    if projects.isEmpty, launch != nil {
                        end = 0
                    } else {
                        // NSOutlineView owns and recycles the viewport's production row views.
                        end = (outline.visibleRowIndexes.last.map { $0 + 1 }) ?? first
                        trace("outline.configure.begin")
                        for index in outline.visibleRowIndexes {
                            guard let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                                  let cell = outline.view(atColumn: 0, row: index,
                                    makeIfNecessary: false) as? Specimen.Row else { continue }
                            configureOutlineRow(cell, item: item, frame: outline.rect(ofRow: index))
                            if let chrome = outline.rowView(atRow: index,
                                makeIfNecessary: false) as? SidebarHoverRowView {
                                configureOutlineChrome(chrome, in: outline)
                            }
                        }
                        trace("outline.configure.end")
                    }
                }
                var floatingMenuRows: [ThemedMenuRowView] = []
                var floatingMenuViews: [NSView] = []
                sessionMenuVisibleEntries.removeAll(keepingCapacity: true)
                if var menu = sessionMenu {
                    root.layoutSubtreeIfNeeded()
                    let anchor = outline.visibleRowIndexes.compactMap { index -> NSRect? in
                        guard let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                              item.kind == .agent, item.id == menu.sessionID,
                              item.projectID == menu.projectID,
                              let row = outline.view(atColumn: 0, row: index,
                                  makeIfNecessary: false) as? Specimen.Row else { return nil }
                        return row.sessionActionAnchor(in: root)
                    }.first
                    if let anchor {
                        let entries = menu.entries
                        let plan = ThemedMenuRowPlan(entries: entries)
                        let menuWidth = min(root.bounds.width - 8,
                            max(190, ThemedMenuMetrics.width(for: entries, minimum: 190,
                                selectedEntryIndex: menu.selected)))
                        let maximumHeight = max(64, root.bounds.height - 8)
                        func visibleEnd(start: Int) -> Int {
                            var height: CGFloat = 12
                            var end = start
                            while end < entries.count,
                                  height + plan.heights[end] <= maximumHeight {
                                height += plan.heights[end]
                                end += 1
                            }
                            return max(start + 1, end)
                        }
                        var firstVisible = min(menu.firstVisible, menu.selected)
                        while menu.selected >= visibleEnd(start: firstVisible),
                              firstVisible < entries.count - 1 {
                            firstVisible += 1
                        }
                        let visible = firstVisible..<visibleEnd(start: firstVisible)
                        if menu.firstVisible != firstVisible {
                            menu.firstVisible = firstVisible
                            sessionMenu = menu
                        }
                        let menuHeight = visible.reduce(CGFloat(12)) {
                            $0 + plan.heights[$1]
                        }
                        let x = max(4, min(root.bounds.width - menuWidth - 4, anchor.minX))
                        let below = anchor.minY - menuHeight - 4
                        let y = below >= 4 ? below : min(root.bounds.height - menuHeight - 4,
                            anchor.maxY + 4)
                        sessionMenuFrame = NSRect(x: x, y: y, width: menuWidth,
                            height: menuHeight)
                        retainedSessionMenuRows.prepare(
                            menu: "session:\(menu.sessionID):\(menu.page)",
                            entries: entries, visible: visible)
                        var top: CGFloat = 6
                        var separatorCount = 0
                        for entry in visible {
                            let rowHeight = plan.heights[entry]
                            if case .separator = entries[entry] {
                                if separatorCount == sessionMenuSeparators.count {
                                    let separator = SeparatorView()
                                    separator.translatesAutoresizingMaskIntoConstraints = true
                                    sessionMenuSeparators.append(separator)
                                }
                                let separator = sessionMenuSeparators[separatorCount]
                                separatorCount += 1
                                let inset = ThemedMenuMetrics.contentInset
                                separator.frame = NSRect(
                                    x: 6 + inset,
                                    y: menuHeight - top - rowHeight / 2 - Design.Radius.border / 2,
                                    width: max(0, menuWidth - 12 - inset * 2),
                                    height: Design.Radius.border)
                                floatingMenuViews.append(separator)
                            } else if let row = retainedSessionMenuRows.row(at: entry, plan: plan) {
                                row.frame = NSRect(x: 6, y: menuHeight - top - rowHeight,
                                    width: menuWidth - 12, height: rowHeight)
                                row.isKeyboardHighlighted = entry == menu.selected
                                row.onChoose = { chosen, _ in activatedSessionMenuEntry = chosen }
                                row.onHighlight = { highlighted in
                                    guard var current = sessionMenu,
                                          current.entries.indices.contains(highlighted),
                                          current.selected != highlighted else { return }
                                    current.selected = highlighted
                                    sessionMenu = current
                                    dirty = true
                                }
                                floatingMenuRows.append(row)
                                floatingMenuViews.append(row)
                                sessionMenuVisibleEntries.append(entry)
                            }
                            top += rowHeight
                        }
                    } else {
                        dismissSessionMenu()
                    }
                }
                root.title = ""
                if addProjectButton.isHidden != (launch == nil) {
                    addProjectButton.isHidden = launch == nil
                }
                addProjectButton.isEnabled = actionsEnabled && accountPicker == nil && savedPicker == nil
                if actionsButton.isHidden != (launch == nil) {
                    actionsButton.isHidden = launch == nil
                }
                actionsButton.isEnabled = actionsEnabled
                actionsButton.isSelected = actions != nil
                actionsButton.setAccessibilityTitle(actions == nil ? "Actions" : "Close actions")
                trace("header.layout.begin")
                publishHeaderGeometry()
                trace("header.layout.end")
                let titleRect = headerPixels(headerBrand)
                let addRect = headerPixels(addProjectButton)
                let actionsRect = headerPixels(actionsButton)
                trace("header bandHeight=\(navigatorHeaderHeight) title=\(titleRect) add=\(addRect) actions=\(actionsRect)")
                let mountStarted = DispatchTime.now().uptimeNanoseconds
                root.finishNavigatorRows()
                let scratchpadBoundary = actions.flatMap { $0.kind == .addProject ? 2 - $0.first : nil }
                if sessionMenu != nil {
                    root.mountFloatingMenu(sessionMenuSurface, frame: sessionMenuFrame,
                        rows: floatingMenuViews)
                } else {
                    root.mountMenuRows(menuRows, separatorBeforeRow: scratchpadBoundary)
                }
                let focusedSlot: Int
                if let menu = actions { focusedSlot = menu.selected - menu.first }
                else if accountPicker != nil { focusedSlot = accountSelected - accountFirst }
                else if savedPicker != nil { focusedSlot = savedSelected - savedFirst }
                else { focusedSlot = selectedInlineIndex - first }
                let focusedView: NSView?
                if let menu = sessionMenu {
                    focusedView = floatingMenuRows.first { $0.entryIndex == menu.selected }
                } else if projectsMode && !projects.isEmpty {
                    focusedView = outline.view(atColumn: 0, row: selectedInlineIndex,
                                               makeIfNecessary: false)
                } else {
                    focusedView = root.mountedRow(at: focusedSlot)
                }
                contentWindow.makeFirstResponder(sidebarFocused && accountPicker == nil
                    ? focusedView : nil)
                let mountMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - mountStarted) / 1_000_000
                trace("raster.begin")
                let bitmap = Bitmap(width: navigatorWidth, height: height,
                                    background: LinuxTheme.components("surface"))
                let context = NSGraphicsContext(bitmap: bitmap, scale: scale)
                NSGraphicsContext.current = context
                let renderStarted = DispatchTime.now().uptimeNanoseconds
                _ = root.layoutSubtreeIfNeeded()
                let markRegions = workingMarks.compactMap { mark ->
                    (mark: ThemedSessionActivityMark, x: Int, y: Int, width: Int, height: Int)? in
                    let rect = mark.convert(mark.bounds, to: root)
                    let x = Int((rect.minX * scale).rounded())
                    let y = height - Int((rect.maxY * scale).rounded())
                    let patchWidth = Int((rect.width * scale).rounded())
                    let patchHeight = Int((rect.height * scale).rounded())
                    guard x >= 0, y >= 0, patchWidth > 0, patchHeight > 0,
                          x + patchWidth <= navigatorWidth, y + patchHeight <= height else {
                        return nil
                    }
                    mark.isHidden = true
                    return (mark, x, y, patchWidth, patchHeight)
                }
                root.render(in: context)
                for region in markRegions {
                    region.mark.isHidden = false
                    var background: [UInt8] = []
                    background.reserveCapacity(region.width * region.height * 4)
                    for row in 0..<region.height {
                        let start = ((region.y + row) * navigatorWidth + region.x) * 4
                        background.append(contentsOf: bitmap.pixels[start..<(start + region.width * 4)])
                    }
                    workingPatches.append((region.mark, region.x, region.y,
                                           region.width, region.height, background))
                }
                visibleWorkingActivity = !workingPatches.isEmpty
                _ = root.takeProjectControlVisualChange()
                addProjectControlVisualChanged = false
                actionsControlVisualChanged = false
                let renderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - renderStarted) / 1_000_000
                NSGraphicsContext.current = nil
                trace("raster.end")
                print("NAVIGATOR_TEXT mounted=0 mountMs=\(mountMilliseconds) renderMs=\(renderMilliseconds)")
                trace("present.begin")
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    hasSplitPane
                        ? tw_present_pane(window, $0.baseAddress,
                                          Int32(navigatorWidth), Int32(height), 1)
                        : tw_present(window, $0.baseAddress, Int32(width), Int32(height))
                }
                trace("present.end")
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                if visibleWorkingActivity {
                    try paintWorkingPatches()
                }
                trace("accessibility-title.begin")
                if let menu = sessionMenu {
                    let rows = floatingMenuRows.filter { menu.command(at: $0.entryIndex) != nil }
                    let bounds = sessionMenuSurface.convert(sessionMenuSurface.bounds, to: root)
                    let listX = Int32(bounds.minX * scale)
                    let listY = Int32((root.bounds.height - bounds.maxY) * scale)
                    tw_accessibility_begin_list(window, "Session actions", 0,
                        Int32(rows.count), 1, listX, listY,
                        Int32(bounds.width * scale), Int32(bounds.height * scale))
                    for row in rows {
                        guard let command = menu.command(at: row.entryIndex),
                              let title = menu.entries[row.entryIndex].item?.title else { continue }
                        let rect = row.convert(row.bounds, to: root)
                        let x = Int32(rect.minX * scale)
                        let y = Int32((root.bounds.height - rect.maxY) * scale)
                        let result = command.rawValue.withCString { identifier in
                            title.withCString { label in
                                tw_accessibility_add_action_row(window, identifier, label,
                                    row.entryIndex == menu.selected ? 1 : 0, 1,
                                    x, y, Int32(rect.width * scale), Int32(rect.height * scale))
                            }
                        }
                        guard result == 0 else {
                            throw WindowFailure("accessible session action exceeds its bound")
                        }
                    }
                    tw_accessibility_end_list(window)
                } else if let menu = actions {
                    let listY = Int32(navigatorHeaderHeight * scale)
                    let listTitle: String
                    switch menu.kind {
                    case .addProject: listTitle = "Add Project"
                    case .projectActions: listTitle = "Project actions"
                    case .projectCreate: listTitle = "New in Project"
                    case .repositoryCreate: listTitle = "New in Repository"
                    case .chatProviders: listTitle = "New Chat providers"
                    }
                    tw_accessibility_begin_list(window,
                        listTitle, Int32(menu.first),
                        Int32(menu.commands.count), 1, 0, listY, Int32(navigatorWidth), Int32(height) - listY)
                    for index in menu.first..<end {
                        let command = menu.commands[index]
                        let label = command.title + (command.availability.disabledReason.map { ". " + $0 } ?? "")
                        guard let bounds = menuRowPixels(index - menu.first, in: root,
                                                         scale: contentWindow.backingScaleFactor) else {
                            throw WindowFailure("accessible menu command has no mounted row")
                        }
                        let result = command.id.withCString { identifier in
                            label.withCString { name in
                                tw_accessibility_add_action_row(window, identifier, name,
                                    index == menu.selected ? 1 : 0, command.availability.isAvailable ? 1 : 0,
                                    bounds.x, bounds.y, bounds.width, bounds.height)
                            }
                        }
                        guard result == 0 else { throw WindowFailure("native action row exceeds its bound") }
                    }
                    tw_accessibility_end_list(window)
                    let target = menu.projectID.flatMap { projectIndexes[$0.uuidString] }
                    let targetPath = target.flatMap { projects.indices.contains($0) ? projects[$0].path : nil }
                        ?? "No project"
                    switch menu.kind {
                    case .addProject: setNavigatorTitle("Threading Add Project")
                    case .projectActions: setNavigatorTitle("Threading actions - " + targetPath)
                    case .projectCreate: setNavigatorTitle("Threading new in - " + targetPath)
                    case .repositoryCreate: setNavigatorTitle("Threading new in - " + targetPath)
                    case .chatProviders: setNavigatorTitle("Threading new chat - " + targetPath)
                    }
                    let frameLabel: String
                    switch menu.kind {
                    case .addProject: frameLabel = "ADD_PROJECT_MENU_FRAME"
                    case .projectActions: frameLabel = "ACTIONS_FRAME"
                    case .projectCreate: frameLabel = "PROJECT_CREATE_MENU_FRAME"
                    case .repositoryCreate: frameLabel = "REPOSITORY_CREATE_MENU_FRAME"
                    case .chatProviders: frameLabel = "CHAT_PROVIDER_MENU_FRAME"
                    }
                    print("\(frameLabel) mounted=\(end - menu.first) selected=\(menu.commands[menu.selected].id) total=\(menu.commands.count)")
                } else if let accountPicker {
                    let provider = accountPicker == .claude ? "Claude" : "Codex"
                    let active = accountPicker == .claude ? claudeAccount : codexAccount
                    let listY = Int32(navigatorHeaderHeight * scale)
                    tw_accessibility_begin_list(window, "\(provider) accounts", Int32(accountFirst),
                                                Int32(pickerAccounts.count), 1, 0, listY,
                                                Int32(navigatorWidth), Int32(height) - listY)
                    for index in accountFirst..<end {
                        let handle = pickerAccounts[index]
                        let name = handle.isStandard ? "Default \(provider)" : "\(provider) \(handle.name)"
                        let label = name + (handle == active ? " active" : "")
                        guard let bounds = menuRowPixels(index - accountFirst, in: root,
                                                         scale: contentWindow.backingScaleFactor)
                        else { throw WindowFailure("accessible account has no mounted row") }
                        let result = handle.name.withCString { identifier in
                            label.withCString { text in
                                tw_accessibility_add_row(window, identifier, text,
                                    index == accountSelected ? 1 : 0,
                                    bounds.x, bounds.y, bounds.width, bounds.height)
                            }
                        }
                        guard result == 0 else {
                            throw WindowFailure("native account row exceeds its bound")
                        }
                    }
                    tw_accessibility_end_list(window)
                    setNavigatorTitle("Threading \(provider) accounts - \(projects[selected].path)")
                    print("ACCOUNT_PICKER_FRAME \(width)x\(height) provider=\(provider.lowercased()) mounted=\(end - accountFirst) selected=\(pickerAccounts[accountSelected].name) total=\(pickerAccounts.count)")
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let saved = savedPicker.isAgent ? project.recentAgents : project.recentTerminals
                    let total = savedPicker.isAgent ? project.sessions : project.terminalCount
                    let listName = "Saved \(savedPicker.isAgent ? "agents" : "terminals") (\(saved.count) of \(total))"
                    let listY = Int32(navigatorHeaderHeight * scale)
                    listName.withCString {
                        tw_accessibility_begin_list(window, $0, Int32(savedFirst), Int32(saved.count),
                                                    launch == nil ? 0 : 1, 0, listY,
                                                    Int32(navigatorWidth), Int32(height) - listY)
                    }
                    for index in savedFirst..<end {
                        let runtime = saved[index]
                        let key: SavedRuntimeKey = savedPicker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                        let retained = hasActiveRuntime(key, projectID: project.id)
                        let provider = runtime.kind.map { "[\($0.displayName)] " } ?? ""
                        let account = runtime.account.map { " [\($0)]" } ?? ""
                        let activity = savedPicker.isAgent
                            ? nativeRuntimes[.agent(runtime.id)]?.activity ?? .idle : .idle
                        let activityText: String = switch activity {
                            case .idle: ""
                            case .loading: " loading"
                            case .working: " working"
                            case .readyWithBackgroundWork: " ready for input; background work running"
                            case .awaitingUser: " waiting for an answer"
                            }
                        let title = boundedAccessibilityLabel(runtime.title,
                            maximumBytes: 400 - provider.utf8.count - account.utf8.count
                                - activityText.utf8.count)
                        let label = "\(provider)\(title)\(account) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                            + (runtime.attentionTitle(at: presentationDate).map { " " + $0 } ?? "")
                            + activityText
                        try publishAccessibleRow(window, id: runtime.id, label: label,
                                                 selected: index == savedSelected,
                                                 visibleIndex: index - savedFirst, width: width, height: height)
                    }
                    tw_accessibility_end_list(window)
                    setNavigatorTitle("Threading \(savedPicker.isAgent ? "agents" : "terminals") - \(project.path)")
                    let selectedID = saved.isEmpty ? "none" : saved[savedSelected].id
                    let capped = total > saved.count ? 1 : 0
                    let label = savedPicker.isAgent ? "AGENT_PICKER_FRAME" : "TERMINAL_PICKER_FRAME"
                    print("\(label) \(width)x\(height) mounted=\(end - savedFirst) selected=\(selectedID) total=\(total) capped=\(capped) dark=\(LinuxTheme.isDark)")
                } else {
                    let listY = Int32(navigatorHeaderHeight * scale)
                    tw_accessibility_begin_list(window, "Projects", Int32(first),
                                                Int32(sidebarRows.totalCount),
                                                launch == nil ? 0 : 1, 0, listY,
                                                Int32(navigatorWidth), Int32(height) - listY)
                    do {
                        for index in first..<end {
                            guard let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                                  let row = item.resolvedRow(in: projects, indexes: projectIndexes)
                            else { continue }
                            let isSelected = index == selectedInlineIndex
                            switch row {
                            case .repository(let identity, _, let representativeID):
                                let name = outlineSource.repositoryGroups[identity]?.name ?? identity
                                let rowID = repositoryAccessibilityID(identity)
                                let label = boundedAccessibilityLabel(name) + " repository"
                                if launch != nil, !representativeID.isEmpty,
                                   let bounds = outlineRowPixels(index),
                                   let create = projectControlPixels(index, create: true),
                                   let action = projectControlPixels(index, create: false) {
                                    let result = rowID.withCString { identifier in
                                        representativeID.withCString { target in
                                            label.withCString { title in
                                                tw_accessibility_add_repository_row(window,
                                                    identifier, target, title, isSelected ? 1 : 0,
                                                    bounds.x, bounds.y, bounds.width, bounds.height,
                                                    create.x, create.y, create.width, create.height,
                                                    action.x, action.y, action.width, action.height,
                                                    actionsEnabled ? 1 : 0)
                                            }
                                        }
                                    }
                                    guard result == 0 else {
                                        throw WindowFailure("native repository controls exceed their bound")
                                    }
                                } else {
                                    try publishOutlineAccessibleRow(index, id: rowID,
                                        label: label, selected: isSelected)
                                }
                            case .project(let projectIndex, _):
                                let project = projects[projectIndex]
                                let retained = terminals[project.id] != nil || restoredProjectIDs.contains(project.id)
                                let title = outlineSource.repositoryIdentityByProject[project.id] == nil
                                    ? project.name : (outlineSource.branch(for: project.id)
                                        ?? project.name) + " [\(project.path)]"
                                let unavailable = outlineSource.repositoryIdentityByProject[project.id] != nil
                                    && outlineSource.checkoutCatalog.checkouts[project.id] == nil
                                let label = "\(boundedAccessibilityLabel(title)) [\(project.sessions) agents, \(project.terminalCount) terminals]\(retained ? " retained" : "")"
                                    + (unavailable ? " Checkout unavailable at this path" : "")
                                if launch == nil {
                                    try publishOutlineAccessibleRow(index, id: project.id,
                                        label: label, selected: isSelected)
                                } else {
                                    guard let bounds = outlineRowPixels(index) else {
                                        throw WindowFailure("mounted project row has no visible layout")
                                    }
                                    if let create = projectControlPixels(index, create: true),
                                       let action = projectControlPixels(index, create: false) {
                                        let result = project.id.withCString { identifier in
                                            label.withCString { name in
                                                tw_accessibility_add_project_row(window, identifier, name,
                                                    isSelected ? 1 : 0,
                                                    bounds.x, bounds.y, bounds.width, bounds.height,
                                                    create.x, create.y, create.width, create.height,
                                                    action.x, action.y, action.width, action.height,
                                                    actionsEnabled ? 1 : 0)
                                            }
                                        }
                                        guard result == 0 else {
                                            throw WindowFailure("native project action row exceeds its bound")
                                        }
                                    } else if bounds.height < Int32(SidebarDefaults.projectCompactRowHeight *
                                        contentWindow.backingScaleFactor) {
                                        // The clipped edge can show a sliver of the row before
                                        // either control is visible. Keep the row accessible.
                                        try publishOutlineAccessibleRow(index, id: project.id,
                                            label: label, selected: isSelected)
                                    } else {
                                        throw WindowFailure("mounted project controls have no layout")
                                    }
                                }
                            case .agent(let projectIndex, let childIndex, _):
                                let project = projects[projectIndex]
                                let runtime = project.recentAgents[childIndex]
                                let retained = hasActiveRuntime(.agent(runtime.id), projectID: project.id)
                                let provider = runtime.kind.map { "[\($0.displayName)] " } ?? ""
                                let account = runtime.account.map { " [\($0)]" } ?? ""
                                let activityText: String = switch nativeRuntimes[.agent(runtime.id)]?.activity ?? .idle {
                                case .idle: ""
                                case .loading: " loading"
                                case .working: " working"
                                case .readyWithBackgroundWork: " ready for input; background work running"
                                case .awaitingUser: " waiting for an answer"
                                }
                                let title = boundedAccessibilityLabel(runtime.title,
                                    maximumBytes: 400 - provider.utf8.count - account.utf8.count
                                        - activityText.utf8.count)
                                let label = "\(provider)\(title)\(account) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                                    + (runtime.attentionTitle(at: presentationDate).map { " " + $0 } ?? "")
                                    + activityText
                                try publishOutlineAccessibleRow(index, id: runtime.id,
                                    label: label, selected: isSelected)
                            case .terminal(let projectIndex, let childIndex, _):
                                let project = projects[projectIndex]
                                let runtime = project.recentTerminals[childIndex]
                                let retained = hasActiveRuntime(.terminal(runtime.id), projectID: project.id)
                                let label = "\(runtime.identityTitle) [\(String(runtime.id.prefix(8)))]\(retained ? " retained" : "")"
                                try publishOutlineAccessibleRow(index, id: runtime.id,
                                    label: label, selected: isSelected)
                            }
                        }
                    }
                    tw_accessibility_end_list(window)
                    if projects.isEmpty, launch != nil {
                        let message = SidebarEmptyState.title + ". " + SidebarEmptyState.detail
                        message.withCString { tw_accessibility_empty_list_message(window, $0) }
                    }
                    let title = projects.isEmpty ? "Threading experiment - empty store" : "Threading experiment - \(projects[selected].path)"
                    setNavigatorTitle(title)
                    print("FRAME \(width)x\(height) mounted=\(end - first) selected=\(projects.isEmpty ? "none" : projects[selected].id) total=\(sidebarRows.totalCount)")
                    if !projects.isEmpty {
                        print("OUTLINE_FRAME total=\(outline.numberOfRows) first=\(first) visible=\(end - first) mounted=\(outline.mountedViewCount) reusable=\(outline.reusableViewCount) scrollY=\(outlineScroll.contentView.bounds.minY)")
                    }
                }
                trace("accessibility-title.end")
                traceFirstFrame = false
                fflush(nil)
                navigatorDisplayRevision = contentWindow.displayRevision
                dirty = false
            }
            var event = TWEvent()
            var selectionWasCommitted = false
            var pointerActivatedRow = false
            if let pending = pendingArchive, let result = pending.gate.take() {
                pendingArchive = nil
                switch result {
                case .success:
                    let key = SavedRuntimeKey.agent(pending.id)
                    if let index = projectIndexes[pending.projectID], projects.indices.contains(index),
                       let row = projects[index].recentAgents.firstIndex(where: { $0.id == pending.id }) {
                        projects[index].recentAgents.remove(at: row)
                        projects[index].sessions = max(0, projects[index].sessions - 1)
                        if inlineSelection?.id == pending.id {
                            inlineSelection = NavigatorOutlineItem(projectID: pending.projectID,
                                projectIndex: index)
                            outlineScrollSelection = true
                        }
                        outlineNeedsReload = true
                    }
                    restoredRuntimes.removeValue(forKey: key)?.stop()
                    nativeRuntimes.removeValue(forKey: key)?.runtime.stop()
                    if activePageTarget?.id == pending.id {
                        activePane?.focus(false, window: window)
                        activePane = nil
                        activePageTarget = nil
                        idlePane = WorkspacePlaceholderPane(onSubmit: {
                            guard pendingFolderImport == nil, pendingSelection == nil else { return }
                            composerSubmitRequested = true
                        })
                        idlePane?.setThemeAppearance()
                        tw_workspace_terminal_top_inset(window, 0)
                        tw_workspace_mode(window, Int32(sidebarWidth), 1)
                        tw_workspace_placeholder_mode(window, 1)
                        focusSidebar(true)
                    }
                    print("SESSION_ARCHIVED id=\(pending.id)")
                case .failure(let error):
                    tw_title(window, "Threading - could not archive conversation")
                    print("SESSION_ARCHIVE_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingPin, let result = pending.gate.take() {
                pendingPin = nil
                switch result {
                case .success(let saved):
                    if let index = projectIndexes[pending.projectID], projects.indices.contains(index),
                       let row = projects[index].recentAgents.firstIndex(where: { $0.id == pending.id }) {
                        var runtime = projects[index].recentAgents.remove(at: row)
                        runtime.isPinned = saved.pinned
                        let boundary = projects[index].recentAgents.firstIndex(where: { !$0.isPinned })
                            ?? projects[index].recentAgents.count
                        projects[index].recentAgents.insert(runtime, at: boundary)
                        outlineNeedsReload = true
                    }
                    print("SESSION_PIN_SAVED id=\(pending.id) pinned=\(saved.pinned)")
                case .failure(let error):
                    tw_title(window, "Threading - could not change session pin")
                    print("SESSION_PIN_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingRenamePrompt, let result = pending.gate.take() {
                pendingRenamePrompt = nil
                switch result {
                case .success(let title?):
                    beginRename(pending.id, projectID: pending.projectID, title: title,
                                displayedCurrentTitle: pending.displayedCurrentTitle)
                case .success(nil):
                    print("SESSION_RENAME_CANCELLED id=\(pending.id)")
                case .failure(let error):
                    tw_title(window, "Threading - could not rename session")
                    print("SESSION_RENAME_PROMPT_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingClosePrompt, let result = pending.gate.take() {
                pendingClosePrompt = nil
                switch result {
                case .success(true):
                    beginClose(pending.id, projectID: pending.projectID)
                case .success(false):
                    print("SESSION_CLOSE_CANCELLED id=\(pending.id)")
                case .failure(let error):
                    tw_title(window, "Threading - could not confirm Close Session")
                    print("SESSION_CLOSE_PROMPT_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingSessionMenuPresence,
               let presence = pending.gate.take() {
                pendingSessionMenuPresence = nil
                if case .running = presence, var menu = sessionMenu,
                   menu.sessionID == pending.id, menu.projectID == pending.projectID {
                    menu.revealCloseForRunningSession()
                    sessionMenu = menu
                    dirty = true
                }
            }
            if let pending = pendingClose, let result = pending.gate.take() {
                pendingClose = nil
                switch result {
                case .success:
                    let key = SavedRuntimeKey.agent(pending.id)
                    restoredRuntimes.removeValue(forKey: key)?.stop()
                    nativeRuntimes.removeValue(forKey: key)?.runtime.stop()
                    if let target = activePageTarget, target.kind == .agent,
                       target.id == pending.id, target.projectID == pending.projectID,
                       let index = projectIndexes[pending.projectID],
                       projects.indices.contains(index),
                       let childIndex = projects[index].recentAgents.firstIndex(where: {
                           $0.id == pending.id
                       }) {
                        let saved = projects[index].recentAgents[childIndex]
                        activePane?.focus(false, window: window)
                        let selected = NavigatorOutlineItem(kind: .agent,
                            projectID: pending.projectID, id: pending.id,
                            projectIndex: index, childIndex: childIndex)
                        let dormant = WorkspaceDormantPane(
                            pageName: readableNavigatorText(saved.title),
                            displayTitle: readableNavigatorText(saved.title),
                            pageIdentity: pending.id,
                            icon: ProviderMarks.image(for: saved.kind, selected: false),
                            supportsResume: saved.kind?.supportsResume ?? false,
                            canResume: saved.agentSessionID != nil,
                            onReveal: { pageReveal.target = selected })
                        activePane = dormant
                        activePageTarget = selected
                        inlineSelection = selected
                        dormant.focus(!sidebarFocused, window: window)
                    }
                    outlineNeedsReload = true
                    print("SESSION_CLOSED id=\(pending.id)")
                case .failure(let error):
                    tw_title(window, "Threading - could not close session")
                    print("SESSION_CLOSE_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingRename, let result = pending.gate.take() {
                pendingRename = nil
                switch result {
                case .success(let saved):
                    if let index = projectIndexes[pending.projectID], projects.indices.contains(index),
                       let row = projects[index].recentAgents.firstIndex(where: { $0.id == pending.id }) {
                        let visibleTitle = String(saved.title.unicodeScalars.prefix(
                            maximumPersistedRuntimeTitleScalars))
                        projects[index].recentAgents[row].title = visibleTitle
                        projects[index].recentAgents[row].customTitle = saved.customTitle.map {
                            String($0.unicodeScalars.prefix(maximumPersistedRuntimeTitleScalars))
                        }
                        if let target = activePageTarget, target.kind == .agent,
                           target.id == pending.id, target.projectID == pending.projectID {
                            activePane?.chrome.updatePageName(readableNavigatorText(visibleTitle))
                        }
                        outlineNeedsReload = true
                    }
                    print("SESSION_RENAME_SAVED id=\(pending.id) changed=\(saved.changed)")
                case .failure(let error):
                    tw_title(window, "Threading - could not rename session")
                    print("SESSION_RENAME_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let gate = pendingSnoozeScan, let result = gate.take() {
                pendingSnoozeScan = nil
                switch result {
                case .success(let scan):
                    snoozeDeadlines = scan.active
                    refreshSnoozeDeadline()
                    let expired = Set(scan.expired.map(\.uuidString))
                    if !expired.isEmpty {
                        for projectIndex in projects.indices {
                            for row in projects[projectIndex].recentAgents.indices
                                where expired.contains(projects[projectIndex].recentAgents[row].id) {
                                projects[projectIndex].recentAgents[row].snoozedUntil = nil
                                projects[projectIndex].recentAgents[row].attention = .woke
                            }
                        }
                        dirty = true
                        if let target = activePageTarget, target.kind == .agent,
                           expired.contains(target.id) {
                            pendingSnoozeAcknowledgements[target.id] = target.projectID
                        }
                    }
                    print("SESSION_SNOOZE_RECONCILED active=\(scan.active.count) expired=\(scan.expired.count)")
                case .failure(let error):
                    nextSnoozeScanAttempt = Date().addingTimeInterval(1)
                    print("SESSION_SNOOZE_RECONCILE_RETRY \(error)")
                }
                fflush(nil)
                continue
            }
            if pendingSnoozeScan == nil, pendingSnoozeExpiry == nil, pendingSnooze == nil,
               let pending = pendingSnoozePicker, let result = pending.gate.take() {
                pendingSnoozePicker = nil
                switch result {
                case .success(let deadline?):
                    if deadline > Date(),
                       let projectIndex = projectIndexes[pending.projectID],
                       projects.indices.contains(projectIndex),
                       projects[projectIndex].recentAgents.contains(where: {
                           $0.id == pending.id
                       }) {
                        beginSnooze(pending.id, projectID: pending.projectID,
                            change: .snooze(until: deadline, at: Date(),
                                            hadTurnInFlight: pending.hadTurnInFlight))
                    }
                case .success(nil):
                    print("SESSION_SNOOZE_CUSTOM_CANCELLED \(pending.id)")
                case .failure(let error):
                    print("SESSION_SNOOZE_CUSTOM_REFUSED \(error)")
                    tw_title(window, "Threading - custom snooze failed")
                }
                fflush(nil)
                dirty = true
            }
            if let pending = pendingSnooze, let result = pending.gate.take() {
                pendingSnooze = nil
                switch result {
                case .success(let saved):
                    if let id = SessionID(uuidString: pending.id) {
                        snoozeDeadlines[id] = saved.deadline
                        refreshSnoozeDeadline()
                    }
                    updateSnoozeRow(pending.id, projectID: pending.projectID,
                                    result: saved)
                    print("SESSION_SNOOZE_SAVED id=\(pending.id) deadline=\(String(describing: saved.deadline))")
                case .failure(let error):
                    tw_title(window, "Threading - could not change session snooze")
                    print("SESSION_SNOOZE_REFUSED id=\(pending.id) \(error)")
                }
                fflush(nil)
                dirty = true
                continue
            }
            if let pending = pendingSnoozeExpiry, let result = pending.gate.take() {
                pendingSnoozeExpiry = nil
                switch result {
                case .success(let expired):
                    for id in pending.ids {
                        snoozeDeadlines[id] = expired[id]?.deadline
                    }
                    refreshSnoozeDeadline()
                    for projectIndex in projects.indices {
                        for row in projects[projectIndex].recentAgents.indices {
                            guard let id = SessionID(uuidString:
                                projects[projectIndex].recentAgents[row].id),
                                  let saved = expired[id] else { continue }
                            projects[projectIndex].recentAgents[row].snoozedUntil = saved.deadline
                            projects[projectIndex].recentAgents[row].attention = saved.hasWake
                                ? .woke : nil
                        }
                    }
                    dirty = true
                    print("SESSION_SNOOZE_EXPIRED count=\(expired.values.filter(\.changed).count)")
                case .failure(let error):
                    nextSnoozeDeadline = Date().addingTimeInterval(1)
                    print("SESSION_SNOOZE_EXPIRY_RETRY \(error)")
                }
                fflush(nil)
                continue
            }
            if pendingSnoozeScan == nil, pendingSnooze == nil,
               pendingSnoozeExpiry == nil,
               let acknowledgement = pendingSnoozeAcknowledgements.first {
                pendingSnoozeAcknowledgements[acknowledgement.key] = nil
                beginSnooze(acknowledgement.key,
                    projectID: acknowledgement.value, change: .acknowledge)
                continue
            }
            if let pending = pendingExpansion {
                if let result = pending.gate.take() {
                    pendingExpansion = nil
                    switch result {
                    case .success:
                        print("OUTLINE_EXPANSION_SAVED project=\(pending.projectID) expanded=\(pending.expanded)")
                    case .failure(let error):
                        if let index = projectIndexes[pending.projectID] {
                            projects[index].isExpanded = !pending.expanded
                            inlineSelection = pending.selection
                            outlineScrollSelection = true
                            outlineNeedsReload = true
                            dirty = true
                        }
                        print("OUTLINE_EXPANSION_REFUSED \(error)")
                    }
                    fflush(nil)
                    if quitAfterExpansion { return }
                } else if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { quitAfterExpansion = true }
                    if event.kind == 1 { try updateSurface(event) }
                    if event.kind == 24 { focusSidebar(event.action == 1) }
                    _ = routeTerminalInput(event)
                }
                continue
            }
            if let pending = pendingRepositoryExpansion {
                if let result = pending.gate.take() {
                    pendingRepositoryExpansion = nil
                    switch result {
                    case .success:
                        print("OUTLINE_REPOSITORY_SAVED identity=\(pending.identity) expanded=\(pending.expanded)")
                    case .failure(let error):
                        collapsedRepositoryIdentities = pending.previous
                        PreferenceStore.shared.set(Array(pending.previous),
                            forKey: SidebarDefaults.collapsedRepositoriesKey)
                        outlineNeedsReload = true
                        dirty = true
                        print("OUTLINE_REPOSITORY_REFUSED \(error)")
                    }
                    fflush(nil)
                    if quitAfterExpansion { return }
                } else if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { quitAfterExpansion = true }
                    if event.kind == 1 { try updateSurface(event) }
                    if event.kind == 24 { focusSidebar(event.action == 1) }
                    _ = routeTerminalInput(event)
                }
                continue
            }
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
                            try updateSurface(event)
                        }
                        if event.kind == 24 { focusSidebar(event.action == 1) }
                        // Persistence freezes navigation decisions, not the visible child's input.
                        _ = routeTerminalInput(event)
                    }
                    continue
                }
            } else if let pendingFolderImport {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { return }
                    if event.kind == 1 {
                        try updateSurface(event)
                    }
                    if !pendingFolderImport.blocksParentInput {
                        if event.kind == 24 { focusSidebar(event.action == 1) }
                        _ = routeTerminalInput(event)
                    }
                }
                continue
            } else if let pendingRenamePrompt {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 {
                        pendingRenamePrompt.gate.cancel()
                        return
                    }
                    if event.kind == 1 { try updateSurface(event) }
                }
                continue
            } else if let pendingClosePrompt {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 {
                        pendingClosePrompt.gate.cancel()
                        return
                    }
                    if event.kind == 1 { try updateSurface(event) }
                }
                continue
            } else if pendingClose != nil {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 { return }
                    if event.kind == 1 { try updateSurface(event) }
                }
                continue
            } else if let pendingSnoozePicker {
                if tw_next_timeout(window, &event, 33) == 1 {
                    if event.kind == 5 {
                        pendingSnoozePicker.gate.cancel()
                        return
                    }
                    if event.kind == 1 { try updateSurface(event) }
                }
                continue
            } else {
                // A creation can finish after the user returned from its starting terminal.
                // Poll only while one of at most eight runtimes owes an admission publication.
                let awaitingCreation = terminals.values.contains { $0.hasPendingTerminalCreation }
                    || restoredRuntimes.values.contains { $0.hasPendingAgentCreation }
                let pollsRuntime = awaitingCreation || activePane?.needsPolling == true
                    || pendingNativeCreation != nil || pendingOpenInCatalogue != nil
                    || pendingOpenInLaunch != nil || pendingArchive != nil || pendingPin != nil
                    || pendingSnoozeScan != nil || pendingSnooze != nil
                    || pendingSnoozeExpiry != nil
                    || pendingRename != nil || pendingClose != nil
                    || openInIcons.isLoading
                // A picker without a terminal still owes a deadline update. Sleep until that
                // expiry (at most one second to recheck wall-clock changes), while the bridge
                // keeps servicing accessibility without returning to the Swift loop every 33ms.
                let expiryWait = nextVisibleAttentionExpiry.map {
                    Int32(max(1, min(1_000, ceil($0.timeIntervalSinceNow * 1_000))))
                }
                let snoozeWait = pendingSnoozeExpiry == nil ? nextSnoozeDeadline.map {
                    Int32(max(1, min(1_000, ceil($0.timeIntervalSinceNow * 1_000))))
                } : nil
                let activityWait = visibleWorkingActivity && !Design.Motion.reducesStatusMotion
                    ? Int32(max(1, min(42, ceil(nextActivityFrame.timeIntervalSinceNow * 1_000))))
                    : nil
                let timeout = [pollsRuntime ? Int32(33) : nil, expiryWait, snoozeWait, activityWait]
                    .compactMap { $0 }.min()
                let received = timeout.map { tw_next_timeout(window, &event, $0) }
                    ?? tw_next(window, &event)
                if timeout != nil, received == 0 { continue }
                guard received == 1 else {
                    throw WindowFailure(String(cString: tw_error()))
                }
            }
            if event.kind == 52 { continue }
            if event.kind == 55 {
                guard let launch else { continue }
                guard event.action == 0,
                      let path = String(validatingCString: tw_event_text(&event)) else {
                    print("PROJECT_IMPORT_REFUSED invalid dropped path"); fflush(nil)
                    continue
                }
                if Int(event.x) >= sidebarWidth {
                    let wakeIdentity = tw_worker_wake_identity(window)
                    let accepted = (activePane as? WorkspaceConversationPane)?
                        .acceptFileDrop(path, windowX: Int(event.x), windowY: Int(event.y),
                                        originX: sidebarWidth, wakeIdentity: wakeIdentity)
                        ?? (activePane == nil ? idlePane?.acceptFileDrop(path,
                            windowX: Int(event.x), windowY: Int(event.y),
                            originX: sidebarWidth, wakeIdentity: wakeIdentity) : nil) ?? false
                    if accepted { dirty = true }
                    continue
                }
                if actions != nil { dismissActions(returnToParent: false) }
                accountPicker = nil
                savedPicker = nil
                focusSidebar(true)
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1],
                                                       droppedPath: path)
                dirty = true
                continue
            }
            if event.kind == 53 || event.kind == 54 {
                if actions != nil || accountPicker != nil || savedPicker != nil {
                    // Menus and the explicit saved catalogs retain their own back behavior.
                    event.kind = event.kind == 53 ? 10 : 11
                } else {
                    guard sidebarFocused, let item = inlineSelection else { continue }
                    let direction: SidebarVisibleRows.Direction = event.kind == 53 ? .right : .left
                    let wasExpanded = outline.isItemExpanded(item)
                    guard let next = sidebarRows.navigate(direction, from: item),
                          next != item || outline.isItemExpanded(item) != wasExpanded else { continue }
                    inlineSelection = next
                    outlineScrollSelection = true
                    dirty = true
                    continue
                }
            }
            trace("event kind=\(event.kind) action=\(event.action)")
            let windowIsKey = tw_window_has_focus(window) != 0
            if contentWindow.isKeyWindow != windowIsKey {
                contentWindow.isKeyWindow = windowIsKey
                if !windowIsKey { contentWindow.cancelPointerGesture() }
                for index in outline.visibleRowIndexes {
                    guard let chrome = outline.rowView(atRow: index,
                        makeIfNecessary: false) as? SidebarHoverRowView else { continue }
                    chrome.isEmphasized = windowIsKey
                }
                dirty = true
            }
            if event.kind == 45 { continue }
            if event.kind == 62 {
                toggleSettings()
                continue
            }
            if settingsPane != nil && event.kind == 2 { toggleSettings() }
            if event.kind == 44 {
                if event.action == 0 {
                    LinuxTheme.setDark(!LinuxTheme.isDark)
                    navigatorRoot.setThemeAppearance()
                    idlePane?.setThemeAppearance()
                    activePane?.setThemeAppearance()
                    dirty = true
                    print("THEME_APPEARANCE \(LinuxTheme.isDark ? "dark" : "light")")
                    fflush(nil)
                } else if let pane = activePane {
                    var identityEvent = event
                    let identity = String(validatingCString: tw_event_text(&identityEvent)) ?? ""
                    if identity == pane.chrome.pageIdentity {
                        focusSidebar(false)
                        if event.action == 1 { _ = pane.chrome.pressOpenInAction() }
                        if event.action == 2 { _ = pane.chrome.pressOpenInChooser() }
                        drainOpenInRequests(pane)
                        dirty = true
                    }
                }
                continue
            }
            if let button = dismissedActionGesture {
                if event.kind == 17 { continue }
                if event.kind == 15, event.key == button, event.action == 3 {
                    dismissedActionGesture = nil
                    continue
                }
            }
            if event.kind == 26 { continue }
            if event.kind == 25, launch != nil {
                contentWindow.cancelPointerGesture()
                if actions != nil { dismissActions() }
                else { openActions(for: nil, returnToSidebar: event.action == 1) }
                continue
            }
            if event.kind == 30, launch != nil {
                openAddProjectMenu()
                continue
            }
            if event.kind == 28, launch != nil {
                contentWindow.cancelPointerGesture()
                let slot = Int(event.key)
                let index = first + slot
                guard actions == nil, accountPicker == nil, savedPicker == nil,
                      slot >= 0, slot < outline.visibleRowIndexes.count,
                      case .some(.project(_, let projectID)) = sidebarRows.row(at: index),
                      let id = String(validatingCString: tw_event_text(&event)),
                      projectID == id, let target = ProjectID(uuidString: id)
                else { continue }
                openActions(for: target, returnToSidebar: true)
                continue
            }
            if event.kind == 33, launch != nil {
                contentWindow.cancelPointerGesture()
                let slot = Int(event.key)
                let index = first + slot
                guard actions == nil, accountPicker == nil, savedPicker == nil,
                      slot >= 0, slot < outline.visibleRowIndexes.count,
                      let row = sidebarRows.row(at: index),
                      let id = String(validatingCString: tw_event_text(&event)),
                      let target = ProjectID(uuidString: id)
                else { continue }
                switch row {
                case .project(let projectIndex, let projectID) where projectID == id:
                    selected = projectIndex
                    openProjectCreateMenu(for: target, returnToSidebar: sidebarFocused)
                case .repository(_, let projectIndex, let projectID) where projectID == id:
                    selected = projectIndex
                    openProjectCreateMenu(for: target, returnToSidebar: sidebarFocused,
                                          repository: true)
                default: break
                }
                continue
            }
            if event.kind == 29, launch != nil {
                contentWindow.cancelPointerGesture()
                guard actions == nil, accountPicker == nil, savedPicker == nil else { continue }
                if let item = inlineSelection, item.kind == .agent {
                    openSessionMenu(item.id, projectID: item.projectID,
                        openInApps: openInCatalogue.apps)
                } else if projects.indices.contains(selected),
                          let target = ProjectID(uuidString: projects[selected].id) {
                    openActions(for: target, returnToSidebar: true)
                }
                continue
            }
            if event.kind == 27 {
                if event.action == 6 {
                    // One native motion leaves the idle pane and enters the navigator.
                    // Clear its retained hover before delivering that same motion to the row.
                    idlePane?.cancelHover()
                    dirty = true
                }
                if event.action == 4 || event.action == 7 {
                    contentWindow.cancelPointerGesture()
                    _ = navigatorRoot.takeActivatedRowSlot()
                    activatedOutlineItem = nil
                    activatedOutlineProjectActionID = nil
                    activatedOutlineProjectCreateID = nil
                    activatedOutlineSessionActionID = nil
                    activatedOutlineSessionArchiveID = nil
                    activatedSessionMenuEntry = nil
                    activatedAccountHandle = nil
                    rowActionMenuGesture = false
                    rowActionMenuEntered = false
                    if hoveredOutlineItem != nil {
                        hoveredOutlineItem = nil; dirty = true
                    }
                    if event.action == 7, activePane == nil, let idlePane {
                        var motion = event
                        motion.kind = 39
                        motion.action = 0
                        motion.x -= Int32(sidebarWidth)
                        idlePane.handle(motion)
                    }
                    dirty = true
                    continue
                }
                // Row hover uses the outline's indexed offset lookup and one geometry check;
                // a pointer move never scans a stored catalogue or builds hidden controls.
                var pointerOutlineItem: NavigatorOutlineItem?
                if actions == nil, accountPicker == nil, savedPicker == nil,
                   launch != nil, let index = outlineRowIndex(at: event),
                   let item = outline.item(atRow: index) as? NavigatorOutlineItem,
                   (item.kind == .project || item.kind == .repository || item.kind == .agent),
                   let row = outlineRowPixels(index) {
                    if event.x >= row.x, event.x < row.x + row.width,
                       event.y >= row.y, event.y < row.y + row.height {
                        pointerOutlineItem = item
                    }
                }
                if hoveredOutlineItem != pointerOutlineItem {
                    hoveredOutlineItem = pointerOutlineItem
                    dirty = true
                }
                let eventType: NSEvent.EventType
                switch event.action {
                case 1: eventType = .leftMouseDown
                case 2: eventType = .leftMouseDragged
                case 3: eventType = .leftMouseUp
                case 5: eventType = .rightMouseDown
                default: eventType = .mouseMoved
                }
                let point = NSPoint(x: CGFloat(event.x) / contentWindow.backingScaleFactor,
                    y: navigatorRoot.bounds.height - CGFloat(event.y) / contentWindow.backingScaleFactor)
                if event.action == 1 {
                    activatedOutlineItem = nil
                    activatedOutlineProjectActionID = nil
                    activatedOutlineProjectCreateID = nil
                    activatedOutlineSessionActionID = nil
                    activatedOutlineSessionArchiveID = nil
                    activatedSessionMenuEntry = nil
                }
                _ = contentWindow.dispatchToContent(NSEvent(type: eventType,
                                                              locationInWindow: point))
                if event.action == 1, let actionID = activatedOutlineSessionActionID {
                    activatedOutlineSessionActionID = nil
                    if pointerOutlineItem?.kind == .agent,
                       pointerOutlineItem?.id == actionID,
                       let projectID = pointerOutlineItem?.projectID {
                        openSessionMenu(actionID, projectID: projectID,
                            openInApps: openInCatalogue.apps)
                    }
                    continue
                }
                if event.action == 5,
                   sessionMenu == nil || !sessionMenuFrame.contains(point) {
                    if pointerOutlineItem?.kind == .agent,
                       let item = pointerOutlineItem {
                        openSessionMenu(item.id, projectID: item.projectID,
                            openInApps: openInCatalogue.apps)
                        continue
                    }
                    dismissSessionMenu()
                }
                if let menu = sessionMenu {
                    if event.action == 3, let entry = activatedSessionMenuEntry,
                       let command = menu.command(at: entry) {
                        activatedSessionMenuEntry = nil
                        sessionMenu?.selected = entry
                        chooseSessionMenu(command)
                    } else if event.action == 1, !sessionMenuFrame.contains(point) {
                        contentWindow.cancelPointerGesture()
                        _ = navigatorRoot.takeActivatedRowSlot()
                        activatedOutlineItem = nil
                        dismissSessionMenu()
                    }
                    if navigatorRoot.takeProjectControlVisualChange() { dirty = true }
                    continue
                }
                if event.action == 3, let chosen = activatedMenuEntry,
                   var menu = actions, menu.commands.indices.contains(chosen) {
                    activatedMenuEntry = nil
                    menu.selected = chosen
                    actions = menu
                    dirty = true
                    event.kind = 8
                }
                if event.action == 3, let handle = activatedAccountHandle {
                    activatedAccountHandle = nil
                    if accountPicker != nil, let index = pickerAccounts.firstIndex(of: handle) {
                        accountSelected = index
                        dirty = true
                        event.kind = 8
                    }
                }
                if navigatorRoot.takeProjectControlVisualChange() { dirty = true }
                if addProjectControlVisualChanged {
                    addProjectControlVisualChanged = false
                    dirty = true
                }
                if actionsControlVisualChanged {
                    actionsControlVisualChanged = false
                    dirty = true
                }
                if addProjectActivated {
                    addProjectActivated = false
                    openAddProjectMenu()
                    continue
                }
                if actionsActivated {
                    actionsActivated = false
                    if actions != nil { dismissActions() }
                    else { openActions(for: nil, returnToSidebar: sidebarFocused) }
                    continue
                }
                if let archiveID = activatedOutlineSessionArchiveID {
                    activatedOutlineSessionArchiveID = nil
                    if pointerOutlineItem?.kind == .agent,
                       pointerOutlineItem?.id == archiveID,
                       let projectID = pointerOutlineItem?.projectID {
                        beginArchive(archiveID, projectID: projectID)
                    }
                    continue
                }
                let wasSidebarFocused = sidebarFocused
                let activatedCreate = activatedOutlineProjectCreateID
                let activatedProject = activatedOutlineProjectActionID
                activatedOutlineProjectCreateID = nil
                activatedOutlineProjectActionID = nil
                let activatedRow = navigatorRoot.takeActivatedRowSlot()
                let activatedOutlineRow = activatedOutlineItem.flatMap {
                    let index = outline.row(forItem: $0)
                    return index >= 0 ? index : nil
                }
                let pointerPixel = NSPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                if event.action == 5 {
                    // A project row and its trailing icon share one exact-target menu, as on
                    // Mac. The right press has no selection effect and Shift+F10 remains its
                    // keyboard route. Resolve only the visible row hit above, then recheck
                    // identity before opening the host-owned command surface.
                    guard let id = pointerOutlineItem?.projectID,
                          let index = projectIndexes[id], projects.indices.contains(index),
                          projects[index].id == id, let target = ProjectID(uuidString: id)
                    else { continue }
                    openActions(for: target, returnToSidebar: sidebarFocused)
                    continue
                }
                if rowActionMenuGesture && event.action == 2 {
                    if !rowActionMenuSource.contains(pointerPixel),
                       let index = actionMenuIndex(at: event.x, y: event.y),
                       var menu = actions {
                        rowActionMenuEntered = true
                        if menu.selected != index {
                            menu.selected = index; actions = menu; dirty = true
                        }
                    }
                    continue
                }
                if rowActionMenuGesture && event.action == 3 {
                    let chosen = rowActionMenuEntered &&
                        !rowActionMenuSource.contains(pointerPixel)
                        ? actionMenuIndex(at: event.x, y: event.y) : nil
                    rowActionMenuGesture = false
                    rowActionMenuEntered = false
                    if let chosen, var menu = actions,
                       let target = menu.projectID,
                       let targetIndex = projectIndexes[target.uuidString],
                       projects.indices.contains(targetIndex),
                       projects[targetIndex].id == target.uuidString {
                        menu.selected = chosen
                        actions = menu
                        dirty = true
                        event.kind = 8 // Reuse the menu's exact-project command admission.
                    } else { continue }
                }
                if event.kind == 8 {
                    // A held press that entered the menu is completed by its release below.
                } else if event.action == 1 {
                    if activePane != nil { focusSidebar(true) }
                    if let activatedCreate, let target = ProjectID(uuidString: activatedCreate),
                       pointerOutlineItem?.projectID == activatedCreate {
                        openProjectCreateMenu(for: target, returnToSidebar: wasSidebarFocused,
                                              repository: pointerOutlineItem?.kind == .repository)
                        if actions?.projectID == target {
                            if let rowIndex = outlineRowIndex(at: event),
                               let source = projectControlPixels(rowIndex, create: true) {
                                rowActionMenuSource = NSRect(
                                    x: CGFloat(source.x), y: CGFloat(source.y),
                                    width: CGFloat(source.width), height: CGFloat(source.height))
                                rowActionMenuGesture = true
                            }
                        }
                        continue
                    }
                    if let activatedProject, let target = ProjectID(uuidString: activatedProject),
                       pointerOutlineItem?.projectID == activatedProject {
                        openActions(for: target, returnToSidebar: true)
                        if actions?.projectID == target {
                            if let rowIndex = outlineRowIndex(at: event),
                               let source = projectControlPixels(rowIndex, create: false) {
                                rowActionMenuSource = NSRect(
                                    x: CGFloat(source.x), y: CGFloat(source.y),
                                    width: CGFloat(source.width), height: CGFloat(source.height))
                                rowActionMenuGesture = true
                            }
                        }
                        continue
                    }
                    if let pressedRow = activatedOutlineRow.map({ $0 - first }) ?? activatedRow {
                        pendingMountedRowSlot = pressedRow
                        pointerActivatedRow = true
                        event.kind = 2
                        event.action = 0
                    } else { continue }
                } else { continue }
            }
            if var menu = sessionMenu {
                let selectable = menu.entries.indices.filter { menu.command(at: $0) != nil }
                switch event.kind {
                case 5: return
                case 1: try updateSurface(event); continue
                case 12, 24:
                    if menu.page != .actions { menu.returnToActions(); sessionMenu = menu; dirty = true }
                    else { dismissSessionMenu() }
                    continue
                case 10:
                    if let command = menu.command(at: menu.selected),
                       command == .copy || command == .openIn {
                        chooseSessionMenu(command)
                    }
                    continue
                case 11:
                    if menu.page != .actions { chooseSessionMenu(.back) }
                    else { dismissSessionMenu() }
                    continue
                case 3, 4:
                    guard let current = selectable.firstIndex(of: menu.selected),
                          !selectable.isEmpty else { continue }
                    let step = event.kind == 3 ? -1 : 1
                    menu.selected = selectable[(current + step + selectable.count) % selectable.count]
                    sessionMenu = menu
                    dirty = true
                    continue
                case 2, 15:
                    let slot = Int(event.key)
                    guard sessionMenuVisibleEntries.indices.contains(slot) else { continue }
                    menu.selected = sessionMenuVisibleEntries[slot]
                    sessionMenu = menu
                    dirty = true
                    if event.kind == 2 && event.action == 1 { continue }
                case 8: break
                default: continue
                }
                if let command = menu.command(at: menu.selected) { chooseSessionMenu(command) }
                continue
            }
            if var menu = actions {
                switch event.kind {
                case 5: return
                case 1: try updateSurface(event); continue
                case 12, 11, 24:
                    dismissActions(); continue
                case 3, 4:
                    guard event.action == 1 || sidebarFocused else { continue }
                    let step = event.kind == 3 ? -1 : 1
                    menu.selected = max(0, min(menu.commands.count - 1, menu.selected + step))
                    actions = menu; dirty = true; continue
                case 2:
                    if let index = actionMenuIndex(at: event.x, y: event.y) {
                        menu.selected = index
                        actions = menu; dirty = true
                        if event.action == 1 { continue }
                    } else { dismissActions(); continue }
                case 8: break
                case 15:
                    if event.action == 1 { dismissedActionGesture = event.key; dismissActions() }
                    continue
                case 37, 38, 39, 40:
                    dismissActions(returnToParent: false)
                    _ = routeTerminalInput(event)
                    continue
                default: continue
                }
                guard let command = NavigatorActions.Command(rawValue: menu.commands[menu.selected].id) else { continue }
                switch NavigatorActions.invoke(command, projectID: menu.projectID,
                                               state: { actionState(for: menu.projectID) }) {
                case .refused(_, let reason):
                    tw_title(window, "Threading actions - " + reason)
                    print("ACTION_REFUSED \(command.rawValue) \(reason)"); fflush(nil)
                    continue
                case .invoked:
                    if (menu.kind == .projectCreate || menu.kind == .repositoryCreate),
                       command == .newChat,
                       let target = menu.projectID {
                        openChatProvidersMenu(for: target,
                            returnToSidebar: menu.returnToSidebar)
                        continue
                    }
                    if menu.kind == .repositoryCreate, command == .newWorktree,
                       let launch, let target = menu.projectID,
                       let index = projectIndexes[target.uuidString], projects.indices.contains(index),
                       projects[index].id == target.uuidString,
                       pendingFolderImport == nil {
                        let sourcePath = projects[index].path
                        dismissActions(returnToParent: false)
                        pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1],
                            choice: .worktree(sourcePath: sourcePath,
                                              dark: LinuxTheme.isDark))
                        continue
                    }
                    if menu.kind == .chatProviders, !menu.returnToSidebar,
                       (command == .newCodex || command == .newClaude) {
                        pendingComposerProjectID = menu.projectID?.uuidString
                    }
                    if ![.addProject, .newProject, .newScratchpad].contains(command),
                       let target = menu.projectID,
                       let targetIndex = projectIndexes[target.uuidString],
                       projects.indices.contains(targetIndex),
                       projects[targetIndex].id == target.uuidString {
                        // Opening a row menu leaves selection in place. Taking a project
                        // command then makes that exact project the existing operation target.
                        selected = targetIndex
                        inlineSelection = NavigatorOutlineItem(projectID: projects[targetIndex].id,
                            projectIndex: targetIndex)
                        dirty = true
                    }
                    dismissActions(returnToParent: false)
                    accountPicker = nil; savedPicker = nil
                    focusSidebar(true)
                    event = TWEvent(); event.kind = command.eventKind
                }
            }
            // Shortcut and menu entry points share the production availability gate before the
            // existing operation below owns persistence, exact identity and process launch.
            if !selectionWasCommitted, accountPicker == nil, savedPicker == nil,
               let command = (event.kind == 8 && projects.isEmpty ? NavigatorActions.Command.addProject
                    : NavigatorActions.Command.allCases.first(where: { $0.eventKind == event.kind })),
               launch != nil {
                switch NavigatorActions.invoke(command, projectID: actionState().projectID,
                                               state: { actionState() }) {
                case .invoked: break
                case .refused(_, let reason):
                    pendingComposerProjectID = nil
                    tw_title(window, "Threading experiment - " + reason)
                    print("ACTION_REFUSED \(command.rawValue) \(reason)"); fflush(nil)
                    continue
                }
            }
            if event.kind == 24 {
                // The same command first focuses navigation, then opens its folder action.
                // Preserve import access after a terminal occupies the adjacent pane.
                if event.action == 1, sidebarFocused, accountPicker == nil,
                   savedPicker == nil, let launch {
                    pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                } else {
                    focusSidebar(event.action == 1)
                    if event.action == 0, idlePane?.isComposing == true {
                        idlePane?.focusEditor()
                        _ = tw_workspace_editor_focus(window, 1)
                    }
                }
                continue
            }
            let routed = routeTerminalInput(event)
            if let dormant = activePane as? WorkspaceDormantPane,
               dormant.takeResumeRequest() {
                event = TWEvent()
                event.kind = 8
            } else if routed { continue }
            switch event.kind {
            case 5: return
            case 12:
                if let idlePane, idlePane.hasOpenComposerChoice,
                   idlePane.handleComposerChoiceKey(NSEvent(type: .keyDown,
                       keyCode: 53, charactersIgnoringModifiers: "")) {
                    dirty = true
                    continue
                }
                if accountPicker != nil {
                    accountPicker = nil
                    dirty = true
                } else if savedPicker != nil {
                    savedPicker = nil
                    dirty = true
                } else if activePane != nil {
                    focusSidebar(false)
                } else if !sidebarFocused, idlePane?.isComposing == true {
                    _ = tw_workspace_editor_focus(window, 0)
                    focusSidebar(true)
                    dirty = true
                } else { return }
            case 1:
                try updateSurface(event)
            case 2:
                let listFirst = accountPicker != nil ? accountFirst : (savedPicker == nil ? first : savedFirst)
                let listCount: Int
                if accountPicker != nil {
                    listCount = pickerAccounts.count
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    listCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                } else { listCount = projects.isEmpty && launch != nil ? 1 : sidebarRows.totalCount }
                let visibleCount = projectsMode && !projects.isEmpty
                    ? outline.visibleRowIndexes.count : max(0, min(listCount - listFirst, count))
                let pressedSlot = event.action == 1 ? Int(event.key) : mountedRowPressed(by: event)
                activatedOutlineItem = nil
                if let mounted = pressedSlot, mounted >= 0, mounted < visibleCount {
                    if projects.isEmpty, let launch, accountPicker == nil, savedPicker == nil {
                        if event.action != 1 {
                            pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
                        }
                        break
                    }
                    let candidate = listFirst + mounted
                    if accountPicker != nil { accountSelected = candidate }
                    else if savedPicker != nil { savedSelected = candidate }
                    else if let row = sidebarRows.row(at: candidate) {
                        if pointerActivatedRow,
                           (row.isExpandableParent),
                           let cell = outline.view(atColumn: 0, row: candidate,
                                makeIfNecessary: false) as? Specimen.Row {
                            let point = NSPoint(x: CGFloat(event.x) / scale,
                                y: navigatorRoot.bounds.height - CGFloat(event.y) / scale)
                            if cell.productionDisclosureContains(cell.convert(point, from: navigatorRoot)) {
                                let item = NavigatorOutlineItem(row, projects: projects)
                                if item.kind == .project {
                                    toggleProjectExpansion(projectID: item.projectID,
                                        projectIndex: item.projectIndex)
                                } else if item.kind == .repository {
                                    if outline.isItemExpanded(item) { outline.collapseItem(item) }
                                    else { outline.expandItem(item) }
                                }
                                dirty = true
                                continue
                            }
                        }
                        inlineSelection = NavigatorOutlineItem(row, projects: projects)
                        switch row {
                        case .repository(_, let projectIndex, _):
                            if projects.indices.contains(projectIndex) { selected = projectIndex }
                        case .project(let projectIndex, _), .agent(let projectIndex, _, _),
                             .terminal(let projectIndex, _, _):
                            selected = projectIndex
                        }
                    }
                    trace("selection index=\(candidate)")
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
                let inlineRuntime: (picker: SavedPicker, index: Int)?
                switch sidebarRows.row(at: selectedInlineIndex) {
                case .some(.agent(let projectIndex, let childIndex, _)):
                    inlineRuntime = (.agents(projectIndex), childIndex)
                case .some(.terminal(let projectIndex, let childIndex, _)):
                    inlineRuntime = (.terminals(projectIndex), childIndex)
                default:
                    inlineRuntime = nil
                }
                if let destination = savedPicker.map({ (picker: $0, index: savedSelected) }) ?? inlineRuntime {
                    let picker = destination.picker
                    let project = projects[picker.projectIndex]
                    let saved = picker.isAgent ? project.recentAgents : project.recentTerminals
                    guard saved.indices.contains(destination.index) else { break }
                    let runtime = saved[destination.index]
                    let key: SavedRuntimeKey = picker.isAgent ? .agent(runtime.id) : .terminal(runtime.id)
                    if picker.isAgent && runtime.usesNativeUI {
                        if !selectionWasCommitted {
                            pendingSelection = recordSelection(runtime.id, terminalID: nil,
                                terminalProjectID: nil, store: launch[0], after: event)
                            break
                        }
                        try activateNative(runtime, projectIndex: picker.projectIndex, childIndex: destination.index)
                        dirty = true
                        break
                    }
                    let session: GraphicalTerminal
                    let mayResume = picker.isAgent && (agentExecutable != nil || claudeExecutable != nil)
                    let mayStartAgain = mayResume || !picker.isAgent
                    let runtimeOwner = owner(of: key, projectID: project.id)
                    let existing = retainedRuntime(for: runtimeOwner)
                    let reuses = existing.map {
                        !(mayStartAgain && $0.canReplace)
                            && !(!picker.isAgent && $0.canReopenSavedTerminal)
                    } ?? false
                    guard reuses || existing != nil
                            || terminals.count + restoredRuntimes.count + nativeRuntimes.count
                                + (composerCreationPending ? 1 : 0) < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    if !selectionWasCommitted {
                        pendingSelection = recordSelection(picker.isAgent ? runtime.id : nil,
                                                           terminalID: picker.isAgent ? nil : runtime.id,
                                                           terminalProjectID: picker.isAgent ? nil : project.id,
                                                           store: launch[0], after: event)
                        break
                    }
                    if reuses, let existing { session = existing }
                    else {
                        existing?.stop()
                        session = makeObservedTerminal()
                        retain(session, for: runtimeOwner)
                        restoredProjectIDs.insert(project.id)
                        if picker.isAgent {
                            if mayResume {
                                session.openAgent(store: launch[0], socket: launch[1], sessionID: runtime.id,
                                    shell: launch[2], codex: agentExecutable, claude: claudeExecutable,
                                    width: terminalWidth,
                                    height: max(1, height - WorkspaceTerminalPane.headerPixelHeight))
                            } else {
                                session.attachAgent(store: launch[0], socket: launch[1], sessionID: runtime.id)
                            }
                        } else {
                            session.openTerminal(store: launch[0], socket: launch[1], terminalID: runtime.id, title: runtime.title,
                                projectID: project.id, executable: launch[2],
                                arguments: Array(launch.dropFirst(3)), width: terminalWidth,
                                height: max(1, height - WorkspaceTerminalPane.headerPixelHeight))
                        }
                    }
                    try activate(session, pageName: readableNavigatorText(runtime.title),
                        pageIdentity: runtime.id,
                        pageIcon: picker.isAgent
                            ? ProviderMarks.image(for: runtime.kind, selected: false) : nil,
                        pageTarget: NavigatorOutlineItem(kind: picker.isAgent ? .agent : .terminal,
                            projectID: project.id, id: runtime.id,
                            projectIndex: picker.projectIndex, childIndex: destination.index))
                    dirty = true
                    break
                }
                let project = projects[selected]
                guard terminals[project.id] != nil
                        || terminals.count + restoredRuntimes.count + nativeRuntimes.count
                            + (composerCreationPending ? 1 : 0) < maximumOpenRuntimes else {
                    tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                    break
                }
                if !selectionWasCommitted {
                    pendingSelection = recordSelection(nil,
                                                       terminalID: terminals[project.id]?.terminalID,
                                                       terminalProjectID: project.id,
                                                       store: launch[0], after: event,
                                                       continuesOnRefusal: terminals[project.id] == nil)
                    break
                }
                let session: GraphicalTerminal
                if let existing = terminals[project.id] { session = existing }
                else {
                    guard terminals.count + restoredRuntimes.count + nativeRuntimes.count
                            + (composerCreationPending ? 1 : 0) < maximumOpenRuntimes else {
                        tw_title(window, "Threading experiment - limit of \(maximumOpenRuntimes) open terminals")
                        break
                    }
                    session = makeObservedTerminal()
                    terminals[project.id] = session
                    session.start(store: launch[0], socket: launch[1], directory: project.path,
                                  executable: launch[2], arguments: Array(launch.dropFirst(3)))
                }
                try activateProjectTerminal(session, project: project, projectIndex: selected)
                dirty = true
            case 9:
                guard accountPicker == nil, savedPicker == nil, let launch, !projects.isEmpty else { break }
                let project = projects[selected]
                if let existing = terminals[project.id], !existing.canReplace {
                    tw_title(window, "Threading experiment - terminal may still be running")
                    break
                }
                // A failed creation can have persisted just after this loop's reconciliation.
                // Its row must survive discarding the finished surface for an explicit new shell.
                if reconcileTerminals() { dirty = true }
                guard terminals.count + restoredRuntimes.count + nativeRuntimes.count
                        + (composerCreationPending ? 1 : 0)
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
                    existing.stop()
                    terminals.removeValue(forKey: project.id)
                }
                let session = makeObservedTerminal()
                terminals[project.id] = session
                session.start(store: launch[0], socket: launch[1], directory: project.path,
                              executable: launch[2], arguments: Array(launch.dropFirst(3)))
                try activateProjectTerminal(session, project: project, projectIndex: selected)
                dirty = true
            case 23:
                guard accountPicker == nil, savedPicker == nil, let launch else { break }
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1])
            case 31, 32:
                guard accountPicker == nil, savedPicker == nil, let launch else { break }
                pendingFolderImport = beginFolderImport(store: launch[0], socket: launch[1],
                    choice: event.kind == 31 ? .new : .scratchpad)
            case 13, 21:
                let composerTargetID = pendingComposerProjectID
                pendingComposerProjectID = nil
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      !projects.isEmpty else { break }
                let kind: AgentKind = event.kind == 13 ? .codex : .claude
                if let targetID = composerTargetID,
                   targetID == projects[selected].id, let idlePane {
                    let accounts = kind == .codex ? codexAccounts : claudeAccounts
                    let preferred = kind == .codex ? codexAccount : claudeAccount
                    let handle = accounts.contains(preferred) ? preferred : .standard
                    composerAccount = AccountID(provider: kind, handle: handle)
                    composerPermissionMode = nil
                    composerFastMode = nil
                    composerUsesNativeUI = false
                    composerModel = nil
                    composerEffort = nil
                    composerShouldRestoreRunChoice = true
                    loadComposerModels()
                    idlePane.showComposer(projectName: projects[selected].name,
                        providerName: kind.displayName)
                    refreshComposerChoices()
                    focusSidebar(false)
                    guard tw_workspace_editor_focus(window, 1) == 0 else {
                        throw WindowFailure("native editor focus unavailable")
                    }
                    dirty = true
                    break
                }
                try beginAgent(kind, prompt: nil)
            case 3, 4:
                if event.action == 1, accountPicker == nil, savedPicker == nil,
                   !projects.isEmpty {
                    let scroll = NSEvent(type: .scrollWheel,
                        scrollingDeltaY: event.kind == 3 ? 1 : -1)
                    outlineScroll.scrollWheel(with: scroll)
                    dirty = true
                    break
                }
                guard let step = navigatorStep(for: event) else { break }
                if accountPicker != nil {
                    let next = max(0, min(pickerAccounts.count - 1,
                                          accountSelected + step))
                    if next != accountSelected { accountSelected = next; dirty = true }
                } else if let savedPicker {
                    let project = projects[savedPicker.projectIndex]
                    let savedCount = savedPicker.isAgent ? project.recentAgents.count : project.recentTerminals.count
                    let next = max(0, min(savedCount - 1, savedSelected + step))
                    if next != savedSelected { savedSelected = next; dirty = true }
                } else {
                    let next = max(0, min(sidebarRows.totalCount - 1, selectedInlineIndex + step))
                    if next != selectedInlineIndex, let row = sidebarRows.row(at: next) {
                        inlineSelection = NavigatorOutlineItem(row, projects: projects)
                        switch row {
                        case .repository(_, let projectIndex, _):
                            if projects.indices.contains(projectIndex) { selected = projectIndex }
                        case .project(let projectIndex, _),
                             .agent(let projectIndex, _, _),
                             .terminal(let projectIndex, _, _):
                            selected = projectIndex
                        }
                        outlineScrollSelection = true
                        dirty = true
                    }
                }
            case 36:
                guard accountPicker == nil, savedPicker == nil, launch != nil,
                      let item = inlineSelection,
                      item.kind == .project || item.kind == .repository else { break }
                if item.kind == .project {
                    toggleProjectExpansion(projectID: item.projectID,
                        projectIndex: item.projectIndex)
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                } else {
                    outline.expandItem(item)
                }
                dirty = true
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
                    if reconcilePendingAgents(projects: &projects, projectIndexes: projectIndexes,
                                              runtimes: &restoredRuntimes,
                                              pending: &pendingAgentProjects,
                                              publishedCounts: &publishedAgentCounts,
                                              retainedProjects: &restoredProjectIDs,
                                              onCommitted: rememberCommittedComposerChoice,
                                              onFailed: forgetFailedComposerChoice) { dirty = true }
                    guard !projects[selected].recentAgents.isEmpty else {
                        let pending = pendingAgentProjects.values.contains {
                            $0.uuidString == projects[selected].id
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
    private static func boundedAccessibilityLabel(_ value: String, maximumBytes: Int = 400) -> String {
        var result = "", bytes = 0
        for scalar in value.unicodeScalars {
            let part = String(scalar)
            let length = part.utf8.count
            if bytes + length > maximumBytes { break }
            result.append(part)
            bytes += length
        }
        return result
    }

    @MainActor private static func publishAccessibleRow(_ window: OpaquePointer, id: String,
                                                         label: String, selected: Bool,
                                                         visibleIndex: Int, width: Int, height: Int,
                                                         indent: CGFloat = 0) throws {
        let bounds = navigatorRowPixels(visibleIndex, width: width, height: height, indent: indent)
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
