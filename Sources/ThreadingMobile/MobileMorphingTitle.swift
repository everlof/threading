import LabelMorph
import SwiftUI
import UIKit

enum MobileMorphingTextRole: Equatable {
    case chatName
    case connectionStatus
    case connectionProgress
}

// MARK: - Mobile Glyph Presentation

/// Chooses how a title's marks are drawn, without changing the title itself.
///
/// An agent names its own chat through the terminal's title, and Claude's is `✳ <name>`.
/// U+2733 is emoji-*capable* but its default presentation is text, and which face satisfies it
/// is a platform decision rather than a property of the string: macOS falls back to Zapf
/// Dingbats and draws the mark the sidebar and the terminal already draw, while iOS resolves the
/// same scalar to Apple Color Emoji — a green asterisk on a shaded plate, at nearly twice the
/// advance. VS15 asks the fallback cascade for the text presentation both platforms agree on.
///
/// Only symbols that are *already* text by default are rewritten, and only when the author has
/// not asked for emoji with VS16. A chat named "🚀 Ship it" keeps its rocket: that scalar's own
/// default presentation is emoji, and the phone renders it as one.
///
/// The line is Unicode's own default rather than "does it look nice in colour", and that is a
/// decision, not an accident. Several text-default scalars do have handsome colour forms on this
/// platform — ❤ ☀ ℹ ✔ ‼ ⏸ all resolve to Apple Color Emoji bare, where macOS draws every one of
/// them as an outline with or without the selector. Following the character's own default is what
/// makes one chat name look like one chat name on both screens; drawing the pretty ones in colour
/// would mean a per-scalar list to keep, and a heart that changes colour when you pick up your
/// phone.
enum MobileGlyphPresentation {
    private static let textVariationSelector = UnicodeScalar(0xFE0E)!

    static func presented(_ title: String) -> String {
        guard title.unicodeScalars.contains(where: isTextDefaultEmoji) else { return title }
        return String(title.map(presented))
    }

    private static func presented(_ character: Character) -> Character {
        let scalars = character.unicodeScalars
        guard let base = scalars.first, isTextDefaultEmoji(base) else { return character }
        switch scalars.count {
        case 1:
            return Character(String(base) + String(textVariationSelector))
        case 2 where scalars.last == textVariationSelector:
            return character
        default:
            // A keycap, a modifier, or an explicit VS16: the author or the sender said more
            // about this cluster than "here is a mark", and that is theirs to say.
            return character
        }
    }

    private static func isTextDefaultEmoji(_ scalar: UnicodeScalar) -> Bool {
        scalar.value > 0x7F
            && scalar.properties.isEmoji
            && !scalar.properties.isEmojiPresentation
    }
}

/// The phone's design boundary around LabelMorph.
///
/// LabelMorph owns character layout and animation. This view owns Dynamic Type, tail
/// truncation, semantic theme colours, Reduce Motion, accessibility, and the app's bounded
/// title tempo. It is shared by SwiftUI rows/navigation chrome and UIKit's native conversation
/// title so a rename has one presentation on every mobile chat surface.
final class MobileMorphingTitleLabel: UIView {
    private enum Defaults {
        static let intensity = 0.72
    }

    private let label = MorphingLabel()
    private var textStyle = UIFont.TextStyle.headline
    private var weight = UIFont.Weight.regular
    private var role = MobileMorphingTextRole.chatName
    private var presentedTitle = ""

