import AppKit

// MARK: - Session Info Popover

/// The hover popover for a session row: the full title, which agent and account it runs,
/// where it runs, and what it is doing.
///
/// This lives at the session level rather than on the project row, because sessions are what
/// get selected and titles are what truncate — the project row already states its identity in
/// full. The checkout's context (path, branch, worktree) is carried here too, since it is the
/// world the session actually runs in.
final class SessionInfoPopoverViewController: NSViewController {

    // MARK: - Info

    struct Info {
        let title: String
        let agentLine: String
        let agentSymbol: String
        let path: String
        let branch: String?
        /// The linked worktree's name, or nil for an ordinary checkout.
        let worktree: String?
        let stateText: String
        let stateSymbol: String

        /// Built from the session, so the row does not have to know how to read git or
        /// resolve accounts.
        init(session: AgentSession, activity: SessionActivity) {
            title = session.displayTitle

            let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )
            if let account, !account.isDefault {
                agentLine = "\(session.kind.displayName) · \(account.displayName)"
            } else {
                agentLine = session.kind.displayName
            }
            agentSymbol = session.kind.symbolName

            let folderPath = ProjectStore.shared.project(forSessionID: session.id)?.folderPath
            path = folderPath ?? ""
            branch = folderPath.flatMap { GitInfo.currentBranch(for: $0) }
            worktree = folderPath.flatMap { GitInfo.worktreeName(for: $0) }

            switch activity {
            case .dormant:
                stateText = SessionPopoverDefaults.dormantState
                stateSymbol = SessionPopoverDefaults.dormantSymbol
            case .working:
                stateText = SessionPopoverDefaults.workingState
                stateSymbol = SessionPopoverDefaults.workingSymbol
            case .idle, .needsAttention:
                stateText = SessionPopoverDefaults.runningState
                stateSymbol = SessionPopoverDefaults.runningSymbol
            }
        }
    }

    // MARK: - Properties

    private let info: Info

    // MARK: - Initialization

    init(info: Info) {
        self.info = info
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let rows = NSStackView(views: makeRows())
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.small
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset, left: Design.Spacing.inset,
            bottom: Design.Spacing.inset, right: Design.Spacing.inset
        )

        let container = NSView()
        container.addSubview(rows)

        // The width is pinned, not merely capped: everything inside is compressible (the
        // title wraps, the detail labels truncate), so with only a maximum the popover's
        // fitting size collapses to a one-character-per-line column.
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: container.topAnchor),
            rows.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.width)
        ])

        view = container
    }

    // MARK: - Private Methods

    private func makeRows() -> [NSView] {
        // The full title leads: it is the one thing the row itself cannot always show.
        let title = NSTextField(wrappingLabelWithString: info.title)
        title.font = Design.Typography.control()
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = SessionPopoverDefaults.width - 2 * Design.Spacing.inset
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = [title]

        rows.append(row(symbol: info.agentSymbol, text: info.agentLine, emphasis: .secondary))

        if !info.path.isEmpty {
            rows.append(row(
                symbol: SessionPopoverDefaults.folderSymbol,
                text: abbreviated(info.path),
                emphasis: .secondary
            ))
        }

        if let branch = info.branch {
            let text = info.worktree.map { SessionPopoverDefaults.worktreeBranchLabel(branch, $0) } ?? branch
            rows.append(row(symbol: SessionPopoverDefaults.branchSymbol, text: text, emphasis: .secondary))
        }

        rows.append(row(symbol: info.stateSymbol, text: info.stateText, emphasis: .muted))

        return rows
    }

    private enum Emphasis {
        case secondary, muted

        var color: NSColor {
            self == .secondary ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    private func row(symbol: String, text: String, emphasis: Emphasis) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.iconSlotWidth).isActive = true

        let label = NSTextField(labelWithString: text)
        label.font = Design.Typography.subheading()
        label.textColor = emphasis.color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small

        return stack
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Session Popover Defaults

enum SessionPopoverDefaults {
    static let width: CGFloat = 300
    static let iconSlotWidth: CGFloat = 14

    static let folderSymbol = "folder"
    static let branchSymbol = "arrow.triangle.branch"

    static let dormantState = "Dormant · resumable"
    static let dormantSymbol = "moon.zzz"
    static let workingState = "Working"
    static let workingSymbol = "play.circle"
    static let runningState = "Running"
    static let runningSymbol = "pause.circle"

    static func worktreeBranchLabel(_ branch: String, _ worktree: String) -> String {
        "\(branch) · worktree \(worktree)"
    }

    /// Hover dwell before the popover opens, so it does not flash while the pointer crosses
    /// rows on its way somewhere else.
    static let hoverDelay: TimeInterval = 0.35
}
