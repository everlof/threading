import AppKit
import ThreadingExtensionKit

// MARK: - Project Row View

/// Sidebar row for a project or a group heading: a single-line name with an optional count at
/// the trailing edge.
///
/// A grouped checkout states its branch followed by a quiet, home-abbreviated path.
/// The path belongs to the native presentation; extensions may replace that content while
/// checkout identity, navigation and trailing actions remain host-owned.
final class ProjectRowView: NSTableCellView, ThemeDerivedContent {

    // MARK: - Properties

    typealias ProjectHoverContentProvider = @MainActor (Project) -> NSViewController?

    /// The project's icon — discovered, chosen, or the folder fallback. Shown only for
    /// project rows; headings and grouped checkouts keep their text-only shape.
    private let rowVisuals = ThemedProjectRowView()
    private var iconView: NSImageView { rowVisuals.iconView }
    private var nameLabel: MorphingTitleLabel { rowVisuals.titleLabel }
    /// Says this checkout's chats behave differently unless they answered for themselves.
    /// Materialized only when one does; see `setConductMark`.
    private var conductIndicator: NSImageView?
    private var executionHostIndicator: NSImageView?
    private var unavailableCheckoutIndicator: NSImageView?
    private var afterTitleSlot: NSStackView { rowVisuals.afterTitleSlot }
    private lazy var contentContainer = ComponentContentContainer(
        defaultContent: rowVisuals.nativeContent)
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
    private var createButton: ThemedIconButton { rowVisuals.createButton }
    private var hoverButton: ThemedIconButton { rowVisuals.actionButton }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPresentingMenu = false
    private var presentsHoverControls: Bool { isHovered || isPresentingMenu }

