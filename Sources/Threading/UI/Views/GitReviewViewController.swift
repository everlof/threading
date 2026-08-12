import AppKit

/// The Review tab: what changed in this session's checkout, as a native diff surface.
///
/// A mode chip picks the comparison — everything since the last commit, the index, the
/// branch against its base, the last agent turn, or any commit from history — and the body
/// is a scrolling list of per-file collapsible diffs.
///
/// The pane watches the checkout and re-reads itself, so the reader's place is kept
/// deliberately: the scroll offset survives a reload of the same surface, and a file opened
/// or closed by hand stays that way. Staging lives in `GitReviewStaging`, and only in the
/// modes whose diff is measured from the index.
final class GitReviewViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    let folderPath: String

    private(set) var mode: GitReviewMode
    private(set) var selectedTurnID: GitTurnCheckpointID?

    private var isTurnInFlight: Bool {
        guard mode == .lastTurn else {
            return AgentRuntime.shared.activity(sessionID: sessionID).hasTurnInFlight
        }
        return selectedTurnID == GitTurnBaselineStore.shared
            .activeCheckpoint(forSessionID: sessionID)?.id
    }

    private var modeTitle: String {
        mode.title(isTurnInFlight: isTurnInFlight)
    }

    /// Called when the user picks a different mode, so the pane can persist the tab with it.
    var onModeChange: (() -> Void)?

    /// Feeds the selected sidebar row. It stays true through main-thread view construction,
    /// not merely through the background git read.
    var onLoadingChange: (@MainActor @Sendable (Bool) -> Void)?

    lazy var backButton: ThemedButton = {
        let button = ThemedButton(
            symbol: "chevron.left",
            accessibility: L10n.string("Back"),
            target: self,
            action: #selector(backToCommits)
        )
        button.isBordered = false
        button.toolTip = L10n.string("Back to history")
        button.isHidden = true
        return button
    }()
    lazy var modeChip: ChipView = {
        let chip = ChipView()
        chip.configure(symbolName: GitReviewUIDefaults.modeSymbol, title: modeTitle)
        chip.itemsProvider = { [weak self] in self?.modeItems() ?? [] }
        chip.onSelect = { [weak self] item in
            guard let raw = item.representedValue as? String,
                  let mode = GitReviewMode(rawValue: raw) else { return }
            self?.switchMode(to: mode)
        }
        return chip
    }()
    lazy var turnChip: ChipView = {
        let chip = ChipView()
        chip.isHidden = true
        chip.itemsProvider = { [weak self] in self?.turnItems() ?? [] }
        chip.onSelect = { [weak self] item in
            guard let raw = item.representedValue as? String,
                  let checkpointID = GitTurnCheckpointID(uuidString: raw) else { return }
            self?.selectTurn(checkpointID)
        }
        return chip
    }()
    private lazy var headerCluster: NSStackView = {
        let cluster = NSStackView(views: [backButton, modeChip, turnChip])
        cluster.orientation = .horizontal
        cluster.alignment = .centerY
        cluster.spacing = Design.Spacing.tight
        cluster.translatesAutoresizingMaskIntoConstraints = false
        return cluster
    }()
    /// The header's margin, held because which view starts the row changes: the chip is a pill
    /// whose frame is its ink, and Back is a plain button carrying its hover surface around a
    /// chevron. Pinned alike they would start 4pt apart, which is visible against a column of
    /// cards on one straight edge.
    private lazy var headerClusterLeading: NSLayoutConstraint = headerCluster.leadingAnchor
        .constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.inset)
    lazy var counterLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()
    private lazy var menuButton: ThemedButton = {
        let button = ThemedButton(
            symbol: "ellipsis",
            accessibility: L10n.string("Diff options"),
            target: self,
            action: #selector(showOverflowMenu(_:))
        )
        button.isBordered = false
        button.toolTip = L10n.string("Diff options")
        return button
    }()
    lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        // No top inset: the gap under the header is the scroll view's, so the stack path and the
        // file table start their first row on the same line.
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        return stack
    }()
    private let clipView = FlippedClipView()
    lazy var scrollView: NSScrollView = {
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clipView
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()
    lazy var fileTableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("GitReviewFile"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        // `.automatic` resolves to `.inset` here, which keeps 16pt at each side and 10pt above
        // the first row — a margin of AppKit's own, on top of the pane's, that put every file
        // card 40pt in while the header's chip started at 12. `.plain` with no intercell width
        // hands the row the table's full width, so the pane's inset is the only one there is.
        // It is also what `viewDidLayout`'s column check already assumes: under `.inset` the
        // column can never equal the table's width, so the guard never held.
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // No intercell spacing either: AppKit splits it, hanging half a gap above the first card
        // as well as between every pair, so the header's margin measured 3pt wider than the
        // pane's. `GitReviewVirtualRowHost` carries the gap under each row instead, where it
        // separates cards without also padding the top of the list.
        table.intercellSpacing = .zero
        table.rowHeight = 48
        // File rows publish their TextKit-measured heights through the delegate. AppKit's
        // automatic path double-counts a vertically large NSTextView during its first fitting
        // pass, producing blank document height even when the descendant constraints are right.
        table.usesAutomaticRowHeights = false
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()
    lazy var placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.body)
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }()
    lazy var changeRequestBar: GitReviewChangeRequestBar = {
        let bar = GitReviewChangeRequestBar()
        bar.isHidden = true
        bar.onPrimaryAction = { [weak self] in self?.performChangeRequestPrimaryAction() }
        bar.onOpen = { [weak self] in self?.openCurrentPullRequest() }
        bar.onPolicyChange = { [weak self] policy in
            guard let self else { return }
            ChangeRequestConfigurationStore.shared.setPublishPolicy(
                policy,
                forProjectPath: self.folderPath
            )
            self.renderChangeRequestBar()
        }
        return bar
    }()
    lazy var jumpToEndButton: ThemedButton = {
        let button = ThemedButton.floatingScrollToEnd(
            accessibility: L10n.string("Scroll to the end of the diff"),
            target: self,
            action: #selector(scrollToDiffEnd)
        )
        button.isHidden = true
        return button
    }()
    private let scrollEvents = AppEventObservations()
    private let appEvents = AppEventObservations()

    /// What the body is currently showing. Commit mode is two phases deep: the history list,
    /// and one commit opened out of it.
    enum Phase {
        case message(String)
        case files([GitFileDiff])
        case commits(canLoadMore: Bool)
        case commitDetail(GitCommitSummary, [GitFileDiff])
    }

    var phase: Phase = .message("")

    /// The history list survives opening a commit, so Back is free.
    var commits: [GitCommitSummary] = []
    var lastPageWasFull = false

    /// Stale async results are dropped by generation, not cancelled — git is already running.
    private var generation = 0
    private var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            onLoadingChange?(isLoading)
        }
    }
    private var lastLoadedAt: Date?

    /// The mode the body on screen was drawn for, so a reload of the same surface can keep the
    /// reader's place while a mode switch starts at the top.
    var renderedMode: GitReviewMode?
    var renderedTurnID: GitTurnCheckpointID?
    var loadedDiffRoot: URL?

    /// Which files the user has opened or closed by hand. Consulted ahead of the initial expanded
    /// state, so a watched checkout re-reading itself does not undo what the reader chose.
    var expansionOverrides: [String: Bool] = [:]
    var bulkExpansionOverride: Bool?

    /// File comparisons use a reusable table. `NSStackView` eagerly solves constraints for
    /// every arranged child, which made both the original eager list and progressively appended
    /// deep indexes superlinear. The table owns all model rows while creating views only around
    /// the viewport.
    var renderedFiles: [GitFileDiff] = []
    var filePreludeViews: [NSView] = []
    var renderedFileRoot: URL?
    var instantiatedFileRowCount = 0
    var instantiatedDeferredFileRowCount = 0
    var measuredFileRowHeights: [String: (width: CGFloat, height: CGFloat)] = [:]
    var measuredPreludeRowHeights: [Int: (width: CGFloat, height: CGFloat)] = [:]
    var fileRowHeightWidth: CGFloat = 0

    /// Whether a long line wraps to the pane or runs off it into a horizontal scroller. Wrapping
    /// is the default because the pane is often narrow, and hiding half a changed line off the
    /// right edge is worse — but a wide window reading long lines wants the other trade.
    var wrapsDiffLines = true

    /// Whether git is asked to fold away whitespace-only changes. A re-read rather than a
    /// display filter: what counts as a changed line is git's judgement, not the view's.
    var ignoresWhitespace = false

    /// The checkout changed while a load was in flight or the pane was off screen; the next
    /// opportunity re-reads regardless of the debounce.
    private var pendingReload = false

    /// A checkout refresh must not replace table rows in the middle of trackpad momentum.
    /// Keep only the newest result and reconcile it when AppKit ends the live-scroll gesture.
    var isFileLiveScrolling = false
    var isFileScrollerSeeking = false
    var deferredPhaseDuringLiveScroll: Phase?

    /// The clock that turns a held-still scroller thumb into real content: every knob action
    /// pushes it back, so it fires only once the thumb has genuinely paused.
    var scrollerSeekSettleWork: DispatchWorkItem?

    private var watcher: GitCheckoutWatcher?

    /// The commit message being written, kept here rather than in the composer: the composer
    /// is rebuilt every time the pane re-reads, which staging makes happen constantly.
    var commitMessage = ""
    weak var commitComposer: PromptView?

    /// A commit-draft run in flight. On the controller, like the message itself — the
    /// composer row is rebuilt on every re-read, and busy-ness must survive the rebuild.
    var isDraftingCommitMessage = false
    weak var draftButton: ThemedButton?

    /// What the last write said, shown once above the diff. Cleared by the render that shows
    /// it, so it never outlives the thing it is about.
    var notice: (text: String, isError: Bool)?

    /// Change-request state is loaded beside the diff, but has its own generation and task: a
    /// network answer from the old branch must not repaint the newly checked-out one.
    let changeRequestProviders: ChangeRequestProviderRegistry
    var changeRequestLocalState: ChangeRequestLocalState?
    var changeRequestRepositoryStatus: ChangeRequestRepositoryStatus?
    var changeRequestFailureMessage: String?
    var changeRequestPrimaryAction: GitReviewChangeRequestPrimaryAction = .retry
    var changeRequestTask: Task<Void, Never>?
    var changeRequestGeneration = 0
    var isChangingRequest = false
    var lastChangeRequestRead: (signature: String, date: Date)?
    lazy var changeRequestBarHeight = changeRequestBar.heightAnchor
        .constraint(equalToConstant: 0)
    lazy var scrollViewTop = scrollView.topAnchor.constraint(
        equalTo: changeRequestBar.bottomAnchor
    )

    /// Holds the header's `···` dropdown while it is up; released from its own dismissal.
    var overflowMenuSession: AnyObject?

    // MARK: - Initialization

    /// One initializer: the turn selection the durable-checkpoint work introduced, and the
    /// provider registry the GitLab work introduced, are independent injections and both default.
    init(
        sessionID: SessionID,
        folderPath: String,
        mode: GitReviewMode,
        selectedTurnID: GitTurnCheckpointID? = nil,
        changeRequestProviders: ChangeRequestProviderRegistry? = nil
    ) {
        self.sessionID = sessionID
        self.folderPath = folderPath
        self.mode = mode
        self.selectedTurnID = selectedTurnID
        self.changeRequestProviders = changeRequestProviders ?? .live()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        // The pane parents this controller's view without adopting the controller, so the
        // appearance callbacks never fire. The view's own move-to-window is the reliable signal
        // for "this tab is on screen", which is when watching earns its keep.
        let root = WindowAwareView()
        root.onWindowChange = { [weak self] window in
            window == nil ? self?.stopWatching() : self?.startWatching()
        }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupBody()
        setupConstraints()

        // The pane's counters and file headers are *built* attributed strings — `+362 −26` is
        // one string carrying two colours — so their font and their ink both freeze at build
        // time, where a plain label's would be re-resolved by the theme sweep. Re-reading is
        // the honest rebuild: this pane already keeps the reader's scroll offset and whatever
        // was expanded by hand across a reload, so a theme switch costs a git read and nothing
        // the user can see move.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refresh(force: true)
        }
        appEvents.observe(ChangeRequestConfigurationDidChange.self) { [weak self] event in
            guard let self,
                  event.repositoryIdentity == GitInfo.repositoryIdentity(for: self.folderPath)
            else { return }
            self.renderChangeRequestBar()
        }
        appEvents.observe(GitTurnCheckpointsDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.refreshModePresentation()
            if self.mode == .lastTurn { self.refresh(force: true) }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard scrollView.documentView === fileTableView else { return }

        // The column follows the table's width in `SoleColumnFitting`, not here. It was here, and
        // a pane laid out before its diff arrives never calls this method again — see that
        // protocol for the cards it left 76pt wide.
        let cardWidth = max(fileTableView.bounds.width - Design.Spacing.inset * 2, 0)
        guard cardWidth > 1, abs(cardWidth - fileRowHeightWidth) > 0.5 else { return }
        fileRowHeightWidth = cardWidth
        guard fileTableView.numberOfRows > 0 else { return }

        // Visible TextKit rows remeasure themselves in `GitReviewFileRow.layout`. Offscreen
        // rows have no views, so invalidate their cheap width-derived estimates as one batch;
        // otherwise a pane resize leaves the document extent and scrollbar at the old wrapping.
        fileTableView.noteHeightOfRows(
            withIndexesChanged: IndexSet(integersIn: 0..<fileTableView.numberOfRows)
        )
    }

    deinit {
        if isLoading {
            let onLoadingChange = onLoadingChange
            Task { @MainActor in
                onLoadingChange?(false)
            }
        }
        watcher?.stop()
        changeRequestTask?.cancel()
    }

    // MARK: - Setup

    private func setupHeader() {
        // One overflow rather than a row of icons: refreshing, collapsing, wrapping and the
        // whitespace fold are all things asked of the diff occasionally, and a header of five
        // glyphs would compete with the mode chip, which is the control that matters here.
        // A stack rather than individual constraints, because the back button is usually
        // hidden: a hidden view keeps the frame its constraints give it, so the chip sat
        // indented past a ghost button and read as floating in the pane rather than starting
        // where the row does. A stack detaches hidden views, so the chip's leading is the
        // row's inset whenever there is nothing to go back to.
        view.addSubview(headerCluster)

        [counterLabel, menuButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }

    private func setupBody() {
        clipView.drawsBackground = false
        clipView.postsBoundsChangedNotifications = true
        scrollEvents.observe(NSView.boundsDidChangeNotification, object: clipView) { [weak self] in
            self?.updateScrollControls()
        }
        scrollEvents.observe(
            NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        ) { [weak self] in
            self?.isFileLiveScrolling = true
        }
        scrollEvents.observe(NSScrollView.didEndLiveScrollNotification, object: scrollView) {
            [weak self] in
            self?.finishFileLiveScrolling()
        }
        if let scroller = scrollView.verticalScroller as? ThemedScroller {
            scroller.onWillScrollWithKnob = { [weak self] in
                self?.beginFileScrollerSeek()
            }
        }

        view.addSubview(scrollView)
        view.addSubview(changeRequestBar)
        view.addSubview(placeholderLabel)
        view.addSubview(jumpToEndButton)
    }

    /// Shows or hides Back, moving the row's margin onto whichever view now starts it.
    func setBackVisible(_ visible: Bool) {
        backButton.isHidden = !visible
        headerClusterLeading.constant = visible
            ? Design.Spacing.inset - backButton.opticalHorizontalInset
            : Design.Spacing.inset
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top would slide
            // the header under it. One margin on all four sides: the row starts and ends where
            // the file cards do, sits `inset` below the tab strip and leaves `inset` above the
            // first card, so the header reads as the top of the list rather than as chrome
            // floating over it.
            headerCluster.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: inset
            ),
            headerClusterLeading,

            counterLabel.leadingAnchor.constraint(
                equalTo: headerCluster.trailingAnchor,
                constant: Design.Spacing.medium
            ),
            counterLabel.firstBaselineAnchor.constraint(equalTo: modeChip.contentFirstBaselineAnchor),
            counterLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: menuButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),

            // Aligned by ink: a plain button's frame carries its hover surface, so pinning the
            // frame to the margin lands the glyph short of it. Pulled out by the padding the
            // button states, the `···` sits on the same line as the cards' trailing edge.
            menuButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -(inset - menuButton.opticalHorizontalInset)
            ),
            menuButton.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),

            changeRequestBar.topAnchor.constraint(equalTo: modeChip.bottomAnchor, constant: inset),
            changeRequestBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            changeRequestBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            changeRequestBarHeight,

            scrollViewTop,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Rows wrap to the pane's width instead of scrolling sideways.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: inset),

            jumpToEndButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpToEndButton.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.inset
            )
        ])
    }

    @objc func scrollToDiffEnd() {
        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumScrollOffsetY()))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateScrollControls()
    }

    func updateScrollControls() {
        guard isViewLoaded,
              scrollView.documentView === fileTableView,
              !counterLabel.isHidden else {
            if isViewLoaded { jumpToEndButton.setFloatingPresence(false) }
            return
        }
        let overflow = maximumScrollOffsetY()
        let distanceFromEnd = overflow - scrollView.contentView.bounds.origin.y
        jumpToEndButton.setFloatingPresence(overflow > 1 && distanceFromEnd > 4)
    }

    /// AppKit's actual terminal scroll position. Let the clip view apply the same constraints
    /// it uses for wheel and scroller-thumb movement rather than approximating from document
    /// and viewport heights.
    func maximumScrollOffsetY() -> CGFloat {
        guard scrollView.documentView != nil else { return 0 }
        let bounds = scrollView.contentView.bounds
        let proposed = NSRect(
            x: bounds.minX,
            y: (scrollView.documentView?.frame.maxY ?? 0) + bounds.height,
            width: bounds.width,
            height: bounds.height
        )
        return max(scrollView.contentView.constrainBoundsRect(proposed).origin.y, 0)
    }

    // MARK: - Public Methods

    /// Reloads the current mode. Non-forced calls debounce and yield to a load in flight —
    /// they arrive from tab switches and activity edges, which cluster.
    func refresh(force: Bool) {
        if !isViewLoaded { loadView() }
        refreshModePresentation()

        // A change the pane could not act on when it arrived is not stale — it is the reason
        // this refresh exists, so it outranks the debounce.
        let force = force || pendingReload
        pendingReload = false

        if !force {
            if isLoading { return }
            if let last = lastLoadedAt,
               Date().timeIntervalSince(last) < GitReviewDefaults.refreshDebounce { return }
        }

        let root: URL?
        if mode == .lastTurn {
            let checkpoints = GitTurnBaselineStore.shared.checkpoints(forSessionID: sessionID)
            guard !checkpoints.isEmpty else {
                setChangeRequestBarVisible(false)
                show(.message(L10n.string(
                    "No turn recorded yet.\nThe checkpoint is captured before the agent starts working."
                )))
                return
            }
            if selectedTurnID == nil || !checkpoints.contains(where: { $0.id == selectedTurnID }) {
                selectedTurnID = checkpoints.last?.id
                refreshModePresentation()
            }
            root = selectedTurnID
                .flatMap(GitTurnBaselineStore.shared.checkpoint(id:))
                .flatMap {
                    GitTurnBaselineStore.shared.repositoryRoot(
                        for: $0,
                        preferredPath: folderPath
                    )
                }
        } else {
            root = repositoryRoot
        }

        guard let root else {
            setChangeRequestBarVisible(false)
            if mode == .lastTurn,
               GitTurnBaselineStore.shared.latestCheckpoint(forSessionID: sessionID) != nil {
                show(.message(L10n.string("The checkpoint repository is no longer available.")))
            } else {
                show(.message("Not a git repository."))
            }
            return
        }

        // Git Review's forced reloads also arrive from filesystem activity. Keep those local
        // reloads responsive without converting every checkout or index write into a GitHub
        // request; explicit PR actions clear the cache and force their own provider refresh.
        refreshChangeRequest(in: root, forceRemote: false)

        switch mode {
        case .commit:
            loadCommitList(in: root, skip: 0)

        case .lastTurn:
            guard let checkpointID = selectedTurnID,
                  let checkpoint = GitTurnBaselineStore.shared.checkpoint(id: checkpointID) else {
                show(.message(L10n.string(
                    "No turn recorded yet.\nThe checkpoint is captured before the agent starts working."
                )))
                return
            }
            guard checkpoint.canPresentDiff else {
                show(.message(
                    checkpoint.failureDescription
                        ?? L10n.string("This turn did not reach a complete checkpoint.")
                ))
                return
            }
            loadDiff(.turnCheckpoint(checkpoint), in: root)

        case .uncommitted: loadDiff(.uncommitted, in: root)
        case .unstaged: loadDiff(.unstaged, in: root)
        case .staged: loadDiff(.staged, in: root)
        case .branch: loadDiff(.branch, in: root)
        }
    }

    // MARK: - Watching

    /// Watches only while the tab is on screen. A dormant tab's checkout is re-read when it is
    /// next shown, which costs one git call rather than a stream per session for the run.
    private func startWatching() {
        guard watcher == nil, let root = repositoryRoot else { return }

        watcher = GitCheckoutWatcher(root: root) { [weak self] in
            self?.checkoutChanged()
        }
        watcher?.start()

        // The tree may have moved on while this tab was away.
        refresh(force: false)
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// The checkout changed. Off screen or mid-load this is only remembered — a diff nobody is
    /// looking at is not worth a git process, and a second load racing the first would show
    /// whichever finished last.
    private func checkoutChanged() {
        guard followsCheckout else { return }
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, !isLoading else {
            pendingReload = true
            return
        }
        refresh(force: true)
    }

    /// An opened commit is immutable and a paged-into history is append-only at the top, so
    /// re-reading either under the pointer loses the reader's place for nothing. Both stay on
    /// the manual button.
    private var followsCheckout: Bool {
        switch phase {
        case .commitDetail: return false
        case .commits: return commits.count <= GitReviewDefaults.logPageSize
        default: return true
        }
    }

    /// Called when a load lands, so a change that arrived while git was running is not lost.
    private func reloadIfPending() {
        guard pendingReload, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh(force: true) }
    }

    // MARK: - Loading

    var repositoryRoot: URL? {
        GitInfo.repositoryRoot(for: folderPath)
    }

    private func loadDiff(_ request: GitReviewReader.DiffRequest, in root: URL) {
        generation += 1
        let expected = generation
        isLoading = true
        let span = PerformanceRecorder.shared.begin(
            "git.review.load-and-render",
            category: "git.review",
            metadata: ["mode": mode.rawValue]
        )

        GitReviewReader.diff(request, in: root, ignoringWhitespace: ignoresWhitespace) { [weak self] result in
            guard let self else {
                span.end(metadata: ["result": "controller-released"])
                return
            }
            guard expected == self.generation else {
                span.end(metadata: ["result": "stale"])
                return
            }
            self.lastLoadedAt = Date()

            switch result {
            case .success(let files):
                self.loadedDiffRoot = root
                self.show(files.isEmpty ? .message("No changes.") : .files(files))
                span.end(metadata: [
                    "result": "success",
                    "files": String(files.count),
                    "changed_lines": String(files.reduce(0) { $0 + $1.added + $1.removed })
                ])
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? L10n.string("git failed.")))
                span.end(metadata: ["result": "failure"])
            }
            self.isLoading = false
            self.reloadIfPending()
        }
    }

    private func loadCommitList(in root: URL, skip: Int) {
        generation += 1
        let expected = generation
        isLoading = true
        let span = PerformanceRecorder.shared.begin(
            "git.review.load-history-and-render",
            category: "git.review",
            metadata: ["skip": String(skip)]
        )

        GitReviewReader.log(skip: skip, in: root) { [weak self] result in
            guard let self else {
                span.end(metadata: ["result": "controller-released"])
                return
            }
            guard expected == self.generation else {
                span.end(metadata: ["result": "stale"])
                return
            }
            self.lastLoadedAt = Date()

            switch result {
            case .success(let page):
                if skip == 0 { self.commits = page } else { self.commits += page }
                self.lastPageWasFull = page.count == GitReviewDefaults.logPageSize
                self.show(self.commits.isEmpty
                    ? .message("No commits yet.")
                    : .commits(canLoadMore: self.lastPageWasFull))
                span.end(metadata: [
                    "result": "success",
                    "commits": String(self.commits.count)
                ])
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? L10n.string("git failed.")))
                span.end(metadata: ["result": "failure"])
            }
            self.isLoading = false
            self.reloadIfPending()
        }
    }

    func openCommit(_ commit: GitCommitSummary) {
        guard let root = repositoryRoot else { return }
        generation += 1
        let expected = generation
        isLoading = true
        let span = PerformanceRecorder.shared.begin(
            "git.review.load-commit-and-render",
            category: "git.review"
        )

        GitReviewReader.diff(
            .commit(hash: commit.hash),
            in: root,
            ignoringWhitespace: ignoresWhitespace
        ) { [weak self] result in
            guard let self else {
                span.end(metadata: ["result": "controller-released"])
                return
            }
            guard expected == self.generation else {
                span.end(metadata: ["result": "stale"])
                return
            }

            switch result {
            case .success(let files):
                self.loadedDiffRoot = root
                if files.isEmpty {
                    self.show(.message("No textual changes (likely a merge commit)."))
                } else {
                    self.show(.commitDetail(commit, files))
                }
                span.end(metadata: [
                    "result": "success",
                    "files": String(files.count)
                ])
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? L10n.string("git failed.")))
                span.end(metadata: ["result": "failure"])
            }
            self.isLoading = false
        }
    }

    // MARK: - Mode

    private func modeItems() -> [ThemedMenuEntry] {
        GitReviewMode.allCases.map { candidate in
            .item(
                ThemedMenuItem(
                    title: candidate.title(isTurnInFlight: isTurnInFlight),
                    subtitle: candidate.comparisonDescription,
                    representedValue: candidate.rawValue,
                    isSelected: candidate == mode
                )
            )
        }
    }

    private func turnItems() -> [ThemedMenuEntry] {
        GitTurnBaselineStore.shared.checkpoints(forSessionID: sessionID).reversed().map { checkpoint in
            .item(ThemedMenuItem(
                title: L10n.format("Turn %lld", Int64(checkpoint.ordinal)),
                subtitle: turnSubtitle(checkpoint),
                representedValue: checkpoint.id.uuidString,
                isSelected: checkpoint.id == selectedTurnID
            ))
        }
    }

    private func turnSubtitle(_ checkpoint: GitTurnCheckpoint) -> String {
        switch checkpoint.status {
        case .complete:
            return L10n.string("Turn Start → Turn End")
        case .inProgress, .capturingAfter:
            return L10n.string("Turn Start → Working Tree")
        case .capturingBefore:
            return L10n.string("Capturing turn start…")
        case .beforeCaptureFailed, .finalCaptureFailed, .incomplete:
            return checkpoint.failureDescription ?? L10n.string("Checkpoint incomplete")
        case .notAdmitted:
            return L10n.string("Turn not admitted")
        }
    }

    /// Switches the comparison from outside — the changed-files card's View diff lands on the
    /// Last Turn scope through here. Same path as the chip, so persistence and the reader's
    /// place follow the same rules.
    func show(mode: GitReviewMode, checkpointID: GitTurnCheckpointID? = nil) {
        // Touching `view` is the macOS-13-compatible `loadViewIfNeeded()`; the mode chip must
        // exist before the switch renames it.
        _ = view
        if mode == .lastTurn, let checkpointID {
            selectedTurnID = checkpointID
        }
        if mode == self.mode {
            if mode == .lastTurn, checkpointID != nil {
                expansionOverrides.removeAll()
                bulkExpansionOverride = nil
                refreshModePresentation()
                refresh(force: true)
            }
            return
        }
        switchMode(to: mode)
    }

    /// Activity changes can rename Last Turn without changing its persisted mode or forcing a
    /// git read. The dropdown receives the same live wording the next time it opens.
    func refreshModePresentation() {
        guard isViewLoaded else { return }
        modeChip.configure(symbolName: GitReviewUIDefaults.modeSymbol, title: modeTitle)
        if mode == .lastTurn,
           let checkpointID = selectedTurnID,
           let checkpoint = GitTurnBaselineStore.shared.checkpoint(id: checkpointID) {
            turnChip.configure(
                symbolName: GitReviewUIDefaults.turnSymbol,
                title: L10n.format("Turn %lld", Int64(checkpoint.ordinal))
            )
            turnChip.isHidden = false
        } else {
            turnChip.isHidden = true
        }
    }

    private func switchMode(to newMode: GitReviewMode) {
        guard newMode != mode else { return }
        mode = newMode
        // What was opened by hand described the old comparison; the same path in a new mode is
        // a different diff.
        expansionOverrides.removeAll()
        refreshModePresentation()
        onModeChange?()
        refresh(force: true)
    }

    private func selectTurn(_ checkpointID: GitTurnCheckpointID) {
        guard checkpointID != selectedTurnID,
              GitTurnBaselineStore.shared.checkpoint(id: checkpointID)?.sessionID == sessionID else {
            return
        }
        selectedTurnID = checkpointID
        expansionOverrides.removeAll()
        bulkExpansionOverride = nil
        refreshModePresentation()
        refresh(force: true)
    }

    // MARK: - Actions

    @objc func loadMoreCommits() {
        guard let root = repositoryRoot, !isLoading else { return }
        loadCommitList(in: root, skip: commits.count)
    }

    @objc private func backToCommits() {
        show(.commits(canLoadMore: lastPageWasFull))
    }
}

// MARK: - Window Awareness

/// Reports when it lands in, or leaves, a window. The display pane parents a live tab's *view*
/// without adopting its controller, so `viewDidAppear` never fires for one — this is the signal
/// that stands in for it.
// MARK: - Defaults

enum GitReviewUIDefaults {
    /// The chip's mark for every mode: the change itself, not any one comparison.
    static let modeSymbol = "plus.forwardslash.minus"
    static let turnSymbol = "clock.arrow.circlepath"

    static var commitPlaceholder: String { L10n.string("Commit staged changes…") }

    /// Delimits the patch in the copied `git apply` heredoc. Distinctive enough that a diff
    /// containing the word cannot close it early.
    static let patchHeredocDelimiter = "THREADING_PATCH_EOF"

    /// The `···` dropdown's floor, so a diff-less menu (one Refresh row) still reads as the
    /// same control as the full one.
    static let overflowMenuWidth: CGFloat = 190
}
