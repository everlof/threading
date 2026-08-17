import AppKit
import XCTest
@testable import Threading

/// What a recovery launch does to the state it finds, which in almost every case is nothing.
///
/// The mode is a process-wide answer set once by the launch sequence, so every case here drives it
/// through `RecoveryMode.withResolution` — a seam that restores whatever was there, rather than
/// leaving a static behind for the next test in this process to trip over.
@MainActor
final class RecoveryModeStartupTests: XCTestCase {

    // MARK: - Fixture

    private var directory = URL(fileURLWithPath: "/")

    private let recovery = LaunchModeResolution(mode: .recovery, reason: .optionKeyHeld)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecoveryModeStartupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - The Mode Itself

    func testTheModeIsOffUnlessAnEntryPathTurnedItOn() {
        XCTAssertFalse(RecoveryMode.isActive)
        RecoveryMode.withResolution(recovery) {
            XCTAssertTrue(RecoveryMode.isActive)
        }
        XCTAssertFalse(RecoveryMode.isActive, "the seam did not put the mode back")
    }

    /// The mode a launch came up in is a fact about the launch. A process that changed its mind
    /// halfway is one whose ledger record has stopped being true.
    func testTheModeIsSetOnceAndASecondEntryIsRefused() {
        RecoveryMode.withResolution(recovery) {
            RecoveryMode.enter(LaunchModeResolution(mode: .normal, reason: .forcedNormal))
            XCTAssertTrue(RecoveryMode.isActive, "a second entry changed the launch's own mode")
        }
    }

    // MARK: - The Running-Sessions Record

    /// **The record a recovery launch must not touch, from either end.**
    ///
    /// The scenario is ordinary and the loss is total: the last normal quit recorded two running
    /// sessions, the user then drops into recovery to look at something and quits again. Recovery
    /// has nothing running, so a quit path that recorded what was live would write an empty list
    /// over those two, and the next normal launch would bring back nothing while looking exactly
    /// like a launch that had nothing to bring back. It is also not consumed here — the read hangs
    /// off the MCP listener's callback, which recovery never starts — so leaving it alone at both
    /// ends is what preserves it end to end.
    func testARecoveryQuitLeavesTheRunningSessionsForTheNextNormalLaunch() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let recorded = [SessionID(), SessionID()]
        XCTAssertTrue(manager.saveRunningSessionIDs(recorded))

        // What a recovery launch does at each end of its life: the plan refuses the quit-time
        // write, and nothing on the recovery path reads the record.
        let plan = LaunchPlan(
            resolution: recovery,
            decision: .launchNormally(.available),
            extensionsDisabledOnce: false,
            needsOnboarding: false
        )
        XCTAssertFalse(
            plan.recordsRunningSessionsOnQuit,
            "recovery would overwrite the record with the empty list it has"
        )
        XCTAssertFalse(plan.restoresWorkspace, "recovery would spend the record on read")

