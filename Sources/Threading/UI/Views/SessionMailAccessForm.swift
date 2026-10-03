import AppKit
import ThreadingController

// MARK: - Session Mail Access Form

/// The Info panel's grant, revoke and contact forms for one session's mailbox.
///
/// Each form is the confirmation itself: an always-asked `ConfirmationAlert`
/// (`.changeMailAccess`) whose accessory holds the fields, so nothing changes until the person
/// reads the sender, the session and the mode together and confirms. Built from `ThemedTextField`
/// and `ThemedPopUp` inside a structural stack; the alert owns focus, Escape and theming.
@MainActor
final class SessionMailAccessForm {

    private let sessionID: SessionID
    private let window: () -> NSWindow?
    private let changed: () -> Void
    var service: MailAccessService = .shared

    init(sessionID: SessionID, window: @escaping () -> NSWindow?, changed: @escaping () -> Void) {
        self.sessionID = sessionID
        self.window = window
        self.changed = changed
    }

    private var sessionTitle: String {
        ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? MacMailDefaults.unnamedSession
    }

    // MARK: - Grant

    /// The grant form's fields, exposed for tests.
    struct GrantFields {
        let sender: ThemedTextField
        let mode: ThemedPopUp
        let view: NSView
    }

    static func grantFields() -> GrantFields {
        let sender = ThemedTextField(string: "")
        sender.placeholderString = L10n.string("<host>/session/<id>, <host>/worker/<id> or <host>/*")
        sender.setAccessibilityLabel(L10n.string("Sender"))
        let mode = ThemedPopUp()
        for option in MailAccessService.offeredModes {
            mode.addItem(withTitle: SessionMailPresentation.words(for: option))
        }
        mode.selectItem(at: 0)
        mode.setAccessibilityLabel(L10n.string("Access"))
        return GrantFields(sender: sender, mode: mode, view: stack([sender, mode]))
    }

    func presentGrant() {
        let fields = Self.grantFields()
        let title = sessionTitle
        ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .changeMailAccess,
            title: L10n.format("Who may write to “%@”?", title),
            message: L10n.string("""
                Name an agent’s mail address, or a whole host as <host>/*. “Can write and wake” \
                also lets that agent’s mail start this chat when it is not running, which spends \
                its usage. Agents cannot change this.
                """),
            confirmTitle: L10n.string("Grant"),
            accessory: fields.view
        ), in: window()) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let index = max(fields.mode.indexOfSelectedItem, 0)
            let mode = MailAccessService.offeredModes[min(index, MailAccessService.offeredModes.count - 1)]
            self.apply { try await self.service.setGrant(
                sessionID: self.sessionID, name: title, sender: fields.sender.stringValue, mode: mode
            ) }
        }
    }

    func presentRevoke(sender: String) {
        let title = sessionTitle
        ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .changeMailAccess,
            title: L10n.format("Revoke %@?", sender),
            message: L10n.format("Mail from it to “%@” will be refused from now on. Mail already received stays.", title),
            confirmTitle: L10n.string("Revoke")
        ), in: window()) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.apply { try await self.service.setGrant(sessionID: self.sessionID, name: title, sender: sender, mode: nil) }
        }
    }

    // MARK: - Contact

    func presentContact() {
        let address = ThemedTextField(string: "")
        address.placeholderString = L10n.string("<host>/session/<id> or <host>/worker/<id>")
        address.setAccessibilityLabel(L10n.string("Address"))
        let name = ThemedTextField(string: "")
        name.placeholderString = L10n.string("Name")
        name.setAccessibilityLabel(L10n.string("Name"))
        ConfirmationAlert.ask(ConfirmationRequest(
            prompt: .changeMailAccess,
            title: L10n.string("Add a contact"),
            message: L10n.string("""
                The address appears in this chat’s mail directory. Listing it grants nothing: \
                the recipient’s own host still decides whether mail is accepted.
                """),
            confirmTitle: L10n.string("Add"),
            accessory: Self.stack([address, name])
        ), in: window()) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.apply { try await self.service.addContact(
                for: self.sessionID, address: address.stringValue, name: name.stringValue
            ) }
        }
    }

    // MARK: - Private

    private func apply(_ change: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do {
                try await change()
                self?.changed()
            } catch {
                self?.report(error)
            }
        }
    }

    private func report(_ error: any Error) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Mail access was not changed")
        switch error as? MailAccessService.Failure {
        case .invalidSender:
            alert.informativeText = L10n.string("That is not a mail address, a host as <host>/*, or *.")
        case .invalidAddress:
            alert.informativeText = L10n.string("That is not a mail address.")
        case .unavailable(let reason):
            alert.informativeText = reason
        case nil:
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = window() { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }

    private static func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.frame = NSRect(x: 0, y: 0, width: SessionMailAccessDefaults.formWidth, height: 1)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: SessionMailAccessDefaults.formWidth).isActive = true
        }
        return stack
    }
}

enum SessionMailAccessDefaults {
    static let formWidth: CGFloat = 320
}
