import XCTest
import SwiftTerm
@testable import Skalman

/// The terminal is a SwiftTerm rendering surface that brings its own `NSScroller`. The runtime
/// theme audit fatals on a raw scroller in app-owned content, so `EmojiFixedTerminalView`
/// declares itself a system-chrome boundary. These pin that the exemption covers the scroller
/// and nothing more — a debug build fatals the moment either half is wrong.
final class TerminalThemeBoundaryTests: XCTestCase {

    private func terminal() -> EmojiFixedTerminalView {
        EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testRemoteGridRestoresLatestNaturalMacGrid() {
        let view = terminal()
        let original = view.getTerminal().getDims()

        view.setRemoteGrid(cols: 42, rows: 20)
        XCTAssertEqual(view.getTerminal().getDims().cols, 42)
        XCTAssertEqual(view.getTerminal().getDims().rows, 20)

        view.frame.size = NSSize(width: 700, height: 500)
        XCTAssertEqual(view.getTerminal().getDims().cols, 42)
        XCTAssertEqual(view.getTerminal().getDims().rows, 20)

        view.clearRemoteGrid()
        let restored = view.getTerminal().getDims()
        XCTAssertGreaterThan(restored.cols, original.cols)
        XCTAssertGreaterThan(restored.rows, original.rows)
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
        XCTAssertEqual(session.terminalView.getTerminal().options.scrollback, 1_234)
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
        view.onWheelForwarded = { forwardedCount += 1 }
        let bottomPosition = view.getTerminal().buffer.yDisp

        view.scrollWheel(with: try XCTUnwrap(makeWheelEvent(modifiers: [])))
        XCTAssertEqual(forwardedCount, 1)
        XCTAssertEqual(view.getTerminal().buffer.yDisp, bottomPosition)

        view.scrollWheel(with: try XCTUnwrap(makeWheelEvent(modifiers: [.option])))
        XCTAssertEqual(forwardedCount, 1)
        XCTAssertLessThan(view.getTerminal().buffer.yDisp, bottomPosition)
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

    // MARK: - The permission contract

    func testTerminalPermitsAScrollerButNotAnArbitraryControl() {
        let terminal = terminal()
        XCTAssertTrue(terminal.permitsSystemChrome(NSScroller()), "the terminal's own scroller must pass")
        XCTAssertFalse(terminal.permitsSystemChrome(NSButton()), "the exemption must not cover a stray control")
    }

    // MARK: - The audit over the real tree

    /// A scroller inside the terminal is what fataled the app at launch; the audit must now let
    /// it through.
    func testAuditPassesAScrollerInsideTheTerminal() {
        let terminal = terminal()
        terminal.addSubview(NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 300)))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: terminal), [])
    }

    /// The exemption is scoped: a control that is *not* the terminal's chrome still fails, so the
    /// boundary cannot be used to smuggle unthemed UI into the terminal subtree.
    func testAuditStillFlagsAForeignControlInsideTheTerminal() {
        let terminal = terminal()
        terminal.addSubview(NSButton(title: "x", target: nil, action: nil))

        let violations = ThemeBoundaryAudit.violations(in: terminal)
        XCTAssertTrue(violations.contains { $0.className == "NSButton" }, "a raw button rode the scroller exemption")
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
