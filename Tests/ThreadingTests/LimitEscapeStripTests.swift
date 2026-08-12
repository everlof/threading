import AppKit
import XCTest
@testable import Threading

/// The strip that offers a way past a spent usage limit.
///
/// What is pinned here is the contract a caller depends on — the press reaches the action, the ✕
/// reaches the dismissal, a press already in flight cannot be pressed again — plus the two things
/// a screenshot cannot show: whether it is readable by somebody who cannot glance at it, and
/// whether its ink survives a live theme switch.
///
/// No window is ordered on screen anywhere below. An unshown host still lays out and still draws
/// through `cacheDisplay`, which is everything these measure.
@MainActor
final class LimitEscapeStripTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        /// A composer column at a comfortable width, and one narrow enough that the strip has to
        /// choose between its sentence and the button answering it.
        static let width: CGFloat = 620
        static let narrowWidth: CGFloat = 260
        static let height: CGFloat = 120

        static let accountName = "Daniel Block"
        static let reading = "5h 12% · 7d 40%"
        static let resetHint = "9:40pm (Europe/Rome)"

        static var offer: LimitEscapeStripView.Offer {
            LimitEscapeStripView.Offer(
                accountName: accountName,
                reading: reading,
                resetHint: resetHint
            )
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    /// A host standing in for the composer's column: it states its size the way a split item
    /// does, rather than carrying a frame that constrains nothing, so a child measured in it is
    /// measured at a width it was actually asked to fit.
    @discardableResult
    private func host(
        _ strip: LimitEscapeStripView,
        width: CGFloat = Fixture.width
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Fixture.height))
        host.addSubview(strip)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: Fixture.height),
            strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func mark(in strip: LimitEscapeStripView) throws -> ThemedWarningMark {
        try XCTUnwrap(
            strip.subviews.compactMap { $0 as? ThemedWarningMark }.first,
            "the strip carries no limit mark"
        )
    }

    private func sentence(in strip: LimitEscapeStripView) throws -> NSTextField {
        try XCTUnwrap(
            strip.subviews.compactMap { $0 as? NSTextField }.first,
            "the strip says nothing"
        )
    }

    // MARK: - What It Says

    func testItNamesTheStateAndTheProvidersOwnWordsForTheReset() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        let said = try sentence(in: strip).stringValue
        XCTAssertTrue(said.contains("Limit reached"), said)
        XCTAssertTrue(
            said.contains(Fixture.resetHint),
            "the reset is quoted, never reformatted into the Mac's locale: \(said)"
        )
    }

    func testAProviderThatRefusedWithoutSayingWhenLeavesTheClauseOut() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading
        ))
        host(strip)

        XCTAssertEqual(try sentence(in: strip).stringValue, L10n.string("Limit reached"))
    }

    /// The button is the whole action, which is what makes a second confirmation unnecessary.
    func testTheButtonNamesTheLoginAndItsReading() {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        let title = strip.continueControl.title
        XCTAssertTrue(title.contains(Fixture.accountName), title)
        XCTAssertTrue(title.contains(Fixture.reading), title)
    }

    func testALoginWithNoWindowsToStateIsStillOfferedByName() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(accountName: Fixture.accountName))
        host(strip)

        XCTAssertEqual(
            strip.continueControl.title,
            L10n.format("Continue as %@", Fixture.accountName)
        )
    }

    func testAStripWithNothingToOfferLeavesRatherThanStandingEmpty() {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)
        XCTAssertFalse(strip.isHidden)

        strip.setOffer(nil)
        XCTAssertTrue(strip.isHidden)
    }

    // MARK: - The Two Gestures

    func testPressingTheButtonAsksToContinue() {
        let strip = LimitEscapeStripView()
        var asked = 0
        strip.onContinue = { asked += 1 }
        strip.setOffer(Fixture.offer)
        host(strip)

        XCTAssertTrue(strip.continueControl.performPrimaryAction())

        XCTAssertEqual(asked, 1)
    }

    func testPressingTheDismissMarkPutsTheOfferAway() {
        let strip = LimitEscapeStripView()
        var dismissed = 0
        strip.onDismiss = { dismissed += 1 }
        strip.setOffer(Fixture.offer)
        host(strip)

        XCTAssertTrue(strip.dismissControl.accessibilityPerformPress())

        XCTAssertEqual(dismissed, 1)
    }

    /// A migration already running must not be started again by a second press.
    func testAPressAlreadyInFlightCannotBePressedAgain() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            resetHint: Fixture.resetHint,
            isBusy: true
        ))
        host(strip)

        XCTAssertFalse(strip.continueControl.isEnabled)
        XCTAssertEqual(strip.continueControl.title, L10n.string("Continuing…"))
        XCTAssertTrue(strip.dismissControl.isEnabled, "the way out stays available")
    }

    /// An offer that could not be taken says why and dims — it does not quietly become an offer
    /// to move to some other login nobody chose.
    func testAnOfferThatCouldNotBeTakenStatesTheReasonAndKeepsItsSubject() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: "5h 96% · 7d 40%",
            resetHint: Fixture.resetHint,
            problem: "Daniel Block is close to its own limit now."
        ))
        host(strip)

        XCTAssertEqual(
            try sentence(in: strip).stringValue,
            "Daniel Block is close to its own limit now."
        )
        XCTAssertFalse(strip.continueControl.isEnabled)
        XCTAssertTrue(
            strip.continueControl.title.contains("5h 96%"),
            "the button keeps the reading the refusal was decided on"
        )
    }

    // MARK: - Accessibility

    func testItIsAGroupWhoseNameCarriesTheLoginAndItsReading() {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        XCTAssertFalse(strip.isAccessibilityElement())
        XCTAssertEqual(strip.accessibilityRole(), .group)

        let spoken = strip.accessibilityLabel() ?? ""
        XCTAssertTrue(spoken.contains("Limit reached"), spoken)
        XCTAssertTrue(spoken.contains(Fixture.accountName), spoken)
        XCTAssertTrue(spoken.contains(Fixture.reading), spoken)
    }

    /// The mark is never a nameless element: the shape carries the meaning on screen and the
    /// label carries it for a reader who cannot see the shape.
    func testTheLimitMarkSaysWhatItMeans() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        let mark = try mark(in: strip)
        XCTAssertEqual(mark.severity, .negative)
        XCTAssertTrue((mark.accessibilityLabel() ?? "").contains("Limit reached"))
    }

    func testBothControlsAreReachableWithoutAPointer() {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        XCTAssertTrue(strip.continueControl.acceptsFirstResponder)
        XCTAssertTrue(strip.dismissControl.acceptsFirstResponder)
    }

    // MARK: - Layout

    /// The sentence yields before the button does: a narrow pane truncates the explanation rather
    /// than squeezing the control that answers it off the row.
    func testANarrowColumnTruncatesTheSentenceRatherThanTheButton() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip, width: Fixture.narrowWidth)

        let said = try sentence(in: strip)
        XCTAssertLessThan(
            said.frame.width,
            said.intrinsicContentSize.width,
            "the sentence did not give way"
        )
        XCTAssertGreaterThan(strip.continueControl.frame.width, 0)
        XCTAssertLessThanOrEqual(
            strip.dismissControl.frame.maxX,
            strip.bounds.width + 0.5,
            "the way out was pushed off the strip"
        )
    }

    func testEverythingSitsOnOneCentreLine() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        for member in [try mark(in: strip) as NSView, strip.continueControl, strip.dismissControl] {
            XCTAssertEqual(
                member.frame.midY, strip.bounds.midY, accuracy: 0.5,
                "\(type(of: member)) does not sit on the strip's centre line"
            )
        }
    }

    // MARK: - Theme

    /// The plate is a **recorded** surface rather than a frozen layer colour, so a theme switched
    /// under a strip that is already standing reaches it.
    ///
    /// The sentence is checked by role rather than by colour identity: every `Design` ink is one
    /// dynamic catalogue colour that resolves per theme, so the object on the label is the same
    /// object before and after and comparing the two proves nothing either way.
    func testALiveThemeSwitchReachesTheStandingStrip() throws {
        AppThemePalette.set(.system)
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        let before = strip.layer?.backgroundColor

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertNotEqual(before, strip.layer?.backgroundColor, "the plate kept its old ground")
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Text.secondary)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: strip), [])
    }

    /// A strip that could not be taken speaks in the status role rather than a colour of its own,
    /// so a theme that redefines "something is wrong" redefines this too.
    func testAProblemTakesTheStatusRoleRatherThanAColourOfItsOwn() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Text.secondary)

        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            resetHint: Fixture.resetHint,
            problem: "Nope."
        ))
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Status.warning)
    }

    /// The rendered check: an offer drawn in both appearances puts ink on the plate. A strip that
    /// laid out correctly and drew nothing passes every assertion above.
    func testItDrawsInBothAppearances() throws {
        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
            let strip = LimitEscapeStripView()
            strip.setOffer(Fixture.offer)
            let host = host(strip)
            // Without this, `cacheDisplay` draws a blank image.
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()

            let representation = try XCTUnwrap(
                strip.bitmapImageRepForCachingDisplay(in: strip.bounds)
            )
            strip.cacheDisplay(in: strip.bounds, to: representation)

            var distinctColours: Set<String> = []
            for x in stride(from: 0, to: representation.pixelsWide, by: 4) {
                for y in stride(from: 0, to: representation.pixelsHigh, by: 4) {
                    guard let colour = representation.colorAt(x: x, y: y) else { continue }
                    distinctColours.insert(colour.description)
                }
            }
            XCTAssertGreaterThan(
                distinctColours.count, 1,
                "the strip drew one flat colour under \(String(describing: appearance?.name))"
            )
        }
    }
}
