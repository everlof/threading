import XCTest
@testable import Threading

/// Which processes are being driven by a machine, and are therefore not worth making noise in.
///
/// The two automated lanes are two different processes and need two different answers, so the rule
/// takes both inputs rather than reading either of them: a test asserting this is by definition
/// running in one of the lanes and could otherwise only ever see its own row.
@MainActor
final class AutomatedRunTests: XCTestCase {

    /// `scripts/test.sh fast` and `all` host the bundle inside the shipping app, so a test class
    /// is loaded in the very process that would make the sound.
    func testAHostedTestBundleIsAnAutomatedRun() {
        XCTAssertTrue(AutomatedRun.isUnderway(environment: [:], isHostedTest: true))
    }

    /// `scripts/test.sh ui` loads no test class into the app it is driving, so the hosted check
    /// answers `false` exactly when a machine is doing the clicking. The disposable Cocoa home the
    /// runner builds is what says so instead.
    func testAUIScenarioIsAnAutomatedRunWithNoTestClassLoaded() {
        XCTAssertTrue(
            AutomatedRun.isUnderway(
                environment: ["THREADING_UI_SCENARIO_HOME": "/tmp/scenario"],
                isHostedTest: false
            )
        )
    }

    /// An ordinary launch is not one, which is the whole point: a person who cannot do the thing
    /// they just asked for still hears why.
    func testAnOrdinaryLaunchIsNotAnAutomatedRun() {
        XCTAssertFalse(
            AutomatedRun.isUnderway(
                environment: ["HOME": "/Users/someone"],
                isHostedTest: false
            )
        )
    }

    /// The marker read here is the one `UIScenarioBootstrap` already fails closed without, rather
    /// than a second flag that could disagree with it about whether a scenario is running.
    func testTheScenarioMarkerIsTheOneTheBootstrapAlreadyRequires() {
        XCTAssertFalse(
            AutomatedRun.isUnderway(
                environment: ["THREADING_UI_SCENARIO_PROJECT": "/tmp/project"],
                isHostedTest: false
            ),
            "a fixture key without the home is a scenario the bootstrap itself refuses to install"
        )
    }

    /// And the live value, which is the half the table above cannot reach.
    func testThisProcessKnowsItIsAutomated() {
        XCTAssertTrue(AutomatedRun.isUnderway, "a hosted test bundle did not recognise itself")
    }
}
