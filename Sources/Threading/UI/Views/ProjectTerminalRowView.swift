import AppKit

/// Sidebar row for a standalone terminal.
final class ProjectTerminalRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = MorphingTitleLabel()
    private let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Terminal actions"),
        target: .inline,
        inkSource: .chrome
    )

    private var trackingArea: NSTrackingArea?
    private var terminalID: TerminalID?
    private var isRunning = false

    var onAction: ((TerminalID, NSView) -> Void)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with terminal: ProjectTerminal, running: Bool) {
        let sameTerminal = terminalID == terminal.id
        terminalID = terminal.id
        isRunning = running
        titleLabel.setStringValue(
            terminal.displayTitle,
            animated: sameTerminal && titleLabel.stringValue != terminal.displayTitle
        )
        toolTip = terminal.currentDirectory
        applyColors()
    }

    private func setupViews() {
        iconView.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: L10n.string("Terminal")
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize,
            weight: .regular
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityIdentifier("sidebar.terminal.identity")

        titleLabel.applyFont(.controlRegular)
        titleLabel.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        titleLabel.setTextColor { [weak self] in
            guard let self else { return Design.Text.label }
            if backgroundStyle == .emphasized { return Design.Text.selected }
            return isRunning ? Design.Text.label : Design.Text.secondary
        }
        titleLabel.setAccessibilityIdentifier("sidebar.terminal.title")

        actionButton.presentsMenu = true
        actionButton.alphaValue = 0
        actionButton.onPress = { [weak self] in
            guard let self, let terminalID else { return }
            onAction?(terminalID, actionButton)
        }
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: SidebarRowDefaults.horizontalSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: actionButton.leadingAnchor,
                constant: -SidebarRowDefaults.horizontalSpacing
            ),
            actionButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(
                    SidebarRowDefaults.trailingInset - actionButton.opticalHorizontalInset
                )
            ),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityRole(.staticText)
    }

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
        if hoverIsStale(actionButton.alphaValue > 0) {
            setActionVisible(false, animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        setActionVisible(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setActionVisible(false, animated: true)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        terminalID = nil
        setActionVisible(false, animated: false)
    }

    private func setActionVisible(_ visible: Bool, animated: Bool) {
        guard animated else {
            actionButton.alphaValue = visible ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            actionButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func applyColors() {
        titleLabel.refreshTextColor()
        iconView.contentTintColor = backgroundStyle == .emphasized
            ? Design.Text.selected
            : (isRunning ? Design.Text.label : Design.Text.secondary)
    }
}
