import Darwin
import Foundation
import ThreadingPTYHostKit

// MARK: - The record

/// One lifecycle edge of one session, as `sessions.jsonl` holds it.
///
/// Three edges, and no state in between: `spawned` when the child exists, `exited` when it has
/// been reaped, `lost` when a *later* daemon could not account for it. Everything else about a
/// session is in memory, because everything else is only interesting while the daemon that owns
/// it is alive.
///
/// Per-record `version`, the shape the app's launch ledger already uses, so a later field is
/// additive and an older line stays readable.
struct PTYHostStateRecord: Codable, Equatable {

    enum Edge: String, Codable {
        case spawned
        case exited
        case lost
    }

    let version: Int
    let edge: Edge
    let id: PTYHostSessionIdentity
    let pid: Int32
    /// Present on `spawned`. The other half of the pid's identity, and the only thing that makes
    /// the restart probe safe: macOS hands pid numbers out again.
    let startTime: PTYHostProcessStartTime?
    /// Present on `spawned`, as the app named it. Nothing here interprets it.
    let executable: String?
    /// Present on `spawned`. **Absent means `.pty`**, so every line written before pipes existed
    /// reads as what it was — the same migration discipline `AgentChildRecord.owner` states, and
    /// for the same reason: the property belongs to the record's shape rather than to a build.
    ///
    /// A restart uses it for one thing, and it is not a decision: the `lost` report and the
    /// journal line say which kind of session could not be accounted for, which is the difference
    /// between "an agent's terminal ended" and "a conversation's turn ended" for whoever reads it
    /// afterwards. The reclaim itself is the same either way — pid, start time, kill the group.
    let channel: PTYHostChannelKind?
    let status: Int32?
    let signalled: Bool?
    let at: Date

    init(
        edge: Edge,
        id: PTYHostSessionIdentity,
        pid: Int32,
        startTime: PTYHostProcessStartTime? = nil,
        executable: String? = nil,
        channel: PTYHostChannelKind? = nil,
        status: Int32? = nil,
        signalled: Bool? = nil,
        at: Date = Date()
    ) {
        self.version = PTYHostDefaults.stateRecordVersion
        self.edge = edge
        self.id = id
        self.pid = pid
        self.startTime = startTime
        self.executable = executable
        self.channel = channel
        self.status = status
        self.signalled = signalled
        self.at = at
    }
}

// MARK: - What a restart could not account for

/// A session the previous daemon spawned and never recorded an ending for.
struct PTYHostUnaccountedSession: Equatable {
    let id: PTYHostSessionIdentity
    let pid: Int32
    let startTime: PTYHostProcessStartTime?
    /// What it was wired up as, for the journal line that says what was lost. Absent is `.pty`.
    let channel: PTYHostChannelKind
    /// The last moment the previous daemon can be said to have vouched for it: the timestamp on
    /// its own `spawned` line.
    let since: Date
}

// MARK: - The store

/// The append-only session ledger, and the whole of what a restarted daemon knows about the one
/// before it.
///
/// **Appended synchronously at each edge**, for the reason the app's journal states about itself:
/// the record that matters most is always the one written immediately before the process died.
/// A `KeepAlive` restart's entire ability to say *what was lost* rests on the `spawned` line
/// having reached the disk before the fork was reported to anybody.
///
/// Confined to the host queue.
final class PTYHostState: @unchecked Sendable {

    // MARK: - Properties

    private let url: URL
    private var descriptor: Int32 = -1

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    init(directory: URL) {
        url = directory.appendingPathComponent(PTYHostDefaults.stateFileName)
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    // MARK: - Public Methods

    /// Appends one record, or answers false having failed. `O_APPEND` so the write is atomic
    /// against anything else that ever opens the file, `O_CLOEXEC` so no agent CLI inherits it.
    @discardableResult
    func append(_ record: PTYHostStateRecord) -> Bool {
        guard let data = try? Self.encoder.encode(record) else { return false }
        if descriptor < 0 {
            descriptor = open(
                url.path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                PTYHostDefaults.filePermissions
            )
        }
        guard descriptor >= 0 else { return false }

        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// What the file says is still running, and how many lines could not be read.
    ///
    /// Read leniently: a line that does not parse is skipped and counted, never a reason to
    /// refuse the file. The file exists to be readable after a crash truncated a write, so
    /// refusing it whole would throw away every session before the damaged line — which is
    /// exactly the set the answer is about.
    func unaccountedSessions() -> (sessions: [PTYHostUnaccountedSession], skippedLines: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }

        var open: [PTYHostSessionIdentity: PTYHostUnaccountedSession] = [:]
        var order: [PTYHostSessionIdentity] = []
        var skipped = 0

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? Self.decoder.decode(
                PTYHostStateRecord.self,
                from: Data(line)
            ) else {
                skipped += 1
                continue
            }
            switch record.edge {
            case .spawned:
                if open[record.id] == nil { order.append(record.id) }
                open[record.id] = PTYHostUnaccountedSession(
                    id: record.id,
                    pid: record.pid,
                    startTime: record.startTime,
                    channel: record.channel ?? .pty,
                    since: record.at
                )
            case .exited, .lost:
                open.removeValue(forKey: record.id)
            }
        }

        return (order.compactMap { open[$0] }, skipped)
    }
}
