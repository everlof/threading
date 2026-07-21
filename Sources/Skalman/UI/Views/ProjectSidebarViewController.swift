import AppKit

// MARK: - Project Sidebar View Controller

/// Source list of projects and the agent sessions inside them.
final class ProjectSidebarViewController: NSViewController {

    // MARK: - Properties

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyStateView: NSView!

    /// Footer controls, retained so settings mode can hide Add Project and mark the cogwheel.
    private var addButton: HoverTintButton!
    private var settingsButton: HoverTintButton!

    /// The settings section list, shown in place of the projects when settings is open — so
    /// the window never grows a second sidebar.
    private var settingsSidebar: SettingsSidebar?
    private(set) var isSettingsMode = false

    /// Top level of the tree: a `RepoGroupNode` for repositories with several checkouts,
    /// a bare `ProjectNode` for everything else.
    private var rootNodes: [NSObject] = []

    /// Every project node, regardless of whether it sits inside a group.
    private var allProjectNodes: [ProjectNode] {
        rootNodes.flatMap { node -> [ProjectNode] in
            if let group = node as? RepoGroupNode { return group.projectNodes }
            if let project = node as? ProjectNode { return [project] }
            return []
        }
    }

    weak var delegate: ProjectSidebarViewControllerDelegate?

    /// Suppresses the selection delegate callback during programmatic selection.
    private var suppressSelectionCallback = false

    /// The session a hover-menu action applies to, set when the menu is opened.
    private var actionSessionID: UUID?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupOutlineView()
        setupEmptyState()
        setupFooter()
        observeStoreChanges()
        reload()
        // Selection is restored by the window controller once the terminal pane exists.
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        // The single column does not track the sidebar's width on its own, so names would
        // truncate while empty space remained beside them.
        outlineView.sizeLastColumnToFit()
    }

}

// MARK: - Setup

private extension ProjectSidebarViewController {

    private func setupOutlineView() {
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = SidebarDefaults.indentationPerLevel
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = makeContextMenu()
        outlineView.registerForDraggedTypes([.fileURL])

        let column = NSTableColumn(identifier: SidebarIdentifiers.mainColumn)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)

        // The sidebar's material fills the window's full height; the list starts below the
        // traffic lights via the safe area, with no app-name header or section label above
        // it — the projects are the sidebar's whole content, so a heading would only repeat
        // what is already visible.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: SidebarDefaults.contentTopInset
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -SidebarDefaults.footerHeight
            )
        ])
    }

    /// Shown centred in the list area while no project has been added, pointing at the two
    /// ways to add one. Hidden the moment the list has content.
    private func setupEmptyState() {
        let title = NSTextField(labelWithString: SidebarStrings.emptyTitle)
        title.font = .systemFont(ofSize: SidebarDefaults.emptyTitleFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: SidebarStrings.emptySubtitle)
        subtitle.font = .systemFont(ofSize: SidebarDefaults.emptySubtitleFontSize)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = SidebarDefaults.emptyStateSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        emptyStateView = stack

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: SidebarDefaults.emptyStateInset
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -SidebarDefaults.emptyStateInset
            )
        ])
    }

    /// Footer holding the add-project control and the settings cogwheel, pinned below the list
    /// behind a hairline. Add sits at the leading edge; settings mirrors it at the trailing one.
    private func setupFooter() {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addButton = HoverTintButton()
        addButton.title = " Add Project"
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Project")
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: SidebarRowDefaults.sessionFontSize)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addProjectClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        // A quiet icon-only twin of Add Project, so settings is reachable without leaving the
        // window. It carries no title, so the row reads as "add on the left, settings opposite".
        settingsButton = HoverTintButton()
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = "Settings"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(separator)
        view.addSubview(addButton)
        view.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -SidebarDefaults.footerHeight
            ),

            addButton.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: SidebarDefaults.footerInset
            ),
            addButton.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -SidebarDefaults.footerInset
            ),

            settingsButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -SidebarDefaults.footerInset
            ),
            settingsButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])
    }

    @objc private func settingsClicked() {
        delegate?.projectSidebarDidToggleSettings(self)
    }

    private func observeStoreChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(projectsDidChange),
            name: .projectsDidChange,
            object: nil
        )
    }

}

