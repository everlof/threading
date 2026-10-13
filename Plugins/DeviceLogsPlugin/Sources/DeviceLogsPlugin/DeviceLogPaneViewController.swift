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

    public enum Stream: String, CaseIterable {
        case regular, bluetooth

        var title: String {
            switch self {
            case .regular: return L10n.string("Regular Logs")
            case .bluetooth: return L10n.string("Bluetooth")
            }
        }

        func includes(_ option: DeviceLogSourceOption) -> Bool {
            if case .bluetooth = option.kind { return self == .bluetooth }
            return self == .regular
        }
    }

    private let stream: Stream?
    var captureManagedByWorkspace = false
    var requestDiscovery: (() -> Void)?
    var sourceFactory: ((DeviceLogSourceOption, DeviceLogSourceOption.Route, String?) -> DeviceLogRowSource?)?
    var selectedDeviceID: String? { selectedMachine?.id }
    private var presentsRows = true
    private var presentationNeedsRefresh = false
    private(set) var presentationUpdateCount = 0

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
        static let maximumProcessChoices = 512
        static let maximumSynchronousMatches = 2_048
        static let maximumProcessControlWidth: CGFloat = 200
        static let bluetoothTimeWidth: CGFloat = 112
        static let bluetoothProtocolWidth: CGFloat = 66
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

    private let devicePopUp = ThemedPopUp()
    private let sourcePopUp = ThemedPopUp()
    private let routePopUp = ThemedPopUp()
    private let levelPopUp = ThemedPopUp()
    private let processPopUp = ThemedPopUp()
    private let contextPopUp = ThemedPopUp()
    /// Bluetooth only, in the process chooser's place: every packet, or only those the project's
    /// definitions decoded. A view filter — the reader still records everything.
    private let packetPopUp = ThemedPopUp()
    private let filterField = ThemedTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var bluetoothProfileSetup = BluetoothProfileSetupView(preferredToolPath: preferredPymobiledevice3Path)
    private lazy var bluetoothSetupButton = ThemedButton(
        title: L10n.string("Set Up…"), target: self, action: #selector(toggleBluetoothSetup)
    )
    private var bluetoothSetupDeviceID: String?
    /// Every recorded try of a firmware update or other declared procedure. Bluetooth only.
    private lazy var timelinesButton: ThemedButton = {
        let button = ThemedButton(title: L10n.string("Timelines"), target: self, action: #selector(toggleTimelines))
        button.setAccessibilityIdentifier("bluetooth-timelines-button")
        button.toolTip = L10n.string("Firmware updates and other procedures, one timeline per try: how each ended and why.")
        return button
    }()
    private var timelinesPopover: ThemedPopover?
    private var timelineLoadGeneration = 0

    /// The "?" beside Set Up…: how to describe the app's own packets. Bluetooth only.
    private lazy var definitionsButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "questionmark.circle",
            accessibility: L10n.string("App packet definitions"),
            target: .inline
        )
        button.onPress = { [weak self] in self?.toggleDefinitionsHelp() }
        button.setAccessibilityIdentifier("bluetooth-definitions-help-button")
        return button
    }()
    private var definitionsPopover: ThemedPopover?
    private weak var definitionsHelp: BluetoothDefinitionsHelpViewController?
    /// The last load of the project's definitions file, from the reader or the "?" panel.
    private(set) var definitionStatus: BluetoothDefinitionStatus?
    private var definitionLoadGeneration = 0
    /// The definitions' `highlight:` words, drawn in their colour in the message column.
    private var definitionHighlights: [String: BluetoothHighlightColor] = [:]
    /// What devices taught through `learn:`, e.g. "AnimaCommand: 149 learned (Kronaby)".
    private var definitionLearned: String?
    /// Enum case names, declared and learned, drawn in a colour of their own.
    private var definitionNames: Set<String> = []
    /// The connection's GATT table: discovered live, remembered (assumed, stale), or none fitting.
    private var definitionGATT: String?
    /// The definitions' `logs:` rules; the workspace links this tab's rows to the other tab's.
    private(set) var logLinks: [BluetoothLogLink] = []
    /// A reader selected one row (not a fold); the workspace reveals its partner in the other tab.
    var onRowSelected: ((DeviceLogRow) -> Void)?
    /// Set while revealing a linked row, so the selection it makes is not linked back.
    private var revealingLinked = false
    private var definitionSummary: String {
        (definitionStatus?.summary ?? "") + (definitionLearned.map { " · " + $0 } ?? "")
            + (definitionGATT.map { " · " + $0 } ?? "")
    }
    /// Footer line naming the definitions file and whether it loaded: the standing hint of where
    /// the file goes, so it is discoverable without opening anything.
    private let definitionsLabel = NSTextField(labelWithString: "")
    /// The session's checkout, where `.threading/bluetooth.yaml` lives.
    let definitionsCheckout: String?
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

    /// Which machine's sources the source popup is showing. Held rather than derived, so a
    /// rescan that finds the same machines does not move the reader off the one being watched.
    private var selectedMachine: DeviceLogSourceOption.Machine?

    /// An explicit host route outranks the pane's current and recent selections once that machine
    /// appears in discovery. It remains pending while a temporarily disconnected device is
    /// absent, so the next rescan still lands where the user asked.
    private var requestedMachineID: String?

    /// The running source's title *within* its machine, used to re-find it after a rescan.
    private var runningSourceTitleWithinMachine: String?

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
    private var sourceGeneration = 0
    private var discoveryGeneration = 0
    private var savedLogColumnWidths: [NSUserInterfaceItemIdentifier: CGFloat]?
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
    private var agentHitOffset = 0
    private var filter = ""
    /// Whole-device Debug output is thousands of rows per second on a paired iPhone. Start at
    /// Info so the pane opens as a useful console; Debug remains one explicit menu choice away.
    private var minimumSeverity = 1
    private var selectedProcess: String?
    private(set) var packetFilter = BluetoothPacketFilter.all
    private var processChoices: [String] = []
    private var knownProcesses: Set<String> = []
    private var showingContext = false
    private var projectionGeneration = 0
    private var projectionTask: Task<Void, Never>?
    // Context projection scans on a worker. Its entries refer to this immutable snapshot until
    // the next result arrives, so a rolling capture cannot silently change the lines on screen.
    private var projectedRows: [DeviceLogRow]?
    private var projectedRowOffset = 0
    private var rowOffset = 0

    /// The controls, as the fold layout reads them. Built rather than stored so the two cannot
    /// drift: the filter field and the level chooser *are* the focus.
    private var focus: LogFocus {
        LogFocus(
            pattern: filter,
            minimumSeverity: minimumSeverity,
            context: DeviceLogLimits.foldContext,
            process: selectedProcess,
            subsystem: packetFilter == .all ? nil : BluetoothATTSession.appProtocolName,
            excluding: packetFilter == .complete ? BluetoothPacketFilter.problemMarker : nil
        )
    }
    private var drainTimer: Timer?
    private var boundsObserver: NSObjectProtocol?
    /// Whether new rows carry the view with them. True until the reader scrolls away, and true
    /// again the moment they come back to the bottom — so following is something you leave and
    /// rejoin rather than a mode you have to remember to switch.
    private var isFollowing = true
    private var updatingTable = false
    private var rateTimer: Timer?
    private var received = 0
    private var lastCount = 0
    private var rate = 0
    /// When the running source was started, so a source that connects and then says nothing can
    /// be told apart from one that simply has not been asked yet.
    private var startedAt: Date?

    /// The session this tab belongs to, kept so a predicate could later be scoped to its project.
    public let owningSessionID: String?

    /// The app-owned tool location. It may not exist when the pane is created: a later rescan
    /// picks up a Settings installation without requiring Threading or the plugin to restart.
    private let preferredPymobiledevice3Path: String?

    /// Writes what arrives to disk, so search and a time range have something to look at once the
    /// ring has moved on. One store per chat: two chats watching two devices are two histories.
    public let recorder: DeviceLogRecorder?

    public init(
        owningSessionID: String?,
        preferredPymobiledevice3Path: String? = nil,
        preferredMachineID: String? = nil,
        stream: Stream? = nil,
        definitionsCheckout: String? = nil
    ) {
        self.stream = stream
        self.definitionsCheckout = definitionsCheckout
        self.owningSessionID = owningSessionID
        self.preferredPymobiledevice3Path = preferredPymobiledevice3Path
        self.requestedMachineID = preferredMachineID
        self.recorder = DeviceLogRecorder(
            directory: Self.storeDirectory,
            name: (owningSessionID ?? "unattached") + (stream == .bluetooth ? "-bluetooth" : "")
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
        projectionTask?.cancel()
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
        rebuildMenus()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard !captureManagedByWorkspace else { return }
        startCapture()
    }

    func startCapture(discover: Bool = true) {
        guard drainTimer == nil else { return }
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
        if discover { reloadSources() }
        else { startSelectedSource() }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        guard !captureManagedByWorkspace else { return }
        stopCapture()
    }

    func stopCapture() {
        bluetoothProfileSetup.cancelBrowser()
        discoveryGeneration += 1
        sourceGeneration += 1
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

    func setRowsPresented(_ presented: Bool) {
        presentsRows = presented
        if !presented {
            if projectedRows == nil {
                projectedRows = rows
                projectedRowOffset = rowOffset
            }
            bluetoothProfileSetup.cancelBrowser()
            projectionGeneration += 1
            projectionTask?.cancel()
            projectionTask = nil
            presentationNeedsRefresh = true
            return
        }
        guard presentationNeedsRefresh else { return }
        presentationNeedsRefresh = false
        processPopUp.removeAllItems()
        processPopUp.addItem(withTitle: L10n.string("All processes"))
        processChoices.forEach { processPopUp.addItem(withTitle: $0) }
        processPopUp.selectItem(at: selectedProcess.flatMap { processChoices.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        recomputeVisible(backgroundContext: true)
        updateStatus()
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
    /// What to select when the pane opens, per machine.
    ///
    /// Deliberately separate from how the menu is *arranged*. Recents used to reorder the one flat
    /// list, which hoisted two apps above the simulator and the phone they belong to — the list
    /// stopped describing anything. Remembering a choice and ordering a menu are different jobs.
    private enum Recents {
        static let machineKey = "deviceLogRecentMachine"
        static let sourceKeyPrefix = "deviceLogRecentSource."

        static func machineID() -> String? {
            PreferenceStore.shared.string(forKey: machineKey)
        }

        static func rememberMachine(_ id: String) {
            PreferenceStore.shared.set(id, forKey: machineKey)
        }

        static func sourceTitle(forMachine id: String) -> String? {
            PreferenceStore.shared.string(forKey: sourceKeyPrefix + id)
        }

        static func rememberSource(_ title: String, forMachine id: String) {
            PreferenceStore.shared.set(title, forKey: sourceKeyPrefix + id)
        }
    }

    private func buildChrome() {
        // Two controls rather than one: the machine, then what to read from it. A single list put
        // one simulator, one phone and twenty-six of that phone's apps side by side as equals,
        // which reads as a jumble because it is one — an app is not a peer of the device it is
        // installed on.
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceChanged)
        devicePopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

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
        levelPopUp.selectItem(at: 1)
        levelPopUp.target = self
        levelPopUp.action = #selector(levelChanged)

        filterField.placeholderString = L10n.string("Filter log lines")
        filterField.delegate = self

        processPopUp.addItem(withTitle: L10n.string("All processes"))
        processPopUp.target = self
        processPopUp.action = #selector(processChanged)
        processPopUp.setAccessibilityIdentifier("device-log-process")
        processPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.maximumProcessControlWidth).isActive = true
        for filter in BluetoothPacketFilter.allCases { packetPopUp.addItem(withTitle: filter.title) }
        packetPopUp.target = self
        packetPopUp.action = #selector(packetFilterChanged)
        packetPopUp.setAccessibilityIdentifier("bluetooth-packet-filter")
        packetPopUp.isHidden = true
        contextPopUp.addItem(withTitle: L10n.string("Matches only"))
        contextPopUp.addItem(withTitle: L10n.string("Show context"))
        contextPopUp.target = self
        contextPopUp.action = #selector(contextChanged)
        contextPopUp.setAccessibilityIdentifier("device-log-context")

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

        bluetoothSetupButton.isHidden = true
        bluetoothSetupButton.setAccessibilityIdentifier("bluetooth-profile-setup")
        bluetoothProfileSetup.isHidden = true
        definitionsButton.isHidden = true
        timelinesButton.isHidden = true
        let bar = NSStackView(views: [devicePopUp, sourcePopUp, routePopUp, bluetoothSetupButton, definitionsButton, timelinesButton, rescan, clear])
        bar.setAccessibilityIdentifier("device-log-source-bar")
        bar.orientation = .horizontal
        bar.spacing = Design.Spacing.small
        bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.small,
            right: Design.Spacing.medium
        )
        let filters = NSStackView(views: [processPopUp, packetPopUp, levelPopUp, filterField, contextPopUp])
        filters.setAccessibilityIdentifier("device-log-filter-bar")
        filters.orientation = .horizontal
        filters.spacing = Design.Spacing.small
        filters.alignment = .centerY
        filters.edgeInsets = bar.edgeInsets
        for control in [devicePopUp, sourcePopUp, routePopUp, levelPopUp, processPopUp, packetPopUp, contextPopUp] as [NSView] + [bluetoothSetupButton, timelinesButton, rescan, clear, filterField] {
            control.heightAnchor.constraint(equalToConstant: Metrics.controlHeight).isActive = true
        }

        definitionsLabel.font = Design.Typography.compactCode()
        definitionsLabel.textColor = Design.Text.tertiary
        definitionsLabel.lineBreakMode = .byTruncatingMiddle
        definitionsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        definitionsLabel.setAccessibilityIdentifier("bluetooth-definitions-footer")
        definitionsLabel.isHidden = true
        let footer = NSStackView(views: [definitionsLabel, statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.tight,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.tight,
            right: Design.Spacing.medium
        )

        guard let scroll else { return }
        let stack = NSStackView(views: [bar, bluetoothProfileSetup, filters, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bluetoothProfileSetup.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        if let requestDiscovery { requestDiscovery(); return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        DeviceLogSourceCatalog.discover(
            preferredPymobiledevice3Path: preferredPymobiledevice3Path
        ) { [weak self] found in
            MainActor.assumeIsolated {
                guard let self, self.discoveryGeneration == generation else { return }
                self.acceptSources(found)
            }
        }
    }

    func acceptSources(_ found: [DeviceLogSourceOption]) {
        options = found.filter { stream?.includes($0) ?? true }
        rebuildMenus()
        if isVisibleForCapture { startSelectedSource() }
    }

    /// The machines, in discovery order, each appearing once.
    private var machines: [DeviceLogSourceOption.Machine] {
        var seen: Set<DeviceLogSourceOption.Machine> = []
        return options.compactMap { seen.insert($0.machine).inserted ? $0.machine : nil }
    }

    private func sources(of machine: DeviceLogSourceOption.Machine?) -> [DeviceLogSourceOption] {
        guard let machine else { return [] }
        return options.filter { $0.machine == machine }
    }

    /// Fills both popups and restores the selection.
    ///
    /// Populating must not read as a user choice: AppKit sends a popup's action as items are
    /// added, which restarted the stream on the wrong source.
    private func rebuildMenus() {
        let deviceAction = devicePopUp.action
        let sourceAction = sourcePopUp.action
        devicePopUp.action = nil
        sourcePopUp.action = nil
        defer {
            devicePopUp.action = deviceAction
            sourcePopUp.action = sourceAction
        }

        let machines = self.machines
        devicePopUp.removeAllItems()
        sourcePopUp.removeAllItems()

        guard !machines.isEmpty else {
            // An empty popup draws as a bare chevron, which does not read as a control at all —
            // the one place the pane most needs to look like somewhere you choose a device is the
            // case where it has not found one.
            devicePopUp.addItem(withTitle: L10n.string("No devices"))
            sourcePopUp.addItem(withTitle: L10n.string("No log sources"))
            devicePopUp.isEnabled = false
            sourcePopUp.isEnabled = false
            selectedMachine = nil
            updateRouteVisibility()
            return
        }
        devicePopUp.isEnabled = true
        sourcePopUp.isEnabled = true

        // A rescan looks for machines; it is not a request to change the one being read. Keep the
        // current machine when it survived, so plugging a phone in does not yank the pane off the
        // simulator it was watching.
        let requestedMachine = requestedMachineID.flatMap { requestedID in
            machines.first { $0.id == requestedID }
        }
        let machine = requestedMachine
            ?? machines.first { $0 == selectedMachine }
            ?? machines.first { $0.id == Recents.machineID() }
            ?? machines[0]
        if requestedMachine != nil { requestedMachineID = nil }
        selectedMachine = machine
        machines.forEach { devicePopUp.addItem(withTitle: $0.title) }
        devicePopUp.selectItem(at: machines.firstIndex(of: machine) ?? 0)

        let sources = self.sources(of: machine)
        sources.forEach { sourcePopUp.addItem(withTitle: $0.title) }
        // By title within the machine rather than by a remembered index: the list changes shape
        // whenever an app is installed or removed, and an index would then name something else.
        let wanted = Recents.sourceTitle(forMachine: recentMachineKey(machine.id))
        let keep = sources.firstIndex { $0.title == runningSourceTitleWithinMachine }
            ?? sources.firstIndex { $0.title == wanted }
            ?? 0
        sourcePopUp.selectItem(at: keep)
        updateRouteVisibility()
    }

    /// The route chooses between an app's two logs, so it belongs to the *selection* rather than
    /// to starting a reader. Setting it only on start left "App log" standing beside a simulator,
    /// which has one log and no choice to make — a control offering a decision that does not
    /// exist.
    private func updateRouteVisibility() {
        let isBluetooth: Bool
        if let option = selectedOption, case .bluetooth = option.kind { isBluetooth = true }
        else { isBluetooth = stream == .bluetooth }
        processPopUp.isHidden = isBluetooth
        packetPopUp.isHidden = !isBluetooth
        if !isBluetooth, packetFilter != .all {
            // Only Bluetooth rows carry the App subsystem; elsewhere the filter would hide all.
            packetFilter = .all
            packetPopUp.selectItem(at: BluetoothPacketFilter.all.rawValue)
            recomputeVisible()
        }
        let setupTarget: BluetoothProfileSetupView.Target?
        if let option = selectedOption, case .bluetooth(let udid, _, _) = option.kind {
            setupTarget = .init(deviceID: udid, title: option.machine.title)
        } else {
            setupTarget = nil
        }
        bluetoothSetupButton.isHidden = setupTarget == nil
        definitionsButton.isHidden = !isBluetooth
        timelinesButton.isHidden = !isBluetooth
        definitionsLabel.isHidden = !isBluetooth
        if isBluetooth, definitionStatus == nil { loadDefinitionStatus() }
        if bluetoothSetupDeviceID != setupTarget?.deviceID || !isBluetooth {
            bluetoothProfileSetup.isHidden = true
        }
        bluetoothSetupDeviceID = setupTarget?.deviceID
        bluetoothProfileSetup.configure(target: setupTarget)
        updateBluetoothColumns(isBluetooth: isBluetooth)
        guard let option = selectedOption else {
            routePopUp.isHidden = true
            return
        }
        if case .app = option.kind {
            routePopUp.isHidden = false
        } else {
            routePopUp.isHidden = true
        }
    }

    @objc private func toggleBluetoothSetup() {
        guard let option = selectedOption, case .bluetooth = option.kind else { return }
        bluetoothProfileSetup.isHidden.toggle()
        if bluetoothProfileSetup.isHidden { bluetoothProfileSetup.cancelBrowser() }
    }

    // MARK: Packet definitions

    private func toggleDefinitionsHelp() {
        if let definitionsPopover, definitionsPopover.isShown {
            definitionsPopover.close()
            return
        }
        let help = BluetoothDefinitionsHelpViewController(
            status: definitionStatus ?? (definitionsCheckout == nil ? .noCheckout : .missing(
                expected: BluetoothDefinitionsFile.candidates(checkout: definitionsCheckout)[0]
            ))
        )
        help.onFileCreated = { [weak self] in self?.loadDefinitionStatus() }
        help.onForgetRememberedTables = { [weak self] in self?.forgetRememberedGATTTables() }
        let popover = ThemedPopover()
        popover.behavior = .transient
        popover.contentViewController = help
        popover.initialFirstResponder = help.view
        popover.onClose = { [weak self] in self?.definitionsPopover = nil }
        definitionsPopover = popover
        definitionsHelp = help
        popover.show(relativeTo: definitionsButton.bounds, of: definitionsButton, preferredEdge: .maxY)
        // The reader reports changes while it runs; without one, read the file now so the panel
        // describes the file as it is rather than as it was.
        loadDefinitionStatus()
    }

    // MARK: Timelines

    @objc private func toggleTimelines() {
        if let timelinesPopover, timelinesPopover.isShown {
            timelinesPopover.close()
            return
        }
        timelineLoadGeneration += 1
        let generation = timelineLoadGeneration
        Task { [weak self] in
            // The worker saves within a second of a change; reading the file off the main actor
            // is what a capture that is not running has too.
            let history = await Task.detached(priority: .userInitiated) { BluetoothProcedureHistory.load() }.value
            guard let self, self.timelineLoadGeneration == generation else { return }
            self.presentTimelines(history)
        }
    }

    private func presentTimelines(_ history: BluetoothProcedureHistory) {
        let panel = BluetoothTimelineViewController(history: history)
        panel.onClear = { [weak self] in self?.clearProcedureHistory() }
        let popover = ThemedPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        popover.initialFirstResponder = panel.view
        popover.onClose = { [weak self] in self?.timelinesPopover = nil }
        timelinesPopover = popover
        popover.show(relativeTo: timelinesButton.bounds, of: timelinesButton, preferredEdge: .maxY)
    }

    /// Forgets every recorded try: on the running capture's worker, else the file off the main actor.
    func clearProcedureHistory() {
        if let bluetooth = source as? BluetoothLogRowSource {
            bluetooth.clearProcedureHistory()
        } else {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: BluetoothProcedureHistory.defaultURL)
            }
        }
    }

    /// Drops what earlier captures taught about devices' GATT tables. A running capture forgets
    /// on its worker; otherwise the file is removed off the main actor.
    func forgetRememberedGATTTables() {
        definitionGATT = nil
        definitionsLabel.stringValue = definitionSummary
        if let bluetooth = source as? BluetoothLogRowSource {
            bluetooth.forgetRememberedGATTTables()
        } else {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: BluetoothGATTTables.defaultURL)
            }
        }
    }

    /// Reads the file off the main actor; the reader's own reports stay authoritative while it runs.
    private func loadDefinitionStatus() {
        definitionLoadGeneration += 1
        let generation = definitionLoadGeneration
        let checkout = definitionsCheckout
        Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                let (definitions, status) = BluetoothDefinitionsFile.load(checkout: checkout)
                let enums = definitions?.learnedEnumNames ?? []
                let learned = enums.isEmpty ? BluetoothLearnedEnums() : BluetoothLearnedEnums.load()
                return BluetoothDefinitionReport(
                    status: status, highlights: definitions?.highlights ?? [:],
                    learned: learned.summary(enums: enums), names: learned.names(definitions: definitions),
                    logLinks: definitions?.logLinks ?? []
                )
            }.value
            guard let self, self.definitionLoadGeneration == generation else { return }
            self.logLinks = report.logLinks
            self.applyDefinitionStatus(report.status, highlights: report.highlights, learned: report.learned,
                                       names: report.names, gatt: report.gatt)
        }
    }

    private func applyDefinitionStatus(
        _ status: BluetoothDefinitionStatus, highlights: [String: BluetoothHighlightColor] = [:],
        learned: String? = nil, names: Set<String> = [], gatt: String? = nil
    ) {
        definitionStatus = status
        definitionLearned = learned
        // The off-main file load knows nothing of the capture's tables; keep the worker's line.
        if gatt != nil || source == nil { definitionGATT = gatt }
        if highlights != definitionHighlights || names != definitionNames {
            definitionHighlights = highlights
            definitionNames = names
            table.reloadData()
        }
        definitionsLabel.stringValue = definitionSummary
        definitionsLabel.toolTip = status.url?.path
        definitionsLabel.textColor = status.isFailure ? Design.Status.warning : Design.Text.tertiary
        definitionsHelp?.apply(status)
    }

    #if DEBUG
    func showBluetoothProfileBrowserForTesting() {
        bluetoothProfileSetup.isHidden = false
        bluetoothProfileSetup.showBrowserForTesting()
    }

    func setLogLinksForTesting(_ links: [BluetoothLogLink]) { logLinks = links }

    var selectedHeldRowForTesting: DeviceLogRow? {
        let selected = table.selectedRow
        guard entries.indices.contains(selected), case .row(let index) = entries[selected] else { return nil }
        return heldRows.indices.contains(index) ? heldRows[index] : nil
    }

    func selectHeldRowAsReaderForTesting(_ index: Int) {
        guard let position = entries.firstIndex(where: { if case .row(index) = $0 { return true } else { return false } }) else { return }
        table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
    }

    func applyDefinitionStatusForTesting(
        _ status: BluetoothDefinitionStatus, highlights: [String: BluetoothHighlightColor] = [:],
        learned: String? = nil, names: Set<String> = [], gatt: String? = nil
    ) {
        applyDefinitionStatus(status, highlights: highlights, learned: learned, names: names, gatt: gatt)
    }
    #endif

    private func updateBluetoothColumns(isBluetooth: Bool) {
        guard isBluetooth != (savedLogColumnWidths != nil) else { return }
        if isBluetooth {
            savedLogColumnWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier, $0.width) })
            table.tableColumn(withIdentifier: Columns.process)?.isHidden = true
            table.tableColumn(withIdentifier: Columns.time)?.width = Metrics.bluetoothTimeWidth
            table.tableColumn(withIdentifier: Columns.subsystem)?.width = Metrics.bluetoothProtocolWidth
        } else {
            table.tableColumn(withIdentifier: Columns.process)?.isHidden = false
            for column in table.tableColumns {
                if let width = savedLogColumnWidths?[column.identifier] { column.width = width }
            }
            savedLogColumnWidths = nil
        }
        scroll?.hasHorizontalScroller = isBluetooth
    }

    @objc private func deviceChanged() {
        let machines = self.machines
        let index = devicePopUp.indexOfSelectedItem
        guard machines.indices.contains(index) else { return }
        selectedMachine = machines[index]
        Recents.rememberMachine(machines[index].id)
        rebuildMenus()
        startSelectedSource()
    }

    /// Points this singleton pane at the machine named by a host affordance. Discovery owns the
    /// available machine objects; this method carries only stable identity and lets the ordinary
    /// menu/source path perform the switch so rows, recents and reader lifetime stay coherent.
    public func selectMachine(id: String) {
        guard !id.isEmpty else { return }
        requestedMachineID = id
        guard isViewLoaded, machines.contains(where: { $0.id == id }) else { return }
        let wasReading = source != nil
        rebuildMenus()
        if wasReading { startSelectedSource() }
    }

    /// Same selection/start path as the source menu, with exact phone identity for agent calls.
    public func selectBluetooth(deviceID: String) -> Bool {
        guard let option = options.first(where: {
            guard $0.machine.id == deviceID else { return false }
            if case .bluetooth = $0.kind { return true }
            return false
        }) else { return false }
        requestedMachineID = deviceID
        rebuildMenus()
        let sources = self.sources(of: selectedMachine)
        guard let index = sources.firstIndex(of: option) else { return false }
        sourcePopUp.selectItem(at: index)
        levelPopUp.selectItem(at: 0)
        applyFocus(pattern: "", minimumSeverity: 0)
        startSelectedSource()
        return true
    }

    public var readerStatus: String {
        // An agent writing `.threading/bluetooth.yaml` needs to read back whether it loaded and
        // which line it stopped at; the footer says so to a person, this says it to the agent.
        guard !definitionsLabel.isHidden, let definitionStatus else { return statusLabel.stringValue }
        let location = definitionStatus.url.map { " (\($0.path))" } ?? ""
        return statusLabel.stringValue + "\n" + definitionSummary + location
    }
    public var isVisibleForCapture: Bool { drainTimer != nil }

    /// The selected source, resolved through the machine rather than through a flat index.
    private var selectedOption: DeviceLogSourceOption? {
        let sources = self.sources(of: selectedMachine)
        let index = sourcePopUp.indexOfSelectedItem
        guard sources.indices.contains(index) else { return nil }
        return sources[index]
    }

    private func startSelectedSource() {
        guard let option = selectedOption else {
            sourceGeneration += 1
            source?.stop()
            source = nil
            updateStatus()
            return
        }
        // The route only means something for an app; a device's system log has just the one.
        var isApp = false
        if case .app = option.kind { isApp = true }
        updateRouteVisibility()
        if case .bluetooth = option.kind {
            // HCI packets have no app PID; an inherited process filter must not hide them.
            selectedProcess = nil
            processPopUp.selectItem(at: 0)
        }
        // Scoped to the machine, because two phones both offer a "System log" and only the
        // machine tells them apart. A bare title would make switching between them look like
        // staying put, and the pane would never restart the reader.
        let identity = "\(option.machine.id)/\(option.title)" + (isApp ? "#\(route.rawValue)" : "")
            + (selectedProcess.map { "#process=\($0)" } ?? "")
        // Already reading this one: restarting would throw away every row read so far.
        guard identity != runningSourceTitle || source == nil || endedReason != nil else { return }
        // Resuming the same source after the pane was hidden keeps what is on screen. Only a
        // genuine change of source discards it, because those rows are no longer about the thing
        // being read. Resuming does leave a gap where the pane was not listening, which is honest
        // for a live tail and better than an empty pane.
        let isSameSource = identity == runningSourceTitle
        runningSourceTitle = identity
        runningSourceTitleWithinMachine = option.title
        Recents.rememberMachine(option.machine.id)
        Recents.rememberSource(option.title, forMachine: recentMachineKey(option.machine.id))

        sourceGeneration += 1
        let generation = sourceGeneration
        source?.stop()
        if !isSameSource {
            clearRows()
            received = 0
            lastCount = 0
            table.reloadData()
        }

        endedReason = nil
        let reader: DeviceLogRowSource?
        if let sourceFactory { reader = sourceFactory(option, route, selectedProcess) }
        else { reader = option.makeSource(predicate: nil, route: route, processName: selectedProcess) }
        guard let started = reader else {
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
                    guard let self, self.sourceGeneration == generation else { return }
                    self.endedReason = reason
                    self.updateStatus()
                }
            }
        }
        if let bluetooth = started as? BluetoothLogRowSource {
            bluetooth.definitionsCheckout = definitionsCheckout
            let apply: @MainActor @Sendable (BluetoothDefinitionReport) -> Void = { [weak self] report in
                guard let self, self.sourceGeneration == generation else { return }
                self.logLinks = report.logLinks
                self.applyDefinitionStatus(report.status, highlights: report.highlights, learned: report.learned,
                                       names: report.names, gatt: report.gatt)
            }
            bluetooth.onDefinitionsChanged = { report in
                DispatchQueue.main.async { MainActor.assumeIsolated { apply(report) } }
            }
        }
        source = started
        started.start()
        startedAt = Date()
        updateStatus()
    }

    private func recentMachineKey(_ id: String) -> String {
        stream == .bluetooth ? id + ".bluetooth" : id
    }

    @objc private func sourceChanged() {
        updateRouteVisibility()
        startSelectedSource()
    }

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

    @objc private func packetFilterChanged() {
        setPacketFilter(BluetoothPacketFilter(rawValue: packetPopUp.indexOfSelectedItem) ?? .all)
    }

    /// Shows only rows the project's definitions decoded, optionally only those whose bytes fit
    /// their definition exactly. Recorded history is unaffected.
    func setPacketFilter(_ filter: BluetoothPacketFilter) {
        packetFilter = filter
        packetPopUp.selectItem(at: filter.rawValue)
        expandedGaps.removeAll()
        clearAgentNote()
        recomputeVisible()
        table.reloadData()
        updateStatus()
    }

    @objc private func processChanged() {
        let index = processPopUp.indexOfSelectedItem - 1
        selectedProcess = processChoices.indices.contains(index) ? processChoices[index] : nil
        expandedGaps.removeAll()
        clearAgentNote()
        recomputeVisible()
        table.reloadData()
        updateStatus()
        // Scope the reader before its bounded queue and recording, not just the visible table.
        // A quiet app must not lose its retained history to thousands of unrelated system rows.
        if source != nil { startSelectedSource() }
    }

    @objc private func contextChanged() {
        showingContext = contextPopUp.indexOfSelectedItem == 1
        expandedGaps.removeAll()
        clearAgentNote()
        recomputeVisible(backgroundContext: true)
        table.reloadData()
        updateStatus()
    }

    /// Incremental, capped discovery; never rebuild a menu for every log tick.
    private func discoverProcesses(in batch: [DeviceLogRow]) {
        for row in batch where processChoices.count < Metrics.maximumProcessChoices {
            guard !row.process.isEmpty, knownProcesses.insert(row.process).inserted else { continue }
            processChoices.append(row.process)
            if presentsRows { processPopUp.addItem(withTitle: row.process) }
        }
    }

    @objc private func clearRows() {
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        rowOffset = 0
        projectedRows = nil
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
        projectedRows = nil
        rows = fixture
        received = fixture.count
        discoverProcesses(in: fixture)
        filter = pattern
        filterField.stringValue = pattern
        entries = LogFocusLayout.entries(rows: rows, focus: focus, showingContext: showingContext)
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
        showingContext = true
        contextPopUp.selectItem(at: 1)
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
        agentHitOffset = rowOffset
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

    /// Fill both popups without discovery, so the control bar can be drawn and reviewed. Discovery
    /// spawns child processes and takes tens of seconds, which no render test should wait for.
    public func installSourcesForTesting(_ fixture: [DeviceLogSourceOption]) {
        options = fixture.filter { stream?.includes($0) ?? true }
        rebuildMenus()
    }

    public var isRouteControlHiddenForTesting: Bool { routePopUp.isHidden }
    public var isProcessControlHiddenForTesting: Bool { processPopUp.isHidden }
    public var selectedMachineIDForTesting: String? { selectedMachine?.id }

    public var agentNoteForTesting: String? { agentNote }
    public var agentHitsForTesting: Set<Int> { agentHits }
    public var statusTextForTesting: String { statusLabel.stringValue }
    public var isProjectingForTesting: Bool { projectionTask != nil }
    public func selectProcessForTesting(_ process: String?) {
        processPopUp.selectItem(at: process.flatMap { processChoices.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        processChanged()
    }

    /// Drives the same path a keystroke in the filter field takes.
    public func simulateUserFilterEditForTesting(_ text: String) {
        filterField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    /// What is on screen right now, for a tool that has to answer for it.
    public var focusSummary: (shown: Int, folded: Int, total: Int) {
        let folded = entries.reduce(0) { $0 + $1.hiddenCount }
        let shown = entries.reduce(0) { count, entry in
            if case .row = entry { return count + 1 }
            return count
        }
        return (shown, folded, rows.count)
    }

    /// The rows currently visible, newest last, for a tool asked what is on screen.
    /// Every row this tab holds, in time order: the ring the reader can scroll.
    var heldRows: [DeviceLogRow] { projectedRows ?? rows }

    /// Selects and scrolls to a held row — opening the fold it is in — without linking it back.
    @discardableResult
    func reveal(heldRow index: Int) -> Bool {
        let displayed = projectedRows ?? rows
        guard displayed.indices.contains(index) else { return false }
        let offset = projectedRows == nil ? rowOffset : projectedRowOffset
        if let position = displayIndex(containing: index), case .gap(let range) = entries[position] {
            expandedGaps.insert(range.lowerBound + offset)
            entries = LogFocusLayout.entries(rows: displayed, focus: focus, expanded: expandedGaps(at: offset))
            table.reloadData()
        }
        guard let position = displayIndex(containing: index), case .row = entries[position] else { return false }
        revealingLinked = true
        defer { revealingLinked = false }
        isFollowing = false
        table.selectRowIndexes(IndexSet(integer: position), byExtendingSelection: false)
        table.scrollRowToVisible(position)
        updateFollowAffordance()
        return true
    }

    public func visibleRowsForTools(limit: Int) -> [DeviceLogRow] {
        let displayed = projectedRows ?? rows
        return entries.suffix(limit).compactMap { entry in
            if case .row(let index) = entry, displayed.indices.contains(index) { return displayed[index] }
            return nil
        }
    }

    // MARK: Filtering

    private var isFiltering: Bool { focus.isActive }

    private func expandedGaps(at offset: Int) -> Set<Int> {
        Set(expandedGaps.compactMap { $0 >= offset ? $0 - offset : nil })
    }

    private func recomputeVisible(backgroundContext: Bool = false) {
        projectionGeneration += 1
        let generation = projectionGeneration
        projectionTask?.cancel()
        projectionTask = nil
        // The legacy agent focus keeps its synchronous receipt contract. User filtering scans
        // the fixed 50k ring off-main; ordinary streaming below tests only incoming rows.
        if showingContext && !backgroundContext {
            entries = LogFocusLayout.entries(rows: rows, focus: focus, expanded: expandedGaps(at: rowOffset))
            projectedRows = rows
            projectedRowOffset = rowOffset
            return
        }
        if projectedRows == nil {
            projectedRows = rows
            projectedRowOffset = rowOffset
        }
        let snapshot = rows
        let selectedFocus = focus
        let offset = rowOffset
        let context = showingContext
        let expanded = expandedGaps(at: offset)
        projectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                if context {
                    return LogFocusLayout.entries(rows: snapshot, focus: selectedFocus, expanded: expanded)
                }
                var result: [LogDisplayEntry] = []
                for index in snapshot.indices {
                    if index % 128 == 0, Task.isCancelled { return result }
                    if selectedFocus.matches(snapshot[index]) { result.append(.row(index)) }
                }
                return result
            }
            let projected = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.projectionGeneration == generation else { return }
            let oldOffset = self.projectedRows == nil ? self.rowOffset : self.projectedRowOffset
            let selectedLines = self.table.selectedRowIndexes.compactMap { position -> Int? in
                guard self.entries.indices.contains(position), case .row(let index) = self.entries[position] else { return nil }
                return oldOffset + index
            }
            let first = self.table.rows(in: self.table.visibleRect).location
            let anchor = self.entries.indices.contains(first) ? self.entryStart(self.entries[first]) + oldOffset : nil
            let oldOrigin = self.scroll?.contentView.bounds.origin ?? .zero
            let pitch = self.table.rowHeight + self.table.intercellSpacing.height
            self.entries = projected
            self.projectedRows = snapshot
            self.presentationNeedsRefresh = false
            self.projectedRowOffset = offset
            self.projectionTask = nil
            let selection = IndexSet(selectedLines.compactMap { line -> Int? in
                guard let position = self.displayIndex(containing: line - offset),
                      case .row = self.entries[position] else { return nil }
                return position
            })
            let origin = anchor.flatMap { self.displayIndex(containing: $0 - offset) }.map {
                NSPoint(x: oldOrigin.x, y: max(0, oldOrigin.y + CGFloat($0 - first) * pitch))
            }
            if self.presentsRows { self.refreshStreamingTable(selection: selection, origin: origin) }
            self.updateStatus()
            // Publish each completed snapshot, then catch up. Discarding every result
            // when more rows arrived would starve a busy device's view indefinitely.
            if self.rowOffset != offset || self.rows.count != snapshot.count {
                self.recomputeVisible(backgroundContext: true)
            } else if !context {
                self.projectedRows = nil
            }
        }
    }

    // MARK: Streaming

    /// One batch per tick. The bottom stays pinned only when it was already pinned, so scrolling
    /// back to read something is not fought by the stream.
    func drain() {
        guard let source else { return }
        let incoming = source.drain()
        guard !incoming.isEmpty else { return }
        received += incoming.count
        discoverProcesses(in: incoming)
        // On disk as well as on screen: the ring is what the table can hold, the store is what a
        // question can reach back through once the ring has moved on.
        recorder?.record(incoming)

        let projectBurst = !showingContext && isFiltering && incoming.count > Metrics.maximumSynchronousMatches
        if presentsRows, projectBurst, projectedRows == nil {
            projectedRows = rows
            projectedRowOffset = rowOffset
        }
        let previousCount = rows.count
        rows.append(contentsOf: incoming)
        let removedCount = max(0, rows.count - DeviceLogLimits.ringCapacity)
        let removedEntries = entries.prefix { entry in
            guard case .row(let index) = entry else { return false }
            return index < removedCount
        }.count
        rowOffset += removedCount
        if rows.count > DeviceLogLimits.ringCapacity {
            rows.removeFirst(rows.count - DeviceLogLimits.ringCapacity)
        }

        guard presentsRows, projectionTask == nil else {
            presentationNeedsRefresh = true
            return
        }
        presentationUpdateCount += 1

        if (showingContext && isFiltering) || projectBurst {
            recomputeVisible(backgroundContext: true)
            return
        }
        projectedRows = nil

        if !showingContext {
            // Strict mode tests new rows only. Old matches shift with the ring; a whole-ring
            // text scan at every 100 ms tick would make a quieter view cost more CPU.
            entries = entries.compactMap { entry in
                guard case .row(let index) = entry, index >= removedCount else { return nil }
                return .row(index - removedCount)
            }
            let selectedFocus = focus
            for index in max(0, previousCount - removedCount)..<rows.count where selectedFocus.matches(rows[index]) {
                entries.append(.row(index))
            }
        } else {
            entries = rows.indices.map { .row($0) }
        }

        // Strict/unfiltered streams only remove entries at the head. Keep the reader's
        // selected lines and paused viewport attached to those surviving entries.
        refreshStreamingTable(removing: removedEntries)
    }

    private func entryStart(_ entry: LogDisplayEntry) -> Int {
        switch entry {
        case .row(let index): return index
        case .gap(let range): return range.lowerBound
        }
    }

    /// Entries are ordered, so restoring a selected line or viewport anchor never scans the ring.
    private func displayIndex(containing row: Int) -> Int? {
        guard row >= 0, !entries.isEmpty else { return nil }
        var lower = 0, upper = entries.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if entryStart(entries[middle]) <= row { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let position = lower - 1
        switch entries[position] {
        case .row(let index): return index == row ? position : nil
        case .gap(let range): return range.contains(row) ? position : nil
        }
    }

    private func refreshStreamingTable(removing removedEntries: Int = 0,
                                       selection: IndexSet? = nil, origin restoredOrigin: NSPoint? = nil) {
        updatingTable = true
        defer { updatingTable = false }
        let selected = table.selectedRowIndexes
        let origin = scroll?.contentView.bounds.origin ?? .zero
        // reloadData destroys every visible row and its cells. A live tail needs only its
        // count and the text in the existing viewport to change, including at a full ring.
        table.noteNumberOfRowsChanged()
        if let selection {
            table.selectRowIndexes(selection, byExtendingSelection: false)
        } else if removedEntries > 0 {
            let surviving = IndexSet(selected.compactMap { index in
                index >= removedEntries ? index - removedEntries : nil
            })
            table.selectRowIndexes(surviving, byExtendingSelection: false)
        }
        if isFollowing, !entries.isEmpty {
            table.scrollRowToVisible(entries.count - 1)
        } else if let restoredOrigin, let scroll {
            scroll.contentView.scroll(to: restoredOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if removedEntries > 0, let scroll {
            let pitch = table.rowHeight + table.intercellSpacing.height
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y - CGFloat(removedEntries) * pitch)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            let selectedFocus = focus
            for row in visible.location..<min(NSMaxRange(visible), entries.count) {
                for (column, definition) in table.tableColumns.enumerated() where !definition.isHidden {
                    guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
                        as? ThemedTableTextCell else { continue }
                    configure(cell, column: definition.identifier, row: row, focus: selectedFocus)
                }
            }
        }
        updateFollowAffordance()
    }

    /// The reader moved the view. Leaving the bottom stops the follow; arriving back resumes it.
    private func scrollPositionChanged() {
        guard !updatingTable else { return }
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
        guard presentsRows else { return }
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
            if let option = selectedOption, case .bluetooth = option.kind {
                statusLabel.stringValue = appending(L10n.string("Waiting for Bluetooth packets. Check the iPhone logging profile and generate Bluetooth activity."))
            } else {
                statusLabel.stringValue = appending(L10n.string("Connected, but no log lines yet."))
            }
            statusLabel.textColor = Design.Status.warning
            return
        }
        statusLabel.textColor = Design.Text.secondary
        let folded = entries.reduce(0) { $0 + $1.hiddenCount }
        let shown = focusSummary.shown
        var parts = [isFiltering ? "\(shown)/\(rows.count)" : "\(rows.count)"]
        if folded > 0 { parts.append("\(folded) folded") }
        parts.append("\(rate)/s")
        if let dropped = source?.dropped, dropped > 0 { parts.append("⚠︎ \(dropped)") }
        if packetFilter != .all, shown == 0 {
            // An empty table under "App packets only" is nearly always a missing or broken file,
            // or characteristics that have not matched yet; say which rather than show nothing.
            switch definitionStatus {
            case .loaded?:
                parts.append(L10n.string("no packets matched a defined characteristic yet"))
            default:
                parts.append(L10n.string("no packet definitions loaded — see ?"))
            }
        }
        if let agentNote { parts.append(agentNote) }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }
}

// MARK: - Filter field

extension DeviceLogPaneViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        // The person is driving again, so the agent's note stops describing what they are seeing.
        clearAgentNote()
        showingContext = false
        contextPopUp.selectItem(at: 0)
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
            as? ThemedTableTextCell ?? ThemedTableTextCell()
        host.identifier = identifier
        configure(host, column: identifier, row: row, focus: focus)
        return host
    }

    private func configure(_ host: ThemedTableTextCell, column identifier: NSUserInterfaceItemIdentifier,
                           row: Int, focus: LogFocus) {
        let label = host.label
        var font: Design.FontRole = .compactCode

        switch entries[row] {
        case .gap(let range):
            // A fold says how much is inside it, in the message column only — a count in the time
            // column would read as a time.
            label.stringValue = identifier == Columns.message
                ? "\(range.count) more \(range.count == 1 ? "row" : "rows") — click to show"
                : ""
            label.textColor = Design.Text.tertiary
        case .row(let index):
            let displayed = projectedRows ?? rows
            guard displayed.indices.contains(index) else { label.stringValue = ""; return }
            let entry = displayed[index]
            label.stringValue = text(for: entry, column: identifier)
            label.textColor = ink(for: entry, column: identifier)
            // A row the agent's search matched, marked in the time column: a stripe down the left
            // that does not collide with the message weight a focus match already carries.
            //
            // Weight as well as colour, because colour alone did not work — an error row already
            // draws its clock in the accent, so a hit on an error was indistinguishable from the
            // error, and only a rendered picture showed it.
            let displayedOffset = projectedRows == nil ? rowOffset : projectedRowOffset
            if agentHits.contains(index + displayedOffset - agentHitOffset), identifier == Columns.time {
                label.textColor = AppThemePalette.color(.accent)
                font = .emphasizedCompactCode
            }
            // The match is why the fold opened around it, so it is what the eye should land on.
            if focus.isActive, focus.matches(entry), identifier == Columns.message {
                // Same metrics as the rows around it, heavier ink: a bolder weight at the same size
                // keeps the column aligned, which a larger one would not.
                font = .emphasizedCompactCode
            }
        }
        label.applyFont(font)
        label.toolTip = label.stringValue
        if identifier == Columns.message, case .row(let index) = entries[row] {
            let displayed = projectedRows ?? rows
            if displayed.indices.contains(index) { colorize(label, entry: displayed[index]) }
        }
    }

    /// Draws the message's structure: grammar in theme syntax colours, scaffolding dimmed, the
    /// project's `highlight:` words in theirs. Errors keep one warning colour so they still read
    /// as errors at a glance. Viewport rows only, each bounded by `LogMessageHighlighter.Limits`.
    private func colorize(_ label: NSTextField, entry: DeviceLogRow) {
        guard entry.severity < 3, let font = label.font else { return }
        let kind: LogMessageHighlighter.Kind
        if entry.process == "Bluetooth" {
            kind = entry.subsystem == BluetoothATTSession.appProtocolName ? .bluetoothApp : .bluetooth
        } else {
            kind = .plain
        }
        let spans = LogMessageHighlighter.spans(
            entry.message, kind: kind, highlights: definitionHighlights, names: definitionNames
        )
        guard !spans.isEmpty else { return }
        let text = NSMutableAttributedString(string: entry.message, attributes: [
            .font: font, .foregroundColor: label.textColor ?? Design.Text.label,
        ])
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for span in spans {
            text.addAttribute(.foregroundColor, value: Self.color(for: span.style), range: span.range)
            if span.style == .characteristic { text.addAttribute(.font, value: bold, range: span.range) }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = label.lineBreakMode
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
    }

    private static func color(for style: LogMessageStyle) -> NSColor {
        switch style {
        case .direction(let received): received ? Design.Syntax.type : Design.Syntax.keyword
        case .route, .verb, .key: Design.Text.secondary
        case .characteristic: Design.Text.label
        case .punctuation: Design.Text.tertiary
        case .preview: Design.Syntax.comment
        case .string: Design.Syntax.string
        case .number: Design.Syntax.number
        case .constant: Design.Syntax.keyword
        case .uuid: Design.Syntax.type
        case .warning: Design.Status.warning
        case .named(let name): NameColor.color(for: name)
        case .custom(let color):
            switch color {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .teal: .systemTeal
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .pink: .systemPink
            case .gray: .systemGray
            }
        }
    }

    /// Opening a fold is a click on it, which is the only affordance a folded run needs.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingTable else { return }
        let selected = table.selectedRow
        guard entries.indices.contains(selected) else { return }
        if case .row(let index) = entries[selected] {
            let displayed = projectedRows ?? rows
            if !revealingLinked, table.selectedRowIndexes.count == 1, displayed.indices.contains(index) {
                onRowSelected?(displayed[index])
            }
            return
        }
        guard case .gap(let range) = entries[selected] else { return }
        let offset = projectedRows == nil ? rowOffset : projectedRowOffset
        expandedGaps.insert(range.lowerBound + offset)
        let displayed = projectedRows ?? rows
        entries = LogFocusLayout.entries(rows: displayed, focus: focus, expanded: expandedGaps(at: offset))
        // A result already in flight was computed before the fold opened.
        if projectionTask != nil { recomputeVisible(backgroundContext: true) }
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

// MARK: - Bluetooth packet filter

/// The Bluetooth tab's packet chooser. Raw values are the menu's item order.
enum BluetoothPacketFilter: Int, CaseIterable, Sendable {
    /// Every HCI, L2CAP and ATT row.
    case all
    /// Rows the project's definitions decoded, including ones whose bytes did not fit.
    case app
    /// Decoded rows whose bytes fit their definition exactly: a misfit is logged at Warning.
    case complete

    /// What a row whose bytes did not fit its definition says, and what "Fully decoded only" hides.
    static let problemMarker = BluetoothATTSession.problemMarker

    var title: String {
        switch self {
        case .all: L10n.string("All packets")
        case .app: L10n.string("App packets only")
        case .complete: L10n.string("Fully decoded only")
        }
    }

    /// The device-log `focus` tool's `packets` argument.
    var toolName: String {
        switch self {
        case .all: "all"
        case .app: "app"
        case .complete: "complete"
        }
    }
}
