import AppKit

// MARK: - Terminal Status Banner

/// A small plate floating over a terminal that states something the terminal itself cannot: the
/// iPhone owns its size, or the machine its agent runs on is out of reach for the moment.
///
/// One component for every such statement, so they read alike wherever they appear: an icon, a
/// one-line title, a quieter detail line. It floats over the terminal's own palette, so every ink
/// is derived from the active backdrop rather than the chrome (`BackdropOverlay`). Hidden until
/// shown; the whole plate is one accessibility element whose label is the title and detail.
@MainActor
final class TerminalStatusBanner: BackdropOverlay {

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(symbol: String, identifier: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(identifier)

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        titleLabel.applyFont(.control)
        detailLabel.applyFont(.detail())
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityElement(false)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [icon, labels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.medium
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(lessThanOrEqualToConstant: TerminalStatusBannerDefaults.maximumWidth),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
            icon.widthAnchor.constraint(equalToConstant: TerminalStatusBannerDefaults.iconWidth)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var title: String { titleLabel.stringValue }
    var detail: String { detailLabel.stringValue }

    override func applyInk(_ ink: Design.Ink) {
        layer?.cornerRadius = Design.Radius.control
        applyLayerBackground(ink.surface)
        layer?.borderWidth = Design.Radius.border
        applyLayerBorder(ink.border)
        icon.contentTintColor = ink.label
        titleLabel.textColor = ink.label
        detailLabel.textColor = ink.secondary
    }

    func show(title: String, detail: String, toolTip: String? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        self.toolTip = toolTip
        setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}

enum TerminalStatusBannerDefaults {
    static let maximumWidth: CGFloat = 380
    static let iconWidth: CGFloat = 16
}
