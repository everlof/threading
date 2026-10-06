import Foundation
import ThreadingController

// MARK: - Mail Agent Command Service

/// The four mail tools on this Mac's server: `mail_send`, `mail_inbox`, `mail_ack`,
/// `mail_directory`. `AgentToolCoordinator` only forwards to this service.
///
/// Scope is the control plane's (`WorkspaceControlPlane.admitMail`): a session may write to the
/// sessions of its own project, and an out-of-scope session answers exactly like one that does
/// not exist. Another host's recipient is queued for that host, whose own grants decide when it
/// arrives. Storage, idempotency, chains and fuses are the controller store's. This file owns the
/// words only.
@MainActor
final class MailAgentCommandService {

    private let control: WorkspaceControlPlane
    private let projects: ProjectStore
    private let mailbox: MacMailbox
    private let arrived: @MainActor (SessionID, MailPriority) -> Void
    private let queuedForHost: @MainActor (HostID) -> Void
    private let hostMailbox: @MainActor (SessionID) -> MailAddress?
    private let sessionForHostAddress: @MainActor (MailAddress) -> SessionID?

    init(
        control: WorkspaceControlPlane,
        projects: ProjectStore,
        mailbox: MacMailbox,
        arrived: @escaping @MainActor (SessionID, MailPriority) -> Void = {
            MacMailDelivery.shared.arrived(for: $0, priority: $1)
        },
        queuedForHost: @escaping @MainActor (HostID) -> Void = { MacMailSync.shared.kick(host: $0) },
        hostMailbox: @escaping @MainActor (SessionID) -> MailAddress? = {
            RemoteSessionMailboxes.shared.binding(for: $0)?.address
        },
        sessionForHostAddress: @escaping @MainActor (MailAddress) -> SessionID? = {
            RemoteSessionMailboxes.shared.session(forAddress: $0)
        }
    ) {
        self.hostMailbox = hostMailbox
        self.sessionForHostAddress = sessionForHostAddress
        self.control = control
        self.projects = projects
        self.mailbox = mailbox
        self.arrived = arrived
        self.queuedForHost = queuedForHost
    }

    // MARK: Sending

    func send(
        _ arguments: MailSendArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let text = WorkspaceControlPlane.sanitized(arguments.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return completion(.failure(ControlRefusal.messageEmpty.toolWords)) }

        let id: UUID
        if let raw = arguments.id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = UUID(uuidString: raw) else {
                return completion(.failure("id must be a UUID you chose for this message, or omitted."))
            }
            id = parsed
        } else {
            id = UUID()
        }