        // The next normal launch still finds both.
        XCTAssertEqual(
            manager.consumeRunningSessionIDs(),
            recorded,
            "the sessions the last real quit recorded did not survive a visit to recovery"
        )
    }

    // MARK: - The Store

    /// The store is read so the sidebar can show the projects survived, and written not at all.
    /// Seeded at construction because `load()` takes a write of its own — the legacy
    /// theme-assignment migration — so a flag set afterwards would arrive one save too late.
    /// Asserted by reading the store back rather than by comparing the files: SQLite touches its
    /// own journal on a read, so bytes on disk answer a different question from "did anything the
    /// app owns change".
    func testARecoveryStoreReadsItsProjectsAndWritesNothingBack() throws {
        let manager = StateManager(appSupportDirectory: directory)
        let seed = ProjectStore(stateManager: manager, refusesWrites: false)
        let seededProject = try XCTUnwrap(seed.addProject(folderURL: directory))
        let seededSession = try XCTUnwrap(
            seed.addSession(to: seededProject.id, kind: .claude)
        )
        seed.flushPendingSave()

        let store = ProjectStore(stateManager: manager, refusesWrites: true)
        XCTAssertEqual(store.projects.count, 1, "recovery must still be able to show the projects")

        // Everything a person can do to the store from a recovery window: browse, and have the
        // sidebar record where they went.
        store.selectedSessionID = SessionID()
        XCTAssertNil(
            store.addProject(folderURL: directory.appendingPathComponent("second")),
            "a refused creation must not return the project it already rolled back"
        )
        XCTAssertNil(
            store.addSession(to: seededProject.id, kind: .claude),
            "a refused creation must not return the session it already rolled back"
        )
        XCTAssertNil(
            store.addTerminal(to: seededProject.id),
            "a refused creation must not return the terminal it already rolled back"
        )
        store.flushPendingSave()
        XCTAssertEqual(store.projects.count, 1, "recovery presented a refused project as saved")
        XCTAssertEqual(
            store.project(withID: seededProject.id)?.sessions.map(\.id),
            [seededSession.id],
            "recovery presented a refused session as saved"
        )
        XCTAssertTrue(
            store.project(withID: seededProject.id)?.terminals.isEmpty == true,
            "recovery presented a refused terminal as saved"
        )
        XCTAssertNil(store.selectedSessionID, "recovery presented a refused selection as saved")

        let reopened = ProjectStore(stateManager: StateManager(appSupportDirectory: directory))
        XCTAssertEqual(
            reopened.projects.map(\.folderPath),
            seed.projects.map(\.folderPath),
            "a recovery launch wrote a project into the store"
        )
        XCTAssertNil(
            reopened.selectedSessionID,
            "a recovery launch recorded where the user browsed as the selection to restore"
        )
    }

    // MARK: - The Theme

    /// No recorded answer means the product dress, and reading that default does not turn it
    /// into an explicit choice. A future default can therefore change without migrating a key
    /// the user never set.
    func testANormalLaunchWithoutAStoredChoiceUsesThreadingWithoutRecordingIt() {
        let key = "appThemeID"
        let original = PreferenceStore.shared.string(forKey: key)
        defer {
            if let original {
                PreferenceStore.shared.set(original, forKey: key)
            } else {
                PreferenceStore.shared.removeObject(forKey: key)
            }
            AppThemeLibrary.restore()
        }

        PreferenceStore.shared.removeObject(forKey: key)
        AppThemeLibrary.restore()

        XCTAssertEqual(AppThemeLibrary.current.id, AppThemeStyles.threading.id)
        XCTAssertEqual(AppThemeLibrary.defaultTheme.id, AppThemeStyles.threading.id)
        XCTAssertNil(AppThemeLibrary.storedThemeID, "restoring the default wrote a user choice")
    }

    /// Recovery wears System, and the user's standing choice is left exactly as it was.
    ///
    /// System rather than "the stored choice if it happens to be stock": a stock theme carrying a
    /// `WindowChromeStyle` opts the window into the app-drawn frame, which is a great deal of
    /// launch-time machinery and a plausible place to die.
    func testRecoveryWearsSystemWithoutTouchingTheStoredChoice() throws {
        let chosen = try XCTUnwrap(AppThemeStyles.all.first)
        let original = AppThemeLibrary.storedThemeID
        defer {
            if let original, let theme = AppThemeLibrary.theme(withID: original) {
                AppThemeLibrary.apply(theme)
            } else {
                AppThemeLibrary.apply(.system)
            }
        }

        AppThemeLibrary.apply(chosen)
        XCTAssertEqual(AppThemeLibrary.storedThemeID, chosen.id)

        AppThemeLibrary.restore(.recovery)

        XCTAssertEqual(AppThemeLibrary.current.id, AppTheme.system.id)
        XCTAssertEqual(
            AppThemeLibrary.storedThemeID,
            chosen.id,
            "a recovery launch re-persisted the theme it was only wearing"
        )
    }

    func testANormalLaunchStillRestoresTheStoredChoice() throws {
        let chosen = try XCTUnwrap(AppThemeStyles.all.first)
        let original = AppThemeLibrary.storedThemeID
        defer {
            if let original, let theme = AppThemeLibrary.theme(withID: original) {
                AppThemeLibrary.apply(theme)
            } else {
                AppThemeLibrary.apply(.system)
            }
        }

        AppThemeLibrary.apply(chosen)
        AppThemeLibrary.restore(.normal)

        XCTAssertEqual(AppThemeLibrary.current.id, chosen.id)
    }

    /// **The trap this design exists to avoid.** In recovery the app wears System while the user's
    /// choice is something else, so an Appearance page whose selection sat on what is *in force*
    /// would put the ring on System — and clicking the entry that already looks selected records
    /// System over their theme. The page selects the stored choice instead, and activating it
    /// writes back the value that was already there.
    func testActivatingTheSelectedThemeInRecoveryWritesNothingNew() throws {
        let chosen = try XCTUnwrap(AppThemeStyles.all.first)
        let original = AppThemeLibrary.storedThemeID
        defer {
            if let original, let theme = AppThemeLibrary.theme(withID: original) {
                AppThemeLibrary.apply(theme)
            } else {
                AppThemeLibrary.apply(.system)
            }
        }

        AppThemeLibrary.apply(chosen)
        AppThemeLibrary.restore(.recovery)

        try RecoveryMode.withResolution(recovery) {
            let controller = ThemePreferencesViewController()
            _ = controller.view

            let selected = try XCTUnwrap(
                controller.selectedAppThemeIDForTesting,
                "the appearance page named no selection at all"
            )
            XCTAssertEqual(
                selected,
                chosen.id,
                "the ring sat on the theme in force rather than the one the user chose"
            )

            // The user clicks the entry that looks selected.
            controller.applyAppThemeForTesting(id: selected)
            XCTAssertEqual(
                AppThemeLibrary.storedThemeID,
                chosen.id,
                "clicking the selected entry overwrote the user's theme"
            )
        }
    }

    // MARK: - The Pane

    /// Recovery lists and selects but opens nothing. The refusal is visible in the pane and
    /// load-bearing at each surface's own launch, which every other route crosses.
    func testTheRecoveryPaneOpensNothingForASelectedSession() {
        let container = TerminalContainerViewController(recovery: true)
        _ = container.view

        let sessionID = SessionID()
        container.show(sessionID: sessionID)

        XCTAssertEqual(container.currentSessionID, sessionID, "the row must still select")
        XCTAssertNil(container.activeTerminalSession, "a recovery pane opened a terminal")
        XCTAssertFalse(container.isShowingConversation)
    }

    func testTheRecoveryPaneRefusesABackgroundLaunch() {
        let container = TerminalContainerViewController(recovery: true)
        _ = container.view

        XCTAssertFalse(container.launchInBackground(sessionID: SessionID()))
    }
}