// MARK: - Public Methods

extension ProjectSidebarViewController {

    /// Rebuilds the outline from the store, preserving expansion and selection.
    func reload() {
        let selectedSessionID = selectedNode()?.sessionID ?? ProjectStore.shared.selectedSessionID

        rootNodes = Self.buildRootNodes(from: ProjectStore.shared.projects)

        emptyStateView.isHidden = !rootNodes.isEmpty

        outlineView.reloadData()

        for node in rootNodes {
            outlineView.expandItem(node)
        }

        for node in allProjectNodes {
            let project = ProjectStore.shared.project(withID: node.projectID)
            if project?.isExpanded ?? true {
                outlineView.expandItem(node)
            }
        }

        if let selectedSessionID {
            select(sessionID: selectedSessionID, notifyDelegate: false)
        }
    }

    /// Arranges projects into the tree, grouping only where a repository has more than one
    /// checkout added. A single-checkout repository stays a plain project row, so the extra
    /// level never appears without cause.
    private static func buildRootNodes(from projects: [Project]) -> [NSObject] {
        let identities = projects.map { GitInfo.repositoryIdentity(for: $0.folderPath) }

        var checkoutCounts: [String: Int] = [:]
        for identity in identities.compactMap({ $0 }) {
            checkoutCounts[identity, default: 0] += 1
        }

        var roots: [NSObject] = []
        var groupsByIdentity: [String: RepoGroupNode] = [:]

        for (project, identity) in zip(projects, identities) {
            let node = ProjectNode(projectID: project.id)
            // Archived sessions are gathered separately, below the projects.
            node.sessionNodes = project.sessions
                .filter { !$0.isArchived }
                .map { SessionNode(sessionID: $0.id) }

            guard let identity, checkoutCounts[identity, default: 0] > 1 else {
                roots.append(node)
                continue
            }

            if let group = groupsByIdentity[identity] {
                group.projectNodes.append(node)
                continue
            }

            let group = RepoGroupNode(name: GitInfo.repositoryName(forIdentity: identity))
            group.projectNodes.append(node)
            groupsByIdentity[identity] = group
            roots.append(group)
        }

        // Archived sessions are not shown here at all — they live in Settings, so the sidebar
        // stays a list of what is active.
        return roots
    }

    /// Refreshes a single session's row, used for frequent updates such as title changes.
    func refreshRow(sessionID: UUID) {
        guard let node = sessionNode(for: sessionID) else { return }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        outlineView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    /// Refreshes the project row owning a session, re-reading its branch.
    ///
    /// Agents switch branches, so the row is refreshed when a session stops working — the
    /// moment it is most likely to have just changed — rather than by polling. The branch
    /// itself now shows in the hover popover, whose data the reconfigure refreshes; a grouped
    /// checkout is also named by its branch, so its title follows too.
    func refreshProjectRow(forSessionID sessionID: UUID) {
        guard let node = sessionNode(for: sessionID),
              let project = allProjectNodes.first(where: { $0.sessionNodes.contains(node) })
        else { return }

        let row = outlineView.row(forItem: project)
        guard row >= 0 else { return }

        outlineView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    /// Refreshes row contents without rebuilding, used when running state changes.
    func refreshRows() {
        let allRows = IndexSet(integersIn: 0..<outlineView.numberOfRows)
        let allColumns = IndexSet(integersIn: 0..<outlineView.numberOfColumns)
        outlineView.reloadData(forRowIndexes: allRows, columnIndexes: allColumns)
    }

    /// Selects a session row, optionally without informing the delegate.
    ///
    /// The delegate is invoked directly rather than via the selection notification, which
    /// does not fire when the requested row is already selected.
    func select(sessionID: UUID, notifyDelegate: Bool = true) {
        guard let node = sessionNode(for: sessionID) else { return }

        // Expand the whole chain: a grouped checkout sits under a repository heading.
        if let project = allProjectNodes.first(where: { $0.sessionNodes.contains(node) }) {
            if let group = outlineView.parent(forItem: project) {
                outlineView.expandItem(group)
            }
            outlineView.expandItem(project)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false

        guard notifyDelegate else { return }

        ProjectStore.shared.selectedSessionID = sessionID
        delegate?.projectSidebar(self, didSelectSession: sessionID)
    }

    /// Swaps the sidebar between the project list and the settings section list, so opening
    /// settings replaces the sidebar rather than adding a second one beside it.
    func setSettingsMode(_ on: Bool) {
        isSettingsMode = on

        if on {
            let sidebar = settingsSidebar ?? makeSettingsSidebar()
            sidebar.isHidden = false
            sidebar.select(0)
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            addButton.isHidden = true
            settingsButton.contentTintColor = .controlAccentColor
        } else {
            settingsSidebar?.isHidden = true
            scrollView.isHidden = false
            emptyStateView.isHidden = !rootNodes.isEmpty
            addButton.isHidden = false
            settingsButton.contentTintColor = .secondaryLabelColor
        }
    }

    private func makeSettingsSidebar() -> SettingsSidebar {
        let sidebar = SettingsSidebar(items: SettingsPages.sidebarItems)
        sidebar.onSelect = { [weak self] index in
            guard let self else { return }
            self.delegate?.projectSidebar(self, didSelectSettingsPage: index)
        }
        view.addSubview(sidebar)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: SidebarDefaults.contentTopInset + Design.Spacing.small
            ),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.medium),
            sidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.medium),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -SidebarDefaults.footerHeight)
        ])

        settingsSidebar = sidebar
        return sidebar
    }

}

