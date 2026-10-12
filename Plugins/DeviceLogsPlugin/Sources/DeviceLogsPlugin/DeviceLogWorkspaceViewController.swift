import AppKit
import ThreadingDesignKit

/// Two independent captures inside the session's one Device Logs workspace. A tab is a view
/// choice, not a capture lifetime: only hiding the whole workspace stops the opened readers.
@MainActor
final class DeviceLogWorkspaceViewController: NSViewController {
    typealias Stream = DeviceLogPaneViewController.Stream

    private let sessionID: String?
    private let toolPath: String?
    private var preferredMachineID: String?
    private let tabs = ThemedSegmentedControl(frame: .zero)
    private let content = NSView()
    private(set) var panes: [Stream: DeviceLogPaneViewController] = [:]
    private(set) var selectedStream: Stream = .regular
    private(set) var isPresented = false
    private var discoveredSources: [DeviceLogSourceOption]?
    private var discoveryGeneration = 0
    private(set) var usesHostSections = false
    private var presentedSections = Set<Stream>()

    func sectionView(_ stream: Stream) -> NSView {
        usesHostSections = true
        let pane = panes[stream] ?? makePane(stream)
        pane.view.isHidden = false
        return pane.view
    }

    func setSectionPresented(_ stream: Stream, presented: Bool) {
        if presented { presentedSections.insert(stream); selectedStream = stream }
        else { presentedSections.remove(stream) }
        setPresented(!presentedSections.isEmpty)
        for (candidate, pane) in panes {
            pane.setRowsPresented(presentedSections.contains(candidate))
            if isPresented { pane.startCapture(discover: false) }
        }
    }

    func repaintSections() {
        panes.values.forEach { AppThemeRefresh.repaint($0.view) }
    }

    // Bounded seams let lifecycle tests exercise the actual controllers without device processes.
    var discover: ((@escaping ([DeviceLogSourceOption]) -> Void) -> Void)?
    var sourceFactory: ((DeviceLogSourceOption, DeviceLogSourceOption.Route, String?) -> DeviceLogRowSource?)?

    var selectedPane: DeviceLogPaneViewController? { panes[selectedStream] }

    init(sessionID: String?, toolPath: String?, preferredMachineID: String?) {
        self.sessionID = sessionID
        self.toolPath = toolPath
        self.preferredMachineID = preferredMachineID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        tabs.configure(titles: Stream.allCases.map(\.title))
        tabs.sizesToTitles = true
        tabs.setAccessibilityIdentifier("device-log-stream-tabs")
        tabs.onSelect = { [weak self] index in
            guard Stream.allCases.indices.contains(index) else { return }
            self?.selectStream(Stream.allCases[index])
        }
        let header = PaneHeaderView(leading: [tabs])
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        selectStream(.regular)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !usesHostSections { setPresented(true) }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if !usesHostSections { setPresented(false) }
    }

    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        if presented {
            for (stream, pane) in panes {
                pane.setRowsPresented(usesHostSections ? presentedSections.contains(stream) : stream == selectedStream)
                pane.startCapture(discover: false)
            }
            reloadSources()
        } else {
            discoveryGeneration += 1
            for pane in panes.values {
                pane.setRowsPresented(false)
                pane.stopCapture()
            }
        }
    }

    func selectStream(_ stream: Stream) {
        let pane = panes[stream] ?? makePane(stream)
        selectedStream = stream
        tabs.selectedIndex = Stream.allCases.firstIndex(of: stream) ?? 0
        for (candidate, controller) in panes {
            controller.setRowsPresented(usesHostSections ? presentedSections.contains(candidate) : candidate == stream)
            if !usesHostSections { controller.view.isHidden = candidate != stream }
        }
        if isPresented { pane.startCapture(discover: false) }
    }

    func selectMachine(id: String) {
        preferredMachineID = id
        panes.values.forEach { $0.selectMachine(id: id) }
    }

    func selectBluetooth(deviceID: String) -> Bool {
        guard isPresented, discoveredSources?.contains(where: {
            $0.machine.id == deviceID && Stream.bluetooth.includes($0)
        }) == true else { return false }
        selectStream(.bluetooth)
        return selectedPane?.selectBluetooth(deviceID: deviceID) ?? false
    }

    private func makePane(_ stream: Stream) -> DeviceLogPaneViewController {
        let pane = DeviceLogPaneViewController(
            owningSessionID: sessionID,
            preferredPymobiledevice3Path: toolPath,
            preferredMachineID: selectedPane?.selectedDeviceID ?? preferredMachineID,
            stream: stream
        )
        pane.captureManagedByWorkspace = true
        pane.sourceFactory = sourceFactory
        pane.requestDiscovery = { [weak self] in self?.reloadSources() }
        panes[stream] = pane
        addChild(pane)
        let child = pane.view
        child.translatesAutoresizingMaskIntoConstraints = false
        if !usesHostSections {
        content.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            child.topAnchor.constraint(equalTo: content.topAnchor),
            child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        }
        if let discoveredSources { pane.acceptSources(discoveredSources) }
        return pane
    }

    private func reloadSources() {
        guard isPresented else { return }
        discoveryGeneration += 1
        let generation = discoveryGeneration
        let completion: @Sendable ([DeviceLogSourceOption]) -> Void = { [weak self] sources in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, self.discoveryGeneration == generation else { return }
                self.discoveredSources = sources
                self.panes.values.forEach { $0.acceptSources(sources) }
            }
        }
        if let discover { discover(completion) }
        else { DeviceLogSourceCatalog.discover(preferredPymobiledevice3Path: toolPath, completion: completion) }
    }
}
