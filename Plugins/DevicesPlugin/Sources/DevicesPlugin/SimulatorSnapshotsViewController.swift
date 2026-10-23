import AppKit
import ImageIO
import ThreadingDesignKit
import ThreadingPluginKit

/// A read-only Simulator pane built entirely through the public native-plugin contract. The
/// host owns CoreSimulator access; this bundle owns the chooser, snapshot and refresh behavior.
@MainActor
final class SimulatorSnapshotsViewController: NSViewController {
    private struct DecodedFrame: @unchecked Sendable {
        let image: CGImage
    }

    private let service: (any PluginSimulatorServices)?
    private let hostOwnsVisibility: Bool
    private var isPresented = false
    private var preferredDeviceID: String?
    private var inventory = PluginSimulatorInventory(devices: [], omittedCount: 0)
    private var requestGeneration = 0
    private var requestTask: Task<Void, Never>?
    private let bitmap = ThemedBitmapView(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var deviceChip: ChipView = {
        let chip = ChipView()
        chip.configure(symbolName: "iphone", title: L10n.string("Choose Simulator"))
        chip.itemsProvider = { [weak self] in
            self?.inventory.devices.map { device in
                .item(ThemedMenuItem(
                    title: "\(device.name) · \(device.runtimeName)", representedValue: device.id,
                    isSelected: device.id == self?.preferredDeviceID
                ))
            } ?? []
        }
        chip.onSelect = { [weak self] item in
            guard let id = item.representedValue as? String else { return }
            self?.selectDevice(id)
        }
        chip.setAccessibilityIdentifier("devices.snapshots.device")
        return chip
    }()
    private lazy var discoverButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "arrow.clockwise", accessibility: L10n.string("Refresh Simulators"),
            target: .inline, inkSource: .chrome
        )
        button.toolTip = L10n.string("Refresh Simulators")
        button.onPress = { [weak self] in self?.refreshInventory() }
        return button
    }()
    private lazy var captureButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "camera", accessibility: L10n.string("Capture Screenshot"),
            target: .inline, inkSource: .chrome
        )
        button.toolTip = L10n.string("Capture Screenshot")
        button.onPress = { [weak self] in self?.capture() }
        return button
    }()

    init(
        service: (any PluginSimulatorServices)?,
        preferredDeviceID: String?,
        hostOwnsVisibility: Bool
    ) {
        self.service = service
        self.preferredDeviceID = preferredDeviceID
        self.hostOwnsVisibility = hostOwnsVisibility
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let header = PaneHeaderView(leading: [deviceChip], trailing: [discoverButton, captureButton])
        bitmap.imageDescription = L10n.string("iOS Simulator screenshot")
        bitmap.setAccessibilityIdentifier("devices.snapshots.image")
        status.applyFont(.detail())
        status.textColor = Design.Text.secondary
        status.stringValue = L10n.string("Choose a running iOS Simulator to capture its screen.")
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(bitmap)
        view.addSubview(status)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bitmap.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.medium),
            bitmap.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.inset),
            bitmap.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.inset),
            bitmap.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -Design.Spacing.medium),
            status.leadingAnchor.constraint(equalTo: bitmap.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: bitmap.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.medium),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !hostOwnsVisibility { setPresented(true) }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if !hostOwnsVisibility { setPresented(false) }
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        if presented { refreshInventory() }
        else { cancelRequest() }
    }

    func selectDevice(_ id: String) {
        preferredDeviceID = id
        bitmap.image = nil
        updateSelection()
        if isPresented {
            if inventory.devices.contains(where: { $0.id == id }) { capture() }
            else if !inventory.devices.isEmpty {
                status.stringValue = L10n.string("Selected device is not a running iOS Simulator. Choose another.")
            }
        }
    }

    func repaint() { AppThemeRefresh.repaint(view) }

    private func refreshInventory() {
        guard let service else {
            status.stringValue = L10n.string("Simulator snapshots need a newer Threading host.")
            return
        }
        cancelRequest()
        let generation = requestGeneration
        status.stringValue = L10n.string("Finding running iOS Simulators…")
        requestTask = Task { [weak self] in
            do {
                let inventory = try await service.runningDevices()
                guard let self, generation == self.requestGeneration else { return }
                self.inventory = inventory
                if let preferredDeviceID,
                   !inventory.devices.contains(where: { $0.id == preferredDeviceID }) {
                    self.preferredDeviceID = nil
                    self.bitmap.image = nil
                    self.updateSelection()
                    self.status.stringValue = L10n.string(
                        "Selected device is not a running iOS Simulator. Choose another."
                    )
                    return
                }
                if self.preferredDeviceID == nil {
                    self.preferredDeviceID = inventory.devices.first?.id
                    self.bitmap.image = nil
                }
                self.updateSelection()
                if self.preferredDeviceID != nil { self.capture() }
                else { self.status.stringValue = L10n.string("No iOS Simulator is running. Start one in Xcode and refresh.") }
            } catch {
                guard let self, generation == self.requestGeneration else { return }
                self.status.stringValue = L10n.format("Couldn’t list Simulators: %@", error.localizedDescription)
            }
        }
    }

    private func capture() {
        guard let service, let deviceID = preferredDeviceID,
              inventory.devices.contains(where: { $0.id == deviceID }) else { return }
        cancelRequest()
        let generation = requestGeneration
        status.stringValue = L10n.string("Capturing screenshot…")
        requestTask = Task { [weak self] in
            do {
                let data = try await service.screenshot(of: deviceID)
                let frame = await Task.detached(priority: .userInitiated) { () -> DecodedFrame? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                    return DecodedFrame(image: image)
                }.value
                guard let self, generation == self.requestGeneration else { return }
                guard let frame else {
                    self.status.stringValue = L10n.string("CoreSimulator returned an unreadable screenshot.")
                    return
                }
                self.bitmap.image = NSImage(
                    cgImage: frame.image,
                    size: NSSize(width: frame.image.width, height: frame.image.height)
                )
                self.status.stringValue = L10n.format("Screenshot from %@.", self.selectedDeviceName)
            } catch {
                guard let self, generation == self.requestGeneration else { return }
                self.status.stringValue = L10n.format("Couldn’t capture screenshot: %@", error.localizedDescription)
            }
        }
    }

    private var selectedDeviceName: String {
        inventory.devices.first(where: { $0.id == preferredDeviceID })?.name ?? "Simulator"
    }

    private func updateSelection() {
        if let device = inventory.devices.first(where: { $0.id == preferredDeviceID }) {
            deviceChip.configure(symbolName: "iphone", title: device.name)
        } else {
            deviceChip.configure(symbolName: "iphone", title: L10n.string("Choose Simulator"))
        }
        captureButton.isEnabled = inventory.devices.contains { $0.id == preferredDeviceID }
        if inventory.omittedCount > 0 {
            deviceChip.toolTip = L10n.format("%lld more running Simulators were omitted.", inventory.omittedCount)
        }
    }

    private func cancelRequest() {
        requestGeneration &+= 1
        requestTask?.cancel()
        requestTask = nil
    }
}
