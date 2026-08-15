import AppKit
import ThreadingExtensionKit

// MARK: - Project Row View

/// Sidebar row for a project or a group heading: a single-line name with an optional count at
/// the trailing edge.
///
/// Where the checkout lives and what branch it is on are shown in the *session* rows' hover
/// popover, since a session is what actually runs inside the checkout — the project row
/// states the project's identity and nothing that merely describes its current state.
final class ProjectRowView: NSTableCellView, ThemeDerivedContent {

    // MARK: - Properties

    typealias ProjectHoverContentProvider = @MainActor (Project) -> NSViewController?

    /// The project's icon — discovered, chosen, or the folder fallback. Shown only for
    /// project rows; headings and grouped checkouts keep their text-only shape.
    private let iconView = NSImageView()
    private let nameLabel = MorphingTitleLabel()
    /// Most project rows have no collapsed-session count. Besides an otherwise empty label and
    /// three constraints, creating this eagerly pays AppKit's cold monospaced-digit font setup
    /// in the first sidebar layout. Materialize it only when there are digits to show.
    private var countLabel: NSTextField?
    /// Says this checkout's chats behave differently unless they answered for themselves.
    /// Materialized only when one does; see `setConductMark`.
    private var conductIndicator: NSImageView?
    private let nativeContent = NSView()
    private let afterTitleSlot = NSStackView()
    private let trailingSlot = NSView()
    private lazy var contentContainer = ComponentContentContainer(defaultContent: nativeContent)
    private lazy var rowContentStack = NSStackView(
        views: [contentContainer, afterTitleSlot]
    )

    /// The two gutters the column's width moves — see `SidebarDensity`. Held so a narrower
    /// column is a constant assignment on the rows already on screen.
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var trailingSlotConstraint: NSLayoutConstraint?
    private lazy var customizationHost = ComponentCustomizationHost(
        target: .init(
            component: HostComponentContracts.sidebarProjectRow.id,
            contractVersion: HostComponentContracts.sidebarProjectRow.version
        ),
        contentContainer: contentContainer,
        slots: ["after-title": afterTitleSlot],
        lookup: customizationLookup,
        imageResolver: { [weak self] reference, _ in
            self?.resolveCustomizationImage(reference)
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
    private let projectHoverContentProvider: ProjectHoverContentProvider

    /// Invoked for semantic actions inside extension-rendered replacement content.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    private var nativeName = ""
    private var nativeToolTip: String?
    private var nativeIcon: NSImage?
    private var nativeIconTint: NSColor?
    private var nativeIconAlpha: CGFloat = 1
    private var nativeIconIsHidden = true

    /// The icon record on display, retained so an appearance flip can re-compose it —
    /// whether it needs a backplate depends on what it is drawn against.
    private var shownProjectIcon: ProjectIcon?

    /// The name behind the generated-tile fallback, kept alongside the record.
    private var shownProjectName = ""

    /// The trailing controls revealed under the pointer, crossfaded with the count in the same
    /// slot. A project row shows `+` and `⋯`; a branch heading shows a grouping gear.
    private let createButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.createSymbol,
        accessibility: L10n.string("New chat or terminal"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    private let hoverButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Project actions"),
        target: .inline,
        inkSource: .chrome,
        glyphMaterialization: .deferred
    )
    private let hoverControls = NSStackView()
    private var trailingWidthConstraint: NSLayoutConstraint?

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Whether this row's role offers hover controls; repository headings keep a quiet edge.
    private var showsHoverButton = false
    private var hasCount = false

    /// Invoked when the `⋯`/gear is pressed, carrying the anchor to hang a menu from.
    var onHoverAction: ((NSView) -> Void)?
    /// Invoked when the project row's `+` is pressed, for everything it can make. Carries the
    /// button to hang the menu from beside the project it belongs to.
    var onCreateMenuAction: ((ProjectID, NSView, ThemedMenuAnchor) -> Bool)?

    /// The project behind the hover popover — set only for project rows, so headings show
    /// none. The popover's content is built at dwell time rather than configure time, because
    /// hovering is what refreshes the count it shows.
    private var popoverProject: Project?
    private var popover: ThemedPopover?

    /// Decides when the hover card opens and closes; `SessionPopoverDefaults.hoverPolicy`
    /// waits out the dwell and closes the instant the pointer leaves the row.
    private lazy var popoverScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(policy: SessionPopoverDefaults.hoverPolicy)
        scheduler.onPresent = { [weak self] in self?.presentPopover() }
        scheduler.onDismiss = { [weak self] in self?.dismissPopover() }
        return scheduler
    }()

    /// Retained so colours can be reapplied when the selection state changes.
    private var isHeading = false

    /// Whether the name landing on the next content pass renames what this row is already
    /// showing, rather than replacing one row's name with another's.
    private var animatesNextName = false

    /// Whether this row has been configured since the pool last handed it out.
    ///
    /// A branch heading's name is its identity, so it cannot ask "same heading, new name?" the
    /// way a project row asks it of its id — but a *reused* cell is the only way a heading's
    /// label changes without the heading having changed. False means the line on screen belongs
    /// to whatever row this view was showing before, and a name landing on it is not a rename.
    private var hasConfiguredSinceReuse = false

    /// `textField` is deliberately left unset (see `SessionRowView`); colours are owned by
    /// `applyTextColors` and reapplied when selection changes.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            applyTextColors()
            // Selection moves the ground under the tile as well as under the text — the same
            // reason `SessionRowView` re-decides its mark here. A project's own favicon is as
            // able to vanish into a block of accent as an agent's is.
            rederiveThemedContent()
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        customizationLookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
        projectHoverContentProvider = Self.nativeProjectHoverContent(for:)
        super.init(frame: frameRect)
        setupViews()
    }

