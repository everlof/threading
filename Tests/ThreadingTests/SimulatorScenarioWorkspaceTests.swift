import AppKit
import XCTest
@testable import Threading

@MainActor
final class SimulatorScenarioWorkspaceTests: XCTestCase {
    private let catalog = SimulatorScenarioLoader.decode(Data(SimulatorScenarioGuide.example.utf8),
                                                       repositoryRoot: URL(fileURLWithPath: "/repo"))

    private func workspace(checkout: URL?, catalog: SimulatorScenarioCatalog? = nil) -> SimulatorWorkspaceViewController {
        let loaded = catalog ?? self.catalog
        let workspace = SimulatorWorkspaceViewController(
            state: SimulatorWorkspaceState(deviceID: SimulatorDeviceID("AAAAAAAA-1111-2222-3333-444444444444")),
            scenarioCheckout: { checkout },
            scenarioLoader: { _ in loaded }
        ) { id in
            SimulatorPaneViewController(preferredDeviceID: id, isWorkspaceMember: true, control: ScenarioWorkspaceControl())
        }
        workspace.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        workspace.view.layoutSubtreeIfNeeded()
        return workspace
    }

    // MARK: - Menu

    func testGroupsBecomeSubmenusAndOneTitlesVariantsShareARow() throws {
        let entries = SimulatorWorkspaceViewController.scenarioEntries(catalog.scenarios, selectedID: "home/full-dark") { _ in }
        XCTAssertEqual(entries.compactMap(\.item).map(\.title), ["Home", "Orders"])
        let home = try XCTUnwrap(entries.first?.item)
        XCTAssertTrue(home.isSelected, "the group holding the open scenario is marked")
        let homeRows = try XCTUnwrap(home.submenu)
        XCTAssertEqual(homeRows.compactMap(\.item).map(\.title), ["Home"], "two variants of one title are one row")
        let variants = try XCTUnwrap(homeRows.first?.item?.submenu).compactMap(\.item)
        XCTAssertEqual(variants.map(\.title), ["Empty", "Many items, dark"])
        XCTAssertEqual(variants.map(\.isSelected), [false, true])
        let orders = try XCTUnwrap(entries.last?.item?.submenu).compactMap(\.item)
        XCTAssertEqual(orders.map(\.title), ["Order from cart to delivery"])
        XCTAssertEqual(orders.first?.subtitle, L10n.format("%lld steps", Int64(4)))
    }

    func testOneGroupIsListedWithoutASubmenu() {
        let orders = catalog.scenarios.filter { $0.group == "Orders" }
        var opened: [String] = []
        let entries = SimulatorWorkspaceViewController.scenarioEntries(orders, selectedID: nil) { opened.append($0.id) }
        XCTAssertEqual(entries.compactMap(\.item).map(\.title), ["Order from cart to delivery"])
        entries.first?.item?.onChoose?()
        XCTAssertEqual(opened, ["order/delivery"])
    }

    // MARK: - Header

    func testTheButtonStandsInTheHeaderOnlyForASessionWithACheckout() {
        let withCheckout = workspace(checkout: URL(fileURLWithPath: "/repo"))
        defer { withCheckout.terminate() }
        XCTAssertTrue(withCheckout.headerForTesting.leadingViews.contains { $0 === withCheckout.scenarioButtonForTesting })
        XCTAssertEqual(withCheckout.scenarioButtonForTesting.accessibilityTitle(), L10n.string("Scenarios"))

        let without = workspace(checkout: nil)
        defer { without.terminate() }
        XCTAssertFalse(without.headerForTesting.leadingViews.contains { $0 === without.scenarioButtonForTesting })
    }

