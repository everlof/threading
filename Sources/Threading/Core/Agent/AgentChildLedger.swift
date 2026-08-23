import Darwin
import Foundation

// MARK: - Agent Child Owner

/// Which process is responsible for ending a recorded child.
///
/// The ledger's whole point is that somebody must end an unowned child, and until now that was
/// always this app. A child spawned by the PTY host (`threading-ptyd`) is recorded so a launch
/// can *see* it — in a list of holders, in a diagnostic — but the host owns its ending, and a
/// second process signalling it is exactly the double-ownership this file exists to avoid.
enum AgentChildOwner: String, Codable, Sendable {
    case app
    case ptyHost
}

// MARK: - Agent Child Record

/// One process-group leader this launch started, named well enough to be recognised after a
/// crash.
///
/// Lifecycle facts only. A prompt, a model, an account token or a working directory would all
/// make this file a place a support report must not include, and none of them helps decide
/// whether the process on the other end of the pid is still ours.
struct AgentChildRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    /// The Threading session the child belongs to, when it is a conversation. Long-lived
    /// infrastructure children such as the Tailscale Serve handler have no session rather than
    /// inventing an id that looks like a row. Optional also makes older records
    /// forward-compatible with new child categories while preserving the original on-disk field.
    let sessionID: String?
    /// The launched file's last path component: `claude`, `codex`, `grok`, `tailscale`.
    /// Enough to say what was killed without recording where it was installed.
    let executable: String
    let recordedAt: Date
    /// Who may end this child. **Absent means `.app`**, and absent is how every app-owned
    /// record is written.
    ///
    /// Optional rather than a defaulted `.app`, because the migration property has to be a
    /// property of the *type* rather than of a build: a nil encodes to no key at all, so a
    /// record this build writes for its own child is byte-identical to one written before the
    /// field existed, and the file on disk right now needs no migration to keep meaning what it
    /// meant. Writing `"owner":"app"` into every record would rewrite the whole ledger on the
    /// first save of a build nobody has opted into anything with, and would leave two on-disk
    /// spellings of one fact for the sweep to agree about.
    ///
    /// Read through `resolvedOwner`; nothing decides anything on the raw optional.
    var owner: AgentChildOwner?

    /// The owner the sweep acts on. Absent is `.app` — see `owner`.
    var resolvedOwner: AgentChildOwner { owner ?? .app }
}

// MARK: - Agent Child Ledger

/// What is running right now, on disk, so the *next* launch can clean up after a crash.
///
/// A native conversation's CLI is an ordinary child with pipes. When Threading is killed rather
/// than quit, `AgentRuntime.terminateAll()` never runs, the child reparents to launchd, and it
/// is then alive, unowned and unreaped with nothing anywhere recording that it exists. This file
/// is that record: written the moment a child is spawned, cleared the moment it is reaped.
///
/// What survives a launch is therefore whatever had not been reaped when it ended. After a clean
/// quit that is at most the children whose exit the app outran — all of them gone by the time
/// anyone looks, which is why the sweep verifies rather than assumes. After a crash it is the
/// orphans themselves. `OrphanedAgentChildSweep` cannot tell the two apart from the file alone,
/// and must not try.
///
/// PTY sessions the *app* launches are deliberately absent. SwiftTerm launches through
/// `forkpty`, so that child already leads its own session with a controlling terminal and dies
/// of `SIGHUP` when the master descriptor closes with the app. It needs no ledger because the
/// kernel already owns the ending.
///
/// That reasoning ends where the master descriptor stops closing with the app. A PTY held open
/// by the host outlives this process on purpose, so the kernel owns nothing here and the child
/// *is* recorded — with `owner == .ptyHost`, which `OrphanedAgentChildSweep.verdict` reads as
/// "visible, never signalled". Recording it is what lets a launch name what is still running;
/// the owner field is what stops the same launch killing it.
///
/// Writes are **synchronous**, for `EventLog`'s reason: the record that matters most is always
/// the one written immediately before the process died, and an asynchronous hand-off is exactly
/// what loses it. A record is a few hundred bytes and is written once per conversation start and
/// once per exit, not per turn.
///
/// `@unchecked Sendable`: `records` and `store` are touched only inside `queue`, a serial queue,
/// and every entry point below hops onto it. It cannot be an actor because the reap that clears
/// a record runs on a `DispatchSourceProcess` handler that must not be made asynchronous — see
/// `SpawnedChildProcess`.
final class AgentChildLedger: @unchecked Sendable {

    // MARK: - Singleton

    /// Redirected under a hosted test bundle for the reason `PreferenceStore` documents: the
    /// tests run inside the shipping app, and a test that spawns a child must not append to the
    /// ledger the developer's own next launch will sweep from.
    static let shared = AgentChildLedger(url: AgentChildLedgerDefaults.defaultURL)

    // MARK: - Properties

    private let queue = DispatchQueue(label: AgentChildLedgerDefaults.queueLabel)
    private let store: RecoverableFileStore<[AgentChildRecord]>
    private var records: [AgentChildRecord] = []

    // MARK: - Initialization

