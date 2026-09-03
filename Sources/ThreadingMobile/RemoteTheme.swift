import BorderBeamKit
import ThreadingRemoteKit
import SwiftUI
import UIKit

/// Layout tokens for application-owned mobile chrome.
///
/// Remote themes own palette and material (radii, border weight and glow). Spacing remains a
/// stable iOS layout concern so changing visual theme never unexpectedly crowds a phone-sized
/// surface. Use this scale instead of introducing measurements at individual call sites.
enum MobileDesign {
    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let inset: CGFloat = 16
        static let large: CGFloat = 20
        static let pane: CGFloat = 24

        /// Composer actions need the normal 44-point tap target, but not a second full inset
        /// above and below it. Keeping these two axes explicit prevents a one-line composer from
        /// becoming needlessly tall while preserving the more generous reading inset at its
        /// leading and trailing edges.
        static let composerHorizontal: CGFloat = inset
        static let composerVertical: CGFloat = small
    }

    enum Size {
        static let minimumTapTarget: CGFloat = 44
        /// The floating return-to-end control stays visually compact while retaining the full
        /// iPhone tap target. Its arrow is deliberately quieter than toolbar glyphs because it
        /// sits over content rather than in a chrome row.
        static let floatingScrollTarget: CGFloat = minimumTapTarget
        static let floatingScrollGlyph: CGFloat = 14
        /// The icon-only chrome control: the dashboard's toolbar circles and the plus that
        /// starts a chat in a project. One size keeps them reading as the same kind of thing.
        static let compactControl: CGFloat = 34
        /// The mark inside a compact glyph control — the paperclip, the draft's one-glyph menus —
        /// as the point size of the subheadline face they draw in. Read when asked rather than
        /// stored: it follows the reader's text size.
        static var compactControlGlyph: CGFloat { glyph(.subheadline) }
        /// The mark inside a glyph control drawn in `textStyle`: that face's point size.
        static func glyph(_ textStyle: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: textStyle).pointSize
        }
        /// The padding a control holds around its visible mark, `(target − mark) / 2` by
        /// construction: the Mac's `ThemedIconButton.opticalHorizontalInset`, stated for the
        /// phone. A container that stands the control on a margin pulls its frame outward by
        /// this much, so the *ink* meets the margin a filled control's plate already stands on.
        /// Equal frame margins are not equal visual margins.
        static func opticalInset(target: CGFloat, mark: CGFloat) -> CGFloat {
            max(0, (target - mark) / 2)
        }
        /// The dashboard's floating bottom pills: the search field and the chat starter riding
        /// above the home indicator. Taller than the minimum tap target because they are the
        /// page's primary actions and float over content rather than sitting in a chrome row.
        static let floatingBarControl: CGFloat = 52
        static let toggleTrackWidth: CGFloat = 52
        static let toggleTrackHeight: CGFloat = 32
        static let toggleThumb: CGFloat = 26
        static let navigationStatusIndicator: CGFloat = 6
        /// How wide a chat's navigation title asks to be, whatever it says.
        ///
        /// The name morphs character by character, and a morph is built against the geometry it
        /// starts in: the label resolves every character's final slot up front, then animates
        /// each one there. A title sized to its own text cannot hold still through a rename,
        /// because the new name is what changed the size — the morph is laid out in the old
        /// width, SwiftUI commits the new one a pass later, and the re-layout snaps every glyph
        /// to its final slot. On screen the animation stops half way through. Claude renaming a
        /// chat to `✳ <name>` moved this bar's title 27 points and did exactly that.
        ///
        /// A *request*, not a guarantee: a bar hands its title what its button groups leave,
        /// which on a 320-point phone is 176. Stating this as both the ideal and the maximum
        /// takes the name out of the answer while leaving the bar's own width in it, so the
        /// title still holds still — the width it settles on depends on the device, never on
        /// what the chat is called. The UIKit conversation title has stated its width since it
        /// was written, for the same reason; this is that decision, named and shared.
        ///
        /// Sized to be *centred* as well as still. UIKit puts a title view on the bar's centre
        /// only when it fits the space that is symmetric about that centre; one wider than that
        /// is centred in whatever lies between the bar's items instead, and the items are never
        /// quite symmetric — a back circle sits 13 points from its edge and a 34-point control
        /// 19 from its, so a 280-point title came to rest 5 points left of centre on every
        /// screen with a control at each end. Between those two, the symmetric space on the
        /// narrowest supported phone (375 points) is 2 × (187.5 − 69), so a title this wide
        /// lands on the centre of every phone.
        static let navigationTitleWidth: CGFloat = 236
        static let navigationTitleHeight: CGFloat = minimumTapTarget
        /// The working orb standing in the status dot's place in a chat's navigation title. It
        /// takes the line the dot leaves rather than a place of its own, so the title stays
        /// centred and one mark speaks at a time; sized to the caption line it sits on rather
        /// than to the orb's own 20pt preset, which would push a two-line title past the bar.
        static let navigationWorkingOrb: CGFloat = 16
        static let dialogActionHeight: CGFloat = 52
        static let conversationEstimatedRowHeight: CGFloat = 88
        static let conversationHistoryTrigger: CGFloat = 180
        static let conversationBottomTolerance: CGFloat = 140
        static let permissionDiffMaximumHeight: CGFloat = 220
        static let permissionDiffMinimumHeight: CGFloat = minimumTapTarget * 2
        static let diffMarkerColumnWidth: CGFloat = 18
        static let workspaceActivityDot: CGFloat = 7
        static let badgeStroke: CGFloat = 2
        /// Between one usage ring and the next inside it: the stroke plus a one-point gap, so
        /// three rings sit 17, 14 and 11 points from the disc's centre and clear its 16-point mark.
        static let usageRingGap: CGFloat = 1
        static let usageRingPitch: CGFloat = badgeStroke + usageRingGap
        /// The same rings as a menu row's glyph. A menu draws its image in the column beside the
        /// label, at about the size of a symbol on that line: three rings at the disc's pitch
        /// still clear one another here, and drawing them any larger only has the menu scale
        /// them back down.
        static let usageMenuGauge: CGFloat = 20
        /// A stroke is centred on the circle it follows, so the outermost ring reaches half a
        /// stroke past the frame. `ImageRenderer` clips to the content it was given; this is the
        /// room that keeps the outer ring whole.
        static let usageMenuGaugeInset: CGFloat = badgeStroke / 2
        /// The current-capacity gauge uses the Mac's same marker vocabulary: a six-point usage
        /// track crossed by a narrow clock line, tall enough to remain visible on either side.
        static let usageCapacityBarHeight: CGFloat = 6
        static let usageTimeMarkWidth: CGFloat = 2
        static let usageTimeMarkHeight: CGFloat = 10
        /// Fixed leading column used by the stacked terminal presence/control/activity rows.
        static let terminalStatusIconColumn: CGFloat = 24

        /// The session row's identity tile, its ink, and the account chip riding its corner.
        ///
        /// Sized against the row's two lines of text rather than against the old 46-point tile: a
        /// dashboard is a list to scan, and the tile was setting a row height no content asked for.
        /// A title line and a caption line come to roughly this, so the tile no longer decides.
        static let rowMark: CGFloat = 30
        static let rowMarkRadius: CGFloat = 9
        static let rowMarkGlyph: CGFloat = 16
        static let accountChip: CGFloat = 15
        static let accountChipGlyph: CGFloat = 9
        /// An emoji's glyph outgrows its point size, so it is set below the letter's.
        static let accountChipEmoji: CGFloat = 10
        static let accountChipRing: CGFloat = 1.5
        static let rowAttentionDot: CGFloat = 8
        /// The working orb at a row's trailing edge, standing where the age would be. Sized to
        /// the caption line it replaces so a working row is no taller than an idle one.
        static let rowWorkingOrb: CGFloat = 16

        /// The draft's composer chips: the chevron that says each is a menu, set to the caption
        /// line the chip's text sits on.
        static let chipChevron: CGFloat = 9
        /// The glyph on the draft's empty ground. A symbol, not a tile: large enough to name the
        /// surface being started, drawn light and in the tertiary ink so it stays a hint.
        static let draftHintGlyph: CGFloat = 30
        /// A cell of the attachment gallery's ledger: a thumbnail big enough to tell a
        /// screenshot from a diagram, small enough that a phone shows six of them.
        static let attachmentLedgerCell: CGFloat = 56
    }

    enum Offset {
        /// The short rise traversed as a return-to-end control enters or leaves the surface.
        static let floatingScrollLift: CGFloat = 12
        /// How far the account chip hangs past the mark's corner. Flush inside the tile it covered
        /// the middle of the mark; hanging it out keeps the mark recognisable underneath.
        static let accountChipOverhang: CGFloat = 3
        /// The same chip on the chat's toolbar disc. Flush with the disc's corner rather than
        /// hanging past it: a navigation bar clips its item's own bounds, and every overhang
        /// tried came back with a flat-bottomed badge. Flush is the whole circle.
        static let accountChipDiscOverhang: CGFloat = 0
        /// How far the attention dot hangs past the mark's top-trailing corner so that its
        /// centre sits on the tile's edge — the midpoint of the corner arc, not the corner of the
        /// bounding box, which on a rounded tile floats the dot off the ink.
        static let rowAttentionDotOverhang: CGFloat = Size.rowAttentionDot / 2
            - Size.rowMarkRadius * (1 - 1 / 2.squareRoot())
    }

    /// Identity colour that is content rather than chrome, so it does not come from a theme role.
    ///
    /// A generated account disc has to stay legible under every authored theme, and it means the
    /// same thing under all of them. The values match `AccountBadgeDefaults` on the Mac so one
    /// login looks like one login on both screens.
    enum Colour {
        static let accountChipSaturation: Double = 0.72
        static let accountChipBrightness: Double = 0.78
        static let accountChipMinimumScale: Double = 0.6
    }

    enum Opacity {
        /// Dims a mark whose session has no live surface, standing in for the tertiary tint that
        /// dims the symbols beside it.
        static let dormantMark: Double = 0.55
        /// Dims an action the surface is offering but cannot perform yet: a dialog button, or a
        /// share grant a dormant chat has nothing to grant.
        static let disabledAction: Double = 0.42
        /// The unfilled part of a usage ring: present enough to read as a ring, faint enough that
        /// the filled arc is what the eye measures.
        static let usageRingTrack: Double = 0.2
        /// Neutral chronology over both the tinted fill and the quiet track.
        static let usageTimeMark: Double = 0.85
    }

    enum Typography {
        static let messageLineSpacing: CGFloat = 4
    }

    enum Motion {
        static let controlResponse: Double = 0.18
        /// Floating return-to-end controls arrive a little more deliberately than an ordinary
        /// tap response, rising and growing into place. Departure is shorter so the control gets
        /// out of the content's way as soon as the live end is reached.
        static let floatingScrollArrival: TimeInterval = 0.24
        static let floatingScrollDeparture: TimeInterval = 0.16
        static let floatingScrollStartScale: CGFloat = 0.88
        /// The attachment ledger bringing the current cell into view, and a page changing under
        /// a tapped cell: one chrome response, so the two read as one move.
        static let ledgerScroll: TimeInterval = 0.25
        /// The session's account disc taking one breath when the agent does something in the
        /// browser: a touch larger, and back, in the time the ellipsis took to pulse.
        static let activityBreathScale: CGFloat = 1.12
        static let activityBreathDuration: TimeInterval = 0.32
        /// LabelMorph's showcase timing brought to the pace of application chrome.
        static let nameMorphTempo: Double = 0.65
        /// The whole character cascade is bounded so sentence-length chat names do not settle
        /// more slowly than short ones.
        static let nameMorphCascade: TimeInterval = 0.3
        /// A connection phrase is one line changing state, not characters becoming a new name.
        /// Keep the complete scroll and its single shared breath inside one bounded chrome
        /// response. The scroll has to clear a caption's full line height: the old 0.2 intensity
        /// moved only about 70% of one line, leaving both phrases stacked over each other.
        static let connectionStatusMorphDuration: TimeInterval = 0.65
        static let connectionStatusMorphIntensity = 0.72
        /// How much of the morph the departing mark's fade takes: gone before the real mark,
        /// which stays invisible for the first half, begins to fade in beside the new phrase.
        static let connectionStatusDepartureShare = 0.42
        /// Every glyph shares one eased trough. Repeating five 100 ms troughs and staggering
        /// them across the sentence made the leading half flicker while a trailing `Book Pro`
        /// stayed fully lit, so the status did not read as one moving line.
        static let connectionStatusFadePulseCount = 1
        static let connectionStatusFadeMinimumOpacity: Float = 0.66
        static let connectionStatusFadePulseDuration: TimeInterval = 0.65
        static let connectionStatusFadePauseDuration: TimeInterval = 0
        static let connectionStatusFadeTravelDuration: TimeInterval = 0
        /// Restate the one active dashboard step without keeping every row in motion.
        static let connectionProgressFadeCadence: TimeInterval = 2
    }
}

