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

    /// Feeds the selected sidebar row. It stays true through main-thread view construction,
    /// not merely through the background git read.
    var onLoadingChange: ((Bool) -> Void)?

    var modeChip: ChipView!
    var backButton: ThemedButton!
    var counterLabel: NSTextField!
    private var menuButton: ThemedButton!
    var scrollView: NSScrollView!
    var stack: NSStackView!
    var placeholderLabel: NSTextField!
    var summaryPill: GitReviewSummaryPill!
    var jumpToEndButton: ThemedButton!
    private var scrollObserver: NSObjectProtocol?

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

    /// Which files the user has opened or closed by hand. Consulted ahead of the auto-expand
    /// heuristic, so a watched checkout re-reading itself does not close what is being read.
    var expansionOverrides: [String: Bool] = [:]

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
        if isLoading { onLoadingChange?(false) }
        watcher?.stop()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    // MARK: - Setup

    private func setupHeader() {
        backButton = ThemedButton(symbol: "chevron.left", accessibility: "Back", target: self, action: #selector(backToCommits)
        )
        backButton.isBordered = false
        backButton.toolTip = "Back to history"
        backButton.isHidden = true

        modeChip = ChipView()
        modeChip.configure(symbolName: GitReviewUIDefaults.modeSymbol, title: mode.title)
        modeChip.itemsProvider = { [weak self] in self?.modeItems() ?? [] }
        modeChip.onSelect = { [weak self] item in
            guard let raw = item.representedValue as? String,
                  let mode = GitReviewMode(rawValue: raw) else { return }
            self?.switchMode(to: mode)
        }

        counterLabel = NSTextField(labelWithString: "")
        counterLabel.font = Design.Typography.caption()
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)

        // One overflow rather than a row of icons: refreshing, collapsing, wrapping and the
        // whitespace fold are all things asked of the diff occasionally, and a header of five
        // glyphs would compete with the mode chip, which is the control that matters here.
        menuButton = ThemedButton(
            symbol: "ellipsis",
            accessibility: "Diff options",
            target: self,
            action: #selector(showOverflowMenu(_:))
        )
        menuButton.isBordered = false
        menuButton.toolTip = "Diff options"

        [backButton, modeChip, counterLabel, menuButton].forEach {
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

        scrollView = ThemedScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clipView
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.updateScrollControls()
        }

        placeholderLabel = NSTextField(labelWithString: "")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = Design.Typography.body()
        placeholderLabel.textColor = Design.Text.tertiary
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0

        summaryPill = GitReviewSummaryPill()
        summaryPill.translatesAutoresizingMaskIntoConstraints = false
        summaryPill.isHidden = true

        jumpToEndButton = ThemedButton(
            symbol: "arrow.down",
            accessibility: "Scroll to the end of the diff",
            target: self,
            action: #selector(scrollToDiffEnd)
        )
        jumpToEndButton.translatesAutoresizingMaskIntoConstraints = false
        jumpToEndButton.isBordered = false
        jumpToEndButton.toolTip = "Scroll to end"
        jumpToEndButton.applySurface(
            fill: Design.Surface.elevated,
            radius: .fixed(20),
            border: Design.Surface.border,
            glow: true
        )
        jumpToEndButton.isHidden = true

        view.addSubview(scrollView)
        view.addSubview(placeholderLabel)
        view.addSubview(summaryPill)
        view.addSubview(jumpToEndButton)
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
                lessThanOrEqualTo: menuButton.leadingAnchor,
                constant: -Design.Spacing.small
            ),

            menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            menuButton.centerYAnchor.constraint(equalTo: modeChip.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: modeChip.bottomAnchor, constant: Design.Spacing.small),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Rows wrap to the pane's width instead of scrolling sideways.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: inset),

            summaryPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            summaryPill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.inset),
            summaryPill.heightAnchor.constraint(equalToConstant: 34),

            jumpToEndButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpToEndButton.bottomAnchor.constraint(
                equalTo: summaryPill.topAnchor,
                constant: -Design.Spacing.small
            ),
            jumpToEndButton.widthAnchor.constraint(equalToConstant: 40),
            jumpToEndButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    @objc func scrollToDiffEnd() {
        view.layoutSubtreeIfNeeded()
        let overflow = max(
            0,
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: overflow))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateScrollControls()
    }

    func updateScrollControls() {
        guard isViewLoaded, summaryPill != nil, !summaryPill.isHidden else {
            jumpToEndButton?.isHidden = true
            return
        }
        let overflow = max(
            0,
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        )
        let distanceFromEnd = overflow - scrollView.contentView.bounds.origin.y
        jumpToEndButton.isHidden = overflow <= 1 || distanceFromEnd <= 4
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

        GitReviewReader.diff(request, in: root, ignoringWhitespace: ignoresWhitespace) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.lastLoadedAt = Date()

            switch result {
            case .success(let files):
                self.show(files.isEmpty ? .message("No changes.") : .files(files))
            case .failure(let failure):
                self.show(.message(failure.errorDescription ?? "git failed."))
            }
            self.isLoading = false
            self.reloadIfPending()
        }
    }

    private func loadCommitList(in root: URL, skip: Int) {
        generation += 1
        let expected = generation
        isLoading = true

        GitReviewReader.log(skip: skip, in: root) { [weak self] result in
            guard let self, expected == self.generation else { return }
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
            self.isLoading = false
            self.reloadIfPending()
        }
    }

    func openCommit(_ commit: GitCommitSummary) {
        guard let root = repositoryRoot else { return }
        generation += 1
        let expected = generation
        isLoading = true

        GitReviewReader.diff(
            .commit(hash: commit.hash),
            in: root,
            ignoringWhitespace: ignoresWhitespace
        ) { [weak self] result in
            guard let self, expected == self.generation else { return }

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
            self.isLoading = false
        }
    }

    // MARK: - Mode

    private func modeItems() -> [ThemedMenuEntry] {
        GitReviewMode.allCases.map { candidate in
            .item(
                ThemedMenuItem(
                    title: candidate.title,
                    representedValue: candidate.rawValue,
                    isSelected: candidate == mode
                )
            )
        }
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

    @objc func loadMoreCommits() {
        guard let root = repositoryRoot, !isLoading else { return }
        loadCommitList(in: root, skip: commits.count)
    }

    @objc private func backToCommits() {
        show(.commits(canLoadMore: lastPageWasFull))
    }
}

