import Foundation

// MARK: - Refusals

/// Why a control frame could not be believed.
///
/// A wire value this build has no meaning for is refused with a token, never defaulted to a
/// neighbouring case and never dropped: a `spawn` that silently became a `pipes` spawn, or a
/// session id that silently became a different session, is worse than a closed connection.
public enum PTYHostFrameRefusal: Error, Equatable, Sendable {
    /// A `type` this build does not know. A frame is additive, so meeting one means the peer is
    /// newer than the `hello` gate admitted.
    case unknownFrameType(String)
    /// A frame type that carries fields arrived without its `body`.
    case missingBody(type: String)
    case malformedSessionIdentity(String)
    case unknownChannel(String)
    case unknownReplay(String)
}

// MARK: - The control frames

/// Every JSON control frame, in one enum.
///
/// The whole set is here rather than spread over per-frame types because the set *is* the
/// protocol: a reader of this file should be able to see everything the two processes can say to
/// each other, and `docs/architecture/pty-host.md` holds the same table in prose.
///
/// **The discriminator is a `type` string and the fields live under `body`.** One place decides
/// the shape, so adding a frame is one case and one token and cannot disturb any existing frame
/// — which is what makes the bump policy in `PTYHostProtocol` honest about additive changes. The
/// alternative, flattening each payload beside `type`, needs a hand-written coder per case and
/// gets a key collision the day two frames want the same field name.
///
/// Not here, deliberately: any token or capability (the `0700` directory is the boundary), any
/// theme, any sequence number (stream delivery is ordered and the seeds are idempotent), any
/// viewport lease, and any title, cwd or activity — the app parses those, and the daemon parses
/// nothing.
public enum PTYHostFrame: Codable, Equatable, Sendable {

    /// Exchanged in both directions on connect. The protocol pair is the gate; `build` is
    /// reported and journalled and never compared for admission (`PTYHostProtocol`).
    case hello(PTYHostHello)

    /// The daemon's refusal of a `hello`, naming which side has to move. Followed by a close.
    case helloRefused(PTYHostHelloRefusal)

    /// App → daemon: what are you holding?
    case list

    /// Daemon → app: everything it holds, running or held-for-a-late-observer.
    case sessions([PTYHostSessionSummary])

    /// App → daemon: start a child.
    ///
    /// The frame carries the *whole* launch — executable, argv, `execName`, environment and cwd
    /// — and the daemon uses them verbatim, adding nothing. That is load-bearing rather than
    /// tidy: the daemon inherits launchd's environment rather than the user's, and the
    /// composition rules (`AgentEnvironment`'s inherited-identity prefixes, the measured leakage
    /// list in `sessions.md`) are one decision that stays in one place in the app.
    ///
    /// **Room for the fd-passing construction.** A feasibility probe may yet show that a child
    /// forked by a launchd agent is attributed to the daemon rather than to Threading by TCC
    /// (R1). The fallback inverts who forks: the *app* calls `forkpty`, so the child is
    /// Threading's, and passes the master fd to the daemon over `SCM_RIGHTS`. Every other frame
    /// in this file survives that unchanged, and this one is shaped so it can too —
    /// `PTYHostChannel` is a discriminated enum, so the fallback is a new case (an adopted
    /// descriptor, whose pid and start time the app already knows) or a sibling `adopt` frame
    /// beside this one. Neither reshapes what is already here, so neither bumps the protocol.
    case spawn(PTYHostSpawnRequest)

    /// Daemon → app: the child exists, here is what identifies it.
    case spawned(PTYHostSpawned)

    /// Daemon → app: it does not, and the reason is a token rather than a sentence.
    case spawnRefused(PTYHostSpawnRefused)

    /// App → daemon: I want this session's bytes, and here is what I can hold of its history.
    case attach(PTYHostAttach)

    /// Daemon → app: attached, and here is what the raw bytes that follow are.
    case attached(PTYHostAttached)

