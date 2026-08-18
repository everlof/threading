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
    private(set) var reviewTextSize = GitReviewTextSizePreference.current

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
    lazy var counterLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()
    private(set) lazy var decreaseTextSizeButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "textformat.size.smaller",
            accessibility: L10n.string("Decrease diff text size"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Decrease diff text size")
        button.setAccessibilityIdentifier("git-review.text-size.decrease")
        button.onPress = { [weak self] in self?.stepReviewTextSize(by: -1) }
        return button
    }()
    private(set) lazy var increaseTextSizeButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "textformat.size.larger",
            accessibility: L10n.string("Increase diff text size"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Increase diff text size")
        button.setAccessibilityIdentifier("git-review.text-size.increase")
        button.onPress = { [weak self] in self?.stepReviewTextSize(by: 1) }
        return button
    }()
    private(set) lazy var jumpToFileButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "doc.text.magnifyingglass",
            accessibility: L10n.string("Jump to file"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Jump to file (⌘J)")
        button.setAccessibilityIdentifier("git-review.jump-to-file")
        button.onPress = { [weak self] in self?.showJumpToFile() }
        return button
    }()
    private(set) lazy var fileNavigatorButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "sidebar.right",
            accessibility: L10n.string("Show changed files"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Show changed files")
        button.setAccessibilityIdentifier("git-review.file-navigator")
        button.onPress = { [weak self] in self?.toggleFileNavigator() }
        return button
    }()
    private(set) lazy var diffLayoutButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "rectangle",
            accessibility: L10n.string("Switch to split diff"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Switch to split diff")
        button.setAccessibilityIdentifier("git-review.diff-layout")
        button.onPress = { [weak self] in self?.toggleDiffLayout() }
        return button
    }()
    private(set) lazy var menuButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: L10n.string("Diff options"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Diff options")
        button.presentsMenu = true
        button.onPress = { [weak self, weak button] in
            guard let button else { return }
            self?.showOverflowMenu(button)
        }
        return button
    }()
    private lazy var navigationButtonGroup = ControlButtonGroupView(buttons: [
        jumpToFileButton,
        diffLayoutButton,
        fileNavigatorButton
    ])
    private lazy var textSizeButtonGroup = ControlButtonGroupView(buttons: [
        decreaseTextSizeButton,
        increaseTextSizeButton
    ])
    private lazy var headerRow = ControlRowView(
        scale: .compact,
        leading: [backButton, modeChip, turnChip, counterLabel],
        trailing: [
            navigationButtonGroup,
            textSizeButtonGroup,
            menuButton
        ]
    )
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
    /// Commit history has the same scaling boundary as a file index: paging bounds each read,
    /// but "Show more" can retain arbitrarily many model rows. A table keeps construction and
    /// drawing proportional to the viewport instead of mounting every rich graph row in `stack`.
    lazy var historyTableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(identifier: GitReviewUIDefaults.historyTableColumnIdentifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = GitReviewCommitRowDefaults.tableRowHeight
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
    private let stickyFileHeaderHost: GitReviewStickyHeaderHost = {
        let host = GitReviewStickyHeaderHost()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        return host
    }()
    private let stickyFileHeaderViewport = GitReviewStickyHeaderViewport()
    private lazy var stickyFileHeaderTop = stickyFileHeaderHost.topAnchor.constraint(
        equalTo: stickyFileHeaderViewport.topAnchor
    )
    private lazy var stickyFileHeaderHeight: NSLayoutConstraint = {
        let height = stickyFileHeaderHost.heightAnchor.constraint(equalToConstant: 0)
        return height
    }()
    private var stickyFileHeaderSignature: String?
    private lazy var fileNavigatorController: GitReviewPathNavigatorViewController = {
        let controller = GitReviewPathNavigatorViewController(
            rootURL: URL(fileURLWithPath: folderPath)
        )
        controller.onChoosePath = { [weak self] path in self?.jumpToFile(path) }
        return controller
    }()
    private let fileNavigatorHost: ThemedSurfaceView = {
        let host = ThemedSurfaceView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        host.applySurface(fill: Design.Surface.panel, radius: .fixed(0))
        return host
    }()
    private lazy var fileNavigatorWidth = fileNavigatorHost.widthAnchor.constraint(
        equalToConstant: 0
    )
    private var showsFileNavigator = false
    private var jumpToFilePopover: ThemedPopover?
    private(set) var stickyFileHeaderPathForTesting: String?

    var fileNavigatorVisibleForTesting: Bool { showsFileNavigator }
    var fileNavigatorWidthForTesting: CGFloat { fileNavigatorWidth.constant }
    var stickyFileHeaderHeightForTesting: CGFloat { stickyFileHeaderHeight.constant }
    var stickyFileHeaderTopForTesting: CGFloat { stickyFileHeaderTop.constant }
    var stickyFileHeaderFrameInViewForTesting: NSRect {
        stickyFileHeaderHost.convert(stickyFileHeaderHost.bounds, to: view)
    }
    var stickyFileHeaderRowForTesting: GitReviewFileRow? {
        stickyFileHeaderHost.installedHeader
    }
    lazy var findBar = BrowserFindBar(
        placeholder: L10n.string("Find in diff"),
        closeAccessibility: L10n.string("Close Find in Diff")
    )
    let findBarSeparator = SeparatorView()
    lazy var findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
    lazy var findBarSeparatorHeight = findBarSeparator.heightAnchor.constraint(equalToConstant: 0)

    /// Find retains at most one immutable full comparison while its bar is open. Exact file
    /// phases already own that value; a progressive index earns the extra bounded read only
    /// after the user types a query.
    var findSnapshot: [GitFileDiff]?
    var findSnapshotCancellation: GitProcessCancellation?
    var findSearchTask: Task<Void, Never>?
    var findSourceGeneration = 0
    var findQuery = ""
    var findMatches: [GitReviewFindMatch] = []
    var findMatchIndex: Int?
    var findResultsAreTruncated = false
    var findPendingBackwards = false
    var isFindBarVisible = false
    private let scrollEvents = AppEventObservations()
    private let appEvents = AppEventObservations()

    /// What the body is currently showing. Commit mode is two phases deep: the history list,
    /// and one commit opened out of it.
    enum Phase {
        case message(String)
        /// Stable file identities whose exact bodies are hydrated only around the viewport.
        case fileIndex([GitFileDiff])
        case files([GitFileDiff])
        case commits(canLoadMore: Bool)
        case commitDetail(GitCommitSummary, [GitFileDiff])
    }

    var phase: Phase = .message("")

    /// The history list survives opening a commit, so Back is free.
    var commits: [GitCommitSummary] = []
    var lastPageWasFull = false
    private var pendingCommitStatsPages: Set<Int> = []

    /// Stale async results are dropped by generation. The one deliberately cancellable read is
    /// a complete patch superseded by the large comparison's compact path roster.
    var generation = 0
    /// Lets a racing raw-index callback know the full patch has already won this generation.
    private var completedDiffGeneration = -1
    var activeDiffCancellation: GitProcessCancellation?
    /// A large comparison retains one value roster and hydrates only the resting viewport.
    /// These values are generation-scoped; no callback may update a later comparison.
    var progressiveDiffGeneration = -1
    var progressiveDiff: GitReviewReader.ProgressiveDiff?
    var progressiveDiffRoot: URL?
    var progressiveHydrationInFlight = false
    var progressiveHydrationSchedule = 0
    var progressiveStatsStarted = false
    var progressiveStatsScheduled = false
    var progressiveStatsCancellation: GitProcessCancellation?
    var isLoading = false {
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
    var collapsedHunksByPath: [String: Set<GitReviewHunkIdentity>] = [:]
    var contextLinesByPath: [String: Int] = [:]
    var contextExpansionInFlightPaths: Set<String> = []
    var contextExpansionExhaustedPaths: Set<String> = []
    /// A context read may finish after the reader has started a trackpad or scroller-thumb
    /// gesture. Keep its one-row geometry replacement out of that transaction, just like a
    /// watched checkout refresh; the durable source-line anchor is resolved when scrolling ends.
    var deferredContextExpansionReloads: [String: GitReviewSourceLineAnchor?] = [:]

    /// File comparisons use a reusable table. `NSStackView` eagerly solves constraints for
    /// every arranged child, which made both the original eager list and progressively appended
    /// deep indexes superlinear. The table owns all model rows while creating views only around
    /// the viewport.
    var renderedFiles: [GitFileDiff] = []

    /// What the turn being shown can say about who wrote each file, or nil where no row may be
    /// marked at all — every mode but a turn checkpoint, and an uncontested turn. Resolved once
    /// per load rather than per row, because both halves of it scan the checkpoint archive.
    var turnAttribution: TurnAttribution?
    var pendingDiffIndexPaths: Set<String> = []
    var failedDiffHydrationPaths: Set<String> = []
    var deferredHydratedFiles: [String: GitFileDiff] = [:]
    var deferredFailedHydrationPaths: Set<String> = []
    var deferredProgressiveStats: [GitFileLineStats]?
    var filePreludeViews: [NSView] = []
    var renderedFileRoot: URL?
    var instantiatedFileRowCount = 0
    var instantiatedDeferredFileRowCount = 0
    var measuredFileRowHeights: [String: (width: CGFloat, height: CGFloat)] = [:]
    var measuredPreludeRowHeights: [Int: (width: CGFloat, height: CGFloat)] = [:]
    var fileRowHeightWidth: CGFloat = 0

    /// The graph is value geometry and is cheap to retain for the complete loaded history.
    /// `historyTableView` asks for the corresponding rich row only when it reaches the viewport.
    var renderedCommitGraph: [GitGraphRow] = []
    var historyPreludeViews: [NSView] = []
    var measuredHistoryPreludeRowHeights: [Int: CGFloat] = [:]
    var renderedCommitLaneCount = 1
    var historyCanLoadMore = false
    var instantiatedCommitRowCount = 0

    /// Whether a long line wraps to the pane or runs off it into a horizontal scroller. Wrapping
    /// is the default because the pane is often narrow, and hiding half a changed line off the
    /// right edge is worse — but a wide window reading long lines wants the other trade.
    var wrapsDiffLines = true
    var diffLayout: GitReviewDiffLayout = .unified
    var showsRichPreviews = true
    var showsWordDiffs = false
    var loadsFullFiles = false
    var diffContextLines: Int {
        loadsFullFiles
            ? GitReviewDefaults.maximumExpandedContextLines
            : GitReviewDefaults.contextLines
    }

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
    var pendingReviewTextSizeRefresh = false

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
            guard let self else { return }
            if window == nil {
                self.stopWatching()
            } else {
                self.startWatching()
                self.applyPendingReviewTextSizeIfNeeded()
            }
        }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupBody()
        setupConstraints()
        updateReviewTextSizeButtons()

        // The pane's counters and file headers are *built* attributed strings — `+362 −26` is
        // one string carrying two colours — so their font and their ink both freeze at build
        // time, where a plain label's would be re-resolved by the theme sweep. Re-reading is
        // the honest rebuild: this pane already keeps the reader's scroll offset and whatever
        // was expanded by hand across a reload, so a theme switch costs a git read and nothing
        // the user can see move.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyFindBarRuleWeight()
            self?.refresh(force: true)
        }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyFindBarRuleWeight()
        }
        appEvents.observe(GitReviewTextSizeDidChange.self) { [weak self] event in
            self?.receiveReviewTextSize(event.size)
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

        // The clip is the pane width the eye already sees. `NSClipView` normally propagates that
        // width to its autoresizing document during the same layout traversal, but a nested split
        // animation can leave the table on the preceding frame until the next traversal. That is
        // cheap in a timing profile and visibly wrong beside a divider that has already moved.
        // State the current width synchronously; `ThemedTableView.setFrameSize` also fits its sole
        // column, so the row host receives the same geometry before this frame is displayed.
        let viewportWidth = scrollView.contentView.bounds.width
        if viewportWidth > 1, abs(fileTableView.bounds.width - viewportWidth) > 0.5 {
            fileTableView.setFrameSize(NSSize(
                width: viewportWidth,
                height: fileTableView.frame.height
            ))
        }

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

        // `noteHeightOfRows` changes the virtual table's geometry after the ordinary descendant
        // layout pass has finished. Settle only the mounted viewport now so its cards and TextKit
        // containers advance with the divider; offscreen rows remain estimates and own no views.
        // Suppress an inherited split-view animation here: the outer pane may animate, but each
        // inner width must describe its current frame instead of beginning a second, trailing one.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.immediate
            context.allowsImplicitAnimation = false
            fileTableView.layoutSubtreeIfNeeded()
        }
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
        activeDiffCancellation?.cancel()
        progressiveStatsCancellation?.cancel()
        findSnapshotCancellation?.cancel()
        findSearchTask?.cancel()
    }

    // MARK: - Setup

    private func setupHeader() {
        // One overflow rather than a row of icons: refreshing, collapsing, wrapping and the
        // whitespace fold are all things asked of the diff occasionally, and a header of five
        // glyphs would compete with the mode chip, which is the control that matters here.
        // `ControlRowView` owns the theme-authored height, hidden Back detachment, the spring
        // between the counter and actions, and optical alignment at both content edges.
        view.addSubview(headerRow)
    }

    private func setupBody() {
        clipView.drawsBackground = false
        clipView.postsBoundsChangedNotifications = true
        scrollEvents.observe(NSView.boundsDidChangeNotification, object: clipView) { [weak self] in
            self?.updateScrollControls()
            self?.scheduleVisibleDiffHydration(
                after: GitReviewDefaults.progressiveDiffHydrationSettleDelay
            )
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
        view.addSubview(fileNavigatorHost)
        addChild(fileNavigatorController)
        let navigatorView = fileNavigatorController.view
        navigatorView.translatesAutoresizingMaskIntoConstraints = false
        fileNavigatorHost.addSubview(navigatorView)
        let navigatorRule = SeparatorView()
        navigatorRule.translatesAutoresizingMaskIntoConstraints = false
        fileNavigatorHost.addSubview(navigatorRule)
        let navigatorTrailing = navigatorView.trailingAnchor.constraint(
            equalTo: fileNavigatorHost.trailingAnchor
        )
        // The rail collapses to zero width. Its hidden child may keep the minimum width implied
        // by the search field without asking AppKit to break required constraints; once the rail
        // opens to 260pt this edge becomes satisfiable and closes normally.
        navigatorTrailing.priority = .init(999)
        NSLayoutConstraint.activate([
            navigatorRule.topAnchor.constraint(equalTo: fileNavigatorHost.topAnchor),
            navigatorRule.bottomAnchor.constraint(equalTo: fileNavigatorHost.bottomAnchor),
            navigatorRule.leadingAnchor.constraint(equalTo: fileNavigatorHost.leadingAnchor),
            navigatorRule.widthAnchor.constraint(equalToConstant: Design.Radius.border),
            navigatorView.topAnchor.constraint(equalTo: fileNavigatorHost.topAnchor),
            navigatorView.bottomAnchor.constraint(equalTo: fileNavigatorHost.bottomAnchor),
            navigatorView.leadingAnchor.constraint(equalTo: navigatorRule.trailingAnchor),
            navigatorTrailing
        ])
        view.addSubview(changeRequestBar)
        findBar.onFind = { [weak self] query, backwards in
            self?.find(query, backwards: backwards)
        }
        findBar.onDismiss = { [weak self] in self?.hideFind() }
        findBar.setAccessibilityIdentifier("git-review.find-bar")
        findBar.isHidden = true
        findBarSeparator.isHidden = true
        view.addSubview(findBar)
        view.addSubview(findBarSeparator)
        view.addSubview(placeholderLabel)
        view.addSubview(stickyFileHeaderViewport)
        stickyFileHeaderViewport.addSubview(stickyFileHeaderHost)
        view.addSubview(jumpToEndButton)
    }

    /// Hidden members are detached by `ControlRowView`, so the chip becomes the leading edge.
    func setBackVisible(_ visible: Bool) {
        backButton.isHidden = !visible
    }

    private func receiveReviewTextSize(_ size: Design.CodeTextScale) {
        reviewTextSize = size
        updateReviewTextSizeButtons()

        switch phase {
        case .fileIndex, .files, .commitDetail:
            guard view.window != nil,
                  !view.isHiddenOrHasHiddenAncestor,
                  !isFileLiveScrolling else {
                pendingReviewTextSizeRefresh = true
                return
            }
            rebuildForReviewTextSize()
        case .message, .commits:
            pendingReviewTextSizeRefresh = false
        }
    }

    private func updateReviewTextSizeButtons() {
        let sizes = Design.CodeTextScale.allCases
        decreaseTextSizeButton.isEnabled = reviewTextSize != sizes.first
        increaseTextSizeButton.isEnabled = reviewTextSize != sizes.last
    }

    /// Called after momentum ends and when a retained Review tab reaches a window again.
    func applyPendingReviewTextSizeIfNeeded() {
        guard pendingReviewTextSizeRefresh, !isFileLiveScrolling else { return }
        rebuildForReviewTextSize()
    }

    private func rebuildForReviewTextSize() {
        pendingReviewTextSizeRefresh = false
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        measuredPreludeRowHeights.removeAll(keepingCapacity: true)
        fileRowHeightWidth = 0
        show(phase, forceRebuild: true)
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top would slide
            // the header under it. One margin on all four sides: the row starts and ends where
            // the file cards do, sits `inset` below the tab strip and leaves `inset` above the
            // first card, so the header reads as the top of the list rather than as chrome
            // floating over it.
            headerRow.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: inset
            ),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            findBar.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: inset),
            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findBarHeight,

            findBarSeparator.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            findBarSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBarSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findBarSeparatorHeight,

            changeRequestBar.topAnchor.constraint(equalTo: findBarSeparator.bottomAnchor),
            changeRequestBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            changeRequestBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            changeRequestBarHeight,

            scrollViewTop,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: fileNavigatorHost.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            fileNavigatorHost.topAnchor.constraint(equalTo: scrollView.topAnchor),
            fileNavigatorHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fileNavigatorHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fileNavigatorWidth,

            // Rows wrap to the pane's width instead of scrolling sideways.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: inset),

            jumpToEndButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpToEndButton.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Design.Spacing.inset
            ),

            stickyFileHeaderViewport.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stickyFileHeaderViewport.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor,
                constant: inset
            ),
            stickyFileHeaderViewport.trailingAnchor.constraint(
                equalTo: scrollView.trailingAnchor,
                constant: -inset
            ),
            stickyFileHeaderViewport.heightAnchor.constraint(
                equalTo: stickyFileHeaderHost.heightAnchor
            ),
            stickyFileHeaderTop,
            stickyFileHeaderHost.leadingAnchor.constraint(
                equalTo: stickyFileHeaderViewport.leadingAnchor
            ),
            stickyFileHeaderHost.trailingAnchor.constraint(
                equalTo: stickyFileHeaderViewport.trailingAnchor
            ),
            stickyFileHeaderHeight
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
            if isViewLoaded {
                jumpToEndButton.setFloatingPresence(false)
                hideStickyFileHeader()
            }
            return
        }
        let overflow = maximumScrollOffsetY()
        let distanceFromEnd = overflow - scrollView.contentView.bounds.origin.y
        jumpToEndButton.setFloatingPresence(overflow > 1 && distanceFromEnd > 4)
        updateStickyFileHeader()
    }

    private func updateStickyFileHeader() {
        // A thumb drag can cross dozens of files per frame. Its lightweight table rows preserve
        // geometry until the pointer rests; let the sticky header follow the same rule and
        // materialize the settled file once instead of formatting transient destinations.
        guard !isFileScrollerSeeking else {
            hideStickyFileHeader()
            return
        }
        let visibleY = scrollView.documentVisibleRect.minY
        let tableRow = fileTableView.row(at: NSPoint(x: 1, y: visibleY + 1))
        guard tableRow >= filePreludeViews.count,
              tableRow < filePreludeViews.count + renderedFiles.count else {
            hideStickyFileHeader()
            return
        }

        let rowRect = fileTableView.rect(ofRow: tableRow)
        guard visibleY > rowRect.minY + 1 else {
            hideStickyFileHeader()
            return
        }

        let file = renderedFiles[tableRow - filePreludeViews.count]
        let isPending = pendingDiffIndexPaths.contains(file.path)
        let didFail = failedDiffHydrationPaths.contains(file.path)
        let attribution = turnAttribution?.mark(for: file.path) ?? .none
        // Expansion does not change a file heading. Keeping it out of the signature preserves
        // the retained header and any pointer press while the real row changes its body height.
        let signature = "\(file.path)\u{0}\(file.change)\u{0}\(file.added)\u{0}\(file.removed)"
            + "\u{0}\(isPending)\u{0}\(didFail)\u{0}\(mode)\u{0}\(attribution)"
            + "\u{0}\(renderedFileRoot?.path ?? "")"
        if signature != stickyFileHeaderSignature {
            let header = GitReviewFileRow(
                file: file,
                expanded: false,
                contentIsPending: isPending,
                contentLoadFailed: didFail,
                attribution: attribution,
                staging: isPending ? nil : staging,
                fileURL: renderedFileRoot?.appendingPathComponent(file.path),
                headerOnly: true
            )
            header.onStageFile = { [weak self] in self?.stageFile(file) }
            // Measure the real header, not the host whose active bootstrap height is zero. The
            // old measurement therefore returned zero and left a one-point "sticky" strip.
            // Adopt that height before installing the row, or Auto Layout briefly tries to pin
            // a complete heading into the bootstrap's zero-height host.
            stickyFileHeaderHeight.constant = max(header.fittingSize.height, 1)
            stickyFileHeaderHost.install(header)
            stickyFileHeaderSignature = signature
        }

        let distanceToNextFile = rowRect.maxY - visibleY
        // The real cards keep `Spacing.small` between their silhouettes. The retained heading
        // lives above the table, so without carrying that same gap into the push calculation it
        // touches — and, by z-order, appears to cover — the incoming real heading. Start moving
        // one card gap earlier and preserve that air throughout the transition.
        positionStickyFileHeader(at: min(
            0,
            distanceToNextFile
                - stickyFileHeaderHeight.constant
                - Design.Spacing.small
        ))
        stickyFileHeaderHost.isHidden = false
        stickyFileHeaderPathForTesting = file.path
    }

    private func hideStickyFileHeader() {
        stickyFileHeaderHost.isHidden = true
        positionStickyFileHeader(at: 0)
        stickyFileHeaderPathForTesting = nil
    }

    /// Scroll bounds move immediately, while a constraint edit may wait for the window's next
    /// layout pass. Move this one retained view by the same delta now so the old header cannot
    /// spend a frame painted over the incoming real one. Asking the root view to lay out here
    /// would also settle the virtual table on every wheel event; this O(1) frame update is adopted
    /// by the already-updated constraint at the next ordinary pass.
    private func positionStickyFileHeader(at visualTopOffset: CGFloat) {
        let previousOffset = stickyFileHeaderTop.constant
        guard abs(visualTopOffset - previousOffset) > 0.01 else { return }
        stickyFileHeaderTop.constant = visualTopOffset

        guard let superview = stickyFileHeaderHost.superview,
              stickyFileHeaderHost.frame.height > 0 else { return }
        var origin = stickyFileHeaderHost.frame.origin
        let delta = visualTopOffset - previousOffset
        origin.y += superview.isFlipped ? delta : -delta
        stickyFileHeaderHost.setFrameOrigin(origin)
    }

    func syncFileNavigator(with files: [GitFileDiff]) {
        guard showsFileNavigator else { return }
        fileNavigatorController.update(files: files)
    }

    var canJumpToFile: Bool {
        scrollView.documentView === fileTableView && !renderedFiles.isEmpty
    }

    func showJumpToFile() {
        guard canJumpToFile else { return }
        jumpToFilePopover?.close()

        let navigator = GitReviewPathNavigatorViewController(
            rootURL: renderedFileRoot ?? URL(fileURLWithPath: folderPath)
        )
        navigator.preferredContentSize = NSSize(width: 520, height: 340)
        let popover = ThemedPopover()
        popover.behavior = .transient
        navigator.onChoosePath = { [weak self, weak popover] path in
            popover?.close()
            self?.jumpToFile(path)
        }
        popover.contentViewController = navigator
        popover.onClose = { [weak self] in self?.jumpToFilePopover = nil }
        // The keyboard belongs to the filter for as long as this is open: the command that
        // raises it is a chord, and a search field it cannot type into is the whole surface
        // failing. `ThemedPopover` makes the panel key only because this is set.
        popover.initialFirstResponder = navigator.searchResponder
        jumpToFilePopover = popover
        navigator.update(files: renderedFiles)
        popover.show(relativeTo: jumpToFileButton.bounds, of: jumpToFileButton, preferredEdge: .maxY)
    }

    private func toggleFileNavigator() {
        showsFileNavigator.toggle()
        fileNavigatorHost.isHidden = !showsFileNavigator
        fileNavigatorWidth.constant = showsFileNavigator ? 260 : 0
        fileNavigatorButton.setSymbol(
            "sidebar.right",
            accessibility: showsFileNavigator
                ? L10n.string("Hide changed files")
                : L10n.string("Show changed files")
        )
        fileNavigatorButton.isSelected = showsFileNavigator
        fileNavigatorButton.toolTip = showsFileNavigator
            ? L10n.string("Hide changed files")
            : L10n.string("Show changed files")
        if showsFileNavigator {
            fileNavigatorController.update(files: renderedFiles)
        }
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        fileRowHeightWidth = 0
        view.needsLayout = true
    }

    private func toggleDiffLayout() {
        diffLayout = diffLayout == .unified ? .split : .unified
        let title = diffLayout == .unified
            ? L10n.string("Switch to split diff")
            : L10n.string("Switch to unified diff")
        diffLayoutButton.setSymbol(
            diffLayout == .unified ? "rectangle" : "rectangle.split.2x1",
            accessibility: title
        )
        diffLayoutButton.isSelected = diffLayout == .split
        diffLayoutButton.toolTip = title
        measuredFileRowHeights.removeAll(keepingCapacity: true)
        fileRowHeightWidth = 0
        show(phase, forceRebuild: true)
    }

    func jumpToFile(_ path: String) {
        guard let fileIndex = renderedFiles.firstIndex(where: { $0.path == path }) else { return }
        let tableRow = filePreludeViews.count + fileIndex
        guard tableRow < fileTableView.numberOfRows else { return }
        view.layoutSubtreeIfNeeded()
        let targetY = min(fileTableView.rect(ofRow: tableRow).minY, maximumScrollOffsetY())
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(targetY, 0)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateScrollControls()
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

        // Every load decides attribution marking again from scratch; only the turn branch below
        // can turn it back on.
        turnAttribution = nil

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
            // Nil keeps every row exactly as it renders on an uncontested turn; the rule itself
            // lives beside the fields it reads.
            turnAttribution = TurnAttribution(
                checkpoint: checkpoint,
                claimedByOtherChats: GitTurnBaselineStore.shared.otherChatsClaimedPaths(
                    overlapping: checkpoint
                )
            )
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
    func reloadIfPending() {
        guard pendingReload, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh(force: true) }
    }

    // MARK: - Loading

    var repositoryRoot: URL? {
        GitInfo.repositoryRoot(for: folderPath)
    }

    private func loadDiff(_ request: GitReviewReader.DiffRequest, in root: URL) {
        activeDiffCancellation?.cancel()
        generation += 1
        let expected = generation
        completedDiffGeneration = -1
        stopProgressiveDiffHydration()
        isLoading = true
        let span = PerformanceRecorder.shared.begin(
            "git.review.load-and-render",
            category: "git.review",
            metadata: ["mode": mode.rawValue]
        )

        if GitReviewReader.supportsProgressiveIndex(request) {
            // Ordinary comparisons normally finish before this fires and pay no second process.
            // Only a load that has already missed the responsiveness budget asks Git for the
            // compact roster it can present while the expensive patch keeps running.
            DispatchQueue.main.asyncAfter(
                deadline: .now() + GitReviewDefaults.progressiveDiffDelay
            ) { [weak self] in
                guard let self,
                      expected == self.generation,
                      self.completedDiffGeneration != expected else { return }
                GitReviewReader.diffIndex(
                    request,
                    in: root,
                    ignoringWhitespace: self.ignoresWhitespace
                ) { [weak self] result in
                    guard let self,
                          expected == self.generation,
                          self.completedDiffGeneration != expected,
                          case .success(let comparison) = result,
                          comparison.files.count >= GitReviewDefaults.progressiveDiffFileThreshold else { return }
                    self.beginProgressiveDiffHydration(
                        comparison: comparison,
                        root: root,
                        generation: expected
                    )
                }
            }
        }

        activeDiffCancellation = GitReviewReader.diff(
            request,
            in: root,
            ignoringWhitespace: ignoresWhitespace,
            contextLines: diffContextLines
        ) { [weak self] result in
            guard let self else {
                span.end(metadata: ["result": "controller-released"])
                return
            }
            guard expected == self.generation else {
                span.end(metadata: ["result": "stale"])
                return
            }
            self.completedDiffGeneration = expected
            self.lastLoadedAt = Date()

            switch result {
            case .success(let files):
                self.stopProgressiveDiffHydration()
                self.loadedDiffRoot = root
                self.show(files.isEmpty ? .message("No changes.") : .files(files))
                span.end(metadata: [
                    "result": "success",
                    "files": String(files.count),
                    "changed_lines": String(files.reduce(0) { $0 + $1.added + $1.removed })
                ])
            case .failure(.cancelled) where self.progressiveDiffGeneration == expected:
                span.end(metadata: ["result": "progressive"])
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? L10n.string("git failed.")))
                span.end(metadata: ["result": "failure"])
            }
            self.activeDiffCancellation = nil
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
                let knownStats = Dictionary(
                    uniqueKeysWithValues: self.commits
                        .filter(\.hasStats)
                        .map { ($0.hash, $0) }
                )
                let presentedPage = page.map { knownStats[$0.hash] ?? $0 }
                if skip == 0 { self.commits = presentedPage } else { self.commits += presentedPage }
                self.lastPageWasFull = page.count == GitReviewDefaults.logPageSize
                self.show(self.commits.isEmpty
                    ? .message("No commits yet.")
                    : .commits(canLoadMore: self.lastPageWasFull))
                span.end(metadata: [
                    "result": "success",
                    "commits": String(self.commits.count)
                ])
                self.loadCommitStats(in: root, skip: skip)
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? L10n.string("git failed.")))
                span.end(metadata: ["result": "failure"])
            }
            self.isLoading = false
            self.reloadIfPending()
        }
    }

    /// Enriches only values already retained by the history table. Fixed row height means this
    /// is a targeted cell reload, not another graph/layout pass, and a commit opened while the
    /// command runs simply receives its stats in the retained Back list.
    private func loadCommitStats(in root: URL, skip: Int) {
        guard pendingCommitStatsPages.insert(skip).inserted else { return }
        let span = PerformanceRecorder.shared.begin(
            "git.review.load-history-stats",
            category: "git.review",
            metadata: ["skip": String(skip)]
        )
        GitReviewReader.logStats(skip: skip, in: root) { [weak self] result in
            guard let self else {
                span.end(metadata: ["result": "controller-released"])
                return
            }
            self.pendingCommitStatsPages.remove(skip)
            switch result {
            case .success(let page):
                let changed = self.applyCommitStats(page)
                span.end(metadata: [
                    "result": "success",
                    "commits": String(page.count),
                    "changed": String(changed)
                ])
            case .failure:
                // Statistics are supplementary: the complete history remains usable, and its
                // next ordinary refresh may retry without replacing it with an error page.
                span.end(metadata: ["result": "failure"])
            }
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
            ignoringWhitespace: ignoresWhitespace,
            contextLines: diffContextLines
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
            return hedgingObservedOverlap(L10n.string("Turn Start → Turn End"), in: checkpoint)
        case .inProgress, .capturingAfter:
            return hedgingObservedOverlap(L10n.string("Turn Start → Working Tree"), in: checkpoint)
        case .capturingBefore:
            return L10n.string("Capturing turn start…")
        case .beforeCaptureFailed, .finalCaptureFailed, .incomplete:
            return checkpoint.failureDescription ?? L10n.string("Checkpoint incomplete")
        case .notAdmitted:
            return L10n.string("Turn not admitted")
        }
    }

    /// The checkpoint recorded another chat working in this checkout while the turn was open, so
    /// its two trees can hold that chat's edits as well. The comparison stays exactly what was
    /// captured; the subtitle is where that uncertainty is allowed to show.
    private func hedgingObservedOverlap(
        _ subtitle: String,
        in checkpoint: GitTurnCheckpoint
    ) -> String {
        let others = checkpoint.overlappingSessionIDs?.count ?? 0
        guard others > 0 else { return subtitle }
        let note = others == 1
            ? L10n.string("may include changes from 1 other chat")
            : L10n.format("may include changes from %lld other chats", Int64(others))
        return subtitle + GitReviewUIDefaults.subtitleSeparator + note
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
                resetContextExpansion()
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
        resetContextExpansion()
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
        resetContextExpansion()
        refreshModePresentation()
        refresh(force: true)
    }

    private func resetContextExpansion() {
        collapsedHunksByPath.removeAll(keepingCapacity: false)
        contextLinesByPath.removeAll(keepingCapacity: false)
        contextExpansionInFlightPaths.removeAll(keepingCapacity: false)
        contextExpansionExhaustedPaths.removeAll(keepingCapacity: false)
        deferredContextExpansionReloads.removeAll(keepingCapacity: false)
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

// MARK: - Sticky File Header

/// The retained heading belongs to the scroll viewport, even though it cannot live inside the
/// scrolling document. This transparent structural host makes that ownership literal: when the
/// next file pushes the retained row upward, no pixel can escape into Review's toolbar above.
final class GitReviewStickyHeaderViewport: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only a control returned by the retained header owns a press. The transparent remainder of
    /// this clip forwards wheel and pointer traffic to the scroll view below it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Keeps one real file-header row above the scrolling document. Reusing `GitReviewFileRow` is
/// deliberate: the retained heading must have the same geometry, hover actions, staging action,
/// theme response and accessibility controls as the row it stands in for.
final class GitReviewStickyHeaderHost: NSView {
    private(set) weak var installedHeader: GitReviewFileRow?

    /// The sticky heading is an overlay above semantic red/green diff washes. A rounded layer
    /// alone has transparent corner pixels, so those washes show through its top arc. This
    /// square source-background surface occludes the scrolling document before the rounded
    /// heading is composited over it. The outer pane ground is intentionally not used: in a theme
    /// whose source surface is navy, it would replace the diff ink with a hard-black corner wedge.
    let occlusionSurface: ThemedSurfaceView = {
        let surface = ThemedSurfaceView()
        surface.applySurface(
            fill: Design.Surface.background,
            radius: .fixed(0),
            bevel: .none
        )
        return surface
    }()

    /// The visible retained-card silhouette. Its lower corners stay square because the file's
    /// content continues below this heading; only the exposed top corners turn.
    let headingSurface: ThemedSurfaceView = {
        let surface = ThemedSurfaceView()
        surface.applySurface(
            fill: Design.Surface.elevated,
            radius: .control,
            corners: .top,
            clipsContent: true
        )
        return surface
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [occlusionSurface, headingSurface].forEach(addSubview)
        NSLayoutConstraint.activate([
            occlusionSurface.topAnchor.constraint(equalTo: topAnchor),
            occlusionSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            occlusionSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            occlusionSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
            headingSurface.topAnchor.constraint(equalTo: topAnchor),
            headingSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            headingSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            headingSurface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func install(_ header: GitReviewFileRow) {
        headingSurface.subviews.forEach { $0.removeFromSuperview() }
        installedHeader = header
        header.translatesAutoresizingMaskIntoConstraints = false
        headingSurface.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headingSurface.topAnchor),
            header.leadingAnchor.constraint(equalTo: headingSurface.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headingSurface.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: headingSurface.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The header's ground remains transparent to pointer routing so trackpad and wheel scrolling
    /// continue in the document beneath it. Its controls are the exception: a visible Copy,
    /// Finder or staging button owns its press instead of becoming decorative chrome.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is ThemedControl { return hit }
            candidate = view.superview
        }
        return nil
    }
}

// MARK: - Defaults

enum GitReviewUIDefaults {
    /// The chip's mark for every mode: the change itself, not any one comparison.
    static let modeSymbol = "plus.forwardslash.minus"
    static let turnSymbol = "clock.arrow.circlepath"
    static let historyTableColumnIdentifier = NSUserInterfaceItemIdentifier("GitReviewCommit")

    static var commitPlaceholder: String { L10n.string("Commit staged changes…") }

    /// Joins secondary text — a menu subtitle, a file row's trailing summary — to a qualifier
    /// about the same comparison.
    static let subtitleSeparator = " · "

    /// Delimits the patch in the copied `git apply` heredoc. Distinctive enough that a diff
    /// containing the word cannot close it early.
    static let patchHeredocDelimiter = "THREADING_PATCH_EOF"

    /// The `···` dropdown's floor, so a diff-less menu (one Refresh row) still reads as the
    /// same control as the full one.
    static let overflowMenuWidth: CGFloat = 190
}
