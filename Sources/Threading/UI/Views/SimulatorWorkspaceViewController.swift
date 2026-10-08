import AppKit

/// One session's Simulator tab: one to four exact-device members, a shared header and hardware
/// controls that act on the selected member, and a canvas that arranges the members.
///
/// The header is one row, the same height as the single pane's: the device chooser, Add, the
/// layout chooser (only once there is something to arrange), then the selected member's own
/// capture, recording, Device Logs and options. A lone member therefore looks like the pane always
/// did, with one extra +.
@MainActor
final class SimulatorWorkspaceViewController: NSViewController {
    private static let deviceMenuWidth: CGFloat = 260
    /// Below this header width the device chooser, Add, the layout chooser and four actions no
    /// longer fit without truncating two labels to a letter each (measured at the protected 260pt
    /// pane), so the layout chooser moves into the options menu, where it is always offered too.
    private static let compactHeaderWidth: CGFloat = 340

    enum Failure: LocalizedError {
        case full
        var errorDescription: String? { L10n.string("This workspace already has four Simulators. Remove one before adding another.") }
    }

    private(set) var state: SimulatorWorkspaceState
    private var controllers: [UUID: SimulatorPaneViewController] = [:]
    private let factory: (SimulatorDeviceID?) -> SimulatorPaneViewController
    private var presented = false
    private var visibleMembers: Set<UUID> = []
    var onChange: (() -> Void)?
    private let canvas = SimulatorWorkspaceCanvas()
    private let hardwareHost = NSView()
    private var hardwareHeight: NSLayoutConstraint?
    private let events = AppEventObservations()
    private var menuSession: AnyObject?
    private var headerIsCompact = false

    /// Installed devices that are not members yet, from the selected member's catalogue.
    private var addableDevices: [SimulatorDevice] {
        let members = Set(state.members.compactMap(\.deviceID))
        return selectedSimulator.availableWorkspaceDevices.filter { !members.contains($0.id) }
    }

    var canAddSimulator: Bool {
        state.members.count < SimulatorWorkspaceState.maximumMembers && !addableDevices.isEmpty
    }

    var selectedSimulator: SimulatorPaneViewController {
        guard let controller = controllers[state.selectedID] else {
            preconditionFailure("A workspace selection must name a retained member.")
        }
        return controller
    }
    private var keyboardSimulator: SimulatorPaneViewController {
        simulators.first { controller in
            controller.isViewLoaded && (controller.view as? KeyEquivalentScopeView)?.containsKeyboardFocus == true
        } ?? selectedSimulator
    }

    var simulators: [SimulatorPaneViewController] { state.members.compactMap { controllers[$0.id] } }

    /// Names the selected member's device. Alone, it switches that device, as the single pane's
    /// chooser always did; beside peers, it chooses which member the header acts on.
    private lazy var deviceChip: ChipView = {
        let chip = ChipView()
        chip.setAccessibilityIdentifier("simulator.device")
        chip.itemsProvider = { [weak self] in self?.deviceEntries() ?? [] }
        chip.onSelect = { [weak self] item in self?.chooseDevice(item.representedValue) }
        // The device's name also heads its tile, so this is the label that gives up width first.
        chip.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        return chip
    }()
    private lazy var layoutChip: ChipView = {
        let chip = ChipView()
        chip.setAccessibilityIdentifier("simulator.workspace.layout")
        chip.itemsProvider = { [weak self] in
            SimulatorWorkspaceLayout.allCases.map { layout in
                .item(ThemedMenuItem(title: layout.displayTitle, representedValue: layout.rawValue,
                                     isSelected: self?.state.layout == layout))
            }
        }
        chip.onSelect = { [weak self] item in
            guard let value = item.representedValue as? String,
                  let layout = SimulatorWorkspaceLayout(rawValue: value) else { return }
            self?.setLayout(layout)
        }
        chip.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return chip
    }()
    private lazy var addButton: ThemedIconButton = {
        let button = ThemedIconButton(symbolName: "plus", accessibility: L10n.string("Add Simulator"),
                                      target: .inline, inkSource: .chrome)
        button.presentsMenu = true
        button.setAccessibilityIdentifier("simulator.workspace.add")
        button.onPress = { [weak self] in self?.showAddMenu() }
        return button
    }()
    private let headerRow = ControlRowView()

