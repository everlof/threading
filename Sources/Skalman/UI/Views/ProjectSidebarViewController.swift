import AppKit
import UniformTypeIdentifiers

// MARK: - Project Sidebar View Controller

/// Source list of projects and the agent sessions inside them.
final class ProjectSidebarViewController: NSViewController {

    // MARK: - Properties

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var emptyStateView: NSView!
    private let appEvents = AppEventObservations()

    /// Footer controls, retained so settings mode can hide Add Project and mark the cogwheel.
    private var addButton: HoverTintButton!
    private var settingsButton: HoverTintButton!

    /// The settings section list, shown in place of the projects when settings is open — so
    /// the window never grows a second sidebar.
    private var settingsSidebar: SettingsSidebar?

    /// Covers the sidebar's system material while a style is in force. Absent under System,
    /// where the material is what should be seen — see `applySidebarSurface`.
    private var themeBackdrop: NSView?
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

    /// The session a hover-menu action applies to, set when the menu is opened. Read by the
    /// row-action handlers, which live in `ProjectSidebarSessionActions.swift`.
    var actionSessionID: SessionID?

    /// Pins the row a hover-button menu targets, since a button click does not set the
    /// outline view's `clickedRow`. Non-nil only while such a menu is up.
    private var overrideContextRow: Int?

    /// Branch groups the user collapsed, keyed `projectID:branch`, kept for this run only.
    /// Branch groups are transient — they come and go as sessions move — so persisting
    /// their expansion the way projects persist theirs would outlive the thing it describes.
    private var collapsedBranchKeys: Set<String> = []

    /// Sessions whose side chats the user folded away, for this run only — kept transient
    /// for the same reason as `collapsedBranchKeys`, and because a session with no side
    /// chats has no disclosure triangle to remember a state for.
    private var collapsedSideChatParents: Set<SessionID> = []

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
        applySidebarSurface()
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
        title.textColor = Design.Text.secondary
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: SidebarStrings.emptySubtitle)
        subtitle.font = .systemFont(ofSize: SidebarDefaults.emptySubtitleFontSize)
        subtitle.textColor = Design.Text.tertiary
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
        addButton.contentTintColor = Design.Text.secondary
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
        settingsButton.contentTintColor = Design.Text.secondary
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
        appEvents.observe(ProjectsDidChange.self) { [weak self] _ in
            self?.projectsDidChange()
        }
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applySidebarSurface()
        }
    }

    /// Paints the sidebar's own ground — or deliberately does not.
    ///
    /// The split item wraps the sidebar in a system `NSVisualEffectView`, which is why a theme
    /// otherwise reached everything on screen except the largest surface on it. Under **System**
    /// that material is the right answer: it samples the window's backdrop, so the terminal's
    /// colour tints the sidebar and there is no seam where the two meet.
    ///
    /// Under a **style** the material is what stops the theme meaning anything, so an opaque
    /// backdrop covers it. That trade is the point of picking a style: translucency sampling a
    /// colour the theme did not choose reads as a bug rather than as depth.
    ///
    /// **The backdrop is a subview, and under System it is removed rather than made clear.**
    /// Filling the controller's own view was the obvious approach and was measured to be wrong:
    /// `applySurface` makes a view layer-backed, and a layer-backed child inside the material
    /// stops `.withinWindow` blending from sampling through it — the System sidebar went from
    /// the terminal's near-black to the material's default grey. Adding and removing a subview
    /// leaves the view hierarchy exactly as it was when no style is in force.
    ///
    /// Its own observer rather than part of `AppThemeRefresh`'s sweep, because the *decision*
    /// changes with the theme, not just the colour — and a recorded surface carries a colour.
    private func applySidebarSurface() {
        guard !AppThemeLibrary.current.isSystem else {
            themeBackdrop?.removeFromSuperview()
            themeBackdrop = nil
            return
        }

        let backdrop = themeBackdrop ?? makeThemeBackdrop()
        backdrop.applySurface(fill: Design.Surface.background, radius: 0)
    }

    private func makeThemeBackdrop() -> NSView {
        let backdrop = NSView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        themeBackdrop = backdrop
        return backdrop
    }

}

// MARK: - Public Methods

