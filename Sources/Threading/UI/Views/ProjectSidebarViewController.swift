import AppKit
import ThreadingExtensionKit
import UniformTypeIdentifiers

// MARK: - Project Sidebar View Controller

/// Source list of projects and the agent sessions inside them.
final class ProjectSidebarViewController: NSViewController {

    // MARK: - Properties

    private lazy var outlineView: ThemedOutlineView = {
        let outline = ThemedOutlineView()
        outline.style = .inset
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = SidebarDefaults.indentationPerLevel
        outline.dataSource = self
        outline.delegate = self
        outline.onContextMenu = { [weak self] row, anchor in
            self?.presentRowContextMenu(row: row, anchor: anchor) ?? false
        }
        outline.registerForDraggedTypes([.fileURL])
        let column = NSTableColumn(identifier: SidebarIdentifiers.mainColumn)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        return outline
    }()
    private lazy var scrollView: NSScrollView = {
        let scroll = ThemedScrollView()
        scroll.surfaceRole = .sidebarNavigator
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }()
    private lazy var emptyStateView: NSView = {
        let title = NSTextField(labelWithString: SidebarStrings.emptyTitle)
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.secondary
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: SidebarStrings.emptySubtitle)
        subtitle.applyFont(.detail())
        subtitle.textColor = Design.Text.tertiary
        subtitle.alignment = .center
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = SidebarDefaults.emptyStateSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private let appEvents = AppEventObservations()

    /// The persisted tree this controller presents. Production uses the app-wide store; an
    /// injected store lets deterministic UI workloads exercise the real outline controller
    /// without reading or mutating the user's projects.
    let projectStore: ProjectStore

    /// Retained so settings mode can mark it as the open page.
    private lazy var settingsButton: ThemedButton = {
        let button = ThemedButton()
        button.title = L10n.string("Settings")
        button.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L10n.string("Settings")
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        button.isBordered = false
        button.applyFont(.controlRegular)
        button.target = self
        button.action = #selector(settingsClicked)
        return button
    }()
    /// Settings is the sidebar's one standing destination. Surfaces that live in the *trailing*
    /// panel are opened from that panel — see `DisplayPaneController.newTabEntries(for:)` — so
    /// this column never carries a permanent door to something it does not show.
    // A non-release build carries its channel mark beside Settings — see `BuildChannelBadge`.
    private lazy var footer = PaneFooterView(
        leading: [settingsButton, BuildChannelBadge.make()].compactMap { $0 },
        margin: .paneEdge
    )

    /// Where a receipt for something the list just did appears — above the footer, in the
    /// column the row left from. See `present(_:)`.
    private lazy var toasts = ToastPresenter(host: view, above: footer.topAnchor)

    /// The band above the list: the brand row at its leading edge, the list's own controls
    /// at its trailing one. The list starts at its bottom. In settings mode the *controls*
    /// hide — they act on the list, which is not on screen — while the band and the brand
    /// stay, because the brand is the window's, not the list's.
    private lazy var header = PaneHeaderView(
        leading: [brand],
        trailing: [addButton, arrangeButton],
        margin: .paneEdge
    )
    /// The Threading mark and wordmark — or whatever the current chrome's sidebar brand says.
    private lazy var brand = SidebarBrandView()
    /// Adds a project — the `+` at the sidebar's top.
    private lazy var addButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("Add Project"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Add Project")
        button.presentsMenu = true
        button.onPress = { [weak self] in self?.presentAddProjectMenu() }
        return button
    }()
    /// Opens the grouping and sorting menu — the sidebar's own view options, kept beside
    /// the list they arrange rather than in Settings.
    private lazy var arrangeButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SidebarDefaults.arrangementSymbol,
            accessibility: SidebarStrings.arrangementOptions,
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = SidebarStrings.arrangementOptions
        button.presentsMenu = true
        button.onPress = { [weak self] in self?.showArrangementOptions() }
        return button
    }()

    /// The launch flourish plays once per app run, not once per window or per settings
    /// round-trip.
    private static var hasPlayedLaunchAnimation = false

    /// The density the outline is currently *drawn* at — not the setting's live value, which
    /// is what lets `applyTreeDensity` answer only the changes that move a frame. See
    /// `AppSettings.compactsSidebarTree` for what the compact tree is.
    private var presentedTreeIsCompact = false

    /// The settings section list, shown in place of the projects when settings is open — so
    /// the window never grows a second sidebar.
    private var settingsSidebar: SettingsSidebar?

    /// Builds the Theme submenu for the row menus; retained because the items target it.
    let themeMenuBuilder = ThemeMenuBuilder()

    /// The sidebar's ground, under every theme — see `applySidebarSurface`.
    private var themeBackdrop: SidebarBackdropView?
    private(set) var isSettingsMode = false

    /// Top level of the tree: a `RepoGroupNode` for repositories with several checkouts,
    /// a bare `ProjectNode` for everything else.
    private var rootNodes: [NSObject] = []

    /// The shape the outline is currently showing, so a change that leaves it alone can refresh
    /// the rows rather than rebuild them — and one that does not can be told to the outline as
    /// the rows that arrived, left and moved. See `reload`.
    private var renderedShape = SidebarTreeShape()

    /// Every presented node by identity, so a step naming a parent can find the object the
    /// outline was handed. Rebuilt with the other indexes.
    private var nodesByKey: [SidebarNodeKey: NSObject] = [:]

    /// A reload arriving while one is in flight, held until it is over.
    ///
    /// Nothing reaches here today: store events are delivered synchronously, but no path inside
    /// a reload edits the store. It is guarded anyway, for the reason the tree builder refuses a
    /// cycle nothing can create (see `attachSideChats`). `reload` now opens an update block and
    /// hands the outline indexes into the tree it is holding, so a second pass rebuilding that
    /// tree underneath is not a wrong-looking row but an AppKit exception — and this reload is
    /// reached from a dozen call sites, including a notification posted from anywhere in the app.
    private var isReloading = false
    private var needsReloadAfterCurrent = false

    /// Stable indexes over the rendered node objects. Row refresh and navigation are frequent;
    /// neither should allocate a flattened tree or recursively search thousands of unrelated
    /// sessions just to find one identity.
    private var allProjectNodes: [ProjectNode] = []
    private var projectNodesByID: [ProjectID: ProjectNode] = [:]
    private var sessionNodesByID: [SessionID: SessionNode] = [:]
    private var projectNodesBySessionID: [SessionID: ProjectNode] = [:]
    private var ancestorsBySessionID: [SessionID: [NSObject]] = [:]
    private var terminalNodesByID: [TerminalID: TerminalNode] = [:]
    private var projectNodesByTerminalID: [TerminalID: ProjectNode] = [:]
    private var ancestorsByTerminalID: [TerminalID: [NSObject]] = [:]

    weak var delegate: ProjectSidebarViewControllerDelegate?

    /// Suppresses the selection delegate callback during programmatic selection.
    private var suppressSelectionCallback = false

    /// Which rows are spinning and why. Kept at controller level so a reused row gets the same
    /// state when it scrolls out and back into view.
    private var loadingState = SessionLoadingState()

    /// Sweeps loading raises nobody lowered — see `SessionLoadingState.lowerExpired`. Alive
    /// only while something is spinning, so an idle sidebar schedules nothing.
    private var loadingWatchdog: Timer?

    /// Invalidates a deferred presentation when the user makes another selection first.
    private var selectionRequestGeneration = 0

    /// The session a hover-menu action applies to, set when the menu is opened. Read by the
    /// row-action handlers, which live in `ProjectSidebarSessionActions.swift`.
    var actionSessionID: SessionID?

    /// Pins the row a hover-button menu targets, since a button click does not set the
    /// outline view's `clickedRow`. Non-nil only while such a menu is up.
    private var overrideContextRow: Int?

    /// Whichever sidebar dropdown or context menu is up — one at a time, released from its
    /// own dismissal.
    private var activeMenuSession: AnyObject?

    /// Branch groups the user collapsed, keyed `projectID:branch`, kept for this run only.
    /// Branch groups are transient — they come and go as sessions move — so persisting
    /// their expansion the way projects persist theirs would outlive the thing it describes.
    private var collapsedBranchKeys: Set<String> = []

    /// Sessions whose side chats the user folded away, for this run only — kept transient
    /// for the same reason as `collapsedBranchKeys`, and because a session with no side
    /// chats has no disclosure triangle to remember a state for.
    private var collapsedSideChatParents: Set<SessionID> = []

    // MARK: - Lifecycle

    init(projectStore: ProjectStore = .shared) {
        self.projectStore = projectStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The bands first: the list ends at the footer's top and starts at the header's
        // bottom, so both have to exist to be constrained against.
        setupFooter()
        setupHeader()
        setupOutlineView()
        setupEmptyState()
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

    override func viewDidAppear() {
        super.viewDidAppear()

        // The launch flourish: the mark stitches itself in the first time the sidebar is on
        // screen this run. Once per run, not per appearance — a settings round-trip or a
        // window re-open replaying it would turn a greeting into a tic.
        if !Self.hasPlayedLaunchAnimation {
            Self.hasPlayedLaunchAnimation = true
            brand.playLaunchAnimation()
        }
    }

}

// MARK: - Setup

private extension ProjectSidebarViewController {