    var stringValue: String { presentedTitle }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.truncation = .tail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            // LabelMorph's glyph rasters extend past their typographic boxes so overhanging ink
            // remains intact. This wrapper clips navigation chrome, so the overflow has to live
            // inside our bounds instead of losing the first and last tile at the edges.
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: MorphingLabel.glyphRasterOverflow
            ),
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -MorphingLabel.glyphRasterOverflow
            ),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // A navigation-title stack has to compress a sentence to the bar's width. Keep a real
        // intrinsic resistance, though: priority 1 lets UIStackView satisfy that over-width
        // case by collapsing the title all the way to zero rather than to the available width.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: MobileMorphingTitleLabel, _) in
            view.applyFont()
        }
        applyEffect(morphingTo: "", role: .chatName)
    }

    override var intrinsicContentSize: CGSize {
        let content = label.intrinsicContentSize
        return CGSize(
            width: content.width + MorphingLabel.glyphRasterOverflow * 2,
            height: content.height
        )
    }

    /// The width of the line this view draws when it is `width` wide: the whole title where it
    /// fits inside the reserved raster overflow, or the ellipsized head tail truncation leaves.
    /// A host placing something beside the words — the connection mark — measures this rather
    /// than the frame, because the frame is the slot and the line is centred inside it.
    func textWidth(fitting width: CGFloat) -> CGFloat {
        label.width(fitting: max(0, width - MorphingLabel.glyphRasterOverflow * 2))
    }

    /// Where the drawn characters' ink is, in this view's coordinates.
    var glyphInkFrames: [CGRect] {
        label.glyphInkFrames.map { convert($0, from: label) }
    }

    func configure(
        title: String,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight,
        textColor: UIColor,
        groundColor: UIColor,
        alignment: NSTextAlignment,
        reducesMotion: Bool,
        animated: Bool = true,
        role: MobileMorphingTextRole = .chatName
    ) {
        let fontChanged = self.textStyle != textStyle || self.weight != weight
        let roleChanged = self.role != role
        self.textStyle = textStyle
        self.weight = weight
        self.role = role
        if fontChanged || label.font != resolvedFont() {
            applyFont()
        }

        label.textColor = textColor
        label.rasterizationBackground = groundColor
        label.alignment = alignment

        // `animated` is the host's say: a status line whose bar is mid-transition lands its
        // phrase rather than morphing it in flight. The rest is this view's.
        let animates = animated
            && !presentedTitle.isEmpty
            && title != presentedTitle
            && !reducesMotion
            && window != nil
        // The label is given the presentation; everything this view answers with — the title it
        // reports, what VoiceOver reads, what counts as a rename — stays the title it was told.
        let presented = role == .chatName
            ? MobileGlyphPresentation.presented(title)
            : title
        if roleChanged || animates {
            applyEffect(morphingTo: presented, role: role)
        }
        label.setText(presented, animated: animates)
        presentedTitle = title
        accessibilityLabel = title
        invalidateIntrinsicContentSize()
    }

    private func applyFont() {
        label.font = resolvedFont()
        invalidateIntrinsicContentSize()
    }

    private func resolvedFont() -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: textStyle,
            compatibleWith: traitCollection
        ).addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }

    private func applyEffect(morphingTo title: String, role: MobileMorphingTextRole) {
        switch role {
        case .chatName:
            let preset = MorphPreset.shapeMorph
            label.effect = preset.makeEffect(intensity: Defaults.intensity)
            var timing = preset.recommendedTiming
            timing.duration *= MobileDesign.Motion.nameMorphTempo
            let steps = Double(max(1, max(presentedTitle.count, title.count) - 1))
            timing.stagger = min(
                timing.stagger * MobileDesign.Motion.nameMorphTempo,
                MobileDesign.Motion.nameMorphCascade / steps
            )
            label.timing = timing
            label.fadeStyle = .none

        case .connectionStatus:
            label.effect = MorphPreset.lineScrollUp.makeEffect(
                intensity: MobileDesign.Motion.connectionStatusMorphIntensity
            )
            label.timing = MorphTiming(
                duration: MobileDesign.Motion.connectionStatusMorphDuration,
                stagger: 0
            )
            applyConnectionFade()

        case .connectionProgress:
            label.effect = MorphPreset.crossfade.makeEffect()
            label.timing = MorphPreset.crossfade.recommendedTiming
            applyConnectionFade()
        }
    }

    private func applyConnectionFade() {
        label.fadeStyle = .traveling
        label.fadeConfiguration = MorphFadeConfiguration(
            pulseCount: MobileDesign.Motion.connectionStatusFadePulseCount,
            minimumOpacity: MobileDesign.Motion.connectionStatusFadeMinimumOpacity,
            pulseDuration: MobileDesign.Motion.connectionStatusFadePulseDuration,
            pauseDuration: MobileDesign.Motion.connectionStatusFadePauseDuration,
            travelDuration: MobileDesign.Motion.connectionStatusFadeTravelDuration
        )
    }

    func playFade() {
        label.playFade()
    }

    func stopFade() {
        label.stopFade()
    }

    var isAnimatingTitleForTesting: Bool {
        layer.sublayers?.contains(where: Self.hasAnimations) == true
    }

    var isAnimatingLineScrollForTesting: Bool {
        Self.hasAnimation(withPrefix: "morph.line.", in: layer)
    }

    var isAnimatingTravelingFadeForTesting: Bool {
        Self.hasAnimation(withPrefix: "morph.fade.traveling", in: layer)
    }

    private static func hasAnimations(_ layer: CALayer) -> Bool {
        if layer.animationKeys()?.isEmpty == false { return true }
        return layer.sublayers?.contains(where: hasAnimations) == true
    }

    private static func hasAnimation(withPrefix prefix: String, in layer: CALayer) -> Bool {
        if layer.animationKeys()?.contains(where: { $0.hasPrefix(prefix) }) == true { return true }
        return layer.sublayers?.contains {
            hasAnimation(withPrefix: prefix, in: $0)
        } == true
    }
}

