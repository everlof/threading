import Foundation

// MARK: - Startup Checkpoint

/// How far a launch got before it stopped being a launch.
///
/// Nine facts, recorded and never acted on. The launch path deliberately keeps its
/// force-unwraps (archived reliability review §3.2): there, a silent no-op would hide a real failure, so
/// nothing here guards anything — a checkpoint says only that the launch reached this line.
/// What reads them is `CrashLoopPolicy`, after the fact and from the *next* launch.
///
/// **The order below is the order the launch sequence states them in, not an order the reader may
/// assume.** `persistenceOpened` is recorded by `ProjectStore` itself, wherever the store is first
/// touched — today that is inside the first window's layout, which is after `mainWindowConstructed`.
/// Recording it from `AppDelegate` instead would mean opening the store earlier than the app
/// otherwise does, and moving a real load for the sake of observing it is not observation.
enum StartupCheckpoint: String, CaseIterable, Sendable {

    /// The pre-rename Application Support adoption has run, or decided it had nothing to do.
    case migrationDone

    /// The projects store answered. Its detail says which of the three answers it gave.
    case persistenceOpened

    /// The app theme library is restored, so everything built after this is built already themed.
    case themeRestored

    /// `MainWindowController` exists. Not that anything of it is on screen.
    case mainWindowConstructed

    /// A window is on screen *and* the run loop has drained one turn past the launch. Whichever
    /// window that is: on a first launch it is the walkthrough, which is as much a window as the
    /// main one. This is the readiness line — everything at or after it says the app got up.
    case firstWindowVisible

    /// The recovery surface is in the window and the run loop has drained one turn past it.
    ///
    /// Recorded so a launch that died *drawing its own recovery screen* is distinguishable in the
    /// ledger from one that died before the window — the two are the same absence otherwise, and
    /// telling them apart is the whole reason a Phase 3 supervisor would read this file.
    ///
    /// **Not the readiness line.** Readiness stays keyed from `firstWindowVisible`, which this
    /// always follows: it exists to say what kind of window came up, not that one did, and a
    /// second checkpoint claiming readiness would let the answer depend on which of two records
    /// a reader happened to look at.
    case recoverySurfaceShown

    /// The extension host is up and the enabled extensions have been asked to start.
    case extensionsStarted

    /// The MCP listener's start callback ran. It runs whether or not the listener bound, which
    /// is the same latitude session restore already takes from it.
    case mcpListenerStarted

    /// The launch's restoration ran. Its detail says whether the workspace came back or was
    /// held back after an unclean previous exit.
    case selectedSessionRestored

    /// Ten interactive minutes after `firstWindowVisible`. The one checkpoint that is not a
    /// point in the launch sequence, and the one that clears a crash-loop count.
    case stable

    // MARK: - Readiness

    /// Whether reaching this checkpoint means the app got far enough to be usable.
    ///
    /// The line matters to the policy rather than to the launch: two exits *before* it cannot
    /// plausibly be something the user did, so they are read as a loop however far apart they
    /// are, while two exits after it have to fall inside the five-minute window to count. See
    /// `CrashLoopPolicy`.
    ///
    /// **The line is `firstWindowVisible`, and adding a checkpoint does not move it.**
    /// `recoverySurfaceShown` is the case that makes this worth saying, and it answers **false**:
    /// it says which *kind* of window came up, not that one did, and readiness must have exactly
    /// one claimant or the policy's answer depends on which record a reader happened to look at.
    /// In practice it always follows `firstWindowVisible`, which is precisely why it must not
    /// also assert readiness — a trail carrying it without that one is a launch whose window
    /// never proved itself, and the conservative reading of such a trail is the exempt one.
    var isReadiness: Bool {
        switch self {
        case .migrationDone, .persistenceOpened, .themeRestored, .mainWindowConstructed,
                .recoverySurfaceShown:
            return false
        case .firstWindowVisible, .extensionsStarted, .mcpListenerStarted,
                .selectedSessionRestored, .stable:
            return true
        }
    }
}

// MARK: - Startup Checkpoint Defaults

enum StartupCheckpointDefaults {
    /// What `persistenceOpened` carries, so a launch that died just after opening the store
    /// says whether the store had answered with rows, with nothing, or with a refusal.
    static let storeStateField = "store"
    static let storeLoaded = "loaded"
    static let storeMissing = "missing"
    static let storeFailed = "failed"

    /// What `selectedSessionRestored` carries.
    static let restorationField = "restoration"
    static let restorationRestored = "restored"
    static let restorationHeldBack = "heldBack"

    /// What `migrationDone` carries when a recovery launch decided not to run the adoption.
    static let migrationField = "migration"
    static let migrationRan = "ran"
    static let migrationSkippedInRecovery = "skippedInRecovery"

    /// What `themeRestored` carries when recovery pinned the stock appearance rather than
    /// resolving the user's stored choice.
    static let themeField = "theme"
    static let themeStored = "stored"
    static let themeRecoveryStock = "recoveryStock"
}