    /// App → daemon: the window changed. This sets the durable grid and raises `SIGWINCH`; an
    /// `attach` deliberately does not, because a new watcher inherits the grid rather than
    /// imposing one (D8).
    case resize(PTYHostResize)

    /// Daemon → app: the grid it applied, to the connection that asked for it.
    ///
    /// The answering frame `resize` did without in version 1, and the reason it needs one is
    /// that `resize` is the only app-to-daemon frame whose delivery the app cannot verify for
    /// itself. In-process the same seam is a synchronous `ioctl` that cannot fail once the
    /// emulator has resized; across a socket it is a write that may be refused, and one refused
    /// write used to leave the emulator and the child's terminal disagreeing until the grid
    /// happened to change again — measured as a 111×81 pty under a 210-column pane, with the
    /// emulator wrapping the child's lines mid-word.
    ///
    /// It carries the grid the daemon **actually applied**, which is also what it stored as the
    /// session's durable window size, so the app compares its own wanted grid against a fact
    /// rather than against what it hoped. Sent only to the connection that asked: another
    /// watcher's resize is not this watcher's acknowledgement.
    case resized(PTYHostResized)

    /// App → daemon: I am leaving, and here is what the screen looked like when I did.
    case detach(PTYHostDetach)

    /// App → daemon: the child will read no more input.
    ///
    /// The graceful shutdown of every native transport, and the reason it needs a frame of its
    /// own: `ClaudeStreamSession`, `CodexStreamSession` and `ACPStreamSession` all end a
    /// conversation by closing the CLI's standard input and letting it exit on end-of-input,
    /// which is a *descriptor* event and has no representation in a byte stream. Without this the
    /// only way to end a hosted conversation would be `kill`, which is the ungraceful one.
    ///
    /// Meaningless on a `.pty` session, where the master is one bidirectional descriptor and
    /// closing it is closing the terminal; that is answered `unsupportedChannel` rather than
    /// obeyed.
    case closeInput(PTYHostCloseInput)

    /// App → daemon: end this child.
    case kill(PTYHostKill)

    /// Daemon → app: it ended.
    case exited(PTYHostExited)

    /// Daemon → app: a different process group owns the terminal now.
    ///
    /// The one question the app can no longer answer for itself about a host-backed session.
    /// `TerminalSession` reads `tcgetpgrp` off the descriptor it owns to decide whether the
    /// title belongs to the shell or to whatever it is running, and a host-backed session has no
    /// descriptor to read. The daemon holds the master, so this is one syscall with no parsing —
    /// it learns nothing about the byte stream by answering it.
    ///
    /// Pushed on change, never polled by the app: checked after each coalesced output burst and
    /// on a slow timer while at least one watcher is attached, and not at all while detached,
    /// because a detached session has nobody to tell.
    case foreground(PTYHostForeground)

    /// Daemon → app: a restart could not account for these. The honest half of the failure model
    /// — when the daemon dies its children lose their master fd and the CLIs exit, so the design
    /// goal is to *say* what was lost rather than pretend nothing was (D12).
    case lost(PTYHostLost)

    /// App → daemon: unlink the socket now so a new binary can bind it, keep serving what is
    /// already attached, and exit when the last session ends.
    case retire

    /// App → daemon: a bounded tail of your journal, for diagnostics — never a shared file, so
    /// the two processes cannot interleave writes into one.
    case journalTail(PTYHostJournalTail)

    /// Daemon → app: those lines.
    case journal(PTYHostJournal)

    /// Daemon → app: an in-band failure that does not end the connection.
    case error(PTYHostErrorFrame)
}

// MARK: - Frame bodies

/// A protocol version pair plus the process generation used for reporting and graceful upgrade.
public struct PTYHostHello: Codable, Equatable, Sendable {
    /// `protocol` on the wire; a Swift keyword, hence the property name.
    public let protocolVersion: Int
    public let minimumSupported: Int
    /// The sender's generation. It may select graceful replacement, but never gates admission;
    /// see `PTYHostProtocol`.
    public let build: String
    public let pid: Int32

