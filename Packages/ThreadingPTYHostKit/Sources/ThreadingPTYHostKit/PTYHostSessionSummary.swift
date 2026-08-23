import Foundation
import ThreadingDomain

/// The wire spelling of `TerminalInstanceIdentity`.
///
/// The domain type is the identity every frame carries — a daemon that minted its own session
/// numbers would be a second identity space to reconcile, which is the bug this wrapper exists
/// to avoid. What it is *not* is `Codable`: `TerminalInstanceIdentity` is an enum with associated
/// values in a package this one only reads, and conforming it from here would be a retroactive
/// conformance that a later `Codable` in `ThreadingDomain` would collide with, encoded in
/// whatever shape the compiler synthesised. So the shape is written out here instead — a
/// two-field object whose `kind` token is stable and whose `id` is the same UUID string the rest
/// of the app persists.
public struct PTYHostSessionIdentity: Codable, Hashable, Sendable, CustomStringConvertible {

    /// The domain value. Every consumer works with this; the wrapper exists only for the wire.
    public let identity: TerminalInstanceIdentity

    public init(_ identity: TerminalInstanceIdentity) {
        self.identity = identity
    }

    public static func agentSession(_ id: SessionID) -> PTYHostSessionIdentity {
        PTYHostSessionIdentity(.agentSession(id))
    }

    public var description: String { identity.historyFileStem }

    /// The `kind` token. Deliberately the case names, not an ordinal: a reordered enum must not
    /// silently rename a session's owner on the wire.
    ///
    /// Version 1 of the protocol hosts `agentSession` only — the other three need a `foreground`
    /// push frame the daemon cannot answer yet (D9) — but all four are spelled here so that
    /// hosting them later is a daemon change and not a protocol change.
    enum Kind: String, Codable {
        case agentSession
        case projectTerminal
        case sessionShell
        case ephemeral
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let raw = try container.decode(String.self, forKey: .id)
        guard let uuid = UUID(uuidString: raw) else {
            throw PTYHostFrameRefusal.malformedSessionIdentity(raw)
        }
        switch kind {
        case .agentSession: identity = .agentSession(SessionID(uuid))
        case .projectTerminal: identity = .projectTerminal(TerminalID(uuid))
        case .sessionShell: identity = .sessionShell(SessionID(uuid))
        case .ephemeral: identity = .ephemeral(uuid)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch identity {
        case .agentSession(let id):
            try container.encode(Kind.agentSession, forKey: .kind)
            try container.encode(id.uuidString, forKey: .id)
        case .projectTerminal(let id):
            try container.encode(Kind.projectTerminal, forKey: .kind)
            try container.encode(id.uuidString, forKey: .id)
        case .sessionShell(let id):
            try container.encode(Kind.sessionShell, forKey: .kind)
            try container.encode(id.uuidString, forKey: .id)
        case .ephemeral(let id):
            try container.encode(Kind.ephemeral, forKey: .kind)
            try container.encode(id.uuidString, forKey: .id)
        }
    }
}

/// A terminal's window size, all four fields of `winsize`.
///
/// The pixel pair travels with the cell pair because `getWindowSize()` produces both and a
/// program that asks for pixel dimensions gets zeroes if they are dropped in transit. It is one
/// value rather than four loose integers so a `spawn`, an `attach` answer and a `resize` cannot
/// disagree about what a grid is.
public struct PTYHostGrid: Codable, Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public let xpixel: Int
    public let ypixel: Int

    public init(cols: Int, rows: Int, xpixel: Int = 0, ypixel: Int = 0) {
        self.cols = cols
        self.rows = rows
        self.xpixel = xpixel
        self.ypixel = ypixel
    }
}

/// When the kernel started a process, to the microsecond.
///
/// A pid on its own does not identify a process: macOS hands the numbers out again, so anything
/// that acts on a recorded pid — the daemon's own restart probe above all — would otherwise
/// signal whatever now holds that number. Seconds alone are not enough either; two processes
/// started in the same second are ordinary at launch.
///
/// This is a copy of the application's `ProcessStartTime` (`Core/Session/ProcessUtility.swift`)
/// rather than the type itself: that type lives in the app module, not in a package, and the
/// daemon must not link the app. The app maps between the two at the client boundary, and the
/// field names are identical so the JSON is the same on both sides.
public struct PTYHostProcessStartTime: Codable, Equatable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

/// One session the daemon holds, as the `sessions` frame reports it.
///
/// Enough to render the Background Sessions list and to decide what a launching app still has to
/// relaunch — and nothing more. There is no title, no project, no activity and no working
/// directory here on purpose: the daemon parses nothing, so it does not know them, and the app
/// already does.
public struct PTYHostSessionSummary: Codable, Equatable, Sendable {
    public let id: PTYHostSessionIdentity
    public let pid: Int32
    /// When the daemon spawned it. Paired with `pid` this is also the identity probe.
    public let startedAt: Date
    /// The executable as the app named it in `spawn`, unchanged. The daemon interprets nothing.
    public let executable: String
    /// The session's window size, or zeroes for a `.pipes` session, which has no terminal.
    public let grid: PTYHostGrid
    public let isAttached: Bool
    /// Set once the child has exited and the status is being held for a late observer; nil while
    /// it is still running.
    public let exit: Int32?

    /// How the child is wired up. **Absent means `.pty`**, and absent is how every summary
    /// written before pipes existed reads.
    ///
    /// Optional rather than a defaulted `.pty` for `AgentChildRecord.owner`'s reason: the
    /// migration property has to belong to the type rather than to a build, so a peer that
    /// predates the field decodes without it and a peer that has it never has to guess. Read
    /// through `resolvedChannel`; nothing decides anything on the raw optional.
    ///
    /// It is here rather than inferred by the app because the app *cannot* infer it. A launch
    /// that finds the daemon holding a session has to decide whether to take the terminal back
    /// or to end the child and resume the conversation from its transcript, and that answer
    /// turns entirely on which transport the child is speaking.
    public let channel: PTYHostChannelKind?

    /// The channel a caller acts on. Absent is `.pty` — see `channel`.
    public var resolvedChannel: PTYHostChannelKind { channel ?? .pty }

    public init(
        id: PTYHostSessionIdentity,
        pid: Int32,
        startedAt: Date,
        executable: String,
        grid: PTYHostGrid,
        isAttached: Bool,
        exit: Int32? = nil,
        channel: PTYHostChannelKind? = nil
    ) {
        self.id = id
        self.pid = pid
        self.startedAt = startedAt
        self.executable = executable
        self.grid = grid
        self.isAttached = isAttached
        self.exit = exit
        self.channel = channel
    }
}

/// Which of `PTYHostChannel`'s two shapes a session has, with none of its payload.
///
/// A separate token from `PTYHostChannel` on purpose: that type carries the grid a `spawn`
/// states, and a summary reporting a channel is answering "what is this" rather than restating
/// a launch. It is also what the daemon's `sessions.jsonl` records, where a grid would be a
/// second copy of durable state the file does not own.
public enum PTYHostChannelKind: String, Codable, Equatable, Sendable {
    case pty
    case pipes
}
