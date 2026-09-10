import XCTest
@testable import Threading

/// Which of the app's commands still work when nothing has been started.
///
/// A table, because the interesting failure is silent in both directions: a command left enabled
/// does nothing and reads as a broken app, and a command wrongly refused is a feature somebody
/// cannot reach on the one launch where they most need it.
final class RecoveryModeCommandPolicyTests: XCTestCase {

    /// **The commands a recovery mode must never take away.** They are allowed by *group* rather
    /// than by being listed, so a system command added later is allowed by existing rather than by
    /// somebody remembering — and a recovery mode that could disable Quit or Copy would be a worse
    /// failure than any it is trying to contain.
    func testThePlatformsOwnCommandsSurviveRecovery() {
        let system = AppCommands.all.filter { $0.group == .system }
        XCTAssertFalse(system.isEmpty, "the fixture found no system commands, so it proves nothing")

        for command in system {
            XCTAssertTrue(
                RecoveryModeCommandPolicy.allows(commandID: command.id),
                "\(command.id) is the platform's and was refused"
            )
        }
    }

    /// The sidebar is on screen and is the evidence somebody in a crash loop came for, so the four
    /// commands that arrange it stay — all four act on settings rather than on a session. Checking
    /// for updates stays because a new build is a legitimate fix, and refusing to look for one
    /// would be the app deciding it cannot be repaired.
    func testTheCommandsThatStillMeanSomethingAreAllowed() {
        for id in [
            AppCommands.ID.toggleSidebar,
            AppCommands.ID.groupByBranch,
            AppCommands.ID.loneBranchHeadings,
            AppCommands.ID.compactTree,
            AppCommands.ID.checkForUpdates
        ] {
            XCTAssertTrue(RecoveryModeCommandPolicy.allows(commandID: id), "\(id) was refused")
        }
    }

    /// Everything that would start work, open a surface that cannot exist, or act on a session
    /// that is not running.
    func testEverythingThatWouldStartWorkIsRefused() {
        for id in [
            AppCommands.ID.newSession,
            AppCommands.ID.newProject,
            AppCommands.ID.addProject,
            AppCommands.ID.closeSession,
            AppCommands.ID.closeTab,
            AppCommands.ID.openIn,
            AppCommands.ID.find,
            AppCommands.ID.newTerminalTab,
            AppCommands.ID.browser,
            AppCommands.ID.files,
            AppCommands.ID.review,
            AppCommands.ID.attachments,
            AppCommands.ID.saveBaseline,
            AppCommands.ID.sessionInfo,
            AppCommands.ID.shell,
            AppCommands.ID.displayPanel,
            AppCommands.ID.statusCard,
            AppCommands.ID.inspectElement,
            AppCommands.ID.previousTurn,
            AppCommands.ID.nextTurn,
            AppCommands.ID.previousTab,
            AppCommands.ID.nextTab,
            AppCommands.ID.selectTab(1)
        ] {
            XCTAssertFalse(RecoveryModeCommandPolicy.allows(commandID: id), "\(id) was allowed")
        }
    }

    /// The refusal is a *narrowing*, not a denial of everything: a policy that refused the whole
    /// table would pass the case above while leaving a window nobody could quit.
    func testTheRefusalIsANarrowingRatherThanAWall() {
        let refused = Set(RecoveryModeCommandPolicy.refusedCommandIDs)
        let all = Set(AppCommands.all.map(\.id))

        XCTAssertFalse(refused.isEmpty)
        XCTAssertNotEqual(refused, all, "recovery refused every command this build has")
        XCTAssertTrue(refused.isSubset(of: all))
    }

    /// A command id this build has never heard of is refused rather than waved through. Recovery
    /// is the one launch where an unknown command is likelier to be a stale menu item than a
    /// feature, and the conservative answer costs one unavailable row.
    func testAnUnknownCommandIsRefused() {
        XCTAssertFalse(RecoveryModeCommandPolicy.allows(commandID: "not.a.command"))
    }
}
