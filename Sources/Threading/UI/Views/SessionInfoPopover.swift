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

    @MainActor
    struct Info {
        let title: String
        let agentLine: String
        let agentIcon: NSImage?
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
            var line = session.kind.displayName
            if let account, !account.isDefault {
                line += " · \(account.displayName)"
            }

            // A side chat's row shows a fork glyph instead of its agent's mark, so this is
            // where the agent is named — and where the lineage the glyph stands for is spelt
            // out, since the parent's title is not otherwise on the row.
            if let parentID = session.forkedFrom,
               let parent = ProjectStore.shared.session(withID: parentID) {
                line += " · \(SessionPopoverDefaults.sideChatPrefix) \(parent.displayTitle)"
            }

            agentLine = line
            agentIcon = session.kind.icon

            let folderPath = ProjectStore.shared.project(forSessionID: session.id)?.folderPath
            path = folderPath ?? ""
            // The session's own record first: a dormant session belongs to the branch it
            // ran on, not whatever the checkout has moved to since.
            branch = session.branch ?? folderPath.flatMap { GitInfo.currentBranch(for: $0) }
            worktree = folderPath.flatMap { GitInfo.worktreeName(for: $0) }

            switch activity {
            case .dormant:
                stateText = SessionPopoverDefaults.dormantState
                stateSymbol = SessionPopoverDefaults.dormantSymbol
            case .working:
                stateText = SessionPopoverDefaults.workingState
                stateSymbol = SessionPopoverDefaults.workingSymbol
            case .awaitingUser:
                stateText = SessionPopoverDefaults.waitingState
                stateSymbol = SessionPopoverDefaults.waitingSymbol
            case .needsAttention:
                stateText = SessionPopoverDefaults.finishedState
                stateSymbol = SessionPopoverDefaults.finishedSymbol
            case .idle:
                stateText = SessionPopoverDefaults.runningState
                stateSymbol = SessionPopoverDefaults.runningSymbol
            }
        }
    }

    // MARK: - Properties

    private let info: Info
    private let isEmbedded: Bool

    // MARK: - Initialization

    init(info: Info, isEmbedded: Bool = false) {
        self.info = info
        self.isEmbedded = isEmbedded
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
        if !isEmbedded {
            rows.edgeInsets = NSEdgeInsets(
                top: Design.Spacing.inset,
                left: Design.Spacing.inset,
                bottom: Design.Spacing.inset,
                right: Design.Spacing.inset
            )
        }

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
            container.widthAnchor.constraint(
                equalToConstant: isEmbedded
                    ? SessionPopoverDefaults.contentWidth
                    : SessionPopoverDefaults.width
            )
        ])

        view = container
    }

    // MARK: - Private Methods

    private func makeRows() -> [NSView] {
        // The full title leads: it is the one thing the row itself cannot always show.
        let title = NSTextField(wrappingLabelWithString: info.title)
        title.applyFont(.control)
        title.textColor = Design.Text.label
        title.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rows: [NSView] = [title]

        rows.append(row(icon: info.agentIcon, text: info.agentLine, emphasis: .secondary))

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

    @MainActor
    private enum Emphasis {
        case secondary, muted

        var color: NSColor {
            self == .secondary ? Design.Text.secondary : Design.Text.tertiary
        }
    }

    private func row(symbol: String, text: String, emphasis: Emphasis) -> NSView {
        row(
            icon: NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
            text: text,
            emphasis: emphasis
        )
    }

    private func row(icon image: NSImage?, text: String, emphasis: Emphasis) -> NSView {
        let icon = NSImageView()
        icon.image = image
        icon.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        icon.contentTintColor = Design.Text.secondary
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.iconSlotWidth).isActive = true

        let label = NSTextField(labelWithString: text)
        label.applyFont(.subheading)
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
    static let contentWidth = width - 2 * Design.Spacing.inset
    static let iconSlotWidth: CGFloat = 14

    static let folderSymbol = "folder"
    static let branchSymbol = "arrow.triangle.branch"

    /// Precedes the parent's title on a side chat's agent line.
    static var sideChatPrefix: String { L10n.string("forked from") }

    static var dormantState: String { L10n.string("Dormant · resumable") }
    static let dormantSymbol = "moon.zzz"
    static var workingState: String { L10n.string("Working") }
    static let workingSymbol = "play.circle"
    static var runningState: String { L10n.string("Running") }
    static let runningSymbol = "pause.circle"
    static var waitingState: String { L10n.string("Waiting for an answer") }
    static let waitingSymbol = "questionmark.circle"
    static var finishedState: String { L10n.string("Finished · not yet seen") }
    static let finishedSymbol = "checkmark.circle"

    static func worktreeBranchLabel(_ branch: String, _ worktree: String) -> String {
        "\(branch) · worktree \(worktree)"
    }

    /// Hover dwell before the popover opens, so it does not flash while the pointer crosses
    /// rows on its way somewhere else.
    static let hoverDelay: TimeInterval = 0.35

    /// Both sidebar hover cards: wait out the dwell, then close the instant the pointer leaves
    /// the row. The card is a reading with nothing to click, so there is no gap worth
    /// crossing and no grace to cross it under.
    static let hoverPolicy = HoverPopoverScheduler.Policy(
        openDelay: hoverDelay,
        closeGrace: 0,
        holdsWhilePointerOnPopover: false
    )
}