/// The connection mark as the bar draws it: a circle in the status colour.
///
/// Where it stands beside the phrase is `MobileConnectionStatusLineView`'s decision, and so is
/// the copy that fades out where it used to stand. The mark itself only settles on a colour —
/// the model colour is always the settled state, so SwiftUI and UIKit agree and an interrupted
/// animation cannot strand it between states — and, when the line asks, stays invisible for the
/// first half of the line's transition before fading back in where the new phrase put it.
final class MobileConnectionStatusIndicatorView: UIView {
    private enum Animation {
        static let transition = "threading.connection-status-indicator.transition"
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    /// Settles on `color` now. `fadingIn` hides the mark for the first half of
    /// `MobileDesign.Motion.connectionStatusMorphDuration` and fades it in over the second —
    /// the line fades a copy out where the mark stood, and the two halves must not overlap.
    func settle(on color: UIColor, fadingIn: Bool) {
        layer.removeAnimation(forKey: Animation.transition)
        backgroundColor = color
        layer.opacity = 1
        guard fadingIn else { return }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0, 1]
        opacity.keyTimes = [0, 0.5, 1]
        opacity.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
        ]

        let transition = CAAnimationGroup()
        transition.animations = [opacity]
        transition.duration = MobileDesign.Motion.connectionStatusMorphDuration
        transition.isRemovedOnCompletion = true
        layer.add(transition, forKey: Animation.transition)
    }

    var isAnimatingTransitionForTesting: Bool {
        layer.animation(forKey: Animation.transition) != nil
    }

    var transitionForTesting: CAAnimationGroup? {
        layer.animation(forKey: Animation.transition) as? CAAnimationGroup
    }
}

