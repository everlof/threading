import XCTest
@testable import Threading

@MainActor
final class SimulatorInputConsentTests: XCTestCase {
    private let grantsKey = "codes.threading.simulator.controlGrantedDeviceIDs"

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "\(PreferenceStore.hostedTestSuitePrefix).simulator-consent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// The whole point of the change: an approval a previous launch recorded is still in force in
    /// a freshly constructed controller, so the user is not re-asked every relaunch.
    func testApprovedDeviceIsRememberedAcrossRelaunch() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let deviceID = SimulatorDeviceID("4111208A-4B29-40E1-8C66-1B8AE2A1BF1F")!
        let unknown = SimulatorDeviceID(UUID().uuidString)!
        defaults.set([deviceID.rawValue], forKey: grantsKey)

        let relaunched = SimulatorInputConsentController(store: defaults)
        XCTAssertEqual(relaunched.decision(for: deviceID), true)
        XCTAssertNil(relaunched.decision(for: unknown))
    }

    /// The header Control button clears the decision; that must also forget the durable grant so
    /// the next gesture asks again rather than silently reusing the old yes.
    func testResetForgetsThePersistedGrant() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let deviceID = SimulatorDeviceID(UUID().uuidString)!
        defaults.set([deviceID.rawValue], forKey: grantsKey)

        let controller = SimulatorInputConsentController(store: defaults)
        XCTAssertEqual(controller.decision(for: deviceID), true)

        controller.resetDecision(for: deviceID)
        XCTAssertNil(controller.decision(for: deviceID))
        XCTAssertEqual(defaults.stringArray(forKey: grantsKey), [])

        // A relaunch after the reset also asks cleanly.
        let relaunched = SimulatorInputConsentController(store: defaults)
        XCTAssertNil(relaunched.decision(for: deviceID))
    }

    /// A malformed stored id is ignored rather than crashing the load.
    func testMalformedStoredGrantIsIgnored() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let deviceID = SimulatorDeviceID(UUID().uuidString)!
        defaults.set(["not-a-uuid", deviceID.rawValue], forKey: grantsKey)

        let controller = SimulatorInputConsentController(store: defaults)
        XCTAssertEqual(controller.decision(for: deviceID), true)
    }
}
