import AppKit
import ThreadingExtensionKit

// MARK: - Project Row View

/// Sidebar row for a project or a group heading: a single-line name with an optional count at
/// the trailing edge.
///
/// Where the checkout lives and what branch it is on are shown in the *session* rows' hover
/// popover, since a session is what actually runs inside the checkout — the project row
/// states the project's identity and nothing that merely describes its current state.
final class ProjectRowView: NSTableCellView {

    // MARK: - Properties

    typealias ProjectHoverContentProvider = @MainActor (Project) -> NSViewController?

    /// The project's icon — discovered, chosen, or the folder fallback. Shown only for
    /// project rows; headings and grouped checkouts keep their text-only shape.
    private let iconView = NSImageView()
    private let nameLabel = MorphingTitleLabel()
    private let countLabel = NSTextField(labelWithString: "")

    private let nativeContent = NSView()
    private let afterTitleSlot = NSStackView()
    private let trailingSlot = NSView()
    private lazy var contentContainer = ComponentContentContainer(defaultContent: nativeContent)
    private lazy var rowContentStack = NSStackView(
        views: [contentContainer, afterTitleSlot, trailingSlot]
    )
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

    /// The trailing control revealed under the pointer, crossfaded with the count in the same
    /// slot — the mechanism session rows use for their `⋯` button. A project row shows `⋯`
    /// for its actions; a branch heading shows a gear for its grouping options.
    ///
    /// A `+` sat beside it once, opening a menu that created a session with defaults for
    /// agent, account, model and checkout. Selecting the row opens the composer, where those
    /// are chosen — so the shortcut was a way to skip the only screen that asks.
    /// The same nested icon button as a session row's `⋯` and a tab's `×`; only its glyph
    /// changes with the row's role. Inks from the chrome — the sidebar's own ground.
    private let hoverButton = ThemedIconButton(
        symbolName: SidebarRowDefaults.actionSymbol,
        accessibility: L10n.string("Project actions"),
        target: .inline,
        inkSource: .chrome
    )
    private let hoverControls = NSStackView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Whether this row's role offers hover controls; repository headings keep a quiet edge.
    private var showsHoverButton = false
    private var hasCount = false

    /// Invoked when the `⋯`/gear is pressed, carrying the anchor to hang a menu from.
    var onHoverAction: ((NSView) -> Void)?

    /// The project behind the hover popover — set only for project rows, so headings show
    /// none. The popover's content is built at dwell time rather than configure time, because
    /// hovering is what refreshes the count it shows.
    private var popoverProject: Project?
    private var hoverTimer: Timer?
    private var popover: ThemedPopover?

    /// Retained so colours can be reapplied when the selection state changes.
    private var isHeading = false

    /// Whether the name landing on the next content pass renames what this row is already
    /// showing. Only a project row can say yes: a heading's name *is* its identity, so a
    /// different name there is a different heading rather than a rename of this one.
    private var animatesNextName = false

    /// `textField` is deliberately left unset (see `SessionRowView`); colours are owned by
    /// `applyTextColors` and reapplied when selection changes.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTextColors() }
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

