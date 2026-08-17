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
    private var isBusy = false
    /// Materialized only after this recycled row first has foreground work to show.
    private var statusSpinner: ThemedSpinner?
    private var isHovered = false
    private var isPresentingMenu = false
    private var presentsHoverAction: Bool { isHovered || isPresentingMenu }

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
    func configure(
        with terminal: ProjectTerminal,
        running: Bool,
        busy: Bool,
        projectRoot: String?
    ) {
        let sameTerminal = terminalID == terminal.id
        terminalID = terminal.id
        isRunning = running
        isBusy = busy
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
        updateBusyStatus()
        // Foreground ownership is sampled while the pointer may already be over the row. Keep
        // the action/status crossfade in that state instead of flashing the spinner through it.
        setActionVisible(presentsHoverAction, animated: false)
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
        if hoverIsStale(isHovered) {
            isHovered = false
            setActionVisible(presentsHoverAction, animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through the receipt floating over the list — see `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }
        isHovered = true
        setActionVisible(presentsHoverAction, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setActionVisible(presentsHoverAction, animated: true)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        terminalID = nil
        isBusy = false
        statusSpinner?.isAnimating = false
        isHovered = false
        setActionVisible(presentsHoverAction, animated: false)
    }

    /// A terminal shell lives for the lifetime of the row, so its running flag cannot say that a
    /// command is in progress. The foreground process group can. Show the same themed progress
    /// mark session rows use, without making an invisible spinner part of every terminal row.
    private func updateBusyStatus() {
        guard isBusy || statusSpinner != nil else { return }

        let spinner: ThemedSpinner
        if let statusSpinner {
            spinner = statusSpinner
        } else {
            let materialized = ThemedSpinner()
            materialized.translatesAutoresizingMaskIntoConstraints = false
            materialized.setAccessibilityLabel(L10n.string("Terminal command running"))
            materialized.setAccessibilityIdentifier("sidebar.terminal.status")
            materialized.hostGround = backgroundStyle == .emphasized ? .selection : nil
            // Keep the status behind the overlapping action. Alpha is presentation state, not
            // hit-testing policy, so the hover button must remain the frontmost target.
            addSubview(materialized, positioned: .below, relativeTo: actionButton)
            NSLayoutConstraint.activate([
                materialized.centerXAnchor.constraint(equalTo: actionButton.centerXAnchor),
                materialized.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
                materialized.widthAnchor.constraint(
                    equalToConstant: StatusIndicatorDefaults.spinnerSize
                ),
                materialized.heightAnchor.constraint(
                    equalToConstant: StatusIndicatorDefaults.spinnerSize
                )
            ])
            statusSpinner = materialized
            spinner = materialized
        }

        spinner.isAnimating = isBusy
    }

    private func setActionVisible(_ visible: Bool, animated: Bool) {
        if visible { actionButton.materializeGlyphIfNeeded() }
        let statusAlpha: CGFloat = (isBusy && !visible) ? 1 : 0

        guard animated else {
            actionButton.alphaValue = visible ? 1 : 0
            statusSpinner?.alphaValue = statusAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            actionButton.animator().alphaValue = visible ? 1 : 0
            statusSpinner?.animator().alphaValue = statusAlpha
        }
    }

    private func applyColors() {
        titleLabel.refreshTextColor()
        iconView.contentTintColor = backgroundStyle == .emphasized
            ? Design.Text.selected
            : (isRunning ? Design.Text.label : Design.Text.secondary)
        statusSpinner?.hostGround = backgroundStyle == .emphasized ? .selection : nil

        // The `⋯` is a drawn control rather than a tinted image, so it is told which ground it is
        // on rather than handed a colour — see `BackdropThemedControl.hostGround`, and the
        // session row beside this one, which states the same thing.
        actionButton.hostGround = backgroundStyle == .emphasized ? .selection : nil
    }
}

// MARK: - Menu Presentation

extension ProjectTerminalRowView: ThemedMenuPresentationObserving {
    func themedMenuPresentationDidChange(isPresented: Bool) {
        guard isPresentingMenu != isPresented else { return }
        isPresentingMenu = isPresented
        setActionVisible(presentsHoverAction, animated: !isPresented)
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
