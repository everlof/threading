import Foundation
import ThreadingRemoteKit

private enum RemoteMobileConnectionDefaults {
    static let conversationPageRows = 64
    /// Stay inside the Mac's five-minute replay window even after timer and network jitter.
    static let acknowledgedSubmissionRetrySeconds: TimeInterval = 4 * 60
    /// How long a socket may stay open without the Mac greeting it.
    ///
    /// Nothing in URLSession is relied on to bound "the TCP connection was accepted and no
    /// frame ever arrived": whether `URLSessionWebSocketTask` honours
    /// `timeoutIntervalForResource` is not established, and the 2026-08-17 hang was never
    /// reproduced. Without this deadline the receive loop can await forever: no failure, no
    /// reconnect, and no terminal event in the diagnostics journal, which is exactly the shape
    /// that report could not explain. Long enough for a slow cellular handshake, far shorter than a person's patience.
    static let helloDeadline: Duration = .seconds(15)
}

enum MobileCollaborationPresentation {
    /// Input control coordinates distinct people, not multiple devices owned by the same person.
    /// The host roster contains accepted reply-capable members (including members who are away),
    /// always includes the current interactive identity, and gives an unused invitation no row.
    static func hasOtherParticipant(_ state: RemoteInputControlStateDTO) -> Bool {
        state.participants.count > 1
    }

    static func showsInputControl(
        featureSupported: Bool,
        capability: RemoteCapability,
        state: RemoteInputControlStateDTO?
    ) -> Bool {
        guard featureSupported, capability == .interact, let state else { return false }
        return hasOtherParticipant(state)
    }

    /// How a terminal session takes typing on this phone. One answer rather than two booleans,
    /// because "no composer" and "keystrokes go straight to the PTY" are not the same thing and
    /// a caller that reads only one of them will eventually offer both or neither.
    static func terminalInputMode(
        settingEnabled: Bool,
        supportsAtomicSubmission: Bool,
        capability: RemoteCapability,
        inputControlFeatureSupported: Bool,
        canWrite: Bool,
        state: RemoteInputControlStateDTO?
    ) -> MobileTerminalInputMode {
        guard capability == .interact else { return .none }
        guard settingEnabled, supportsAtomicSubmission else {
            return canWrite ? .direct : .none
        }
        // An older host cannot state whether another participant has joined, and never will, so
        // the safe atomic path is its settled answer rather than a placeholder.
        guard inputControlFeatureSupported else { return .independentComposer }
        // A host that does send a roster has not necessarily sent it yet: `hello` and the first
        // `inputControl` frame are two messages with a render between them. Answering
        // `.independentComposer` for that gap put the line composer on screen for a frame and
        // then took it away again on every solo terminal session — a flash of the non-TUI text
        // area on the way into the TUI. Offer nothing until the roster settles it; the wait is
        // one frame, and it is the same wait that keeps raw keystrokes from starting before we
        // know whether somebody else holds the session.
        guard let state else { return .none }
        if hasOtherParticipant(state) { return .independentComposer }
        return canWrite ? .direct : .none
    }
}

