import Foundation
import ThreadingRemoteKit

/// The in-app demo: a canned Mac, reachable from the welcome screen, that drives the real
/// remote pipeline with fixture data.
///
/// It exists for two audiences at once. App Review runs this app with no Mac reachable, so
/// something must be demonstrable standalone (releasing.md, "Releasing beside the iOS
/// companion"); and a person who installs the phone app before the Mac app deserves a taste
/// instead of a dead end. One mechanism serves both.
///
/// The fake stops at the lowest layer that can carry it: `DemoSessionScript` synthesizes the
/// same type-tagged JSON the Mac's WebSocket sends and feeds it through the connection's real
/// message handler, so hello handling, snapshot application, and submit acknowledgements all
/// run the production path. Only the socket is skipped — which is what keeps the demo from
/// quietly drifting away from real behavior as the protocol grows.
@MainActor
enum DemoExperience {

    /// `.invalid` is reserved by RFC 2606, so this host can never resolve anywhere real — and
    /// it is the marker `RemoteSessionConnection.connect()` routes to a script instead of a
    /// socket.
    static let sentinelHost = "demo.threading.invalid"

    static var link: RemoteConnectionLink {
        RemoteConnectionLink(string: "https://\(sentinelHost)/#demo")!
    }

    static func isDemo(link: RemoteConnectionLink) -> Bool {
        link.baseURL.host == sentinelHost
    }

    /// The host row the dashboard shows while the demo is active. Deliberately not written to
    /// `RemoteHostStore`: the demo owns no credential and should not survive as a keychain
    /// record that outlives the run.
    static var pairedHost: PairedRemoteHost {
        PairedRemoteHost(
            id: "demo",
            hostID: "demo",
            shareID: "demo",
            scope: "all",
            name: MobileL10n.string("Demo Mac"),
            link: link,
            lastConnectedAt: Date()
        )
    }
}

/// Plays the Mac's half of one session socket.
///
/// `begin` delivers the same opening the real server sends — `hello`, then the conversation
/// snapshot or terminal replay — and `handleClient` answers the messages the app sends back.
/// Everything crosses the same JSON boundary a socket would, via
/// `RemoteSessionConnection.receiveDemoServerText`.
@MainActor
final class DemoSessionScript {

    /// The script for a connection whose link is the demo sentinel, or nil for every real link.
    static func forDemo(
        link: RemoteConnectionLink,
        session: RemoteSessionSummaryDTO
    ) -> DemoSessionScript? {
        guard DemoExperience.isDemo(link: link) else { return nil }
        return DemoSessionScript(session: session)
    }

    private let session: RemoteSessionSummaryDTO
    private weak var connection: RemoteSessionConnection?
    private var rows: [RemoteConversationRowDTO]
    private var nextRowID: Int
    private var revision = 1
    private var replyIndex = 0
    private var pendingReply: Task<Void, Never>?
    private var terminalLine = ""

    private init(session: RemoteSessionSummaryDTO) {
        self.session = session
        rows = Self.seedRows(for: session)
        nextRowID = rows.count
    }

    func cancel() {
        pendingReply?.cancel()
        pendingReply = nil
        connection = nil
    }

    // MARK: - The Mac's opening

    func begin(on connection: RemoteSessionConnection) {
        self.connection = connection
        deliver(RemoteHelloDTO(
            surface: session.surface,
            capability: RemoteCapability.interact.rawValue,
            cols: session.surface == .terminal ? 80 : 0,
            rows: session.surface == .terminal ? 24 : 0,
            title: session.title,
            theme: RemoteAppModel.demoTheme,
            terminalTheme: RemoteAppModel.demoTerminalTheme,
            features: [
                RemoteWebSocketFeature.submitAcknowledgement.rawValue,
                RemoteWebSocketFeature.conversationContextAttachments.rawValue,
                RemoteWebSocketFeature.atomicTerminalSubmission.rawValue,
            ]
        ))
        if session.surface == .terminal {
            connection.receiveDemoTerminalOutput(Data(Self.terminalSeed.utf8))
        } else {
            deliverSnapshot()
        }
    }

    // MARK: - The app's messages

    func handleClient(_ message: RemoteClientMessage) {
        switch message.type {
        case "submit":
            guard let text = message.text else { return }
            if let requestID = message.requestID {
                deliver(RemotePromptSubmissionResultDTO(requestID: requestID, status: .accepted))
            }
            appendUserTurn(text)
        case "terminalSubmit":
            guard let text = message.text else { return }
            if let requestID = message.requestID {
                deliver(RemotePromptSubmissionResultDTO(requestID: requestID, status: .accepted))
            }
            echoTerminal(text + "\r")
        case "input":
            echoTerminal(message.data ?? "")
        case "viewport":
            if let cols = message.cols, let rows = message.rows {
                deliver(RemoteResizeDTO(cols: cols, rows: rows))
            }
        case "conversationResync":
            deliverSnapshot()
        default:
            // Presence, typing, viewport release: a demo Mac has nobody else to tell.
            break
        }
    }

    // MARK: - Conversation

