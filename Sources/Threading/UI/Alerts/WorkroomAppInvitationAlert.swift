import AppKit
import ThreadingRemoteKit

// MARK: - Workroom App Invitation

/// A workroom person's invitation to the Threading app, shown as a code to scan.
///
/// A link sent by message is opened by whatever the person taps it in. Pasted into Safari, or
/// tapped where universal links are off, it lands on the web page, whose browser button is for
/// shared chats — the pilot's first invitation went exactly there. The camera hands a scanned
/// `threading://` invitation straight to the app, so the code carries the app's own payload. The
/// copied link stays the web link, which works from anywhere the app is installed.
@MainActor
enum WorkroomAppInvitationAlert {

    static func show(_ url: URL, personName: String, expiresAt: Date, in window: NSWindow?) {
        makeAlert(url, personName: personName, expiresAt: expiresAt).begin(in: window) { _ in }
    }

    /// Built without being run, so a test can read the words, the code and the buttons.
    static func makeAlert(_ url: URL, personName: String, expiresAt: Date) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.format("Invite %@ to the Threading app", personName)
        alert.informativeText = L10n.format(
            "Scan the code with the camera on %@’s phone. Threading opens with only their questions, never anything else on this Mac.",
            personName
        )
        let code = ScannableCodeView(
            payload: scannedPayload(for: url),
            caption: L10n.format("One person · Single use · Accept before %@",
                                 expiresAt.formatted(date: .omitted, time: .shortened)),
            side: WorkroomAppInvitationDefaults.codeSide,
            accessibilityLabel: L10n.string("Invitation code")
        )
        alert.accessoryView = code
        alert.addButton(withTitle: L10n.string("Done"))
        alert.addButton(withTitle: L10n.string("Copy Link"))
        alert.shouldChooseButton = { index in
            guard index == WorkroomAppInvitationDefaults.copyButtonIndex else { return true }
            ShareInvitationText.copy(url)
            code.caption = L10n.string("Link copied. Send it to them; it opens the app when tapped.")
            return false
        }
        return alert
    }

    /// The app's own invitation inside a web link, or the link itself when it carries none.
    static func scannedPayload(for url: URL) -> String {
        RemoteInvitationWebLink.appPayload(from: url.absoluteString) ?? url.absoluteString
    }
}

enum WorkroomAppInvitationDefaults {
    /// Larger than the pairing card's code: an invitation carries a rendezvous credential, so its
    /// symbol has more modules, and it is scanned from across a desk rather than held up close.
    static let codeSide: CGFloat = 260
    static let copyButtonIndex = 1
}