    init(url: URL, fileManager: FileManager = .default) {
        // `.rebuildableCache`: this file describes processes that exist right now, so a copy
        // nobody could read describes nothing recoverable — there is no user data in it to
        // preserve. What it must never do is read as *empty*, which is why the sweep asks for
        // the outcome rather than the value.
        store = RecoverableFileStore(
            url: url,
            fileManager: fileManager,
            criticality: .rebuildableCache,
            sizePolicy: .compactMetadata,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
    }

    // MARK: - Public Methods

    /// Reads what the previous launch left behind and empties the ledger.
    ///
    /// Consumed on read, the same discipline as `EventLog`'s launch marker: a list that outlived
    /// the launch which acted on it would have this launch's own children swept by the next one.
    /// Every other entry point below assumes this ran first, which `AppDelegate` guarantees by
    /// sweeping before anything can start a conversation.
    func consumeInheritedRecords() -> RecoverableStoreLoadOutcome<[AgentChildRecord]> {
        queue.sync {
            let outcome = store.load(defaultValue: [])
            records = []
            store.save([])
            return outcome
        }
    }

    /// The same list, read without consuming it.
    ///
    /// One caller, and it is the one that cannot use the consuming read: a launch refused the
    /// single-instance lock has not reached `OrphanedAgentChildSweep` — that runs *after* the
    /// lock is taken, which is exactly the deadlock when the previous launch's orphans are the
    /// ones holding it. Emptying the ledger from a process that is about to quit would rob the
    /// launch that does get in of the only record of what is still running.
    func inheritedRecords() -> RecoverableStoreLoadOutcome<[AgentChildRecord]> {
        queue.sync { store.load(defaultValue: []) }
    }

    /// Records a child that has just been spawned. Returns whether the record reached disk — a
    /// caller cannot do anything about a refusal, but a test can assert one.
    @discardableResult
    func record(_ record: AgentChildRecord) -> Bool {
        queue.sync {
            var updated = records.filter { $0.pid != record.pid }
            updated.append(record)

            // A named budget rather than an unbounded file. Reaching it means children are
            // being spawned and never reaped, which is a bug this file must report rather than
            // grow through; the oldest entry goes first because it is the likeliest to be stale.
            var evicted: [AgentChildRecord] = []
            while updated.count > AgentChildLedgerDefaults.maximumRecords {
                evicted.append(updated.removeFirst())
            }

            // Memory changes only after disk does. If the write fails, reporting success in
            // memory would let `AgentChildProcess` run an untracked child and a later save could
            // accidentally make that stale record durable after the process had already gone.
            guard store.save(updated) else { return false }
            records = updated

            for record in evicted {
                ThreadingLogger.agent.error(
                    """
                    Live-children ledger is full at \
                    \(AgentChildLedgerDefaults.maximumRecords, privacy: .public) records; \
                    pid \(record.pid, privacy: .public) will not be swept.
                    """
                )
            }
            return true
        }
    }

    /// Builds and durably records the identity of a child immediately after spawn.
    ///
    /// This is shared by native conversations and non-PTY infrastructure children. Keeping the
    /// start-time read here prevents a new launch path from recording a pid without the second
    /// half of the identity the next-launch sweep requires.
    func recordSpawnedChild(
        _ child: SpawnedChildProcess,
        sessionID: String?,
        executable: String
    ) -> LiveChildEnrollmentResult {
        guard let startTime = ProcessUtility.startTime(forPid: child.processIdentifier) else {
            return .identityUnavailable
        }
        let record = AgentChildRecord(
            pid: child.processIdentifier,
            startTime: startTime,
            sessionID: sessionID,
            executable: URL(fileURLWithPath: executable).lastPathComponent,
            recordedAt: Date()
        )
        return self.record(record) ? .recorded : .persistenceRefused
    }

    /// Forgets a child that has been reaped. Its pid is the kernel's to hand out again from
    /// this moment, so the record must not outlive the reap by any amount.
    func clear(pid: pid_t) {
        queue.sync {
            let remaining = records.filter { $0.pid != pid }
            guard remaining.count != records.count else { return }
            guard store.save(remaining) else { return }
            records = remaining
        }
    }

    /// What this launch believes is live. A test seam; the sweep reads the file instead,
    /// because it is asking about a launch that is over.
    var currentRecords: [AgentChildRecord] {
        queue.sync { records }
    }
}

enum LiveChildEnrollmentResult: Equatable, Sendable {
    case recorded
    case identityUnavailable
    case persistenceRefused
}

// MARK: - Agent Child Ledger Defaults

enum AgentChildLedgerDefaults {
    static let fileName = "agent-children.json"
    static let queueLabel = "codes.threading.agent-child-ledger"

    /// One record per live native conversation or infrastructure child. Far above any plausible
    /// live set, and low enough that a leak shows up as a full file rather than as a directory
    /// nobody looks at.
    static let maximumRecords = 64

    /// The scratch name a hosted test bundle writes under, so a test run never leaves entries
    /// the developer's next launch would act on.
    static let hostedTestDirectoryName = "AgentChildLedgerHostedTests"

    static var defaultURL: URL {
        let directory = AppDataLocations.supportDirectory
        guard NSClassFromString("XCTestCase") != nil else {
            return directory.appendingPathComponent(fileName)
        }
        return directory
            .appendingPathComponent(hostedTestDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