// MARK: - Actions & Menus

/// Everything the sidebar does in response to clicks: toolbar-less footer actions, context
/// menu commands, and the per-row hover menu. Split from the class body purely for size.
private extension ProjectSidebarViewController {

    @objc private func addProjectClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to add as a project."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addProject(folderURL: url)
        }
    }

    private func addProject(folderURL: URL) {
        let project = ProjectStore.shared.addProject(folderURL: folderURL)
        reload()
        delegate?.projectSidebar(self, didAddProject: project)
    }

    @objc private func newSessionClicked(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? NewSessionRequest,
              let projectID = contextProjectID() else { return }

        createSession(request: request, in: projectID)
    }

    /// Creates a session and selects it, which starts the agent.
    private func createSession(request: NewSessionRequest, in projectID: UUID) {
        guard let session = ProjectStore.shared.addSession(
            to: projectID,
            kind: request.kind,
            accountHandle: request.accountHandle
        ) else { return }

        ProjectStore.shared.setProject(id: projectID, expanded: true)

        reload()
        select(sessionID: session.id)
    }

    @objc private func renameClicked() {
        guard let row = contextRow() else { return }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            promptRename(
                title: "Rename Project",
                current: ProjectStore.shared.project(withID: node.projectID)?.name ?? ""
            ) { newName in
                ProjectStore.shared.renameProject(id: node.projectID, to: newName)
                self.reload()
            }
        } else if let node = outlineView.item(atRow: row) as? SessionNode {
            let session = ProjectStore.shared.session(withID: node.sessionID)
            promptRename(
                title: "Rename Session",
                current: session?.customTitle ?? "",
                placeholder: session?.displayTitle ?? "",
                allowsEmpty: true
            ) { newTitle in
                ProjectStore.shared.renameSession(id: node.sessionID, to: newTitle)
                self.reload()
            }
        }
    }

    @objc private func removeClicked() {
        guard let row = contextRow() else { return }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            removeProject(node.projectID)
        } else if let node = outlineView.item(atRow: row) as? SessionNode {
            removeSession(node.sessionID)
        }
    }

    private func removeProject(_ projectID: UUID) {
        guard let project = ProjectStore.shared.project(withID: projectID) else { return }

        let runningCount = project.sessions.filter {
            AgentRuntime.shared.isRunning(sessionID: $0.id)
        }.count

        let alert = NSAlert()
        alert.messageText = "Remove \"\(project.name)\"?"
        alert.informativeText = runningCount > 0
            ? "\(runningCount) running session(s) will be terminated. Saved conversations are not deleted."
            : "Its sessions are removed from the sidebar. Saved conversations are not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for session in project.sessions {
            AgentRuntime.shared.discard(sessionID: session.id)
        }

        ProjectStore.shared.removeProject(id: projectID)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    private func removeSession(_ sessionID: UUID) {
        AgentRuntime.shared.discard(sessionID: sessionID)
        ProjectStore.shared.removeSession(id: sessionID)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    @objc private func revealInFinderClicked() {
        guard let row = contextRow(),
              let node = outlineView.item(atRow: row) as? ProjectNode,
              let project = ProjectStore.shared.project(withID: node.projectID) else { return }

        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    @objc private func projectsDidChange() {
        // A full rebuild rather than a row refresh: this fires on structural changes — a
        // session archived or unarchived (possibly from Settings, in another window), added or
        // removed — which add and drop rows. `reload` preserves selection and expansion.
        reload()
    }

    // MARK: - Private Methods

    private func selectedNode() -> SessionNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? SessionNode
    }

    private func sessionNode(for sessionID: UUID) -> SessionNode? {
        allProjectNodes.flatMap(\.sessionNodes).first { $0.sessionID == sessionID }
    }

    /// The row a context menu action applies to: the clicked row, else the selected row.
    private func contextRow() -> Int? {
        let clicked = outlineView.clickedRow
        let row = clicked >= 0 ? clicked : outlineView.selectedRow
        return row >= 0 ? row : nil
    }

    /// The project a context menu action applies to, whether a project or session was clicked.
    private func contextProjectID() -> UUID? {
        guard let row = contextRow() else { return nil }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            return node.projectID
        }
        if let node = outlineView.item(atRow: row) as? SessionNode {
            return ProjectStore.shared.project(forSessionID: node.sessionID)?.id
        }
        return nil
    }

    /// Prompts for a new name.
    ///
    /// When `allowsEmpty` is set, clearing the field is meaningful — it drops a custom name
    /// so the automatic one applies again — and is passed through rather than ignored.
    private func promptRename(
        title: String,
        current: String,
        placeholder: String = "",
        allowsEmpty: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if allowsEmpty {
            alert.informativeText = "Leave empty to use the name reported by the terminal."
        }
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(
            x: 0, y: 0,
            width: SidebarDefaults.renameFieldWidth,
            height: SidebarDefaults.renameFieldHeight
        ))
        textField.stringValue = current
        textField.placeholderString = placeholder
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard allowsEmpty || !trimmed.isEmpty else { return }
        completion(trimmed)
    }

    /// Shows a row's actions beneath its hover button.
    ///
    /// Archiving is offered rather than deletion, since a session's conversation outlives the
    /// app and filing it away should not destroy anything.
    private func showRowActions(for sessionID: UUID, from anchor: NSView) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }

        let menu = NSMenu()
        actionSessionID = sessionID

        // The sidebar only ever lists unarchived sessions, so this is always "Archive";
        // restoring one happens from Settings, where the archived sessions live.
        menu.addItem(withTitle: "Archive", action: #selector(archiveClicked), keyEquivalent: "")

        if AgentRuntime.shared.isRunning(sessionID: sessionID) {
            menu.addItem(withTitle: "Close Session", action: #selector(closeSessionClicked), keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename Session…", action: #selector(renameSessionClicked), keyEquivalent: "")
        addMoveToAccountItem(to: menu, for: session)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Session", action: #selector(deleteSessionClicked), keyEquivalent: "")

        for item in menu.items { item.target = self }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.maxY),
            in: anchor
        )
    }

    /// Adds a "Move to Account" submenu when the conversation can move — it resumes by id, has
    /// a transcript recorded, and there is another account of the same agent to move it to.
    private func addMoveToAccountItem(to menu: NSMenu, for session: AgentSession) {
        guard let project = ProjectStore.shared.project(forSessionID: session.id),
              SessionMigration.canMigrate(session, in: project) else { return }

        let submenu = NSMenu()
        for account in SessionMigration.destinations(for: session) {
            let item = NSMenuItem(
                title: accountMenuLabel(account),
                action: #selector(moveToAccountClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = account
            submenu.addItem(item)
        }

        let moveItem = NSMenuItem(title: "Move to Account", action: nil, keyEquivalent: "")
        moveItem.submenu = submenu
        menu.addItem(moveItem)
    }

    private func accountMenuLabel(_ account: AgentAccount) -> String {
        account.emoji.map { "\($0)  \(account.displayName)" } ?? account.displayName
    }

    // MARK: - Row Actions

    @objc private func moveToAccountClicked(_ sender: NSMenuItem) {
        guard let sessionID = actionSessionID,
              let account = sender.representedObject as? AgentAccount else { return }

        switch SessionMigration.move(sessionID: sessionID, to: account) {
        case .success:
            reload()
        case .failure(let error):
            presentMigrationError(error)
        }
    }

    private func presentMigrationError(_ error: SessionMigration.MoveError) {
        let alert = NSAlert()
        alert.messageText = "Couldn't move the conversation"
        alert.informativeText = error.message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func archiveClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, setArchived: true, for: sessionID)
    }

    @objc private func closeSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        AgentRuntime.shared.discard(sessionID: sessionID)
        reload()
    }

    @objc private func renameSessionClicked() {
        guard let sessionID = actionSessionID,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        promptRename(
            title: "Rename Session",
            current: session.customTitle ?? "",
            placeholder: session.displayTitle,
            allowsEmpty: true
        ) { newTitle in
            ProjectStore.shared.renameSession(id: sessionID, to: newTitle)
            self.reload()
        }
    }

    @objc private func deleteSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        removeSession(sessionID)
    }

    // MARK: - Context Menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

