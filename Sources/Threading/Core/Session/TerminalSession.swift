import AppKit
@preconcurrency import SwiftTerm
import ThreadingPTYHostKit

/// A person-originated terminal write and the semantic boundary activity actually needs.
///
/// Raw bytes alone are insufficient: a bracketed paste may contain newlines without submitting,
/// while Kitty keyboard mode encodes Return without a literal carriage return. The terminal
/// sources resolve that distinction before the tracker sees the event.
struct TerminalUserInput: Equatable {
    let bytes: [UInt8]
    let submitsLine: Bool

    /// Remote clients carry terminal bytes over one WebSocket input message. Literal Return and
    /// Kitty's CSI-u Enter both submit; one complete bracketed paste does not, regardless of the
    /// newlines in its payload.
    static func remote(bytes: [UInt8]) -> TerminalUserInput {
        let isBracketedPaste = bytes.containsSubsequence([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
            && bytes.containsSubsequence([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        let submitsLine = !isBracketedPaste
            && (bytes.contains(0x0D) || bytes.contains(0x0A) || bytes.containsKittyEnter)
        return TerminalUserInput(bytes: bytes, submitsLine: submitsLine)
    }
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        for start in 0...(count - needle.count)
        where self[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    /// Kitty's Enter is `CSI 13 ... u`; modifiers and event type, when present, live between
    /// the code point and the final `u`.
    var containsKittyEnter: Bool {
        var index = 0
        while index + 3 < count {
            guard self[index] == 0x1B, self[index + 1] == 0x5B else {
                index += 1
                continue
            }
            var cursor = index + 2
            var codePoint = 0
            var hasDigit = false
            while cursor < count, self[cursor] >= 0x30, self[cursor] <= 0x39 {
                hasDigit = true
                codePoint = codePoint * 10 + Int(self[cursor] - 0x30)
                cursor += 1
            }
            guard hasDigit, codePoint == 13 else {
                index += 1
                continue
            }
            while cursor < count {
                let byte = self[cursor]
                if byte == 0x75 { return true }
                guard (byte >= 0x30 && byte <= 0x39) || byte == 0x3B || byte == 0x3A else {
                    break
                }
                cursor += 1
            }
            index += 1
        }
        return false
    }
}

/// Manages a single terminal session including the terminal view, shell process, and session state.
@MainActor
final class TerminalSession: NSObject {

    // MARK: - Properties

    let identity: TerminalInstanceIdentity
    let terminalView: EmojiFixedTerminalView
    private(set) var title: String
    private(set) var currentDirectory: URL?
    private(set) var isRunning: Bool = false

    weak var delegate: TerminalSessionDelegate?

    /// Raw PTY output, for the remote-access mirror. Single-consumer, same doctrine as
    /// `ConversationStreamSession.onEvent`: the mirror registry is the one consumer and fans
    /// out from there. Fired on the main thread inside SwiftTerm's synchronous read hop, so the
    /// closure copies and hands off to its own queue — it must never block the PTY read loop.
    var onRawOutput: ((Data) -> Void)?

    private var profile: TerminalProfile
    /// Identifies the palette/font application that renderer findings belong to. The callback
    /// is delivered one main-queue turn later; a profile can change during that turn, and a
    /// finding from the page just left must not repopulate the notice after its invalidation.
    private var profileApplicationGeneration = 0

    /// A launch requested after SIGTERM but before SwiftTerm has finished the old lifecycle.
    ///
    /// LocalProcess deliberately remains occupied through its output drain and `windingDown`
    /// interval so an exit callback can never reap a replacement PID. Keep the user's latest
    /// launch request here and perform it from the exact old child's termination callback.
    private enum PendingLaunch {
        case shell(initialDirectory: URL?, initialCommand: ShellCommand?)
        case agent(AgentLaunchPlan)
    }
    private var pendingLaunch: PendingLaunch?

    /// The PID of the shell process, captured after starting.
    private(set) var shellPid: pid_t = 0

    // MARK: - Foreground Process

    /// The command currently holding the terminal, or nil at the shell's own prompt.
    ///
    /// Refreshed by `refreshForegroundProcess()` rather than on a timer of its own: an agent's
    /// terminal has no use for the answer, and only the owners that already poll — the
    /// standalone terminal and the shell drawer — should pay for it.
    private(set) var foregroundProcessName: String?

    /// The title a program set over OSC 0/2, or nil when nothing has named this terminal.
    ///
    /// Kept apart from `title`, which starts as the shell path and only ever grows. A reported
    /// title is dropped when the program that set it exits, because nothing else will correct
    /// it: the hook that rewrites a title at every prompt belongs to Terminal.app and is not
    /// loaded under our `TERM_PROGRAM`. Without this, quitting `vim` leaves a row named after
    /// the file forever.
    private(set) var reportedTitle: String?

    /// Which foreground group set `reportedTitle`. Nil means the shell's own — a user whose
    /// `zsh` writes a title at each prompt has said what they want this terminal called, and
    /// that title outlives every command.
    private var reportedTitleOwner: pid_t?

    private var foregroundGroup: pid_t?

    /// Whether a command rather than the shell itself currently owns the terminal.
    ///
    /// Kept separately from `foregroundProcessName`: naming is best-effort, while the foreground
    /// process-group reading itself is the exact fact the standalone terminal's activity mark
    /// needs. A command whose argument area cannot be read is still a command in progress.
    var hasForegroundProcess: Bool { foregroundGroup != nil }

    /// The primary side of the pty, which is what `tcgetpgrp` must be asked.
    ///
    /// `-1` for a host-backed session: the descriptor belongs to `threading-ptyd`, which is why
    /// the daemon pushes a `foreground` frame instead and `currentForegroundGroup()` below is the
    /// one place that knows there are two answers to the same question.
    private var ptyDescriptor: Int32 {
        terminalView.process?.childfd ?? -1
    }

    // MARK: - Background Host

    /// How this session reaches `threading-ptyd`, or nil for today's in-process `forkpty`.
    ///
    /// Named by whoever launches the session rather than resolved here, because resolving it
    /// needs the conversation record and the app's settings, and a terminal that reached into the
    /// store for its own policy would be the dependency direction this file has never had. See
    /// `PTYHostPolicy.transportFactory(for:session:…)`, which is the whole decision as one call.
    var hostTransportFactory: PTYHostTransportFactory?

    /// The live link, while this session's child lives in the background host.
    private var hostLink: PTYHostTerminalLink?

    /// The transport-queue parser belonging to `hostLink`. Invalidated before the link is
    /// replaced or cleared so a late burst from an old child cannot enter the replacement's
    /// emulator.
    private var hostOutputParser: TerminalHostOutputParser?

    /// The launch a host-backed spawn is still waiting on an answer for.
    ///
    /// Kept because a refusal is not an ending: the daemon may hold the previous incarnation of
    /// this session for a few seconds after it exited, so a stop followed at once by a start is
    /// answered `alreadyExists`. That launch has to *happen*, in-process, rather than be reported
    /// as a conversation that died before it began.
    private var hostLaunchPlan: AgentLaunchPlan?

    /// The process group the host last reported as owning the terminal.
    ///
    /// Pushed rather than polled, because `tcgetpgrp` needs a descriptor this process does not
    /// have. Nil means nothing has been reported yet, which reads the same way an in-process
    /// terminal reads a foreground group equal to its own shell: no other program is in charge.
    private var hostForegroundGroup: pid_t?

    /// Whether this session's child is owned by `threading-ptyd` rather than by this process.
    var isHostBacked: Bool { hostLink != nil }

    /// Called on the main actor once, after a reattach's replay has been fed and before any
    /// live byte is reported as this session's own work.
    ///
    /// The owner needs the boundary because the two runs of bytes mean opposite things: the
    /// replay is a repaint of a screen that already existed, and everything behind it is the
    /// child working now. See `SessionActivityTracker.endUnattendedLaunchGrace()`.
    var onHostAttachReplayFinished: (() -> Void)?

    /// The name of the profile used for this session.
    var profileName: String {
        profile.name
    }

    // MARK: - Initialization

    init(
        profile: TerminalProfile = .default,
        frame: NSRect = .zero,
        identity: TerminalInstanceIdentity = .ephemeral(UUID())
    ) {
        self.identity = identity
        self.profile = profile
        self.title = profile.shellPath
        self.terminalView = EmojiFixedTerminalView(frame: frame)

        super.init()

        setupTerminalView()
    }

    // MARK: - Setup

    private func setupTerminalView() {
        terminalView.processDelegate = self
        // Allow Option key to compose special characters (e.g., ~ on non-US keyboards)
        terminalView.optionAsMetaKey = false

        terminalView.onOutput = { [weak self] byteCount in
            guard let self else { return }
            self.delegate?.terminalSession(self, didProduceOutputOf: byteCount)
        }

        // Both halves of a bell, in the order they matter: noticed, then heard. The view no
        // longer lets SwiftTerm beep for us (see `EmojiFixedTerminalView.bell`), so this is
        // where the sound is decided — and it is decided *after* the edge, because the cause
        // the delegate works out while recording it is what the sound is chosen by.
        //
        // The ring is this session's rather than the delegate's, so a conformer that says
        // nothing still rings: nothing goes silent because somebody forgot to implement a
        // method. It happens exactly once, in one place that knows both the session and the
        // cause — which is also what lets a bell that was actually heard leave a note for the
        // attention alert about to describe this same edge, so the pair does not sound twice.
        // The note is left inside `TerminalBell`'s play step and read by
        // `AttentionAlertCenter.stateAlertSound`; it flows this way, and not the other, because
        // the ring below is synchronous while the alert's decision is a main-actor turn later.
        // See `AudibleBellRegister`.
        //
        // The owner is this terminal's own identity rather than only its session, so a
        // standalone terminal's bell resolves through *its* record and its project — a chat's
        // and a shell drawer's still resolve through the conversation, and an ephemeral
        // terminal through the app alone. See `SoundOwner`.
        terminalView.onBell = { [weak self] in
            guard let self else { return }
            let cause = self.delegate?.terminalSessionDidReceiveBell(self)
            TerminalBell.ring(cause: cause, owner: SoundOwner(self.identity))
        }

        terminalView.onMouseReportForwarded = { [weak self] in
            guard let self else { return }
            self.delegate?.terminalSessionDidForwardMouseReport(self)
        }

        terminalView.onUserInput = { [weak self] input in
            guard let self else { return }
            self.delegate?.terminalSession(self, didReceiveUserInput: input)
            guard let sessionID = self.identity.ownerSessionID else { return }
            Task { @MainActor in
                RemoteNotificationService.shared.recordOwnerInteraction(
                    sessionID: sessionID
                )
            }
        }

        terminalView.acceptsLocalInput = { [weak self] in
            guard let sessionID = self?.identity.ownerSessionID else { return true }
            return RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID)
        }
        terminalView.onLocalInputBlocked = { [weak self] in
            guard let sessionID = self?.identity.ownerSessionID else { return }
            NotificationCenter.default.post(SessionLocalInputBlocked(sessionID: sessionID))
        }

        terminalView.onOutputBytes = { [weak self] slice in
            guard let self, let onRawOutput = self.onRawOutput else { return }
            // Copy the slice out of SwiftTerm's reused buffer before it hands off.
            onRawOutput(Data(slice))
        }

        terminalView.onLowContrastText = { [weak self] conflict in
            guard let self else { return }
            let generation = self.profileApplicationGeneration
            let themeID = self.profile.theme.id.rawValue
            // The callback arrives while SwiftTerm is assembling a visible row for drawing.
            // Defer the app event one turn so a notice never changes the view hierarchy from
            // inside that draw pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.profileApplicationGeneration == generation else { return }
                NotificationCenter.default.post(TerminalTextVisibilityIssueDetected(issue: .init(
                    identity: self.identity,
                    themeID: themeID,
                    conflict: conflict
                )))
            }
        }

        applyProfile()

        // Deliberately *not* an observer of `ProfileDidChange`.
        //
        // This used to adopt whatever profile that notification carried, which was correct
        // while there was one theme for the whole app and is wrong now that a session or its
        // project can name its own: a broadcast value is exactly what a per-session override
        // must not be overwritten by. The owning `AgentSessionViewController` re-resolves this
        // session's theme instead and pushes the result through `updateProfile`.
    }

    private func applyProfile() {
        profileApplicationGeneration &+= 1
        // The renderer clears its measured pairs when the palette lands below. Clear the app's
        // corresponding finding first: if the new theme fixes the collision there will be no
        // replacement callback, so retaining the old one would explain colours no longer on
        // screen. A still-bad pair is reported again by the next visible draw.
        NotificationCenter.default.post(TerminalTextVisibilityIssuesInvalidated(
            identity: identity
        ))

        // Sampled before the palette lands so the announcement below can tell a re-apply from
        // an actual change of page.
        let previousBackground = terminalView.terminalStateSnapshot().backgroundColor

        // The terminal is the one surface whose typeface comes from TerminalProfile rather
        // than the app/conversation typography stack. `profile.font` also owns the fallback
        // when a saved family is no longer installed.
        terminalView.font = profile.font

        // Changing the font rebuilds SwiftTerm's TerminalOptions with their 500-line default,
        // so apply the user's history size afterwards on every profile refresh.
        terminalView.changeHistorySize(max(0, profile.scrollbackLines))

        // Install ANSI color palette
        let colors = profile.theme.asSwiftTermColors()
        terminalView.installColors(colors)

        // Apply theme colors
        terminalView.nativeForegroundColor = profile.theme.foreground
        // What a heading written as SGR 1 in the default colour is drawn in. Set beside the
        // foreground rather than derived from it: the palette states it.
        terminalView.nativeBoldForegroundColor = profile.theme.boldForeground
        terminalView.nativeBackgroundColor = profile.theme.background

        // Installed after the palette, because the transform is built from it. Re-installed on
        // every profile refresh rather than once at construction: the anchors are this theme's
        // hues, so a session that changes theme has to rebuild them or it keeps harmonising
        // toward the palette it left.
        terminalView.trueColorBackgroundTransform = AppSettings.harmonizesTerminalBackgrounds
            ? TerminalBackgroundHarmony.transform(for: profile.theme)
            : nil
        terminalView.selectedTextBackgroundColor = profile.theme.selection
        terminalView.caretColor = profile.theme.cursor

        // Apply cursor style
        let swiftTermStyle = swiftTermCursorStyle(from: profile.cursorStyle, blink: profile.cursorBlink)
        terminalView.cursorStyle = swiftTermStyle

        // Force redraw
        terminalView.needsDisplay = true

        // A theme changed under a running program has to be *announced*, or it never lands:
        // Claude asks what colour the terminal is once, at startup (`OSC 11 ; ?`), and keeps
        // that answer for the whole session — repainting the view moves nothing on its side,
        // which is precisely the white-on-white diff. It does subscribe to colour-scheme
        // reports (`DECSET 2031`), and the report is a prompt to *re-ask*, not the news
        // itself — so it must be sent only after the palette above is in place, and it moves
        // nothing unless the answer to the re-ask has actually changed. Gated on the
        // background actually changing so font tweaks and re-applies stay silent.
        let backgroundChanged = terminalView.terminalStateSnapshot().backgroundColor != previousBackground
        terminalView.updateColorScheme(
            profile.theme.hasDarkBackground ? .dark : .light,
            notify: backgroundChanged
        )
        if backgroundChanged {
            promptColorRereadThroughFocus()
        }
    }

    // MARK: - Prompting a Program That Only Re-Reads on Focus

    /// A theme change waiting for the terminal to be looked at again.
    ///
    /// Set when the palette moved while this terminal was not the focused one, because the
    /// prompt below is only truthful when it is. The observer is registered on demand and torn
    /// down on delivery, so a session that never changes theme observes nothing.
    private var isAwaitingFocusForColorPrompt = false
    private let focusColorPromptObservations = AppEventObservations()

    /// Re-sends this terminal's focus state as a second prompt to re-read the palette.
    ///
    /// `DECSET 2031` is the mechanism designed for this and is what SwiftTerm's
    /// `updateColorScheme(_:notify:)` above honors. Codex does not implement it (filed as
    /// openai/codex#38575) and instead
    /// re-reads `OSC 10/11` when it is told focus was gained, so a focus report is the only
    /// prompt it can hear. Measured against a bare PTY: 0.146.0 answers a synthetic focus
    /// report with a fresh `OSC 10 ; ?` / `OSC 11 ; ?` pair and repaints its composer, while
    /// 0.147.0 removed that path and ignores it (openai/codex#18942). So this is inert on
    /// current Codex, works on older ones, and starts working again when that issue is fixed.
    /// **Delete it once both are answered** rather than leaving a synthetic focus report in the
    /// stream forever.
    ///
    /// Two things keep it safe. `setTerminalFocus` sends nothing unless the program asked for
    /// focus reports (`DECSET 1004`), so a program that never opted in sees no stray bytes. And
    /// it is only sent while this terminal really is focused, so the report stays a true
    /// statement — a prompt to re-ask, never a claim about where the user is looking.
    private func promptColorRereadThroughFocus() {
        // `applyProfile` also runs once from `init`, where the background moves from SwiftTerm's
        // own default to this theme's and there is no program yet to prompt. Without this every
        // session would arm the carried prompt below at construction and spend it on a stray
        // focus report the first time the user looked at the terminal.
        guard profileApplicationGeneration > 1 else { return }

        if terminalView.hasFocus {
            deliverFocusColorPrompt()
            return
        }
        // Not focused, so there is nothing truthful to send yet. A theme can perfectly well move
        // behind the app's back: macOS going dark at sunset under an adaptive theme is the
        // ordinary case. SwiftTerm reports focus from the responder hooks alone, so a window
        // merely becoming key again emits nothing on its own and a terminal that stayed first
        // responder would never be prompted. Carry it to the moment the user is looking.
        guard !isAwaitingFocusForColorPrompt else { return }
        isAwaitingFocusForColorPrompt = true
        focusColorPromptObservations.observe(NSWindow.didBecomeKeyNotification) { [weak self] in
            guard let self, self.isAwaitingFocusForColorPrompt, self.terminalView.hasFocus else {
                return
            }
            self.isAwaitingFocusForColorPrompt = false
            self.focusColorPromptObservations.removeAll()
            self.deliverFocusColorPrompt()
        }
    }

    private func deliverFocusColorPrompt() {
        terminalView.setTerminalFocus(true)
    }

    private func swiftTermCursorStyle(from style: TerminalProfile.CursorStyle, blink: Bool) -> CursorStyle {
        switch style {
        case .block:
            return blink ? .blinkBlock : .steadyBlock
        case .underline:
            return blink ? .blinkUnderline : .steadyUnderline
        case .bar:
            return blink ? .blinkBar : .steadyBar
        }
    }

    // MARK: - Shell Management

    func startShell() {
        startShell(initialDirectory: nil)
    }

    func startShell(initialDirectory: URL?) {
        startShell(initialDirectory: initialDirectory, initialCommand: nil)
    }

    /// Starts a project terminal with one host-built command already in its process arguments.
    ///
    /// Typing that source after spawning the shell is not equivalent. macOS caps the complete
    /// tty input queue at 1024 bytes, so a multi-provider update or one valid 4 KiB project script
    /// can be silently duplicated or dropped when it is queued before the shell begins reading.
    /// A clean interactive bootstrap preserves foreground-job interruption, runs the command in
    /// the visible PTY, then replaces itself with the person's configured shell.
    func startShell(initialDirectory: URL, running initialCommand: ShellCommand) {
        startShell(initialDirectory: initialDirectory, initialCommand: initialCommand)
    }

    private func startShell(initialDirectory: URL?, initialCommand: ShellCommand?) {
        guard !isRunning else { return }

        guard !terminalView.process.running, !terminalView.process.windingDown else {
            pendingLaunch = .shell(
                initialDirectory: initialDirectory,
                initialCommand: initialCommand
            )
            return
        }

        launchShell(initialDirectory: initialDirectory, initialCommand: initialCommand)
    }

    private func launchShell(initialDirectory: URL?, initialCommand: ShellCommand?) {
        let environment = buildEnvironment()

        if let initialCommand {
            guard let initialDirectory else {
                preconditionFailure("A terminal startup command requires an execution directory")
            }

            var configuredShell = ShellCommand(word: profile.shellPath)
            for argument in profile.shellArguments {
                configuredShell.append(word: argument)
            }
            var resumedShell = ShellCommand(word: "exec")
            resumedShell.append(contentsOf: configuredShell)

            var bootstrap = ShellCommand(word: ProjectTerminalDefaults.bootstrapShell)
            for argument in ProjectTerminalDefaults.bootstrapArguments {
                bootstrap.append(word: argument)
            }
            bootstrap.append(word: initialCommand.source + "; " + resumedShell.source)

            let source = ShellCommand.executing(bootstrap, in: initialDirectory.path)
            terminalView.startProcess(
                executable: "/bin/sh",
                args: ["-c", source.source],
                environment: environment,
                execName: (profile.shellPath as NSString).lastPathComponent
            )
            finishProcessStart()
            return
        }

        if let dir = initialDirectory {
            var shell = ShellCommand(word: profile.shellPath)
            for argument in profile.shellArguments {
                shell.append(word: argument)
            }
            let source = ShellCommand.executing(shell, in: dir.path)

            terminalView.startProcess(
                executable: "/bin/sh",
                args: ["-c", source.source],
                environment: environment,
                execName: (profile.shellPath as NSString).lastPathComponent
            )
        } else {
            terminalView.startProcess(
                executable: profile.shellPath,
                args: profile.shellArguments,
                environment: environment,
                execName: (profile.shellPath as NSString).lastPathComponent
            )
        }

        finishProcessStart()
    }

    /// Starts an agent using a resolved launch plan.
    ///
    /// Unlike `startShell`, the plan already encodes the working directory and the agent
    /// command, so the process is started verbatim.
    func start(plan: AgentLaunchPlan) {
        guard !isRunning else { return }

        guard !terminalView.process.running, !terminalView.process.windingDown else {
            pendingLaunch = .agent(plan)
            return
        }

        launchAgent(plan: plan)
    }

    private func launchAgent(plan: AgentLaunchPlan) {
        // The host-backed path first, and falling through to the local one on every refusal:
        // there is exactly one behaviour to degrade to and it is the one below, unchanged.
        if launchAgentThroughHost(plan: plan) { return }

        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: buildEnvironment(),
            execName: (plan.executable as NSString).lastPathComponent
        )

        finishProcessStart()
    }

    /// Starts the same command line in `threading-ptyd`, answering whether it did.
    ///
    /// The plan, the environment and the working directory are composed **exactly** as the local
    /// path composes them and handed over verbatim: the daemon inherits launchd's environment
    /// rather than the user's, and the composition rules — `AgentEnvironment`'s inherited-identity
    /// prefixes, the measured leakage list in `sessions.md`, `AgentLauncher`'s login-shell command
    /// line — are one decision that stays in one place, here. The daemon adds nothing.
    ///
    /// The grid is the view's real one. It is not defended against a placeholder here on purpose:
    /// the deferred-launch gate that makes it real — layout at a genuine frame before the launch,
    /// then `startIfTerminalIsSized` — is the same gate the local `forkpty` depends on for the
    /// same reason, and a second, differently-drawn threshold in this method would be a second
    /// place for that rule to be wrong.
    private func launchAgentThroughHost(plan: AgentLaunchPlan) -> Bool {
        guard let hostTransportFactory else { return false }
        // Version 1 hosts agent sessions only; every other surface still polls a descriptor.
        guard case .agentSession = identity else { return false }

        let size = terminalView.getWindowSize()
        guard size.ws_col > 0, size.ws_row > 0 else { return false }

        let hostIdentity = PTYHostSessionIdentity(identity)
        let link = PTYHostTerminalLink(identity: hostIdentity)
        let outputParser = terminalView.makeHostOutputParser()
        link.delivery = hostDelivery(for: link, outputParser: outputParser)

        do {
            link.adopt(try hostTransportFactory(link.events()))
            try link.spawn(PTYHostSpawnRequest(
                id: hostIdentity,
                channel: .pty(grid: PTYHostGrid(
                    cols: Int(size.ws_col),
                    rows: Int(size.ws_row),
                    xpixel: Int(size.ws_xpixel),
                    ypixel: Int(size.ws_ypixel)
                )),
                executable: plan.executable,
                arguments: plan.arguments,
                execName: (plan.executable as NSString).lastPathComponent,
                environment: buildEnvironment(),
                cwd: nil
            ))
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            EventLog.shared.record(
                .session,
                "Session runs its PTY in-process",
                ["session": identity.historyFileStem, "cause": cause]
            )
            ThreadingLogger.ptyHost.error(
                """
                PTY host could not start this session: \(cause, privacy: .public); \
                running the PTY in-process
                """
            )
            return false
        }

        hostOutputParser?.invalidate()
        hostLink = link
        hostOutputParser = outputParser
        hostLaunchPlan = plan
        terminalView.hostTransport = TerminalHostTransport(
            sendInput: { [weak link] bytes in link?.sendInput(bytes) },
            sendWindowSize: { [weak link] size in link?.sendWindowSize(size) ?? false },
            kill: { [weak link] in link?.kill() }
        )
        // Running from the moment the spawn request left, rather than from the `spawned` answer:
        // a stop arriving in between has to reach the daemon, and the pid the answer carries is
        // what `effectiveWorkingDirectory()` needs, not what "is this session running" means.
        isRunning = true
        return true
    }

    /// Takes back a child `threading-ptyd` has been holding since the last quit.
    ///
    /// The counterpart of `launchAgentThroughHost` and deliberately **not** a launch: nothing is
    /// spawned, no command line is built, no launch record is written. The conversation never
    /// stopped, so there is nothing to resume — this reconnects a terminal to a process that has
    /// been running the whole time.
    ///
    /// `grid` is the daemon's, and the emulator adopts it before a byte of the replay lands. An
    /// attach never resizes, so a screen written at 100×40 is rendered at 100×40; imposing this
    /// window's grid first and reflowing afterwards would be a screen nobody ever saw, and would
    /// raise `SIGWINCH` on an agent that has been working at that size all along.
    ///
    /// Answers whether the attach was sent. False is not a failure of the session: the caller's
    /// answer is to leave the row dormant, and the ordinary resume still works.
    @discardableResult
    func attachToHost(grid: PTYHostGrid) -> Bool {
        guard !isRunning else { return false }
        guard let hostTransportFactory else { return false }
        // Version 1 hosts agent sessions only, exactly as the spawn path does.
        guard case .agentSession = identity else { return false }

        let hostIdentity = PTYHostSessionIdentity(identity)
        let link = PTYHostTerminalLink(identity: hostIdentity)
        let outputParser = terminalView.makeHostOutputParser()
        link.delivery = hostDelivery(for: link, outputParser: outputParser)

        do {
            link.adopt(try hostTransportFactory(link.events()))
            try link.attach(PTYHostAttach(
                id: hostIdentity,
                replayBudget: PTYHostSessionDefaults.reattachReplayBudget
            ))
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            EventLog.shared.record(
                .session,
                "Session could not be taken back from the PTY host",
                ["session": identity.historyFileStem, "cause": cause]
            )
            ThreadingLogger.ptyHost.error(
                """
                PTY host could not hand this session back: \(cause, privacy: .public); \
                the conversation stays dormant
                """
            )
            return false
        }

        hostOutputParser?.invalidate()
        hostLink = link
        hostOutputParser = outputParser
        terminalView.hostTransport = TerminalHostTransport(
            sendInput: { [weak link] bytes in link?.sendInput(bytes) },
            sendWindowSize: { [weak link] size in link?.sendWindowSize(size) ?? false },
            kill: { [weak link] in link?.kill() }
        )
        // Running from the moment the attach left, for the same reason the spawn path is: a stop
        // arriving in between has to reach the daemon.
        isRunning = true

        // After the transport, and still ahead of every replayed byte: the daemon's answer is
        // delivered on a later main-queue turn and this call is on the current one. Adopting the
        // grid makes SwiftTerm report a resize straight back, and nothing of it reaches the
        // daemon: the link compares the wanted grid with the one the daemon has acknowledged and
        // sends only a difference, so the size the daemon told us in the first place is silence
        // and a window that genuinely moved is one frame.
        terminalView.adoptHostGrid(cols: grid.cols, rows: grid.rows)
        return true
    }

    /// Hands this session's child back to `threading-ptyd` instead of ending it.
    ///
    /// The two seeds are computed here because only this process can: a repaint is derived from a
    /// live emulator and the daemon has none. `ringOffset` travels with them from the link, and
    /// together they are what makes the next launch's replay exact rather than a cut.
    ///
    /// Answers whether there was a child to hand over. **Blocking, bounded by `deadline`** — see
    /// `PTYHostTerminalLink.detach(screenSeed:modeSeed:by:)`; this is the quit path, where the
    /// close after the frame is the process exiting.
    @discardableResult
    func detachFromHost(by deadline: Date) -> Bool {
        guard let hostLink else { return false }

        let terminal = terminalView.terminalStateSnapshot()
        let sent = hostLink.detach(
            screenSeed: RemoteScreenSeed.repaint(of: terminal),
            modeSeed: RemoteTerminalModeSeed.bytes(for: RemoteTerminalModes(terminal)),
            by: deadline
        )

        hostOutputParser?.invalidate()
        hostOutputParser = nil
        self.hostLink = nil
        hostLaunchPlan = nil
        hostForegroundGroup = nil
        terminalView.hostTransport = nil
        // Not `handleProcessTermination`: nothing terminated. The session stops being *this*
        // process's without becoming an ending anybody is told about.
        isRunning = false
        shellPid = 0
        return sent
    }

    /// The edges of a host-backed session. Live parsing stays on the transport queue; lifecycle
    /// and output reporting arrive on main.
    ///
    /// Every one of them is guarded by the link still being *this* session's. A stop followed at
    /// once by a relaunch leaves the previous link alive until the daemon answers it, and its
    /// late `exited` must not end the launch that replaced it.
    private func hostDelivery(
        for link: PTYHostTerminalLink,
        outputParser: TerminalHostOutputParser
    ) -> PTYHostTerminalLink.Delivery {
        PTYHostTerminalLink.Delivery(
            parseOutput: { segment in
                outputParser.feed(segment.bytes)
            },
            output: { [weak self, weak link] segments in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    for segment in segments {
                        if segment.requiresMainActorParse {
                            self.terminalView.feedFromHost(
                                segment.bytes,
                                answersQueries: segment.answersQueries
                            )
                        } else {
                            self.terminalView.reportHostOutput(segment.bytes)
                        }
                    }
                }
            },
            spawned: { [weak self, weak link] spawned in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.hostDidSpawn(pid: spawned.pid)
                }
            },
            attached: { [weak self, weak link] attached in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.hostDidAttach(attached)
                }
            },
            attachReplayFinished: { [weak self, weak link] in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.onHostAttachReplayFinished?()
                }
            },
            foreground: { [weak self, weak link] group in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.hostForegroundGroup = group
                }
            },
            ended: { [weak self, weak link] exitCode, cause in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.hostDidEnd(exitCode: exitCode, cause: cause)
                }
            },
            refused: { [weak self, weak link] reason in
                MainActor.assumeIsolated {
                    guard let self, let link, self.hostLink === link else { return }
                    self.hostDidRefuseSpawn(reason)
                }
            }
        )
    }

    /// The child exists. `shellPid` is what keeps `effectiveWorkingDirectory()` and
    /// `AgentRuntime.terminalRootProcessIdentifier` answering for a session whose pty moved.
    private func hostDidSpawn(pid: pid_t) {
        guard pid > 0 else { return }
        hostLaunchPlan = nil
        shellPid = pid
        delegate?.terminalSessionDidStart(self)
    }

    /// The daemon handed the child back, ahead of the replay bytes.
    ///
    /// The grid is adopted again because this frame is the authoritative one — the summary the
    /// launch attached from was a moment older — and re-adopting a grid already in force costs
    /// nothing: `adoptHostGrid` refuses a resize that would not change anything, and SwiftTerm's
    /// resize path ends in `softReset()`.
    private func hostDidAttach(_ attached: PTYHostAttached) {
        terminalView.adoptHostGrid(cols: attached.grid.cols, rows: attached.grid.rows)
        guard attached.pid > 0 else { return }
        shellPid = attached.pid
        delegate?.terminalSessionDidStart(self)
    }

    /// The daemon would not start this child, so this launch runs in-process instead.
    ///
    /// The same degradation every other unavailability gets, arrived at one step later — and
    /// emphatically not a termination: nothing started, so reporting an exit would record a
    /// launch failure against a conversation that has not been launched. The common case is
    /// `alreadyExists`, because the daemon keeps an exited session for a few seconds so a late
    /// watcher can still be told how it ended, and a stop followed straight away by a start
    /// arrives inside that window.
    private func hostDidRefuseSpawn(_ reason: PTYHostSpawnRefusal) {
        EventLog.shared.record(
            .session,
            "Session runs its PTY in-process",
            ["session": identity.historyFileStem, "cause": "spawnRefused.\(reason.rawValue)"]
        )
        ThreadingLogger.ptyHost.warning(
            """
            PTY host refused the spawn (\(reason.rawValue, privacy: .public)); \
            running the PTY in-process
            """
        )

        hostOutputParser?.invalidate()
        hostOutputParser = nil
        hostLink = nil
        hostForegroundGroup = nil
        terminalView.hostTransport = nil

        guard let plan = hostLaunchPlan else { return }
        hostLaunchPlan = nil
        terminalView.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: buildEnvironment(),
            execName: (plan.executable as NSString).lastPathComponent
        )
        finishProcessStart()
    }

    private func hostDidEnd(exitCode: Int32?, cause: String?) {
        if let cause {
            EventLog.shared.record(
                .session,
                "Host-backed session ended without an exit status",
                ["session": identity.historyFileStem, "cause": cause]
            )
        }
        hostOutputParser?.invalidate()
        hostOutputParser = nil
        hostLink = nil
        hostLaunchPlan = nil
        hostForegroundGroup = nil
        terminalView.hostTransport = nil
        handleProcessTermination(exitCode: exitCode)
        NotificationCenter.default.post(PTYHostMayHaveDrained())
    }

    /// `LocalProcess` now uses `forkpty`, which returns the exact child synchronously. Keeping
    /// that identity at the launch seam avoids attributing one session's process to another
    /// when several sessions start alongside unrelated app helpers.
    private func finishProcessStart() {
        guard terminalView.process.running, terminalView.process.shellPid > 0 else { return }
        shellPid = terminalView.process.shellPid
        isRunning = true
        delegate?.terminalSessionDidStart(self)
    }

    /// Terminates the child process and closes the PTY.
    ///
    /// This must actually tear the process down rather than wait for deallocation, so a
    /// session going dormant releases its PTY and file descriptors immediately.
    func terminate() {
        // A second stop while an old child is being reaped cancels a queued rapid restart.
        pendingLaunch = nil
        guard isRunning else { return }

        if let hostLink {
            // The child is the daemon's, so the view has no process to tear down — and must not
            // pretend otherwise. Input stops leaving at once; the link stays until the daemon
            // answers `exited`, because a watcher is owed the ending and the ending is what
            // drives the same termination path a local exit drives.
            //
            // The reattach slice replaces this with `detach`, which hands the session over
            // instead of ending it. Until then a session nothing references is killed rather
            // than left working somewhere no surface can reach.
            terminalView.hostTransport = nil
            hostLink.kill()
        } else {
            terminalView.terminate()
        }
        isRunning = false
        shellPid = 0
    }

    /// The environment the child is launched into.
    ///
    /// Not `private`: `TerminalColorQueryTests` reads it back, because what this hands a child is
    /// the whole of what the child knows about the palette before it draws anything.
    func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment

        // Drop the launching process's own agent identity. These describe whoever started
        // Threading — if that was itself an agent session, every session spawned here would
        // inherit its identifiers and believe it was a nested child of that conversation.
        for key in env.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
            env.removeValue(forKey: key)
        }

        env[EnvironmentKeys.term] = TerminalDefaults.terminalType
        env[EnvironmentKeys.colorTerm] = TerminalDefaults.colorTerm
        env[EnvironmentKeys.shell] = profile.shellPath
        env["TERM_PROGRAM"] = "Threading"

        // Says whether this session's page is paper or ink, before the child draws anything —
        // the standing answer behind the `OSC 11` handshake, which an agent asks for in its
        // first few bytes and gives up on quickly. Set from `profile`, so it is this session's
        // palette rather than the app's: two sessions side by side may not agree. Always
        // written, never defaulted-to: Threading inherits launchd's environment, and whatever a
        // terminal that started the app happened to leave here describes *that* terminal.
        env[EnvironmentKeys.colorFGBG] = profile.theme.colorFGBG

        // The same inheritance, one step further. A caller with nothing watching its output
        // flattens the environment on the way in — `NO_COLOR=1`, `PAGER=cat` — and every one of
        // those claims is about *that* stream. The stream here is a PTY this app draws, so all
        // of them are false by the time a session sees them, and unlike `TERM` above they were
        // never restated. The first thing it costs is not a hue but a rank: the agent CLIs mark
        // their own chrome with bare SGR 2 (faint), so under `NO_COLOR` a proposed prompt
        // reaches the terminal at exactly the strength of one the user typed, and the missing
        // faint reads as a rendering bug on this side of the PTY.
        //
        // Cleared, not answered: absence is how "colour is fine" is spelled, and a pager is the
        // login shell's to choose on the way back up.
        env.removeValue(forKey: EnvironmentKeys.noColor)
        for key in EnvironmentKeys.colorVetoes where env[key] == "0" {
            env.removeValue(forKey: key)
        }
        for key in EnvironmentKeys.pagers where env[key] == EnvironmentKeys.nonPager {
            env.removeValue(forKey: key)
        }

        if env[EnvironmentKeys.lang] == nil {
            env[EnvironmentKeys.lang] = "en_US.UTF-8"
        }

        // Per-session history file
        HistoryManager.prepareHistoryFile(for: identity)
        let historyPath = HistoryManager.historyFilePath(for: identity)
        env["HISTFILE"] = historyPath.path

        // The opt-in `PATH` entry for Threading's own command-line tools. Applied through
        // `AgentEnvironment` rather than here, because it is a rule about what the app launches
        // rather than about how a terminal is drawn, and the headless path needs the same one.
        return AgentEnvironment.applyingCommandLineTools(to: env)
            .map { "\($0.key)=\($0.value)" }
    }

    // MARK: - Profile Management

    func updateProfile(_ newProfile: TerminalProfile) {
        self.profile = newProfile
        applyProfile()
    }

    func increaseFontSize() {
        profile.fontSize = min(profile.fontSize + 1, 72)
        applyProfile()
    }

    func decreaseFontSize() {
        profile.fontSize = max(profile.fontSize - 1, 8)
        applyProfile()
    }

    // MARK: - Working Directory

    /// Returns the effective working directory for this session.
    /// First checks if OSC 7 reported a directory, then falls back to querying the shell process.
    func effectiveWorkingDirectory() -> URL? {
        // If we already have a directory from OSC 7, use that
        if let currentDirectory = currentDirectory {
            return currentDirectory
        }

        // Otherwise, query the shell process directly
        guard shellPid > 0 else { return nil }
        return ProcessUtility.workingDirectory(forPid: shellPid)
    }

    // MARK: - AI Integration

    /// Inserts text at the current cursor position (e.g., a generated command).
    /// This sends the text to the PTY as if the user typed it.
    func insertText(_ text: String) {
        if let sessionID = identity.ownerSessionID,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            return
        }
        terminalView.sendUserText(text)
    }

    /// Inserts text the way a paste arrives, rather than the way typing does.
    ///
    /// The difference is load-bearing and is not about speed: both agent CLIs treat one arriving
    /// bracketed paste as a unit and read it as an image when the whole of it is a path with an
    /// image extension, while the same bytes typed stay text. It is how a dropped screenshot
    /// becomes an attachment, and how `SessionContextHandoff` hands a commented-on attachment to
    /// a terminal session. See `TerminalDrop` for the escaping that survives the trip.
    func pasteText(_ text: String) {
        if let sessionID = identity.ownerSessionID,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            return
        }
        terminalView.pasteUserText(text)
    }

    /// Sends raw bytes to the PTY as if typed — the entry point for remote keyboard input.
    func sendRemoteInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        delegate?.terminalSession(self, didReceiveUserInput: .remote(bytes: bytes))
        terminalView.sendRemote(bytes[...])
    }

    /// The grid the phones watching this session currently hold it at, or nil when the Mac's own
    /// frame decides.
    var remoteViewport: (cols: Int, rows: Int)? {
        terminalView.remoteGrid
    }

    /// Lets the actively controlling phone own the shared PTY grid. SwiftTerm's ordinary resize
    /// path applies the winsize and raises SIGWINCH, so Claude Code/Codex redraw at mobile width.
    func setRemoteViewport(cols: Int, rows: Int) {
        terminalView.setRemoteGrid(cols: cols, rows: rows)
        delegate?.terminalSession(self, remoteViewportChangedTo: (cols, rows))
    }

    /// Restores the natural Mac grid after the phone closes or loses its interactive socket.
    func clearRemoteViewport() {
        terminalView.clearRemoteGrid()
        delegate?.terminalSession(self, remoteViewportChangedTo: nil)
    }

    /// The terminal's current character grid, sent to a joining remote client so it sizes its
    /// own renderer to match rather than reflowing the shared PTY.
    var characterGrid: (cols: Int, rows: Int) {
        let dimensions = terminalView.terminalDimensions
        return (dimensions.cols, dimensions.rows)
    }

    /// The visible screen as plain text rows, for a reader matching words on it.
    ///
    /// `translateToString` hands a blank cell back as U+0000, not a space — the same trap
    /// `RemoteScreenSeed` documents — so the gaps a TUI leaves between words are mapped before
    /// any caller compares text. Rows follow what is *displayed* (`getLine` is scroll-relative),
    /// which is the right frame for reading a prompt the user could answer.
    func visibleScreenLines() -> [String] {
        terminalView.terminalStateSnapshot().visibleRows.map(\.text)
    }

    /// Whether a program other than this session's own command holds the terminal **right now**.
    ///
    /// The same judgement the title makes — a foreground process group that is not the session's
    /// shell is a command running *in* the terminal rather than the thing the terminal is — and
    /// deliberately not the same reading. `refreshForegroundProcess()` caches its answer for a
    /// row that repaints once a second; this is asked at the byte, because a second-old answer
    /// is not an answer about the bell that just arrived. Two syscalls, and only ever behind the
    /// gate that says someone asked to hear the distinction.
    func foregroundIsAnotherProgram() -> Bool {
        guard isRunning, shellPid > 0 else { return false }
        return currentForegroundGroup() != nil
    }

    /// Which process group owns this terminal, or nil when the session's own command does.
    ///
    /// Two sources, one answer. An in-process session asks its own master with `tcgetpgrp`. A
    /// host-backed one has no master to ask — `ptyDescriptor` is `-1` — and is *told* instead, by
    /// the `foreground` frame the daemon pushes whenever the value changes. That frame exists for
    /// exactly this: it is one syscall with no bytes in it, so a daemon that parses nothing can
    /// still answer it, and it is the only fact about a host-backed terminal the app cannot
    /// recover from the emulator it still owns.
    ///
    /// The nil rule is the same on both sides — `foregroundProcessGroup(ofPTY:shellPid:)` reports
    /// nothing when the group *is* the session's own command — so no caller has to know which
    /// side answered.
    private func currentForegroundGroup() -> pid_t? {
        guard isHostBacked else {
            return ProcessUtility.foregroundProcessGroup(
                ofPTY: ptyDescriptor,
                shellPid: shellPid
            )
        }
        guard let group = hostForegroundGroup, group > 0, group != shellPid else { return nil }
        return group
    }

    /// Re-reads which command owns the terminal, and retires a title whose owner has gone.
    ///
    /// Returns whether either answer moved, so a caller can repaint on the tick that changed
    /// something instead of on every tick.
    @discardableResult
    func refreshForegroundProcess() -> Bool {
        guard isRunning, shellPid > 0 else {
            let changed = hasForegroundProcess || foregroundProcessName != nil || reportedTitle != nil
            clearForegroundState()
            return changed
        }

        var changed = false
        let group = currentForegroundGroup()
        let hadForegroundProcess = hasForegroundProcess

        if group != foregroundGroup {
            foregroundGroup = group
            // `processName` copies the kernel's argument area for the process, which is far
            // more than a once-a-second poll should repeat — so it is read only when the group
            // actually changes, and the name is held until it changes again.
            let name = group.flatMap { ProcessUtility.processName(forPid: $0) }
            if name != foregroundProcessName {
                foregroundProcessName = name
                changed = true
            }
        }

        // The sidebar's working mark follows ownership, not whether the kernel also yielded a
        // printable process name. Preserve that edge even when `processName` returns nil.
        if hadForegroundProcess != hasForegroundProcess {
            changed = true
        }

        if let owner = reportedTitleOwner, owner != group {
            reportedTitleOwner = nil
            if reportedTitle != nil {
                reportedTitle = nil
                changed = true
            }
        }

        return changed
    }

    private func clearForegroundState() {
        foregroundProcessName = nil
        reportedTitle = nil
        reportedTitleOwner = nil
        foregroundGroup = nil
    }

}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        delegate?.terminalSession(self, sizeChangedTo: newCols, rows: newRows)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
        self.reportedTitle = title
        // Recorded at the moment of the report, not read back later: by the next poll the
        // program may already have exited, and the title would then look like the shell's.
        self.reportedTitleOwner = currentForegroundGroup()
        delegate?.terminalSession(self, titleChangedTo: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let directory = directory {
            self.currentDirectory = URL(fileURLWithPath: directory)
        } else {
            self.currentDirectory = nil
        }
        delegate?.terminalSession(self, directoryChangedTo: currentDirectory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleProcessTermination(exitCode: exitCode)
    }
}