    public init(
        protocolVersion: Int = PTYHostProtocol.current,
        minimumSupported: Int = PTYHostProtocol.minimumSupported,
        build: String,
        pid: Int32
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupported = minimumSupported
        self.build = build
        self.pid = pid
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case minimumSupported
        case build
        case pid
    }
}

public struct PTYHostHelloRefusal: Codable, Equatable, Sendable {
    public let compatibility: PTYHostCompatibility
    public let update: PTYHostUpdateTarget

    public init(compatibility: PTYHostCompatibility, update: PTYHostUpdateTarget) {
        self.compatibility = compatibility
        self.update = update
    }
}

/// How a child is wired up.
///
/// Present from protocol version 1, which is what let hosting native conversations arrive as a
/// daemon change rather than a protocol bump (D6). It is also the seam the fd-passing fallback
/// would extend; see `PTYHostFrame.spawn`.
public enum PTYHostChannel: Codable, Equatable, Sendable {
    /// A pseudo-terminal, sized by `grid`. The app must send the real grid: SwiftTerm clamps an
    /// unlaid-out view to 2×1 rather than to zero, and `forkpty` takes 2×1 at face value, so a
    /// placeholder boots the agent's TUI into a two-column window.
    case pty(grid: PTYHostGrid)

    /// Three pipes — stdin, stdout, stderr — a process group, and `waitpid`.
    ///
    /// What a native conversation's CLI is launched on: `AgentChildProcess`'s spawn contract
    /// minus the `Process` object. The three streams stay three on the wire as well, because
    /// merging stderr into stdout would corrupt the JSON line stream the transports parse —
    /// stderr crosses as a `kind` 1 frame carrying `PTYHostFramingDefaults.standardErrorFlag`.
    ///
    /// A pipes session has **no terminal**, so three things a `.pty` session has are absent
    /// rather than defaulted: no grid (`resize` is answered `unsupportedChannel`), no
    /// `tcgetpgrp` and therefore no `foreground` frame, and no screen to seed — a `detach`
    /// carries empty seeds and a rejoin is always `.cut`.
    case pipes

    enum Mode: String, Codable {
        case pty
        case pipes
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case grid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .mode)
        guard let mode = Mode(rawValue: raw) else {
            throw PTYHostFrameRefusal.unknownChannel(raw)
        }
        switch mode {
        case .pty: self = .pty(grid: try container.decode(PTYHostGrid.self, forKey: .grid))
        case .pipes: self = .pipes
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pty(let grid):
            try container.encode(Mode.pty, forKey: .mode)
            try container.encode(grid, forKey: .grid)
        case .pipes:
            try container.encode(Mode.pipes, forKey: .mode)
        }
    }
}

public struct PTYHostSpawnRequest: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let channel: PTYHostChannel
    public let executable: String
    public let arguments: [String]
    /// `argv[0]`, when it must differ from `executable` — a login shell is spawned as `-zsh`.
    public let execName: String?
    /// `KEY=value` entries, complete. The daemon adds nothing to this and removes nothing.
    public let environment: [String]
    public let cwd: String?
    /// This launch intentionally supersedes any live incarnation of the same durable identity.
    /// Optional for additive compatibility: an older app omits it, and an older daemon ignores
    /// it. A new daemon treats only `true` as replacement authority.
    public let replaceExisting: Bool?

    public init(
        id: PTYHostSessionIdentity,
        channel: PTYHostChannel,
        executable: String,
        arguments: [String],
        execName: String? = nil,
        environment: [String],
        cwd: String? = nil,
        replaceExisting: Bool = false
    ) {
        self.id = id
        self.channel = channel
        self.executable = executable
        self.arguments = arguments
        self.execName = execName
        self.environment = environment
        self.cwd = cwd
        self.replaceExisting = replaceExisting ? true : nil
    }
}

