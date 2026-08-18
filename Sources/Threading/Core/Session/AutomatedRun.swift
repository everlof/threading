import Foundation

// MARK: - Automated Run

/// Whether a test is driving this process rather than a person.
///
/// The app makes three sounds, and none of them are for a machine. A suite that runs while the
/// developer is doing something else beeped in their room from a process with nothing on screen to
/// account for it, which is both useless and untraceable: there was no window to look at, and the
/// sound arrived from an app that appeared not to be running. The same reason
/// `ScheduledMessageNotifier` and `UsageAlertCenter` already refuse to post under test.
///
/// **The two lanes are two processes and need two answers.** `scripts/test.sh fast` and `all` host
/// the test bundle *inside* the shipping app, so `XCTestCase` is loaded here and
/// `StateManager.isHostedTest` already names that condition. `scripts/test.sh ui` does not: it
/// launches the shipping executable and drives it from a separate runner, so no test class is
/// loaded in this process and that check answers `false` exactly when a machine is doing the
/// clicking. What the runner does leave is the disposable Cocoa home it built, which
/// `UIScenarioBootstrap` reads and refuses to start without — so the scenario's own marker is the
/// honest signal there rather than a second flag that could disagree with it.
///
/// **Kept out of `SoundResolution.isSilenced` deliberately.** That value is the *user's* answer:
/// the sidebar's speaker and the Settings row draw it, and a scenario whose screenshots showed a
/// silenced app would be photographing a state nobody is in. This suppresses the sound, not the
/// setting, and nothing visual turns on it — a banner still posts, the sidebar still raises its
/// hand, a bell still ends the inferred turn.
@MainActor
enum AutomatedRun {

    /// Read once: the environment cannot change under a running process, and a value read per
    /// sound would put a dictionary lookup on a path a key repeat can reach.
    static let isUnderway = isUnderway(
        environment: ProcessInfo.processInfo.environment,
        isHostedTest: StateManager.isHostedTest
    )

    /// The rule itself, with both inputs handed in — a process that can answer this honestly is by
    /// definition a test one, so the live value above could otherwise only ever report one row.
    static func isUnderway(environment: [String: String], isHostedTest: Bool) -> Bool {
        isHostedTest || environment[Key.uiScenarioHome] != nil
    }

    // MARK: - Private Properties

    private enum Key {
        /// Set by `UIScenarioSandbox` for every application-level UI scenario, and required by
        /// `UIScenarioBootstrap` before it will install a fixture agent at all.
        static let uiScenarioHome = "THREADING_UI_SCENARIO_HOME"
    }
}
