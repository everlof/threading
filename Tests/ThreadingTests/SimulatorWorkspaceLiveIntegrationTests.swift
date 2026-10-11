import AppKit
import ThreadingSimulatorKit
import XCTest
@testable import Threading

/// Opt-in signed-helper verification against four dedicated, already-booted fixture devices.
/// Ordinary suites skip this lane; it never adopts an arbitrary device from the catalogue.
@MainActor
final class SimulatorWorkspaceLiveIntegrationTests: HostedStoreTestCase {
    private let commands = SimulatorCommandQueue(queue: DispatchQueue(label: "workspace.live.commands"))
    private var containers: [String: String] = [:]

    func testFourAnimatedGuestsRotateAndReflowThroughTheShippingWorkspace() async throws {
        let rawIDs = ProcessInfo.processInfo.environment["THREADING_SIMULATOR_WORKSPACE_UDIDS"] ?? ""
        let deviceIDs = rawIDs.split(separator: ",").compactMap { SimulatorDeviceID(String($0)) }
        guard deviceIDs.count == 4, Set(deviceIDs).count == 4 else {
            throw XCTSkip("Provide four dedicated fixture devices in THREADING_SIMULATOR_WORKSPACE_UDIDS.")
        }
        let rawContainers = try XCTUnwrap(ProcessInfo.processInfo.environment["THREADING_SIMULATOR_WORKSPACE_CONTAINERS"])
        containers = try JSONDecoder().decode([String: String].self, from: Data(rawContainers.utf8))
        XCTAssertEqual(Set(containers.keys), Set(deviceIDs.map(\.rawValue)))
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["THREADING_SIMULATOR_WORKSPACE_OUT"])
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let control = WorkspaceLiveControl(deviceIDs: Set(deviceIDs))
        let observations = WorkspaceLiveObservations(deviceIDs: deviceIDs)
        let streams = WorkspaceLiveCoordinator(observations: observations)
        let pane = DisplayPaneController(simulatorControl: control, simulatorStreamCoordinator: streams,
            simulatorInputAuthorizer: WorkspaceLiveAuthorizer(deviceIDs: Set(deviceIDs)))
        let session = AgentSession(kind: .codex, title: "Live simulator workspace", usesNativeUI: true)
        let project = Project(name: "Workspace verification", folderURL: directory)
        let conversation = requireConversationViewController(agentSession: session, project: project,
            customizationLookup: { _ in .empty })
        let split = SidebarSplitViewController()
        let conversationItem = NSSplitViewItem(viewController: conversation)
        conversationItem.minimumThickness = 560
        let paneItem = NSSplitViewItem(viewController: pane)
        paneItem.minimumThickness = 260
        split.addSplitViewItem(conversationItem)
        split.addSplitViewItem(paneItem)
        let host = WindowChromeHostViewController(workspace: split)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.orderFront(nil)
        host.setTakeoverActive(true)
        host.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(split.splitView.bounds.width - 640, ofDividerAt: 0)
        pane.showSession(session.id)
        defer {
            for tab in pane.tabs(for: session.id) { _ = pane.closeTab(id: tab.id, for: session.id) }
            DisplayPaneStore.shared.removeSession(session.id)
            window.contentViewController = nil
            window.close()
        }

