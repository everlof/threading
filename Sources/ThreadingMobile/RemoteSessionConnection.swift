import Foundation
import ThreadingRemoteKit

private enum RemoteMobileConnectionDefaults {
    static let conversationPageRows = 64
    /// Stay inside the Mac's five-minute replay window even after timer and network jitter.
    static let acknowledgedSubmissionRetrySeconds: TimeInterval = 4 * 60
}

struct RemotePromptSubmissionFeedback: Equatable {
    let requestID: String
    let text: String
    let status: RemotePromptSubmissionStatus
}

struct RemoteAttentionRequestFeedback: Equatable {
    let requestID: String
    let recipientID: String
    let status: RemoteAttentionRequestStatus
}

private struct PendingRemoteSubmission {
    let requestID: String
    let messageType: String
    let text: String
    let createdAt: Date
}

private struct PendingAttentionRequest {
    let requestID: String
    let recipientID: String
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
    @Published private(set) var composerCapabilities: [RemoteComposerCapabilityDTO] = []
    @Published private(set) var presence: [String: RemotePresenceDTO] = [:]
    @Published private(set) var isPromptSubmissionPending = false
    @Published private(set) var promptSubmissionFeedback: RemotePromptSubmissionFeedback?
    @Published private(set) var supportsAtomicTerminalSubmission = false
    @Published private(set) var supportsAttentionRequests = false
    @Published private(set) var supportsFocusedInputControl = false
    @Published private(set) var inputControl: RemoteInputControlStateDTO?
    @Published private(set) var inputControlEvents: [RemoteInputControlEventDTO] = []
    @Published private(set) var inputControlResult: RemoteInputControlResultDTO?
    @Published private(set) var attentionRecipients: [RemoteCollaborationParticipantDTO] = []
    @Published private(set) var attentionEvents: [RemoteAttentionEventDTO] = []
    @Published private(set) var isAttentionRequestPending = false
    @Published private(set) var attentionRequestFeedback: RemoteAttentionRequestFeedback?