    func configure(with project: Project, style: Style = .standalone, collapsedSessionCount: Int = 0) {
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
            moreAccessibility: "Project actions"
        )
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
        nativeToolTip = project.folderPath
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
        setHoverControls(moreSymbol: nil)
        nameLabel.applyFont(.caption)
        nativeName = name
        setCount(count)
        nativeToolTip = nil
        animatesNextName = false
        applyTextColors()
        captureNativePresentation()
        customizationHost.deactivate()
    }

    /// Shows a branch heading above the sessions that ran on it. Same quiet treatment as a
    /// repository heading — it groups, it is not selectable — sized to sit inside a project,
    /// with the grouping's own gear appearing under the pointer.
    func configureAsBranch(named branch: String, collapsedSessionCount: Int = 0) {
        isHeading = true
        popoverProject = nil
        dismissPopover()
        hideIcon()
        setHoverControls(
            moreSymbol: SidebarRowDefaults.settingsSymbol,
            moreAccessibility: "Grouping options"
        )
        nameLabel.applyFont(.caption)
        nativeName = branch
        setCount(collapsedSessionCount)
        nativeToolTip = branch
        animatesNextName = false
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
    private func setHoverControls(moreSymbol: String?, moreAccessibility: String = "") {
        hoverButton.isHidden = moreSymbol == nil
        if let moreSymbol {
            hoverButton.setSymbol(moreSymbol, accessibility: moreAccessibility)
        }

        showsHoverButton = moreSymbol != nil
        updateTrailingSlotVisibility()

        if showsHoverButton {
            setHoverButtonVisible(isHovered, animated: false)
        } else {
            hoverControls.alphaValue = 0
            countLabel.alphaValue = 1
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

        countLabel.applyFont(.numericDetail())
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setAccessibilityIdentifier("sidebar.project.count")

        setupTrailingSlot()
        setupCustomizableContent()
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            rowContentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
            // Pulled out by the padding the hover button holds around its glyph, the way
            // `PaneFooterView` places a trailing control — see `OpticalInsetProviding`. The
            // count inside the slot is pulled back in by the same amount, so the two land on
            // one line instead of the edge stepping inboard when the pointer arrives.
            rowContentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(
                    SidebarRowDefaults.trailingInset - hoverButton.opticalHorizontalInset
                )
            ),
            rowContentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth)
        ])
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

        rowContentStack.orientation = .horizontal
        rowContentStack.alignment = .centerY
        rowContentStack.spacing = SidebarRowDefaults.horizontalSpacing
        rowContentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowContentStack)

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
            ProjectIconStore.displayImage(for: $0, darkAppearance: isDarkAppearance)
        }
        // No real mark yet: a deterministic tile from the name, so every project is
        // distinguishable at a glance without anything having been found or stored.
        iconView.image = stored ?? GeneratedProjectIcon.image(for: shownProjectName)
        nativeIcon = iconView.image
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The backplate decision depends on the appearance, so a flip re-composes the icon.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard shownProjectIcon != nil else { return }
        applyIconImage()
        customizationHost.refresh()
    }

    /// Records what the row would show with no extension in play. The name is deliberately
    /// not applied here: every configure path ends in a content pass, and setting it twice
    /// would morph the row through the native name on its way to a customized one.
    private func captureNativePresentation() {
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

        hoverControls.orientation = .horizontal
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alignment = .centerY
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(hoverButton)

        trailingSlot.translatesAutoresizingMaskIntoConstraints = false
        trailingSlot.setAccessibilityIdentifier("sidebar.project.trailing")
        hoverControls.setAccessibilityIdentifier("sidebar.project.actions")
        trailingSlot.addSubview(countLabel)
        trailingSlot.addSubview(hoverControls)

        NSLayoutConstraint.activate([
            trailingSlot.widthAnchor.constraint(
                equalToConstant: SidebarRowDefaults.trailingSlotSize
            ),
            trailingSlot.heightAnchor.constraint(
                equalToConstant: SidebarRowDefaults.trailingSlotSize
            ),
            countLabel.leadingAnchor.constraint(equalTo: trailingSlot.leadingAnchor),
            // A count is text, whose frame *is* its ink, so it takes back the padding the slot
            // was widened by for the glyph beside it.
            countLabel.trailingAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor,
                constant: -hoverButton.opticalHorizontalInset
            ),
            countLabel.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor),
            hoverControls.trailingAnchor.constraint(
                equalTo: trailingSlot.trailingAnchor
            ),
            hoverControls.centerYAnchor.constraint(equalTo: trailingSlot.centerYAnchor)
        ])
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
        isHovered = true
        setHoverButtonVisible(true, animated: true)

        guard let project = popoverProject else { return }

        // Kicked at entry rather than at dwell: scc answers in tens of milliseconds, so the
        // count is usually fresh again by the time the popover opens.
        CodeStatsService.shared.refreshIfAged(project)

        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(
            withTimeInterval: SessionPopoverDefaults.hoverDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentPopover()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverDidEnd(animated: true)
    }

    /// What leaving the row means, whether the pointer left it or it left the pointer. The
    /// correction does not animate: the row it would animate is no longer under the pointer.
    private func hoverDidEnd(animated: Bool) {
        isHovered = false
        setHoverButtonVisible(false, animated: animated)
        dismissPopover()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        dismissPopover()
        customizationHost.deactivate()
    }

    private func presentPopover() {
        guard let project = popoverProject, window != nil, popover == nil else { return }
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
    /// The card exists when either Threading's native SCC feature or an extension has content.
    /// This is what lets an extension introduce a useful hover on a machine where SCC has not
    /// produced a reading, without taking over hover timing, placement, or dismissal.
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
        // A reading shows itself; a machine known to have no scc shows how to get one. A
        // project merely not counted *yet* still contributes no native content.
        if let info = ProjectStatsPopoverViewController.Info(project: project) {
            return ProjectStatsPopoverViewController(info: info, isEmbedded: true)
        }
        if CodeStatsService.shared.toolIsMissing {
            return ProjectStatsPopoverViewController(
                missingToolFor: project.name,
                isEmbedded: true
            )
        }
        return nil
    }

    private func dismissPopover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        popover?.close()
        popover = nil
    }

    /// Crossfades the trailing slot between the count and the hover controls. Alpha rather than
    /// visibility, and both permanently installed, so hovering never re-lays out the row.
    private func setHoverButtonVisible(_ visible: Bool, animated: Bool) {
        guard showsHoverButton else { return }

        guard animated else {
            hoverControls.alphaValue = visible ? 1 : 0
            countLabel.alphaValue = visible ? 0 : 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            hoverControls.animator().alphaValue = visible ? 1 : 0
            countLabel.animator().alphaValue = visible ? 0 : 1
        }
    }

    private func hoverButtonClicked() {
        onHoverAction?(hoverButton)
    }

    private func setCount(_ count: Int) {
        hasCount = count > 0
        countLabel.stringValue = count > 0 ? String(count) : ""
        countLabel.isHidden = count <= 0
        updateTrailingSlotVisibility()
    }

    private func updateTrailingSlotVisibility() {
        trailingSlot.isHidden = !showsHoverButton && !hasCount
    }

    /// Applies the row's colours for its current role and selection state. The icon tint
    /// only reaches the folder-symbol fallback; a real icon keeps its own colours.
    private func applyTextColors() {
        nameLabel.refreshTextColor()

        if backgroundStyle == .emphasized {
            countLabel.textColor = Design.Text.selected.withAlphaComponent(
                SidebarRowDefaults.secondaryTextAlpha
            )
            iconView.contentTintColor = Design.Text.selected
            nativeIconTint = iconView.contentTintColor
            return
        }

        countLabel.textColor = Design.Text.secondary
        iconView.contentTintColor = Design.Text.secondary
        nativeIconTint = iconView.contentTintColor
    }
}
