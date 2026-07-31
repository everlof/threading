import Foundation
import ThreadingRemoteKit

private enum RemoteMobileConnectionDefaults {
    static let conversationPageRows = 64
}

@MainActor
final class RemoteSessionConnection: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case connected
        case ended(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var title: String
    @Published private(set) var surface: String
    @Published private(set) var capability: RemoteCapability = .view
    @Published private(set) var theme: RemoteThemeDTO?
    @Published private(set) var terminalTheme: RemoteTerminalThemeDTO?
    @Published private(set) var terminalColumns = 0
    @Published private(set) var terminalRows = 0
    @Published private(set) var conversationCanSend = false
    @Published private(set) var presence: [String: RemotePresenceDTO] = [:]

    let session: RemoteSessionSummaryDTO
    let conversationStore = RemoteConversationStore()
    private let client: RemoteClient
    private let deviceID: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var stopped = false
    private var connectionGeneration = 0
    private var pendingTerminalOutput = Data()
    private let pendingTerminalOutputLimit = 2 * 1_024 * 1_024
    private var pendingViewport: (cols: Int, rows: Int)?
    private var typingIdleTask: Task<Void, Never>?
    private var isReportingTyping = false
    var onTerminalOutput: ((Data) -> Void)? {
        didSet {
            guard let onTerminalOutput, !pendingTerminalOutput.isEmpty else { return }
            let buffered = pendingTerminalOutput
            pendingTerminalOutput.removeAll(keepingCapacity: true)
            onTerminalOutput(buffered)
        }
    }
    var onTerminalGridChange: ((Int, Int) -> Void)? {
        didSet {
            guard terminalColumns > 0, terminalRows > 0 else { return }
            onTerminalGridChange?(terminalColumns, terminalRows)
        }
    }
    var onWorkspaceChanged: ((RemoteWorkspaceChangedDTO) -> Void)?

    init(session: RemoteSessionSummaryDTO, client: RemoteClient) {
        self.session = session
        self.client = client
        title = session.title
        surface = session.surface
        terminalTheme = session.terminalTheme
        deviceID = RemoteDeviceIdentity.current
        conversationStore.onCanSendChange = { [weak self] canSend in
            self?.conversationCanSend = canSend
        }
    }

    func connect() {
        disconnect(markEnded: false)
        let generation = connectionGeneration
        stopped = false
        phase = .connecting
        MobileDiagnostics.record(.socketConnecting, fields: [
            .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ])
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        // A reconnect receives the Mac's authoritative ring again. Reset an already-mounted
        // SwiftTerm first so replay replaces its prior state instead of duplicating scrollback.
        onTerminalOutput?(Data([0x1b, 0x63]))

        do {
            let task = try client.webSocketTask(sessionID: session.id)
            self.task = task
            task.resume()
            try send(RemoteClientMessage(
                type: "auth",
                token: client.link.token,
                device: deviceID,
                deviceName: RemoteDeviceIdentity.currentName,
                protocolVersion: RemoteProtocol.current,
                protocolMinimum: RemoteProtocol.minimumSupported
            ), generation: generation)
            receiveTask = Task { [weak self, task] in
                await self?.receiveLoop(task: task, generation: generation)
            }
        } catch {
            guard connectionGeneration == generation else { return }
            stopped = true
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
        }
    }

    func disconnect(markEnded: Bool = true) {
        reportTyping(false)
        if phase == .connected, capability == .interact, pendingViewport != nil {
            try? send(RemoteClientMessage(type: "viewportRelease"))
        }
        connectionGeneration &+= 1
        stopped = true
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        presence.removeAll()
        conversationStore.cancelLoadingEarlier()
        if markEnded {
            phase = .ended(MobileL10n.string("Disconnected"))
            MobileDiagnostics.record(.socketEnded, fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .reason: "user",
            ])
        }
    }

    func sendTerminalInput(_ data: ArraySlice<UInt8>) {
        guard phase == .connected, capability == .interact else { return }
        try? send(RemoteClientMessage(type: "input", data: String(decoding: data, as: UTF8.self)))
    }

    func sendTerminalKey(_ text: String) {
        guard phase == .connected, capability == .interact else { return }
        try? send(RemoteClientMessage(type: "input", data: text))
    }

    /// Reports the grid SwiftTerm can actually display on this phone. The latest value is kept
    /// across the auth handshake so an initial layout that happens before `hello` is not lost.
    func updateTerminalViewport(cols: Int, rows: Int) {
        guard cols >= 20, rows >= 4 else { return }
        let viewport = (cols, rows)
        if pendingViewport?.cols == cols, pendingViewport?.rows == rows { return }
        pendingViewport = viewport
        guard phase == .connected, capability == .interact else { return }
        try? send(RemoteClientMessage(type: "viewport", cols: cols, rows: rows))
    }

    func releaseTerminalViewport() {
        guard pendingViewport != nil else { return }
        pendingViewport = nil
        guard phase == .connected, capability == .interact else { return }
        try? send(RemoteClientMessage(type: "viewportRelease"))
    }

    /// Applies a picker choice locally while the Mac persists and broadcasts it.
    func previewTerminalTheme(_ theme: RemoteTerminalThemeDTO?) {
        terminalTheme = theme
    }

    func submit(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .connected, capability == .interact,
              conversationStore.state.canSend, !trimmed.isEmpty else { return false }
        do {
            reportTyping(false)
            try send(RemoteClientMessage(type: "submit", text: trimmed))
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
            return false
        }
    }

    func reportTyping(_ typing: Bool) {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        guard phase == .connected, capability == .interact else {
            isReportingTyping = false
            return
        }

        if typing {
            if !isReportingTyping {
                isReportingTyping = true
                try? send(RemoteClientMessage(type: "presence", state: "typing"))
            }
            typingIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.reportTyping(false)
            }
        } else if isReportingTyping {
            isReportingTyping = false
            try? send(RemoteClientMessage(type: "presence", state: "idle"))
        }
    }

    func decidePermission(_ permission: RemotePermissionRequestDTO, allow: Bool) {
        guard phase == .connected, capability == .interact, permission.canDecide else { return }
        do {
            try send(RemoteClientMessage(
                type: "permission",
                id: permission.id,
                decision: allow ? "allow" : "deny"
            ))
            MobileDiagnostics.record(.permissionDecisionSent, fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .trace: permission.id,
                .result: allow ? "allow" : "deny",
            ])
        } catch {
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
        }
    }

    func loadEarlierConversation() {
        guard phase == .connected,
              let beforeRowID = conversationStore.beginLoadingEarlier() else {
            return
        }
        do {
            try send(RemoteClientMessage(
                type: "conversationPage",
                beforeRowID: beforeRowID,
                limit: RemoteMobileConnectionDefaults.conversationPageRows
            ))
        } catch {
            conversationStore.cancelLoadingEarlier()
            recordSocketFailure(error)
        }
    }

    private func send(_ message: RemoteClientMessage, generation: Int? = nil) throws {
        let expectedGeneration = generation ?? connectionGeneration
        guard expectedGeneration == connectionGeneration, !stopped,
              let task else { throw RemoteClientError.invalidResponse }
        let data = try JSONEncoder().encode(message)
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.connectionGeneration == expectedGeneration,
                      self.stopped == false, self.task === task else { return }
                self.phase = .failed(error.localizedDescription)
                self.recordSocketFailure(error)
            }
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, generation: Int) async {
        do {
            while !Task.isCancelled, !stopped, connectionGeneration == generation {
                let message = try await task.receive()
                guard !stopped, connectionGeneration == generation, self.task === task else {
                    return
                }
                switch message {
                case .data(let data):
                    if let onTerminalOutput {
                        onTerminalOutput(data)
                    } else {
                        pendingTerminalOutput.append(data)
                        if pendingTerminalOutput.count > pendingTerminalOutputLimit {
                            pendingTerminalOutput.removeFirst(
                                pendingTerminalOutput.count - pendingTerminalOutputLimit
                            )
                        }
                    }
                case .string(let text):
                    handle(text)
                @unknown default:
                    continue
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !stopped, connectionGeneration == generation, self.task === task else { return }
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
        }
    }

    private struct Envelope: Decodable {
        let type: String
    }

    private func handle(_ text: String) {
        let data = Data(text.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        switch envelope.type {
        case "hello":
            guard let hello = try? JSONDecoder().decode(RemoteHelloDTO.self, from: data) else { return }
            title = hello.title.isEmpty ? title : hello.title
            surface = hello.surface
            capability = RemoteCapability(rawValue: hello.capability) ?? .view
            theme = hello.theme ?? theme
            terminalTheme = hello.terminalTheme ?? terminalTheme
            updateTerminalGrid(cols: hello.cols, rows: hello.rows)
            phase = .connected
            MobileDiagnostics.record(.socketConnected, fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .capability: hello.capability,
                .surface: hello.surface,
            ])
            if let pendingViewport, capability == .interact {
                try? send(RemoteClientMessage(
                    type: "viewport",
                    cols: pendingViewport.cols,
                    rows: pendingViewport.rows
                ))
            }
        case "resize":
            if let resize = try? JSONDecoder().decode(RemoteResizeDTO.self, from: data) {
                updateTerminalGrid(cols: resize.cols, rows: resize.rows)
            }
        case "theme":
            if let update = try? JSONDecoder().decode(RemoteThemeUpdateDTO.self, from: data) {
                theme = update.theme
                terminalTheme = update.terminalTheme
            }
        case "title":
            if let update = try? JSONDecoder().decode(RemoteTitleDTO.self, from: data) {
                title = update.title
            }
        case "workspaceChanged":
            if let update = try? JSONDecoder().decode(
                RemoteWorkspaceChangedDTO.self,
                from: data
            ) {
                onWorkspaceChanged?(update)
            }
        case "conversation":
            if let snapshot = try? JSONDecoder().decode(RemoteConversationSnapshotDTO.self, from: data) {
                conversationStore.replace(with: snapshot)
            }
        case "conversationDelta":
            if let delta = try? JSONDecoder().decode(
                RemoteConversationDeltaDTO.self,
                from: data
            ), !conversationStore.apply(delta) {
                try? send(RemoteClientMessage(type: "conversationResync"))
            }
        case "conversationPage":
            if let page = try? JSONDecoder().decode(
                RemoteConversationPageDTO.self,
                from: data
            ) {
                conversationStore.prepend(page)
            }
        case "presence":
            if let update = try? JSONDecoder().decode(RemotePresenceDTO.self, from: data) {
                if update.state == "typing" {
                    presence[update.memberID] = update
                } else {
                    presence[update.memberID] = nil
                }
            }
        case "ended":
            let ended = try? JSONDecoder().decode(RemoteEndedDTO.self, from: data)
            stopped = true
            switch ended?.reason {
            case "sessionClosed":
                phase = .ended(MobileL10n.string("Session closed on Mac"))
            case "protocolMismatch":
                phase = .ended(
                    ended?.update == .client
                        ? MobileL10n.string("Update this app to reconnect")
                        : MobileL10n.string("Update Threading on the Mac to reconnect")
                )
            default:
                phase = .ended(MobileL10n.string("Session ended"))
            }
            MobileDiagnostics.record(.socketEnded, fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .reason: ended?.reason ?? "server",
            ])
        case "error":
            let error = try? JSONDecoder().decode(RemoteErrorDTO.self, from: data)
            if error?.code == "invalidConversationPage" {
                conversationStore.cancelLoadingEarlier()
            }
            // Another paired client may answer the same visible card first. Its authoritative
            // snapshot follows immediately; that benign race must not mark this socket failed.
            if error?.code != "permissionNotPending" {
                let message: String
                switch error?.code {
                case "forbidden":
                    message = MobileL10n.string("This link is view only.")
                case "inputTooLarge", "promptTooLarge":
                    message = MobileL10n.string(
                        "That input is too large to send in one action."
                    )
                default:
                    message = MobileL10n.string("Remote action failed")
                }
                phase = .failed(message)
                MobileDiagnostics.record(
                    .socketFailed,
                    level: .error,
                    fields: [
                        .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                        .code: error?.code ?? "remote.actionFailed",
                    ]
                )
            }
        default:
            break
        }
    }

    private func recordSocketFailure(_ error: Error) {
        MobileDiagnostics.record(
            .socketFailed,
            level: .error,
            fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .code: MobileDiagnostics.errorCode(error),
            ]
        )
    }

    private func updateTerminalGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        terminalColumns = cols
        terminalRows = rows
        onTerminalGridChange?(cols, rows)
    }

