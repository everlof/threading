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

    /// The grouping model, which lives in `ReclaimableFindings` because the agent proposal sheet
    /// draws the same content and the two must not disagree about what a directory belongs to.
    /// Named here as well so the page — and the tests that read its cards — keep their vocabulary.
    typealias GroupAttribution = ReclaimableFindings.Attribution
    typealias FindingsGroup = ReclaimableFindings.Group
    typealias GroupsProvider = @MainActor () -> [FindingsGroup]
    typealias ScanningProvider = @MainActor () -> Bool
    typealias RefreshAction = @MainActor () -> Void

    private enum PresentationRow {
        case explanation
        case group(Int)
        case artifact(group: Int, artifact: Int)
        case tail(Int)
        case empty
        case safety
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    // MARK: - Properties

    /// Findings by group, largest first, read from the caches the service keeps.
    private var groups: [FindingsGroup] = []
    private var presentationRows: [PresentationRow] = []
    private var extensionSections: [ExtensionSettingsSectionModel] = []
    private weak var pageView: SettingsPageView?

    /// Disk discovery is unbounded provider input. Keep it behind a value seam so both the live
    /// scanner and deterministic stress fixtures feed the same virtual row model.
    private let groupsProvider: GroupsProvider
    private let scanningProvider: ScanningProvider
    private let refreshStaleProjects: RefreshAction
    private let extensionSectionsProvider: @MainActor () -> [ExtensionSettingsSectionModel]
    private let summaryProvider: @MainActor () -> String?

    /// Groups whose cards the user has unfolded, by identity. Collapsed, a group is one row —
    /// name, path and size — which is the table the page's numbers actually want to be read as;
    /// the artifact rows are detail. Kept for the session only; a view state, not a preference.
    private var expandedGroups: Set<String> = []

    /// Within an unfolded group, whose sub-gigabyte tail is open. A checkout of a codebase
    /// collects dozens of tiny `__pycache__` directories, which buried the two that mattered
    /// under a page of noise — so anything under a gigabyte folds into one row until asked for.
    private var expandedTails: Set<String> = []
    private let appEvents = AppEventObservations()

    private var isScanning: Bool { scanningProvider() }

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("StorageSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = StorageDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    private lazy var rescanButton = SettingsUI.button(
        StorageStrings.rescan,
        target: self,
        action: #selector(rescanClicked)
    )

    /// Installed once with the header, then hidden when there is nothing to remove. Replacing
    /// the whole page to add or remove this action would also replace the viewport and editors.
    private lazy var removeEverythingButton = SettingsUI.button(
        StorageStrings.removeEverything,
        target: self,
        action: #selector(removeEverythingClicked)
    )

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

    init(
        groupsProvider: GroupsProvider? = nil,
        scanningProvider: @escaping ScanningProvider = {
            ArtifactScanService.shared.isScanning
        },
        refreshStaleProjects: @escaping RefreshAction = {
            ArtifactScanService.shared.refreshStaleProjects()
        },
        extensionSectionsProvider: @escaping @MainActor () -> [ExtensionSettingsSectionModel] = {
            ExtensionSettingsRenderer.hostSectionModels(for: .storage)
        },
        summaryProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.groupsProvider = groupsProvider ?? Self.liveGroups
        self.scanningProvider = scanningProvider
        self.refreshStaleProjects = refreshStaleProjects
        self.extensionSectionsProvider = extensionSectionsProvider
        self.summaryProvider = summaryProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        let page = SettingsUI.listPage(
            title: StorageStrings.title,
            summary: StorageStrings.nothingFound,
            actions: [rescanButton, removeEverythingButton],
            body: scrollView
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        pageView = page
        removeEverythingButton.isHidden = true
        reload()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appEvents.observe(ArtifactScanDidChange.self) { [weak self] _ in
            self?.reload()
        }
        appEvents.observe(ExtensionSettingsRegistryDidChange.self) { [weak self] _ in
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
        refreshStaleProjects()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    // MARK: - Reading

    /// Rebuilds from the caches, whether they changed because a scan landed or because something
    /// was removed.
    private func reload() {
        groups = groupsProvider()
        extensionSections = extensionSectionsProvider()
        reloadPresentationRows()
        pageView?.updateSummary(summaryProvider() ?? headerSummary())
        removeEverythingButton.isHidden = totalBytes == 0
    }

    // MARK: - Build

    /// Builds only row identities. A collapsed group is one value, while opening it adds cheap
    /// artifact coordinates; AppKit remains responsible for the controls inside the viewport.
    private func reloadPresentationRows() {
        var rows: [PresentationRow] = [.explanation]

        for (groupIndex, group) in groups.enumerated() {
            rows.append(.group(groupIndex))
            guard expandedGroups.contains(group.identity) else { continue }

            let indexed = Array(group.artifacts.enumerated())
            let large = indexed.filter {
                $0.element.byteCount >= StorageDefaults.collapseThreshold
            }
            let small = indexed.filter {
                $0.element.byteCount < StorageDefaults.collapseThreshold
            }
            rows.append(contentsOf: large.map {
                .artifact(group: groupIndex, artifact: $0.offset)
            })
            if !small.isEmpty {
                if expandedTails.contains(group.identity) {
                    rows.append(contentsOf: small.map {
                        .artifact(group: groupIndex, artifact: $0.offset)
                    })
                }
                rows.append(.tail(groupIndex))
            }
        }

        if !isScanning, groups.isEmpty { rows.append(.empty) }
        rows.append(.safety)

        for (sectionIndex, section) in extensionSections.enumerated() {
            if section.visibleTitle != nil {
                rows.append(.extensionCaption(sectionIndex))
            }
            rows.append(contentsOf: section.fields.indices.map {
                .extensionField(section: sectionIndex, field: $0)
            })
        }

        presentationRows = rows
        updateCardDecorations()
        tableView.reloadData()
    }

    /// The production value seam. Attribution remains owned by `ReclaimableFindings`; this page
    /// only projects its answer into virtual rows.
    private static func liveGroups() -> [FindingsGroup] {
        let projects = ProjectStore.shared.projects

        // A project's build cache in a temporary location is that project's line item, so it
        // sorts among the checkouts by size. The two tiers that name no project trail the page
        // instead, in the order they are worth reading: the orphans first, since they are the
        // only findings on this page nothing can ever want back. That order is the grouping
        // model's, so the proposal sheet reads them the same way.
        return ReclaimableFindings.groups(
            checkoutArtifacts: projects.map {
                ($0, ArtifactScanService.shared.artifacts(for: $0.id))
            },
            scratchArtifacts: ArtifactScanService.shared.scratchArtifacts(),
            among: projects
        )
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
                self?.setGroup(identity, expanded: nowExpanded)
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
                self?.setTail(identity, expanded: nowOpen)
            }
        )
    }

    /// The live table's group heading. The card surface itself belongs to
    /// `ThemedGroupedTableView`, so this is only the row content.
    private func groupHeader(_ group: FindingsGroup, groupIndex: Int) -> NSView {
        let removeAll = SettingsUI.button(
            StorageStrings.removeAll,
            target: self,
            action: #selector(removeGroupClicked(_:))
        )
        removeAll.tag = tag(group: groupIndex, artifact: StorageDefaults.wholeGroupTag)

        let identity = group.identity
        return SettingsUI.disclosureHeader(
            title: group.title,
            subtitle: group.subtitle,
            summary: Self.size.string(fromByteCount: group.byteCount),
            control: removeAll,
            isExpanded: expandedGroups.contains(identity),
            localizes: false,
            onToggle: { [weak self] nowExpanded in
                self?.setGroup(identity, expanded: nowExpanded)
            }
        )
    }

    private func setGroup(_ identity: String, expanded: Bool) {
        if expanded {
            expandedGroups.insert(identity)
        } else {
            expandedGroups.remove(identity)
        }
        reloadPresentationRows()
    }

    private func setTail(_ identity: String, expanded: Bool) {
        if expanded {
            expandedTails.insert(identity)
        } else {
            expandedTails.remove(identity)
        }
        reloadPresentationRows()
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
            title: ReclaimableFindings.rowTitle(for: artifact),
            subtitle: caption(for: artifact, in: group),
            control: trailing
        )
    }

    private func caption(for artifact: ReclaimableArtifact, in group: FindingsGroup) -> String {
        var parts = [artifact.kind.displayName, artifact.kind.rebuildHint]
        if let modifiedAt = artifact.modifiedAt {
            let age = Self.relativeDate.localizedString(for: modifiedAt, relativeTo: Date())
            parts.append(
                artifact.isInUse()
                    ? ReclaimableFindings.Strings.inUse(age)
                    : ReclaimableFindings.Strings.lastWritten(age)
            )
        }

        // The tree it was built for. Two rows in one temporary directory can be caches of two
        // different checkouts of the same project, and the path they sit at says nothing about
        // which — while under the orphan heading this is the whole story of why removing it is
        // safe.
        if let workspace = artifact.workspacePath {
            let readable = ReclaimableFindings.abbreviate(workspace)
            parts.append(
                group.attribution.namesADeletedWorkspace
                    ? ReclaimableFindings.Strings.builtForMissing(readable)
                    : ReclaimableFindings.Strings.builtFor(readable)
            )
        }

        return parts.joined(separator: " · ")
    }

    private func content(for presentationRow: PresentationRow) -> NSView {
        switch presentationRow {
        case .explanation:
            return SettingsUI.note(StorageStrings.explanation)
        case .group(let groupIndex):
            guard groups.indices.contains(groupIndex) else { return NSView() }
            return groupHeader(groups[groupIndex], groupIndex: groupIndex)
        case .artifact(let groupIndex, let artifactIndex):
            guard groups.indices.contains(groupIndex),
                  groups[groupIndex].artifacts.indices.contains(artifactIndex) else {
                return NSView()
            }
            let group = groups[groupIndex]
            return row(
                for: group.artifacts[artifactIndex],
                in: group,
                tag: tag(group: groupIndex, artifact: artifactIndex)
            )
        case .tail(let groupIndex):
            guard groups.indices.contains(groupIndex) else { return NSView() }
            let group = groups[groupIndex]
            let small = group.artifacts.filter {
                $0.byteCount < StorageDefaults.collapseThreshold
            }
            return foldRow(
                for: small,
                in: group,
                expanded: expandedTails.contains(group.identity)
            )
        case .empty:
            return SettingsUI.note(StorageStrings.empty)
        case .safety:
            return SettingsUI.note(StorageStrings.safety)
        case .extensionCaption(let sectionIndex):
            guard extensionSections.indices.contains(sectionIndex),
                  let title = extensionSections[sectionIndex].visibleTitle else {
                return NSView()
            }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(
                extensionSections[sectionIndex].accessibilityIdentifier
            )
            return caption
        case .extensionField(let sectionIndex, let fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    private func topInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .explanation, .group, .empty, .safety, .extensionCaption:
            return Design.Spacing.large
        case .artifact, .tail:
            return 0
        case .extensionField(let sectionIndex, let fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil
                ? Design.Spacing.large
                : 0
        }
    }

    private func bottomInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        if case .extensionCaption = presentationRows[index] {
            return Design.Spacing.small
        }
        return index == presentationRows.count - 1 ? Design.Spacing.large : 0
    }

    private func updateCardDecorations() {
        var groupBounds: [Int: (first: Int, last: Int)] = [:]
        var extensionBounds: [Int: (first: Int, last: Int)] = [:]

        for (index, presentationRow) in presentationRows.enumerated() {
            switch presentationRow {
            case .group(let groupIndex),
                 .artifact(let groupIndex, _),
                 .tail(let groupIndex):
                if var bounds = groupBounds[groupIndex] {
                    bounds.last = index
                    groupBounds[groupIndex] = bounds
                } else {
                    groupBounds[groupIndex] = (index, index)
                }
            case .extensionField(let sectionIndex, _):
                if var bounds = extensionBounds[sectionIndex] {
                    bounds.last = index
                    extensionBounds[sectionIndex] = bounds
                } else {
                    extensionBounds[sectionIndex] = (index, index)
                }
            case .explanation, .empty, .safety, .extensionCaption:
                break
            }
        }

        var decorations = groupBounds.sorted { $0.key < $1.key }.map {
            ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: Design.Spacing.large
            )
        }
        decorations.append(contentsOf: extensionBounds.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: section.visibleTitle == nil
                    ? Design.Spacing.large
                    : 0,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        })
        tableView.cardDecorations = decorations
    }

    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    func scrollGroupToVisibleForTesting(_ identity: String) {
        guard let index = presentationRows.firstIndex(where: { presentationRow in
            guard case .group(let groupIndex) = presentationRow,
                  groups.indices.contains(groupIndex) else { return false }
            return groups[groupIndex].identity == identity
        }) else { return }
        tableView.scrollRowToVisible(index)
    }

    func setGroupExpandedForTesting(_ identity: String, expanded: Bool) {
        setGroup(identity, expanded: expanded)
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

// MARK: - Virtual Rows

extension StoragePreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("StorageSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(forRowAt: tableRow),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }
}

// MARK: - Storage Defaults

private enum StorageDefaults {
    static let estimatedRowHeight: CGFloat = 72

    /// Comfortably more than any group's artifact count, so a tag packs two indices.
    static let tagStride = 10_000

    /// The artifact index meaning "every artifact in this group".
    static let wholeGroupTag = tagStride - 1

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
