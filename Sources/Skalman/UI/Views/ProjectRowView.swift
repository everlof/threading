import AppKit

// MARK: - Project Row View

/// Sidebar row for a project or a group heading: a single-line name with an optional count at
/// the trailing edge.
///
/// Where the checkout lives and what branch it is on are shown in the *session* rows' hover
/// popover, since a session is what actually runs inside the checkout — the project row
/// states the project's identity and nothing that merely describes its current state.
final class ProjectRowView: NSTableCellView {

    // MARK: - Properties

    /// The project's icon — discovered, chosen, or the folder fallback. Shown only for
    /// project rows; headings and grouped checkouts keep their text-only shape.
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    /// The name's two leading anchors: beside the icon for project rows, at the row's own
    /// inset for the roles that show none. Exactly one is active at a time.
    private var nameLeadingWithIcon: NSLayoutConstraint?
    private var nameLeadingPlain: NSLayoutConstraint?

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
    private let hoverButton = ThemedButton()
    private let hoverControls = NSStackView()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    /// Whether this row's role offers hover controls; repository headings keep a quiet edge.
    private var showsHoverButton = false

    /// Keeps the name clear of the controls' slot, active only when they are shown so a
    /// repository heading's name keeps its full width. Pinned to the stack, so it tracks
    /// whether one control shows or two.
    private var hoverNameTrailingConstraint: NSLayoutConstraint?

    /// Invoked when the `⋯`/gear is pressed, carrying the anchor to hang a menu from.
    var onHoverAction: ((NSView) -> Void)?

    /// Retained so colours can be reapplied when the selection state changes.
    private var isHeading = false

    /// `textField` is deliberately left unset (see `SessionRowView`); colours are owned by
    /// `applyTextColors` and reapplied when selection changes.
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
        setHoverControls(
            moreSymbol: SidebarRowDefaults.actionSymbol,
            moreAccessibility: "Project actions"
        )
        nameLabel.font = .systemFont(ofSize: SidebarRowDefaults.projectFontSize, weight: .semibold)

        switch style {
        case .standalone:
            nameLabel.stringValue = project.name
            // The icon shows on standalone rows only: under a repository heading the same
            // repo's mark would repeat once per checkout and say nothing new.
            showIcon(for: project)
        case .checkout:
            nameLabel.stringValue = GitInfo.currentBranch(for: project.folderPath) ?? project.name
            hideIcon()
        }

