import LabelMorph
import SwiftUI
import UIKit

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
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        applyEffect(morphingTo: "")
    }

    override var intrinsicContentSize: CGSize {
        label.intrinsicContentSize
    }

    func configure(
        title: String,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight,
        textColor: UIColor,
        groundColor: UIColor,
        alignment: NSTextAlignment,
        reducesMotion: Bool
    ) {
        let fontChanged = self.textStyle != textStyle || self.weight != weight
        self.textStyle = textStyle
        self.weight = weight
        if fontChanged || label.font != resolvedFont() {
            applyFont()
        }

        label.textColor = textColor
        label.rasterizationBackground = groundColor
        label.alignment = alignment

        let animates = !presentedTitle.isEmpty
            && title != presentedTitle
            && !reducesMotion
            && window != nil
        if animates {
            applyEffect(morphingTo: title)
        }
        label.setText(title, animated: animates)
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

    private func applyEffect(morphingTo title: String) {
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
    }

    var isAnimatingTitleForTesting: Bool {
        layer.sublayers?.contains(where: Self.hasAnimations) == true
    }

    private static func hasAnimations(_ layer: CALayer) -> Bool {
        if layer.animationKeys()?.isEmpty == false { return true }
        return layer.sublayers?.contains(where: hasAnimations) == true
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
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func makeUIView(context: Context) -> MobileMorphingTitleLabel {
        MobileMorphingTitleLabel()
    }

    func updateUIView(_ view: MobileMorphingTitleLabel, context: Context) {
        view.configure(
            title: title,
            textStyle: textStyle,
            weight: weight,
            textColor: textColor,
            groundColor: groundColor,
            alignment: alignment,
            reducesMotion: reducesMotion
        )
    }
}
