import AppKit

// MARK: - Session Row View

/// Sidebar row for a session: the agent icon, the session title, and a trailing slot that
/// shows status normally and the row's actions under the pointer.
final class SessionRowView: NSTableCellView {

    // MARK: - Properties

    private let statusIndicator = SessionStatusIndicator()
    private let actionButton = NSButton()

    /// Fixed-size container holding the status indicator and the action button overlaid,
    /// so swapping between them on hover never re-lays out the row.
    private let trailingSlot = NSView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Content for the hover popover, refreshed on every configure.
    private var popoverInfo: SessionInfoPopoverViewController.Info?
    private var hoverTimer: Timer?
    private var popover: NSPopover?

    /// Invoked when the row's action button is pressed, carrying the row's session.
    var onAction: ((UUID, NSView) -> Void)?
    private var sessionID: UUID?

    private let iconView = NSImageView()
    private let emojiLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    /// Retained so colours can be reapplied when the selection state changes.
    private var isDormant = false

    /// Assigning `textField` lets the table restyle it on selection, which tints an
    /// unemphasized source-list row with the accent colour. The row already shows selection
    /// as a filled shape, so the colour is reapplied here to keep the text readable instead.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColors() }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyDown
        // The slot is wider than the symbol so a 12pt emoji fits unclipped; the symbol
        // keeps its own point size rather than growing to fill.
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize,
            weight: .regular
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false

        emojiLabel.font = .systemFont(ofSize: SidebarRowDefaults.emojiFontSize)
        emojiLabel.alignment = .center
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: SidebarRowDefaults.sessionFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail

