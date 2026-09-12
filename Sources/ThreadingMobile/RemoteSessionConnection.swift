import Foundation
import ThreadingRemoteKit
#if canImport(UIKit)
import UIKit
#endif

/// Interaction timing writes are ordered, but never run on the phone UI actor whose latency they
/// measure. `RemoteDiagnosticJournal.record` performs a synchronous file append.
private let remoteInteractionDiagnosticQueue = DispatchQueue(
    label: "codes.threading.mobile-diagnostics.interaction"
)

enum RemoteWireEncodingFailure: LocalizedError, Equatable, Sendable {
    case backpressure
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .backpressure:
            return "The remote connection stopped accepting messages."
        case .encodingFailed:
            return "Threading could not encode a remote message."
        }
    }
}

/// One ordered, bounded JSON lane for a session socket.
///
/// A prompt or snapshot can carry externally sized strings, so encoding never belongs to the
/// main actor. Calls are admitted synchronously in O(1), encoded in admission order, and dropped
/// when their connection generation is retired. The class is `@unchecked Sendable` because its
/// only mutable state is confined by `stateLock`, while `encodingQueue` owns codec execution.
final class RemoteWireEncodingLane: @unchecked Sendable {
    typealias Completion = @Sendable (Result<String, RemoteWireEncodingFailure>) -> Void

    private let encodingQueue: DispatchQueue
    private let stateLock = NSLock()
    private let maximumPendingMessages: Int
    private var currentGeneration: Int
    private var pendingMessages = 0

    init(
        label: String,
        generation: Int = 0,
        maximumPendingMessages: Int = RemoteMobileConnectionDefaults.maximumPendingWireMessages
    ) {
        encodingQueue = DispatchQueue(label: label, qos: .userInitiated)
        currentGeneration = generation
        self.maximumPendingMessages = max(1, maximumPendingMessages)
    }

    /// Retires queued work from the previous socket without waiting for codec work on the UI
    /// actor. Already-enqueued closures observe the new generation and return before encoding.
    func advance(to generation: Int) {
        stateLock.lock()
        currentGeneration = generation
        pendingMessages = 0
        stateLock.unlock()
    }

    /// A successful return transfers ownership: the lane will either deliver the encoded text
    /// or discard it because its socket generation was retired.
    func enqueue<Message: Encodable & Sendable>(
        _ message: Message,
        generation: Int,
        completion: @escaping Completion
    ) throws {
        stateLock.lock()
        guard generation == currentGeneration else {
            stateLock.unlock()
            return
        }
        guard pendingMessages < maximumPendingMessages else {
            stateLock.unlock()
            throw RemoteWireEncodingFailure.backpressure
        }
        pendingMessages += 1
        stateLock.unlock()

        encodingQueue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let result: Result<String, RemoteWireEncodingFailure>
            do {
                result = .success(String(decoding: try JSONEncoder().encode(message), as: UTF8.self))
            } catch {
                result = .failure(.encodingFailed(error.localizedDescription))
            }
            guard self.completeIfCurrent(generation) else { return }
            completion(result)
        }
    }

    /// Places an already encoded frame in the same order as JSON work. Demo terminal payloads
    /// use this path so a binary replay cannot overtake the `hello` text frame that authorizes
    /// it merely because the replay itself needs no codec work.
    func enqueuePrepared(
        generation: Int,
        completion: @escaping @Sendable () -> Void
    ) throws {
        stateLock.lock()
        guard generation == currentGeneration else {
            stateLock.unlock()
            return
        }
        guard pendingMessages < maximumPendingMessages else {
            stateLock.unlock()
            throw RemoteWireEncodingFailure.backpressure
        }
        pendingMessages += 1
        stateLock.unlock()

        encodingQueue.async { [weak self] in
            guard let self, self.completeIfCurrent(generation) else { return }
            completion()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == currentGeneration
    }

    private func completeIfCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == currentGeneration else { return false }
        pendingMessages = max(0, pendingMessages - 1)
        return true
    }
}

enum RemoteMobileConnectionDefaults {
    static let conversationPageRows = 64
    static let runPlanPageSteps = 64
    static let runPlanMaximumSteps = 256
    static let runPlanMaximumTitleUTF8Bytes = 4_096
    static let runPlanMaximumIdentifierUTF8Bytes = 1_024
    static let maximumPendingWireMessages = 64
    /// How much of the Mac's replay this phone asks for when it joins a terminal.
    ///
    /// The emulator here keeps SwiftTerm's default 500-line scrollback, so the Mac's whole
    /// 512 KB ring was parsed in full and then immediately trimmed down to that — 330–350 ms of
    /// main-thread work at chat entry, most of it thrown away. This comfortably fills the
    /// scrollback the phone actually keeps plus the visible screen, and brings the parse down to
    /// roughly a third of that even counting the repaint the Mac sends after a cut replay — so a
    /// shorter replay is not a dimmer one, only a cheaper one.
    static let terminalReplayBudgetBytes = 128 * 1024
    /// How long a return from the background waits for the socket to answer a ping before
    /// treating it as dead and reconnecting.
    static let resumeLivenessDeadline: Duration = .seconds(1)
    /// Direct terminal input stays fire-and-forget. One write per interval carries an opaque
    /// diagnostic request id so a support capture can measure host admission without adding an
    /// acknowledgement or journal record for every keystroke.
    static let terminalInputProbeIntervalNanoseconds: UInt64 = 5_000_000_000
    static let terminalInputProbeTimeout: Duration = .seconds(10)
    /// A background longer than this has almost certainly cost the socket on the Mac's side
    /// while the phone's side still looks alive; asking is slower than reconnecting.
    static let reconnectOutrightAfterBackground: TimeInterval = 30
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
    /// Once the host has explicitly accepted this socket into a session startup transaction,
    /// provider history loading may outlive an ordinary route handshake.
    // Slightly longer than the host's 60-second ownership window, so its authoritative timeout
    // frame/close wins over a client-side transport race on a slow link.
    static let startupHelloDeadline: Duration = .seconds(65)
    /// How long a phone-owned grid must hold still before it is leased to the Mac.
    ///
    /// A pinch, a keyboard, or an animated layout reports one grid per crossed cell boundary,
    /// and the Mac's journal showed nineteen leases from a single gesture. Every lease
    /// soft-resets and reflows the Mac's emulator and SIGWINCHes the agent into a whole-screen
    /// repaint, which is work only the settled grid deserves — the browser client has debounced
    /// its fit for the same reason all along. The first grid of a lease still goes immediately,
    /// so entering a chat sizes the agent without waiting out a quiet window.
    static let viewportSettleDelay: Duration = .milliseconds(150)
    /// Compatibility fallback for a host that predates the ordered terminal hydration boundary.
    /// Initial replay and resize repair remain one presentation transaction, but only an older
    /// host makes the phone infer its end from wire silence.
    static let terminalHydrationQuietDelay: Duration = .seconds(1)
    /// A chat that is already producing an unbounded stream must eventually become visible.
    static let terminalHydrationMaximumDelay: Duration = .seconds(4)
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
        preference: MobileTerminalInputPreference,
        supportsAtomicSubmission: Bool,
        capability: RemoteCapability,
        inputControlFeatureSupported: Bool,
        canWrite: Bool,
        state: RemoteInputControlStateDTO?
    ) -> MobileTerminalInputMode {
        guard capability == .interact else { return .none }
        guard supportsAtomicSubmission else {
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
        guard canWrite else { return .none }
        return preference == .compose ? .independentComposer : .direct
    }
}

/// How this iPhone prefers to type into one real terminal UI while no collaboration policy has
/// to override it. It is device-local presentation state: changing it neither mutates nor
/// restarts the Mac session.
enum MobileTerminalInputPreference: String, Codable, Equatable, Sendable {
    case direct
    case compose

    static let defaultPreferenceKey = "threading.mobile.terminal-input.default"
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

enum RemoteLiveConnectionTarget: Equatable {
    case session(String)
    case projectTerminal(String)
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
    let contextAttachments: [RemoteConversationContextAttachmentDTO]
    let attachmentUploadIDs: [String]
    let createdAt: Date
    let startedAtNanoseconds: UInt64
}

private struct PendingTerminalInputProbe {
    let requestID: String
    let startedAtNanoseconds: UInt64
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

/// Minimal typed dispatch for the session socket.
///
/// Visit fields are decoded only for their own message because established run-plan frames use
/// the same `revision` key for a scalar edition. Keeping this pure parser outside the main-actor
/// connection also keeps keyed decoding out of the UI coordination boundary.
private struct RemoteSessionServerEnvelope: Decodable {
    let type: String
    let session: RemoteSessionSummaryDTO?
    let revision: RemoteCatalogueRevisionDTO?
    let receiptCommitted: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case revision
        case receiptCommitted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if type == "sessionVisited" {
            session = try container.decodeIfPresent(
                RemoteSessionSummaryDTO.self,
                forKey: .session
            )
            revision = try container.decodeIfPresent(
                RemoteCatalogueRevisionDTO.self,
                forKey: .revision
            )
            receiptCommitted = try container.decodeIfPresent(
                Bool.self,
                forKey: .receiptCommitted
            )
        } else {
            session = nil
            revision = nil
            receiptCommitted = nil
        }
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

    private enum WarmTransportState: Equatable {
        case active
        case parking
        case parked
        case resuming
    }

    @Published private(set) var phase: Phase = .connecting
    /// What the mirrored surface calls itself right now — a terminal's OSC title as the agent
    /// sent it, or the name the Mac put in `hello`. **Not the session's name**, which is the
    /// catalogue's `displayTitle`: the Mac strips a caption's decoration, ignores the ones that
    /// name the product or the working directory, and applies the user's choice about agent
    /// titles before a row is named, and none of that has happened to this string. Chrome asks
    /// `MobileSessionChrome.navigationTitle(for:in:liveTitle:)`, which is why this is not called
    /// `title`: read as a title it made one chat answer to two names.
    @Published private(set) var mirroredCaption: String
    @Published private(set) var surface: RemoteSessionSurface
    @Published private(set) var capability: RemoteCapability = .view
    @Published private(set) var theme: RemoteThemeDTO?
    @Published private(set) var terminalTheme: RemoteTerminalThemeDTO?
    @Published private(set) var terminalColumns = 0
    @Published private(set) var terminalRows = 0
    @Published private(set) var isTerminalHydrating: Bool
    /// True once a mounted terminal has drawn this connection's output. A reconnect then has a
    /// screen worth keeping on display, and holds its replay until hydration completes.
    @Published private(set) var hasPresentedTerminalOutput = false
    /// True while a reconnect keeps the previous screen on display with its replay held. The
    /// surface dims and softens only then — an opening whose replay streams in live shows the
    /// loader, not a blur over the text arriving behind it.
    @Published private(set) var holdsPreviousScreen = false
    /// True once a hello has been answered: the next `.connecting` is a reconnect, not an
    /// opening, and is named as one.
    @Published private(set) var hasEverConnected = false
    /// Set as the app resigns active and cleared once the connection has proven itself again —
    /// a pong, or a completed reconnect. The terminal surface keeps its last screen locked
    /// under the loader for the whole span, so the snapshot iOS shows on return is already the
    /// softened one rather than sharp text that blurs a moment later.
    @Published private(set) var isAwaitingResume = false
    private var resumeProbeGeneration: Int?
    private var backgroundedAt: Date?
    @Published private(set) var conversationCanSend = false
    @Published private(set) var composerCapabilities: [RemoteComposerCapabilityDTO] = []
    @Published private(set) var presence: [String: RemotePresenceDTO] = [:]
    @Published private(set) var isPromptSubmissionPending = false
    @Published private(set) var promptSubmissionFeedback: RemotePromptSubmissionFeedback?
    @Published private(set) var supportsAtomicTerminalSubmission = false
    @Published private(set) var supportsAttentionRequests = false
    @Published private(set) var supportsFocusedInputControl = false
    @Published private(set) var supportsSessionConnectionParking = false
    /// Whether this connection may hand the Mac files to send with a prompt. False for a
    /// view-only or guest link, which the host never advertises the feature to — so the composer
    /// draws no attach button rather than one that would be refused.
    @Published private(set) var supportsComposerAttachmentUploads = false
    /// Direct-input terminals use a separate negotiated mutation: uploaded files enter the
    /// workspace and their paths are inserted at the TUI cursor without an implicit Return.
    @Published private(set) var supportsTerminalAttachmentInsertion = false
    @Published private(set) var supportsRunPlanProgress = false
    @Published private(set) var runPlan: RemoteRunPlanSummaryDTO?
    @Published private(set) var runPlanSteps: [RemoteRunPlanStepDTO] = []
    @Published private(set) var inputControl: RemoteInputControlStateDTO?
    @Published private(set) var inputControlEvents: [RemoteInputControlEventDTO] = []
    @Published private(set) var inputControlResult: RemoteInputControlResultDTO?
    @Published private(set) var attentionRecipients: [RemoteCollaborationParticipantDTO] = []
    @Published private(set) var attentionEvents: [RemoteAttentionEventDTO] = []
    @Published private(set) var isAttentionRequestPending = false
    @Published private(set) var attentionRequestFeedback: RemoteAttentionRequestFeedback?

