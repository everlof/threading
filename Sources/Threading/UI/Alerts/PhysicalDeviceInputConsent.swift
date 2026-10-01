import AppKit

@MainActor
protocol PhysicalDeviceInputAuthorizing: AnyObject {
    func decision(for deviceID: PhysicalDeviceID) -> Bool?
    func resetDecision(for deviceID: PhysicalDeviceID)
    func revokeDecision(for deviceID: PhysicalDeviceID)
    func authorize(
        device: PhysicalDevice,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    )
}

/// One visible-pane control grant for one exact physical iPhone.
///
/// Unlike Simulator approval, this is intentionally not durable. Hiding the pane or selecting a
/// different phone revokes it, and every input call rechecks the decision before targeting the
/// hardware UDID. A denial is remembered until the explicit control button asks to retry, so a
/// stray click cannot turn into repeated pressure from confirmation sheets.
@MainActor
final class PhysicalDeviceInputConsentController: PhysicalDeviceInputAuthorizing {
    typealias Present = @MainActor (
        _ request: ConfirmationRequest,
        _ window: NSWindow?,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void

    private let present: Present
    private var decisions: [PhysicalDeviceID: Bool] = [:]
    private var pending: [PhysicalDeviceID: [@MainActor (Bool) -> Void]] = [:]

    init(
        present: @escaping Present = { ConfirmationAlert.ask($0, in: $1, completion: $2) }
    ) {
        self.present = present
    }

    func decision(for deviceID: PhysicalDeviceID) -> Bool? {
        decisions[deviceID]
    }

    func resetDecision(for deviceID: PhysicalDeviceID) {
        guard pending[deviceID] == nil else { return }
        decisions.removeValue(forKey: deviceID)
    }

    func revokeDecision(for deviceID: PhysicalDeviceID) {
        decisions.removeValue(forKey: deviceID)
    }

    func authorize(
        device: PhysicalDevice,
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
            prompt: .controlPhysicalDevice,
            title: L10n.format("Control %@?", device.name),
            message: L10n.string(
                "Threading will be able to tap, swipe and type on this exact iPhone while its pane "
                    + "is visible. Hiding the pane or switching phones revokes control."
            ),
            confirmTitle: L10n.string("Allow Control"),
            style: .warning
        )
        present(request, window) { [weak self] approved in
            guard let self else { return }
            decisions[device.id] = approved
            let completions = pending.removeValue(forKey: device.id) ?? []
            completions.forEach { $0(approved) }
        }
    }
}
