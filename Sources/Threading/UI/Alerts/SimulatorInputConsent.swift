import AppKit

@MainActor
protocol SimulatorInputAuthorizing: AnyObject {
    func authorize(
        device: SimulatorDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    )
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