    let session: RemoteSessionSummaryDTO
    let target: RemoteLiveConnectionTarget
    let conversationStore = RemoteConversationStore()
    private var client: RemoteClient
    private let reconnectClient: (
        @MainActor (MobileSessionReconnectRequest) async -> RemoteClient?
    )?
    private let deviceID: String
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Armed by `connect()`, disarmed by the `hello` frame, and the only thing that turns a
    /// socket the Mac never greets into a terminal state.
    private var helloDeadlineTask: Task<Void, Never>?
    private let helloDeadline: Duration
    private var reconnectAttempt = 0
    private var reconnectSequence = 0
    /// Whether the loss being recovered from ended with the Mac's close frame. Read off the task
    /// before anything cancels it, because `cancel(with:)` writes a close code of its own.
    private var lossPeerSentClose = false
    private var socketTrace: String?
    private var socketStartedAt: UInt64?
    private var socketAttempt = 1
    private var sessionResumeTrace: String?
    private var sessionResumeStartedAt: UInt64?
    private var stopped = false
    private var connectionGeneration = 0
    private let wireEncodingLane = RemoteWireEncodingLane(
        label: "codes.threading.mobile-session-wire.encode"
    )
    private var pendingTerminalOutput = Data()
    /// Set by a reconnect whose terminal already shows something: output is held rather than
    /// delivered until hydration completes, then arrives behind one reset.
    private var holdsReplayForHydration = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let pendingTerminalOutputLimit = 2 * 1_024 * 1_024
    /// The mounted SwiftTerm view that owns terminal delivery and the phone's viewport lease.
    ///
    /// UIKit may finish dismantling an outgoing representable after SwiftUI has already mounted
    /// its replacement on this same warm connection. Teardown therefore has to name the view it
    /// is tearing down: an older view must not clear the replacement's callbacks or release the
    /// viewport it just acquired.
    private var terminalRendererOwner: ObjectIdentifier?
    private let terminalHydrationQuietDelay: Duration
    private let terminalHydrationMaximumDelay: Duration
    private var terminalHydrationQuietTask: Task<Void, Never>?
    private var terminalHydrationMaximumTask: Task<Void, Never>?
    private var hasReceivedTerminalHydrationOutput = false
    private var terminalHydrationRequestID: String?
    private var pendingTerminalReady: RemoteTerminalReadyDTO?
    private var pendingViewport: (cols: Int, rows: Int)?
    private var lastSentTerminalViewport: (cols: Int, rows: Int)?
    private let viewportSettleDelay: Duration
    private var viewportSettleTask: Task<Void, Never>?
    private var typingIdleTask: Task<Void, Never>?
    private var isReportingTyping = false
    private var pendingTerminalInputProbe: PendingTerminalInputProbe?
    private var terminalInputProbeTimeoutTask: Task<Void, Never>?
    private var nextTerminalInputProbeAt: UInt64 = 0
    private var serverFeatures: Set<String> = []
    private var runPlanRevision: Int?
    private var runPlanPagePending = false
    private var warmTransportState: WarmTransportState = .active
    private var pendingPromptSubmission: PendingRemoteSubmission?
    private var pendingAttentionRequest: PendingAttentionRequest?
    /// Non-nil only for the demo sentinel link: plays the Mac's half of the socket in-process,
    /// through the same message handler a real frame reaches (`DemoExperience`).
    private var demoScript: DemoSessionScript?
    var onTerminalOutput: ((Data) -> Void)? {
        didSet {
            // A detached renderer takes its screen with it: a chat reopened from the list on a
            // parked connection has nothing to keep, and gets the opening loader as before.
            if onTerminalOutput == nil { hasPresentedTerminalOutput = false }
            guard let onTerminalOutput, !pendingTerminalOutput.isEmpty else { return }
            let buffered = pendingTerminalOutput
            pendingTerminalOutput.removeAll(keepingCapacity: true)
            // Receiving and rendering buffered bytes are separate moments. Restart hydration's
            // quiet boundary when the terminal actually takes the buffer so it cannot reveal
            // before SwiftTerm has parsed output that arrived ahead of the view. The static UI
            // fixtures enter through this same buffer instead of pretending to own a socket.
            noteTerminalHydrationOutput()
            if holdsReplayForHydration {
                // A view attaching mid-reconnect has no old screen to keep: give it the reset
                // and everything held so far, and let hydration reveal the rest live.
                holdsReplayForHydration = false
                holdsPreviousScreen = false
                var frame = Data([0x1b, 0x63])
                frame.append(buffered)
                presentTerminalOutput(frame, through: onTerminalOutput)
            } else {
                presentTerminalOutput(buffered, through: onTerminalOutput)
            }
            if let ready = pendingTerminalReady {
                pendingTerminalReady = nil
                completeTerminalHydration(ifMatching: ready)
            }
        }
    }
    var onTerminalGridChange: ((Int, Int) -> Void)? {
        didSet {
            guard terminalColumns > 0, terminalRows > 0 else { return }
            onTerminalGridChange?(terminalColumns, terminalRows)
        }
    }
    var onWorkspaceChanged: ((RemoteWorkspaceChangedDTO) -> Void)?
    private var lastSessionVisit: RemoteSessionVisitedDTO?
    /// The detail socket's authoritative post-visit row. Replaying the last frame lets a warm
    /// pooled connection settle a dashboard even when SwiftUI installs its callback afterwards.
    var onSessionVisited: ((RemoteSessionVisitedDTO) -> Void)? {
        didSet {
            if let lastSessionVisit { onSessionVisited?(lastSessionVisit) }
        }
    }
    /// Set only while the pool owns this connection. A transport that dies while no view is
    /// mounted removes itself from the pool instead of starting an invisible reconnect loop.
    var onPooledConnectionInvalidated: (() -> Void)?

    /// True while this session's agent is working on a turn — what the navigation title's orb
    /// is drawn for. See `MobileAgentTurnActivity` for why `canSend` is the signal.
    var isAwaitingUserDecision: Bool {
        conversationStore.state.permission != nil || conversationStore.state.questions.contains { $0.blocksTurn }
    }

