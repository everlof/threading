import AppKit

/// Sidebar row for a standalone terminal.
final class ProjectTerminalRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = MorphingTitleLabel()
    private let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Terminal actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )

    /// The two gutters the column's width moves — see `SidebarDensity`. Held so a narrower
    /// column is a constant assignment on the rows already on screen.
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var trailingSlotConstraint: NSLayoutConstraint?

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

    /// `projectRoot` is the folder of the project this row sits under, which the name is stated
    /// relative to: at the project's own folder the row above already says the folder's name.
    func configure(with terminal: ProjectTerminal, running: Bool, projectRoot: String?) {
        let sameTerminal = terminalID == terminal.id
        terminalID = terminal.id
        isRunning = running
        let title = ProjectTerminalTitle.displayTitle(for: terminal, projectRoot: projectRoot)
        titleLabel.setStringValue(
            title,
            animated: sameTerminal && titleLabel.stringValue != title
        )
        // A sound this terminal does not inherit is named on the line under its folder, so an
        // overridden row is identifiable without opening a menu — and only then, since an
        // override is configuration rather than status.
        toolTip = [
            terminal.currentDirectory,
            SoundOverrideAudit.toolTipLine(
                for: .terminal(terminal.id),
                overrides: terminal.soundOverrides
            )
        ].compactMap { $0 }.joined(separator: "\n")
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
        // Named the way the session and project rows name theirs, so the inspector — and a test
        // sweeping all three — reads this row by the same convention.
        actionButton.setAccessibilityIdentifier("sidebar.terminal.actions")

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(actionButton)

        let leading = iconView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: SidebarRowDefaults.leadingInset
        )
        let trailing = actionButton.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -trailingSlotInset(for: SidebarRowDefaults.trailingInset)
        )
        contentLeadingConstraint = leading
        trailingSlotConstraint = trailing

        NSLayoutConstraint.activate([
            leading,
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
            trailing,
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityRole(.staticText)
    }

    /// How far inside the row's trailing edge the `⋯` is pinned, for a given gutter. Never
    /// negative — see `SessionRowView.trailingSlotInset(for:)` for the hit-testing rule.
    private func trailingSlotInset(for gutter: CGFloat) -> CGFloat {
        max(0, gutter - actionButton.opticalHorizontalInset)
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
        // Not through the receipt floating over the list — see `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }
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
        if visible { actionButton.materializeGlyphIfNeeded() }

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

        // The `⋯` is a drawn control rather than a tinted image, so it is told which ground it is
        // on rather than handed a colour — see `BackdropThemedControl.hostGround`, and the
        // session row beside this one, which states the same thing.
        actionButton.hostGround = backgroundStyle == .emphasized ? .selection : nil
    }
}

// MARK: - Sidebar Density

extension ProjectTerminalRowView: SidebarDensityAdopting {

    /// Restates the row's two gutters at the width the column now has.
    func applySidebarDensity(_ density: SidebarDensity) {
        contentLeadingConstraint?.constant = density.rowLeadingInset
        trailingSlotConstraint?.constant = -trailingSlotInset(for: density.rowTrailingInset)
    }
}