    init(state: SimulatorWorkspaceState, factory: @escaping (SimulatorDeviceID?) -> SimulatorPaneViewController) {
        self.state = state
        self.factory = factory
        super.init(nibName: nil, bundle: nil)
        for member in state.members { makeMember(member) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = KeyEquivalentScopeView()
        root.onKeyEquivalent = { [weak self] event in self?.keyboardSimulator.performSimulatorShortcut(event) ?? false }
        root.setAccessibilityIdentifier("simulator.workspace")
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [headerRow, canvas, hardwareHost] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        hardwareHeight = hardwareHost.heightAnchor.constraint(equalToConstant: ThemedIconButton.Target.device.size.height)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.medium),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.inset),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.inset),
            hardwareHeight!,
            canvas.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Design.Spacing.medium),
            canvas.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: hardwareHost.topAnchor, constant: -Design.Spacing.medium),
            hardwareHost.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            hardwareHost.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            hardwareHost.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Design.Spacing.medium),
        ])
        canvas.holdsGesture = { [weak self] in self?.simulators.contains(where: \.hasActiveWorkspaceGesture) ?? false }
        canvas.onVisibleMembers = { [weak self] ids in
            guard let self, ids != self.visibleMembers else { return }
            self.visibleMembers = ids
            self.updatePresentation()
        }
        events.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self else { return }
            if let group = self.selectedSimulator.workspaceHardwareControls as? SimulatorHardwareControlsView {
                self.hardwareHeight?.constant = group.preferredHeight(for: self.hardwareHost.bounds.width)
            }
            self.simulators.forEach { $0.refreshWorkspaceMetrics() }
            self.canvas.tileChromeHeight = self.selectedSimulator.workspaceChromeHeight
            self.canvas.needsLayout = true
        }
        rebuildMembership()
        refreshSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let compact = view.bounds.width - 2 * Design.Spacing.inset < Self.compactHeaderWidth
        guard compact != headerIsCompact else { return }
        headerIsCompact = compact
        refreshHeader()
    }

    // MARK: - Membership

    @discardableResult
    func adopt(_ deviceID: SimulatorDeviceID?) throws -> SimulatorPaneViewController {
        guard let deviceID else { return selectedSimulator }
        if let member = state.members.first(where: { $0.deviceID == deviceID }) {
            select(member.id)
            return controllers[member.id]!
        }
        if state.members.count == 1, state.members[0].deviceID == nil {
            state.members[0].deviceID = deviceID
            selectedSimulator.selectDevice(deviceID)
            if isViewLoaded { refreshHeader() }
            onChange?()
            return selectedSimulator
        }
        guard state.members.count < SimulatorWorkspaceState.maximumMembers else { throw Failure.full }
        let member = SimulatorWorkspaceState.Member(id: UUID(), deviceID: deviceID)
        state.members.append(member)
        makeMember(member)
        state.selectedID = member.id
        if isViewLoaded { rebuildMembership(); refreshSelection(); updatePresentation() }
        onChange?()
        return controllers[member.id]!
    }

    func select(_ id: UUID) {
        guard controllers[id] != nil, state.selectedID != id else { return }
        state.selectedID = id
        if isViewLoaded { refreshSelection(); canvas.layoutSubtreeIfNeeded(); updatePresentation() }
        onChange?()
    }

    func setLayout(_ layout: SimulatorWorkspaceLayout) {
        guard state.layout != layout else { return }
        state.layout = layout
        if isViewLoaded { refreshSelection(); canvas.layoutSubtreeIfNeeded() }
        onChange?()
    }

    func removeSelected() { remove(state.selectedID) }

    /// Releases only that member's lease. The neighbour that took its place becomes selected, so
    /// the header keeps acting on a device beside the one that left rather than jumping to the
    /// first.
    func remove(_ id: UUID) {
        guard state.members.count > 1, let index = state.members.firstIndex(where: { $0.id == id }) else { return }
        state.members.remove(at: index)
        if state.selectedID == id {
            state.selectedID = state.members[min(index, state.members.count - 1)].id
        }
        let controller = controllers.removeValue(forKey: id)
        controller?.terminate()
        controller?.view.removeFromSuperview()
        controller?.removeFromParent()
        if isViewLoaded { rebuildMembership(); refreshSelection(); updatePresentation() }
        onChange?()
    }

    func setPresented(_ value: Bool) {
        presented = value
        if value { _ = view; canvas.layoutSubtreeIfNeeded() }
        updatePresentation()
    }

    func terminate() {
        presented = false
        for controller in simulators { controller.terminate() }
    }

    func showAddMenu() {
        let entries = addableDevices.map { device in
            ThemedMenuEntry.item(ThemedMenuItem(
                title: device.name, subtitle: device.runtimeName,
                isEnabled: state.members.count < SimulatorWorkspaceState.maximumMembers,
                onChoose: { [weak self] in _ = try? self?.adopt(device.id) }
            ))
        }
        guard !entries.isEmpty else { return }
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: Self.deviceMenuWidth),
            from: addButton, selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    var canvasForTesting: SimulatorWorkspaceCanvas { canvas }
    var headerForTesting: ControlRowView { headerRow }

    // MARK: - Private

    private func makeMember(_ member: SimulatorWorkspaceState.Member) {
        let controller = factory(member.deviceID)
        controllers[member.id] = controller
        addChild(controller)
        controller.onFocusRequest = { [weak self] in self?.select(member.id) }
        controller.onGestureEnd = { [weak self] in self?.canvas.needsLayout = true }
        controller.onFrameAspectChange = { [weak self] aspect in self?.canvas.updateAspect(aspect, for: member.id) }
        controller.onWorkspaceIdentityChange = { [weak self] in
            guard let self, self.isViewLoaded, self.state.selectedID == member.id else { return }
            self.refreshHeader()
        }
        controller.workspaceMenuExtras = { [weak self, weak controller] in
            guard let self, let controller, self.state.members.count > 1 else { return [] }
            let layouts: [ThemedMenuEntry] = SimulatorWorkspaceLayout.allCases.map { layout in
                .item(ThemedMenuItem(title: layout.displayTitle, isSelected: self.state.layout == layout,
                                     onChoose: { [weak self] in self?.setLayout(layout) }))
            }
            return [
                .item(ThemedMenuItem(title: L10n.string("Layout"), submenu: layouts)),
                .item(ThemedMenuItem(
                    title: L10n.format("Remove %@ from Workspace", controller.workspaceDeviceName),
                    onChoose: { [weak self] in self?.remove(member.id) }
                )),
            ]
        }
        controller.onSelectedDeviceChange = { [weak self] device in
            guard let self, let index = self.state.members.firstIndex(where: { $0.id == member.id }) else { return }
            self.state.members[index].deviceID = device
            if self.isViewLoaded { self.refreshHeader() }
            self.onChange?()
        }
    }

    private func rebuildMembership() {
        let tiles = state.members.map { member in
            let controller = controllers[member.id]!
            let size = controller.workspaceFrameSize
            let aspect = size.flatMap { $0.height > 0 ? $0.width / $0.height : nil }
                ?? SimulatorWorkspaceGeometry.defaultPortraitAspect
            return SimulatorWorkspaceCanvas.Tile(id: member.id, content: controller.view, aspect: aspect)
        }
        canvas.setTiles(tiles)
    }

    private func refreshSelection() {
        let selected = selectedSimulator
        let solo = state.members.count == 1
        for member in state.members {
            controllers[member.id]?.workspaceRole = solo ? .solo : member.id == state.selectedID ? .selected : .unselected
        }
        let hardware = selected.workspaceHardwareControls
        if let group = hardware as? SimulatorHardwareControlsView {
            group.onHeightChange = { [weak self, weak group] height in
                guard let self, let group, self.selectedSimulator.workspaceHardwareControls === group else { return }
                self.hardwareHeight?.constant = height
            }
            hardwareHeight?.constant = group.preferredHeight(for: hardwareHost.bounds.width)
        }
        install(hardware, in: hardwareHost)
        canvas.selectedID = state.selectedID
        canvas.arrangement = state.layout
        canvas.tileChromeHeight = selected.workspaceChromeHeight
        refreshHeader()
    }

    /// The header follows the selected member: its device, its own actions, and the layout
    /// chooser once there is more than one device to arrange.
    private func refreshHeader() {
        let selected = selectedSimulator
        deviceChip.configure(symbolName: "iphone", title: selected.workspaceDeviceName)
        deviceChip.isEnabled = !selected.availableWorkspaceDevices.isEmpty || state.members.count > 1
        layoutChip.configure(symbolName: state.layout.symbolName, title: state.layout.displayTitle)
        addButton.isEnabled = canAddSimulator
        addButton.toolTip = state.members.count >= SimulatorWorkspaceState.maximumMembers
            ? L10n.string("This workspace already has four Simulators. Remove one before adding another.")
            : L10n.string("Add Simulator")
        // Nothing to arrange with one device, so the chooser leaves the row rather than idling in it;
        // a narrow pane keeps it in the options menu instead.
        let showsLayout = state.members.count > 1 && !headerIsCompact
        let leading: [NSView] = showsLayout ? [deviceChip, addButton, layoutChip] : [deviceChip, addButton]
        let trailing = [selected.workspaceActions]
        if !headerRow.leadingViews.elementsEqual(leading, by: ===)
            || !headerRow.trailingViews.elementsEqual(trailing, by: ===) {
            headerRow.configure(leading: leading, trailing: trailing)
        }
    }

    private func deviceEntries() -> [ThemedMenuEntry] {
        guard state.members.count > 1 else {
            let selected = selectedSimulator
            return selected.availableWorkspaceDevices.map { device in
                .item(ThemedMenuItem(title: device.name, subtitle: device.runtimeName,
                                     representedValue: device.id.rawValue,
                                     isSelected: device.id == selected.selectedDeviceID))
            }
        }
        return state.members.map { member in
            let controller = controllers[member.id]
            return .item(ThemedMenuItem(
                title: controller?.workspaceDeviceName ?? L10n.string("Choose Simulator"),
                subtitle: controller?.adoptedDevice?.runtimeName,
                representedValue: member.id.uuidString,
                isSelected: member.id == state.selectedID
            ))
        }
    }

    private func chooseDevice(_ value: Any?) {
        guard let raw = value as? String else { return }
        if state.members.count > 1 {
            if let id = UUID(uuidString: raw) { select(id) }
            return
        }
        // Alone, the chooser switches the device, exactly like the single pane: + adds one.
        guard let device = SimulatorDeviceID(raw), state.members[0].deviceID != device else { return }
        state.members[0].deviceID = device
        selectedSimulator.selectDevice(device)
        refreshHeader()
        onChange?()
    }

    private func install(_ child: NSView, in host: NSView) {
        guard child.superview !== host else { return }
        for previous in host.subviews { previous.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: host.topAnchor),
            child.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    private func updatePresentation() {
        if presented, !visibleMembers.isEmpty, simulators.contains(where: \.hasActiveWorkspaceGesture) { return }
        let visible = visibleMembers
        for member in state.members {
            guard let controller = controllers[member.id] else { continue }
            controller.setPresented(presented && visible.contains(member.id))
            if !presented || !visible.contains(member.id) { controller.relinquishUnwatchedTransport() }
        }
    }
}
