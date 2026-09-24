import AppKit
import ImageIO
import ThreadingSimulatorKit

enum SimulatorPaneAgentResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

struct SimulatorPaneScreenshot: Sendable {
    let data: Data
    let device: SimulatorDevice
}

struct SimulatorPaneAccessibilitySnapshot: Sendable {
    let root: SimulatorAccessibilityElement
    let device: SimulatorDevice
}

/// Apple Simulator's own chords (its Device and Features menus) for the actions this pane can
/// perform, so the muscle memory carries over. They apply only while keyboard focus is inside the
/// pane: several collide with app commands — ⇧⌘B is Browser — and the app's binding wins
/// everywhere else. Simulator's Rotate (⌘←/→), Shake (⌃⌘Z), Siri (⌥⇧⌘H) and App Switcher
/// (⌃⇧⌘H) have no route in the helper's input vocabulary yet, so they are deliberately absent.
enum SimulatorPaneShortcuts {
    static let home = KeyboardShortcut(key: "h", modifiers: [.command, .shift])
    static let lock = KeyboardShortcut(key: "l", modifiers: .command)
    static let sideButton = KeyboardShortcut(key: "b", modifiers: [.command, .shift])
    static let volumeUp = KeyboardShortcut(key: "\u{F700}", modifiers: .command)
    static let volumeDown = KeyboardShortcut(key: "\u{F701}", modifiers: .command)
    static let toggleAppearance = KeyboardShortcut(key: "a", modifiers: [.command, .shift])
}

/// The pane's glyphs, named once so the toolbar, its menus and the commands agree. Each was chosen
/// against its neighbours: the screenshot is the camera, so the element inspector is not a
/// viewfinder beside it; the touches toggle is the tap, so enabling control is the pointer.
enum SimulatorPaneSymbols {
    static let screenshot = "camera"
    static let copyScreenshot = "doc.on.doc"
    static let record = "record.circle"
    static let stopRecording = "stop.circle"
    static let touches = "hand.tap"
    static let inspect = "accessibility"
    static let presenter = "macwindow.on.rectangle"
    static let control = "cursorarrow.click"
    static let controlDenied = "cursorarrow.slash"
    static let appearance = "circle.lefthalf.filled"
}

/// A session's adopted CoreSimulator device inside the right display pane.
///
/// The signed helper is the default live renderer; bounded `simctl` screenshots remain its public
/// view-only fallback. Both feed this controller so a backend change cannot create another tab
/// kind, device lease or agent-visible identity.
@MainActor
final class SimulatorPaneViewController: NSViewController {

    enum PresentationState: Equatable {
        case idle
        case discovering
        case preparing(SimulatorDeviceID)
        case ready(SimulatorDevice)
        case failed(String)
    }

    private enum Timing {
        /// A public-process fallback, not the eventual live stream. One frame per second makes
        /// progress visible without pretending repeated `simctl` launches are a 30 fps backend.
        static let fallbackFrameInterval: UInt64 = 1_000_000_000
        /// How long a hidden pane keeps its direct helper. A glance at another session and back
        /// stays live; a pane left behind returns its helper and its slot in the app-wide stream
        /// budget. Kept for the life of the tab instead, every session that had ever shown one
        /// held a helper, and the fifth session's pane was refused into the screenshot fallback.
        static let hiddenTransportGrace: Duration = .seconds(15)
        /// How long an agent screenshot waits for the live stream's next frame. The helper
        /// captures continuously at 30 fps, so a frame is normally tens of milliseconds away;
        /// silence past this means the stream is not delivering, and the public capture answers.
        static let liveFrameWait: Duration = .seconds(1)
    }

    private enum ControlActivity: Equatable {
        case idle
        case connecting
        case failed(String)
    }

