import AppKit

// MARK: - Storage Preferences

/// The Storage page: build output the projects can rebuild, and the button that removes it.
///
/// Grouped **by checkout rather than by project**, because that is where the surprise lives. On
/// the machine this was built for, four projects held 79.5 GB of reclaimable output and 58 GB of
/// it sat in git worktrees — abandoned branches each carrying a full `target/` and their own copy
/// of `node_modules`, none of it visible from the folders anyone actually opens.
///
/// **The scratch scope sits on the same page.** Agents build in `/private/tmp` and the per-user
/// temporary directory as well, and what they leave there belongs to no checkout. Those findings
/// are attributed *here*, when the page is read, rather than when the disk was walked: Xcode's
/// manifest names the workspace each tree was built for, and both whether that workspace still
/// exists and whether it sits inside a project Threading knows change between the two moments.
///
/// Built from the settings kit like `ArchivedPreferencesViewController`, and for the same
/// reason: every row carries its own action, so there is no selection state to maintain and no
/// footer button bar. "Clean everything" is a row of its own rather than a mode.
///
/// Each row states what removing it costs — the command that brings it back, and how long ago it
/// was last written. An artifact built minutes ago is one somebody is using; one last touched in
/// March is not.
final class StoragePreferencesViewController: NSViewController {

    // MARK: - Types

    /// What one group's findings belong to, and therefore what the page may do with them.
    ///
    /// A checkout is a project's own scan: forgotten per project and re-measured after a
    /// removal. The three scratch cases are the read-time attribution of findings that belong to
    /// no checkout at all.
    ///
    /// Four cases rather than one optional project, because "no project" is two different facts.
    /// A workspace that is gone is the safest thing this page will ever offer — nothing can
    /// rebuild into that tree and nothing will read it again. A workspace that is alive and
    /// simply not ours is usually another agent session's copy of a tree, and filing it under
    /// the orphan heading would tell the user a directory somebody may be building in right now
    /// was left over from a deletion.
    enum GroupAttribution {

        /// One checkout of a project: its own folder, or one of its worktrees.
        case checkout(Project)

        /// Scratch findings built for a workspace inside this project's folder.
        case scratchProject(Project)

        /// Scratch findings whose workspace no longer exists.
        case scratchOrphan

        /// Scratch findings whose workspace exists and belongs to no project Threading knows.
        case scratchOther

        /// The project whose running sessions the confirmation warns about, when there is one.
        var project: Project? {
            switch self {
            case .checkout(let project), .scratchProject(let project): return project
            case .scratchOrphan, .scratchOther: return nil
            }
        }

        /// Whether a removal here corrects the scratch reading rather than a project's.
        var isScratch: Bool {
            switch self {
            case .checkout: return false
            case .scratchProject, .scratchOrphan, .scratchOther: return true
            }
        }

        /// Whether the group trails the page instead of sorting into it by size. A heading that
        /// names no project reads as a mistake in the middle of a list of projects.
        var trailsThePage: Bool {
            switch self {
            case .checkout, .scratchProject: return false
            case .scratchOrphan, .scratchOther: return true
            }
        }

        /// Whether the workspace these findings name is gone, which changes what a row's caption
        /// says about it.
        var namesADeletedWorkspace: Bool {
            switch self {
            case .scratchOrphan: return true
            case .checkout, .scratchProject, .scratchOther: return false
            }
        }
    }

    /// One group's findings — a checkout's, or one tier of the scratch scope's.
    ///
    /// The **checkout** is the grouping rather than the project, because a project's build
    /// output is spread across every worktree it has and the path alone does not say which:
    /// six of these checkouts hold a `web/node_modules`, and a row reading `web/node_modules`
    /// under a heading reading `sonda` names none of them.
    struct FindingsGroup {
        let attribution: GroupAttribution

        /// The card's first line: the project and its checkout, or the scratch tier's heading.
        let title: String

        /// The line beneath it, which is always where on disk. A worktree name does not say
        /// where it lives, and neither does a tier's name — and that is what somebody about to
        /// delete gigabytes wants to confirm.
        let subtitle: String

        /// What the fold state is keyed by. A checkout's path for a checkout; a stated key for
        /// a scratch tier, which spans roots and so has no one path to be named after.
        let identity: String

        let artifacts: [ReclaimableArtifact]

        var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    }

    // MARK: - Properties

    /// Findings by group, largest first, read from the caches the service keeps.
    private var groups: [FindingsGroup] = []

    /// Groups whose cards the user has unfolded, by identity. Collapsed, a group is one row —
    /// name, path and size — which is the table the page's numbers actually want to be read as;
    /// the artifact rows are detail. Kept for the session only; a view state, not a preference.
    private var expandedGroups: Set<String> = []

