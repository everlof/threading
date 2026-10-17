import AppKit

// MARK: - Workroom Opening Sheet

/// The sheet an agent's `workroom_request_opening` is put to the user in. Opening a room makes
/// its questions reachable from the internet by one named person, so the sheet says exactly
/// that: which room, which person (and whether the agent made that person up), how many
/// questions are waiting, which tunnel carries it and that its provider can read the traffic,
/// for how long, and — labelled as the agent's words — why.
///
/// Native on purpose: agents can drive Threading's own browser, so an approval on a web page
/// would be one they could click themselves.
@MainActor
enum WorkroomOpeningSheet {

    typealias Facts = WorkroomOpeningFacts

    static func ask(in window: NSWindow, facts: Facts) async -> Bool {
        await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(request(facts), in: window) { approved in continuation.resume(returning: approved) }
        }
    }

    static func request(_ facts: Facts) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .approveWorkroomOpening,
            title: L10n.format("Open “%@” to %@?", facts.roomTitle, facts.personName),
            message: message(facts),
            confirmTitle: L10n.string("Open Room"),
            cancelTitle: L10n.string("Don’t Open")
        )
    }

    static func message(_ facts: Facts) -> String {
        var lines: [String] = []
        lines.append(L10n.format("Room: “%@” in %@", facts.roomTitle, facts.projectName))
        let person = L10n.format("Person: %@ (%@, %@)", facts.personName, facts.handle, facts.language)
        lines.append(facts.proposedByAgent ? person + " — " + L10n.string("new, proposed by the agent") : person)
        lines.append(L10n.format("Questions waiting for them: %d", facts.openQuestions))
        let address = facts.provider == .ngrok
            ? (facts.domain.map { L10n.format("ngrok at %@", $0) } ?? L10n.string("ngrok, at the address your account assigns"))
            : L10n.string("a Cloudflare Quick Tunnel, whose address changes whenever Threading restarts")
        lines.append(L10n.format("Reached through %@. The tunnel provider terminates the connection and can read what passes through it.",
                                 address))
        lines.append(L10n.format("Open for %d days. You can close it any time in Settings ▸ Workrooms.", facts.days))
        lines.append(L10n.format("The agent’s reason: “%@”", facts.reason))
        lines.append(L10n.string("They will see only the questions addressed to them in this room, and answer through a link you send them."))
        return lines.joined(separator: "\n\n")
    }

    /// After an approval: where the user copies the person's link once the tunnel is up.
    static func revealSettings() {
        let controller = NSApp.windows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        controller?.showSettingsPage(id: SettingsPages.workroomsID)
    }
}