        setCount(collapsedSessionCount)
        toolTip = project.folderPath
        applyTextColors()
    }

    /// Shows a group heading — a repository above its checkouts, or the archive — with an
    /// optional count of what it contains.
    func configureAsRepository(named name: String, count: Int = 0) {
        isHeading = true
        hideIcon()
        setHoverControls(moreSymbol: nil)
        nameLabel.font = .systemFont(ofSize: SidebarRowDefaults.headingFontSize, weight: .semibold)
        nameLabel.stringValue = name
        setCount(count)
        toolTip = nil
        applyTextColors()
    }

    /// Shows a branch heading above the sessions that ran on it. Same quiet treatment as a
    /// repository heading — it groups, it is not selectable — sized to sit inside a project,
    /// with the grouping's own gear appearing under the pointer.
    func configureAsBranch(named branch: String, collapsedSessionCount: Int = 0) {
        isHeading = true
        hideIcon()
        setHoverControls(
            moreSymbol: SidebarRowDefaults.settingsSymbol,
            moreAccessibility: "Grouping options"
        )
        nameLabel.font = .systemFont(ofSize: SidebarRowDefaults.headingFontSize, weight: .semibold)
        nameLabel.stringValue = branch
        setCount(collapsedSessionCount)
        toolTip = branch
        applyTextColors()
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
            hoverButton.image = NSImage(
                systemSymbolName: moreSymbol,
                accessibilityDescription: moreAccessibility
            )
        }

        showsHoverButton = moreSymbol != nil
        hoverNameTrailingConstraint?.isActive = showsHoverButton

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

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: SidebarRowDefaults.countFontSize,
            weight: .regular
        )
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(countLabel)
        setAccessibilityRole(.staticText)

        nameLeadingWithIcon = nameLabel.leadingAnchor.constraint(
            equalTo: iconView.trailingAnchor,
            constant: SidebarRowDefaults.horizontalSpacing
        )
        nameLeadingPlain = nameLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: SidebarRowDefaults.leadingInset
        )
        nameLeadingPlain?.isActive = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),
            iconView.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.iconSlotWidth),

            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: countLabel.leadingAnchor,
                constant: -SidebarRowDefaults.horizontalSpacing
            ),

            countLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarRowDefaults.trailingInset
            ),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setupHoverControls()
    }

    /// Shows the project's stored icon, or the folder symbol while it has none.
    ///
    /// The stored icon is the *composed* rendition — rounded, and backplated when its tone
    /// would vanish against the current appearance — so the icon is retained and re-composed
    /// when the appearance flips.
    private func showIcon(for project: Project) {
        iconView.isHidden = false
        nameLeadingPlain?.isActive = false
        nameLeadingWithIcon?.isActive = true

        shownProjectIcon = project.icon
        shownProjectName = project.name
        applyIconImage()
    }

    private func hideIcon() {
        iconView.isHidden = true
        shownProjectIcon = nil
        shownProjectName = ""
        nameLeadingWithIcon?.isActive = false
        nameLeadingPlain?.isActive = true
    }

    private func applyIconImage() {
        let stored = shownProjectIcon.flatMap {
            ProjectIconStore.displayImage(for: $0, darkAppearance: isDarkAppearance)
        }
        // No real mark yet: a deterministic tile from the name, so every project is
        // distinguishable at a glance without anything having been found or stored.
        iconView.image = stored ?? GeneratedProjectIcon.image(for: shownProjectName)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The backplate decision depends on the appearance, so a flip re-composes the icon.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard shownProjectIcon != nil else { return }
        applyIconImage()
    }

    /// Installs the trailing hover controls, dormant until a role enables them. Both buttons
    /// live in a stack so hiding one collapses it and the name reservation tracks the rest.
    private func setupHoverControls() {
        hoverButton.target = self
        hoverButton.action = #selector(hoverButtonClicked)

        for button in [hoverButton] {
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize),
                button.heightAnchor.constraint(equalToConstant: SidebarRowDefaults.trailingSlotSize)
            ])
        }

        hoverControls.orientation = .horizontal
        hoverControls.spacing = SidebarRowDefaults.hoverButtonSpacing
        hoverControls.alignment = .centerY
        hoverControls.alphaValue = 0
        hoverControls.translatesAutoresizingMaskIntoConstraints = false
        hoverControls.addArrangedSubview(hoverButton)

        addSubview(hoverControls)

        NSLayoutConstraint.activate([
            hoverControls.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SidebarRowDefaults.trailingInset
            ),
            hoverControls.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // Activated only when a role shows controls: it reserves their slot so a long name
        // never sits underneath them. Pinned to the stack's leading edge, so it tightens or
        // loosens as one control shows or two.
        hoverNameTrailingConstraint = nameLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: hoverControls.leadingAnchor,
            constant: -SidebarRowDefaults.horizontalSpacing
        )
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
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setHoverButtonVisible(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setHoverButtonVisible(false, animated: true)
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
            context.duration = SidebarRowDefaults.hoverFadeDuration
            hoverControls.animator().alphaValue = visible ? 1 : 0
            countLabel.animator().alphaValue = visible ? 0 : 1
        }
    }

    @objc private func hoverButtonClicked() {
        onHoverAction?(hoverButton)
    }

    private func setCount(_ count: Int) {
        countLabel.stringValue = count > 0 ? String(count) : ""
        countLabel.isHidden = count <= 0
    }

    /// Applies the row's colours for its current role and selection state. The icon tint
    /// only reaches the folder-symbol fallback; a real icon keeps its own colours.
    private func applyTextColors() {
        if backgroundStyle == .emphasized {
            nameLabel.textColor = Design.Text.selected
            countLabel.textColor = Design.Text.selected.withAlphaComponent(
                SidebarRowDefaults.secondaryTextAlpha
            )
            iconView.contentTintColor = Design.Text.selected
            return
        }

        nameLabel.textColor = isHeading ? Design.Text.secondary : Design.Text.label
        countLabel.textColor = Design.Text.secondary
        iconView.contentTintColor = Design.Text.secondary
    }
}
