import Foundation

// MARK: - Mail Wake

/// Starts a dormant chat whose mailbox received mail under a `wake` grant.
///
/// Scheduled messages' wake (`SessionCoordinator+ScheduledMessages.wakeAndDeliver`), with one
/// difference that matters: the opening prompt is the controller's **notice**, never the body,
/// so a peer's words still reach the agent only through `mail_inbox`'s vouched frame. The same
/// refusal holds — a terminal is never typed into unattended — and `MacMailDelivery` only ever
/// asks for native chats.
@MainActor
extension SessionCoordinator {
    func performMailWake(_ event: MailWakeRequested) {
        guard let session = environment.projectStore.session(withID: event.sessionID),
              !session.isArchived, session.usesNativeUI, session.kind.supportsNativeUI else {
            return MacMailDelivery.shared.wakeFinished(event.sessionID, launched: false)
        }
        if environment.agentRuntime.hasTerminal(sessionID: session.id) {
            environment.agentRuntime.discard(sessionID: session.id)
        }
        environment.eventLog.record(.mcp, "Waking a session for mail", ["session": session.id.uuidString])
        let launched = container.launchInBackground(sessionID: session.id, initialPrompt: event.notice)
        MacMailDelivery.shared.wakeFinished(event.sessionID, launched: launched)
    }
}