    /// Within an unfolded group, whose sub-gigabyte tail is open. A checkout of a codebase
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

    /// Rebuilds from the caches, whether they changed because a scan landed or because something
    /// was removed.
    private func reload() {
        let projects = ProjectStore.shared.projects
        var sortable = projects.flatMap { project in
            Self.group(ArtifactScanService.shared.artifacts(for: project.id), of: project)
        }

        let scratch = Self.scratchGroups(
            ArtifactScanService.shared.scratchArtifacts(),
            among: projects
        )
        sortable += scratch.filter { !$0.attribution.trailsThePage }

        // A project's build cache in a temporary location is that project's line item, so it
        // sorts among the checkouts by size. The two tiers that name no project trail the page
        // instead, in the order they are worth reading: the orphans first, since they are the
        // only findings on this page nothing can ever want back.
        groups = sortable.sorted { $0.byteCount > $1.byteCount }
            + scratch.filter(\.attribution.trailsThePage)

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
    ) -> [FindingsGroup] {
        Dictionary(grouping: artifacts, by: \.checkoutPath)
            .map { path, artifacts in
                let label = GitInfo.worktreeName(for: path)
                    ?? GitInfo.currentBranch(for: path)
                    ?? URL(fileURLWithPath: path).lastPathComponent
                return FindingsGroup(
                    attribution: .checkout(project),
                    title: "\(project.name) · \(label)",
                    subtitle: abbreviate(path),
                    identity: path,
                    artifacts: artifacts.sorted { $0.byteCount > $1.byteCount }
                )
            }
            .sorted { $0.byteCount > $1.byteCount }
    }