/// The compact total that remains visible while reading a long diff, mirroring the mobile
/// review surface without making the Mac renderer depend on the phone's view layer.
final class GitReviewSummaryPill: NSView {
    private let filesLabel = NSTextField(labelWithString: "")
    private let addedLabel = NSTextField(labelWithString: "")
    private let removedLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let labels = [filesLabel, addedLabel, removedLabel]
        labels.forEach {
            $0.font = Design.Typography.caption()
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        let stack = NSStackView(views: labels)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(files: Int, added: Int, removed: Int) {
        filesLabel.stringValue = "\(files) \(files == 1 ? "file" : "files")"
        filesLabel.textColor = Design.Text.secondary
        addedLabel.stringValue = "+\(added.formatted(.number.notation(.compactName)))"
        addedLabel.textColor = Design.Diff.added
        removedLabel.stringValue = "−\(removed.formatted(.number.notation(.compactName)))"
        removedLabel.textColor = Design.Diff.removed
        setAccessibilityLabel(
            "\(files) changed files, \(added) additions, \(removed) deletions"
        )
        applySurface(
            fill: Design.Surface.elevated,
            radius: .fixed(17),
            border: Design.Surface.border,
            glow: true
        )
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

    static let commitPlaceholder = "Commit staged changes…"

    /// Delimits the patch in the copied `git apply` heredoc. Distinctive enough that a diff
    /// containing the word cannot close it early.
    static let patchHeredocDelimiter = "SKALMAN_PATCH_EOF"
}
