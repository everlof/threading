import AppKit
import ThreadingExtensionKit

// MARK: - Session Row View

/// Sidebar row for a session: the agent icon, the session title and its optional pinned mark,
/// plus a trailing slot that shows status normally and the row's actions under the pointer.
final class SessionRowView: NSTableCellView, ThemeDerivedContent {

    // MARK: - Properties

    typealias SessionHoverContentProvider =
        @MainActor (SessionInfoPopoverViewController.Info) -> NSViewController?

    private let statusIndicator = SessionStatusIndicator()
    /// The row's `⋯`, the same nested icon button a tab's `×` is — see `ThemedIconButton`.
    /// It inks from the chrome because the sidebar sits on the chrome's ground, not the
    /// terminal's backdrop.
    private let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Session actions"),
        target: .inline,
        inkSource: .chrome
    )

    /// Archiving without opening the menu first — the one row action reached often enough to
    /// earn the row's own surface. It sits outermost, where a list is scanned to its edge.
    private let archiveButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.archiveSymbol,
        accessibility: SidebarRowDefaults.archiveAccessibilityLabel,
        target: .inline,
        inkSource: .chrome
    )

    /// The buttons the pointer reveals, crossfaded against the status indicator as one.
    ///
    /// Sized into the slot rather than overhanging it — see `sessionTrailingSlotWidth` for why
    /// the slot expands before these buttons appear.
    private let hoverControls = NSStackView()

    /// Container holding the status indicator and the hover controls overlaid. At rest it pays
    /// for the status target alone; under the pointer it expands to contain both actions.
    private let trailingSlot = NSView()
    private var trailingSlotWidthConstraint: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Content for the hover popover, refreshed on every configure.
    private var popoverInfo: SessionInfoPopoverViewController.Info?
    private var popover: ThemedPopover?

    /// Decides when the hover card opens and closes; `SessionPopoverDefaults.hoverPolicy`
    /// waits out the dwell and closes the instant the pointer leaves the row.
    private lazy var popoverScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(policy: SessionPopoverDefaults.hoverPolicy)
        scheduler.onPresent = { [weak self] in self?.presentPopover() }
        scheduler.onDismiss = { [weak self] in self?.dismissPopover() }
        return scheduler
    }()
    private let sessionHoverContentProvider: SessionHoverContentProvider

    /// Invoked when the row's action button is pressed, carrying the row's session.
    var onAction: ((SessionID, NSView) -> Void)?
    /// Invoked when the row's archive button is pressed, carrying the row's session.
    var onArchive: ((SessionID) -> Void)?
    /// Invoked for semantic actions inside extension-rendered content.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?
    private var sessionID: SessionID?

    private let iconView = NSImageView()

    /// The account's chip, overlaid on the mark's bottom-trailing corner. Deliberately not
    /// an arranged subview: the stack would give it a slot of its own, when the whole point
    /// is that it rides the mark rather than standing beside it.
    private let accountChipView = NSImageView()

    private let titleLabel = MorphingTitleLabel()
    /// Pinning is stronger than every sidebar sort, so it remains visible beside the title
    /// rather than being communicated only by the row's position.
    private let pinnedIndicator = NSImageView()
    private let nativeIdentityContent = NSView()
    private let nativeContent = NSView()
    private let afterTitleSlot = NSStackView()
    private lazy var identityContentContainer = ComponentContentContainer(
        defaultContent: nativeIdentityContent
    )
    private lazy var contentContainer = ComponentContentContainer(defaultContent: nativeContent)
    private lazy var rowContentStack = NSStackView(
        views: [contentContainer, pinnedIndicator, afterTitleSlot]
    )
    private lazy var identityCustomizationHost = ComponentCustomizationHost(
        target: .sessionIdentity(),
        contentContainer: identityContentContainer,
        lookup: customizationLookup,
        imageResolver: { [weak self] reference, extensionIdentifier in
            self?.resolveCustomizationImage(
                reference,
                extensionIdentifier: extensionIdentifier
            )
        }
    )
    private lazy var customizationHost = ComponentCustomizationHost(
        target: .init(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version
        ),
        contentContainer: contentContainer,
        slots: ["after-title": afterTitleSlot],
        lookup: customizationLookup,
        imageResolver: { [weak self] reference, extensionIdentifier in
            self?.resolveCustomizationImage(
                reference,
                extensionIdentifier: extensionIdentifier
            )
        },
        onAction: { [weak self] action in
            guard let self else { return }
            if let onCustomizationAction {
                onCustomizationAction(action)
            } else {
                ComponentCustomizationProviderSlot.shared.perform(action)
            }
        },
        onProperties: { [weak self] properties in
            self?.applyCustomizationProperties(properties)
        }
    )
    private let customizationLookup: ComponentCustomizationHost.Lookup

    private var nativeTitle = ""
    private var nativeToolTip: String?
    private var nativeIcon: NSImage?
    private var nativeIconTint: NSColor?
    private var nativeIconAlpha: CGFloat = 1

    /// Retained so colours can be reapplied when the selection state changes.
    private var isDormant = false

    /// Whether the title landing on the next content pass is a **rename** of the name this
    /// row is already showing, rather than a row being filled in.
    ///
    /// Decided in `configure`, spent in `applyCustomizationProperties` — the two are one
    /// pass apart, and the property is what carries the answer across. A morph from a name
    /// this row never showed reads as a glitch rather than as a rename, so this is false
    /// for a first fill and for a cell recycled from another session.
    private var animatesNextTitle = false

    /// Assigning `textField` lets the table restyle it on selection, which tints an
    /// unemphasized source-list row with the accent colour. The row already shows selection
    /// as a filled shape, so the colour is reapplied here to keep the text readable instead.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyTextColors()
            // Selection changes the ground under the mark, not just under the text: a coral
            // starburst on a holly-red selected row is the same hole a dark favicon is on the
            // dark sidebar, and it appears and disappears as the row is selected.
            rederiveThemedContent()
        }
    }

    /// The agent's mark before any plate, kept so the plate can be decided again when the
    /// ground moves. Re-plating a plated image would measure the plate.
    private var agentMark: NSImage?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        customizationLookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
        sessionHoverContentProvider = Self.nativeSessionHoverContent(for:)
        super.init(frame: frameRect)
        setupViews()
    }

    /// Injection point used by the Component Gallery and focused shell tests. Product rows use
    /// the process-wide provider slot through `init(frame:)`.
    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup,
        sessionHoverContentProvider: @escaping SessionHoverContentProvider =
            SessionRowView.nativeSessionHoverContent(for:)
    ) {
        self.customizationLookup = customizationLookup
        self.sessionHoverContentProvider = sessionHoverContentProvider
        super.init(frame: .zero)
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
        iconView.setAccessibilityIdentifier("sidebar.session.identity")

        accountChipView.imageScaling = .scaleProportionallyDown
        accountChipView.translatesAutoresizingMaskIntoConstraints = false
        accountChipView.setAccessibilityIdentifier("sidebar.session.account")

        titleLabel.applyFont(.controlRegular)
        titleLabel.setAccessibilityIdentifier("sidebar.session.title")

        // The ink is stated once, as a rule: the row's dormancy and selection both move
        // under it, and a theme switch replaces the colours it resolves to. See
        // `applyTextColors`.
        titleLabel.setTextColor { [weak self] in
            guard let self else { return Design.Text.label }
            if backgroundStyle == .emphasized { return Design.Text.selected }
            return isDormant ? Design.Text.secondary : Design.Text.label
        }

        // The lowest hugging in the stack, unambiguously: the title absorbs all slack, which
        // is what pins the status/actions slot to the row's trailing edge. Left at the
        // default, the stack has no single view to stretch and the slot trails the text.
        titleLabel.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )

        pinnedIndicator.image = Design.Symbol.image(
            SidebarRowDefaults.pinnedSymbol,
            slot: Design.Size.inlineButtonGlyph,
            pointSize: Design.Symbol.control
        )
        pinnedIndicator.imageScaling = .scaleProportionallyDown
        pinnedIndicator.translatesAutoresizingMaskIntoConstraints = false
        pinnedIndicator.setContentHuggingPriority(.required, for: .horizontal)
        pinnedIndicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        pinnedIndicator.setAccessibilityElement(true)
        pinnedIndicator.setAccessibilityRole(.image)
        pinnedIndicator.setAccessibilityLabel(SidebarRowDefaults.pinnedAccessibilityLabel)
        pinnedIndicator.setAccessibilityIdentifier("sidebar.session.pinned")
        pinnedIndicator.isHidden = true

        NSLayoutConstraint.activate([
            pinnedIndicator.widthAnchor.constraint(
                equalToConstant: Design.Size.inlineButtonGlyph
            ),
            pinnedIndicator.heightAnchor.constraint(
                equalToConstant: Design.Size.inlineButtonGlyph
            )
        ])

        setupTrailingSlot()
        setupCustomizableContent()

        // `textField` is deliberately left unset. Assigning it lets the table restyle the
        // label on selection, which tints an unemphasized source-list row with the accent
        // colour — a second selection cue on top of the filled shape. The label is
        // exposed for accessibility directly instead.
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            rowContentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
            rowContentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingSlot.leadingAnchor,
                constant: -SidebarRowDefaults.horizontalSpacing
            ),
            rowContentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            // The slot is pulled out by the padding its outermost control holds around its
            // glyph, the way `PaneFooterView` places a trailing button — see
            // `OpticalInsetProviding`. Pinned by frame instead, the archive glyph and the
            // status dot stop short of the margin a project row's count reaches, and the
            // list's trailing edge reads as two edges.
            trailingSlot.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(
                    SidebarRowDefaults.trailingInset - archiveButton.opticalHorizontalInset
                )
            ),
            trailingSlot.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// Builds the one visual subtree extensions may customize. The activity/actions slot is a
    /// sibling outside the container, so replacing or invalidating content cannot disturb it.
    private func setupCustomizableContent() {
        nativeIdentityContent.translatesAutoresizingMaskIntoConstraints = false
        nativeIdentityContent.addSubview(iconView)
        nativeIdentityContent.addSubview(accountChipView)
        nativeIdentityContent.setAccessibilityIdentifier(
            "sidebar.session.identity.default-content"
        )

        NSLayoutConstraint.activate([
            nativeIdentityContent.widthAnchor.constraint(
                equalToConstant: SidebarRowDefaults.iconSlotWidth
            ),
            nativeIdentityContent.heightAnchor.constraint(
                equalToConstant: SidebarRowDefaults.iconSlotWidth
            ),
            iconView.topAnchor.constraint(equalTo: nativeIdentityContent.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: nativeIdentityContent.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: nativeIdentityContent.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: nativeIdentityContent.trailingAnchor),

            // Hung off the provider mark rather than laid out beside it, so the native
            // composition remains compact. A selected identity renderer may choose a HStack
            // instead by replacing this entire inner container.
            accountChipView.widthAnchor.constraint(
                equalToConstant: AccountBadgeDefaults.chipSize
            ),
            accountChipView.heightAnchor.constraint(
                equalToConstant: AccountBadgeDefaults.chipSize
            ),
            accountChipView.trailingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: AccountBadgeDefaults.cornerOverhang
            ),
            accountChipView.bottomAnchor.constraint(
                equalTo: iconView.bottomAnchor,
                constant: AccountBadgeDefaults.cornerOverhang
            )
        ])

        identityContentContainer.setAccessibilityIdentifier(
            "sidebar.session.identity.content"
        )
        identityContentContainer.onReplacementChanged = { [weak self] replacement in
            self?.applyIdentityReplacementState(replacement)
        }

        let nativeStack = NSStackView(views: [identityContentContainer, titleLabel])
        nativeStack.orientation = .horizontal
        nativeStack.alignment = .centerY
        nativeStack.spacing = SidebarRowDefaults.horizontalSpacing
        nativeStack.translatesAutoresizingMaskIntoConstraints = false

        nativeContent.translatesAutoresizingMaskIntoConstraints = false
        nativeContent.addSubview(nativeStack)

        NSLayoutConstraint.activate([
            nativeStack.topAnchor.constraint(equalTo: nativeContent.topAnchor),
            nativeStack.bottomAnchor.constraint(equalTo: nativeContent.bottomAnchor),
            nativeStack.leadingAnchor.constraint(equalTo: nativeContent.leadingAnchor),
            nativeStack.trailingAnchor.constraint(equalTo: nativeContent.trailingAnchor)
        ])

        nativeContent.setAccessibilityIdentifier("sidebar.session.default-content")
        contentContainer.setAccessibilityIdentifier("sidebar.session.content")
        contentContainer.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        afterTitleSlot.orientation = .horizontal
        afterTitleSlot.alignment = .centerY
        afterTitleSlot.spacing = Design.Spacing.tight
        afterTitleSlot.isHidden = true
        afterTitleSlot.setAccessibilityIdentifier("sidebar.session.slot.after-title")

        // The trailing slot is **not** in the stack.
        //
        // As an arranged view it landed wherever the stack's packing left it: the stack pushes it
        // to the edge only by stretching something to its left, and hugging can only stretch a
        // view that has an intrinsic size to hug. A row whose identity content an extension has
        // replaced has no such view, so the stack packed everything at the leading edge and the ⋯
        // came to rest against the title — mid-row on some rows and at the edge on others, for a
        // reason nothing in the row could show. Pinned to the row it is always where the eye
        // looks for it, whatever the row is made of.
        rowContentStack.orientation = .horizontal
        rowContentStack.alignment = .centerY
        rowContentStack.spacing = SidebarRowDefaults.horizontalSpacing
        rowContentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContentStack)
        addSubview(trailingSlot)

        _ = identityCustomizationHost
        _ = customizationHost
    }

    /// The slot sits at the trailing edge, where it reads as status rather than as another
    /// icon competing with the agent's own.
    private func setupTrailingSlot() {
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false

        // No size stated for either button: each knows its own target and padding.
        //
        // The `⋯` opens on the press. The row is rebuilt under the pointer whenever the tree's
        // shape changes, and a press waiting for its release loses it to that rebuild — see
        // `ThemedIconButton.presentsMenu`.
        actionButton.presentsMenu = true
        actionButton.onPress = { [weak self] in self?.actionClicked() }
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        // The archive action is bound per session in `configure`, not here: it has to name the
        // session it was aimed at rather than read the row's current one when it fires.
        archiveButton.translatesAutoresizingMaskIntoConstraints = false

        // Trailing-most last: the archive button takes the row's edge, and the `⋯` sits
        // inboard of it.
        hoverControls.orientation = .horizontal
        hoverControls.alignment = .centerY
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(actionButton)
        hoverControls.addArrangedSubview(archiveButton)

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.setAccessibilityIdentifier("sidebar.session.trailing")
        statusIndicator.setAccessibilityIdentifier("sidebar.session.status")
        actionButton.setAccessibilityIdentifier("sidebar.session.actions")
        archiveButton.setAccessibilityIdentifier("sidebar.session.archive")
        hoverControls.setAccessibilityIdentifier("sidebar.session.hover-controls")
        trailingSlot.addSubview(statusIndicator)
        trailingSlot.addSubview(hoverControls)

        let width = trailingSlot.widthAnchor.constraint(
            equalToConstant: SidebarRowDefaults.trailingSlotSize
        )
        trailingSlotWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            trailingSlot.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),

            // On the archive button's centre rather than the slot's: the archive button holds
            // the row's trailing edge, which is exactly where the dot sat when it was the only
            // thing in the slot. Centred in the widened slot it would drift inboard, moving
            // the status of every row in the list to buy a button nobody is hovering.
            statusIndicator.centerXAnchor.constraint(equalTo: archiveButton.centerXAnchor),
            statusIndicator.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            statusIndicator.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            statusIndicator.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            hoverControls.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            hoverControls.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
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

        // A row scrolls, or the list reloads under a pointer that never moved, and no exit is
        // delivered for either — see `NSView.hoverIsStale`. Left alone, the row keeps its
        // actions showing and its popover open for a session the pointer is no longer on.
        if hoverIsStale(isHovered) {
            hoverDidEnd(animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through the receipt floating over the list: the row would show its actions and open
        // its popover for a session the pointer is nowhere near, on top of the band somebody is
        // reaching across. See `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }

        isHovered = true
        setActionVisible(true, animated: true)
        popoverScheduler.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        hoverDidEnd(animated: true)
    }

    /// What leaving the row means, whether the pointer left it or it left the pointer. The
    /// correction does not animate: the row it would animate is no longer under the pointer.
    private func hoverDidEnd(animated: Bool) {
        isHovered = false
        setActionVisible(false, animated: animated)
        popoverScheduler.pointerExited()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dismissPopover()
    }

    /// A sidebar reload can discard this row without reuse and without a pointer exit; a
    /// popover anchored to a row that left the window would keep floating over nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverDidEnd(animated: false) }
    }

    private func presentPopover() {
        // Asked of the popover rather than of the reference held to it, for the reason
        // `ProjectRowView.presentPopover` states: a dropdown opening in this window closes the
        // card, and a stale reference would read as one still showing.
        guard let popoverInfo, let sessionID, window != nil, popover?.isShown != true else { return }
        guard let controller = makeSessionHoverCard(
            info: popoverInfo,
            sessionID: sessionID
        ) else {
            return
        }

        let content = HostPopoverFactory.make(.sidebarSessionHoverCard)
        // Closed by hand on exit and reuse; a transient popover would instead close on the
        // next click anywhere, which is not the gesture that should dismiss it.
        content.behavior = .applicationDefined
        content.animates = false
        content.contentViewController = controller
        content.show(relativeTo: bounds, of: self, preferredEdge: .maxX)

        popover = content
    }

    /// Builds the customizable presentation independently from its hover trigger. The row keeps
    /// ownership of timing, placement and dismissal; extensions compose only the card content.
    func makeSessionHoverCard(
        info: SessionInfoPopoverViewController.Info,
        sessionID: SessionID
    ) -> NSViewController? {
        let target = ExtensionComponentTarget.sessionHoverCard(
            sessionID: sessionID.uuidString.lowercased()
        )
        let native = sessionHoverContentProvider(info)
        let initialResolution = customizationLookup(target)
        guard native != nil || !initialResolution.isEmpty else { return nil }

        let hasNativeContent = native != nil
        let child = native ?? EmptyComponentContentViewController()
        let controller = ExtensionComponentHookViewController(
            target: target,
            child: child,
            contentInsets: NSEdgeInsets(
                top: Design.Spacing.inset,
                left: Design.Spacing.inset,
                bottom: Design.Spacing.inset,
                right: Design.Spacing.inset
            ),
            fixedWidth: SessionPopoverDefaults.width,
            lookup: customizationLookup,
            onAction: { [weak self] action in
                guard let self else { return }
                if let onCustomizationAction {
                    onCustomizationAction(action)
                } else {
                    ComponentCustomizationProviderSlot.shared.perform(action)
                }
            },
            onResolution: { [weak self] resolution in
                if !hasNativeContent, resolution.isEmpty {
                    self?.dismissPopover()
                }
            }
        )
        controller.view.setAccessibilityIdentifier("sidebar.session-hover-card")
        return controller
    }

    private static func nativeSessionHoverContent(
        for info: SessionInfoPopoverViewController.Info
    ) -> NSViewController? {
        SessionInfoPopoverViewController(info: info, isEmbedded: true)
    }

    private func dismissPopover() {
        popoverScheduler.cancelPendingWork()
        popover?.close()
        popover = nil
    }

    /// Crossfades the trailing slot between status and actions. The resting row reserves one
    /// inline target; the title yields the second target only while both actions are visible.
    private func setActionVisible(_ visible: Bool, animated: Bool) {
        if visible {
            setTrailingSlotExpanded(true)
        }

        guard animated else {
            hoverControls.alphaValue = visible ? 1 : 0
            statusIndicator.alphaValue = visible ? 0 : 1
            setTrailingSlotExpanded(visible)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.quick
            hoverControls.animator().alphaValue = visible ? 1 : 0
            statusIndicator.animator().alphaValue = visible ? 0 : 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, !self.isHovered else { return }
                self.setTrailingSlotExpanded(false)
            }
        })
    }

    /// Keeps invisible controls from taxing every title. Expansion happens before the actions
    /// fade in so both targets remain inside the hit-tested parent; collapse waits until the fade
    /// out completes so a visible button never overhangs it.
    private func setTrailingSlotExpanded(_ expanded: Bool) {
        let target = expanded
            ? SidebarRowDefaults.sessionTrailingSlotWidth
            : SidebarRowDefaults.trailingSlotSize
        guard trailingSlotWidthConstraint?.constant != target else { return }
        trailingSlotWidthConstraint?.constant = target
        layoutSubtreeIfNeeded()
    }

    private func actionClicked() {
        guard let sessionID else { return }
        onAction?(sessionID, actionButton)
    }

    // MARK: - Public Methods

    func configure(
        with session: AgentSession,
        activity: SessionActivity,
        isLoading: Bool = false
    ) {
        // Rows reconfigure constantly while an agent works, so an open popover survives a
        // same-session refresh; only reuse for a different session dismisses it.
        if sessionID != session.id {
            dismissPopover()
        }
        popoverInfo = SessionInfoPopoverViewController.Info(session: session, activity: activity)

        // Read before the id is overwritten: a morph is only honest when the name being
        // replaced is the one this row is showing, which means the *same* session with a
        // *different* title. Everything else — a first fill, a row reconfigured while an
        // agent works, a cell recycled from another session — lands the title directly.
        animatesNextTitle = sessionID == session.id
            && titleLabel.stringValue != session.displayTitle

        sessionID = session.id
        nativeTitle = session.displayTitle
        nativeToolTip = nil
        pinnedIndicator.isHidden = !session.isPinned

        // Bound to *this* session rather than reading the row's id when it fires. A press
        // outlives the row it started on — `ThemedIconButton` completes the gesture even after
        // the sidebar has recycled this view into another session's row — and a late release
        // reading `sessionID` would archive whichever session the row had become.
        archiveButton.onPress = { [weak self] in self?.onArchive?(session.id) }

        isDormant = activity == .dormant

        statusIndicator.update(for: activity, isLoading: isLoading)

        // Rows are reconfigured while the pointer sits on them (activity changes as an
        // agent works), so the hover state is reasserted rather than reset.
        setActionVisible(isHovered, animated: false)

        // The hover popover carries the full title and account, so a tooltip would only
        // duplicate it more slowly.
        let account = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)
        applyAgentIcon(for: session, account: account)
        applyTextColors()

        identityCustomizationHost.updateTarget(
            .sessionIdentity(sessionID: session.id.uuidString.lowercased())
        )
        customizationHost.updateTarget(
            .init(
                component: HostComponentContracts.sidebarSessionRow.id,
                contractVersion: HostComponentContracts.sidebarSessionRow.version,
                entityID: session.id.uuidString.lowercased()
            )
        )
    }

    /// The icon slot carries the *agent* — Claude's starburst, OpenAI's knot, a shell's
    /// terminal symbol — and an alternate account rides its corner as an `AccountBadge`
    /// chip. Both facts a row must carry are shown at once, at the weights they deserve:
    /// an earlier design gave the account the whole slot, which hid the agent entirely on
    /// every row that was not on the default login.
    ///
    /// A **side chat** breaks that rule and takes a fork glyph instead of the agent's mark.
    /// It can afford to: a fork necessarily runs its parent's agent and account, and its
    /// parent is the row it is nested under — so the agent is the one thing about that row
    /// which cannot differ, and the lineage is what the slot is better spent saying.
    ///
    /// Symbols and template marks dim for dormancy through their tint. Claude's mark and
    /// the chip keep their own colours — tinting does not touch a non-template image — so
    /// they dim through their view's alpha instead.
    private func applyAgentIcon(for session: AgentSession, account: AgentAccount?) {
        let builtInProviderImage = session.kind.icon
        let image: NSImage?
        if session.isSideChat {
            image = NSImage(
                systemSymbolName: SidebarRowDefaults.sideChatSymbol,
                accessibilityDescription: SidebarRowDefaults.sideChatAccessibilityLabel
            )
        } else if let resolution = ExtensionIdentityResolverProviderSlot.shared.providerIcon(
            providerID: session.kind.rawValue
        ) {
            image = resolveIdentityImage(
                resolution.image,
                extensionIdentifier: resolution.extensionIdentifier
            ) ?? builtInProviderImage
        } else {
            image = builtInProviderImage
        }
        agentMark = image.map(slotSized)
        iconView.image = plated(agentMark)
        iconView.setAccessibilityLabel(
            session.isSideChat
                ? SidebarRowDefaults.sideChatAccessibilityLabel
                : session.kind.displayName
        )
        iconView.contentTintColor = isDormant ? Design.Text.tertiary : Design.Text.secondary

        let dimsThroughAlpha = image.map { !$0.isTemplate } ?? false
        iconView.alphaValue = (isDormant && dimsThroughAlpha) ? AgentIconDefaults.dormantAlpha : 1

        let builtInChip = AccountBadge.chip(for: account)
        let chip: NSImage?
        if let account, account.emoji == nil,
           let resolution = ExtensionIdentityResolverProviderSlot.shared.accountIcon(
               accountID: account.id.rawValue
           ) {
            chip = resolveIdentityImage(
                resolution.image,
                extensionIdentifier: resolution.extensionIdentifier
            ) ?? builtInChip
        } else {
            // An explicit user emoji remains above an extension resolver in precedence.
            chip = builtInChip
        }
        accountChipView.image = chip
        accountChipView.setAccessibilityLabel(account?.displayName)
        accountChipView.isHidden = chip == nil
        accountChipView.alphaValue = isDormant ? AgentIconDefaults.dormantAlpha : 1

        nativeIcon = iconView.image
        nativeIconTint = iconView.contentTintColor
        nativeIconAlpha = iconView.alphaValue
    }

    /// The ground is a themed colour, so it moves with the appearance as well as with the
    /// selection — and the plate is baked into an image rather than resolved at draw time,
    /// which is exactly the frozen-value trap `ThemedControl` exists to avoid.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rederiveThemedContent()
    }

    /// Re-decides the mark's plate against the ground the row currently has.
    ///
    /// Cheap enough to run on every selection change: the tone of a mark this size is measured
    /// from a 32×32 sample, and a mark that needs no plate returns the image it was given.
    ///
    /// The three ways the ground can move are the three callers: the row is filled in, the
    /// selection arrives or leaves, and the theme changes under it. The third was missing, and an
    /// appearance flip only stood in for it when the two themes disagreed about light and dark —
    /// see `ThemeDerivedContent`.
    func rederiveThemedContent() {
        // Unlike the buttons, NSImageView keeps the tint object it was handed. Re-ask the
        // current theme whenever the sweep reaches this retained/reused row.
        applyTextColors()
        guard let agentMark else { return }
        iconView.image = plated(agentMark)
        nativeIcon = iconView.image
    }

    /// The mark at the ink size this slot draws, `iconSize`, whether or not it is plated.
    ///
    /// The brand marks ship at a nominal 15pt and rely on their slot to contain them — but
    /// this slot is deliberately wider than its ink (`iconSlotWidth`, the emoji margin), so
    /// left alone a non-template mark drew 15pt beside the 13pt symbols, and *shrank* the
    /// moment a plate composed it smaller. Sized here once, gaining a plate moves nothing.
    ///
    /// Symbols pass through unharmed: the view's `symbolConfiguration` states their point
    /// size and wins over the image's own — a resized symbol copy renders identically.
    private func slotSized(_ image: NSImage) -> NSImage {
        let side = max(image.size.width, image.size.height)
        guard side > SidebarRowDefaults.iconSize,
              let sized = image.copy() as? NSImage else { return image }

        let scale = SidebarRowDefaults.iconSize / side
        sized.size = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return sized
    }

    /// The plate spans the full slot, so it appears *around* the mark rather than replacing
    /// it: the ink stays `iconSize` either way — see `IconBackplate.compose`.
    private func plated(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        return IconBackplate.plated(
            image,
            against: IconBackplate.Ground(rowGround()),
            size: SidebarRowDefaults.iconSlotWidth
        )
    }

    /// What the mark is actually drawn on: the sidebar's surface, with the selection fill
    /// composited onto it where there is one.
    ///
    /// Only the *emphasized* fill is asked about, because that is the only one the row can
    /// tell apart — AppKit reports `.normal` both for an unselected row and for a selected one
    /// in an unfocused sidebar, and that second fill is the accent held far down, which moves
    /// the ground too little to lose a mark in it.
    private func rowGround() -> NSColor {
        let base = Design.Surface.background
        guard backgroundStyle == .emphasized else { return base }
        return base.composited(under: Design.Surface.accent)
    }

    private func resolveIdentityImage(
        _ reference: ExtensionImageReference,
        extensionIdentifier: String
    ) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: name)

        case .extensionResource(let relativePath):
            guard let url = ExtensionManager.shared.imageResourceURL(
                relativePath: relativePath,
                extensionIdentifier: extensionIdentifier
            ) else {
                return nil
            }
            return ExtensionImageResourceLoader.image(at: url)

        case .hostAsset(let assetID):
            if let providerID = ExtensionIdentityAssetID.providerID(from: assetID),
               let provider = AgentKind(rawValue: providerID) {
                return provider.icon
            }
            if let accountID = ExtensionIdentityAssetID.accountID(from: assetID),
               let parsed = AccountID(rawValue: accountID),
               let account = AgentAccountDiscovery.account(
                   for: parsed.provider,
                   handle: parsed.handle
               ) {
                return AccountBadge.chip(for: account)
            }
            return nil
        }
    }

    private func applyCustomizationProperties(
        _ properties: [
            ExtensionComponentPropertyID: ExtensionComponentPropertyValue
        ]
    ) {
        toolTip = nativeToolTip
        iconView.image = nativeIcon
        iconView.contentTintColor = nativeIconTint
        iconView.alphaValue = nativeIconAlpha

        // The title is resolved before it is set, not set twice: an extension's override
        // landing on top of the native name would morph the row through a name nobody
        // chose to show.
        var title = nativeTitle
        if case .text(let customized) = properties[.title] {
            title = customized
        }
        titleLabel.setStringValue(title, animated: animatesNextTitle)
        animatesNextTitle = false

        if case .text(let value) = properties[.toolTip] {
            toolTip = value
        }
        if case .image(let reference) = properties[.identityImage],
           let image = resolveCustomizationImage(reference) {
            iconView.image = image
        }
    }

    private func resolveCustomizationImage(
        _ reference: ExtensionImageReference,
        extensionIdentifier: String? = nil
    ) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .hostAsset(let identifier):
            switch identifier {
            case "session.provider-image":
                return nativeIcon
            case "session.account-image":
                return accountChipView.image
            default:
                return nil
            }
        case .extensionResource:
            guard let extensionIdentifier else { return nil }
            return resolveIdentityImage(
                reference,
                extensionIdentifier: extensionIdentifier
            )
        }
    }

    private func applyIdentityReplacementState(_ replacement: NSView?) {
        replacement?.alphaValue = isDormant ? AgentIconDefaults.dormantAlpha : 1
    }

    // MARK: - Private Methods

    /// Applies the row's colours for its current dormancy and selection state.
    ///
    /// `.emphasized` means the row is selected in the window in front — `SidebarHoverRowView`
    /// answers that with the window's key state rather than with the sidebar's focus — where the
    /// selection is filled with the accent colour and the text must invert to stay legible.
    /// Every other state keeps the ordinary label colours, so selection is shown by the
    /// filled shape alone.
    private func applyTextColors() {
        titleLabel.refreshTextColor()

        // The row's own buttons sit on whatever the row is filled with, and selection changes
        // that out from under them — see `BackdropThemedControl.hostGround`. Only the emphasized
        // fill is named: the unemphasized one is the accent held far back over the sidebar's
        // surface, where the chrome's ink is still the ink that reads.
        let ground: InkSource? = backgroundStyle == .emphasized ? .selection : nil
        pinnedIndicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.label
            : Design.Surface.accent
        statusIndicator.hostGround = ground
        actionButton.hostGround = ground
        archiveButton.hostGround = ground
    }
}

// MARK: - Agent Kind Symbols

extension AgentKind {

    /// SF Symbol representing this agent in the sidebar.
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .grok: return "bolt.circle"
        case .openCode: return "curlybraces.square"
        }
    }
}
