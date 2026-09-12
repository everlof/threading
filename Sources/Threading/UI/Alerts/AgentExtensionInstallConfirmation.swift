import AppKit

/// Host-owned consent: the persistent choice is authority for one chat, not prompt suppression.
@MainActor
enum AgentExtensionInstallConfirmation {
    static func request(
        from request: ConfirmationRequest,
        agentName: String
    ) -> ChoiceRequest {
        ChoiceRequest(
            prompt: request.prompt,
            title: request.title,
            message: request.message + "\n\n" + L10n.format(
                "Allow all installs from this agent trusts only the chat “%@” to install and "
                    + "update extensions, including future capability changes, without asking "
                    + "again. This lasts across restarts until you revoke it in Settings → "
                    + "Extensions → Trusted agents. New extensions remain disabled.",
                String(agentName.prefix(AgentExtensionInstallTrustStore.maximumNameLength))
            ),
            options: [
                ConfirmationOption(title: request.confirmTitle),
                ConfirmationOption(title: L10n.string("Allow all installs from this agent"))
            ],
            cancelTitle: request.cancelTitle,
            style: request.style,
            accessory: request.accessory
        )
    }
}