public struct PTYHostSpawned: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let pid: Int32
    /// The other half of the child's identity, so a recorded pid can never be acted on after the
    /// number has been reused.
    public let startTime: PTYHostProcessStartTime

    public init(id: PTYHostSessionIdentity, pid: Int32, startTime: PTYHostProcessStartTime) {
        self.id = id
        self.pid = pid
        self.startTime = startTime
    }
}

/// Why a spawn did not happen. Structural tokens: they cross the wire, reach a journal, and must
/// never carry anything a person wrote or a path the user chose.
public enum PTYHostSpawnRefusal: String, Codable, Equatable, Sendable {
    case alreadyExists
    case executableUnavailable
    case retiring
    case capacity
    /// A `channel` this build does not implement. Nothing refuses `.pipes` any more, but the
    /// token stays because the refusal is the rule rather than the case: a conversation transport
    /// quietly given a pseudo-terminal would look like a working session producing unparseable
    /// output, so an unimplemented channel is always a refusal and never a substitution.
    case unsupportedChannel
}

public struct PTYHostSpawnRefused: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let reason: PTYHostSpawnRefusal

    public init(id: PTYHostSessionIdentity, reason: PTYHostSpawnRefusal) {
        self.id = id
        self.reason = reason
    }
}

/// The bounds a replay budget is held to.
///
/// The numbers mirror `RemoteAccessDefaults.ringBufferBytes` and
/// `minimumTerminalReplayBudgetBytes`, and are restated rather than shared because the daemon
/// cannot link the app. `PTYHostReplayTests` pins them so the two cannot drift silently.
public enum PTYHostReplayDefaults {
    /// The floor a stated budget is raised to. Below this a tail is a few lines of a wide grid,
    /// which is more plausibly a mistake than an intention.
    public static let minimumBudgetBytes = 16 * 1024
    /// The ceiling, which is the ring itself: a larger number is not a request for more history,
    /// because none exists.
    public static let ringBufferBytes = 512 * 1024
}

public struct PTYHostAttach: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// How much history the watcher says it can hold, or nil for "no statement".
    public let replayBudget: Int?

    public init(id: PTYHostSessionIdentity, replayBudget: Int? = nil) {
        self.id = id
        self.replayBudget = replayBudget
    }

    /// The stated budget, held to the host's range.
    ///
    /// Only a missing or non-positive value is "no statement", and only that is answered with
    /// everything. Anything else is a statement and stays one — clamped into the range rather
    /// than discarded, because refusing a small ask costs the watcher the very parse it asked to
    /// avoid. Mirrors `RemoteInboundPolicy.normalizedTerminalReplayBudget`.
    public static func normalizedBudget(_ rawValue: Int?) -> Int? {
        guard let rawValue, rawValue > 0 else { return nil }
        return min(
            max(rawValue, PTYHostReplayDefaults.minimumBudgetBytes),
            PTYHostReplayDefaults.ringBufferBytes
        )
    }

    public var normalizedReplayBudget: Int? { Self.normalizedBudget(replayBudget) }
}

/// What the raw output frames that follow an `attached` are.
///
/// The three answers are `RemoteSessionMirrorRegistry.TerminalReplay`'s, restated for a transport
/// where the ring *is* the stream rather than lagging it by a main-queue hop — which is what
/// makes `.exact` possible at all (D7).
public enum PTYHostReplay: Codable, Equatable, Sendable {
    /// Every byte the watcher missed, and no more: the stored screen seed, then the ring from
    /// `fromOffset`, then the stored mode seed. No cut marker, no loss, no repaint gamble.
    /// Available when the detach seed exists and the ring has not wrapped past its offset.
    case exact(fromOffset: UInt64)
    /// The ring wrapped, or there was no seed. `CAN` (0x18) then the ring tail — CAN first,
    /// because cutting the head off the ring means the replay can now *begin* inside an escape
    /// sequence too. The watcher re-derives its own screen from what follows.
    ///
    /// **On a `.pipes` session the tail is trimmed to a line boundary**, and this is the only
    /// answer such a session ever gives. The stream the adapters parse is newline-delimited
    /// JSON, so a tail beginning mid-line hands a fresh parser one guaranteed malformed line;
    /// the daemon therefore drops everything before the first newline in the tail, leaving the
    /// `CAN` alone on the first line and every line after it whole. It still parses nothing to
    /// do it — finding a byte is not reading a stream.
    case cut
    /// There is no history to replay.
    case none