        for id in deviceIDs { try await orient(id, landscape: false) }
        for id in deviceIDs.prefix(2) { _ = try pane.activateSimulator(for: session.id, deviceID: id) }
        let workspace = try XCTUnwrap(pane.currentSimulatorWorkspace)
        try await wait("portrait pair") {
            workspace.simulators.allSatisfy { self.isDirect($0) && self.isLandscape($0) == false }
                && observations.snapshot().prefix(2).allSatisfy { $0.frames >= 10 }
        }
        for simulator in workspace.simulators { try await confirmFixtureForeground(simulator) }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.canvasForTesting.plan?.layout, .row)
        try capture(host.view, name: "live-portraits", directory: directory)

        // Use accessibility-derived targets and the actual input bridge for the first rotation.
        for simulator in workspace.simulators { try await tap("Landscape", on: simulator) }
        try await wait("landscape pair after real rotation") {
            workspace.simulators.allSatisfy { self.isDirect($0) && self.isLandscape($0) == true }
                && observations.snapshot().prefix(2).allSatisfy { $0.geometryChanges > 0 && $0.opens > 1 }
        }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.canvasForTesting.plan?.layout, .column)
        try capture(host.view, name: "live-landscapes", directory: directory)
        for simulator in workspace.simulators {
            try await tap("Portrait", on: simulator)
            try await wait("landscape accessibility target maps to the native digitizer") {
                self.isDirect(simulator) && self.isLandscape(simulator) == false
            }
        }
        for id in deviceIDs.prefix(2) { try await orient(id, landscape: true) }
        try await wait("restored landscape pair") { workspace.simulators.allSatisfy { self.isLandscape($0) == true } }

        for id in deviceIDs.suffix(2) { _ = try pane.activateSimulator(for: session.id, deviceID: id) }
        try await wait("four independent guests") {
            workspace.simulators.count == 4 && workspace.simulators.allSatisfy(self.isDirect)
                && observations.snapshot().allSatisfy { $0.frames >= 10 }
        }
        let identities = workspace.simulators.map(ObjectIdentifier.init)
        workspace.setLayout(.grid)
        host.view.layoutSubtreeIfNeeded()
        try capture(host.view, name: "live-mixed-grid", directory: directory)
        for id in deviceIDs { try await orient(id, landscape: false) }
        try await wait("four portrait guests") {
            workspace.simulators.allSatisfy { self.isDirect($0) && self.isLandscape($0) == false }
        }

        var processSamples: [String] = []
        for _ in 0..<6 {
            let before = observations.snapshot().map(\.frames)
            try await Task.sleep(for: .seconds(5))
            let after = observations.snapshot()
            for (index, reading) in after.enumerated() {
                XCTAssertGreaterThan(reading.frames - before[index], 10,
                    "Device \(deviceIDs[index]) stopped moving during the four-guest workload.")
                XCTAssertTrue(reading.failures.isEmpty, reading.failures.joined(separator: "; "))
            }
            processSamples.append(try await processSample())
        }
        try capture(host.view, name: "live-four-portraits", directory: directory)
        try JSONEncoder().encode(observations.snapshot()).write(
            to: directory.appendingPathComponent("four-guest-streams.json"))
        try processSamples.joined(separator: "\n\n").write(
            to: directory.appendingPathComponent("process-samples.txt"), atomically: true, encoding: .utf8)
        print("Four animated guest workload completed: \(observations.snapshot())")
        do {
            let extra = try await streams.base.openStream(for: deviceIDs[0])
            extra.stop()
            XCTFail("The live four-helper budget admitted a fifth stream.")
        } catch {
            XCTAssertEqual(error as? SimulatorLiveStreamError, .streamLimit(maximum: 4))
        }

        // Confirm real geometry changes end an authorized contact and preserve device identity.
        workspace.setLayout(.focus)
        workspace.select(workspace.state.members[0].id)
        let selected = workspace.selectedSimulator
        try await wait("focused direct transport") { self.isDirect(selected) }
        selected.screenViewForTesting.onTouchBegan?(CGPoint(x: 0.5, y: 0.2))
        try await wait("authorized continuous contact") { selected.hasActiveWorkspaceGesture }
        try await orient(try XCTUnwrap(selected.selectedDeviceID), landscape: true)
        // UIKit may defer the scene transition until the current contact ends. Keep the host's
        // gesture attached to this device, release it, then confirm the actual geometry event.
        selected.screenViewForTesting.onTouchEnded?(CGPoint(x: 0.5, y: 0.2))
        try await orient(try XCTUnwrap(selected.selectedDeviceID), landscape: true)
        try await wait("rotation around a continuous contact renegotiates") {
            !selected.hasActiveWorkspaceGesture && self.isDirect(selected) && self.isLandscape(selected) == true
        }
        XCTAssertEqual(workspace.state.layout, .focus)
        XCTAssertEqual(workspace.simulators.map(ObjectIdentifier.init), identities)
        try await orient(try XCTUnwrap(selected.selectedDeviceID), landscape: false)
        try await wait("focused portrait") { self.isDirect(selected) && self.isLandscape(selected) == false }
        paneItem.maximumThickness = 260
        host.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(split.splitView.bounds.width - 260, ofDividerAt: 0)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.view.bounds.width, 260, accuracy: 2)
        try capture(host.view, name: "live-focus-narrow", directory: directory)

        paneItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        split.splitView.setPosition(split.splitView.bounds.width - 640, ofDividerAt: 0)
        workspace.setLayout(.grid)
        try await wait("restored four guests after Focus") { workspace.simulators.allSatisfy(self.isDirect) }
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.state.layout, .grid)
        XCTAssertEqual(workspace.simulators.map(ObjectIdentifier.init), identities)
        let counters = await control.counters()
        XCTAssertEqual(counters.prepares, Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0.rawValue, 1) }))
        XCTAssertEqual(counters.screenshots, 0, "Real rotation must recover without public screenshot polling.")
        try JSONEncoder().encode(observations.snapshot()).write(to: directory.appendingPathComponent("streams.json"))
        try processSamples.joined(separator: "\n\n").write(
            to: directory.appendingPathComponent("process-samples.txt"), atomically: true, encoding: .utf8)
        print("Four guest workload: \(observations.snapshot()); public screenshots=\(counters.screenshots)")
    }

    private func isDirect(_ pane: SimulatorPaneViewController) -> Bool {
        switch pane.liveBackendForTesting {
        case .direct, .sharedMemory, .android: return pane.frameImageForTesting != nil
        case .screenshotFallback, nil: return false
        }
    }

    private func isLandscape(_ pane: SimulatorPaneViewController) -> Bool? {
        guard let size = pane.frameImageForTesting?.size else { return nil }
        return size.width > size.height
    }

    private func wait(_ operation: String, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WorkspaceLiveError.failed(operation) }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Live workspace checkpoint: \(operation)")
    }

    private func orient(_ id: SimulatorDeviceID, landscape: Bool) async throws {
        let path = try XCTUnwrap(containers[id.rawValue])
        guard path.contains("/CoreSimulator/Devices/\(id.rawValue)/data/Containers/Data/Application/") else {
            throw WorkspaceLiveError.failed("The fixture container does not belong to the exact dedicated device.")
        }
        let directory = URL(fileURLWithPath: path).appendingPathComponent("Documents", isDirectory: true)
        try await commands.perform {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ((landscape ? "landscape" : "portrait") + "\n" + UUID().uuidString).write(
                to: directory.appendingPathComponent("orientation.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func snapshot(_ simulator: SimulatorPaneViewController) async throws -> SimulatorAccessibilityElement {
        try await withCheckedThrowingContinuation { continuation in
            simulator.snapshotForAgent { result in
                switch result {
                case .success(let snapshot): continuation.resume(returning: snapshot.root)
                case .failure(let detail): continuation.resume(throwing: WorkspaceLiveError.failed(detail))
                }
            }
        }
    }

    private func button(_ label: String, in root: SimulatorAccessibilityElement) -> SimulatorAccessibilityElement? {
        if root.role == "AXButton", root.label == label { return root }
        return root.children.lazy.compactMap { self.button(label, in: $0) }.first
    }

    private func tap(_ label: String, on simulator: SimulatorPaneViewController) async throws {
        let root = try await snapshot(simulator)
        let target = try XCTUnwrap(button(label, in: root), "Fixture button \(label) was unavailable.")
        let input = SimulatorBridgeInput.tap(x: target.frame.midX / root.frame.width,
                                            y: target.frame.midY / root.frame.height)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            simulator.sendInputForAgent(input) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let detail): continuation.resume(throwing: WorkspaceLiveError.failed(detail))
                }
            }
        }
    }

    private func confirmFixtureForeground(_ simulator: SimulatorPaneViewController) async throws {
        // Clear the fixture's own first URL-open prompt left by exploratory setup, if present.
        if button("Cancel", in: try await snapshot(simulator)) != nil {
            try await tap("Cancel", on: simulator)
            try await Task.sleep(for: .milliseconds(300))
        }
        let root = try await snapshot(simulator)
        XCTAssertNotNil(button("Portrait", in: root), "Fixture root: \(root)")
        XCTAssertNotNil(button("Landscape", in: root), "Fixture root: \(root)")
    }

    private func command(_ arguments: [String], executable: String = "/usr/bin/xcrun",
                         prefix: [String] = ["simctl"]) async throws -> String {
        try await commands.perform {
            let result = try XcrunSimulatorCommandRunner(executable: executable, prefixArguments: prefix).run(
                arguments, timeout: 20, maximumOutputBytes: 64_000, capture: .combined,
                cancellation: SimulatorCommandCancellation())
            let output = String(decoding: result.output, as: UTF8.self)
            guard result.termination == .exited(0) else { throw WorkspaceLiveError.failed("\(arguments.first ?? executable): \(output)") }
            return output
        }
    }

    private func processSample() async throws -> String {
        let hostPID = String(ProcessInfo.processInfo.processIdentifier)
        let children = try await command(["-P", hostPID], executable: "/usr/bin/pgrep", prefix: [])
        let guests = try await command(["-x", "WorkspaceFixture"], executable: "/usr/bin/pgrep", prefix: [])
        let pids = ([hostPID] + (children + "\n" + guests).split(whereSeparator: \.isWhitespace).map(String.init))
            .joined(separator: ",")
        let output = try await command(["-p", pids, "-o", "pid,ppid,%cpu,rss,comm"], executable: "/bin/ps", prefix: [])
        let lines = output.split(separator: "\n").filter { line in
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5 else { return false }
            return fields[0] == hostPID || fields[4].hasSuffix("/WorkspaceFixture")
                || (fields[1] == hostPID && fields[4].hasSuffix("/threading-simulator-helper"))
        }
        XCTAssertEqual(lines.filter { $0.hasSuffix("/threading-simulator-helper") }.count, 4)
        XCTAssertEqual(lines.filter { $0.hasSuffix("/WorkspaceFixture") }.count, 4)
        return "pid ppid ps_cpu_percent rss_kb executable\n" + lines.joined(separator: "\n")
    }

    private func capture(_ root: NSView, name: String, directory: URL) throws {
        root.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private enum WorkspaceLiveError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let detail): "Live workspace verification failed: \(detail)" }
    }
}