/// One connection reading — the mark and the phrase beside it — with one owner for where each
/// stands. Both navigation titles draw their second line with this: the SwiftUI principal item
/// through `MobileConnectionStatusLine`, the UIKit conversation title directly.
///
/// It exists because the mark and the phrase were two views the bar could move separately, and a
/// recording of a chat opening showed both of them flying. The connection settles about 100 ms
/// after the screen appears, which is always inside the push that brings its title in, and that
/// one status change did two things wrong:
///
/// - The mark faded a copy of itself out **in the window**, at `convert(bounds, to: window)`.
///   During a push the model frame is already the resting frame while the presentation is still
///   sliding, so the copy popped in at the far end of the slide, sat still while the words slid
///   under it, and the real mark — hidden for half the morph — faded in somewhere else. On screen
///   a dot appeared from nowhere, held, dimmed, and a different dot arrived beside it.
/// - The phrase label was sized to its words by SwiftUI, and a morph is built against the
///   geometry it starts in. The new phrase was laid out — and tail-truncated — in the old width;
///   the wider frame landed a pass later and `relayoutCurrent()` made the characters that had not
///   fit as fresh, unanimated layers at their final slots. "David's MacBo" was still rising and
///   dim while "ok Pro" already sat lit, a line above it.
///
/// So this view keeps three things true. The label's frame is decided by the row's width and the
/// mark's slot, never by the phrase, so a phrase change re-lays nothing while it morphs and the
/// centred old and new lines cross inside one set of bounds. The mark is placed at the phrase's
/// leading ink by this view's own layout, and the copy that fades out where it stood is this
/// view's subview, so both go wherever the row goes. And a change that lands while anything
/// above this row is mid-animation is committed without any of it: a title still sliding in
/// arrives already saying the settled state, rather than performing a status change in flight.
final class MobileConnectionStatusLineView: UIView {
    private enum Animation {
        static let departing = "threading.connection-status-indicator.departing"
    }