    /// Whether this row has trailing hover controls to crossfade in at all — `+`, `⋯`, or the
    /// grouping gear. False for a row that offers none, such as the archive heading.
    private var showsHoverControls = false

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
        conduct: RowConductSummary? = nil,
        executionHost: String? = nil
    ) {
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

        switch style {
        case .standalone:
            let presentation = NavigatorProjectRowPresentation.project(name: project.name)
            // The icon shows on standalone rows only: under a repository heading the same
            // repo's mark would repeat once per checkout and say nothing new.
            applyNativePresentation(presentation, identityProject: project)
        case .checkout:
            let presentation = NavigatorProjectRowPresentation.checkout(
                branch: GitInfo.currentBranch(for: project.folderPath),
                fallbackName: project.name,
                abbreviatedPath: PathAbbreviation.abbreviatingHome(in: project.folderPath)
            )
            applyNativePresentation(presentation, worktreePath: project.folderPath)
        }

        setCount(collapsedSessionCount)

        // Two overrides, told apart by whether they change what the app *does* when nobody is
        // looking. A sound is presentation: it announces itself by being heard, so it is named
        // in the tooltip and draws nothing. Conduct — muted, or continuing at its reset — never
        // announces itself at all, and a checkout whose chats behave differently says so with a
        // mark. See `RowConductSummary`; this is the one case the old "a row acquires no badge
        // for carrying configuration" rule was too broad for.
        setConductMark(conduct)
        setExecutionHostMark(executionHost)
        let checkoutUnavailable = project.lastKnownRepositoryIdentity != nil
            && GitInfo.repositoryIdentity(for: project.folderPath) == nil
        setUnavailableCheckoutMark(checkoutUnavailable)
        nativeToolTip = [
            project.folderPath,
            checkoutUnavailable ? L10n.string("Checkout unavailable at this path") : nil,
            executionHost.map(RemoteExecutionHostMark.runsOn),
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

    /// Shows a repository's root row above its checkouts, or the archive heading, with an
    /// optional count of what it contains.
    ///
    /// `representing` is the checkout that answers for the repository — see
    /// `RepoGroupNode.representativeProjectID`. Given one, the row is a real root: it draws the
    /// repository's mark and offers `+`. The repository's own checkouts draw no mark of their
    /// own (`Style.checkout`), so the icon appears exactly once per repository, at the top,
    /// rather than once per row or — as it did before this — nowhere at all.
    ///
    /// Without one it stays the quiet heading it always was, which is what the archive is.
    func configureAsRepository(
        named name: String,
        count: Int = 0,
        representing project: Project? = nil
    ) {
        popoverProject = nil
        dismissPopover()

        // A represented root is a row, not a label over one: full ink, like the project rows
        // it sits above. The bare heading below keeps the quiet treatment.
        let presentation = NavigatorProjectRowPresentation.repository(
            name: name, hasRepresentative: project != nil)
        applyNativePresentation(presentation, identityProject: project)

        if let project {
            // The repository's name, not the checkout's: the icon is borrowed from a record,
            // the name is not.
            shownProjectName = name
            applyIconImage()
            setHoverControls(moreSymbol: nil, showsCreate: true)
            bindCreateButton(to: project.id)
            nativeToolTip = GitInfo.repositoryRoot(for: project.folderPath)?.path
        } else {
            setHoverControls(moreSymbol: nil, showsCreate: false)
            nativeToolTip = nil
        }

        setCount(count)
        // A repository has no record and therefore no settings of its own. Cleared explicitly
        // because this view is recycled: a mark left over from the checkout that used the cell
        // before would be a root claiming a chat's configuration.
        setConductMark(nil)
        setUnavailableCheckoutMark(false)
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
        popoverProject = nil
        dismissPopover()
        setHoverControls(
            moreSymbol: SidebarRowDefaults.settingsSymbol,
            moreAccessibility: "Grouping options",
            showsCreate: false
        )
        applyNativePresentation(.heading(name: branch))
        setCount(collapsedSessionCount)
        setConductMark(nil)
        setUnavailableCheckoutMark(false)
        nativeToolTip = branch
        animatesNextName = hasConfiguredSinceReuse && nameLabel.stringValue != nativeName
        applyTextColors()
        captureNativePresentation()
        customizationHost.deactivate()
    }

    /// Shows a provider-defined fact bucket as a quiet, nonselectable heading. Unlike a branch
    /// heading it owns no branch operation, so no hover control is reserved beside its label.
    func configureAsFactGroup(named title: String, collapsedSessionCount: Int = 0) {
        popoverProject = nil
        dismissPopover()
        setHoverControls(moreSymbol: nil, moreAccessibility: "", showsCreate: false)
        applyNativePresentation(.heading(name: title))
        setCount(collapsedSessionCount)
        setConductMark(nil)
        setUnavailableCheckoutMark(false)
        nativeToolTip = title
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
        showsHoverControls = moreSymbol != nil || showsCreate
        rowVisuals.setHoverControls(
            moreSymbol: moreSymbol,
            moreAccessibility: moreAccessibility,
            showsCreate: showsCreate
        )
        if showsHoverControls {
            setHoverButtonVisible(presentsHoverControls, animated: false)
        }
    }

    // MARK: - Private Methods

    private func setupViews() {
        rowVisuals.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowVisuals)
        NSLayoutConstraint.activate([
            rowVisuals.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowVisuals.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowVisuals.topAnchor.constraint(equalTo: topAnchor),
            rowVisuals.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rowVisuals.onActionPress = { [weak self] _ in self?.hoverButtonClicked() }
        rowVisuals.prepareForExternalContent()
        rowVisuals.installContentContainer(contentContainer)
        contentContainer.setAccessibilityIdentifier("sidebar.project.content")
        _ = customizationHost
        setAccessibilityRole(.staticText)
    }

    /// Applies only the native content's visual role. The host still owns project identity,
    /// selection, actions, accessibility and extension replacement.
    private func applyNativePresentation(
        _ presentation: NavigatorProjectRowPresentation,
        identityProject: Project? = nil,
        worktreePath: String? = nil
    ) {
        nativeName = presentation.title
        rowVisuals.applyPresentation(presentation, path: worktreePath)
        if presentation.showsIdentityMark, let identityProject {
            showIcon(for: identityProject)
        } else {
            hideIcon()
        }
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
        setHoverButtonVisible(presentsHoverControls, animated: animated)
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
        rowVisuals.setHoverControlsVisible(visible, animated: animated)
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
        rowVisuals.setCount(count)
    }

    var countLabelIsMaterialized: Bool { rowVisuals.countLabelIsMaterialized }

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

        rowVisuals.insertHostStatusMark(indicator)
        NSLayoutConstraint.activate(indicator.squareSizeConstraints(side: Design.Size.inlineButtonGlyph))
        conductIndicator = indicator
    }

    /// Says which machine this row's sessions run on, whenever it is not this Mac.
    ///
    /// Always visible rather than a hover detail: a project that runs its agents somewhere else
    /// must never look like one that runs them here. Materialized on first need and hidden on
    /// reuse, exactly like the settings mark beside it.
    private func setExecutionHostMark(_ destination: String?) {
        guard let destination else {
            executionHostIndicator?.isHidden = true
            return
        }
        let label = RemoteExecutionHostMark.runsOn(destination)
        if let executionHostIndicator {
            executionHostIndicator.isHidden = false
            executionHostIndicator.setAccessibilityLabel(label)
            return
        }

        let indicator = NSImageView()
        indicator.holdSymbol(RemoteExecutionHostMark.symbol, slot: Design.Size.inlineButtonGlyph)
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(label)
        indicator.setAccessibilityIdentifier(RemoteExecutionHostMark.projectMarkIdentifier)
        indicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.secondary

        rowVisuals.insertHostStatusMark(indicator)
        NSLayoutConstraint.activate(indicator.squareSizeConstraints(side: Design.Size.inlineButtonGlyph))
        executionHostIndicator = indicator
    }

    /// Host-owned availability remains visible even when an extension replaces row content.
    private func setUnavailableCheckoutMark(_ unavailable: Bool) {
        guard unavailable else {
            unavailableCheckoutIndicator?.isHidden = true
            return
        }
        if let unavailableCheckoutIndicator {
            unavailableCheckoutIndicator.isHidden = false
            return
        }

        let indicator = NSImageView()
        indicator.holdSymbol("exclamationmark.triangle", slot: Design.Size.inlineButtonGlyph)
        indicator.imageScaling = .scaleProportionallyDown
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setAccessibilityElement(true)
        indicator.setAccessibilityRole(.image)
        indicator.setAccessibilityLabel(L10n.string("Checkout unavailable at this path"))
        indicator.setAccessibilityIdentifier("sidebar.project.checkout-unavailable")
        indicator.contentTintColor = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary
            : Design.Text.secondary

        rowVisuals.insertHostStatusMark(indicator)
        NSLayoutConstraint.activate(indicator.squareSizeConstraints(side: Design.Size.inlineButtonGlyph))
        unavailableCheckoutIndicator = indicator
    }

    /// The Design row handles native title, path, count, icon and control ink. Host-owned
    /// status marks stay here because an extension cannot replace or hide their meaning.
    private func applyTextColors() {
        rowVisuals.setSelection(backgroundStyle == .emphasized)
        let tint = backgroundStyle == .emphasized
            ? Design.Ink.selection.secondary : Design.Text.secondary
        conductIndicator?.contentTintColor = tint
        executionHostIndicator?.contentTintColor = tint
        unavailableCheckoutIndicator?.contentTintColor = tint
        nativeIconTint = iconView.contentTintColor
    }
}

// MARK: - Menu Presentation

extension ProjectRowView: ThemedMenuPresentationObserving {
    func themedMenuPresentationDidChange(isPresented: Bool) {
        guard isPresentingMenu != isPresented else { return }
        isPresentingMenu = isPresented
        setHoverButtonVisible(presentsHoverControls, animated: !isPresented)
    }
}

// MARK: - Sidebar Density

extension ProjectRowView: SidebarDensityAdopting {

    /// Restates the row's two gutters at the width the column now has. Project rows and branch
    /// headings are the same view, so both follow the density their sessions do.
    func applySidebarDensity(_ density: SidebarDensity) {
        rowVisuals.applySidebarDensity(
            leading: density.rowLeadingInset,
            trailing: density.rowTrailingInset
        )
    }
}