private actor WorkspaceLiveControl: SimulatorControlling {
    private let base = SimctlSimulatorControl()
    private let deviceIDs: Set<SimulatorDeviceID>
    private var prepares: [String: Int] = [:]
    private var screenshots = 0
    init(deviceIDs: Set<SimulatorDeviceID>) { self.deviceIDs = deviceIDs }
    func availableDevices() async throws -> [SimulatorDevice] {
        try await base.availableDevices().filter { deviceIDs.contains($0.id) }
    }
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        guard let deviceID, deviceIDs.contains(deviceID) else { throw WorkspaceLiveError.failed("Unknown fixture device") }
        prepares[deviceID.rawValue, default: 0] += 1
        let lease = try await base.prepare(deviceID: deviceID)
        guard lease.bootOwnership == .user else { throw WorkspaceLiveError.failed("Fixture must already be booted") }
        return lease
    }
    func installAndLaunch(applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID,
                          arguments: [String]) async throws -> SimulatorLaunchReceipt {
        try await base.installAndLaunch(applicationURL: applicationURL, bundleIdentifier: bundleIdentifier,
                                       on: deviceID, arguments: arguments)
    }
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        screenshots += 1
        return try await base.screenshot(of: deviceID)
    }
    func release(_ lease: SimulatorDeviceLease) async throws { try await base.release(lease) }
    func counters() -> (prepares: [String: Int], screenshots: Int) { (prepares, screenshots) }
}