    let indicator = MobileConnectionStatusIndicatorView()
    let label = MobileMorphingTitleLabel()

    /// A mark that stands in the dot's place while a turn runs — a chat's working orb. It takes
    /// the dot's slot rather than a place of its own, so the phrase keeps its position and one
    /// mark speaks at a time. The host owns the mark's theme and its animation; this row only
    /// decides where it stands.
    var workingMark: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let workingMark {
                workingMark.translatesAutoresizingMaskIntoConstraints = false
                workingMarkHost.addSubview(workingMark)
                NSLayoutConstraint.activate([
                    workingMark.centerXAnchor.constraint(equalTo: workingMarkHost.centerXAnchor),
                    workingMark.centerYAnchor.constraint(equalTo: workingMarkHost.centerYAnchor),
                ])
            }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var isWorking = false {
        didSet {
            guard isWorking != oldValue else { return }
            // Entering the working state replaces the dot immediately. A status change may have
            // left both the real dot and its departing copy mid-fade; neither may remain beside
            // the orb, and the settled dot must be ready when work ends again.
            if isWorking {
                departingIndicator?.removeFromSuperview()
                departingIndicator = nil
                if let settledColor {
                    indicator.settle(on: settledColor, fadingIn: false)
                }
            }
            indicator.isHidden = isWorking
            workingMarkHost.isHidden = !isWorking
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// The status this row last settled on; nil before the first one.
    var presentedStatus: String? { settledStatus }

    private let workingMarkHost = UIView()
    private var settledStatus: String?
    private var settledColor: UIColor?
    private weak var departingIndicator: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The host names the whole title; a line that is also an element would be read twice.
        isAccessibilityElement = false
        label.isAccessibilityElement = false
        workingMarkHost.isHidden = true
        workingMarkHost.isUserInteractionEnabled = false
        addSubview(label)
        addSubview(indicator)
        addSubview(workingMarkHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(label.intrinsicContentSize.height, markSize)
        )
    }

    func update(
        status: String,
        color: UIColor,
        textColor: UIColor,
        groundColor: UIColor,
        reducesMotion: Bool
    ) {
        let isFirstPresentation = settledStatus == nil
        // Keyed to the status identity, not only to the colour: the phrase's width is what
        // moves the mark, and it moves between two warning-coloured steps as well.
        let changed = settledStatus != status || settledColor?.isEqual(color) != true
        let animates = changed
            && !isFirstPresentation
            && !reducesMotion
            && window != nil
            && !isHostInMotion
        // Read where the mark is drawn before anything moves it — in this row's coordinates,
        // which are the coordinates the copy will live in.
        let departure = animates && !isWorking ? presentedMark() : nil
        settledStatus = status
        settledColor = color

        departingIndicator?.removeFromSuperview()
        // SwiftUI and the UIKit conversation host may restate the same title several times per
        // frame. Do not let an idempotent restatement remove the transition this change began.
        if changed {
            indicator.settle(on: color, fadingIn: departure != nil)
        }
        label.configure(
            title: status,
            textStyle: .caption2,
            weight: .regular,
            textColor: textColor,
            groundColor: groundColor,
            alignment: .center,
            reducesMotion: reducesMotion,
            animated: animates,
            role: .connectionStatus
        )
        invalidateIntrinsicContentSize()
        // The mark takes its place beside the new phrase in the next layout pass, invisible
        // until the copy is gone. Only `setNeedsLayout`, deliberately: this runs from a
        // `UIViewRepresentable`'s `updateUIView`, which is SwiftUI's own graph update, and a
        // synchronous layout from there is the shape that put the morph label's forced window
        // layout into an AttributeGraph cycle on every status change (LabelMorph in
        // `dependencies.md`). Nothing below needs the new geometry: the departing copy stands
        // where the mark *was*, read above before anything moved.
        setNeedsLayout()

        guard let departure else { return }
        let departing = UIView(frame: departure.frame)
        departing.isUserInteractionEnabled = false
        departing.backgroundColor = departure.color
        departing.layer.cornerCurve = .continuous
        departing.layer.cornerRadius = min(departure.frame.width, departure.frame.height) / 2
        departing.layer.opacity = departure.opacity
        addSubview(departing)
        departingIndicator = departing

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = departure.opacity
        fade.toValue = 0
        fade.duration = MobileDesign.Motion.connectionStatusMorphDuration
            * MobileDesign.Motion.connectionStatusDepartureShare
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        departing.layer.opacity = 0
        departing.layer.add(fade, forKey: Animation.departing)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + MobileDesign.Motion.connectionStatusMorphDuration
        ) { [weak self, weak departing] in
            departing?.removeFromSuperview()
            if self?.departingIndicator === departing {
                self?.departingIndicator = nil
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let mark = markSize
        let slot = mark + MobileDesign.Spacing.tight
        let labelHeight = label.intrinsicContentSize.height
        let labelWidth = max(0, bounds.width - slot)
        // The label's frame follows from the row and the slot alone. It centres whatever it
        // says inside that frame, so the mark lands `Spacing.tight` before the line it draws:
        // the phrase where it fits, the ellipsized head where it does not.
        label.frame = CGRect(
            x: slot,
            y: snapped((bounds.height - labelHeight) / 2),
            width: labelWidth,
            height: labelHeight
        )
        let textWidth = min(label.textWidth(fitting: labelWidth), labelWidth)
        let leading = snapped(max(0, (bounds.width - slot - textWidth) / 2))
        let markFrame = CGRect(
            x: leading,
            y: snapped((bounds.height - mark) / 2),
            width: mark,
            height: mark
        )
        indicator.frame = markFrame
        workingMarkHost.frame = markFrame
    }

    /// The mark's footprint: the dot, or the working mark's own stated size while a turn runs.
    private var markSize: CGFloat {
        guard isWorking, let workingMark else { return MobileDesign.Size.navigationStatusIndicator }
        let stated = workingMark.intrinsicContentSize.width
        if stated > 0 { return stated }
        let measured = workingMark.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        return measured > 0 ? measured : MobileDesign.Size.navigationStatusIndicator
    }

    /// Whether anything above this row is being moved or faded: a push sliding the bar's title
    /// in, a bar collapsing under a scroll. Only geometry and opacity count — a decorative
    /// animation some chrome layer keeps running must not silence every morph under it. Walked
    /// only on a status change, and a view's depth deep.
    private var isHostInMotion: Bool {
        var ancestor = layer.superlayer
        while let current = ancestor {
            for key in current.animationKeys() ?? [] {
                guard let animation = current.animation(forKey: key) else { continue }
                if Self.movesOrFades(animation) { return true }
            }
            ancestor = current.superlayer
        }
        return false
    }

    private static let motionKeyPaths = ["position", "bounds", "transform", "opacity", "frame"]

    private static func movesOrFades(_ animation: CAAnimation) -> Bool {
        if let group = animation as? CAAnimationGroup {
            return group.animations?.contains(where: movesOrFades) == true
        }
        guard let keyPath = (animation as? CAPropertyAnimation)?.keyPath else { return false }
        return motionKeyPaths.contains { keyPath == $0 || keyPath.hasPrefix($0 + ".") }
    }

    /// The mark as it is drawn right now: the real one, or a copy still fading out from an
    /// earlier change when that copy is the more visible of the two.
    private func presentedMark() -> (frame: CGRect, color: UIColor, opacity: Float)? {
        guard let color = indicator.backgroundColor else { return nil }
        var mark = (
            frame: indicator.frame,
            color: color,
            opacity: indicator.layer.presentation()?.opacity ?? indicator.layer.opacity
        )
        if let departingIndicator, let departingColor = departingIndicator.backgroundColor {
            let departingOpacity = departingIndicator.layer.presentation()?.opacity
                ?? departingIndicator.layer.opacity
            if departingOpacity > mark.opacity {
                mark = (departingIndicator.frame, departingColor, departingOpacity)
            }
        }
        return mark
    }

    private func snapped(_ value: CGFloat) -> CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return (value * scale).rounded() / scale
    }

    var departingIndicatorForTesting: UIView? {
        departingIndicator
    }
}

/// SwiftUI's bridge to the status line. Fills the width it is offered, whatever the phrase
/// says, for the reason `MobileMorphingTitle` does: the frame is decided in SwiftUI's pass, a
/// pass after the phrase changed, and a morph cannot survive its bounds moving under it.
struct MobileConnectionStatusLine: UIViewRepresentable {
    let status: String
    let statusColor: Color
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func makeUIView(context: Context) -> MobileConnectionStatusLineView {
        MobileConnectionStatusLineView()
    }