    private func setupOutlineView() {
        // `.inset`, not `.sourceList`, and the difference is a *material*.
        //
        // The two styles draw the same rows and the same inset selection capsule; what
        // `.sourceList` adds is a vibrant background of its own, drawn by the table. That was
        // invisible while the split item wrapped the whole pane in the same material — two
        // identical translucencies stacked — and became the sidebar's whole appearance the
        // moment the pane stopped supplying one: the list sampled the *desktop* through the
        // window, so the column carried a blue-grey wash off whatever wallpaper was behind it
        // and the theme's own ground showed only in the strips the table did not cover.
        //
        // Proven by filling the ground with a flat red: everything the list covered stayed
        // grey-blue, everything it did not turned red.
        // The list already starts below the toolbar, because it is pinned to the safe area two
        // lines down. Left automatic, AppKit insets it a second time for the same titlebar —
        // and on macOS 26 it also installs a scroll-edge-effect material *inside* the scroll
        // view to fade content passing under chrome that this content never reaches. A system
        // material inside app-owned content is precisely what the theme boundary forbids, and
        // the audit caught it the moment the sidebar stopped being wrapped in a material of
        // its own. One pane, one answer about its own insets.
        view.addSubview(scrollView)

        // The sidebar fills the window's full height; the list starts below the header band —
        // which itself starts below the traffic lights via the safe area. Still no app-name
        // label or section heading: the band holds controls that act on the list, not a
        // repetition of what the list already shows.
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: SidebarDefaults.contentTopInset
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])

        // Before the first `reload()`, so the first tree is drawn at the chosen density
        // rather than arriving indented and snapping flat.
        applyTreeDensity(initial: true)
    }

    /// Shown centred in the list area while no project has been added, pointing at the two
    /// ways to add one. Hidden the moment the list has content.
    private func setupEmptyState() {
        let stack = emptyStateView
        view.addSubview(stack)

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

    /// The global destination at the leading edge — icon *and* word, because it is a place the
    /// sidebar reaches rather than an action on the project list. The band's hairline, height
    /// and insets remain `PaneFooterView`'s to state.
    ///
    /// `.paneEdge`, because the sidebar's margin is the list's: the platform's corner
    /// clearance is stated for the whole band's width, and Settings sits well above the
    /// window's bottom curve, so taking it put the gear two steps inboard of every row above
    /// it. See `PaneBandMargin`.
    private func setupFooter() {
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        _ = toasts
    }

    /// Header holding the brand row at the leading edge and the list's two controls — add,
    /// then arrangement — at the trailing one. The band itself — the hairline, the height,
    /// the insets — is `PaneHeaderView`'s to state.
    ///
    /// `.paneEdge`, for the footer's reason and then some: the band runs the sidebar's full
    /// width, so the platform reports the clearance the *traffic lights* need even though the
    /// band begins below them at the safe area. Measured on the running window, the brand was
    /// starting some eighty points in — under the toolbar's sidebar toggle rather than over
    /// the list it names.
    ///
    /// The brand went here rather than staying absent (the band long said "no app-name label")
    /// because the top-left of the sidebar is now a *themed* surface: a chrome may restate the
    /// logo, the name and the face, so the row earns its place as the one thing a chrome can
    /// sign. Adding a project moved up with it — a `+` beside the list it adds to, in the slot
    /// every source-list app puts it.
    private func setupHeader() {
        // The `+` opens its two ways in — existing folder or new — on the press, which is the
        // platform's menu gesture.
        view.addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    @objc private func settingsClicked() {
        delegate?.projectSidebarDidToggleSettings(self)
    }

    private func observeStoreChanges() {
        appEvents.observe(ProjectsDidChange.self) { [weak self] change in
            self?.projectsDidChange(change)
        }
        // No theme observer for the ground: `SidebarBackdropView` re-decides what it shows on
        // every theme change itself, so the controller cannot forget to tell it.
        appEvents.observe(ExtensionIdentityResolversDidChange.self) { [weak self] _ in
            self?.reload()
        }
        appEvents.observe(ExtensionSettingsRegistryDidChange.self) { [weak self] _ in
            self?.extensionSettingsDidChange()
        }
        // The one settings observer this list carries, and it is value-guarded inside: the
        // event fires for every setting, and every other sidebar-shaping setting rebuilds the
        // *tree* and so arrives as `ProjectsDidChange`. Density changes no node — `reload()`
        // would compare shapes, find them equal, and refresh contents without moving a frame —
        // so it takes its own route to a wholesale re-layout.
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.applyTreeDensity()
        }
    }

    /// Installs the sidebar's own ground, under every theme including System.
    ///
    /// The pane is a plain split item (see `MainWindowController.setupSplitViewController`), so
    /// the sidebar supplies its own column and the seam is the split view's hairline rather than
    /// an absence of one. What that column *is* — the platform's sidebar material under the
    /// identity theme, an opaque themed surface under a style — is `SidebarBackdropView`'s own
    /// decision; this controller only says that the sidebar has a ground.
    ///
    /// The backdrop stays a *subview* rather than a fill on the controller's own view, because
    /// the outline view, its scroll view and the footer are all layered over it — one view whose
    /// only job is the ground is what keeps the ordering obvious.
    private func applySidebarSurface() {
        guard themeBackdrop == nil else { return }

        let backdrop = SidebarBackdropView()
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        themeBackdrop = backdrop
    }

}

// MARK: - Public Methods

extension ProjectSidebarViewController {

    /// Shows a receipt for something the list just did, with the way back on it.
    ///
    /// It appears **here**, at the bottom of this column, because this is the column the change
    /// happened in: an archived row leaves the sidebar and the undo puts it back into the
    /// sidebar, so the eye is already on the pane the band arrives in. The other two placements
    /// fail for the same reason from opposite ends — a band centred on the window covers the
    /// composer, and one in the content pane's corner reports a sidebar change somewhere the
    /// sidebar is not.
    func presentToast(_ toast: ToastRequest) {
        toasts.present(toast)
    }

    /// Brings the outline up to date with the store, preserving expansion and selection.
    ///
    /// A change that leaves the tree's *shape* alone refreshes the rows in place instead.
    /// `ProjectsDidChange` fires for content edits as well as structural ones — a rename is
    /// the common case — and rebuilding for those is not merely wasteful: it hands every
    /// row back to the reuse pool, and a recycled cell has no memory of the name it is
    /// replacing, which is exactly what the title's morph animates from.
    ///
    /// A change that *does* move rows is told to the outline as the rows that arrived, left and
    /// moved, rather than as `reloadData`. Both end at the same list; only one of them is a
    /// list that can be watched changing. See `applyStructure`.
    func reload() {
        // Re-entrancy: see `isReloading`.
        guard !isReloading else {
            needsReloadAfterCurrent = true
            return
        }
        isReloading = true
        defer {
            isReloading = false
            if needsReloadAfterCurrent {
                needsReloadAfterCurrent = false
                reload()
            }
        }

        let projects = projectStore.projects
        let reloadSpan = PerformanceRecorder.shared.begin(
            "sidebar.reload",
            category: "sidebar",
            metadata: [
                "projects": String(projects.count),
                "sessions": String(projects.reduce(0) { $0 + $1.sessions.count })
            ]
        )
        var reloadKind = "structural"
        defer {
            reloadSpan.end(metadata: [
                "kind": reloadKind,
                "rows": String(outlineView.numberOfRows)
            ])
        }

        let treeSpan = PerformanceRecorder.shared.begin(
            "sidebar.tree.build",
            category: "sidebar",
            metadata: ["projects": String(projects.count)]
        )
        let rebuilt = SidebarTreeBuilder.rootNodes(from: projects)
        treeSpan.end(metadata: ["roots": String(rebuilt.count)])
        let shape = SidebarTreeShape(roots: rebuilt)

        if shape == renderedShape, !rootNodes.isEmpty {
            // The presented nodes are kept deliberately: the outline identifies rows by
            // object identity, and replacing equivalent nodes would invalidate every row
            // for nothing. Content is read from the store at configure time anyway.
            reloadKind = "content"
            refreshRows()
            return
        }

        let selectedSessionID = selectedNode()?.sessionID ?? projectStore.selectedSessionID
        let selectedTerminalID = selectedTerminalNode()?.terminalID

        let previousShape = renderedShape
        // The rebuild's *content*, on the rows already on screen wherever the identity
        // survived — see `SidebarOutlineUpdate.adopt`.
        rootNodes = SidebarOutlineUpdate.adopt(rebuilt, reusing: rootNodes)
        renderedShape = shape
        rebuildNodeIndexes()

        emptyStateView.isHidden = !rootNodes.isEmpty

        let outlineSpan = PerformanceRecorder.shared.begin(
            "sidebar.outline.apply-structure",
            category: "sidebar",
            metadata: ["roots": String(rootNodes.count)]
        )

        // A list nobody has seen yet has nothing to animate *from*: the first tree arrives
        // whole, as does one whose every row was dropped while the outline showed none.
        //
        // Deliberately not "no steps means reload": a shape that changed always has steps, and
        // reloading whenever it does not would turn a diff that missed something into a blink
        // nobody can see instead of a failing test.
        let isFirstList = previousShape.isEmpty || outlineView.numberOfRows == 0
        let steps = isFirstList
            ? []
            : SidebarOutlineUpdate.steps(from: previousShape, to: shape)
        applyStructure(steps: steps, wholesale: isFirstList)

        if let selectedTerminalID {
            select(terminalID: selectedTerminalID, notifyDelegate: false)
        } else if let selectedSessionID {
            select(sessionID: selectedSessionID, notifyDelegate: false)
        }
        outlineSpan.end(metadata: [
            "rows": String(outlineView.numberOfRows),
            "steps": String(steps.count)
        ])
    }

