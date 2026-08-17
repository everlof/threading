import AppKit
import XCTest
@testable import Threading

/// What arrives on the composer while the eye is elsewhere, and how loudly.
///
/// Two surfaces on this screen change on their own: the line over the box, and the import offer
/// under it. Both shipped as a flicker — the greeting because it was re-rolled by every chip
/// selection, the offer because discovery switched it on at full strength a beat after the pane
/// had settled. Neither is asserted by a render: a picture of a composer cannot show that its
/// greeting is a *different* greeting from the one before the click.
@MainActor
final class ComposerArrivalTests: XCTestCase {

    private enum Fixture {
        static let size = NSSize(width: 900, height: 700)
    }

    // MARK: - The Greeting Belongs To The Arrival

    /// Picking a model does not rewrite the sentence over the box.
    ///
    /// The greeting is a *welcome*: it belongs to arriving at the composer, not to a decision
    /// made on it. Every chip's `onSelect` ends in `refreshChips()` (see `wireChips`), which
    /// restates the role — and the role owns the hero, because choosing Manager replaces the
    /// greeting with a brief. A fresh line was rolled on that path, so picking a model, an
    /// effort or a permission mode morphed the hero into a different sentence, which reads as
    /// the app answering a choice it has nothing to say about.
    func testAChipSelectionLeavesTheGreetingAlone() throws {
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer { Design.Motion.reduceMotionOverrideForTesting = previousMotion }
        Design.Motion.reduceMotionOverrideForTesting = true

        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)
        window.layoutIfNeeded()

        let hero = try hero(in: composer)
        let greeting = hero.stringValue
        XCTAssertFalse(greeting.isEmpty, "the composer opened with no greeting at all")

        // Many more rounds than a re-roll could survive: the plain pool alone holds several
        // lines, so a greeting picked again would differ from this one within a few of them.
        for _ in 0..<20 {
            composer.refreshChips()
            XCTAssertEqual(
                hero.stringValue,
                greeting,
                "restating the chips rewrote the greeting over them"
            )
        }
    }

    /// Manager replaces the greeting; chat brings back the *same* greeting, not another one.
    ///
    /// The hero morphs between the two, so a round trip that landed on a different line would
    /// animate a change nobody asked for on the way back to where they started.
    func testTheRoleRoundTripKeepsTheOneGreeting() throws {
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer { Design.Motion.reduceMotionOverrideForTesting = previousMotion }
        Design.Motion.reduceMotionOverrideForTesting = true

        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)
        window.layoutIfNeeded()

        let hero = try hero(in: composer)
        let greeting = hero.stringValue

        // The role chip's own two lines: set the choice, then restate the chips.
        composer.selectedRole = .manager
        composer.refreshChips()
        XCTAssertEqual(
            hero.stringValue,
            ComposerDefaults.managerGreeting,
            "the manager's brief has to replace the greeting"
        )

        composer.selectedRole = .chat
        composer.refreshChips()
        XCTAssertEqual(hero.stringValue, greeting, "chat came back to a different greeting")
    }

    // MARK: - The Import Offer Fades In

    /// The offer arrives as a fade, from nothing to fully opaque.
    ///
    /// Discovery answers a couple of seconds after the composer has settled, so the button
    /// appears under a pane the eye has already stopped moving over; switched on at full
    /// strength it reads as a blink beside the send.
    func testTheImportOfferFadesInRatherThanBlinking() throws {
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer { Design.Motion.reduceMotionOverrideForTesting = previousMotion }
        Design.Motion.reduceMotionOverrideForTesting = false

        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)
        window.layoutIfNeeded()

        let offer = try importOffer(in: composer)
        XCTAssertTrue(offer.isHidden, "nothing has been discovered, so there is nothing to offer")

        composer.importable = [session("a")]
        XCTAssertFalse(offer.isHidden, "the offer is up the moment there is one")
        XCTAssertEqual(offer.title, ComposerDefaults.importTitle(count: 1))
        XCTAssertTrue(
            isFadingIn(offer),
            "the offer was switched on rather than faded in (alpha \(offer.alphaValue), "
                + "animations \(offer.layer?.animationKeys() ?? []))"
        )

        // And it lands at full opacity: an offer that stops short of it is a button drawn
        // dimmer than the row it sits on.
        let settled = expectation(description: "the fade finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.standard + 0.3) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(offer.alphaValue, 1, accuracy: 0.001, "the offer settled short of opaque")
    }

    /// Withdrawal is immediate, and leaves the button at full opacity behind `isHidden`.
    ///
    /// Every route that takes the offer away — another project, an edit taking the slot — has
    /// already replaced what the rest of the row says, so a fade out would be a stale count
    /// lingering over a row that has moved on. The resting alpha matters as much: a button
    /// parked at zero would come back invisible for anything that reveals it directly.
    func testTheImportOfferIsWithdrawnAtOnceAndRestsOpaque() throws {
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer { Design.Motion.reduceMotionOverrideForTesting = previousMotion }
        Design.Motion.reduceMotionOverrideForTesting = false

        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)
        window.layoutIfNeeded()

        let offer = try importOffer(in: composer)
        composer.importable = [session("a"), session("b")]
        XCTAssertEqual(offer.title, ComposerDefaults.importTitle(count: 2))

        composer.importable = []
        XCTAssertTrue(offer.isHidden, "the offer outlived what it was offering")
        XCTAssertEqual(offer.alphaValue, 1, accuracy: 0.001, "a hidden offer rests opaque")
    }

    /// Under Reduce Motion the offer is simply there — the finished state, applied now.
    func testUnderReduceMotionTheOfferSimplyAppears() throws {
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer { Design.Motion.reduceMotionOverrideForTesting = previousMotion }
        Design.Motion.reduceMotionOverrideForTesting = true

        let composer = SessionComposerViewController()
        let window = window(for: composer)
        composer.show(projectID: nil)
        window.layoutIfNeeded()

        let offer = try importOffer(in: composer)
        composer.importable = [session("a")]
        XCTAssertFalse(offer.isHidden)
        XCTAssertEqual(offer.alphaValue, 1, accuracy: 0.001, "a reduced arrival is not a fade")
        XCTAssertNil(offer.layer?.animation(forKey: "opacity"), "Reduce Motion still animated")
    }

    // MARK: - Fixtures

    /// Whether the button is mid-fade, asked in the two shapes AppKit answers an `animator()`
    /// opacity change in: a layer-backed view keeps the model value and installs the animation
    /// on its layer, one without a layer is driven through the property itself.
    private func isFadingIn(_ view: NSView) -> Bool {
        if view.alphaValue < 1 { return true }
        return view.layer?.animation(forKey: "opacity") != nil
    }

    private func session(_ id: String) -> ImportableSession {
        ImportableSession(
            agentSessionID: TranscriptID(id),
            kind: .claude,
            accountHandle: .standard,
            title: "Conversation \(id)",
            lastActiveAt: Date()
        )
    }

    /// An unshown window: the composer needs a real one for a fade to have a render tree to run
    /// in, and nothing here has to be on screen.
    private func window(for composer: SessionComposerViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.size),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = composer
        window.setContentSize(Fixture.size)
        return window
    }

    private func hero(
        in composer: SessionComposerViewController
    ) throws -> MorphingMultilineTitleLabel {
        try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? MorphingMultilineTitleLabel }
                .first,
            "the composer's greeting is the morphing block"
        )
    }

    private func importOffer(in composer: SessionComposerViewController) throws -> ThemedButton {
        try XCTUnwrap(
            descendants(of: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.import"
            } as? ThemedButton,
            "the composer offers no import button"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
