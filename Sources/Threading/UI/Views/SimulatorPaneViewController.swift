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

    private lazy var controlRow = ControlRowView(
        leading: [deviceChip],
        trailing: [controlButton, retryButton]
    )

    private lazy var screenView: SimulatorScreenView = {
        let preview = SimulatorScreenView()
        preview.setAccessibilityLabel(L10n.string("Simulator screen"))
        preview.setAccessibilityIdentifier("simulator.screen")
        preview.onTap = { [weak self] point in
            self?.submitInput(.tap(x: Double(point.x), y: Double(point.y)))
        }
        preview.onDrag = { [weak self] from, to, duration in
            self?.submitInput(.drag(
                fromX: Double(from.x),
                fromY: Double(from.y),
                toX: Double(to.x),
                toY: Double(to.y),
                durationMilliseconds: duration
            ))
        }
        preview.onText = { [weak self] text in self?.submitInput(.text(text)) }
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
        let root = NSView()
        root.setAccessibilityIdentifier("simulator.pane")
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
            if lease != nil {
                if let device = lease?.device { presentationState = .ready(device) }
                startFrameLoop()
            } else if preparationTask == nil {
                prepare(preferredDeviceID)
            }
        } else {
            stopFrameLoop()
        }
    }

    /// Explicit tab/session teardown. A user-owned boot stays running; a Threading-owned boot is
    /// handed back through the lease capability without retaining this controller.
    func terminate() {
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
    }

    private func submitInput(_ input: SimulatorBridgeInput) {
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
        case .direct:
            guard let capabilities = liveCapabilities,
                  capabilities.supportsTouch || capabilities.supportsKeyboard else {
                return L10n.string("View only")
            }
            return effectiveControlDecision == true
                ? L10n.string("Control ready")
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
            let backend: String
            switch liveBackend {
            case .direct(.h264): backend = L10n.string("Live H.264")
            case .direct(.jpeg): backend = L10n.string("Live JPEG")
            case .screenshotFallback: backend = L10n.string("Preview fallback")
            case nil: backend = L10n.string("Connecting live preview…")
            }
            var status = [device.name, device.runtimeName, backend]
            if let control = controlStatus() { status.append(control) }
            statusLabel.stringValue = status.joined(separator: " · ")
            if case .screenshotFallback = liveBackend {
                statusLabel.textColor = Design.Status.warning
            } else {
                statusLabel.textColor = Design.Status.positive
            }
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
        if let lastStreamFailure,
           !lastStreamFailure.isEmpty,
           lastStreamFailure != statusLabel.stringValue {
            statusLabel.toolTip = statusLabel.stringValue + "\n" + lastStreamFailure
        } else {
            statusLabel.toolTip = statusLabel.stringValue
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
