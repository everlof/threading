import AppKit
import ImageIO

/// A paired physical iPhone inside the display panel.
///
/// CoreDevice owns authoritative discovery and the screenshot fallback. When the concrete
/// DisplayService/HID operations pass their probe, an explicit visible-pane grant enables the
/// selected phone's touch callbacks. Pairing a phone or detecting its services is never consent.
@MainActor
final class RealDevicePaneViewController: NSViewController {
    enum PresentationState: Equatable {
        case idle
        case discovering
        case ready(PhysicalDevice)
        case failed(String)
    }

    private enum CaptureState: Equatable {
        case idle
        case capturing
        case live
        case toolingRequired
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private enum ControlSupportState: Equatable {
        case idle
        case probing
        case preparing
        case resolved(PhysicalDeviceControlSupport)
    }

    private enum Timing {
        static let maximumPendingInput = 32
        static let menuWidth: CGFloat = 220
        static let touchFramesPerSecond = 30.0
        static let confirmationDuration = 1.8
    }

    private enum RecordingState { case idle, starting, recording, finishing }
    private let touchPreferences: SimulatorTouchPreferences
    private let captureDirectory: URL?
    private let revealCapture: @MainActor (URL) -> Void
    private let showPresenter: @MainActor (SimulatorPresenterWindowController) -> Void
    private var touchPreferencesObserver: NSObjectProtocol?
    private let touchOverlay = SimulatorTouchOverlayModel()
    private var touchTimer: Timer?
    private var recordingTimer: Timer?
    private var latestFrame: CGImage?
    private var recorder: DevicePreviewCapture?
    private var recordingStartTask: Task<Bool, Never>?
    private var frameWriteTask: Task<Void, Never>?
    private var recordingState: RecordingState = .idle
    private var recordingStartedAt: Date?
    private var lastRecordingFrameAt: TimeInterval = 0
    private var captureBusy = false
    private var captureMessageTimer: Timer?
    private var captureMessage: String? {
        didSet {
            captureMessageTimer?.invalidate()
            captureMessageTimer = nil
            guard captureMessage != nil else { return }
            let timer = Timer(timeInterval: Timing.confirmationDuration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.captureMessage = nil
                    self?.renderState()
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            captureMessageTimer = timer
        }
    }
    private var presenter: SimulatorPresenterWindowController?
    private var menuSession: AnyObject?
    private var wantsPreview: Bool {
        isPresented || presenter != nil || recordingState == .starting || recordingState == .recording
    }

    private let control: any PhysicalDeviceControlling
    private let inputAuthorizer: any PhysicalDeviceInputAuthorizing
    private let appEvents: AppEventObservations
    private var preferredDeviceID: PhysicalDeviceID?
    private var devices: [PhysicalDevice] = []
    private var selectedDevice: PhysicalDevice?
    private var discoveryTask: Task<Void, Never>?
    private var controlSupportTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var pendingInput: [PhysicalDeviceInput] = []
    private var inputReady = false
    private var discoveryGeneration = 0
    private var controlSupportGeneration = 0
    private var captureGeneration = 0
    private var inputGeneration = 0
    private var dragOrigin: CGPoint?
    private var inputFailure: String?
    private var isPresented = false
    private var captureState: CaptureState = .idle {
        didSet { renderState() }
    }
    private var controlSupportState: ControlSupportState = .idle {
        didSet { renderState() }
    }

    private(set) var presentationState: PresentationState = .idle {
        didSet { renderState() }
    }

    var selectedDeviceID: PhysicalDeviceID? {
        selectedDevice?.id ?? preferredDeviceID
    }

    var onSelectedDeviceChange: ((PhysicalDeviceID) -> Void)?
    var onOpenDeviceLogs: ((PhysicalDeviceID) -> Void)?
    var onDevicePluginRoutes: ((PhysicalDeviceID) -> [ThemedMenuEntry])?
    var onOpenToolingSettings: (() -> Void)?

    private lazy var deviceChip: ChipView = {
        let chip = ChipView()
        chip.configure(symbolName: "iphone", title: L10n.string("Choose iPhone"))
        chip.itemsProvider = { [weak self] in self?.deviceEntries() ?? [] }
        chip.onSelect = { [weak self] item in
            guard let rawValue = item.representedValue as? String,
                  let id = PhysicalDeviceID(rawValue) else { return }
            self?.selectDevice(id)
        }
        chip.setAccessibilityIdentifier("realDevice.device")
        return chip
    }()

    private lazy var captureButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "camera",
            accessibility: L10n.string("Save Screenshot"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Save a screenshot of the device (right-click for options)")
        button.onPress = { [weak self] in self?.saveSnapshot() }
        button.onContextMenu = { [weak self, weak button] anchor in
            guard let self, let button else { return false }
            return self.presentMenu(self.captureEntries(), from: button, anchor: anchor)
        }
        button.setAccessibilityIdentifier("realDevice.capture")
        return button
    }()

    private lazy var retryButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "arrow.clockwise",
            accessibility: L10n.string("Refresh iPhones"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Refresh iPhones")
        button.onPress = { [weak self] in self?.retry() }
        button.setAccessibilityIdentifier("realDevice.refresh")
        return button
    }()

    private lazy var logsButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "list.bullet.rectangle",
            accessibility: L10n.string("Open Device Logs in Bottom Pane"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Open Device Logs in Bottom Pane (right-click for plugin actions)")
        button.onPress = { [weak self] in
            guard let self, let deviceID = self.selectedDeviceID else { return }
            self.onOpenDeviceLogs?(deviceID)
        }
        button.onContextMenu = { [weak self, weak button] anchor in
            guard let self, let button, let deviceID = self.selectedDeviceID,
                  let entries = self.onDevicePluginRoutes?(deviceID), !entries.isEmpty
            else { return false }
            return self.presentMenu(entries, from: button, anchor: anchor)
        }
        button.setAccessibilityIdentifier("realDevice.logs")
        return button
    }()

    private lazy var controlButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: SimulatorPaneSymbols.control,
            accessibility: L10n.string("Enable iPhone Control"),
            target: .inline,
            inkSource: .chrome
        )
        button.onPress = { [weak self] in self?.activateControl() }
        button.setAccessibilityIdentifier("realDevice.control")
        return button
    }()