    private enum ControlAuthorizationError: LocalizedError {
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .denied(let deviceName):
                L10n.format("Simulator control was not allowed for %@.", deviceName)
            }
        }
    }

    private let control: any SimulatorControlling
    private let leaseManager: any SimulatorLeaseManaging
    private let streamCoordinator: any SimulatorLiveStreamCoordinating
    private let inputAuthorizer: any SimulatorInputAuthorizing
    private var preferredDeviceID: SimulatorDeviceID?
    private var devices: [SimulatorDevice] = []
    private var lease: SimulatorDeviceLease?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var preparationCompletions: [
        @MainActor @Sendable (SimulatorPaneAgentResult<SimulatorDeviceLease>) -> Void
    ] = []
    private var streamTask: Task<Void, Never>?
    private var streamSession: (any SimulatorLiveStreamSession)?
    private var streamGeneration = 0
    private var fallbackTask: Task<Void, Never>?
    private var fallbackGeneration = 0
    private var liveBackend: SimulatorLiveBackend?
    private var liveCapabilities: SimulatorBridgeCapabilities?
    private var lastStreamFailure: String?
    private var requiresLeaseRefresh = false
    private var controlActivity: ControlActivity = .idle
    private var controlAuthorizationDecisions: [SimulatorDeviceID: Bool] = [:]
    private var agentCommandTasks: [UUID: Task<Void, Never>] = [:]
    private var isPresented = false

    /// Whether anything is showing the device's pixels: the pane, its presenter window, or a
    /// touch-inclusive recording that composites every frame it is fed. The stream's demand
    /// follows this, not the pane's visibility alone — a person sharing the presenter window on a
    /// call, or recording, keeps a live device while they switch to another session.
    private var wantsFrames: Bool {
        isPresented || presenter != nil || streamRecorder != nil
    }
    private let hiddenTransportGrace: Duration
    private let liveFrameWait: Duration
    private var hiddenTransportReleaseTask: Task<Void, Never>?
    /// Agent screenshots waiting for the next decoded live frame; resumed with nil when the
    /// transport stops or the pane hides, so a waiter never outlives the stream it waits on.
    private var liveFrameWaiters: [UUID: CheckedContinuation<SimulatorLiveFrame?, Never>] = [:]
    /// Public `simctl` device transactions in flight. The private framebuffer stream must not be
    /// opened while one runs (see `installAndLaunchForAgent`).
    private var publicTransactionCount = 0

    private(set) var presentationState: PresentationState = .idle {
        didSet { renderState() }
    }

    var selectedDeviceID: SimulatorDeviceID? {
        lease?.device.id ?? preferredDeviceID
    }

    var adoptedDevice: SimulatorDevice? { lease?.device }
    var canAnnotateNotes: Bool { isPresented && lease != nil && screenView.image != nil }

    var onSelectedDeviceChange: ((SimulatorDeviceID) -> Void)?

    private lazy var deviceChip: ChipView = {
        let chip = ChipView()
        chip.configure(symbolName: "iphone", title: L10n.string("Choose Simulator"))
        chip.itemsProvider = { [weak self] in self?.deviceEntries() ?? [] }
        chip.onSelect = { [weak self] item in
            guard let rawValue = item.representedValue as? String,
                  let id = SimulatorDeviceID(rawValue) else { return }
            self?.selectDevice(id)
        }
        chip.setAccessibilityIdentifier("simulator.device")
        return chip
    }()

    private lazy var retryButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "arrow.clockwise",
            accessibility: L10n.string("Refresh Simulator"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Refresh Simulator")
        button.onPress = { [weak self] in self?.retry() }
        button.setAccessibilityIdentifier("simulator.refresh")
        return button
    }()

    private lazy var controlButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.control,
            accessibility: L10n.string("Enable Simulator Control"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Enable Simulator Control")
        button.onPress = { [weak self] in self?.requestControl() }
        button.setAccessibilityIdentifier("simulator.control")
        return button
    }()

    private lazy var appearanceButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.appearance,
            accessibility: L10n.string("Toggle appearance"),
            target: .device,
            inkSource: .chrome
        )
        button.toolTip = L10n.format(
            "%1$@ (%2$@)",
            L10n.string("Toggle appearance"),
            SimulatorPaneShortcuts.toggleAppearance.displayString
        )
        button.onPress = { [weak self] in self?.toggleAppearance() }
        button.setAccessibilityIdentifier("simulator.appearance")
        return button
    }()

    /// Tracked locally because `simctl` does not report the device's current appearance; a press
    /// flips this and applies it, so the toggle stays in step with what the person last did.
    private var appearanceIsDark = false

    private lazy var inspectButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.inspect,
            accessibility: L10n.string("Inspect elements"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Outline the accessibility elements — click one to copy its target")
        button.onPress = { [weak self] in self?.toggleInspection() }
        button.setAccessibilityIdentifier("simulator.inspect")
        return button
    }()

    private lazy var annotateButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: DesignSymbols.annotate,
            accessibility: L10n.string("Annotate device"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Annotate device (Option-click to add a note without switching modes)")
        button.onPress = { [weak self] in self?.toggleAnnotating() }
        button.onContextMenu = { [weak self] anchor in
            self?.presentAnnotationMenu(from: anchor) ?? false
        }
        button.setAccessibilityIdentifier("simulator.annotate")
        return button
    }()

    private lazy var captureButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.screenshot,
            accessibility: L10n.string("Save Screenshot"),
            target: .inline,
            inkSource: .chrome
        )
        button.onContextMenu = { [weak self] anchor in
            self?.presentCaptureMenu(from: anchor) ?? false
        }
        button.setAccessibilityIdentifier("simulator.capture")
        return button
    }()

    private let captureModifierMonitor = LocalEventMonitor()
    private var captureCopiesSnapshot = false

    private var captureMenuSession: AnyObject?

    /// Recording has a button of its own. It shared the screenshot button's right-click menu,
    /// which left starting one undiscoverable and a running one visible only as that button's
    /// selected state.
    private lazy var recordButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.record,
            accessibility: L10n.string("Record Video"),
            target: .inline,
            inkSource: .chrome
        )
        button.onPress = { [weak self] in self?.toggleRecording() }
        button.onContextMenu = { [weak self] anchor in
            self?.presentRecordMenu(from: anchor) ?? false
        }
        button.setAccessibilityIdentifier("simulator.record")
        return button
    }()

    private var recordMenuSession: AnyObject?
    private let simctlRecorder = SimulatorSimctlRecorder()
    /// Non-nil while recording via the stream engine (composites the touch overlay).
    private var streamRecorder: SimulatorStreamRecorder?
    private var isRecording = false
    /// Between the stop and the finished file: the movie is being written.
    private var isFinishingRecording = false
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    /// Where recordings are written; nil is the Movies ▸ Threading default. A test seam, so a
    /// hosted test never writes into the developer's own Movies folder.
    private let recordingDirectory: URL?
    /// Reveals a saved capture. A test seam for the same reason as the directory above.
    private let revealCapture: @MainActor (URL) -> Void

    /// The "this is being recorded" mark over the device, and its stop control.
    private lazy var recordingBadge: SimulatorRecordingBadge = {
        let badge = SimulatorRecordingBadge()
        badge.onPress = { [weak self] in self?.stopRecording() }
        badge.isHidden = true
        return badge
    }()

    private lazy var showTouchesButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.touches,
            accessibility: L10n.string("Show Touches"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Show taps and swipes on the device (right-click for style)")
        button.onPress = { [weak self] in self?.toggleShowTouches() }
        button.onContextMenu = { [weak self] anchor in
            self?.presentTouchMenu(from: anchor) ?? false
        }
        button.setAccessibilityIdentifier("simulator.showTouches")
        return button
    }()

    private var touchMenuSession: AnyObject?
    private let touchOverlayModel = SimulatorTouchOverlayModel()
    private let touchPreferences: SimulatorTouchPreferences
    private var touchPreferencesObserver: NSObjectProtocol?
    private var showTouches: Bool { touchPreferences.showsLiveTouches }
    private var touchDisplayTimer: Timer?

    /// The device alone in a window of its own, for sharing on a call.
    private lazy var presenterButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.presenter,
            accessibility: L10n.string("Open Presenter Window"),
            target: .inline,
            inkSource: .chrome
        )
        button.onPress = { [weak self] in self?.togglePresenterWindow() }
        button.setAccessibilityIdentifier("simulator.presenter")
        return button
    }()

    private var presenter: SimulatorPresenterWindowController?
    /// Shows a presenter window. A test seam: a hosted test builds the window but never orders it
    /// on screen.
    private let showPresenterWindow: @MainActor (SimulatorPresenterWindowController) -> Void
    private var screenMenuSession: AnyObject?

    private var annotationMenuSession: AnyObject?

    /// Whether the person is placing their own note pins on the device.
    private var isAnnotatingNotes = false
    /// The floating note editor while one is open, and the note it edits.
    private var noteEditor: BrowserAnnotationEditor?
    private var editingNoteID: ImageAnnotation.ID?
    private let annotationStore = SimulatorAnnotationStore.shared

    /// The session these notes are handed to when the person presses Send. Set by the display pane.
    var annotationSessionID: SessionID?
    private var isSendingNotes = false
    private var exportConfirmationTimer: Timer?

    /// The band that says annotation mode is on, what a click does in it and how to leave. It
    /// replaced a floating "Annotating · Esc to finish" button over the device's status bar, which
    /// covered device content and read as part of the app under it.
    private var annotationBand: PaneNoticeView?
    /// Whether the band currently offers Clear All — rebuilt only when that changes.
    private var annotationBandOffersClear = false
    private lazy var screenTopToControlRow = screenView.topAnchor.constraint(
        equalTo: controlRow.bottomAnchor,
        constant: Design.Spacing.medium
    )

    private lazy var noteSendBar: AnnotationSendBar = {
        let bar = AnnotationSendBar()
        bar.onSend = { [weak self] in self?.sendPendingNotes() }
        bar.isHidden = true
        return bar
    }()

    /// Delivered notes are removed; every remaining nonempty note is pending.
    private var pendingNotes: [ImageAnnotation] {
        screenView.noteMarks.filter { !$0.note.isEmpty }
    }

    /// Whether the accessibility inspector overlay is on. Reading the tree is a host-side call, so
    /// this is a manual refresh (toggle) in Phase 1 rather than a per-frame poll.
    private var isInspecting = false

    /// Capture first (screenshot, record), then what draws over the device (touches, notes,
    /// element outlines), then where it is shown (the presenter window), then the connection
    /// (control, refresh). Device settings live with the hardware buttons under the screen.
    private lazy var controlRow = ControlRowView(
        leading: [deviceChip],
        trailing: [
            captureButton, recordButton, showTouchesButton, annotateButton,
            inspectButton, presenterButton, controlButton, retryButton,
        ]
    )

    private func makeHardwareButton(
        symbol: String,
        title: String,
        identifier: String,
        button: SimulatorBridgeButton,
        shortcut: KeyboardShortcut
    ) -> ThemedIconButton {
        let control = ThemedIconButton(
            symbolName: symbol,
            accessibility: title,
            target: .device,
            inkSource: .chrome
        )
        control.toolTip = L10n.format("%1$@ (%2$@)", title, shortcut.displayString)
        control.setAccessibilityIdentifier(identifier)
        control.onPress = { [weak self] in self?.submitInput(.button(button)) }
        return control
    }

    private lazy var homeButton = makeHardwareButton(
        symbol: "house", title: L10n.string("Home"),
        identifier: "simulator.button.home", button: .home,
        shortcut: SimulatorPaneShortcuts.home
    )
    private lazy var lockButton = makeHardwareButton(
        symbol: "lock", title: L10n.string("Lock"),
        identifier: "simulator.button.lock", button: .lock,
        shortcut: SimulatorPaneShortcuts.lock
    )
    private lazy var sideButton = makeHardwareButton(
        symbol: "power", title: L10n.string("Side button"),
        identifier: "simulator.button.side", button: .side,
        shortcut: SimulatorPaneShortcuts.sideButton
    )
    private lazy var volumeDownButton = makeHardwareButton(
        symbol: "speaker.minus", title: L10n.string("Volume down"),
        identifier: "simulator.button.volumeDown", button: .volumeDown,
        shortcut: SimulatorPaneShortcuts.volumeDown
    )
    private lazy var volumeUpButton = makeHardwareButton(
        symbol: "speaker.plus", title: L10n.string("Volume up"),
        identifier: "simulator.button.volumeUp", button: .volumeUp,
        shortcut: SimulatorPaneShortcuts.volumeUp
    )

    private var hardwareButtons: [ThemedIconButton] {
        [homeButton, lockButton, sideButton, volumeDownButton, volumeUpButton]
    }

    /// Each chord presses its button rather than calling the action beside it, so a shortcut is
    /// enabled, consented and fails closed exactly as a click on that button would.
    private var shortcutButtons: [(shortcut: KeyboardShortcut, button: ThemedIconButton)] {
        [
            (SimulatorPaneShortcuts.home, homeButton),
            (SimulatorPaneShortcuts.lock, lockButton),
            (SimulatorPaneShortcuts.sideButton, sideButton),
            (SimulatorPaneShortcuts.volumeUp, volumeUpButton),
            (SimulatorPaneShortcuts.volumeDown, volumeDownButton),
            (SimulatorPaneShortcuts.toggleAppearance, appearanceButton),
        ]
    }

    /// The device's hardware buttons, then its appearance. A press converges on the same consented
    /// input path as a tap, so it asks for control the first time and fails closed when the lease
    /// or consent is gone. Appearance is a device setting rather than HID input, and sits apart.
    private lazy var hardwareButtonRow: NSStackView = {
        let stack = NSStackView(views: hardwareButtons + [appearanceButton])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.large
        stack.setCustomSpacing(Design.Spacing.pane, after: volumeUpButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("simulator.hardwareButtons")
        return stack
    }()

    private lazy var screenView: SimulatorScreenView = {
        let preview = SimulatorScreenView()
        preview.setAccessibilityLabel(L10n.string("Simulator screen"))
        preview.setAccessibilityIdentifier("simulator.screen")
        preview.onTap = { [weak self] point in
            self?.submitInput(.tap(x: Double(point.x), y: Double(point.y)))
        }
        preview.onTouchBegan = { [weak self] point in self?.beginTouchStream(at: point) }
        preview.onTouchMoved = { [weak self] point in self?.moveTouchStream(to: point) }
        preview.onTouchEnded = { [weak self] point in self?.endTouchStream(at: point) }
        preview.onScroll = { [weak self] point, deltaX, deltaY in
            self?.scrollDevice(at: point, deltaX: deltaX, deltaY: deltaY)
        }
        preview.onText = { [weak self] text in self?.submitInput(.text(text)) }
        preview.onAddNote = { [weak self] point in self?.addNote(at: point) }
        preview.onSelectNote = { [weak self] id in self?.selectNote(id) }
        preview.onDeleteNote = { [weak self] id in self?.deleteHoveredNote(id) }
        preview.onClearAllNotes = { [weak self] in self?.clearAllNotes() }
        preview.onCommandReturn = { [weak self] in self?.sendPendingNotes() }
        preview.onContextMenu = { [weak self] request in
            guard let self else { return false }
            return self.presentScreenMenu(request, from: self.screenView, includesNotes: true)
        }
        return preview
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("simulator.status")
        return label
    }()

    init(
        preferredDeviceID: SimulatorDeviceID? = nil,
        control: any SimulatorControlling,
        leaseManager: (any SimulatorLeaseManaging)? = nil,
        streamCoordinator: any SimulatorLiveStreamCoordinating = SimulatorLiveStreamCoordinator.shared,
        inputAuthorizer: any SimulatorInputAuthorizing = SimulatorInputConsentController.shared,
        hiddenTransportGrace: Duration? = nil,
        liveFrameWait: Duration? = nil,
        touchPreferences: SimulatorTouchPreferences? = nil,
        recordingDirectory: URL? = nil,
        revealCapture: (@MainActor (URL) -> Void)? = nil,
        showPresenterWindow: (@MainActor (SimulatorPresenterWindowController) -> Void)? = nil
    ) {
        self.preferredDeviceID = preferredDeviceID
        self.control = control
        self.leaseManager = leaseManager ?? SimulatorLeaseManager(control: control)
        self.streamCoordinator = streamCoordinator
        self.inputAuthorizer = inputAuthorizer
        self.hiddenTransportGrace = hiddenTransportGrace ?? Timing.hiddenTransportGrace
        self.liveFrameWait = liveFrameWait ?? Timing.liveFrameWait
        self.touchPreferences = touchPreferences ?? .shared
        self.recordingDirectory = recordingDirectory
        self.revealCapture = revealCapture ?? { SimulatorCaptureSaver.reveal($0) }
        self.showPresenterWindow = showPresenterWindow ?? { $0.showWindow(nil) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = KeyEquivalentScopeView()
        root.setAccessibilityIdentifier("simulator.pane")
        root.onKeyEquivalent = { [weak self] event in self?.performSimulatorShortcut(event) ?? false }
        view = root
    }

    private func performSimulatorShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(KeyboardShortcut.eventModifierMask)
        if event.keyCode == 53, modifiers.isEmpty {
            if noteEditor != nil { cancelNoteEditor(); return true }
            if isAnnotatingNotes { finishAnnotating(); return true }
        }
        if (event.keyCode == 36 || event.keyCode == 76), modifiers == .command,
           noteEditor != nil || !pendingNotes.isEmpty {
            sendPendingNotes()
            return true
        }
        guard let match = shortcutButtons.first(where: { $0.shortcut.matches(event) }) else {
            return false
        }
        // Claimed even while the button is unavailable: a focused device pane must not hand ⇧⌘B
        // on to the Browser command just because its stream is reconnecting.
        _ = match.button.performPrimaryAction()
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        touchPreferencesObserver = NotificationCenter.default.addObserver(
            forName: SimulatorTouchPreferences.didChange,
            object: touchPreferences,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTouchPreferences() }
        }
        applyTouchPreferences()
        refreshCaptureButton()
        refreshRecordingPresentation()
        refreshPresenterButton()
        renderState()
    }

    private func setupUI() {
        view.addSubview(controlRow)
        view.addSubview(screenView)
        view.addSubview(hardwareButtonRow)
        view.addSubview(statusLabel)
        view.addSubview(noteSendBar)
        view.addSubview(recordingBadge)

        NSLayoutConstraint.activate([
            // Over the device's top centre — the status bar's quietest spot, and the margin above
            // the device whenever the pane is taller than the device's aspect.
            recordingBadge.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            recordingBadge.topAnchor.constraint(equalTo: screenView.topAnchor,
                                                constant: Design.Spacing.small),
            recordingBadge.widthAnchor.constraint(lessThanOrEqualTo: screenView.widthAnchor),
            // Floats over the framebuffer's bottom-trailing while annotating, like the browser's.
            noteSendBar.trailingAnchor.constraint(
                equalTo: screenView.trailingAnchor,
                constant: -Design.Spacing.medium
            ),
            noteSendBar.bottomAnchor.constraint(
                equalTo: screenView.bottomAnchor,
                constant: -Design.Spacing.medium
            ),

            controlRow.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: Design.Spacing.medium
            ),
            controlRow.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            controlRow.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),

            screenTopToControlRow,
            screenView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            screenView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            screenView.bottomAnchor.constraint(
                equalTo: hardwareButtonRow.topAnchor,
                constant: -Design.Spacing.medium
            ),

            hardwareButtonRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hardwareButtonRow.bottomAnchor.constraint(
                equalTo: statusLabel.topAnchor,
                constant: -Design.Spacing.medium
            ),

            statusLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            statusLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            statusLabel.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    /// The display host states visibility explicitly because AppKit keeps tab controllers as
    /// children while their views are detached. Hidden means zero framebuffer requests.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            updateCaptureModifiers(NSEvent.modifierFlags)
            captureModifierMonitor.install(
                matching: [.flagsChanged, .leftMouseDown, .keyDown, .appKitDefined]
            ) { [weak self] event in
                guard let self else { return event }
                // Activation can follow a Control release in another app, where no local
                // flagsChanged event was delivered. Resample the keyboard on that transition.
                if event.type == .appKitDefined {
                    self.updateCaptureModifiers(NSEvent.modifierFlags)
                } else if event.type == .flagsChanged || event.window === self.view.window {
                    self.updateCaptureModifiers(event.modifierFlags)
                }
                return event
            }
            hiddenTransportReleaseTask?.cancel()
            hiddenTransportReleaseTask = nil
            if let lease {
                presentationState = .ready(lease.device)
                // The stream can drop while the pane is hidden (a helper loss, or a background
                // install/launch), which parks it on the screenshot fallback. Reconnecting the
                // direct transport on the way back in means the returning pane is controllable on
                // the first click, instead of spending that click to reconnect. A healthy hidden
                // stream is not on the fallback, so this is a no-op there and `startFrameLoop`
                // simply re-shows it.
                reconnectTransportForInputIfNeeded(on: lease.device.id)
                startFrameLoop()
            } else if preparationTask == nil {
                prepare(preferredDeviceID)
            }
        } else {
            captureModifierMonitor.remove()
            releaseFramesIfUnwatched()
        }
        renderState()
    }

    /// The pane, its presenter window and a touch-inclusive recording each hold the stream open;
    /// the last of them to go stops asking for frames and starts the hidden-transport grace.
    private func releaseFramesIfUnwatched() {
        guard !wantsFrames else { return }
        stopFrameLoop()
        scheduleHiddenTransportRelease()
    }

    /// Explicit tab/session teardown. A user-owned boot stays running; a Threading-owned boot is
    /// handed back through the lease capability without retaining this controller.
    func terminate() {
        captureModifierMonitor.remove()
        if let touchPreferencesObserver {
            NotificationCenter.default.removeObserver(touchPreferencesObserver)
            self.touchPreferencesObserver = nil
        }
        // A movie left unfinished is unplayable; closing the tab finishes it where it stands.
        if isRecording { stopRecording() }
        closePresenterWindow()
        isPresented = false
        hiddenTransportReleaseTask?.cancel()
        hiddenTransportReleaseTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration += 1
        finishPreparation(.failure("The Simulator pane was closed."))
        agentCommandTasks.values.forEach { $0.cancel() }
        agentCommandTasks.removeAll()
        stopTransport()
        let releasedLease = lease
        lease = nil
        guard let releasedLease else { return }
        Task { await leaseManager.release(releasedLease) }
    }

    func selectDevice(_ id: SimulatorDeviceID) {
        guard id != selectedDeviceID else { return }
        // A recording is of one device; switching ends it rather than splicing another in.
        if isRecording { stopRecording() }
        if noteEditor != nil { commitNoteEditor() }
        setAnnotatingNotes(false)
        screenView.noteMarks = []
        screenView.selectedNoteID = nil
        updateSendBar()
        controlActivity = .idle
        preferredDeviceID = id
        prepare(id, releasingCurrentLease: true)
    }

    /// Agent commands enter through the same lease as the visible pane. This is the adoption
    /// boundary: the agent asks Threading for a device instead of launching Simulator.app and
    /// cannot accidentally create a second, invisible CoreSimulator owner.
    func prepareForAgent(
        deviceID: SimulatorDeviceID?,
        completion: @escaping @MainActor @Sendable (
            SimulatorPaneAgentResult<SimulatorDeviceLease>
        ) -> Void
    ) {
        if let lease, deviceID == nil || lease.device.id == deviceID {
            completion(.success(lease))
            return
        }

        preparationCompletions.append(completion)
        if preparationTask != nil, deviceID == nil || preferredDeviceID == deviceID {
            return
        }

        preferredDeviceID = deviceID
        prepare(deviceID, releasingCurrentLease: lease != nil)
    }

    func installAndLaunchForAgent(
        applicationURL: URL,
        bundleIdentifier: String,
        arguments: [String],
        completion: @escaping @MainActor @Sendable (
            SimulatorPaneAgentResult<SimulatorLaunchReceipt>
        ) -> Void
    ) {
        guard let lease else {
            completion(.failure("Call simulator_prepare before installing an app."))
            return
        }
        let deviceID = lease.device.id
        let control = control
        runAgentCommand { [weak self] in
            guard let self else { return }
            // CoreSimulator does not serialize its public simctl mutations against the private
            // framebuffer service for us. Keeping the adopted stream open while install/launch
            // runs can wedge both services: the helper remains connected but sends no frames,
            // while simctl never answers. Quiesce the one pane-owned transport for the bounded
            // public mutation, then establish a fresh stream against the launched process.
            self.stopTransport()
            self.publicTransactionCount += 1
            defer {
                self.publicTransactionCount -= 1
                if self.wantsFrames, self.lease?.device.id == deviceID {
                    self.startFrameLoop()
                }
            }
            do {
                let receipt = try await control.installAndLaunch(
                    applicationURL: applicationURL,
                    bundleIdentifier: bundleIdentifier,
                    on: deviceID,
                    arguments: arguments
                )
                try Task.checkCancellation()
                guard self.lease?.device.id == deviceID else {
                    completion(.failure("The selected Simulator changed during launch."))
                    return
                }
                completion(.success(receipt))
            } catch is CancellationError {
                completion(.failure("The Simulator launch was cancelled."))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    func screenshotForAgent(
        completion: @escaping @MainActor @Sendable (
            SimulatorPaneAgentResult<SimulatorPaneScreenshot>
        ) -> Void
    ) {
        guard let device = lease?.device else {
            completion(.failure("Call simulator_prepare before capturing the Simulator."))
            return
        }
        let control = control
        runAgentCommand { [weak self] in
            guard let self else { return }
            // A visible pane already holds the device's pixels. Answering from its next live frame
            // costs no public transaction, so the stream keeps running and the agent's following
            // tap or element read finds it connected rather than mid-reconnect.
            if let frame = await self.nextLiveFrame() {
                guard let png = await Self.encodedPNG(frame) else {
                    completion(.failure("The live Simulator frame could not be encoded."))
                    return
                }
                guard self.lease?.device.id == device.id else {
                    completion(.failure("The selected Simulator changed during capture."))
                    return
                }
                completion(.success(SimulatorPaneScreenshot(data: png, device: device)))
                return
            }
            // A public screenshot is another CoreSimulator service transaction. It must not
            // overlap the adopted private framebuffer stream for the same device; after the
            // capture, reconnect so subsequent input stays on the direct pane transport.
            self.stopTransport()
            self.publicTransactionCount += 1
            defer {
                self.publicTransactionCount -= 1
                if self.wantsFrames, self.lease?.device.id == device.id {
                    self.startFrameLoop()
                }
            }
            do {
                let data = try await control.screenshot(of: device.id)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else {
                    throw SimulatorControlError.invalidScreenshot
                }
                guard self.lease?.device.id == device.id else {
                    completion(.failure("The selected Simulator changed during capture."))
                    return
                }
                self.showFrame(image)
                completion(.success(SimulatorPaneScreenshot(data: data, device: device)))
            } catch is CancellationError {
                completion(.failure("The Simulator capture was cancelled."))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    /// Read the foreground app's accessibility tree once, over the live direct-pane transport (the
    /// same session that carries frames). Unlike a screenshot this needs no public CoreSimulator
    /// transaction, so the stream is left running. When inspection is on, the overlay is refreshed
    /// with the same tree so the agent's view and the pane's outlines agree.
    func snapshotForAgent(
        completion: @escaping @MainActor @Sendable (
            SimulatorPaneAgentResult<SimulatorPaneAccessibilitySnapshot>
        ) -> Void
    ) {
        guard let device = lease?.device else {
            completion(.failure("Call simulator_prepare before reading the Simulator's elements."))
            return
        }
        runAgentCommand { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.awaitLiveSession(for: device.id)
                let root = try await session.requestAccessibilitySnapshot()
                guard self.lease?.device.id == device.id,
                      self.streamSession === session else {
                    completion(.failure("The selected Simulator changed during the read."))
                    return
                }
                if self.isInspecting {
                    self.screenView.annotations = Self.annotations(from: root)
                }
                completion(.success(SimulatorPaneAccessibilitySnapshot(root: root, device: device)))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    /// Capture just one element by cropping the current live frame to its bounds — no public-path
    /// screenshot and no transport stop. Resolves the locator against a fresh snapshot first.
    func elementScreenshotForAgent(
        locator: SimulatorAgentCommandService.ElementLocator,
        completion: @escaping @MainActor @Sendable (
            SimulatorPaneAgentResult<SimulatorPaneScreenshot>
        ) -> Void
    ) {
        guard let device = lease?.device else {
            completion(.failure("Call simulator_prepare before capturing the Simulator."))
            return
        }
        runAgentCommand { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.awaitLiveSession(for: device.id)
                let root = try await session.requestAccessibilitySnapshot()
                guard self.lease?.device.id == device.id,
                      self.streamSession === session else {
                    completion(.failure("The selected Simulator changed during capture."))
                    return
                }
                switch SimulatorElementResolver.resolveElement(locator, in: root) {
                case .element(let element, let width, let height):
                    guard let image = self.screenView.image else {
                        completion(.failure("No Simulator frame is available yet."))
                        return
                    }
                    let normalized = CGRect(
                        x: element.frame.x / width,
                        y: element.frame.y / height,
                        width: element.frame.width / width,
                        height: element.frame.height / height
                    )
                    guard let png = Self.croppedPNG(image, normalizedFrame: normalized) else {
                        completion(.failure("The element is off-screen or too small to capture."))
                        return
                    }
                    completion(.success(SimulatorPaneScreenshot(data: png, device: device)))
                case .notFound(let message), .ambiguous(let message):
                    completion(.failure(message))
                }
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    /// Crop an NSImage to a normalized rect (0…1, top-left origin — matching the framebuffer and the
    /// tap space) and encode PNG. CGImage pixels are top-left origin, so no flip is needed.
    /// `nonisolated`: a pure, bounded transform of a single cropped element, not main-actor work.
    private nonisolated static func croppedPNG(_ image: NSImage, normalizedFrame: CGRect) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: normalizedFrame.minX * width,
            y: normalizedFrame.minY * height,
            width: normalizedFrame.width * width,
            height: normalizedFrame.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }

    private func retry() {
        controlActivity = .idle
        if let lease {
            if requiresLeaseRefresh {
                prepare(
                    lease.device.id,
                    refreshingCurrentLease: true
                )
            } else {
                stopTransport()
                presentationState = .ready(lease.device)
                startFrameLoop()
            }
        } else {
            prepare(preferredDeviceID)
        }
    }

    private func prepare(
        _ requestedID: SimulatorDeviceID?,
        releasingCurrentLease: Bool = false,
        refreshingCurrentLease: Bool = false
    ) {
        preparationTask?.cancel()
        stopTransport()
        presentationState = .discovering
        let leaseManager = leaseManager
        let currentLease = (releasingCurrentLease || refreshingCurrentLease) ? lease : nil
        if currentLease != nil { lease = nil }
        preparationGeneration += 1
        let generation = preparationGeneration

        preparationTask = Task { [weak self] in
            defer {
                if self?.preparationGeneration == generation {
                    self?.preparationTask = nil
                }
            }
            do {
                if let currentLease, !refreshingCurrentLease {
                    await leaseManager.release(currentLease)
                }
                try Task.checkCancellation()
                let devices = try await leaseManager.availableDevices()
                try Task.checkCancellation()
                guard self != nil else { return }
                self?.devices = devices
                let targetID = requestedID
                    ?? devices.first(where: { $0.state.isBooted })?.id
                    ?? devices.first?.id
                guard let targetID else {
                    throw SimulatorControlError.noAvailableIOSDevices
                }
                self?.preferredDeviceID = targetID
                self?.presentationState = .preparing(targetID)

                let preparedLease: SimulatorDeviceLease
                if let currentLease, refreshingCurrentLease {
                    preparedLease = try await leaseManager.refresh(currentLease)
                } else {
                    preparedLease = try await leaseManager.acquire(deviceID: targetID)
                }
                guard !Task.isCancelled, let self else {
                    await leaseManager.release(preparedLease)
                    return
                }
                self.lease = preparedLease
                self.requiresLeaseRefresh = false
                self.preferredDeviceID = preparedLease.device.id
                self.presentationState = .ready(preparedLease.device)
                self.onSelectedDeviceChange?(preparedLease.device.id)
                self.finishPreparation(.success(preparedLease))
                self.startFrameLoop()
            } catch is CancellationError {
                return
            } catch let error as SimulatorControlError where error == .cancelled {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                if refreshingCurrentLease, let currentLease {
                    self.lease = currentLease
                    self.requiresLeaseRefresh = true
                }
                self.presentationState = .failed(error.localizedDescription)
                self.finishPreparation(.failure(error.localizedDescription))
            }
        }
    }

    private func finishPreparation(
        _ result: SimulatorPaneAgentResult<SimulatorDeviceLease>
    ) {
        let completions = preparationCompletions
        preparationCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    private func runAgentCommand(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let id = UUID()
        agentCommandTasks[id] = Task { [weak self] in
            await operation()
            guard let self else { return }
            self.agentCommandTasks[id] = nil
            // A command may have opened the transport of a hidden pane; it goes again once idle.
            if !self.wantsFrames, self.agentCommandTasks.isEmpty {
                self.scheduleHiddenTransportRelease()
            }
        }
    }

    /// A hidden pane captures nothing, but its helper is still a process and a slot in the
    /// app-wide stream budget. Once the pane has stayed hidden for the grace period with no agent
    /// command using it, the transport is released. Showing the pane again, or an agent command
    /// reaching it (its session need not be the one on screen), opens a fresh stream.
    private func scheduleHiddenTransportRelease() {
        hiddenTransportReleaseTask?.cancel()
        hiddenTransportReleaseTask = nil
        guard !wantsFrames,
              streamSession != nil || streamTask != nil || liveBackend != nil else { return }
        let grace = hiddenTransportGrace
        hiddenTransportReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            self.hiddenTransportReleaseTask = nil
            guard !self.wantsFrames, self.agentCommandTasks.isEmpty else { return }
            self.stopTransport()
        }
    }

    private func startFrameLoop() {
        guard wantsFrames, lease != nil else { return }
        if let streamSession {
            streamSession.setVisible(true)
            if let capabilities = liveCapabilities {
                setScreenInteraction(.ready(
                    touch: capabilities.supportsTouch,
                    keyboard: capabilities.supportsKeyboard
                ))
            }
            return
        }
        openTransport()
    }

    /// Opens the direct stream for the adopted device. A presented pane asks the helper for frames;
    /// a hidden one, opened for an agent command, asks for none and gains input and element reads.
    /// Returns whether an open was started.
    @discardableResult
    private func openTransport() -> Bool {
        guard let deviceID = lease?.device.id,
              streamSession == nil, streamTask == nil, fallbackTask == nil,
              publicTransactionCount == 0 else { return false }

        liveBackend = nil
        liveCapabilities = nil
        lastStreamFailure = nil
        streamGeneration += 1
        let generation = streamGeneration
        let coordinator = streamCoordinator
        streamTask = Task { [weak self] in
            do {
                let session = try await coordinator.openStream(for: deviceID)
                guard !Task.isCancelled else {
                    session.stop()
                    return
                }
                guard let self,
                      self.streamGeneration == generation,
                      self.lease?.device.id == deviceID else {
                    session.stop()
                    return
                }
                self.streamSession = session
                session.setVisible(self.wantsFrames)

                var terminalFailure: String?
                for await event in session.events {
                    guard !Task.isCancelled else { break }
                    guard self.streamGeneration == generation,
                          self.lease?.device.id == deviceID else { break }
                    switch event {
                    case .ready(let backend, let capabilities, _, _):
                        self.liveBackend = backend
                        self.liveCapabilities = capabilities
                        self.setScreenInteraction(.ready(
                            touch: capabilities.supportsTouch,
                            keyboard: capabilities.supportsKeyboard
                        ))
                        if let device = self.lease?.device {
                            self.presentationState = .ready(device)
                        }
                    case .frame(let frame):
                        self.showFrame(NSImage(cgImage: frame.image, size: .zero))
                        self.feedStreamRecorder(frame.image)
                        self.resumeLiveFrameWaiters(with: frame)
                    case .statistics:
                        break
                    case .failed(let message):
                        terminalFailure = message
                        break
                    case .ended:
                        terminalFailure = SimulatorLiveStreamError.disconnected.localizedDescription
                    }
                    if terminalFailure != nil { break }
                }

                session.stop()
                guard !Task.isCancelled,
                      self.streamGeneration == generation,
                      self.lease?.device.id == deviceID else { return }
                self.streamSession = nil
                self.streamTask = nil
                let reason = terminalFailure ?? L10n.string("The direct Simulator stream ended.")
                // A hidden pane takes no fallback; the reason still answers the agent command
                // that is waiting on this transport.
                self.lastStreamFailure = reason
                self.beginFallback(reason: reason)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.streamGeneration == generation,
                      self.lease?.device.id == deviceID else { return }
                self.streamTask = nil
                self.lastStreamFailure = error.localizedDescription
                self.beginFallback(reason: error.localizedDescription)
            }
        }
        return true
    }

    private func beginFallback(reason: String) {
        guard wantsFrames, let deviceID = lease?.device.id, fallbackTask == nil else { return }
        liveBackend = .screenshotFallback(reason: reason)
        SimulatorStreamDiagnostics.shared.recordedFallback()
        liveCapabilities = nil
        lastStreamFailure = reason
        setScreenInteraction(.recoverable)
        if let device = lease?.device { presentationState = .ready(device) }

        let control = control
        fallbackGeneration += 1
        let generation = fallbackGeneration
        fallbackTask = Task { [weak self] in
            defer {
                if self?.fallbackGeneration == generation {
                    self?.fallbackTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    let data = try await control.screenshot(of: deviceID)
                    try Task.checkCancellation()
                    guard let image = NSImage(data: data) else {
                        throw SimulatorControlError.invalidScreenshot
                    }
                    guard let self, self.lease?.device.id == deviceID else { return }
                    self.showFrame(image)
                    if let device = self.lease?.device { self.presentationState = .ready(device) }
                    try await Task.sleep(nanoseconds: Timing.fallbackFrameInterval)
                } catch is CancellationError {
                    return
                } catch let error as SimulatorControlError where error == .cancelled {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.requiresLeaseRefresh = true
                    self.setScreenInteraction(.unavailable)
                    self.presentationState = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func stopFrameLoop() {
        setScreenInteraction(.unavailable)
        streamSession?.setVisible(false)
        resumeLiveFrameWaiters(with: nil)
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackGeneration += 1
        if streamSession == nil {
            streamTask?.cancel()
            streamTask = nil
            streamGeneration += 1
        }
    }

    private func stopTransport() {
        scrollGeneration += 1
        scrollAuthorizationInFlight = false
        scrollSession = nil
        pendingScroll = .zero
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        streamGeneration += 1
        streamSession?.stop()
        streamSession = nil
        resumeLiveFrameWaiters(with: nil)
        liveBackend = nil
        liveCapabilities = nil
        lastStreamFailure = nil
        setScreenInteraction(.unavailable)
        // A stale overlay must not hang over a disconnected screen; a fresh read follows a reconnect.
        screenView.annotations = []
    }

    // MARK: - Continuous touch streaming

    private var touchStreamActive = false
    /// The session captured at `began`, so moves stream straight to it — no consent/authorization
    /// path per move, and no per-move round-trip at all.
    private var touchStreamSession: (any SimulatorLiveStreamSession)?
    /// A move that arrived while `began` was still authorizing; sent once the session is captured.
    private var bufferedTouchMove: CGPoint?
    private var scrollSession: (any SimulatorLiveStreamSession)?
    private var pendingScroll: CGPoint = .zero
    private var pendingScrollOrigin = CGPoint(x: 0.5, y: 0.5)
    private var scrollAuthorizationInFlight = false
    private var scrollGeneration = 0

    /// One in-flight swipe consumes bounded accumulated deltas from the cursor's latest point.
    /// The native SimulatorKit scroll packet acknowledged input but did not scroll the guest on
    /// Xcode 26.5, and the mouse-target variant reset SpringBoard, so a wheel tick uses the
    /// existing device touch-drag path that scrollable iOS views understand.
    private func scrollDevice(at point: CGPoint, deltaX: Double, deltaY: Double) {
        guard let device = lease?.device else { return }
        guard effectiveControlDecision != false else { return }
        guard deltaX.isFinite, deltaY.isFinite else { return }
        let delta = CGPoint(
            x: min(64, max(-64, deltaX)),
            y: min(64, max(-64, deltaY))
        )
        guard delta != .zero else { return }
        reconnectTransportForInputIfNeeded(on: device.id)
        pendingScroll.x = min(64, max(-64, pendingScroll.x + delta.x))
        pendingScroll.y = min(64, max(-64, pendingScroll.y + delta.y))
        pendingScrollOrigin = point
        guard !scrollAuthorizationInFlight else { return }
        scrollAuthorizationInFlight = true
        let generation = scrollGeneration
        runAgentCommand { [weak self] in
            guard let self else { return }
            defer {
                if self.scrollGeneration == generation { self.scrollAuthorizationInFlight = false }
            }
            do {
                let session: any SimulatorLiveStreamSession
                if let cached = self.scrollSession,
                   self.streamSession === cached,
                   self.effectiveControlDecision == true {
                    session = cached
                } else {
                    session = try await self.authorizedInputSession(for: device)
                }
                guard self.scrollGeneration == generation,
                      self.lease?.device.id == device.id,
                      self.streamSession === session,
                      self.effectiveControlDecision == true else { return }
                if self.controlActivity != .idle {
                    self.controlActivity = .idle
                    self.renderState()
                }
                self.scrollSession = session
                while self.pendingScroll != .zero {
                    let delta = self.pendingScroll
                    let origin = self.pendingScrollOrigin
                    self.pendingScroll = .zero
                    try await session.sendInput(Self.wheelDrag(at: origin, delta: delta))
                    guard self.scrollGeneration == generation,
                          self.lease?.device.id == device.id,
                          self.streamSession === session else { return }
                }
            } catch {
                guard self.scrollGeneration == generation else { return }
                self.pendingScroll = .zero
                if self.effectiveControlDecision != false {
                    self.controlActivity = .failed(error.localizedDescription)
                    self.renderState()
                }
            }
        }
    }

    private static func wheelDrag(at point: CGPoint, delta: CGPoint) -> SimulatorBridgeInput {
        let horizontal = wheelDragAxis(origin: Double(point.x), lines: Double(delta.x))
        let vertical = wheelDragAxis(origin: Double(point.y), lines: Double(delta.y))
        return .drag(
            fromX: horizontal.start, fromY: vertical.start,
            toX: horizontal.end, toY: vertical.end,
            durationMilliseconds: 140
        )
    }

    private static func wheelDragAxis(origin: Double, lines: Double) -> (start: Double, end: Double) {
        let distance = min(0.5, max(-0.5, lines * 0.06))
        let start = min(0.95 - max(0, distance), max(0.05 - min(0, distance), origin))
        return (start, start + distance)
    }

    /// `began` authorizes once — asking for control and recovering a dropped transport, like a tap
    /// — and captures the live session, sent reliably (awaited). Moves then go through the session's
    /// ordered fire-and-forget `streamInput`: a pan is a fast stream of moves, and gating each on a
    /// round-trip ack is what made it lag. The reliable ordered socket guarantees delivery, and a
    /// dropped move is corrected by the next one. `ended` is likewise ordered after the last move.
    private func beginTouchStream(at point: CGPoint) {
        guard let device = lease?.device else { return }
        feedTouchOverlay { $0.contactBegan(at: point) }
        touchStreamActive = true
        touchStreamSession = nil
        bufferedTouchMove = nil
        runAgentCommand { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.authorizedInputSession(for: device)
                try await session.sendInput(
                    .touch(phase: .began, x: Double(point.x), y: Double(point.y))
                )
                guard self.touchStreamActive else {
                    session.streamInput(.touch(phase: .cancelled, x: Double(point.x), y: Double(point.y)))
                    return
                }
                self.touchStreamSession = session
                if let buffered = self.bufferedTouchMove {
                    self.bufferedTouchMove = nil
                    session.streamInput(
                        .touch(phase: .moved, x: Double(buffered.x), y: Double(buffered.y))
                    )
                }
            } catch {
                self.touchStreamActive = false
            }
        }
    }

    private func moveTouchStream(to point: CGPoint) {
        guard touchStreamActive else { return }
        feedTouchOverlay { $0.contactMoved(to: point) }
        guard let session = touchStreamSession else {
            bufferedTouchMove = point // authorization still in flight; send the latest once ready
            return
        }
        session.streamInput(.touch(phase: .moved, x: Double(point.x), y: Double(point.y)))
    }

    private func endTouchStream(at point: CGPoint) {
        guard touchStreamActive else { return }
        feedTouchOverlay { $0.contactEnded(at: point) }
        touchStreamActive = false
        bufferedTouchMove = nil
        let session = touchStreamSession
        touchStreamSession = nil
        session?.streamInput(.touch(phase: .ended, x: Double(point.x), y: Double(point.y)))
    }

    private func submitInput(_ input: SimulatorBridgeInput) {
        showInputInOverlay(input)
        if liveCapabilities == nil || effectiveControlDecision != true {
            controlActivity = .connecting
            renderState()
        }
        sendInput(input) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.controlActivity = .idle
            case .failure(let message):
                if self.effectiveControlDecision == false {
                    self.controlActivity = .idle
                } else {
                    self.controlActivity = .failed(message)
                }
            }
            self.renderState()
        }
    }

    /// The ordinary, retryable route for a person who wants control without spending a tap.
    /// A prior denial is cleared only here; tapping the screen after denial remains fail-closed
    /// and does not ask again.
    private func requestControl() {
        guard let device = lease?.device else { return }
        let retriesDeniedDecision = effectiveControlDecision == false
        controlActivity = .connecting
        renderState()
        runAgentCommand { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.authorizedInputSession(
                    for: device,
                    resettingDeniedDecision: retriesDeniedDecision
                )
                self.controlActivity = .idle
            } catch is ControlAuthorizationError {
                self.controlActivity = .idle
            } catch is CancellationError {
                self.controlActivity = .failed(L10n.string(
                    "The Simulator input was cancelled."
                ))
            } catch {
                self.controlActivity = .failed(error.localizedDescription)
            }
            self.renderState()
        }
    }

    func sendInputForAgent(
        _ input: SimulatorBridgeInput,
        completion: @escaping @MainActor @Sendable (SimulatorPaneAgentResult<Void>) -> Void
    ) {
        showInputInOverlay(input)
        sendInput(input, completion: completion)
    }

    private func sendInput(
        _ input: SimulatorBridgeInput,
        completion: @escaping @MainActor @Sendable (SimulatorPaneAgentResult<Void>) -> Void
    ) {
        guard let device = lease?.device else {
            completion(.failure("Call simulator_prepare before controlling the Simulator."))
            return
        }
        runAgentCommand { [weak self] in
            guard let self else { return }
            do {
                let session = try await self.authorizedInputSession(for: device)
                try await session.sendInput(input)
                try Task.checkCancellation()
                guard self.lease?.device.id == device.id,
                      self.streamSession === session else {
                    completion(.failure("The selected Simulator changed while input was sent."))
                    return
                }
                completion(.success(()))
            } catch is CancellationError {
                completion(.failure("The Simulator input was cancelled."))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private func authorizedInputSession(
        for device: SimulatorDevice,
        resettingDeniedDecision: Bool = false
    ) async throws -> any SimulatorLiveStreamSession {
        if resettingDeniedDecision {
            inputAuthorizer.resetDecision(for: device.id)
            controlAuthorizationDecisions.removeValue(forKey: device.id)
        }
        reconnectTransportForInputIfNeeded(on: device.id)
        let session = try await awaitLiveSession(for: device.id)
        let approved = await inputAuthorization(for: device)
        controlAuthorizationDecisions[device.id] = approved
        renderState()
        guard approved else {
            throw ControlAuthorizationError.denied(device.name)
        }
        guard lease?.device.id == device.id,
              streamSession === session else {
            throw SimulatorLiveStreamError.helperUnavailable(
                "The selected Simulator changed before input was sent."
            )
        }
        return session
    }

    /// A device install or launch can invalidate an otherwise healthy private framebuffer
    /// connection. The public fallback keeps the pane visible, but an explicit input request is
    /// also a useful one-shot signal to reconnect the direct transport before failing closed.
    /// Stale-device failures still require the stronger lease refresh path owned by Retry.
    private func reconnectTransportForInputIfNeeded(on deviceID: SimulatorDeviceID) {
        guard !requiresLeaseRefresh,
              lease?.device.id == deviceID,
              case .screenshotFallback = liveBackend else { return }
        stopTransport()
        if let device = lease?.device { presentationState = .ready(device) }
        startFrameLoop()
    }

    private func awaitLiveSession(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        var openedOnDemand = false
        while clock.now < deadline {
            try Task.checkCancellation()
            guard lease?.device.id == deviceID else {
                throw SimulatorLiveStreamError.disconnected
            }
            if let streamSession, liveCapabilities != nil { return streamSession }
            if case .screenshotFallback = liveBackend {
                throw SimulatorLiveStreamError.helperUnavailable(
                    "Direct Simulator control is unavailable while the pane uses screenshot fallback."
                )
            }
            // A hidden pane has no transport once its grace lapses, and nothing else will open one
            // for it. The command opens it once; finding it empty again means that attempt ended.
            if !wantsFrames, streamSession == nil, streamTask == nil, publicTransactionCount == 0 {
                guard !openedOnDemand, !requiresLeaseRefresh else {
                    throw SimulatorLiveStreamError.helperUnavailable(
                        lastStreamFailure ?? SimulatorLiveStreamError.disconnected.localizedDescription
                    )
                }
                openedOnDemand = true
                openTransport()
                continue
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SimulatorLiveStreamError.handshakeTimedOut
    }

    /// The next frame the live stream delivers, or nil when the pane is not showing a direct stream
    /// or none arrives within the wait. Only a frame decoded after the request counts, so a capture
    /// taken just after an input is not the picture from before it.
    private func nextLiveFrame() async -> SimulatorLiveFrame? {
        guard wantsFrames, streamSession != nil, liveCapabilities != nil else { return nil }
        switch liveBackend {
        case .direct, .sharedMemory: break
        case .screenshotFallback, nil: return nil
        }
        let id = UUID()
        let wait = liveFrameWait
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.liveFrameWaiters.removeValue(forKey: id)?.resume(returning: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            liveFrameWaiters[id] = continuation
        }
    }

    private func resumeLiveFrameWaiters(with frame: SimulatorLiveFrame?) {
        guard !liveFrameWaiters.isEmpty else { return }
        let waiters = liveFrameWaiters.values
        liveFrameWaiters.removeAll()
        waiters.forEach { $0.resume(returning: frame) }
    }

    /// PNG-encodes a whole live frame on a worker. A full-resolution iPhone frame is a
    /// multi-megapixel compression, which is not main-actor work.
    private nonisolated static func encodedPNG(_ frame: SimulatorLiveFrame) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                "public.png" as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }.value
    }

    private func inputAuthorization(for device: SimulatorDevice) async -> Bool {
        await withCheckedContinuation { continuation in
            inputAuthorizer.authorize(device: device, in: interactionWindow) {
                continuation.resume(returning: $0)
            }
        }
    }

    private var effectiveControlDecision: Bool? {
        guard let deviceID = lease?.device.id else { return nil }
        return controlAuthorizationDecisions[deviceID]
            ?? inputAuthorizer.decision(for: deviceID)
    }

    private func controlStatus() -> String? {
        if effectiveControlDecision == false {
            return L10n.string("Control denied")
        }
        switch controlActivity {
        case .connecting:
            return L10n.string("Connecting Simulator control…")
        case .failed(let message):
            return message
        case .idle:
            break
        }
        switch liveBackend {
        case .direct, .sharedMemory:
            guard let capabilities = liveCapabilities,
                  capabilities.supportsTouch || capabilities.supportsKeyboard else {
                return L10n.string("View only")
            }
            return effectiveControlDecision == true
                ? nil
                : L10n.string("Click to enable control")
        case .screenshotFallback:
            return L10n.string("Click to reconnect control")
        case nil:
            return nil
        }
    }

    private func configureControlButton(for device: SimulatorDevice?) {
        let decision = effectiveControlDecision
        let hasDirectHumanControl = liveCapabilities.map {
            $0.supportsTouch || $0.supportsKeyboard
        } ?? false
        let title: String
        switch controlActivity {
        case .connecting:
            title = L10n.string("Connecting Simulator control…")
        case .failed:
            title = L10n.string("Enable Simulator Control")
        case .idle:
            if decision == false {
                title = L10n.string("Retry Simulator Control")
            } else if decision == true, hasDirectHumanControl {
                title = L10n.string("Simulator control ready")
            } else if case .screenshotFallback = liveBackend {
                title = L10n.string("Reconnect Simulator Control")
            } else {
                title = L10n.string("Enable Simulator Control")
            }
        }
        controlButton.setSymbol(
            decision == false ? SimulatorPaneSymbols.controlDenied : SimulatorPaneSymbols.control,
            accessibility: title
        )
        controlButton.toolTip = title
        controlButton.isSelected = decision == true && hasDirectHumanControl
        controlButton.isEnabled = device != nil
            && isPresented
            && !requiresLeaseRefresh
            && controlActivity != .connecting
            && (liveCapabilities == nil || hasDirectHumanControl)
    }

    /// Hardware buttons are live only when a direct session that supports buttons is up. On the
    /// screenshot fallback (`liveCapabilities == nil`) they are disabled, exactly like the screen.
    private func configureHardwareButtons() {
        let enabled = isPresented
            && !requiresLeaseRefresh
            && (liveCapabilities?.supportsButtons ?? false)
        for button in hardwareButtons {
            button.isEnabled = enabled
        }
    }

    /// Appearance is a `simctl` device setting, not HID input, so it is live whenever a device is
    /// adopted — even on the screenshot fallback — and needs no input consent.
    private func configureAppearanceButton() {
        appearanceButton.isEnabled = isPresented && lease != nil
    }

    private func toggleAppearance() {
        guard let deviceID = lease?.device.id else { return }
        let dark = !appearanceIsDark
        appearanceIsDark = dark
        let control = control
        runAgentCommand { [weak self] in
            do {
                try await control.setAppearance(dark: dark, on: deviceID)
            } catch {
                // Keep the toggle honest if the command failed.
                self?.appearanceIsDark = !dark
            }
        }
    }

    // MARK: - Accessibility inspector overlay

    private func toggleInspection() {
        isInspecting.toggle()
        inspectButton.setAccessibilityValue(isInspecting ? "on" : "off")
        if isInspecting {
            refreshAccessibilityOverlay()
        } else {
            screenView.annotations = []
        }
    }

    /// Read the foreground app's tree once and outline every element over the framebuffer. Best
    /// effort: a failure (this Xcode's AX path unavailable, automation off, a disconnected helper)
    /// simply leaves the overlay empty rather than surfacing an error over a live device.
    private func refreshAccessibilityOverlay() {
        guard isInspecting, let session = streamSession else {
            screenView.annotations = []
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let root = try? await session.requestAccessibilitySnapshot() else {
                self?.screenView.annotations = []
                return
            }
            guard self.isInspecting, self.streamSession === session else { return }
            self.screenView.annotations = Self.annotations(from: root)
        }
    }

    /// Flatten the tree into normalized outlines. The root frame is the device's logical size, so
    /// every descendant normalizes to `(x/W, y/H, …)` — the same 0…1 space taps use. Off-screen
    /// elements the guest still reports (a horizontally paged list) are dropped.
    private static func annotations(
        from root: SimulatorAccessibilityElement
    ) -> [SimulatorScreenView.ElementAnnotation] {
        let width = root.frame.width
        let height = root.frame.height
        guard width > 0, height > 0 else { return [] }
        var annotations: [SimulatorScreenView.ElementAnnotation] = []
        // Number refs over the same interactive_only listing simulator_snapshot uses, in preorder,
        // so a ref shown in the badge is the same eN the agent tools resolve — even for elements
        // that fall off-screen and get no outline.
        var refIndex = 0
        func visit(_ element: SimulatorAccessibilityElement, isRoot: Bool) {
            if !isRoot {
                var ref: String?
                if SimulatorElementListing.isListed(element, interactiveOnly: true) {
                    refIndex += 1
                    ref = "e\(refIndex)"
                }
                let normalized = CGRect(
                    x: element.frame.x / width,
                    y: element.frame.y / height,
                    width: element.frame.width / width,
                    height: element.frame.height / height
                )
                if normalized.maxX > 0, normalized.minX < 1,
                   normalized.maxY > 0, normalized.minY < 1 {
                    annotations.append(SimulatorScreenView.ElementAnnotation(
                        normalizedFrame: normalized,
                        label: element.label,
                        name: Self.badgeName(ref: ref, element: element),
                        copyText: Self.copyTarget(element: element, normalized: normalized),
                        emphasized: Self.isInteractiveRole(element.role)
                    ))
                }
            }
            for child in element.children { visit(child, isRoot: false) }
        }
        visit(root, isRoot: true)
        return annotations
    }

    /// The hover badge text: `e5 · AXButton · Kronaby`, or the role alone when there is no ref/label.
    static func badgeName(ref: String?, element: SimulatorAccessibilityElement) -> String {
        var parts: [String] = []
        if let ref { parts.append(ref) }
        parts.append(element.role)
        if let label = element.label, !label.isEmpty { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    /// A paste-ready handle for the clipboard: the durable, human-readable target plus the exact
    /// normalized tap point, so it can be dropped straight into a prompt.
    static func copyTarget(
        element: SimulatorAccessibilityElement,
        normalized: CGRect
    ) -> String {
        var target = element.label.map { "\"\($0)\" (\(element.role))" } ?? element.role
        if let identifier = element.identifier, !identifier.isEmpty { target += " #\(identifier)" }
        return String(
            format: "%@ at (%.3f, %.3f)", target, normalized.midX, normalized.midY
        )
    }

    private static func isInteractiveRole(_ role: String) -> Bool {
        [
            "AXButton", "AXTextField", "AXSecureTextField", "AXSearchField", "AXTextArea",
            "AXSwitch", "AXSlider", "AXLink", "AXCell", "AXPopUpButton", "AXCheckBox",
            "AXStepper", "AXMenuButton", "AXSegmentedControl"
        ].contains(role)
    }

    // MARK: - Human note annotations

    private static let noteEditorWidth: CGFloat = 240
    private static let annotationMenuWidth: CGFloat = 220

    private func toggleAnnotating() {
        setAnnotatingNotes(!isAnnotatingNotes)
    }

    /// Shared operation for the toolbar, palette commands and user-assigned shortcuts.
    func setAnnotatingNotes(_ enabled: Bool) {
        guard enabled != isAnnotatingNotes, let device = lease?.device.id,
              !enabled || canAnnotateNotes else { return }
        if noteEditor != nil {
            if noteEditor?.note.isEmpty == true { cancelNoteEditor() }
            else { commitNoteEditor() }
        }
        isAnnotatingNotes = enabled
        screenView.isAnnotatingNotes = enabled
        screenView.noteMarks = annotationStore.annotations(for: device)
        screenView.selectedNoteID = nil
        view.window?.makeFirstResponder(screenView)
        updateSendBar()
    }

    /// The annotate button and the mode band say the same thing: whether the mode is on and how
    /// many notes are waiting to be sent.
    private func refreshAnnotationChrome() {
        let pending = pendingNotes.count
        annotateButton.setSymbol(
            isAnnotatingNotes ? DesignSymbols.annotating : DesignSymbols.annotate,
            accessibility: isAnnotatingNotes
                ? L10n.string("Stop Annotating")
                : L10n.string("Annotate device")
        )
        annotateButton.isSelected = isAnnotatingNotes
        var tip = isAnnotatingNotes
            ? L10n.string("Stop annotating (Esc)")
            : L10n.string("Annotate device (Option-click to add a note without switching modes)")
        if pending > 0 {
            tip += "\n" + L10n.format("%lld notes waiting to be sent (right-click for options)", Int64(pending))
        }
        annotateButton.toolTip = tip
        updateAnnotationBand()
    }

    /// Shown only while annotating: what a click does, how a pin goes away, and the way out.
    /// Rebuilt when Clear All becomes meaningful or stops being so — a small fixed band.
    private func updateAnnotationBand() {
        guard isAnnotatingNotes else {
            guard let band = annotationBand else { return }
            band.removeFromSuperview()
            annotationBand = nil
            screenTopToControlRow.isActive = true
            return
        }
        let offersClear = !screenView.noteMarks.isEmpty
        if annotationBand != nil, offersClear == annotationBandOffersClear { return }
        annotationBand?.removeFromSuperview()
        // The ✕ ends the mode — the band's own way out, where every notice keeps it.
        let band = PaneNoticeView(
            tone: .informational,
            message: L10n.string("Click the device to pin a note. Delete removes the pin under the pointer; Esc finishes."),
            actions: offersClear
                ? [PaneNoticeAction(title: L10n.string("Clear All")) { [weak self] in
                    self?.clearAllNotes()
                  }]
                : [],
            dismissTitle: L10n.string("Stop Annotating"),
            onDismiss: { [weak self] in self?.finishAnnotating() }
        )
        band.setAccessibilityIdentifier("simulator.annotate.band")
        view.addSubview(band)
        screenTopToControlRow.isActive = false
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.topAnchor.constraint(equalTo: controlRow.bottomAnchor, constant: Design.Spacing.medium),
            screenView.topAnchor.constraint(equalTo: band.bottomAnchor, constant: Design.Spacing.medium),
        ])
        annotationBand = band
        annotationBandOffersClear = offersClear
    }

    private func finishAnnotating() {
        setAnnotatingNotes(false)
    }

    private func addNote(at point: CGPoint) {
        guard let device = lease?.device.id, screenView.image != nil else { return }
        if noteEditor != nil { commitNoteEditor() }
        screenView.noteMarks = annotationStore.annotations(for: device)
        guard screenView.noteMarks.count < SimulatorAnnotationStore.maximumCount else { return }
        let annotation = ImageAnnotation(point: point)
        screenView.noteMarks.append(annotation)
        screenView.selectedNoteID = annotation.id
        annotationStore.setAnnotations(screenView.noteMarks, for: device)
        updateSendBar()
        presentNoteEditor(for: annotation.id, isExisting: false)
    }

    private func selectNote(_ id: ImageAnnotation.ID?) {
        if noteEditor != nil { commitNoteEditor() }
        screenView.selectedNoteID = id
        if let id, screenView.noteMarks.contains(where: { $0.id == id }) {
            presentNoteEditor(for: id, isExisting: true)
        } else {
            dismissNoteEditor()
        }
    }

    private func presentNoteEditor(for id: ImageAnnotation.ID, isExisting: Bool) {
        dismissNoteEditor()
        guard let index = screenView.noteMarks.firstIndex(where: { $0.id == id }) else { return }
        let editor = BrowserAnnotationEditor(
            identifier: index + 1,
            note: screenView.noteMarks[index].note,
            isExisting: isExisting
        )
        editor.onSave = { [weak self] in self?.commitNoteEditor() }
        editor.onCancel = { [weak self] in self?.cancelNoteEditor() }
        editor.onDelete = { [weak self] in self?.deleteEditedNote() }
        editingNoteID = id
        noteEditor = editor
        view.addSubview(editor)
        positionNoteEditor()
        editor.focusNote()
    }

    private func positionNoteEditor() {
        guard let editor = noteEditor, let id = editingNoteID,
              let annotation = screenView.noteMarks.first(where: { $0.id == id }) else { return }
        let inset = Design.Spacing.small
        let width = min(Self.noteEditorWidth, max(0, view.bounds.width - inset * 2))
        editor.frame.size.width = width
        let height = editor.fittingSize.height
        let pin = ImageAnnotationGeometry.viewPoint(
            for: annotation, in: screenView.imageRect, isFlipped: false
        )
        let anchor = screenView.convert(pin, to: view)
        var origin = CGPoint(x: anchor.x + inset, y: anchor.y - height - inset)
        origin.x = min(max(view.bounds.minX + inset, origin.x), view.bounds.maxX - width - inset)
        origin.y = min(max(view.bounds.minY + inset, origin.y), view.bounds.maxY - height - inset)
        editor.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func commitNoteEditor() {
        guard let device = lease?.device.id, let id = editingNoteID, let editor = noteEditor else {
            return
        }
        if let index = screenView.noteMarks.firstIndex(where: { $0.id == id }) {
            screenView.noteMarks[index].note = editor.note
        }
        annotationStore.setAnnotations(screenView.noteMarks, for: device)
        finishNoteEditing()
    }

    private func cancelNoteEditor() {
        // A brand-new note the person never gave text to is discarded rather than left blank.
        if let device = lease?.device.id, let id = editingNoteID,
           let index = screenView.noteMarks.firstIndex(where: { $0.id == id }),
           screenView.noteMarks[index].note.isEmpty {
            screenView.noteMarks.remove(at: index)
            annotationStore.setAnnotations(screenView.noteMarks, for: device)
        }
        finishNoteEditing()
    }

    private func deleteEditedNote() {
        guard let device = lease?.device.id, let id = editingNoteID else { return }
        screenView.noteMarks.removeAll { $0.id == id }
        annotationStore.setAnnotations(screenView.noteMarks, for: device)
        finishNoteEditing()
    }

    private func finishNoteEditing() {
        dismissNoteEditor()
        screenView.selectedNoteID = nil
        view.window?.makeFirstResponder(screenView)
        updateSendBar()
    }

    private func dismissNoteEditor() {
        noteEditor?.removeFromSuperview()
        noteEditor = nil
        editingNoteID = nil
    }

    private func updateSendBar() {
        noteSendBar.setPending(count: pendingNotes.count, sending: isSendingNotes)
        refreshAnnotationChrome()
    }

    /// The annotation actions, shared by the annotate button's menu and the screen's. The button's
    /// menu keeps every row and disables what does not apply; the device's menu, which is about
    /// the whole device, leaves out note actions until there are notes to act on.
    private func annotationEntries(omittingUnavailable: Bool = false) -> [ThemedMenuEntry] {
        let hasNotes = !screenView.noteMarks.isEmpty
        let pending = pendingNotes.count
        let mode: ThemedMenuEntry = .item(ThemedMenuItem(
            title: isAnnotatingNotes ? L10n.string("Stop Annotating") : L10n.string("Annotate Device"),
            isSelected: isAnnotatingNotes,
            isEnabled: isAnnotatingNotes || canAnnotateNotes,
            onChoose: { [weak self] in self?.toggleAnnotating() }
        ))
        if omittingUnavailable, !hasNotes { return [mode] }
        return [
            mode,
            .item(ThemedMenuItem(
                title: pending > 0
                    ? L10n.format("Send %lld Notes", Int64(pending))
                    : L10n.string("Send Notes"),
                shortcut: KeyboardShortcut(key: "\r", modifiers: .command),
                isEnabled: pending > 0 && !isSendingNotes && annotationSessionID != nil,
                onChoose: { [weak self] in self?.sendPendingNotes() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Copy Annotated Screenshot"),
                isEnabled: hasNotes,
                onChoose: { [weak self] in self?.exportAnnotatedFrame() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Clear All Notes"),
                isEnabled: hasNotes,
                onChoose: { [weak self] in self?.clearAllNotes() }
            )),
        ]
    }

    private func presentAnnotationMenu(from anchor: ThemedMenuAnchor) -> Bool {
        annotationMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: annotationEntries(), minimumWidth: Self.annotationMenuWidth),
            from: annotateButton,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.annotationMenuSession = nil }
        )
        return annotationMenuSession != nil
    }

    private func clearAllNotes() {
        guard let device = lease?.device.id,
              !screenView.noteMarks.isEmpty else { return }
        dismissNoteEditor()
        screenView.noteMarks = []
        screenView.selectedNoteID = nil
        annotationStore.setAnnotations([], for: device)
        updateSendBar()
        flashStatus(L10n.string("Cleared notes"))
    }

    /// Delete the pin the person is pointing at (or has selected) — the simple removal, no editor.
    private func deleteHoveredNote(_ id: ImageAnnotation.ID) {
        guard isAnnotatingNotes else { return }
        deleteNote(id)
    }

    /// Remove one pin, from the keyboard in annotation mode or from its context menu in any mode.
    private func deleteNote(_ id: ImageAnnotation.ID) {
        guard let device = lease?.device.id else { return }
        if editingNoteID == id { dismissNoteEditor() }
        screenView.noteMarks.removeAll { $0.id == id }
        if screenView.selectedNoteID == id { screenView.selectedNoteID = nil }
        annotationStore.setAnnotations(screenView.noteMarks, for: device)
        updateSendBar()
    }

    /// Flatten the current frame with the note pins burned in and copy it to the clipboard, to share
    /// a marked-up screenshot. Reuses the app's shared flattening, so the pins match everywhere.
    private func exportAnnotatedFrame() {
        guard let image = screenView.image, !screenView.noteMarks.isEmpty,
              let flattened = ImageAnnotationFlattening.flattened(
                image, annotations: screenView.noteMarks
              ) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([flattened])
        flashStatus(L10n.string("Copied annotated screenshot"))
    }

    // MARK: - Frame fan-out

    /// Every picture of the device goes through here, so the pane and its presenter window never
    /// disagree about what the device shows.
    private func showFrame(_ image: NSImage) {
        screenView.image = image
        guard let presenter else { return }
        presenter.screenView.image = image
        presenter.adoptFrameSize(image.size)
    }

    private func setScreenInteraction(_ state: SimulatorScreenView.InteractionState) {
        screenView.interactionState = state
        presenter?.screenView.interactionState = state
    }

    private func setTouchIndicators(_ indicators: SimulatorTouchIndicators?) {
        screenView.touchIndicators = indicators
        presenter?.screenView.touchIndicators = indicators
    }

    // MARK: - Capture (screenshot)

    private func saveSnapshot() {
        guard let device = lease?.device, let data = currentFramePNG() else { return }
        let name = SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "png")
        guard let url = SimulatorCaptureSaver.write(data, suggestedName: name, video: false) else {
            flashStatus(L10n.string("Could not save the screenshot"))
            return
        }
        revealCapture(url)
        flashStatus(L10n.string("Saved screenshot"))
    }

    private func copySnapshot() {
        guard let image = screenView.image else { return }
        SimulatorCaptureSaver.copyImage(image)
        flashStatus(L10n.string("Copied screenshot"))
    }

    private func saveSnapshotAs() {
        guard let device = lease?.device, let data = currentFramePNG() else { return }
        SimulatorCaptureSaver.saveAs(
            suggestedName: SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "png"),
            contentType: .png,
            video: false,
            from: view.window
        ) { url in SimulatorCaptureSaver.writeData(data, to: url) }
    }

    /// Only one fixed-size control changes; no device/frame work runs on modifier events.
    private func updateCaptureModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let copies = modifiers.contains(.control)
        guard copies != captureCopiesSnapshot else { return }
        captureCopiesSnapshot = copies
        refreshCaptureButton()
    }

    private func refreshCaptureButton() {
        let copies = captureCopiesSnapshot
        let title = copies ? L10n.string("Copy Screenshot") : L10n.string("Save Screenshot")
        captureButton.setSymbol(
            copies ? SimulatorPaneSymbols.copyScreenshot : SimulatorPaneSymbols.screenshot,
            accessibility: title
        )
        captureButton.toolTip = copies ? title
            : L10n.string("Save a screenshot of the device (hold Control to copy; right-click for options)")
        // ThemedIconButton freezes this closure at mouse-down, so releasing Control before
        // mouse-up cannot turn a copy into an unexpected file save.
        captureButton.onPress = { [weak self] in
            guard let self else { return }
            if copies { self.copySnapshot() } else { self.saveSnapshot() }
        }
    }

    private func captureEntries() -> [ThemedMenuEntry] {
        let hasFrame = lease != nil && screenView.image != nil
        return [
            .item(ThemedMenuItem(
                title: L10n.string("Copy Screenshot"),
                isEnabled: hasFrame,
                onChoose: { [weak self] in self?.copySnapshot() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Save Screenshot"),
                isEnabled: hasFrame,
                onChoose: { [weak self] in self?.saveSnapshot() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Save Screenshot As…"),
                isEnabled: hasFrame,
                onChoose: { [weak self] in self?.saveSnapshotAs() }
            )),
        ]
    }

    private func presentCaptureMenu(from anchor: ThemedMenuAnchor) -> Bool {
        captureMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: captureEntries(), minimumWidth: Self.menuWidth),
            from: captureButton,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.captureMenuSession = nil }
        )
        return captureMenuSession != nil
    }

    private func currentFramePNG() -> Data? {
        guard let image = screenView.image else { return nil }
        return Self.pngData(image)
    }

    /// `nonisolated`: a one-frame PNG encode, not main-actor work.
    private nonisolated static func pngData(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    // MARK: - Capture (recording)

    private static let menuWidth: CGFloat = 220

    var canRecord: Bool { lease != nil && screenView.image != nil && !isFinishingRecording }
    var isRecordingForCommands: Bool { isRecording }

    /// The record button, its menu, the screen's menu and the palette command all end here.
    /// Starting records what the pane shows, touches included when they are drawn.
    func toggleRecording() {
        if isRecording { stopRecording() } else { startStreamRecording() }
    }

    private func videoURL(for device: SimulatorDevice) -> URL {
        let directory = recordingDirectory ?? SimulatorCaptureSaver.defaultDirectory(video: true)
        return directory.appendingPathComponent(
            SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "mov")
        )
    }

    /// simctl engine — pristine capture, no touch overlay.
    private func startSimctlRecording() {
        guard !isRecording, !isFinishingRecording, let device = lease?.device else { return }
        do {
            try simctlRecorder.start(deviceID: device.id.rawValue, to: videoURL(for: device)) {
                [weak self] finalized in self?.finishRecording(saved: finalized)
            }
            beginRecordingUI()
        } catch {
            flashStatus(L10n.string("Could not start recording"))
        }
    }

    /// Stream engine — records our frames with the touch overlay composited in.
    private func startStreamRecording() {
        guard !isRecording, !isFinishingRecording else { return }
        guard let device = lease?.device, let image = screenView.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            flashStatus(L10n.string("Could not start recording"))
            return
        }
        guard let recorder = SimulatorStreamRecorder(
            url: videoURL(for: device), width: cgImage.width, height: cgImage.height
        ) else {
            flashStatus(L10n.string("Could not start recording"))
            return
        }
        streamRecorder = recorder
        beginRecordingUI()
        // The first frame is the one on screen now, so a still device still makes a movie.
        feedStreamRecorder(cgImage)
    }

    private func feedStreamRecorder(_ image: CGImage) {
        streamRecorder?.append(
            image: image,
            indicators: touchOverlayModel.indicators(),
            style: touchPreferences.style
        )
    }

    func stopRecording() {
        guard isRecording, !isFinishingRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        isFinishingRecording = true
        refreshRecordingPresentation()
        if let recorder = streamRecorder {
            streamRecorder = nil
            recorder.finish { [weak self] url in self?.finishRecording(saved: url) }
            // The recording no longer holds the stream open.
            releaseFramesIfUnwatched()
        } else {
            simctlRecorder.stop()  // finishRecording fires from its termination handler
        }
    }

    private func beginRecordingUI() {
        isRecording = true
        recordingStartedAt = Date()
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRecordingPresentation() }
        }
        RunLoop.current.add(timer, forMode: .common)
        recordingTimer = timer
        refreshRecordingPresentation()
    }

    private var recordingElapsedSeconds: Int {
        recordingStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
    }

    /// One place states what recording looks like: the button, the badge over the device, the
    /// screen's ring and the status line all change together.
    private func refreshRecordingPresentation() {
        guard isViewLoaded else { return }
        let elapsed = SimulatorRecordingBadge.elapsedText(recordingElapsedSeconds)
        let title: String
        if isFinishingRecording {
            title = L10n.string("Saving recording…")
        } else if isRecording {
            title = L10n.format("Stop Recording (%@)", elapsed)
        } else {
            title = L10n.string("Record Video")
        }
        recordButton.setSymbol(
            isRecording ? SimulatorPaneSymbols.stopRecording : SimulatorPaneSymbols.record,
            accessibility: title
        )
        recordButton.toolTip = isRecording ? title
            : L10n.string("Record a video of the device with its touches (right-click for options)")
        recordButton.isSelected = isRecording
        recordButton.isEnabled = isRecording ? !isFinishingRecording : canRecord
        recordingBadge.isHidden = !isRecording
        recordingBadge.phase = isFinishingRecording
            ? .finishing
            : .recording(elapsedSeconds: recordingElapsedSeconds)
        screenView.isRecording = isRecording && !isFinishingRecording
        // The status line ticks with the badge, unless it is briefly confirming something else.
        if isRecording, exportConfirmationTimer == nil { showRecordingStatus() }
    }

    /// While recording, the status line says so first — in the live-status colour, the one word
    /// the pane otherwise reserves for a lost device route.
    private func showRecordingStatus() {
        statusLabel.stringValue = isFinishingRecording
            ? L10n.string("Saving recording…")
            : L10n.format("Recording %@", SimulatorRecordingBadge.elapsedText(recordingElapsedSeconds))
        statusLabel.textColor = Design.Status.negative
    }

    private func finishRecording(saved url: URL?) {
        isRecording = false
        isFinishingRecording = false
        recordingStartedAt = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        refreshRecordingPresentation()
        if let url {
            revealCapture(url)
            flashStatus(L10n.string("Saved recording"))
        } else {
            renderState()
        }
    }

    /// `explained` adds a line under each way to record; the record button's own menu has room
    /// for that, the device's longer menu does not.
    private func recordEntries(explained: Bool = true) -> [ThemedMenuEntry] {
        if isRecording {
            return [.item(ThemedMenuItem(
                title: L10n.format(
                    "Stop Recording (%@)",
                    SimulatorRecordingBadge.elapsedText(recordingElapsedSeconds)
                ),
                isEnabled: !isFinishingRecording,
                onChoose: { [weak self] in self?.stopRecording() }
            ))]
        }
        return [
            .item(ThemedMenuItem(
                title: L10n.string("Record Video"),
                subtitle: explained ? L10n.string("What the pane shows, touches included") : nil,
                isEnabled: canRecord,
                onChoose: { [weak self] in self?.startStreamRecording() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Record High-Quality Video"),
                subtitle: explained ? L10n.string("Full resolution from Simulator, without touches") : nil,
                isEnabled: lease != nil && !isFinishingRecording,
                onChoose: { [weak self] in self?.startSimctlRecording() }
            )),
        ]
    }

    private func presentRecordMenu(from anchor: ThemedMenuAnchor) -> Bool {
        recordMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: recordEntries(), minimumWidth: Self.menuWidth),
            from: recordButton,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.recordMenuSession = nil }
        )
        return recordMenuSession != nil
    }

    // MARK: - Show touches

    /// The toolbar, the menus and the palette command share this; the choice is remembered, so
    /// a person who presents their device finds touches still on next time.
    func toggleShowTouches() {
        touchPreferences.showsLiveTouches.toggle()
    }

    var showsTouchesForCommands: Bool { showTouches }

    /// Reflects the stored choices everywhere they show. Called on load and whenever any pane or
    /// menu changes them.
    private func applyTouchPreferences() {
        let style = touchPreferences.style
        screenView.touchStyle = style
        presenter?.screenView.touchStyle = style
        let on = showTouches
        let title = on ? L10n.string("Hide Touches") : L10n.string("Show Touches")
        showTouchesButton.setSymbol(SimulatorPaneSymbols.touches, accessibility: title)
        showTouchesButton.isSelected = on
        showTouchesButton.setAccessibilityValue(on ? "on" : "off")
        // The display tick is the live overlay's alone; a recording reads the model per frame, so
        // turning the overlay off mid-recording clears the screen without dropping the movie's marks.
        if !on {
            touchDisplayTimer?.invalidate()
            touchDisplayTimer = nil
            setTouchIndicators(nil)
        }
    }

    private func touchStyleEntries() -> [ThemedMenuEntry] {
        let style = touchPreferences.style
        let colors: [ThemedMenuEntry] = SimulatorTouchStyle.Color.allCases.map { color in
            .item(ThemedMenuItem(
                title: Design.SimulatorTouch.name(color),
                image: Design.SimulatorTouch.swatch(color),
                isSelected: style.color == color,
                onChoose: { [weak self] in self?.updateTouchStyle { $0.color = color } }
            ))
        }
        let sizes: [ThemedMenuEntry] = SimulatorTouchStyle.Size.allCases.map { size in
            .item(ThemedMenuItem(
                title: Design.SimulatorTouch.name(size),
                isSelected: style.size == size,
                onChoose: { [weak self] in self?.updateTouchStyle { $0.size = size } }
            ))
        }
        return [
            .item(ThemedMenuItem(title: L10n.string("Color"), submenu: colors)),
            .item(ThemedMenuItem(title: L10n.string("Size"), submenu: sizes)),
            .item(ThemedMenuItem(
                title: L10n.string("Show Swipe Trail"),
                isSelected: style.showsTrail,
                onChoose: { [weak self] in self?.updateTouchStyle { $0.showsTrail.toggle() } }
            )),
        ]
    }

    private func touchEntries() -> [ThemedMenuEntry] {
        [
            .item(ThemedMenuItem(
                title: L10n.string("Show Touches"),
                help: L10n.string("Draw taps and swipes over the device, yours and the agent's"),
                isSelected: showTouches,
                onChoose: { [weak self] in self?.toggleShowTouches() }
            )),
            .separator,
            .header(L10n.string("Touch Style")),
        ] + touchStyleEntries()
    }

    private func updateTouchStyle(_ change: (inout SimulatorTouchStyle) -> Void) {
        var style = touchPreferences.style
        change(&style)
        touchPreferences.style = style
    }

    private func presentTouchMenu(from anchor: ThemedMenuAnchor) -> Bool {
        touchMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: touchEntries(), minimumWidth: Self.menuWidth),
            from: showTouchesButton,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.touchMenuSession = nil }
        )
        return touchMenuSession != nil
    }

    /// Record an input event into the touch overlay and make sure it is animating. No-op unless the
    /// overlay is on, so it costs nothing when hidden.
    private func feedTouchOverlay(_ apply: (SimulatorTouchOverlayModel) -> Void) {
        // Fed while the overlay is on (for the live view) or while stream-recording (for the movie),
        // so touches reach the recording even when the live overlay is off.
        guard showTouches || streamRecorder != nil else { return }
        apply(touchOverlayModel)
        // The tick only drives the live display; the recorder pulls indicators per frame.
        guard showTouches, touchDisplayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTouchOverlay() }
        }
        RunLoop.current.add(timer, forMode: .common)
        touchDisplayTimer = timer
    }

    private func tickTouchOverlay() {
        let indicators = touchOverlayModel.indicators()
        setTouchIndicators(indicators.isEmpty ? nil : indicators)
        if !touchOverlayModel.hasActivity {
            touchDisplayTimer?.invalidate()
            touchDisplayTimer = nil
            setTouchIndicators(nil)
        }
    }

    /// Feed the overlay from an input the pane or an agent sends (both routes converge here).
    private func showInputInOverlay(_ input: SimulatorBridgeInput) {
        switch input {
        case .tap(let x, let y):
            feedTouchOverlay { $0.tap(at: CGPoint(x: x, y: y)) }
        case .drag(let fromX, let fromY, let toX, let toY, _):
            feedTouchOverlay {
                $0.contactBegan(at: CGPoint(x: fromX, y: fromY))
                $0.contactMoved(to: CGPoint(x: toX, y: toY))
                $0.contactEnded(at: CGPoint(x: toX, y: toY))
            }
        case .touch(let phase, let x, let y):
            let point = CGPoint(x: x, y: y)
            feedTouchOverlay {
                switch phase {
                case .began: $0.contactBegan(at: point)
                case .moved: $0.contactMoved(to: point)
                case .ended, .cancelled: $0.contactEnded(at: point)
                }
            }
        case .text, .button:
            break
        }
    }

    // MARK: - Presenter window

    var isPresenterWindowOpen: Bool { presenter != nil }

    /// The toolbar button, the screen's menu and the palette command share this.
    func togglePresenterWindow() {
        if presenter != nil { closePresenterWindow() } else { openPresenterWindow() }
    }

    private func openPresenterWindow() {
        guard presenter == nil, let device = lease?.device else { return }
        let controller = SimulatorPresenterWindowController(deviceName: device.name)
        let mirror = controller.screenView
        mirror.onTap = { [weak self] point in
            self?.submitInput(.tap(x: Double(point.x), y: Double(point.y)))
        }
        mirror.onTouchBegan = { [weak self] point in self?.beginTouchStream(at: point) }
        mirror.onTouchMoved = { [weak self] point in self?.moveTouchStream(to: point) }
        mirror.onTouchEnded = { [weak self] point in self?.endTouchStream(at: point) }
        mirror.onScroll = { [weak self] point, deltaX, deltaY in
            self?.scrollDevice(at: point, deltaX: deltaX, deltaY: deltaY)
        }
        mirror.onText = { [weak self] text in self?.submitInput(.text(text)) }
        mirror.onContextMenu = { [weak self, weak mirror] request in
            guard let self, let mirror else { return false }
            return self.presentScreenMenu(request, from: mirror, includesNotes: false)
        }
        mirror.touchStyle = touchPreferences.style
        mirror.interactionState = screenView.interactionState
        mirror.touchIndicators = screenView.touchIndicators
        if let image = screenView.image {
            mirror.image = image
            controller.adoptFrameSize(image.size)
        }
        controller.content.onKeyEquivalent = { [weak self] event in
            self?.performSimulatorShortcut(event) ?? false
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.presenter === controller else { return }
            self.presenter = nil
            self.refreshPresenterButton()
            self.releaseFramesIfUnwatched()
        }
        presenter = controller
        controller.placeBeside(view.window)
        refreshPresenterButton()
        // The stream now has a viewer even if this pane is hidden.
        hiddenTransportReleaseTask?.cancel()
        hiddenTransportReleaseTask = nil
        reconnectTransportForInputIfNeeded(on: device.id)
        startFrameLoop()
        showPresenterWindow(controller)
    }

    private func closePresenterWindow() {
        guard let controller = presenter else { return }
        presenter = nil
        controller.onClose = nil
        controller.close()
        refreshPresenterButton()
        releaseFramesIfUnwatched()
    }

    private func refreshPresenterButton() {
        let open = presenter != nil
        let title = open ? L10n.string("Close Presenter Window") : L10n.string("Open Presenter Window")
        presenterButton.setSymbol(SimulatorPaneSymbols.presenter, accessibility: title)
        presenterButton.toolTip = open ? title
            : L10n.string("Open the device alone in its own window, to share in Meet or Zoom")
        presenterButton.isSelected = open
        presenterButton.isEnabled = open || lease != nil
    }

    /// The window a consent sheet belongs to: the presenter's when that is where the person is
    /// working, the pane's otherwise.
    private var interactionWindow: NSWindow? {
        if let window = presenter?.window, window.isKeyWindow || view.window == nil {
            return window
        }
        return view.window
    }

    // MARK: - Screen context menu

    /// Everything the pane does to the device, offered where the device is: capture, recording,
    /// notes, overlays and the presenter window. Built on each open from current state — a fixed
    /// list of about fifteen rows, so there is nothing to cache.
    func screenMenuEntries(
        for request: SimulatorScreenView.ContextMenuRequest,
        includesNotes: Bool
    ) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []

        if includesNotes, let noteID = request.noteID,
           let index = screenView.noteMarks.firstIndex(where: { $0.id == noteID }) {
            entries.append(.header(L10n.format("Note %lld", Int64(index + 1))))
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Edit Note…"),
                onChoose: { [weak self] in self?.selectNote(noteID) }
            )))
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Delete Note"),
                onChoose: { [weak self] in self?.deleteNote(noteID) }
            )))
            entries.append(.separator)
        }

        entries += captureEntries()
        entries.append(.separator)
        entries += recordEntries(explained: false)

        if includesNotes {
            entries.append(.separator)
            let canAdd = canAnnotateNotes
                && screenView.noteMarks.count < SimulatorAnnotationStore.maximumCount
            if let point = request.point {
                entries.append(.item(ThemedMenuItem(
                    title: L10n.string("Add Note Here"),
                    isEnabled: canAdd,
                    onChoose: { [weak self] in self?.addNote(at: point) }
                )))
            }
            entries += annotationEntries(omittingUnavailable: true)
        }

        entries.append(.separator)
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Show Touches"),
            isSelected: showTouches,
            onChoose: { [weak self] in self?.toggleShowTouches() }
        )))
        entries.append(.item(ThemedMenuItem(
            title: L10n.string("Touch Style"),
            submenu: touchStyleEntries()
        )))
        if includesNotes {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Inspect Elements"),
                isSelected: isInspecting,
                isEnabled: streamSession != nil || isInspecting,
                onChoose: { [weak self] in self?.toggleInspection() }
            )))
        }

        entries.append(.separator)
        if includesNotes {
            entries.append(.item(ThemedMenuItem(
                title: presenter == nil
                    ? L10n.string("Open Presenter Window")
                    : L10n.string("Close Presenter Window"),
                isEnabled: presenter != nil || lease != nil,
                onChoose: { [weak self] in self?.togglePresenterWindow() }
            )))
        } else {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Keep on Top"),
                isSelected: presenter?.keepsOnTop == true,
                onChoose: { [weak self] in
                    guard let presenter = self?.presenter else { return }
                    presenter.keepsOnTop.toggle()
                }
            )))
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Close Presenter Window"),
                onChoose: { [weak self] in self?.closePresenterWindow() }
            )))
        }
        return entries
    }

    private func presentScreenMenu(
        _ request: SimulatorScreenView.ContextMenuRequest,
        from source: SimulatorScreenView,
        includesNotes: Bool
    ) -> Bool {
        guard lease != nil else { return false }
        if includesNotes, noteEditor != nil { commitNoteEditor() }
        screenMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: screenMenuEntries(for: request, includesNotes: includesNotes),
                minimumWidth: Self.menuWidth
            ),
            from: source,
            anchor: request.anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.screenMenuSession = nil }
        )
        return screenMenuSession != nil
    }

    /// Briefly show a confirmation in the status line, then restore the normal state.
    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = Design.Text.secondary
        exportConfirmationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.exportConfirmationTimer = nil
                self?.renderState()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        exportConfirmationTimer = timer
    }

    /// Hand the pending notes to the session as a message, mirroring the browser's send: save any
    /// open note first, then remove only the unchanged notes acknowledged by delivery.
    private func sendPendingNotes() {
        guard let device = lease?.device,
              let sessionID = annotationSessionID else { return }
        if noteEditor != nil { commitNoteEditor() }
        let pending = pendingNotes
        guard !isSendingNotes, !pending.isEmpty else { return }
        isSendingNotes = true
        updateSendBar()
        let text = Self.annotationMessage(
            allNotes: screenView.noteMarks, pending: pending, device: device
        )
        SessionMessageDelivery.deliver(text, to: sessionID) { [weak self] outcome in
            guard let self else { return }
            self.isSendingNotes = false
            switch outcome {
            case .sentNow, .queuedBehindTurn:
                var delivered = pending
                if self.lease?.device.id == device.id,
                   let editingID = self.editingNoteID, let editor = self.noteEditor {
                    // A newer, unsaved draft belongs to the person still typing. Keep both
                    // its pin and its editor instead of finishing their edit on delivery.
                    delivered.removeAll { $0.id == editingID && $0.note != editor.note }
                    if delivered.contains(where: { $0.id == editingID }) {
                        self.finishNoteEditing()
                    }
                }
                self.annotationStore.removeDelivered(delivered, for: device.id)
                if self.lease?.device.id == device.id {
                    self.screenView.noteMarks = self.annotationStore.annotations(for: device.id)
                    if !self.screenView.noteMarks.contains(where: { $0.id == self.screenView.selectedNoteID }) {
                        self.screenView.selectedNoteID = nil
                    }
                }
            case .noLiveSurface, .busyTerminal, .typedUnconfirmed, .notTaken:
                break  // Stay pending; the person can send again when the chat is ready.
            }
            self.updateSendBar()
        }
    }

    /// The message the agent receives. Notes are numbered by their pin (their position in the full
    /// list) so the text matches what the person sees, and the normalized point feeds `simulator_tap`.
    static func annotationMessage(
        allNotes: [ImageAnnotation],
        pending: [ImageAnnotation],
        device: SimulatorDevice
    ) -> String {
        let pendingIDs = Set(pending.map(\.id))
        let entries = allNotes.enumerated().compactMap { index, note -> String? in
            guard pendingIDs.contains(note.id) else { return nil }
            return """
                Annotation \(index + 1)
                Device: \(device.name) (\(device.id.rawValue))
                Position: (\(note.point.x), \(note.point.y)) normalized
                Note: \(note.note)
                """
        }
        // localization-ignore: message content sent to the agent, matching browser annotations.
        return "Please address these Simulator annotations from me:\n\n"
            + entries.joined(separator: "\n\n")
    }

    private func renderState() {
        guard isViewLoaded else { return }
        switch presentationState {
        case .idle:
            deviceChip.configure(symbolName: "iphone", title: L10n.string("Choose Simulator"))
            statusLabel.stringValue = L10n.string("Starting…")
            statusLabel.textColor = Design.Text.tertiary
            retryButton.isEnabled = true
        case .discovering:
            statusLabel.stringValue = L10n.string("Starting…")
            statusLabel.textColor = Design.Text.tertiary
            retryButton.isEnabled = false
        case .preparing(let id):
            let name = devices.first(where: { $0.id == id })?.name ?? L10n.string("iPhone")
            deviceChip.configure(symbolName: "iphone", title: name)
            statusLabel.stringValue = L10n.format("Preparing %@…", name)
            statusLabel.textColor = Design.Text.tertiary
            retryButton.isEnabled = false
        case .ready(let device):
            deviceChip.configure(symbolName: "iphone", title: device.name)
            // The chip already names the device, and a live stream under granted control is the
            // default: the line stays quiet then and speaks up only for what needs attention.
            // Which transport carries the pixels is a diagnostic, so it moves to the tooltip.
            var status = [device.runtimeName]
            switch liveBackend {
            case .screenshotFallback: status.append(L10n.string("Disconnected"))
            case nil: status.append(L10n.string("Connecting…"))
            case .direct, .sharedMemory: break
            }
            if let control = controlStatus() { status.append(control) }
            statusLabel.stringValue = status.joined(separator: " · ")
            statusLabel.textColor = isDisconnected ? Design.Status.negative : Design.Text.tertiary
            retryButton.isEnabled = true
        case .failed(let message):
            statusLabel.stringValue = message
            statusLabel.textColor = Design.Status.negative
            retryButton.isEnabled = true
        }
        if isRecording { showRecordingStatus() }
        recordButton.isEnabled = isRecording ? !isFinishingRecording : canRecord
        refreshPresenterButton()
        // The selected device is useful identity even when it is the only available target.
        // Keeping the chip enabled also lets the user inspect that one-item choice instead of
        // washing the device name out as though Simulator itself were unavailable.
        deviceChip.isEnabled = !devices.isEmpty
        configureControlButton(for: lease?.device)
        configureHardwareButtons()
        configureAppearanceButton()
        var tooltipLines = [statusLabel.stringValue]
        if case .ready = presentationState, let backend = liveBackendDescription {
            tooltipLines.append(backend)
        }
        if let lastStreamFailure,
           !lastStreamFailure.isEmpty,
           lastStreamFailure != statusLabel.stringValue {
            tooltipLines.append(lastStreamFailure)
        }
        statusLabel.toolTip = tooltipLines.joined(separator: "\n")
    }

    /// Red is kept for a pane that lost its device route: on the view-only fallback, or when
    /// enabling control failed. Everything else — connecting, a hint to click — is ordinary text.
    private var isDisconnected: Bool {
        if case .screenshotFallback = liveBackend { return true }
        if case .failed = controlActivity { return true }
        return false
    }

    private var liveBackendDescription: String? {
        switch liveBackend {
        case .direct(.h264): L10n.string("Live H.264")
        case .direct(.jpeg): L10n.string("Live JPEG")
        case .sharedMemory: L10n.string("Live shared memory")
        case .screenshotFallback: L10n.string("Preview fallback")
        case nil: nil
        }
    }

    private func deviceEntries() -> [ThemedMenuEntry] {
        devices.map { device in
            .item(ThemedMenuItem(
                title: device.name,
                subtitle: device.runtimeName,
                representedValue: device.id.rawValue,
                isSelected: device.id == selectedDeviceID
            ))
        }
    }

    var frameImageForTesting: NSImage? { screenView.image }
    var liveBackendForTesting: SimulatorLiveBackend? { liveBackend }
    var isPresentedForTesting: Bool { isPresented }
    var screenInteractionStateForTesting: SimulatorScreenView.InteractionState {
        screenView.interactionState
    }
    var screenViewForTesting: SimulatorScreenView { screenView }
    var statusForTesting: String { statusLabel.stringValue }
    var controlButtonForTesting: ThemedIconButton { controlButton }
    var recordButtonForTesting: ThemedIconButton { recordButton }
    var recordingBadgeForTesting: SimulatorRecordingBadge { recordingBadge }
    var showTouchesButtonForTesting: ThemedIconButton { showTouchesButton }
    var annotateButtonForTesting: ThemedIconButton { annotateButton }
    var presenterButtonForTesting: ThemedIconButton { presenterButton }
    var annotationBandForTesting: PaneNoticeView? { annotationBand }

    /// Puts the pane's recording presentation on screen without a recorder, so a render can show
    /// it without writing a movie into the developer's Movies folder. The recording path itself
    /// is covered by `SimulatorPaneControlsTests` with an injected directory.
    func showRecordingPresentationForTesting(elapsedSeconds: Int?) {
        isRecording = elapsedSeconds != nil
        isFinishingRecording = false
        recordingStartedAt = elapsedSeconds.map { Date().addingTimeInterval(-TimeInterval($0)) }
        refreshRecordingPresentation()
        renderState()
    }
    func performScreenPrimaryActionForTesting() -> Bool { screenView.performPrimaryAction() }
    func retryForTesting() { retry() }
}
