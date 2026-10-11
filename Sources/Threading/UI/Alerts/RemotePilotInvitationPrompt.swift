import AppKit

/// Admission and credential custody stay host-owned; this bounded input is not an extension slot.
@MainActor
enum RemotePilotInvitationPrompt {
    static var request: TextPromptRequest {
        TextPromptRequest(
            title: L10n.string("Join the Hosted Access Pilot"),
            message: L10n.string("Paste the invitation code you received. It can be used for one Mac. Local connections do not need an invitation."),
            confirmTitle: L10n.string("Enable Hosted Access"),
            placeholder: L10n.string("Pilot invitation code"),
            fieldSize: NSSize(width: TextPromptDefaults.commentFieldWidth, height: TextPromptDefaults.fieldHeight)
        )
    }
}