    enum Mode: String, Codable {
        case exact
        case cut
        case none
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case fromOffset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .mode)
        guard let mode = Mode(rawValue: raw) else {
            throw PTYHostFrameRefusal.unknownReplay(raw)
        }
        switch mode {
        case .exact: self = .exact(fromOffset: try container.decode(UInt64.self, forKey: .fromOffset))
        case .cut: self = .cut
        case .none: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact(let offset):
            try container.encode(Mode.exact, forKey: .mode)
            try container.encode(offset, forKey: .fromOffset)
        case .cut:
            try container.encode(Mode.cut, forKey: .mode)
        case .none:
            try container.encode(Mode.none, forKey: .mode)
        }
    }
}

public struct PTYHostAttached: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let pid: Int32
    /// The grid the session already has. The watcher adopts it; it does not impose its own.
    public let grid: PTYHostGrid
    public let replay: PTYHostReplay
    /// The ring's monotonic write count as of this frame. The watcher records it and sends it
    /// back in `detach`, which is the whole mechanism behind `.exact`.
    public let totalBytesWritten: UInt64

    public init(
        id: PTYHostSessionIdentity,
        pid: Int32,
        grid: PTYHostGrid,
        replay: PTYHostReplay,
        totalBytesWritten: UInt64
    ) {
        self.id = id
        self.pid = pid
        self.grid = grid
        self.replay = replay
        self.totalBytesWritten = totalBytesWritten
    }
}

public struct PTYHostResize: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let grid: PTYHostGrid

    public init(id: PTYHostSessionIdentity, grid: PTYHostGrid) {
        self.id = id
        self.grid = grid
    }
}

/// The grid a `resize` actually put on a session's pseudo-terminal.
///
/// Four numbers rather than "it worked", because the acknowledgement is only worth having if the
/// app can compare it with what it asked for: a grid the daemon clamped, or a stale one it is
/// still holding, has to be told apart from the one that was wanted, and a boolean cannot.
public struct PTYHostResized: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// What `TIOCSWINSZ` was given, and what the session now keeps as its durable window size.
    public let grid: PTYHostGrid

    public init(id: PTYHostSessionIdentity, grid: PTYHostGrid) {
        self.id = id
        self.grid = grid
    }
}

/// The last watcher is leaving, and hands over what only it could compute.
///
/// The daemon cannot synthesise a screen — a repaint is derived from a live emulator, and the
/// daemon has none. But the app is present at exactly the moment the last watcher leaves, so it
/// computes both seeds then and the daemon stores three opaque values. It still parses nothing.
public struct PTYHostDetach: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// `RemoteScreenSeed.repaint(of:)`'s bytes. Opaque to the daemon.
    public let screenSeed: Data
    /// `RemoteTerminalModeSeed.bytes(for:)`'s bytes. Replayed **last** in both branches, because
    /// the ring is replayed history and history holds modes that stopped being true.
    public let modeSeed: Data
    /// The ring's `totalBytesWritten` as of the last byte this watcher had applied.
    public let ringOffset: UInt64
    /// When a deliberately idle child may be stopped if nobody has attached again. Nil for
    /// unfinished or otherwise protected work. Optional so version-1 detach frames still decode.
    public let idleExpiresAt: Date?

    public init(
        id: PTYHostSessionIdentity,
        screenSeed: Data,
        modeSeed: Data,
        ringOffset: UInt64,
        idleExpiresAt: Date? = nil
    ) {
        self.id = id
        self.screenSeed = screenSeed
        self.modeSeed = modeSeed
        self.ringOffset = ringOffset
        self.idleExpiresAt = idleExpiresAt
    }
}

