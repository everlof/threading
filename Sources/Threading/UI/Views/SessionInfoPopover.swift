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
        let handoffLine: String?
        let roleLine: String?
        let path: String
        let branch: String?
        /// The linked worktree's name, or nil for an ordinary checkout.
        let worktree: String?

        /// A sound this chat does not inherit, or nil — the common case. The session row keeps
        /// no tooltip of its own, so this card is the one hover surface where an overridden
        /// chat is identifiable without opening a menu. Same rule as the project row's tooltip:
        /// presentation is not status, and the row itself acquires no decoration for it.
        let soundLine: String?

        /// How this chat behaves differently from the ones around it — it continues at its
        /// reset, or it stays quiet when it finishes. Unlike the sound above, the row *does*
        /// carry a mark for this, and this line is what the mark means: a silhouette can say
        /// "configured" and nothing else, so the card is where it is spelled out.
        let conductLine: String?
        let stateText: String
        let stateSymbol: String

        /// Why a dormant session is dormant, where this launch's own decision is still the
        /// answer, and where that decision is made.
        ///
        /// Nil for a live session, and nil for one whose agent has since exited: the launch
        /// ledger forgets a session the moment it runs, so the card never blames a setting for
        /// something the setting did not do. "Dormant" alone was true and unhelpful — the state
        /// is the one thing a user cannot act on without knowing which rule produced it.
        let dormancyReason: String?

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
            if let handoff = session.handoff {
                var stops = handoff.endpoints.map(\.displayName)
                if handoff.omittedEndpointCount > 0, !stops.isEmpty {
                    stops.insert("… +\(handoff.omittedEndpointCount)", at: min(1, stops.count))
                }
                handoffLine = stops.joined(separator: " → ")
            } else {
                handoffLine = nil
            }

            let supervision = ControlGrantStore.shared.overview(for: session.id)
            if ControlGrantStore.shared.isManager(session.id) {
                let activities = supervision.children.map { AgentRuntime.shared.activity(sessionID: $0) }
                let working = activities.filter(\.hasTurnInFlight).count
                let waiting = activities.filter { $0 == .awaitingUser || $0 == .needsAttention }.count
                let detail = [
                    working > 0 ? L10n.format("%lld working", Int64(working)) : nil,
                    waiting > 0 ? L10n.format("%lld waiting", Int64(waiting)) : nil,
                ].compactMap { $0 }.joined(separator: ", ")
                let count = supervision.children.count
                roleLine = count == 0
                    ? L10n.string("Manages no chats yet")
                    : L10n.format(
                        "Manages %lld chats%@",
                        Int64(count),
                        detail.isEmpty ? "" : " · \(detail)"
                    )
            } else if let managerID = supervision.managedBy,
                      let manager = ProjectStore.shared.session(withID: managerID) {
                let brief = supervision.brief?
                    .split(whereSeparator: \.isNewline).first.map(String.init)
                roleLine = [L10n.format("Managed by %@", manager.displayTitle), brief]
                    .compactMap { $0 }.joined(separator: " · ")
            } else {
                roleLine = nil
            }

            let project = ProjectStore.shared.executionProject(forSessionID: session.id)
            let folderPath = project?.folderPath
            path = folderPath ?? ""
            // The session's own record first: a dormant session belongs to the branch it
            // ran on, not whatever the checkout has moved to since.
            branch = session.branch ?? folderPath.flatMap { GitInfo.currentBranch(for: $0) }
            worktree = folderPath.flatMap { GitInfo.worktreeName(for: $0) }

            soundLine = SoundOverrideAudit.toolTipLine(
                for: .session(session.id),
                overrides: session.soundOverrides
            )
            conductLine = RowConductSummary.forSession(session)?.sentence

            dormancyReason = activity == .dormant
                ? SessionRestorationLedger.shared.outcome(for: session.id)
                    .flatMap(SessionPopoverDefaults.dormancyReason(for:))
                : nil

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
            case .limitReached:
                // Read from what has already been scanned rather than re-read here: the card
                // is built while the pointer rests on a row, and the mark it is explaining was
                // raised by the same reading. A session whose stop is not in memory still says
                // it stopped — the state is the row's, the hint is a detail.
                let hint = project.flatMap {
                    ObservedUsageLimit.known(for: session, in: $0)?.resetHint
                }
                stateText = hint.map(SessionPopoverDefaults.limitState(resetHint:))
                    ?? SessionPopoverDefaults.limitState
                stateSymbol = SessionPopoverDefaults.limitSymbol
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

        if let handoffLine = info.handoffLine {
            rows.append(wrappingRow(
                symbol: SessionPopoverDefaults.handoffSymbol,
                classicGlyph: .handoff,
                text: handoffLine
            ))
        }

        if let roleLine = info.roleLine {
            rows.append(wrappingRow(
                symbol: "person.3",
                classicGlyph: .status,
                text: roleLine
            ))
        }

        if !info.path.isEmpty {
            rows.append(row(
                symbol: SessionPopoverDefaults.folderSymbol,
                classicGlyph: .folder,
                text: abbreviated(info.path),
                emphasis: .secondary
            ))
        }

        if let branch = info.branch {
            let text = info.worktree.map { SessionPopoverDefaults.worktreeBranchLabel(branch, $0) } ?? branch
            rows.append(row(
                symbol: SessionPopoverDefaults.branchSymbol,
                classicGlyph: .branch,
                text: text,
                emphasis: .secondary
            ))
        }

        // Beside the branch rather than under the state: a sound the chat carries is
        // configuration, like the checkout it runs in, not a condition it is in.
        if let soundLine = info.soundLine {
            rows.append(row(
                symbol: SessionPopoverDefaults.soundSymbol,
                classicGlyph: .status,
                text: soundLine,
                emphasis: .secondary
            ))
        }

        // Beside the sound, for the same reason it is beside the branch: both are what this chat
        // was set to, read together, above the state it happens to be in.
        if let conductLine = info.conductLine {
            rows.append(row(
                symbol: RowConductDefaults.symbol,
                classicGlyph: .status,
                text: conductLine,
                emphasis: .secondary
            ))
        }

        rows.append(row(
            symbol: info.stateSymbol,
            classicGlyph: .status,
            text: info.stateText,
            emphasis: .muted
        ))

        // Under the state, not instead of it: the state is what the row is, and this is why.
        if let dormancyReason = info.dormancyReason {
            rows.append(wrappingRow(
                symbol: SessionPopoverDefaults.restoreSymbol,
                classicGlyph: .status,
                text: dormancyReason
            ))
        }

        return rows
    }

    @MainActor
    private enum Emphasis {
        case secondary, muted

        var color: NSColor {
            self == .secondary ? Design.Text.secondary : Design.Text.tertiary
        }
    }

    private func row(
        symbol: String,
        classicGlyph: ThemedFloatingGlyphView.ClassicGlyph,
        text: String,
        emphasis: Emphasis
    ) -> NSView {
        row(
            icon: ThemedFloatingGlyphView(
                systemSymbolName: symbol,
                classicGlyph: classicGlyph
            ),
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
        return row(iconView: icon, text: text, emphasis: emphasis)
    }

    private func row(
        icon: ThemedFloatingGlyphView,
        text: String,
        emphasis: Emphasis
    ) -> NSView {
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.iconSlotWidth).isActive = true

        return row(iconView: icon, text: text, emphasis: emphasis)
    }

    private func row(iconView icon: NSView, text: String, emphasis: Emphasis) -> NSView {
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

    private func wrappingRow(
        symbol: String,
        classicGlyph: ThemedFloatingGlyphView.ClassicGlyph,
        text: String
    ) -> NSView {
        let icon = ThemedFloatingGlyphView(
            systemSymbolName: symbol,
            classicGlyph: classicGlyph
        )
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: SessionPopoverDefaults.iconSlotWidth).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        label.preferredMaxLayoutWidth = SessionPopoverDefaults.contentWidth
            - SessionPopoverDefaults.iconSlotWidth
            - Design.Spacing.small
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .top
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
    /// The hover card's line for a sound the chat does not inherit — the same speaker the
    /// Sounds submenu wears.
    static let soundSymbol = "speaker.wave.2"
    static let handoffSymbol = "arrow.left.arrow.right"

    /// Precedes the parent's title on a side chat's agent line.
    static var sideChatPrefix: String { L10n.string("forked from") }

    static var dormantState: String { L10n.string("Dormant · resumable") }
    static let dormantSymbol = "moon.zzz"
    static let restoreSymbol = "arrow.clockwise"
    static var workingState: String { L10n.string("Working") }
    static let workingSymbol = "play.circle"
    static var runningState: String { L10n.string("Running") }
    static let runningSymbol = "pause.circle"
    static var waitingState: String { L10n.string("Waiting for an answer") }
    static let waitingSymbol = "questionmark.circle"
    static var finishedState: String { L10n.string("Finished · not yet seen") }
    static let finishedSymbol = "checkmark.circle"
    static var limitState: String { L10n.string("Stopped · usage limit reached") }
    static let limitSymbol = "exclamationmark.triangle"

    /// The provider's own words about when it lifts, appended to the state line.
    ///
    /// Quoted rather than reformatted: Claude states a wall clock in the *account's* zone with
    /// no date (`1:20pm (Europe/Rome)`), and rewriting that into the Mac's locale would produce
    /// a time the provider never promised. See `UsageLimitStop`.
    static func limitState(resetHint: String) -> String {
        L10n.format("Stopped · usage limit resets %@", resetHint)
    }

    static func worktreeBranchLabel(_ branch: String, _ worktree: String) -> String {
        "\(branch) · worktree \(worktree)"
    }

    /// Where launch restore is decided, appended to every reason below.
    ///
    /// The reason without it states a rule the reader has no way to find; naming the page is what
    /// turns the card from an explanation into something they can act on.
    static var restoreSettingHint: String {
        L10n.string("Settings ▸ General decides what comes back at launch.")
    }

    /// One sentence for why a dormant session was not brought back, plus where to change it.
    ///
    /// Nil for a session that *was* restored: it is live, and the card is already saying so.
    static func dormancyReason(for outcome: SessionRestorationOutcome) -> String? {
        // The one answer launch restore did not decide: the background host kept this session
        // running past the quit, and it is dormant now because it ended, not because a rule
        // turned it away. Pointing at the restore page would point at a setting that had no say.
        if case .reattached = outcome { return backgroundHostReason }
        guard let reason = reasonSentence(for: outcome) else { return nil }
        return "\(reason) \(restoreSettingHint)"
    }

    /// Said for a session `threading-ptyd` was still running when this launch asked.
    static var backgroundHostReason: String {
        L10n.string("It kept running in the background after Threading quit, and has since stopped.")
    }

    private static func reasonSentence(for outcome: SessionRestorationOutcome) -> String? {
        switch outcome {
        case .restored, .reattached:
            return nil

        case .restoreDisabled:
            return L10n.string("Launch restore is switched off.")

        case .notRunningAtLastQuit:
            return L10n.string("It was not running when Threading last quit.")

        case .nothingRecorded:
            return L10n.string("The last quit left no record of what was running.")

        case .outsideWindow(let days, let lastUsedAt):
            return L10n.format(
                "Last used %@, outside the %@ restore window.",
                relativeDate.localizedString(for: lastUsedAt, relativeTo: Date()),
                windowLength(days: days)
            )

        case .beyondLimit(let limit):
            // Numerals rather than a count of sessions, which would need plural agreement in
            // every language for a number the user chose themselves.
            return L10n.format(
                "Inside the restore window, past the limit of %d.",
                limit
            )
        }
    }

    /// "1 day", "3 days", localized by the system rather than by a plural rule of ours.
    private static func windowLength(days: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day]
        formatter.unitsStyle = .full
        let seconds = Double(days) * SessionRestoreDefaults.secondsPerDay
        return formatter.string(from: seconds) ?? "\(days)"
    }

    private static var relativeDate: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
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
