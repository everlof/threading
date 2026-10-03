import Foundation
import ThreadingController

// MARK: - Mail Human Turn

/// A person started a new turn in a session, so what it sends next by mail starts a new
/// conversation (`ControllerStore.resetMailContext`).
///
/// Until then a session's acknowledgements carry into what it sends: a blocked `Stop`, a typed
/// notice, a cross-session delivery or a wake all keep an agent going with nobody typing, and the
/// shared chain is what bounds such an exchange. A person's prompt is the one signal that the
/// next message is theirs, not the loop's. Prompts this app wrote — the mail notice and the
/// cross-session provenance header — are recognised and do not count.
@MainActor
enum MailHumanTurn {

    /// The opening of every prompt this app writes into a session on another agent's behalf.
    static let agentPromptPrefixes = [MailHumanTurnDefaults.mailNoticePrefix, MailHumanTurnDefaults.crossSessionPrefix]

    static func isAgentOriginated(_ prompt: String) -> Bool {
        let opening = prompt.drop { $0.isWhitespace }
        return agentPromptPrefixes.contains { opening.hasPrefix($0) }
    }

    /// A terminal's reported turn start; a missing prompt changes nothing (the bound stays).
    static func turnStarted(_ sessionID: SessionID, prompt: String?) {
        guard let prompt, !prompt.isEmpty, !isAgentOriginated(prompt) else { return }
        started(sessionID)
    }

    /// A person submitted a prompt (a native chat's composer, or a paired phone).
    static func started(_ sessionID: SessionID, mailbox: MacMailbox = .shared, mailboxes: RemoteSessionMailboxes = .shared) {
        if let binding = mailboxes.binding(for: sessionID) {
            let rpc = RemoteControllerRPC(endpoint: binding.endpoint, runner: mailboxes.runner,
                                          timeout: RemoteControllerRPCDefaults.launchTimeout)
            Task {
                // Best effort: a host that cannot be reached keeps the bound, which is the safe side.
                let _: [String: String]? = try? await rpc.owner("mail-context-reset", [.init(value: binding.address.description)])
            }
        } else {
            Task { try? await mailbox.resetContext(for: sessionID) }
        }
    }
}

enum MailHumanTurnDefaults {
    static let mailNoticePrefix = MailNoticeWords.prefix
    /// `WorkspaceControlPlane.provenancePrefixed` opens every cross-session delivery with this.
    static let crossSessionPrefix = "[Cross-session message from "
}