    /// Tells the outline what moved, then opens whatever should be open.
    ///
    /// **`.effectFade`, and nothing else.** The slide options were measured against this list:
    /// they park the arriving row at the very top of the view for the whole animation and snap
    /// it into place at the end, and `.effectGap` holds it invisible and then pops it in. The
    /// fade is the only one that moves the row it names; the rows *below* it slide either way,
    /// animated by AppKit as a `position` animation on their layers, which is the motion the
    /// eye actually follows.
    ///
    /// Unlike `PaneTransition`, this does not stand down for a window nobody can see. That rule
    /// exists because a pane's completion carries real work and AppKit withholds it off-screen;
    /// nothing here waits on a completion, row animations were measured running and settling in
    /// an unshown window, and standing down would make every hosted fixture assert a motion the
    /// app does not perform.
    private func applyStructure(steps: [SidebarOutlineStep], wholesale: Bool) {
        let animated = !Design.Motion.reducesMotion && !wholesale
        let animation: NSTableView.AnimationOptions = animated ? [.effectFade] : []

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Design.Motion.standard : Design.Motion.immediate
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            if wholesale {
                outlineView.reloadData()
            } else {
                outlineView.beginUpdates()
                for step in steps {
                    switch step {
                    case .remove(let parent, let indexes):
                        outlineView.removeItems(
                            at: indexes,
                            inParent: parent.flatMap { nodesByKey[$0] },
                            withAnimation: animation
                        )

                    case .move(let parent, let from, let to):
                        let node = parent.flatMap { nodesByKey[$0] }
                        outlineView.moveItem(at: from, inParent: node, to: to, inParent: node)

                    case .insert(let parent, let indexes):
                        outlineView.insertItems(
                            at: indexes,
                            inParent: parent.flatMap { nodesByKey[$0] },
                            withAnimation: animation
                        )
                    }
                }
                outlineView.endUpdates()
            }

            expandStandingRows(animated: animated)
        }

