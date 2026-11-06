import AppKit
import ThreadingController

/// The owner extends a specific invitation, never a replacement token or a room grant.
/// The Settings row and command palette share this operation and its native confirmation.
@MainActor
enum WorkroomLinkExtension {
    struct Target: Sendable {
        let person: WorkroomPerson
        let invitation: WorkroomInvitation
    }

    static func start(target: Target? = nil, in window: NSWindow?) {
        Task {
            do {
                let store = try await MacMailbox.shared.controllerStore()
                let targets: [Target]
                if let target { targets = [target] }
                else { targets = try await candidates(in: store) }
                guard !targets.isEmpty else {
                    showMessage(L10n.string("No unused invitation links are available to extend."), in: window)
                    return
                }
                present(targets: targets, store: store, in: window)
            } catch {
                showMessage(WorkroomAgentCommandService.words(for: error), in: window)
            }
        }
    }

    /// Same bounded people slice as Settings; each invitation is one indexed latest-row read.
    static func candidates(in store: ControllerStore) async throws -> [Target] {
        let people = try await store.workroomPeople(limit: WorkroomsPageDefaults.people)
        var targets: [Target] = []
        for person in people.items {
            if let invitation = try await store.latestWorkroomInvitation(person: person.id), invitation.state == .pending {
                targets.append(Target(person: person, invitation: invitation))
            }
        }
        return targets
    }

    static func present(targets: [Target], store: ControllerStore, in window: NSWindow?,
                        completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard !targets.isEmpty else { completion(false); return }
        let (request, picker) = Self.request(targets: targets)
        ConfirmationAlert.ask(request, in: window) { approved in
            guard approved, targets.indices.contains(picker.indexOfSelectedItem) else { completion(false); return }
            let target = targets[picker.indexOfSelectedItem]
            Task {
                do {
                    _ = try await store.extendWorkroomInvitation(
                        person: target.person.id, invitationID: target.invitation.id,
                        expectedExpiry: target.invitation.expiresAt
                    )
                    NotificationCenter.default.post(WorkroomStatusDidChange())
                    completion(true)
                } catch {
                    showMessage(L10n.string("The link could not be extended. It may have been used, replaced or changed. Refresh Workrooms and try again."), in: window)
                    completion(false)
                }
            }
        }
    }

    static func request(targets: [Target]) -> (ConfirmationRequest, ThemedPopUp) {
        let picker = ThemedPopUp()
        SettingsUI.preferControlWidth(picker, width: SettingsUIDefaults.controlWidth)
        picker.setAccessibilityLabel(L10n.string("Invitation link"))
        for target in targets {
            let expiry = ISO8601DateFormatter().date(from: target.invitation.expiresAt)
                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? target.invitation.expiresAt
            picker.addItem(withTitle: L10n.format("%@ · expires %@", target.person.name, expiry))
        }
        picker.selectItem(at: 0)
        let request = ConfirmationRequest(
            prompt: .extendWorkroomInvitation,
            title: L10n.string("Extend Workroom Link"),
            message: L10n.string("Add seven days to this unused link’s expiry, or seven days from now if it has expired. The same link will work once. Room closing dates and signed-in browsers are unchanged."),
            confirmTitle: L10n.string("Extend Link"),
            accessory: SettingsUI.row(title: "Invitation link", control: picker)
        )
        return (request, picker)
    }

    private static func showMessage(_ message: String, in window: NSWindow?) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Extend Workroom Link")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) { _ in } }
        else { alert.runModal() }
    }
}
