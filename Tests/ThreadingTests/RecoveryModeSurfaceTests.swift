import AppKit
import XCTest
@testable import Threading

/// The screen a recovery launch opens onto: what it offers, what each offer presses, and what it
/// says while doing it.
///
/// Every action is injected, so the whole surface can be exercised without relaunching the app,
/// moving anybody's data, or writing a support report — which is the only way an offer whose real
/// primitive is `exit()` is ever checked at all.
@MainActor
final class RecoveryModeSurfaceTests: XCTestCase {

    // MARK: - Fixture

    /// One counter per offer, so a press can be attributed rather than merely observed.
    private final class Spy {
        var pressed: [String] = []
        func handler(_ name: String) -> () -> Void {
            { [weak self] in self?.pressed.append(name) }
        }
    }

    private func actions(_ spy: Spy) -> RecoveryModeActions {
        RecoveryModeActions(
            tryNormalLaunchOnce: spy.handler("tryNormal"),
            continueInRecoveryMode: spy.handler("continue"),
            toggleExtensionsForNextLaunch: spy.handler("extensions"),
            resetWindowLayout: spy.handler("layout"),
            createSupportReport: spy.handler("report"),
            moveAppDataAside: spy.handler("moveAside"),
            revealCrashReport: spy.handler("crashReport")
        )
    }

    private func surface(
        reason: LaunchModeReason = .crashLoop,
        checkpoint: StartupCheckpoint? = .themeRestored,
        hasCrashReport: Bool = true,
        extensionsArmed: Bool = false,
        spy: Spy
    ) -> RecoveryModeView {
        RecoveryModeSurface.make(
            reason: reason,
            checkpoint: checkpoint,
            hasCrashReport: hasCrashReport,
            extensionsDisabledNextLaunch: extensionsArmed,
            actions: actions(spy)
        )
    }

