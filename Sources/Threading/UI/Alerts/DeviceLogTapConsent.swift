import AppKit

@MainActor
protocol DeviceLogTapAuthorizing: AnyObject {
    /// The remembered decision for one chat, or nil when the next request must ask.
    func decision(for sessionID: SessionID) -> Bool?
    func authorize(
        for sessionID: SessionID,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    )
}

/// One explicit decision per chat before Threading hands an agent a tap to link into an app.
///
/// The tap is not a Threading-internal change: it goes into the user's own product and alters what
/// that product publishes. Everything the app prints stops being ephemeral and becomes an `os_log`
/// entry marked public, which persists in the device's log store and leaves the device in a
/// sysdiagnose. Rebuilding without the tap stops new lines but cannot unwrite the ones already
/// written, which is why `ConfirmationPrompt` treats this as a security grant.
///
/// **Scoped to one chat and remembered across launches.** Asking once per app launch was both too
/// often and too broad: it nagged a user who had already decided, while granting every session at
/// once. A chat is the actor that builds, so it is the thing the answer should be about. Denial is
/// remembered too: a refused request must not become repeated prompting when an agent retries.
@MainActor
final class DeviceLogTapConsentController: DeviceLogTapAuthorizing {
    static let shared = DeviceLogTapConsentController()

    private enum Defaults {
        static let key = "deviceLogTapDecisions"
    }

    private var pending: [SessionID: [@MainActor (Bool) -> Void]] = [:]

    func decision(for sessionID: SessionID) -> Bool? {
        stored().decision(for: sessionID)
    }

    func authorize(
        for sessionID: SessionID,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        if let decision = decision(for: sessionID) {
            completion(decision)
            return
        }
        if pending[sessionID] != nil {
            pending[sessionID]?.append(completion)
            return
        }
        pending[sessionID] = [completion]

        let request = ConfirmationRequest(
            prompt: .linkDeviceLogTap,
            title: L10n.string("Let Threading read this app's printed output?"),
            message: L10n.string(
                "Threading will give this chat's agent a small library to link into the app it "
                    + "builds. Everything the app prints then appears in the Device logs pane, and "
                    + "also in the device's own system log, where it stays and can leave the "
                    + "device in a sysdiagnose. Building without it stops new lines but does not "
                    + "remove lines already written.\n\nThis answer is remembered for this chat."
            ),
            confirmTitle: L10n.string("Allow"),
            style: .warning
        )
        ConfirmationAlert.ask(request, in: window) { [weak self] approved in
            guard let self else { return }
            remember(approved, for: sessionID)
            let waiting = pending.removeValue(forKey: sessionID) ?? []
            waiting.forEach { $0(approved) }
        }
    }

    private func stored() -> DeviceLogTapDecisions {
        DeviceLogTapDecisions(
            entries: PreferenceStore.shared.stringArray(forKey: Defaults.key) ?? []
        )
    }

    private func remember(_ approved: Bool, for sessionID: SessionID) {
        var decisions = stored()
        decisions.remember(approved, for: sessionID)
        PreferenceStore.shared.set(decisions.entries, forKey: Defaults.key)
    }
}