    func updateUIView(_ view: MobileConnectionStatusLineView, context: Context) {
        view.update(
            status: status,
            color: UIColor(statusColor),
            textColor: theme.uiSecondaryLabel,
            groundColor: theme.uiSurface,
            reducesMotion: reducesMotion
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MobileConnectionStatusLineView,
        context: Context
    ) -> CGSize? {
        let height = uiView.intrinsicContentSize.height
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: MobileDesign.Size.navigationTitleWidth, height: height)
        }
        return CGSize(width: width, height: height)
    }
}

/// The compact two-line title shared by remote surfaces and owner flows.
///
/// The first line identifies the task or flow; the second always identifies connection state
/// through colour and the Mac through its user-visible name. Keeping this in the mobile design
/// layer prevents individual screens from drifting back to vague labels such as "Remote control"
/// or duplicating the host name in their body content.
struct MobileConnectionNavigationTitle: View {
    let title: String
    let status: String
    let statusColor: Color
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.hairline) {
            MobileMorphingTitle(
                title: title,
                textStyle: .headline,
                weight: .semibold,
                textColor: theme.uiLabel,
                groundColor: theme.uiSurface,
                alignment: .center
            )
            .frame(maxWidth: .infinity)

            MobileConnectionStatusLine(status: status, statusColor: statusColor)
                .frame(maxWidth: .infinity)
        }
        // Asked for, not measured. The ideal is what a principal toolbar item is sized by, so
        // stating one takes the name out of the answer; the same value as the maximum keeps the
        // title inside whatever the bar's button groups actually left, which on a 320-point
        // phone is well under it. See `MobileDesign.Size.navigationTitleWidth`.
        .frame(
            idealWidth: MobileDesign.Size.navigationTitleWidth,
            maxWidth: MobileDesign.Size.navigationTitleWidth
        )
        .accessibilityElement(children: .combine)
        // Stated, not combined: the two lines are bridged UIKit labels, and combining the
        // children of a SwiftUI element reads nothing off a bridged view, so the title reached
        // VoiceOver as an unnamed element. The name is what the two lines say.
        .accessibilityLabel(Text(verbatim: "\(title), \(status)"))
    }
}

