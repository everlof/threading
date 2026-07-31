import AppKit

/// The walkthrough's third page: every conversation the discovered accounts hold, grouped by
/// the checkout it ran in, with the last two days pre-checked.
///
/// Continue performs the import — each group whose conversations are checked becomes (or
/// reuses) a project at its folder, and the checked conversations are adopted resumable, the
/// same records `ProjectStore.importSession` has always written. Skip performs nothing; every
/// conversation stays importable later from its project's composer.
final class OnboardingImportPageViewController: NSViewController, OnboardingPage {

    private enum Layout {
        static let contentWidth: CGFloat = 620
        static let iconSide: CGFloat = 16
        static let listHeight: CGFloat = 300
    }

    var pageTitle: String { L10n.string("Conversations") }
    var skipTitle: String? { L10n.string("Skip for now") }

    private static let relativeDate = RelativeDateTimeFormatter()

    /// One group's live selection state.
    @MainActor
    private final class Group {
        let data: DiscoveredProjectImports
        var header: ThemedCheckbox?
        var rows: [(session: ImportableSession, checkbox: ThemedCheckbox)] = []

        init(data: DiscoveredProjectImports) {
            self.data = data
        }

        var selected: [ImportableSession] {
            rows.filter { $0.checkbox.state == .on }.map(\.session)
        }
    }

    private var groups: [Group] = []
    private var scanResult: GlobalScanResult?
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let listHost = NSView()

    override func loadView() {
        view = NSView()
        setupViews()
    }

    func pageWillAppear() {
        guard scanResult == nil else { return }
        GlobalSessionScan.discover { [weak self] result in
            self?.apply(result: result)
        }
    }

    /// The scan's landing point — internal so a render test can put a known result on screen
    /// without a disk full of fixtures.
    func apply(result: GlobalScanResult) {
        scanResult = result
        rebuildList()
    }

    /// The import itself. On the main actor throughout: `addProject` dedups by path, and the
    /// batch adoption saves once per group rather than once per conversation.
    func pageWillContinue() {
        for group in groups {
            let selected = group.selected
            guard !selected.isEmpty else { continue }

            let project = ProjectStore.shared.addProject(
                folderURL: URL(fileURLWithPath: group.data.folder)
            )
            ProjectStore.shared.importSessions(selected, into: project.id)
        }
    }

    private func setupViews() {
        let heading = NSTextField(
            labelWithString: L10n.string("Bring your conversations along")
        )
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        summaryLabel.applyFont(.body)
        summaryLabel.textColor = Design.Text.secondary
        summaryLabel.alignment = .center

        listHost.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [heading, summaryLabel, listHost])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        stack.setCustomSpacing(Design.Spacing.large, after: summaryLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            summaryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth),
            listHost.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            listHost.heightAnchor.constraint(equalToConstant: Layout.listHeight)
        ])

        rebuildList()
    }

    // MARK: - List

    private func rebuildList() {
        listHost.subviews.forEach { $0.removeFromSuperview() }

        guard let result = scanResult else {
            summaryLabel.stringValue = L10n.string("Looking through your past conversations…")
            let spinner = ThemedSpinner()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            listHost.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: listHost.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: listHost.centerYAnchor)
            ])
            return
        }

        let now = Date()
        groups = result.groups.map(Group.init)

        guard !groups.isEmpty else {
            summaryLabel.stringValue = L10n.string(
                "No conversations to import — everything starts fresh."
            )
            return
        }

        let sections: [NSView] = groups.map { group in
            let rows = [headerRow(for: group)] + group.data.conversations.map { session in
                conversationRow(for: session, in: group, now: now)
            }
            return SettingsCard(rows: rows)
        }

        let column = NSStackView(views: sections)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.inset
        column.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        // The settings-page scroll shape: a flipped document so the first group sits at the
        // top, themed scrollers, no background of its own.
        let document = SettingsFlippedView()
        document.addSubview(column)

        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        listHost.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listHost.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: Design.Size.glowGutter
            ),
            column.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -Design.Size.glowGutter
            ),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        refreshSummary()
    }

    private func headerRow(for group: Group) -> NSView {
        let folderName = (group.data.folder as NSString).lastPathComponent
        let header = ThemedCheckbox(
            title: folderName,
            accessibility: L10n.format("Include conversations in %@", folderName)
        ) { [weak self, weak group] state in
            guard let group else { return }
            for row in group.rows {
                row.checkbox.state = state
            }
            self?.refreshSummary()
        }
        group.header = header

        let path = NSTextField(
            labelWithString: (group.data.folder as NSString).abbreviatingWithTildeInPath
        )
        path.applyFont(.caption)
        path.textColor = Design.Text.tertiary
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [header, path])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small

        return SettingsUI.fullRow(content)
    }

    private func conversationRow(
        for session: ImportableSession,
        in group: Group,
        now: Date
    ) -> NSView {
        let checkbox = ThemedCheckbox(
            title: session.title,
            state: GlobalSessionScan.isPrechecked(session, now: now) ? .on : .off
        ) { [weak self, weak group] _ in
            guard let self, let group else { return }
            self.refreshHeader(of: group)
            self.refreshSummary()
        }
        group.rows.append((session, checkbox))

        let icon = NSImageView()
        icon.image = session.kind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSide)
        ])

        let when = NSTextField(
            labelWithString: Self.relativeDate.localizedString(
                for: session.lastActiveAt,
                relativeTo: now
            )
        )
        when.applyFont(.caption)
        when.textColor = Design.Text.tertiary

        checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [checkbox, icon, when])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small

        return SettingsUI.fullRow(content)
    }

    private func refreshHeader(of group: Group) {
        let states = group.rows.map(\.checkbox.state)
        let onCount = states.filter { $0 == .on }.count
        group.header?.state = onCount == 0 ? .off : (onCount == states.count ? .on : .mixed)
    }

    private func refreshSummary() {
        guard let result = scanResult else { return }

        let total = groups.reduce(0) { $0 + $1.data.conversations.count }
        let selected = groups.reduce(0) { $0 + $1.selected.count }
        for group in groups {
            refreshHeader(of: group)
        }

        var summary = L10n.format(
            "%lld conversations in %lld folders — %lld selected to import.",
            Int64(total),
            Int64(groups.count),
            Int64(selected)
        )
        if result.missingFolderConversations > 0 {
            summary += " " + L10n.format(
                "%lld more ran in folders that no longer exist and were left out.",
                Int64(result.missingFolderConversations)
            )
        }
        summaryLabel.stringValue = summary
    }
}