extension ProjectSidebarViewController {

    /// Rebuilds the outline from the store, preserving expansion and selection.
    func reload() {
        let selectedSessionID = selectedNode()?.sessionID ?? ProjectStore.shared.selectedSessionID

        rootNodes = SidebarTreeBuilder.rootNodes(from: ProjectStore.shared.projects)

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

            // Branch groups open with their project; only ones collapsed by hand stay shut.
            for case let branchNode as BranchGroupNode in node.childNodes
            where !collapsedBranchKeys.contains(Self.branchKey(branchNode)) {
                outlineView.expandItem(branchNode)
            }

            // Side chats do the same beneath the session they were forked from. Read from
            // the flat list, since a parent may sit under a branch group rather than the
            // project itself.
            for sessionNode in node.sessionNodes
            where !sessionNode.childNodes.isEmpty
                && !collapsedSideChatParents.contains(sessionNode.sessionID) {
                outlineView.expandItem(sessionNode)
            }
        }

        if let selectedSessionID {
            select(sessionID: selectedSessionID, notifyDelegate: false)
        }
    }

    private static func branchKey(_ node: BranchGroupNode) -> String {
        "\(node.projectID):\(node.branch)"
    }

    /// Removes a session and its terminal. Shared by the row's context menu and its hover
    /// `⋯` actions (in `ProjectSidebarSessionActions.swift`), so it lives in the internal
    /// extension both files can reach.
    func removeSession(_ sessionID: SessionID) {
        AgentRuntime.shared.discard(sessionID: sessionID)
        ProjectStore.shared.removeSession(id: sessionID)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    /// Prompts for a new name.
    ///
    /// When `allowsEmpty` is set, clearing the field is meaningful — it drops a custom name
    /// so the automatic one applies again — and is passed through rather than ignored.
    func promptRename(
        title: String,
        current: String,
        placeholder: String = "",
        allowsEmpty: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        promptForText(
            title: title,
            message: allowsEmpty
                ? "Leave empty to use the name reported by the terminal."
                : nil,
            confirmTitle: "Rename",
            current: current,
            placeholder: placeholder,
            allowsEmpty: allowsEmpty,
            completion: completion
        )
    }

    /// A one-field modal prompt, shared by every "type a short string" action on these rows —
    /// the renames and the side chat's opening question — so they behave alike.
    func promptForText(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        current: String = "",
        placeholder: String = "",
        allowsEmpty: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if let message {
            alert.informativeText = message
        }
        alert.addButton(withTitle: confirmTitle)
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

    /// Refreshes a single session's row, used for frequent updates such as title changes.
    func refreshRow(sessionID: SessionID) {
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
    func refreshProjectRow(forSessionID sessionID: SessionID) {
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

    /// Selects a project row, which is what puts its composer on screen.
    ///
    /// Starting a session goes through here rather than creating one outright: the composer
    /// is the only place agent, account, model and checkout are actually chosen.
    func select(projectID: ProjectID) {
        guard let node = allProjectNodes.first(where: { $0.projectID == projectID }) else { return }

        if let group = outlineView.parent(forItem: node) {
            outlineView.expandItem(group)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false

        ProjectStore.shared.selectedSessionID = nil
        delegate?.projectSidebar(self, didSelectProject: projectID)
    }

    /// Selects a session row, optionally without informing the delegate.
    ///
    /// The delegate is invoked directly rather than via the selection notification, which
    /// does not fire when the requested row is already selected.
    func select(sessionID: SessionID, notifyDelegate: Bool = true) {
        guard let node = sessionNode(for: sessionID) else { return }

        // Expand the whole chain: a grouped checkout sits under a repository heading, and
        // the session itself may sit under a branch heading.
        if let project = allProjectNodes.first(where: { $0.sessionNodes.contains(node) }) {
            if let group = outlineView.parent(forItem: project) {
                outlineView.expandItem(group)
            }
            outlineView.expandItem(project)

            for case let branchNode as BranchGroupNode in project.childNodes
            where branchNode.sessionNodes.contains(node) {
                outlineView.expandItem(branchNode)
            }
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
            settingsButton.contentTintColor = Design.Surface.accent
        } else {
            settingsSidebar?.isHidden = true
            scrollView.isHidden = false
            emptyStateView.isHidden = !rootNodes.isEmpty
            addButton.isHidden = false
            settingsButton.contentTintColor = Design.Text.secondary
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

    /// The `+` button offers both ways in: a folder that exists, or one made on the spot.
    @objc private func addProjectClicked() {
        let menu = NSMenu()

        let scratch = NSMenuItem(
            title: "Start from Scratch…",
            action: #selector(startFromScratchClicked),
            keyEquivalent: ""
        )
        scratch.target = self
        scratch.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(scratch)

        let existing = NSMenuItem(
            title: "Use an Existing Folder…",
            action: #selector(useExistingFolderClicked),
            keyEquivalent: ""
        )
        existing.target = self
        existing.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(existing)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: addButton.bounds.maxY),
            in: addButton
        )
    }

    @objc private func startFromScratchClicked() {
        ProjectFolderPrompt.createNewFolder { [weak self] url in
            self?.addProject(folderURL: url)
        }
    }

    @objc private func useExistingFolderClicked() {
        ProjectFolderPrompt.chooseExistingFolder { [weak self] url in
            self?.addProject(folderURL: url)
        }
    }

    private func addProject(folderURL: URL) {
        let project = ProjectStore.shared.addProject(folderURL: folderURL)
        reload()
        delegate?.projectSidebar(self, didAddProject: project)
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

    private func removeProject(_ projectID: ProjectID) {
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

    /// Opens Storage, which reports every project rather than only this one.
    ///
    /// Reached from a project because that is where the question occurs to someone — but not
    /// scoped to it, since the build output worth finding is usually in a worktree they were
    /// not thinking about.
    @objc private func reclaimDiskSpaceClicked() {
        guard let index = SettingsPages.all.firstIndex(where: { $0.title == SettingsPages.storageTitle })
        else { return }

        delegate?.projectSidebar(self, didSelectSettingsPage: index)
    }

    @objc private func revealInFinderClicked() {
        guard let row = contextRow(),
              let node = outlineView.item(atRow: row) as? ProjectNode,
              let project = ProjectStore.shared.project(withID: node.projectID) else { return }

        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    private func projectsDidChange() {
        // A full rebuild rather than a row refresh: this fires on structural changes — a
        // session archived or unarchived (possibly from Settings, in another window), added or
        // removed — which add and drop rows. `reload` preserves selection and expansion.
        reload()
    }

    // MARK: - Private Methods

    private func selectedNode() -> SessionNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? SessionNode
    }

    private func sessionNode(for sessionID: SessionID) -> SessionNode? {
        allProjectNodes.flatMap(\.sessionNodes).first { $0.sessionID == sessionID }
    }

    /// The row a context menu action applies to: a hover button's pinned row, else the
    /// clicked row, else the selected row.
    private func contextRow() -> Int? {
        if let overrideContextRow { return overrideContextRow }
        let clicked = outlineView.clickedRow
        let row = clicked >= 0 ? clicked : outlineView.selectedRow
        return row >= 0 ? row : nil
    }

    /// The session a context menu action applies to, when one was clicked.
    ///
    /// Internal rather than private: the theme menu is built in `ProjectSidebarThemeMenu` and
    /// serves the right-click menu as well as the row's `⋯` button.
    func contextSessionID() -> SessionID? {
        guard let row = contextRow(),
              let node = outlineView.item(atRow: row) as? SessionNode else { return nil }
        return node.sessionID
    }

    /// The project a context menu action applies to, whether a project or session was clicked.
    func contextProjectID() -> ProjectID? {
        guard let row = contextRow() else { return nil }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            return node.projectID
        }
        if let node = outlineView.item(atRow: row) as? BranchGroupNode {
            return node.projectID
        }
        if let node = outlineView.item(atRow: row) as? SessionNode {
            return ProjectStore.shared.project(forSessionID: node.sessionID)?.id
        }
        return nil
    }

    // MARK: - Project Actions

    /// The `+` button: the project's new-session choices, split out from its `⋯` menu.
    /// The `⋯` button: everything a project offers but starting a session.
    private func showProjectActions(for projectID: ProjectID, from anchor: NSView) {
        presentProjectMenu(for: projectID, from: anchor) { self.addProjectManagementItems(to: $0) }
    }

    /// Pops a project's menu beneath the button that opened it, pinning the row so the
    /// handlers act on the right project rather than on whatever was last clicked.
    private func presentProjectMenu(
        for projectID: ProjectID,
        from anchor: NSView,
        build: (NSMenu) -> Void
    ) {
        guard let node = allProjectNodes.first(where: { $0.projectID == projectID }) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        let menu = NSMenu()
        build(menu)
        for item in menu.items { item.target = self }

        // A button click leaves `clickedRow` at whatever was last clicked, so the row this
        // menu targets is pinned while it is open. `popUp` is modal and the handlers read
        // `contextRow()` before it returns, so the pin is cleared immediately afterwards.
        overrideContextRow = row
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
        overrideContextRow = nil
    }

    // MARK: - Branch Grouping Options

    /// The menu behind a branch heading's hover gear: the grouping toggle itself — the one
    /// setting that governs the row it hangs from — and the door to the rest of Settings.
    private func showBranchGroupingOptions(from anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(makeBranchGroupingItem())
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "All Settings…",
            action: #selector(settingsClicked),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchor.bounds.maxY),
            in: anchor
        )
    }

    /// The grouping toggle as a menu item, its check showing the current state.
    private func makeBranchGroupingItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Group Sessions by Branch",
            action: #selector(toggleBranchGroupingClicked),
            keyEquivalent: ""
        )
        item.target = self
        item.state = AppSettings.shared.groupsSessionsByBranch ? .on : .off
        return item
    }

    @objc private func toggleBranchGroupingClicked() {
        AppSettings.shared.groupsSessionsByBranch.toggle()
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
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
        if let project = item as? ProjectNode { return project.childNodes.count }
        if let branch = item as? BranchGroupNode { return branch.sessionNodes.count }
        if let session = item as? SessionNode { return session.childNodes.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootNodes[index] }

        if let group = item as? RepoGroupNode { return group.projectNodes[index] }
        if let project = item as? ProjectNode { return project.childNodes[index] }
        if let branch = item as? BranchGroupNode { return branch.sessionNodes[index] }
        if let session = item as? SessionNode { return session.childNodes[index] }
        return rootNodes[index]
    }

    /// A session is expandable only once something was forked from it, so the disclosure
    /// triangle appears on the few rows that have side chats rather than on every row.
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let session = item as? SessionNode { return !session.childNodes.isEmpty }
        return item is ProjectNode || item is RepoGroupNode || item is BranchGroupNode
    }

    // Drag and drop lives in `ProjectSidebarDragDrop.swift`, split purely for size.
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
            cell.onHoverAction = { [weak self] anchor in
                self?.showProjectActions(for: projectNode.projectID, from: anchor)
            }
            return cell
        }

        if let branchNode = item as? BranchGroupNode {
            let cell = dequeueCell(SidebarIdentifiers.branchCell) { ProjectRowView() }

            let hiddenSessions = outlineView.isItemExpanded(branchNode)
                ? 0
                : branchNode.sessionNodes.count

            cell.configureAsBranch(
                named: branchNode.branch,
                collapsedSessionCount: hiddenSessions
            )
            cell.onHoverAction = { [weak self] anchor in
                self?.showBranchGroupingOptions(from: anchor)
            }
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

        // A branch heading sits inside a project, so it takes the compact height rather
        // than the between-groups one.
        if item is BranchGroupNode {
            return SidebarDefaults.projectCompactRowHeight
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
        if let branchNode = notification.userInfo?["NSObject"] as? BranchGroupNode {
            collapsedBranchKeys.remove(Self.branchKey(branchNode))
            reloadRow(for: branchNode)
            return
        }

        if let sessionNode = notification.userInfo?["NSObject"] as? SessionNode {
            collapsedSideChatParents.remove(sessionNode.sessionID)
            return
        }

        guard let node = notification.userInfo?["NSObject"] as? ProjectNode else { return }
        ProjectStore.shared.setProject(id: node.projectID, expanded: true)
        reloadRow(for: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let branchNode = notification.userInfo?["NSObject"] as? BranchGroupNode {
            collapsedBranchKeys.insert(Self.branchKey(branchNode))
            reloadRow(for: branchNode)
            return
        }

        if let sessionNode = notification.userInfo?["NSObject"] as? SessionNode {
            collapsedSideChatParents.insert(sessionNode.sessionID)
            return
        }

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
            addProjectMenuItems(to: menu)
        } else if item is BranchGroupNode {
            // The heading offers the display option that created it, and nothing else — it
            // is a grouping, not a place.
            menu.addItem(makeBranchGroupingItem())
        } else if let node = item as? SessionNode {
            menu.addItem(withTitle: "Rename Session…", action: #selector(renameClicked), keyEquivalent: "")
            menu.addItem(makeSessionThemeItem(for: node.sessionID))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete Session", action: #selector(removeClicked), keyEquivalent: "")
        }

        for menuItem in menu.items {
            menuItem.target = self
        }
    }

    /// The project row's full menu, used by its right-click and by its `⋯` button alike:
    /// starting a session is not in it, because that is what selecting the row does.
    private func addProjectMenuItems(to menu: NSMenu) {
        addProjectManagementItems(to: menu)
    }

    /// Everything a project offers. Sessions are started by selecting the project, which
    /// opens its composer.
    private func addProjectManagementItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Rename Project…", action: #selector(renameClicked), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinderClicked), keyEquivalent: "")
        menu.addItem(makeProjectIconItem())
        if let projectID = contextProjectID() {
            menu.addItem(makeProjectThemeItem(for: projectID))
        }
        menu.addItem(
            withTitle: "Reclaim Disk Space…",
            action: #selector(reclaimDiskSpaceClicked),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(makeBranchGroupingItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove Project", action: #selector(removeClicked), keyEquivalent: "")
    }

    /// The icon submenu: choose one, take a site's favicon, re-run the free discovery,
    /// optionally spend a Codex run on it, and clear it. Research appears only when a Codex
    /// login exists, and is menu-only on purpose — each run costs the user's own usage, so
    /// each is an explicit click, never a background default. A run in flight shows as a
    /// disabled "Researching…", and the last run's full output stays openable from here.
    private func makeProjectIconItem() -> NSMenuItem {
        let project = contextProjectID().flatMap { ProjectStore.shared.project(withID: $0) }

        let submenu = NSMenu()
        submenu.addItem(
            withTitle: "Choose Icon…",
            action: #selector(chooseProjectIconClicked),
            keyEquivalent: ""
        )
        submenu.addItem(
            withTitle: "Use Website Favicon…",
            action: #selector(useWebsiteFaviconClicked),
            keyEquivalent: ""
        )
        submenu.addItem(
            withTitle: "Find Icon Automatically",
            action: #selector(findProjectIconClicked),
            keyEquivalent: ""
        )

        let isResearching = project.map {
            ProjectIconResearch.runningProjectIDs.contains($0.id)
        } ?? false

        if isResearching {
            // Action-less, so the menu's auto-enabling leaves it disabled.
            submenu.addItem(withTitle: "Researching…", action: nil, keyEquivalent: "")
        } else if !AgentAccountDiscovery.accounts(for: .codex).isEmpty {
            submenu.addItem(
                withTitle: "Research Icon with Codex",
                action: #selector(researchProjectIconClicked),
                keyEquivalent: ""
            )
        }

        if let project, FileManager.default.fileExists(
            atPath: ProjectIconResearch.recordURL(for: project.id).path
        ) {
            submenu.addItem(
                withTitle: "Open Last Research Log",
                action: #selector(openResearchLogClicked),
                keyEquivalent: ""
            )
        }

        if project?.icon != nil {
            submenu.addItem(.separator())
            submenu.addItem(
                withTitle: "Remove Icon",
                action: #selector(removeProjectIconClicked),
                keyEquivalent: ""
            )
        }

        for item in submenu.items { item.target = self }

        let iconItem = NSMenuItem(title: "Project Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = submenu
        return iconItem
    }

    // MARK: - Project Icon Actions

    @objc private func chooseProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to use as the project's icon."

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            guard let data = try? Data(contentsOf: url),
                  let fileName = ProjectIconStore.store(imageData: data, for: projectID) else {
                self?.presentIconNotice("The file could not be read as an image.")
                return
            }

            ProjectStore.shared.setIcon(
                ProjectIcon(source: .custom, fileName: fileName),
                for: projectID
            )
        }
    }

    @objc private func findProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }

        ProjectIconDiscovery.shared.rediscover(projectID: projectID) { [weak self] found in
            if !found {
                self?.presentIconNotice("No icon was found for this project.")
            }
        }
    }

    @objc private func researchProjectIconClicked() {
        guard let projectID = contextProjectID(),
              let project = ProjectStore.shared.project(withID: projectID) else { return }

        ProjectIconResearch.run(for: project) { [weak self] result in
            guard case .failure(let error) = result else { return }

            // The record answers "what did it actually do?" — point at it when there is one.
            var message = error.message
            let record = ProjectIconResearch.recordURL(for: projectID)
            if FileManager.default.fileExists(atPath: record.path) {
                message += "\n\nThe run's full output: Project Icon > Open Last Research Log."
            }
            self?.presentIconNotice(message)
        }
    }

    @objc private func useWebsiteFaviconClicked() {
        guard let projectID = contextProjectID() else { return }

        promptForWebsite { [weak self] input in
            guard let origin = ProjectIconDiscovery.origin(fromWebsite: input) else {
                self?.presentIconNotice("\"\(input)\" is not a usable web address.")
                return
            }

            // Fetched off the main queue; everything that touches the store hops back.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = ProjectIconDiscovery.websiteIcon(atOrigin: origin)

                DispatchQueue.main.async {
                    guard let data,
                          let fileName = ProjectIconStore.store(imageData: data, for: projectID) else {
                        self?.presentIconNotice("No favicon was found at \(origin.absoluteString).")
                        return
                    }

                    // The user named the site, so this is their choice — never replaced
                    // automatically, exactly like a file they picked.
                    ProjectStore.shared.setIcon(
                        ProjectIcon(source: .custom, fileName: fileName),
                        for: projectID
                    )
                }
            }
        }
    }

    @objc private func openResearchLogClicked() {
        guard let projectID = contextProjectID() else { return }
        NSWorkspace.shared.open(ProjectIconResearch.recordURL(for: projectID))
    }

    /// Asks for the site whose favicon to take, e.g. `sonda.io`.
    private func promptForWebsite(completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Use Website Favicon"
        alert.informativeText = "The site's touch icon or favicon becomes the project's icon."
        alert.addButton(withTitle: "Use Favicon")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(
            x: 0, y: 0,
            width: SidebarDefaults.renameFieldWidth,
            height: SidebarDefaults.renameFieldHeight
        ))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        completion(trimmed)
    }

    @objc private func removeProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }
        ProjectStore.shared.setIcon(nil, for: projectID)
    }

    /// A quiet informational alert; icon actions have no state worth a warning style.
    private func presentIconNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Project Icon"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// MARK: - Sidebar Identifiers

enum SidebarIdentifiers {
    static let mainColumn = NSUserInterfaceItemIdentifier("SidebarMainColumn")
    static let projectCell = NSUserInterfaceItemIdentifier("SidebarProjectCell")
    static let repoCell = NSUserInterfaceItemIdentifier("SidebarRepoCell")
    static let branchCell = NSUserInterfaceItemIdentifier("SidebarBranchCell")
    static let sessionCell = NSUserInterfaceItemIdentifier("SidebarSessionCell")
}

// MARK: - ProjectSidebarViewControllerDelegate

protocol ProjectSidebarViewControllerDelegate: AnyObject {
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSession sessionID: SessionID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: ProjectID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didAddProject project: Project)
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setArchived archived: Bool,
        for sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setUsesNativeUI usesNative: Bool,
        for sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        createSideChatOf sessionID: SessionID,
        prompt: String?
    )
    func projectSidebarDidRemoveSessions(_ sidebar: ProjectSidebarViewController)
    func projectSidebarDidToggleSettings(_ sidebar: ProjectSidebarViewController)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSettingsPage index: Int)
}
