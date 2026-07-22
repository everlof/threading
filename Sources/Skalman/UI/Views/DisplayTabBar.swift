import AppKit

// MARK: - Tab Bar Item

/// A lightweight description of one tab, so the strip can draw itself without reaching into a
/// tab's live content (an image, a document, or a whole browser view controller).
struct DisplayTabBarItem {
    let id: UUID
    let title: String
    let symbolName: String
    let isActive: Bool
}

// MARK: - Display Tab Bar

/// The strip of tabs along the top of the display pane, in the app's flat, quiet style.
///
/// It appears only once surfaces coexist (see `DisplayPaneDefaults.tabBarMinimumTabs`), scrolls
/// horizontally when it runs out of room rather than shrinking chips to nothing, and reports a
/// selection or a close back to the pane — it owns no state of its own beyond what it is handed.
final class DisplayTabBar: NSView {

    // MARK: - Callbacks

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    // MARK: - Views

    private let stack = NSStackView()
    private let scrollView = NSScrollView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.hairline
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: Design.Spacing.small,
            bottom: 0, right: Design.Spacing.small
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            // The document is as tall as the clip and only as wide as its chips, which is what
            // makes the overflow scroll sideways rather than the chips wrapping or squashing.
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        ])

        // A hairline under the strip, separating it from the content below.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Update

    /// Rebuilds the chips from the given items. Cheap: tabs change rarely and are few.
    func update(items: [DisplayTabBarItem]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in items {
            let chip = DisplayTabChip(item: item)
            chip.onSelect = { [weak self] in self?.onSelect?(item.id) }
            chip.onClose = { [weak self] in self?.onClose?(item.id) }
            stack.addArrangedSubview(chip)
        }
    }
}

// MARK: - Display Tab Chip

/// One tab in the strip: an icon, a truncated title, and a close control that stays quiet until
/// the tab is active or hovered — the same crossfade-not-hide trick the sidebar rows use, so a
/// pointer crossing the strip does not relayout it.
final class DisplayTabChip: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let item: DisplayTabBarItem
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var hovered = false

    init(item: DisplayTabBarItem) {
        self.item = item
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = Design.Radius.control

        iconView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: DisplayPaneDefaults.tabChipFontSize, weight: .regular)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: DisplayPaneDefaults.tabChipFontSize, weight: item.isActive ? .semibold : .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let closeConfig = NSImage.SymbolConfiguration(pointSize: DisplayPaneDefaults.tabChipFontSize - 2, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(closeConfig)
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [iconView, titleLabel, closeButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.hairline
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.hairline),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.tabBarHeight - Design.Spacing.small),
            widthAnchor.constraint(lessThanOrEqualToConstant: DisplayPaneDefaults.tabChipMaxWidth),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        applyColours()
    }

    // MARK: - Appearance

    private func applyColours() {
        let emphasised = item.isActive || hovered
        titleLabel.textColor = item.isActive ? .labelColor : .secondaryLabelColor
        iconView.contentTintColor = item.isActive ? .labelColor : .secondaryLabelColor

        let fill: NSColor = item.isActive
            ? Design.Surface.controlHover
            : (hovered ? Design.Surface.controlResting : .clear)
        layer?.backgroundColor = fill.cgColor

        // The close control is reserved a slot always, so raising it on hover does not relayout
        // the strip; it simply fades in.
        closeButton.animator().alphaValue = emphasised ? 1 : 0
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; applyColours() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyColours() }

    override func mouseDown(with event: NSEvent) {
        // A click anywhere but the close control selects the tab.
        onSelect?()
    }

    @objc private func closeClicked() { onClose?() }
}
