import AppKit
import ThreadingExtensionKit

// MARK: - Session Row View

/// Sidebar row for a session: the agent icon, the session title and its optional pinned mark,
/// plus a trailing slot that shows status normally and the row's actions under the pointer.
final class SessionRowView: NSTableCellView, ThemeDerivedContent {

    // MARK: - Properties

    typealias SessionHoverContentProvider =
        @MainActor (SessionInfoPopoverViewController.Info) -> NSViewController?
    typealias SessionHoverInfoProvider =
        @MainActor (AgentSession, SessionActivity) -> SessionInfoPopoverViewController.Info
    typealias SessionAccountProvider =
        @MainActor (AgentKind, AccountHandle) -> AgentAccount?

    /// The trailing geometry exists for every row, but idle and dormant sessions draw no status.
    /// Keep that stable slot cheap and materialize the indicator's attention/limit subviews and
    /// constraints only after a state has pixels to contribute.
    private let statusSlot = NSView()
    private var statusIndicator: SessionStatusIndicator?
    /// The row's `⋯`, the same nested icon button a tab's `×` is — see `ThemedIconButton`.
    /// It inks from the chrome because the sidebar sits on the chrome's ground, not the
    /// terminal's backdrop.
    private let actionButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Session actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )

    /// Archiving without opening the menu first — the one row action reached often enough to
    /// earn the row's own surface. It sits outermost of the pair, on the row's very edge — the
    /// column the status mark occupies at rest and yields while the pointer is on the row.
    private let archiveButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.archiveSymbol,
        accessibility: SidebarRowDefaults.archiveAccessibilityLabel,
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )

    /// The buttons the pointer reveals, fading in as one while the status mark fades out —
    /// a crossfade inside the status's own column, not an arrival beside it.
    ///
    /// Sized into the slot rather than overhanging it — see `sessionTrailingSlotWidth` for why
    /// the slot expands before these buttons appear.
    private let hoverControls = NSStackView()

    /// Container holding the status indicator and the hover controls overlaid. At rest it pays
    /// for the status target alone; under the pointer it expands to contain both actions.
    private let trailingSlot = NSView()
    private var trailingSlotWidthConstraint: NSLayoutConstraint?
    private var presentsStatus = false

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPresentingMenu = false
    private var presentsHoverControls: Bool { isHovered || isPresentingMenu }

    /// Source for the hover popover, refreshed on every configure.
    ///
    /// The derived `Info` is deliberately not retained here. It reads account directories and
    /// git context, and most rows are never hovered; paying that file-system work while AppKit
    /// mounts every visible sidebar row made it part of cold launch instead.
    private var popoverSession: AgentSession?
    private var popoverActivity: SessionActivity?
    private var popover: ThemedPopover?

    /// Decides when the hover card opens and closes; `SessionPopoverDefaults.hoverPolicy`
    /// waits out the dwell and closes the instant the pointer leaves the row.
    private lazy var popoverScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(policy: SessionPopoverDefaults.hoverPolicy)
        scheduler.onPresent = { [weak self] in self?.presentPopover() }
        scheduler.onDismiss = { [weak self] in self?.dismissPopover() }
        return scheduler
    }()
    private let sessionHoverInfoProvider: SessionHoverInfoProvider
    private let sessionHoverContentProvider: SessionHoverContentProvider
    private let sessionAccountProvider: SessionAccountProvider

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
    /// Exists only after a row actually has an alternate-account chip to show. A standard
    /// session has no badge at all; constructing an image view and four constraints for every
    /// ordinary row made absent content part of viewport mounting and scrolling.
    private var accountChipView: NSImageView?

    private let titleLabel = MorphingTitleLabel()
    /// Durable visibility state in words: the row remains findable while snoozed, and an early
    /// wake remains obvious until the session is visited.
    private var attentionOverlayLabel: NSTextField?
    /// Pinning is stronger than every sidebar sort, so it remains visible beside the title
    /// rather than being communicated only by the row's position.
    /// Inserted into the arranged content only for a pinned session. Most rows are unpinned, so
    /// resolving this SF Symbol (and carrying an empty arranged slot) belongs behind that state.
    private var pinnedIndicator: NSImageView?
    private var managerIndicator: NSImageView?
    /// Says that this chat behaves differently from the ones around it — it continues at its
    /// reset, or it says nothing when it finishes. Materialized on the same terms as the pin,
    /// and for the same reason: nearly every row carries no override, and absent content must
    /// not become part of mounting and scrolling. See `RowConductSummary`.
    private var conductIndicator: NSImageView?
    private let nativeIdentityContent = NSView()
    private lazy var afterTitleSlot = NSStackView()
    private lazy var identityContentContainer = ComponentContentContainer(
        defaultContent: nativeIdentityContent
    )
    private lazy var nativeStack = NSStackView(views: [nativeIdentityContent, titleLabel])
    private lazy var contentContainer = ComponentContentContainer(defaultContent: nativeStack)
    private lazy var rowContentStack = NSStackView(views: [nativeStack])

    /// The two gutters the column's width moves — see `SidebarDensity`. Held so a narrower
    /// column is a constant assignment on the rows already on screen.
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var trailingSlotConstraint: NSLayoutConstraint?

    private var identityContentContainerIsMaterialized = false
    private var contentContainerIsMaterialized = false
    private var afterTitleSlotIsMaterialized = false
    private var identityCustomizationHostIsMaterialized = false
    private lazy var identityCustomizationHost: ComponentCustomizationHost = {
        identityCustomizationHostIsMaterialized = true
        return ComponentCustomizationHost(
            target: .sessionIdentity(),
            contentContainer: materializeIdentityContentContainer(),
            lookup: customizationLookup,
            imageResolver: { [weak self] reference, extensionIdentifier in
                self?.resolveCustomizationImage(
                    reference,
                    extensionIdentifier: extensionIdentifier
                )
            },
            observesChanges: !defersCustomizationUntilNeeded
        )
    }()
    private var customizationHostIsMaterialized = false
    private lazy var customizationHost: ComponentCustomizationHost = {
        customizationHostIsMaterialized = true
        return ComponentCustomizationHost(
            target: .init(
                component: HostComponentContracts.sidebarSessionRow.id,
                contractVersion: HostComponentContracts.sidebarSessionRow.version
            ),
            contentContainer: materializeContentContainer(),
            slots: ["after-title": materializeAfterTitleSlot()],
            lookup: customizationLookup,
            imageResolver: { [weak self] reference, extensionIdentifier in
                self?.resolveCustomizationImage(
                    reference,
                    extensionIdentifier: extensionIdentifier
                )
            },
            observesChanges: !defersCustomizationUntilNeeded,
            onAction: { [weak self] action in
                guard let self else { return }
                if let onCustomizationAction {
                    onCustomizationAction(action)
                } else {
                    NativeSidebarParity.host(
                        .customizationPresentation,
                        ComponentCustomizationProviderSlot.shared.perform(action)
                    )
                }
            },
            onProperties: { [weak self] properties in
                self?.applyCustomizationProperties(properties)
            }
        )
    }()
    private let customizationLookup: ComponentCustomizationHost.Lookup
    /// Product rows are watched as one visible collection by the sidebar controller. Building
    /// two independently observing hosts for every row before an extension has published any
    /// content turned the empty customization path into launch work. Gallery and shell-test
    /// rows remain self-observing because they do not have that controller.
    private let defersCustomizationUntilNeeded: Bool

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
    /// Built-in brand artwork is immutable and shared. Measuring its pixels once per row — and
    /// again when AppKit assigns the row's background style — made contrast detection scale with
    /// the first viewport. Extension images remain uncached because their bytes may change.
    private var agentMarkTone: CGFloat?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        defersCustomizationUntilNeeded = true
        customizationLookup = {
            NativeSidebarParity.host(
                .customizationPresentation,
                ComponentCustomizationProviderSlot.shared.customization(for: $0)
            )
        }
        sessionHoverInfoProvider = SessionInfoPopoverViewController.Info.init
        sessionHoverContentProvider = Self.nativeSessionHoverContent(for:)
        sessionAccountProvider = NativeSidebarParity.host(
            .identityPresentation,
            AgentAccountDiscovery.account(for:handle:)
        )
        super.init(frame: frameRect)
        setupViews()
    }

    /// Injection point used by the Component Gallery and focused shell tests. Product rows use
    /// the process-wide provider slot through `init(frame:)`.
    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup,
        defersCustomizationUntilNeeded: Bool = false,
        sessionHoverContentProvider: @escaping SessionHoverContentProvider =
            SessionRowView.nativeSessionHoverContent(for:),
        sessionHoverInfoProvider: @escaping SessionHoverInfoProvider =
            SessionInfoPopoverViewController.Info.init,
        sessionAccountProvider: @escaping SessionAccountProvider =
            NativeSidebarParity.host(
                .identityPresentation,
                AgentAccountDiscovery.account(for:handle:)
            )
    ) {
        self.defersCustomizationUntilNeeded = defersCustomizationUntilNeeded
        self.customizationLookup = customizationLookup
        self.sessionHoverContentProvider = sessionHoverContentProvider
        self.sessionHoverInfoProvider = sessionHoverInfoProvider
        self.sessionAccountProvider = sessionAccountProvider
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

        setupTrailingSlot()
        setupCustomizableContent()

        // `textField` is deliberately left unset. Assigning it lets the table restyle the
        // label on selection, which tints an unemphasized source-list row with the accent
        // colour — a second selection cue on top of the filled shape. The label is
        // exposed for accessibility directly instead.
        setAccessibilityRole(.staticText)

        // The slot is pulled out by the padding an inline button holds around its glyph, the way
        // `PaneFooterView` places a trailing button — see `OpticalInsetProviding`. Pinned by
        // frame instead, the status dot stops short of the margin a project row's count reaches,
        // and the list's trailing edge reads as two edges.
        let leading = rowContentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: SidebarRowDefaults.leadingInset
        )
        let trailing = trailingSlot.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -trailingSlotInset(for: SidebarRowDefaults.trailingInset)
        )
        contentLeadingConstraint = leading
        trailingSlotConstraint = trailing

        NSLayoutConstraint.activate([
            leading,
            rowContentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingSlot.leadingAnchor,
                constant: -SidebarRowDefaults.horizontalSpacing
            ),
            rowContentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing,
            trailingSlot.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// How far inside the row's trailing edge the slot is pinned, for a given gutter.
    ///
    /// Never negative. The gutter is measured to the button's *ink*, so the slot is pulled out by
    /// the padding around the glyph — and a gutter narrower than that padding would push the slot
    /// past the row it lives in, where it draws perfectly and cannot be clicked at all:
    /// `NSView.hitTest` stops at the container's bounds. A tight column lends the title the space
    /// it has, not space the row does not own.
    private func trailingSlotInset(for gutter: CGFloat) -> CGFloat {
        max(0, gutter - archiveButton.opticalHorizontalInset)
    }

    /// Builds the one visual subtree extensions may customize. The activity/actions slot is a
    /// sibling outside the container, so replacing or invalidating content cannot disturb it.
    private func setupCustomizableContent() {
        nativeIdentityContent.translatesAutoresizingMaskIntoConstraints = false
        nativeIdentityContent.addSubview(iconView)
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
            iconView.trailingAnchor.constraint(equalTo: nativeIdentityContent.trailingAnchor)
        ])

        nativeStack.orientation = .horizontal
        nativeStack.alignment = .centerY
        nativeStack.spacing = SidebarRowDefaults.horizontalSpacing
        nativeStack.translatesAutoresizingMaskIntoConstraints = false
        nativeStack.setAccessibilityIdentifier("sidebar.session.default-content")
        nativeStack.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        nativeStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        if !defersCustomizationUntilNeeded {
            _ = identityCustomizationHost
            _ = customizationHost
        }
    }

    /// The native row is the launch path. Extension containers are compatibility scaffolding,
    /// not visible content, so an empty registry must not add their views and constraints to
    /// every mounted row. A published identity patch crosses this boundary and reparents the
    /// already configured native identity into the same container the eager path used.
    private func materializeIdentityContentContainer() -> ComponentContentContainer {
        if identityContentContainerIsMaterialized { return identityContentContainer }

        let index = nativeStack.arrangedSubviews.firstIndex(of: nativeIdentityContent) ?? 0
        nativeStack.removeArrangedSubview(nativeIdentityContent)
        nativeIdentityContent.removeFromSuperview()
        let container = identityContentContainer
        container.setAccessibilityIdentifier("sidebar.session.identity.content")
        container.onReplacementChanged = { [weak self] replacement in
            self?.applyIdentityReplacementState(replacement)
        }
        nativeStack.insertArrangedSubview(container, at: index)
        identityContentContainerIsMaterialized = true
        return container
    }

    /// Materializes the replaceable row surface only when a row-level extension actually has
    /// content. The native icon/title stack itself is retained and reparented; a one-child
    /// wrapper and its four edge constraints would add no semantics here. Disabling the
    /// extension therefore restores the exact same views without rebuilding title/icon state.
    private func materializeContentContainer() -> ComponentContentContainer {
        if contentContainerIsMaterialized { return contentContainer }

        let index = rowContentStack.arrangedSubviews.firstIndex(of: nativeStack) ?? 0
        rowContentStack.removeArrangedSubview(nativeStack)
        nativeStack.removeFromSuperview()
        let container = contentContainer
        container.setAccessibilityIdentifier("sidebar.session.content")
        container.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowContentStack.insertArrangedSubview(container, at: index)
        contentContainerIsMaterialized = true
        return container
    }

    /// Slot geometry is absent until a published customization can put pixels in the slot.
    private func materializeAfterTitleSlot() -> NSStackView {
        guard !afterTitleSlotIsMaterialized else { return afterTitleSlot }
        afterTitleSlot.orientation = .horizontal
        afterTitleSlot.alignment = .centerY
        afterTitleSlot.spacing = Design.Spacing.tight
        afterTitleSlot.isHidden = true
        afterTitleSlot.setAccessibilityIdentifier("sidebar.session.slot.after-title")
        rowContentStack.addArrangedSubview(afterTitleSlot)
        afterTitleSlotIsMaterialized = true
        return afterTitleSlot
    }

    /// Woken/snoozed text is uncommon durable state. Ordinary rows do not carry an empty label
    /// and its intrinsic-size constraints merely because another row might need one.
    private func attentionLabelForPresentation() -> NSTextField {
        if let attentionOverlayLabel { return attentionOverlayLabel }

        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.setAccessibilityIdentifier("sidebar.session.attention-overlay")
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.isHidden = true
        let insertionIndex = afterTitleSlotIsMaterialized
            ? max(0, rowContentStack.arrangedSubviews.count - 1)
            : rowContentStack.arrangedSubviews.count
        rowContentStack.insertArrangedSubview(label, at: insertionIndex)
        attentionOverlayLabel = label
        return label
    }

    /// Materializes the alternate-account overlay when it first has pixels to contribute.
    /// Hung off the provider mark rather than laid out beside it, so the native composition
    /// remains compact. A selected identity renderer may still replace this whole container.
    private func accountChipViewForPresentation() -> NSImageView {
        if let accountChipView { return accountChipView }

        let chip = NSImageView()
        chip.imageScaling = .scaleProportionallyDown
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setAccessibilityIdentifier("sidebar.session.account")
        nativeIdentityContent.addSubview(chip)

        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: AccountBadgeDefaults.chipSize),
            chip.heightAnchor.constraint(equalToConstant: AccountBadgeDefaults.chipSize),
            chip.trailingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: AccountBadgeDefaults.cornerOverhang
            ),
            chip.bottomAnchor.constraint(
                equalTo: iconView.bottomAnchor,
                constant: AccountBadgeDefaults.cornerOverhang
            )
        ])

        accountChipView = chip
        return chip
    }

    /// Adds the pin mark only once a pinned row needs it. Reuse keeps the now-warm view hidden,
    /// while rows that never carry a pin never pay for its image, constraints, or stack slot.
    private func setPinned(_ pinned: Bool) {
        guard pinned else {
            pinnedIndicator?.isHidden = true
            return
        }
        if let pinnedIndicator {
            pinnedIndicator.isHidden = false
            return
        }

        let indicator = NSImageView()
        indicator.holdSymbol(
            SidebarRowDefaults.pinnedSymbol,
            slot: Design.Size.inlineButtonGlyph
        )
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(SidebarRowDefaults.pinnedAccessibilityLabel)
        indicator.setAccessibilityIdentifier("sidebar.session.pinned")
        indicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.label
            : Design.Surface.accent

        rowContentStack.insertArrangedSubview(indicator, at: 1)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
            indicator.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
        ])
        pinnedIndicator = indicator
    }

    private func setManager(_ isManager: Bool) {
        guard isManager else {
            managerIndicator?.isHidden = true
            return
        }
        if let managerIndicator {
            managerIndicator.isHidden = false
            return
        }

        let indicator = NSImageView()
        indicator.holdSymbol("person.3", slot: Design.Size.inlineButtonGlyph)
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(L10n.string("Manager"))
        indicator.setAccessibilityIdentifier("sidebar.session.manager")
        indicator.toolTip = L10n.string("Manager")

        let insertionIndex = afterTitleSlotIsMaterialized
            ? max(0, rowContentStack.arrangedSubviews.count - 1)
            : rowContentStack.arrangedSubviews.count
        rowContentStack.insertArrangedSubview(indicator, at: insertionIndex)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
            indicator.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
        ])
        managerIndicator = indicator
    }

    /// Adds the settings mark only once a row behaves differently, on the pin's terms exactly.
    ///
    /// Drawn in the secondary ink rather than the accent the pin uses: the pin is a decision the
    /// user makes about *this list* and should be findable at a glance, while this is a footnote
    /// about the row's conduct — it should be noticeable when looked for and silent otherwise.
    private func setConductMark(_ summary: RowConductSummary?) {
        guard let summary else {
            conductIndicator?.isHidden = true
            return
        }
        if let conductIndicator {
            conductIndicator.isHidden = false
            conductIndicator.toolTip = summary.sentence
            return
        }

        let indicator = NSImageView()
        indicator.image = Design.Symbol.image(
            RowConductDefaults.symbol,
            slot: Design.Size.inlineButtonGlyph,
            pointSize: Design.Symbol.control
        )
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(RowConductStrings.markLabel)
        indicator.setAccessibilityIdentifier(RowConductDefaults.sessionIdentifier)
        indicator.toolTip = summary.sentence
        indicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.secondary

        // After the title rather than before it: the pin changes where the row *is* and belongs
        // in front, while this describes what it does and reads as a trailing footnote. Placed
        // by the attention overlay's own rule — last, but never past the extension slot, which
        // owns the end of the row.
        let insertionIndex = afterTitleSlotIsMaterialized
            ? max(0, rowContentStack.arrangedSubviews.count - 1)
            : rowContentStack.arrangedSubviews.count
        rowContentStack.insertArrangedSubview(indicator, at: insertionIndex)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
            indicator.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
        ])
        conductIndicator = indicator
    }

    /// The slot sits at the trailing edge, where it reads as status rather than as another
    /// icon competing with the agent's own.
    private func setupTrailingSlot() {
        statusSlot.translatesAutoresizingMaskIntoConstraints = false

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

        // Trailing-most last: the archive button takes the row's edge — the same column the
        // status mark holds at rest — and the `⋯` sits inboard of it.
        hoverControls.orientation = .horizontal
        hoverControls.alignment = .centerY
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(actionButton)
        hoverControls.addArrangedSubview(archiveButton)

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.setAccessibilityIdentifier("sidebar.session.trailing")
        statusSlot.setAccessibilityIdentifier("sidebar.session.status")
        actionButton.setAccessibilityIdentifier("sidebar.session.actions")
        archiveButton.setAccessibilityIdentifier("sidebar.session.archive")
        hoverControls.setAccessibilityIdentifier("sidebar.session.hover-controls")
        trailingSlot.addSubview(statusSlot)
        trailingSlot.addSubview(hoverControls)

        let width = trailingSlot.widthAnchor.constraint(
            equalToConstant: SidebarRowDefaults.trailingSlotSize
        )
        trailingSlotWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            trailingSlot.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),

            // The status and the archive button share the row's outer column and trade
            // visibility there — see `setActionVisible`. Both are pinned to the slot's trailing
            // edge rather than to each other, so neither one's absence moves the other.
            statusSlot.centerXAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor,
                constant: -SidebarRowDefaults.trailingSlotSize / 2
            ),
            statusSlot.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            statusSlot.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            statusSlot.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            hoverControls.trailingAnchor.constraint(equalTo: trailingSlot.trailingAnchor),
            hoverControls.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
    }

    /// Applies status without making an invisible `SessionStatusIndicator` part of every cold
    /// viewport mount. Once a recycled row has needed one it remains warm and receives idle state
    /// so any former mark disappears; rows that have only ever been idle keep the empty slot.
    private func updateStatus(for activity: SessionActivity, isLoading: Bool) {
        let presentsStatus = isLoading || ![.idle, .dormant].contains(activity)
        self.presentsStatus = presentsStatus
        guard presentsStatus || statusIndicator != nil else { return }

        let indicator: SessionStatusIndicator
        if let statusIndicator {
            indicator = statusIndicator
        } else {
            let materialized = SessionStatusIndicator()
            materialized.translatesAutoresizingMaskIntoConstraints = false
            materialized.hostGround = backgroundStyle == .emphasized ? .selection : nil
            statusSlot.addSubview(materialized)
            NSLayoutConstraint.activate([
                materialized.leadingAnchor.constraint(equalTo: statusSlot.leadingAnchor),
                materialized.trailingAnchor.constraint(equalTo: statusSlot.trailingAnchor),
                materialized.topAnchor.constraint(equalTo: statusSlot.topAnchor),
                materialized.bottomAnchor.constraint(equalTo: statusSlot.bottomAnchor)
            ])
            statusIndicator = materialized
            indicator = materialized
        }
        indicator.update(for: activity, isLoading: isLoading)
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
        setActionVisible(presentsHoverControls, animated: animated)
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
        guard let popoverSession,
              let popoverActivity,
              window != nil,
              popover?.isShown != true
        else { return }
        guard let controller = makeSessionHoverCard(
            session: popoverSession,
            activity: popoverActivity
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

    /// Resolves hover-only state at the point the hover card is actually requested. Keeping
    /// this seam separate also lets the launch regression prove that ordinary row configuration
    /// performs no hover discovery.
    func makeSessionHoverCard(
        session: AgentSession,
        activity: SessionActivity
    ) -> NSViewController? {
        let hoverSession = NativeSidebarParity.host(.hoverContent, session)
        let hoverSessionID = NativeSidebarParity.host(.entityIdentity, hoverSession.id)
        return makeSessionHoverCard(
            info: NativeSidebarParity.host(
                .hoverContent,
                sessionHoverInfoProvider(hoverSession, activity)
            ),
            sessionID: hoverSessionID
        )
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
                    NativeSidebarParity.host(
                        .customizationPresentation,
                        ComponentCustomizationProviderSlot.shared.perform(action)
                    )
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

    /// Crossfades between the row's two trailing readings: status at rest, actions under the
    /// pointer. The archive button takes the very column the status mark occupies, so the swap
    /// moves nothing — the marks trade visibility inside a geometry that holds still.
    ///
    /// The status yielding to the pointer is deliberate, not lost truth: the pointer is on the
    /// row *to act on it*, the hover card still names the state, and the selected row — the one
    /// whose spinner is most often under a pointer, because clicking it is what raised it —
    /// wears its activity as the row's own beam ring instead. See `SidebarHoverRowView`.
    private func setActionVisible(_ visible: Bool, animated: Bool) {
        if visible {
            actionButton.materializeGlyphIfNeeded()
            archiveButton.materializeGlyphIfNeeded()
            setTrailingSlotExpanded(true)
        }
        let statusAlpha: CGFloat = (presentsStatus && !visible) ? 1 : 0

        guard animated else {
            hoverControls.alphaValue = visible ? 1 : 0
            statusSlot.alphaValue = statusAlpha
            setTrailingSlotExpanded(visible)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.quick
            hoverControls.animator().alphaValue = visible ? 1 : 0
            statusSlot.animator().alphaValue = statusAlpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, !self.presentsHoverControls else { return }
                self.setTrailingSlotExpanded(false)
            }
        })
    }

    /// Keeps invisible controls from taxing every title. Expansion happens before the actions
    /// fade in so both targets remain inside the hit-tested parent; collapse waits until the fade
    /// out completes so a visible button never overhangs it.
    ///
    /// The expanded geometry is the same one whatever the row is doing: the pair holds the row's
    /// edge, with archive in the status's own column, so revealing the actions moves nothing and
    /// neither does an activity change arriving while the pointer is on the row. See
    /// `SidebarRowDefaults.sessionTrailingSlotWidth` for the behaviour that bought.
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

    /// `conduct` is handed in rather than looked up: this runs on the viewport path, and a row
    /// that reaches for `ProjectStore.shared` answers about a different store than the sidebar
    /// it lives in was built against. See `RowConductSummary`.
    func configure(
        with session: AgentSession,
        activity: SessionActivity,
        isLoading: Bool = false,
        conduct: RowConductSummary? = nil,
        isScheduledStart: Bool = false
    ) {
        let hoverSession = NativeSidebarParity.host(.hoverContent, session)
        let rowID = NativeSidebarParity.host(.entityIdentity, session.id)
        let rowTitle = NativeSidebarParity.fact(.sessionTitle, session.displayTitle)
        let rowIsPinned = NativeSidebarParity.fact(.sessionPinned, session.isPinned)
        let rowActivity = NativeSidebarParity.fact(.sessionActivity, activity)
        let rowIsLoading = NativeSidebarParity.host(.transientLoading, isLoading)
        let rowIsScheduled = NativeSidebarParity.fact(
            .sessionScheduledStart,
            isScheduledStart
        )
        let rowWake = NativeSidebarParity.fact(.sessionWake, session.wake)
        let hasCustomConduct = NativeSidebarParity.fact(.sessionConduct, conduct != nil)
        let conductDetail = NativeSidebarParity.host(.conductDetail, conduct)
        let provider = NativeSidebarParity.fact(.sessionProvider, session.kind)
        let accountHandle = NativeSidebarParity.fact(.sessionAccount, session.accountHandle)
        let isSideChat = NativeSidebarParity.fact(.sessionParent, session.isSideChat)

        // Rows reconfigure constantly while an agent works, so an open popover survives a
        // same-session refresh; only reuse for a different session dismisses it.
        if sessionID != rowID {
            dismissPopover()
        }
        popoverSession = hoverSession
        popoverActivity = rowActivity

        // Read before the id is overwritten: a morph is only honest when the name being
        // replaced is the one this row is showing, which means the *same* session with a
        // *different* title. Everything else — a first fill, a row reconfigured while an
        // agent works, a cell recycled from another session — lands the title directly.
        animatesNextTitle = sessionID == rowID
            && titleLabel.stringValue != rowTitle

        sessionID = rowID
        nativeTitle = rowTitle
        nativeToolTip = nil
        setPinned(rowIsPinned)
        let supervision = NativeSidebarParity.fact(
            .sessionManagerRelationship,
            ControlGrantStore.shared.overview(for: rowID)
        )
        let isManager = NativeSidebarParity.fact(
            .sessionManagerRole,
            ControlGrantStore.shared.isManager(rowID)
        )
        setManager(isManager)
        setConductMark(hasCustomConduct ? conductDetail : nil)
        if let managerID = supervision.managedBy,
           let manager: AgentSession = NativeSidebarParity.fact(
               .sessionTitle,
               ProjectStore.shared.session(withID: managerID)
           ) {
            let managerTitle = NativeSidebarParity.fact(.sessionTitle, manager.displayTitle)
            titleLabel.setAccessibilityLabel(
                L10n.format("%@, managed by %@", rowTitle, managerTitle)
            )
        } else if isManager {
            titleLabel.setAccessibilityLabel(L10n.format("%@, manager", rowTitle))
        } else {
            titleLabel.setAccessibilityLabel(rowTitle)
        }
        if rowIsScheduled {
            let label = attentionLabelForPresentation()
            label.stringValue = L10n.string("Scheduled")
            label.setAccessibilityLabel(L10n.string("Session is scheduled to start automatically"))
            label.isHidden = false
        } else if rowWake != nil {
            let label = attentionLabelForPresentation()
            label.stringValue = L10n.string("Woke")
            label.setAccessibilityLabel(L10n.string("Session woke from snooze"))
            label.isHidden = false
        } else if NativeSidebarParity.fact(
            .sessionSnoozed,
            session.isSnoozed(at: NativeSidebarParity.host(.clock, Date()))
        ) {
            let label = attentionLabelForPresentation()
            label.stringValue = L10n.string("Snoozed")
            label.setAccessibilityLabel(L10n.string("Session is snoozed"))
            label.isHidden = false
        } else if let attentionOverlayLabel {
            attentionOverlayLabel.stringValue = ""
            attentionOverlayLabel.isHidden = true
        }

        // Bound to *this* session rather than reading the row's id when it fires. A press
        // outlives the row it started on — `ThemedIconButton` completes the gesture even after
        // the sidebar has recycled this view into another session's row — and a late release
        // reading `sessionID` would archive whichever session the row had become.
        archiveButton.isHidden = rowIsScheduled
        archiveButton.onPress = rowIsScheduled
            ? nil
            : { [weak self] in self?.onArchive?(rowID) }

        isDormant = rowActivity == .dormant && !rowIsScheduled

        updateStatus(for: rowActivity, isLoading: rowIsLoading)

        // Rows are reconfigured while the pointer sits on them (activity changes as an
        // agent works), so the hover state is reasserted rather than reset.
        setActionVisible(presentsHoverControls, animated: false)

        // The hover popover carries the full title and account, so a tooltip would only
        // duplicate it more slowly.
        // The standard login never has an account chip. Looking it up anyway makes the first
        // visible row scan every account directory and parse shell aliases during cold launch.
        // Alternate rows still resolve synchronously because their chip is visible content;
        // the hover card performs its own complete lookup only when requested.
        let account = accountHandle.isStandard
            ? nil
            : NativeSidebarParity.host(
                .identityPresentation,
                sessionAccountProvider(provider, accountHandle)
            )
        applyAgentIcon(provider: provider, isSideChat: isSideChat, account: account)
        applyTextColors()

        refreshCustomizations()
    }

    /// Rechecks the two public row surfaces after an extension publication. Product rows call
    /// this from the sidebar's one observer; rows that are not visible stay entirely dormant
    /// until AppKit configures them later.
    func refreshCustomizations(
        changedTargets: Set<ExtensionComponentTarget>? = nil
    ) {
        guard let sessionID else { return }
        let entityID = sessionID.uuidString.lowercased()
        let identityTarget = ExtensionComponentTarget.sessionIdentity(sessionID: entityID)
        let rowTarget = ExtensionComponentTarget(
            component: HostComponentContracts.sidebarSessionRow.id,
            contractVersion: HostComponentContracts.sidebarSessionRow.version,
            entityID: entityID
        )

        refreshCustomizationHost(
            target: identityTarget,
            isMaterialized: identityCustomizationHostIsMaterialized,
            host: { identityCustomizationHost },
            changedTargets: changedTargets
        )
        let rowSurfaceSettled = refreshCustomizationHost(
            target: rowTarget,
            isMaterialized: customizationHostIsMaterialized,
            host: { customizationHost },
            changedTargets: changedTargets
        )
        // The title, tooltip and icon land only through `applyCustomizationProperties`,
        // which a materialized host fires on every `updateTarget`. A row whose host stays
        // dormant still owes its native content the same application.
        if !rowSurfaceSettled {
            applyCustomizationProperties([:])
        }
    }

    /// Returns whether the target's presentation is settled: the host consumed the update,
    /// or `changedTargets` proves this row's content was not affected. `false` means the
    /// deferral guard skipped a dormant host, so nothing applied the row's properties.
    @discardableResult
    private func refreshCustomizationHost(
        target: ExtensionComponentTarget,
        isMaterialized: Bool,
        host: () -> ComponentCustomizationHost,
        changedTargets: Set<ExtensionComponentTarget>?
    ) -> Bool {
        guard Self.isCustomizationTarget(target, affectedBy: changedTargets) else { return true }
        guard !defersCustomizationUntilNeeded
                || isMaterialized
                || !customizationLookup(target).isEmpty
        else { return false }
        host().updateTarget(target)
        return true
    }

    private static func isCustomizationTarget(
        _ target: ExtensionComponentTarget,
        affectedBy changedTargets: Set<ExtensionComponentTarget>?
    ) -> Bool {
        guard let changedTargets else { return true }
        return changedTargets.contains {
            $0.component == target.component
                && $0.contractVersion == target.contractVersion
                && ($0.entityID == nil || $0.entityID == target.entityID)
        }
    }

    var customizationHostsAreMaterialized: Bool {
        identityCustomizationHostIsMaterialized || customizationHostIsMaterialized
    }

    var customizationScaffoldingIsMaterialized: Bool {
        identityContentContainerIsMaterialized
            || contentContainerIsMaterialized
            || afterTitleSlotIsMaterialized
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
    private func applyAgentIcon(
        provider: AgentKind,
        isSideChat: Bool,
        account: AgentAccount?
    ) {
        let builtInProviderImage = provider.icon
        let image: NSImage?
        let knownMarkTone: CGFloat?
        if isSideChat {
            image = NSImage(
                systemSymbolName: SidebarRowDefaults.sideChatSymbol,
                accessibilityDescription: SidebarRowDefaults.sideChatAccessibilityLabel
            )
            knownMarkTone = nil
        } else if let resolution = NativeSidebarParity.host(
            .identityPresentation,
            ExtensionIdentityResolverProviderSlot.shared.providerIcon(
                providerID: provider.rawValue
            )
        ) {
            let resolved = resolveIdentityImage(
                resolution.image,
                extensionIdentifier: resolution.extensionIdentifier
            )
            image = resolved ?? builtInProviderImage
            knownMarkTone = resolved == nil ? provider.brandIconTone : nil
        } else {
            image = builtInProviderImage
            knownMarkTone = provider.brandIconTone
        }
        agentMark = image.map(slotSized)
        agentMarkTone = knownMarkTone
        iconView.image = plated(agentMark)
        iconView.setAccessibilityLabel(
            isSideChat
                ? SidebarRowDefaults.sideChatAccessibilityLabel
                : provider.displayName
        )
        iconView.contentTintColor = isDormant ? Design.Text.tertiary : Design.Text.secondary

        let dimsThroughAlpha = image.map { !$0.isTemplate } ?? false
        iconView.alphaValue = (isDormant && dimsThroughAlpha) ? AgentIconDefaults.dormantAlpha : 1

        let builtInChip = AccountBadge.chip(for: account)
        let chip: NSImage?
        if let account, account.emoji == nil,
           let resolution = NativeSidebarParity.host(
               .identityPresentation,
               ExtensionIdentityResolverProviderSlot.shared.accountIcon(
                   accountID: account.id.rawValue
               )
           ) {
            chip = resolveIdentityImage(
                resolution.image,
                extensionIdentifier: resolution.extensionIdentifier
            ) ?? builtInChip
        } else {
            // An explicit user emoji remains above an extension resolver in precedence.
            chip = builtInChip
        }
        if let chip {
            let chipView = accountChipViewForPresentation()
            chipView.image = chip
            chipView.setAccessibilityLabel(account?.displayName)
            chipView.isHidden = false
            chipView.alphaValue = isDormant ? AgentIconDefaults.dormantAlpha : 1
        } else if let accountChipView {
            accountChipView.image = nil
            accountChipView.setAccessibilityLabel(nil)
            accountChipView.isHidden = true
        }

        nativeIcon = iconView.image
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
        if backgroundStyle == .emphasized, !image.isTemplate,
           let selected = image.copy() as? NSImage {
            // Selection already supplies the row's strongest plate. Turning a provider mark
            // into selection ink keeps its identity readable without stacking a second neutral
            // tile inside that fill. Account avatars remain separate corner chips and retain
            // their pixels; this conversion applies only to the provider mark in the main slot.
            selected.isTemplate = true
            return selected
        }
        return IconBackplate.plated(
            image,
            knownMarkTone: agentMarkTone,
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
            guard let url = NativeSidebarParity.host(
                .identityPresentation,
                ExtensionManager.shared.imageResourceURL(
                    relativePath: relativePath,
                    extensionIdentifier: extensionIdentifier
                )
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
               let account = NativeSidebarParity.host(
                   .identityPresentation,
                   AgentAccountDiscovery.account(
                       for: parsed.provider,
                       handle: parsed.handle
                   )
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
                return accountChipView?.image
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
        let iconTint = backgroundStyle == .emphasized
            ? Design.Ink.selection.label
            : (isDormant ? Design.Text.tertiary : Design.Text.secondary)
        iconView.contentTintColor = iconTint
        // `applyCustomizationProperties` restores the native icon before applying an optional
        // replacement. Keep that snapshot on the row's current ground: caching it only in
        // `applyAgentIcon` captured the ordinary sidebar tint, so the next activity refresh of a
        // selected Codex row restored white over an orange selection after this method had
        // correctly chosen black.
        nativeIconTint = iconTint
        pinnedIndicator?.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.label
            : Design.Surface.accent
        managerIndicator?.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.secondary
        attentionOverlayLabel?.textColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.tertiary
        statusIndicator?.hostGround = ground
        actionButton.hostGround = ground
        archiveButton.hostGround = ground
    }
}

// MARK: - Menu Presentation

extension SessionRowView: ThemedMenuPresentationObserving {
    func themedMenuPresentationDidChange(isPresented: Bool) {
        guard isPresentingMenu != isPresented else { return }
        isPresentingMenu = isPresented
        setActionVisible(presentsHoverControls, animated: !isPresented)
    }
}

// MARK: - Sidebar Density

extension SessionRowView: SidebarDensityAdopting {

    /// Restates the row's two gutters at the width the column now has. Both are constraint
    /// constants, so this is the whole of a row's part in a divider drag.
    func applySidebarDensity(_ density: SidebarDensity) {
        contentLeadingConstraint?.constant = density.rowLeadingInset
        trailingSlotConstraint?.constant = -trailingSlotInset(for: density.rowTrailingInset)
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
        case .cursor: return "cursorarrow"
        }
    }
}
