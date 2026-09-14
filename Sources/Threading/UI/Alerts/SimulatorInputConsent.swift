import AppKit

@MainActor
protocol SimulatorInputAuthorizing: AnyObject {
    /// The remembered decision for this exact device, or nil when the next request must ask.
    func decision(for deviceID: SimulatorDeviceID) -> Bool?

    /// Clears a previous decision only after an explicit, ordinary Control-button press.
    /// Repeated gestures never call this, so a denial cannot turn into repeated prompting.
    func resetDecision(for deviceID: SimulatorDeviceID)

    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    )
}

extension SimulatorInputAuthorizing {
    func decision(for deviceID: SimulatorDeviceID) -> Bool? { nil }
    func resetDecision(for deviceID: SimulatorDeviceID) {}
}

/// One explicit decision for one exact adopted device, an **approval remembered across launches**.
///
/// Approving control for a device is a durable user choice: once granted, that exact device stays
/// controllable without another sheet on the next launch, because re-asking every relaunch was
/// the app's most-repeated permission prompt and taught nothing new each time. A **denial** is
/// deliberately *not* persisted — it is remembered only for the current launch so repeated
/// gestures do not turn the sheet into pressure, and a fresh launch asks cleanly rather than a
/// stray dismissal silencing the device forever. Approval never floats from one UDID to another
/// after the pane switches.
@MainActor
final class SimulatorInputConsentController: SimulatorInputAuthorizing {
    static let shared = SimulatorInputConsentController()

    private enum Storage {
        /// The UDIDs the user has granted control, most-recent last.
        static let grantedDeviceIDsKey = "codes.threading.simulator.controlGrantedDeviceIDs"
        /// A device the user has not touched in a long time is not worth remembering forever;
        /// the list is bounded so a machine that churns simulators does not grow it without end.
        static let maximumRememberedGrants = 64
    }

    /// Presents the control-consent prompt and yields the answer. Injectable so a test can drive an
    /// approval or a denial deterministically without a modal — the same reason `ConfirmationAlert`
    /// takes its settings by injection.
    typealias Present = @MainActor (
        _ request: ConfirmationRequest,
        _ window: NSWindow?,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void

    private let store: UserDefaults
    private let present: Present
    private var decisions: [SimulatorDeviceID: Bool] = [:]
    private var pending: [SimulatorDeviceID: [@MainActor (Bool) -> Void]] = [:]

    /// `store` defaults to `PreferenceStore.shared` so a hosted test writes a scratch suite rather
    /// than the developer's own preferences, exactly as every other stored user choice does.
    init(
        store: UserDefaults = PreferenceStore.shared,
        present: @escaping Present = { ConfirmationAlert.ask($0, in: $1, completion: $2) }
    ) {
        self.store = store
        self.present = present
        for rawValue in persistedGrants() {
            guard let deviceID = SimulatorDeviceID(rawValue) else { continue }
            decisions[deviceID] = true
        }
    }

    func decision(for deviceID: SimulatorDeviceID) -> Bool? {
        decisions[deviceID]
    }

    func resetDecision(for deviceID: SimulatorDeviceID) {
        // An explicit retry cannot replace a sheet that is already being answered. This is also
        // what keeps every pending input request converged on one decision.
        guard pending[deviceID] == nil else { return }
        decisions.removeValue(forKey: deviceID)
        forgetGrant(deviceID)
    }

    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if let decision = decisions[device.id] {
            completion(decision)
            return
        }
        if pending[device.id] != nil {
            pending[device.id]?.append(completion)
            return
        }
        pending[device.id] = [completion]

        let request = ConfirmationRequest(
            prompt: .controlSimulatorDevice,
            title: L10n.format("Control %@?", device.name),
            message: L10n.string(
                "Threading and this session's agent will be able to tap, swipe, type, and press "
                    + "buttons on this exact device while it is adopted in the right panel. "
                    + "Threading remembers this choice for this device."
            ),
            confirmTitle: L10n.string("Allow Control"),
            style: .warning
        )
        present(request, window) { [weak self] approved in
            guard let self else { return }
            decisions[device.id] = approved
            // Only an approval is durable. A denial stays in memory for this launch so the sheet
            // does not reappear on the next gesture, but a relaunch asks again from a clean slate.
            if approved { rememberGrant(device.id) }
            let completions = pending.removeValue(forKey: device.id) ?? []
            completions.forEach { $0(approved) }
        }
    }

    // MARK: - Persistence

    private func persistedGrants() -> [String] {
        store.stringArray(forKey: Storage.grantedDeviceIDsKey) ?? []
    }

    private func rememberGrant(_ deviceID: SimulatorDeviceID) {
        var grants = persistedGrants().filter { $0 != deviceID.rawValue }
        grants.append(deviceID.rawValue)
        if grants.count > Storage.maximumRememberedGrants {
            grants.removeFirst(grants.count - Storage.maximumRememberedGrants)
        }
        store.set(grants, forKey: Storage.grantedDeviceIDsKey)
    }

    private func forgetGrant(_ deviceID: SimulatorDeviceID) {
        let grants = persistedGrants()
        let remaining = grants.filter { $0 != deviceID.rawValue }
        guard remaining.count != grants.count else { return }
        store.set(remaining, forKey: Storage.grantedDeviceIDsKey)
    }
}