        // A move can change which root stands first, and a moved row keeps its view — so the
        // compact tree's rules are re-stamped after every structural pass rather than only
        // where a row view is born (`didAdd`).
        refreshGroupRules()
    }

    /// Opens the rows that are meant to be open. Idempotent — `expandItem` on a row that is
    /// already open does nothing — so this runs after every structural change and only the rows
    /// that just arrived actually move.
    private func expandStandingRows(animated: Bool) {
        let outline = animated ? outlineView.animator() : outlineView

        for node in rootNodes {
            outline.expandItem(node)
        }

        for node in allProjectNodes {
            let project = projectStore.project(withID: node.projectID)
            if project?.isExpanded ?? true {
                outline.expandItem(node)
            }

            // Branch groups open with their project; only ones collapsed by hand stay shut.
            for case let branchNode as BranchGroupNode in node.childNodes
            where !collapsedBranchKeys.contains(Self.branchKey(branchNode)) {
                outline.expandItem(branchNode)
            }

            // Side chats do the same beneath the session they were forked from. Read from
            // the flat list, since a parent may sit under a branch group rather than the
            // project itself.
            for sessionNode in node.sessionNodes
            where !sessionNode.childNodes.isEmpty
                && !collapsedSideChatParents.contains(sessionNode.sessionID) {
                outline.expandItem(sessionNode)
            }
        }
    }

    /// Draws the outline at the density the setting asks for: the ordinary indented tree, or
    /// the compact one — every row starting at `SidebarDefaults.compactCellLeading`, groups
    /// told apart by vertical spacing and a rule instead of depth.
    ///
    /// Density is presentation, not shape: `SidebarTreeBuilder` never reads it and the nodes
    /// are untouched, which is why this cannot ride `reload()` — the shapes would compare
    /// equal and the refresh would move no frame. The wholesale pass re-lays out every row at
    /// its new frame and height and reopens what should be open; `initial` skips it, because
    /// at setup the first `reload()` has not drawn anything to re-lay out.
    func applyTreeDensity(initial: Bool = false) {
        let compact = AppSettings.shared.compactsSidebarTree
        guard initial || compact != presentedTreeIsCompact else { return }

        presentedTreeIsCompact = compact
        outlineView.flattenedIndentation = compact
            ? .init(
                cellLeading: SidebarDefaults.compactCellLeading,
                markerLeading: SidebarDefaults.compactMarkerLeading
            )
            : nil

        guard !initial else { return }
        applyStructure(steps: [], wholesale: true)
    }

    /// Whether the compact tree draws its rule above this row: a top-level group opening
    /// while another stands above it. The first root has the header band's own hairline
    /// above it, and a second line under that one would read as a mistake.
    private func showsGroupRule(forRow row: Int) -> Bool {
        guard presentedTreeIsCompact,
              let item = outlineView.item(atRow: row) as? NSObject,
              outlineView.parent(forItem: item) == nil
        else { return false }
        return rootNodes.first !== item
    }

    /// Re-answers `showsGroupRule` for every row view the outline has built. Cheap enough to
    /// run after any structural pass: it walks built views only and stamping is a no-op where
    /// the answer stands.
    private func refreshGroupRules() {
        for row in 0..<outlineView.numberOfRows {
            guard let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false)
                as? SidebarHoverRowView else { continue }
            rowView.showsGroupRule = showsGroupRule(forRow: row)
        }
    }

    /// Rebuilds all identity and ancestry indexes in one walk whenever the outline's shape
    /// changes. The arrays contain the exact objects handed to `NSOutlineView`.
    private func rebuildNodeIndexes() {
        allProjectNodes.removeAll(keepingCapacity: true)
        projectNodesByID.removeAll(keepingCapacity: true)
        sessionNodesByID.removeAll(keepingCapacity: true)
        projectNodesBySessionID.removeAll(keepingCapacity: true)
        ancestorsBySessionID.removeAll(keepingCapacity: true)
        terminalNodesByID.removeAll(keepingCapacity: true)
        projectNodesByTerminalID.removeAll(keepingCapacity: true)
        ancestorsByTerminalID.removeAll(keepingCapacity: true)
        nodesByKey.removeAll(keepingCapacity: true)

        func walk(
            _ node: NSObject,
            ancestors: [NSObject],
            projectNode: ProjectNode?
        ) {
            if let node = node as? any SidebarOutlineNode {
                nodesByKey[node.sidebarKey] = node
            }

            switch node {
            case let repo as RepoGroupNode:
                for child in repo.projectNodes {
                    walk(child, ancestors: ancestors + [repo], projectNode: nil)
                }

            case let project as ProjectNode:
                allProjectNodes.append(project)
                projectNodesByID[project.projectID] = project
                for child in project.childNodes {
                    walk(child, ancestors: ancestors + [project], projectNode: project)
                }

            case let branch as BranchGroupNode:
                for child in branch.childNodes {
                    walk(child, ancestors: ancestors + [branch], projectNode: projectNode)
                }

            case let session as SessionNode:
                sessionNodesByID[session.sessionID] = session
                ancestorsBySessionID[session.sessionID] = ancestors
                if let projectNode {
                    projectNodesBySessionID[session.sessionID] = projectNode
                }
                for child in session.childNodes {
                    walk(child, ancestors: ancestors + [session], projectNode: projectNode)
                }

            case let terminal as TerminalNode:
                terminalNodesByID[terminal.terminalID] = terminal
                ancestorsByTerminalID[terminal.terminalID] = ancestors
                if let projectNode {
                    projectNodesByTerminalID[terminal.terminalID] = projectNode
                }

            default:
                break
            }
        }

        for root in rootNodes {
            walk(root, ancestors: [], projectNode: nil)
        }
    }

    private static func branchKey(_ node: BranchGroupNode) -> String {
        "\(node.projectID):\(node.branch)"
    }

    /// Removes a session and its terminal. Shared by the row's context menu and its hover
    /// `⋯` actions (in `ProjectSidebarSessionActions.swift`), so it lives in the internal
    /// extension both files can reach.
    /// Deleting asks whatever the session is doing, unlike close and archive, which ask only
    /// when there is a running agent to interrupt: those two keep the session, and this one is
    /// the row itself going. It shipped for a long time with no confirmation at all next to a
    /// Close that had one, which read as Delete being the lesser of the two.
    ///
    /// Both callers are an explicit "delete this row" — the row menu and the outline's Remove.
    /// Removing a *project* does not come through here; it discards its sessions itself, under
    /// its own single confirmation, so this cannot ask a second time per session.
    func removeSession(_ sessionID: SessionID) {
        guard let session = projectStore.session(withID: sessionID) else { return }

        let request = Self.deleteConfirmation(
            for: session,
            isRunning: AgentRuntime.shared.isRunning(sessionID: sessionID)
        )
        guard ConfirmationAlert.ask(request) else { return }

        AgentRuntime.shared.discard(sessionID: sessionID)
        projectStore.removeSession(id: sessionID)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    /// Built separately from being asked, the same seam the close and archive requests offer.
    ///
    /// It says what survives, because "Delete" alone reads as the conversation going with the
    /// row — and it does not: the agent's own transcript stays on disk and can be imported
    /// again. That is the one thing worth knowing before pressing the button, and it is the
    /// same sentence the archived-session delete already says.
    static func deleteConfirmation(
        for session: AgentSession,
        isRunning: Bool
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .deleteSession,
            title: L10n.format("Delete “%@”?", session.displayTitle),
            message: isRunning
                ? L10n.string(
                    "The agent will stop and the session is removed from Threading. The saved "
                        + "conversation on disk is not deleted, so it could still be imported "
                        + "again later."
                )
                : L10n.string(
                    "It is removed from Threading. The saved conversation on disk is not deleted, "
                        + "so it could still be imported again later."
                ),
            confirmTitle: L10n.string("Delete")
        )
    }

    /// Prompts for a new name.
    ///
    /// When `allowsEmpty` is set, clearing the field is meaningful — it drops a custom name
    /// so the automatic one applies again — and is passed through rather than ignored.
    ///
    /// That used to be *said*: "Leave empty to follow the agent's own name for the
    /// conversation" was a sentence describing a gesture, in a sheet that had room for the
    /// gesture itself. It is a button now, and only when there is a custom name to drop —
    /// a session already following its agent has nothing to be returned to.
    func promptRename(
        title: String,
        current: String,
        placeholder: String = "",
        allowsEmpty: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        promptForText(
            title: title,
            confirmTitle: "Rename",
            clearTitle: allowsEmpty && !current.isEmpty ? "Use Agent's Name" : nil,
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
        clearTitle: String? = nil,
        current: String = "",
        placeholder: String = "",
        allowsEmpty: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        let request = TextPromptRequest(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            clearTitle: clearTitle,
            current: current,
            placeholder: placeholder,
            allowsEmpty: allowsEmpty,
            fieldSize: NSSize(
                width: SidebarDefaults.renameFieldWidth,
                height: SidebarDefaults.renameFieldHeight
            )
        )

        // The clear button answers with the empty string, which is what the callers already
        // read as "drop the custom name" — the field's contents are beside the point.
        switch TextPromptAlert.ask(request) {
        case .text(let typed): completion(typed)
        case .cleared: completion("")
        case nil: return
        }
    }

    /// Refreshes a single session's row, used for frequent updates such as title changes.
    func refreshRow(sessionID: SessionID) {
        guard let node = sessionNode(for: sessionID) else { return }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        reconfigureRow(at: row)
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    func refreshRow(terminalID: TerminalID) {
        guard let node = terminalNodesByID[terminalID] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        reconfigureRow(at: row)
    }

    /// Re-applies a row's content to the view already on screen.
    ///
    /// `reloadData(forRowIndexes:)` does the same job by handing the row back to the reuse
    /// pool and asking for it again, which loses the one thing a title's morph needs: the
    /// name being replaced, held by the very view that was showing it. A recycled cell
    /// would morph from whichever row it last served.
    ///
    /// A row with no live view needs nothing done — the outline builds it from the store
    /// when it next asks, which is already current.
    private func reconfigureRow(at row: Int) {
        guard let item = outlineView.item(atRow: row),
              let view = outlineView.view(
                  atColumn: 0,
                  row: row,
                  makeIfNecessary: false
              ) as? NSTableCellView
        else { return }

        apply(item, to: view)
    }

    /// Refreshes the project row owning a session, re-reading its branch.
    ///
    /// Agents switch branches, so the row is refreshed when a session stops working — the
    /// moment it is most likely to have just changed — rather than by polling. The branch
    /// itself now shows in the hover popover, whose data the reconfigure refreshes; a grouped
    /// checkout is also named by its branch, so its title follows too.
    func refreshProjectRow(forSessionID sessionID: SessionID) {
        guard let project = projectNodesBySessionID[sessionID] else { return }

        let row = outlineView.row(forItem: project)
        guard row >= 0 else { return }

        reconfigureRow(at: row)
    }

    /// Refreshes row contents without rebuilding, used when running state changes.
    func refreshRows() {
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let upperBound = min(NSMaxRange(visibleRows), outlineView.numberOfRows)
        for row in visibleRows.location..<upperBound {
            reconfigureRow(at: row)
        }
    }

    /// Aggregate outline state used by the deterministic sidebar workload. Keeping this seam
    /// here lets the test use the production data source, delegate, row reuse and layout path
    /// without exposing the outline view itself.
    var outlineRowCount: Int { outlineView.numberOfRows }

    var instantiatedRowCount: Int {
        (0..<outlineView.numberOfRows).reduce(into: 0) { count, row in
            if outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) != nil {
                count += 1
            }
        }
    }

    /// The rows the outline is presenting, top to bottom.
    ///
    /// Beside `outlineRowCount` for the same reason: the outline view stays private, and a test
    /// asking what the list says goes through the production data source and delegate rather
    /// than a parallel model of its own.
    var presentedRowKeys: [SidebarNodeKey] {
        (0..<outlineView.numberOfRows).compactMap {
            (outlineView.item(atRow: $0) as? any SidebarOutlineNode)?.sidebarKey
        }
    }

    /// Where a row is now, or nil when nothing is showing it.
    func presentedRow(of key: SidebarNodeKey) -> Int? {
        guard let node = nodesByKey[key] else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    /// The live row view a structural change is happening *to* — where an arriving row's fade
    /// and a displaced row's slide can be watched. Nil for a row the outline has not built.
    func presentedRowView(of key: SidebarNodeKey) -> NSTableRowView? {
        guard let row = presentedRow(of: key) else { return nil }
        return outlineView.rowView(atRow: row, makeIfNecessary: false)
    }

    var selectedSessionID: SessionID? { selectedNode()?.sessionID }
    var selectedTerminalID: TerminalID? { selectedTerminalNode()?.terminalID }

    func setExpanded(_ expanded: Bool, forProject projectID: ProjectID) {
        guard let node = projectNodesByID[projectID] else { return }
        if expanded {
            outlineView.expandItem(node)
        } else {
            outlineView.collapseItem(node)
        }
    }

    #if DEBUG
    /// Exact pre-virtualization refresh path, retained only in Debug so the opt-in workload can
    /// compare both algorithms against the same warm outline in one process.
    func refreshAllRowsForPerformanceComparison() {
        for row in 0..<outlineView.numberOfRows {
            reconfigureRow(at: row)
        }
    }

    /// Exact pre-index single-row path for the same controlled comparison.
    func refreshRowByScanningForPerformanceComparison(sessionID: SessionID) {
        guard let node = allProjectNodes
            .flatMap(\.sessionNodes)
            .first(where: { $0.sessionID == sessionID })
        else { return }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        reconfigureRow(at: row)
        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }
    #endif

    /// Shows or clears a row's spinner for one reason.
    ///
    /// The reason is what makes the spinner endable: whoever raises one lowers the same one,
    /// and a row keeps spinning while any other still holds it. Refreshing just the rows
    /// `SessionLoadingState` reports as changed avoids rebuilding the complete outline during
    /// navigation.
    func setSessionLoading(
        _ isLoading: Bool,
        reason: SessionLoadingState.Reason,
        for sessionID: SessionID
    ) {
        for affectedSessionID in loadingState.set(isLoading, reason: reason, for: sessionID) {
            refreshRow(sessionID: affectedSessionID)
        }
        updateLoadingWatchdog()
    }

    /// Keeps the expiry sweep scheduled exactly while any row is spinning.
    ///
    /// The sweep is the failsafe under the reasons: a raise whose lower gets dropped — a
    /// completion dying with its owner, a callback guarded on a selection that has moved on —
    /// used to spin its row for the rest of the app's life, and nothing on screen said whose
    /// raise it was. Now it ends after `SessionLoadingDefaults.maxHold`, and the journal names
    /// the owner that leaked it.
    private func updateLoadingWatchdog() {
        if loadingState.isEmpty {
            loadingWatchdog?.invalidate()
            loadingWatchdog = nil
            return
        }

        guard loadingWatchdog == nil else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: SessionLoadingDefaults.sweepInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.sweepExpiredLoadingReasons() }
        }
        timer.tolerance = SessionLoadingDefaults.sweepInterval / 2
        loadingWatchdog = timer
    }

    private func sweepExpiredLoadingReasons() {
        let cutoff = Date().addingTimeInterval(-SessionLoadingDefaults.maxHold)

        for (sessionID, reason) in loadingState.lowerExpired(raisedBefore: cutoff) {
            // An expiry is a raiser that dropped its lower — a bug, and this is its only trace.
            ThreadingLogger.session.error(
                """
                Lowered a loading spinner nobody ended: \(reason.rawValue, privacy: .public) \
                for \(sessionID.uuidString, privacy: .public)
                """
            )
            EventLog.shared.record(.session, "Lowered a loading spinner nobody ended", [
                "session": sessionID.uuidString,
                "reason": reason.rawValue
            ])
            refreshRow(sessionID: sessionID)
        }

        updateLoadingWatchdog()
    }

    /// Selects a project row, which is what puts its composer on screen.
    ///
    /// Starting a session goes through here rather than creating one outright: the composer
    /// is the only place agent, account, model and checkout are actually chosen.
    func select(projectID: ProjectID) {
        guard let node = projectNodesByID[projectID] else { return }

        if let group = outlineView.parent(forItem: node) {
            outlineView.expandItem(group)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false

        cancelPendingSessionPresentation()
        projectStore.selectedSessionID = nil
        delegate?.projectSidebar(self, didSelectProject: projectID)
    }

    /// Selects a session row, optionally without informing the delegate.
    ///
    /// The delegate is invoked directly rather than via the selection notification, which
    /// does not fire when the requested row is already selected.
    /// Shows *where* a session is: selects its row, opening whatever groups hide it, and scrolls
    /// it into view.
    ///
    /// Separate from `select` because it answers a different question. Selecting is how a session
    /// is *opened*, and it tells the delegate so the pane follows. Revealing is for something
    /// already on screen — the toolbar's page tab — where the pane must not change and the only
    /// thing wanted is the row brought into sight.
    func reveal(sessionID: SessionID) {
        select(sessionID: sessionID, notifyDelegate: false)
        scrollSelectionIntoView()
    }

    func reveal(terminalID: TerminalID) {
        select(terminalID: terminalID, notifyDelegate: false)
        scrollSelectionIntoView()
    }

    /// The same, for a project — the row behind an open composer.
    func reveal(projectID: ProjectID) {
        guard let node = projectNodesByID[projectID] else { return }

        if let group = outlineView.parent(forItem: node) {
            outlineView.expandItem(group)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        outlineView.scrollRowToVisible(row)
    }

    func select(sessionID: SessionID, notifyDelegate: Bool = true) {
        guard let node = sessionNode(for: sessionID) else { return }

        // Expand the whole chain, outermost first, so each level's children are loaded before
        // the next is asked for. The chain used to be spelled out here as repository →
        // project → branch, which missed the level below: a **side chat** hangs off the
        // session it was forked from, so one the user had folded away had no row, and
        // selecting it silently did nothing — including when the request came from a clicked
        // notification, which then left the pane on whatever session it was already showing.
        for ancestor in ancestorsBySessionID[sessionID] ?? [] {
            outlineView.expandItem(ancestor)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false

        guard notifyDelegate else { return }

        requestSessionPresentation(sessionID)
    }

    func select(terminalID: TerminalID, notifyDelegate: Bool = true) {
        guard let node = terminalNodesByID[terminalID] else { return }
        for ancestor in ancestorsByTerminalID[terminalID] ?? [] {
            outlineView.expandItem(ancestor)
        }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        suppressSelectionCallback = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false

        cancelPendingSessionPresentation()
        projectStore.selectedSessionID = nil
        if notifyDelegate {
            delegate?.projectSidebar(self, didSelectTerminal: terminalID)
        }
    }

    /// Clears the transient page selection without stopping the session behind it.
    ///
    /// The active-page tab uses this for its close button: closing a view is not deleting a
    /// persisted session and is not stopping an agent that may still be working in the
    /// background. Selecting the row again reopens the same page.
    func clearSelection() {
        suppressSelectionCallback = true
        outlineView.deselectAll(nil)
        suppressSelectionCallback = false
        cancelPendingSessionPresentation()
        projectStore.selectedSessionID = nil
    }

    /// Returns to the event loop before constructing or swapping the session surface. That one
    /// turn lets AppKit paint the selection and start the layer-backed spinner immediately.
    private func requestSessionPresentation(_ sessionID: SessionID) {
        projectStore.selectedSessionID = sessionID
        setSessionLoading(true, reason: .presentation, for: sessionID)

        selectionRequestGeneration += 1
        let generation = selectionRequestGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Lowered on **every** path out, including the two that abandon the presentation.
            // A spinner raised for work that then does not happen is the case that left a row
            // spinning for the rest of the app's life, because the only thing that used to
            // clear it was an unrelated git load finishing for whatever session was on screen.
            defer { self.setSessionLoading(false, reason: .presentation, for: sessionID) }

            guard self.selectionRequestGeneration == generation,
                  self.selectedNode()?.sessionID == sessionID else { return }
            self.delegate?.projectSidebar(self, didSelectSession: sessionID)
        }
    }

    private func cancelPendingSessionPresentation() {
        selectionRequestGeneration += 1
        for sessionID in loadingState.loadingSessions {
            setSessionLoading(false, reason: .presentation, for: sessionID)
        }
    }

    /// Swaps the sidebar between the project list and the settings section list, so opening
    /// settings replaces the sidebar rather than adding a second one beside it.
    /// Highlights a settings row, for doors that land on a specific page rather than the
    /// first. A no-op outside settings mode, where there is no list to highlight.
    func selectSettingsPage(id: String) {
        settingsSidebar?.select(id: id)
    }

    /// The cogwheel marks settings by **raising its ink**, not by taking the accent.
    ///
    /// It was accent-tinted, which spends the one colour that means "this wants you" — the
    /// sidebar's attention dot is the same colour — on the fact that a page happens to be open.
    /// The design system already states this for tabs ("a tab's icon takes the label's colour,
    /// never the accent") and the cog is the same kind of thing: a destination, not a summons.
    /// Secondary at rest and label-coloured while it is the page on screen reads as selected
    /// without saying anything is waiting.
    func setSettingsMode(_ on: Bool) {
        isSettingsMode = on

        if on {
            let sidebar = settingsSidebar ?? makeSettingsSidebar()
            sidebar.isHidden = false
            sidebar.select(id: SettingsPages.generalID)
            scrollView.isHidden = true
            emptyStateView.isHidden = true
            // The list's controls go with the list: they add to and arrange the projects,
            // which are not on screen. The band and the brand stay — the brand is the
            // window's signature, not a list control, and a header that vanished took the
            // logo with it.
            addButton.isHidden = true
            arrangeButton.isHidden = true
            settingsButton.contentTintColor = Design.Text.label
        } else {
            settingsSidebar?.isHidden = true
            scrollView.isHidden = false
            emptyStateView.isHidden = !rootNodes.isEmpty
            addButton.isHidden = false
            arrangeButton.isHidden = false
            settingsButton.contentTintColor = Design.Text.secondary
        }
    }

    private func makeSettingsSidebar() -> SettingsSidebar {
        let sidebar = SettingsSidebar(items: SettingsPages.sidebarItems)
        sidebar.onSelect = { [weak self] pageID in
            guard let self else { return }
            self.delegate?.projectSidebar(self, didSelectSettingsPage: pageID)
        }
        // Read once as the sidebar is built: availability is a filesystem scan for logins,
        // which a per-keystroke rebuild must not repeat.
        sidebar.isAskAIAvailable = SettingsSearchResearch.provider != nil
        sidebar.onAskAI = { [weak self] query in
            guard let self else { return }
            self.delegate?.projectSidebar(self, askAIAboutSettings: query)
        }
        view.addSubview(sidebar)

        NSLayoutConstraint.activate([
            // Below the header band, which stays on screen in settings mode carrying the
            // brand row.
            sidebar.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: SidebarDefaults.contentTopInset + Design.Spacing.small
            ),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.medium),
            sidebar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.medium),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor)
        ])

        settingsSidebar = sidebar
        return sidebar
    }

    private func extensionSettingsDidChange() {
        guard let sidebar = settingsSidebar else { return }
        let previous = sidebar.selectedID
        let selected = previous.flatMap(SettingsPages.page(id:)) == nil
            ? SettingsPages.generalID
            : previous ?? SettingsPages.generalID
        sidebar.rebuild(items: SettingsPages.sidebarItems, selecting: selected)
        if isSettingsMode, selected != previous {
            delegate?.projectSidebar(self, didSelectSettingsPage: selected)
        }
    }

}

