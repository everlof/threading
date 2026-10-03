import Foundation
import ThreadingController

// MARK: - Mail Access Service

/// The owner's grants and contacts for a session's mailbox — who may leave mail for it, who may
/// wake it, and which remote addresses it can see in `mail_directory`.
///
/// Host-owned: no MCP tool reaches this type, so an agent can neither grant itself access nor
/// widen anyone else's. Every change comes from the session's Info panel behind an always-asked
/// confirmation (`ConfirmationPrompt.changeMailAccess`). Changes go to the store that holds the
/// session's mailbox: this Mac's, or the host controller's for a session whose mailbox lives on
/// its remote host (`RemoteSessionMailboxes`), over owner SSH.
@MainActor
final class MailAccessService {

    enum Failure: Error, Equatable {
        /// The sender is not an address, `<host>/*` or `*`.
        case invalidSender
        case invalidAddress
        case unavailable(String)
    }

    /// The modes the editor offers. `ask` is a worker's blocking question and has no meaning
    /// for an interactive session, so it is not offered here.
    static let offeredModes: [MailMode] = [.notify, .wake]

    static let shared = MailAccessService()

    var mailbox: MacMailbox = .shared
    var mailboxes: RemoteSessionMailboxes = .shared
    var runner: (any RemoteHostCommandRunning)?

    // MARK: - Validation

    /// Accepts exactly what the controller's grant pattern accepts.
    static func validSender(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" { return trimmed }
        if trimmed.hasSuffix("/*") { return (try? HostID(String(trimmed.dropLast(2)))) == nil ? nil : trimmed }
        return (try? MailAddress(trimmed)).map(\.description)
    }

    // MARK: - Grants

    func grants(for sessionID: SessionID, name: String) async throws -> [MailGrant] {
        do {
            if let binding = mailboxes.binding(for: sessionID) {
                let page: ControllerPage<MailGrant> = try await rpc(binding).owner(
                    "mail-grants", [.init(value: binding.address.description)]
                )
                return page.items
            }
            return try await mailbox.grants(for: sessionID, name: name)
        } catch {
            throw Failure.unavailable(RemoteControllerRPC.describe(error))
        }
    }

    /// Sets (or, with a nil mode, revokes) one sender's access to the session's mailbox.
    func setGrant(sessionID: SessionID, name: String, sender: String, mode: MailMode?) async throws {
        guard let sender = Self.validSender(sender) else { throw Failure.invalidSender }
        do {
            if let binding = mailboxes.binding(for: sessionID) {
                let rpc = rpc(binding)
                let page: ControllerPage<MailGrant> = try await rpc.owner("mail-grants", [.init(value: binding.address.description)])
                let prior = page.items.first { $0.sender == sender }
                let _: MailGrant = try await rpc.owner("mail-grant-set", [
                    .init(value: binding.address.description), .init(value: sender),
                    .init(value: String(prior?.revision ?? 0)), .init(value: mode?.rawValue ?? "none"),
                    .init(value: MailPriority.normal.rawValue)
                ])
                return
            }
            let recipient = try await mailbox.register(sessionID, name: name)
            try await mailbox.ensureGrant(recipient: recipient, sender: sender, mode: mode)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable(RemoteControllerRPC.describe(error))
        }
    }

    // MARK: - Contacts

    /// Names a remote address in the directory of the store holding this session's mailbox.
    /// Listing confers nothing: the recipient's host still decides.
    func addContact(for sessionID: SessionID, address text: String, name: String) async throws {
        guard let address = try? MailAddress(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.invalidAddress
        }
        let name = MacMailbox.mailboxName(name)
        do {
            if let binding = mailboxes.binding(for: sessionID) {
                let _: MailContact? = try await rpc(binding).owner("mail-contact-set", [
                    .init(value: address.description), .init(value: name)
                ])
                return
            }
            try await mailbox.setContact(address, name: name)
        } catch {
            throw Failure.unavailable(RemoteControllerRPC.describe(error))
        }
    }

    private func rpc(_ binding: RemoteSessionMailboxes.Binding) -> RemoteControllerRPC {
        RemoteControllerRPC(endpoint: binding.endpoint, runner: runner ?? mailboxes.runner)
    }
}
