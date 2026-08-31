import AppKit

/// One destination in the part of a diff the Review pane can actually present.
struct GitReviewFindMatch: Equatable, Sendable {
    struct TextRange: Equatable, Sendable {
        let location: Int
        let length: Int
    }

    enum Location: Equatable, Sendable {
        case path
        case hunk(Int)
        case line(hunk: Int, line: Int, range: TextRange)
    }

    let fileIndex: Int
    let path: String
    let location: Location
    let text: String
}

struct GitReviewFindResults: Equatable, Sendable {
    let matches: [GitReviewFindMatch]
    let isTruncated: Bool
}

/// The presentation boundary shared by the TextKit renderer and its search index.
/// Searching raw text past this cap would return a destination the pane cannot show.
enum GitReviewDiffPresentationText {
    static func displayed(_ text: String) -> String {
        guard text.count > GitReviewDefaults.lineCharacterCap else { return text }
        return String(text.prefix(GitReviewDefaults.lineCharacterCap)) + "…"
    }
}

/// Pure, background-safe indexing over immutable diff values.
enum GitReviewFindIndex {
    static func results(
        in files: [GitFileDiff],
        matching rawQuery: String,
        limit: Int = GitReviewDefaults.findMatchCap,
        isCancelled: () -> Bool = { false }
    ) -> GitReviewFindResults {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            return GitReviewFindResults(matches: [], isTruncated: false)
        }

        var matches: [GitReviewFindMatch] = []
        matches.reserveCapacity(min(files.count * 2, limit))

        func append(
            fileIndex: Int,
            path: String,
            location: GitReviewFindMatch.Location,
            text: String
        ) -> Bool {
            guard matches.count < limit else { return false }
            matches.append(GitReviewFindMatch(
                fileIndex: fileIndex,
                path: path,
                location: location,
                text: text
            ))
            return true
        }

        for (fileIndex, file) in files.enumerated() {
            if isCancelled() {
                return GitReviewFindResults(matches: [], isTruncated: false)
            }

            if firstRange(in: file.path, matching: query) != nil,
               !append(
                   fileIndex: fileIndex,
                   path: file.path,
                   location: .path,
                   text: file.path
               ) {
                return GitReviewFindResults(matches: matches, isTruncated: true)
            }

            var remaining = GitReviewDefaults.fileDisplayCap
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                guard remaining > 0 else { break }

                let showsHeader = file.hunks.count > 1 || file.change != .untracked
                if showsHeader,
                   firstRange(in: hunk.header, matching: query) != nil,
                   !append(
                       fileIndex: fileIndex,
                       path: file.path,
                       location: .hunk(hunkIndex),
                       text: hunk.header
                   ) {
                    return GitReviewFindResults(matches: matches, isTruncated: true)
                }

                for (lineIndex, line) in hunk.lines.prefix(remaining).enumerated() {
                    if isCancelled() {
                        return GitReviewFindResults(matches: [], isTruncated: false)
                    }
                    let text = GitReviewDiffPresentationText.displayed(line.text)
                    guard let range = firstRange(in: text, matching: query) else { continue }
                    let nsRange = NSRange(range, in: text)
                    guard append(
                        fileIndex: fileIndex,
                        path: file.path,
                        location: .line(
                            hunk: hunkIndex,
                            line: lineIndex,
                            range: GitReviewFindMatch.TextRange(
                                location: nsRange.location,
                                length: nsRange.length
                            )
                        ),
                        text: text
                    ) else {
                        return GitReviewFindResults(matches: matches, isTruncated: true)
                    }
                }
                remaining -= hunk.lines.count
            }
        }

        return GitReviewFindResults(matches: matches, isTruncated: false)
    }

    private static func firstRange(
        in text: String,
        matching query: String
    ) -> Range<String.Index>? {
        text.range(of: query, options: SearchTextMatch.comparisonOptions)
    }
}

// MARK: - Surface-owned Find

extension GitReviewViewController {
    var canShowFind: Bool {
        switch phase {
        case .fileIndex, .files, .commitDetail: true
        case .message, .commits: false
        }
    }

