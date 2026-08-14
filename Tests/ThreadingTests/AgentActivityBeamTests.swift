import AppKit
import XCTest
@testable import Threading

/// The composer's ambient agent-activity beam — the judgement layer: what the
/// ring is told to draw for a given workload, theme, and motion setting, and
/// how the workload itself is measured. The pixels are pinned by
/// BorderBeamKit's own 40-frame snapshot matrix; these tests own the mapping
/// and the gates.
@MainActor
final class AgentActivityBeamTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func beam(workingCount: Int = 0, topEffort: Bool = false) -> AgentActivityBeamView {
        let view = AgentActivityBeamView()
        view.update(workload: AgentWorkload(workingCount: workingCount, anyAtTopEffort: topEffort))
        return view
    }

    private func claudeSession(effort: String?, model: String? = "claude-fable-5") -> AgentSession {
        AgentSession(
            configuration: AgentSessionConfiguration(
                kind: .claude,
                reasoningEffort: effort,
                accountHandle: .standard,
                permissionMode: nil
            )!,
            title: "Working",
            model: model
        )
    }

    // MARK: - The count-to-strength curve

    func testNothingIsMountedUntilAnAgentWorks() {
        let view = beam(workingCount: 0)
        XCTAssertFalse(view.isBeamMountedAndShowingForTesting)
        XCTAssertNil(view.appliedStrengthForTesting)
    }

    func testOneWorkingAgentLightsTheFloorInAdaptiveMono() {
        let view = beam(workingCount: 1)
        XCTAssertTrue(view.isBeamMountedAndShowingForTesting)
        XCTAssertEqual(view.appliedStrengthForTesting, ActivityBeamDefaults.baseStrength)
        XCTAssertEqual(view.appliedActiveForTesting, true)
        XCTAssertEqual(view.appliedVariantIsColorfulForTesting, false)
        XCTAssertEqual(view.appliedVariantIsMonoForTesting, true)
    }

    func testEachAdditionalAgentAddsAStep() {
        let view = beam(workingCount: 3)
        XCTAssertEqual(
            view.appliedStrengthForTesting ?? 0,
            ActivityBeamDefaults.baseStrength + 2 * ActivityBeamDefaults.strengthPerAdditionalAgent,
            accuracy: 0.0001
        )
    }

    func testTheStrengthCapsAtFull() {
        let view = beam(workingCount: 12)
        XCTAssertEqual(view.appliedStrengthForTesting, 1)
    }

    func testTheFadeOutKeepsTheLastStrength() {
        let view = beam(workingCount: 4)
        view.update(workload: .none)
        XCTAssertEqual(view.appliedActiveForTesting, false)
        XCTAssertEqual(
            view.appliedStrengthForTesting ?? 0,
            ActivityBeamDefaults.baseStrength + 3 * ActivityBeamDefaults.strengthPerAdditionalAgent,
            accuracy: 0.0001
        )
    }

    // MARK: - Escalation

    func testTopEffortTurnsTheRingColorful() {
        let view = beam(workingCount: 2, topEffort: true)
        XCTAssertEqual(view.appliedVariantIsColorfulForTesting, true)
        XCTAssertEqual(view.appliedVariantIsMonoForTesting, false)
    }

    // MARK: - The theme gate

    func testAStyledThemeRemovesTheRingOutright() {
        AppThemePalette.set(AppThemeStyles.win98)
        let view = beam(workingCount: 2)
        XCTAssertFalse(view.isBeamMountedAndShowingForTesting)
        XCTAssertEqual(view.appliedActiveForTesting, false)
    }

    func testTheRingReturnsWithTheSystemThemeOnALiveSwitch() {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let view = beam(workingCount: 1)
        XCTAssertFalse(view.isBeamMountedAndShowingForTesting)

        AppThemePalette.set(.system)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeID.system))

        XCTAssertTrue(view.isBeamMountedAndShowingForTesting)
        XCTAssertEqual(view.appliedActiveForTesting, true)
    }

    // MARK: - Motion

    func testReduceMotionRendersTheRingStatic() {
        let view = beam(workingCount: 1)
        XCTAssertEqual(view.appliedRendersStaticallyForTesting, false)

        Design.Motion.reduceMotionOverrideForTesting = true
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeID.system))
        XCTAssertEqual(view.appliedRendersStaticallyForTesting, true)

        Design.Motion.reduceMotionOverrideForTesting = false
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeID.system))
        XCTAssertEqual(view.appliedRendersStaticallyForTesting, false)
    }

    // MARK: - The decorative contract

    func testTheRingIsInvisibleToPointerAndAccessibility() {
        let view = beam(workingCount: 1)
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 50)))
        XCTAssertFalse(view.isAccessibilityElement())
    }

    func testTheRingMatchesThePanelRadius() {
        let view = beam(workingCount: 1)
        XCTAssertEqual(view.appliedBorderRadiusForTesting, Double(SurfaceRadius.panel.current))
    }

    /// The sidebar-row surface follows the selection capsule instead. The ring only draws
    /// under the System theme, so the capsule in question is the stock source list's — the
    /// same radius `SidebarHoverRowView` was measured against.
    func testTheRowSurfaceFollowsTheSelectionCapsuleRadius() {
        let view = AgentActivityBeamView(surface: .sidebarRow)
        view.update(workload: AgentWorkload(workingCount: 1, anyAtTopEffort: false))
        XCTAssertEqual(
            view.appliedBorderRadiusForTesting,
            Double(SidebarRowDefaults.systemHoverHighlightRadius)
        )
    }

    // MARK: - Measuring the workload

    func testMeasureCountsWorkingSessionsAndJudgesTopByTheLadder() {
        let low = claudeSession(effort: "low")
        let top = claudeSession(effort: "max")

        let loud = AgentWorkload.measure(workingSessions: [low, top]) { _, _ in nil }
        XCTAssertEqual(loud.workingCount, 2)
        XCTAssertTrue(loud.anyAtTopEffort)

        let calm = AgentWorkload.measure(workingSessions: [low]) { _, _ in nil }
        XCTAssertEqual(calm.workingCount, 1)
        XCTAssertFalse(calm.anyAtTopEffort)
    }

    func testASessionWithoutAModelNeverEscalates() {
        // No model → no catalog option → no ladder to be at the top of. The
        // beam stays mono rather than guessing a provider's levels by name.
        let unresolved = claudeSession(effort: "max", model: nil)
        let measured = AgentWorkload.measure(workingSessions: [unresolved]) { _, _ in nil }
        XCTAssertFalse(measured.anyAtTopEffort)
    }
}
