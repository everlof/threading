import AppKit
import ThreadingDesignKit

/// A live log stream from a booted simulator or a paired iPhone.
///
/// Host-owned for the same reasons `simulator-pane.md` gives for the simulator: the sources are
/// device transactions, and log content is the user's. An extension may later contribute a
/// *source*; it does not get to own the buffer, the virtualization or the ceilings.
///
/// The scaling contract is in
/// [`device-and-simulator-logs.md`](../../../../docs/feature-drafts/device-and-simulator-logs.md):
/// a real device produces ~5,800 rows/sec unfiltered. Rows stay a value model in a bounded ring,
/// the table owns viewport rows only, and the drain is coalesced onto a timer so one batch of
/// main-thread work happens per tick regardless of the source's rate.
@MainActor
public final class DeviceLogPaneViewController: NSViewController {

    // MARK: Constants

    private enum Metrics {
        static let drainInterval: TimeInterval = 0.1
        static let rateInterval: TimeInterval = 1
        static let rowHeight: CGFloat = 16
        static let bottomSlack: CGFloat = 4
        /// The header is created with an explicit height on purpose: `NSTableHeaderView` built from
        /// a zero frame reserves no room in the scroll view, and the first rows then draw *under*
        /// the column titles rather than below them.
        static let headerHeight: CGFloat = 22
        /// One height for every control in the bar. Their intrinsic heights differ — a popup, a
        /// button and a field each measure themselves — and a row of controls that disagree by a
        /// point or two reads as sloppy long before anyone can say why.
        static let controlHeight: CGFloat = 22
        /// How long a source may produce nothing before the pane says so rather than showing a
        /// bare zero. Long enough that an ordinarily quiet moment does not read as a fault.
        static let silenceGrace: TimeInterval = 6
    }

    private enum Columns {
        static let time = NSUserInterfaceItemIdentifier("time")
        static let level = NSUserInterfaceItemIdentifier("level")
        static let process = NSUserInterfaceItemIdentifier("process")
        static let subsystem = NSUserInterfaceItemIdentifier("subsystem")
        static let message = NSUserInterfaceItemIdentifier("message")

