import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// Sidebar row for a standalone terminal.
final class ProjectTerminalRowView: NSTableCellView, ThemeDerivedContent {
    private let assembly = SidebarTerminalRowAssembly()
    private var rowVisuals: ThemedTerminalRowContentView { assembly.visuals }
    private var titleLabel: MorphingTitleLabel { rowVisuals.titleLabel }
    private var actionButton: ThemedIconButton { assembly.actionButton }

    /// The two gutters the column's width moves — see `SidebarDensity`. Held so a narrower
    /// column is a constant assignment on the rows already on screen.
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var trailingSlotConstraint: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var terminalID: TerminalID?
    private var isRunning = false
    private var isBusy = false
    private var isHovered = false
    private var isPresentingMenu = false
    private var actionEnabled = true
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

    func rederiveThemedContent() {
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// `projectRoot` is the folder of the project this row sits under, which the name is stated
    /// relative to: at the project's own folder the row above already says the folder's name.
    #if !os(Linux)
    func configure(
        with terminal: ProjectTerminal,
        running: Bool,
        busy: Bool,
        projectRoot: String?
    ) {
        let title = ProjectTerminalTitle.displayTitle(for: terminal, projectRoot: projectRoot)
        // A sound this terminal does not inherit is named on the line under its folder, so an
        // overridden row is identifiable without opening a menu — and only then, since an
        // override is configuration rather than status.
        let tooltip = [
            terminal.currentDirectory,
            SoundOverrideAudit.toolTipLine(
                for: .terminal(terminal.id),
                overrides: terminal.soundOverrides
            )
        ].compactMap { $0 }.joined(separator: "\n")
        configure(terminalID: terminal.id, title: title, icon: nil, running: running,
                  busy: busy, tooltip: tooltip)
    }
    #endif

    /// Hosts provide identity and measured runtime facts; the same row owns every visual state.
    /// The Mac adapter above derives its title and tooltip from the project model. Linux supplies
    /// those facts from its bounded sidebar snapshot and its platform symbol shim.
    func configure(terminalID id: TerminalID?, title: String, icon: NSImage?,
                   running: Bool, busy: Bool, tooltip: String?) {
        let sameTerminal = terminalID == id
        terminalID = id
        isRunning = running
        isBusy = busy
        rowVisuals.setTitle(title,
            animated: sameTerminal && titleLabel.stringValue != title)
        if let icon { rowVisuals.setIcon(icon) }
        toolTip = tooltip
        assembly.setBusy(isBusy, in: self, selected: backgroundStyle == .emphasized,
                         actionVisible: presentsHoverAction)
        // Foreground ownership is sampled while the pointer may already be over the row. Keep
        // the action/status crossfade in that state instead of flashing the spinner through it.
        setActionVisible(presentsHoverAction, animated: false)
        applyColors()
    }

    func setActionEnabled(_ enabled: Bool) {
        guard actionEnabled != enabled else { return }
        actionEnabled = enabled
        actionButton.isEnabled = enabled
        actionButton.setAccessibilityElement(enabled)
        setActionVisible(presentsHoverAction, animated: false)
    }

    /// The host owns overlay placement and input transport; the production control owns its
    /// bounds and hit target on both platforms.
    func actionAnchor(in ancestor: NSView) -> NSRect? {
        guard actionEnabled else { return nil }
        return actionButton.convert(actionButton.bounds, to: ancestor)
    }

    func containsActiveActionTarget(_ target: NSView) -> Bool {
        guard actionEnabled, presentsHoverAction else { return false }
        var view: NSView? = target
        while let candidate = view, candidate !== self {
            if candidate === actionButton { return true }
            view = candidate.superview
        }
        return false
    }

    /// A host with a native pointer transport may supply its already indexed row-hover fact.
    /// AppKit continues to drive this through the tracking area on macOS.
    func setHostHover(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        setActionVisible(presentsHoverAction, animated: false)
    }

    func applyContentInsets(leading: CGFloat, trailing: CGFloat) {
        contentLeadingConstraint?.constant = leading
        trailingSlotConstraint?.constant = -assembly.trailingSlotInset(for: trailing)
    }

    private func setupViews() {
        rowVisuals.setIcon(NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(
            Design.Symbol.configuration(SidebarRowDefaults.iconSize, weight: .regular)
        ))
        rowVisuals.iconView.contrastGround = { [weak self] in
            guard let self else { return Design.Surface.background }
            return SidebarHoverRowView.contentGround(for: self)
        }

        actionButton.onPress = { [weak self] in
            guard let self, let terminalID else { return }
            onAction?(terminalID, actionButton)
        }
        let edges = assembly.mount(in: self, leadingInset: SidebarRowDefaults.leadingInset,
                                   trailingInset: SidebarRowDefaults.trailingInset)
        contentLeadingConstraint = edges.leading
        trailingSlotConstraint = edges.trailing

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
        assembly.setBusy(false, in: self, selected: backgroundStyle == .emphasized,
                         actionVisible: false)
        isHovered = false
        setActionVisible(presentsHoverAction, animated: false)
    }

    private func setActionVisible(_ visible: Bool, animated: Bool) {
        assembly.setActionVisible(visible && actionEnabled, animated: animated)
    }

    private func applyColors() {
        rowVisuals.setInk(selected: backgroundStyle == .emphasized, running: isRunning)
        assembly.setSelected(backgroundStyle == .emphasized)
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
        applyContentInsets(leading: density.rowLeadingInset, trailing: density.rowTrailingInset)
    }
}
