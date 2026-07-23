import AppKit

// MARK: - Storage Preferences

/// The Storage page: build output the projects can rebuild, and the button that removes it.
///
/// Grouped **by checkout rather than by project**, because that is where the surprise lives. On
/// the machine this was built for, four projects held 79.5 GB of reclaimable output and 58 GB of
/// it sat in git worktrees — abandoned branches each carrying a full `target/` and their own copy
/// of `node_modules`, none of it visible from the folders anyone actually opens.
///
/// Built from the settings kit like `ArchivedPreferencesViewController`, and for the same
/// reason: every row carries its own action, so there is no selection state to maintain and no
/// footer button bar. "Clean everything" is a row of its own rather than a mode.
///
/// Each row states what removing it costs — the command that brings it back, and how long ago it
/// was last written. An artifact built minutes ago is one somebody is using; one last touched in
/// March is not.
final class StoragePreferencesViewController: NSViewController {

    // MARK: - Properties

    /// One checkout's findings — a project's own folder, or one of its worktrees.
    ///
    /// The **checkout** is the grouping rather than the project, because a project's build
    /// output is spread across every worktree it has and the path alone does not say which:
    /// six of these checkouts hold a `web/node_modules`, and a row reading `web/node_modules`
    /// under a heading reading `sonda` names none of them.
    private struct CheckoutGroup {
        let project: Project
        let label: String
        let path: String
        let artifacts: [ReclaimableArtifact]

        var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    }

    /// Findings by checkout, largest first, read from the cache the service keeps.
    private var groups: [CheckoutGroup] = []

    /// Checkouts whose sub-gigabyte rows the user has unfolded, by path. A checkout of a
    /// codebase collects dozens of tiny `__pycache__` directories, which buried the two that
    /// mattered under a page of noise — so anything under a gigabyte folds into one row until
    /// asked for. Kept for the session only; the fold is a view state, not a preference.
    private var expandedCheckouts: Set<String> = []
    private let appEvents = AppEventObservations()

    private var isScanning: Bool { ArtifactScanService.shared.isScanning }

    private static let size: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var totalBytes: Int64 {
        groups.reduce(0) { $0 + $1.byteCount }
    }

    private var allArtifacts: [ReclaimableArtifact] {
        groups.flatMap(\.artifacts)
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(ArtifactScanDidChange.self) { [weak self] _ in
            self?.reload()
        }
    }

