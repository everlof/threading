import AppKit

/// One session's Simulator tab: one to four exact-device members, a shared header and hardware
/// controls that act on the selected member, and a canvas that arranges the members.
///
/// The header is one row, the same height as the single pane's: the device chooser, Add, the
/// layout chooser (only once there is something to arrange), then the selected member's own
/// capture, recording and Device Logs. Each titled device has its own options menu; the shared
/// menu carries touch settings and, when the header is narrow, Layout.
@MainActor
final class SimulatorWorkspaceViewController: NSViewController {
    private static let deviceMenuWidth: CGFloat = 260
    /// Below this header width the device chooser, Add, the layout chooser and four actions no
    /// longer fit without truncating two labels to a letter each (measured at the protected 260pt
    /// pane), so the layout chooser moves into the shared options menu.
    private static let compactHeaderWidth: CGFloat = 340

    enum Failure: LocalizedError, Equatable {
        case full
        case noOtherDevice(android: Bool)
        var errorDescription: String? {
            switch self {
            case .full:
                L10n.string("This workspace already has four devices. Remove one before adding another.")
            case .noOtherDevice(android: true):
                L10n.string("No other Android emulator or USB Android device is available to add.")
            case .noOtherDevice(android: false):
                L10n.string("No other iOS Simulator is available to add.")
            }
        }
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
    /// The checkout's scenarios and the one on show. See `SimulatorScenarioController`.
    let scenarios: SimulatorScenarioController
    private let scenarioCheckout: @MainActor () -> URL?
    /// Says which step is on show, with Back, Next and Play, between the header and the devices.
    private var scenarioBand: PaneNoticeView?
    /// A refusal from the scenario menu, shown in the band until dismissed.
    private var scenarioNotice: String?
    private var scenarioHelpPopover: ThemedPopover?
    private lazy var canvasTop = canvas.topAnchor.constraint(
        equalTo: headerRow.bottomAnchor, constant: Design.Spacing.medium
    )

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
        let button = ThemedIconButton(symbolName: "plus", accessibility: L10n.string("Add Device"),
                                      target: .inline, inkSource: .chrome)
        button.presentsMenu = true
        button.setAccessibilityIdentifier("simulator.workspace.add")
        button.onPress = { [weak self] in self?.showAddMenu() }
        return button
    }()
    /// The checkout's scenarios: a menu of states the app's debug build can open, or the setup
    /// help when the checkout has none yet.
    private lazy var scenarioButton: ThemedIconButton = {
        let button = ThemedIconButton(symbolName: SimulatorPaneSymbols.scenarios,
                                      accessibility: L10n.string("Scenarios"),
                                      target: .inline, inkSource: .chrome)
        button.presentsMenu = true
        button.toolTip = L10n.string("Open the app in a state from this project's scenarios")
        button.setAccessibilityIdentifier("simulator.workspace.scenarios")
        button.onPress = { [weak self] in self?.showScenarioMenu() }
        return button
    }()
    private let headerRow = ControlRowView()

