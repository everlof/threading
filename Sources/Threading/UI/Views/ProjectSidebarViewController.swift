import AppKit
import ThreadingExtensionKit
import UniformTypeIdentifiers

// MARK: - Performance diagnostics

#if DEBUG
/// Phase timings from the most recent sidebar reload.
///
/// The production recorder keeps the always-on coarse spans. This Debug-only value lets the
/// deterministic stress fixture print the same reload's internal phases without exporting and
/// reparsing a trace, so a cold-load regression can be assigned to model projection, indexing,
/// or AppKit rather than hidden inside one controller-load number.
struct ProjectSidebarReloadPerformance {
    var totalNanoseconds: UInt64 = 0
    var treeNanoseconds: UInt64 = 0
    var shapeNanoseconds: UInt64 = 0
    var adoptionNanoseconds: UInt64 = 0
    var indexingNanoseconds: UInt64 = 0
    var outlineNanoseconds: UInt64 = 0

    var unclassifiedNanoseconds: UInt64 {
        let classified = treeNanoseconds
            &+ shapeNanoseconds
            &+ adoptionNanoseconds
            &+ indexingNanoseconds
            &+ outlineNanoseconds
        return totalNanoseconds >= classified ? totalNanoseconds - classified : 0
    }
}
#endif

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
    private var scrollViewBottomConstraint: NSLayoutConstraint?
    private var emptyStateView: NSView?

    private func makeEmptyStateView() -> NSView {
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
    }
    private let appEvents = AppEventObservations()

    /// The persisted tree this controller presents. Production uses the app-wide store; an
    /// injected store lets deterministic UI workloads exercise the real outline controller
    /// without reading or mutating the user's projects.
    let projectStore: ProjectStore

    /// Whether the first tree waits for its host to finish establishing window geometry.
    ///
    /// `MainWindowController` attaches native chrome and restores the saved frame before the
    /// window can be shown. Mounting cells while those transient sizes pass through AppKit made
    /// the same visible rows lay out once under toolbar installation and again at their final
    /// width. Standalone sidebars keep the ordinary eager behavior; the main window explicitly
    /// crosses this boundary after its final frame is in force.
    private let defersInitialTreeMount: Bool
    private var hasMountedInitialTree = false

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
    /// The global silence gate, at the band's trailing edge.
    ///
    /// One glyph, worn while it holds: the button's own selected state is the whole indication,
    /// because a control that stops every sound the app can make and then looks exactly like it
    /// did is the mystery-noise problem inverted. Pressing it writes one Boolean and no
    /// override anywhere, so releasing it gives every scope back the answer it already had.
    private lazy var silenceButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SidebarDefaults.silenceSymbol,
            accessibility: SidebarStrings.silenceSounds,
            target: .inline,
            inkSource: .chrome
        )
        button.onPress = { [weak self] in self?.silenceClicked() }
        return button
    }()
    /// Settings is the sidebar's one standing destination. Surfaces that live in the *trailing*
    /// panel are opened from that panel — see `DisplayPaneController.newTabEntries(for:)` — so
    /// this column never carries a permanent door to something it does not show.
    /// The trailing silence gate is not a counterexample: it opens nothing and goes nowhere,
    /// it reports and changes one piece of the app's own live state, and the rule is about
    /// destinations rather than about controls.
    // A non-release build carries its channel mark beside Settings — see `BuildChannelBadge`.
    private lazy var footer = PaneFooterView(
        leading: [settingsButton, BuildChannelBadge.make()].compactMap { $0 },
        trailing: [silenceButton],
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

    /// The same for the Sounds submenu, retained for the same reason: its rows carry a closure
    /// back to it, and a builder made per menu would be gone before the first click.
    let soundMenuBuilder = SoundMenuBuilder()

    /// The sidebar's ground, under every theme — see `applySidebarSurface`.
    private var themeBackdrop: SidebarBackdropView?
    private(set) var isSettingsMode = false

    /// Top level of the tree: a `RepoGroupNode` for repositories with several checkouts,
    /// a bare `ProjectNode` for everything else.
    private var rootNodes: [NSObject] = []

    /// A per-window presentation choice. The attention view is the default; Snoozed is a
    /// discoverable alternate view over the same project hierarchy, not a second flat model.
    private var sessionVisibility: SidebarSessionVisibility = .attention

    /// The shape the outline is currently showing, so a change that leaves it alone can refresh
    /// the rows rather than rebuild them — and one that does not can be told to the outline as
    /// the rows that arrived, left and moved. See `reload`.
    private var renderedShape = SidebarTreeShape()

    /// Every presented node by identity, so a step naming a parent can find the object the
    /// outline was handed. Rebuilt with the other indexes.
    private var nodesByKey: [SidebarNodeKey: NSObject] = [:]

    /// The latest insertion fade scheduled for each identity. macOS 26 can leave an off-screen
    /// `.effectFade` row at alpha zero; one batched callback per structural pass repairs only the
    /// identities whose fade has not since been superseded by another insertion.
    private var pendingInsertFadeFinalizations: [SidebarNodeKey: UUID] = [:]

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

    /// The outline reports programmatic expansion through the same delegate methods as a user's
    /// disclosure click. During a structural apply, `expandStandingRows` already owns the whole
    /// descendant walk and persistence is already authoritative; letting the callback enter that
    /// route again recursively enumerated the same large project a second time at cold launch.
    private var isApplyingStandingExpansion = false

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

    /// The row views AppKit currently owns. Structural edits need to restamp compact group
    /// rules on survivors, but asking the outline for every logical row to discover these views
    /// made a one-row edit O(total sessions). The weak table follows AppKit's reuse lifecycle and
    /// keeps that pass proportional to mounted rows.
    private let instantiatedHoverRowViews = NSHashTable<SidebarHoverRowView>.weakObjects()

    #if DEBUG
    private(set) var lastReloadPerformance = ProjectSidebarReloadPerformance()
    private(set) var lastProjectStructureNanoseconds: UInt64 = 0
    private(set) var lastProjectStructurePerformance = ProjectSidebarReloadPerformance()
    private(set) var lastGroupRuleRefreshCandidateCount = 0
    #endif

    // MARK: - Lifecycle

    init(
        projectStore: ProjectStore = .shared,
        defersInitialTreeMount: Bool = false
    ) {
        self.projectStore = projectStore
        self.defersInitialTreeMount = defersInitialTreeMount
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
        observeStoreChanges()
        applySidebarSurface()
        if !defersInitialTreeMount {
            mountInitialTreeIfNeeded()
        }
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
        let bottomConstraint = scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor)
        scrollViewBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: SidebarDefaults.contentTopInset
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint
        ])

        // Before the first `reload()`, so the first tree is drawn at the chosen density
        // rather than arriving indented and snapping flat.
        applyTreeDensity(initial: true)
    }

    /// Shows the prompt centred in the list area while no project has been added.
    ///
    /// The ordinary launch already has projects, so constructing and theming these labels in
    /// `viewDidLoad` spent launch time on a branch that contributed no pixels. Keep absence
    /// cheap: hiding an unbuilt prompt is a no-op, and the first genuinely empty tree installs
    /// it exactly once.
    private func setEmptyStateVisible(_ visible: Bool) {
        guard visible else {
            emptyStateView?.isHidden = true
            return
        }

        if let emptyStateView {
            emptyStateView.isHidden = false
            return
        }

        let stack = makeEmptyStateView()
        emptyStateView = stack
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
        stack.isHidden = false
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

        applySilenceState()
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

    /// Toggles the gate and nothing else. The button is not set here: the setting's own change
    /// event is what moves it, so this window, a second window, the Settings row and the menu
    /// item all follow the same one signal rather than each other.
    @objc private func silenceClicked() {
        AppSettings.shared.silencesAllSounds.toggle()
    }

    /// Wears the gate's current state — filled and bordered while it holds, quiet otherwise —
    /// and says which state that is in words the pointer and VoiceOver can both reach.
    ///
    /// Called on every settings change rather than only on the press, because the same Boolean
    /// is written from three surfaces and a control that only followed its own presses would be
    /// wrong the first time one of the other two was used.
    private func applySilenceState() {
        let silenced = AppSettings.shared.silencesAllSounds
        silenceButton.isSelected = silenced
        silenceButton.toolTip = silenced
            ? SidebarStrings.silencedHint
            : SidebarStrings.silenceSoundsHint
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
        // Session rows have two independently customizable surfaces. Watching each one made
        // every visible row install two notification observers before extensions had published
        // any content. The list owns visibility, so it owns the one observer and wakes only
        // rows that AppKit has actually materialized.
        appEvents.observe(ComponentCustomizationDidChange.self) { [weak self] event in
            self?.refreshVisibleSessionCustomizations(changedTargets: event.targets)
        }
        // The one settings observer this list carries, and it is value-guarded inside: the
        // event fires for every setting, and every other sidebar-shaping setting rebuilds the
        // *tree* and so arrives as `ProjectsDidChange`. Density changes no node — `reload()`
        // would compare shapes, find them equal, and refresh contents without moving a frame —
        // so it takes its own route to a wholesale re-layout.
        appEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.applyTreeDensity()
            // The footer's silence gate is written from three surfaces, so it follows the
            // setting rather than its own press. It repaints only on a real change —
            // `ThemedIconButton.isSelected` guards that for it.
            self?.applySilenceState()
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

    /// Installs the persisted tree exactly once, after a host that requested deferral has put
    /// its permanent geometry in force. Idempotence lets a host state the lifecycle point
    /// directly without coupling it to whether AppKit happened to load the view earlier.
    func mountInitialTreeIfNeeded() {
        _ = view
        guard !hasMountedInitialTree else { return }
        hasMountedInitialTree = true

        // A correctly sized live viewport makes every programmatic disclosure materialize and
        // retain rows from each intermediate tree height. None of those intermediate states is
        // presented: the complete first tree lands synchronously in this call. Replace only the
        // list's bottom constraint while constructing it, keeping the final width and the rest
        // of the window in force, then restore the real viewport before the next display pass.
        guard let bottomConstraint = scrollViewBottomConstraint,
              scrollView.frame.height > 0 else {
            reload()
            return
        }

        let suppressedHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        bottomConstraint.isActive = false
        suppressedHeight.isActive = true
        view.layoutSubtreeIfNeeded()
        reload()
        suppressedHeight.isActive = false
        bottomConstraint.isActive = true
        view.needsLayout = true
    }

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
        #if DEBUG
        let reloadStarted = DispatchTime.now().uptimeNanoseconds
        var measuredReload = ProjectSidebarReloadPerformance()
        #endif
        defer {
            #if DEBUG
            measuredReload.totalNanoseconds = DispatchTime.now().uptimeNanoseconds - reloadStarted
            lastReloadPerformance = measuredReload
            #endif
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

        #if DEBUG
        let treeStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let treeSpan = PerformanceRecorder.shared.begin(
            "sidebar.tree.build",
            category: "sidebar",
            metadata: ["projects": String(projects.count)]
        )
        let rebuilt = SidebarTreeBuilder.rootNodes(
            from: projects,
            visibility: sessionVisibility
        )
        treeSpan.end(metadata: ["roots": String(rebuilt.count)])
        #if DEBUG
        measuredReload.treeNanoseconds = DispatchTime.now().uptimeNanoseconds - treeStarted
        let shapeStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        let shape = SidebarTreeShape(roots: rebuilt)
        #if DEBUG
        measuredReload.shapeNanoseconds = DispatchTime.now().uptimeNanoseconds - shapeStarted
        #endif

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
        #if DEBUG
        let adoptionStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        rootNodes = SidebarOutlineUpdate.adopt(rebuilt, reusing: rootNodes)
        #if DEBUG
        measuredReload.adoptionNanoseconds = DispatchTime.now().uptimeNanoseconds
            - adoptionStarted
        #endif
        renderedShape = shape
        #if DEBUG
        let indexingStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        rebuildNodeIndexes()
        #if DEBUG
        measuredReload.indexingNanoseconds = DispatchTime.now().uptimeNanoseconds
            - indexingStarted
        #endif

        setEmptyStateVisible(rootNodes.isEmpty)

        #if DEBUG
        let outlineStarted = DispatchTime.now().uptimeNanoseconds
        #endif
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
        applyStructure(
            steps: steps,
            wholesale: isFirstList,
            recursivelyExpandStandingRows: isFirstList
        )

        if let selectedTerminalID {
            select(terminalID: selectedTerminalID, notifyDelegate: false)
        } else if let selectedSessionID {
            select(sessionID: selectedSessionID, notifyDelegate: false)
        }
        outlineSpan.end(metadata: [
            "rows": String(outlineView.numberOfRows),
            "steps": String(steps.count)
        ])
        #if DEBUG
        measuredReload.outlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            - outlineStarted
        #endif
    }

    /// Reorders the one project whose session title changed while Name order is active.
    ///
    /// A title cannot add a row, change repository grouping, move a terminal, or change a
    /// session's branch/lineage. Rebuilding all projects for it made one 5,000-session title
    /// event sort thousands of unrelated names. Rebuild the affected project's projection,
    /// preserve every presented node identity, then apply the same outline diff as `reload`.
    /// Unexpected identity drift falls back to the complete path rather than leaving indexes
    /// that do not describe the tree.
    private func applySessionOrderChange(_ sessionID: SessionID) {
        guard let presentedProject = projectNodesBySessionID[sessionID],
              let rebuiltProject = SidebarTreeBuilder.projectNode(
                  for: presentedProject.projectID,
                  from: projectStore.projects,
                  visibility: sessionVisibility
              )
        else {
            reload()
            return
        }

        let presentedProjectShape = SidebarTreeShape(roots: [presentedProject])
        let rebuiltProjectShape = SidebarTreeShape(roots: [rebuiltProject])
        guard presentedProjectShape.keys == rebuiltProjectShape.keys else {
            reload()
            return
        }

        let span = PerformanceRecorder.shared.begin(
            "sidebar.session-order.apply",
            category: "sidebar",
            metadata: ["project_sessions": String(rebuiltProject.sessionNodes.count)]
        )
        let steps = SidebarOutlineUpdate.steps(
            from: presentedProjectShape,
            to: rebuiltProjectShape
        )
        _ = SidebarOutlineUpdate.adopt([rebuiltProject], reusing: [presentedProject])
        renderedShape.replaceSubtreeOrdering(with: rebuiltProjectShape)

        guard !steps.isEmpty else {
            refreshRow(sessionID: sessionID)
            span.end(metadata: ["steps": "0"])
            return
        }

        applyStructure(steps: steps, wholesale: false)
        refreshRow(sessionID: sessionID)
        span.end(metadata: ["steps": String(steps.count)])
    }

    /// Rebuilds one project's descendants after a session is permanently removed.
    ///
    /// Repository grouping and every other project stand unchanged, so a complete tree build,
    /// shape walk, adoption pass, and index rebuild made deletion scale with unrelated chats.
    /// The same outline diff remains authoritative; only its input is the affected subtree.
    private func applyProjectStructureChange(_ projectID: ProjectID) {
        #if DEBUG
        let updateStarted = DispatchTime.now().uptimeNanoseconds
        var measuredUpdate = ProjectSidebarReloadPerformance()
        defer {
            measuredUpdate.totalNanoseconds = DispatchTime.now().uptimeNanoseconds - updateStarted
            lastProjectStructureNanoseconds = measuredUpdate.totalNanoseconds
            lastProjectStructurePerformance = measuredUpdate
        }
        let treeStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        guard let presentedProject = projectNodesByID[projectID],
              let rebuiltProject = SidebarTreeBuilder.projectNode(
                  for: projectID,
                  from: projectStore.projects,
                  visibility: sessionVisibility
              )
        else {
            reload()
            return
        }
        #if DEBUG
        measuredUpdate.treeNanoseconds = DispatchTime.now().uptimeNanoseconds - treeStarted
        let shapeStarted = DispatchTime.now().uptimeNanoseconds
        #endif

        let span = PerformanceRecorder.shared.begin(
            "sidebar.project-structure.apply",
            category: "sidebar",
            metadata: ["project_sessions": String(rebuiltProject.sessionNodes.count)]
        )
        let presentedProjectShape = SidebarTreeShape(roots: [presentedProject])
        let rebuiltProjectShape = SidebarTreeShape(roots: [rebuiltProject])
        #if DEBUG
        measuredUpdate.shapeNanoseconds = DispatchTime.now().uptimeNanoseconds - shapeStarted
        #endif
        let steps = SidebarOutlineUpdate.steps(
            from: presentedProjectShape,
            to: rebuiltProjectShape
        )
        #if DEBUG
        let adoptionStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        guard let adoptedProject = SidebarOutlineUpdate.adopt(
            [rebuiltProject],
            reusing: [presentedProject]
        ).first as? ProjectNode else {
            span.end(metadata: ["fallback": "adoption"])
            reload()
            return
        }
        #if DEBUG
        measuredUpdate.adoptionNanoseconds = DispatchTime.now().uptimeNanoseconds
            - adoptionStarted
        #endif

        guard renderedShape.replaceSubtree(
            presentedProjectShape,
            with: rebuiltProjectShape
        ) else {
            span.end(metadata: ["fallback": "shape"])
            reload()
            return
        }
        #if DEBUG
        let indexingStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        replaceIndexes(
            for: adoptedProject,
            removing: presentedProjectShape.keys
        )
        #if DEBUG
        measuredUpdate.indexingNanoseconds = DispatchTime.now().uptimeNanoseconds
            - indexingStarted
        let outlineStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        applyStructure(steps: steps, wholesale: false)
        if let row = projectRow(for: projectID) {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: [0])
        }
        #if DEBUG
        measuredUpdate.outlineNanoseconds = DispatchTime.now().uptimeNanoseconds - outlineStarted
        #endif
        span.end(metadata: ["steps": String(steps.count)])
    }

    /// Removes one rendered leaf without rebuilding every sibling in its project.
    ///
    /// A deletion that changes grouping still takes the complete project-local path: a parent
    /// with children becoming orphaned, or a two-item branch losing the level it had earned, can
    /// move several rows. The overwhelmingly common leaf under a stable project/branch/session
    /// parent changes one child array, one shape entry, three identity maps and one outline row.
    private func applySessionRemoval(_ sessionID: SessionID, from projectID: ProjectID) {
        guard let sessionNode = sessionNodesByID[sessionID] else {
            // Archived or filtered into the other attention scope: no presented row changed.
            return
        }
        guard let projectNode = projectNodesByID[projectID],
              projectNodesBySessionID[sessionID] === projectNode,
              sessionNode.childNodes.isEmpty,
              let parent = ancestorsBySessionID[sessionID]?.last as? any SidebarOutlineNode
        else {
            applyProjectStructureChange(projectID)
            return
        }

        // At one remaining item, branch grouping may dissolve or stay because another shared
        // branch keeps lone headings enabled. Rebuild that uncommon boundary rather than copy
        // the tree builder's grouping policy into the mutation path.
        if let branch = parent as? BranchGroupNode,
           branch.sidebarOutlineChildCount <= 2 {
            applyProjectStructureChange(projectID)
            return
        }

        guard let flatIndex = projectNode.sessionNodes.firstIndex(where: { $0 === sessionNode })
        else {
            applyProjectStructureChange(projectID)
            return
        }

        let parentKey = parent.sidebarKey
        let childIndex: Int?
        switch parent {
        case let project as ProjectNode:
            childIndex = project.childNodes.firstIndex(where: { $0 === sessionNode })
        case let branch as BranchGroupNode:
            childIndex = branch.sessionNodes.firstIndex(where: { $0 === sessionNode })
        case let ancestor as SessionNode:
            childIndex = ancestor.childNodes.firstIndex(where: { $0 === sessionNode })
        default:
            childIndex = nil
        }

        guard let childIndex,
              renderedShape.children(of: parentKey).indices.contains(childIndex),
              renderedShape.children(of: parentKey)[childIndex] == .session(sessionID),
              renderedShape.children(of: .session(sessionID)).isEmpty else {
            // No presentation mutation has happened yet. Rebuild from the authoritative store
            // if a damaged presented tree did not agree with its own indexes.
            applyProjectStructureChange(projectID)
            return
        }

        // Begin the exact-path measurement only after every invariant that can choose the
        // project-local fallback. Starting sooner made the cheap abandoned attempt overwrite
        // the fallback's real tree/shape/adoption timings in the stress ledger.
        #if DEBUG
        let updateStarted = DispatchTime.now().uptimeNanoseconds
        var measuredUpdate = ProjectSidebarReloadPerformance()
        defer {
            measuredUpdate.totalNanoseconds = DispatchTime.now().uptimeNanoseconds - updateStarted
            lastProjectStructureNanoseconds = measuredUpdate.totalNanoseconds
            lastProjectStructurePerformance = measuredUpdate
        }
        let indexingStarted = DispatchTime.now().uptimeNanoseconds
        #endif

        projectNode.sessionNodes.remove(at: flatIndex)
        switch parent {
        case let project as ProjectNode:
            project.childNodes.remove(at: childIndex)
        case let branch as BranchGroupNode:
            branch.sessionNodes.remove(at: childIndex)
        case let ancestor as SessionNode:
            ancestor.childNodes.remove(at: childIndex)
        default:
            preconditionFailure("Validated sidebar session parent changed type")
        }
        let removedShapeIndex = renderedShape.removeLeaf(
            .session(sessionID),
            from: parentKey
        )
        precondition(removedShapeIndex == childIndex)

        nodesByKey.removeValue(forKey: .session(sessionID))
        sessionNodesByID.removeValue(forKey: sessionID)
        projectNodesBySessionID.removeValue(forKey: sessionID)
        ancestorsBySessionID.removeValue(forKey: sessionID)
        #if DEBUG
        measuredUpdate.indexingNanoseconds = DispatchTime.now().uptimeNanoseconds
            - indexingStarted
        let outlineStarted = DispatchTime.now().uptimeNanoseconds
        #endif

        applyStructure(
            steps: [.remove(parent: parentKey, indexes: IndexSet(integer: childIndex))],
            wholesale: false
        )
        if let row = projectRow(for: projectID) {
            outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: [0])
        }
        #if DEBUG
        measuredUpdate.outlineNanoseconds = DispatchTime.now().uptimeNanoseconds - outlineStarted
        #endif
    }

    /// Replaces only the identity maps owned by one project subtree.
    private func replaceIndexes(
        for projectNode: ProjectNode,
        removing oldKeys: Set<SidebarNodeKey>
    ) {
        for key in oldKeys where key != .project(projectNode.projectID) {
            nodesByKey.removeValue(forKey: key)
            switch key {
            case .session(let sessionID):
                sessionNodesByID.removeValue(forKey: sessionID)
                projectNodesBySessionID.removeValue(forKey: sessionID)
                ancestorsBySessionID.removeValue(forKey: sessionID)
            case .terminal(let terminalID):
                terminalNodesByID.removeValue(forKey: terminalID)
                projectNodesByTerminalID.removeValue(forKey: terminalID)
                ancestorsByTerminalID.removeValue(forKey: terminalID)
            case .repository, .project, .branch:
                break
            }
        }

        let projectAncestors: [NSObject] = rootNodes.compactMap { root in
            guard let repository = root as? RepoGroupNode,
                  repository.projectNodes.contains(where: { $0 === projectNode }) else {
                return nil
            }
            return repository
        }

        func index(_ node: NSObject, ancestors: [NSObject]) {
            guard let outlineNode = node as? any SidebarOutlineNode else { return }
            nodesByKey[outlineNode.sidebarKey] = node
            switch node {
            case let branch as BranchGroupNode:
                for child in branch.childNodes {
                    index(child, ancestors: ancestors + [branch])
                }
            case let session as SessionNode:
                sessionNodesByID[session.sessionID] = session
                projectNodesBySessionID[session.sessionID] = projectNode
                ancestorsBySessionID[session.sessionID] = ancestors
                for child in session.childNodes {
                    index(child, ancestors: ancestors + [session])
                }
            case let terminal as TerminalNode:
                terminalNodesByID[terminal.terminalID] = terminal
                projectNodesByTerminalID[terminal.terminalID] = projectNode
                ancestorsByTerminalID[terminal.terminalID] = ancestors
            default:
                break
            }
        }

        nodesByKey[.project(projectNode.projectID)] = projectNode
        for child in projectNode.childNodes {
            index(child, ancestors: projectAncestors + [projectNode])
        }
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
    private func applyStructure(
        steps: [SidebarOutlineStep],
        wholesale: Bool,
        recursivelyExpandStandingRows: Bool = false
    ) {
        let animated = !Design.Motion.reducesMotion && !wholesale
        let animation: NSTableView.AnimationOptions = animated ? [.effectFade] : []
        let insertedKeys = steps.flatMap { step -> [SidebarNodeKey] in
            guard case let .insert(parent, indexes) = step else { return [] }
            let children = renderedShape.children(of: parent)
            return indexes.compactMap { children.indices.contains($0) ? children[$0] : nil }
        }
        let needsExpansionPass = wholesale || !insertedKeys.isEmpty

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

            if needsExpansionPass {
                expandStandingRows(
                    animated: animated,
                    recursively: recursivelyExpandStandingRows
                )
            }
        }

        if animated, !insertedKeys.isEmpty {
            // AppKit owns this fade, including its presentation frames. On macOS 26 an unshown
            // outline can retire those frames without restoring the row view's model alpha from
            // zero. Its animation-group completion is withheld in the same state, so normalize
            // one frame after the measured duration. A per-key token prevents an older pass from
            // cutting short a newer fade if the same identity is removed and reinserted quickly.
            let token = UUID()
            for key in insertedKeys { pendingInsertFadeFinalizations[key] = token }
            let delay = Design.Motion.standard + (1.0 / 60.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                for key in insertedKeys where self.pendingInsertFadeFinalizations[key] == token {
                    self.pendingInsertFadeFinalizations.removeValue(forKey: key)
                    self.presentedRowView(of: key)?.alphaValue = 1
                }
            }
        }

        // A move can change which root stands first, and a moved row keeps its view — so the
        // compact tree's rules are re-stamped after every structural pass rather than only
        // where a row view is born (`didAdd`).
        refreshGroupRules()
    }

    /// Opens the rows that are meant to be open. Idempotent — `expandItem` on a row that is
    /// already open does nothing — so this runs after every structural change and only the rows
    /// that just arrived actually move.
    private func expandStandingRows(animated: Bool, recursively: Bool = false) {
        let wasApplyingStandingExpansion = isApplyingStandingExpansion
        isApplyingStandingExpansion = true
        defer { isApplyingStandingExpansion = wasApplyingStandingExpansion }

        let outline = animated ? outlineView.animator() : outlineView

        // Repository headings have no persisted disclosure state. A project can also be a root
        // when it is the repository's only checkout, but its persisted state is handled below;
        // expanding every root here silently reopened those standalone projects on launch.
        for case let repository as RepoGroupNode in rootNodes {
            outline.expandItem(repository)
        }

        for node in allProjectNodes {
            let project = projectStore.project(withID: node.projectID)
            if project?.isExpanded ?? true {
                // The first tree has no transient disclosure choices to preserve. Asking AppKit
                // once per project to expand its descendants avoids hundreds of live row-count
                // mutations and keeps that expansion batched whether or not the host arrived
                // with a live viewport.
                if recursively,
                   collapsedBranchKeys.isEmpty,
                   collapsedSideChatParents.isEmpty {
                    outline.expandItem(node, expandChildren: true)
                    continue
                }
                outline.expandItem(node)
                expandStandingDescendants(of: node, in: outline)
            }
        }
    }

    /// Opens one project's default-open groups after the project itself is visible. AppKit does
    /// not remember an expansion request made beneath a closed ancestor, so this same path runs
    /// both during reload and when the user later opens a project persisted as closed.
    private func expandStandingDescendants(of project: ProjectNode, in outline: NSOutlineView) {
        func expandSideChat(_ session: SessionNode) {
            guard !session.childNodes.isEmpty,
                  !collapsedSideChatParents.contains(session.sessionID)
            else { return }
            outline.expandItem(session)
            for child in session.childNodes {
                expandSideChat(child)
            }
        }

        // Branch groups open with their project; only ones collapsed by hand stay shut.
        for case let branchNode as BranchGroupNode in project.childNodes
        where !collapsedBranchKeys.contains(Self.branchKey(branchNode)) {
            outline.expandItem(branchNode)
        }

        // Side chats do the same beneath the session they were forked from. Walk the presented
        // tree rather than `sessionNodes`' flat sort order: recent/name ordering can put a
        // descendant before its parent, and AppKit cannot expand an item whose ancestor has not
        // made it into the outline yet.
        for child in project.childNodes {
            if let branch = child as? BranchGroupNode,
               !collapsedBranchKeys.contains(Self.branchKey(branch)) {
                for session in branch.sessionNodes {
                    expandSideChat(session)
                }
            } else if let session = child as? SessionNode {
                expandSideChat(session)
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

    /// Re-answers `showsGroupRule` for every row view the outline currently owns.
    private func refreshGroupRules() {
        let rowViews = instantiatedHoverRowViews.allObjects
        #if DEBUG
        lastGroupRuleRefreshCandidateCount = rowViews.count
        #endif
        for rowView in rowViews {
            let row = outlineView.row(for: rowView)
            guard row >= 0 else { continue }
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

        guard projectStore.removeSession(id: sessionID) == .applied else {
            presentToast(ToastRequest(
                message: L10n.format("Couldn’t delete “%@”", session.displayTitle),
                detail: L10n.string(
                    "The project data could not be saved. Its running agent was left alone."
                ),
                identifier: "sidebar.toast.delete.persistence.failed"
            ))
            return
        }
        // Deleting the durable owner is the commitment point. A refused database write must not
        // kill a process whose row and resumable record still stand.
        AgentRuntime.shared.discardDeletedSession(sessionID)
        // `removeSession` posts its project-scoped structural event synchronously. That pass has
        // already removed the row; another reload here rebuilt and refreshed the same list.
        delegate?.projectSidebar(self, didRemoveSession: sessionID)
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
        // A rename asks for no accelerated affirmative, so `.immediate` cannot arrive — and if
        // one were ever added, what was typed is still what was typed.
        switch TextPromptAlert.ask(request) {
        case .text(let typed), .immediate(let typed): completion(typed)
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

    private func refreshVisibleSessionCustomizations(
        changedTargets: Set<ExtensionComponentTarget>?
    ) {
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }

        let upperBound = min(NSMaxRange(visibleRows), outlineView.numberOfRows)
        for row in visibleRows.location..<upperBound {
            guard let view = outlineView.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ) as? SessionRowView else { continue }
            view.refreshCustomizations(changedTargets: changedTargets)
        }
    }

    /// Aggregate outline state used by the deterministic sidebar workload. Keeping this seam
    /// here lets the test use the production data source, delegate, row reuse and layout path
    /// without exposing the outline view itself.
    var initialTreeIsMounted: Bool { hasMountedInitialTree }

    /// Whether the no-project prompt paid its construction cost. A populated startup should
    /// never cross this branch; deterministic lifecycle tests keep that scaling rule explicit.
    var emptyStateIsMaterialized: Bool { emptyStateView != nil }

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
            setEmptyStateVisible(false)
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
            setEmptyStateVisible(rootNodes.isEmpty)
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
        guard let project = projectStore.addProject(folderURL: folderURL) else {
            presentProjectNotice(L10n.string("The project could not be saved."))
            return
        }
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
                guard self.projectStore.renameProject(id: node.projectID, to: newName).succeeded
                else {
                    self.reload()
                    self.presentProjectNotice(L10n.string("The project data could not be saved."))
                    return
                }
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
                guard self.projectStore.renameSession(id: node.sessionID, to: newTitle).succeeded
                else {
                    self.reload()
                    self.presentProjectNotice(L10n.string("The project data could not be saved."))
                    return
                }
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
                guard self.projectStore.renameTerminal(id: node.terminalID, to: newTitle).succeeded
                else {
                    self.reload()
                    self.presentProjectNotice(L10n.string("The project data could not be saved."))
                    return
                }
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

        guard projectStore.removeProject(id: projectID) == .applied else {
            reload()
            presentToast(ToastRequest(
                message: L10n.format("Couldn’t remove “%@”", project.name),
                detail: L10n.string(
                    "The project data could not be saved. Its running processes were left alone."
                ),
                identifier: "sidebar.toast.remove-project.persistence.failed"
            ))
            return
        }
        // As with a surface switch, process teardown follows the durable graph mutation. A store
        // refusal leaves every running chat and terminal untouched and still reachable.
        for session in project.sessions {
            AgentRuntime.shared.discardDeletedSession(session.id)
        }
        ProjectTerminalRuntime.shared.discard(terminalsIn: project)
        reload()
        delegate?.projectSidebarDidRemoveSessions(self)
    }

    private func closeTerminal(_ terminalID: TerminalID) {
        guard projectStore.removeTerminal(id: terminalID) == .applied else {
            reload()
            presentToast(ToastRequest(
                message: L10n.string("Couldn’t close the terminal"),
                detail: L10n.string(
                    "The project data could not be saved. The terminal was left running."
                ),
                identifier: "sidebar.toast.close-terminal.persistence.failed"
            ))
            return
        }
        ProjectTerminalRuntime.shared.discard(terminalID: terminalID)
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
        case .projectStructure(let projectID):
            applyProjectStructureChange(projectID)
        case .sessionRemoved(let projectID, let sessionID):
            applySessionRemoval(sessionID, from: projectID)
        case .sessionOrder(let sessionID):
            applySessionOrderChange(sessionID)
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
                    image: ThemedMenuIcon.symbol("bubble.left"),
                    onChoose: pinnedAction(row) { $0.newProjectChatClicked() }
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("New Terminal"),
                    image: ThemedMenuIcon.symbol("terminal"),
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

    private func snoozedSessionsEntry() -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: L10n.string("Snoozed Sessions"),
            isSelected: sessionVisibility == .snoozed,
            onChoose: { [weak self] in self?.toggleSnoozedSessionsClicked() }
        ))
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

    /// One direction as a checkable row, worded for the order it applies to — a second radio
    /// group under the orders rather than a modifier on each of them, so three sorts stay three
    /// rows instead of six. The wording follows the chosen order because "Descending" describes
    /// a comparator, not a list of sessions.
    private func directionEntry(isReversed: Bool) -> ThemedMenuEntry {
        let order = AppSettings.shared.sidebarSessionOrder
        return .item(ThemedMenuItem(
            title: isReversed ? order.reversedDirectionTitle : order.naturalDirectionTitle,
            isSelected: AppSettings.shared.sidebarSessionOrderIsReversed == isReversed,
            onChoose: { [weak self] in self?.sessionOrderDirectionChosen(isReversed) }
        ))
    }

    @objc private func toggleBranchGroupingClicked() {
        AppSettings.shared.groupsSessionsByBranch.toggle()
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func toggleSnoozedSessionsClicked() {
        sessionVisibility = sessionVisibility == .snoozed ? .attention : .snoozed
        reload()
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

    private func sessionOrderDirectionChosen(_ isReversed: Bool) {
        AppSettings.shared.sidebarSessionOrderIsReversed = isReversed
        NotificationCenter.default.post(ProjectsDidChange())
    }
}

// MARK: - NSOutlineViewDataSource

extension ProjectSidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootNodes.count }
        return (item as? any SidebarOutlineNode)?.sidebarOutlineChildCount ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return rootNodes[index] }
        guard let node = item as? any SidebarOutlineNode else { return rootNodes[index] }
        return node.sidebarOutlineChild(at: index)
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
        instantiatedHoverRowViews.add(rowView)
        rowView.showsGroupRule = showsGroupRule(forRow: row)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        didRemove rowView: NSTableRowView,
        forRow row: Int
    ) {
        guard let rowView = rowView as? SidebarHoverRowView else { return }
        instantiatedHoverRowViews.remove(rowView)
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
        // `expandStandingRows` is the authoritative programmatic pass. AppKit synchronously
        // reflects it here, but this callback is the *user* disclosure route: entering it would
        // repeat descendant expansion and issue persistence work for state that already matches.
        guard !isApplyingStandingExpansion else { return }

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
        expandStandingDescendants(of: node, in: outlineView)
        reloadRow(for: node)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isApplyingStandingExpansion else { return }

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
            terminalSoundEntry(for: terminalID),
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
                image: ThemedMenuIcon.symbol("pencil"),
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
            image: ThemedMenuIcon.symbol("magnifyingglass"),
            onChoose: pinnedAction(row) { $0.revealInFinderClicked() }
        )))
        entries.append(projectIconEntry(row: row))
        if let projectID {
            entries.append(projectThemeEntry(for: projectID))
            // Beside Theme, not beside Mute below it: presentation, not delivery.
            entries.append(projectSoundEntry(for: projectID))
            entries.append(projectChangeRequestEntry(for: projectID))
            entries.append(projectMuteEntry(for: projectID, row: row))
        }
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Reclaim Disk Space…"),
            image: ThemedMenuIcon.symbol("internaldrive"),
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
            image: ThemedMenuIcon.symbol("minus.circle"),
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

        guard projectStore.setNotificationsMuted(
            !(project.notificationsMuted ?? false),
            forProjectID: projectID
        ).succeeded else {
            reload()
            presentProjectNotice(L10n.string("The project data could not be saved."))
            return
        }
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

            guard let data = ProjectIconStore.candidateData(at: url) else {
                self?.presentIconNotice(
                    L10n.string("The file could not be read as an image.")
                )
                return
            }

            guard let self else { return }
            switch self.projectStore.setIcon(
                imageData: data,
                source: .custom,
                for: projectID
            ) {
            case .success:
                break
            case .failure(.unusableImage):
                self.presentIconNotice(L10n.string("The file could not be read as an image."))
            case .failure:
                self.presentIconNotice(L10n.string("The project icon could not be saved."))
            }
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
                    guard let data else {
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
                    guard let self else { return }
                    switch self.projectStore.setIcon(
                        imageData: data,
                        source: .custom,
                        for: projectID
                    ) {
                    case .success:
                        break
                    case .failure(.unusableImage):
                        self.presentIconNotice(
                            L10n.format("No favicon was found at %@.", origin.absoluteString)
                        )
                    case .failure:
                        self.presentIconNotice(L10n.string("The project icon could not be saved."))
                    }
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

    func presentProjectNotice(_ message: String) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Project")
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
    func projectSidebar(_ sidebar: ProjectSidebarViewController, didRemoveSession sessionID: SessionID)
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
            snoozedSessionsEntry(),
            .separator,
            branchGroupingEntry(),
            loneBranchHeadingsEntry(),
            compactTreeEntry(),
            .separator
        ]
        for order in SidebarSessionOrder.allCases {
            entries.append(orderEntry(order))
        }
        entries.append(.separator)
        entries.append(directionEntry(isReversed: false))
        entries.append(directionEntry(isReversed: true))
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