// MARK: - Termination

extension TerminalSession {

    /// The one ending, whichever process owned the child.
    ///
    /// `LocalProcessTerminalViewDelegate.processTerminated` reaches it for an in-process pty and
    /// the daemon's `exited` frame reaches it for a host-backed one, so a rapid restart, a
    /// retired title and the delegate's exit notice behave identically on both paths — which is
    /// the whole claim host-backing makes.
    fileprivate func handleProcessTermination(exitCode: Int32?) {
        isRunning = false
        shellPid = 0
        // Nothing is in the foreground of a terminal with no process, and a title the dead
        // program left behind must not outlive it into the next launch.
        clearForegroundState()

        if let pendingLaunch {
            self.pendingLaunch = nil
            switch pendingLaunch {
            case .shell(let initialDirectory, let initialCommand):
                launchShell(
                    initialDirectory: initialDirectory,
                    initialCommand: initialCommand
                )
            case .agent(let plan):
                launchAgent(plan: plan)
            }
            return
        }

        delegate?.terminalSession(self, didTerminateWithExitCode: exitCode)
    }
}

// MARK: - TerminalSessionDelegate

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func terminalSessionDidStart(_ session: TerminalSession)
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String)
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?)
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int)
    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    )
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?)
    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int)
    func terminalSession(_ session: TerminalSession, didReceiveUserInput input: TerminalUserInput)

    /// A `BEL` arrived: record whatever activity edge it means, and answer why it rang.
    ///
    /// `nil` — the default, and the answer from every surface with no activity tracker — means
    /// the delegate cannot say. The session rings either way.
    func terminalSessionDidReceiveBell(_ session: TerminalSession) -> SoundEvent?
    func terminalSessionDidForwardMouseReport(_ session: TerminalSession)
}