    private lazy var controlRow = ControlRowView(
        leading: [deviceChip],
        trailing: [captureButton, recordButton, touchesButton, presenterButton, logsButton, controlButton, retryButton]
    )

    private lazy var recordButton: ThemedIconButton = {
        let button = ThemedIconButton(symbolName: SimulatorPaneSymbols.record,
            accessibility: L10n.string("Record Video"), target: .inline, inkSource: .chrome)
        button.onPress = { [weak self] in self?.toggleRecording() }
        button.setAccessibilityIdentifier("realDevice.record")
        return button
    }()

    private lazy var touchesButton: ThemedIconButton = {
        let button = ThemedIconButton(symbolName: SimulatorPaneSymbols.touches,
            accessibility: L10n.string("Show Touches"), target: .inline, inkSource: .chrome)
        button.onPress = { [weak self] in self?.toggleShowTouches() }
        button.onContextMenu = { [weak self, weak button] anchor in
            guard let self, let button else { return false }
            return self.presentMenu(self.touchEntries(), from: button, anchor: anchor)
        }
        button.setAccessibilityIdentifier("realDevice.touches")
        button.toolTip = L10n.string("Show touches sent through Threading (right-click for style)")
        return button
    }()

    private lazy var presenterButton: ThemedIconButton = {
        let button = ThemedIconButton(symbolName: SimulatorPaneSymbols.presenter,
            accessibility: L10n.string("Open Presenter Window"), target: .inline, inkSource: .chrome)
        button.onPress = { [weak self] in self?.togglePresenterWindow() }
        button.setAccessibilityIdentifier("realDevice.presenter")
        return button
    }()

    private lazy var recordingBadge: SimulatorRecordingBadge = {
        let badge = SimulatorRecordingBadge()
        badge.isHidden = true
        badge.onPress = { [weak self] in self?.stopRecording() }
        badge.setAccessibilityIdentifier("realDevice.recording")
        return badge
    }()

    private lazy var screenView: SimulatorScreenView = {
        let screen = SimulatorScreenView()
        screen.interactionState = .unavailable
        screen.setAccessibilityLabel(L10n.string("iPhone screen"))
        screen.setAccessibilityIdentifier("realDevice.screen")
        screen.onTap = { [weak self] point in
            self?.submitInput(.tap(x: Double(point.x), y: Double(point.y)))
        }
        screen.onTouchBegan = { [weak self] point in
            guard let self else { return }
            self.dragOrigin = point
            if self.control.supportsLiveTouch { self.submitInput(.touchDown(x: point.x, y: point.y)) }
        }
        screen.onTouchMoved = { [weak self] point in
            guard let self, self.control.supportsLiveTouch else { return }
            self.submitInput(.touchMove(x: point.x, y: point.y))
        }
        screen.onTouchEnded = { [weak self] point in
            guard let self, let origin = self.dragOrigin else { return }
            self.dragOrigin = nil
            if self.control.supportsLiveTouch {
                self.submitInput(.touchUp(x: point.x, y: point.y))
                return
            }
            self.submitInput(.drag(
                fromX: Double(origin.x),
                fromY: Double(origin.y),
                toX: Double(point.x),
                toY: Double(point.y)
            ))
        }
        screen.onText = { [weak self] text in self?.submitText(text) }
        screen.onContextMenu = { [weak self, weak screen] request in
            guard let self, let screen else { return false }
            return self.presentMenu(self.screenMenuEntries(), from: screen, anchor: request.anchor)
        }
        return screen
    }()