    /// `scenarioCheckout` names the session's working directory; nil offers no scenarios.
    init(
        state: SimulatorWorkspaceState,
        scenarioCheckout: @escaping @MainActor () -> URL? = { nil },
        scenarioLoader: @escaping @Sendable (URL) async -> SimulatorScenarioCatalog = SimulatorScenarioController.loadDetached,
        factory: @escaping (SimulatorDeviceID?) -> SimulatorPaneViewController
    ) {
        self.state = state
        self.factory = factory
        self.scenarioCheckout = scenarioCheckout
        self.scenarios = SimulatorScenarioController(checkout: scenarioCheckout, loader: scenarioLoader)
        super.init(nibName: nil, bundle: nil)
        for member in state.members { makeMember(member) }
        scenarios.targets = { [weak self] in self?.simulators ?? [] }
        scenarios.onChange = { [weak self] in self?.refreshScenarioBand() }
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
            canvasTop,
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

    /// The device a member holds or is reaching for, so a member still preparing counts as taken.
    private func heldDevice(_ member: SimulatorWorkspaceState.Member) -> SimulatorDeviceID? {
        member.deviceID ?? controllers[member.id]?.selectedDeviceID
    }

    func deviceID(ofMember id: UUID) -> SimulatorDeviceID? {
        state.members.first { $0.id == id }.flatMap(heldDevice)
    }

    /// Every member as an agent sees it, in order, for `simulator_prepare`'s result.
    var agentSummary: SimulatorAgentCommandService.WorkspaceSummary {
        SimulatorAgentCommandService.WorkspaceSummary(
            layout: state.layout.rawValue,
            devices: state.members.map { member in
                SimulatorAgentCommandService.WorkspaceMember(
                    deviceID: heldDevice(member), name: controllers[member.id]?.adoptedDevice?.name,
                    selected: member.id == state.selectedID
                )
            }
        )
    }

    func agentShape(android: Bool) -> SimulatorAgentCommandService.WorkspaceShape {
        SimulatorAgentCommandService.WorkspaceShape(
            memberCount: state.members.count,
            isLoneAndEmpty: state.members.count == 1 && selectedSimulator.selectedDeviceID == nil,
            deviceOnPlatform: memberID(onAndroid: android).flatMap(deviceID(ofMember:))
        )
    }

    enum PlatformMix { case iOS, android, mixed }

    /// What the workspace holds, for the tab's name and glyph. A member still choosing counts as
    /// the device it is reaching for; with nothing chosen, the tab is the iOS Simulator it always was.
    var platformMix: PlatformMix {
        let platforms = Set(state.members.compactMap { heldDevice($0)?.platform.isAndroid })
        switch (platforms.contains(false), platforms.contains(true)) {
        case (false, true): return .android
        case (true, true): return .mixed
        default: return .iOS
        }
    }

    /// The first member on that platform, if the workspace has one.
    func memberID(onAndroid android: Bool) -> UUID? {
        state.members.first { heldDevice($0)?.platform.isAndroid == android }?.id
    }

    /// Adds a device of that platform beside the members already here — the one an unnamed
    /// request would choose, never one already held — and selects it. This is how a panel command
    /// or an agent asks for "iOS and Android side by side" without knowing any device id.
    @discardableResult
    func addAutomaticMember(android: Bool) async throws -> SimulatorPaneViewController {
        guard state.members.count < SimulatorWorkspaceState.maximumMembers else { throw Failure.full }
        let devices = try await selectedSimulator.refreshWorkspaceCatalogue()
        // Membership may have moved during discovery.
        guard state.members.count < SimulatorWorkspaceState.maximumMembers else { throw Failure.full }
        let taken = Set(state.members.compactMap(heldDevice))
        guard let deviceID = SimulatorAutomaticChoice.deviceID(in: devices, android: android, excluding: taken) else {
            throw Failure.noOtherDevice(android: android)
        }
        // A lone member already reaching for a device keeps it; the new one goes beside it rather
        // than replacing it, which is what `adopt` does with an unbound lone member.
        if state.members.count == 1, state.members[0].deviceID == nil, let held = heldDevice(state.members[0]) {
            state.members[0].deviceID = held
        }
        return try adopt(deviceID)
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
        let full = state.members.count >= SimulatorWorkspaceState.maximumMembers
        let entries = Self.groupedDeviceEntries(addableDevices) { device in
            ThemedMenuItem(
                title: device.name, subtitle: device.unavailableReason ?? device.runtimeName,
                isEnabled: !full && device.isAdoptable,
                onChoose: { [weak self] in _ = try? self?.adopt(device.id) }
            )
        }
        guard !entries.isEmpty else { return }
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: Self.deviceMenuWidth),
            from: addButton, selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    /// One list of every platform's devices, under a header per platform once there is more than
    /// one — so an iOS-only machine sees exactly the list it always did.
    static func groupedDeviceEntries(
        _ devices: [SimulatorDevice], item: (SimulatorDevice) -> ThemedMenuItem
    ) -> [ThemedMenuEntry] {
        let groups = DevicePlatformGroup.allCases.compactMap { group -> (DevicePlatformGroup, [SimulatorDevice])? in
            let members = devices.filter { DevicePlatformGroup($0.platform) == group }
            return members.isEmpty ? nil : (group, members)
        }
        guard groups.count > 1 else { return devices.map { .item(item($0)) } }
        return groups.flatMap { group, members in
            [ThemedMenuEntry.header(group.title)] + members.map { .item(item($0)) }
        }
    }

    /// The sections the device menus are grouped under: an emulator and a USB phone are both
    /// "Android" to the person choosing.
    enum DevicePlatformGroup: CaseIterable {
        case iOS, android

        init(_ platform: SimulatorDevicePlatform) { self = platform.isAndroid ? .android : .iOS }

        var title: String {
            switch self {
            case .iOS: return L10n.string("iOS")
            case .android: return L10n.string("Android")
            }
        }
    }

    /// What a device-chooser row stands for. Typed, so a member's UUID can never be mistaken for
    /// an iOS device UUID however the membership changed while the menu was open.
    enum ChooserChoice {
        case member(UUID)
        case device(SimulatorDeviceID)
    }

    var canvasForTesting: SimulatorWorkspaceCanvas { canvas }
    var headerForTesting: ControlRowView { headerRow }
    var scenarioButtonForTesting: ThemedIconButton { scenarioButton }
    var scenarioBandForTesting: PaneNoticeView? { scenarioBand }
    var scenarioHelpForTesting: SimulatorScenarioHelpViewController? {
        scenarioHelpPopover?.contentViewController as? SimulatorScenarioHelpViewController
    }

    // MARK: - Private

    private func makeMember(_ member: SimulatorWorkspaceState.Member) {
        let controller = factory(member.deviceID)
        controllers[member.id] = controller
        addChild(controller)
        controller.onFocusRequest = { [weak self] in self?.select(member.id) }
        controller.onRecoveryDeviceSelection = { [weak self, weak controller] deviceID in
            guard let self else { return }
            if let existing = self.state.members.first(where: { $0.deviceID == deviceID }) {
                self.select(existing.id)
            } else {
                self.select(member.id)
                controller?.selectDevice(deviceID)
            }
        }
        controller.onGestureEnd = { [weak self] in self?.canvas.needsLayout = true }
        controller.onFrameAspectChange = { [weak self] aspect in self?.canvas.updateAspect(aspect, for: member.id) }
        controller.onWorkspaceIdentityChange = { [weak self] in
            guard let self, self.isViewLoaded, self.state.selectedID == member.id else { return }
            self.refreshHeader()
        }
        controller.workspaceMenuExtras = { [weak self, weak controller] in
            guard let self, let controller, self.state.members.count > 1 else { return [] }
            return [.item(ThemedMenuItem(
                title: L10n.format("Remove %@ from Workspace", controller.workspaceDeviceName),
                onChoose: { [weak self] in self?.remove(member.id) }
            ))]
        }
        controller.workspaceLayoutMenu = { [weak self] in
            guard let self, self.state.members.count > 1 else { return [] }
            return SimulatorWorkspaceLayout.allCases.map { layout in
                .item(ThemedMenuItem(title: layout.displayTitle, isSelected: self.state.layout == layout,
                                     onChoose: { [weak self] in self?.setLayout(layout) }))
            }
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
        deviceChip.configure(symbolName: selected.workspaceDeviceSymbol, title: selected.workspaceDeviceName)
        deviceChip.isEnabled = !selected.availableWorkspaceDevices.isEmpty || state.members.count > 1
        layoutChip.configure(symbolName: state.layout.symbolName, title: state.layout.displayTitle)
        addButton.isEnabled = canAddSimulator
        addButton.toolTip = state.members.count >= SimulatorWorkspaceState.maximumMembers
            ? L10n.string("This workspace already has four devices. Remove one before adding another.")
            : L10n.string("Add Device")
        // Nothing to arrange with one device, so the chooser leaves the row rather than idling in it;
        // a narrow pane keeps it in the options menu instead.
        let showsLayout = state.members.count > 1 && !headerIsCompact
        selected.workspaceHeaderShowsLayout = showsLayout
        // A session with a checkout always offers Scenarios: with no file yet, the button opens
        // the help that sets one up, which is how a project finds out the feature exists.
        var leading: [NSView] = [deviceChip, addButton]
        if scenarioCheckout() != nil { leading.append(scenarioButton) }
        if showsLayout { leading.append(layoutChip) }
        let trailing = [selected.workspaceActions]
        if !headerRow.leadingViews.elementsEqual(leading, by: ===)
            || !headerRow.trailingViews.elementsEqual(trailing, by: ===) {
            headerRow.configure(leading: leading, trailing: trailing)
        }
    }

    private func deviceEntries() -> [ThemedMenuEntry] {
        guard state.members.count > 1 else {
            let selected = selectedSimulator
            return Self.groupedDeviceEntries(selected.availableWorkspaceDevices) { device in
                ThemedMenuItem(title: device.name, subtitle: device.unavailableReason ?? device.runtimeName,
                               representedValue: ChooserChoice.device(device.id),
                               isSelected: device.id == selected.selectedDeviceID,
                               isEnabled: device.isAdoptable || device.id == selected.selectedDeviceID)
            }
        }
        return state.members.map { member in
            let controller = controllers[member.id]
            return .item(ThemedMenuItem(
                title: controller?.workspaceDeviceName ?? L10n.string("Choose Simulator"),
                subtitle: controller?.adoptedDevice?.runtimeName,
                representedValue: ChooserChoice.member(member.id),
                isSelected: member.id == state.selectedID
            ))
        }
    }

    private func chooseDevice(_ value: Any?) {
        switch value as? ChooserChoice {
        case .member(let id)?:
            if state.members.contains(where: { $0.id == id }) { select(id) }
        case .device(let device)?:
            // Alone, the chooser switches the device, exactly like the single pane: + adds one.
            guard state.members.count == 1, state.members[0].deviceID != device else { return }
            state.members[0].deviceID = device
            selectedSimulator.selectDevice(device)
            refreshHeader()
            onChange?()
        case nil:
            return
        }
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

// MARK: - Scenarios

extension SimulatorWorkspaceViewController {
    /// Reads the checkout's file again, then offers it: the scenarios the members can open, or the
    /// setup help when the checkout has no file yet.
    func showScenarioMenu() {
        Task { [weak self] in
            guard let self else { return }
            guard let catalog = await self.scenarios.reload(), catalog.fileExists else {
                self.showScenarioHelp()
                return
            }
            self.presentScenarioMenu(catalog)
        }
    }

    /// Opens a scenario on every member that can show it, as the menu does.
    func openScenario(_ id: String) {
        scenarioNotice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.scenarios.open(id)
            } catch {
                self.scenarioNotice = error.localizedDescription
                self.refreshScenarioBand()
            }
        }
    }

    /// What the setup help says about this checkout's file.
    var scenarioHelpStatus: SimulatorScenarioHelpViewController.Status {
        guard let catalog = scenarios.catalog else {
            return scenarioCheckout() == nil ? .noCheckout : .reading
        }
        guard catalog.fileExists else { return .missing(catalog.fileURL) }
        if catalog.scenarios.isEmpty, let problem = catalog.diagnostics.first {
            return .failed(catalog.fileURL, problem.message)
        }
        return .loaded(catalog.fileURL, scenarios: catalog.scenarios.count, problems: catalog.diagnostics.count)
    }

    func showScenarioHelp() {
        if let popover = scenarioHelpPopover, popover.isShown { popover.close() }
        let help = SimulatorScenarioHelpViewController(status: scenarioHelpStatus)
        help.onFileCreated = { [weak self] in self?.reloadScenarioHelp() }
        let popover = ThemedPopover()
        popover.behavior = .transient
        popover.contentViewController = help
        popover.initialFirstResponder = help.view
        popover.onClose = { [weak self] in self?.scenarioHelpPopover = nil }
        scenarioHelpPopover = popover
        popover.show(relativeTo: scenarioButton.bounds, of: scenarioButton, preferredEdge: .maxY)
        reloadScenarioHelp()
    }

    /// Groups become submenus once there is more than one; scenarios that share a title within a
    /// group are one row whose submenu lists their variants, in file order.
    static func scenarioEntries(
        _ scenarios: [SimulatorScenario], selectedID: String?, open: @escaping (SimulatorScenario) -> Void
    ) -> [ThemedMenuEntry] {
        func item(_ scenario: SimulatorScenario, title: String) -> ThemedMenuItem {
            ThemedMenuItem(
                title: title,
                subtitle: scenario.hasSteps ? L10n.format("%lld steps", Int64(scenario.steps.count)) : nil,
                isSelected: scenario.id == selectedID,
                onChoose: { open(scenario) }
            )
        }
        func rows(_ members: [SimulatorScenario]) -> [ThemedMenuEntry] {
            orderedGroups(members, by: \.title).map { title, variants in
                guard variants.count > 1 else { return .item(item(variants[0], title: variants[0].displayTitle)) }
                return .item(ThemedMenuItem(
                    title: title,
                    isSelected: variants.contains { $0.id == selectedID },
                    submenu: variants.map { .item(item($0, title: $0.variant ?? $0.title)) }
                ))
            }
        }
        let groups = orderedGroups(scenarios, by: \.group)
        guard groups.count > 1 else { return rows(groups.first?.members ?? []) }
        return groups.map { group, members in
            .item(ThemedMenuItem(title: group, isSelected: members.contains { $0.id == selectedID }, submenu: rows(members)))
        }
    }

    private static func orderedGroups(
        _ scenarios: [SimulatorScenario], by key: KeyPath<SimulatorScenario, String>
    ) -> [(name: String, members: [SimulatorScenario])] {
        var order: [String] = []
        var members: [String: [SimulatorScenario]] = [:]
        for scenario in scenarios {
            let name = scenario[keyPath: key]
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(scenario)
        }
        return order.map { ($0, members[$0] ?? []) }
    }

    private func presentScenarioMenu(_ catalog: SimulatorScenarioCatalog) {
        var entries = Self.scenarioEntries(scenarios.offeredScenarios, selectedID: scenarios.session?.scenario.id) {
            [weak self] scenario in self?.openScenario(scenario.id)
        }
        if entries.isEmpty, catalog.diagnostics.isEmpty {
            entries.append(.item(ThemedMenuItem(title: L10n.string("No scenario opens on these devices"), isEnabled: false)))
        }
        if !catalog.diagnostics.isEmpty {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.header(L10n.format("Problems in %@", SimulatorScenarioDefaults.relativePath)))
            entries += catalog.diagnostics.map { .item(ThemedMenuItem(title: $0.message, help: $0.message, isEnabled: false)) }
        }
        entries += [.separator, .item(ThemedMenuItem(
            title: L10n.string("Scenario Help…"), onChoose: { [weak self] in self?.showScenarioHelp() }
        ))]
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: Self.deviceMenuWidth),
            from: scenarioButton, selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    private func reloadScenarioHelp() {
        Task { [weak self] in
            guard let self else { return }
            await self.scenarios.reload()
            self.scenarioHelpForTesting?.apply(self.scenarioHelpStatus)
        }
    }

    /// The band follows the scenario: rebuilt on each change, which is a small fixed band and
    /// announces the new step to VoiceOver as it arrives. Keyboard focus on one of its buttons
    /// moves to the same button of the new band.
    func refreshScenarioBand() {
        guard isViewLoaded else { return }
        let focused = scenarioBand?.actionControls.firstIndex { $0 === view.window?.firstResponder }
        scenarioBand?.removeFromSuperview()
        scenarioBand = nil
        guard let band = makeScenarioBand() else {
            canvasTop.isActive = true
            return
        }
        view.addSubview(band)
        canvasTop.isActive = false
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Design.Spacing.medium),
            canvas.topAnchor.constraint(equalTo: band.bottomAnchor, constant: Design.Spacing.medium),
        ])
        scenarioBand = band
        if let focused, band.actionControls.indices.contains(focused) {
            let control = band.actionControls[focused]
            view.window?.makeFirstResponder(control.isEnabled ? control : band.dismissControl)
        }
    }

    private func makeScenarioBand() -> PaneNoticeView? {
        guard let session = scenarios.session else {
            guard let notice = scenarioNotice else { return nil }
            let band = PaneNoticeView(tone: .attention, message: notice, actions: [], onDismiss: { [weak self] in
                self?.scenarioNotice = nil
                self?.refreshScenarioBand()
            })
            band.setAccessibilityIdentifier("simulator.workspace.scenarioBand")
            return band
        }
        let scenario = session.scenario
        let message: String
        if session.isOpening {
            message = L10n.string("Starting the app…")
        } else if let failure = session.failure {
            message = failure
        } else if scenario.hasSteps {
            message = L10n.format(
                "Step %lld of %lld: %@", Int64(session.step + 1), Int64(scenario.steps.count), scenario.steps[session.step].title
            )
        } else {
            return nil
        }
        var actions: [PaneNoticeAction] = []
        let steps = scenario.hasSteps && !session.isOpening
        if steps {
            actions = [
                PaneNoticeAction(title: L10n.string("Back")) { [weak self] in self?.scenarios.previous() },
                PaneNoticeAction(title: L10n.string("Next")) { [weak self] in self?.scenarios.next() },
                PaneNoticeAction(title: session.isPlaying ? L10n.string("Pause") : L10n.string("Play")) { [weak self] in
                    self?.scenarios.togglePlay()
                },
            ]
        } else if session.failure != nil {
            actions = [PaneNoticeAction(title: L10n.string("Try Again")) { [weak self] in self?.openScenario(scenario.id) }]
        }
        let band = PaneNoticeView(
            tone: session.failure == nil ? .informational : .attention,
            title: scenario.displayTitle,
            message: message,
            actions: actions,
            dismissTitle: L10n.string("Close Scenario"),
            onDismiss: { [weak self] in self?.scenarios.close() }
        )
        if steps {
            band.actionControls[0].isEnabled = !session.isAtFirstStep
            band.actionControls[1].isEnabled = !session.isAtLastStep
        }
        band.setAccessibilityIdentifier("simulator.workspace.scenarioBand")
        return band
    }
}