/// SwiftUI's retained bridge to the same UIKit title used by the native conversation chrome.
struct MobileMorphingTitle: UIViewRepresentable {
    let title: String
    let textStyle: UIFont.TextStyle
    let weight: UIFont.Weight
    let textColor: UIColor
    let groundColor: UIColor
    let alignment: NSTextAlignment
    let role: MobileMorphingTextRole
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    init(
        title: String,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight,
        textColor: UIColor,
        groundColor: UIColor,
        alignment: NSTextAlignment,
        role: MobileMorphingTextRole = .chatName
    ) {
        self.title = title
        self.textStyle = textStyle
        self.weight = weight
        self.textColor = textColor
        self.groundColor = groundColor
        self.alignment = alignment
        self.role = role
    }

    func makeUIView(context: Context) -> MobileMorphingTitleLabel {
        MobileMorphingTitleLabel()
    }

    /// Fills the width it is offered, whatever the title says.
    ///
    /// A morph is built against the geometry it starts in: the label resolves every character's
    /// final slot up front and animates each one there. A label sized to its own text cannot
    /// hold still through a rename, because the new name is what changed the size — the morph is
    /// laid out in the old width, SwiftUI commits the new one a pass later, and the re-layout
    /// snaps every glyph to its final slot. On screen the animation stops half way. Claude
    /// renaming a chat to `✳ <name>` moved the terminal's navigation title 27 points and did
    /// exactly that. Filling the offer instead makes the container decide — the bar's title
    /// area, the row's remaining width — and a rename changes only the glyphs inside it.
    ///
    /// The connection phrase once hugged its words here instead, so that the status mark beside
    /// it in a SwiftUI row would not be stranded at the slot's leading edge — and paid for it
    /// with exactly the snap above, drawn as a phrase in two pieces. That row is
    /// `MobileConnectionStatusLineView` now: it gives the phrase a frame the words do not decide
    /// and places the mark at the drawn line itself, so nothing bridged here needs to hug.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MobileMorphingTitleLabel,
        context: Context
    ) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: width, height: intrinsic.height)
    }

    func updateUIView(_ view: MobileMorphingTitleLabel, context: Context) {
        view.configure(
            title: title,
            textStyle: textStyle,
            weight: weight,
            textColor: textColor,
            groundColor: groundColor,
            alignment: alignment,
            reducesMotion: reducesMotion,
            role: role
        )
    }
}
