import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

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
    var requestSourceRefresh: (() -> Void)?
    private var sourceCatalogPending = false
    private var sourceCatalogUpdatedAt: Date?
    var sourceFactory: ((DeviceLogSourceOption, DeviceLogSourceOption.Route, String?) -> DeviceLogRowSource?)?
    var selectedDeviceID: String? { selectedMachine?.id }
    private var responsiveBars: [(bar: NSStackView, groups: [NSStackView])] = []
    private var narrowBarConstraints: [NSLayoutConstraint] = []
    private var usesNarrowBars = false
    private var regularLayoutWidth: CGFloat = 0
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
        /// Info and above, the level menu's second item.
        static let initialSeverity = 1
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
    private let textModePopUp = ThemedPopUp()
    private let subsystemField = ThemedTextField()
    private let categoryField = ThemedTextField()
    private let scopeLabel = NSTextField(labelWithString: "")
    private lazy var pauseButton = ThemedButton(title: "Pause capture", target: self, action: #selector(toggleCapturePaused))
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var bluetoothProfileSetup = BluetoothProfileSetupView(
        preferredToolPath: preferredPymobiledevice3Path, deviceServices: deviceServices
    )
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
    private var runningStableSourceKey: String?
    private var focusSourceBundleID: String?
    private var focusSourceProcess: String?
    private var cachedFocus: LogFocus?

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
    private var route: DeviceLogSourceOption.Route = .system
    private var rows: [DeviceLogRow] = []
    private var rowByteSizes: [Int] = []
    private var retainedByteCount = 0
    static let ringByteCapacity = 128 * 1_024 * 1_024
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
    private var captureHistoryGap = false
    private var retainedHandoffDrops = 0
    private var runningSourceInitialDrops = 0
    private var panelReadInFlight = false
    private var observedProcesses: [DeviceLogPanelProcess] = []
    private var observedProcessKeys = Set<String>()
    private var observedRecordSources = Set<String>()
    private var observedDescriptorOrigins: [String: Set<String>] = [:]
    private var lastReceivedAt: Date?
    private var observedSelectedPID: Int?
    private var panelRevision: UInt64 = 1
    private var panelDataRevision: UInt64 = 0
    private var panelEpoch = UUID().uuidString
    private var capturePaused = false
    private var sharedFilter = DeviceLogPanelFilter() {
        didSet {
            if sharedFilter != oldValue { panelRevision &+= 1; cachedFocus = nil }
        }
    }
    private var filter: String {
        get { sharedFilter.text }
        set { sharedFilter.text = newValue }
    }
    /// Whole-device Debug output is thousands of rows per second on a paired iPhone. Start at
    /// Info so the pane opens as a useful console; Debug remains one explicit menu choice away.
    private var minimumSeverity: Int {
        get { sharedFilter.minimumSeverity }
        set { sharedFilter.minimumSeverity = newValue }
    }
    /// The level the reader is asked for, which only the level menu moves.
    ///
    /// Rows below it are never read, so they are not decoded, kept in the ring or recorded. An
    /// agent's focus changes what is shown, not what is read: clearing a focus sets the view to
    /// every level, and following it here would quietly turn a phone's Debug firehose back on.
    private var captureSeverity = Metrics.initialSeverity
    private var runningCaptureSeverity: Int?
    private var selectedProcess: String? {
        get { sharedFilter.process }
        set { sharedFilter.process = newValue }
    }
    private(set) var packetFilter = BluetoothPacketFilter.all {
        didSet { if packetFilter != oldValue { cachedFocus = nil } }
    }
    private var processChoices: [String] = []
    private var knownProcesses: Set<String> = []
    private var showingContext: Bool {
        get { sharedFilter.showingContext }
        set { sharedFilter.showingContext = newValue }
    }
    private var projectionGeneration = 0
    private var projectionLimited = false
    private var projectionTask: Task<Void, Never>?
    // Context projection scans on a worker. Its entries refer to this immutable snapshot until
    // the next result arrives, so a rolling capture cannot silently change the lines on screen.
    private var completedProjectionFocus: LogFocus?
    private var completedProjectionContext = false
    private var projectedRows: [DeviceLogRow]?
    private var projectedRowOffset = 0
    private var rowOffset = 0

    /// The controls, as the fold layout reads them. Built rather than stored so the two cannot
    /// drift: the filter field and the level chooser *are* the focus.
    private var focus: LogFocus {
        if let cachedFocus { return cachedFocus }
        let result = LogFocus(
            pattern: filter,
            minimumSeverity: minimumSeverity,
            context: DeviceLogLimits.foldContext,
            process: selectedProcess,
            subsystem: sharedFilter.subsystem,
            excluding: packetFilter == .complete ? BluetoothPacketFilter.problemMarker : nil,
            textMode: sharedFilter.textMode, levels: sharedFilter.levels,
            bundleID: sharedFilter.bundleID, pid: sharedFilter.pid, category: sharedFilter.category,
            sourceBundleID: focusSourceBundleID,
            sourceProcess: focusSourceProcess ?? selectedProcess,
            requiredSubsystem: packetFilter == .all ? nil : BluetoothATTSession.appProtocolName
        )
        cachedFocus = result
        return result
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
    private var receivedInGeneration = 0
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
    private let deviceServices: (any PluginDeviceServices)?

    /// Writes what arrives to disk, so search and a time range have something to look at once the
    /// ring has moved on. One store per chat: two chats watching two devices are two histories.
    public let recorder: DeviceLogRecorder?

    public init(
        owningSessionID: String?,
        preferredPymobiledevice3Path: String? = nil,
        deviceServices: (any PluginDeviceServices)? = nil,
        preferredMachineID: String? = nil,
        stream: Stream? = nil,
        definitionsCheckout: String? = nil
    ) {
        self.stream = stream
        self.definitionsCheckout = definitionsCheckout
        self.owningSessionID = owningSessionID
        self.preferredPymobiledevice3Path = preferredPymobiledevice3Path
        self.deviceServices = deviceServices
        self.requestedMachineID = preferredMachineID
        self.recorder = DeviceLogRecorder(
            directory: Self.storeDirectory,
            name: (owningSessionID ?? "unattached") + (stream == .bluetooth ? "-bluetooth" : "")
        )
        super.init(nibName: nil, bundle: nil)
    }

    /// Under Caches rather than Application Support: a log history is reconstructible by watching
    /// again, and the system may reclaim it when the disk is tight without losing anything the
    /// user authored. `DeviceLogStoreRetention` bounds it.
    ///
    /// A test process gets a per-process temporary directory instead. Panes built by tests carry a
    /// fresh session id each, and every one used to leave a store in the user's real Caches folder:
    /// on 2026-10-17, 2,180 of 2,186 stores there belonged to no session that existed.
    static var storeDirectory: URL {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Threading-TestDeviceLogs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
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

    public override func viewDidLayout() {
        super.viewDidLayout()
        adaptRegularColumns()
        let narrow = view.bounds.width < 640
        guard narrow != usesNarrowBars else { return }
        usesNarrowBars = narrow
        for pair in responsiveBars {
            pair.bar.orientation = narrow ? .vertical : .horizontal
            pair.bar.alignment = narrow ? .leading : .centerY
        }
        if narrow { NSLayoutConstraint.activate(narrowBarConstraints) }
        else { NSLayoutConstraint.deactivate(narrowBarConstraints) }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        guard !captureManagedByWorkspace else { return }
        startCapture()
    }

    func startCapture(discover: Bool = true) {
        guard drainTimer == nil, !capturePaused else { return }
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
        stopCaptureUnlessRecording()
    }

    /// A Bluetooth capture is a recording someone started on purpose — a firmware update, a
    /// pairing — and the thing worth seeing often happens while they look at something else. So a
    /// running Bluetooth reader keeps reading, recording and following procedures while the pane is
    /// hidden; only drawing stops. Everything else stops, because a hidden tab must not keep a
    /// firehose of system log alive. The reader still ends with the pane: releasing it releases the
    /// source, whose `deinit` stops the capture.
    var recordsWhileHidden: Bool {
        guard source != nil, endedReason == nil, case .bluetooth = selectedOption?.kind else { return false }
        return true
    }

    func stopCaptureUnlessRecording() {
        guard recordsWhileHidden else {
            stopCapture()
            return
        }
        bluetoothProfileSetup.cancelBrowser()
        discoveryGeneration += 1
        setRowsPresented(false)
    }

    func stopCapture() {
        bluetoothProfileSetup.cancelBrowser()
        discoveryGeneration += 1
        sourceGeneration += 1
        if source != nil { captureHistoryGap = true }
        // A hidden tab must not keep a child process reading a firehose.
        //
        // `runningSourceTitle` deliberately survives. It records *which* source the rows on screen
        // came from, not whether a process is alive, and clearing it here made every re-appearance
        // look like a source change — so switching tabs or sessions and coming back wiped the
        // whole log. `source == nil` is what says "not currently reading".
        retireHandoffDrops()
        source?.stop()
        source = nil
        panelDataRevision &+= 1
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

    /// A console's message remains readable at drawer widths. App identity is already named in
    /// the controls, so narrow panes hide those redundant columns before sacrificing the content.
    private func adaptRegularColumns() {
        guard packetPopUp.isHidden, let scroll else { return }
        let width = min(view.bounds.width, scroll.bounds.width, scroll.contentView.bounds.width)
        guard width > 0, abs(width - regularLayoutWidth) > 1 else { return }
        regularLayoutWidth = width
        let narrow = width < 640
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.tableColumn(withIdentifier: Columns.process)?.isHidden = narrow
        table.tableColumn(withIdentifier: Columns.subsystem)?.isHidden = narrow
        let time: CGFloat = narrow ? 72 : 92
        let level: CGFloat = narrow ? 50 : 62
        let process: CGFloat = width < 900 ? 100 : 150
        let subsystem: CGFloat = width < 900 ? 120 : 180
        let metadataWidth = time + level + (narrow ? 0 : process + subsystem)
        let gaps = table.intercellSpacing.width * CGFloat(narrow ? 3 : 5)
        table.tableColumn(withIdentifier: Columns.time)?.width = time
        table.tableColumn(withIdentifier: Columns.level)?.width = level
        table.tableColumn(withIdentifier: Columns.process)?.width = process
        table.tableColumn(withIdentifier: Columns.subsystem)?.width = subsystem
        table.tableColumn(withIdentifier: Columns.message)?.width = max(180, width - metadataWidth - gaps)
        table.setFrameSize(NSSize(width: width, height: table.frame.height))
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
    @MainActor private enum Recents {
        static let machineKey = "deviceLogRecentMachine"
        static let sourceKeyPrefix = "deviceLogRecentSource."
        static let identityKeyPrefix = "deviceLogRecentSourceIdentity."

        static func machineID() -> String? {
            PreferenceStore.shared.string(forKey: machineKey)
        }

        static func rememberMachine(_ id: String) {
            PreferenceStore.shared.set(id, forKey: machineKey)
        }

        static func sourceTitle(forMachine id: String) -> String? {
            PreferenceStore.shared.string(forKey: sourceKeyPrefix + id)
        }

        static func stableSourceKey(forMachine id: String) -> String? {
            PreferenceStore.shared.string(forKey: identityKeyPrefix + id)
        }

        static func rememberSource(_ title: String, stableKey: String, forMachine id: String) {
            PreferenceStore.shared.set(title, forKey: sourceKeyPrefix + id)
            PreferenceStore.shared.set(stableKey, forKey: identityKeyPrefix + id)
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
        routePopUp.selectItem(at: route.rawValue)
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
        filterField.setAccessibilityIdentifier("device-log-text-filter")
        for title in ["Literal", "Regex"] { textModePopUp.addItem(withTitle: title) }
        textModePopUp.target = self
        textModePopUp.action = #selector(textModeChanged)
        textModePopUp.setAccessibilityIdentifier("device-log-text-mode")
        subsystemField.placeholderString = "Subsystem"
        categoryField.placeholderString = "Category"
        subsystemField.delegate = self
        categoryField.delegate = self
        subsystemField.setAccessibilityIdentifier("device-log-subsystem-filter")
        categoryField.setAccessibilityIdentifier("device-log-category-filter")
        pauseButton.setAccessibilityIdentifier("device-log-pause-capture")
        scopeLabel.applyFont(.compactCode)
        scopeLabel.textColor = Design.Text.secondary
        scopeLabel.lineBreakMode = .byTruncatingMiddle
        scopeLabel.setAccessibilityIdentifier("device-log-active-scope")

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
        let sourceSelectors = NSStackView(views: [devicePopUp, sourcePopUp, routePopUp])
        let sourceActions = NSStackView(views: [bluetoothSetupButton, definitionsButton, timelinesButton, rescan, clear])
        let bar = NSStackView(views: [sourceSelectors, sourceActions])
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
        let filterSelectors = NSStackView(views: [processPopUp, packetPopUp, levelPopUp, textModePopUp])
        let filterText = NSStackView(views: [filterField, contextPopUp])
        let filters = NSStackView(views: [filterSelectors, filterText])
        filters.setAccessibilityIdentifier("device-log-filter-bar")
        filters.toolTip = "Text, app/process, level, subsystem and category filters combine with AND. Selected levels combine with OR. Literal text is the default; regex is explicit."
        filters.orientation = .horizontal
        filters.spacing = Design.Spacing.small
        filters.alignment = .centerY
        filters.edgeInsets = bar.edgeInsets
        let scopeFields = NSStackView(views: [subsystemField, categoryField])
        let scopeIdentity = NSStackView(views: [scopeLabel, pauseButton])
        let scope = NSStackView(views: [scopeFields, scopeIdentity])
        scope.orientation = .horizontal
        scope.spacing = Design.Spacing.small
        scope.alignment = .centerY
        scope.edgeInsets = bar.edgeInsets
        scope.setAccessibilityIdentifier("device-log-scope-bar")
        responsiveBars = [(bar, [sourceSelectors, sourceActions]), (filters, [filterSelectors, filterText]),
                          (scope, [scopeFields, scopeIdentity])]
        for pair in responsiveBars {
            for group in pair.groups {
                group.orientation = .horizontal
                group.alignment = .centerY
                group.spacing = Design.Spacing.small
                narrowBarConstraints.append(group.widthAnchor.constraint(equalTo: pair.bar.widthAnchor,
                    constant: -pair.bar.edgeInsets.left - pair.bar.edgeInsets.right))
            }
        }
        for control in [devicePopUp, sourcePopUp, processPopUp, levelPopUp, scopeLabel] as [NSView] {
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sourceSelectors.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scopeIdentity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subsystemField.widthAnchor.constraint(equalTo: categoryField.widthAnchor).isActive = true
        subsystemField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        categoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [devicePopUp, sourcePopUp, routePopUp, levelPopUp, processPopUp, packetPopUp, contextPopUp, textModePopUp] as [NSView] + [bluetoothSetupButton, timelinesButton, rescan, clear, filterField, subsystemField, categoryField, pauseButton] {
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
        let stack = NSStackView(views: [bar, bluetoothProfileSetup, filters, scope, scroll, footer])
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
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filters.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scope.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        beginSourceDiscovery()
        if let requestDiscovery { requestDiscovery(); return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        DeviceLogSourceCatalog.discover(
            preferredPymobiledevice3Path: preferredPymobiledevice3Path,
            deviceServices: deviceServices
        ) { [weak self] found in
            MainActor.assumeIsolated {
                guard let self, self.discoveryGeneration == generation else { return }
                self.acceptSources(found)
            }
        }
    }

    func beginSourceDiscovery() { sourceCatalogPending = true }

    public func refreshPanelSources() -> DeviceLogPanelState {
        beginSourceDiscovery()
        if let requestSourceRefresh { requestSourceRefresh() }
        else { reloadSources() }
        return panelState()
    }

    func acceptSources(_ found: [DeviceLogSourceOption]) {
        sourceCatalogPending = false
        sourceCatalogUpdatedAt = Date()
        options = found.filter { stream?.includes($0) ?? true }
        discoverSourceProcesses()
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
        if selectedMachine != machine { panelRevision &+= 1 }
        selectedMachine = machine
        machines.forEach { devicePopUp.addItem(withTitle: $0.title) }
        devicePopUp.selectItem(at: machines.firstIndex(of: machine) ?? 0)

        let sources = self.sources(of: machine)
        sources.forEach { sourcePopUp.addItem(withTitle: $0.title) }
        // By title within the machine rather than by a remembered index: the list changes shape
        // whenever an app is installed or removed, and an index would then name something else.
        let wanted = Recents.sourceTitle(forMachine: recentMachineKey(machine.id))
        let wantedIdentity = Recents.stableSourceKey(forMachine: recentMachineKey(machine.id))
        let keep = sources.firstIndex { stableSourceKey($0) == runningStableSourceKey }
            ?? sources.firstIndex { $0.title == runningSourceTitleWithinMachine }
            ?? sources.firstIndex { stableSourceKey($0) == wantedIdentity }
            ?? sources.firstIndex { $0.title == wanted }
            ?? 0
        sourcePopUp.selectItem(at: keep)
        if sharedFilter.pid == nil, let pid = sources[keep].processIdentity?.pid, pid != observedSelectedPID {
            observedSelectedPID = pid
            panelRevision &+= 1
        }
        updateRouteVisibility()
    }

    /// The route chooses between an app's two logs, so it belongs to the *selection* rather than
    /// to starting a reader. Setting it only on start left "App log" standing beside a simulator,
    /// which has one log and no choice to make — a control offering a decision that does not
    /// exist.
    private func updateRouteVisibility() {
        let bundleID = selectedOption?.bundleID
        let process = selectedOption?.processIdentity?.name
        if focusSourceBundleID != bundleID || focusSourceProcess != process {
            focusSourceBundleID = bundleID
            focusSourceProcess = process
            cachedFocus = nil
        }
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
        regularLayoutWidth = 0
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
        guard !capturePaused else { updateStatus(); return }
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
        let identity = "\(option.machine.id)/\(stableSourceKey(option))" + (isApp ? "#\(route.rawValue)" : "")
            + (selectedProcess.map { "#process=\($0)" } ?? "")
        let severity = option.readsAtLevel(route: route) ? captureSeverity : 0
        // Already reading this one: restarting would throw away every row read so far.
        guard identity != runningSourceTitle || severity != runningCaptureSeverity
                || source == nil || endedReason != nil else { return }
        // Resuming the same source after the pane was hidden keeps what is on screen. Only a
        // genuine change of source discards it, because those rows are no longer about the thing
        // being read. Resuming does leave a gap where the pane was not listening, which is honest
        // for a live tail and better than an empty pane. A new level is the same source read
        // differently, so it keeps its rows too.
        let isSameSource = identity == runningSourceTitle
        if !isSameSource { panelRevision &+= 1 }
        runningSourceTitle = identity
        runningCaptureSeverity = severity
        runningSourceTitleWithinMachine = option.title
        runningStableSourceKey = stableSourceKey(option)
        Recents.rememberMachine(option.machine.id)
        Recents.rememberSource(option.title, stableKey: stableSourceKey(option), forMachine: recentMachineKey(option.machine.id))

        sourceGeneration += 1
        let generation = sourceGeneration
        if source != nil, isSameSource { captureHistoryGap = true }
        retireHandoffDrops()
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
        else {
            reader = option.makeSource(
                predicate: nil, route: route, processName: selectedProcess,
                minimumSeverity: severity, deviceServices: deviceServices
            )
        }
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
                    self.panelDataRevision &+= 1
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
        observedRecordSources.removeAll()
        observedDescriptorOrigins.removeAll()
        source = started
        receivedInGeneration = 0
        lastReceivedAt = nil
        runningSourceInitialDrops = started.dropped
        started.start()
        startedAt = Date()
        updateStatus()
    }

    private func stableSourceKey(_ option: DeviceLogSourceOption) -> String {
        if let bundleID = option.bundleID { return "bundle:" + bundleID }
        if let path = option.processIdentity?.executablePath { return "process:" + path }
        return "source:" + option.title
    }

    private func recentMachineKey(_ id: String) -> String {
        stream == .bluetooth ? id + ".bluetooth" : id
    }

    @objc private func sourceChanged() {
        sharedFilter.bundleID = selectedOption?.bundleID
        sharedFilter.pid = nil
        observedSelectedPID = nil
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
        sharedFilter.levels = []
        minimumSeverity = Self.levelThresholds.indices.contains(index)
            ? Self.levelThresholds[index]
            : 0
        captureSeverity = minimumSeverity
        recomputeVisible()
        table.reloadData()
        updateStatus()
        // Lowering the level has to ask the reader for rows it was told to leave unread.
        if source != nil { startSelectedSource() }
    }

    @objc private func packetFilterChanged() {
        setPacketFilter(BluetoothPacketFilter(rawValue: packetPopUp.indexOfSelectedItem) ?? .all)
    }

    /// Shows only rows the project's definitions decoded, optionally only those whose bytes fit
    /// their definition exactly. Recorded history is unaffected.
    func setPacketFilter(_ filter: BluetoothPacketFilter) {
        if packetFilter != filter { panelRevision &+= 1 }
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

    private func discoverSourceProcesses() {
        for option in options.prefix(512) {
            guard let process = option.processIdentity else { continue }
            if processChoices.count < Metrics.maximumProcessChoices, knownProcesses.insert(process.name).inserted {
                processChoices.append(process.name)
                if presentsRows { processPopUp.addItem(withTitle: process.name) }
            }
        }
    }

    /// Incremental, capped discovery; never rebuild a menu for every log tick.
    private func discoverProcesses(in batch: [DeviceLogRow]) {
        let activeBundleID = sharedFilter.bundleID ?? focusSourceBundleID
        let activeProcess = selectedProcess ?? focusSourceProcess
        for row in batch {
            observedRecordSources.insert(row.source.rawValue)
            if row.source == .stdout || row.source == .stderr {
                let origin = descriptorOrigin(bundleID: row.bundleID, process: row.process, pid: row.pid)
                if observedDescriptorOrigins.count < Metrics.maximumProcessChoices || observedDescriptorOrigins[origin] != nil {
                    observedDescriptorOrigins[origin, default: []].insert(row.source.rawValue)
                }
            }
            let identity = DeviceLogPanelProcess(process: row.process, bundleID: row.bundleID, pid: row.pid)
            let key = "\(row.process)\u{0}\(row.bundleID ?? "")\u{0}\(row.pid ?? 0)"
            if observedProcesses.count < Metrics.maximumProcessChoices, observedProcessKeys.insert(key).inserted {
                observedProcesses.append(identity)
            }
            let selectedIdentity = activeBundleID.map {
                row.bundleID == $0 || (row.bundleID == nil && activeProcess == row.process)
            } ?? activeProcess.map { row.process == $0 } ?? false
            if selectedIdentity, let pid = row.pid, pid != observedSelectedPID {
                observedSelectedPID = pid
                panelRevision &+= 1
            }
            guard processChoices.count < Metrics.maximumProcessChoices else { continue }
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
        captureHistoryGap = false
        retainedHandoffDrops = 0
        runningSourceInitialDrops = source?.dropped ?? 0
        panelEpoch = UUID().uuidString
        panelDataRevision &+= 1
        projectedRows = nil
        completedProjectionFocus = nil
        rows.removeAll(keepingCapacity: true)
        rowByteSizes.removeAll(keepingCapacity: true)
        retainedByteCount = 0
        observedRecordSources.removeAll()
        observedDescriptorOrigins.removeAll()
        lastReceivedAt = nil
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
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        projectedRows = nil
        rows.removeAll(keepingCapacity: true)
        rowByteSizes.removeAll(keepingCapacity: true)
        retainedByteCount = 0
        rowOffset = appendToRing(fixture)
        panelEpoch = UUID().uuidString
        panelDataRevision &+= 1
        received = fixture.count
        receivedInGeneration = fixture.count
        lastReceivedAt = fixture.isEmpty ? nil : Date()
        discoverProcesses(in: fixture)
        filter = pattern
        filterField.stringValue = pattern
        entries = LogFocusLayout.entries(rows: rows, focus: focus, showingContext: showingContext)
        completedProjectionFocus = focus
        completedProjectionContext = showingContext
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
        sharedFilter.levels = []
        sharedFilter.textMode = .literal
        synchronizePanelControls()
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
        discoverSourceProcesses()
        rebuildMenus()
    }

    public func selectAppForTesting(bundleID: String, route: DeviceLogSourceOption.Route = .system) {
        guard let option = options.first(where: { $0.bundleID == bundleID }) else { return }
        requestedMachineID = option.machine.id
        rebuildMenus()
        let choices = sources(of: selectedMachine)
        guard let index = choices.firstIndex(of: option) else { return }
        sourcePopUp.selectItem(at: index)
        self.route = route
        routePopUp.selectItem(at: route.rawValue)
        updateRouteVisibility()
        if isVisibleForCapture { startSelectedSource() }
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
    /// Chooses a level menu item by position: all levels, Info and above, errors only.
    public func selectLevelForTesting(_ index: Int) {
        levelPopUp.selectItem(at: index)
        levelChanged()
    }
    /// The level the running reader was asked for; nil before one has started.
    public var captureSeverityForTesting: Int? { runningCaptureSeverity }
    public var scrollOriginForTesting: NSPoint { scroll?.contentView.bounds.origin ?? .zero }
    public var selectedRowIDsForTesting: [String] {
        let snapshot = projectedRows ?? rows
        return table.selectedRowIndexes.compactMap { position in
            guard entries.indices.contains(position), case .row(let index) = entries[position], snapshot.indices.contains(index) else { return nil }
            return snapshot[index].id
        }
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
            panelRevision &+= 1
            entries = LogFocusLayout.entries(rows: displayed, focus: focus, expanded: expandedGaps(at: offset))
            table.reloadData()
        }
        guard let position = displayIndex(containing: index), case .row = entries[position] else { return false }
        revealingLinked = true
        defer { revealingLinked = false }
        if isFollowing { panelRevision &+= 1 }
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
            completedProjectionFocus = focus
            completedProjectionContext = showingContext
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
        projectionLimited = false
        projectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> (entries: [LogDisplayEntry], limited: Bool) in
                let deadline: UInt64? = selectedFocus.textMode == .regex
                    ? DispatchTime.now().uptimeNanoseconds + 250_000_000 : nil
                if context {
                    let result = LogFocusLayout.entries(rows: snapshot, focus: selectedFocus, expanded: expanded,
                                                        evaluationDeadline: deadline)
                    return (result, deadline.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false)
                }
                var result: [LogDisplayEntry] = []
                for index in snapshot.indices {
                    if index % 128 == 0, Task.isCancelled { return (result, false) }
                    if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { return (result, true) }
                    if selectedFocus.evaluation(of: snapshot[index], deadline: deadline).matches { result.append(.row(index)) }
                }
                return (result, false)
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
            let replacesDataset = self.completedProjectionFocus != selectedFocus || self.completedProjectionContext != context
            self.entries = projected.entries
            self.projectionLimited = projected.limited
            self.completedProjectionFocus = selectedFocus
            self.completedProjectionContext = context
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
            if self.presentsRows { self.refreshStreamingTable(selection: selection, origin: origin, replacingDataset: replacesDataset) }
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
        receivedInGeneration += incoming.count
        lastReceivedAt = Date()
        panelDataRevision &+= 1
        discoverProcesses(in: incoming)
        // On disk as well as on screen: the ring is what the table can hold, the store is what a
        // question can reach back through once the ring has moved on.
        recorder?.record(incoming)

        let projectBurst = !showingContext && isFiltering
            && (incoming.count > Metrics.maximumSynchronousMatches || sharedFilter.textMode == .regex)
        if presentsRows, projectBurst, projectedRows == nil {
            projectedRows = rows
            projectedRowOffset = rowOffset
        }
        let previousCount = rows.count
        let removedCount = appendToRing(incoming)
        let removedEntries = entries.prefix { entry in
            guard case .row(let index) = entry else { return false }
            return index < removedCount
        }.count
        rowOffset += removedCount

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
        completedProjectionFocus = focus
        completedProjectionContext = showingContext

        if !showingContext {
            // Strict mode tests new rows only. Old matches shift with the ring; a whole-ring
            // text scan at every 100 ms tick would make a quieter view cost more CPU.
            let shownBefore = entries.count
            entries = entries.compactMap { entry in
                guard case .row(let index) = entry, index >= removedCount else { return nil }
                return .row(index - removedCount)
            }
            let selectedFocus = focus
            for index in max(0, previousCount - removedCount)..<rows.count where selectedFocus.matches(rows[index]) {
                entries.append(.row(index))
            }
            streamRows(removing: removedEntries, appending: entries.count - (shownBefore - removedEntries))
        } else {
            entries = rows.indices.map { .row($0) }
            // Strict/unfiltered streams only remove entries at the head. Keep the reader's
            // selected lines and paused viewport attached to those surviving entries.
            refreshStreamingTable(removing: removedEntries)
        }
    }

    /// One bounded value-ring mutation, shared by capture and deterministic fixtures.
    @discardableResult
    private func appendToRing(_ incoming: [DeviceLogRow]) -> Int {
        rows.append(contentsOf: incoming)
        let addedSizes = incoming.map(\.estimatedRetainedBytes)
        rowByteSizes.append(contentsOf: addedSizes)
        retainedByteCount += addedSizes.reduce(0, +)
        var removedCount = 0
        while rows.count - removedCount > DeviceLogLimits.ringCapacity || retainedByteCount > Self.ringByteCapacity {
            retainedByteCount -= rowByteSizes[removedCount]
            removedCount += 1
        }
        if removedCount > 0 {
            rows.removeFirst(removedCount)
            rowByteSizes.removeFirst(removedCount)
        }
        return removedCount
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

    /// Tells the table exactly what a strict stream did: entries left at the head and arrived at
    /// the tail. Rows still on screen keep their views, text and drawn layers, and the table moves
    /// the selection with its lines; only arriving rows are configured and drawn.
    ///
    /// The tail used to re-bind every visible cell to whatever its row number now held. Under a
    /// level filter the matched count changes on nearly every tick, so the visible row numbers
    /// moved too and AppKit built fresh row views for them — 30 new cells a tick that were never
    /// reused. Replaying an iPhone's 2,614 rows/s, that held the main thread at 54% of a core even
    /// while the reader was scrolled up and nothing they could see was changing.
    private func streamRows(removing removedEntries: Int, appending appendedEntries: Int) {
        guard table.numberOfRows == entries.count - appendedEntries + removedEntries else {
            // The table was last told about some other list; only a full refresh is honest.
            return refreshStreamingTable(removing: removedEntries)
        }
        // A tail that brings a whole viewport of new lines leaves nothing on screen to keep, and
        // re-binding the cells already there costs less than inserting and building fresh rows.
        if isFollowing, appendedEntries >= table.rows(in: table.visibleRect).length {
            return refreshStreamingTable(removing: removedEntries)
        }
        updatingTable = true
        defer { updatingTable = false }
        guard let scroll else { return }
        let pitch = table.rowHeight + table.intercellSpacing.height
        let origin = scroll.contentView.bounds.origin
        // The frame carries the table's own padding beyond its rows, so the new bottom is measured
        // from it rather than rebuilt from a row count.
        let bottom = max(0, table.frame.height + CGFloat(appendedEntries - removedEntries) * pitch
            - scroll.contentView.bounds.height)
        table.beginUpdates()
        if removedEntries > 0 {
            table.removeRows(at: IndexSet(integersIn: 0..<removedEntries), withAnimation: [])
        }
        if appendedEntries > 0 {
            table.insertRows(at: IndexSet(integersIn: (entries.count - appendedEntries)..<entries.count), withAnimation: [])
        }
        // The viewport moves inside the same update. Moved after it, the table would first build
        // rows for wherever the shifted lines left it — a whole fresh viewport each tick — and then
        // tear them down again when the scroll arrived.
        let target = isFollowing ? bottom : min(bottom, max(0, origin.y - CGFloat(removedEntries) * pitch))
        if target != origin.y {
            scroll.contentView.setBoundsOrigin(NSPoint(x: origin.x, y: target))
        }
        table.endUpdates()
        // Settles the follow exactly; with the viewport already at the tail this does nothing.
        if isFollowing, !entries.isEmpty { table.scrollRowToVisible(entries.count - 1) }
        scroll.reflectScrolledClipView(scroll.contentView)
        updateFollowAffordance()
    }

    private func refreshStreamingTable(removing removedEntries: Int = 0,
                                       selection: IndexSet? = nil, origin restoredOrigin: NSPoint? = nil,
                                       replacingDataset: Bool = false) {
        updatingTable = true
        defer { updatingTable = false }
        let selected = table.selectedRowIndexes
        let origin = scroll?.contentView.bounds.origin ?? .zero
        // reloadData destroys every visible row and its cells. A live tail needs only its
        // count and the text in the existing viewport to change, including at a full ring.
        if replacingDataset {
            // A different filter is a different dataset. Count-only updates leave AppKit's retired
            // row presentations alive; reload the bounded viewport once for this user operation.
            table.reloadData()
        } else {
            table.noteNumberOfRowsChanged()
        }
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
        adaptRegularColumns()
        guard !updatingTable else { return }
        let atBottom = isPinnedToBottom()
        guard atBottom != isFollowing else { return }
        isFollowing = atBottom
        panelRevision &+= 1
        updateFollowAffordance()
    }

    @objc private func resumeFollowing() {
        if !isFollowing { panelRevision &+= 1 }
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
        let unavailable = currentSourceAvailability().unavailable
            .filter { $0 == "stdout" || $0 == "stderr" }.map { "\($0) unavailable" }
        return ([text] + unavailable + (agentNote.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private func updateStatus() {
        guard presentsRows else { return }
        updateScopeLabel()
        if capturePaused {
            statusLabel.stringValue = appending("Capture paused · \(rows.count) retained rows")
            return
        }
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
        if receivedInGeneration == 0, let startedAt, Date().timeIntervalSince(startedAt) > Metrics.silenceGrace {
            if let option = selectedOption, case .bluetooth = option.kind {
                statusLabel.stringValue = appending(L10n.string("Waiting for Bluetooth packets. Check the iPhone logging profile and generate Bluetooth activity."))
            } else {
                if source?.lastTransportActivity.map({ Date().timeIntervalSince($0) <= Metrics.silenceGrace }) == true {
                    statusLabel.stringValue = appending("Live transport · no rows for the selected app/process yet")
                } else {
                    statusLabel.stringValue = appending("No live log data received yet")
                }
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
        if projectionLimited { parts.append("Regex projection limited — refine the filter") }
        else if isFiltering, shown == 0, !rows.isEmpty { parts.append("No matching rows") }
        statusLabel.stringValue = appending(parts.joined(separator: " · "))
    }
    // MARK: Shared panel control plane

    private func nonempty(_ value: String) -> String? { value.isEmpty ? nil : value }

    private func validRoutes(for option: DeviceLogSourceOption) -> [DeviceLogSourceOption.Route] {
        if case .app = option.kind { return [.system, .appLog, .console] }
        if case .bluetooth = option.kind { return [] }
        return [.system]
    }

    private func routeName(_ value: DeviceLogSourceOption.Route) -> String {
        switch value { case .appLog: return "app_log"; case .console: return "console"; case .system: return "system" }
    }

    private func synchronizePanelControls() {
        filterField.stringValue = sharedFilter.text
        subsystemField.stringValue = sharedFilter.subsystem ?? ""
        categoryField.stringValue = sharedFilter.category ?? ""
        textModePopUp.selectItem(at: sharedFilter.textMode == .literal ? 0 : 1)
        contextPopUp.selectItem(at: showingContext ? 1 : 0)
        if sharedFilter.levels.isEmpty {
            levelPopUp.selectItem(at: Self.levelThresholds.firstIndex(of: minimumSeverity) ?? 0)
        } else {
            let title = sharedFilter.levels.joined(separator: ", ")
            levelPopUp.removeAllItems()
            for item in ["All levels", "Info and above", "Errors only"] { levelPopUp.addItem(withTitle: L10n.string(item)) }
            levelPopUp.addItem(withTitle: title)
            levelPopUp.selectItem(at: Self.levelThresholds.count)
        }
        processPopUp.selectItem(at: selectedProcess.flatMap { processChoices.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        pauseButton.title = capturePaused ? "Start capture" : "Pause capture"
        updateScopeLabel()
    }

    private func updateScopeLabel() {
        var labels: [String] = []
        if let bundleID = sharedFilter.bundleID { labels.append(bundleID) }
        if let process = sharedFilter.process { labels.append(process) }
        if let pid = sharedFilter.pid ?? observedSelectedPID { labels.append("PID \(pid)") }
        if !sharedFilter.levels.isEmpty { labels.append(sharedFilter.levels.joined(separator: ", ")) }
        scopeLabel.stringValue = labels.isEmpty ? "All app identities" : labels.joined(separator: " · ")
        scopeLabel.toolTip = scopeLabel.stringValue
        textModePopUp.toolTip = sharedFilter.textMode == .regex
            ? "Regex examines the first 4096 characters of each field; expensive matching stops cooperatively after 2ms per field."
            : "Literal ignores ASCII letter case; non-ASCII bytes compare exactly. Searches message, process, subsystem or category."
    }

    @objc private func textModeChanged() {
        let mode: DeviceLogPanelFilter.TextMode = textModePopUp.indexOfSelectedItem == 1 ? .regex : .literal
        if mode == .regex, (try? NSRegularExpression(pattern: filter)) == nil {
            textModePopUp.selectItem(at: sharedFilter.textMode == .literal ? 0 : 1)
            statusLabel.stringValue = "Invalid regular expression"
            return
        }
        sharedFilter.textMode = mode
        showingContext = false
        expandedGaps.removeAll()
        clearAgentNote()
        recomputeVisible(backgroundContext: true)
        updateStatus()
    }

    @objc private func toggleCapturePaused() {
        setCapturePaused(!capturePaused)
        synchronizePanelControls()
        updateStatus()
    }

    private func setCapturePaused(_ paused: Bool) {
        guard paused != capturePaused else { return }
        capturePaused = paused
        panelRevision &+= 1
        if paused { stopCapture() }
        else { startCapture(discover: false) }
    }

    private var currentHandoffDrops: Int {
        retainedHandoffDrops + max(0, (source?.dropped ?? runningSourceInitialDrops) - runningSourceInitialDrops)
    }

    private func retireHandoffDrops() {
        retainedHandoffDrops = currentHandoffDrops
        runningSourceInitialDrops = source?.dropped ?? 0
    }

    private func descriptorOrigin(bundleID: String?, process: String, pid: Int?) -> String {
        "\(bundleID ?? "")|\(process)|\(pid ?? 0)"
    }

    private func currentSourceAvailability() -> (available: [String], unavailable: [String], observedDescriptors: [String], detail: String?) {
        guard let option = selectedOption else { return ([], ["stdout", "stderr"], [], nil) }
        let capability = option.captureAvailability(route: route)
        let process = sharedFilter.process ?? option.processIdentity?.name
            ?? observedProcesses.last(where: { $0.bundleID == option.bundleID && option.bundleID != nil })?.process
        let pid = sharedFilter.pid ?? observedSelectedPID ?? option.processIdentity?.pid
        var descriptors = Set<String>()
        if let process {
            let bundleID = sharedFilter.bundleID ?? option.bundleID
            descriptors.formUnion(observedDescriptorOrigins[descriptorOrigin(bundleID: bundleID, process: process, pid: pid)] ?? [])
            // Legacy rows can prove a descriptor for an exact process/PID without proving bundle ID.
            descriptors.formUnion(observedDescriptorOrigins[descriptorOrigin(bundleID: nil, process: process, pid: pid)] ?? [])
        }
        return (Array(Set(capability.availableSources.map(\.rawValue)).union(descriptors)).sorted(),
                capability.unavailableSources.map(\.rawValue).filter { !descriptors.contains($0) },
                descriptors.sorted(), capability.detail)
    }

    /// Configuration and manual controls mutate this same filter and reader. Data arrival has a
    /// separate revision so live traffic cannot invalidate every optimistic configuration edit.
    public func panelState() -> DeviceLogPanelState {
        let availability = currentSourceAvailability()
        let captureState: String
        if capturePaused { captureState = "paused" }
        else if selectedOption == nil { captureState = "unavailable" }
        else if endedReason != nil { captureState = "stopped" }
        else if source == nil { captureState = "stopped" }
        else if receivedInGeneration == 0 {
            if source?.lastTransportActivity.map({ Date().timeIntervalSince($0) <= Metrics.silenceGrace }) == true {
                captureState = "awaiting_matches"
            } else {
                captureState = startedAt.map { Date().timeIntervalSince($0) > Metrics.silenceGrace } == true
                ? "awaiting_first_data" : "starting"
            }
        } else if source?.lastTransportActivity.map({ Date().timeIntervalSince($0) <= Metrics.silenceGrace }) == true {
            captureState = "live"
        } else if lastReceivedAt.map({ Date().timeIntervalSince($0) > 15 }) == true { captureState = "stale" }
        else { captureState = "live" }
        let sourceKind: String
        switch selectedOption?.kind {
        case .simulator?: sourceKind = "simulator"
        case .device?, .structuredDevice?, .brokeredStructuredDevice?: sourceKind = "device"
        case .app?: sourceKind = "app"
        case .bluetooth?: sourceKind = "bluetooth"
        case nil: sourceKind = "none"
        }
        return DeviceLogPanelState(
            stream: stream?.rawValue ?? "regular",
            bluetooth: stream == .bluetooth ? DeviceLogBluetoothState(packets: packetFilter, status: definitionStatus) : nil,
            devices: machines.prefix(128).map { .init(id: $0.id, name: $0.title, simulator: $0.isSimulator) },
            processes: Array((options.prefix(512).compactMap { option in
                option.processIdentity.map { DeviceLogPanelProcess(process: $0.name, bundleID: $0.bundleID, pid: $0.pid) }
            } + observedProcesses).prefix(512)),
            sources: options.prefix(512).map { option in
                DeviceLogPanelSource(deviceID: option.machine.id, title: option.title, bundleID: option.bundleID,
                                     process: option.processIdentity?.name ?? option.application?.executableName,
                                     pid: option.processIdentity?.pid,
                                     routes: validRoutes(for: option).map(routeName),
                                     catalogWarning: option.catalogWarning)
            },
            observedSources: observedRecordSources.filter { $0 != "stdout" && $0 != "stderr" }.sorted() + availability.observedDescriptors,
            sourceAvailabilityDetail: availability.detail,
            selectedPID: sharedFilter.pid ?? observedSelectedPID,
            revision: panelRevision, dataRevision: panelDataRevision,
            deviceID: selectedMachine?.id, deviceName: selectedMachine?.title,
            source: selectedOption?.title, sourceKind: sourceKind, route: routeName(route),
            filter: sharedFilter, captureMinimumSeverity: runningCaptureSeverity ?? captureSeverity,
            projectionPending: projectionTask != nil, projectionLimited: projectionLimited,
            readScope: showingContext ? "matches_context_and_expanded_folds" : "matching_rows",
            filterEvaluationLimits: sharedFilter.textMode == .regex
                ? "Regex examines the first 4096 characters per field with a cooperative 2ms field budget, 250ms shared projection budget and 50ms read budget. Limited evaluation is disclosed." : nil,
            following: isFollowing, paused: capturePaused,
            captureState: captureState, readerStatus: readerStatus,
            retainedCount: rows.count, ringCapacity: DeviceLogLimits.ringCapacity,
            retainedBytes: retainedByteCount, ringByteCapacity: Self.ringByteCapacity,
            ringDropped: rowOffset, handoffDropped: currentHandoffDrops,
            historyScope: "retained_buffer", historyHasGap: captureHistoryGap || currentHandoffDrops > 0, oldestRowID: rows.first?.id, newestRowID: rows.last?.id,
            sourceGeneration: sourceGeneration, sourceCatalogPending: sourceCatalogPending,
            sourceCatalogUpdatedAt: sourceCatalogUpdatedAt,
            availableSources: availability.available,
            unavailableSources: availability.unavailable
        )
    }

    private func panelError(_ code: String, _ message: String) -> DeviceLogPanelError {
        .init(code: code, message: message, state: panelState())
    }

    private func requireRevision(_ expected: UInt64?) throws {
        if let expected, expected != panelRevision {
            throw panelError("stale_revision", "The panel changed. Read its current state and retry with that revision.")
        }
    }

    public func configurePanel(
        _ configuration: DeviceLogPanelConfiguration, expectedRevision: UInt64? = nil
    ) async throws -> DeviceLogPanelState {
        if !isViewLoaded { loadView() }
        try requireRevision(expectedRevision)
        let nextPackets: BluetoothPacketFilter
        if let packets = configuration.packets {
            guard stream == .bluetooth,
                  let filter = BluetoothPacketFilter.allCases.first(where: { $0.toolName == packets }) else {
                throw panelError("invalid_packets", "packets is supported only for Bluetooth: all, app or complete.")
            }
            nextPackets = filter
        } else {
            nextPackets = configuration.clearFilter == true ? .all : packetFilter
        }
        if stream == .bluetooth,
           configuration.bundleID != nil || configuration.process != nil || configuration.pid != nil || configuration.route != nil {
            throw panelError("unsupported_filter", "Bluetooth captures phone-wide packets. Use device_id, packets and text; app/process/route choices belong to Regular Logs.")
        }
        var next = configuration.clearFilter == true ? DeviceLogPanelFilter() : sharedFilter
        if configuration.clearFilter == true { next.minimumSeverity = 0 }
        if let text = configuration.text { next.text = text }
        if let mode = configuration.textMode { next.textMode = mode }
        if let bundleID = configuration.bundleID {
            if nonempty(bundleID) != next.bundleID {
                next.process = nil
                next.pid = nil
            }
            next.bundleID = nonempty(bundleID)
        }
        if configuration.source != nil, configuration.source != selectedOption?.title {
            next.process = nil
            next.pid = nil
            if configuration.bundleID == nil { next.bundleID = nil }
        }
        if let process = configuration.process { next.process = nonempty(process) }
        if let pid = configuration.pid {
            guard pid >= 0 else { throw panelError("invalid_pid", "pid must be positive, or 0 to clear it.") }
            next.pid = pid == 0 ? nil : pid
        }
        if let subsystem = configuration.subsystem { next.subsystem = nonempty(subsystem) }
        if let category = configuration.category { next.category = nonempty(category) }
        if let context = configuration.showContext { next.showingContext = context }
        if let levels = configuration.levels {
            let normalized = levels.map { $0.lowercased() }
            guard normalized.allSatisfy(DeviceLogToolLevels.accepted.contains) else {
                throw panelError("invalid_levels", "levels must contain debug, info, notice, warning, error or fault.")
            }
            next.levels = Array(Set(normalized)).sorted()
            next.minimumSeverity = 0
        }
        guard next.text.utf8.count <= 512 else { throw panelError("invalid_filter", "The text filter exceeds 512 bytes.") }
        if next.textMode == .regex {
            do { _ = try NSRegularExpression(pattern: next.text, options: .caseInsensitive) }
            catch { throw panelError("invalid_regex", "Invalid regular expression: \(error.localizedDescription)") }
        }
        let device = configuration.deviceID ?? selectedMachine?.id
        if let device, !machines.contains(where: { $0.id == device }) {
            throw panelError("device_unavailable", "That exact device is not in this panel's discovered sources.")
        }
        let candidates = options.filter { $0.machine.id == device }
        let selected: DeviceLogSourceOption?
        if let bundleID = next.bundleID {
            selected = candidates.first { $0.bundleID == bundleID }
            guard selected != nil else {
                throw panelError("app_unavailable", "That bundle_id is not a discovered app on the selected device.")
            }
        } else if let title = configuration.source {
            selected = candidates.first { $0.title == title }
            guard selected != nil else { throw panelError("source_unavailable", "That source is not available on the selected device.") }
        } else if let process = configuration.process, !process.isEmpty {
            let matching = candidates.filter { $0.processIdentity?.name == process }
            if let pid = next.pid {
                selected = matching.first { $0.processIdentity?.pid == pid }
                guard selected != nil || matching.isEmpty else {
                    throw panelError("process_unavailable", "That process/PID pair is not in the discovered source catalog.")
                }
            } else {
                let identities = Set(matching.compactMap { $0.processIdentity?.executablePath })
                guard identities.count <= 1 else {
                    throw panelError("ambiguous_process", "Multiple executable paths share that process name. Select an exact source or include its pid.")
                }
                selected = matching.first
            }
        } else { selected = nil }
        let requestedRoute: DeviceLogSourceOption.Route?
        if let name = configuration.route {
            requestedRoute = DeviceLogSourceOption.Route.allCases.first { routeName($0) == name || String(describing: $0) == name }
            guard requestedRoute != nil else { throw panelError("invalid_route", "Unknown capture route.") }
        } else { requestedRoute = nil }

        if let requestedRoute, let target = selected ?? selectedOption,
           !validRoutes(for: target).contains(requestedRoute) {
            throw panelError("unsupported_route", "That capture route is not supported by the selected source.")
        }

        // All validation precedes mutation, including expression compilation and exact identity.
        if let device, device != selectedMachine?.id {
            requestedMachineID = device
            rebuildMenus()
        }
        if let selected {
            let choices = sources(of: selectedMachine)
            if let index = choices.firstIndex(of: selected) {
                sourcePopUp.selectItem(at: index)
                if runningSourceTitleWithinMachine != selected.title { panelRevision &+= 1 }
            }
        }
        let oldRoute = route
        if let requestedRoute { route = requestedRoute }
        else if configuration.bundleID != nil, next.bundleID != nil { route = .system }
        if oldRoute != route { panelRevision &+= 1 }
        routePopUp.selectItem(at: route.rawValue)
        let filterChanged = sharedFilter != next
        sharedFilter = next
        if nextPackets != packetFilter {
            packetFilter = nextPackets
            packetPopUp.selectItem(at: nextPackets.rawValue)
            panelRevision &+= 1
            expandedGaps.removeAll()
        }
        if configuration.levels != nil || configuration.clearFilter == true {
            captureSeverity = next.levels.isEmpty ? 0 : next.levels.map { DeviceLogToolLevels.severity(named: $0) }.min() ?? 0
        }
        observedSelectedPID = next.pid ?? selectedOption?.processIdentity?.pid
            ?? observedProcesses.last { $0.bundleID == next.bundleID && next.bundleID != nil }?.pid
        if let follow = configuration.follow, isFollowing != follow {
            isFollowing = follow
            panelRevision &+= 1
        }
        if filterChanged { expandedGaps.removeAll() }
        clearAgentNote()
        updateRouteVisibility()
        synchronizePanelControls()
        if let paused = configuration.paused { setCapturePaused(paused) }
        if isVisibleForCapture { startSelectedSource() }
        recomputeVisible(backgroundContext: true)
        updateStatus()
        return panelState()
    }

    private struct PanelCursor {
        let epoch: String
        let revision: UInt64
        let ordinal: Int
        let dataRevision: UInt64
        let sourceGeneration: Int
        var encoded: String { "\(epoch):\(revision):\(ordinal):\(dataRevision):\(sourceGeneration)" }
        init(epoch: String, revision: UInt64, ordinal: Int, dataRevision: UInt64, sourceGeneration: Int) {
            self.epoch = epoch; self.revision = revision; self.ordinal = ordinal; self.dataRevision = dataRevision
            self.sourceGeneration = sourceGeneration
        }
        init?(_ value: String) {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 5, let sourceGeneration = Int(parts[4]), let revision = UInt64(parts[1]), let ordinal = Int(parts[2]),
                  ordinal >= 0, let data = UInt64(parts[3]) else { return nil }
            self.init(epoch: String(parts[0]), revision: revision, ordinal: ordinal, dataRevision: data, sourceGeneration: sourceGeneration)
        }
    }

    /// A read scans at most 10,000 retained values on a worker, with at most one query in flight.
    /// The cursor advances through examined rows even when none match. It never touches AppKit.
    public func readPanel(
        cursor: String? = nil, limit: Int = 50, expectedRevision: UInt64? = nil
    ) async throws -> DeviceLogPanelReadPage {
        try await readPanelSnapshot(cursor: cursor, limit: limit, expectedRevision: expectedRevision, allowRetry: true)
    }

    private func readPanelSnapshot(
        cursor: String?, limit: Int, expectedRevision: UInt64?, allowRetry: Bool,
        queryBudgetNanoseconds: UInt64 = 50_000_000
    ) async throws -> DeviceLogPanelReadPage {
        try requireRevision(expectedRevision)
        guard (1...200).contains(limit) else { throw panelError("invalid_limit", "limit must be between 1 and 200.") }
        guard !panelReadInFlight else { throw panelError("busy", "A bounded panel read is already in progress.") }
        let supplied = cursor.flatMap(PanelCursor.init)
        if cursor != nil, supplied == nil { throw panelError("invalid_cursor", "Malformed panel cursor.") }
        let changeReason: String?
        if let supplied, supplied.epoch != panelEpoch { changeReason = "source_changed" }
        else if let supplied, supplied.revision != panelRevision { changeReason = "configuration_changed" }
        else if let supplied, supplied.sourceGeneration != sourceGeneration { changeReason = "capture_restarted" }
        else { changeReason = nil }
        let parsed = [nil, "capture_restarted"].contains(changeReason) ? supplied : nil
        let state = panelState()
        if showingContext, projectionTask != nil,
           completedProjectionFocus != focus || !completedProjectionContext {
            let pendingCursor = supplied?.encoded ?? PanelCursor(epoch: panelEpoch, revision: panelRevision,
                ordinal: rowOffset, dataRevision: panelDataRevision, sourceGeneration: sourceGeneration).encoded
            return .init(state: state, rows: [], cursor: pendingCursor, count: 0, hasMore: true,
                         cursorTruncated: false, timedOut: false, changed: changeReason != nil,
                         outputTruncated: false, changeReason: changeReason, dataChanged: false, pending: true)
        }
        let context = showingContext
        let snapshot = context ? (projectedRows ?? rows) : rows
        let offset = context && projectedRows != nil ? projectedRowOffset : rowOffset
        let displayEntries = context ? entries : []
        let contextLimited = context && projectionLimited
        let epoch = panelEpoch
        let start = max(offset, parsed?.ordinal ?? offset) - offset
        if start > snapshot.count, context, let parsed, parsed.ordinal <= rowOffset + rows.count {
            // A tail wait may be ahead of the last completed UI projection while capture catches up.
            return .init(state: state, rows: [], cursor: parsed.encoded, count: 0, hasMore: true,
                         cursorTruncated: parsed.ordinal < rowOffset, timedOut: false, changed: changeReason != nil,
                         outputTruncated: contextLimited, changeReason: changeReason,
                         dataChanged: parsed.dataRevision != state.dataRevision, pending: true)
        }
        guard start <= snapshot.count else { throw panelError("invalid_cursor", "The cursor is beyond this capture buffer.") }
        let selectedFocus = focus
        panelReadInFlight = true
        defer { panelReadInFlight = false }
        let queryStarted = DispatchTime.now().uptimeNanoseconds
        let worker = Task.detached(priority: .userInitiated) { () -> (rows: [DeviceLogPanelReadRow], next: Int, truncated: Bool) in
            var selected: [DeviceLogPanelReadRow] = []
            var next = start
            var bytes = 0
            var outputTruncated = contextLimited
            // Context and opened folds read the completed projection the table itself uses.
            // Preparing these bounded value indices performs no regex evaluation.
            let displayed: Set<Int>? = context ? Set(displayEntries.compactMap {
                if case .row(let index) = $0 { return index }; return nil
            }) : nil
            let deadline = DispatchTime.now().uptimeNanoseconds + queryBudgetNanoseconds
            let scanEnd = min(snapshot.count, start + (selectedFocus.textMode == .regex ? 2_048 : 10_000))
            while next < scanEnd, selected.count < limit, !Task.isCancelled {
                if DispatchTime.now().uptimeNanoseconds >= deadline { outputTruncated = true; break }
                let row = snapshot[next]
                let evaluation = selectedFocus.evaluation(of: row, deadline: deadline)
                outputTruncated = outputTruncated || evaluation.limited
                let isMatch = evaluation.matches
                if displayed?.contains(next) ?? isMatch {
                    let value = DeviceLogPanelReadRow(row, isMatch: isMatch)
                    let cost = value.message.utf8.count + value.rawLine.utf8.count + 1_024
                    if !selected.isEmpty, bytes + cost > 128 * 1_024 { outputTruncated = true; break }
                    selected.append(value)
                    bytes += cost
                    outputTruncated = outputTruncated || value.truncated
                }
                next += 1
            }
            return (selected, next, outputTruncated)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard state.revision == panelRevision, epoch == panelEpoch, state.sourceGeneration == sourceGeneration else {
            if allowRetry, expectedRevision == nil || state.revision == panelRevision {
                panelReadInFlight = false
                let elapsed = DispatchTime.now().uptimeNanoseconds - queryStarted
                return try await readPanelSnapshot(cursor: cursor, limit: limit, expectedRevision: expectedRevision,
                    allowRetry: false, queryBudgetNanoseconds: queryBudgetNanoseconds > elapsed ? queryBudgetNanoseconds - elapsed : 0)
            }
            throw panelError("stale_revision", "The panel changed during this read. Retry using its current revision.")
        }
        let next = PanelCursor(epoch: epoch, revision: state.revision, ordinal: offset + result.next, dataRevision: state.dataRevision, sourceGeneration: state.sourceGeneration)
        return .init(state: state, rows: result.rows, cursor: next.encoded, count: result.rows.count,
                     hasMore: result.next < snapshot.count, cursorTruncated: (parsed?.ordinal ?? offset) < offset,
                     timedOut: false, changed: changeReason != nil,
                     outputTruncated: result.truncated, changeReason: changeReason,
                     dataChanged: supplied.map { $0.dataRevision != state.dataRevision } ?? false, pending: false)
    }

    public func waitPanel(
        cursor: String? = nil, limit: Int = 50, timeout: TimeInterval = 5,
        expectedRevision: UInt64? = nil
    ) async throws -> DeviceLogPanelReadPage {
        guard timeout.isFinite, (0...30).contains(timeout) else { throw panelError("invalid_timeout", "timeout must be between 0 and 30 seconds.") }
        let deadline = Date().addingTimeInterval(timeout)
        let initial = panelState()
        var nextCursor = cursor ?? PanelCursor(epoch: panelEpoch, revision: panelRevision,
                                               ordinal: rowOffset + rows.count, dataRevision: panelDataRevision, sourceGeneration: sourceGeneration).encoded
        while true {
            try Task.checkCancellation()
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let budget = UInt64(min(0.05, remaining) * 1_000_000_000)
            let page = try await readPanelSnapshot(cursor: nextCursor, limit: limit, expectedRevision: expectedRevision,
                                                  allowRetry: true, queryBudgetNanoseconds: max(1_000_000, budget))
            if !page.rows.isEmpty || page.changed || page.cursorTruncated || page.state.captureState != initial.captureState
                || ["unavailable", "stopped", "paused"].contains(page.state.captureState) { return page }
            nextCursor = page.cursor
            if Date() >= deadline {
                return .init(state: page.state, rows: [], cursor: page.cursor, count: 0,
                             hasMore: page.hasMore, cursorTruncated: page.cursorTruncated, timedOut: true,
                             changed: page.changed, outputTruncated: page.outputTruncated,
                             changeReason: page.changeReason, dataChanged: page.dataChanged, pending: page.pending)
            }
            if !page.hasMore || page.pending {
                try await Task.sleep(for: .milliseconds(Int64(min(50, max(1, deadline.timeIntervalSinceNow * 1_000)))))
            }
        }
    }

    /// Revealing is the only read-side operation that changes selection or scrolling. UUID row
    /// identity is checked against the current ring before the table uses its immutable snapshot.
    public func revealPanel(
        rowID: String, throughRowID: String? = nil, expectedRevision: UInt64? = nil
    ) async throws -> DeviceLogPanelState {
        try requireRevision(expectedRevision)
        guard projectionTask == nil || (completedProjectionFocus == focus && completedProjectionContext == showingContext) else {
            throw panelError("projection_pending", "The shared panel projection is still updating. Retry when it is ready.")
        }
        let snapshot = projectedRows ?? rows
        let displayEntries = entries
        let epoch = panelEpoch
        let revision = panelRevision
        let offset = projectedRows == nil ? rowOffset : projectedRowOffset
        let selectedFocus = focus
        let result = await Task.detached(priority: .userInitiated) {
            let start = snapshot.firstIndex { $0.id == rowID }
            let end = throughRowID.flatMap { id in snapshot.firstIndex { $0.id == id } } ?? start
            guard let start, let end, end >= start, end - start < 200 else {
                return (entries: [LogDisplayEntry](), selection: [Int](), error: "row_unavailable")
            }
            guard selectedFocus.matches(snapshot[start]), selectedFocus.matches(snapshot[end]) else {
                return (entries: [LogDisplayEntry](), selection: [Int](), error: "row_filtered")
            }
            let selected = displayEntries.indices.filter { position in
                guard case .row(let index) = displayEntries[position] else { return false }
                return (start...end).contains(index) && selectedFocus.matches(snapshot[index])
            }
            return (entries: displayEntries, selection: selected, error: "")
        }.value
        guard revision == panelRevision, epoch == panelEpoch else { throw panelError("stale_revision", "The panel changed during reveal.") }
        guard result.error.isEmpty else {
            throw panelError(result.error, result.error == "row_filtered"
                             ? "The requested row is excluded by the active panel filter. Change the filter before revealing it."
                             : "The requested stable row IDs are unavailable or the range exceeds 200 rows.")
        }
        guard rows.contains(where: { $0.id == rowID }),
              rows.contains(where: { $0.id == (throughRowID ?? rowID) }) else {
            throw panelError("row_unavailable", "The requested rows left the bounded ring during reveal.")
        }
        projectionTask?.cancel(); projectionTask = nil; projectionGeneration += 1
        projectedRows = snapshot
        projectedRowOffset = offset
        entries = result.entries
        updatingTable = true
        revealingLinked = true
        table.reloadData()
        let selection = IndexSet(result.selection)
        table.selectRowIndexes(selection, byExtendingSelection: false)
        if let first = selection.first { table.scrollRowToVisible(first) }
        revealingLinked = false
        updatingTable = false
        if isFollowing { isFollowing = false; panelRevision &+= 1 }
        updateFollowAffordance()
        updateStatus()
        return panelState()
    }

}

// MARK: - Filter field

extension DeviceLogPaneViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        // The person is driving again, so the agent's note stops describing what they are seeing.
        clearAgentNote()
        showingContext = false
        contextPopUp.selectItem(at: 0)
        if notification.object as? ThemedTextField === subsystemField {
            sharedFilter.subsystem = nonempty(subsystemField.stringValue)
        } else if notification.object as? ThemedTextField === categoryField {
            sharedFilter.category = nonempty(categoryField.stringValue)
        } else {
            let text = filterField.stringValue
            guard text.utf8.count <= 512 else { statusLabel.stringValue = "Text filter exceeds 512 bytes"; return }
            if sharedFilter.textMode == .regex, (try? NSRegularExpression(pattern: text)) == nil {
                statusLabel.stringValue = "Invalid regular expression"
                return
            }
            filter = text
        }
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
            if focus.isActive, focus.textMode != .regex, focus.matches(entry), identifier == Columns.message {
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
        panelRevision &+= 1
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
        case Columns.subsystem: return entry.subsystemLabel ?? ""
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
