import AppKit

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
/// The first renderer deliberately uses bounded `simctl` screenshots. It is the public fallback
/// behind the same controller the direct framebuffer helper will feed: replacing the frame source
/// must not create another tab kind, device lease or agent-visible identity.
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

    private let control: any SimulatorControlling
    private var preferredDeviceID: SimulatorDeviceID?
    private var devices: [SimulatorDevice] = []
    private var lease: SimulatorDeviceLease?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var preparationCompletions: [
        @MainActor @Sendable (SimulatorPaneAgentResult<SimulatorDeviceLease>) -> Void
    ] = []
    private var frameTask: Task<Void, Never>?
    private var frameGeneration = 0
    private var agentCommandTasks: [UUID: Task<Void, Never>] = [:]
    private var isPresented = false

    private(set) var presentationState: PresentationState = .idle {
        didSet { renderState() }
    }

    var selectedDeviceID: SimulatorDeviceID? {
        lease?.device.id ?? preferredDeviceID
    }

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

    private lazy var controlRow = ControlRowView(
        leading: [deviceChip],
        trailing: [retryButton]
    )

    private lazy var screenView: ThemedImagePreview = {
        let preview = ThemedImagePreview()
        preview.allowsUpscaling = true
        preview.setAccessibilityLabel(L10n.string("Simulator screen"))
        preview.setAccessibilityIdentifier("simulator.screen")
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
        control: any SimulatorControlling
    ) {
        self.preferredDeviceID = preferredDeviceID
        self.control = control
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
        stopFrameLoop()
        let releasedLease = lease
        lease = nil
        guard let releasedLease else { return }
        let control = control
        Task { try? await control.release(releasedLease) }
    }

    func selectDevice(_ id: SimulatorDeviceID) {
        guard id != selectedDeviceID else { return }
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
            do {
                let receipt = try await control.installAndLaunch(
                    applicationURL: applicationURL,
                    bundleIdentifier: bundleIdentifier,
                    on: deviceID,
                    arguments: arguments
                )
                try Task.checkCancellation()
                guard self?.lease?.device.id == deviceID else {
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
            do {
                let data = try await control.screenshot(of: device.id)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else {
                    throw SimulatorControlError.invalidScreenshot
                }
                guard self?.lease?.device.id == device.id else {
                    completion(.failure("The selected Simulator changed during capture."))
                    return
                }
                self?.screenView.image = image
                completion(.success(SimulatorPaneScreenshot(data: data, device: device)))
            } catch is CancellationError {
                completion(.failure("The Simulator capture was cancelled."))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private func retry() {
        if let lease {
            presentationState = .ready(lease.device)
            startFrameLoop()
        } else {
            prepare(preferredDeviceID)
        }
    }

    private func prepare(
        _ requestedID: SimulatorDeviceID?,
        releasingCurrentLease: Bool = false
    ) {
        preparationTask?.cancel()
        stopFrameLoop()
        presentationState = .discovering
        let control = control
        let currentLease = releasingCurrentLease ? lease : nil
        if releasingCurrentLease { lease = nil }
        preparationGeneration += 1
        let generation = preparationGeneration

        preparationTask = Task { [weak self] in
            defer {
                if self?.preparationGeneration == generation {
                    self?.preparationTask = nil
                }
            }
            do {
                if let currentLease { try await control.release(currentLease) }
                try Task.checkCancellation()
                let devices = try await control.availableDevices()
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

                let preparedLease = try await control.prepare(deviceID: targetID)
                guard !Task.isCancelled, let self else {
                    try? await control.release(preparedLease)
                    return
                }
                self.lease = preparedLease
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
        guard isPresented, let deviceID = lease?.device.id, frameTask == nil else { return }
        let control = control
        frameGeneration += 1
        let generation = frameGeneration
        frameTask = Task { [weak self] in
            defer {
                if self?.frameGeneration == generation {
                    self?.frameTask = nil
                }
            }
            while !Task.isCancelled {
                do {
                    let data = try await control.screenshot(of: deviceID)
                    try Task.checkCancellation()
                    guard let image = NSImage(data: data) else {
                        throw SimulatorControlError.invalidScreenshot
                    }
                    self?.screenView.image = image
                    if let device = self?.lease?.device {
                        self?.presentationState = .ready(device)
                    }
                    try await Task.sleep(nanoseconds: Timing.fallbackFrameInterval)
                } catch is CancellationError {
                    return
                } catch let error as SimulatorControlError where error == .cancelled {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.presentationState = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func stopFrameLoop() {
        frameTask?.cancel()
        frameTask = nil
        frameGeneration += 1
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
            statusLabel.stringValue = L10n.format(
                "%@ · %@ · Preview",
                device.name,
                device.runtimeName
            )
            statusLabel.textColor = Design.Status.positive
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
        statusLabel.toolTip = statusLabel.stringValue
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
    var isPresentedForTesting: Bool { isPresented }
}