        // The lowest hugging in the stack, unambiguously: the title absorbs all slack, which
        // is what pins the status/actions slot to the row's trailing edge. Left at the
        // default, the stack has no single view to stretch and the slot trails the text.
        titleLabel.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )

        setupTrailingSlot()

        let stack = NSStackView(views: [iconView, emojiLabel, titleLabel, trailingSlot])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = SidebarRowDefaults.horizontalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        // `textField` is deliberately left unset. Assigning it lets the table restyle the
        // label on selection, which tints an unemphasized source-list row with the accent
        // colour — a second selection cue on top of the filled shape. The label is
        // exposed for accessibility directly instead.
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarRowDefaults.trailingInset
            ),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            emojiLabel.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth)
        ])
    }

    /// The slot sits at the trailing edge, where it reads as status rather than as another
    /// icon competing with the agent's own.
    private func setupTrailingSlot() {
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false

        actionButton.image = NSImage(
            systemSymbolName: SidebarRowDefaults.actionSymbol,
            accessibilityDescription: "Session actions"
        )
        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.contentTintColor = .secondaryLabelColor
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.alphaValue = 0
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.addSubview(statusIndicator)
        trailingSlot.addSubview(actionButton)

        NSLayoutConstraint.activate([
            trailingSlot.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),
            trailingSlot.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),
            statusIndicator.centerXAnchor.constraint(equalTo: trailingSlot.centerXAnchor),
            statusIndicator.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            statusIndicator.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            actionButton.centerXAnchor.constraint(equalTo: trailingSlot.centerXAnchor),
            actionButton.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),
            actionButton.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize)
        ])
    }

    // MARK: - Hover

    /// The actions appear only under the pointer, so a full list of rows stays quiet.
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setActionVisible(true, animated: true)

        // The popover waits out a dwell, so it does not flash while the pointer crosses
        // rows on its way somewhere else.
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(
            withTimeInterval: SessionPopoverDefaults.hoverDelay,
            repeats: false
        ) { [weak self] _ in
            self?.presentPopover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setActionVisible(false, animated: true)
        dismissPopover()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dismissPopover()
    }

    private func presentPopover() {
        guard let popoverInfo, window != nil, popover == nil else { return }

        let content = NSPopover()
        // Closed by hand on exit and reuse; a transient popover would instead close on the
        // next click anywhere, which is not the gesture that should dismiss it.
        content.behavior = .applicationDefined
        content.animates = false
        content.contentViewController = SessionInfoPopoverViewController(info: popoverInfo)
        content.show(relativeTo: bounds, of: self, preferredEdge: .maxX)

        popover = content
    }

    private func dismissPopover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        popover?.close()
        popover = nil
    }

    /// Crossfades the trailing slot between status and actions. Both stay installed at a
    /// fixed size, so the title never re-wraps under the pointer.
    private func setActionVisible(_ visible: Bool, animated: Bool) {
        guard animated else {
            actionButton.alphaValue = visible ? 1 : 0
            statusIndicator.alphaValue = visible ? 0 : 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = SidebarRowDefaults.hoverFadeDuration
            actionButton.animator().alphaValue = visible ? 1 : 0
            statusIndicator.animator().alphaValue = visible ? 0 : 1
        }
    }

    @objc private func actionClicked() {
        guard let sessionID else { return }
        onAction?(sessionID, actionButton)
    }

    // MARK: - Public Methods

    func configure(with session: AgentSession, activity: SessionActivity) {
        // Rows reconfigure constantly while an agent works, so an open popover survives a
        // same-session refresh; only reuse for a different session dismisses it.
        if sessionID != session.id {
            dismissPopover()
        }
        popoverInfo = SessionInfoPopoverViewController.Info(session: session, activity: activity)

        sessionID = session.id
        titleLabel.stringValue = session.displayTitle

        isDormant = activity == .dormant
        applyTextColors()

        statusIndicator.update(for: activity)

        // Rows are reconfigured while the pointer sits on them (activity changes as an
        // agent works), so the hover state is reasserted rather than reset.
        setActionVisible(isHovered, animated: false)

        // The hover popover carries the full title and account, so a tooltip would only
        // duplicate it more slowly.
        toolTip = nil

        // The icon slot identifies the account: its chosen emoji, else a letter badge from
        // its name, else the agent's own symbol for the default account.
        let account = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)

        if let emoji = account?.emoji {
            emojiLabel.stringValue = emoji
            emojiLabel.isHidden = false
            iconView.isHidden = true
        } else {
            emojiLabel.isHidden = true
            iconView.isHidden = false
            applyAgentIcon(for: session, account: account)
        }
    }

    /// The icon slot's image for a session without an account emoji: the account's
    /// discovered avatar, else a letter badge for an alternate account, else the agent's
    /// own mark. The avatar outranks even the default account's brand mark — an account
    /// that resolved to a real face is more identifying than the agent logo, and the
    /// per-account emoji still overrides both.
    ///
    /// Symbols and template marks dim for dormancy through their tint. Claude's mark and
    /// avatars keep their own colours — tinting does not touch a non-template image — so
    /// they dim through the view's alpha instead.
    private func applyAgentIcon(for session: AgentSession, account: AgentAccount?) {
        let image: NSImage?
        if let account, let avatar = AccountAvatarStore.avatar(for: account) {
            image = avatar
        } else if let badge = Self.accountBadgeSymbol(for: account) {
            image = NSImage(
                systemSymbolName: badge,
                accessibilityDescription: account?.displayName
            )
        } else {
            image = session.kind.icon
        }

        iconView.image = image
        iconView.contentTintColor = isDormant ? .tertiaryLabelColor : .secondaryLabelColor

        let dimsThroughAlpha = image.map { !$0.isTemplate } ?? false
        iconView.alphaValue = (isDormant && dimsThroughAlpha) ? AgentIconDefaults.dormantAlpha : 1
    }

    /// A letter badge (`c.circle.fill`) for an alternate account with no emoji, or nil when
    /// the agent's own mark should identify the row.
    private static func accountBadgeSymbol(for account: AgentAccount?) -> String? {
        guard let account, !account.isDefault,
              let first = account.displayName.lowercased().first else { return nil }

        let badge = "\(first)\(SidebarRowDefaults.accountBadgeSymbolSuffix)"
        guard NSImage(systemSymbolName: badge, accessibilityDescription: nil) != nil else {
            return nil
        }
        return badge
    }

    // MARK: - Private Methods

    /// Applies the row's colours for its current dormancy and selection state.
    ///
    /// `.emphasized` means the row is selected while the sidebar has focus, where macOS
    /// fills the selection with the accent colour and the text must invert to stay legible.
    /// Every other state keeps the ordinary label colours, so selection is shown by the
    /// filled shape alone.
    private func applyTextColors() {
        if backgroundStyle == .emphasized {
            titleLabel.textColor = .alternateSelectedControlTextColor
            return
        }

        titleLabel.textColor = isDormant ? .secondaryLabelColor : .labelColor
    }
}

// MARK: - Agent Kind Symbols

extension AgentKind {

    /// SF Symbol representing this agent in the sidebar.
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .shell: return "terminal"
        }
    }
}
