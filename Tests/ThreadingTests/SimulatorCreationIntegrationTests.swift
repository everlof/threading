import AppKit
import XCTest
@testable import Threading

/// Explicitly opted in: creates and removes only its own empty device, never mutating an
/// already-installed Simulator. Exercises the shipping agent route with the real consent store.
@MainActor
final class SimulatorCreationIntegrationTests: HostedStoreTestCase {
    func testBackgroundAgentCreatesInspectsAndControlsWithoutAConsentDialog() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_SIMULATOR_CREATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_THREADING_SIMULATOR_CREATION_INTEGRATION=1 on xcodebuild to create a disposable iOS Simulator.")
        }
        let suite = "\(PreferenceStore.hostedTestSuitePrefix).simulator-creation.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let authorizer = SimulatorInputConsentController(store: store) { _, _, complete in
            XCTFail("A background agent was asked to approve its own empty Simulator.")
            complete(false)
        }
        let control = SimctlSimulatorControl()
        let pane = DisplayPaneController(
            simulatorControl: control,
            simulatorStreamCoordinator: SimulatorLiveStreamCoordinator(maximumStreams: 1),
            simulatorInputAuthorizer: authorizer
        )
        let sessionID = SessionID()
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane, visibleSessionID: { nil }, setPaneVisible: { _ in },
            windowProvider: { nil }, activateApp: {}
        )
        let created = await execute(.simulatorPrepare(SimulatorPrepareArguments(
            deviceID: nil, createName: "Threading Creation Test \(UUID().uuidString.prefix(8))"
        )), coordinator: coordinator, sessionID: sessionID)
        // The grant is recorded immediately after creation, even if boot/preparation then fails.
        let ids = store.stringArray(forKey: "codes.threading.simulator.controlGrantedDeviceIDs") ?? []
        var failure: Error?
        do {
            XCTAssertFalse(created.isError, created.text)
            let id = try XCTUnwrap(ids.first)
            XCTAssertEqual(ids.count, 1)
            let snapshot = await execute(.simulatorSnapshot(SimulatorSnapshotArguments(
                interactiveOnly: false, deviceID: id)), coordinator: coordinator, sessionID: sessionID)
            XCTAssertFalse(snapshot.isError, snapshot.text)
            let home = await execute(.simulatorPressButton(SimulatorPressButtonArguments(button: "home", deviceID: id)),
                                     coordinator: coordinator, sessionID: sessionID)
            XCTAssertFalse(home.isError, home.text)
            XCTAssertEqual(SimulatorInputConsentController(store: store).decision(for: SimulatorDeviceID(id)!), true)
        } catch { failure = error }

        for tab in pane.tabs(for: sessionID) { _ = pane.closeTab(id: tab.id, for: sessionID) }
        DisplayPaneStore.shared.removeSession(sessionID)
        // Let the lease's bounded release grace finish before deleting the device it owns.
        try await Task.sleep(for: .seconds(6))
        try await Task.detached {
            let runner = XcrunSimulatorCommandRunner()
            for id in ids {
                _ = try? runner.run(["shutdown", id], timeout: 30, maximumOutputBytes: 4096,
                                   capture: .combined, cancellation: SimulatorCommandCancellation())
                let removed = try runner.run(["delete", id], timeout: 30, maximumOutputBytes: 4096,
                                             capture: .combined, cancellation: SimulatorCommandCancellation())
                guard removed.termination == .exited(0) else {
                    throw SimulatorControlError.commandFailed(operation: "delete test device",
                        detail: String(decoding: removed.output, as: UTF8.self))
                }
            }
        }.value
        if let failure { throw failure }
    }

    private func execute(_ command: AgentCommand, coordinator: AgentToolCoordinator,
                         sessionID: SessionID) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(command, for: sessionID) { continuation.resume(returning: $0) }
        }
    }
}