private final class WorkspaceLiveObservations: @unchecked Sendable {
    struct Reading: Codable, Sendable {
        let deviceID: String
        var frames = 0
        var opens = 0
        var geometryChanges = 0
        var width = 0
        var height = 0
        var failures: [String] = []
    }
    private let lock = NSLock()
    private var readings: [Reading]
    init(deviceIDs: [SimulatorDeviceID]) { readings = deviceIDs.map { Reading(deviceID: $0.rawValue) } }
    func opened(_ id: SimulatorDeviceID) {
        lock.withLock { if let index = readings.firstIndex(where: { $0.deviceID == id.rawValue }) { readings[index].opens += 1 } }
    }
    func record(_ event: SimulatorLiveStreamEvent, for id: SimulatorDeviceID) {
        lock.withLock {
            guard let index = readings.firstIndex(where: { $0.deviceID == id.rawValue }) else { return }
            switch event {
            case .frame(let frame):
                readings[index].frames += 1
                readings[index].width = frame.image.width
                readings[index].height = frame.image.height
            case .geometryChanged: readings[index].geometryChanges += 1
            case .failed(let detail): readings[index].failures.append(detail)
            case .ready, .statistics, .ended: break
            }
        }
    }
    func snapshot() -> [Reading] { lock.withLock { readings } }
}

