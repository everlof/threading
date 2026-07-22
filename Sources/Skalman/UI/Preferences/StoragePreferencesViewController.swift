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

    /// Findings by checkout, largest first. Empty until the first scan lands.
    private var groups: [CheckoutGroup] = []

    private var isScanning = false

    /// Scans run here and hop to the main queue with their results — the walk touches every
    /// file in a `target/`, which is not a thing to do on the main thread.
    private let queue = DispatchQueue(label: "com.skalman.artifact-scan", qos: .utility)

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

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
        scan()
    }

    // MARK: - Scanning

    /// Rescans every project, replacing whatever was shown.
    ///
    /// Results land per project rather than all at once, so a long scan fills the page as it
    /// goes instead of showing nothing until the last checkout is measured.
    private func scan() {
        guard !isScanning else { return }

        isScanning = true
        groups = []
        rebuild()

        let projects = ProjectStore.shared.projects
        queue.async { [weak self] in
            for project in projects {
                let artifacts = ArtifactScanner.scan(projectFolder: project.folderPath)
                guard !artifacts.isEmpty else { continue }

                let found = Self.group(artifacts, of: project)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.groups.append(contentsOf: found)
                    self.groups.sort { $0.byteCount > $1.byteCount }
                    self.rebuild()
                }
            }

            DispatchQueue.main.async {
                self?.isScanning = false
                self?.rebuild()
            }
        }
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
        total.textColor = totalBytes > 0 ? .labelColor : .secondaryLabelColor

        let caption = NSTextField(labelWithString: isScanning
            ? StorageStrings.scanning
            : StorageStrings.reclaimable(count: allArtifacts.count))
        caption.font = Design.Typography.subheading()
        caption.textColor = .secondaryLabelColor

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

    /// One checkout: its artifacts largest first, closed by a row that removes the lot.
    ///
    /// The heading carries the project *and* the checkout, because the checkout is the answer
    /// to "which of these is it" and the project alone is not.
    private func checkoutSection(_ group: CheckoutGroup, groupIndex: Int) -> NSView {
        var rows: [NSView] = group.artifacts.enumerated().map { index, artifact in
            row(for: artifact, in: group, tag: tag(group: groupIndex, artifact: index))
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
        return SettingsUI.section(title, SettingsCard(rows: rows))
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
        size.textColor = .secondaryLabelColor
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
        scan()
    }

    @objc private func removeArtifactClicked(_ sender: NSButton) {
        let position = coordinates(of: sender.tag)
        guard groups.indices.contains(position.group) else { return }

        let group = groups[position.group]
        guard group.artifacts.indices.contains(position.artifact) else { return }

        remove([group.artifacts[position.artifact]], in: [group.project])
    }

    @objc private func removeCheckoutClicked(_ sender: NSButton) {
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

        // Removal walks directories too, so it goes to the same queue as the scan. The page is
        // rebuilt from a fresh scan rather than by editing the list in place: what is left on
        // disk afterwards is the only answer worth showing.
        queue.async { [weak self] in
            var removed = 0
            for artifact in artifacts where ArtifactScanner.remove(artifact) {
                removed += 1
            }

            SkalmanLogger.agent.info(
                "Reclaimed \(removed, privacy: .public) of \(artifacts.count, privacy: .public) artifacts"
            )

            DispatchQueue.main.async {
                self?.isScanning = false
                self?.scan()
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