    func showFind() {
        guard canShowFind else { return }
        isFindBarVisible = true
        findBar.isHidden = false
        findBarSeparator.isHidden = false
        findBarHeight.constant = findBar.intrinsicContentSize.height
        applyFindBarRuleWeight()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        findBar.focus()

        let query = findBar.queryField.stringValue
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            find(query, backwards: false)
        }
    }

    func repeatFind(backwards: Bool) {
        find(findBar.queryField.stringValue, backwards: backwards)
    }

    func hideFind() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findBar.isHidden = true
        findBarSeparator.isHidden = true
        findBarHeight.constant = 0
        applyFindBarRuleWeight()
        cancelFindWork(clearSnapshot: true)
        findMatches.removeAll(keepingCapacity: false)
        findMatchIndex = nil
        findResultsAreTruncated = false
        findBar.setStatus("", canNavigate: false)
        view.needsLayout = true
        view.window?.makeFirstResponder(fileTableView)
    }

    func applyFindBarRuleWeight() {
        findBarSeparatorHeight.constant = isFindBarVisible ? Design.Radius.border : 0
    }

    /// Called by the renderer after it has committed a new file surface. Search results belong
    /// to one immutable comparison; a checkout refresh or mode change invalidates all of them.
    func findPhaseDidChange() {
        findSourceGeneration += 1
        cancelFindWork(clearSnapshot: true, incrementsGeneration: false)
        findMatches.removeAll(keepingCapacity: false)
        findMatchIndex = nil
        findResultsAreTruncated = false

        guard isFindBarVisible else { return }
        guard canShowFind else {
            hideFind()
            return
        }
        let query = findBar.queryField.stringValue
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findBar.setStatus("", canNavigate: false)
        } else {
            startFind(query, backwards: false)
        }
    }

    func find(_ rawQuery: String, backwards: Bool) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            findQuery = ""
            cancelFindWork(clearSnapshot: false)
            findMatches.removeAll(keepingCapacity: false)
            findMatchIndex = nil
            findResultsAreTruncated = false
            findBar.setStatus("", canNavigate: false)
            return
        }

        if query == findQuery {
            guard !findMatches.isEmpty,
                  findSearchTask == nil,
                  findSnapshotCancellation == nil else { return }
            stepFind(backwards: backwards)
            return
        }
        startFind(query, backwards: backwards)
    }

    private func startFind(_ query: String, backwards: Bool) {
        findQuery = query
        findPendingBackwards = backwards
        findMatches.removeAll(keepingCapacity: false)
        findMatchIndex = nil
        findResultsAreTruncated = false
        findSearchTask?.cancel()
        findSearchTask = nil
        findBar.setStatus(L10n.string("Searching…"), canNavigate: false)

        switch phase {
        case .files(let files), .commitDetail(_, let files):
            scanFindSnapshot(files, query: query, backwards: backwards)

        case .fileIndex:
            if let findSnapshot {
                scanFindSnapshot(findSnapshot, query: query, backwards: backwards)
                return
            }
            loadFindSnapshot()

        case .message, .commits:
            findBar.setStatus(L10n.string("Search unavailable"), canNavigate: false)
        }
    }

    private func loadFindSnapshot() {
        guard findSnapshotCancellation == nil,
              let root = loadedDiffRoot ?? repositoryRoot,
              let request = currentDiffRequest else {
            findBar.setStatus(L10n.string("Search unavailable"), canNavigate: false)
            return
        }
        let expectedSource = findSourceGeneration
        findSnapshotCancellation = GitReviewReader.diff(
            request,
            in: root,
            ignoringWhitespace: ignoresWhitespace,
            contextLines: diffContextLines
        ) { [weak self] result in
            guard let self, expectedSource == self.findSourceGeneration else { return }
            self.findSnapshotCancellation = nil
            switch result {
            case .success(let files):
                self.findSnapshot = files
                guard !self.findQuery.isEmpty else { return }
                self.scanFindSnapshot(
                    files,
                    query: self.findQuery,
                    backwards: self.findPendingBackwards
                )
            case .failure(.cancelled):
                break
            case .failure:
                self.findBar.setStatus(
                    L10n.string("Search unavailable"),
                    canNavigate: false
                )
            }
        }
    }

    private func scanFindSnapshot(
        _ files: [GitFileDiff],
        query: String,
        backwards: Bool
    ) {
        findSearchTask?.cancel()
        let expectedSource = findSourceGeneration
        findSearchTask = Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                GitReviewFindIndex.results(
                    in: files,
                    matching: query,
                    isCancelled: { Task.isCancelled }
                )
            }.value
            guard !Task.isCancelled, let self,
                  expectedSource == self.findSourceGeneration,
                  query == self.findQuery else { return }
            self.findSearchTask = nil
            self.findMatches = results.matches
            self.findResultsAreTruncated = results.isTruncated
            guard !results.matches.isEmpty else {
                self.findMatchIndex = nil
                self.findBar.setStatus(L10n.string("No matches"), canNavigate: false)
                return
            }
            self.findMatchIndex = backwards ? results.matches.count - 1 : 0
            self.revealCurrentFindMatch()
        }
    }

    private func stepFind(backwards: Bool) {
        guard let current = findMatchIndex, !findMatches.isEmpty else { return }
        findMatchIndex = backwards
            ? (current - 1 + findMatches.count) % findMatches.count
            : (current + 1) % findMatches.count
        revealCurrentFindMatch()
    }

    private func revealCurrentFindMatch() {
        guard let index = findMatchIndex, findMatches.indices.contains(index) else { return }
        let match = findMatches[index]
        let snapshotFile = findSnapshot.flatMap { snapshot in
            snapshot.indices.contains(match.fileIndex) ? snapshot[match.fileIndex] : nil
        }
        revealFindMatch(match, snapshotFile: snapshotFile)

        let status = findResultsAreTruncated
            ? L10n.format("%lld of %lld+", Int64(index + 1), Int64(findMatches.count))
            : L10n.format("%lld of %lld", Int64(index + 1), Int64(findMatches.count))
        findBar.setStatus(status, canNavigate: true)
    }

    private func cancelFindWork(
        clearSnapshot: Bool,
        incrementsGeneration: Bool = true
    ) {
        if incrementsGeneration { findSourceGeneration += 1 }
        findSearchTask?.cancel()
        findSearchTask = nil
        findSnapshotCancellation?.cancel()
        findSnapshotCancellation = nil
        if clearSnapshot { findSnapshot = nil }
    }

    var findMatchCountForTesting: Int { findMatches.count }
}