/// What a terminal session offers this phone for typing.
enum MobileTerminalInputMode: Equatable {
    /// Keystrokes reach the PTY as they are typed.
    case direct
    /// A whole line is composed here and submitted atomically, so two people cannot splice one
    /// terminal line between them.
    case independentComposer
    /// Nothing: this viewer cannot write, or the host has not yet said who else is here.
    case none
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

/// Whether the agent is mid-turn, read from what one chat client can actually see.
///
/// The Mac never sends a status word over the wire, but it does send `canSend`, which each
/// transport defines as `isRunning && input != nil && !isTurnInFlight && pendingPrompt == nil`
/// and the server then narrows to this viewer's own capability. So on a connected session a
/// client that *would* be allowed to type and is told it cannot is being told a turn is in
/// flight — the mobile reading of the Mac's `isTurnInFlight`, which is what gates the orb there.
///
/// The two narrowings matter as much as the signal. A view-only viewer is sent `canSend: false`
/// with no turn running at all, and a collaborator holding the input control makes it false for
/// everyone else; neither is the agent working, so both answer `false` rather than spinning an
/// orb about someone else's keyboard.
enum MobileAgentTurnActivity {
    static func isWorking(
        isConnected: Bool,
        capability: RemoteCapability,
        canWrite: Bool,
        canSend: Bool,
        isPromptSubmissionPending: Bool
    ) -> Bool {
        guard isConnected, capability == .interact else { return false }
        // A prompt still being acknowledged is the very start of a turn: the Mac has it and has
        // not answered yet, so the composer is already closed on this side.
        if isPromptSubmissionPending { return true }
        guard canWrite else { return false }
        return !canSend
    }
}

@MainActor
final class RemoteSessionConnection: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case connected
        case ended(String)
        case failed(RemoteConnectionFailure)

        var failure: RemoteConnectionFailure? {
            if case .failed(let failure) = self { return failure }
            return nil
        }
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var title: String
    @Published private(set) var surface: RemoteSessionSurface
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
    /// Whether this connection may hand the Mac files to send with a prompt. False for a
    /// view-only or guest link, which the host never advertises the feature to — so the composer
    /// draws no attach button rather than one that would be refused.
    @Published private(set) var supportsComposerAttachmentUploads = false
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
    /// Armed by `connect()`, disarmed by the `hello` frame, and the only thing that turns a
    /// socket the Mac never greets into a terminal state.
    private var helloDeadlineTask: Task<Void, Never>?
    private let helloDeadline: Duration
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

    /// True while this session's agent is working on a turn — what the navigation title's orb
    /// is drawn for. See `MobileAgentTurnActivity` for why `canSend` is the signal.
    var isAgentWorking: Bool {
        MobileAgentTurnActivity.isWorking(
            isConnected: phase == .connected,
            capability: capability,
            canWrite: inputControl?.canWrite != false,
            canSend: conversationCanSend,
            isPromptSubmissionPending: isPromptSubmissionPending
        )
    }

    var shouldPresentInputControl: Bool {
        MobileCollaborationPresentation.showsInputControl(
            featureSupported: supportsFocusedInputControl,
            capability: capability,
            state: inputControl
        )
    }