        var replyTo: UUID?
        if let raw = arguments.replyTo?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = UUID(uuidString: raw) else {
                return completion(.failure("reply_to must be a message id exactly as mail_inbox printed it."))
            }
            replyTo = parsed
        }

        let priority: MailPriority
        switch (arguments.priority ?? "normal").lowercased() {
        case "normal": priority = .normal
        case "interrupt": priority = .interrupt
        default:
            return completion(.failure("priority is \"normal\" or \"interrupt\"."))
        }

        let raw = (arguments.to ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mailbox = mailbox
        let control = control
        let senderName = Self.mailTitle(of: sessionID, projects: projects)

        Task { @MainActor in
            do {
                let localHost = try await mailbox.host()
                guard let target = Self.mailTarget(raw, localHost: localHost.id) else {
                    return completion(.failure(Self.unknownRecipientWords))
                }
                let recipient: MailAddress
                var localTarget: SessionID?
                switch target {
                case .session(let targetID):
                    switch control.admitMail(to: targetID, from: .agentSession(sessionID)) {
                    case .failure(.targetUnknown):
                        return completion(.failure(Self.unknownRecipientWords))
                    case .failure(let refusal):
                        return completion(.failure(refusal.toolWords))
                    case .success(let row):
                        if let hosted = self.hostMailbox(targetID) {
                            // The sibling's mailbox lives on its host: queue for that host, whose
                            // `<macHost>/*` grant stands for this plane's admission just made.
                            recipient = hosted
                        } else {
                            recipient = try await mailbox.register(targetID, name: row.title)
                            localTarget = targetID
                        }
                    }
                case .remote(let address):
                    // An address that is one of this Mac's own sessions on its host is still
                    // that session: the same scope rule applies, whatever spelling was used.
                    if let hostedSession = self.sessionForHostAddress(address) {
                        switch control.admitMail(to: hostedSession, from: .agentSession(sessionID)) {
                        case .failure(.targetUnknown): return completion(.failure(Self.unknownRecipientWords))
                        case .failure(let refusal): return completion(.failure(refusal.toolWords))
                        case .success: break
                        }
                    }
                    recipient = address
                }
                let message = try await mailbox.send(
                    from: sessionID, senderName: senderName, to: recipient, id: id, text: text,
                    replyTo: replyTo, priority: priority, ownerAdmitted: localTarget != nil
                )
                if let localTarget {
                    self.arrived(localTarget, priority)
                } else {
                    self.queuedForHost(recipient.host)
                }
                completion(.success(Self.sentWords(message, local: localTarget != nil)))
            } catch let failure as MacMailbox.Failure {
                completion(.failure(Self.mailWords(for: failure)))
            } catch {
                completion(.failure(Self.mailWords(for: .unavailable(MacMailbox.describe(error)))))
            }
        }
    }

    // MARK: Reading

    func inbox(
        _ arguments: MailInboxArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let after = max(arguments.after ?? 0, 0)
        let mailbox = mailbox
        let name = Self.mailTitle(of: sessionID, projects: projects)
        Task { @MainActor in
            do {
                let page = try await mailbox.inbox(for: sessionID, name: name, after: after, limit: MacMailDefaults.inboxPage)
                completion(.success(Self.inboxWords(page, after: after)))
            } catch let failure as MacMailbox.Failure {
                completion(.failure(Self.mailWords(for: failure)))
            } catch {
                completion(.failure(Self.mailWords(for: .unavailable(MacMailbox.describe(error)))))
            }
        }
    }

    func acknowledge(
        _ arguments: MailAckArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let raw = arguments.ids ?? []
        let ids = raw.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !raw.isEmpty, ids.count == raw.count, ids.count <= MacMailToolDefaults.maximumAcknowledgements else {
            return completion(.failure("""
                ids must be 1 to \(MacMailToolDefaults.maximumAcknowledgements) message ids, exactly as \
                mail_inbox printed them.
                """))
        }
        let mailbox = mailbox
        let name = Self.mailTitle(of: sessionID, projects: projects)
        Task { @MainActor in
            do {
                let acknowledged = try await mailbox.acknowledge(for: sessionID, name: name, ids: ids)
                completion(.success("Acknowledged \(acknowledged.count) message\(acknowledged.count == 1 ? "" : "s")."))
            } catch let failure as MacMailbox.Failure {
                completion(.failure(Self.mailWords(for: failure)))
            } catch {
                completion(.failure(Self.mailWords(for: .unavailable(MacMailbox.describe(error)))))
            }
        }
    }

    func directory(
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let siblings: [ControlSessionOverview]
        switch control.sessions(for: .agentSession(sessionID)) {
        case .failure(let refusal): return completion(.failure(refusal.toolWords))
        case .success(let rows): siblings = rows.filter { !$0.isCaller }
        }
        let mailbox = mailbox
        let name = Self.mailTitle(of: sessionID, projects: projects)
        Task { @MainActor in
            do {
                let own = try await mailbox.register(sessionID, name: name)
                let contacts = try await mailbox.storeDirectory(for: sessionID, name: name)
                let hosted = Dictionary(uniqueKeysWithValues: siblings.compactMap { row in
                    self.hostMailbox(row.id).map { (row.id, $0) }
                })
                completion(.success(Self.directoryWords(own: own, siblings: siblings, contacts: contacts, hosted: hosted)))
            } catch let failure as MacMailbox.Failure {
                completion(.failure(Self.mailWords(for: failure)))
            } catch {
                completion(.failure(Self.mailWords(for: .unavailable(MacMailbox.describe(error)))))
            }
        }
    }

    // MARK: - Resolution

    enum MailTarget: Equatable {
        case session(SessionID)
        case remote(MailAddress)
    }

    /// A bare Threading id, or an address. A worker on this Mac does not exist, so it is unknown.
    nonisolated static func mailTarget(_ raw: String, localHost: HostID) -> MailTarget? {
        if let id = SessionID(uuidString: raw) { return .session(id) }
        guard let address = try? MailAddress(raw) else { return nil }
        guard address.host == localHost else { return .remote(address) }
        return address.kind == .session ? .session(SessionID(address.id)) : nil
    }

    // MARK: - Wording

    nonisolated static let unknownRecipientWords = """
        No mailbox with that address is reachable from here. mail_directory lists every address \
        this session can write to: this project's sessions, and any agent the user has granted \
        or named.
        """

    nonisolated static func mailWords(for failure: MacMailbox.Failure) -> String {
        switch failure {
        case .unavailable(let reason):
            return "This Mac's mailbox is unavailable (\(reason)), so nothing was sent or read. The user can see why in Threading's event log."
        case .refused(let error):
            switch error {
            case .invalidInput(let field):
                switch field {
                case "unknown_host", "mail_address", "mail_recipient": return unknownRecipientWords
                case "chain_limit":
                    return "This conversation between agents has reached its \(MailLimits.chainMessages)-message limit."
                case "send_rate":
                    return "This session has sent \(MailLimits.sendsPerMinute) messages in the last minute. Wait before sending more."
                case "inbox_full":
                    return "The recipient already has \(MailLimits.openInbox) unread messages; it is not reading its mail."
                case "mail_text":
                    return "The message is over 32 KiB. Send the conclusion, not the transcript."
                case "ids":
                    return "ids must be 1 to \(MacMailToolDefaults.maximumAcknowledgements) message ids."
                default:
                    return "The mailbox refused the request (\(field))."
                }
            case .conflict:
                return "A different message was already sent under that id. Choose a new id for new content."
            case .forbidden:
                return "That is not yours to answer or acknowledge: reply_to and mail_ack take ids of mail this session received."
            case .notFound:
                return "No message with that id is in this session's mail."
            case .unsupportedSchema, .storage:
                return "This Mac's mailbox is unavailable (\(error.description)), so nothing was changed."
            }
        }
    }

    nonisolated static func sentWords(_ message: MailMessage, local: Bool) -> String {
        let id = message.envelope.id.uuidString.lowercased()
        let urgent = message.envelope.priority == .interrupt ? " It is marked urgent." : ""
        if local {
            return """
                Stored in the recipient's mailbox as message \(id).\(urgent) If it is busy it is told \
                only that mail is waiting; it reads the text with mail_inbox, and a reply arrives in \
                this session's own mailbox.
                """
        }
        return """
            Queued as message \(id) for its host, which receives it the next time this Mac reaches \
            that host; that host's own grants decide whether it is accepted.\(urgent) A refusal \
            comes back as a bounce, never silently.
            """
    }

    nonisolated static func inboxWords(_ page: ControllerPage<MailInboxItem>, after: Int64) -> String {
        guard !page.items.isEmpty else {
            return after == 0 ? "No unacknowledged mail." : "No more unacknowledged mail after \(after)."
        }
        var blocks = page.items.map { item in
            "\(item.header)\n\(item.message.envelope.text)"
        }
        blocks.append("""
            next: \(page.next) — pass it as after for the next page. Acknowledge what you acted on \
            with mail_ack.
            """)
        return blocks.joined(separator: "\n\n———\n\n")
    }

    nonisolated static func directoryWords(
        own: MailAddress,
        siblings: [ControlSessionOverview],
        contacts: [MailContact],
        hosted: [SessionID: MailAddress] = [:]
    ) -> String {
        var lines = ["This session's address: \(own)"]
        if siblings.isEmpty && contacts.isEmpty {
            lines.append("Nobody else is reachable by mail from here yet.")
            return lines.joined(separator: "\n")
        }
        if !siblings.isEmpty {
            lines.append("Sessions in this project (notify):")
            for row in siblings {
                let address = hosted[row.id] ?? MailAddress(host: own.host, kind: .session, id: row.id.rawValue)
                lines.append("• “\(row.title)” — \(address)")
            }
        }
        if !contacts.isEmpty {
            lines.append("Granted or named by the user:")
            for contact in contacts {
                let mode = contact.mode.map { " (\($0.rawValue))" } ?? ""
                let name = WorkspaceControlPlane.safeHeaderTitle(contact.name)
                lines.append("• “\(name)” — \(contact.address)\(mode)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func mailTitle(of sessionID: SessionID, projects: ProjectStore) -> String {
        projects.session(withID: sessionID)?.displayTitle ?? MacMailDefaults.unnamedSession
    }
}

enum MacMailToolDefaults {
    static let maximumAcknowledgements = 100
}