// MARK: - NSOutlineViewDataSource

extension ProjectSidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootNodes.count }

        if let group = item as? RepoGroupNode { return group.projectNodes.count }
        if let project = item as? ProjectNode { return project.sessionNodes.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootNodes[index] }

        if let group = item as? RepoGroupNode { return group.projectNodes[index] }
        if let project = item as? ProjectNode { return project.sessionNodes[index] }
        return rootNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ProjectNode || item is RepoGroupNode
    }

    // MARK: Drag and Drop

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Only folders dropped onto the list background become new projects.
        guard item == nil, droppedFolderURLs(from: info).isEmpty == false else { return [] }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let folders = droppedFolderURLs(from: info)
        guard !folders.isEmpty else { return false }

        for folder in folders {
            ProjectStore.shared.addProject(folderURL: folder)
        }
        reload()
        return true
    }

    /// Extracts directory URLs from a drag, ignoring dropped files.
    private func droppedFolderURLs(from info: NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return [] }

        return urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }
}

// MARK: - NSOutlineViewDelegate

extension ProjectSidebarViewController: NSOutlineViewDelegate {

    /// Reuses a cell of the given type, creating it on first use.
    private func dequeueCell<Cell: NSTableCellView>(
        _ identifier: NSUserInterfaceItemIdentifier,
        make: () -> Cell
    ) -> Cell {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? Cell {
            return cell
        }

        let cell = make()
        cell.identifier = identifier
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let groupNode = item as? RepoGroupNode {
            let cell = dequeueCell(SidebarIdentifiers.repoCell) { ProjectRowView() }
            cell.configureAsRepository(named: groupNode.name)
            return cell
        }

        if let projectNode = item as? ProjectNode {
            guard let project = ProjectStore.shared.project(withID: projectNode.projectID) else { return nil }

            let cell = dequeueCell(SidebarIdentifiers.projectCell) { ProjectRowView() }

            // Inside a group the repository name is already above, so the checkout is
            // identified by its branch instead of repeating the folder name.
            let isGrouped = outlineView.parent(forItem: projectNode) is RepoGroupNode

            // A collapsed project says how many sessions it is hiding; expanded, the
            // sessions speak for themselves.
            let hiddenSessions = outlineView.isItemExpanded(projectNode)
                ? 0
                : projectNode.sessionNodes.count

            cell.configure(
                with: project,
                style: isGrouped ? .checkout : .standalone,
                collapsedSessionCount: hiddenSessions
            )
            return cell
        }

        if let sessionNode = item as? SessionNode {
            guard let session = ProjectStore.shared.session(withID: sessionNode.sessionID) else { return nil }

            let cell = dequeueCell(SidebarIdentifiers.sessionCell) { SessionRowView() }

            cell.configure(
                with: session,
                activity: AgentRuntime.shared.activity(sessionID: sessionNode.sessionID)
            )
            cell.onAction = { [weak self] sessionID, anchor in
                self?.showRowActions(for: sessionID, from: anchor)
            }
            return cell
        }

        return nil
    }