    var isAgentWorking: Bool {
        !isAwaitingUserDecision && MobileAgentTurnActivity.isWorking(
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

    var isReadyForConnectionPool: Bool {
        phase == .connected && task != nil && warmTransportState == .active
    }

    /// Installs one terminal renderer as the owner of live output, authoritative grid updates,
    /// and the viewport lease. A later mount atomically supersedes an earlier renderer.
    func mountTerminalRenderer(
        _ owner: AnyObject,
        output: @escaping (Data) -> Void,
        gridChange: @escaping (Int, Int) -> Void
    ) {
        guard warmTransportState != .parking, warmTransportState != .parked else { return }
        terminalRendererOwner = ObjectIdentifier(owner)
        // State first, bytes second. Both setters immediately replay anything that arrived
        // before the view mounted, and the parser must know the host grid before taking bytes.
        onTerminalGridChange = gridChange
        onTerminalOutput = output
    }

    func isTerminalRendererOwner(_ owner: AnyObject) -> Bool {
        terminalRendererOwner == ObjectIdentifier(owner)
    }

    /// Removes a renderer only while it still owns this connection. Returns whether removal
    /// happened so the lifecycle ordering is directly testable without a UIKit transition.
    @discardableResult
    func unmountTerminalRenderer(_ owner: AnyObject) -> Bool {
        guard isTerminalRendererOwner(owner) else { return false }
        terminalRendererOwner = nil
        onTerminalOutput = nil
        onTerminalGridChange = nil
        releaseTerminalViewport()
        return true
    }

    func terminalInputMode(
        preference: MobileTerminalInputPreference
    ) -> MobileTerminalInputMode {
        MobileCollaborationPresentation.terminalInputMode(
            preference: preference,
            supportsAtomicSubmission: supportsAtomicTerminalSubmission,
            capability: capability,
            inputControlFeatureSupported: supportsFocusedInputControl,
            canWrite: inputControl?.canWrite != false,
            state: inputControl
        )
    }

    init(
        session: RemoteSessionSummaryDTO,
        target: RemoteLiveConnectionTarget? = nil,
        client: RemoteClient,
        reconnectClient: (
            @MainActor (MobileSessionReconnectRequest) async -> RemoteClient?
        )? = nil,
        helloDeadline: Duration = RemoteMobileConnectionDefaults.helloDeadline,
        viewportSettleDelay: Duration = RemoteMobileConnectionDefaults.viewportSettleDelay,
        terminalHydrationQuietDelay: Duration =
            RemoteMobileConnectionDefaults.terminalHydrationQuietDelay,
        terminalHydrationMaximumDelay: Duration =
            RemoteMobileConnectionDefaults.terminalHydrationMaximumDelay
    ) {
        self.session = session
        self.target = target ?? .session(session.id)
        self.client = client
        self.reconnectClient = reconnectClient
        self.helloDeadline = helloDeadline
        self.viewportSettleDelay = viewportSettleDelay
        self.terminalHydrationQuietDelay = terminalHydrationQuietDelay
        self.terminalHydrationMaximumDelay = terminalHydrationMaximumDelay
        mirroredCaption = session.title
        surface = session.surface
        isTerminalHydrating = session.surface == .terminal
        terminalTheme = session.terminalTheme
        deviceID = RemoteDeviceIdentity.current
        conversationStore.onDecisionChange = { [weak self] in self?.objectWillChange.send() }
        conversationStore.onCanSendChange = { [weak self] canSend in
            self?.conversationCanSend = canSend
        }
#if canImport(UIKit)
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteResigningActive() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteEnteringBackground() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterActivation() }
            },
        ]
#endif
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func connect() {
        disconnect(markEnded: false)
        let generation = connectionGeneration
#if DEBUG
        MobileTerminalWirePerformanceProbe.connectionStarted(session)
#endif
        stopped = false
        lossPeerSentClose = false
        phase = .connecting
        beginTerminalHydration()
        lastSentTerminalViewport = nil
        // A reconnect keeps what the last hello established until the next hello replaces it
        // wholesale. Clearing these here put every terminal into `.none` input mode for the
        // reconnect, which resigned the keyboard and unmounted the composer someone was typing
        // in — a return from another app ended with the keyboard gone and the draft blinking out.
        if !hasEverConnected {
            composerCapabilities = []
            serverFeatures.removeAll()
            supportsComposerAttachmentUploads = false
            supportsTerminalAttachmentInsertion = false
            supportsAtomicTerminalSubmission = false
            supportsAttentionRequests = false
            supportsFocusedInputControl = false
            supportsSessionConnectionParking = false
            inputControl = nil
        }
        clearRunPlanState(resetFeature: true)
        warmTransportState = .active
        inputControlEvents = []
        attentionRecipients = []
        socketTrace = MobileDiagnostics.connectivityTrace()
        socketStartedAt = MobileDiagnostics.monotonicNow()
        socketAttempt = reconnectSequence + 1
        MobileDiagnostics.recordConnectivity(.socketConnecting, fields: socketFields(
            phase: "hello"
        ).merging([
            .result: "started",
            .attempt: String(socketAttempt),
            .timeoutMS: MobileDiagnostics.milliseconds(helloDeadline),
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ]) { current, _ in current })
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        // A reconnect receives the Mac's authoritative ring again, so a mounted SwiftTerm must
        // be reset before replay replaces its prior state. A terminal that has already drawn
        // something keeps it on display instead: the reset and the replay are held and
        // delivered together when hydration completes, so the old screen becomes the new one
        // in a single frame rather than going blank while the replay streams in.
        if surface == .terminal, hasPresentedTerminalOutput, onTerminalOutput != nil {
            holdsReplayForHydration = true
            holdsPreviousScreen = true
        } else {
            holdsReplayForHydration = false
            holdsPreviousScreen = false
            onTerminalOutput?(Data([0x1b, 0x63]))
        }

        // The demo's canned Mac takes the socket's place; everything downstream of the wire —
        // the hello, snapshots, acknowledgements — still arrives through `handle`.
        if case .session = target,
           let script = DemoSessionScript.forDemo(link: client.link, session: session) {
            demoScript = script
            script.begin(on: self)
            return
        }

        do {
            let task: URLSessionWebSocketTask
            switch target {
            case .session(let sessionID):
                task = try client.webSocketTask(sessionID: sessionID)
            case .projectTerminal(let terminalID):
                task = try client.terminalWebSocketTask(terminalID: terminalID)
            }
            self.task = task
            task.resume()
            armHelloDeadline(generation: generation)
            try send(RemoteClientMessage(
                type: "auth",
                token: client.link.token,
                device: deviceID,
                deviceName: RemoteDeviceIdentity.currentName,
                replayBudget: RemoteMobileConnectionDefaults.terminalReplayBudgetBytes,
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
    private func armHelloDeadline(generation: Int, deadline: Duration? = nil) {
        helloDeadlineTask?.cancel()
        let deadline = deadline ?? helloDeadline
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
        finishSessionResume(result: "cancelled")
        finishTerminalInputProbe(result: "cancelled")
        if markEnded { isAwaitingResume = false }
        resumeProbeGeneration = nil
        terminalHydrationQuietTask?.cancel()
        terminalHydrationQuietTask = nil
        terminalHydrationMaximumTask?.cancel()
        terminalHydrationMaximumTask = nil
        isTerminalHydrating = false
        if holdsReplayForHydration {
            // The held replay belonged to a connection that is now over; the next one asks for
            // the ring again. The old screen stays as it is.
            holdsReplayForHydration = false
            holdsPreviousScreen = false
            pendingTerminalOutput.removeAll(keepingCapacity: true)
        }
        viewportSettleTask?.cancel()
        viewportSettleTask = nil
        if phase == .connected, capability == .interact, pendingViewport != nil {
            try? send(RemoteClientMessage(type: "viewportRelease"))
        }
        connectionGeneration &+= 1
        wireEncodingLane.advance(to: connectionGeneration)
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
        warmTransportState = .active
        onPooledConnectionInvalidated = nil
        presence.removeAll()
        attentionRecipients = []
        clearRunPlanState(resetFeature: true)
        pendingAttentionRequest = nil
        isAttentionRequestPending = false
        conversationStore.cancelLoadingEarlier()
        if markEnded {
            phase = .ended(MobileL10n.string("Disconnected"))
            MobileDiagnostics.recordConnectivity(.socketEnded, fields: socketFields(
                phase: "session"
            ).merging([
                .result: "ended",
                .reason: "user",
            ]) { current, _ in current })
        }
    }

    /// Turns a visible session connection into a transport-only warm entry.
    ///
    /// No renderer callback survives this boundary. The host's `sessionPark` removes the socket
    /// from PTY fan-out, collaboration presence and viewport ownership; keeping those alive would
    /// be a hidden terminal, not a connection pool.
    @discardableResult
    func parkForReuse() -> Bool {
        guard phase == .connected,
              supportsSessionConnectionParking,
              case .session = target,
              task != nil,
              warmTransportState == .active else { return false }

        // Move out of `active` before publishing any teardown state. SwiftUI may schedule one
        // last update while this view disappears; a renderer must not remount onto a connection
        // that has already committed to leaving host fan-out.
        warmTransportState = .parking
        reportTyping(false)
        terminalHydrationQuietTask?.cancel()
        terminalHydrationQuietTask = nil
        terminalHydrationMaximumTask?.cancel()
        terminalHydrationMaximumTask = nil
        viewportSettleTask?.cancel()
        viewportSettleTask = nil
        isTerminalHydrating = false
        pendingViewport = nil
        lastSentTerminalViewport = nil
        terminalRendererOwner = nil
        onTerminalOutput = nil
        onTerminalGridChange = nil
        onWorkspaceChanged = nil
        do {
            try send(RemoteClientMessage(type: "sessionPark"))
            return true
        } catch {
            warmTransportState = .active
            return false
        }
    }

    /// Reattaches a parked authenticated socket. The normal `hello` and bounded replay/snapshot
    /// remain the synchronization boundary, so resuming cannot expose state accumulated while
    /// the phone was away.
    @discardableResult
    func resumeFromPool() -> Bool {
        guard phase == .connected,
              supportsSessionConnectionParking,
              task != nil,
              warmTransportState == .parking || warmTransportState == .parked else {
            return false
        }
        warmTransportState = .resuming
        phase = .connecting
#if DEBUG
        MobileTerminalWirePerformanceProbe.connectionStarted(session)
#endif
        sessionResumeTrace = MobileDiagnostics.connectivityTrace()
        sessionResumeStartedAt = MobileDiagnostics.monotonicNow()
        recordInteractionDiagnostic(
            .sessionResumeStarted,
            fields: sessionResumeFields(result: "started")
        )
        clearRunPlanState(resetFeature: true)
        beginTerminalHydration()
        lastSentTerminalViewport = nil
        presence.removeAll()
        attentionRecipients = []
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        armHelloDeadline(generation: connectionGeneration)
        do {
            try send(RemoteClientMessage(type: "sessionResume"))
            return true
        } catch {
            cancelHelloDeadline()
            warmTransportState = .active
            finishSessionResume(result: "failed", code: MobileDiagnostics.errorCode(error))
            return false
        }
    }

    private var isOwnedByConnectionPool: Bool {
        warmTransportState == .parking || warmTransportState == .parked
    }

    private func invalidatePooledConnection() {
        let invalidated = onPooledConnectionInvalidated
        onPooledConnectionInvalidated = nil
        disconnect(markEnded: false)
        invalidated?()
    }

    private func beginTerminalHydration() {
        terminalHydrationQuietTask?.cancel()
        terminalHydrationQuietTask = nil
        terminalHydrationMaximumTask?.cancel()
        terminalHydrationMaximumTask = nil
        hasReceivedTerminalHydrationOutput = false
        terminalHydrationRequestID = nil
        pendingTerminalReady = nil
        isTerminalHydrating = session.surface == .terminal
    }

    private func noteTerminalHydrationOutput() {
        guard isTerminalHydrating else { return }
        hasReceivedTerminalHydrationOutput = true
        if terminalHydrationMaximumTask == nil {
            terminalHydrationMaximumTask = Task { [weak self, terminalHydrationMaximumDelay] in
                try? await Task.sleep(for: terminalHydrationMaximumDelay)
                guard !Task.isCancelled else { return }
                self?.completeTerminalHydration()
            }
        }
        scheduleTerminalHydrationCompletionIfReady()
    }

    private func noteTerminalHydrationViewportSent() {
        scheduleTerminalHydrationCompletionIfReady()
    }

    private func scheduleTerminalHydrationCompletionIfReady() {
        guard isTerminalHydrating, hasReceivedTerminalHydrationOutput else { return }
        // A capable host puts an ordered boundary behind its post-SIGWINCH output and final
        // screen seed. Its own PTY timing decides stability; packet gaps must not restart a
        // second client-side timer. The maximum task remains the escape for a broken boundary.
        guard !serverFeatures.contains(
            RemoteWebSocketFeature.terminalHydrationBoundary.rawValue
        ) else { return }
        // An interactive terminal is not stable until its first phone-owned grid has reached
        // the Mac. A view-only connection never leases a viewport and can reveal its replay.
        guard capability != .interact || pendingViewport != nil else { return }
        terminalHydrationQuietTask?.cancel()
        terminalHydrationQuietTask = Task { [weak self, terminalHydrationQuietDelay] in
            try? await Task.sleep(for: terminalHydrationQuietDelay)
            guard !Task.isCancelled else { return }
            self?.completeTerminalHydration()
        }
    }

    private func completeTerminalHydration() {
        guard isTerminalHydrating else { return }
        terminalHydrationQuietTask?.cancel()
        terminalHydrationQuietTask = nil
        terminalHydrationMaximumTask?.cancel()
        terminalHydrationMaximumTask = nil
        isTerminalHydrating = false
        releaseHeldReplay()
        isAwaitingResume = false
#if DEBUG
        MobileTerminalWirePerformanceProbe.terminalHydrationCompleted(session)
#endif
    }

    /// The moment a held reconnect becomes the screen: one reset, then everything the Mac
    /// replayed, in one delivery.
    private func releaseHeldReplay() {
        guard holdsReplayForHydration else { return }
        holdsReplayForHydration = false
        holdsPreviousScreen = false
        guard let onTerminalOutput else { return }
        var frame = Data([0x1b, 0x63])
        frame.append(pendingTerminalOutput)
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        presentTerminalOutput(frame, through: onTerminalOutput)
    }

    private func presentTerminalOutput(_ data: Data, through output: (Data) -> Void) {
        hasPresentedTerminalOutput = true
        output(data)
    }

    /// The app is losing the front — to another app, to the switcher, or only to a prompt. A
    /// terminal with something on screen locks it now, so the switcher card and the snapshot
    /// iOS keeps for the return are already the softened screen. Locking any later (on entering
    /// the background) raced that snapshot and let sharp old text flash on return.
    func noteResigningActive() {
        guard hasEverConnected, surface == .terminal, hasPresentedTerminalOutput else { return }
        isAwaitingResume = true
    }

    /// Only a real background can have cost the socket; a prompt never reaches here.
    func noteEnteringBackground(at now: Date = Date()) {
        backgroundedAt = now
    }

    /// The app is back. A reconnect already waiting starts now. A resign that never became a
    /// background — a paste prompt, Control Center — releases the lock at once, nothing having
    /// happened to the socket. A long background reconnects outright, because the Mac has
    /// almost certainly dropped a socket the phone's side still thinks alive; a short one asks
    /// with a ping, briefly, so a quick app switch does not replay for nothing.
    func resumeAfterActivation(now: Date = Date()) {
        let backgroundDuration = backgroundedAt.map { now.timeIntervalSince($0) }
        backgroundedAt = nil
        if reconnectTask != nil {
            reconnectNowIfWaiting()
            return
        }
        guard isAwaitingResume else { return }
        guard let backgroundDuration else {
            isAwaitingResume = false
            return
        }
        if backgroundDuration >= RemoteMobileConnectionDefaults.reconnectOutrightAfterBackground {
            connect()
            return
        }
        guard probeLiveness() else {
            isAwaitingResume = false
            return
        }
    }

    /// Asks the socket whether it is still there, and reconnects if it is not.
    ///
    /// One ping with a one-second deadline. A pong clears the resume hold; silence or an error
    /// reconnects, which asks the model for the current route. Returns false when there is no
    /// connected socket to ask, or a probe is already out. Shared by the return from the
    /// background and by a terminal input the Mac never acknowledged: a socket the phone still
    /// calls connected can be dead on the wire for as long as iOS takes to notice, and typing
    /// into it is the moment the person finds out (2026-09-11).
    @discardableResult
    private func probeLiveness() -> Bool {
        guard phase == .connected, let task, resumeProbeGeneration == nil else { return false }
        let generation = connectionGeneration
        resumeProbeGeneration = generation
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.resumeProbeGeneration == generation else { return }
                self.resumeProbeGeneration = nil
                if error == nil {
                    self.isAwaitingResume = false
                } else {
                    self.connect()
                }
            }
        }
        Task { [weak self, deadline = RemoteMobileConnectionDefaults.resumeLivenessDeadline] in
            try? await Task.sleep(for: deadline)
            guard let self, self.resumeProbeGeneration == generation else { return }
            self.resumeProbeGeneration = nil
            self.connect()
        }
        return true
    }

    /// A socket dropped in the background is not a flaky network. Reconnect the moment the
    /// app is back rather than serving out a backoff that was counting while it was suspended.
    private func reconnectNowIfWaiting() {
        guard let waiting = reconnectTask else { return }
        waiting.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        reconnectThroughModel(
            MobileSessionReconnectRequest(attempt: 0, peerSentClose: lossPeerSentClose)
        )
    }

    /// The network path changed underneath this socket. A delivering socket is asked whether it
    /// is still there; one sleeping out a backoff toward the old network retries now; one still
    /// dialling is left to its hello deadline and the model's route, which the same change is
    /// already re-resolving.
    func networkPathChanged() {
        guard !isOwnedByConnectionPool, demoScript == nil else { return }
        if reconnectTask != nil {
            reconnectNowIfWaiting()
        } else {
            probeLiveness()
        }
    }

    /// The person asked for another try, from the title or the recovery row.
    ///
    /// Until now this dialled the client the socket already held, which after a route loss is
    /// the origin that just failed — and cancelled the model-routed retry that was sleeping in
    /// its backoff to do it. A tap is stronger evidence than any backoff that the person wants
    /// the Mac found now, so it goes to the model at once, and as a retry rather than a first
    /// attempt so the route is re-resolved rather than trusted. Without a model to ask, the
    /// old client is all there is.
    func retryNow() {
        guard reconnectClient != nil else {
            connect()
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectThroughModel(MobileSessionReconnectRequest(
            attempt: max(reconnectAttempt, 1),
            peerSentClose: lossPeerSentClose
        ))
    }

    /// Asks the model for the route a retry should take and dials it, unless this connection
    /// has moved on meanwhile.
    private func reconnectThroughModel(_ request: MobileSessionReconnectRequest) {
        guard let reconnectClient else { return }
        let generation = connectionGeneration
        Task { [weak self] in
            guard let client = await reconnectClient(request) else {
                self?.isAwaitingResume = false
                return
            }
            guard let self, self.connectionGeneration == generation,
                  self.reconnectTask == nil else { return }
            self.client = client
            self.connect()
        }
    }

    /// The model's authoritative route moved while this socket was still on the previous one.
    ///
    /// A hello that has not come is not made faster by waiting for it, and a backoff counting
    /// toward the old origin counts toward nothing; both restart on the new route now, and the
    /// abandoned attempt gets the terminal journal entry every connect is owed. A connected
    /// socket is left alone: it is either fine or about to say it is not, and its own reconnect
    /// asks the model for the current route. Returns whether anything was restarted.
    @discardableResult
    func adoptRoute(_ client: RemoteClient) -> Bool {
        guard !isOwnedByConnectionPool, demoScript == nil else { return false }
        guard client.link.baseURL != self.client.link.baseURL
            || client.endpointKind != self.client.endpointKind else { return false }
        guard let abandonedPhase = unansweredDialPhase else { return false }
        MobileDiagnostics.recordConnectivity(.socketEnded, fields: socketFields(
            phase: abandonedPhase
        ).merging([
            .result: "superseded",
            .reason: "routeChanged",
        ]) { current, _ in current })
        reconnectTask?.cancel()
        reconnectTask = nil
        self.client = client
        connect()
        return true
    }

    /// The person left the screen. A socket still waiting for its hello, or sleeping out a
    /// backoff, gets the terminal journal entry every connect is owed before it is torn down;
    /// without one, a chat that was abandoned mid-dial reads in a report as a connect that never
    /// ended, and the abandonment is the fact a support reader most needs (2026-09-11). A
    /// connected socket ends silently: its hello answered, and the pool declined to keep it.
    func leave() {
        if !isOwnedByConnectionPool, demoScript == nil, let abandonedPhase = unansweredDialPhase {
            MobileDiagnostics.recordConnectivity(.socketEnded, fields: socketFields(
                phase: abandonedPhase
            ).merging([
                .result: "abandoned",
                .reason: "userLeft",
            ]) { current, _ in current })
        }
        disconnect(markEnded: false)
    }

    /// Which wait a dial that has not been answered is in: `hello` while the socket is open and
    /// unanswered, `backoff` while a retry is sleeping. Nil for a connected or ended socket.
    private var unansweredDialPhase: String? {
        if reconnectTask != nil { return "backoff" }
        if phase == .connecting, task != nil { return "hello" }
        return nil
    }

    private func completeTerminalHydration(ifMatching ready: RemoteTerminalReadyDTO) {
        guard isTerminalHydrating else { return }
        if capability == .interact {
            guard let requestID = ready.requestID,
                  requestID == terminalHydrationRequestID else { return }
        } else {
            guard ready.requestID == nil else { return }
        }
        completeTerminalHydration()
    }

    func sendTerminalInput(_ data: ArraySlice<UInt8>) {
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false else { return }
        reportTyping(true)
        sendTerminalInputMessage(String(decoding: data, as: UTF8.self))
    }

    func sendTerminalKey(_ text: String) {
        guard phase == .connected, capability == .interact,
              inputControl?.canWrite != false else { return }
        reportTyping(true)
        sendTerminalInputMessage(text)
    }

    private func sendTerminalInputMessage(_ text: String) {
        let probeID = beginTerminalInputProbeIfEligible()
        do {
            try send(RemoteClientMessage(type: "input", data: text, requestID: probeID))
        } catch {
            if let probeID {
                finishTerminalInputProbe(requestID: probeID, result: "sendFailed")
            }
        }
    }

    /// Reports the grid SwiftTerm can actually display on this phone. The latest value is kept
    /// across the auth handshake so an initial layout that happens before `hello` is not lost.
    ///
    /// Only a settled grid becomes a lease. A pinch or an animating layout calls this once per
    /// crossed cell boundary, and forwarding each one had the Mac reflow its emulator and
    /// SIGWINCH the agent nineteen times in one gesture — churn that stalled every hello behind
    /// it. The local renderer already followed each step; the Mac needs only where it ended.
    func updateTerminalViewport(cols: Int, rows: Int) {
        guard cols >= 20, rows >= 4 else { return }
#if DEBUG
        MobileTerminalWirePerformanceProbe.viewportObserved(
            columns: cols,
            rows: rows,
            session: session
        )
#endif
        if pendingViewport?.cols == cols, pendingViewport?.rows == rows { return }
        let isFirstGridOfLease = pendingViewport == nil
        pendingViewport = (cols, rows)
        guard phase == .connected, capability == .interact else { return }
        if isFirstGridOfLease {
            try? send(terminalViewportMessage(cols: cols, rows: rows))
            return
        }
        viewportSettleTask?.cancel()
        viewportSettleTask = Task { [weak self, viewportSettleDelay] in
            try? await Task.sleep(for: viewportSettleDelay)
            guard !Task.isCancelled else { return }
            self?.sendSettledViewport()
        }
    }

    private func sendSettledViewport() {
        viewportSettleTask = nil
        guard !stopped, phase == .connected, capability == .interact,
              let pendingViewport else { return }
        try? send(terminalViewportMessage(
            cols: pendingViewport.cols,
            rows: pendingViewport.rows
        ))
    }

    private func terminalViewportMessage(cols: Int, rows: Int) -> RemoteClientMessage {
        let requestID: String?
        if isTerminalHydrating,
           serverFeatures.contains(
               RemoteWebSocketFeature.terminalHydrationBoundary.rawValue
           ) {
            // Every grid sent before reveal is a new presentation generation. A settled grid
            // can supersede the immediate first lease while its repaint is still in flight;
            // giving it a new id makes the earlier boundary harmless instead of revealing the
            // newer resize half-painted.
            requestID = UUID().uuidString.lowercased()
        } else {
            requestID = nil
        }
        return RemoteClientMessage(
            type: "viewport",
            cols: cols,
            rows: rows,
            requestID: requestID
        )
    }

    func releaseTerminalViewport() {
        viewportSettleTask?.cancel()
        viewportSettleTask = nil
        guard pendingViewport != nil else { return }
        pendingViewport = nil
        lastSentTerminalViewport = nil
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

    /// Submits a device-local terminal line as one acknowledged transaction. The host writes its
    /// text and Return to the PTY separately so agent TUIs do not classify the line as a paste. A
    /// host must advertise the capability because older hosts only understand shared raw keys.
    @discardableResult
    func submitTerminalLine(
        _ text: String,
        attachmentUploadIDs: [String] = []
    ) -> String? {
        let line = text.trimmingCharacters(in: .newlines)
        guard supportsAtomicTerminalSubmission, inputControl?.canWrite != false else { return nil }
        return sendSubmission(
            type: "terminalSubmit",
            text: line,
            attachmentUploadIDs: attachmentUploadIDs,
            permitsLegacyHost: false
        )
    }

    /// Hands staged files to the session and inserts their quoted workspace paths at the live
    /// terminal cursor. This deliberately does not send Return: the direct-input TUI still owns
    /// editing and submission of the line.
    @discardableResult
    func insertTerminalAttachments(_ attachmentUploadIDs: [String]) -> String? {
        guard supportsTerminalAttachmentInsertion,
              inputControl?.canWrite != false,
              !attachmentUploadIDs.isEmpty else { return nil }
        return sendSubmission(
            type: "terminalAttachmentInsert",
            text: "",
            attachmentUploadIDs: attachmentUploadIDs,
            permitsLegacyHost: false
        )
    }

    @discardableResult
    func changeInputControl(
        action: RemoteInputControlAction,
        targetID: String? = nil
    ) -> String? {
        guard phase == .connected, capability == .interact,
              supportsFocusedInputControl else { return nil }
        let requestID = UUID().uuidString
        do {
            try send(RemoteClientMessage(
                type: "inputControl",
                state: action.rawValue,
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
                contextAttachments: contextAttachments,
                attachmentUploadIDs: attachmentUploadIDs,
                createdAt: Date(),
                startedAtNanoseconds: MobileDiagnostics.monotonicNow()
            )
            recordPromptSubmissionStarted(requestID: requestID, messageType: type)
            isPromptSubmissionPending = supportsAcknowledgement
            try send(RemoteClientMessage(
                type: type,
                text: text,
                requestID: supportsAcknowledgement ? requestID : nil,
                contextAttachments: contextAttachments.isEmpty ? nil : contextAttachments,
                attachmentUploadIDs: attachmentUploadIDs.isEmpty ? nil : attachmentUploadIDs
            ))
            if !supportsAcknowledgement {
                finishPendingPrompt(with: .accepted)
            }
            return requestID
        } catch {
            recordPromptSubmissionEnded(
                pendingPromptSubmission,
                result: "sendFailed"
            )
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
                try? send(RemoteClientMessage(
                    type: "presence",
                    state: RemotePresenceUpdate.typing.rawValue
                ))
            }
            typingIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.reportTyping(false)
            }
        } else if isReportingTyping {
            isReportingTyping = false
            try? send(RemoteClientMessage(
                type: "presence",
                state: RemotePresenceUpdate.idle.rawValue
            ))
        }
    }

    func answerQuestion(_ request: RemoteQuestionRequestDTO, answers: [String: String]?) {
        guard phase == .connected, capability == .interact, request.canAnswer,
              conversationStore.state.questions.contains(where: { $0.id == request.id && $0.canAnswer }),
              answers.map(request.accepts) ?? true else { return }
#if DEBUG
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]?.hasPrefix("conversation-question") == true {
            let state = conversationStore.state
            conversationStore.replace(with: RemoteConversationSnapshotDTO(
                rows: state.rows + [.init(id: "answered-" + request.id, kind: .notice,
                                         text: answers == nil ? "Question cancelled." : "Answer sent.")],
                canSend: true, questions: state.questions.filter { $0.id != request.id }
            ))
            return
        }
#endif
        do {
            try send(RemoteClientMessage(type: "questionAnswer", id: request.id,
                                         decision: answers == nil ? "cancel" : "answer", answers: answers))
        } catch {
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
            scheduleReconnect(generation: connectionGeneration)
        }
    }

    func decidePermission(_ permission: RemotePermissionRequestDTO, allow: Bool) {
        guard phase == .connected, capability == .interact, permission.canDecide else { return }
        let decision: RemotePermissionDecision = allow ? .allow : .deny
        do {
            try send(RemoteClientMessage(
                type: "permission",
                id: permission.id,
                decision: decision.rawValue
            ))
            MobileDiagnostics.record(.permissionDecisionSent, fields: [
                .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
                .trace: permission.id,
                .result: decision.rawValue,
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
        if message.type == "viewport", let cols = message.cols, let rows = message.rows {
            if lastSentTerminalViewport?.cols == cols,
               lastSentTerminalViewport?.rows == rows {
                return
            }
            // The hydration generation belongs to the viewport that actually crosses the
            // wire. Constructing a message is not sending it: a settled layout can return to
            // the already-leased grid and hit the duplicate guard above. Recording its fresh
            // request id before that guard would make the real host boundary look stale and
            // leave the opening placeholder up until the emergency timeout.
            if let requestID = message.requestID {
                terminalHydrationRequestID = requestID
            }
            lastSentTerminalViewport = (cols, rows)
            noteTerminalHydrationViewportSent()
#if DEBUG
            MobileTerminalWirePerformanceProbe.viewportSent(
                columns: cols,
                rows: rows,
                hasHydrationRequestID: message.requestID != nil,
                session: session
            )
#endif
        }
        if let demoScript {
            guard expectedGeneration == connectionGeneration, !stopped else {
                throw RemoteClientError.invalidResponse
            }
            demoScript.handleClient(message)
            return
        }
        guard expectedGeneration == connectionGeneration, !stopped,
              let task else { throw RemoteClientError.invalidResponse }
        try wireEncodingLane.enqueue(message, generation: expectedGeneration) { [weak self, task] result in
            switch result {
            case .success(let text):
                task.send(.string(text)) { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.handleOutboundFailure(
                            error,
                            task: task,
                            generation: expectedGeneration
                        )
                    }
                }
            case .failure(let error):
                Task { @MainActor in
                    self?.handleOutboundFailure(
                        error,
                        task: task,
                        generation: expectedGeneration
                    )
                }
            }
        }
    }

    private func handleOutboundFailure(
        _ error: Error,
        task: URLSessionWebSocketTask,
        generation: Int
    ) {
        guard connectionGeneration == generation,
              stopped == false, self.task === task else { return }
        if isOwnedByConnectionPool {
            invalidatePooledConnection()
            return
        }
        lossPeerSentClose = Self.peerSentClose(on: task)
        fail(
            with: RemoteConnectionFailure.transport(error, host: destinationHost),
            httpStatus: Self.httpStatus(of: task)
        )
        scheduleReconnect(generation: generation)
    }

    /// Requests the next bounded page only while an expanded disclosure needs it.
    func requestNextRunPlanPage() {
        guard phase == .connected,
              supportsRunPlanProgress,
              let runPlan,
              let runPlanRevision,
              runPlanSteps.count < runPlan.total,
              !runPlanPagePending else { return }
        runPlanPagePending = true
        do {
            try send(RemoteClientMessage(
                type: "runPlanPage",
                limit: RemoteMobileConnectionDefaults.runPlanPageSteps,
                offset: runPlanSteps.count,
                revision: runPlanRevision
            ))
        } catch {
            runPlanPagePending = false
            recordSocketFailure(error)
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
#if DEBUG
                    MobileTerminalWirePerformanceProbe.outputReceived(data, session: session)
#endif
                    applyTerminalOutput(data)
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
            if isOwnedByConnectionPool {
                invalidatePooledConnection()
                return
            }
            lossPeerSentClose = Self.peerSentClose(on: task)
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
    func receiveDemoServerMessage<Message: Encodable & Sendable>(_ message: Message) {
        guard demoScript != nil else { return }
        let generation = connectionGeneration
        do {
            try wireEncodingLane.enqueue(message, generation: generation) { [weak self] result in
                // Both JSON and prepared binary frames originate on this one serial queue.
                // Submitting them to the main queue from here preserves their socket order all
                // the way through state application, rather than relying on unstructured Task
                // scheduling to happen to retain it.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.demoScript != nil,
                              self.connectionGeneration == generation else { return }
                        switch result {
                        case .success(let text):
                            self.handle(text)
                        case .failure(let error):
                            self.fail(
                                with: RemoteConnectionFailure.transport(
                                    error,
                                    host: self.destinationHost
                                )
                            )
                        }
                    }
                }
            }
        } catch {
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
        }
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

    /// Synthesized terminal bytes, ordered and buffered exactly the way `receiveLoop` handles
    /// real WebSocket frames. They join the JSON codec lane even though no encoding is needed:
    /// otherwise a replay submitted after `hello` can reach the main actor before it.
    func receiveDemoTerminalOutput(_ data: Data) {
        guard demoScript != nil else { return }
        let generation = connectionGeneration
        do {
            try wireEncodingLane.enqueuePrepared(generation: generation) { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.demoScript != nil,
                              self.connectionGeneration == generation else { return }
                        self.applyTerminalOutput(data)
                    }
                }
            }
        } catch {
            fail(with: RemoteConnectionFailure.transport(error, host: destinationHost))
        }
    }

    /// The shared binary-frame boundary. A real WebSocket invokes it directly on the main
    /// actor; the demo reaches it only after its ordered worker lane has applied prior frames.
    private func applyTerminalOutput(_ data: Data) {
        noteTerminalHydrationOutput()
        if let onTerminalOutput, !holdsReplayForHydration {
            presentTerminalOutput(data, through: onTerminalOutput)
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
    var terminalHydrationRequestIDForTesting: String? {
        terminalHydrationRequestID
    }

    /// Feeds binary output through the same state boundary as a real WebSocket without
    /// requiring a demo script. Hydration compatibility tests use it beside injected text
    /// frames so the current demo protocol cannot race an older-host fixture.
    func receiveServerTerminalOutputForTesting(_ data: Data) {
        applyTerminalOutput(data)
    }

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

    private func handle(_ text: String) {
        let data = Data(text.utf8)
        guard let envelope = try? JSONDecoder().decode(
            RemoteSessionServerEnvelope.self,
            from: data
        ) else { return }
        switch envelope.type {
        case "sessionStarting":
            guard phase == .connecting,
                  (try? JSONDecoder().decode(RemoteSessionStartingDTO.self, from: data)) != nil
            else { return }
            // The host has authenticated this exact socket and owns completing it when the live
            // surface exists. Replace the route deadline with the bounded startup transaction;
            // no catalogue refresh or reconnect is needed in between.
            armHelloDeadline(
                generation: connectionGeneration,
                deadline: RemoteMobileConnectionDefaults.startupHelloDeadline
            )
        case "hello":
            guard let hello = try? JSONDecoder().decode(RemoteHelloDTO.self, from: data) else { return }
            let wasResumingParkedSession = warmTransportState == .resuming
            mirroredCaption = hello.title.isEmpty ? mirroredCaption : hello.title
            surface = hello.surface
            if surface != .terminal {
                completeTerminalHydration()
            }
            capability = hello.capability.knownCapability ?? .view
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
            supportsSessionConnectionParking = serverFeatures.contains(
                RemoteWebSocketFeature.sessionConnectionParking.rawValue
            )
            supportsComposerAttachmentUploads = serverFeatures.contains(
                RemoteWebSocketFeature.composerAttachmentUploads.rawValue
            )
            supportsTerminalAttachmentInsertion = serverFeatures.contains(
                RemoteWebSocketFeature.terminalAttachmentInsertion.rawValue
            )
            supportsRunPlanProgress = serverFeatures.contains(
                RemoteWebSocketFeature.runPlanProgress.rawValue
            )
            updateTerminalGrid(cols: hello.cols, rows: hello.rows)
            cancelHelloDeadline()
            warmTransportState = .active
            phase = .connected
            hasEverConnected = true
#if DEBUG
            MobileTerminalWirePerformanceProbe.helloReceived(
                session,
                supportsHydrationBoundary: serverFeatures.contains(
                    RemoteWebSocketFeature.terminalHydrationBoundary.rawValue
                )
            )
#endif
            if wasResumingParkedSession {
                finishSessionResume(result: "succeeded")
            } else {
                MobileDiagnostics.recordConnectivity(.socketConnected, fields: socketFields(
                    phase: "hello"
                ).merging([
                    .result: "succeeded",
                    .attempt: String(socketAttempt),
                    .capability: hello.capability.rawValue,
                    .surface: hello.surface.rawValue,
                ]) { current, _ in current })
            }
            reconnectAttempt = 0
            reconnectSequence = 0
            if let pendingViewport, capability == .interact,
               lastSentTerminalViewport == nil {
                try? send(terminalViewportMessage(
                    cols: pendingViewport.cols,
                    rows: pendingViewport.rows
                ))
            }
            resendPendingPromptIfSupported()
        case "sessionParked":
            // This frame is ordered after any PTY output already queued when the host detached
            // us, and before a later resumed hello. Dropping the buffer here makes a fresh view's
            // replay authoritative even when pop and push happen in consecutive gestures.
            pendingTerminalOutput.removeAll(keepingCapacity: true)
            pendingTerminalReady = nil
            if warmTransportState == .parking {
                warmTransportState = .parked
            }
        case "sessionVisited":
            guard let visitedSession = envelope.session,
                  let revision = envelope.revision,
                  let receiptCommitted = envelope.receiptCommitted,
                  visitedSession.id == session.id else { return }
            let visit = RemoteSessionVisitedDTO(
                session: visitedSession,
                revision: revision,
                receiptCommitted: receiptCommitted
            )
            lastSessionVisit = visit
            onSessionVisited?(visit)
        case "resize":
            if let resize = try? JSONDecoder().decode(RemoteResizeDTO.self, from: data) {
                updateTerminalGrid(cols: resize.cols, rows: resize.rows)
            }
        case "terminalReady":
            guard let ready = try? JSONDecoder().decode(
                RemoteTerminalReadyDTO.self,
                from: data
            ) else { return }
#if DEBUG
            MobileTerminalWirePerformanceProbe.terminalReadyReceived(
                session,
                hasRequestID: ready.requestID != nil,
                matchesExpectedRequest: capability == .interact
                    ? ready.requestID == terminalHydrationRequestID
                    : ready.requestID == nil
            )
#endif
            // Text and binary WebSocket messages are ordered, but SwiftTerm may not be mounted
            // yet. Keep the boundary behind the buffered bytes in the renderer as well as on
            // the socket or a fast host could reveal before the view parsed its final seed.
            if onTerminalOutput == nil, !pendingTerminalOutput.isEmpty {
                pendingTerminalReady = ready
            } else {
                completeTerminalHydration(ifMatching: ready)
            }
        case "theme":
            if let update = try? JSONDecoder().decode(RemoteThemeUpdateDTO.self, from: data) {
                theme = update.theme
                terminalTheme = update.terminalTheme
            }
        case "title":
            if let update = try? JSONDecoder().decode(RemoteTitleDTO.self, from: data) {
                mirroredCaption = update.title
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
        case "runPlan":
            guard let update = try? JSONDecoder().decode(
                RemoteRunPlanUpdateDTO.self,
                from: data
            ), update.revision >= 0,
               Self.isValidRunPlanSummary(update.plan) else { return }
            if let runPlanRevision {
                guard update.revision > runPlanRevision else {
                    // A revision is immutable. Ignoring duplicates also keeps a repeated summary
                    // from clearing the pending bit for a page requested after that summary.
                    return
                }
            }
            runPlanRevision = update.revision
            runPlan = update.plan
            runPlanSteps = []
            runPlanPagePending = false
        case "runPlanPage":
            if let page = try? JSONDecoder().decode(RemoteRunPlanPageDTO.self, from: data),
               page.revision == runPlanRevision,
               let runPlan,
               page.offset == runPlanSteps.count {
                runPlanPagePending = false
                guard page.total == runPlan.total,
                      page.steps.count <= RemoteMobileConnectionDefaults.runPlanPageSteps,
                      page.offset <= page.total,
                      page.steps.count <= page.total - page.offset,
                      page.steps.allSatisfy(Self.isValidRunPlanStep),
                      Set(page.steps.map(\.id)).count == page.steps.count,
                      Set(runPlanSteps.map(\.id)).isDisjoint(with: page.steps.map(\.id))
                else { return }
                // A page must extend the exact prefix already displayed. A repeated page at
                // offset zero or an out-of-order later page can therefore never roll back or
                // punch a hole in the list.
                runPlanSteps.append(contentsOf: page.steps)
            }
        case "presence":
            if let update = try? JSONDecoder().decode(RemotePresenceDTO.self, from: data) {
                if update.state == .left {
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
                    try? send(terminalViewportMessage(
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
            finishPendingPrompt(with: result.status)
        case "inputProbeResult":
            guard let result = try? JSONDecoder().decode(
                RemoteTerminalInputProbeResultDTO.self,
                from: data
            ) else { return }
            finishTerminalInputProbe(
                requestID: result.requestID,
                result: result.accepted ? "accepted" : "refused"
            )
        case "ended":
            let ended = try? JSONDecoder().decode(RemoteEndedDTO.self, from: data)
            if isOwnedByConnectionPool {
                invalidatePooledConnection()
                return
            }
            stopped = true
            clearRunPlanState(resetFeature: true)
            switch ended?.reason {
            case "sessionClosed":
                phase = .ended(MobileL10n.string("Session closed on Mac"))
            case "sessionStartupTimedOut":
                phase = .ended(MobileL10n.string("Couldn’t start session"))
            case "protocolMismatch":
                phase = .ended(
                    ended?.update == .client
                        ? MobileL10n.string("Update this app to reconnect")
                        : MobileL10n.string("Update Threading on the Mac to reconnect")
                )
            default:
                phase = .ended(MobileL10n.string("Session ended"))
            }
            MobileDiagnostics.recordConnectivity(.socketEnded, fields: socketFields(
                phase: "session"
            ).merging([
                .result: "ended",
                .reason: MobileDiagnostics.machineToken(ended?.reason ?? "server"),
            ]) { current, _ in current })
        case "error":
            let error = try? JSONDecoder().decode(RemoteErrorDTO.self, from: data)
            if isOwnedByConnectionPool {
                invalidatePooledConnection()
                return
            }
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
        "questionNotPending",
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
        let failedPhase = phase == .connected ? "session" : "hello"
        let failureCode = code ?? "connection.\(failure.cause.rawValue)"
        finishSessionResume(result: "failed", code: failureCode)
        finishTerminalInputProbe(result: "failed")
        clearRunPlanState(resetFeature: true)
        phase = .failed(failure)
        var fields = socketFields(phase: failedPhase)
        fields[.result] = "failed"
        fields[.attempt] = String(socketAttempt)
        fields[.code] = failureCode
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
        if failure.cause == .helloTimeout {
            fields[.timeoutMS] = MobileDiagnostics.milliseconds(helloDeadline)
        }
        MobileDiagnostics.recordConnectivity(.socketFailed, level: .error, fields: fields)
    }

    private func recordSocketFailure(_ error: Error) {
        var fields = socketFields(phase: "action")
        fields[.result] = "failed"
        fields[.attempt] = String(socketAttempt)
        fields[.code] = MobileDiagnostics.errorCode(error)
        MobileDiagnostics.recordConnectivity(.socketFailed, level: .error, fields: fields)
    }

    private func clearRunPlanState(resetFeature: Bool) {
        if resetFeature { supportsRunPlanProgress = false }
        runPlan = nil
        runPlanSteps = []
        runPlanRevision = nil
        runPlanPagePending = false
    }

    private static func isValidRunPlanSummary(_ plan: RemoteRunPlanSummaryDTO?) -> Bool {
        guard let plan else { return true }
        guard plan.total > 0,
              plan.total <= RemoteMobileConnectionDefaults.runPlanMaximumSteps,
              (1...plan.total).contains(plan.current),
              (0...plan.total).contains(plan.completed),
              (0...plan.total).contains(plan.active),
              (plan.activeTitle?.utf8.count ?? 0)
                <= RemoteMobileConnectionDefaults.runPlanMaximumTitleUTF8Bytes else {
            return false
        }
        return plan.completed <= plan.total - plan.active
    }

    private static func isValidRunPlanStep(_ step: RemoteRunPlanStepDTO) -> Bool {
        guard !step.id.isEmpty,
              step.id.utf8.count <= RemoteMobileConnectionDefaults.runPlanMaximumIdentifierUTF8Bytes,
              step.title.utf8.count <= RemoteMobileConnectionDefaults.runPlanMaximumTitleUTF8Bytes
        else { return false }
        guard let providerID = step.providerID else { return true }
        return !providerID.isEmpty
            && providerID.utf8.count
                <= RemoteMobileConnectionDefaults.runPlanMaximumIdentifierUTF8Bytes
    }

    private func socketFields(phase: String) -> [RemoteDiagnosticField: String] {
        var fields = destinationFields
        fields[.phase] = phase
        if let socketTrace { fields[.trace] = socketTrace }
        if let socketStartedAt {
            fields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(since: socketStartedAt)
        }
        return fields
    }

    private func sessionResumeFields(
        result: String,
        code: String? = nil
    ) -> [RemoteDiagnosticField: String] {
        var fields = destinationFields
        fields[.phase] = "resume"
        fields[.result] = result
        if let sessionResumeTrace { fields[.trace] = sessionResumeTrace }
        if let sessionResumeStartedAt {
            fields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(
                since: sessionResumeStartedAt
            )
        }
        if let code { fields[.code] = code }
        return fields
    }

    private func finishSessionResume(result: String, code: String? = nil) {
        guard sessionResumeTrace != nil else { return }
        recordInteractionDiagnostic(
            .sessionResumeEnded,
            level: result == "succeeded" || result == "cancelled" ? .info : .warning,
            fields: sessionResumeFields(result: result, code: code)
        )
        sessionResumeTrace = nil
        sessionResumeStartedAt = nil
    }

    private func beginTerminalInputProbeIfEligible() -> String? {
        let now = MobileDiagnostics.monotonicNow()
        guard serverFeatures.contains(
            RemoteWebSocketFeature.terminalInputLatencyProbe.rawValue
        ), pendingTerminalInputProbe == nil, now >= nextTerminalInputProbeAt else {
            return nil
        }
        let requestID = UUID().uuidString.lowercased()
        pendingTerminalInputProbe = PendingTerminalInputProbe(
            requestID: requestID,
            startedAtNanoseconds: now
        )
        let (next, overflow) = now.addingReportingOverflow(
            RemoteMobileConnectionDefaults.terminalInputProbeIntervalNanoseconds
        )
        nextTerminalInputProbeAt = overflow ? UInt64.max : next
        recordInteractionDiagnostic(
            .terminalInputProbeStarted,
            fields: terminalInputProbeFields(
                requestID: requestID,
                startedAtNanoseconds: now,
                result: "started"
            )
        )
        terminalInputProbeTimeoutTask?.cancel()
        terminalInputProbeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(
                for: RemoteMobileConnectionDefaults.terminalInputProbeTimeout
            )
            guard !Task.isCancelled else { return }
            self?.finishTerminalInputProbe(requestID: requestID, result: "timedOut")
        }
        return requestID
    }

    private func finishTerminalInputProbe(
        requestID: String? = nil,
        result: String
    ) {
        guard let pending = pendingTerminalInputProbe,
              requestID == nil || requestID == pending.requestID else { return }
        terminalInputProbeTimeoutTask?.cancel()
        terminalInputProbeTimeoutTask = nil
        pendingTerminalInputProbe = nil
        let durationMS = MobileDiagnostics.elapsedMilliseconds(
            since: pending.startedAtNanoseconds
        )
        recordInteractionDiagnostic(
            .terminalInputProbeEnded,
            level: result == "accepted" || result == "cancelled" ? .info : .warning,
            fields: terminalInputProbeFields(
                requestID: pending.requestID,
                startedAtNanoseconds: pending.startedAtNanoseconds,
                result: result
            )
        )
        // Ten seconds without the Mac acknowledging a keystroke is not latency. The socket may
        // still say connected; ask it.
        if result == "timedOut" { probeLiveness() }
#if DEBUG
        MobileTerminalWirePerformanceProbe.inputProbeCompleted(
            session: session,
            result: result,
            durationMS: durationMS
        )
#endif
    }

    private func terminalInputProbeFields(
        requestID: String,
        startedAtNanoseconds: UInt64,
        result: String
    ) -> [RemoteDiagnosticField: String] {
        var fields = destinationFields
        fields[.trace] = MobileDiagnostics.pseudonym(requestID, prefix: "trace")
        fields[.phase] = "clientRoundTrip"
        fields[.kind] = "terminal"
        fields[.result] = result
        fields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(
            since: startedAtNanoseconds
        )
        return fields
    }

    private func recordPromptSubmissionStarted(requestID: String, messageType: String) {
        var fields = destinationFields
        fields[.trace] = MobileDiagnostics.pseudonym(requestID, prefix: "trace")
        fields[.phase] = "clientRoundTrip"
        fields[.kind] = submissionKind(messageType)
        fields[.result] = "started"
        recordInteractionDiagnostic(.promptSubmissionStarted, fields: fields)
    }

    private func recordPromptSubmissionEnded(
        _ pending: PendingRemoteSubmission?,
        result: String
    ) {
        guard let pending else { return }
        var fields = destinationFields
        fields[.trace] = MobileDiagnostics.pseudonym(
            pending.requestID,
            prefix: "trace"
        )
        fields[.phase] = "clientRoundTrip"
        fields[.kind] = submissionKind(pending.messageType)
        fields[.result] = result
        fields[.durationMS] = MobileDiagnostics.elapsedMilliseconds(
            since: pending.startedAtNanoseconds
        )
        recordInteractionDiagnostic(
            .promptSubmissionEnded,
            level: result == RemotePromptSubmissionStatus.accepted.rawValue ? .info : .warning,
            fields: fields
        )
    }

    private func submissionKind(_ messageType: String) -> String {
        switch messageType {
        case "terminalSubmit": "terminal"
        case "terminalAttachmentInsert": "terminalAttachment"
        default: "conversation"
        }
    }

    private func recordInteractionDiagnostic(
        _ event: RemoteDiagnosticEvent,
        level: RemoteDiagnosticLevel = .info,
        fields: [RemoteDiagnosticField: String]
    ) {
        remoteInteractionDiagnosticQueue.async {
            MobileDiagnostics.recordConnectivity(event, level: level, fields: fields)
        }
    }

#if DEBUG
    /// Lets a focused test cross the asynchronous writer boundary without repeatedly reading the
    /// bounded on-disk journal (which can itself take long enough to starve the writer queue).
    func waitForInteractionDiagnosticsForTesting() async {
        await withCheckedContinuation { continuation in
            remoteInteractionDiagnosticQueue.async {
                continuation.resume()
            }
        }
    }
#endif

    /// Which session, which kind of address, and which address, as a hash.
    ///
    /// Without the last two, "wrong address" and "right address, host down" are the same record
    /// in a support report and have opposite fixes.
    private var destinationFields: [RemoteDiagnosticField: String] {
        [
            .session: MobileDiagnostics.pseudonym(session.id, prefix: "session"),
            .transport: client.endpointKind.rawValue,
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

    /// Whether a close frame reached this task. `closeCode` stays `.invalid` for a socket that
    /// died on the wire and is set both by the peer's frame and by our own `cancel(with:)`,
    /// which is why it is read before anything here cancels the task.
    private static func peerSentClose(on task: URLSessionWebSocketTask) -> Bool {
        task.closeCode != .invalid
    }

    /// What the journal says about the loss a retry answers: `peerClosed` when the Mac's close
    /// frame arrived, `routeSuspect` when the socket died without one.
    private static func lossToken(peerSentClose: Bool) -> String {
        peerSentClose ? "peerClosed" : "routeSuspect"
    }

    private func scheduleReconnect(generation: Int) {
        guard reconnectClient != nil, reconnectTask == nil,
              connectionGeneration == generation else { return }
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        let request = MobileSessionReconnectRequest(
            attempt: reconnectAttempt,
            peerSentClose: lossPeerSentClose
        )
        reconnectAttempt = min(reconnectAttempt + 1, 4)
        reconnectSequence &+= 1
        let delay = min(pow(2.0, Double(request.attempt)), 8.0)
        MobileDiagnostics.recordConnectivity(.socketReconnectScheduled, fields: socketFields(
            phase: "backoff"
        ).merging([
            .result: "scheduled",
            .attempt: String(reconnectSequence + 1),
            .delayMS: MobileDiagnostics.milliseconds(delay),
            .detail: Self.lossToken(peerSentClose: request.peerSentClose),
        ]) { current, _ in current })
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.connectionGeneration == generation,
                  let reconnectClient = self.reconnectClient else { return }
            guard let client = await reconnectClient(request) else {
                // Nothing to reconnect with: the locked screen would never be released.
                self.isAwaitingResume = false
                return
            }
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
        if pending.messageType == "terminalAttachmentInsert",
           !supportsTerminalAttachmentInsertion {
            finishPendingPrompt(with: .unavailable)
            return
        }
        isPromptSubmissionPending = true
        try? send(RemoteClientMessage(
            type: pending.messageType,
            text: pending.text,
            requestID: pending.requestID,
            contextAttachments: pending.contextAttachments.isEmpty
                ? nil
                : pending.contextAttachments,
            attachmentUploadIDs: pending.attachmentUploadIDs.isEmpty
                ? nil
                : pending.attachmentUploadIDs
        ))
    }

    private func finishPendingPrompt(with status: RemotePromptSubmissionStatus) {
        guard let pending = pendingPromptSubmission else { return }
        recordPromptSubmissionEnded(pending, result: status.rawValue)
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
                    role: .owner,
                    isOnline: true
                ),
            ],
            revision: 0
        )
    }

    static func demoTerminal() -> RemoteSessionConnection {
        let demoMode = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] ?? ""
        let marketingProvider: MobileMarketingTerminalFixture.Provider? = switch demoMode {
        case MobileDemoFixture.marketingClaudeTUI.rawValue,
             MobileDemoFixture.marketingClaudeUsageMenu.rawValue:
            .claude
        case MobileDemoFixture.marketingCodexTUI.rawValue:
            .codex
        default:
            nil
        }
        let isCodexFixture = demoMode == "terminal-ansi"
            || demoMode == "terminal-attachments"
            || demoMode == "terminal-codex-tui"
            || demoMode == "terminal-scrollback"
            || marketingProvider == .codex
        let agentName = isCodexFixture ? "Codex" : "Claude Code"
        let session: RemoteSessionSummaryDTO
        if let marketingProvider {
            session = RemoteAppModel.marketingTerminalSession(
                provider: marketingProvider,
                now: Date().timeIntervalSince1970
            )
        } else {
            session = RemoteSessionSummaryDTO(
                id: "f50c77da-5716-470b-933c-d68310644b4f",
                title: "\(agentName) · AnotherTerminal",
                agentKind: isCodexFixture ? "codex" : "claude",
                surface: .terminal,
                state: .idle,
                projectName: "AnotherTerminal"
            )
        }
        let link = RemoteConnectionLink(string: "https://demo.invalid/#terminal-preview")!
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: link)
        )
        connection.phase = .connected
        connection.surface = .terminal
        connection.capability = .interact
        let requestedTheme = ProcessInfo.processInfo.environment["THREADING_MOBILE_THEME"]
        switch requestedTheme {
        case "fallback":
            connection.theme = nil
        case "light":
            connection.theme = RemoteAppModel.demoLightTheme
        case "threading":
            connection.theme = RemoteAppModel.demoThreadingTheme
        case "system-remote":
            connection.theme = RemoteAppModel.demoSystemRemoteTheme
        case let requested?:
            connection.theme = RemoteAppModel.demoCatalogThemes.first(where: {
                $0.id == requested
            }) ?? RemoteAppModel.demoTheme
        case nil:
            connection.theme = RemoteAppModel.demoTheme
        }
        if marketingProvider != nil, let appTheme = connection.theme {
            connection.terminalTheme = RemoteAppModel.demoMarketingTerminalTheme(
                matching: appTheme
            )
        } else {
            connection.terminalTheme = requestedTheme == "threading"
                ? RemoteAppModel.demoThreadingTerminalTheme
                : RemoteAppModel.demoTerminalTheme
        }
        connection.terminalColumns = 48
        connection.terminalRows = 18
        // This DEBUG-only snapshot fixture preloads bytes directly and has no demo script or
        // remote host that can answer its first viewport with `terminalReady`. Advertising the
        // ordered boundary here would promise a frame that can never arrive; the real in-app
        // demo goes through `DemoSessionScript` and does advertise it.
        connection.serverFeatures = Set(
            RemoteWebSocketFeature.allCases
                .filter { $0 != .terminalHydrationBoundary }
                .map(\.rawValue)
        )
        connection.supportsAtomicTerminalSubmission = true
        connection.supportsAttentionRequests = true
        connection.supportsFocusedInputControl = true
        connection.supportsComposerAttachmentUploads = true
        connection.supportsTerminalAttachmentInsertion = true
        connection.inputControl = ownerOnlyInputControlState()
        if let marketingProvider {
            let fixture: MobileMarketingTerminalFixture
            do {
                fixture = try MobileMarketingTerminalFixture.load(
                    marketingProvider,
                    mode: connection.theme.map(MobileMarketingTerminalFixture.TerminalMode.matching)
                        ?? .dark
                )
            } catch {
                fatalError("Invalid marketing terminal fixture: \(error)")
            }
            connection.terminalColumns = fixture.columns
            connection.terminalRows = fixture.rows
            connection.pendingTerminalOutput = fixture.payload
            if marketingProvider == .claude {
                connection.runPlanRevision = 1
                connection.runPlan = RemoteRunPlanSummaryDTO(
                    activeTitle: "Render theme variants",
                    current: 3,
                    completed: 2,
                    active: 1,
                    total: 3
                )
                connection.runPlanSteps = [
                    .init(id: "0", title: "Build deterministic provider fixtures", status: .completed),
                    .init(id: "1", title: "Capture six marketing checkpoints", status: .completed),
                    .init(id: "2", title: "Render theme variants", status: .inProgress),
                ]
            }
            return connection
        }
        let lines: [String]
        switch demoMode {
        case "terminal-selection":
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;35mClaude Code\u{1b}[0m",
                "\u{1b}[2mSonnet · AnotherTerminal\u{1b}[0m",
                "",
                "\u{23FA} Bash(sudo nginx -t)",
                "  \u{23BF}  nginx: the configuration file /etc/nginx/nginx.conf syntax is ok",
                "",
                "\u{1b}[31mnginx: [emerg] unknown directive \"serer_name\" in /etc/nginx/sites-enabled/app:12\u{1b}[0m",
                "\u{1b}[31mnginx: configuration file /etc/nginx/nginx.conf test failed\u{1b}[0m",
                "",
                "\u{23FA} Read(/etc/nginx/sites-enabled/app)",
                "  \u{23BF}  Read 41 lines",
                "",
                "❯ ",
            ]
        case "terminal-attachments":
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;36mCodex\u{1b}[0m  AnotherTerminal",
                "\u{1b}[2mDirect TUI input · attachment paths insert at the cursor\u{1b}[0m",
                "",
                "› Compare the screenshots in ",
            ]
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
                "\u{1b}[2J\u{1b}[H\u{1b}[?1000h\u{1b}[?1006h\u{1b}[1;35mClaude Code\u{1b}[0m",
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
            let compileLines = (1...72).map { index in
                let source = [
                    "RemoteConversationViewController.swift",
                    "RemoteNotifications.swift",
                    "TerminalViewRepresentable.swift",
                    "RemoteSessionConnection.swift",
                ][index % 4]
                return "Compile [\(index)/72] \(source)"
            }
            lines = [
                "\u{1b}[2J\u{1b}[H\u{1b}[1;36mCodex\u{1b}[0m  Test run",
                "$ xcodebuild -scheme ThreadingMobile test",
            ] + compileLines + [
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
            state: .typing
        )
        let ipad = RemotePresenceDTO(
            presenceID: "terminal-ipad",
            memberID: "member-david",
            displayName: "David",
            deviceName: "iPad",
            surface: .terminal,
            state: .viewing
        )
        connection.presence = [anna.id: anna, ipad.id: ipad]
        connection.attentionRecipients = [
            .init(id: "member-anna", displayName: "Anna", role: .member, isOnline: true),
            .init(id: "member-priya", displayName: "Priya", role: .member, isOnline: false),
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
                .init(id: "owner", displayName: "David", role: .owner, isOnline: true),
                .init(id: "member-anna", displayName: "Anna", role: .member, isOnline: true),
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
        let demoMode = environment[MobileDemoScene.environmentKey] ?? ""
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
            state: .idle,
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
                    kind: .user,
                    text: "Review the remote access work, fix what you find, and make the iPhone experience feel native."
                ),
                .init(
                    id: "1",
                    kind: .assistant,
                    text: "I found two concrete issues in the first pass: dormant sessions could not be resumed remotely, and native conversations were being flattened into a terminal-shaped experience."
                ),
                .init(
                    id: "2",
                    kind: .tool,
                    toolName: "Bash",
                    summary: "xcodebuild ThreadingMobile",
                    result: "Build Succeeded"
                ),
                .init(
                    id: "3",
                    kind: .assistant,
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
                kind: .user,
                text: "Review the keyboard lifecycle, quote the relevant file, and run the focused tests."
            ),
            .init(
                id: "content-thinking",
                kind: .thinking,
                text: "I need to trace first-responder ownership and compare the editor frame before and after dismissal."
            ),
            .init(
                id: "content-tool-success",
                kind: .tool,
                toolName: "Read",
                summary: "RemoteConversationViewController.swift · 164 lines",
                result: "Found keyboard frame observation and the composer bottom constraint."
            ),
            .init(
                id: "content-tool-error",
                kind: .tool,
                toolName: "Bash",
                summary: "swift test --filter KeyboardLifecycleTests",
                result: "Exit 1 · editor stayed 291 pt above its baseline",
                isError: true
            ),
            .init(
                id: "content-notice",
                kind: .notice,
                text: "The connection recovered. Tool output before the reconnect was preserved."
            ),
            .init(
                id: "content-assistant",
                kind: .assistant,
                text: """
                Keyboard lifecycle passed: focus waits for `keyboardDidShow`, dismissal waits for
                `keyboardDidHide`, and the composer returns to its original visual anchor.
                """
            ),
        ]
        let richContentRows: [RemoteConversationRowDTO] = [
            .init(
                id: "rich-user",
                kind: .user,
                text: "Show the release result with the structure and code intact."
            ),
            .init(
                id: "rich-assistant",
                kind: .assistant,
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
                kind: .user,
                text: "Compare the visual review with the implementation and keep the linked evidence together.",
                contextAttachments: [
                    .init(
                        id: "attachment-image",
                        kind: .reference,
                        source: .attachment,
                        title: "keyboard-dismissed.png",
                        excerpt: "1179 × 2556 PNG · 184 KB",
                        locator: "screenshots/keyboard-dismissed.png"
                    ),
                    .init(
                        id: "attachment-pdf",
                        kind: .reference,
                        source: .attachment,
                        title: "threading-ui-review.pdf",
                        excerpt: "12-page review · 843 KB",
                        locator: "artifacts/threading-ui-review.pdf"
                    ),
                    .init(
                        id: "attachment-code",
                        kind: .comment,
                        source: .code,
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
                kind: .assistant,
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
                        kind: .user,
                        text: "Remote prompt \(index): verify the deterministic cross-device fixture."
                    )
                case 1, 5, 9:
                    return RemoteConversationRowDTO(
                        id: String(index),
                        kind: .tool,
                        toolName: index.isMultiple(of: 2) ? "Read" : "Bash",
                        summary: "Sources/Remote/Fixture\(index).swift",
                        result: "Completed deterministic operation \(index)."
                    )
                default:
                    return RemoteConversationRowDTO(
                        id: String(index),
                        kind: .assistant,
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
                    kind: index.isMultiple(of: 7) ? .tool : .assistant,
                    text: index.isMultiple(of: 7) ? nil : "Cached fixture message \(index).",
                    toolName: index.isMultiple(of: 7) ? "Read" : nil,
                    summary: index.isMultiple(of: 7) ? "Sources/Feature\(index).swift" : nil,
                    result: index.isMultiple(of: 14) ? "Read 84 lines" : nil
                )
            }
            rows = history + [
                .init(
                    id: "396",
                    kind: .user,
                    text: "Please review this very long conversation on a compact phone, including dynamic type, code, and a permission request without losing my reading position."
                ),
                .init(
                    id: "397",
                    kind: .assistant,
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
                    kind: .tool,
                    toolName: "Bash",
                    summary: "xcodebuild -scheme ThreadingMobile test",
                    result: "Executed the focused performance and protocol fixtures successfully."
                ),
                .init(
                    id: "399",
                    kind: .notice,
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
                    kind: index.isMultiple(of: 5) ? .user : .assistant,
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
                    kind: .user,
                    text: "Check the compact layout while the agent is still responding."
                ),
                .init(
                    id: "stream-tool",
                    kind: .tool,
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
                kind: .command,
                trigger: .slash,
                presentation: .turn
            ),
            RemoteComposerCapabilityDTO(
                id: "codex.skill:release",
                name: "release",
                displayName: "Release",
                description: "Prepare and verify a release",
                argumentHint: "[version]",
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            ),
            RemoteComposerCapabilityDTO(
                id: RemoteComposerCatalog.skillsCommandID,
                name: "skills",
                displayName: "Skills",
                description: "Browse skills available in this conversation",
                argumentHint: "",
                kind: .command,
                trigger: .slash,
                presentation: .command
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
        if demoMode.hasPrefix("conversation-question") {
            let request = RemoteQuestionRequestDTO(
                id: "F1000000-0000-0000-0000-000000000001",
                questions: [
                    .init(id: "density", header: "Density", prompt: "How much work detail should the chat show?",
                          options: [.init(label: "Compact", detail: "Keep completed work behind a disclosure."),
                                    .init(label: "Expanded", detail: "Show every step in the transcript.")],
                          allowsOther: true),
                    .init(id: "review", header: "Review", prompt: "What should we check first?",
                          options: [.init(label: "Interactions", detail: "Check scrolling and keyboard behavior."),
                                    .init(label: "Appearance", detail: "Check spacing, typography, and themes.")],
                          allowsOther: false)
                ], blocksTurn: true, canAnswer: demoMode != "conversation-question-readonly"
            )
            connection.conversationStore.replace(with: RemoteConversationSnapshotDTO(
                rows: [.init(id: "question-user", kind: .user, text: "Polish this chat on Mac and iPhone."),
                       .init(id: "question-assistant", kind: .assistant, text: "I have one choice to check before continuing.")],
                canSend: false, questions: [request]
            ))
        }
        if demoMode == "conversation-run-plan" || demoMode == "conversation-run-plan-expanded" {
            connection.runPlanRevision = 7
            connection.runPlan = RemoteRunPlanSummaryDTO(
                activeTitle: "Polish the phone checklist disclosure",
                current: 3,
                completed: 2,
                active: 1,
                total: 5
            )
            connection.runPlanSteps = [
                .init(id: "0", title: "Inspect structured provider events", status: .completed),
                .init(id: "1", title: "Relay the current plan to every surface", status: .completed),
                .init(id: "2", title: "Polish the phone checklist disclosure", status: .inProgress),
                .init(id: "3", title: "Verify native and terminal fixtures", status: .pending),
                .init(id: "4", title: "Document the structured-data boundary", status: .pending),
            ]
        }
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
                state: .typing
            )
            let ipad = RemotePresenceDTO(
                presenceID: "presence-ipad",
                memberID: "owner-ipad",
                displayName: "David’s iPad",
                deviceName: "David’s iPad",
                surface: .conversation,
                state: .viewing
            )
            connection.presence = [anna.id: anna, ipad.id: ipad]
            connection.attentionRecipients = [
                .init(id: "member-anna", displayName: "Anna", role: .member, isOnline: true),
                .init(id: "member-priya", displayName: "Priya", role: .member, isOnline: false),
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
                    .init(id: "owner", displayName: "David", role: .owner, isOnline: true),
                    .init(
                        id: "member-anna",
                        displayName: "Anna",
                        role: .member,
                        isOnline: true
                    ),
                    .init(
                        id: "member-priya",
                        displayName: "Priya",
                        role: .member,
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
        let usesLongFixture = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == "permission-long"
        connection.conversationStore.replace(with: RemoteConversationSnapshotDTO(
            rows: [
                .init(
                    id: "0",
                    kind: .user,
                    text: "Update the connection state without losing the first terminal frame."
                ),
                .init(
                    id: "1",
                    kind: .assistant,
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
                    .init(id: "0", kind: .context, text: "# This command runs deterministic local fixtures only."),
                    .init(id: "1", kind: .addition, text: "THREADING_UI_EVIDENCE_VERIFY_KEYBOARD=1 scripts/ui-evidence-ios.sh"),
                    .init(id: "2", kind: .addition, text: "open .build/ui-evidence-ios-reports/latest/report/index.html"),
                ] : [
                    .init(id: "0", kind: .removal, text: "onTerminalOutput?(data)"),
                    .init(id: "1", kind: .addition, text: "pendingTerminalOutput.append(data)"),
                ]
            )
        ))
        return connection
    }
#endif
}
