import Foundation

/// A Claude background hook holds one request here until mail arrives. Its exit code, rather
/// than terminal keystrokes, wakes the provider. Only a host-authored notice crosses this path.
///
/// Normal size is a handful of live terminal sessions; the hard ceiling is 512 watchers. A
/// replacement retires the previous hook, disconnect removes its watcher, and arrival touches
/// only its recipient. Bursts share one mailbox query. SQLite stays on the mailbox actor.
@MainActor
final class MailIdleWake {
    struct Watcher {
        let connection: ObjectIdentifier
        let respond: @Sendable (HTTPResponse) -> Void
    }

    static let shared = MailIdleWake(mailbox: .shared)
    static let maximumWatchers = 512

    private let mailbox: MacMailbox
    private let eligible: @MainActor (SessionID) -> Bool
    private var watchers: [SessionID: Watcher] = [:]
    private var sessionsByConnection: [ObjectIdentifier: SessionID] = [:]
    private var pending: Set<SessionID> = []
    private var changedWhilePending: Set<SessionID> = []

    init(mailbox: MacMailbox, eligible: @escaping @MainActor (SessionID) -> Bool = isEligible) {
        self.mailbox = mailbox
        self.eligible = eligible
    }

    static func isEligible(_ sessionID: SessionID) -> Bool {
        guard MCPToolCatalog.isEnabled(MCPToolCatalog.workspace),
              let session = ProjectStore.shared.session(withID: sessionID),
              !session.isArchived, !session.usesNativeUI,
              session.kind.supports(.rewakingMailHooks),
              ProjectStore.shared.project(forSessionID: sessionID)?.executionHost == nil else { return false }
        return true
    }

    /// SessionStart, UserPromptSubmit and Stop renew the single background hook. Renewal also
    /// recovers after an interrupted wake, when the provider did not run its Stop hooks.
    func watch(_ sessionID: SessionID, connection: ObjectIdentifier,
               respond: @escaping @Sendable (HTTPResponse) -> Void) {
        guard eligible(sessionID), watchers[sessionID] != nil || watchers.count < Self.maximumWatchers else {
            return respond(.status(204, "No Content"))
        }
        if let previous = remove(sessionID) { previous.respond(.status(204, "No Content")) }
        watchers[sessionID] = Watcher(connection: connection, respond: respond)
        sessionsByConnection[connection] = sessionID
        arrived(for: sessionID)
    }

    func disconnected(_ connection: ObjectIdentifier) {
        guard let sessionID = sessionsByConnection[connection] else { return }
        _ = remove(sessionID)
    }

    func arrived(for sessionID: SessionID) {
        guard watchers[sessionID] != nil else { return }
        guard pending.insert(sessionID).inserted else {
            changedWhilePending.insert(sessionID)
            return
        }
        Task { @MainActor in
            defer {
                pending.remove(sessionID)
                if changedWhilePending.remove(sessionID) != nil { arrived(for: sessionID) }
            }
            guard watchers[sessionID] != nil else { return }
            guard eligible(sessionID) else {
                remove(sessionID)?.respond(.status(204, "No Content"))
                return
            }
            // Share the store's one continuation opportunity with Stop. SessionStart may have
            // already announced mail without starting a model turn, so an inbox-only notice
            // would lose the wake. Conversely, rearming must not keep waking for unacked mail.
            guard let notice = await mailbox.notice(for: sessionID, event: .stop),
                  let watcher = remove(sessionID) else { return }
            guard eligible(sessionID) else { return watcher.respond(.status(204, "No Content")) }
            watcher.respond(HTTPResponse(status: 200, reason: "OK", contentType: "text/plain",
                                         body: Data(notice.utf8)))
        }
    }

    private func remove(_ sessionID: SessionID) -> Watcher? {
        guard let watcher = watchers.removeValue(forKey: sessionID) else { return nil }
        sessionsByConnection.removeValue(forKey: watcher.connection)
        return watcher
    }
}

/// Claude's supported asyncRewake contract: a background command exits 2 with a reminder.
/// The provider owns waking its existing conversation and preserving its prompt editor.
enum MailIdleWakeHook {
    static let events = ["SessionStart", "UserPromptSubmit", "Stop"]
    static let path = "/mail-idle-wake"
    // Keep below the provider's signed 32-bit millisecond timer limit. Every prompt and stop
    // renews this; a terminal left completely idle for 24 days falls back to ordinary hooks.
    static let timeoutSeconds = 2_073_600

    static func entry() -> [String: Any] {
        ["hooks": [["type": "command", "command": command(),
                    "async": true, "asyncRewake": true, "timeout": timeoutSeconds]]]
    }

    static func command() -> String {
        let reply = "threading_wake_reply"
        let token = "$\(MCPDefaults.sessionTokenEnvironmentKey)"
        let socket = "$\(MCPDefaults.socketEnvironmentKey)"
        let port = "$\(MCPDefaults.portEnvironmentKey)"
        // Unlike a brief notice hook, this shell and curl may live for days. The token must
        // appear in neither process's arguments: inherit it and pass the header over stdin.
        let authenticatedPost = "printf 'header = \"Authorization: Bearer %s\"\\n' \"\(token)\" | "
            + "curl --config - -fs --connect-timeout 2 --max-time \(timeoutSeconds - 1) --data-binary '{}'"
        let post = "( { [ -n \"\(socket)\" ] && \(authenticatedPost) "
            + "--unix-socket \"\(socket)\" \"\(MCPDefaults.socketURLBase)\(path)\"; } "
            + "|| { [ -n \"\(port)\" ] && \(authenticatedPost) "
            + "\"http://\(MCPDefaults.host):\(port)\(path)\"; } )"
        // A held connection costs no polling while the app is up. Retry only transport failure:
        // the stable socket survives app relaunches, and a 204 retires a superseded watcher.
        return "cat >/dev/null; [ -n \"\(token)\" ] || exit 0; threading_wake_delay=2; "
            + "while :; do \(reply)=$(\(post) 2>/dev/null) && { "
            + "[ -z \"$\(reply)\" ] && exit 0; printf '%s' \"$\(reply)\"; exit 2; }; "
            + "sleep \"$threading_wake_delay\"; "
            + "[ \"$threading_wake_delay\" -ge 32 ] || threading_wake_delay=$((threading_wake_delay * 2)); done"
    }
}
