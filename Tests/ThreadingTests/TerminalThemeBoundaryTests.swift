import XCTest
@testable import SwiftTerm
@testable import Threading

/// The terminal is a SwiftTerm rendering surface whose scrollbar is application chrome.
/// SwiftTerm retains its scrolling behavior while `EmojiFixedTerminalView` replaces the stock
/// scroller with the same themed component used elsewhere. These pin both halves of that seam.
@MainActor
final class TerminalThemeBoundaryTests: XCTestCase {

    func testTerminalIdentityKeepsProjectTerminalsOutOfTheSessionDomain() {
        let raw = UUID()
        let session = SessionID(raw)
        let terminal = TerminalID(raw)

        XCTAssertEqual(
            TerminalInstanceIdentity.agentSession(session).ownerSessionID,
            session
        )
        XCTAssertNil(TerminalInstanceIdentity.projectTerminal(terminal).ownerSessionID)
        XCTAssertEqual(
            TerminalInstanceIdentity.projectTerminal(terminal).historyFileStem,
            "terminal-\(terminal.uuidString)"
        )
        XCTAssertEqual(
            TerminalInstanceIdentity.sessionShell(session).historyFileStem,
            "shell-\(session.uuidString)"
        )
        XCTAssertNotEqual(
            TerminalInstanceIdentity.agentSession(session).historyFileStem,
            TerminalInstanceIdentity.sessionShell(session).historyFileStem
        )
        XCTAssertEqual(
            Set([
                TerminalInstanceIdentity.agentSession(session).historyFileStem,
                TerminalInstanceIdentity.projectTerminal(terminal).historyFileStem,
                TerminalInstanceIdentity.sessionShell(session).historyFileStem
            ]).count,
            3
        )
    }

    private func terminal() -> EmojiFixedTerminalView {
        EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testRemoteGridRestoresLatestNaturalMacGrid() {
        let view = terminal()
        let original = view.terminalDimensions

        view.setRemoteGrid(cols: 42, rows: 20)
        XCTAssertEqual(view.terminalDimensions.cols, 42)
        XCTAssertEqual(view.terminalDimensions.rows, 20)

        view.frame.size = NSSize(width: 700, height: 500)
        XCTAssertEqual(view.terminalDimensions.cols, 42)
        XCTAssertEqual(view.terminalDimensions.rows, 20)

        view.clearRemoteGrid()
        let restored = view.terminalDimensions
        XCTAssertGreaterThan(restored.cols, original.cols)
        XCTAssertGreaterThan(restored.rows, original.rows)
    }

    /// A remote-controlled terminal is laid out at a pixel size that disagrees with its grid, so
    /// every layout pass proposes a grid the phone did not ask for. Suppressing only the PTY
    /// resize was not enough: the emulator had already been reflowed to the desktop grid, and
    /// putting it back ran SwiftTerm's resize path, which ends in `softReset()`. A full-screen
    /// agent lost its scrolling region on each pass — including passes that set the identical
    /// frame, which is what the banner's own text change caused.
    func testLayoutLeavesARemoteControlledTerminalUntouched() {
        let view = terminal()
        view.setRemoteGrid(cols: 46, rows: 20)

        // DECSTBM, as every full-screen agent sets it.
        view.feed(text: "\u{1b}[5;15r")
        XCTAssertEqual(view.terminalStateSnapshot().scrollTop, 4)
        XCTAssertEqual(view.terminalStateSnapshot().scrollBottom, 14)

        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)  // the rect it already has
        XCTAssertEqual(view.terminalDimensions.cols, 46)
        XCTAssertEqual(view.terminalDimensions.rows, 20)
        XCTAssertEqual(view.terminalStateSnapshot().scrollTop, 4)
        XCTAssertEqual(view.terminalStateSnapshot().scrollBottom, 14)

        view.frame = NSRect(x: 0, y: 0, width: 900, height: 640)  // a real window resize
        XCTAssertEqual(view.terminalDimensions.cols, 46)
        XCTAssertEqual(view.terminalDimensions.rows, 20)
        XCTAssertEqual(view.terminalStateSnapshot().scrollTop, 4)
        XCTAssertEqual(view.terminalStateSnapshot().scrollBottom, 14)
    }

    /// Re-leasing the grid already in force is not a resize. The lease is re-applied whenever any
    /// client joins or leaves, and each `resize` would soft-reset a running agent.
    func testReapplyingTheSameRemoteGridDoesNotResetTheEmulator() {
        let view = terminal()
        view.setRemoteGrid(cols: 46, rows: 20)
        view.feed(text: "\u{1b}[5;15r")

        view.setRemoteGrid(cols: 46, rows: 20)

        XCTAssertEqual(view.terminalStateSnapshot().scrollTop, 4)
        XCTAssertEqual(view.terminalStateSnapshot().scrollBottom, 14)
    }

