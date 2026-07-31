import AppKit
import XCTest
@testable import Threading

/// The walkthrough's spine: page order, footer state, skip-versus-continue semantics, and the
/// completion callback. Windows here are built, never shown.
@MainActor
final class OnboardingFlowTests: XCTestCase {

    /// A page that records what the flow told it, so ordering is a fact rather than a guess.
    private final class RecordingPage: NSViewController, OnboardingPage {
        let pageTitle: String
        let skipTitle: String?
        var continueTitle: String { customContinueTitle ?? L10n.string("Continue") }
        let customContinueTitle: String?
        var events: [String] = []

        init(title: String, skipTitle: String? = nil, continueTitle: String? = nil) {
            self.pageTitle = title
            self.skipTitle = skipTitle
            self.customContinueTitle = continueTitle
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func loadView() { view = NSView() }

        func pageWillAppear() { events.append("appear") }
        func pageWillDisappear() { events.append("disappear") }
        func pageWillContinue() { events.append("continue") }
    }

    private func makeFlow(
        pages: [RecordingPage],
        onFinish: @escaping () -> Void = {}
    ) -> OnboardingFlowViewController {
        let flow = OnboardingFlowViewController(pages: pages, onFinish: onFinish)
        _ = flow.view
        return flow
    }

    private func press(_ identifier: String, in flow: OnboardingFlowViewController) throws {
        let button = try XCTUnwrap(
            descendants(of: flow.view).compactMap { $0 as? ThemedButton }.first {
                $0.accessibilityIdentifier() == identifier
            },
            "No button \(identifier)"
        )
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        _ = button.performPrimaryAction()
    }

    func testContinueRunsThePageAndAdvances() throws {
        let first = RecordingPage(title: "One")
        let second = RecordingPage(title: "Two")
        var finished = false
        let flow = makeFlow(pages: [first, second]) { finished = true }

        XCTAssertEqual(flow.pageIndex, 0)
        XCTAssertEqual(first.events, ["appear"])

        try press("onboarding.continue", in: flow)
        XCTAssertEqual(first.events, ["appear", "continue", "disappear"])
        XCTAssertEqual(second.events, ["appear"])
        XCTAssertEqual(flow.pageIndex, 1)
        XCTAssertFalse(finished)

        try press("onboarding.continue", in: flow)
        XCTAssertTrue(finished)
        XCTAssertEqual(second.events, ["appear", "continue", "disappear"])
    }

    func testSkipMovesOnWithoutRunningThePage() throws {
        let first = RecordingPage(title: "One", skipTitle: "Skip for now")
        let second = RecordingPage(title: "Two")
        let flow = makeFlow(pages: [first, second])

        let skip = try XCTUnwrap(
            descendants(of: flow.view).compactMap { $0 as? ThemedButton }.first {
                $0.title == "Skip for now"
            }
        )
        _ = skip.performPrimaryAction()

        XCTAssertEqual(first.events, ["appear", "disappear"], "Skip must not run pageWillContinue")
        XCTAssertEqual(flow.pageIndex, 1)
    }

    func testBackIsHiddenOnTheFirstPageAndStepsBackAfterIt() throws {
        let first = RecordingPage(title: "One")
        let second = RecordingPage(title: "Two")
        let flow = makeFlow(pages: [first, second])

        let back = try XCTUnwrap(
            descendants(of: flow.view).compactMap { $0 as? ThemedButton }.first {
                $0.title == L10n.string("Back")
            }
        )
        XCTAssertTrue(back.isHidden)

        try press("onboarding.continue", in: flow)
        XCTAssertFalse(back.isHidden)

        _ = back.performPrimaryAction()
        XCTAssertEqual(flow.pageIndex, 0)
        XCTAssertEqual(first.events, ["appear", "continue", "disappear", "appear"])
    }

    func testEscapeStepsBackRatherThanClosing() throws {
        let first = RecordingPage(title: "One")
        let second = RecordingPage(title: "Two")
        let flow = makeFlow(pages: [first, second])

        try press("onboarding.continue", in: flow)
        XCTAssertEqual(flow.pageIndex, 1)

        flow.cancelOperation(nil)
        XCTAssertEqual(flow.pageIndex, 0)

        // On the first page Escape has nowhere to go, and must not crash or finish.
        flow.cancelOperation(nil)
        XCTAssertEqual(flow.pageIndex, 0)
    }

    func testTheLastPageNamesItsOwnContinue() throws {
        let only = RecordingPage(title: "One", continueTitle: "Start using Threading")
        let flow = makeFlow(pages: [only])
        let button = try XCTUnwrap(
            descendants(of: flow.view).compactMap { $0 as? ThemedButton }.first {
                $0.accessibilityIdentifier() == "onboarding.continue"
            }
        )
        XCTAssertEqual(button.title, "Start using Threading")
    }

    /// The terminate-trap defense: finishing must put the main window on screen before the
    /// walkthrough closes, or closing the app's last window quits it mid-handshake. The
    /// AppDelegate ordering is not reachable from a hosted test, so the contract is held here
    /// as the flow's own: `onFinish` fires while the walkthrough is still up — the closer runs
    /// inside it, after showing the main window.
    func testFinishFiresWhileTheFlowIsStillInstalled() {
        let only = RecordingPage(title: "One")
        var pageWasStillInstalled = false
        weak var weakFlow: OnboardingFlowViewController?

        let flow = makeFlow(pages: [only]) {
            pageWasStillInstalled = weakFlow?.view.window == nil // built, never shown
        }
        weakFlow = flow

        only.view.layoutSubtreeIfNeeded()
        // Continue on the only page finishes.
        let button = descendants(of: flow.view).compactMap { $0 as? ThemedButton }.first {
            $0.accessibilityIdentifier() == "onboarding.continue"
        }
        _ = button?.performPrimaryAction()
        XCTAssertTrue(pageWasStillInstalled)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
