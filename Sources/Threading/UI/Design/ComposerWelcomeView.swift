import AppKit

/// The app-owned geometry around an opening greeting. Themes may replace its content.
enum ComposerWelcomeLayout {
    static let markSide: CGFloat = 40
    static let minimumClearance: CGFloat = 48
    static let maximumLines = 3
    static var measure: CGFloat { Design.Size.readableWidth }

    static func measure(forPaneWidth width: CGFloat) -> CGFloat {
        min(measure, max(1, width - 2 * Design.Spacing.pane))
    }
}

/// The mark, greeting and optional caption share one stack on both platforms. Hosts supply
/// their theme-aware mark and text leaves, then place this stack in the opening hero region.
@MainActor
final class ComposerWelcomeStackView: NSStackView {
    init(mark: NSView, greeting: NSView, caption: NSView? = nil,
         fixedMarkSide: CGFloat? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Design.Spacing.inset
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(mark)
        addArrangedSubview(greeting)
        if let caption {
            addArrangedSubview(caption)
            setCustomSpacing(Design.Spacing.small, after: greeting)
        }
        if let fixedMarkSide {
            NSLayoutConstraint.activate([
                mark.widthAnchor.constraint(equalToConstant: fixedMarkSide),
                mark.heightAnchor.constraint(equalToConstant: fixedMarkSide)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func exceedsHeroRegion(height: CGFloat) -> Bool {
        height < fittingSize.height + ComposerWelcomeLayout.minimumClearance
    }
}
