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

    /// Checkouts whose cards the user has unfolded, by path. Collapsed, a checkout is one row —
    /// name, path and size — which is the table the page's numbers actually want to be read as;
    /// the artifact rows are detail. Kept for the session only; a view state, not a preference.
    private var expandedCheckouts: Set<String> = []

    /// Within an unfolded checkout, whose sub-gigabyte tail is open. A checkout of a codebase
    /// collects dozens of tiny `__pycache__` directories, which buried the two that mattered
    /// under a page of noise — so anything under a gigabyte folds into one row until asked for.
    private var expandedTails: Set<String> = []
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
            SettingsUI.note(StorageStrings.explanation)
        ]

        for (index, group) in groups.enumerated() {
            sections.append(checkoutSection(group, groupIndex: index))
        }

        if !isScanning, groups.isEmpty {
            sections.append(SettingsUI.note(StorageStrings.empty))
        }

        sections.append(SettingsUI.note(StorageStrings.safety))

        var actions: [NSView] = [
            SettingsUI.button(StorageStrings.rescan, target: self, action: #selector(rescanClicked))
        ]
        if totalBytes > 0 {
            actions.append(SettingsUI.button(
                StorageStrings.removeEverything,
                target: self,
                action: #selector(removeEverythingClicked)
            ))
        }

        let page = SettingsUI.page(
            title: "Storage",
            summary: headerSummary(),
            actions: actions,
            sections: sections,
            hostPage: .storage
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The header's one line: the total — the number the page exists to report, kept on screen
    /// however far the list scrolls — then when it was true, then the room left.
    ///
    /// A cached reading has to say **when** it was true, or it quietly claims to be live. The
    /// page shows numbers measured up to an hour ago and would otherwise look identical whether
    /// the disk was read a second or a day before. And what the total is worth depends entirely
    /// on the room left: 87 GB reclaimable means something different beside 14 GB free than
    /// beside 800 GB.
    private func headerSummary() -> String {
        if isScanning {
            return StorageStrings.scanning
        }

        let count = allArtifacts.count
        guard count > 0 else { return StorageStrings.nothingFound }

        var parts = [
            StorageStrings.total(
                Self.size.string(fromByteCount: totalBytes),
                directories: count
            )
        ]

        let projectIDs = ProjectStore.shared.projects.map(\.id)
        if let measured = ArtifactScanService.shared.oldestScan(among: projectIDs) {
            parts.append(StorageStrings.measured(
                Self.relativeDate.localizedString(for: measured, relativeTo: Date())
            ))
        }

        if let disk = DiskSpace.homeReading() {
            parts.append(StorageStrings.free(
                Self.size.string(fromByteCount: disk.available),
                pressured: disk.isUnderPressure
            ))
        }

        return parts.joined(separator: " · ")
    }

    /// One checkout, folded to the row the page's numbers want to be read as: project and
    /// checkout name, the full path beneath, the size trailing, Remove All beside it. Unfolded,
    /// the big artifacts get their own rows and everything under a gigabyte folds again into
    /// one tail row.
    ///
    /// The title carries the project *and* the checkout, because the checkout is the answer to
    /// "which of these is it"; the path sits beneath it, because a worktree name alone does not
    /// say where on disk it lives, and that is what someone about to delete gigabytes wants to
    /// confirm.
    private func checkoutSection(_ group: CheckoutGroup, groupIndex: Int) -> NSView {
        // Enumerated over the *original* order, so a row's tag still indexes `group.artifacts`
        // however the rows are then partitioned for display.
        let indexed = Array(group.artifacts.enumerated())
        let large = indexed.filter { $0.element.byteCount >= StorageDefaults.collapseThreshold }
        let small = indexed.filter { $0.element.byteCount < StorageDefaults.collapseThreshold }

        let expanded = expandedCheckouts.contains(group.path)
        var rows: [NSView] = []
        if expanded {
            rows = large.map { index, artifact in
                row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
            }

            if !small.isEmpty {
                let tailOpen = expandedTails.contains(group.path)
                if tailOpen {
                    rows += small.map { index, artifact in
                        row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
                    }
                }
                rows.append(foldRow(for: small.map(\.element), in: group, expanded: tailOpen))
            }
        }

        let removeAll = SettingsUI.button(
            StorageStrings.removeAll,
            target: self,
            action: #selector(removeCheckoutClicked(_:))
        )
        removeAll.tag = tag(group: groupIndex, artifact: StorageDefaults.wholeGroupTag)

        let path = group.path
        return SettingsUI.disclosureCard(
            title: "\(group.project.name) · \(group.label)",
            subtitle: abbreviate(path),
            summary: Self.size.string(fromByteCount: group.byteCount),
            control: removeAll,
            isExpanded: expanded,
            localizes: false,
            onToggle: { [weak self] nowExpanded in
                guard let self else { return }
                if nowExpanded {
                    self.expandedCheckouts.insert(path)
                } else {
                    self.expandedCheckouts.remove(path)
                }
                self.rebuild()
            },
            detailRows: rows
        )
    }

    /// The row that stands in for everything under a gigabyte, and unfolds it on a click.
    private func foldRow(
        for artifacts: [ReclaimableArtifact],
        in group: CheckoutGroup,
        expanded: Bool
    ) -> NSView {
        let total = artifacts.reduce(0) { $0 + $1.byteCount }
        let path = group.path
        return SettingsUI.disclosureRow(
            title: StorageStrings.smallerDirectories(artifacts.count),
            subtitle: StorageStrings.underAGigabyte,
            summary: Self.size.string(fromByteCount: total),
            isExpanded: expanded,
            localizes: false,
            onToggle: { [weak self] nowOpen in
                guard let self else { return }
                if nowOpen {
                    self.expandedTails.insert(path)
                } else {
                    self.expandedTails.remove(path)
                }
                self.rebuild()
            }
        )
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
        size.applyFont(.numericBody)
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
        // cannot: a build running in a worktree Threading has no session for.
        let inUse = artifacts.filter { $0.isInUse() }

        var warnings: [String] = []
        if !busy.isEmpty {
            warnings.append(StorageStrings.confirmBusy(busy.map(\.name).joined(separator: ", ")))
        }
        if !inUse.isEmpty {
            warnings.append(StorageStrings.confirmInUse(count: inUse.count))
        }

        let request = ConfirmationRequest(
            prompt: .removeReclaimableDirectories,
            title: StorageStrings.confirmTitle(
                count: artifacts.count,
                size: Self.size.string(fromByteCount: bytes)
            ),
            message: ([StorageStrings.confirmBody] + warnings).joined(separator: "\n\n"),
            confirmTitle: StorageStrings.remove,
            cancelTitle: StorageStrings.cancel
        )

        guard ConfirmationAlert.ask(request) else { return }

        // Deleting walks the directory too, so it never happens on the main thread — but at
        // `.userInitiated`, unlike the passive scan: this one somebody is waiting on.
        DispatchQueue.global(qos: .userInitiated).async {
            var removed = 0
            for artifact in artifacts where ArtifactScanner.remove(artifact) {
                removed += 1
            }

            ThreadingLogger.agent.info(
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
    static var title: String { L10n.string("Storage") }

    static var explanation: String {
        L10n.string("""
            Build output your projects can make again — Rust and Swift build directories, installed \
            packages, caches. Worktrees are included, which is usually where most of it is hiding.
            """)
    }

    static var safety: String {
        L10n.string("""
            Only directories git ignores and a known tool can rebuild are offered. Anything tracked \
            in a repository is left alone, whatever it is called — and ignored files that are not \
            build output, such as .env files, are never touched. Removal is immediate rather than \
            moved to the Trash, since space in the Trash has not been reclaimed.
            """)
    }

    static var empty: String { L10n.string("Nothing to reclaim.") }
    static var nothingFound: String { L10n.string("Nothing found to remove") }
    static var scanning: String { L10n.string("Scanning…") }
    static var rescan: String { L10n.string("Rescan") }
    static var remove: String { L10n.string("Remove") }
    static var cancel: String { L10n.string("Cancel") }
    static var removeEverything: String { L10n.string("Remove All…") }

    /// The header's opening clause: the size and the count, one fact.
    static func total(_ size: String, directories count: Int) -> String {
        count == 1
            ? L10n.format("%@ reclaimable in 1 directory", size)
            : L10n.format("%@ reclaimable in %lld directories", size, Int64(count))
    }

    static var removeAll: String { L10n.string("Remove All…") }
    static var underAGigabyte: String {
        L10n.string("Under 1 GB — click to show each")
    }

    static func smallerDirectories(_ count: Int) -> String {
        count == 1
            ? L10n.string("1 smaller directory")
            : L10n.format("%lld smaller directories", Int64(count))
    }

    /// When the reading was taken. A cached number that does not say its age claims to be live.
    static func measured(_ relative: String) -> String {
        L10n.format("measured %@", relative)
    }

    /// Room left on the disk, marked when it is short — the context that turns the total from a
    /// number into a decision.
    static func free(_ size: String, pressured: Bool) -> String {
        pressured
            ? L10n.format("only %@ free", size)
            : L10n.format("%@ free", size)
    }

    static func built(_ relative: String) -> String {
        L10n.format("last written %@", relative)
    }

    /// Written moments ago, which almost always means a build is running in it.
    static func inUse(_ relative: String) -> String {
        L10n.format("in use — written %@", relative)
    }

    static func confirmInUse(count: Int) -> String {
        count == 1
            ? L10n.string(
                "One of these was written in the last few minutes, so something is probably "
                    + "building in it right now. Removing it will interrupt that build."
            )
            : L10n.format(
                "%lld of these were written in the last few minutes, so something is probably "
                    + "building in them right now. Removing them will interrupt those builds.",
                Int64(count)
            )
    }

    static func confirmTitle(count: Int, size: String) -> String {
        count == 1
            ? L10n.format("Remove this directory and reclaim %@?", size)
            : L10n.format(
                "Remove %lld directories and reclaim %@?",
                Int64(count),
                size
            )
    }

    static var confirmBody: String {
        L10n.string("""
            They will be deleted immediately, not moved to the Trash. Each one is rebuilt by the \
            command shown beside it, which takes time but no decisions.
            """)
    }

    static func confirmBusy(_ projects: String) -> String {
        L10n.format(
            "A session is running in %@. If it is building right now, removing its build "
                + "output will interrupt that build.",
            projects
        )
    }
}