    private func appendUserTurn(_ text: String) {
        rows.append(RemoteConversationRowDTO(id: rowID(), kind: "user", text: text))
        deliverSnapshot(streamingText: "", canSend: false)

        let reply = Self.replies[replyIndex % Self.replies.count]
        replyIndex += 1
        pendingReply?.cancel()
        pendingReply = Task { [weak self] in
            // Stream the reply the way a real turn arrives: a growing tail, then the settled
            // row. The pauses are what make the demo read as an agent rather than a lookup.
            var shown = ""
            for chunk in reply.streamedChunks {
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                shown += chunk
                self.deliverSnapshot(streamingText: shown, canSend: false)
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            if let tool = reply.tool {
                self.rows.append(tool.row(id: self.rowID()))
                self.deliverSnapshot(streamingText: shown, canSend: false)
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
            }
            self.rows.append(RemoteConversationRowDTO(
                id: self.rowID(),
                kind: "assistant",
                text: reply.text
            ))
            self.deliverSnapshot()
        }
    }

    private func deliverSnapshot(streamingText: String = "", canSend: Bool = true) {
        revision += 1
        deliver(RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: streamingText,
            canSend: canSend,
            revision: revision
        ))
    }

    private func rowID() -> String {
        defer { nextRowID += 1 }
        return String(nextRowID)
    }

    // MARK: - Terminal

    /// A toy line discipline: echo what is typed, answer Return with a canned line and a new
    /// prompt. Enough for the terminal surface to feel attached to something.
    private func echoTerminal(_ input: String) {
        var output = ""
        for character in input {
            switch character {
            case "\r", "\n":
                output += "\r\n" + Self.terminalAnswer(for: terminalLine) + "$ "
                terminalLine = ""
            case "\u{7f}", "\u{8}":
                if !terminalLine.isEmpty {
                    terminalLine.removeLast()
                    output += "\u{8} \u{8}"
                }
            default:
                terminalLine.append(character)
                output += String(character)
            }
        }
        guard !output.isEmpty else { return }
        connection?.receiveDemoTerminalOutput(Data(output.utf8))
    }

    // MARK: - Delivery

    private func deliver<Message: Encodable>(_ message: Message) {
        guard let connection,
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        connection.receiveDemoServerText(text)
    }

    // MARK: - Fixture content

    private static func seedRows(for session: RemoteSessionSummaryDTO) -> [RemoteConversationRowDTO] {
        [
            RemoteConversationRowDTO(
                id: "0",
                kind: "user",
                text: session.title
            ),
            RemoteConversationRowDTO(
                id: "1",
                kind: "assistant",
                text: "I looked at where this stands. Two things needed attention: the sidebar "
                    + "lost its selection across a relaunch, and one render test asserted a "
                    + "fixture nothing ships."
            ),
            RemoteConversationRowDTO(
                id: "2",
                kind: "tool",
                toolName: "Bash",
                summary: "scripts/test.sh",
                result: "Executed 3,517 tests, with 0 failures"
            ),
            RemoteConversationRowDTO(
                id: "3",
                kind: "assistant",
                text: "Both are fixed and the fast suite is green. This conversation is demo "
                    + "data. Pair your own Mac and this screen drives the real thing. Try "
                    + "sending a message below."
            ),
        ]
    }

    private struct ScriptedReply {
        struct Tool {
            let name: String
            let summary: String
            let result: String

            func row(id: String) -> RemoteConversationRowDTO {
                RemoteConversationRowDTO(
                    id: id,
                    kind: "tool",
                    toolName: name,
                    summary: summary,
                    result: result
                )
            }
        }

        let streamedChunks: [String]
        let tool: Tool?
        let text: String
    }

    private static let replies: [ScriptedReply] = [
        ScriptedReply(
            streamedChunks: ["Looking at that now:", " checking the diff", " and the tests…"],
            tool: ScriptedReply.Tool(
                name: "Bash",
                summary: "git diff --stat",
                result: "3 files changed, 41 insertions(+), 6 deletions(-)"
            ),
            text: "Done. The change is small and the existing tests still cover it. In the "
                + "real app I would show you the diff here, and you could open Git Review "
                + "from the session header to read it line by line."
        ),
        ScriptedReply(
            streamedChunks: ["Good question.", " In the demo I can only pretend to think", "…"],
            tool: nil,
            text: "This whole conversation is canned: no Mac, no agent, no tokens. Everything "
                + "else is real: the rendering, the streaming, the composer you just used. "
                + "Pair a Mac from the welcome screen and this becomes your actual session."
        ),
        ScriptedReply(
            streamedChunks: ["On it,", " running the checks again…"],
            tool: ScriptedReply.Tool(
                name: "Bash",
                summary: "scripts/test.sh",
                result: "Executed 3,517 tests, with 0 failures"
            ),
            text: "Still green. If this were a live session the status here would follow the "
                + "agent's real turn, and a permission request would appear as a card you "
                + "can approve from the phone."
        ),
    ]

    private static let terminalSeed = "\u{1b}[2J\u{1b}[H"
        + "$ scripts/test.sh\r\n"
        + "==> Running the Threading-Fast plan\r\n"
        + "Executed 3,517 tests, with 0 failures (0 unexpected)\r\n"
        + "\u{1b}[32m** TEST SUCCEEDED **\u{1b}[0m\r\n"
        + "\r\n"
        + "This terminal is demo data. Type here and a canned shell echoes back.\r\n"
        + "$ "

    private static func terminalAnswer(for line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        switch trimmed {
        case "ls":
            return "CHANGELOG.md   Sources   Tests   scripts\r\n"
        case "pwd":
            return "/Users/you/repo/demo\r\n"
        default:
            return "demo: '\(trimmed)' is canned output. Pair your Mac for a real shell\r\n"
        }
    }
}