/// The phone's rendering of the Mac's semantic app theme.
///
/// Fallbacks preserve the original mobile appearance against an older host. The Mac sends
/// resolved values, so this layer never needs to know whether a colour came from a built-in,
/// custom, inherited, or dynamic System theme.
struct RemoteThemePalette: Equatable {
    let source: RemoteThemeDTO?

    init(_ source: RemoteThemeDTO?) {
        self.source = source
    }

    var colorScheme: ColorScheme { source?.mode == .light ? .light : .dark }
    var ground: Color { color("ground", fallback: "#16181D") }
    var surface: Color { color("surface", fallback: "#1B1E24") }
    var panel: Color { color("panel", fallback: "#22252C") }
    var elevated: Color { color("elevated", fallback: "#292D35") }
    /// The opaque semantic surface for a modal or other card floating over live content.
    ///
    /// System deliberately sends `panel` as a faint label wash. That is correct for an ordinary
    /// card over the page ground and unreadable for a dialog over text, so mobile floating chrome
    /// follows the Mac alert's `floating_surface` role instead. Older hosts did not send that
    /// derived role; `elevated` is their closest opaque answer. Flattening against the ground also
    /// keeps a custom translucent floating role from revealing the content beneath the modal.
    var floatingSurface: Color { Color(uiFloatingSurface) }
    var controlResting: Color { color("control_resting", fallback: "#FFFFFF12") }
    var controlHover: Color { color("control_hover", fallback: "#FFFFFF20") }
    var border: Color { color("border", fallback: "#FFFFFF14") }
    var divider: Color { color("divider", fallback: "#FFFFFF0C") }
    var label: Color { color("label", fallback: "#F3F4F6") }
    var secondaryLabel: Color { color("secondary_label", fallback: "#A7ABB4") }
    var tertiaryLabel: Color { color("tertiary_label", fallback: "#747983") }
    var accent: Color { color("accent", fallback: "#FFFFFF") }
    /// Text/icon colour chosen from the resolved accent itself, not from an unrelated surface.
    /// Authored themes may pair a pale accent with either a light or dark ground.
    var accentForeground: Color { Color(uiAccentForeground) }
    var accentMuted: Color { color("accent_muted", fallback: "#FFFFFF24") }
    var selection: Color { color("selection", fallback: "#FFFFFF32") }
    var positive: Color { color("status_positive", fallback: "#55B978") }
    var warning: Color { color("status_warning", fallback: "#D9A441") }
    var negative: Color { color("status_negative", fallback: "#D87878") }
    var diffAdded: Color { color("diff_added", fallback: "#55B978") }
    var diffRemoved: Color { color("diff_removed", fallback: "#D87878") }