    func terminalInputMode(settingEnabled: Bool) -> MobileTerminalInputMode {
        MobileCollaborationPresentation.terminalInputMode(
            settingEnabled: settingEnabled,
            supportsAtomicSubmission: supportsAtomicTerminalSubmission,
            capability: capability,
            inputControlFeatureSupported: supportsFocusedInputControl,
            canWrite: inputControl?.canWrite != false,
            state: inputControl
        )
    }

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        reconnectClient: (@MainActor () async -> RemoteClient?)? = nil,
        helloDeadline: Duration = RemoteMobileConnectionDefaults.helloDeadline
    ) {
        self.session = session
        self.client = client
        self.reconnectClient = reconnectClient
        self.helloDeadline = helloDeadline
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
        supportsComposerAttachmentUploads = false
        supportsAtomicTerminalSubmission = false
        supportsAttentionRequests = false
        supportsFocusedInputControl = false
        inputControl = nil
        inputControlEvents = []
        attentionRecipients = []
        MobileDiagnostics.record(.socketConnecting, fields: destinationFields.merging([
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ]) { current, _ in current })
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
            armHelloDeadline(generation: generation)
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
            cancelHelloDeadline()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
            scheduleReconnect(generation: generation)
        }
    }

    /// Every connect ends in a terminal event, including the one nobody answers.
    private func armHelloDeadline(generation: Int) {
        helloDeadlineTask?.cancel()
        let deadline = helloDeadline
        helloDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.helloDeadlineExpired(generation: generation)
        }
    }

    private func cancelHelloDeadline() {
        helloDeadlineTask?.cancel()
        helloDeadlineTask = nil
    }

    private func helloDeadlineExpired(generation: Int) {
        guard !stopped, connectionGeneration == generation, phase != .connected else { return }
        helloDeadlineTask = nil
        // A socket that has not greeted us by now is not going to. Declaring the connection
        // failed also ends it, rather than leaving a receive loop awaiting a frame forever,
        // which is the shape of the bug this deadline exists to close.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        fail(with: .helloTimeout())
        scheduleReconnect(generation: generation)
    }

    func disconnect(markEnded: Bool = true) {
        reportTyping(false)
        if phase == .connected, capability == .interact, pendingViewport != nil {
            try? send(RemoteClientMessage(type: "viewportRelease"))
        }
        connectionGeneration &+= 1
        stopped = true
        cancelHelloDeadline()
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
        contextAttachments: [RemoteConversationContextAttachmentDTO] = [],
        attachmentUploadIDs: [String] = []
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false,
              contextAttachments.isEmpty || serverFeatures.contains(
                  RemoteWebSocketFeature.conversationContextAttachments.rawValue
              ),
              attachmentUploadIDs.isEmpty || supportsComposerAttachmentUploads,
              conversationStore.state.canSend else { return nil }
        return sendSubmission(
            type: "submit",
            text: trimmed,
            contextAttachments: contextAttachments,
            attachmentUploadIDs: attachmentUploadIDs,
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
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
            return nil
        }
    }

    private func sendSubmission(
        type: String,
        text: String,
        contextAttachments: [RemoteConversationContextAttachmentDTO] = [],
        attachmentUploadIDs: [String] = [],
        permitsLegacyHost: Bool
    ) -> String? {
        guard phase == .connected, capability == .interact,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !contextAttachments.isEmpty
                || !attachmentUploadIDs.isEmpty,
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
                contextAttachments: contextAttachments.isEmpty ? nil : contextAttachments,
                attachmentUploadIDs: attachmentUploadIDs.isEmpty ? nil : attachmentUploadIDs
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
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
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
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
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
                self.fail(
                    with: RemoteConnectionFailure.transport(
                        error,
                        host: self.destinationHost
                    ),
                    httpStatus: Self.httpStatus(of: task)
                )
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
            fail(
                with: RemoteConnectionFailure.transport(error, host: destinationHost),
                httpStatus: Self.httpStatus(of: task)
            )
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

#if DEBUG
    /// Feeds one server frame through the same handler a real socket frame reaches.
    ///
    /// Refusal policy is the part of this class most worth asserting and the part hardest to
    /// reach: it needs a Mac that answers. Kept out of release builds so nothing shipping can
    /// inject server state.
    func receiveServerTextForTesting(_ text: String) {
        handle(text)
    }
#endif

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

#if DEBUG
    /// Drives the UI half of a reconnect performance fixture after the initial conversation has
    /// fully mounted. The socket's transport/hydration cost has its own host-side benchmark; this
    /// boundary deliberately exercises the same published phase changes and authoritative store
    /// replacement that the mounted UIKit surface observes.
    @discardableResult
    func performReconnectPerformanceFixture(
        snapshot: RemoteConversationSnapshotDTO
    ) -> Bool {
        phase = .failed(.transport("Performance fixture reconnect"))
        phase = .connecting
        composerCapabilities = []
        supportsAtomicTerminalSubmission = false
        supportsAttentionRequests = false
        supportsFocusedInputControl = false
        inputControl = nil
        attentionRecipients = []

        phase = .connected
        supportsAttentionRequests = true
        supportsFocusedInputControl = true
        let change = conversationStore.replace(with: snapshot)
        composerCapabilities = snapshot.composerCapabilities
        if case .reset = change { return true }
        return false
    }
#endif

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
            supportsComposerAttachmentUploads = serverFeatures.contains(
                RemoteWebSocketFeature.composerAttachmentUploads.rawValue
            )
            updateTerminalGrid(cols: hello.cols, rows: hello.rows)
            cancelHelloDeadline()
            phase = .connected
            reconnectAttempt = 0
            MobileDiagnostics.record(.socketConnected, fields: destinationFields.merging([
                .capability: hello.capability,
                .surface: hello.surface.rawValue,
            ]) { current, _ in current })
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
                   surface == .terminal, capability == .interact {
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
            // Two refusals are ordinary traffic on a healthy socket rather than reasons to tear
            // the session down. `permissionNotPending` is another paired client answering the
            // same visible card first, whose authoritative snapshot follows immediately.
            // `invalidViewport` is this phone asking for a grid the Mac will not accept, which
            // costs the terminal a resize and nothing else; ending the session over it took the
            // conversation, the composer and the scrollback with it.
            if !Self.survivableErrorCodes.contains(error?.code ?? "") {
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
                fail(with: .remoteAction(message), code: error?.code ?? "remote.actionFailed")
            } else {
                reportSurvivableRefusal(error)
            }
        default:
            break
        }
    }

    /// Refusals a healthy socket may carry. Everything else still fails the session.
    private static let survivableErrorCodes: Set<String> = [
        "permissionNotPending",
        "invalidViewport",
    ]

    /// A refusal the session survives is still evidence. The Mac names the guard clause it
    /// failed, so the phone's log can say which one rather than only that a viewport was
    /// rejected.
    private func reportSurvivableRefusal(_ error: RemoteErrorDTO?) {
        guard let error else { return }
        MobileDiagnostics.logDegraded(
            .sessionRefusal,
            code: error.code,
            detail: error.detail
        )
    }

    /// The one place a connection becomes terminal.
    ///
    /// Phase and journal entry move together so a failure cannot reach the screen without
    /// reaching the report, which is how the 2026-08-17 incident produced a phone stuck on
    /// "Connecting…" and a journal with nothing after `socketConnecting`.
    private func fail(
        with failure: RemoteConnectionFailure,
        code: String? = nil,
        httpStatus: Int? = nil
    ) {
        phase = .failed(failure)
        var fields = destinationFields
        fields[.code] = code ?? "connection.\(failure.cause.rawValue)"
        fields[.reason] = failure.cause.rawValue
        // Whether the identity check passed, refused, or never ran. A token, never a
        // fingerprint: the certificate is not a fact a support bundle carries, and without this
        // a refused pin and an ordinary cancelled request are the same line in the journal.
        if let host = destinationHost,
           let verdict = RemoteClient.pinningDelegate.verdict(forHost: host) {
            fields[.detail] = RemoteHostTrust.token(for: verdict)
        }
        // 530, 502 and 404 behind the same -1011 mean three different things: an origin that is
        // gone, something on the path that could not reach it, and something else answering on
        // that address entirely.
        if let httpStatus { fields[.status] = String(httpStatus) }
        MobileDiagnostics.record(.socketFailed, level: .error, fields: fields)
    }

    private func recordSocketFailure(_ error: Error) {
        var fields = destinationFields
        fields[.code] = MobileDiagnostics.errorCode(error)
        MobileDiagnostics.record(.socketFailed, level: .error, fields: fields)
    }

    /// Which session, which kind of address, and which address, as a hash.
    ///
    /// Without the last two, "wrong address" and "right address, host down" are the same record
    /// in a support report and have opposite fixes.
    private var destinationFields: [RemoteDiagnosticField: String] {
        [
            .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
            .transport: PairedRemoteHost.endpointKind(for: client.link.baseURL),
            .origin: MobileDiagnostics.originDigest(client.link.baseURL),
        ]
    }

    private var destinationHost: String? { client.link.baseURL.host }

    /// The status URLSession kept from a handshake that was answered but not upgraded.
    ///
    /// `URLSessionWebSocketTask` reports the refusal as `NSURLErrorBadServerResponse` and puts
    /// the real response on the task, which is the only place the status survives.
    private static func httpStatus(of task: URLSessionWebSocketTask) -> Int? {
        (task.response as? HTTPURLResponse)?.statusCode
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
    private static func ownerOnlyInputControlState() -> RemoteInputControlStateDTO {
        RemoteInputControlStateDTO(
            mode: .collaborative,
            currentParticipantID: RemoteCollaborationParticipantDTO.ownerID,
            canWrite: true,
            canManage: true,
            canHandOff: false,
            participants: [
                .init(
                    id: RemoteCollaborationParticipantDTO.ownerID,
                    displayName: "David",
                    role: "owner",
                    isOnline: true
                ),
            ],
            revision: 0
        )
    }

    static func demoTerminal() -> RemoteSessionConnection {
        let demoMode = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"] ?? ""
        let isCodexFixture = demoMode == "terminal-ansi"
            || demoMode == "terminal-codex-tui"
        let agentName = isCodexFixture ? "Codex" : "Claude Code"
        let session = RemoteSessionSummaryDTO(
            id: "f50c77da-5716-470b-933c-d68310644b4f",
            title: "\(agentName) · AnotherTerminal",
            agentKind: isCodexFixture ? "codex" : "claude",
            surface: .terminal,
            state: "running",
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.invalid/#terminal-preview")!
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link)
        )
        connection.phase = .connected
        connection.surface = .terminal
        connection.capability = .interact
        let usesThreadingTheme = ProcessInfo.processInfo.environment["THREADING_MOBILE_THEME"]
            == "threading"
        connection.theme = usesThreadingTheme
            ? RemoteAppModel.demoThreadingTheme
            : RemoteAppModel.demoTheme
        connection.terminalTheme = usesThreadingTheme
            ? RemoteAppModel.demoThreadingTerminalTheme
            : RemoteAppModel.demoTerminalTheme
        connection.terminalColumns = 48
        connection.terminalRows = 18
        connection.serverFeatures = Set(RemoteWebSocketFeature.allCases.map(\.rawValue))
        connection.supportsAtomicTerminalSubmission = true
        connection.supportsAttentionRequests = true
        connection.supportsFocusedInputControl = true
        connection.inputControl = ownerOnlyInputControlState()
        let lines: [String]
        switch demoMode {
        case "terminal-ansi":
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;36mCodex\u{1b}[0m  ANSI and Unicode fixture",
                "",
                "\u{1b}[32m✓ build\u{1b}[0m  \u{1b}[33m⚠ 2 warnings\u{1b}[0m  \u{1b}[31m✗ 1 failure\u{1b}[0m",
                "",
                "Palette  \u{1b}[31mred\u{1b}[0m \u{1b}[32mgreen\u{1b}[0m \u{1b}[34mblue\u{1b}[0m \u{1b}[35mmagenta\u{1b}[0m",
                "Unicode  café · 東京 · 🙂 · λ → ∑",
                "",
                "Wrapping a deliberately long command keeps the final flag and quoted value visible instead of clipping at the phone edge:",
                "$ swift test --filter RemoteKeyboardLifecycleTests --parallel",
                "",
                "Progress [########################] 100%",
                "\u{1b}[1;31merror:\u{1b}[0m expected keyboard inset to return to zero",
                "  Sources/ThreadingMobile/Composer.swift:128:9",
                "",
                "❯ ",
            ]
        case "terminal-codex-tui":
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;36mCodex\u{1b}[0m  AnotherTerminal",
                "\u{1b}[2mGPT-5.6 Sol · high reasoning\u{1b}[0m",
                "",
                "› Make keyboard dismissal deterministic and",
                "  add visual regression evidence.",
                "",
                "• Inspected the composer and evidence harness",
                "• Fixed the keyboard notification lifecycle",
                "• Added open, dismissed, and multiline cases",
                "",
                "\u{1b}[32m✓ xcodebuild ThreadingMobileTests\u{1b}[0m",
                "\u{1b}[32m✓ 58 evidence captures\u{1b}[0m",
                "",
                "Ready for review.  4 files changed",
                "› ",
            ]
        case "terminal-claude-tui":
            // Keep Claude's actual one-cell marker in the fixture. SwiftTerm's renderer requests
            // text presentation for narrow emoji-capable symbols, while genuine wide emoji stay
            // color; substituting a safer bullet here would stop the evidence from testing that.
            let completedTool = "\u{23FA}"
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;35mClaude Code\u{1b}[0m",
                "\u{1b}[2mSonnet · plan mode · AnotherTerminal\u{1b}[0m",
                "",
                "❯ Review the mobile Git pane at 20k files.",
                "",
                "\u{1b}[35m\(completedTool)\u{1b}[0m  Read(RemoteGitReviewView.swift)",
                "   ⎿ Read 912 lines",
                "\u{1b}[35m\(completedTool)\u{1b}[0m  Search(ReviewScrollBottomReader)",
                "   ⎿ Found 4 matches",
                "\u{1b}[35m\(completedTool)\u{1b}[0m  Update(RemoteGitReviewView.swift)",
                "   ⎿ Virtualized visible rows",
                "     Added a conditional jump control",
                "",
                "● The list now allocates visible rows only, and",
                "  shows the jump control only for content below.",
                "",
                "\u{1b}[32m✓ swift test --filter GitReview\u{1b}[0m",
                "",
                "────────────────────────────────────────",
                "❯ ",
            ]
        case "terminal-scrollback":
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;36mClaude Code\u{1b}[0m  Test run",
                "$ xcodebuild -scheme ThreadingMobile test",
                "Compile RemoteConversationViewController.swift",
                "Compile RemoteNotifications.swift",
                "Link ThreadingMobileTests.xctest",
                "Test Suite 'KeyboardLifecycleTests' started",
                "  ✓ testConversationRestoresComposerGeometry (0.42s)",
                "  ✓ testTerminalDismissesSoftwareKeyboard (0.31s)",
                "  ✓ testPairingLinkFieldReturnsToBaseline (0.18s)",
                "  ✓ testIssueReportEditorReturnsToBaseline (0.29s)",
                "",
                "Executed 48 tests, with 0 failures in 4.812 seconds",
                "\u{1b}[32m** TEST SUCCEEDED **\u{1b}[0m",
                "",
                "❯ git status --short",
                " M Tests/UIEvidence/ios-coverage.json",
                " M scripts/ui-evidence-ios.sh",
                "❯ ",
            ]
        default:
            lines = [
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
        }
        connection.pendingTerminalOutput = Data(lines.joined(separator: "\r\n").utf8)
        guard demoMode == "terminal-collaboration" else { return connection }
        let anna = RemotePresenceDTO(
            presenceID: "terminal-anna",
            memberID: "member-anna",
            displayName: "Anna",
            deviceName: "iPhone",
            surface: .terminal,
            state: "typing"
        )
        let ipad = RemotePresenceDTO(
            presenceID: "terminal-ipad",
            memberID: "member-david",
            displayName: "David",
            deviceName: "iPad",
            surface: .terminal,
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
            || demoMode == "conversation-reconnect-stress"
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
            surface: .conversation,
            state: "idle",
            projectName: "AnotherTerminal"
        )
        let link = RemoteConnectionLink(string: "https://demo.invalid/#preview")!
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link)
        )
        connection.phase = .connected
        connection.surface = .conversation
        connection.capability = .interact
        connection.serverFeatures = Set(RemoteWebSocketFeature.allCases.map(\.rawValue))
        connection.supportsAttentionRequests = true
        connection.supportsFocusedInputControl = true
        connection.inputControl = ownerOnlyInputControlState()
        switch environment["THREADING_MOBILE_THEME"] {
        case "light":
            connection.theme = RemoteAppModel.demoLightTheme
            connection.terminalTheme = RemoteAppModel.demoTerminalTheme
        case "threading":
            connection.theme = RemoteAppModel.demoThreadingTheme
            connection.terminalTheme = RemoteAppModel.demoThreadingTerminalTheme
        case let requestedTheme?:
            connection.theme = RemoteAppModel.demoCatalogThemes.first(where: {
                $0.id == requestedTheme
            }) ?? RemoteAppModel.demoTheme
            connection.terminalTheme = RemoteAppModel.demoTerminalTheme
        default:
            connection.theme = RemoteAppModel.demoTheme
            connection.terminalTheme = RemoteAppModel.demoTerminalTheme
        }
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
        let contentRows: [RemoteConversationRowDTO] = [
            .init(
                id: "content-user",
                kind: "user",
                text: "Review the keyboard lifecycle, quote the relevant file, and run the focused tests."
            ),
            .init(
                id: "content-thinking",
                kind: "thinking",
                text: "I need to trace first-responder ownership and compare the editor frame before and after dismissal."
            ),
            .init(
                id: "content-tool-success",
                kind: "tool",
                toolName: "Read",
                summary: "RemoteConversationViewController.swift · 164 lines",
                result: "Found keyboard frame observation and the composer bottom constraint."
            ),
            .init(
                id: "content-tool-error",
                kind: "tool",
                toolName: "Bash",
                summary: "swift test --filter KeyboardLifecycleTests",
                result: "Exit 1 · editor stayed 291 pt above its baseline",
                isError: true
            ),
            .init(
                id: "content-notice",
                kind: "notice",
                text: "The connection recovered. Tool output before the reconnect was preserved."
            ),
            .init(
                id: "content-assistant",
                kind: "assistant",
                text: """
                Keyboard lifecycle passed: focus waits for `keyboardDidShow`, dismissal waits for
                `keyboardDidHide`, and the composer returns to its original visual anchor.
                """
            ),
        ]
        let richContentRows: [RemoteConversationRowDTO] = [
            .init(
                id: "rich-user",
                kind: "user",
                text: "Show the release result with the structure and code intact."
            ),
            .init(
                id: "rich-assistant",
                kind: "assistant",
                text: """
                ## Release review

                > Keyboard dismissal is now a measured lifecycle, not a delay.

                - **Focus:** waits for the real keyboard
                - **Dismissal:** clears the editor responder
                - **Layout:** returns to its stable anchor

                ```swift
                focus.wrappedValue = false
                window.endEditing(true)
                ```

                See `RemoteNotifications.swift` for the shared evidence contract.
                """
            ),
        ]
        let attachmentRows: [RemoteConversationRowDTO] = [
            .init(
                id: "attachment-user",
                kind: "user",
                text: "Compare the visual review with the implementation and keep the linked evidence together.",
                contextAttachments: [
                    .init(
                        id: "attachment-image",
                        kind: "reference",
                        source: "attachment",
                        title: "keyboard-dismissed.png",
                        excerpt: "1179 × 2556 PNG · 184 KB",
                        locator: "screenshots/keyboard-dismissed.png"
                    ),
                    .init(
                        id: "attachment-pdf",
                        kind: "reference",
                        source: "attachment",
                        title: "threading-ui-review.pdf",
                        excerpt: "12-page review · 843 KB",
                        locator: "artifacts/threading-ui-review.pdf"
                    ),
                    .init(
                        id: "attachment-code",
                        kind: "comment",
                        source: "code",
                        title: "RemoteConversationViewController.swift",
                        comment: "Keep the composer anchored after keyboard dismissal.",
                        locator: "Sources/ThreadingMobile/RemoteConversationViewController.swift",
                        lineStart: 128,
                        lineEnd: 156
                    ),
                ]
            ),
            .init(
                id: "attachment-assistant",
                kind: "assistant",
                text: "The image, PDF, and code reference remain attached to the originating prompt, including their provenance and bounded locators."
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
        } else if ["conversation-content-types", "conversation-tool-expanded"].contains(demoMode) {
            rows = contentRows
        } else if demoMode == "conversation-attachments" {
            rows = attachmentRows
        } else if demoMode == "conversation-away-from-latest" {
            rows = (0..<28).map { index in
                RemoteConversationRowDTO(
                    id: "latest-\(index)",
                    kind: index.isMultiple(of: 5) ? "user" : "assistant",
                    text: index.isMultiple(of: 5)
                        ? "Checkpoint \(index): keep my reading position while more work arrives."
                        : "Verified checkpoint \(index). The timeline remains virtualized and the latest-message control only appears away from the bottom."
                )
            }
        } else if demoMode == "conversation-rich-content" {
            rows = richContentRows
        } else if demoMode == "conversation-streaming" {
            rows = [
                .init(
                    id: "stream-user",
                    kind: "user",
                    text: "Check the compact layout while the agent is still responding."
                ),
                .init(
                    id: "stream-tool",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "xcodebuild -scheme ThreadingMobile build",
                    result: "Build Succeeded"
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
        let conversationSnapshot = RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: demoMode == "conversation-streaming"
                ? "I’m checking the keyboard-safe-area transaction and comparing the composer’s baseline frame…"
                : "",
            canSend: demoMode != "conversation-streaming",
            composerCapabilities: capabilities,
            hasEarlier: demoMode == "conversation-cold-stress"
                && sourceRowCount > rows.count
        )
        connection.conversationStore.replace(with: conversationSnapshot)
        if isPerformanceFixture {
            let storeEnded = ProcessInfo.processInfo.systemUptime
            MobileConversationPerformanceProbe.fixtureDidLoad(
                mode: demoMode,
                sourceRows: sourceRowCount,
                mountedRows: rows.count,
                startedAt: fixtureStarted,
                generationMilliseconds: (storeStarted - fixtureStarted) * 1_000,
                storeMilliseconds: (storeEnded - storeStarted) * 1_000,
                reconnect: demoMode == "conversation-reconnect-stress"
                    ? { [weak connection] in
                        connection?.performReconnectPerformanceFixture(
                            snapshot: conversationSnapshot
                        ) ?? false
                    }
                    : nil
            )
        }
        if ["conversation-collaboration", "attention-request"].contains(demoMode) {
            let anna = RemotePresenceDTO(
                presenceID: "presence-anna",
                memberID: "member-anna",
                displayName: "Anna",
                deviceName: "Anna’s iPhone",
                surface: .conversation,
                state: "typing"
            )
            let ipad = RemotePresenceDTO(
                presenceID: "presence-ipad",
                memberID: "owner-ipad",
                displayName: "David’s iPad",
                deviceName: "David’s iPad",
                surface: .conversation,
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
        let usesLongFixture = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
            == "permission-long"
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
                toolName: usesLongFixture ? "Bash" : "Edit",
                summary: usesLongFixture
                    ? "Run the complete mobile evidence matrix, compare keyboard geometry before and after every focus transition, and write the generated report under .build without changing repository baselines"
                    : "Sources/ThreadingMobile/RemoteSessionConnection.swift",
                filePath: usesLongFixture
                    ? "scripts/ui-evidence-ios.sh --only native-conversation --verify-keyboard-lifecycle --report .build/ui-evidence-ios-reports/review/index.html"
                    : "RemoteSessionConnection.swift",
                diff: usesLongFixture ? [
                    .init(id: "0", kind: "context", text: "# This command runs deterministic local fixtures only."),
                    .init(id: "1", kind: "addition", text: "THREADING_UI_EVIDENCE_VERIFY_KEYBOARD=1 scripts/ui-evidence-ios.sh"),
                    .init(id: "2", kind: "addition", text: "open .build/ui-evidence-ios-reports/latest/report/index.html"),
                ] : [
                    .init(id: "0", kind: "removal", text: "onTerminalOutput?(data)"),
                    .init(id: "1", kind: "addition", text: "pendingTerminalOutput.append(data)"),
                ]
            )
        ))
        return connection
    }
#endif
}
