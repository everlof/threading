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
    private let folderPath: String

    private(set) var mode: GitReviewMode

    /// Called when the user picks a different mode, so the pane can persist the tab with it.
    var onModeChange: (() -> Void)?

    var modeChip: ChipView!
    var backButton: NSButton!
    var counterLabel: NSTextField!
    private var refreshButton: NSButton!
    var scrollView: NSScrollView!
    var stack: NSStackView!
    var placeholderLabel: NSTextField!

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
    private var isLoading = false
    private var lastLoadedAt: Date?

    /// The mode the body on screen was drawn for, so a reload of the same surface can keep the
    /// reader's place while a mode switch starts at the top.
    var renderedMode: GitReviewMode?

    /// Which files the user has opened or closed by hand. Consulted ahead of the auto-expand
    /// heuristic, so a watched checkout re-reading itself does not close what is being read.
    var expansionOverrides: [String: Bool] = [:]

    /// The checkout changed while a load was in flight or the pane was off screen; the next
    /// opportunity re-reads regardless of the debounce.
    private var pendingReload = false

    private var watcher: GitCheckoutWatcher?

    /// The commit message being written, kept here rather than in the composer: the composer
    /// is rebuilt every time the pane re-reads, which staging makes happen constantly.
    var commitMessage = ""
    weak var commitComposer: PromptView?

    /// What the last write said, shown once above the diff. Cleared by the render that shows
    /// it, so it never outlives the thing it is about.
    var notice: (text: String, isError: Bool)?

    // MARK: - Initialization

    init(sessionID: SessionID, folderPath: String, mode: GitReviewMode) {
        self.sessionID = sessionID
        self.folderPath = folderPath
        self.mode = mode
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
    }

    deinit {
        watcher?.stop()
    }

    // MARK: - Setup

    private func setupHeader() {
        backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self,
            action: #selector(backToCommits)
        )
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.toolTip = "Back to history"
        backButton.isHidden = true

        modeChip = ChipView()
        modeChip.configure(symbolName: GitReviewUIDefaults.modeSymbol, title: mode.title)
        modeChip.menuProvider = { [weak self] in self?.modeMenu() ?? NSMenu() }
        modeChip.onSelect = { [weak self] item in
            guard let raw = item.representedObject as? String,
                  let mode = GitReviewMode(rawValue: raw) else { return }
            self?.switchMode(to: mode)
        }

        counterLabel = NSTextField(labelWithString: "")
        counterLabel.font = Design.Typography.caption()
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)

        refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshTapped)
        )
        refreshButton.bezelStyle = .accessoryBarAction
        refreshButton.isBordered = false
        refreshButton.toolTip = "Refresh"

        [backButton, modeChip, counterLabel, refreshButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }

    private func setupBody() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        let clipView = FlippedClipView()
        clipView.drawsBackground = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clipView
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholderLabel = NSTextField(labelWithString: "")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Design.Typography.body()
        placeholderLabel.textColor = Design.Text.tertiary
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0

        view.addSubview(scrollView)
        view.addSubview(placeholderLabel)
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top would slide
            // the header under it.
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.small),
            backButton.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),

            modeChip.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            modeChip.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: Design.Spacing.tight),

            counterLabel.leadingAnchor.constraint(equalTo: modeChip.trailingAnchor, constant: Design.Spacing.medium),
            counterLabel.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),
            counterLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),

            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            refreshButton.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: modeChip.bottomAnchor, constant: Design.Spacing.small),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Rows wrap to the pane's width instead of scrolling sideways.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: inset)
        ])
    }

    // MARK: - Public Methods

    /// Reloads the current mode. Non-forced calls debounce and yield to a load in flight —
    /// they arrive from tab switches and activity edges, which cluster.
    func refresh(force: Bool) {
        if !isViewLoaded { loadView() }

        // A change the pane could not act on when it arrived is not stale — it is the reason
        // this refresh exists, so it outranks the debounce.
        let force = force || pendingReload
        pendingReload = false

        if !force {
            if isLoading { return }
            if let last = lastLoadedAt,
               Date().timeIntervalSince(last) < GitReviewDefaults.refreshDebounce { return }
        }

        guard let root = repositoryRoot else {
            show(.message("Not a git repository."))
            return
        }

        switch mode {
        case .commit:
            loadCommitList(in: root, skip: 0)

        case .lastTurn:
            guard let baseline = GitTurnBaselineStore.shared.baseline(forSessionID: sessionID) else {
                show(.message("No turn recorded yet.\nThe baseline is captured when the agent starts working."))
                return
            }
            loadDiff(.lastTurn(baseline), in: root)

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

        GitReviewReader.diff(request, in: root) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.isLoading = false
            self.lastLoadedAt = Date()

            switch result {
            case .success(let files):
                self.show(files.isEmpty ? .message("No changes.") : .files(files))
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? "git failed."))
            }
            self.reloadIfPending()
        }
    }

    private func loadCommitList(in root: URL, skip: Int) {
        generation += 1
        let expected = generation
        isLoading = true

        GitReviewReader.log(skip: skip, in: root) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.isLoading = false
            self.lastLoadedAt = Date()

            switch result {
            case .success(let page):
                if skip == 0 { self.commits = page } else { self.commits += page }
                self.lastPageWasFull = page.count == GitReviewDefaults.logPageSize
                self.show(self.commits.isEmpty
                    ? .message("No commits yet.")
                    : .commits(canLoadMore: self.lastPageWasFull))
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? "git failed."))
            }
            self.reloadIfPending()
        }
    }

    func openCommit(_ commit: GitCommitSummary) {
        guard let root = repositoryRoot else { return }
        generation += 1
        let expected = generation
        isLoading = true

        GitReviewReader.diff(.commit(hash: commit.hash), in: root) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.isLoading = false

            switch result {
            case .success(let files):
                if files.isEmpty {
                    self.show(.message("No textual changes (likely a merge commit)."))
                } else {
                    self.show(.commitDetail(commit, files))
                }
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? "git failed."))
            }
        }
    }

    // MARK: - Mode

    private func modeMenu() -> NSMenu {
        let menu = NSMenu()
        for candidate in GitReviewMode.allCases {
            let item = NSMenuItem(title: candidate.title, action: nil, keyEquivalent: "")
            item.representedObject = candidate.rawValue
            item.state = candidate == mode ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func switchMode(to newMode: GitReviewMode) {
        guard newMode != mode else { return }
        mode = newMode
        // What was opened by hand described the old comparison; the same path in a new mode is
        // a different diff.
        expansionOverrides.removeAll()
        modeChip.configure(symbolName: GitReviewUIDefaults.modeSymbol, title: newMode.title)
        onModeChange?()
        refresh(force: true)
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        refresh(force: true)
    }

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
private final class WindowAwareView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

// MARK: - Defaults

enum GitReviewUIDefaults {
    /// The chip's mark for every mode: the change itself, not any one comparison.
    static let modeSymbol = "plus.forwardslash.minus"

    static let commitPlaceholder = "Commit staged changes…"
}