private struct WorkspaceLiveCoordinator: SimulatorLiveStreamCoordinating {
    let base = SimulatorLiveStreamCoordinator(maximumStreams: 4)
    let observations: WorkspaceLiveObservations
    func openStream(for deviceID: SimulatorDeviceID) async throws -> any SimulatorLiveStreamSession {
        let stream = try await base.openStream(for: deviceID)
        observations.opened(deviceID)
        return WorkspaceObservedStream(base: stream, deviceID: deviceID, observations: observations)
    }
}

private final class WorkspaceObservedStream: SimulatorLiveStreamSession, @unchecked Sendable {
    let events: AsyncStream<SimulatorLiveStreamEvent>
    var screenOrientation: SimulatorScreenOrientation? { base.screenOrientation }
    private let base: any SimulatorLiveStreamSession
    private let forwarding: Task<Void, Never>
    init(base: any SimulatorLiveStreamSession, deviceID: SimulatorDeviceID, observations: WorkspaceLiveObservations) {
        self.base = base
        let pair = AsyncStream<SimulatorLiveStreamEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        events = pair.stream
        forwarding = Task {
            for await event in base.events {
                observations.record(event, for: deviceID)
                pair.continuation.yield(event)
            }
            pair.continuation.finish()
        }
    }
    func setVisible(_ visible: Bool) { base.setVisible(visible) }
    func sendInput(_ input: SimulatorBridgeInput) async throws { try await base.sendInput(input) }
    func streamInput(_ input: SimulatorBridgeInput) { base.streamInput(input) }
    func requestAccessibilitySnapshot() async throws -> SimulatorAccessibilityElement { try await base.requestAccessibilitySnapshot() }
    func stop() { base.stop(); forwarding.cancel() }
}

@MainActor
private final class WorkspaceLiveAuthorizer: SimulatorInputAuthorizing {
    private let deviceIDs: Set<SimulatorDeviceID>
    init(deviceIDs: Set<SimulatorDeviceID>) { self.deviceIDs = deviceIDs }
    func authorize(device: SimulatorDevice, in window: NSWindow?, completion: @escaping @MainActor (Bool) -> Void) {
        completion(deviceIDs.contains(device.id))
    }
}
