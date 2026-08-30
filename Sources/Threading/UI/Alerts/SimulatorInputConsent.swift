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

/// One explicit decision for one exact adopted device during this app launch.
///
/// Both approval and denial are remembered. Repeating a denied gesture must not turn the sheet
/// into pressure, and approval must never float from one UDID to another after the pane switches.
@MainActor
final class SimulatorInputConsentController: SimulatorInputAuthorizing {
    static let shared = SimulatorInputConsentController()

    private var decisions: [SimulatorDeviceID: Bool] = [:]
    private var pending: [SimulatorDeviceID: [@MainActor (Bool) -> Void]] = [:]

    func decision(for deviceID: SimulatorDeviceID) -> Bool? {
        decisions[deviceID]
    }

    func resetDecision(for deviceID: SimulatorDeviceID) {
        // An explicit retry cannot replace a sheet that is already being answered. This is also
        // what keeps every pending input request converged on one decision.
        guard pending[deviceID] == nil else { return }
        decisions.removeValue(forKey: deviceID)
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
                    + "Switching devices or closing the pane stops the connection."
            ),
            confirmTitle: L10n.string("Allow Control"),
            style: .warning
        )
        ConfirmationAlert.ask(request, in: window) { [weak self] approved in
            guard let self else { return }
            decisions[device.id] = approved
            let completions = pending.removeValue(forKey: device.id) ?? []
            completions.forEach { $0(approved) }
        }
    }
}