// MARK: - Default Delegate Implementation

extension TerminalSessionDelegate {
    func terminalSessionDidStart(_ session: TerminalSession) {}
    func terminalSession(_ session: TerminalSession, titleChangedTo title: String) {}
    func terminalSession(_ session: TerminalSession, directoryChangedTo directory: URL?) {}
    func terminalSession(_ session: TerminalSession, sizeChangedTo cols: Int, rows: Int) {}
    func terminalSession(
        _ session: TerminalSession,
        remoteViewportChangedTo grid: (cols: Int, rows: Int)?
    ) {}
    func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {}
    func terminalSession(_ session: TerminalSession, didProduceOutputOf byteCount: Int) {}
    func terminalSession(_ session: TerminalSession, didReceiveUserInput input: TerminalUserInput) {}
    func terminalSessionDidReceiveBell(_ session: TerminalSession) -> SoundEvent? { nil }
    func terminalSessionDidForwardMouseReport(_ session: TerminalSession) {}
}

// MARK: - RemoteTerminalSurface

extension TerminalSession: RemoteTerminalSurface {
    var remoteTerminalState: RemoteTerminalState {
        let terminal = terminalView.terminalStateSnapshot()
        return RemoteTerminalState(
            grid: RemoteTerminalGrid(
                cols: terminal.dimensions.cols,
                rows: terminal.dimensions.rows),
            title: title,
            remoteViewport: remoteViewport.map {
                RemoteTerminalGrid(cols: $0.cols, rows: $0.rows)
            },
            modes: RemoteTerminalModes(terminal)
        )
    }

    var remoteTerminalSnapshot: RemoteTerminalSnapshot {
        let terminal = terminalView.terminalStateSnapshot()
        let state = RemoteTerminalState(
            grid: RemoteTerminalGrid(
                cols: terminal.dimensions.cols,
                rows: terminal.dimensions.rows),
            title: title,
            remoteViewport: remoteViewport.map {
                RemoteTerminalGrid(cols: $0.cols, rows: $0.rows)
            },
            modes: RemoteTerminalModes(terminal))
        return RemoteTerminalSnapshot(
            grid: state.grid,
            title: state.title,
            screenSeed: RemoteScreenSeed.repaint(of: terminal),
            remoteViewport: state.remoteViewport,
            modes: state.modes
        )
    }

    func setRemoteOutputSink(_ sink: RemoteTerminalOutputSink?) {
        onRawOutput = sink
    }

    func setRemoteViewport(_ grid: RemoteTerminalGrid?) {
        if let grid {
            setRemoteViewport(cols: grid.cols, rows: grid.rows)
        } else {
            clearRemoteViewport()
        }
    }
}