// MARK: - Actions & Menus

/// Everything the sidebar does in response to clicks: toolbar-less footer actions, context
/// menu commands, and the per-row hover menu. Split from the class body purely for size.
private extension ProjectSidebarViewController {

    /// The `+` button offers both ways in: a folder that exists, or one made on the spot.
    private func presentAddProjectMenu() {
        presentSidebarMenu(
            [
                .item(ThemedMenuItem(
                    title: L10n.string("Start from Scratch…"),
                    image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil),
                    onChoose: { [weak self] in self?.startFromScratchClicked() }
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("Use an Existing Folder…"),
                    image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil),
                    onChoose: { [weak self] in self?.useExistingFolderClicked() }
                ))
            ],
            from: addButton
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
        let project = projectStore.addProject(folderURL: folderURL)
        reload()
        delegate?.projectSidebar(self, didAddProject: project)
    }

    @objc private func renameClicked() {
        guard let row = contextRow() else { return }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            promptRename(
                title: L10n.string("Rename Project"),
                current: projectStore.project(withID: node.projectID)?.name ?? ""
            ) { newName in
                self.projectStore.renameProject(id: node.projectID, to: newName)
                self.reload()
            }
        } else if let node = outlineView.item(atRow: row) as? SessionNode {
            let session = projectStore.session(withID: node.sessionID)
            promptRename(
                title: L10n.string("Rename Session"),
                current: session?.customTitle ?? "",
                placeholder: session?.displayTitle ?? "",
                allowsEmpty: true
            ) { newTitle in
                self.projectStore.renameSession(id: node.sessionID, to: newTitle)
                self.reload()
            }
        } else if let node = outlineView.item(atRow: row) as? TerminalNode {
            let terminal = projectStore.terminal(withID: node.terminalID)
            promptRename(
                title: L10n.string("Rename Terminal"),
                current: terminal?.customTitle ?? "",
                placeholder: terminal.map { ProjectTerminalTitle.displayTitle(for: $0) }
                    ?? L10n.string("Terminal"),
                allowsEmpty: true
            ) { newTitle in
                self.projectStore.renameTerminal(id: node.terminalID, to: newTitle)
            }
        }
    }

    @objc private func removeClicked() {
        guard let row = contextRow() else { return }

        if let node = outlineView.item(atRow: row) as? ProjectNode {
            removeProject(node.projectID)
        } else if let node = outlineView.item(atRow: row) as? SessionNode {
            removeSession(node.sessionID)
        } else if let node = outlineView.item(atRow: row) as? TerminalNode {
            closeTerminal(node.terminalID)
        }
    }

    private func removeProject(_ projectID: ProjectID) {
        guard let project = projectStore.project(withID: projectID) else { return }

        let runningSessionCount = project.sessions.filter {
            AgentRuntime.shared.isRunning(sessionID: $0.id)
        }.count
        let runningTerminalCount = project.terminals.filter {
            ProjectTerminalRuntime.shared.isRunning(terminalID: $0.id)
        }.count
        let runningCount = runningSessionCount + runningTerminalCount

        let request = ConfirmationRequest(
            prompt: .removeProject,
            title: L10n.format("Remove “%@”?", project.name),
            message: runningCount > 0
                ? L10n.format(
                    "%lld running chats or terminals will be terminated. Saved conversations are not deleted, but this project's visual baselines are.",
                    Int64(runningCount)
                )
                : L10n.string(
                    "Its chats and terminals are removed from the sidebar. Saved conversations are not deleted, but this project's visual baselines are."
                ),
            confirmTitle: L10n.string("Remove")
        )

        guard ConfirmationAlert.ask(request) else { return }

        for session in project.sessions {
            AgentRuntime.shared.discard(sessionID: session.id)
        }
        ProjectTerminalRuntime.shared.discard(terminalsIn: project)

        projectStore.removeProject(id: projectID)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    private func closeTerminal(_ terminalID: TerminalID) {
        ProjectTerminalRuntime.shared.discard(terminalID: terminalID)
        projectStore.removeTerminal(id: terminalID)
        delegate?.projectSidebar(self, didCloseTerminal: terminalID)
    }

    @objc private func closeTerminalClicked() {
        guard let terminalID = contextTerminalID() else { return }
        closeTerminal(terminalID)
    }

    /// Opens Storage, which reports every project rather than only this one.
    ///
    /// Reached from a project because that is where the question occurs to someone — but not
    /// scoped to it, since the build output worth finding is usually in a worktree they were
    /// not thinking about.
    @objc private func reclaimDiskSpaceClicked() {
        delegate?.projectSidebar(self, didSelectSettingsPage: SettingsPages.storageID)
    }

    @objc private func revealInFinderClicked() {
        guard let row = contextRow(),
              let node = outlineView.item(atRow: row) as? ProjectNode,
              let project = projectStore.project(withID: node.projectID) else { return }

        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
    }

    private func projectsDidChange(_ change: ProjectsDidChange) {
        switch change.sidebarImpact {
        case .structure:
            // Archive, add, remove, reorder, branch and grouping changes add, drop or move rows.
            // `reload` preserves selection and expansion around that structural rebuild.
            reload()
        case .sessionRow(let sessionID):
            refreshRow(sessionID: sessionID)
        case .terminalRow(let terminalID):
            refreshRow(terminalID: terminalID)
        }
    }

    // MARK: - Private Methods

    private func selectedNode() -> SessionNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? SessionNode
    }

    private func selectedTerminalNode() -> TerminalNode? {
        outlineView.item(atRow: outlineView.selectedRow) as? TerminalNode
    }

    private func sessionNode(for sessionID: SessionID) -> SessionNode? {
        sessionNodesByID[sessionID]
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

    func contextTerminalID() -> TerminalID? {
        guard let row = contextRow(),
              let node = outlineView.item(atRow: row) as? TerminalNode else { return nil }
        return node.terminalID
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
            return projectNodesBySessionID[node.sessionID]?.projectID
        }
        if let node = outlineView.item(atRow: row) as? TerminalNode {
            return projectNodesByTerminalID[node.terminalID]?.projectID
        }
        return nil
    }

    // MARK: - Project Actions

    /// The `+` button: the project's new-session choices, split out from its `⋯` menu.
    /// The `⋯` button: everything a project offers but starting a session.
    private func showProjectActions(for projectID: ProjectID, from anchor: NSView) {
        guard let row = projectRow(for: projectID) else { return }
        presentSidebarMenu(projectMenuEntries(row: row), from: anchor)
    }

    /// The rest of what a project's `+` can make, offered on its secondary click. The press
    /// itself makes a chat; this is where the terminal lives, and where the chat is named so
    /// the gesture still says what it does.
    @discardableResult
    private func showProjectCreationMenu(
        for projectID: ProjectID,
        from source: NSView,
        anchor: ThemedMenuAnchor = .control
    ) -> Bool {
        guard let row = projectRow(for: projectID) else { return false }
        return presentSidebarMenu(
            [
                .item(ThemedMenuItem(
                    title: L10n.string("New Chat…"),
                    onChoose: pinnedAction(row) { $0.newProjectChatClicked() }
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("New Terminal"),
                    onChoose: pinnedAction(row) { $0.newProjectTerminalClicked() }
                ))
            ],
            from: source,
            anchor: anchor
        )
    }

    private func projectRow(for projectID: ProjectID) -> Int? {
        guard let node = projectNodesByID[projectID] else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    @objc private func newProjectChatClicked() {
        guard let projectID = contextProjectID() else { return }
        select(projectID: projectID)
    }

    @objc private func newProjectTerminalClicked() {
        guard let projectID = contextProjectID(),
              let terminal = projectStore.addTerminal(to: projectID) else { return }
        select(terminalID: terminal.id)
    }

    private func showTerminalActions(for terminalID: TerminalID, from anchor: NSView) {
        guard let node = terminalNodesByID[terminalID] else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }

        presentSidebarMenu(terminalMenuEntries(for: terminalID, row: row), from: anchor)
    }

    // MARK: - Branch Grouping Options

    /// The menu behind a branch heading's hover gear: the grouping rules — the settings
    /// that govern the row it hangs from — and the door to the rest of Settings.
    private func showBranchGroupingOptions(from anchor: NSView) {
        presentSidebarMenu(
            [
                branchGroupingEntry(),
                loneBranchHeadingsEntry(),
                .separator,
                .item(ThemedMenuItem(
                    title: L10n.string("All Settings…"),
                    onChoose: { [weak self] in self?.settingsClicked() }
                ))
            ],
            from: anchor
        )
    }

    /// The menu behind the header's arrangement control: how the list groups, then how it
    /// orders. Rebuilt on every open so the checks always say what is currently true.
    private func showArrangementOptions() {
        presentSidebarMenu(arrangementMenuEntries(), from: arrangeButton)
    }

    /// The grouping toggle, its check showing the current state.
    private func branchGroupingEntry() -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: L10n.string("Group Sessions by Branch"),
            isSelected: AppSettings.shared.groupsSessionsByBranch,
            onChoose: { [weak self] in self?.toggleBranchGroupingClicked() }
        ))
    }

    /// The lone-branch refinement, disabled while grouping is off — it refines the grouping
    /// rule, so without grouping there is nothing for it to say.
    private func loneBranchHeadingsEntry() -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: L10n.string("Headings for Lone Branches"),
            isSelected: AppSettings.shared.groupsLoneBranches,
            isEnabled: AppSettings.shared.groupsSessionsByBranch,
            onChoose: { [weak self] in self?.toggleLoneBranchHeadingsClicked() }
        ))
    }

    /// The compact tree, in the menu that owns how the list presents itself. Grouped with the
    /// grouping toggles rather than the orders: all three say what the tree *is*, where an
    /// order says what comes first.
    private func compactTreeEntry() -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: L10n.string("Compact Tree"),
            isSelected: AppSettings.shared.compactsSidebarTree,
            onChoose: { [weak self] in self?.toggleCompactTreeClicked() }
        ))
    }

    /// One order as a checkable row; the chosen one carries the check.
    private func orderEntry(_ order: SidebarSessionOrder) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: order.menuTitle,
            isSelected: AppSettings.shared.sidebarSessionOrder == order,
            onChoose: { [weak self] in self?.sessionOrderChosen(order) }
        ))
    }

    @objc private func toggleBranchGroupingClicked() {
        AppSettings.shared.groupsSessionsByBranch.toggle()
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func toggleLoneBranchHeadingsClicked() {
        AppSettings.shared.groupsLoneBranches.toggle()
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func toggleCompactTreeClicked() {
        // No `ProjectsDidChange`: the tree's shape is unchanged, so that route would answer
        // with a content refresh that moves no frame. The setter's own settings event reaches
        // `applyTreeDensity`, here and in every other window.
        AppSettings.shared.compactsSidebarTree.toggle()
    }

    private func sessionOrderChosen(_ order: SidebarSessionOrder) {
        AppSettings.shared.sidebarSessionOrder = order
        NotificationCenter.default.post(ProjectsDidChange())
    }
}

// MARK: - NSOutlineViewDataSource

extension ProjectSidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootNodes.count }

        if let group = item as? RepoGroupNode { return group.projectNodes.count }
        if let project = item as? ProjectNode { return project.childNodes.count }
        if let branch = item as? BranchGroupNode { return branch.childNodes.count }
        if let session = item as? SessionNode { return session.childNodes.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootNodes[index] }

        if let group = item as? RepoGroupNode { return group.projectNodes[index] }
        if let project = item as? ProjectNode { return project.childNodes[index] }
        if let branch = item as? BranchGroupNode { return branch.childNodes[index] }
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
        if item is RepoGroupNode || item is ProjectNode {
            let identifier = item is RepoGroupNode
                ? SidebarIdentifiers.repoCell
                : SidebarIdentifiers.projectCell
            let cell = dequeueCell(identifier) { ProjectRowView() }
            return apply(item, to: cell) ? cell : nil
        }

        if item is BranchGroupNode {
            let cell = dequeueCell(SidebarIdentifiers.branchCell) { ProjectRowView() }
            return apply(item, to: cell) ? cell : nil
        }

        if item is SessionNode {
            let cell = dequeueCell(SidebarIdentifiers.sessionCell) { SessionRowView() }
            return apply(item, to: cell) ? cell : nil
        }

        if item is TerminalNode {
            let cell = dequeueCell(SidebarIdentifiers.terminalCell) { ProjectTerminalRowView() }
            return apply(item, to: cell) ? cell : nil
        }

        return nil
    }

    /// Fills a row view from its node, reading current state from the stores.
    ///
    /// Split out of `viewFor` so a row already on screen can be brought up to date without
    /// being handed back to the reuse pool first — see `reconfigureRow(at:)`. Returns false
    /// for a node whose record has gone, which is the outline asking about something the
    /// store has already dropped.
    @discardableResult
    private func apply(_ item: Any, to view: NSTableCellView) -> Bool {
        if let groupNode = item as? RepoGroupNode, let cell = view as? ProjectRowView {
            cell.configureAsRepository(named: groupNode.name)
            return true
        }

        if let projectNode = item as? ProjectNode, let cell = view as? ProjectRowView {
            guard let project = projectStore.project(withID: projectNode.projectID) else {
                return false
            }

            // Inside a group the repository name is already above, so the checkout is
            // identified by its branch instead of repeating the folder name.
            let isGrouped = outlineView.parent(forItem: projectNode) is RepoGroupNode

            // A collapsed project says how many sessions it is hiding; expanded, the
            // sessions speak for themselves.
            let hiddenItems = outlineView.isItemExpanded(projectNode)
                ? 0
                : projectNode.sessionNodes.count + projectNode.terminalNodes.count

            cell.configure(
                with: project,
                style: isGrouped ? .checkout : .standalone,
                collapsedSessionCount: hiddenItems
            )
            cell.onHoverAction = { [weak self] anchor in
                self?.showProjectActions(for: projectNode.projectID, from: anchor)
            }
            cell.onCreateAction = { [weak self] projectID in
                // What the `+` is for: a chat in this project, without a menu in the way.
                self?.select(projectID: projectID)
            }
            cell.onCreateMenuAction = { [weak self] projectID, anchor, menuAnchor in
                self?.showProjectCreationMenu(
                    for: projectID,
                    from: anchor,
                    anchor: menuAnchor
                ) ?? false
            }
            return true
        }

        if let branchNode = item as? BranchGroupNode, let cell = view as? ProjectRowView {
            let hiddenItems = outlineView.isItemExpanded(branchNode)
                ? 0
                : branchNode.childNodes.count

            cell.configureAsBranch(
                named: branchNode.branch,
                collapsedSessionCount: hiddenItems
            )
            cell.onHoverAction = { [weak self] anchor in
                self?.showBranchGroupingOptions(from: anchor)
            }
            return true
        }


        if let terminalNode = item as? TerminalNode,
           let cell = view as? ProjectTerminalRowView {
            guard let terminal = projectStore.terminal(withID: terminalNode.terminalID) else {
                return false
            }
            cell.configure(
                with: terminal,
                running: ProjectTerminalRuntime.shared.isRunning(terminalID: terminal.id),
                projectRoot: terminalNode.displayProjectFolderPath
            )
            cell.onAction = { [weak self] terminalID, anchor in
                self?.showTerminalActions(for: terminalID, from: anchor)
            }
            return true
        }

        if let sessionNode = item as? SessionNode, let cell = view as? SessionRowView {
            guard let session = projectStore.session(withID: sessionNode.sessionID) else {
                return false
            }

            cell.configure(
                with: session,
                activity: AgentRuntime.shared.activity(sessionID: sessionNode.sessionID),
                isLoading: loadingState.isLoading(sessionNode.sessionID)
            )
            cell.onAction = { [weak self] sessionID, anchor in
                self?.showRowActions(for: sessionID, from: anchor)
            }
            cell.onArchive = { [weak self] sessionID in
                self?.archiveSession(sessionID)
            }
            return true
        }

        return false
    }

    /// Clickable rows highlight under the pointer; group headings do not, since they only
    /// respond at their disclosure triangle.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is ProjectNode || item is SessionNode || item is TerminalNode {
            return SidebarHoverRowView()
        }

        // In the compact tree a repository heading can open a group, and the rule above a
        // group is the row's to draw — so the heading takes the same row class with the
        // hover wash off, keeping the promise above.
        if presentedTreeIsCompact, item is RepoGroupNode {
            let rowView = SidebarHoverRowView()
            rowView.isHoverEnabled = false
            return rowView
        }

        return nil
    }

    /// The compact tree's rule rides the row view, so it is stamped where the view is born;
    /// `refreshGroupRules()` re-stamps the survivors after each structural pass.
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarHoverRowView else { return }
        rowView.showsGroupRule = showsGroupRule(forRow: row)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // In the compact tree, the space indentation used to put *beside* a group goes above
        // it instead: every top-level row adds the group gap. Uniformly — first root included —
        // so a root moving to or from the top never changes a height mid-diff.
        let groupSpacing = presentedTreeIsCompact ? SidebarDefaults.compactGroupSpacing : 0

        // Project rows are a single line — the branch that used to add a second one now lives
        // in the hover popover — so they take the compact height.
        if item is ProjectNode {
            let isRoot = outlineView.parent(forItem: item) == nil
            return SidebarDefaults.projectCompactRowHeight + (isRoot ? groupSpacing : 0)
        }

        // Headings get extra height, which reads as space between groups.
        if item is RepoGroupNode {
            return SidebarDefaults.headingRowHeight + groupSpacing
        }

        // A branch heading sits inside a project, so it takes the compact height rather
        // than the between-groups one.
        if item is BranchGroupNode {
            return SidebarDefaults.projectCompactRowHeight
        }

        return SidebarDefaults.rowHeight
    }

    /// Chats and terminals open their page; projects open the composer. Repository headings group
    /// their checkouts and select nothing themselves.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SessionNode || item is TerminalNode || item is ProjectNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }

        let item = outlineView.item(atRow: outlineView.selectedRow)

        if let node = item as? SessionNode {
            requestSessionPresentation(node.sessionID)
            return
        }

        if let node = item as? TerminalNode {
            cancelPendingSessionPresentation()
            projectStore.selectedSessionID = nil
            delegate?.projectSidebar(self, didSelectTerminal: node.terminalID)
            return
        }

        if let node = item as? ProjectNode {
            cancelPendingSessionPresentation()
            projectStore.selectedSessionID = nil
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
        projectStore.setProject(id: node.projectID, expanded: true)
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
        projectStore.setProject(id: node.projectID, expanded: false)
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

// MARK: - Row Context Menus

extension ProjectSidebarViewController {

    /// Presents the context menu for whichever row a secondary click (or an accessibility
    /// "show menu") landed on. The anchor came with the gesture: a click carries its pointer,
    /// a pointerless request hangs from the row.
    func presentRowContextMenu(row: Int, anchor: ThemedMenuAnchor) -> Bool {
        guard row >= 0, let item = outlineView.item(atRow: row) else { return false }

        let entries: [ThemedMenuEntry]
        if item is ProjectNode {
            entries = projectMenuEntries(row: row)
        } else if item is BranchGroupNode {
            // The heading offers the display options that created it, and nothing else — it
            // is a grouping, not a place.
            entries = [branchGroupingEntry(), loneBranchHeadingsEntry()]
        } else if let node = item as? SessionNode,
                  let session = projectStore.session(withID: node.sessionID) {
            // The right-click menu offers exactly what the row's `⋯` button does, built from
            // the one place both share. `actionSessionID` is what every handler reads, set as
            // the menu is built.
            actionSessionID = node.sessionID
            entries = sessionActionEntries(for: session)
        } else if let node = item as? TerminalNode {
            entries = terminalMenuEntries(for: node.terminalID, row: row)
        } else {
            return false
        }

        let source = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            ?? outlineView
        return presentSidebarMenu(entries, from: source, anchor: anchor)
    }

    func terminalMenuEntries(for terminalID: TerminalID, row: Int) -> [ThemedMenuEntry] {
        [
            .item(ThemedMenuItem(
                title: L10n.string("Rename Terminal…"),
                onChoose: pinnedAction(row) { $0.renameClicked() }
            )),
            // The same fold the chat rows carry, holding the two facts a terminal can state:
            // the id that names it to Threading, and the checkout it is standing in. Captured
            // by id, not row-resolved — an id does not move when the tree reloads under the
            // open menu. The worktree is resolved on the click rather than at build, because
            // `displayProject` costs git calls and the theme entry beside this one already
            // answers *its* tier with the same cwd-derived project.
            .item(ThemedMenuItem(title: L10n.string("Copy"), submenu: [
                .item(ThemedMenuItem(
                    title: L10n.string("Threading ID"),
                    onChoose: {
                        Self.copyToPasteboard(terminalID.uuidString.lowercased())
                    }
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("Worktree Path"),
                    onChoose: { [weak self] in
                        guard let project = self?.projectStore
                            .displayProject(forTerminalID: terminalID) else { return }
                        Self.copyToPasteboard(project.folderPath)
                    }
                ))
            ])),
            terminalThemeEntry(for: terminalID),
            .separator,
            .item(ThemedMenuItem(
                title: L10n.string("Close Terminal"),
                onChoose: pinnedAction(row) { $0.closeTerminalClicked() }
            ))
        ]
    }

    /// Everything a project offers — its right-click and its `⋯` button alike. Sessions are
    /// started by selecting the project, which opens its composer.
    func projectMenuEntries(row: Int) -> [ThemedMenuEntry] {
        let projectID = (outlineView.item(atRow: row) as? ProjectNode)?.projectID

        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Rename Project…"),
                onChoose: pinnedAction(row) { $0.renameClicked() }
            ))
        ]
        // The way out to an editor sits above the Finder reveal, because it is the one people
        // reach for: a checkout is opened in the app they work in far more often than it is
        // looked at in a file manager. Finder is in that submenu too, and stays here in its own
        // right — it is one press either way, and the one press is what the item is for.
        if let projectID,
           let project = projectStore.project(withID: projectID),
           let openIn = OpenInMenu.submenuEntry(for: .folder(project.folderURL)) {
            entries.append(openIn)
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Reveal in Finder"),
            onChoose: pinnedAction(row) { $0.revealInFinderClicked() }
        )))
        entries.append(projectIconEntry(row: row))
        if let projectID {
            entries.append(projectThemeEntry(for: projectID))
            entries.append(projectChangeRequestEntry(for: projectID))
            entries.append(projectMuteEntry(for: projectID, row: row))
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Reclaim Disk Space…"),
            onChoose: pinnedAction(row) { $0.reclaimDiskSpaceClicked() }
        )))
        entries.append(.separator)
        entries.append(branchGroupingEntry())
        // Only while grouping is on: a refinement with nothing to refine would read as live
        // here. The arrangement control and the View menu carry the disabled-but-visible form.
        if AppSettings.shared.groupsSessionsByBranch {
            entries.append(loneBranchHeadingsEntry())
        }
        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Remove Project"),
            onChoose: pinnedAction(row) { $0.removeClicked() }
        )))

        if let projectID {
            entries.append(contentsOf: extensionCommandEntries(
                placement: .projectRow,
                context: ExtensionCommandContext(
                    projectID: projectID.uuidString.lowercased()
                )
            ))
        }
        return entries
    }

    /// The icon submenu: choose one, take a site's favicon, re-run the free discovery,
    /// optionally spend a Codex run on it, and clear it. Research appears only when a Codex
    /// login exists, and is menu-only on purpose — each run costs the user's own usage, so
    /// each is an explicit click, never a background default. A run in flight shows as a
    /// disabled "Researching…", and the last run's full output stays openable from here.
    private func projectIconEntry(row: Int) -> ThemedMenuEntry {
        let project = (outlineView.item(atRow: row) as? ProjectNode)
            .flatMap { projectStore.project(withID: $0.projectID) }

        var submenu: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Choose Icon…"),
                onChoose: pinnedAction(row) { $0.chooseProjectIconClicked() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Use Website Favicon…"),
                onChoose: pinnedAction(row) { $0.useWebsiteFaviconClicked() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Find Icon Automatically"),
                onChoose: pinnedAction(row) { $0.findProjectIconClicked() }
            ))
        ]

        let isResearching = project.map {
            ProjectIconResearch.runningProjectIDs.contains($0.id)
        } ?? false

        if isResearching {
            submenu.append(.item(ThemedMenuItem(
                title: L10n.string("Researching…"),
                isEnabled: false
            )))
        } else if !AgentAccountDiscovery.accounts(for: .codex).isEmpty {
            submenu.append(.item(ThemedMenuItem(
                title: L10n.string("Research Icon with Codex"),
                onChoose: pinnedAction(row) { $0.researchProjectIconClicked() }
            )))
        }

        if let project, FileManager.default.fileExists(
            atPath: ProjectIconResearch.recordURL(for: project.id).path
        ) {
            submenu.append(.item(ThemedMenuItem(
                title: L10n.string("Open Last Research Log"),
                onChoose: pinnedAction(row) { $0.openResearchLogClicked() }
            )))
        }

        if project?.icon != nil {
            submenu.append(.separator)
            submenu.append(.item(ThemedMenuItem(
                title: L10n.string("Remove Icon"),
                onChoose: pinnedAction(row) { $0.removeProjectIconClicked() }
            )))
        }

        return .item(ThemedMenuItem(title: L10n.string("Project Icon"), submenu: submenu))
    }

    /// Silences a whole checkout, or lets it speak again.
    ///
    /// A project is where "this repository is busy and I do not want to hear from it" is
    /// actually said — muting its sessions one at a time would have to be repeated for every
    /// session started afterwards, which is the case that makes the setting worth having at
    /// all. Sessions follow unless they answered for themselves.
    private func projectMuteEntry(for projectID: ProjectID, row: Int) -> ThemedMenuEntry {
        let muted = projectStore.project(withID: projectID)?.notificationsMuted ?? false
        return .item(ThemedMenuItem(
            title: muted
                ? L10n.string("Unmute Notifications")
                : L10n.string("Mute Notifications"),
            onChoose: pinnedAction(row) { $0.toggleProjectMuteClicked() }
        ))
    }

    @objc private func toggleProjectMuteClicked() {
        guard let projectID = contextProjectID(),
              let project = projectStore.project(withID: projectID) else { return }

        projectStore.setNotificationsMuted(
            !(project.notificationsMuted ?? false),
            forProjectID: projectID
        )
        // The store has no idea notifications exist, so what it has just silenced is still on
        // screen until this asks. Muting is not a settings change, which is why the alert
        // center's own observation does not cover it.
        AttentionAlertCenter.shared.preferencesChanged()
    }

    // MARK: - Project Icon Actions

    @objc private func chooseProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = L10n.string("Choose an image to use as the project's icon.")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            guard let data = try? Data(contentsOf: url),
                  let fileName = ProjectIconStore.store(imageData: data, for: projectID) else {
                self?.presentIconNotice(
                    L10n.string("The file could not be read as an image.")
                )
                return
            }

            self?.projectStore.setIcon(
                ProjectIcon(source: .custom, fileName: fileName),
                for: projectID
            )
        }
    }

    @objc private func findProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }

        ProjectIconDiscovery.shared.rediscover(projectID: projectID) { [weak self] found in
            if !found {
                self?.presentIconNotice(
                    L10n.string("No icon was found for this project.")
                )
            }
        }
    }

    @objc private func researchProjectIconClicked() {
        guard let projectID = contextProjectID(),
              let project = projectStore.project(withID: projectID) else { return }

        ProjectIconResearch.run(for: project) { [weak self] result in
            guard case .failure(let error) = result else { return }

            // The record answers "what did it actually do?" — point at it when there is one.
            var message = error.message
            let record = ProjectIconResearch.recordURL(for: projectID)
            if FileManager.default.fileExists(atPath: record.path) {
                message += L10n.string(
                    "\n\nThe run's full output: Project Icon > Open Last Research Log."
                )
            }
            self?.presentIconNotice(message)
        }
    }

    @objc private func useWebsiteFaviconClicked() {
        guard let projectID = contextProjectID() else { return }

        promptForWebsite { [weak self] input in
            guard let origin = ProjectIconDiscovery.origin(fromWebsite: input) else {
                self?.presentIconNotice(
                    L10n.format("“%@” is not a usable web address.", input)
                )
                return
            }

            // Fetched off the main queue; everything that touches the store hops back.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = ProjectIconDiscovery.websiteIcon(atOrigin: origin)

                DispatchQueue.main.async {
                    guard let data,
                          let fileName = ProjectIconStore.store(imageData: data, for: projectID) else {
                        self?.presentIconNotice(
                            L10n.format(
                                "No favicon was found at %@.",
                                origin.absoluteString
                            )
                        )
                        return
                    }

                    // The user named the site, so this is their choice — never replaced
                    // automatically, exactly like a file they picked.
                    self?.projectStore.setIcon(
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
        let request = TextPromptRequest(
            title: L10n.string("Use Website Favicon"),
            message: L10n.string("The site's touch icon or favicon becomes the project's icon."),
            confirmTitle: L10n.string("Use Favicon"),
            placeholder: L10n.string("example.com"),
            fieldSize: NSSize(
                width: SidebarDefaults.renameFieldWidth,
                height: SidebarDefaults.renameFieldHeight
            )
        )

        guard case .text(let host)? = TextPromptAlert.ask(request) else { return }
        completion(host)
    }

    @objc private func removeProjectIconClicked() {
        guard let projectID = contextProjectID() else { return }
        projectStore.setIcon(nil, for: projectID)
    }

    /// A quiet informational alert; icon actions have no state worth a warning style.
    private func presentIconNotice(_ message: String) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Project Icon")
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
    static let terminalCell = NSUserInterfaceItemIdentifier("SidebarTerminalCell")
}

// MARK: - ProjectSidebarViewControllerDelegate

@MainActor
protocol ProjectSidebarViewControllerDelegate: AnyObject {
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSession sessionID: SessionID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectTerminal terminalID: TerminalID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectProject projectID: ProjectID)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didAddProject project: Project)
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setArchived archived: Bool,
        for sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        closeSession sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        askAgentToRename sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        sendResultToParentOf sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        setUsesNativeUI usesNative: Bool,
        for sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        showAttachmentsFor sessionID: SessionID
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        moveSession sessionID: SessionID,
        toAccount account: AgentAccount
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        continueSession sessionID: SessionID,
        withAccount account: AgentAccount
    )
    func projectSidebar(
        _ sidebar: ProjectSidebarViewController,
        createSideChatOf sessionID: SessionID,
        prompt: String?
    )
    func projectSidebarDidRemoveSessions(_ sidebar: ProjectSidebarViewController)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didCloseTerminal terminalID: TerminalID)
    func projectSidebarDidToggleSettings(_ sidebar: ProjectSidebarViewController)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didSelectSettingsPage pageID: String)
    func projectSidebar(_ sidebar: ProjectSidebarViewController, askAIAboutSettings query: String)
}