// MARK: - Changed-file navigator

/// A changed-path tree shared by the persistent rail and the jump-to-file popover. It receives
/// the diff's already-bounded value roster and never walks the checkout.
final class GitReviewPathNavigatorViewController: NSViewController {
    private struct RosterEntry: Equatable {
        let path: String
        let added: Int
        let removed: Int
    }

    private final class Node: NSObject {
        var name: String
        var path: String
        let isDirectory: Bool
        var children: [Node] = []
        var added = 0
        var removed = 0

        init(name: String, path: String, isDirectory: Bool) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
        }
    }

    private let rootURL: URL
    private let searchField = ThemedSearchField()
    private let outlineView = ThemedOutlineView()
    private let scrollView = ThemedScrollView()
    private var roots: [Node] = []
    private var leaves: [Node] = []
    private var filteredLeaves: [Node]?
    private var roster: [RosterEntry] = []
    private(set) var modelRebuildCountForTesting = 0

    var onChoosePath: ((String) -> Void)?

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = ThemedSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
        view = root

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.string("Filter files…")
        searchField.setAccessibilityLabel(L10n.string("Filter changed files"))
        searchField.delegate = self

        let column = NSTableColumn(identifier: .init("GitReviewChangedPath"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.indentationPerLevel = 12
        outlineView.rowHeight = 24
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel(L10n.string("Changed files"))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        let inset = Design.Spacing.small
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: inset),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    /// Catches the outline up with a roster that arrived before there was a view to show it in.
    ///
    /// The popover is handed its files while it is still an unloaded controller, so `applyFilter`
    /// ran against `isViewLoaded == false` and returned without expanding anything — ⌘J opened on
    /// a column of collapsed directories rather than the changed files. The model may legitimately
    /// be set first; loading is where the view owes it a pass, not the caller's ordering.
    override func viewDidLoad() {
        super.viewDidLoad()
        applyFilter()
    }

    func update(files: [GitFileDiff]) {
        let nextRoster = files.map {
            RosterEntry(path: $0.path, added: $0.added, removed: $0.removed)
        }
        guard nextRoster != roster else { return }
        roster = nextRoster
        modelRebuildCountForTesting += 1

        var nodesByPath: [String: Node] = [:]
        var rootNodes: [Node] = []
        var leafNodes: [Node] = []

        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            var parent: Node?
            var accumulated = ""
            for (index, component) in components.enumerated() {
                accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
                let isDirectory = index < components.count - 1
                let node: Node
                if let existing = nodesByPath[accumulated] {
                    node = existing
                } else {
                    node = Node(name: component, path: accumulated, isDirectory: isDirectory)
                    nodesByPath[accumulated] = node
                    if let parent {
                        parent.children.append(node)
                    } else {
                        rootNodes.append(node)
                    }
                }
                if !isDirectory {
                    node.added = file.added
                    node.removed = file.removed
                    leafNodes.append(node)
                }
                parent = node
            }
        }

        // A chain of single-child directories is one row — "Sources/Threading/Core/Agent" —
        // rather than four rows with one file behind the last. Nine files took twenty-five
        // rows with every level on its own line, and the names truncated at the rail's width.
        func compact(_ nodes: [Node]) {
            for node in nodes where node.isDirectory {
                while node.children.count == 1,
                      let child = node.children.first,
                      child.isDirectory {
                    node.name += "/" + child.name
                    node.path = child.path
                    node.children = child.children
                }
                compact(node.children)
            }
        }
        compact(rootNodes)

        func sort(_ nodes: inout [Node]) {
            nodes.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for node in nodes where node.isDirectory { sort(&node.children) }
        }
        sort(&rootNodes)
        roots = rootNodes
        leaves = leafNodes
        applyFilter()
    }

    /// The field a presenter hands the keyboard to. Loading the view is part of the answer — the
    /// responder has to exist before the surface carrying it is shown.
    var searchResponder: NSResponder {
        _ = view
        return searchField
    }

    var rootPathsForTesting: [String] { roots.map(\.path) }
    var visibleLeafPathsForTesting: [String] { (filteredLeaves ?? leaves).map(\.path) }

    /// What the outline is *showing*, as against the model answer the two above give. The
    /// difference is the whole of the bug they could not see: a tree the view never reloaded.
    var outlineRowCountForTesting: Int { outlineView.numberOfRows }

    func setFilterForTesting(_ query: String) {
        _ = view
        searchField.stringValue = query
        applyFilter()
    }

    private var visibleRoots: [Node] { filteredLeaves ?? roots }

    private func applyFilter() {
        guard isViewLoaded else { return }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredLeaves = query.isEmpty
            ? nil
            : leaves.filter { $0.path.range(
                of: query,
                options: SearchTextMatch.comparisonOptions
            ) != nil }
        outlineView.reloadData()
        if filteredLeaves == nil {
            // Every level, not just the first. Expanding one deep left the files this exists to
            // reach sitting behind a second disclosure — `Sources ▸ Git ▸` and nothing to jump
            // to. The roster is the diff's already-bounded file list, so there is no tail here
            // that a full expansion could run away with.
            roots.filter(\.isDirectory).forEach {
                outlineView.expandItem($0, expandChildren: true)
            }
        }
    }
}

extension GitReviewPathNavigatorViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? visibleRoots.count : (item as? Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? visibleRoots[index] : (item as! Node).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        filteredLeaves == nil && ((item as? Node)?.isDirectory ?? false)
    }
}

extension GitReviewPathNavigatorViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }
        return GitReviewPathNavigatorRow(
            title: filteredLeaves == nil ? node.name : node.path,
            url: rootURL.appendingPathComponent(node.path),
            isDirectory: node.isDirectory,
            added: node.added,
            removed: node.removed
        )
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? Node)?.isDirectory ?? true)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? Node,
              !node.isDirectory else { return }
        onChoosePath?(node.path)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarHoverRowView()
    }
}

extension GitReviewPathNavigatorViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    /// Return takes the top match, so a jump opened from the keyboard can be finished from the
    /// keyboard rather than sending the hand back to the pointer for the last step. There is no
    /// arrow-key highlight to move through first because selecting a row here *is* choosing it —
    /// the rail alongside the diff works the same way — so the query is the whole selection.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let match = filteredLeaves?.first else { return false }
        onChoosePath?(match.path)
        return true
    }
}

private final class GitReviewPathNavigatorRow: NSView {
    init(
        title: String,
        url: URL,
        isDirectory: Bool,
        added: Int,
        removed: Int
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = ThemedFileIconView(url: url, isDirectory: isDirectory)
        let name = NSTextField(labelWithString: title)
        name.applyFont(.caption)
        name.textColor = isDirectory ? Design.Text.label : Design.Text.secondary
        name.lineBreakMode = .byTruncatingMiddle
        name.usesSingleLineMode = true
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stats = NSTextField.label(attributed: Self.stats(added: added, removed: removed))
        stats.isHidden = isDirectory
        stats.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(name)
        addSubview(stats)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Design.Spacing.tight),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: stats.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor),
            stats.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func stats(added: Int, removed: Int) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "+\(added)", attributes: [
            .foregroundColor: Design.Diff.added,
            .font: Design.Typography.numericDetail()
        ])
        value.append(NSAttributedString(string: " −\(removed)", attributes: [
            .foregroundColor: Design.Diff.removed,
            .font: Design.Typography.numericDetail()
        ]))
        return value
    }
}
