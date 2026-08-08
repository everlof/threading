import AppKit
import XCTest
@testable import Threading

/// The pane's third band: a standing condition the pane found on its own, the ways to answer it,
/// and the way to be rid of it.
///
/// What is pinned here is the contract a caller depends on — a press reaches the answer it was
/// aimed at, the ✕ is a real control, the sentence yields before the buttons do — plus the two
/// things that are invisible in a screenshot: whether it is readable by someone who cannot glance
/// at it, and whether its ink survives a live theme switch.
///
/// No window is ordered on screen anywhere below. An unshown host still lays out, which is
/// everything these measure.
@MainActor
final class PaneNoticeTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        /// A pane at a comfortable width, and one narrow enough that the band has to choose
        /// between the sentence and the controls answering it.
        static let width: CGFloat = 720
        static let narrowWidth: CGFloat = 320
        static let height: CGFloat = 400

        static let message = "Threading quit unexpectedly last time."
        static let longMessage = "Threading quit unexpectedly last time. Its open session and "
            + "browser windows were not reopened, and are waiting here until you ask for them."
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    /// A host standing in for a pane: it states its size the way a split item does, rather than
    /// carrying a frame that constrains nothing, so a child measured in it is measured at a width
    /// it was actually asked to fit.
    @discardableResult
    private func host(_ notice: PaneNoticeView, width: CGFloat = Fixture.width) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Fixture.height))
        host.addSubview(notice)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: Fixture.height),
            notice.topAnchor.constraint(equalTo: host.topAnchor),
            notice.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func label(in notice: PaneNoticeView) throws -> NSTextField {
        try XCTUnwrap(
            notice.subviews.compactMap { $0 as? NSTextField }.first,
            "the band has no sentence on it"
        )
    }

    private func glyph(in notice: PaneNoticeView) throws -> GlyphView {
        try XCTUnwrap(
            notice.subviews.compactMap { $0 as? GlyphView }.first,
            "the band has no mark on it"
        )
    }

    private func separator(in notice: PaneNoticeView) throws -> SeparatorView {
        try XCTUnwrap(
            notice.subviews.compactMap { $0 as? SeparatorView }.first,
            "the band does not fold against the content under it"
        )
    }

    // MARK: - The Band

    func testTheBandStandsAtThePanesOwnHeaderHeight() {
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        XCTAssertEqual(notice.frame.height, PaneHeaderView.bandHeight, accuracy: 0.5)
    }

    func testTheHairlineRunsEdgeToEdgeAlongTheBottom() throws {
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        let frame = try separator(in: notice).frame
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxX, notice.bounds.width)
        // Unflipped coordinates: the bottom anchor is the frame's minY.
        XCTAssertEqual(frame.minY, 0)
    }

    /// The pane's own inset, measured to the *ink* rather than to a control's frame — a glyph
    /// button's frame carries its click target, and its edge is not its mark.
    func testTheMarkAndTheTrailingControlBothLandOnTheStatedMargin() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [PaneNoticeAction(title: "Restore") {}],
            onDismiss: {}
        )
        host(notice)

        let mark = try glyph(in: notice)
        XCTAssertEqual(mark.frame.minX, PaneNoticeDefaults.contentInset, accuracy: 0.5)

        let dismiss = try XCTUnwrap(notice.dismissControl)
        XCTAssertEqual(
            dismiss.frame.maxX - dismiss.opticalHorizontalInset,
            notice.bounds.width - PaneNoticeDefaults.contentInset,
            accuracy: 0.5
        )
    }

    func testEverythingOnTheBandSitsOnItsContentCentreLine() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [PaneNoticeAction(title: "Restore") {}],
            onDismiss: {}
        )
        host(notice)

        let rule = try separator(in: notice)
        let contentMidY = (rule.frame.maxY + notice.bounds.maxY) / 2

        for member in [try glyph(in: notice), notice.actionControls[0], notice.dismissControl!] {
            XCTAssertEqual(
                member.frame.midY, contentMidY, accuracy: 0.5,
                "\(type(of: member)) counts the rule as breathing room"
            )
        }
    }

    func testALiveThemeSwitchRemeasuresTheSharedBandAndItsContentLine() throws {
        AppThemePalette.set(.system)
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        let host = host(notice)
        let systemHeight = notice.frame.height
        let systemRule = Design.Radius.border

        AppThemePalette.set(AppThemeStyles.bauhaus)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.bauhaus.id))
        host.layoutSubtreeIfNeeded()

        let rule = try separator(in: notice)
        let mark = try glyph(in: notice)
        XCTAssertEqual(notice.frame.height, PaneHeaderView.bandHeight, accuracy: 0.5)
        XCTAssertEqual(
            notice.frame.height - systemHeight,
            Design.Radius.border - systemRule,
            accuracy: 0.5
        )
        XCTAssertEqual(
            mark.frame.midY,
            (rule.frame.maxY + notice.bounds.maxY) / 2,
            accuracy: 0.5
        )
    }

    /// The sentence yields first. A band too narrow for both wraps and truncates its own words
    /// rather than squeezing the control that answers it into something unreadable.
    func testANarrowBandTruncatesItsSentenceRatherThanItsControls() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.longMessage,
            actions: [
                PaneNoticeAction(title: "Restore") {},
                PaneNoticeAction(title: "Show Crash Report", emphasis: .tertiary) {}
            ],
            onDismiss: {}
        )
        host(notice, width: Fixture.narrowWidth)

        for button in notice.actionControls {
            XCTAssertGreaterThanOrEqual(
                button.frame.width, button.fittingSize.width - 0.5,
                "\(button.title) was squeezed so the sentence could keep its words"
            )
        }
    }

    func testTheSentenceNeverRunsUnderTheControlsAnsweringIt() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.longMessage,
            actions: [PaneNoticeAction(title: "Restore") {}],
            onDismiss: {}
        )
        host(notice, width: Fixture.narrowWidth)

        let sentence = try label(in: notice)
        let firstTrailing = try XCTUnwrap(notice.dismissControl)
        XCTAssertLessThanOrEqual(sentence.frame.maxX, firstTrailing.frame.minX)
    }

    /// The defect the band shipped with, and the reason its budget is two lines rather than one:
    /// `lineBreakMode = .byTruncatingTail` turns wrapping off outright, so the second line was
    /// never spent and the sentence came out clipped at *every* width — at a full 760pt pane it
    /// read "…browser windows were…", losing the half that says what was held back.
    func testASentenceTooLongForOneLineGrowsTheBandRatherThanBeingClipped() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.longMessage,
            actions: [PaneNoticeAction(title: "Restore") {}],
            onDismiss: {}
        )
        host(notice)

        XCTAssertGreaterThan(
            notice.frame.height, PaneHeaderView.bandHeight,
            "the band stayed at its floor, so the sentence it exists to say is clipped"
        )

        // The cell is asked rather than the field: an `NSTextField`'s `intrinsicContentSize` and
        // the cell that typesets it disagree at a width the string very nearly fits, which is the
        // clipping `ToastView` measured its own way out of.
        let sentence = try label(in: notice)
        let drawn = try XCTUnwrap(
            sentence.cell?.cellSize(
                forBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: sentence.bounds.width,
                    height: .greatestFiniteMagnitude
                )
            ).height
        )
        XCTAssertGreaterThanOrEqual(sentence.frame.height, drawn - 0.5)
    }

    /// A pane's content may not decide how tall the window is. Above 500 AppKit reads a
    /// constraint as the window's minimum content size, and a wrapping label resists compression
    /// at 750 — which is how a preview once grew the window off the screen.
    func testTheSentenceIsNotAllowedToSetTheWindowsMinimumHeight() throws {
        let notice = PaneNoticeView(tone: .attention, message: Fixture.longMessage, actions: [])
        host(notice, width: Fixture.narrowWidth)

        let sentence = try label(in: notice)
        XCTAssertLessThan(
            sentence.contentCompressionResistancePriority(for: .vertical).rawValue,
            500
        )
        XCTAssertEqual(sentence.maximumNumberOfLines, PaneNoticeDefaults.maximumLines)
    }

    /// The pane behind it may be filled with the *terminal's* palette, which the app theme knows
    /// nothing about, so the band cannot be transparent.
    func testTheBandDrawsItsOwnGroundRatherThanBorrowingThePanes() throws {
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        let rep = try XCTUnwrap(notice.bitmapImageRepForCachingDisplay(in: notice.bounds))
        notice.cacheDisplay(in: notice.bounds, to: rep)
        let drawn = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        XCTAssertEqual(drawn.alphaComponent, 1, accuracy: 0.001)
    }

    // MARK: - Answering It

    func testEachActionBecomesAControlInTheOrderItWasGiven() {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [
                PaneNoticeAction(title: "Restore") {},
                PaneNoticeAction(title: "Show Crash Report", emphasis: .tertiary) {}
            ]
        )
        host(notice)

        XCTAssertEqual(notice.actionControls.map(\.title), ["Restore", "Show Crash Report"])
        XCTAssertEqual(notice.actionControls.map(\.emphasis), [.secondary, .tertiary])
    }

    /// The controls queue from the trailing edge inwards, so the first action given is the one
    /// furthest from the ✕ — leading to trailing on screen, in the order the caller wrote them.
    func testTheActionsReadLeadingToTrailingInTheOrderTheyWereGiven() {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [
                PaneNoticeAction(title: "Restore") {},
                PaneNoticeAction(title: "Show Crash Report", emphasis: .tertiary) {}
            ],
            onDismiss: {}
        )
        host(notice)

        let positions = notice.actionControls.map(\.frame.minX)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertLessThan(
            notice.actionControls.last!.frame.maxX,
            notice.dismissControl!.frame.minX + 0.5,
            "the ✕ sits at the margin with the answers queued to its leading side"
        )
    }

    /// A press has to reach the answer it was aimed at. The handlers are held beside the buttons
    /// and found by the sender's tag, which is the part a second action would break silently.
    func testPressingAnActionRunsThatActionAndNoOther() {
        var pressed: [String] = []
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [
                PaneNoticeAction(title: "Restore") { pressed.append("Restore") },
                PaneNoticeAction(title: "Show Crash Report") { pressed.append("Report") }
            ]
        )
        host(notice)

        // `performPrimaryAction` is the one route pointer, keyboard and accessibility activation
        // all take through `ThemedControl`, so pressing it here is pressing what the user does.
        _ = notice.actionControls[1].performPrimaryAction()
        XCTAssertEqual(pressed, ["Report"])

        _ = notice.actionControls[0].performPrimaryAction()
        XCTAssertEqual(pressed, ["Report", "Restore"])
    }

    func testABandWithNoWayOutCarriesNoCross() {
        let notice = PaneNoticeView(tone: .informational, message: Fixture.message, actions: [])
        host(notice)

        XCTAssertNil(notice.dismissControl)
    }

    func testTheCrossPerformsTheDismissalItWasGiven() throws {
        var dismissed = 0
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [],
            onDismiss: { dismissed += 1 }
        )
        host(notice)

        _ = try XCTUnwrap(notice.dismissControl).performPrimaryAction()
        XCTAssertEqual(dismissed, 1)
    }

    // MARK: - Read Without Looking

    /// The band appears without being asked for and takes no focus, so its accessible name is
    /// the only thing a screen reader ever gets — which means it has to be the whole sentence.
    func testTheBandIsOneGroupNamedByWhatItSays() {
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        XCTAssertTrue(notice.isAccessibilityElement())
        XCTAssertEqual(notice.accessibilityRole(), .group)
        XCTAssertEqual(notice.accessibilityLabel(), Fixture.message)
        XCTAssertEqual(notice.accessibilityIdentifier(), PaneNoticeDefaults.identifier)
        XCTAssertEqual(notice.message, Fixture.message)
    }

    /// Escape is deliberately not claimed — the band covers nothing and blocks nothing, so
    /// taking the key would take it from the composer underneath. The ✕ is the dismissal, and
    /// it has to be a real, named, keyboard-reachable control for that to be enough.
    func testTheWayOutIsAKeyboardReachableNamedControl() throws {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [PaneNoticeAction(title: "Restore") {}],
            onDismiss: {}
        )
        host(notice)

        let dismiss = try XCTUnwrap(notice.dismissControl)
        XCTAssertTrue(dismiss.isAccessibilityElement())
        XCTAssertTrue(dismiss.canBecomeKeyView || dismiss.acceptsFirstResponder)
        XCTAssertEqual(dismiss.accessibilityIdentifier(), PaneNoticeDefaults.dismissIdentifier)
        // A button's words are its *title*: `accessibilityLabel` maps to AXDescription, and both
        // a screen reader and a UI script ask for the title first.
        XCTAssertEqual(dismiss.accessibilityTitle(), L10n.string("Dismiss"))
    }

    /// A band identifiable by hue alone fails the first viewer who cannot separate two of them,
    /// so the two tones differ in the *shape* of the mark as well as in its ink.
    func testTheTwoTonesDifferInTheirMarkAndNotOnlyInItsInk() throws {
        let attention = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        let informational = PaneNoticeView(
            tone: .informational,
            message: Fixture.message,
            actions: []
        )
        host(attention)
        host(informational)

        let attentionMark = try glyph(in: attention)
        let informationalMark = try glyph(in: informational)

        XCTAssertNotEqual(
            try XCTUnwrap(attentionMark.image?.tiffRepresentation),
            try XCTUnwrap(informationalMark.image?.tiffRepresentation),
            "both tones drew the same glyph, so only the colour tells them apart"
        )
        XCTAssertNotEqual(attentionMark.tint?.hexString, informationalMark.tint?.hexString)
    }

    // MARK: - Theming

    /// The band is not rebuilt when the theme changes — the pane holds it until it is answered —
    /// so it survives a switch only by re-reading its roles when it is told to. A view that had
    /// baked the token into a colour at setup would look identical here and keep the old theme's
    /// ink for as long as it stayed up.
    func testTheInkFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        let mark = try glyph(in: notice)
        let sentence = try label(in: notice)
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
            "the two themes paint the band identically, so this fixture proves nothing"
        )
    }

    /// The fill is drawn rather than assigned to the layer, because a theme colour frozen into a
    /// `CGColor` keeps the theme it was frozen under — and the band outlives a switch.
    func testTheGroundIsDrawnRatherThanFrozenIntoTheLayer() {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let notice = PaneNoticeView(tone: .attention, message: Fixture.message, actions: [])
        host(notice)

        XCTAssertNil(
            notice.layer?.backgroundColor,
            "a layer fill is how a themed surface stops being themed"
        )
    }

    func testTheBandIsBuiltEntirelyFromTheDesignSystem() {
        let notice = PaneNoticeView(
            tone: .attention,
            message: Fixture.message,
            actions: [
                PaneNoticeAction(title: "Restore") {},
                PaneNoticeAction(title: "Show Crash Report", emphasis: .tertiary) {}
            ],
            onDismiss: {}
        )
        host(notice)

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: notice), [])
    }
}
