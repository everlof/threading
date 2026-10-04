#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import ThreadingPTYHostKit

// MARK: - The record

/// One lifecycle edge of one session, as `sessions.jsonl` holds it.
///
/// Three edges, and no state in between: `spawned` when the child exists, `exited` when it has
/// been reaped, `lost` when a *later* daemon could not account for it. Everything else about a
/// session is in memory, because everything else is only interesting while the daemon that owns
/// it is alive — with one exception: a `retain` session's ending is owed to an unattended owner
/// until it says it has recorded it, which is the fourth edge, `acknowledged`.
///
/// Per-record `version`, the shape the app's launch ledger already uses, so a later field is
/// additive and an older line stays readable.
struct PTYHostStateRecord: Codable, Equatable {

    enum Edge: String, Codable {
        case spawned
        case exited
        case lost
        /// The owner of a `retain` session recorded its ending; the receipt may be forgotten.
        /// An older daemon cannot read this edge and skips the line, which only means it keeps
        /// a receipt longer than it had to.
        case acknowledged
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
    /// Present, and true, on the `spawned` edge of a session whose ending must be kept until
    /// acknowledged (`PTYHostSpawnRequest.retainReceipt`). Absent everywhere else.
    let retain: Bool?
    /// Present on a `lost` edge: the recovery event that found it.
    let incidentID: UUID?

    init(
        edge: Edge,
        id: PTYHostSessionIdentity,
        pid: Int32,
        startTime: PTYHostProcessStartTime? = nil,
        executable: String? = nil,
        channel: PTYHostChannelKind? = nil,
        status: Int32? = nil,
        signalled: Bool? = nil,
        at: Date = Date(),
        retain: Bool = false,
        incidentID: UUID? = nil
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
        self.retain = retain ? true : nil
        self.incidentID = incidentID
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
    /// Its owner asked for its ending to be kept until acknowledged.
    var retain = false
}

/// What a restarted daemon reads back: the sessions nobody wrote an ending for, and the
/// retained endings nobody has acknowledged yet.
struct PTYHostRecoveredState {
    let unaccounted: [PTYHostUnaccountedSession]
    /// Oldest first, at most `PTYHostReceiptLimits.retained`.
    let receipts: [PTYHostReceipt]
    let skippedLines: Int
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
        return PTYHostPOSIX.writeAll(descriptor, line)
    }

    /// What the file says is still running, and how many lines could not be read.
    ///
    /// Read leniently: a line that does not parse is skipped and counted, never a reason to
    /// refuse the file. The file exists to be readable after a crash truncated a write, so
    /// refusing it whole would throw away every session before the damaged line — which is
    /// exactly the set the answer is about.
    func unaccountedSessions() -> (sessions: [PTYHostUnaccountedSession], skippedLines: Int) {
        let recovered = recover()
        return (recovered.unaccounted, recovered.skippedLines)
    }

    /// One pass over the ledger: what is unaccounted for, and which retained endings are still
    /// owed. A receipt is a `retain` session's latest incarnation whose last edge is an ending
    /// with no `acknowledged` after it.
    func recover() -> PTYHostRecoveredState {
        guard let data = try? Data(contentsOf: url) else {
            return PTYHostRecoveredState(unaccounted: [], receipts: [], skippedLines: 0)
        }

        var open: [PTYHostSessionIdentity: PTYHostUnaccountedSession] = [:]
        var retained: [PTYHostSessionIdentity: PTYHostStateRecord] = [:]
        var endings: [PTYHostSessionIdentity: PTYHostStateRecord] = [:]
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
                open[record.id] = PTYHostUnaccountedSession(
                    id: record.id,
                    pid: record.pid,
                    startTime: record.startTime,
                    channel: record.channel ?? .pty,
                    since: record.at,
                    retain: record.retain == true
                )
                endings.removeValue(forKey: record.id)
                if record.retain == true { retained[record.id] = record }
                else { retained.removeValue(forKey: record.id) }
            case .exited, .lost:
                open.removeValue(forKey: record.id)
                if retained[record.id] != nil { endings[record.id] = record }
            case .acknowledged:
                retained.removeValue(forKey: record.id)
                endings.removeValue(forKey: record.id)
            }
        }
        let receipts = endings.compactMap { id, ending -> PTYHostReceipt? in
            guard let spawned = retained[id] else { return nil }
            return PTYHostReceipt(
                id: id,
                pid: spawned.pid,
                startTime: spawned.startTime,
                ending: ending.edge == .lost ? .lost : .exited,
                status: ending.status,
                signalled: ending.signalled,
                incidentID: ending.incidentID,
                at: ending.at
            )
        }
        .sorted { $0.at < $1.at }
        .suffix(PTYHostReceiptLimits.retained)

        // A logical session may have several process incarnations in this append-only file.
        // Ordering every historical `.spawned` edge used to return the final open incarnation
        // once for every earlier incarnation of the same id. Recovery then reported and counted
        // one lost session several times. The dictionary is the truth; sort only its current
        // values so the answer is deterministic without retaining historical duplicates.
        let sessions = open.values.sorted { lhs, rhs in
            if lhs.since != rhs.since { return lhs.since < rhs.since }
            return lhs.id.description < rhs.id.description
        }
        return PTYHostRecoveredState(unaccounted: sessions, receipts: Array(receipts), skippedLines: skipped)
    }
}