    /// A pane-sized host that states its size the way a split view does.
    ///
    /// The frame *and* the anchors: a detached `NSView(frame:)` pins no width, so Auto Layout
    /// lays the subtree out at the width it would prefer and a child can come out wider than the
    /// view holding it, with nothing to say so.
    private func host(_ surface: RecoveryModeView, width: CGFloat = 760) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 620))
        host.addSubview(surface)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: 620),
            surface.topAnchor.constraint(equalTo: host.topAnchor),
            surface.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The first view of a kind inside the surface, for the two checks that are about ink rather
    /// than about behaviour.
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T { found.append(match) }
            found.append(contentsOf: descendants(type, in: subview))
        }
        return found
    }

    // MARK: - The Offers

    func testEveryOfferPressesExactlyTheThingItNames() throws {
        let spy = Spy()
        let surface = surface(spy: spy)

        let expected: [(String, String)] = [
            (RecoveryModeDefaults.tryNormalAction, "tryNormal"),
            (RecoveryModeDefaults.continueAction, "continue"),
            (RecoveryModeDefaults.crashReportAction, "crashReport"),
            (RecoveryModeDefaults.extensionsAction, "extensions"),
            (RecoveryModeDefaults.windowLayoutAction, "layout"),
            (RecoveryModeDefaults.supportReportAction, "report"),
            (RecoveryModeDefaults.moveDataAsideAction, "moveAside")
        ]

        for (identifier, name) in expected {
            let control = try XCTUnwrap(
                surface.control(identifier: identifier),
                "\(identifier) is not on the surface"
            )
            spy.pressed.removeAll()
            _ = control.performPrimaryAction()
            XCTAssertEqual(spy.pressed, [name], "\(identifier) pressed the wrong primitive")
        }
    }

    /// The report is offered only when macOS filed one. A button that reveals nothing is worse
    /// than no button, because it teaches the user that this screen does not work.
    func testTheCrashReportOfferIsAbsentWhenThereIsNoReport() {
        let spy = Spy()
        XCTAssertNil(
            surface(hasCrashReport: false, spy: spy)
                .control(identifier: RecoveryModeDefaults.crashReportAction)
        )
        XCTAssertNotNil(
            surface(hasCrashReport: true, spy: spy)
                .control(identifier: RecoveryModeDefaults.crashReportAction)
        )
    }

    /// **The harder verdict demotes the first offer rather than removing it.** Pressing it again
    /// is the least likely thing to help once the recovery launch has itself died, and the group
    /// below is where the answer now is — but taking it away would strand the user in recovery.
    func testARecoveryLaunchThatDiedDemotesTryNormalWithoutRemovingIt() throws {
        let spy = Spy()

        let ordinary = try XCTUnwrap(
            surface(reason: .crashLoop, spy: spy)
                .control(identifier: RecoveryModeDefaults.tryNormalAction)
        )
        XCTAssertEqual(ordinary.emphasis, .primary)

        let escalated = try XCTUnwrap(
            surface(reason: .recoveryLaunchFailed, spy: spy)
                .control(identifier: RecoveryModeDefaults.tryNormalAction)
        )
        XCTAssertEqual(escalated.emphasis, .secondary)
    }

    /// Armed reads as a state, not as a command. A one-shot the user cannot see they set is a
    /// setting, whatever the storage says.
    func testTheExtensionsOfferSaysWhetherItIsArmed() throws {
        let spy = Spy()

        let idle = try XCTUnwrap(
            surface(extensionsArmed: false, spy: spy)
                .control(identifier: RecoveryModeDefaults.extensionsAction)
        )
        let armed = try XCTUnwrap(
            surface(extensionsArmed: true, spy: spy)
                .control(identifier: RecoveryModeDefaults.extensionsAction)
        )

        XCTAssertEqual(idle.title, RecoveryModeCopy.extensionsTitle(armed: false))
        XCTAssertEqual(armed.title, RecoveryModeCopy.extensionsTitle(armed: true))
        XCTAssertNotEqual(idle.title, armed.title)
    }

    // MARK: - Copy

    /// Four quite different things put this screen up, and "recovery" alone cannot say which.
    func testEachReasonGetsItsOwnSentence() {
        let sentences = [
            LaunchModeReason.crashLoop,
            .recoveryLaunchFailed,
            .optionKeyHeld,
            .commandLineFlag
        ].map(RecoveryModeCopy.reason)

        XCTAssertEqual(Set(sentences).count, sentences.count, "two reasons share a sentence")
        for sentence in sentences {
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains("—"), "no em dashes in user-facing copy")
        }
    }

    /// The raw case name is a fact about this code, not copy — and the person reading this screen
    /// is being asked to act on it.
    func testEveryCheckpointHasAName() {
        for checkpoint in StartupCheckpoint.allCases {
            let name = RecoveryModeCopy.name(of: checkpoint)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(
                name,
                checkpoint.rawValue,
                "\(checkpoint.rawValue) is showing its enum case name to a user"
            )
        }
    }

    func testALaunchThatRecordedNothingSaysSoRatherThanNamingNoCheckpoint() {
        XCTAssertNotEqual(
            RecoveryModeCopy.checkpoint(nil),
            RecoveryModeCopy.checkpoint(.themeRestored)
        )
        XCTAssertFalse(RecoveryModeCopy.checkpoint(nil).isEmpty)
    }

    // MARK: - Accessibility

    /// The surface arrives without being asked for and takes no focus, so its whole content has
    /// to be reachable by somebody who cannot glance at it.
    func testTheSurfaceIsAGroupWhoseSummaryCarriesTheReasonAndTheCheckpoint() {
        let spy = Spy()
        let surface = surface(spy: spy)

        XCTAssertTrue(surface.isAccessibilityElement())
        XCTAssertEqual(surface.accessibilityRole(), .group)
        XCTAssertTrue(surface.spokenSummary.contains(RecoveryModeCopy.reason(.crashLoop)))
        XCTAssertTrue(
            surface.spokenSummary.contains(RecoveryModeCopy.checkpoint(.themeRestored))
        )
    }

    /// Every offer is an ordinary control: a role, a title, and a press that reaches the same
    /// primitive the pointer would.
    func testEveryOfferAnswersAnAccessibilityPress() throws {
        let spy = Spy()
        let surface = surface(spy: spy)

        for control in surface.actionControls {
            XCTAssertFalse(try XCTUnwrap(control.accessibilityIdentifier()).isEmpty)
            spy.pressed.removeAll()
            XCTAssertTrue(control.accessibilityPerformPress())
            XCTAssertEqual(spy.pressed.count, 1, "\(control.title) did not answer a press")
        }
    }

    // MARK: - Layout And Theme

    /// A pane's content may not decide how tall the window is, and it may not run past its edges
    /// either. Measured in a host that states its size, because a detached view constrains nothing.
    func testTheColumnStaysInsideAPaneAtItsNarrowest() {
        let spy = Spy()
        let surface = surface(spy: spy)
        let host = host(surface, width: 420)

        for control in surface.actionControls {
            let frame = control.convert(control.bounds, to: host)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(control.title) ran off the leading edge")
            XCTAssertLessThanOrEqual(
                frame.maxX,
                host.bounds.width,
                "\(control.title) ran off the trailing edge"
            )
        }
    }

    /// The ink is set on labels rather than read at draw, so a live theme switch has to reach it.
    /// The surface outlives a switch: Settings is reachable from recovery, and a theme applied
    /// there is one this screen has to follow.
    func testALiveThemeSwitchRepaintsTheSurface() throws {
        defer { AppThemePalette.set(.system) }

        let spy = Spy()
        let surface = surface(spy: spy)
        _ = host(surface)

        let mark = try XCTUnwrap(descendants(GlyphView.self, in: surface).first)
        let sentence = try XCTUnwrap(descendants(NSTextField.self, in: surface).first)
        let markBefore = try XCTUnwrap(mark.tint?.hexString)
        let sentenceBefore = try XCTUnwrap(sentence.textColor?.hexString)

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        NotificationCenter.default.post(
            AppThemeDidChange(themeID: AppThemeStyles.swissMinimalist.id)
        )

        XCTAssertEqual(mark.tint?.hexString, Design.Status.warning.hexString)
        XCTAssertEqual(sentence.textColor?.hexString, Design.Text.label.hexString)
        XCTAssertNotEqual(
            [markBefore, sentenceBefore],
            [Design.Status.warning.hexString, Design.Text.label.hexString],
            "the two themes paint the surface identically, so this fixture proves nothing"
        )
    }
}