    let session: RemoteSessionSummaryDTO
    let conversationStore = RemoteConversationStore()
    private var client: RemoteClient
    private let reconnectClient: (@MainActor () async -> RemoteClient?)?
    private let deviceID: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var stopped = false
    private var connectionGeneration = 0
    private var pendingTerminalOutput = Data()
    private let pendingTerminalOutputLimit = 2 * 1_024 * 1_024
    private var pendingViewport: (cols: Int, rows: Int)?
    private var typingIdleTask: Task<Void, Never>?
    private var isReportingTyping = false
    private var serverFeatures: Set<String> = []
    private var pendingPromptSubmission: PendingRemoteSubmission?
    private var pendingAttentionRequest: PendingAttentionRequest?
    /// Non-nil only for the demo sentinel link: plays the Mac's half of the socket in-process,
    /// through the same message handler a real frame reaches (`DemoExperience`).
    private var demoScript: DemoSessionScript?
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

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        reconnectClient: (@MainActor () async -> RemoteClient?)? = nil
    ) {
        self.session = session
        self.client = client
        self.reconnectClient = reconnectClient
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
        composerCapabilities = []
        serverFeatures.removeAll()
        supportsAtomicTerminalSubmission = false
        supportsAttentionRequests = false
        supportsFocusedInputControl = false
        inputControl = nil
        inputControlEvents = []
        attentionRecipients = []
        MobileDiagnostics.record(.socketConnecting, fields: [
            .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ])
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        // A reconnect receives the Mac's authoritative ring again. Reset an already-mounted
        // SwiftTerm first so replay replaces its prior state instead of duplicating scrollback.
        onTerminalOutput?(Data([0x1b, 0x63]))

        // The demo's canned Mac takes the socket's place; everything downstream of the wire —
        // the hello, snapshots, acknowledgements — still arrives through `handle`.
        if let script = DemoSessionScript.forDemo(link: client.link, session: session) {
            demoScript = script
            script.begin(on: self)
            return
        }

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
            scheduleReconnect(generation: generation)
        }
    }

    func disconnect(markEnded: Bool = true) {
        reportTyping(false)
        if phase == .connected, capability == .interact, pendingViewport != nil {
            try? send(RemoteClientMessage(type: "viewportRelease"))
        }
        connectionGeneration &+= 1
        stopped = true
        demoScript?.cancel()
        demoScript = nil
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        presence.removeAll()
        attentionRecipients = []
        pendingAttentionRequest = nil
        isAttentionRequestPending = false
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
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false else { return }
        reportTyping(true)
        try? send(RemoteClientMessage(type: "input", data: String(decoding: data, as: UTF8.self)))
    }

    func sendTerminalKey(_ text: String) {
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false else { return }
        reportTyping(true)
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

    @discardableResult
    func submit(
        _ text: String,
        contextAttachments: [RemoteConversationContextAttachmentDTO] = []
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false,
              contextAttachments.isEmpty || serverFeatures.contains(
                  RemoteWebSocketFeature.conversationContextAttachments.rawValue
              ),
              conversationStore.state.canSend else { return nil }
        return sendSubmission(
            type: "submit",
            text: trimmed,
            contextAttachments: contextAttachments,
            permitsLegacyHost: true
        )
    }

    /// Submits a device-local terminal draft as one PTY write. A host must advertise the
    /// capability because older hosts only understand shared raw keystrokes.
    @discardableResult
    func submitTerminalLine(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .newlines)
        guard supportsAtomicTerminalSubmission, inputControl?.canWrite != false else { return nil }
        return sendSubmission(type: "terminalSubmit", text: line, permitsLegacyHost: false)
    }

    @discardableResult
    func changeInputControl(action: String, targetID: String? = nil) -> String? {
        guard phase == .connected, capability == .interact,
              supportsFocusedInputControl else { return nil }
        let requestID = UUID().uuidString
        do {
            try send(RemoteClientMessage(
                type: "inputControl",
                state: action,
                recipientID: targetID,
                requestID: requestID
            ))
            return requestID
        } catch {
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
            return nil
        }
    }

    private func sendSubmission(
        type: String,
        text: String,
        contextAttachments: [RemoteConversationContextAttachmentDTO] = [],
        permitsLegacyHost: Bool
    ) -> String? {
        guard phase == .connected, capability == .interact,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !contextAttachments.isEmpty,
              pendingPromptSubmission == nil else { return nil }
        let requestID = UUID().uuidString
        let supportsAcknowledgement = serverFeatures.contains(
            RemoteWebSocketFeature.submitAcknowledgement.rawValue
        )
        guard supportsAcknowledgement || permitsLegacyHost else { return nil }
        do {
            reportTyping(false)
            pendingPromptSubmission = PendingRemoteSubmission(
                requestID: requestID,
                messageType: type,
                text: text,
                createdAt: Date()
            )
            isPromptSubmissionPending = supportsAcknowledgement
            try send(RemoteClientMessage(
                type: type,
                text: text,
                requestID: supportsAcknowledgement ? requestID : nil,
                contextAttachments: contextAttachments.isEmpty ? nil : contextAttachments
            ))
            if !supportsAcknowledgement {
                pendingPromptSubmission = nil
                Task { @MainActor [weak self] in
                    self?.promptSubmissionFeedback = RemotePromptSubmissionFeedback(
                        requestID: requestID,
                        text: text,
                        status: .accepted
                    )
                }
            }
            return requestID
        } catch {
            pendingPromptSubmission = nil
            isPromptSubmissionPending = false
            phase = .failed(error.localizedDescription)
            recordSocketFailure(error)
            scheduleReconnect(generation: connectionGeneration)
            return nil
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
            scheduleReconnect(generation: connectionGeneration)
        }
    }

    /// Requests a person's attention without touching the native prompt or terminal input paths.
    @discardableResult
    func requestAttention(recipientID: String, note: String?) -> String? {
        guard phase == .connected,
              capability == .interact,
              supportsAttentionRequests,
              pendingAttentionRequest == nil,
              attentionRecipients.contains(where: { $0.id == recipientID }) else {
            return nil
        }
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNote.map({
            $0.utf8.count <= RemoteAttentionDefaults.maximumNoteUTF8Bytes
        }) ?? true else { return nil }

        let requestID = UUID().uuidString
        do {
            pendingAttentionRequest = PendingAttentionRequest(
                requestID: requestID,
                recipientID: recipientID
            )
            isAttentionRequestPending = true
            attentionRequestFeedback = nil
            try send(RemoteClientMessage(
                type: "attentionRequest",
                text: normalizedNote?.isEmpty == false ? normalizedNote : nil,
                recipientID: recipientID,
                requestID: requestID
            ))
            return requestID
        } catch {
            pendingAttentionRequest = nil
            isAttentionRequestPending = false
            recordSocketFailure(error)
            return nil
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
        if let demoScript {
            guard expectedGeneration == connectionGeneration, !stopped else {
                throw RemoteClientError.invalidResponse
            }
            demoScript.handleClient(message)
            return
        }
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
                self.scheduleReconnect(generation: expectedGeneration)
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
            scheduleReconnect(generation: generation)
        }
    }

    // MARK: - The demo's wire

    /// A synthesized server frame from `DemoSessionScript`, entering through the same handler
    /// a real socket frame reaches. Ignored unless the demo script owns this connection, so
    /// nothing else can inject server state.
    func receiveDemoServerText(_ text: String) {
        guard demoScript != nil else { return }
        handle(text)
    }

    /// Synthesized terminal bytes, buffered exactly the way `receiveLoop` buffers real ones.
    func receiveDemoTerminalOutput(_ data: Data) {
        guard demoScript != nil else { return }
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
            serverFeatures = Set(hello.features ?? [])
            supportsAtomicTerminalSubmission = serverFeatures.contains(
                RemoteWebSocketFeature.atomicTerminalSubmission.rawValue
            )
            supportsAttentionRequests = serverFeatures.contains(
                RemoteWebSocketFeature.attentionRequests.rawValue
            )
            supportsFocusedInputControl = serverFeatures.contains(
                RemoteWebSocketFeature.focusedInputControl.rawValue
            )
            updateTerminalGrid(cols: hello.cols, rows: hello.rows)
            phase = .connected
            reconnectAttempt = 0
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
            resendPendingPromptIfSupported()
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
                composerCapabilities = snapshot.composerCapabilities
            }
        case "conversationDelta":
            if let delta = try? JSONDecoder().decode(
                RemoteConversationDeltaDTO.self,
                from: data
            ) {
                if !conversationStore.apply(delta) {
                    try? send(RemoteClientMessage(type: "conversationResync"))
                } else if let capabilities = delta.composerCapabilities {
                    composerCapabilities = capabilities
                }
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
                if update.state == "left" {
                    presence[update.id] = nil
                } else {
                    presence[update.id] = update
                }
            }
        case "collaborationParticipants":
            if let update = try? JSONDecoder().decode(
                RemoteCollaborationParticipantsDTO.self,
                from: data
            ) {
                attentionRecipients = update.participants
            }
        case "inputControl":
            if let update = try? JSONDecoder().decode(
                RemoteInputControlStateDTO.self,
                from: data
            ) {
                let gainedControl = inputControl?.canWrite != true && update.canWrite
                inputControl = update
                if gainedControl, let pendingViewport,
                   surface == "terminal", capability == .interact {
                    try? send(RemoteClientMessage(
                        type: "viewport",
                        cols: pendingViewport.cols,
                        rows: pendingViewport.rows
                    ))
                }
            }
        case "inputControlEvent":
            if let event = try? JSONDecoder().decode(
                RemoteInputControlEventDTO.self,
                from: data
            ), !inputControlEvents.contains(where: { $0.id == event.id }) {
                inputControlEvents.append(event)
                if inputControlEvents.count > 12 {
                    inputControlEvents.removeFirst(inputControlEvents.count - 12)
                }
            }
        case "inputControlResult":
            if let result = try? JSONDecoder().decode(
                RemoteInputControlResultDTO.self,
                from: data
            ) {
                inputControlResult = result
            }
        case "attention":
            if let event = try? JSONDecoder().decode(RemoteAttentionEventDTO.self, from: data),
               !attentionEvents.contains(where: { $0.id == event.id }) {
                attentionEvents.append(event)
                if attentionEvents.count > 12 {
                    attentionEvents.removeFirst(attentionEvents.count - 12)
                }
            }
        case "attentionResult":
            guard let result = try? JSONDecoder().decode(
                RemoteAttentionRequestResultDTO.self,
                from: data
            ), let pending = pendingAttentionRequest,
               pending.requestID == result.requestID else { return }
            pendingAttentionRequest = nil
            isAttentionRequestPending = false
            attentionRequestFeedback = RemoteAttentionRequestFeedback(
                requestID: result.requestID,
                recipientID: pending.recipientID,
                status: result.status
            )
        case "submitResult":
            guard let result = try? JSONDecoder().decode(
                RemotePromptSubmissionResultDTO.self,
                from: data
            ), let pending = pendingPromptSubmission,
               pending.requestID == result.requestID else { return }
            pendingPromptSubmission = nil
            isPromptSubmissionPending = false
            promptSubmissionFeedback = RemotePromptSubmissionFeedback(
                requestID: result.requestID,
                text: pending.text,
                status: result.status
            )
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
            if error?.code == "promptTooLarge" || error?.code == "invalidRequestID"
                || error?.code == "invalidTerminalSubmission" {
                finishPendingPrompt(with: .rejected)
                return
            }
            if error?.code == "invalidAttentionRequest", let pending = pendingAttentionRequest {
                pendingAttentionRequest = nil
                isAttentionRequestPending = false
                attentionRequestFeedback = RemoteAttentionRequestFeedback(
                    requestID: pending.requestID,
                    recipientID: pending.recipientID,
                    status: .rejected
                )
                return
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

    private func scheduleReconnect(generation: Int) {
        guard reconnectClient != nil, reconnectTask == nil,
              connectionGeneration == generation else { return }
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        let attempt = reconnectAttempt
        reconnectAttempt = min(reconnectAttempt + 1, 4)
        let delay = min(pow(2.0, Double(attempt)), 8.0)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.connectionGeneration == generation,
                  let reconnectClient = self.reconnectClient,
                  let client = await reconnectClient() else { return }
            guard !Task.isCancelled, self.connectionGeneration == generation else { return }
            self.client = client
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func updateTerminalGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        terminalColumns = cols
        terminalRows = rows
        onTerminalGridChange?(cols, rows)
    }

    private func resendPendingPromptIfSupported() {
        guard let pending = pendingPromptSubmission else { return }
        guard serverFeatures.contains(
            RemoteWebSocketFeature.submitAcknowledgement.rawValue
        ) else {
            finishPendingPrompt(with: .unavailable)
            return
        }
        guard Date().timeIntervalSince(pending.createdAt)
                < RemoteMobileConnectionDefaults.acknowledgedSubmissionRetrySeconds else {
            finishPendingPrompt(with: .unavailable)
            return
        }
        if pending.messageType == "terminalSubmit", !supportsAtomicTerminalSubmission {
            finishPendingPrompt(with: .unavailable)
            return
        }
        isPromptSubmissionPending = true
        try? send(RemoteClientMessage(
            type: pending.messageType,
            text: pending.text,
            requestID: pending.requestID
        ))
    }

    private func finishPendingPrompt(with status: RemotePromptSubmissionStatus) {
        guard let pending = pendingPromptSubmission else { return }
        pendingPromptSubmission = nil
        isPromptSubmissionPending = false
        promptSubmissionFeedback = RemotePromptSubmissionFeedback(
            requestID: pending.requestID,
            text: pending.text,
            status: status
        )
    }

#if DEBUG
    static func demoTerminal() -> RemoteSessionConnection {
        let session = RemoteSessionSummaryDTO(
            id: "f50c77da-5716-470b-933c-d68310644b4f",
            title: "Claude Code · AnotherTerminal",
            agentKind: "claude",
            surface: "terminal",
            state: "running",
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.invalid/#terminal-preview")!
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link)
        )
        connection.phase = .connected
        connection.surface = "terminal"
        connection.capability = .interact
        connection.theme = RemoteAppModel.demoTheme
        connection.terminalTheme = RemoteAppModel.demoTerminalTheme
        connection.terminalColumns = 48
        connection.terminalRows = 18
        connection.serverFeatures = Set(RemoteWebSocketFeature.allCases.map(\.rawValue))
        connection.supportsAtomicTerminalSubmission = true
        connection.supportsAttentionRequests = true
        connection.supportsFocusedInputControl = true
        let lines = [
            "\u{1b}[2J\u{1b}[H\u{1b}[1;36mClaude Code\u{1b}[0m  AnotherTerminal",
            "",
            "● Collaboration is ready.",
            "  Devices keep separate drafts.",
            "",
            "● Running transport and UI tests…",
            "",
            "  $ swift test",
            "  All tests passed",
            "",
            "\u{1b}[2m──────────────────────────────────────\u{1b}[0m",
            "❯ Waiting for the next instruction",
        ]
        connection.pendingTerminalOutput = Data(lines.joined(separator: "\r\n").utf8)
        let anna = RemotePresenceDTO(
            presenceID: "terminal-anna",
            memberID: "member-anna",
            displayName: "Anna",
            deviceName: "iPhone",
            surface: "terminal",
            state: "typing"
        )
        let ipad = RemotePresenceDTO(
            presenceID: "terminal-ipad",
            memberID: "member-david",
            displayName: "David",
            deviceName: "iPad",
            surface: "terminal",
            state: "viewing"
        )
        connection.presence = [anna.id: anna, ipad.id: ipad]
        connection.attentionRecipients = [
            .init(id: "member-anna", displayName: "Anna", role: "member", isOnline: true),
            .init(id: "member-priya", displayName: "Priya", role: "member", isOnline: false),
        ]
        connection.inputControl = RemoteInputControlStateDTO(
            mode: .focused,
            controllerID: "member-anna",
            controllerDisplayName: "Anna",
            currentParticipantID: "owner",
            canWrite: false,
            canManage: true,
            canHandOff: true,
            participants: [
                .init(id: "owner", displayName: "David", role: "owner", isOnline: true),
                .init(id: "member-anna", displayName: "Anna", role: "member", isOnline: true),
            ],
            revision: 2
        )
        connection.attentionEvents = [
            .init(
                requestID: "terminal-attention-demo",
                senderID: "member-david",
                senderDisplayName: "David",
                recipientID: "member-anna",
                recipientDisplayName: "Anna",
                note: "Could you confirm the release wording?"
            )
        ]
        return connection
    }

    static func demoConversation() -> RemoteSessionConnection {
        let environment = ProcessInfo.processInfo.environment
        let demoMode = environment["THREADING_MOBILE_DEMO"] ?? ""
        let isPerformanceFixture = demoMode == "conversation-cold-stress"
            || demoMode == "conversation-scroll-stress"
        let sourceRowCount = environment["THREADING_MOBILE_CONVERSATION_STRESS_ROWS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 5_000
        let fixtureStarted = ProcessInfo.processInfo.systemUptime
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
        connection.serverFeatures = Set(RemoteWebSocketFeature.allCases.map(\.rawValue))
        connection.supportsAttentionRequests = true
        connection.supportsFocusedInputControl = true
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
        let isStressFixture = demoMode == "conversation-stress"
        let rows: [RemoteConversationRowDTO]
        if isPerformanceFixture {
            // A cold remote open receives only the newest bounded host window. The deep-scroll
            // case represents the same client after it has explicitly paged the whole history.
            let presentedRows = demoMode == "conversation-cold-stress"
                ? min(sourceRowCount, 160)
                : sourceRowCount
            let firstIndex = sourceRowCount - presentedRows
            rows = (firstIndex..<sourceRowCount).map { index in
                switch index % 12 {
                case 0:
                    return RemoteConversationRowDTO(
                        id: String(index),
                        kind: "user",
                        text: "Remote prompt \(index): verify the deterministic cross-device fixture."
                    )
                case 1, 5, 9:
                    return RemoteConversationRowDTO(
                        id: String(index),
                        kind: "tool",
                        toolName: index.isMultiple(of: 2) ? "Read" : "Bash",
                        summary: "Sources/Remote/Fixture\(index).swift",
                        result: "Completed deterministic operation \(index)."
                    )
                default:
                    return RemoteConversationRowDTO(
                        id: String(index),
                        kind: "assistant",
                        text: """
                        ### Cross-device result \(index)

                        This generated message exercises Markdown parsing, wrapping, reusable \
                        collection cells, and height discovery after another device wrote a \
                        long conversation.

                        `let remoteRow = \(index)`
                        """
                    )
                }
            }
        } else if isStressFixture {
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
        let capabilities = [
            RemoteComposerCapabilityDTO(
                id: "codex.command:review",
                name: "review",
                displayName: "Review",
                description: "Review uncommitted changes",
                argumentHint: "[instructions]",
                kind: "command",
                trigger: "slash",
                presentation: "turn"
            ),
            RemoteComposerCapabilityDTO(
                id: "codex.skill:release",
                name: "release",
                displayName: "Release",
                description: "Prepare and verify a release",
                argumentHint: "[version]",
                kind: "skill",
                trigger: "dollar",
                presentation: "turn"
            ),
            RemoteComposerCapabilityDTO(
                id: RemoteComposerCatalog.skillsCommandID,
                name: "skills",
                displayName: "Skills",
                description: "Browse skills available in this conversation",
                argumentHint: "",
                kind: "command",
                trigger: "slash",
                presentation: "command"
            ),
        ]
        connection.composerCapabilities = capabilities
        let storeStarted = ProcessInfo.processInfo.systemUptime
        connection.conversationStore.replace(with: RemoteConversationSnapshotDTO(
            rows: rows,
            canSend: true,
            composerCapabilities: capabilities,
            hasEarlier: demoMode == "conversation-cold-stress"
                && sourceRowCount > rows.count
        ))
        if isPerformanceFixture {
            let storeEnded = ProcessInfo.processInfo.systemUptime
            MobileConversationPerformanceProbe.fixtureDidLoad(
                mode: demoMode,
                sourceRows: sourceRowCount,
                mountedRows: rows.count,
                startedAt: fixtureStarted,
                generationMilliseconds: (storeStarted - fixtureStarted) * 1_000,
                storeMilliseconds: (storeEnded - storeStarted) * 1_000
            )
        }
        if ["conversation-collaboration", "attention-request"].contains(demoMode) {
            let anna = RemotePresenceDTO(
                presenceID: "presence-anna",
                memberID: "member-anna",
                displayName: "Anna",
                deviceName: "Anna’s iPhone",
                surface: "conversation",
                state: "typing"
            )
            let ipad = RemotePresenceDTO(
                presenceID: "presence-ipad",
                memberID: "owner-ipad",
                displayName: "David’s iPad",
                deviceName: "David’s iPad",
                surface: "conversation",
                state: "viewing"
            )
            connection.presence = [anna.id: anna, ipad.id: ipad]
            connection.attentionRecipients = [
                .init(id: "member-anna", displayName: "Anna", role: "member", isOnline: true),
                .init(id: "member-priya", displayName: "Priya", role: "member", isOnline: false),
            ]
            connection.attentionEvents = [
                .init(
                    requestID: "conversation-attention-demo",
                    senderID: "owner-ipad",
                    senderDisplayName: "David",
                    recipientID: "member-anna",
                    recipientDisplayName: "Anna",
                    note: "Need your domain take on the approval wording."
                )
            ]

            // The paired owner is the focused controller in this companion fixture. Together
            // with `demoTerminal()` (where Anna controls and the owner watches), this gives the
            // screenshot/E2E pass both personalized projections of one shared-session policy.
            connection.inputControl = RemoteInputControlStateDTO(
                mode: .focused,
                controllerID: "owner",
                controllerDisplayName: "David",
                currentParticipantID: "owner",
                canWrite: true,
                canManage: true,
                canHandOff: true,
                participants: [
                    .init(id: "owner", displayName: "David", role: "owner", isOnline: true),
                    .init(
                        id: "member-anna",
                        displayName: "Anna",
                        role: "member",
                        isOnline: true
                    ),
                    .init(
                        id: "member-priya",
                        displayName: "Priya",
                        role: "member",
                        isOnline: false
                    ),
                ],
                revision: 3
            )
        }
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
            composerCapabilities: connection.composerCapabilities,
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
