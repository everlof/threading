import Darwin
import Foundation

// MARK: - Agent Child Record

/// One native agent CLI this launch started, named well enough to be recognised after a crash.
///
/// Lifecycle facts only. A prompt, a model, an account token or a working directory would all
/// make this file a place a support report must not include, and none of them helps decide
/// whether the process on the other end of the pid is still ours.
struct AgentChildRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let startTime: ProcessStartTime
    /// The Threading session the child belongs to, so a journal line points at a row.
    let sessionID: String
    /// The launched file's last path component — `claude`, `codex`, `grok`. Enough to say what
    /// was killed without recording where it was installed.
    let executable: String
    let recordedAt: Date
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
/// PTY sessions are deliberately absent. SwiftTerm launches through `forkpty`, so that child
/// already leads its own session with a controlling terminal and dies of `SIGHUP` when the
/// master descriptor closes with the app. It needs no ledger because the kernel already owns
/// the ending.
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

    /// Records a child that has just been spawned. Returns whether the record reached disk — a
    /// caller cannot do anything about a refusal, but a test can assert one.
    @discardableResult
    func record(_ record: AgentChildRecord) -> Bool {
        queue.sync {
            records.removeAll { $0.pid == record.pid }
            records.append(record)

            // A named budget rather than an unbounded file. Reaching it means children are
            // being spawned and never reaped, which is a bug this file must report rather than
            // grow through; the oldest entry goes first because it is the likeliest to be stale.
            while records.count > AgentChildLedgerDefaults.maximumRecords {
                let evicted = records.removeFirst()
                ThreadingLogger.agent.error(
                    """
                    Live-children ledger is full at \
                    \(AgentChildLedgerDefaults.maximumRecords, privacy: .public) records; \
                    pid \(evicted.pid, privacy: .public) will not be swept.
                    """
                )
            }

            return store.save(records)
        }
    }

    /// Forgets a child that has been reaped. Its pid is the kernel's to hand out again from
    /// this moment, so the record must not outlive the reap by any amount.
    func clear(pid: pid_t) {
        queue.sync {
            let remaining = records.filter { $0.pid != pid }
            guard remaining.count != records.count else { return }
            records = remaining
            store.save(records)
        }
    }

    /// What this launch believes is live. A test seam; the sweep reads the file instead,
    /// because it is asking about a launch that is over.
    var currentRecords: [AgentChildRecord] {
        queue.sync { records }
    }
}

// MARK: - Agent Child Ledger Defaults

enum AgentChildLedgerDefaults {
    static let fileName = "agent-children.json"
    static let queueLabel = "codes.threading.agent-child-ledger"

    /// One record per live native conversation. Far above any plausible number of agents a
    /// person runs side by side, and low enough that a leak shows up as a full file rather than
    /// as a directory nobody looks at.
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
