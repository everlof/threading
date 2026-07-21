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

    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

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
        nameLabel.font = .systemFont(ofSize: SidebarRowDefaults.projectFontSize, weight: .semibold)

        switch style {
        case .standalone:
            nameLabel.stringValue = project.name
        case .checkout:
            nameLabel.stringValue = GitInfo.currentBranch(for: project.folderPath) ?? project.name
        }

        setCount(collapsedSessionCount)
        toolTip = project.folderPath
        applyTextColors()
    }

    /// Shows a group heading — a repository above its checkouts, or the archive — with an
    /// optional count of what it contains.
    func configureAsRepository(named name: String, count: Int = 0) {
        isHeading = true
        nameLabel.font = .systemFont(ofSize: SidebarRowDefaults.headingFontSize, weight: .semibold)
        nameLabel.stringValue = name
        setCount(count)
        toolTip = nil
        applyTextColors()
    }

    // MARK: - Private Methods

    private func setupViews() {
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

        addSubview(nameLabel)
        addSubview(countLabel)
        setAccessibilityRole(.staticText)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SidebarRowDefaults.leadingInset
            ),
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
    }

    private func setCount(_ count: Int) {
        countLabel.stringValue = count > 0 ? String(count) : ""
        countLabel.isHidden = count <= 0
    }

    /// Applies the row's colours for its current role and selection state.
    private func applyTextColors() {
        if backgroundStyle == .emphasized {
            nameLabel.textColor = .alternateSelectedControlTextColor
            countLabel.textColor = .alternateSelectedControlTextColor.withAlphaComponent(
                SidebarRowDefaults.secondaryTextAlpha
            )
            return
        }

        nameLabel.textColor = isHeading ? .secondaryLabelColor : .labelColor
        countLabel.textColor = .secondaryLabelColor
    }
}