    /// Draws what is already known, then asks for anything stale to be measured again.
    ///
    /// The page never scans on the way in. Finding 45 directories means walking every other
    /// directory in four projects first — over a minute here — and paying that on each visit
    /// would mean the page is empty every time it opens, for numbers that barely move between
    /// builds. `ArtifactScanService` keeps them from launch to launch instead.
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        ArtifactScanService.shared.refreshStaleProjects()
    }

    // MARK: - Reading

    /// Rebuilds from the cache, whether it changed because a scan landed or because something
    /// was removed.
    private func reload() {
        groups = ProjectStore.shared.projects.flatMap { project in
            Self.group(ArtifactScanService.shared.artifacts(for: project.id), of: project)
        }
        .sorted { $0.byteCount > $1.byteCount }

        rebuild()
    }

    /// Splits a project's findings by the checkout each belongs to, and names each one.
    ///
    /// The name is the worktree's, else the branch the checkout stands on — a worktree is
    /// recognisable by its name, while the project's own folder is best identified by what it
    /// has checked out. Runs off the main queue with the scan, since both read git.
    private static func group(
        _ artifacts: [ReclaimableArtifact],
        of project: Project
    ) -> [CheckoutGroup] {
        Dictionary(grouping: artifacts, by: \.checkoutPath)
            .map { path, artifacts in
                CheckoutGroup(
                    project: project,
                    label: GitInfo.worktreeName(for: path)
                        ?? GitInfo.currentBranch(for: path)
                        ?? URL(fileURLWithPath: path).lastPathComponent,
                    path: path,
                    artifacts: artifacts.sorted { $0.byteCount > $1.byteCount }
                )
            }
            .sorted { $0.byteCount > $1.byteCount }
    }

    // MARK: - Build

    /// Rebuilds the page wholesale, as the other settings pages do: the list is short, and a
    /// fresh build keeps every button's tag in step with `findings`.
    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }

        var sections: [NSView] = [
            SettingsUI.heading(StorageStrings.title),
            SettingsUI.note(StorageStrings.explanation),
            summarySection()
        ]

        for (index, group) in groups.enumerated() {
            sections.append(checkoutSection(group, groupIndex: index))
        }

        if !isScanning, groups.isEmpty {
            sections.append(SettingsUI.note(StorageStrings.empty))
        }

        sections.append(SettingsUI.note(StorageStrings.safety))

        let page = SettingsUI.page(sections)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The total, sized like the page's own heading — it is the number the page exists to
    /// report, and the one thing worth reading from across the room.
    private func summarySection() -> NSView {
        let total = NSTextField(labelWithString: Self.size.string(fromByteCount: totalBytes))
        total.font = Design.Typography.heading()
        total.textColor = totalBytes > 0 ? Design.Text.label : Design.Text.secondary

        let caption = NSTextField(labelWithString: summaryCaption())
        caption.font = Design.Typography.subheading()
        caption.textColor = Design.Text.secondary

        let labels = NSStackView(views: [total, caption])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let actions = NSStackView(views: [
            SettingsUI.button(StorageStrings.rescan, target: self, action: #selector(rescanClicked))
        ])
        actions.orientation = .horizontal
        actions.spacing = Design.Spacing.small

        if totalBytes > 0 {
            let removeAll = SettingsUI.button(
                StorageStrings.removeEverything,
                target: self,
                action: #selector(removeEverythingClicked)
            )
            actions.addArrangedSubview(removeAll)
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(actions)

        return SettingsUI.section(nil, SettingsCard(rows: [SettingsUI.fullRow(row)]))
    }

    /// What the number underneath the total means, which is not the same sentence twice.
    ///
    /// A cached reading has to say **when** it was true, or it quietly claims to be live. The
    /// page shows numbers measured up to an hour ago and would otherwise look identical whether
    /// the disk was read a second or a day before.
    private func summaryCaption() -> String {
        if isScanning {
            return StorageStrings.scanning
        }

        let count = allArtifacts.count
        guard count > 0 else { return StorageStrings.nothingFound }

        let projectIDs = ProjectStore.shared.projects.map(\.id)
        guard let measured = ArtifactScanService.shared.oldestScan(among: projectIDs) else {
            return StorageStrings.reclaimable(count: count)
        }

        var caption = StorageStrings.reclaimable(count: count)
            + " · "
            + StorageStrings.measured(
                Self.relativeDate.localizedString(for: measured, relativeTo: Date())
            )

        // What the total is worth depends entirely on the room left: 87 GB reclaimable means
        // something different beside 14 GB free than beside 800 GB.
        if let disk = DiskSpace.homeReading() {
            caption += " · " + StorageStrings.free(
                Self.size.string(fromByteCount: disk.available),
                pressured: disk.isUnderPressure
            )
        }

        return caption
    }

    /// One checkout: its big artifacts as their own rows, everything under a gigabyte folded
    /// into one, closed by a row that removes the lot.
    ///
    /// The heading carries the project *and* the checkout, because the checkout is the answer to
    /// "which of these is it"; the full path sits beneath it, because a worktree name alone does
    /// not say where on disk it lives, and that is what someone about to delete gigabytes wants
    /// to confirm.
    private func checkoutSection(_ group: CheckoutGroup, groupIndex: Int) -> NSView {
        // Enumerated over the *original* order, so a row's tag still indexes `group.artifacts`
        // however the rows are then partitioned for display.
        let indexed = Array(group.artifacts.enumerated())
        let large = indexed.filter { $0.element.byteCount >= StorageDefaults.collapseThreshold }
        let small = indexed.filter { $0.element.byteCount < StorageDefaults.collapseThreshold }

        var rows: [NSView] = large.map { index, artifact in
            row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
        }

        if !small.isEmpty {
            let expanded = expandedCheckouts.contains(group.path)
            if expanded {
                rows += small.map { index, artifact in
                    row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
                }
            }
            rows.append(foldRow(for: small.map(\.element), in: group, expanded: expanded))
        }

        if group.artifacts.count > 1 {
            let button = SettingsUI.button(
                StorageStrings.removeAll,
                target: self,
                action: #selector(removeCheckoutClicked(_:))
            )
            button.tag = tag(group: groupIndex, artifact: StorageDefaults.wholeGroupTag)
            rows.append(SettingsUI.row(
                title: StorageStrings.everythingHere,
                subtitle: StorageStrings.rebuiltOnDemand,
                control: button
            ))
        }

        let title = "\(group.project.name) · \(group.label)"
            + " · \(Self.size.string(fromByteCount: group.byteCount))"
        return pathSection(title: title, path: group.path, card: SettingsCard(rows: rows))
    }

    /// A section whose heading is followed by the checkout's full path — abbreviated at the home
    /// directory, truncated in the middle so both ends survive a long worktree path.
    private func pathSection(title: String, path: String, card: NSView) -> NSView {
        let pathLabel = NSTextField(labelWithString: abbreviate(path))
        pathLabel.font = Design.Typography.subheading()
        pathLabel.textColor = Design.Text.tertiary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [SettingsUI.caption(title), pathLabel, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight

        for pinned in [pathLabel, card] {
            pinned.translatesAutoresizingMaskIntoConstraints = false
            pinned.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            pinned.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        return stack
    }

    /// The row that stands in for everything under a gigabyte, and unfolds it on a click.
    ///
    /// It reads like a data row so the size column stays aligned — a count and a total where a
    /// name and a size would be — with a chevron in place of a Remove button, since the whole
    /// row is the control.
    private func foldRow(
        for artifacts: [ReclaimableArtifact],
        in group: CheckoutGroup,
        expanded: Bool
    ) -> NSView {
        let total = artifacts.reduce(0) { $0 + $1.byteCount }

        let size = NSTextField(labelWithString: Self.size.string(fromByteCount: total))
        size.font = .monospacedDigitSystemFont(ofSize: StorageDefaults.sizeFontSize, weight: .regular)
        size.textColor = Design.Text.secondary
        size.alignment = .right

        let chevron = NSImageView()
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )
        chevron.contentTintColor = Design.Text.tertiary
        chevron.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.chevron)

        let trailing = NSStackView(views: [size, chevron])
        trailing.orientation = .horizontal
        trailing.spacing = Design.Spacing.medium

        let content = SettingsUI.row(
            title: expanded
                ? StorageStrings.showFewer
                : StorageStrings.smallerDirectories(artifacts.count),
            subtitle: expanded ? nil : StorageStrings.underAGigabyte,
            control: trailing
        )

        let path = group.path
        return ClickableRow(content: content) { [weak self] in
            guard let self else { return }
            if self.expandedCheckouts.contains(path) {
                self.expandedCheckouts.remove(path)
            } else {
                self.expandedCheckouts.insert(path)
            }
            self.rebuild()
        }
    }

    /// Replaces the home directory with `~`, so a path is read for its shape rather than its
    /// first forty identical characters.
    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// One artifact: what it is, where it is, what it costs to bring back, and how stale it is.
    private func row(for artifact: ReclaimableArtifact, in group: CheckoutGroup, tag: Int) -> NSView {
        let button = SettingsUI.button(
            StorageStrings.remove,
            target: self,
            action: #selector(removeArtifactClicked(_:))
        )
        button.tag = tag

        let size = NSTextField(labelWithString: Self.size.string(fromByteCount: artifact.byteCount))
        // Monospaced digits so the sizes form a column instead of jittering row to row.
        size.font = .monospacedDigitSystemFont(ofSize: StorageDefaults.sizeFontSize, weight: .regular)
        size.textColor = Design.Text.secondary
        size.alignment = .right

        let trailing = NSStackView(views: [size, button])
        trailing.orientation = .horizontal
        trailing.spacing = Design.Spacing.medium

        return SettingsUI.row(
            title: artifact.url.path.replacingOccurrences(of: group.path + "/", with: ""),
            subtitle: caption(for: artifact),
            control: trailing
        )
    }

    private func caption(for artifact: ReclaimableArtifact) -> String {
        var parts = [artifact.kind.displayName, artifact.kind.rebuildHint]
        if let modifiedAt = artifact.modifiedAt {
            let age = Self.relativeDate.localizedString(for: modifiedAt, relativeTo: Date())
            parts.append(artifact.isInUse() ? StorageStrings.inUse(age) : StorageStrings.built(age))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tags

    /// Buttons carry their row's coordinates, so an action maps straight back to `groups`
    /// without the page holding a second index of its own.
    private func tag(group: Int, artifact: Int) -> Int {
        group * StorageDefaults.tagStride + artifact
    }

    private func coordinates(of tag: Int) -> (group: Int, artifact: Int) {
        (tag / StorageDefaults.tagStride, tag % StorageDefaults.tagStride)
    }

    // MARK: - Actions

    @objc private func rescanClicked() {
        ArtifactScanService.shared.refreshAll()
    }

    @objc private func removeArtifactClicked(_ sender: ThemedButton) {
        let position = coordinates(of: sender.tag)
        guard groups.indices.contains(position.group) else { return }

        let group = groups[position.group]
        guard group.artifacts.indices.contains(position.artifact) else { return }

        remove([group.artifacts[position.artifact]], in: [group.project])
    }

    @objc private func removeCheckoutClicked(_ sender: ThemedButton) {
        let position = coordinates(of: sender.tag)
        guard groups.indices.contains(position.group) else { return }

        let group = groups[position.group]
        remove(group.artifacts, in: [group.project])
    }

    @objc private func removeEverythingClicked() {
        remove(allArtifacts, in: groups.map(\.project))
    }

    /// Confirms, removes, and rescans.
    ///
    /// The confirmation names a **running session** in any affected project when there is one:
    /// deleting a `target/` out from under a build in flight is the one way this goes wrong for
    /// somebody who otherwise understood exactly what they asked for.
    private func remove(_ artifacts: [ReclaimableArtifact], in projects: [Project]) {
        guard !artifacts.isEmpty else { return }

        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }
        let busy = projects.filter { project in
            project.sessions.contains { AgentRuntime.shared.isRunning(sessionID: $0.id) }
        }

        // Two independent signs of work in flight, and the second catches what the first
        // cannot: a build running in a worktree Skalman has no session for.
        let inUse = artifacts.filter { $0.isInUse() }

        var warnings: [String] = []
        if !busy.isEmpty {
            warnings.append(StorageStrings.confirmBusy(busy.map(\.name).joined(separator: ", ")))
        }
        if !inUse.isEmpty {
            warnings.append(StorageStrings.confirmInUse(count: inUse.count))
        }

        let alert = NSAlert()
        alert.messageText = StorageStrings.confirmTitle(
            count: artifacts.count,
            size: Self.size.string(fromByteCount: bytes)
        )
        alert.informativeText = ([StorageStrings.confirmBody] + warnings)
            .joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: StorageStrings.remove)
        alert.addButton(withTitle: StorageStrings.cancel)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Deleting walks the directory too, so it never happens on the main thread — but at
        // `.userInitiated`, unlike the passive scan: this one somebody is waiting on.
        DispatchQueue.global(qos: .userInitiated).async {
            var removed = 0
            for artifact in artifacts where ArtifactScanner.remove(artifact) {
                removed += 1
            }

            SkalmanLogger.agent.info(
                "Reclaimed \(removed, privacy: .public) of \(artifacts.count, privacy: .public) artifacts"
            )

            DispatchQueue.main.async {
                // The cache is corrected from what actually went, so the page updates at once;
                // the project is then re-measured, since removing one directory changes the
                // size of nothing else but proves the reading is a moment old.
                for project in projects {
                    ArtifactScanService.shared.forget(artifacts, in: project.id)
                    ArtifactScanService.shared.refresh(project, force: true)
                }
            }
        }
    }
}

// MARK: - Storage Defaults

private enum StorageDefaults {
    /// Comfortably more than any checkout's artifact count, so a tag packs two indices.
    static let tagStride = 10_000

    /// The artifact index meaning "every artifact in this checkout".
    static let wholeGroupTag = tagStride - 1

    /// Matches `Design.Typography.body()`, in its monospaced-digit form.
    static let sizeFontSize: CGFloat = 13

    /// Directories smaller than this fold into one row. A gigabyte is the line between "worth
    /// its own row" and "part of the tail" — a checkout gathers dozens of KB-sized caches, and
    /// they buried the two directories that held the space.
    static let collapseThreshold: Int64 = 1_000_000_000
}

// MARK: - Storage Strings

private enum StorageStrings {
    static let title = "Storage"

    static let explanation = """
        Build output your projects can make again — Rust and Swift build directories, installed \
        packages, caches. Worktrees are included, which is usually where most of it is hiding.
        """

    static let safety = """
        Only directories git ignores and a known tool can rebuild are offered. Anything tracked \
        in a repository is left alone, whatever it is called — and ignored files that are not \
        build output, such as .env files, are never touched. Removal is immediate rather than \
        moved to the Trash, since space in the Trash has not been reclaimed.
        """

    static let empty = "Nothing to reclaim."
    static let nothingFound = "Nothing found to remove"
    static let scanning = "Scanning…"
    static let rescan = "Rescan"
    static let remove = "Remove"
    static let cancel = "Cancel"
    static let removeEverything = "Remove All…"
    static let everythingHere = "Everything above"
    static let rebuiltOnDemand = "Removed together, rebuilt when each project next builds"

    static func reclaimable(count: Int) -> String {
        count == 1 ? "1 directory can be removed" : "\(count) directories can be removed"
    }

    static let removeAll = "Remove All…"
    static let showFewer = "Show fewer"
    static let underAGigabyte = "Under 1 GB — click to show each"

    static func smallerDirectories(_ count: Int) -> String {
        count == 1 ? "1 smaller directory" : "\(count) smaller directories"
    }

    /// When the reading was taken. A cached number that does not say its age claims to be live.
    static func measured(_ relative: String) -> String {
        "measured \(relative)"
    }

    /// Room left on the disk, marked when it is short — the context that turns the total from a
    /// number into a decision.
    static func free(_ size: String, pressured: Bool) -> String {
        pressured ? "only \(size) free" : "\(size) free"
    }

    static func built(_ relative: String) -> String {
        "last written \(relative)"
    }

    /// Written moments ago, which almost always means a build is running in it.
    static func inUse(_ relative: String) -> String {
        "in use — written \(relative)"
    }

    static func confirmInUse(count: Int) -> String {
        count == 1
            ? "One of these was written in the last few minutes, so something is probably "
                + "building in it right now. Removing it will interrupt that build."
            : "\(count) of these were written in the last few minutes, so something is probably "
                + "building in them right now. Removing them will interrupt those builds."
    }

    static func confirmTitle(count: Int, size: String) -> String {
        count == 1
            ? "Remove this directory and reclaim \(size)?"
            : "Remove \(count) directories and reclaim \(size)?"
    }

    static let confirmBody = """
        They will be deleted immediately, not moved to the Trash. Each one is rebuilt by the \
        command shown beside it, which takes time but no decisions.
        """

    static func confirmBusy(_ projects: String) -> String {
        "A session is running in \(projects). If it is building right now, removing its build "
            + "output will interrupt that build."
    }
}

// MARK: - Clickable Row

/// Wraps a row so a click anywhere on it fires a callback — for the fold row, whose whole
/// surface is the control rather than a button at its edge.
private final class ClickableRow: NSView {

    private let handler: () -> Void

    init(content: NSView, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A pointing hand, so the row reads as clickable before it is clicked.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func clicked() {
        handler()
    }
}