        static let widths: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (time, "Time", 92),
            (level, "Level", 62),
            (process, "Process", 150),
            (subsystem, "Subsystem", 180),
            (message, "Message", 640),
        ]
    }

    // MARK: Chrome

    private let sourcePopUp = ThemedPopUp()
    private let routePopUp = ThemedPopUp()
    private let levelPopUp = ThemedPopUp()
    private let filterField = ThemedTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    /// The opaque ground the Resume button stands on while it floats over the rows.
    ///
    /// A view rather than a layer colour on purpose: a theme colour baked into a `CGColor` is not
    /// re-resolved when the theme changes, and this pane already redraws on that notification, so
    /// drawing it is both simpler and correct under a live switch.
    /// Why the reader stopped on its own, if it did.
    ///
    /// A dead reader and a quiet device look identical, and the pane could not tell them apart
    /// because nothing told it. Cleared whenever a source is started.
    private var endedReason: String?

    private let followPlate = FollowPlateView()

    private lazy var followButton = ThemedButton(
        title: L10n.string("Resume"),
        target: self,
        action: #selector(resumeFollowing)
    )
    private let table = ThemedTableView()
    private var scroll: ThemedScrollView?

    // MARK: State

    private var options: [DeviceLogSourceOption] = []
    private var source: DeviceLogRowSource?
    private var runningSourceTitle: String?
    private var route: DeviceLogSourceOption.Route = .appLog
    private var rows: [DeviceLogRow] = []
    /// What the table draws: rows, and folds standing in for runs of them.
    ///
    /// This used to be the rows that matched, with the rest dropped — so the lines that explain a
    /// failure went with them. A fold keeps them one click away.
    private var entries: [LogDisplayEntry] = []
    /// Folds the reader has opened.
    private var expandedGaps: Set<Int> = []

    /// What the agent last did here, in the pane's own words.
    ///
    /// An agent can search everything this pane recorded and fold the view down to what it cares
    /// about. Doing that invisibly would mean the person watching sees a view that changed, or a
    /// conclusion drawn from rows they were never shown, with nothing saying who did it. Folding
    /// already moves the controls; this covers the reading, which otherwise leaves no trace at all.
    private var agentNote: String?

    /// Ring positions an agent's search matched, marked so its reading is something you can see.
    private var agentHits: Set<Int> = []
    private var filter = ""
    private var minimumSeverity = 0

    /// The controls, as the fold layout reads them. Built rather than stored so the two cannot
    /// drift: the filter field and the level chooser *are* the focus.
    private var focus: LogFocus {
        LogFocus(
            pattern: filter,
            minimumSeverity: minimumSeverity,
            context: DeviceLogLimits.foldContext
        )
    }
    private var drainTimer: Timer?
    private var boundsObserver: NSObjectProtocol?
    /// Whether new rows carry the view with them. True until the reader scrolls away, and true
    /// again the moment they come back to the bottom — so following is something you leave and
    /// rejoin rather than a mode you have to remember to switch.
    private var isFollowing = true
    private var rateTimer: Timer?
    private var received = 0
    private var lastCount = 0
    private var rate = 0
    /// When the running source was started, so a source that connects and then says nothing can
    /// be told apart from one that simply has not been asked yet.
    private var startedAt: Date?

    /// The session this tab belongs to, kept so a predicate could later be scoped to its project.
    public let owningSessionID: String?

    /// Writes what arrives to disk, so search and a time range have something to look at once the
    /// ring has moved on. One store per chat: two chats watching two devices are two histories.
    public let recorder: DeviceLogRecorder?

    public init(owningSessionID: String?) {
        self.owningSessionID = owningSessionID
        self.recorder = DeviceLogRecorder(
            directory: Self.storeDirectory,
            name: owningSessionID ?? "unattached"
        )
        super.init(nibName: nil, bundle: nil)
    }

    /// Under Caches rather than Application Support: a log history is reconstructible by watching
    /// again, and the system may reclaim it when the disk is tight without losing anything the
    /// user authored.
    static var storeDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("codes.threading", isDirectory: true)
            .appendingPathComponent("DeviceLogs", isDirectory: true)
    }

    public required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        // Timers and the child process must not outlive the pane. `source` is stopped on the main
        // actor by `viewWillDisappear`; this is the belt for a controller released another way.
        drainTimer?.invalidate()
        rateTimer?.invalidate()
    }

    // MARK: Lifecycle

    public override func loadView() {
        view = NSView()
        buildTable()
        buildChrome()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard drainTimer == nil else { return }
        reloadSources()
        drainTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.drainInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        rateTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.rateInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rate = self.received - self.lastCount
                self.lastCount = self.received
                self.updateStatus()
            }
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        // A hidden tab must not keep a child process reading a firehose.
        //
        // `runningSourceTitle` deliberately survives. It records *which* source the rows on screen
        // came from, not whether a process is alive, and clearing it here made every re-appearance
        // look like a source change — so switching tabs or sessions and coming back wiped the
        // whole log. `source == nil` is what says "not currently reading".
        source?.stop()
        source = nil
        drainTimer?.invalidate()
        drainTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
    }

    // MARK: Building

    private func buildTable() {
        for (identifier, title, width) in Columns.widths {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Metrics.rowHeight
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        let scroll = ThemedScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        // Order matters, and getting it wrong is subtle: a header assigned *before* the table has a
        // scroll view is adopted by the table itself, so it scrolls with the content — the first
        // rows draw under the column titles and a ghost copy of the header appears mid-list. Set it
        // once the scroll view owns the table, then tile so the header band is actually reserved.
        table.headerView = ThemedTableHeaderView(
            frame: NSRect(x: 0, y: 0, width: 0, height: Metrics.headerHeight)
        )
        scroll.tile()

        // The pane follows the tail until the reader scrolls away, so it has to know when they do.
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollPositionChanged() }
        }
        self.scroll = scroll
    }

    /// The level filter's thresholds, in menu order. `ThemedMenuItem` carries no tag, so the
    /// menu's own order is the mapping.
    private static let levelThresholds = [0, 1, 3]

    /// Sources the user actually reached for, most recent first.
    ///
    /// A phone carries every app its owner has ever built — 29 here — and alphabetical order says
    /// nothing about which of them is being worked on today. Ordering by what was last opened lets
    /// the list organise itself, and costs no round trip to the device to work out.
    private enum Recents {
        static let key = "deviceLogRecentSources"
        static let capacity = 12

        static func titles() -> [String] {
            PreferenceStore.shared.stringArray(forKey: key) ?? []
        }

        static func remember(_ title: String) {
            var titles = self.titles().filter { $0 != title }
            titles.insert(title, at: 0)
            PreferenceStore.shared.set(Array(titles.prefix(capacity)), forKey: key)
        }

        /// Recently used first, in the order they were used; everything else after, as found.
        static func ordered(_ options: [DeviceLogSourceOption]) -> [DeviceLogSourceOption] {
            let ranks = titles().enumerated().reduce(into: [String: Int]()) { $0[$1.element] = $1.offset }
            let recent = options.filter { ranks[$0.title] != nil }
                .sorted { (ranks[$0.title] ?? 0) < (ranks[$1.title] ?? 0) }
            let rest = options.filter { ranks[$0.title] == nil }
            return recent + rest
        }
    }

    private func buildChrome() {
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)

        // Built from `allCases` so the menu order and the enum order cannot drift apart.
        for route in DeviceLogSourceOption.Route.allCases {
            routePopUp.addItem(withTitle: route.title)
        }
        routePopUp.selectItem(at: 0)
        routePopUp.target = self
        routePopUp.action = #selector(routeChanged)
        routePopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        for title in ["All levels", "Info and above", "Errors only"] {
            levelPopUp.addItem(withTitle: L10n.string(title))
        }
        levelPopUp.selectItem(at: 0)
        levelPopUp.target = self
        levelPopUp.action = #selector(levelChanged)

        filterField.placeholderString = L10n.string("Filter log lines")
        filterField.delegate = self

        let rescan = ThemedButton(
            title: L10n.string("Rescan"),
            target: self,
            action: #selector(reloadSources)
        )
        let clear = ThemedButton(
            title: L10n.string("Clear"),
            target: self,
            action: #selector(clearRows)
        )

        // Counts and rate live in a footer rather than the control bar. In the bar they competed
        // with the filter field for width, so every control resized as the number of rows grew —
        // chrome that moves while you read it.
        statusLabel.alignment = .right
        statusLabel.setAccessibilityIdentifier("device-log-status")
        statusLabel.font = Design.Typography.compactCode()
        statusLabel.textColor = Design.Text.secondary

        let bar = NSStackView(views: [sourcePopUp, routePopUp, rescan, levelPopUp, filterField, clear])
        bar.orientation = .horizontal
        bar.spacing = Design.Spacing.small
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.small,
            right: Design.Spacing.medium
        )
        for control in [sourcePopUp, routePopUp, levelPopUp] as [NSView] + [rescan, clear, filterField] {
            control.heightAnchor.constraint(equalToConstant: Metrics.controlHeight).isActive = true
        }

        let footer = NSStackView(views: [statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.tight,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.tight,
            right: Design.Spacing.medium
        )

        guard let scroll else { return }
        let stack = NSStackView(views: [bar, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Over the rows rather than in the chrome: it belongs to the thing that stopped moving,
        // and it must not take a permanent slice of a bar that is already full.
        //
        // Floating over content means it has to bring its own ground. A plain themed button
        // deliberately rests on nothing — that is right for a button on a panel and wrong for one
        // standing on a moving log, where the rows were legible straight through the word
        // "Resume". The plate is the pane's job, not the button's.
        // Both, deliberately. Hiding only the container leaves the button reporting itself
        // visible while nothing can reach it, which is what an accessibility client and a UI test
        // both ask — and the identifier is on the button, because the button is the thing you
        // press.
        followPlate.isHidden = true
        followButton.isHidden = true
        followButton.setAccessibilityIdentifier("device-log-resume-follow")
        followButton.translatesAutoresizingMaskIntoConstraints = false
        followPlate.translatesAutoresizingMaskIntoConstraints = false
        followPlate.addSubview(followButton)
        view.addSubview(followPlate)
        NSLayoutConstraint.activate([
            followButton.leadingAnchor.constraint(
                equalTo: followPlate.leadingAnchor,
                constant: Design.Spacing.small
            ),
            followButton.trailingAnchor.constraint(
                equalTo: followPlate.trailingAnchor,
                constant: -Design.Spacing.small
            ),
            followButton.topAnchor.constraint(
                equalTo: followPlate.topAnchor,
                constant: Design.Spacing.tight
            ),
            followButton.bottomAnchor.constraint(
                equalTo: followPlate.bottomAnchor,
                constant: -Design.Spacing.tight
            ),
            followPlate.trailingAnchor.constraint(
                equalTo: scroll.trailingAnchor,
                constant: -Design.Spacing.large
            ),
            followPlate.bottomAnchor.constraint(
                equalTo: scroll.bottomAnchor,
                constant: -Design.Spacing.medium
            ),
        ])
    }

    // MARK: Sources

    @objc private func reloadSources() {
        DeviceLogSourceCatalog.discover { [weak self] found in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.options = Recents.ordered(found)
                let found = self.options
                // Populating must not read as a user choice: AppKit sends a popup's action as
                // items are added, which restarted the stream on the wrong source.
                let action = self.sourcePopUp.action
                self.sourcePopUp.action = nil
                self.sourcePopUp.removeAllItems()
                found.forEach { self.sourcePopUp.addItem(withTitle: $0.title) }
                // Rescan looks for sources; it is not a request to change the one being read.
                // Keep the running selection when it survived the rescan, so plugging a phone in
                // does not yank the pane off the simulator it was watching.
                let keep = self.runningSourceTitle.flatMap { title in
                    found.firstIndex { $0.title == title }
                }
                if found.isEmpty {
                    // An empty popup draws as a bare chevron, which does not read as a control at
                    // all — the one place the pane most needs to look like somewhere you choose a
                    // device is the case where it has not found one.
                    self.sourcePopUp.addItem(withTitle: L10n.string("No log sources"))
                    self.sourcePopUp.isEnabled = false
                } else {
                    self.sourcePopUp.isEnabled = true
                    self.sourcePopUp.selectItem(at: keep ?? 0)
                }
                self.sourcePopUp.action = action
                self.startSelectedSource()
            }
        }
    }

    private func startSelectedSource() {
        let index = sourcePopUp.indexOfSelectedItem
        guard index >= 0, index < options.count else {
            updateStatus()
            return
        }
        let option = options[index]
        // The route only means something for an app; a device's system log has just the one.
        var isApp = false
        if case .app = option.kind { isApp = true }
        routePopUp.isHidden = !isApp
        let identity = isApp ? "\(option.title)#\(route.rawValue)" : option.title
        // Already reading this one: restarting would throw away every row read so far.
        guard identity != runningSourceTitle || source == nil else { return }
        // Resuming the same source after the pane was hidden keeps what is on screen. Only a
        // genuine change of source discards it, because those rows are no longer about the thing
        // being read. Resuming does leave a gap where the pane was not listening, which is honest
        // for a live tail and better than an empty pane.
        let isSameSource = identity == runningSourceTitle
        runningSourceTitle = identity
        Recents.remember(option.title)

        source?.stop()
        if !isSameSource {
            rows.removeAll(keepingCapacity: true)
            entries.removeAll(keepingCapacity: true)
            expandedGaps.removeAll()
            received = 0
            lastCount = 0
            table.reloadData()
        }

        endedReason = nil
        guard let started = option.makeSource(predicate: nil, route: route) else {
            source = nil
            endedReason = L10n.string("this source has no reader on this Mac")
            updateStatus()
            return
        }
        // Reported from the reader's own queue, so it comes back to the main actor before it
        // touches the pane.
        started.onStreamEnded = { [weak self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.endedReason = reason
                    self.updateStatus()
                }
            }
        }
        source = started
        started.start()
        startedAt = Date()
        updateStatus()
    }

    @objc private func sourceChanged() { startSelectedSource() }

    @objc private func routeChanged() {
        // The menu is built from `allCases` in order, so its index *is* the route. An index that
        // is not one leaves the current route alone rather than quietly meaning "app log": a
        // selection nobody made must not decide which of an app's two logs is read.
        let routes = DeviceLogSourceOption.Route.allCases
        let index = routePopUp.indexOfSelectedItem
        guard routes.indices.contains(index) else { return }
        route = routes[index]
        startSelectedSource()
    }

    @objc private func levelChanged() {
        let index = levelPopUp.indexOfSelectedItem
        minimumSeverity = Self.levelThresholds.indices.contains(index)
            ? Self.levelThresholds[index]
            : 0
        recomputeVisible()
        table.reloadData()
        updateStatus()
    }

    @objc private func clearRows() {
        rows.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        expandedGaps.removeAll()
        table.reloadData()
        updateStatus()
    }

    /// Rows without a device, so the pane's own layout can be reviewed as a picture.
    ///
    /// `design-system.md` asks for a rendered state on a new component, and this surface earns it:
    /// its header sat *on top of* the first rows for a whole build because nothing drew it.
    public func installRowsForTesting(_ fixture: [DeviceLogRow], focusing pattern: String = "") {
        rows = fixture
        filter = pattern
        filterField.stringValue = pattern
        recomputeVisible()
        table.reloadData()
        updateStatus()
    }

    // MARK: Driving from outside

    /// Sets the focus from somewhere that is not the controls — an agent, today.
    ///
    /// It moves the controls too rather than holding a second, invisible state: a pane whose
    /// filter field disagrees with what it is showing is a pane nobody can reason about, and the
    /// user has to be able to see what the agent did and undo it.
    public func applyFocus(pattern: String, minimumSeverity: Int) {
        filter = pattern
        filterField.stringValue = pattern
        self.minimumSeverity = minimumSeverity
        expandedGaps.removeAll()
        agentHits.removeAll()
        recomputeVisible()
        table.reloadData()
        updateStatus()
    }

    /// Records what the agent just did, and marks what its search found.
    ///
    /// `hits` are matched against the ring, so older matches that have scrolled out of memory are
    /// counted in the note but cannot be marked — saying "and 340 older" is honest where marking
    /// nothing would imply the search found only what is on screen.
    public func noteAgentAction(_ note: String, searching pattern: String? = nil) {
        agentNote = note
        agentHits.removeAll()
        if let pattern, !pattern.isEmpty {
            let focus = LogFocus(pattern: pattern, minimumSeverity: 0, context: 0)
            for (index, row) in rows.enumerated() where focus.matches(row) {
                agentHits.insert(index)
            }
        }
        table.reloadData()
        updateStatus()
    }

    /// Clears the note when the person takes the view back.
    public func clearAgentNote() {
        guard agentNote != nil || !agentHits.isEmpty else { return }
        agentNote = nil
        agentHits.removeAll()
        table.reloadData()
        updateStatus()
    }

    /// What the pane is saying about the agent, for a test that has to see it.
    /// Which source the rows on screen came from, and whether one is being read.
    ///
    /// Two facts rather than one, because conflating them is what wiped the log: hiding the pane
    /// stops the reader but does not change what the rows are *about*.
    public var runningSourceTitleForTesting: String? { runningSourceTitle }
    public var isReadingForTesting: Bool { source != nil }

    public func setRunningSourceTitleForTesting(_ title: String?) { runningSourceTitle = title }

    public var agentNoteForTesting: String? { agentNote }
    public var agentHitsForTesting: Set<Int> { agentHits }
    public var statusTextForTesting: String { statusLabel.stringValue }

    /// Drives the same path a keystroke in the filter field takes.
    public func simulateUserFilterEditForTesting(_ text: String) {
        filterField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// What is on screen right now, for a tool that has to answer for it.
    public var focusSummary: (shown: Int, folded: Int, total: Int) {
        let folded = entries.reduce(0) { $0 + $1.hiddenCount }
        return (rows.count - folded, folded, rows.count)
    }

    /// The rows currently visible, newest last, for a tool asked what is on screen.
    public func visibleRowsForTools(limit: Int) -> [DeviceLogRow] {
        entries.suffix(limit).compactMap { entry in
            if case .row(let index) = entry, rows.indices.contains(index) { return rows[index] }
            return nil
        }
    }

    // MARK: Filtering

    private var isFiltering: Bool { !filter.isEmpty || minimumSeverity > 0 }

    private func matches(_ row: DeviceLogRow) -> Bool {
        guard row.severity >= minimumSeverity else { return false }
        guard !filter.isEmpty else { return true }
        return row.message.lowercased().contains(filter)
            || row.process.lowercased().contains(filter)
            || (row.subsystem?.lowercased().contains(filter) ?? false)
    }

    private func recomputeVisible() {
        entries = LogFocusLayout.entries(rows: rows, focus: focus, expanded: expandedGaps)
    }

    // MARK: Streaming

    /// One batch per tick. The bottom stays pinned only when it was already pinned, so scrolling
    /// back to read something is not fought by the stream.
    private func drain() {
        guard let source else { return }
        let incoming = source.drain()
        guard !incoming.isEmpty else { return }
        received += incoming.count
        // On disk as well as on screen: the ring is what the table can hold, the store is what a
        // question can reach back through once the ring has moved on.
        recorder?.record(incoming)

        rows.append(contentsOf: incoming)
        if rows.count > DeviceLogLimits.ringCapacity {
            rows.removeFirst(rows.count - DeviceLogLimits.ringCapacity)
        }

        if isFiltering {
            entries = LogFocusLayout.entries(rows: rows, focus: focus, expanded: expandedGaps)
            if false {
                entries.removeFirst(0)
            }
        } else {
            entries = rows.indices.map { .row($0) }
        }

        table.reloadData()
        if isFollowing, !entries.isEmpty {
            table.scrollRowToVisible(entries.count - 1)
        }
        updateFollowAffordance()
    }

    /// The reader moved the view. Leaving the bottom stops the follow; arriving back resumes it.
    private func scrollPositionChanged() {
        let atBottom = isPinnedToBottom()
        guard atBottom != isFollowing else { return }
        isFollowing = atBottom
        updateFollowAffordance()
    }

    @objc private func resumeFollowing() {
        isFollowing = true
        if !entries.isEmpty { table.scrollRowToVisible(entries.count - 1) }
        updateFollowAffordance()
    }

    /// The button is the only thing that says the view has stopped moving on purpose. Without it a
    /// reader who scrolled up sees a still list and cannot tell it from a source that went quiet.
    private func updateFollowAffordance() {
        followPlate.isHidden = isFollowing
        followButton.isHidden = isFollowing
        let behind = max(0, entries.count - (table.rows(in: table.visibleRect).location
            + table.rows(in: table.visibleRect).length))
        followButton.title = behind > 0
            ? L10n.format("Resume · %@ new", "\(behind)")
            : L10n.string("Resume")
    }

    private func isPinnedToBottom() -> Bool {
        guard let scroll, let document = scroll.documentView else { return true }
        return scroll.contentView.documentVisibleRect.maxY
            >= document.bounds.height - Metrics.bottomSlack
    }

    /// Puts the agent's note after whatever the pane was going to say.
    private func appending(_ text: String) -> String {
        guard let agentNote else { return text }
        return text + " · " + agentNote
    }

    private func updateStatus() {
        // The agent's note is appended to every state, including these two. It says what happened
        // to what the person is looking at, and dropping it in exactly the states where the pane is
        // otherwise uninformative is where it would be missed most: a search of recorded history
        // works perfectly well while the current source is silent or absent.
        guard !options.isEmpty else {
            statusLabel.stringValue = appending(
                L10n.string("No booted simulator or paired iPhone found.")
            )
            return
        }
        // Above every other state, because a reader that stopped makes the rest of them untrue:
        // a row count and a rate describe a stream that is no longer running. The reason comes
        // from the child's own diagnostics, which used to be discarded — "device is locked" and
        // "application is not installed" both arrived as silence.
        if let endedReason {
            statusLabel.stringValue = appending(
                L10n.format("The log reader stopped: %@ — press Rescan to start it again.", endedReason)
            )
            statusLabel.textColor = Design.Status.warning
            return
        }
        // Silence is a state, not an absence of one. A device whose relay accepts the connection
        // and then sends nothing looks identical to a quiet device unless the pane says so, and
        // that exact case cost an afternoon: `os_trace_relay` connects, streams nothing, and the
        // archive route through the same service works fine.
        if received == 0, let startedAt, Date().timeIntervalSince(startedAt) > Metrics.silenceGrace {
            statusLabel.stringValue = appending(L10n.string("Connected, but no log lines yet."))
            statusLabel.textColor = Design.Status.warning
            return
        }
        statusLabel.textColor = Design.Text.secondary
        let folded = entries.reduce(0) { $0 + $1.hiddenCount }
        var parts = [isFiltering ? "\(rows.count - folded)/\(rows.count)" : "\(rows.count)"]
        if folded > 0 { parts.append("\(folded) folded") }
        parts.append("\(rate)/s")
        if let dropped = source?.dropped, dropped > 0 { parts.append("⚠︎ \(dropped)") }
        if let agentNote { parts.append(agentNote) }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }
}