    /// Clickable rows highlight under the pointer; group headings do not, since they only
    /// respond at their disclosure triangle.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard item is ProjectNode || item is SessionNode else { return nil }
        return SidebarHoverRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // Project rows are a single line — the branch that used to add a second one now lives
        // in the hover popover — so they take the compact height.
        if item is ProjectNode {
            return SidebarDefaults.projectCompactRowHeight
        }

        // Headings get extra height, which reads as space between groups.
        if item is RepoGroupNode {
            return SidebarDefaults.headingRowHeight
        }

        return SidebarDefaults.rowHeight
    }

    /// Sessions open their terminal; projects open the composer. Repository headings group
    /// their checkouts and select nothing themselves.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SessionNode || item is ProjectNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }

        let item = outlineView.item(atRow: outlineView.selectedRow)

        if let node = item as? SessionNode {
            ProjectStore.shared.selectedSessionID = node.sessionID
            delegate?.projectSidebar(self, didSelectSession: node.sessionID)
            return
        }

        if let node = item as? ProjectNode {
            delegate?.projectSidebar(self, didSelectProject: node.projectID)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ProjectNode else { return }
        ProjectStore.shared.setProject(id: node.projectID, expanded: true)
        reloadRow(for: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? ProjectNode else { return }
        ProjectStore.shared.setProject(id: node.projectID, expanded: false)
        reloadRow(for: node)
    }

    /// Refreshes a single row's cell, used when its count badge changes with expansion.
    private func reloadRow(for item: NSObject) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }

        outlineView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }
}