/// Close this child's standard input, and nothing else.
public struct PTYHostCloseInput: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity

    public init(id: PTYHostSessionIdentity) {
        self.id = id
    }
}

public struct PTYHostKill: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// `SIGTERM`, then `SIGKILL` to the process **group** after a grace period.
    public let escalate: Bool

    public init(id: PTYHostSessionIdentity, escalate: Bool) {
        self.id = id
        self.escalate = escalate
    }
}

public struct PTYHostExited: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// The exit code, or the signal number when `signalled`.
    public let status: Int32
    public let signalled: Bool

    public init(id: PTYHostSessionIdentity, status: Int32, signalled: Bool) {
        self.id = id
        self.status = status
        self.signalled = signalled
    }
}

/// Which process group currently owns a session's terminal.
public struct PTYHostForeground: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    /// `pid_t`, spelled `Int32` so this package needs no `Darwin` import to describe it. Zero is
    /// never sent: a terminal with no foreground group is reported by not sending the frame.
    public let processGroup: Int32

    public init(id: PTYHostSessionIdentity, processGroup: Int32) {
        self.id = id
        self.processGroup = processGroup
    }
}

public struct PTYHostLost: Codable, Equatable, Sendable {
    public let ids: [PTYHostSessionIdentity]
    /// The last moment the daemon can vouch for them — its own previous journal write.
    public let since: Date
    /// One recovery event, repeated on every connection for this daemon's lifetime. Optional so
    /// a current app continues to understand a compatible daemon from before incident identity
    /// was added to this additive frame.
    public let incidentID: UUID?
    /// When the replacement daemon detected the loss, distinct from `since`, which may be the
    /// much earlier time the oldest lost child was spawned.
    public let detectedAt: Date?

    public init(
        ids: [PTYHostSessionIdentity],
        since: Date,
        incidentID: UUID? = nil,
        detectedAt: Date? = nil
    ) {
        self.ids = ids
        self.since = since
        self.incidentID = incidentID
        self.detectedAt = detectedAt
    }
}

public struct PTYHostJournalTail: Codable, Equatable, Sendable {
    public let maxBytes: Int

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }
}

public struct PTYHostJournal: Codable, Equatable, Sendable {
    public let lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

/// An in-band failure. Structural tokens, never sentences: this reaches a journal and a support
/// report, and neither may carry a path the user chose or anything a person wrote.
public enum PTYHostError: String, Codable, Equatable, Sendable {
    case unknownSession
    case notAttached
    case alreadyAttached
    case sessionExited
    case unsupportedChannel
    case malformedFrame
    case retiring
    case spawnFailed
    case internalFailure
}

public struct PTYHostErrorFrame: Codable, Equatable, Sendable {
    public let code: PTYHostError
    /// A bounded machine token qualifying `code`, such as the guard clause that refused.
    public let detail: String?

