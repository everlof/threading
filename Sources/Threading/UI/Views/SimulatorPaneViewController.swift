import AppKit
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
            symbolName: "hand.tap",
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
            symbolName: "circle.lefthalf.filled",
            accessibility: L10n.string("Toggle appearance"),
            target: .inline,
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
            symbolName: "viewfinder",
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
            symbolName: "note.text",
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
            symbolName: "camera",
            accessibility: L10n.string("Save snapshot"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Save a snapshot of the device (hold Control to copy; right-click for options)")
        button.onPress = { [weak self] in self?.captureButtonPressed() }
        button.onContextMenu = { [weak self] anchor in
            self?.presentCaptureMenu(from: anchor) ?? false
        }
        button.setAccessibilityIdentifier("simulator.capture")
        return button
    }()

    private let captureModifierMonitor = LocalEventMonitor()
    private var captureCopiesSnapshot = false

    private var captureMenuSession: AnyObject?
    private let simctlRecorder = SimulatorSimctlRecorder()
    /// Non-nil while recording via the stream engine (composites the touch overlay).
    private var streamRecorder: SimulatorStreamRecorder?
    private var isRecording = false
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?

    private lazy var showTouchesButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "hand.point.up.left",
            accessibility: L10n.string("Show touches"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Show taps and swipes on the device")
        button.onPress = { [weak self] in self?.toggleShowTouches() }
        button.setAccessibilityIdentifier("simulator.showTouches")
        return button
    }()

    private let touchOverlayModel = SimulatorTouchOverlayModel()
    private var showTouches = false
    private var touchDisplayTimer: Timer?

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

    private lazy var annotationModeButton: ThemedButton = {
        let button = ThemedButton(title: L10n.string("Annotating · Esc to finish"), target: self,
                                  action: #selector(finishAnnotating))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.emphasis = .primary
        button.isHidden = true
        button.setAccessibilityIdentifier("simulator.annotate.done")
        return button
    }()

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

    private lazy var controlRow = ControlRowView(
        leading: [deviceChip],
        trailing: [
            captureButton, showTouchesButton, annotateButton,
            inspectButton, appearanceButton, controlButton, retryButton,
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
        symbol: "speaker.wave.1.fill", title: L10n.string("Volume down"),
        identifier: "simulator.button.volumeDown", button: .volumeDown,
        shortcut: SimulatorPaneShortcuts.volumeDown
    )
    private lazy var volumeUpButton = makeHardwareButton(
        symbol: "speaker.wave.3.fill", title: L10n.string("Volume up"),
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

    /// The device's hardware buttons. A press converges on the same consented input path as a tap,
    /// so it asks for control the first time and fails closed when the lease or consent is gone.
    private lazy var hardwareButtonRow: NSStackView = {
        let stack = NSStackView(views: hardwareButtons)
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.large
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
        preview.onText = { [weak self] text in self?.submitInput(.text(text)) }
        preview.onAddNote = { [weak self] point in self?.addNote(at: point) }
        preview.onSelectNote = { [weak self] id in self?.selectNote(id) }
        preview.onDeleteNote = { [weak self] id in self?.deleteHoveredNote(id) }
        preview.onClearAllNotes = { [weak self] in self?.clearAllNotes() }
        preview.onCommandReturn = { [weak self] in self?.sendPendingNotes() }
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
        inputAuthorizer: any SimulatorInputAuthorizing = SimulatorInputConsentController.shared
    ) {
        self.preferredDeviceID = preferredDeviceID
        self.control = control
        self.leaseManager = leaseManager ?? SimulatorLeaseManager(control: control)
        self.streamCoordinator = streamCoordinator
        self.inputAuthorizer = inputAuthorizer
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
        renderState()
    }

    private func setupUI() {
        view.addSubview(controlRow)
        view.addSubview(screenView)
        view.addSubview(hardwareButtonRow)
        view.addSubview(statusLabel)
        view.addSubview(noteSendBar)
        view.addSubview(annotationModeButton)

        NSLayoutConstraint.activate([
            annotationModeButton.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            annotationModeButton.topAnchor.constraint(equalTo: screenView.topAnchor,
                                                       constant: Design.Spacing.small),
            annotationModeButton.widthAnchor.constraint(lessThanOrEqualTo: screenView.widthAnchor),
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

            screenView.topAnchor.constraint(
                equalTo: controlRow.bottomAnchor,
                constant: Design.Spacing.medium
            ),
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
            stopFrameLoop()
        }
    }

    /// Explicit tab/session teardown. A user-owned boot stays running; a Threading-owned boot is
    /// handed back through the lease capability without retaining this controller.
    func terminate() {
        captureModifierMonitor.remove()
        isPresented = false
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
            defer {
                if self.isPresented, self.lease?.device.id == deviceID {
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
            // A public screenshot is another CoreSimulator service transaction. It must not
            // overlap the adopted private framebuffer stream for the same device; after the
            // capture, reconnect so subsequent input stays on the direct pane transport.
            self.stopTransport()
            defer {
                if self.isPresented, self.lease?.device.id == device.id {
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
                self.screenView.image = image
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
        guard let session = streamSession else {
            completion(.failure(
                "The Simulator is not streaming live; element reading needs the direct pane transport."
            ))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let root = try await session.requestAccessibilitySnapshot()
                guard let self, self.lease?.device.id == device.id,
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
        guard let session = streamSession else {
            completion(.failure(
                "The Simulator is not streaming live; an element screenshot needs the pane transport."
            ))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let root = try await session.requestAccessibilitySnapshot()
                guard let self, self.lease?.device.id == device.id,
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
            self?.agentCommandTasks[id] = nil
        }
    }

    private func startFrameLoop() {
        guard isPresented, let deviceID = lease?.device.id else { return }
        if let streamSession {
            streamSession.setVisible(true)
            if let capabilities = liveCapabilities {
                screenView.interactionState = .ready(
                    touch: capabilities.supportsTouch,
                    keyboard: capabilities.supportsKeyboard
                )
            }
            return
        }
        guard streamTask == nil, fallbackTask == nil else { return }

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
                      self.isPresented,
                      self.lease?.device.id == deviceID else {
                    session.stop()
                    return
                }
                self.streamSession = session
                session.setVisible(true)

                var terminalFailure: String?
                for await event in session.events {
                    guard !Task.isCancelled else { break }
                    guard self.streamGeneration == generation,
                          self.lease?.device.id == deviceID else { break }
                    switch event {
                    case .ready(let backend, let capabilities, _, _):
                        self.liveBackend = backend
                        self.liveCapabilities = capabilities
                        self.screenView.interactionState = .ready(
                            touch: capabilities.supportsTouch,
                            keyboard: capabilities.supportsKeyboard
                        )
                        if let device = self.lease?.device {
                            self.presentationState = .ready(device)
                        }
                    case .frame(let frame):
                        self.screenView.image = NSImage(cgImage: frame.image, size: .zero)
                        self.feedStreamRecorder(frame.image)
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
                self.beginFallback(reason: terminalFailure ?? L10n.string(
                    "The direct Simulator stream ended."
                ))
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.streamGeneration == generation,
                      self.lease?.device.id == deviceID else { return }
                self.streamTask = nil
                self.beginFallback(reason: error.localizedDescription)
            }
        }
    }

    private func beginFallback(reason: String) {
        guard isPresented, let deviceID = lease?.device.id, fallbackTask == nil else { return }
        liveBackend = .screenshotFallback(reason: reason)
        SimulatorStreamDiagnostics.shared.recordedFallback()
        liveCapabilities = nil
        lastStreamFailure = reason
        screenView.interactionState = .recoverable
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
                    self.screenView.image = image
                    if let device = self.lease?.device { self.presentationState = .ready(device) }
                    try await Task.sleep(nanoseconds: Timing.fallbackFrameInterval)
                } catch is CancellationError {
                    return
                } catch let error as SimulatorControlError where error == .cancelled {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.requiresLeaseRefresh = true
                    self.screenView.interactionState = .unavailable
                    self.presentationState = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func stopFrameLoop() {
        screenView.interactionState = .unavailable
        streamSession?.setVisible(false)
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
        fallbackTask?.cancel()
        fallbackTask = nil
        fallbackGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        streamGeneration += 1
        streamSession?.stop()
        streamSession = nil
        liveBackend = nil
        liveCapabilities = nil
        lastStreamFailure = nil
        screenView.interactionState = .unavailable
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
        let session = try await awaitInputSession(for: device.id)
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

    private func awaitInputSession(
        for deviceID: SimulatorDeviceID
    ) async throws -> any SimulatorLiveStreamSession {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
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
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SimulatorLiveStreamError.handshakeTimedOut
    }

    private func inputAuthorization(for device: SimulatorDevice) async -> Bool {
        await withCheckedContinuation { continuation in
            inputAuthorizer.authorize(device: device, in: view.window) {
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
        controlButton.setSymbol("hand.tap", accessibility: title)
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
        annotateButton.isSelected = enabled
        annotationModeButton.isHidden = !enabled
        screenView.isAnnotatingNotes = enabled
        screenView.noteMarks = annotationStore.annotations(for: device)
        screenView.selectedNoteID = nil
        view.window?.makeFirstResponder(screenView)
        updateSendBar()
    }

    @objc private func finishAnnotating() {
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
    }

    private func presentAnnotationMenu(from anchor: ThemedMenuAnchor) -> Bool {
        let hasNotes = !screenView.noteMarks.isEmpty
        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: L10n.string("Copy annotated frame"), isEnabled: hasNotes,
                                onChoose: { [weak self] in self?.exportAnnotatedFrame() })),
            .item(ThemedMenuItem(title: L10n.string("Clear all notes"), isEnabled: hasNotes,
                                onChoose: { [weak self] in self?.clearAllNotes() })),
        ]
        annotationMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: Self.annotationMenuWidth), from: annotateButton, anchor: anchor,
            selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
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
        guard isAnnotatingNotes, let device = lease?.device.id else { return }
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
        flashStatus(L10n.string("Copied annotated frame"))
    }

    // MARK: - Capture (snapshot)

    private func saveSnapshot() {
        guard let device = lease?.device, let data = currentFramePNG() else { return }
        let name = SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "png")
        guard let url = SimulatorCaptureSaver.write(data, suggestedName: name, video: false) else {
            flashStatus(L10n.string("Could not save the snapshot"))
            return
        }
        SimulatorCaptureSaver.reveal(url)
        flashStatus(L10n.string("Saved snapshot"))
    }

    private func copySnapshot() {
        guard let image = screenView.image else { return }
        SimulatorCaptureSaver.copyImage(image)
        flashStatus(L10n.string("Copied snapshot"))
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

    // MARK: - Capture (recording)

    private func captureButtonPressed() {
        if isRecording { stopRecording() } else { saveSnapshot() }
    }

    /// Only one fixed-size control changes; no device/frame work runs on modifier events.
    private func updateCaptureModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let copies = modifiers.contains(.control)
        guard copies != captureCopiesSnapshot else { return }
        captureCopiesSnapshot = copies
        refreshCaptureButton()
    }

    private func refreshCaptureButton() {
        let copies = captureCopiesSnapshot && !isRecording
        let title = isRecording ? L10n.string("Stop recording")
            : copies ? L10n.string("Copy Snapshot") : L10n.string("Save snapshot")
        captureButton.setSymbol(copies ? "doc.on.doc" : "camera", accessibility: title)
        captureButton.toolTip = isRecording || copies ? title
            : L10n.string("Save a snapshot of the device (hold Control to copy; right-click for options)")
        // ThemedIconButton freezes this closure at mouse-down, so releasing Control before
        // mouse-up cannot turn a copy into an unexpected file save.
        captureButton.onPress = { [weak self] in
            guard let self else { return }
            if self.isRecording { self.stopRecording() }
            else if copies { self.copySnapshot() }
            else { self.saveSnapshot() }
        }
    }

    private func videoURL(for device: SimulatorDevice) -> URL {
        SimulatorCaptureSaver.defaultDirectory(video: true).appendingPathComponent(
            SimulatorCaptureSaver.suggestedName(device: device, fileExtension: "mov")
        )
    }

    /// simctl engine — pristine capture, no touch overlay.
    private func startSimctlRecording() {
        guard !isRecording, let device = lease?.device else { return }
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
        guard !isRecording, let device = lease?.device, let image = screenView.image,
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
    }

    private func feedStreamRecorder(_ image: CGImage) {
        streamRecorder?.append(image: image, indicators: touchOverlayModel.indicators())
    }

    private func stopRecording() {
        guard isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusLabel.stringValue = L10n.string("Finishing recording…")
        if let recorder = streamRecorder {
            streamRecorder = nil
            recorder.finish { [weak self] url in self?.finishRecording(saved: url) }
        } else {
            simctlRecorder.stop()  // finishRecording fires from its termination handler
        }
    }

    private func beginRecordingUI() {
        isRecording = true
        recordingStartedAt = Date()
        captureButton.isSelected = true
        refreshCaptureButton()
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRecordingElapsed() }
        }
        RunLoop.current.add(timer, forMode: .common)
        recordingTimer = timer
        updateRecordingElapsed()
    }

    private func updateRecordingElapsed() {
        guard let started = recordingStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(started))
        let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        statusLabel.stringValue = L10n.format("Recording %@", time)
        statusLabel.textColor = Design.Text.secondary
    }

    private func finishRecording(saved url: URL?) {
        isRecording = false
        recordingStartedAt = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        captureButton.isSelected = false
        refreshCaptureButton()
        if let url {
            SimulatorCaptureSaver.reveal(url)
            flashStatus(L10n.string("Saved recording"))
        } else {
            renderState()
        }
    }

    private func presentCaptureMenu(from anchor: ThemedMenuAnchor) -> Bool {
        var entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: L10n.string("Save Snapshot"),
                onChoose: { [weak self] in self?.saveSnapshot() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Copy Snapshot"),
                onChoose: { [weak self] in self?.copySnapshot() }
            )),
            .item(ThemedMenuItem(
                title: L10n.string("Save Snapshot As…"),
                onChoose: { [weak self] in self?.saveSnapshotAs() }
            )),
        ]
        if isRecording {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Stop Recording"),
                onChoose: { [weak self] in self?.stopRecording() }
            )))
        } else {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Record Video with Touches"),
                onChoose: { [weak self] in self?.startStreamRecording() }
            )))
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Record Video (High Quality)"),
                onChoose: { [weak self] in self?.startSimctlRecording() }
            )))
        }
        captureMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 220),
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

    // MARK: - Show touches

    private func toggleShowTouches() {
        showTouches.toggle()
        showTouchesButton.setAccessibilityValue(showTouches ? "on" : "off")
        showTouchesButton.isSelected = showTouches
        if !showTouches {
            touchDisplayTimer?.invalidate()
            touchDisplayTimer = nil
            screenView.touchIndicators = nil
        }
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
        screenView.touchIndicators = indicators.isEmpty ? nil : indicators
        if !touchOverlayModel.hasActivity {
            touchDisplayTimer?.invalidate()
            touchDisplayTimer = nil
            screenView.touchIndicators = nil
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

    /// Briefly show a confirmation in the status line, then restore the normal state.
    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = Design.Text.secondary
        exportConfirmationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderState() }
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
    var statusForTesting: String { statusLabel.stringValue }
    var controlButtonForTesting: ThemedIconButton { controlButton }
    func performScreenPrimaryActionForTesting() -> Bool { screenView.performPrimaryAction() }
    func retryForTesting() { retry() }
}