// MARK: - Arrangement Menu

extension ProjectSidebarViewController {

    /// Built separately from shown, so a test can assert the entries without presenting —
    /// internal for exactly that caller, the same seam the theme menu builders offer. Lives
    /// outside the private extension because a private extension's members are fileprivate
    /// no matter what they intend.
    func arrangementMenuEntries() -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = [
            branchGroupingEntry(),
            loneBranchHeadingsEntry(),
            compactTreeEntry(),
            .separator
        ]
        for order in SidebarSessionOrder.allCases {
            entries.append(orderEntry(order))
        }
        return entries
    }
}

// MARK: - Themed Menu Presentation

extension ProjectSidebarViewController {

    /// Presents one sidebar menu at a time, keeping the token until the menu lets go.
    /// The shared door for every sidebar entrance — row context menus, hover buttons, the
    /// header controls — so they cannot drift in width, anchoring, or retention.
    @discardableResult
    func presentSidebarMenu(
        _ entries: [ThemedMenuEntry],
        from source: NSView,
        anchor: ThemedMenuAnchor = .control
    ) -> Bool {
        guard entries.contains(where: \.isItem) else { return false }
        activeMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
            from: source,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.activeMenuSession = nil }
        )
        return activeMenuSession != nil
    }

    /// Wraps a menu action so it runs with `row` pinned as the context row — the
    /// closure-world equivalent of the pin the old modal `popUp` held for its whole life.
    /// Every ambient `contextRow()` reader then answers for the row the menu was actually
    /// opened on, not for whatever was last clicked by the time the action fired.
    func pinnedAction(
        _ row: Int,
        _ body: @escaping (ProjectSidebarViewController) -> Void
    ) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            self.overrideContextRow = row
            body(self)
            self.overrideContextRow = nil
        }
    }
}