#if DEBUG
    static func demoConversation() -> RemoteSessionConnection {
        let session = RemoteSessionSummaryDTO(
            id: "5de80220-2172-4fbe-8ed7-a707572fc922",
            title: "Review the new remote access feature",
            agentKind: "codex",
            surface: "conversation",
            state: "idle",
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.invalid/#preview")!
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link)
        )
        connection.phase = .connected
        connection.surface = "conversation"
        connection.capability = .interact
        connection.theme = ProcessInfo.processInfo.environment["THREADING_MOBILE_THEME"] == "light"
            ? RemoteAppModel.demoLightTheme
            : RemoteAppModel.demoTheme
        connection.terminalTheme = RemoteAppModel.demoTerminalTheme
        let coreRows: [RemoteConversationRowDTO] = [
                .init(
                    id: "0",
                    kind: "user",
                    text: "Review the remote access work, fix what you find, and make the iPhone experience feel native."
                ),
                .init(
                    id: "1",
                    kind: "assistant",
                    text: "I found two concrete issues in the first pass: dormant sessions could not be resumed remotely, and native conversations were being flattened into a terminal-shaped experience."
                ),
                .init(
                    id: "2",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "xcodebuild ThreadingMobile",
                    result: "Build Succeeded"
                ),
                .init(
                    id: "3",
                    kind: "assistant",
                    text: """
                    Both are fixed. Initial terminal output is buffered until SwiftTerm mounts:

                    ```swift
                    if let onTerminalOutput {
                        onTerminalOutput(data)
                    } else {
                        pendingTerminalOutput.append(data)
                    }
                    ```

                    The app now pairs by QR code, groups sessions by project, resumes disconnected work on the Mac, and renders either the terminal or this structured code conversation.
                    """
                ),
            ]
        let isStressFixture = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
            == "conversation-stress"
        let rows: [RemoteConversationRowDTO]
        if isStressFixture {
            let history = (0..<396).map { index in
                RemoteConversationRowDTO(
                    id: String(index),
                    kind: index.isMultiple(of: 7) ? "tool" : "assistant",
                    text: index.isMultiple(of: 7) ? nil : "Cached fixture message \(index).",
                    toolName: index.isMultiple(of: 7) ? "Read" : nil,
                    summary: index.isMultiple(of: 7) ? "Sources/Feature\(index).swift" : nil,
                    result: index.isMultiple(of: 14) ? "Read 84 lines" : nil
                )
            }
            rows = history + [
                .init(
                    id: "396",
                    kind: "user",
                    text: "Please review this very long conversation on a compact phone, including dynamic type, code, and a permission request without losing my reading position."
                ),
                .init(
                    id: "397",
                    kind: "assistant",
                    text: """
                    The timeline now keeps only visible cells alive. Markdown is parsed once off \
                    the main actor and cached, while live tokens update one synthetic row.

                    ```swift
                    let delta = RemoteConversationDeltaDTO(
                        baseRevision: 41,
                        revision: 42,
                        streamingText: "Still working…",
                        canSend: false
                    )
                    ```

                    Older messages arrive in prepend-only pages, and the first visible message \
                    stays under your finger when a page lands.
                    """
                ),
                .init(
                    id: "398",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "xcodebuild -scheme ThreadingMobile test",
                    result: "Executed the focused performance and protocol fixtures successfully."
                ),
                .init(
                    id: "399",
                    kind: "notice",
                    text: "Fixture contains 400 rows; only visible collection cells are mounted."
                ),
            ]
        } else {
            rows = coreRows
        }
        connection.conversationStore.replace(with: RemoteConversationSnapshotDTO(
            rows: rows,
            canSend: true
        ))
        return connection
    }

    static func demoPermissionConversation() -> RemoteSessionConnection {
        let connection = demoConversation()
        connection.conversationStore.replace(with: RemoteConversationSnapshotDTO(
            rows: [
                .init(
                    id: "0",
                    kind: "user",
                    text: "Update the connection state without losing the first terminal frame."
                ),
                .init(
                    id: "1",
                    kind: "assistant",
                    text: "I have the fix ready. This edit needs your approval before I apply it."
                ),
            ],
            canSend: false,
            permission: .init(
                id: "permission-preview",
                toolName: "Edit",
                summary: "Sources/ThreadingMobile/RemoteSessionConnection.swift",
                filePath: "RemoteSessionConnection.swift",
                diff: [
                    .init(id: "0", kind: "removal", text: "onTerminalOutput?(data)"),
                    .init(id: "1", kind: "addition", text: "pendingTerminalOutput.append(data)"),
                ]
            )
        ))
        return connection
    }
#endif
}