    /// Injection point used by the Component Gallery and focused shell tests.
    init(
        customizationLookup: @escaping ComponentCustomizationHost.Lookup,
        projectHoverContentProvider: @escaping ProjectHoverContentProvider =
            ProjectRowView.nativeProjectHoverContent(for:)
    ) {
        self.customizationLookup = customizationLookup
        self.projectHoverContentProvider = projectHoverContentProvider
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// How a project row names itself.
    enum Style {
        /// The only checkout of its repository: named after the folder.
        case standalone

        /// One of several checkouts, sitting under a repository heading: named by its branch,
        /// since the repository name is already shown above it and the branch is what tells
        /// the checkouts apart.
        case checkout
    }

    func configure(
        with project: Project,
        style: Style = .standalone,
        collapsedSessionCount: Int = 0,
        conduct: RowConductSummary? = nil
    ) {
        isHeading = false

        // Read before the record is replaced: the same project named differently is a
        // rename — or, for a grouped checkout named by its branch, a branch that moved
        // under it. Either is a change to the name already on screen, and worth showing as
        // one. A cell recycled from another project is not, and lands its name directly.
        let wasShowingThisProject = popoverProject?.id == project.id

        // Rows reconfigure while the pointer sits on them, so an open popover survives a
        // same-project refresh; only reuse for a different project dismisses it.
        if !wasShowingThisProject {
            dismissPopover()
        }
        popoverProject = project

        setHoverControls(
            moreSymbol: SidebarRowDefaults.actionSymbol,
            moreAccessibility: "Project actions",
            showsCreate: true
        )
        bindCreateButton(to: project.id)
        nameLabel.applyFont(.emphasizedBody)

        switch style {
        case .standalone:
            nativeName = project.name
            // The icon shows on standalone rows only: under a repository heading the same
            // repo's mark would repeat once per checkout and say nothing new.
            showIcon(for: project)
        case .checkout:
            nativeName = GitInfo.currentBranch(for: project.folderPath) ?? project.name
            hideIcon()
        }

        setCount(collapsedSessionCount)

        // Two overrides, told apart by whether they change what the app *does* when nobody is
        // looking. A sound is presentation: it announces itself by being heard, so it is named
        // in the tooltip and draws nothing. Conduct — muted, or continuing at its reset — never
        // announces itself at all, and a checkout whose chats behave differently says so with a
        // mark. See `RowConductSummary`; this is the one case the old "a row acquires no badge
        // for carrying configuration" rule was too broad for.
        setConductMark(conduct)
        nativeToolTip = [
            project.folderPath,
            SoundOverrideAudit.toolTipLine(
                for: .project(project.id),
                overrides: project.soundOverrides
            ),
            conduct?.sentence
        ].compactMap { $0 }.joined(separator: "\n")
        animatesNextName = wasShowingThisProject && nameLabel.stringValue != nativeName
        applyTextColors()
        captureNativePresentation()
        customizationHost.updateTarget(
            .init(
                component: HostComponentContracts.sidebarProjectRow.id,
                contractVersion: HostComponentContracts.sidebarProjectRow.version,
                entityID: project.id.uuidString.lowercased()
            )
        )
    }

    /// Shows a group heading — a repository above its checkouts, or the archive — with an
    /// optional count of what it contains.
    func configureAsRepository(named name: String, count: Int = 0) {
        isHeading = true
        popoverProject = nil
        dismissPopover()
        hideIcon()
        setHoverControls(moreSymbol: nil, showsCreate: false)
        nameLabel.applyFont(.caption)
        nativeName = name
        setCount(count)
        // A heading has no record and therefore no settings of its own. Cleared explicitly
        // because this view is recycled: a mark left over from the checkout that used the cell
        // before would be a group claiming a chat's configuration.
        setConductMark(nil)
        nativeToolTip = nil
        animatesNextName = false
        applyTextColors()
        captureNativePresentation()
        customizationHost.deactivate()
    }

    /// Shows a branch heading above the sessions that ran on it. Same quiet treatment as a
    /// repository heading — it groups, it is not selectable — sized to sit inside a project,
    /// with the grouping's own gear appearing under the pointer.
    ///
    /// A heading whose branch moved keeps its row (see `SidebarOutlineUpdate.branchRenames`), so
    /// unlike a repository heading this one can be renamed in place and says so by morphing.
    func configureAsBranch(named branch: String, collapsedSessionCount: Int = 0) {
        isHeading = true
        popoverProject = nil
        dismissPopover()
        hideIcon()
        setHoverControls(
            moreSymbol: SidebarRowDefaults.settingsSymbol,
            moreAccessibility: "Grouping options",
            showsCreate: false
        )
        nameLabel.applyFont(.caption)
        nativeName = branch
        setCount(collapsedSessionCount)
        setConductMark(nil)
        nativeToolTip = branch
        animatesNextName = hasConfiguredSinceReuse && nameLabel.stringValue != nativeName
        applyTextColors()
        captureNativePresentation()
        customizationHost.deactivate()
    }

    /// Configures the trailing hover control for the row's role: a `nil` `moreSymbol` hides
    /// the `⋯`/gear. Hiding is done here at configure time, never on hover, so the stack
    /// collapses without re-laying out under the pointer.
    ///
    /// The hover state is reasserted rather than reset: a row reconfigures under the pointer
    /// when its count badge changes with expansion.
    private func setHoverControls(
        moreSymbol: String?,
        moreAccessibility: String = "",
        showsCreate: Bool
    ) {
        createButton.isHidden = !showsCreate
        hoverButton.isHidden = moreSymbol == nil
        if let moreSymbol {
            hoverButton.setSymbol(moreSymbol, accessibility: moreAccessibility)
        }

        showsHoverButton = moreSymbol != nil
        trailingWidthConstraint?.constant = showsCreate
            ? SidebarRowDefaults.projectTrailingSlotWidth
            : SidebarRowDefaults.trailingSlotSize
        updateTrailingSlotVisibility()

        if showsHoverButton {
            setHoverButtonVisible(isHovered, animated: false)
        } else {
            hoverControls.alphaValue = 0
            countLabel?.alphaValue = 1
        }
    }

    // MARK: - Private Methods

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SidebarRowDefaults.iconSize,
            weight: .regular
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityIdentifier("sidebar.project.identity")

        nameLabel.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        nameLabel.setAccessibilityIdentifier("sidebar.project.title")

        // Stated once as a rule: the row's role and selection both move under it, and a
        // theme switch replaces the colours it resolves to. See `applyTextColors`.
        nameLabel.setTextColor { [weak self] in
            guard let self else { return Design.Text.label }
            if backgroundStyle == .emphasized { return Design.Text.selected }
            return isHeading ? Design.Text.secondary : Design.Text.label
        }

        setupTrailingSlot()
        setupCustomizableContent()
        setAccessibilityRole(.staticText)

        // Pulled out by the padding the hover button holds around its glyph, the way
        // `PaneFooterView` places a trailing control — see `OpticalInsetProviding`. The count
        // inside the slot is pulled back in by the same amount, so the two land on one line
        // instead of the edge stepping inboard when the pointer arrives.
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
            trailingSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth)
        ])
    }

    /// How far inside the row's trailing edge the slot is pinned, for a given gutter. Never
    /// negative — see `SessionRowView.trailingSlotInset(for:)` for the hit-testing rule this
    /// keeps, which both rows answer the same way.
    private func trailingSlotInset(for gutter: CGFloat) -> CGFloat {
        max(0, gutter - hoverButton.opticalHorizontalInset)
    }

    /// Builds the visual subtree extensions may replace. Count and hover actions remain in the
    /// trailing sibling so no replacement can hide or move host-owned project state.
    private func setupCustomizableContent() {
        let nativeStack = NSStackView(views: [iconView, nameLabel])
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

        nativeContent.setAccessibilityIdentifier("sidebar.project.default-content")
        contentContainer.setAccessibilityIdentifier("sidebar.project.content")
        contentContainer.setContentHuggingPriority(
            SidebarRowDefaults.stretchableHugging,
            for: .horizontal
        )
        contentContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        afterTitleSlot.orientation = .horizontal
        afterTitleSlot.alignment = .centerY
        afterTitleSlot.spacing = Design.Spacing.tight
        afterTitleSlot.isHidden = true
        afterTitleSlot.setAccessibilityIdentifier("sidebar.project.slot.after-title")

        // The trailing slot is **not** in the stack — pinned to the row instead, for the
        // reason `SessionRowView` states at its own trailing slot: an arranged slot reaches
        // the edge only when the stack can stretch something to its left, so it came to rest
        // against the name on some rows and on the margin on others.
        rowContentStack.orientation = .horizontal
        rowContentStack.alignment = .centerY
        rowContentStack.spacing = SidebarRowDefaults.horizontalSpacing
        rowContentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContentStack)
        addSubview(trailingSlot)

        _ = customizationHost
    }

    /// Shows the project's stored icon, or the folder symbol while it has none.
    ///
    /// The stored icon is the *composed* rendition — rounded, and backplated when its tone
    /// would vanish against the current appearance — so the icon is retained and re-composed
    /// when the appearance flips.
    private func showIcon(for project: Project) {
        iconView.isHidden = false

        shownProjectIcon = project.icon
        shownProjectName = project.name
        applyIconImage()
    }

    private func hideIcon() {
        iconView.isHidden = true
        shownProjectIcon = nil
        shownProjectName = ""
    }

    private func applyIconImage() {
        let stored = shownProjectIcon.flatMap {
            ProjectIconStore.displayImage(for: $0, on: IconBackplate.Ground(rowGround()))
        }
        // No real mark yet: a deterministic tile from the name, so every project is
        // distinguishable at a glance without anything having been found or stored.
        iconView.image = stored ?? GeneratedProjectIcon.image(for: shownProjectName)
        nativeIcon = iconView.image
    }

    /// What the tile is actually drawn on: the sidebar's surface, with the selection fill
    /// composited onto it where there is one. The same rule, and the same reason for asking only
    /// about the emphasized fill, that `SessionRowView.rowGround` states.
    ///
    /// This used to be `isDarkAppearance` — a `Bool` that `ProjectIconStore` turned into the tone
    /// of the *system* sidebar. Under Windows 98 the sidebar is `#C0C0C0`, tone 0.75, and the
    /// constant claimed 0.97; every favicon whose own tone fell between them kept a plate it did
    /// not need or lost one it did. See `IconBackplate.Ground`.
    private func rowGround() -> NSColor {
        let base = Design.Surface.background
        guard backgroundStyle == .emphasized else { return base }
        return base.composited(under: Design.Surface.accent)
    }

    /// The backplate decision depends on the ground, so an appearance flip re-composes the icon —
    /// and so does a theme change, through `ThemeDerivedContent`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rederiveThemedContent()
    }

    func rederiveThemedContent() {
        guard shownProjectIcon != nil else { return }
        applyIconImage()
        customizationHost.refresh()
    }

    /// Records what the row would show with no extension in play. The name is deliberately
    /// not applied here: every configure path ends in a content pass, and setting it twice
    /// would morph the row through the native name on its way to a customized one.
    private func captureNativePresentation() {
        // Every configure path ends here, which makes this where the row stops showing whatever
        // the pool last had it showing — read by the next pass to tell a rename from a reuse.
        hasConfiguredSinceReuse = true
        toolTip = nativeToolTip
        nativeIcon = iconView.image
        nativeIconTint = iconView.contentTintColor
        nativeIconAlpha = iconView.alphaValue
        nativeIconIsHidden = iconView.isHidden
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
        iconView.isHidden = nativeIconIsHidden

        var name = nativeName
        if case .text(let title) = properties[.title] {
            name = title
        }
        nameLabel.setStringValue(name, animated: animatesNextName)
        animatesNextName = false

        if case .text(let value) = properties[.toolTip] {
            toolTip = value
        }
        if case .image(let reference) = properties[.identityImage],
           let image = resolveCustomizationImage(reference) {
            iconView.image = image
            iconView.isHidden = false
        }
    }

    private func resolveCustomizationImage(
        _ reference: ExtensionImageReference
    ) -> NSImage? {
        switch reference {
        case .systemSymbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .hostAsset(let identifier):
            guard identifier == "project.image" else { return nil }
            return nativeIcon
        case .extensionResource:
            // Package-relative resources are resolved by the process-backed provider later.
            return nil
        }
    }

    /// Installs the host-owned trailing shell. Count and hover controls are overlaid and
    /// crossfaded, so pointer movement never changes the row's layout.
    private func setupTrailingSlot() {
        // No size stated here: the button knows its own target and padding.
        // The actions and the grouping gear alike open a menu, which happens on the press —
        // see `ThemedIconButton.presentsMenu`.
        hoverButton.presentsMenu = true
        hoverButton.onPress = { [weak self] in self?.hoverButtonClicked() }
        hoverButton.translatesAutoresizingMaskIntoConstraints = false

        // The `+` is a menu again: its press used to make a chat directly, but that is exactly
        // what clicking the row already does, so the shortcut saved nothing — and it hid
        // the terminal behind a right-click. The choice is bound to a project in `configure`,
        // not here — see `bindCreateButton`.
        createButton.presentsMenu = true
        createButton.translatesAutoresizingMaskIntoConstraints = false

        hoverControls.orientation = .horizontal
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alignment = .centerY
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(createButton)
        hoverControls.addArrangedSubview(hoverButton)

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.setAccessibilityIdentifier("sidebar.project.trailing")
        hoverControls.setAccessibilityIdentifier("sidebar.project.actions")
        trailingSlot.addSubview(hoverControls)

        let width = trailingSlot.widthAnchor.constraint(
            equalToConstant: SidebarRowDefaults.trailingSlotSize
        )
        trailingWidthConstraint = width
        NSLayoutConstraint.activate([
            width,
            trailingSlot.heightAnchor.constraint(
                equalToConstant: SidebarRowDefaults.trailingSlotSize
            ),
            hoverControls.trailingAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor
            ),
            hoverControls.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
    }

    /// Crosses the count boundary once. A reused row keeps the label warm and merely hides it
    /// when its next project has no collapsed sessions.
    private func countLabelForPresentation() -> NSTextField {
        if let countLabel { return countLabel }

        let label = NSTextField(labelWithString: "")
        label.applyFont(.numericDetail())
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("sidebar.project.count")
        // Preserve the original crossfade order: hover controls stay above partially faded
        // count ink while the pointer transition is in flight.
        trailingSlot.addSubview(label, positioned: .below, relativeTo: hoverControls)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: trailingSlot.leadingAnchor),
            // A count is text, whose frame *is* its ink, so it takes back the padding the slot
            // was widened by for the glyph beside it.
            label.trailingAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor,
                constant: -hoverButton.opticalHorizontalInset
            ),
            label.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
        countLabel = label
        return label
    }

    // MARK: - Hover

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

        // The sidebar reloads and scrolls under a still pointer, and neither delivers an exit —
        // see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) {
            hoverDidEnd(animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through the receipt floating over the list — see `NSView.isPointerCovered(at:)`.
        guard !isPointerCovered(at: event.locationInWindow) else { return }

        isHovered = true
        setHoverButtonVisible(true, animated: true)

        guard let project = popoverProject else { return }

        // Kicked at entry rather than at dwell: the cached readings are usually fresh again by
        // the time the popover opens, without doing process work in the dwell callback.
        ProjectStatsService.shared.refreshIfAged(project)

        popoverScheduler.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        hoverDidEnd(animated: true)
    }

    /// What leaving the row means, whether the pointer left it or it left the pointer. The
    /// correction does not animate: the row it would animate is no longer under the pointer.
    private func hoverDidEnd(animated: Bool) {
        isHovered = false
        setHoverButtonVisible(false, animated: animated)
        popoverScheduler.pointerExited()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hasConfiguredSinceReuse = false
        dismissPopover()
        customizationHost.deactivate()
    }

    /// A sidebar reload can discard this row without reuse and without a pointer exit; a
    /// popover anchored to a row that left the window would keep floating over nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverDidEnd(animated: false) }
    }

    private func presentPopover() {
        // Asked of the popover rather than of the reference held to it: a dropdown opening in
        // this window closes the card out from under the row (see
        // `ThemedPopover.closeAll(presentedFrom:)`), and a row that read a stale reference as
        // "still showing" would never raise one again.
        guard let project = popoverProject, window != nil, popover?.isShown != true else { return }
        guard let controller = makeProjectHoverCard(for: project) else { return }

        let content = HostPopoverFactory.make(.sidebarProjectHoverCard)
        // Closed by hand on exit and reuse, matching the session popover's reasoning.
        content.behavior = .applicationDefined
        content.animates = false
        content.contentViewController = controller
        content.show(relativeTo: bounds, of: self, preferredEdge: .maxX)

        popover = content
    }

    /// Builds the presentation independently from the pointer shell so tests and future
    /// project-card triggers exercise the exact same customizable component.
    ///
    /// The card exists when either Threading's native project metrics or an extension has content.
    /// This lets an extension introduce a useful hover before the passive scan has produced a
    /// reading, without taking over hover timing, placement, or dismissal.
    func makeProjectHoverCard(for project: Project) -> NSViewController? {
        let target = ExtensionComponentTarget.projectHoverCard(
            projectID: project.id.uuidString.lowercased()
        )
        let native = projectHoverContentProvider(project)
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
            fixedWidth: ProjectPopoverDefaults.width,
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
                // If extension content was the only reason this presentation existed, removing
                // it closes the card instead of leaving an empty popover under the pointer.
                if !hasNativeContent, resolution.isEmpty {
                    self?.dismissPopover()
                }
            }
        )
        controller.view.setAccessibilityIdentifier("sidebar.project-hover-card")
        return controller
    }

    private static func nativeProjectHoverContent(for project: Project) -> NSViewController? {
        if let info = ProjectStatsPopoverViewController.Info(project: project) {
            return ProjectStatsPopoverViewController(info: info, isEmbedded: true)
        }
        return nil
    }

    private func dismissPopover() {
        popoverScheduler.cancelPendingWork()
        popover?.close()
        popover = nil
    }

    /// Crossfades the trailing slot between the count and the hover controls. Alpha rather than
    /// visibility, and both permanently installed, so hovering never re-lays out the row.
    private func setHoverButtonVisible(_ visible: Bool, animated: Bool) {
        guard showsHoverButton else { return }

        if visible {
            if !createButton.isHidden { createButton.materializeGlyphIfNeeded() }
            if !hoverButton.isHidden { hoverButton.materializeGlyphIfNeeded() }
        }

        guard animated else {
            hoverControls.alphaValue = visible ? 1 : 0
            countLabel?.alphaValue = visible ? 0 : 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            hoverControls.animator().alphaValue = visible ? 1 : 0
            countLabel?.animator().alphaValue = visible ? 0 : 1
        }
    }

    private func hoverButtonClicked() {
        onHoverAction?(hoverButton)
    }

    /// Binds the `+`'s menu to *this* project rather than to whatever the row is showing when
    /// the press fires — a menu read off the row's current project would offer to make things
    /// in whichever checkout the recycled row shows next.
    private func bindCreateButton(to projectID: ProjectID) {
        createButton.onPress = { [weak self] in
            guard let self else { return }
            _ = onCreateMenuAction?(projectID, createButton, .control)
        }
    }

    private func setCount(_ count: Int) {
        hasCount = count > 0
        if count > 0 {
            let label = countLabelForPresentation()
            label.stringValue = String(count)
            label.isHidden = false
        } else if let countLabel {
            countLabel.stringValue = ""
            countLabel.isHidden = true
        }
        updateTrailingSlotVisibility()
    }

    var countLabelIsMaterialized: Bool { countLabel != nil }

    /// Adds the settings mark only once a checkout behaves differently, on the session row's
    /// terms exactly: materialized on first need, hidden on reuse, and absent entirely from the
    /// rows — nearly all of them — that carry nothing of their own.
    ///
    /// Between the name and the extension slot, so it reads as a footnote to the checkout rather
    /// than as another icon competing with its own.
    private func setConductMark(_ summary: RowConductSummary?) {
        guard let summary else {
            conductIndicator?.isHidden = true
            return
        }
        if let conductIndicator {
            conductIndicator.isHidden = false
            return
        }

        let indicator = NSImageView()
        indicator.holdSymbol(
            RowConductDefaults.symbol,
            slot: Design.Size.inlineButtonGlyph
        )
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(RowConductStrings.markLabel)
        indicator.setAccessibilityIdentifier(RowConductDefaults.projectIdentifier)
        indicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.secondary

        let insertionIndex = rowContentStack.arrangedSubviews.firstIndex(of: afterTitleSlot)
            ?? rowContentStack.arrangedSubviews.count
        rowContentStack.insertArrangedSubview(indicator, at: insertionIndex)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph),
            indicator.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph)
        ])
        conductIndicator = indicator
    }

    private func updateTrailingSlotVisibility() {
        trailingSlot.isHidden = !showsHoverButton && !hasCount
    }

    /// Applies the row's colours for its current role and selection state. The icon tint
    /// only reaches the folder-symbol fallback; a real icon keeps its own colours.
    private func applyTextColors() {
        nameLabel.refreshTextColor()

        // The `+` and the `⋯` are drawn controls rather than tinted images, so they are told
        // which ground they are on rather than handed a colour — see
        // `BackdropThemedControl.hostGround`. Only the emphasized fill is named: the
        // unemphasized one is the accent held far back over the sidebar's surface, where the
        // chrome's ink is still the ink that reads.
        let ground: InkSource? = backgroundStyle == .emphasized ? .selection : nil
        createButton.hostGround = ground
        hoverButton.hostGround = ground

        if backgroundStyle == .emphasized {
            countLabel?.textColor = Design.Text.selected.withAlphaComponent(
                SidebarRowDefaults.secondaryTextAlpha
            )
            conductIndicator?.contentTintColor = Design.Ink.selection.secondary
            iconView.contentTintColor = Design.Text.selected
            nativeIconTint = iconView.contentTintColor
            return
        }

        countLabel?.textColor = Design.Text.secondary
        conductIndicator?.contentTintColor = Design.Text.secondary
        iconView.contentTintColor = Design.Text.secondary
        nativeIconTint = iconView.contentTintColor
    }
}

// MARK: - Sidebar Density

extension ProjectRowView: SidebarDensityAdopting {

    /// Restates the row's two gutters at the width the column now has. Project rows and branch
    /// headings are the same view, so both follow the density their sessions do.
    func applySidebarDensity(_ density: SidebarDensity) {
        contentLeadingConstraint?.constant = density.rowLeadingInset
        trailingSlotConstraint?.constant = -trailingSlotInset(for: density.rowTrailingInset)
    }
}
