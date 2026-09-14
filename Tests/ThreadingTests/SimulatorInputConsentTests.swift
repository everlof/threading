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

    private func device(_ id: SimulatorDeviceID) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            family: .iPhone,
            state: .booted,
            lastBootedAt: nil
        )
    }

    /// A denial is deliberately not persisted: it holds for the current launch (so a repeated
    /// gesture does not re-prompt) but leaves storage untouched, and a relaunch asks cleanly rather
    /// than a stray dismissal silencing the device forever.
    func testDeniedDeviceIsRememberedThisLaunchButNotPersisted() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let deviceID = SimulatorDeviceID(UUID().uuidString)!
        let controller = SimulatorInputConsentController(store: defaults) { _, _, completion in
            completion(false) // The user denies.
        }

        var answer: Bool?
        controller.authorize(device: device(deviceID), in: nil) { answer = $0 }
        XCTAssertEqual(answer, false)

        // Held in memory for this launch — a second gesture does not re-prompt.
        XCTAssertEqual(controller.decision(for: deviceID), false)
        // But nothing was written: the grants list is still absent/empty.
        XCTAssertNil(defaults.stringArray(forKey: grantsKey))

        // A relaunch (fresh controller over the same store) asks cleanly rather than staying denied.
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