    /// Splits the scratch scope's findings three ways by the workspace each was built for.
    ///
    /// **Pure, and free of git by contract.** The per-checkout `group(_:of:)` above shells out
    /// once per checkout to name it; this path must not, because the trees it groups have no
    /// repository to ask — that absence is the whole reason the manifest gate exists — and
    /// because there can be one group here per project and two more besides.
    ///
    /// - A workspace that still exists inside a known project's folder groups under that
    ///   project, exactly as a nested worktree does.
    /// - A workspace that no longer exists is an orphan. Nothing can rebuild into that tree and
    ///   nothing will read it again, which makes it the safest thing this page offers.
    /// - Anything else is a workspace that is alive and is not ours, most often another agent
    ///   session's copy of a tree. It is offered, but under its own heading: it is not an
    ///   orphan, and saying so would be a claim about somebody else's live directory.
    ///
    /// Paths are compared with symlinks resolved, because `/tmp` is a symlink to `/private/tmp`
    /// and two spellings of one directory must not read as two places. The most specific project
    /// wins, so a project checked out inside another takes its own build caches with it.
    ///
    /// `workspaceExists` is stated for tests, which have no deleted workspace to point at.
    static func scratchGroups(
        _ artifacts: [ReclaimableArtifact],
        among projects: [Project],
        workspaceExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [FindingsGroup] {
        let folders = projects
            .map { (project: $0, folder: normalized($0.folderPath)) }
            .sorted { $0.folder.count > $1.folder.count }

        var attributed: [ProjectID: [ReclaimableArtifact]] = [:]
        var byID: [ProjectID: Project] = [:]
        var orphaned: [ReclaimableArtifact] = []
        var other: [ReclaimableArtifact] = []

        for artifact in artifacts {
            guard let workspace = artifact.workspacePath else {
                // Every scratch finding the scanner produces names a workspace. One that does
                // not is still not an orphan: nothing said a workspace was deleted.
                other.append(artifact)
                continue
            }

            guard workspaceExists(workspace) else {
                orphaned.append(artifact)
                continue
            }

            let path = normalized(workspace)
            let owner = folders.first { path == $0.folder || path.hasPrefix($0.folder + "/") }
            guard let owner else {
                other.append(artifact)
                continue
            }

            attributed[owner.project.id, default: []].append(artifact)
            byID[owner.project.id] = owner.project
        }

        var groups: [FindingsGroup] = attributed.compactMap { id, artifacts in
            guard let project = byID[id] else { return nil }
            return FindingsGroup(
                attribution: .scratchProject(project),
                title: "\(project.name) · \(StorageStrings.buildCacheInTemporary)",
                subtitle: rootsLabel(of: artifacts),
                identity: ScratchGroupKey.project(id),
                artifacts: artifacts.sorted { $0.byteCount > $1.byteCount }
            )
        }
        .sorted { $0.byteCount > $1.byteCount }

        if !orphaned.isEmpty {
            groups.append(FindingsGroup(
                attribution: .scratchOrphan,
                title: StorageStrings.deletedWorkspaces,
                subtitle: rootsLabel(of: orphaned),
                identity: ScratchGroupKey.orphaned,
                artifacts: orphaned.sorted { $0.byteCount > $1.byteCount }
            ))
        }

        if !other.isEmpty {
            groups.append(FindingsGroup(
                attribution: .scratchOther,
                title: StorageStrings.otherTemporaryCaches,
                subtitle: rootsLabel(of: other),
                identity: ScratchGroupKey.other,
                artifacts: other.sorted { $0.byteCount > $1.byteCount }
            ))
        }

        return groups
    }

    /// Where a scratch group's findings sit, which is what a checkout card says with its path.
    /// A tier's heading names what the findings are, not where they are, and the second question
    /// is the one asked before deleting gigabytes.
    private static func rootsLabel(of artifacts: [ReclaimableArtifact]) -> String {
        Set(artifacts.map(\.checkoutPath))
            .sorted()
            .map(abbreviate)
            .joined(separator: " · ")
    }

    /// One spelling for one directory, so `/tmp` and `/private/tmp` cannot disagree about being
    /// the same place. Resolution happens on both sides of every comparison.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
            sections.append(groupSection(
                group,
                groupIndex: index,
                expanded: expandedGroups.contains(group.identity)
            ))
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

        // The oldest of every reading on show, and the scratch scope is one of them. It is also
        // the reading that goes stale fastest — agents and the OS both clean in `/private/tmp`,
        // and one session directory there fell from 21 GB to 92 KB during a five-minute
        // measurement — so leaving it out of this line would date the page by the steadier half.
        let projectIDs = ProjectStore.shared.projects.map(\.id)
        let readings = [
            ArtifactScanService.shared.oldestScan(among: projectIDs),
            ArtifactScanService.shared.scratchScannedAt()
        ].compactMap { $0 }

        if let measured = readings.min() {
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

    /// One group, folded to the row the page's numbers want to be read as: what it is, where it
    /// is, the size trailing, Remove All beside it. Unfolded, the big artifacts get their own
    /// rows and everything under a gigabyte folds again into one tail row.
    ///
    /// Internal rather than private, and taking its fold state rather than reading it, so a
    /// render test can draw the real card: a claim about how these headings look is checked by
    /// looking at a picture, and a picture of a transcription proves nothing.
    func groupSection(_ group: FindingsGroup, groupIndex: Int, expanded: Bool) -> NSView {
        // Enumerated over the *original* order, so a row's tag still indexes `group.artifacts`
        // however the rows are then partitioned for display.
        let indexed = Array(group.artifacts.enumerated())
        let large = indexed.filter { $0.element.byteCount >= StorageDefaults.collapseThreshold }
        let small = indexed.filter { $0.element.byteCount < StorageDefaults.collapseThreshold }

        var rows: [NSView] = []
        if expanded {
            rows = large.map { index, artifact in
                row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
            }

            if !small.isEmpty {
                let tailOpen = expandedTails.contains(group.identity)
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
            action: #selector(removeGroupClicked(_:))
        )
        removeAll.tag = tag(group: groupIndex, artifact: StorageDefaults.wholeGroupTag)

        let identity = group.identity
        return SettingsUI.disclosureCard(
            title: group.title,
            subtitle: group.subtitle,
            summary: Self.size.string(fromByteCount: group.byteCount),
            control: removeAll,
            isExpanded: expanded,
            localizes: false,
            onToggle: { [weak self] nowExpanded in
                guard let self else { return }
                if nowExpanded {
                    self.expandedGroups.insert(identity)
                } else {
                    self.expandedGroups.remove(identity)
                }
                self.rebuild()
            },
            detailRows: rows
        )
    }

    /// The row that stands in for everything under a gigabyte, and unfolds it on a click.
    private func foldRow(
        for artifacts: [ReclaimableArtifact],
        in group: FindingsGroup,
        expanded: Bool
    ) -> NSView {
        let total = artifacts.reduce(0) { $0 + $1.byteCount }
        let identity = group.identity
        return SettingsUI.disclosureRow(
            title: StorageStrings.smallerDirectories(artifacts.count),
            subtitle: StorageStrings.underAGigabyte,
            summary: Self.size.string(fromByteCount: total),
            isExpanded: expanded,
            localizes: false,
            onToggle: { [weak self] nowOpen in
                guard let self else { return }
                if nowOpen {
                    self.expandedTails.insert(identity)
                } else {
                    self.expandedTails.remove(identity)
                }
                self.rebuild()
            }
        )
    }

    /// Replaces the home directory with `~`, so a path is read for its shape rather than its
    /// first forty identical characters.
    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A finding's path, read for its shape: relative to the checkout or scratch root it was
    /// found under, which every row under one heading shares.
    private static func rowTitle(for artifact: ReclaimableArtifact) -> String {
        let root = artifact.checkoutPath + "/"
        let path = artifact.url.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : abbreviate(path)
    }

    /// One artifact: what it is, where it is, what it costs to bring back, and how stale it is.
    private func row(for artifact: ReclaimableArtifact, in group: FindingsGroup, tag: Int) -> NSView {
        let button = SettingsUI.button(
            StorageStrings.remove,
            target: self,
            action: #selector(removeArtifactClicked(_:))
        )
        button.tag = tag

        let size = NSTextField(labelWithString: Self.size.string(fromByteCount: artifact.byteCount))
        // Monospaced digits and trailing alignment, so the sizes read as a column of numbers
        // rather than jittering row to row. The column is only a column because the group holds
        // its fitting width against the trailing inset — see `SettingsUI.controlGroup`.
        size.applyFont(.numericBody)
        size.textColor = Design.Text.secondary
        size.alignment = .right

        let trailing = SettingsUI.controlGroup([size, button])

        return SettingsUI.row(
            title: Self.rowTitle(for: artifact),
            subtitle: caption(for: artifact, in: group),
            control: trailing
        )
    }

    private func caption(for artifact: ReclaimableArtifact, in group: FindingsGroup) -> String {
        var parts = [artifact.kind.displayName, artifact.kind.rebuildHint]
        if let modifiedAt = artifact.modifiedAt {
            let age = Self.relativeDate.localizedString(for: modifiedAt, relativeTo: Date())
            parts.append(artifact.isInUse() ? StorageStrings.inUse(age) : StorageStrings.built(age))
        }

        // The tree it was built for. Two rows in one temporary directory can be caches of two
        // different checkouts of the same project, and the path they sit at says nothing about
        // which — while under the orphan heading this is the whole story of why removing it is
        // safe.
        if let workspace = artifact.workspacePath {
            let readable = Self.abbreviate(workspace)
            parts.append(
                group.attribution.namesADeletedWorkspace
                    ? StorageStrings.builtForMissing(readable)
                    : StorageStrings.builtFor(readable)
            )
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - Tags

    /// Buttons carry their row's coordinates, so an action maps straight back to `groups`
    /// without the page holding a second index of its own. The scratch groups are members of
    /// that one array like any other, which is what keeps them out of a bookkeeping scheme of
    /// their own.
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

        remove([group.artifacts[position.artifact]], from: [group])
    }

    @objc private func removeGroupClicked(_ sender: ThemedButton) {
        let position = coordinates(of: sender.tag)
        guard groups.indices.contains(position.group) else { return }

        remove(groups[position.group].artifacts, from: [groups[position.group]])
    }

    @objc private func removeEverythingClicked() {
        remove(allArtifacts, from: groups)
    }

    /// Confirms, removes, and corrects the readings the removal changed.
    ///
    /// The confirmation names a **running session** in any affected project when there is one:
    /// deleting a `target/` out from under a build in flight is the one way this goes wrong for
    /// somebody who otherwise understood exactly what they asked for.
    ///
    /// The groups come along rather than only their artifacts, because which cache a finding is
    /// forgotten from is a fact about where it was listed, and after the delete there is nothing
    /// left on disk to ask.
    private func remove(_ artifacts: [ReclaimableArtifact], from groups: [FindingsGroup]) {
        guard !artifacts.isEmpty else { return }

        let bytes = artifacts.reduce(0) { $0 + $1.byteCount }
        let projects = Self.distinct(groups.compactMap(\.attribution.project))
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

        let scratchPaths = Set(
            groups.filter(\.attribution.isScratch).flatMap { $0.artifacts.map(\.url.path) }
        )
        let checkoutProjects = Self.distinct(
            groups.filter { !$0.attribution.isScratch }.compactMap(\.attribution.project)
        )

        // One coordinator serialises this surface with agent-approved cleanup, performs each
        // directory walk off the main actor, and publishes one progress stream for both.
        let started = ArtifactCleanupCoordinator.shared.remove(artifacts) { outcome in
            // Only what actually went. The scanner re-checks both safety gates and refuses what
            // stopped being disposable; a refusal therefore stays in the cache and on this page.
            let removed = outcome.removed

            ThreadingLogger.storage.info(
                "Reclaimed \(removed.count, privacy: .public) of \(artifacts.count, privacy: .public) artifacts"
            )

            // The caches are corrected from what actually went, so the page updates at once.
            // A project is then re-measured; the scratch scope is not, because re-walking
            // `/private/tmp` to learn what this delete just did is the most expensive answer.
            let scratch = removed.filter { scratchPaths.contains($0.url.path) }
            if !scratch.isEmpty {
                ArtifactScanService.shared.forgetScratch(scratch)
            }

            let fromCheckouts = removed.filter { !scratchPaths.contains($0.url.path) }
            guard !fromCheckouts.isEmpty else { return }
            for project in checkoutProjects {
                ArtifactScanService.shared.forget(fromCheckouts, in: project.id)
                ArtifactScanService.shared.refresh(project, force: true)
            }
        }
        guard started else {
            ThreadingLogger.storage.notice(
                "Ignored duplicate cleanup request while another cleanup is running"
            )
            return
        }
    }

    /// One entry per project, in the order they were met. Two checkouts of one project must not
    /// name it twice in a warning, nor ask for it to be rescanned twice.
    private static func distinct(_ projects: [Project]) -> [Project] {
        var seen: Set<ProjectID> = []
        return projects.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Storage Defaults

private enum StorageDefaults {
    /// Comfortably more than any group's artifact count, so a tag packs two indices.
    static let tagStride = 10_000

    /// The artifact index meaning "every artifact in this group".
    static let wholeGroupTag = tagStride - 1

    /// Directories smaller than this fold into one row. A gigabyte is the line between "worth
    /// its own row" and "part of the tail" — a checkout gathers dozens of KB-sized caches, and
    /// they buried the two directories that held the space.
    static let collapseThreshold: Int64 = 1_000_000_000
}

// MARK: - Scratch Group Key

/// What a scratch group's fold state is keyed by.
///
/// A checkout is named by its path; a scratch tier spans every root the walk covers and has no
/// one path to be named after, so it states a key instead. The same set holds both, and these
/// cannot collide with a checkout: a checkout identity is an absolute path and begins with `/`.
private enum ScratchGroupKey {
    static let prefix = "scratch"

    static func project(_ id: ProjectID) -> String { "\(prefix).project.\(id.uuidString)" }
    static let orphaned = "\(prefix).orphaned"
    static let other = "\(prefix).other"
}

// MARK: - Storage Strings

private enum StorageStrings {
    static var title: String { L10n.string("Storage") }

    static var explanation: String {
        L10n.string("""
            Build output your projects can make again — Rust and Swift build directories, installed \
            packages, caches. Worktrees are included, which is usually where most of it is hiding. \
            Temporary locations are scanned too, since that is where an agent builds when it is \
            not building in a project.
            """)
    }

    static var safety: String {
        L10n.string("""
            Only directories git ignores and a known tool can rebuild are offered. Anything tracked \
            in a repository is left alone, whatever it is called — and ignored files that are not \
            build output, such as .env files, are never touched. In a temporary location a build \
            cache is offered only when Xcode's own manifest identifies it, never an agent's working \
            copy of a repository. Removal is immediate rather than moved to the Trash, since space \
            in the Trash has not been reclaimed.
            """)
    }

    static var empty: String { L10n.string("Nothing to reclaim.") }
    static var nothingFound: String { L10n.string("Nothing found to remove") }
    static var scanning: String { L10n.string("Scanning…") }
    static var rescan: String { L10n.string("Rescan") }
    static var remove: String { L10n.string("Remove") }
    static var cancel: String { L10n.string("Cancel") }
    static var removeEverything: String { L10n.string("Remove All…") }

    /// What a project's findings outside its own folder are called, after its name: the same
    /// `<project> · <where>` shape a checkout heading has.
    static var buildCacheInTemporary: String { L10n.string("build cache in /tmp") }

    /// The orphan tier's heading, which names what the findings are rather than where they live
    /// — there is no project left to name, and that absence is the point.
    static var deletedWorkspaces: String { L10n.string("Left over from deleted workspaces") }

    /// The tier for a workspace that is alive and is not ours. Deliberately not the orphan
    /// heading: somebody may be building in it right now.
    static var otherTemporaryCaches: String {
        L10n.string("Other build caches in temporary locations")
    }

    /// The tree a cache was built for, which is the only thing that says which checkout fed it.
    static func builtFor(_ workspace: String) -> String {
        L10n.format("built for %@", workspace)
    }

    /// The same, when that tree is gone. On the orphan tier this is the whole reason the row is
    /// safe to remove.
    static func builtForMissing(_ workspace: String) -> String {
        L10n.format("built for %@, which no longer exists", workspace)
    }

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
