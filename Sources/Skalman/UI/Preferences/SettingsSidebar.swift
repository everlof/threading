import AppKit

// MARK: - Settings Sidebar

/// The vertical list of pages down the left of Settings — a quiet source-list-style nav in the
/// app's own design language, so choosing a page feels like the rest of the app rather than a
/// system dialog.
final class SettingsSidebar: NSView {

    // MARK: - Item

    struct Item {
        let title: String
        let symbol: String
    }

    // MARK: - Properties

    /// Called with the index the user picked. Not fired by `select(_:)`, so the owner can set
    /// the initial page without re-entrancy.
    var onSelect: ((Int) -> Void)?

    private var rows: [SettingsSidebarRow] = []

    // MARK: - Initialization

    init(items: [Item]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(items)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Selects a page without notifying, for setting the initial state.
    func select(_ index: Int) {
        for (offset, row) in rows.enumerated() {
            row.isSelected = offset == index
        }
    }

    // MARK: - Private Methods

    private func build(_ items: [Item]) {
        rows = items.enumerated().map { index, item in
            let row = SettingsSidebarRow(title: item.title, symbol: item.symbol)
            row.onClick = { [weak self] in
                self?.select(index)
                self?.onSelect?(index)
            }
            return row
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])

        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

// MARK: - Settings Sidebar Row

/// One page row: an icon and label that fills with a rounded highlight when selected and lifts
/// on hover, following the design system's "quiet until relevant" rule.
private final class SettingsSidebarRow: NSView {

    // MARK: - Properties

    var onClick: (() -> Void)?

    var isSelected = false {
        didSet { updateStyle() }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    private var isHovered = false {
        didSet { updateStyle() }
    }

    private var trackingArea: NSTrackingArea?

    // MARK: - Initialization

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        setup(title: title, symbol: symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup(title: String, symbol: String) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Design.Radius.control

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.widthAnchor.constraint(equalToConstant: SettingsSidebarDefaults.iconSlotWidth).isActive = true

        label.font = Design.Typography.control()
        label.stringValue = title
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.medium,
            bottom: 0, right: Design.Spacing.medium
        )
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsSidebarDefaults.rowHeight),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        updateStyle()
    }

    // MARK: - Hover & Click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { onClick?() }

    /// The whole row is the click target: its label and icon are plain subviews that would
    /// otherwise swallow the mouse, leaving only the padding clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: - Style

    private func updateStyle() {
        let fill: NSColor
        let foreground: NSColor

        if isSelected {
            fill = Design.Surface.controlHover
            foreground = Design.Text.label
        } else if isHovered {
            fill = Design.Surface.controlResting
            foreground = Design.Text.label
        } else {
            fill = .clear
            foreground = Design.Text.secondary
        }

        layer?.backgroundColor = fill.cgColor
        label.textColor = foreground
        iconView.contentTintColor = foreground
    }
}

// MARK: - Settings Sidebar Defaults

private enum SettingsSidebarDefaults {
    static let rowHeight: CGFloat = 30
    static let iconSlotWidth: CGFloat = 18
}
