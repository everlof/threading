import XCTest

@testable import Threading

/// The rules that decide what an unnamed terminal is called.
///
/// Kept entirely off the process: `TerminalNaming` takes a directory and two strings, so every
/// case here is a value comparison. What reads those values from a live pty belongs to
/// `TerminalSession.refreshForegroundProcess()`, which needs a shell to say anything about.
final class TerminalNamingTests: XCTestCase {

    private let shell = "/bin/zsh"

    // MARK: - Derived Names

    func testATerminalAtTheProjectRootIsNamedAfterItsShell() {
        // Not after the folder: the row directly above this one in the sidebar is the project,
        // and it already carries the folder's name. Repeating it says nothing twice.
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/alpha",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "zsh"
        )
    }

    func testALoginShellKeepsItsNameWithoutTheConventionalDash() {
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/alpha",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: "-bash"
            ),
            "bash"
        )
    }

    func testATerminalBelowTheRootIsNamedByItsPathWithinTheProject() {
        // The whole relative path, not the last component: `Sources` alone is ambiguous the
        // moment a project has two of them, and the path is what answers "where has it got to".
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/alpha/Sources/Threading",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "Sources/Threading"
        )
    }

    func testATrailingSlashOnTheProjectRootDoesNotLeakIntoTheName() {
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/alpha/Sources",
                projectRoot: "/tmp/alpha/",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "Sources"
        )
    }

    func testADirectoryOutsideEveryProjectKeepsItsLastTwoComponents() {
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/elsewhere/client/src",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "client/src"
        )
    }

    func testTheHomeFolderIsWrittenTheWayEveryOtherPathIs() {
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: NSHomeDirectory(),
                projectRoot: nil,
                foregroundProcess: nil,
                shellPath: shell
            ),
            "~"
        )
    }

    func testARunningCommandOutranksTheDirectory() {
        // Terminal.app makes the same choice: while a dev server is up, that is what the tab
        // is, and the directory it was started from is implied by it.
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/tmp/alpha/Sources",
                projectRoot: "/tmp/alpha",
                foregroundProcess: "npm",
                shellPath: shell
            ),
            "npm"
        )
    }

    func testNothingToGoOnFallsBackToTheShell() {
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "",
                projectRoot: nil,
                foregroundProcess: nil,
                shellPath: shell
            ),
            "zsh"
        )
        XCTAssertEqual(
            TerminalNaming.derived(
                directory: "/",
                projectRoot: nil,
                foregroundProcess: nil,
                shellPath: shell
            ),
            "zsh"
        )
    }

    // MARK: - The Ladder

    func testARenameWinsAndStopsFollowingTheTerminal() {
        XCTAssertEqual(
            TerminalNaming.displayTitle(
                custom: "Server",
                reported: "vim README.md",
                directory: "/tmp/alpha/Sources",
                projectRoot: "/tmp/alpha",
                foregroundProcess: "vim",
                shellPath: shell
            ),
            "Server"
        )
    }

    func testAProgramsOwnTitleOutranksAnythingDerived() {
        XCTAssertEqual(
            TerminalNaming.displayTitle(
                custom: nil,
                reported: "david@host: ~/alpha",
                directory: "/tmp/alpha/Sources",
                projectRoot: "/tmp/alpha",
                foregroundProcess: "ssh",
                shellPath: shell
            ),
            "david@host: ~/alpha"
        )
    }

    func testTheStoredPlaceholderFallsThroughToADerivedName() {
        // Every record written before this ladder existed still stores the literal "Terminal".
        // Recognising it here is what spares those records a migration: the placeholder is not
        // a name that was chosen, only the absence of one.
        XCTAssertEqual(
            TerminalNaming.displayTitle(
                custom: nil,
                reported: TerminalNamingDefaults.fallback,
                directory: "/tmp/alpha/Sources",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "Sources"
        )
    }

    func testABareShellPathIsNotATitle() {
        // `TerminalSession.title` starts life as the profile's shell path, so a caller that
        // reads it before any program has reported one hands us `/bin/zsh`.
        XCTAssertTrue(TerminalNaming.isPlaceholder("/bin/zsh"))
        XCTAssertTrue(TerminalNaming.isPlaceholder("   "))
        XCTAssertTrue(TerminalNaming.isPlaceholder("Terminal"))
        XCTAssertFalse(TerminalNaming.isPlaceholder("npm run dev"))
        // A title that happens to contain a path is still something a program chose to say.
        XCTAssertFalse(TerminalNaming.isPlaceholder("vim /etc/hosts"))
    }

    func testAnEmptyRenameIsNoRename() {
        XCTAssertEqual(
            TerminalNaming.displayTitle(
                custom: "   ",
                reported: nil,
                directory: "/tmp/alpha",
                projectRoot: "/tmp/alpha",
                foregroundProcess: nil,
                shellPath: shell
            ),
            "zsh"
        )
    }

    // MARK: - Foreground Process

    func testAClosedDescriptorHasNoForegroundGroup() {
        XCTAssertNil(ProcessUtility.foregroundProcessGroup(ofPTY: -1, shellPid: 0))
    }

    /// A silent command produces no output edge to infer activity from. Its PTY ownership must
    /// still turn the standalone terminal's working state on, then return it to the shell after
    /// interruption.
    @MainActor
    func testASilentForegroundCommandOwnsTheTerminalUntilItStops() {
        var profile = TerminalProfile.default
        profile.shellPath = "/bin/sh"
        profile.shellArguments = []

        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        session.startShell()
        defer { session.terminate() }

        XCTAssertFalse(session.hasForegroundProcess)
        session.insertText("sleep 30\n")

        XCTAssertTrue(waitUntilForegroundState(true, in: session))

        session.sendRemoteInput([3]) // Control-C
        XCTAssertTrue(waitUntilForegroundState(false, in: session))
    }

    @MainActor
    private func waitUntilForegroundState(
        _ expected: Bool,
        in session: TerminalSession,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            _ = session.refreshForegroundProcess()
            if session.hasForegroundProcess == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline

        _ = session.refreshForegroundProcess()
        return session.hasForegroundProcess == expected
    }
}