// MARK: - Filter field

extension DeviceLogPaneViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        // The person is driving again, so the agent's note stops describing what they are seeing.
        clearAgentNote()
        filter = filterField.stringValue.lowercased()
        recomputeVisible()
        table.reloadData()
        updateStatus()
    }
}

// MARK: - Table

extension DeviceLogPaneViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
}

extension DeviceLogPaneViewController: NSTableViewDelegate {
    /// Only the viewport's rows are ever built, through ordinary reuse. This is the whole reason
    /// the pane is a table rather than a stack of labels.
    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, entries.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let host = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.font = Design.Typography.compactCode()
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true

        switch entries[row] {
        case .gap(let range):
            // A fold says how much is inside it, in the message column only — a count in the time
            // column would read as a time.
            label.stringValue = identifier == Columns.message
                ? "\(range.count) more \(range.count == 1 ? "row" : "rows") — click to show"
                : ""
            label.textColor = Design.Text.tertiary
        case .row(let index):
            guard rows.indices.contains(index) else { return nil }
            let entry = rows[index]
            label.stringValue = text(for: entry, column: identifier)
            label.textColor = ink(for: entry, column: identifier)
            // A row the agent's search matched, marked in the time column: a stripe down the left
            // that does not collide with the message weight a focus match already carries.
            //
            // Weight as well as colour, because colour alone did not work — an error row already
            // draws its clock in the accent, so a hit on an error was indistinguishable from the
            // error, and only a rendered picture showed it.
            if agentHits.contains(index), identifier == Columns.time {
                label.textColor = AppThemePalette.color(.accent)
                label.font = .monospacedSystemFont(
                    ofSize: Design.Typography.compactCode().pointSize,
                    weight: .bold
                )
            }
            // The match is why the fold opened around it, so it is what the eye should land on.
            if focus.isActive, focus.matches(entry), identifier == Columns.message {
                // Same metrics as the rows around it, heavier ink: a bolder weight at the same size
                // keeps the column aligned, which a larger one would not.
                label.font = .monospacedSystemFont(
                    ofSize: Design.Typography.compactCode().pointSize,
                    weight: .bold
                )
            }
        }
        host.install(label, columnWidth: tableColumn.width, horizontalInset: Design.Spacing.tight)
        return host
    }

    /// Opening a fold is a click on it, which is the only affordance a folded run needs.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = table.selectedRow
        guard entries.indices.contains(selected), case .gap(let range) = entries[selected] else {
            return
        }
        expandedGaps.insert(range.lowerBound)
        entries = LogFocusLayout.entries(rows: rows, focus: focus, expanded: expandedGaps)
        table.reloadData()
    }

    private func text(for entry: DeviceLogRow, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Columns.time: return entry.time
        case Columns.level: return entry.level
        case Columns.process: return entry.process
        case Columns.subsystem: return entry.subsystem ?? ""
        default: return entry.message
        }
    }

    private func ink(for entry: DeviceLogRow, column: NSUserInterfaceItemIdentifier) -> NSColor {
        if entry.severity >= 3 { return Design.Status.warning }
        switch column {
        case Columns.process, Columns.message: return Design.Text.label
        default: return Design.Text.secondary
        }
    }
}

/// The plate behind the floating Resume button.
///
/// The plate exists because a plain `ThemedButton` rests on nothing, which is right for a button on
/// a panel and wrong for one floating over a log: the rows were legible through the word "Resume".
///
/// Its fill is flattened over the ground — the floating-surface rule, the same one
/// `ImageCompareView`'s handle and a lifted `ThemedTabItemView` follow. Measured, `elevated` is
/// opaque under every theme that ships today, so the flattening changes nothing now; it is here
/// because unlike `ground`, which `AppThemeEditing` refuses unless it is opaque, `elevated` carries
/// no such guarantee, and an authored theme may make it translucent.
final class FollowPlateView: NSView {

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: Design.Radius.control,
            yRadius: Design.Radius.control
        )
        path.addClip()
        Design.Surface.elevated.composited(over: InkSource.chrome.ground).setFill()
        bounds.fill()

        Design.Surface.divider.setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Design.Radius.border / 2, dy: Design.Radius.border / 2),
            xRadius: Design.Radius.control,
            yRadius: Design.Radius.control
        )
        border.lineWidth = Design.Radius.border
        border.stroke()
    }
}
