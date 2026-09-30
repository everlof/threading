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
        /// `idevicescreenshot` is a process fallback, not the eventual media stream. One frame per
        /// second is enough to prove the pane and keep device activity visible without pretending
        /// this is a low-latency backend.
        static let fallbackFrameInterval: Duration = .seconds(1)
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
            accessibility: L10n.string("Retry iPhone Preview"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Retry iPhone Preview")
        button.onPress = { [weak self] in self?.restartCapture() }
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
        button.toolTip = L10n.string("Open Device Logs in Bottom Pane")
        button.onPress = { [weak self] in
            guard let self, let deviceID = self.selectedDeviceID else { return }
            self.onOpenDeviceLogs?(deviceID)
        }
        button.setAccessibilityIdentifier("realDevice.logs")
        return button
    }()

    private lazy var controlButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "hand.tap",
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
        trailing: [logsButton, controlButton, captureButton, retryButton]
    )

    private lazy var screenView: SimulatorScreenView = {
        let screen = SimulatorScreenView()
        screen.interactionState = .unavailable
        screen.setAccessibilityLabel(L10n.string("iPhone screen"))
        screen.setAccessibilityIdentifier("realDevice.screen")
        screen.onTap = { [weak self] point in
            self?.submitInput(.tap(x: Double(point.x), y: Double(point.y)))
        }
        screen.onTouchBegan = { [weak self] point in self?.dragOrigin = point }
        screen.onTouchMoved = { _ in }
        screen.onTouchEnded = { [weak self] point in
            guard let self, let origin = self.dragOrigin else { return }
            self.dragOrigin = nil
            self.submitInput(.drag(
                fromX: Double(origin.x),
                fromY: Double(origin.y),
                toX: Double(point.x),
                toY: Double(point.y)
            ))
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
        control: any PhysicalDeviceControlling = DevicectlPhysicalDeviceControl(),
        inputAuthorizer: any PhysicalDeviceInputAuthorizing =
            PhysicalDeviceInputConsentController(),
        notificationCenter: NotificationCenter = .default
    ) {
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
        renderState()
    }

    private func setupUI() {
        view.addSubview(controlRow)
        view.addSubview(screenView)
        view.addSubview(emptyContent)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
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
                startCaptureLoop(for: selectedDevice)
            } else {
                discover(preferredDeviceID)
            }
        } else {
            revokeControl()
            stopDiscovery()
            stopControlSupportProbe()
            stopCapture()
        }
        renderState()
    }

    func terminate() {
        isPresented = false
        revokeControl()
        stopDiscovery()
        stopControlSupportProbe()
        stopCapture()
    }

    func selectDevice(_ id: PhysicalDeviceID) {
        guard id != selectedDeviceID else { return }
        revokeControl()
        preferredDeviceID = id
        selectedDevice = nil
        screenView.image = nil
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
        screenView.image = nil
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

    private func restartCapture() {
        guard let selectedDevice else { return }
        startCaptureLoop(for: selectedDevice)
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
        guard inputTask == nil,
              isPresented,
              let device = selectedDevice,
              inputAuthorizer.decision(for: device.id) == true,
              case .resolved(.available) = controlSupportState else { return }

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
                try await control.sendInput(input, to: device)
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
                self.inputFailure = error.localizedDescription
                self.renderState()
            }
        }
    }

    private func stopInput() {
        inputGeneration += 1
        inputTask?.cancel()
        inputTask = nil
        dragOrigin = nil
    }

    private func startCaptureLoop(for device: PhysicalDevice) {
        guard isPresented else { return }
        stopCapture()
        captureGeneration += 1
        let generation = captureGeneration
        let control = control
        captureState = .capturing
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await control.screenshot(of: device)
                    try Task.checkCancellation()
                    guard let cgImage = await Self.decodedCGImage(from: data) else {
                        throw PhysicalDeviceControlError.invalidScreenshot
                    }
                    guard let self,
                          self.isPresented,
                          self.captureGeneration == generation,
                          self.selectedDevice?.id == device.id else { return }
                    self.screenView.image = NSImage(cgImage: cgImage, size: .zero)
                    self.captureState = .live
                    try await Task.sleep(for: Timing.fallbackFrameInterval)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.captureGeneration == generation else { return }
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
        if captureState == .capturing { captureState = .idle }
    }

    /// Full-resolution phone PNG decoding is worker work. Only the immutable Core Graphics image
    /// crosses back to the main actor; AppKit wraps it after the bounded decode has completed.
    private nonisolated static func decodedCGImage(from data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
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
        captureButton.isEnabled = isPresented && selectedDevice != nil && captureState != .capturing
        configureControlButton()
        configureScreenInteraction()
        statusLabel.toolTip = statusLabel.stringValue
    }

    private func configureControlButton() {
        let decision = selectedDeviceID.flatMap { inputAuthorizer.decision(for: $0) }
        if needsToolingSetup {
            controlButton.setSymbol("hand.tap", accessibility: toolingActionTitle)
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
            decision == false ? "hand.raised.slash" : "hand.tap",
            accessibility: title
        )
        controlButton.toolTip = title
        controlButton.isSelected = decision == true
        controlButton.isEnabled = isPresented && enabled
    }

    private func configureScreenInteraction() {
        guard let deviceID = selectedDeviceID,
              inputAuthorizer.decision(for: deviceID) == true,
              case .resolved(.available) = controlSupportState else {
            screenView.interactionState = .unavailable
            return
        }
        screenView.interactionState = .ready(touch: true, keyboard: false)
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
                detail = L10n.string("Control ready")
            } else if let deviceID = selectedDeviceID,
                      inputAuthorizer.decision(for: deviceID) == false {
                detail = L10n.string("Control denied")
            } else {
                detail = L10n.string("Click to enable control")
            }
        }
        let isControlReady = selectedDeviceID.map {
            inputAuthorizer.decision(for: $0) == true
        } ?? false
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