    var uiGround: UIColor { uiColor("ground", fallback: "#16181D") }
    var uiSurface: UIColor { uiColor("surface", fallback: "#1B1E24") }
    var uiPanel: UIColor { uiColor("panel", fallback: "#22252C") }
    var uiElevated: UIColor { uiColor("elevated", fallback: "#292D35") }
    var uiFloatingSurface: UIColor {
        let authored = source?.colors["floating_surface"]
            .flatMap(UIColor.init(remoteHex:))
            ?? uiElevated
        return authored.remoteComposited(over: uiGround)
    }
    var uiControlResting: UIColor { uiColor("control_resting", fallback: "#FFFFFF12") }
    var uiBorder: UIColor { uiColor("border", fallback: "#FFFFFF14") }
    var uiDivider: UIColor { uiColor("divider", fallback: "#FFFFFF0C") }
    var uiLabel: UIColor { uiColor("label", fallback: "#F3F4F6") }
    var uiSecondaryLabel: UIColor { uiColor("secondary_label", fallback: "#A7ABB4") }
    var uiTertiaryLabel: UIColor { uiColor("tertiary_label", fallback: "#747983") }
    var uiAccent: UIColor { uiColor("accent", fallback: "#FFFFFF") }
    var uiAccentForeground: UIColor {
        guard let luminance = uiAccent.remoteRelativeLuminance else {
            return colorScheme == .light ? .black : .white
        }
        return luminance > MobileKeyboardAppearance.lightThreshold ? .black : .white
    }
    var uiAccentMuted: UIColor { uiColor("accent_muted", fallback: "#FFFFFF24") }
    var uiPositive: UIColor { uiColor("status_positive", fallback: "#55B978") }
    var uiWarning: UIColor { uiColor("status_warning", fallback: "#D9A441") }
    var uiNegative: UIColor { uiColor("status_negative", fallback: "#D87878") }
    var uiDiffAdded: UIColor { uiColor("diff_added", fallback: "#55B978") }
    var uiDiffRemoved: UIColor { uiColor("diff_removed", fallback: "#D87878") }

    /// A usage window's colour by how close it is to its limit.
    ///
    /// One answer for both drawings of a reading: the toolbar disc rings it in `Color`, the chat
    /// menu's gauge is rendered from the same view, and a limit means the same thing in each.
    func usageTint(for fraction: Double?) -> Color {
        switch MobileUsageSeverity.from(fraction: fraction) {
        case .normal: return positive
        case .warning: return warning
        case .critical: return negative
        }
    }

    /// Adaptive identity colours for categorical data such as providers or accounts.
    ///
    /// These deliberately do not use the theme's semantic positive, warning or negative roles:
    /// a provider is not a connection state, warning, or failure. Keeping the distinction in the
    /// palette makes charts legible under every authored chrome without weakening status colour.
    func categorical(_ index: Int) -> Color {
        let darkFallbacks = [
            "#64A8FF", "#B69BFF", "#758BFD",
            "#42C7D9", "#EA83C5", "#C5956B",
        ]
        let lightFallbacks = [
            "#155DB1", "#6F42C1", "#3F51B5",
            "#087E8B", "#A93686", "#855A38",
        ]
        let resolvedIndex = ((index % darkFallbacks.count) + darkFallbacks.count)
            % darkFallbacks.count
        let fallback = colorScheme == .light
            ? lightFallbacks[resolvedIndex]
            : darkFallbacks[resolvedIndex]
        return color("data_series_\(resolvedIndex + 1)", fallback: fallback)
    }

    var panelRadius: CGFloat { CGFloat(source?.material.panelRadius ?? 20) }
    var controlRadius: CGFloat { CGFloat(source?.material.controlRadius ?? 10) }
    var borderWidth: CGFloat { CGFloat(source?.material.borderWidth ?? 1) }
    var glow: RemoteThemeDTO.Material.Glow? { source?.material.glow }

    func color(_ role: String, fallback: String) -> Color {
        Color(uiColor(role, fallback: fallback))
    }

    func uiColor(_ role: String, fallback: String) -> UIColor {
        UIColor(remoteHex: source?.colors[role] ?? fallback) ?? .black
    }
}

private struct RemoteThemeKey: EnvironmentKey {
    static let defaultValue = RemoteThemePalette(nil)
}

extension EnvironmentValues {
    var remoteTheme: RemoteThemePalette {
        get { self[RemoteThemeKey.self] }
        set { self[RemoteThemeKey.self] = newValue }
    }
}

extension View {
    /// Gives a themed panel the Mac theme's optional halo without duplicating shadow math.
    @ViewBuilder
    func remoteThemeGlow(_ theme: RemoteThemePalette) -> some View {
        if let glow = theme.glow,
           let color = UIColor(remoteHex: glow.color) {
            shadow(
                color: Color(color).opacity(glow.opacity),
                radius: CGFloat(glow.radius),
                x: CGFloat(glow.offsetX ?? 0),
                y: CGFloat(-(glow.offsetY ?? 0))
            )
        } else {
            self
        }
    }