    public init(code: PTYHostError, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

// MARK: - Codable

extension PTYHostFrame {

    /// The wire tokens. Case names by design: a reordered enum must not rename a frame.
    enum FrameType: String, Codable {
        case hello
        case helloRefused
        case list
        case sessions
        case spawn
        case spawned
        case spawnRefused
        case attach
        case attached
        case resize
        case resized
        case detach
        case closeInput
        case kill
        case exited
        case foreground
        case lost
        case retire
        case journalTail
        case journal
        case error
    }

    enum CodingKeys: String, CodingKey {
        case type
        case body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .type)
        guard let type = FrameType(rawValue: raw) else {
            throw PTYHostFrameRefusal.unknownFrameType(raw)
        }
        switch type {
        case .hello: self = .hello(try Self.body(container, raw))
        case .helloRefused: self = .helloRefused(try Self.body(container, raw))
        case .list: self = .list
        case .sessions: self = .sessions(try Self.body(container, raw))
        case .spawn: self = .spawn(try Self.body(container, raw))
        case .spawned: self = .spawned(try Self.body(container, raw))
        case .spawnRefused: self = .spawnRefused(try Self.body(container, raw))
        case .attach: self = .attach(try Self.body(container, raw))
        case .attached: self = .attached(try Self.body(container, raw))
        case .resize: self = .resize(try Self.body(container, raw))
        case .resized: self = .resized(try Self.body(container, raw))
        case .detach: self = .detach(try Self.body(container, raw))
        case .closeInput: self = .closeInput(try Self.body(container, raw))
        case .kill: self = .kill(try Self.body(container, raw))
        case .exited: self = .exited(try Self.body(container, raw))
        case .foreground: self = .foreground(try Self.body(container, raw))
        case .lost: self = .lost(try Self.body(container, raw))
        case .retire: self = .retire
        case .journalTail: self = .journalTail(try Self.body(container, raw))
        case .journal: self = .journal(try Self.body(container, raw))
        case .error: self = .error(try Self.body(container, raw))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value):
            try container.encode(FrameType.hello, forKey: .type)
            try container.encode(value, forKey: .body)
        case .helloRefused(let value):
            try container.encode(FrameType.helloRefused, forKey: .type)
            try container.encode(value, forKey: .body)
        case .list:
            try container.encode(FrameType.list, forKey: .type)
        case .sessions(let value):
            try container.encode(FrameType.sessions, forKey: .type)
            try container.encode(value, forKey: .body)
        case .spawn(let value):
            try container.encode(FrameType.spawn, forKey: .type)
            try container.encode(value, forKey: .body)
        case .spawned(let value):
            try container.encode(FrameType.spawned, forKey: .type)
            try container.encode(value, forKey: .body)
        case .spawnRefused(let value):
            try container.encode(FrameType.spawnRefused, forKey: .type)
            try container.encode(value, forKey: .body)
        case .attach(let value):
            try container.encode(FrameType.attach, forKey: .type)
            try container.encode(value, forKey: .body)
        case .attached(let value):
            try container.encode(FrameType.attached, forKey: .type)
            try container.encode(value, forKey: .body)
        case .resize(let value):
            try container.encode(FrameType.resize, forKey: .type)
            try container.encode(value, forKey: .body)
        case .resized(let value):
            try container.encode(FrameType.resized, forKey: .type)
            try container.encode(value, forKey: .body)
        case .detach(let value):
            try container.encode(FrameType.detach, forKey: .type)
            try container.encode(value, forKey: .body)
        case .closeInput(let value):
            try container.encode(FrameType.closeInput, forKey: .type)
            try container.encode(value, forKey: .body)
        case .kill(let value):
            try container.encode(FrameType.kill, forKey: .type)
            try container.encode(value, forKey: .body)
        case .exited(let value):
            try container.encode(FrameType.exited, forKey: .type)
            try container.encode(value, forKey: .body)
        case .foreground(let value):
            try container.encode(FrameType.foreground, forKey: .type)
            try container.encode(value, forKey: .body)
        case .lost(let value):
            try container.encode(FrameType.lost, forKey: .type)
            try container.encode(value, forKey: .body)
        case .retire:
            try container.encode(FrameType.retire, forKey: .type)
        case .journalTail(let value):
            try container.encode(FrameType.journalTail, forKey: .type)
            try container.encode(value, forKey: .body)
        case .journal(let value):
            try container.encode(FrameType.journal, forKey: .type)
            try container.encode(value, forKey: .body)
        case .error(let value):
            try container.encode(FrameType.error, forKey: .type)
            try container.encode(value, forKey: .body)
        }
    }

    /// A frame that carries fields and arrived without them is a refusal with a token, not a
    /// default-constructed body.
    private static func body<Value: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ type: String
    ) throws -> Value {
        guard container.contains(.body) else {
            throw PTYHostFrameRefusal.missingBody(type: type)
        }
        return try container.decode(Value.self, forKey: .body)
    }
}