// MARK: - NSMenuDelegate

extension ProjectSidebarViewController: NSMenuDelegate {

    /// Builds the context menu for whichever row was clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let row = contextRow() else { return }
        let item = outlineView.item(atRow: row)

        if item is ProjectNode {
            addNewSessionItems(to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename Project…", action: #selector(renameClicked), keyEquivalent: "")
            menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinderClicked), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove Project", action: #selector(removeClicked), keyEquivalent: "")
        } else if item is SessionNode {
            addNewSessionItems(to: menu)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename Session…", action: #selector(renameClicked), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete Session", action: #selector(removeClicked), keyEquivalent: "")
        }

        for menuItem in menu.items {
            menuItem.target = self
        }
    }

    private func addNewSessionItems(to menu: NSMenu) {
        NewSessionMenuBuilder.addItems(
            to: menu,
            target: self,
            action: #selector(newSessionClicked(_:))
        )
    }
}

// MARK: - Hover Tint Button

/// Borderless footer button that brightens under the pointer, so it reads as interactive
/// without carrying a bezel.
private final class HoverTintButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }
}

// MARK: - Sidebar Identifiers

enum SidebarIdentifiers {
    static let mainColumn = NSUserInterfaceItemIdentifier("SidebarMainColumn")
    static let projectCell = NSUserInterfaceItemIdentifier("SidebarProjectCell")
    static let repoCell = NSUserInterfaceItemIdentifier("SidebarRepoCell")
    static let sessionCell = NSUserInterfaceItemIdentifier("SidebarSessionCell")
}

// MARK: - ProjectSidebarViewControllerDelegate

protocol ProjectSidebarViewControllerDelegate: AnyObject {
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSession sessionID: UUID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: UUID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didAddProject project: Project)
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setArchived archived: Bool,
        for sessionID: UUID
    )
    func projectSidebarDidRemoveSessions(_ sidebar: ProjectSidebarViewController)
    func projectSidebarDidToggleSettings(_ sidebar: ProjectSidebarViewController)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSettingsPage index: Int)
}