    /// Gives an active Ultra choice the same tuned, breathing beam as the package's web demo.
    ///
    /// The model matrix is bounded to one active cell, so only one Metal timeline is mounted.
    /// Palette, appearance, radius and the ordinary material shadow still come from the remote
    /// theme; the multicolour beam is Ultra's semantic emphasis rather than replacement chrome.
    func mobileUltraBeam(
        active: Bool,
        radius: CGFloat,
        reducesMotion: Bool,
        freezesForEvidence: Bool
    ) -> some View {
        borderBeam(
            .pulseOutside,
            colorVariant: .colorful,
            theme: .auto,
            staticColors: reducesMotion || freezesForEvidence,
            duration: 3,
            active: active,
            borderRadius: Double(radius),
            brightness: 1.12,
            saturation: 1.18,
            strength: 1,
            tuning: BeamTuning(
                glowBoost: 1.05,
                strokeOpacity: 1.71,
                innerOpacity: 1.71,
                bloomOpacity: 1.71,
                glowBrightness: 1.3 * 1.71,
                glowSaturate: 1.2 * 1.71
            ),
            rendersStatically: freezesForEvidence
        )
    }
}

/// A full-width action whose foreground remains legible against an arbitrary authored accent.
///
/// SwiftUI's prominent button chooses its own foreground colour, which can disappear when a Mac
/// theme supplies a pale accent. Application-owned mobile actions use the resolved accent contrast
/// instead, while secondary actions stay on the theme's control surface.
struct MobileThemedActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    let theme: RemoteThemePalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.dialogActionHeight)
            .foregroundStyle(kind == .primary ? theme.accentForeground : theme.label)
            .background(
                kind == .primary ? theme.accent : theme.controlResting,
                in: RoundedRectangle(cornerRadius: theme.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .stroke(
                        kind == .primary ? Color.clear : theme.border,
                        lineWidth: theme.borderWidth
                    )
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
    }
}

/// A theme-safe mobile switch whose state stays legible when the theme accent is white.
///
/// The native switch uses a white thumb over the accent track. That collapses into a blank
/// capsule for Threading's default white accent, so the phone owns both surfaces here. Position
/// and the thumb glyph carry state independently of colour.
struct MobileThemedToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let theme: RemoteThemePalette

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                configuration.label
                    .foregroundStyle(theme.label)

                Spacer(minLength: MobileDesign.Spacing.medium)

                track(isOn: configuration.isOn)
            }
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(
            reduceMotion ? nil : .snappy(
                duration: MobileDesign.Motion.controlResponse,
                extraBounce: 0.08
            ),
            value: configuration.isOn
        )
        .accessibilityRepresentation {
            Toggle(
                isOn: Binding(
                    get: { configuration.isOn },
                    set: { configuration.isOn = $0 }
                )
            ) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }

    private func track(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? theme.accent : theme.controlHover)

            Circle()
                .fill(isOn ? theme.ground : theme.label)
                .frame(
                    width: MobileDesign.Size.toggleThumb,
                    height: MobileDesign.Size.toggleThumb
                )
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding((MobileDesign.Size.toggleTrackHeight - MobileDesign.Size.toggleThumb) / 2)
        }
        .frame(
            width: MobileDesign.Size.toggleTrackWidth,
            height: MobileDesign.Size.toggleTrackHeight
        )
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: max(theme.borderWidth, 1))
        }
    }
}

extension UIColor {
    convenience init?(remoteHex source: String) {
        let hex = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else {
            return nil
        }

        let hasAlpha = hex.count == 8
        let redShift: UInt64 = hasAlpha ? 24 : 16
        let greenShift: UInt64 = hasAlpha ? 16 : 8
        let blueShift: UInt64 = hasAlpha ? 8 : 0
        self.init(
            red: CGFloat((value >> redShift) & 0xff) / 255,
            green: CGFloat((value >> greenShift) & 0xff) / 255,
            blue: CGFloat((value >> blueShift) & 0xff) / 255,
            alpha: hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        )
    }

    /// Resolves a possibly translucent semantic role to the colour it has over the theme ground.
    /// Floating chrome must keep that appearance without allowing arbitrary live content through.
    fileprivate func remoteComposited(over ground: UIColor) -> UIColor {
        var foregroundRed: CGFloat = 0
        var foregroundGreen: CGFloat = 0
        var foregroundBlue: CGFloat = 0
        var foregroundAlpha: CGFloat = 0
        var groundRed: CGFloat = 0
        var groundGreen: CGFloat = 0
        var groundBlue: CGFloat = 0
        var groundAlpha: CGFloat = 0
        guard getRed(
            &foregroundRed,
            green: &foregroundGreen,
            blue: &foregroundBlue,
            alpha: &foregroundAlpha
        ), ground.getRed(
            &groundRed,
            green: &groundGreen,
            blue: &groundBlue,
            alpha: &groundAlpha
        ) else { return self }

        let alpha = foregroundAlpha + groundAlpha * (1 - foregroundAlpha)
        guard alpha > 0 else { return .clear }

        func composite(_ foreground: CGFloat, over background: CGFloat) -> CGFloat {
            (
                foreground * foregroundAlpha
                    + background * groundAlpha * (1 - foregroundAlpha)
            ) / alpha
        }

        return UIColor(
            red: composite(foregroundRed, over: groundRed),
            green: composite(foregroundGreen, over: groundGreen),
            blue: composite(foregroundBlue, over: groundBlue),
            alpha: alpha
        )
    }
}
