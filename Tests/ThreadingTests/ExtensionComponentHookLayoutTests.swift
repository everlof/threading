import AppKit
import XCTest
@testable import Threading

/// The wrapper `ExtensionComponentHookViewController` builds when a caller asks for insets or a
/// fixed width — the sidebar's session and project hover cards, and the account usage card.
///
/// Nothing here is about what the card *looks* like. It is about the one thing that was wrong
/// with it: a fresh `NSView` carries `translatesAutoresizingMaskIntoConstraints`, so its zero
/// frame becomes required `width == 0` / `height == 0`, and the required inset constraints and
/// `fixedWidth` are then unsatisfiable from the first layout pass. That is invisible — AppKit
/// breaks one of them and the popover looks right once a parent hands it a frame — and it logged
/// several thousand `Unable to simultaneously satisfy constraints` an hour, one burst per hover,
/// which is how a log stops being worth reading.
@MainActor
final class ExtensionComponentHookLayoutTests: XCTestCase {

    // MARK: - Fixtures

    private func makeController(
        containerView: NSView? = nil
    ) -> ExtensionComponentHookViewController {
        ExtensionComponentHookViewController(
            target: .init(component: .applicationMainWindow, contractVersion: 1),
            child: StubHoverContentViewController(),
            contentInsets: NSEdgeInsets(
                top: Design.Spacing.inset,
                left: Design.Spacing.inset,
                bottom: Design.Spacing.inset,
                right: Design.Spacing.inset
            ),
            fixedWidth: SessionPopoverDefaults.width,
            containerView: containerView,
            lookup: { _ in .empty }
        )
    }

    /// AppKit's own translation of a frame into constraints. The class is private, so it is
    /// identified by name — which is the honest spelling of "did a frame get a vote here".
    private func frameDerivedConstraints(affecting view: NSView) -> [NSLayoutConstraint] {
        (view.constraintsAffectingLayout(for: .horizontal)
            + view.constraintsAffectingLayout(for: .vertical))
            .filter { String(describing: type(of: $0)).contains("Autoresizing") }
    }

    // MARK: - The Wrapper Is Sized By Its Constraints

    func testTheInsetWrapperIsSizedByItsConstraintsAndNotByItsZeroFrame() {
        let controller = makeController()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            controller.view.translatesAutoresizingMaskIntoConstraints,
            "a wrapper carrying a required width cannot also be sized by its frame"
        )
        XCTAssertTrue(
            frameDerivedConstraints(affecting: controller.view).isEmpty,
            "the wrapper's zero frame is still generating required size constraints: "
                + "\(frameDerivedConstraints(affecting: controller.view))"
        )
    }

    /// A container handed in by a caller — `AccountUsageItemView` passes its `HoverTrackingView`
    /// — is built the same way and arrives with the same zero frame, so it is held to the same
    /// contract rather than left to log the same conflict from a different file.
    func testACallerSuppliedContainerIsHeldToTheSameContract() {
        let supplied = NSView()
        let controller = makeController(containerView: supplied)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.view === supplied)
        XCTAssertTrue(
            frameDerivedConstraints(affecting: supplied).isEmpty,
            "a caller's container still derives required size constraints from its frame"
        )
    }

    /// The positive half: the arrangement still states the width the popover is shown at, and a
    /// height that has the insets in it. Both come out of the constraints alone, which is what
    /// `NSPopover` asks a content view controller for.
    func testTheWrapperStatesThePopoverWidthAndAnInsetHeight() {
        let controller = makeController()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            controller.view.fittingSize.width,
            SessionPopoverDefaults.width,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(
            controller.view.fittingSize.height,
            2 * Design.Spacing.inset,
            "the content should sit inside the insets, not be flattened by them"
        )
    }

    /// The branch that never had the defect, so a later tidy-up cannot quietly route the
    /// no-inset case through a wrapper and reintroduce it.
    func testWithoutInsetsOrAWidthTheContainerIsTheContentItself() {
        let controller = ExtensionComponentHookViewController(
            target: .init(component: .applicationMainWindow, contractVersion: 1),
            child: StubHoverContentViewController(),
            lookup: { _ in .empty }
        )

        XCTAssertTrue(controller.view is ComponentContentContainer)
        XCTAssertFalse(controller.view.translatesAutoresizingMaskIntoConstraints)
    }
}

// MARK: - Stub Content

private final class StubHoverContentViewController: NSViewController {
    override func loadView() {
        view = NSTextField(labelWithString: "Hover card content")
    }
}