    // MARK: - Profile boundary

    /// Terminal type is intentionally outside the app/conversation font cascade: this surface
    /// must use the family the user selected in TerminalProfile, including its own missing-font
    /// fallback, while still applying the configured history size after SwiftTerm rebuilds its
    /// options for that font.
    func testTerminalSessionAppliesItsProfileFontAndScrollback() throws {
        var profile = TerminalProfile.default
        let selectedFont = try XCTUnwrap(NSFont(name: "Helvetica", size: 17))
        profile.fontName = selectedFont.fontName
        profile.fontSize = selectedFont.pointSize
        profile.scrollbackLines = 1_234

        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(session.terminalView.font.fontName, profile.font.fontName)
        XCTAssertEqual(session.terminalView.font.pointSize, profile.font.pointSize)
        XCTAssertEqual(session.terminalView.terminalStateSnapshot().historySize, 1_234)
    }

    func testTerminalSessionUsesSwiftTermsExactChildPID() {
        var profile = TerminalProfile.default
        profile.shellPath = "/bin/sleep"
        profile.shellArguments = ["30"]

        let terminated = expectation(description: "terminal child terminated")
        let delegate = TerminalSessionDelegateSpy { _ in
            terminated.fulfill()
        }
        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        session.delegate = delegate
        session.startShell()

        XCTAssertTrue(session.isRunning)
        XCTAssertGreaterThan(session.shellPid, 0)
        XCTAssertEqual(session.shellPid, session.terminalView.process.shellPid)

        session.terminate()
        wait(for: [terminated], timeout: 5)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.shellPid, 0)
    }

    func testRapidRestartWaitsForOldChildToBeReaped() {
        var sleepingProfile = TerminalProfile.default
        sleepingProfile.shellPath = "/bin/sleep"
        sleepingProfile.shellArguments = ["30"]

        let replacementStarted = expectation(description: "replacement child started")
        let replacementTerminated = expectation(description: "replacement child terminated")
        var startCount = 0
        var reportedExitCodes: [Int32?] = []
        let delegate = TerminalSessionDelegateSpy(
            started: {
                startCount += 1
                if startCount == 2 {
                    replacementStarted.fulfill()
                }
            },
            terminated: { exitCode in
                reportedExitCodes.append(exitCode)
                replacementTerminated.fulfill()
            }
        )
        let session = TerminalSession(
            profile: sleepingProfile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        session.delegate = delegate
        session.startShell()

        let oldPID = session.shellPid
        session.terminate()

        var replacementProfile = sleepingProfile
        replacementProfile.shellPath = "/bin/sh"
        replacementProfile.shellArguments = ["-c", "exit 7"]
        session.updateProfile(replacementProfile)
        session.startShell()

        wait(for: [replacementStarted, replacementTerminated], timeout: 5)

        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(reportedExitCodes.count, 1, "the superseded child exit stays internal")
        XCTAssertEqual(reportedExitCodes.first!, 7)
        XCTAssertEqual(kill(oldPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.shellPid, 0)
    }

    func testClaudeMouseModeKeepsWheelRoutingAndOptionScrollback() throws {
        let view = terminal()
        for line in 0..<200 {
            view.feed(text: "line \(line)\r\n")
        }
        view.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")

        var forwardedCount = 0
        view.onMouseReportForwarded = { forwardedCount += 1 }
        let bottomPosition = view.terminalStateSnapshot().viewportRow

        view.scrollWheel(with: try XCTUnwrap(makeWheelEvent(modifiers: [])))
        XCTAssertEqual(forwardedCount, 1)
        XCTAssertEqual(view.terminalStateSnapshot().viewportRow, bottomPosition)

        view.scrollWheel(with: try XCTUnwrap(makeWheelEvent(modifiers: [.option])))
        XCTAssertEqual(forwardedCount, 1)
        XCTAssertLessThan(view.terminalStateSnapshot().viewportRow, bottomPosition)
    }

    /// The bug this exists for: under any-event tracking every pointer move is written to the
    /// process, the CLI redraws the row under the pointer, and that repaint used to read as the
    /// agent working — a spinner started by moving the mouse over a finished turn.
    func testPointerMotionUnderAnyEventTrackingIsReportedAsProvokedOutput() throws {
        let view = terminal()
        var forwardedCount = 0
        view.onMouseReportForwarded = { forwardedCount += 1 }

        view.mouseMoved(with: try XCTUnwrap(makeMouseMovedEvent()))
        XCTAssertEqual(forwardedCount, 0, "a program not tracking the mouse is sent nothing")

        view.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
        view.mouseMoved(with: try XCTUnwrap(makeMouseMovedEvent()))
        XCTAssertEqual(forwardedCount, 1)

        // Button tracking (1002) reports motion only while a button is down, so a bare move
        // reaches nobody and provokes no repaint.
        view.feed(text: "\u{1b}[?1003l\u{1b}[?1002h")
        view.mouseMoved(with: try XCTUnwrap(makeMouseMovedEvent()))
        XCTAssertEqual(forwardedCount, 1)
    }

    /// The same thing through the whole chain a session actually uses — terminal view, session
    /// delegate, activity tracker — because each half of this fix passes its own test while the
    /// wiring between them is what decides whether the spinner starts.
    ///
    /// Output is delivered through `dataReceived`, which is the PTY's own entry point, so the
    /// burst counts exactly as the CLI's repaint does.
    func testMovingThePointerOverATrackingAgentDoesNotStartItsSpinner() throws {
        let controller = AgentSessionViewController(
            agentSession: AgentSession(kind: .claude, title: "Pointer")
        )
        let view = controller.session.terminalView
        controller.activityTracker.markRunning()
        controller.isVisible = true
        view.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")

        let repaint = ArraySlice(
            [UInt8](repeating: 0x20, count: ActivityDefaults.workingByteThreshold * 4)
        )

        // The control: the same burst with nobody touching the mouse is the agent working, and
        // has to stay that way — this suppression must not blind the inference it guards.
        view.dataReceived(slice: repaint)
        XCTAssertEqual(controller.activity, .working)

        controller.activityTracker.markRunning()
        XCTAssertEqual(controller.activity, .idle)

        view.mouseMoved(with: try XCTUnwrap(makeMouseMovedEvent()))
        view.dataReceived(slice: repaint)

        XCTAssertEqual(
            controller.activity,
            .idle,
            "a hover highlight the pointer provoked is not the agent working"
        )
    }

    private func makeMouseMovedEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
    }

    private func makeWheelEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ) else {
            return nil
        }
        event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        return NSEvent(cgEvent: event)
    }

    // MARK: - The scroller seam

    func testTerminalInstallsAThemedBackdropScrollerWithoutChangingItsBehavior() throws {
        let terminal = terminal()
        let window = NSWindow(
            contentRect: terminal.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView = terminal
        terminal.suspendsRenderingWhenNotVisible = false
        let scroller = try XCTUnwrap(
            terminal.subviews.compactMap { $0 as? ThemedScroller }.first
        )

        if case .backdrop = scroller.inkSource {
            // Expected: terminal chrome resolves against the terminal/window backdrop.
        } else {
            XCTFail("terminal scrollbar used chrome ink instead of backdrop ink")
        }
        XCTAssertEqual(scroller.scrollerStyle, .legacy)
        XCTAssertTrue(scroller.target === terminal)
        XCTAssertNotNil(scroller.action)

        for line in 0..<200 {
            terminal.feed(text: "line \(line)\r\n")
        }
        terminal.frameTick()
        terminal.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroller.isEnabled)
        XCTAssertLessThan(scroller.knobProportion, 1)
    }

    // MARK: - The audit over the real tree

    func testAuditPassesTheInstalledThemedScroller() {
        let terminal = terminal()
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: terminal), [])
    }

    func testAuditStillFlagsRawChromeInsideTheTerminal() {
        let terminal = terminal()
        terminal.addSubview(NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 300)))
        terminal.addSubview(NSButton(title: "x", target: nil, action: nil))

        let violations = Set(ThemeBoundaryAudit.violations(in: terminal).map(\.className))
        XCTAssertTrue(violations.contains("NSScroller"))
        XCTAssertTrue(violations.contains("NSButton"))
    }
}

private final class TerminalSessionDelegateSpy: TerminalSessionDelegate {
    private let started: () -> Void
    private let terminated: (Int32?) -> Void

    init(
        started: @escaping () -> Void = {},
        terminated: @escaping (Int32?) -> Void
    ) {
        self.started = started
        self.terminated = terminated
    }

    func terminalSessionDidStart(_ session: TerminalSession) {
        started()
    }

    func terminalSession(
        _ session: TerminalSession,
        didTerminateWithExitCode exitCode: Int32?
    ) {
        terminated(exitCode)
    }
}