    private lazy var emptyLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: L10n.string(
            "Connect and unlock a paired iPhone to preview it here."
        ))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.detail())
        label.textColor = Design.Text.secondary
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("realDevice.empty")
        return label
    }()

    private lazy var setupTitle: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: L10n.string("Set up your iPhone"))
        label.applyFont(.emphasizedBody)
        label.textColor = Design.Text.label
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("realDevice.setupTitle")
        return label
    }()

    private lazy var toolingButton: ThemedButton = {
        let button = ThemedButton()
        button.emphasis = .primary
        button.target = self
        button.action = #selector(openToolingSettings)
        button.setAccessibilityIdentifier("realDevice.setupTooling")
        return button
    }()

    private lazy var emptyContent: NSStackView = {
        let announcement = NSStackView(views: [setupTitle, emptyLabel])
        announcement.orientation = .vertical
        announcement.alignment = .centerX
        announcement.spacing = Design.Placeholder.line
        let stack = NSStackView(views: [announcement, toolingButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Placeholder.group
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The paragraph wraps within the pane instead of widening its split item.
        NSLayoutConstraint.activate([
            announcement.widthAnchor.constraint(equalTo: stack.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: announcement.widthAnchor),
            setupTitle.widthAnchor.constraint(equalTo: announcement.widthAnchor),
        ])
        return stack
    }()

    private lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.detail())
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("realDevice.status")
        return label
    }()

    init(
        preferredDeviceID: PhysicalDeviceID? = nil,
        control: any PhysicalDeviceControlling = PersistentPhysicalDeviceControl(),
        inputAuthorizer: any PhysicalDeviceInputAuthorizing =
            PhysicalDeviceInputConsentController(),
        notificationCenter: NotificationCenter = .default,
        touchPreferences: SimulatorTouchPreferences? = nil,
        captureDirectory: URL? = nil,
        revealCapture: (@MainActor (URL) -> Void)? = nil,
        showPresenter: (@MainActor (SimulatorPresenterWindowController) -> Void)? = nil
    ) {
        self.touchPreferences = touchPreferences ?? .shared
        self.captureDirectory = captureDirectory
        self.revealCapture = revealCapture ?? SimulatorCaptureSaver.reveal
        self.showPresenter = showPresenter ?? { $0.showWindow(nil) }
        self.preferredDeviceID = preferredDeviceID
        self.control = control
        self.inputAuthorizer = inputAuthorizer
        self.appEvents = AppEventObservations(center: notificationCenter)
        super.init(nibName: nil, bundle: nil)
        appEvents.observe(Pymobiledevice3ToolDidInstall.self) { [weak self] _ in
            guard let self, self.isPresented, self.needsToolingSetup else { return }
            self.retry()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.setAccessibilityIdentifier("realDevice.pane")
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        touchPreferencesObserver = NotificationCenter.default.addObserver(
            forName: SimulatorTouchPreferences.didChange, object: touchPreferences, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTouchPreferences() }
        }
        applyTouchPreferences()
        renderState()
    }

    private func setupUI() {
        view.addSubview(controlRow)
        view.addSubview(screenView)
        view.addSubview(emptyContent)
        view.addSubview(statusLabel)
        view.addSubview(recordingBadge)

        NSLayoutConstraint.activate([
            recordingBadge.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            recordingBadge.topAnchor.constraint(equalTo: screenView.topAnchor, constant: Design.Spacing.small),
            recordingBadge.widthAnchor.constraint(lessThanOrEqualTo: screenView.widthAnchor),
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
                equalTo: statusLabel.topAnchor,
                constant: -Design.Spacing.medium
            ),

            emptyContent.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            emptyContent.centerYAnchor.constraint(equalTo: screenView.centerYAnchor),
            emptyContent.leadingAnchor.constraint(
                greaterThanOrEqualTo: screenView.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            emptyContent.trailingAnchor.constraint(
                lessThanOrEqualTo: screenView.trailingAnchor,
                constant: -Design.Spacing.inset
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
            ),
        ])
    }

    /// AppKit retains inactive tab controllers. The host states visibility explicitly so a hidden
    /// physical-device tab performs no capture and retains only its last local frame.
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            if let selectedDevice {
                presentationState = .ready(selectedDevice)
                startControlSupportProbe(for: selectedDevice)
                if captureTask == nil { startCaptureLoop(for: selectedDevice) }
            } else {
                discover(preferredDeviceID)
            }
        } else {
            revokeControl()
            stopDiscovery()
            stopControlSupportProbe()
            if !wantsPreview { stopCapture() }
        }
        renderState()
    }

    func terminate() {
        stopRecording()
        closePresenterWindow()
        captureMessage = nil
        touchTimer?.invalidate()
        touchTimer = nil
        if let touchPreferencesObserver {
            NotificationCenter.default.removeObserver(touchPreferencesObserver)
            self.touchPreferencesObserver = nil
        }
        ThemedMenuPresenter.dismiss(menuSession)
        menuSession = nil
        isPresented = false
        revokeControl()
        stopDiscovery()
        stopControlSupportProbe()
        stopCapture()
    }

    func selectDevice(_ id: PhysicalDeviceID) {
        guard id != selectedDeviceID else { return }
        stopRecording()
        closePresenterWindow()
        stopCapture()
        revokeControl()
        captureMessage = nil
        preferredDeviceID = id
        selectedDevice = nil
        clearFrame()
        captureState = .idle
        stopControlSupportProbe()
        stopInput()
        guard isPresented else {
            presentationState = .idle
            return
        }
        discover(id)
    }

    private func retry() {
        guard isPresented else { return }
        stopRecording()
        captureMessage = nil
        clearFrame()
        captureState = .idle
        stopControlSupportProbe()
        stopInput()
        discover(preferredDeviceID)
    }

    private func discover(_ requestedID: PhysicalDeviceID?) {
        guard isPresented else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        discoveryTask?.cancel()
        stopControlSupportProbe()
        stopCapture()
        presentationState = .discovering
        let control = control

        discoveryTask = Task { [weak self] in
            defer {
                if self?.discoveryGeneration == generation { self?.discoveryTask = nil }
            }
            do {
                let devices = try await control.availableDevices()
                try Task.checkCancellation()
                guard let self, self.discoveryGeneration == generation else { return }
                self.devices = devices
                let device: PhysicalDevice
                if let requestedID {
                    guard let requested = devices.first(where: { $0.id == requestedID }) else {
                        throw PhysicalDeviceControlError.deviceNotFound(requestedID)
                    }
                    device = requested
                } else if let first = devices.first {
                    device = first
                } else {
                    throw PhysicalDeviceControlError.noAvailableIPhones
                }
                self.preferredDeviceID = device.id
                self.selectedDevice = device
                self.presentationState = .ready(device)
                self.onSelectedDeviceChange?(device.id)
                self.startControlSupportProbe(for: device)
                self.startCaptureLoop(for: device)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.discoveryGeneration == generation else {
                    return
                }
                self.selectedDevice = nil
                self.presentationState = .failed(error.localizedDescription)
            }
        }
    }

    private func stopDiscovery() {
        discoveryGeneration += 1
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    private func startControlSupportProbe(for device: PhysicalDevice) {
        guard isPresented else { return }
        stopControlSupportProbe()
        controlSupportGeneration += 1
        let generation = controlSupportGeneration
        let control = control
        controlSupportState = .probing

        controlSupportTask = Task { [weak self] in
            defer {
                if self?.controlSupportGeneration == generation {
                    self?.controlSupportTask = nil
                }
            }
            do {
                let support = try await control.controlSupport(of: device)
                try Task.checkCancellation()
                guard let self,
                      self.isPresented,
                      self.controlSupportGeneration == generation,
                      self.selectedDevice?.id == device.id else { return }
                self.controlSupportState = .resolved(support)
            } catch is CancellationError {
                return
            } catch PhysicalDeviceControlError.cancelled {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.controlSupportGeneration == generation else { return }
                self.controlSupportState = .resolved(.unknown(.probeFailed))
            }
        }
    }

    private func prepareControl(for device: PhysicalDevice) {
        guard isPresented else { return }
        stopControlSupportProbe()
        controlSupportGeneration += 1
        let generation = controlSupportGeneration
        let control = control
        inputFailure = nil
        controlSupportState = .preparing

        controlSupportTask = Task { [weak self] in
            defer {
                if self?.controlSupportGeneration == generation {
                    self?.controlSupportTask = nil
                }
            }
            do {
                try await control.prepareControl(of: device)
                try Task.checkCancellation()
                guard let self,
                      self.isPresented,
                      self.controlSupportGeneration == generation,
                      self.selectedDevice?.id == device.id else { return }
                self.startControlSupportProbe(for: device)
            } catch is CancellationError {
                return
            } catch PhysicalDeviceControlError.cancelled {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.controlSupportGeneration == generation else { return }
                self.inputFailure = error.localizedDescription
                self.controlSupportState = .resolved(.unknown(.probeFailed))
            }
        }
    }

    private func stopControlSupportProbe() {
        controlSupportGeneration += 1
        controlSupportTask?.cancel()
        controlSupportTask = nil
        controlSupportState = .idle
    }

    private func activateControl() {
        guard let device = selectedDevice, isPresented else { return }
        captureMessage = nil
        if needsToolingSetup {
            openToolingSettings()
            return
        }
        switch controlSupportState {
        case .resolved(.available):
            if inputAuthorizer.decision(for: device.id) == true {
                revokeControl()
                return
            }
            inputAuthorizer.resetDecision(for: device.id)
            inputAuthorizer.authorize(device: device, in: view.window) { [weak self] approved in
                guard let self else { return }
                guard self.isPresented, self.selectedDevice?.id == device.id else {
                    self.inputAuthorizer.revokeDecision(for: device.id)
                    return
                }
                self.inputFailure = approved ? nil : L10n.string("Control denied")
                if approved { self.connectInput(for: device) }
                self.renderState()
            }
        case .resolved(.unknown(.probeFailed)):
            prepareControl(for: device)
        case .idle, .probing, .preparing, .resolved:
            break
        }
    }

    private func revokeControl() {
        if let deviceID = selectedDeviceID {
            inputAuthorizer.revokeDecision(for: deviceID)
        }
        stopInput()
        inputFailure = nil
        renderState()
    }

    private func submitInput(_ input: PhysicalDeviceInput) {
        guard isPresented, inputReady,
              let device = selectedDevice,
              inputAuthorizer.decision(for: device.id) == true,
              case .resolved(.available) = controlSupportState else { return }

        if case .touchMove = input, case .touchMove? = pendingInput.last {
            pendingInput[pendingInput.count - 1] = input
        } else {
            guard pendingInput.count < Timing.maximumPendingInput else {
                revokeControl()
                inputFailure = L10n.string("Control interrupted. Enable control again to reconnect.")
                renderState()
                return
            }
            pendingInput.append(input)
        }
        showTouch(input)
        guard inputTask == nil else { return }

        inputGeneration += 1
        let generation = inputGeneration
        let control = control
        inputTask = Task { [weak self] in
            defer {
                if self?.inputGeneration == generation {
                    self?.inputTask = nil
                }
            }
            do {
                while let self, self.isPresented, self.inputGeneration == generation,
                      self.selectedDevice?.id == device.id,
                      self.inputAuthorizer.decision(for: device.id) == true,
                      !self.pendingInput.isEmpty {
                    let next = self.pendingInput.removeFirst()
                    try await control.sendInput(next, to: device)
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                guard let self,
                      self.isPresented,
                      self.inputGeneration == generation,
                      self.selectedDevice?.id == device.id else { return }
                self.inputFailure = nil
                self.renderState()
            } catch is CancellationError {
                return
            } catch PhysicalDeviceControlError.cancelled {
                return
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.inputGeneration == generation else { return }
                self.revokeControl()
                self.inputFailure = error.localizedDescription
                self.renderState()
            }
        }
    }

    private func submitText(_ text: String) {
        guard control.supportsKeyboardInput else { return }
        do {
            for input in try PhysicalDeviceKeyboard.inputs(for: text) {
                submitInput(input)
            }
        } catch {
            inputFailure = L10n.string(
                "This iPhone keyboard currently supports standard US text and editing keys."
            )
            renderState()
        }
    }

    private func stopInput() {
        inputGeneration += 1
        inputTask?.cancel()
        inputTask = nil
        pendingInput.removeAll(keepingCapacity: true)
        inputReady = false
        control.stopInput()
        dragOrigin = nil
        touchOverlay.reset()
        screenView.touchIndicators = nil
        presenter?.screenView.touchIndicators = nil
        touchTimer?.invalidate()
        touchTimer = nil
    }

    private func connectInput(for device: PhysicalDevice) {
        stopInput()
        if !control.supportsLiveTouch {
            inputReady = true
            return
        }
        let generation = inputGeneration
        let control = control
        inputTask = Task { [weak self] in
            do {
                try await control.beginInput(of: device)
                try Task.checkCancellation()
                guard let self, self.isPresented, self.inputGeneration == generation,
                      self.selectedDevice?.id == device.id,
                      self.inputAuthorizer.decision(for: device.id) == true else { return }
                self.inputTask = nil
                self.inputReady = true
                self.renderState()
            } catch {
                guard let self, self.inputGeneration == generation, !Task.isCancelled else { return }
                self.revokeControl()
                self.inputFailure = error.localizedDescription
                self.renderState()
            }
        }
    }

    private func startCaptureLoop(for device: PhysicalDevice) {
        guard wantsPreview else { return }
        stopCapture()
        captureGeneration += 1
        let generation = captureGeneration
        let control = control
        captureState = .capturing
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let started = ContinuousClock.now
                    if self?.captureState == .capturing { try await control.preparePreview(of: device) }
                    let data = try await control.screenshot(of: device)
                    try Task.checkCancellation()
                    guard let cgImage = await Self.decodedCGImage(from: data) else {
                        throw PhysicalDeviceControlError.invalidScreenshot
                    }
                    guard let self,
                          self.wantsPreview,
                          self.captureGeneration == generation,
                          self.selectedDevice?.id == device.id else { return }
                    if let previous = self.screenView.image,
                       previous.size != NSSize(width: cgImage.width, height: cgImage.height) {
                        self.stopRecording()
                        self.revokeControl()
                    }
                    self.showFrame(cgImage)
                    if self.captureState != .live { self.captureState = .live }
                    try await Task.sleep(until: started.advanced(by: control.frameInterval), clock: .continuous)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.captureGeneration == generation else { return }
                    self.stopRecording()
                    self.revokeControl()
                    self.captureTask = nil
                    control.stopPreview()
                    if error as? PhysicalDeviceControlError == .screenshotToolUnavailable {
                        self.captureState = .toolingRequired
                    } else {
                        self.captureState = .failed(error.localizedDescription)
                    }
                    return
                }
            }
        }
    }

    private func stopCapture() {
        captureGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        control.stopPreview()
        if captureState == .capturing { captureState = .idle }
    }

    /// Full-resolution phone PNG decoding is worker work. Only the immutable Core Graphics image
    /// crosses back to the main actor; AppKit wraps it after the bounded decode has completed.
    private nonisolated static func decodedCGImage(from data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= PhysicalDeviceDefaults.maximumScreenshotPixels / height else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }.value
    }

    private func renderState() {
        guard isViewLoaded else { return }
        switch presentationState {
        case .idle:
            deviceChip.configure(symbolName: "iphone", title: L10n.string("Choose iPhone"))
            statusLabel.stringValue = L10n.string("Starting…")
            statusLabel.textColor = Design.Text.tertiary
            retryButton.isEnabled = true
        case .discovering:
            statusLabel.stringValue = L10n.string("Looking for paired iPhones…")
            statusLabel.textColor = Design.Text.tertiary
            retryButton.isEnabled = false
        case .ready(let device):
            deviceChip.configure(symbolName: "iphone", title: device.name)
            var deviceParts = [
                device.runtimeName,
                device.connection.displayName,
            ]
            switch captureState {
            case .idle: break
            case .capturing: deviceParts.append(L10n.string("Capturing…"))
            case .live: deviceParts.append(L10n.string("Preview fallback"))
            case .toolingRequired: deviceParts.append(L10n.string("Setup required"))
            case .failed(let message): deviceParts.append(message)
            }
            statusLabel.stringValue = [
                deviceParts.joined(separator: " · "),
                controlSupportSummary,
            ].joined(separator: "\n")
            statusLabel.textColor = captureState.isFailure
                ? Design.Status.negative
                : Design.Text.tertiary
            retryButton.isEnabled = true
        case .failed(let message):
            deviceChip.configure(symbolName: "iphone", title: L10n.string("Choose iPhone"))
            statusLabel.stringValue = message
            statusLabel.textColor = Design.Status.negative
            retryButton.isEnabled = true
        }

        let needsSetup = needsToolingSetup
        emptyContent.isHidden = screenView.image != nil
        emptyLabel.isHidden = screenView.image != nil
        setupTitle.isHidden = !needsSetup
        toolingButton.isHidden = !needsSetup
        toolingButton.isEnabled = isPresented && needsSetup
        toolingButton.title = toolingActionTitle
        emptyLabel.stringValue = needsSetup
            ? L10n.string("Install or update iPhone tooling to preview and control this phone. Settings will guide you; the pane retries when installation finishes.")
            : L10n.string("Connect and unlock a paired iPhone to preview it here.")
        deviceChip.isEnabled = !devices.isEmpty
        if case .ready = presentationState {
            logsButton.isEnabled = selectedDeviceID != nil
        } else {
            logsButton.isEnabled = false
        }
        captureButton.isEnabled = canSaveSnapshot
        refreshCapturePresentation()
        configureControlButton()
        configureScreenInteraction()
        statusLabel.toolTip = statusLabel.stringValue
    }

    private func configureControlButton() {
        let decision = selectedDeviceID.flatMap { inputAuthorizer.decision(for: $0) }
        if needsToolingSetup {
            controlButton.setSymbol(SimulatorPaneSymbols.control, accessibility: toolingActionTitle)
            controlButton.toolTip = toolingActionTitle
            controlButton.isSelected = false
            controlButton.isEnabled = isPresented && selectedDevice != nil
            return
        }
        let title: String
        let enabled: Bool
        switch controlSupportState {
        case .idle, .probing:
            title = L10n.string("Checking iPhone Control…")
            enabled = false
        case .preparing:
            title = L10n.string("Preparing iPhone control…")
            enabled = false
        case .resolved(.unknown(.probeFailed)):
            title = L10n.string("Prepare iPhone Control")
            enabled = selectedDevice != nil
        case .resolved(.unknown):
            title = L10n.string("iPhone Control Unavailable")
            enabled = false
        case .resolved(.unavailable):
            title = L10n.string("iPhone Control Unavailable")
            enabled = false
        case .resolved(.available):
            if decision == true {
                title = L10n.string("Disable iPhone Control")
            } else if decision == false {
                title = L10n.string("Retry iPhone Control")
            } else {
                title = L10n.string("Enable iPhone Control")
            }
            enabled = selectedDevice != nil
        }
        controlButton.setSymbol(
            decision == false ? SimulatorPaneSymbols.controlDenied : SimulatorPaneSymbols.control,
            accessibility: title
        )
        controlButton.toolTip = title
        controlButton.isSelected = decision == true
        controlButton.isEnabled = isPresented && enabled
    }

    private func configureScreenInteraction() {
        guard inputReady, let deviceID = selectedDeviceID,
              inputAuthorizer.decision(for: deviceID) == true,
              case .resolved(.available) = controlSupportState else {
            screenView.interactionState = .unavailable
            presenter?.screenView.interactionState = .unavailable
            return
        }
        screenView.interactionState = .ready(
            touch: true,
            keyboard: control.supportsKeyboardInput
        )
        presenter?.screenView.interactionState = screenView.interactionState
    }

    private func deviceEntries() -> [ThemedMenuEntry] {
        devices.map { device in
            .item(ThemedMenuItem(
                title: device.name,
                subtitle: "\(device.runtimeName) · \(device.connection.displayName)",
                representedValue: device.id.rawValue,
                isSelected: device.id == selectedDeviceID
            ))
        }
    }

    private var controlSupportSummary: String {
        let detail: String?
        switch controlSupportState {
        case .idle:
            detail = nil
        case .probing:
            detail = L10n.string("Checking control support…")
        case .preparing:
            detail = L10n.string("Preparing iPhone control…")
        case .resolved(.unknown(.probeToolUnavailable)),
             .resolved(.unknown(.probeFailed)):
            detail = inputFailure ?? L10n.string("Control check unavailable")
        case .resolved(.unknown(.probeVersionUnsupported)):
            detail = L10n.string("Control check needs a newer pymobiledevice3")
        case .resolved(.unavailable(.mediaStreamingUnavailable)):
            detail = L10n.string("Media streaming unavailable")
        case .resolved(.unavailable(.mainTouchscreenUnavailable)):
            detail = L10n.string("Touch surface unavailable")
        case .resolved(.available):
            if let inputFailure {
                detail = inputFailure
            } else if let deviceID = selectedDeviceID,
                      inputAuthorizer.decision(for: deviceID) == true {
                detail = inputReady ? L10n.string("Control ready") : L10n.string("Preparing iPhone control…")
            } else if let deviceID = selectedDeviceID,
                      inputAuthorizer.decision(for: deviceID) == false {
                detail = L10n.string("Control denied")
            } else {
                detail = L10n.string("Click to enable control")
            }
        }
        let isControlReady = inputReady && (selectedDeviceID.map {
            inputAuthorizer.decision(for: $0) == true
        } ?? false)
        return [isControlReady ? nil : L10n.string("View only"), detail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var needsToolingSetup: Bool {
        guard case .ready = presentationState else { return false }
        if captureState == .toolingRequired { return true }
        switch controlSupportState {
        case .resolved(.unknown(.probeToolUnavailable)),
             .resolved(.unknown(.probeVersionUnsupported)):
            return true
        default:
            return false
        }
    }

    private var toolingActionTitle: String {
        if case .resolved(.unknown(.probeVersionUnsupported)) = controlSupportState {
            return L10n.string("Update iPhone Tooling…")
        }
        return L10n.string("Install iPhone Tooling…")
    }

    @objc private func openToolingSettings() {
        guard isPresented, needsToolingSetup else { return }
        if let onOpenToolingSettings {
            onOpenToolingSettings()
        } else {
            (view.window?.windowController as? MainWindowController)?.showSettingsPage(
                id: SettingsPages.advancedID,
                revealing: AdvancedStrings.iphoneToolingTitle
            )
        }
    }

    // MARK: - Capture and presentation

    var canCapture: Bool { wantsPreview && latestFrame != nil && captureState == .live }
    var canSaveSnapshot: Bool { canCapture && !captureBusy }
    var canRecord: Bool { canCapture && recordingState == .idle }
    var isRecordingForCommands: Bool { recordingState == .starting || recordingState == .recording }
    var isPresenterWindowOpen: Bool { presenter != nil }

    private func clearFrame() {
        latestFrame = nil
        screenView.image = nil
        presenter?.screenView.image = nil
    }

    private func showFrame(_ image: CGImage) {
        latestFrame = image
        let frame = NSImage(cgImage: image, size: .zero)
        screenView.image = frame
        presenter?.screenView.image = frame
        presenter?.adoptFrameSize(frame.size)
        appendRecordingFrame(image)
    }

    private func appendRecordingFrame(_ image: CGImage) {
        guard recordingState == .recording, frameWriteTask == nil, let recorder else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecordingFrameAt >= 1.0 / Timing.touchFramesPerSecond else { return }
        lastRecordingFrameAt = now
        let indicators = touchOverlay.indicators()
        let style = touchPreferences.style
        let ink = SimulatorTouchMarks.Ink(style: style)
        frameWriteTask = Task { [weak self] in
            await recorder.append(image: image, indicators: indicators, style: style, ink: ink)
            self?.frameWriteTask = nil
        }
    }

    func saveSnapshot() { captureSnapshot(copying: false) }
    func copySnapshot() { captureSnapshot(copying: true) }

    private func captureSnapshot(copying: Bool) {
        guard canSaveSnapshot, let image = latestFrame, let device = selectedDevice else { return }
        captureBusy = true
        captureMessage = nil
        renderState()
        let directory = captureDirectory
        Task { [weak self] in
            if copying {
                let data = await Task.detached(priority: .userInitiated) {
                    DevicePreviewCapture.png(image)
                }.value
                if let data {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                }
                self?.captureMessage = data == nil
                    ? L10n.string("Could not copy the screenshot") : L10n.string("Copied screenshot")
            } else {
                let url = await Task.detached(priority: .userInitiated) {
                    DevicePreviewCapture.save(image, deviceName: device.name, directory: directory)
                }.value
                if let url { self?.revealCapture(url) }
                self?.captureMessage = url == nil
                    ? L10n.string("Could not save the screenshot") : L10n.string("Saved screenshot")
            }
            self?.captureBusy = false
            self?.renderState()
        }
    }

    func toggleRecording() {
        if isRecordingForCommands { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard canRecord, let image = latestFrame, let device = selectedDevice else { return }
        let recorder = DevicePreviewCapture()
        self.recorder = recorder
        recordingState = .starting
        recordingStartedAt = Date()
        lastRecordingFrameAt = ProcessInfo.processInfo.systemUptime
        captureMessage = nil
        let directory = captureDirectory
        let indicators = touchOverlay.indicators()
        let style = touchPreferences.style
        let ink = SimulatorTouchMarks.Ink(style: style)
        recordingStartTask = Task {
            let url = await Task.detached(priority: .userInitiated) {
                DevicePreviewCapture.destination(deviceName: device.name, video: true, directory: directory)
            }.value
            return await recorder.start(url: url, image: image, indicators: indicators, style: style, ink: ink)
        }
        let startTask = recordingStartTask
        Task { [weak self] in
            let started = await startTask?.value == true
            guard let self, self.recorder === recorder, self.recordingState == .starting else { return }
            self.recordingStartTask = nil
            if started {
                self.recordingState = .recording
            } else {
                self.recordingState = .idle
                self.recorder = nil
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.captureMessage = L10n.string("Could not start recording")
                self.releaseUnwatchedPreview()
            }
            self.renderState()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCapturePresentation() }
        }
        RunLoop.current.add(timer, forMode: .common)
        recordingTimer = timer
        renderState()
    }

    func stopRecording() {
        guard isRecordingForCommands, let recorder else { return }
        recordingState = .finishing
        recordingTimer?.invalidate()
        recordingTimer = nil
        let startTask = recordingStartTask
        let appendTask = frameWriteTask
        renderState()
        releaseUnwatchedPreview()
        // Start/append may still own the worker. Finish only after those accepted operations.
        Task { [weak self] in
            _ = await startTask?.value
            await appendTask?.value
            let url = await recorder.finish()
            guard let self, self.recorder === recorder else { return }
            self.recorder = nil
            self.recordingStartTask = nil
            self.recordingState = .idle
            self.recordingStartedAt = nil
            self.captureMessage = url == nil
                ? L10n.string("Could not save recording") : L10n.string("Saved recording")
            if let url { self.revealCapture(url) }
            self.renderState()
        }
    }

    private func refreshCapturePresentation() {
        let active = isRecordingForCommands
        let finishing = recordingState == .finishing
        let elapsed = max(0, Int(recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0))
        let title = finishing ? L10n.string("Saving recording…")
            : active ? L10n.string("Stop Recording") : L10n.string("Record Video")
        recordButton.setSymbol(active ? SimulatorPaneSymbols.stopRecording : SimulatorPaneSymbols.record,
                               accessibility: title)
        recordButton.toolTip = active || finishing ? title
            : L10n.string("Record the iPhone preview with Threading touches; frame rate follows the connection")
        recordButton.isSelected = active
        recordButton.isEnabled = active || canRecord
        recordingBadge.isHidden = !active && !finishing
        recordingBadge.phase = finishing ? .finishing : .recording(elapsedSeconds: elapsed)
        screenView.isRecording = active
        presenter?.screenView.isRecording = active
        let presenterTitle = presenter == nil ? L10n.string("Open Presenter Window")
            : L10n.string("Close Presenter Window")
        presenterButton.setSymbol(SimulatorPaneSymbols.presenter, accessibility: presenterTitle)
        presenterButton.toolTip = presenterTitle
        presenterButton.isSelected = presenter != nil
        presenterButton.isEnabled = presenter != nil || canCapture
        if active || finishing {
            let recordingText = finishing ? title
                : L10n.format("Recording %@", SimulatorRecordingBadge.elapsedText(elapsed))
            statusLabel.stringValue = [recordingText, controlSupportSummary].joined(separator: "\n")
            statusLabel.textColor = Design.Status.negative
        } else if let captureMessage, captureState == .live {
            statusLabel.stringValue = [captureMessage, controlSupportSummary].joined(separator: "\n")
        }
    }

    func togglePresenterWindow() {
        if presenter != nil { closePresenterWindow(); return }
        guard canCapture, let device = selectedDevice else { return }
        let controller = SimulatorPresenterWindowController(deviceName: device.name)
        let mirror = controller.screenView
        mirror.setAccessibilityLabel(L10n.string("iPhone screen"))
        mirror.image = screenView.image
        mirror.touchStyle = touchPreferences.style
        mirror.touchIndicators = screenView.touchIndicators
        mirror.interactionState = screenView.interactionState
        mirror.onTap = screenView.onTap
        mirror.onTouchBegan = screenView.onTouchBegan
        mirror.onTouchMoved = screenView.onTouchMoved
        mirror.onTouchEnded = screenView.onTouchEnded
        mirror.onText = screenView.onText
        mirror.onContextMenu = { [weak self, weak mirror] request in
            guard let self, let mirror else { return false }
            return self.presentMenu(self.screenMenuEntries(), from: mirror, anchor: request.anchor)
        }
        if let image = screenView.image { controller.adoptFrameSize(image.size) }
        controller.onClose = { [weak self] in
            self?.presenter = nil
            self?.releaseUnwatchedPreview()
            self?.renderState()
        }
        presenter = controller
        controller.placeBeside(view.window)
        renderState()
        showPresenter(controller)
    }

    private func closePresenterWindow() {
        guard let presenter else { return }
        self.presenter = nil
        presenter.onClose = nil
        presenter.close()
        releaseUnwatchedPreview()
        renderState()
    }

    private func releaseUnwatchedPreview() {
        if !wantsPreview { stopCapture() }
    }

    // MARK: - Touch overlays

    func toggleShowTouches() { touchPreferences.showsLiveTouches.toggle() }

    private func applyTouchPreferences() {
        screenView.touchStyle = touchPreferences.style
        presenter?.screenView.touchStyle = touchPreferences.style
        let shows = touchPreferences.showsLiveTouches
        touchesButton.isSelected = shows
        touchesButton.setSymbol(SimulatorPaneSymbols.touches,
            accessibility: shows ? L10n.string("Hide Touches") : L10n.string("Show Touches"))
        if !shows {
            if !isRecordingForCommands {
                touchTimer?.invalidate()
                touchTimer = nil
            }
            screenView.touchIndicators = nil
            presenter?.screenView.touchIndicators = nil
        }
    }

    private func showTouch(_ input: PhysicalDeviceInput) {
        guard touchPreferences.showsLiveTouches || isRecordingForCommands else { return }
        switch input {
        case .tap(let x, let y): touchOverlay.tap(at: CGPoint(x: x, y: y))
        case .touchDown(let x, let y): touchOverlay.contactBegan(at: CGPoint(x: x, y: y))
        case .touchMove(let x, let y): touchOverlay.contactMoved(to: CGPoint(x: x, y: y))
        case .touchUp(let x, let y): touchOverlay.contactEnded(at: CGPoint(x: x, y: y))
        case .drag(let fromX, let fromY, let toX, let toY):
            touchOverlay.contactBegan(at: CGPoint(x: fromX, y: fromY))
            touchOverlay.contactMoved(to: CGPoint(x: toX, y: toY))
            touchOverlay.contactEnded(at: CGPoint(x: toX, y: toY))
        default: return
        }
        // A slow screenshot connection can go a whole ripple lifetime between frames. Capture
        // accepted input on the current picture too, so a tap is not lost from the movie.
        if let latestFrame { appendRecordingFrame(latestFrame) }
        guard touchTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / Timing.touchFramesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTouches() }
        }
        RunLoop.current.add(timer, forMode: .common)
        touchTimer = timer
        tickTouches()
    }

    private func tickTouches() {
        let indicators = touchOverlay.indicators()
        screenView.touchIndicators = touchPreferences.showsLiveTouches && !indicators.isEmpty ? indicators : nil
        presenter?.screenView.touchIndicators = screenView.touchIndicators
        if let latestFrame { appendRecordingFrame(latestFrame) }
        if !touchOverlay.hasActivity {
            touchTimer?.invalidate()
            touchTimer = nil
        }
    }

    private func updateTouchStyle(_ change: (inout SimulatorTouchStyle) -> Void) {
        var style = touchPreferences.style
        change(&style)
        touchPreferences.style = style
    }

    private func touchEntries() -> [ThemedMenuEntry] {
        let style = touchPreferences.style
        return [
            .item(ThemedMenuItem(title: L10n.string("Show Touches"),
                isSelected: touchPreferences.showsLiveTouches,
                onChoose: { [weak self] in self?.toggleShowTouches() })),
            .item(ThemedMenuItem(title: L10n.string("Color"), submenu:
                SimulatorTouchStyle.Color.allCases.map { color in
                    .item(ThemedMenuItem(title: Design.SimulatorTouch.name(color),
                        image: Design.SimulatorTouch.swatch(color), isSelected: style.color == color,
                        onChoose: { [weak self] in self?.updateTouchStyle { $0.color = color } }))
                })),
            .item(ThemedMenuItem(title: L10n.string("Size"), submenu:
                SimulatorTouchStyle.Size.allCases.map { size in
                    .item(ThemedMenuItem(title: Design.SimulatorTouch.name(size), isSelected: style.size == size,
                        onChoose: { [weak self] in self?.updateTouchStyle { $0.size = size } }))
                })),
            .item(ThemedMenuItem(title: L10n.string("Show Swipe Trail"), isSelected: style.showsTrail,
                onChoose: { [weak self] in self?.updateTouchStyle { $0.showsTrail.toggle() } })),
        ]
    }

    private func captureEntries() -> [ThemedMenuEntry] {
        [
            .item(ThemedMenuItem(title: L10n.string("Save Screenshot"), isEnabled: canSaveSnapshot,
                onChoose: { [weak self] in self?.saveSnapshot() })),
            .item(ThemedMenuItem(title: L10n.string("Copy Screenshot"), isEnabled: canSaveSnapshot,
                onChoose: { [weak self] in self?.copySnapshot() })),
        ]
    }

    func screenMenuEntries() -> [ThemedMenuEntry] {
        captureEntries() + [
            .item(ThemedMenuItem(title: isRecordingForCommands ? L10n.string("Stop Recording") : L10n.string("Record Video"),
                isEnabled: isRecordingForCommands || canRecord,
                onChoose: { [weak self] in self?.toggleRecording() })),
            .separator,
        ] + touchEntries() + [
            .separator,
            .item(ThemedMenuItem(title: presenter == nil ? L10n.string("Open Presenter Window") : L10n.string("Close Presenter Window"),
                isEnabled: presenter != nil || canCapture,
                onChoose: { [weak self] in self?.togglePresenterWindow() })),
            .item(ThemedMenuItem(title: L10n.string("Keep on Top"), isSelected: presenter?.keepsOnTop == true,
                isEnabled: presenter != nil,
                onChoose: { [weak self] in self?.presenter?.keepsOnTop.toggle() })),
        ]
    }

    private func presentMenu(_ entries: [ThemedMenuEntry], from source: NSView, anchor: ThemedMenuAnchor) -> Bool {
        ThemedMenuPresenter.dismiss(menuSession)
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: Timing.menuWidth), from: source, anchor: anchor,
            selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil })
        return menuSession != nil
    }

    func showRecordingPresentationForTesting(elapsedSeconds: Int?) {
        recordingState = elapsedSeconds == nil ? .idle : .recording
        recordingStartedAt = elapsedSeconds.map { Date().addingTimeInterval(-TimeInterval($0)) }
        renderState()
    }

    var recordingHasFinishedForTesting: Bool { recordingState == .idle }
    var recordingHasStartedForTesting: Bool { recordingState == .recording }
    var captureButtonForTesting: ThemedIconButton { captureButton }
    var recordButtonForTesting: ThemedIconButton { recordButton }
    var touchesButtonForTesting: ThemedIconButton { touchesButton }
    var presenterButtonForTesting: ThemedIconButton { presenterButton }
    var recordingBadgeForTesting: SimulatorRecordingBadge { recordingBadge }

    var frameImageForTesting: NSImage? { screenView.image }
    var isPresentedForTesting: Bool { isPresented }
    var statusForTesting: String { statusLabel.stringValue }
    var controlSupportForTesting: PhysicalDeviceControlSupport? {
        guard case .resolved(let support) = controlSupportState else { return nil }
        return support
    }
    var emptyLabelForTesting: NSTextField { emptyLabel }
    var toolingButtonForTesting: ThemedButton { toolingButton }
    var logsButtonForTesting: ThemedIconButton { logsButton }
    var controlButtonForTesting: ThemedIconButton { controlButton }
    var screenViewForTesting: SimulatorScreenView { screenView }
    var screenInteractionStateForTesting: SimulatorScreenView.InteractionState {
        screenView.interactionState
    }
    func retryForTesting() { retry() }
}