    func testWithoutAFileTheHelpSaysWhereItGoes() async throws {
        let empty = SimulatorScenarioCatalog.empty(repositoryRoot: URL(fileURLWithPath: "/repo"))
        let workspace = workspace(checkout: URL(fileURLWithPath: "/repo"), catalog: empty)
        defer { workspace.terminate() }
        await workspace.scenarios.reload()
        XCTAssertEqual(workspace.scenarioHelpStatus, .missing(URL(fileURLWithPath: "/repo/.threading/scenarios.json")))
        let broken = SimulatorScenarioLoader.decode(Data("{".utf8), repositoryRoot: URL(fileURLWithPath: "/repo"))
        let failing = self.workspace(checkout: URL(fileURLWithPath: "/repo"), catalog: broken)
        defer { failing.terminate() }
        await failing.scenarios.reload()
        guard case .failed(_, let message) = failing.scenarioHelpStatus else {
            return XCTFail("\(failing.scenarioHelpStatus)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Band

    func testTheBandFollowsTheScenarioThroughItsSteps() async throws {
        let workspace = workspace(checkout: URL(fileURLWithPath: "/repo"))
        defer { workspace.terminate() }
        let phone = FakeScenarioTarget(SimulatorDeviceID("AAAAAAAA-1111-2222-3333-444444444444"))
        workspace.scenarios.targets = { [phone] }
        XCTAssertNil(workspace.scenarioBandForTesting)

        _ = try await workspace.scenarios.open("order/delivery")
        var band = try XCTUnwrap(workspace.scenarioBandForTesting)
        XCTAssertEqual(band.title, "Order from cart to delivery")
        XCTAssertEqual(band.message, L10n.format("Step %lld of %lld: %@", Int64(1), Int64(4), "Cart with three items"))
        XCTAssertEqual(band.actionControls.map(\.title), [L10n.string("Back"), L10n.string("Next"), L10n.string("Play")])
        XCTAssertEqual(band.actionControls.map(\.isEnabled), [false, true, true])

        XCTAssertTrue(band.actionControls[1].accessibilityPerformPress())
        try await waitUntil { workspace.scenarios.session?.step == 1 && phone.calls.count == 2 }
        band = try XCTUnwrap(workspace.scenarioBandForTesting)
        XCTAssertEqual(band.message, L10n.format("Step %lld of %lld: %@", Int64(2), Int64(4), "Payment accepted"))

        _ = try await workspace.scenarios.go(to: 3)
        XCTAssertEqual(workspace.scenarioBandForTesting?.actionControls.map(\.isEnabled), [true, false, true],
                       "Next rests at the last step")

        XCTAssertTrue(try XCTUnwrap(workspace.scenarioBandForTesting?.dismissControl).performPrimaryAction())
        XCTAssertNil(workspace.scenarios.session)
        XCTAssertNil(workspace.scenarioBandForTesting)
    }

    func testAScenarioWithoutStepsLeavesNoBandOnceItOpened() async throws {
        let workspace = workspace(checkout: URL(fileURLWithPath: "/repo"))
        defer { workspace.terminate() }
        workspace.scenarios.targets = { [FakeScenarioTarget(SimulatorDeviceID("AAAAAAAA-1111-2222-3333-444444444444"))] }
        _ = try await workspace.scenarios.open("home/empty")
        XCTAssertNil(workspace.scenarioBandForTesting)
    }

    func testARefusedChoiceIsShownUntilDismissed() async throws {
        let workspace = workspace(checkout: URL(fileURLWithPath: "/repo"))
        defer { workspace.terminate() }
        workspace.scenarios.targets = { [] }
        workspace.openScenario("home/empty")
        try await waitUntil { workspace.scenarioBandForTesting != nil }
        let band = try XCTUnwrap(workspace.scenarioBandForTesting)
        XCTAssertEqual(band.message, SimulatorScenarioError.noDevice.localizedDescription)
        XCTAssertTrue(try XCTUnwrap(band.dismissControl).performPrimaryAction())
        XCTAssertNil(workspace.scenarioBandForTesting)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }
}

/// A control the workspace's members can hold without a device answering.
private actor ScenarioWorkspaceControl: SimulatorControlling {
    func availableDevices() async throws -> [SimulatorDevice] { [] }
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        throw SimulatorControlError.noAvailableIOSDevices
    }
    func installAndLaunch(applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID,
                          arguments: [String]) async throws -> SimulatorLaunchReceipt {
        throw SimulatorControlError.noAvailableIOSDevices
    }
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data { Data() }
    func release(_ lease: SimulatorDeviceLease) async throws {}
}
