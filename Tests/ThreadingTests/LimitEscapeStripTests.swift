import AppKit
import XCTest
@testable import Threading

/// The pane ribbon that offers a way past a spent usage limit.
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
        /// A pane at a comfortable width, and one narrow enough that the ribbon has to
        /// choose between its sentence and the button answering it.
        static let width: CGFloat = 620
        static let narrowWidth: CGFloat = 260
        static let height: CGFloat = 120

        static let accountName = "Daniel Block"
        static let reading = "5h 12% · 7d 40%"
        static let resetHint = "9:40pm (Europe/Rome)"

        /// The ledger `CurfewReceiptWords.stripSentence` writes, handed over whole — this strip
        /// never assembles one, which is why the fixture is a string rather than a state.
        static let curfewLine = "Curfew since 04:00 · wrap-up sent 03:50 · interrupted 04:05 ×2"

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

    /// A host standing in for the pane: it states its size the way a split item
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

    /// The conduct mark, which is an image view rather than a `ThemedWarningMark` — that
    /// difference *is* the behaviour under test, so the helper finds it by what it is.
    private func conductMark(in strip: LimitEscapeStripView) throws -> NSImageView {
        try XCTUnwrap(
            strip.subviews.compactMap { $0 as? NSImageView }.first,
            "the strip carries no conduct mark"
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

    // MARK: - The Wait Offer

    /// The case the strip was not drawn for at all until this landed: one login, spent, nothing
    /// to move to. It used to mean no record and therefore no strip, leaving the sidebar's
    /// triangle as the only thing saying the session had stopped — and no way to arm the wait
    /// on a refusal that was already standing.
    func testARefusalWithNoLoginStillDrawsAndOffersTheWait() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        XCTAssertFalse(strip.isHidden)
        XCTAssertTrue(
            strip.continueControl.isHidden,
            "a login that does not exist is absent from the row, not dimmed on it"
        )
        XCTAssertFalse(strip.waitControl.isHidden)
        XCTAssertTrue(strip.waitControl.isEnabled)
        XCTAssertTrue(try sentence(in: strip).stringValue.contains(Fixture.resetHint))
    }

    func testBothAnswersStandTogetherWhenBothAreAvailable() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        XCTAssertFalse(strip.continueControl.isHidden)
        XCTAssertFalse(strip.waitControl.isHidden)
        XCTAssertTrue(strip.continueControl.title.contains(Fixture.accountName))
    }

    /// Already armed means already answered: the pending send is the fact from then on, and the
    /// composer's scheduled-message strip is what names it.
    func testTheWaitIsNotOfferedOnceItHasBeenTaken() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            offersWaitForReset: false,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        XCTAssertTrue(strip.waitControl.isHidden)
        XCTAssertFalse(strip.continueControl.isHidden)
    }

    /// **The button and the standing option must not share a name.** They were identical once,
    /// on the reasoning that one behaviour deserves one name — and the result was a control
    /// reading as a mode on a row whose first two words are "Limit reached", where switching a
    /// setting on could no longer change anything. A button instructs; a checkbox states. This
    /// pins the split so a later tidy-up does not helpfully merge them back.
    func testTheButtonInstructsWhileTheStandingOptionStates() {
        XCTAssertEqual(LimitEscapeStripStrings.waitForReset, "Wait for Reset")
        XCTAssertEqual(SessionActionMenuDefaults.limitRecoveryTitle, "Continue at Reset")
        XCTAssertNotEqual(
            LimitEscapeStripStrings.waitForReset,
            SessionActionMenuDefaults.limitRecoveryTitle
        )
    }

    /// The button does not repeat the reset the sentence beside it already quotes: two clocks on
    /// one row invite a comparison that means nothing.
    func testTheButtonDoesNotRestateTheResetTheSentenceCarries() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        XCTAssertFalse(strip.waitControl.title.contains("9:40"), strip.waitControl.title)
    }

    func testTheWaitButtonReachesItsAction() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(offersWaitForReset: true))
        host(strip)

        var pressed = 0
        strip.onWaitForReset = { pressed += 1 }

        // Through the control's own semantic action, like the sibling test above: a themed
        // button answers that rather than `performClick`, and pressing what the user presses is
        // the whole point of the control being readable from here.
        XCTAssertTrue(strip.waitControl.performPrimaryAction())
        XCTAssertEqual(pressed, 1)
    }

    /// A press in flight dims both answers, not just the one pressed: the second would act on the
    /// same refusal, and two recoveries for one stop is the thing every guard here is for.
    func testAPressInFlightDimsBothAnswers() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            offersWaitForReset: true,
            busy: .moveAccount
        ))
        host(strip)

        XCTAssertFalse(strip.continueControl.isEnabled)
        XCTAssertFalse(strip.waitControl.isEnabled)
    }

    /// **Only the pressed answer reports itself working.** Both dim, but a strip saying
    /// "Continuing as Daniel Block…" because somebody pressed *Continue at Reset* would name a
    /// login change that is not happening, to a conversation that has not moved — which is why
    /// the record names the action instead of counting a Boolean.
    func testOnlyThePressedAnswerSaysItIsWorking() {
        let strip = LimitEscapeStripView()

        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            offersWaitForReset: true,
            busy: .waitForReset
        ))
        host(strip)

        XCTAssertEqual(strip.waitControl.title, LimitEscapeStripStrings.waitingBusy)
        XCTAssertTrue(
            strip.continueControl.title.contains(Fixture.accountName),
            "the login button announced a migration nobody asked for: \(strip.continueControl.title)"
        )

        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            offersWaitForReset: true,
            busy: .moveAccount
        ))

        XCTAssertEqual(strip.continueControl.title, L10n.string("Continuing…"))
        XCTAssertEqual(strip.waitControl.title, LimitEscapeStripStrings.waitForReset)
    }

    /// A stood-down press is owed an answer where it was made. The sentence replaces the state
    /// and the controls dim, rather than the strip vanishing and taking the reason with it.
    func testAStoodDownWaitSaysWhyAndKeepsTheRowStanding() throws {
        let strip = LimitEscapeStripView()
        let problem = "There is no usage reading yet to schedule against."
        strip.setOffer(LimitEscapeStripView.Offer(
            offersWaitForReset: true,
            resetHint: Fixture.resetHint,
            problem: problem
        ))
        host(strip)

        XCTAssertFalse(strip.isHidden)
        XCTAssertEqual(try sentence(in: strip).stringValue, problem)
        XCTAssertFalse(strip.waitControl.isEnabled)
    }

    func testTheSpokenLabelNamesBothAnswers() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        let spoken = strip.accessibilityLabel() ?? ""
        XCTAssertTrue(spoken.contains(Fixture.accountName), spoken)
        XCTAssertTrue(spoken.contains(LimitEscapeStripStrings.waitToolTip), spoken)
    }

    /// A refusal carrying only the wait still reads as one statement rather than trailing an
    /// empty clause where the login would have been.
    func testTheSpokenLabelOmitsTheLoginWhenThereIsNone() {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        let spoken = strip.accessibilityLabel() ?? ""
        XCTAssertFalse(spoken.contains("Continue as"), spoken)
        XCTAssertTrue(spoken.contains(LimitEscapeStripStrings.waitToolTip), spoken)
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
            busy: .moveAccount
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

    // MARK: - A Curfew

    /// **The triangle stays the provider's.** `ThemedWarningMark` means "this was done to you and
    /// you cannot answer it"; a curfew is a line the reader drew themselves and can end with the
    /// button beside it, and wearing the triangle for that would teach them that the triangle is
    /// sometimes negotiable.
    func testACurfewWearsTheConductMarkAndNotTheProvidersTriangle() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        XCTAssertTrue(
            try mark(in: strip).isHidden,
            "the user's own bedtime borrowed the provider's warning triangle"
        )
        XCTAssertFalse(try conductMark(in: strip).isHidden)
    }

    /// The whole ledger, in the words its owner wrote — the strip states it and invents none of it.
    func testACurfewSaysWhatItHasAlreadyDoneToTheSession() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        XCTAssertEqual(try sentence(in: strip).stringValue, Fixture.curfewLine)
    }

    /// A line that failed to arrive still says why nothing is being sent, rather than leaving an
    /// unexplained plate over the conversation — the case this whole strip exists to prevent.
    func testACurfewWithNoLineStillNamesTheStateItIsIn() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(LimitEscapeStripView.Offer(source: .curfew))
        host(strip)

        XCTAssertEqual(try sentence(in: strip).stringValue, L10n.string("Under a curfew"))
    }

    /// One answer, and it ends the rule rather than making an exception to it. No wait, because
    /// no window is coming back; **no ✕**, because a standing state has the lift — putting the
    /// sentence away would hide the reason while leaving the hold exactly where it was.
    func testACurfewOffersTheLiftAloneWithNoWaitAndNoWayToWaveItAway() {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        XCTAssertFalse(strip.continueControl.isHidden)
        XCTAssertTrue(strip.continueControl.isEnabled)
        XCTAssertEqual(strip.continueControl.title, L10n.string("Lift Curfew"))
        XCTAssertTrue(strip.waitControl.isHidden, "a curfew has no window to wait for")
        XCTAssertTrue(
            strip.dismissControl.isHidden,
            "a curfew that is holding the session right now can be dismissed out of sight"
        )
    }

    /// The one button, third act. A curfew's press must not migrate the conversation to another
    /// login and must not stand a *custom limit* down — those are different rules with different
    /// lifetimes, and the strip is shared.
    func testACurfewsButtonRoutesToTheLiftAndNowhereElse() {
        let strip = LimitEscapeStripView()
        var lifted = 0
        var migrated = false
        var continuedAnyway = false
        strip.onLiftCurfew = { lifted += 1 }
        strip.onContinue = { migrated = true }
        strip.onContinueAnyway = { continuedAnyway = true }

        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        XCTAssertTrue(strip.continueControl.performPrimaryAction())

        XCTAssertEqual(lifted, 1)
        XCTAssertFalse(migrated, "a curfew's button moved the conversation to another account")
        XCTAssertFalse(continuedAnyway, "a curfew's button stood down somebody's spending limit")
    }

    /// Read aloud, the row is the ledger and then the way out of it. A reader who cannot glance
    /// at the strip is owed the answer as well as the state — the button carries no login to
    /// announce it for them here.
    func testACurfewsSpokenLabelCarriesItsLedgerAndItsAnswer() {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        let spoken = strip.accessibilityLabel() ?? ""
        XCTAssertTrue(spoken.contains(Fixture.curfewLine), spoken)
        XCTAssertTrue(spoken.contains(L10n.string("Lift Curfew")), spoken)
        XCTAssertFalse(
            spoken.contains(LimitEscapeStripStrings.waitToolTip),
            "the spoken row offered a wait the drawn row does not have"
        )
    }

    /// The mark is never a nameless element, whichever mark is showing: the shape carries the
    /// meaning on screen and the label carries it for a reader who cannot see the shape.
    func testTheConductMarkSaysWhatItMeans() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        XCTAssertEqual(
            try conductMark(in: strip).accessibilityLabel(),
            Fixture.curfewLine
        )
    }

    /// The two states are one strip, so switching between them has to put every control back —
    /// the ✕ a curfew removed included. A row that kept a curfew's missing dismissal would leave
    /// the next provider refusal with no way out of it.
    func testAProviderRefusalAfterACurfewGetsItsWayOutBack() {
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)
        XCTAssertTrue(strip.dismissControl.isHidden)

        strip.setOffer(Fixture.offer)

        XCTAssertFalse(strip.dismissControl.isHidden)
        XCTAssertFalse(try mark(in: strip).isHidden)
        XCTAssertTrue(try conductMark(in: strip).isHidden)
    }

    // MARK: - Layout

    func testItUsesPaneRibbonGeometryRatherThanARoundedComposerCard() {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)

        XCTAssertEqual(strip.frame.height, PaneNoticeDefaults.bandHeight, accuracy: 0.5)
        XCTAssertEqual(strip.layer?.cornerRadius ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(
            strip.subviews.compactMap { $0 as? SeparatorView }.count,
            1,
            "a pane ribbon needs one edge-to-edge closing rule"
        )
    }

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
        strip.setOffer(LimitEscapeStripView.Offer(
            accountName: Fixture.accountName,
            reading: Fixture.reading,
            offersWaitForReset: true,
            resetHint: Fixture.resetHint
        ))
        host(strip)

        // Measured in the strip's own space rather than off each member's `frame`, because the
        // two answers are held in a stack and a frame read straight off one is stated in *its*
        // coordinates. The original form only worked while every member was a direct subview,
        // which is a fact about the hierarchy rather than about where the ink lands.
        let members: [NSView] = [
            try mark(in: strip),
            strip.continueControl,
            strip.waitControl,
            strip.dismissControl
        ]
        for member in members {
            let inStrip = try XCTUnwrap(member.superview).convert(member.frame, to: strip)
            XCTAssertEqual(
                inStrip.midY, strip.bounds.midY, accuracy: 0.5,
                "\(type(of: member)) does not sit on the strip's centre line"
            )
        }
    }

    /// The screenshot regression: the sentence was assigned the row's slack while the action was
    /// pinned beside the far-edge dismissal, turning one choice into two unrelated islands. The
    /// action belongs to the sentence; only dismissal owns the opposite edge.
    func testAWideStripKeepsTheActionWithTheConditionItAnswers() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip, width: 900)

        let sentence = try sentence(in: strip)
        let action = strip.continueControl
        let actionInStrip = try XCTUnwrap(action.superview).convert(action.frame, to: strip)

        let actionGap = actionInStrip.minX - sentence.frame.maxX
        XCTAssertGreaterThanOrEqual(actionGap, Design.Spacing.small)
        XCTAssertLessThanOrEqual(actionGap, Design.Spacing.medium)
        XCTAssertGreaterThan(
            strip.bounds.maxX - actionInStrip.maxX,
            Design.Spacing.pane,
            "the action is still being used as the strip's trailing-edge furniture"
        )
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
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Text.label)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: strip), [])
    }

    /// The same question asked of the state the *conduct* mark draws in. The mark's tint used to
    /// be set once at construction, which is exactly the shape that survives a light/dark switch
    /// and quietly fails an app-theme one — so it is inked from the sweep with everything else.
    func testALiveThemeSwitchReachesAStandingCurfewStrip() throws {
        AppThemePalette.set(.system)
        let strip = LimitEscapeStripView()
        strip.setOffer(.curfew(line: Fixture.curfewLine))
        host(strip)

        let before = strip.layer?.backgroundColor

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertNotEqual(before, strip.layer?.backgroundColor, "the plate kept its old ground")
        XCTAssertEqual(try conductMark(in: strip).contentTintColor, Design.Text.secondary)
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Text.label)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: strip), [])
    }

    /// A strip that could not be taken speaks in the status role rather than a colour of its own,
    /// so a theme that redefines "something is wrong" redefines this too.
    func testAProblemTakesTheStatusRoleRatherThanAColourOfItsOwn() throws {
        let strip = LimitEscapeStripView()
        strip.setOffer(Fixture.offer)
        host(strip)
        XCTAssertEqual(try sentence(in: strip).textColor, Design.Text.label)

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
    ///
    /// Three shapes, because they are three different layouts: the account offer fills the row, a
    /// wait-only refusal has to stand without the control the sentence was sized against, and a
    /// curfew draws a different mark beside a much longer sentence with no ✕ closing the row.
    func testItDrawsInBothAppearances() throws {
        let offers = [
            Fixture.offer,
            LimitEscapeStripView.Offer(
                offersWaitForReset: true,
                resetHint: Fixture.resetHint
            ),
            .curfew(line: Fixture.curfewLine)
        ]
        for (appearance, offer) in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)]
            .flatMap({ appearance in offers.map { (appearance, $0) } }) {
            let strip = LimitEscapeStripView()
            strip.setOffer(offer)
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
