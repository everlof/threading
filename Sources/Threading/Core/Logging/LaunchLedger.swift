import Foundation

// MARK: - Launch Mode

/// Which way a launch was asked to come up. `recovery` is written by Phase 2 and read by the
/// policy today, so the "recovery itself died" branch is complete and testable before the mode
/// that produces it exists.
enum LaunchMode: String, Sendable {
    case normal
    case recovery
}

// MARK: - Launch Ledger Writer

/// Which process authored a record.
///
/// The ledger is app-owned now and supervisor-owned later, and the two overlap in one file: a
/// supervisor's records land beneath records this build wrote. Saying so per record is what makes
/// the handoff auditable afterwards instead of guessable.
enum LaunchLedgerWriter: String, Sendable {
    case app
    case supervisor
}

// MARK: - Launch Disposition

/// How a launch ended, as the ledger records it.
///
/// `unclean` is the only one that counts toward a crash loop. The other three are all "the
/// process left on purpose", told apart because a support report reads very differently when the
/// restart was the user pressing Reset than when it was the app dying.
enum LaunchDisposition: Equatable, Sendable {

    /// The quit path ran — Cmd+Q, closing the window, a logout, Sparkle's quit event.
    case clean

    /// The process left without the quit path, deliberately. See `AppRelaunch`.
    case intentional(IntentionalExitReason)

    /// No ending was written and none could be inferred except from the absence itself.
    case unclean

    /// An `end` record whose disposition token this build does not know. It still means the
    /// process wrote something down on its way out, so it is not counted as a crash.
    case endedForUnknownReason

    // MARK: - Tokens

    var token: String {
        switch self {
        case .clean: return LaunchLedgerDefaults.dispositionClean
        case .intentional(let reason):
            return "\(LaunchLedgerDefaults.dispositionIntentionalPrefix)\(reason.rawValue)"
        case .unclean: return LaunchLedgerDefaults.dispositionUnclean
        case .endedForUnknownReason: return LaunchLedgerDefaults.dispositionUnknown
        }
    }

    init(token: String) {
        if token == LaunchLedgerDefaults.dispositionClean {
            self = .clean
        } else if token == LaunchLedgerDefaults.dispositionUnclean {
            self = .unclean
        } else if token.hasPrefix(LaunchLedgerDefaults.dispositionIntentionalPrefix),
                  let reason = IntentionalExitReason(
                      rawValue: String(
                          token.dropFirst(
                              LaunchLedgerDefaults.dispositionIntentionalPrefix.count
                          )
                      )
                  ) {
            self = .intentional(reason)
        } else {
            self = .endedForUnknownReason
        }
    }
}

// MARK: - Build Fingerprint

/// What "the same build" means to the policy.
///
/// The version pair alone is not enough while the app is being worked on: a Debug build's
/// `CFBundleShortVersionString` is `0.0.0` and its `CFBundleVersion` never moves, so every
/// rebuild would share one identity and a crash fixed twenty minutes ago would still be counted
/// against the build that fixed it. The executable's modification time is what actually changes
/// per build, and it costs one `stat`.
struct BuildFingerprint: Equatable, Sendable {

    /// The human version pair, as `EventLog` spells it.
    let build: String

    /// What the policy compares. Never shown to anyone.
    let token: String

    init(build: String, token: String) {
        self.build = build
        self.token = token
    }

    static var current: BuildFingerprint {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
            ?? LaunchLedgerDefaults.unknownVersion
        let number = info?["CFBundleVersion"] as? String ?? LaunchLedgerDefaults.unknownVersion
        let build = "\(short) (\(number))"
        return BuildFingerprint(build: build, token: "\(build)+\(executableStamp())")
    }

    private static func executableStamp() -> String {
        guard let executable = Bundle.main.executableURL,
              let modified = try? executable.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate
        else { return LaunchLedgerDefaults.unknownVersion }
        return String(Int(modified.timeIntervalSince1970))
    }
}

// MARK: - Launch Ledger Record

/// One line of the ledger.
///
/// `version` is per **record**, not per file, because the writer handoff is incremental: a Phase 3
/// supervisor appends its own records into a file still holding this build's, and a record a
/// build cannot read must be skippable without the rest of the file becoming unreadable.
///
/// The enum-valued fields are stored as their raw strings and read back through typed accessors.
/// That is the leniency the format needs and the type system cannot express: a build that meets a
/// checkpoint name it has never heard of has met a record it does not understand, not a corrupt
/// file, and `JSONDecoder` cannot tell those apart for a `RawRepresentable`.
struct LaunchLedgerRecord: Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        case begin
        case checkpoint
        case end
        /// Written by the *successor* for a launch that never wrote an `end` of its own. The
        /// dying process is the one that cannot write this record, which is why someone else has
        /// to.
        case outcome
    }

    let version: Int
    let kind: Kind
    let launch: String
    /// Local time with its offset, matching how macOS stamps crash reports.
    let at: String
    /// Seconds since boot. Advances across sleep, which is what "five minutes of the user's
    /// time" has to mean, and is immune to the clock being set.
    let uptime: Double
    /// Identifies the boot session, so two uptimes are only ever compared within one.
    let boot: String

    // `begin` only.
    let build: String?
    let fingerprint: String?
    let mode: String?
    let writer: String?
    let pid: Int32?

    // `checkpoint` only.
    let checkpoint: String?
    let detail: [String: String]?

    // `end` and `outcome` only.
    let disposition: String?
    let systemInitiated: Bool?
}

// MARK: - Launch Ledger Launch

/// One launch, assembled from every record naming it.
struct LaunchLedgerLaunch: Equatable, Sendable {

    let id: String
    let startedAt: Date?
    let uptime: Double
    let bootID: String
    let fingerprint: String
    let mode: LaunchMode
    var checkpoints: [StartupCheckpoint] = []
    var ending: LaunchEnding?

    /// Whether the launch got far enough to be usable. See `StartupCheckpoint.isReadiness`.
    var reachedReadiness: Bool { checkpoints.contains { $0.isReadiness } }

    /// Whether ten interactive minutes elapsed under this launch, which is what clears a count.
    var reachedStability: Bool { checkpoints.contains(.stable) }

    var lastCheckpoint: StartupCheckpoint? { checkpoints.last }

    /// **A `begin` with neither an `end` nor an `outcome` is an unexpected exit.** Ordinarily the
    /// next launch tombstones it, so this is belt and braces — but a successor that itself died
    /// before reaching `beginLaunch` writes no tombstone at all, and a crash a missing record
    /// could hide is exactly the crash worth catching.
    var endedUnexpectedly: Bool {
        guard let ending else { return true }
        return ending.disposition == .unclean
    }
}

struct LaunchEnding: Equatable, Sendable {
    let disposition: LaunchDisposition
    /// Whether the system, rather than the user, started the quit. Only an `end` written by the
    /// quitting process can know this; a tombstone leaves it absent.
    let systemInitiated: Bool
}

// MARK: - Launch Ledger History

struct LaunchLedgerHistory: Equatable, Sendable {

    /// In file order, oldest first.
    var launches: [LaunchLedgerLaunch] = []

    /// The raw records, kept so compaction can rewrite the file without re-encoding anything it
    /// only half understands.
    var records: [LaunchLedgerRecord] = []

    /// The last line was cut off mid-write. That is what dying between two writes looks like, so
    /// it is dropped rather than treated as damage.
    var droppedTrailingPartial = false

    /// Records naming a launch with no `begin` — what Reset Everything leaves when the directory
    /// is moved aside under a running app. Counted, never fatal.
    var unattachedRecordCount = 0
}

// MARK: - Launch Ledger Read

/// Missing, valid, unsupported-version and corrupt are four different answers.
///
/// The third is not a kind of damage: a record from a *later* Threading is one this build cannot
/// read, and quarantining it would mean a downgrade confiscated the newer build's history. It is
/// left exactly as found and counted. See `docs/architecture/reliability-and-type-safety.md`.
enum LaunchLedgerRead: Equatable, Sendable {
    case missing
    case valid(LaunchLedgerHistory)
    case unsupportedVersion(newestFormatSeen: Int)
    case corrupt(quarantinedAt: URL?)

    var history: LaunchLedgerHistory? {
        guard case .valid(let history) = self else { return nil }
        return history
    }

    /// Machine-stable, for the journal and the support report — counts and enum tokens, never a
    /// path. The quarantine's location is a user path and stays in the log, where the person who
    /// owns the machine is the one reading.
    var token: String {
        switch self {
        case .missing:
            return LaunchLedgerDefaults.readMissingToken
        case .valid(let history):
            return "\(LaunchLedgerDefaults.readValidToken) launches=\(history.launches.count)"
        case .unsupportedVersion(let newest):
            return "\(LaunchLedgerDefaults.readUnsupportedToken) newest=\(newest)"
        case .corrupt(let quarantinedAt):
            let kept = quarantinedAt == nil ? "no" : "yes"
            return "\(LaunchLedgerDefaults.readCorruptToken) quarantined=\(kept)"
        }
    }
}

// MARK: - Launch Ledger Opening

/// The receipt for step one of opening a launch, and the only way to reach step two.
///
/// `bootID` and `isValid` are `fileprivate` on purpose: a value with them set can be made only
/// inside this file, so `beginLaunch` cannot be reached by a caller who has not first read,
/// tombstoned and compacted. The `read` is public because it is the whole point — it is what the
/// crash-loop policy decides the launch's mode from, before the mode is written down.
struct LaunchLedgerOpening: Sendable {

    /// The history as the tombstones just written left it.
    let read: LaunchLedgerRead

    fileprivate let bootID: String

    /// False for an opening this ledger refused to hand out — a second open in one process.
    fileprivate let isValid: Bool
}

// MARK: - Launch Ledger

/// Every launch attempt, how far it got, and how it ended — on disk, so the *next* launch can
/// tell a bad afternoon from a crash loop.
///
/// **Append-only JSONL over `O_APPEND`, not an atomic whole-file store.** `AgentChildLedger` takes
/// the other shape and is right to: it describes what is running *now*, so rewriting the whole
/// value each time costs one small file. This file describes what happened, it grows through a
/// launch, and it has to survive the process dying between two of its own writes. A whole-file
/// store also cannot survive a second writer, which is both what a hosted test bundle already is
/// and what Phase 3 deliberately introduces. `O_APPEND` puts the seek in the kernel where it is
/// atomic with the write — the fix `docs/architecture/persistence.md` records for the journal,
/// for the same reason.
///
/// It lives in its own directory rather than beside the journal because `EventLog` prunes *any*
/// `.jsonl` in its directory past the retention window, and a quarantined copy that a neighbour
/// deletes is not a quarantine.
///
/// Writes are synchronous and unbuffered, `EventLog`'s reason exactly: the record that matters
/// most is always the one written immediately before the process died.
///
/// `@unchecked Sendable`: every mutable property is touched only inside `queue`, a serial queue,
/// and every entry point below hops onto it.
final class LaunchLedger: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = LaunchLedger(url: LaunchLedgerDefaults.defaultURL)

    // MARK: - Properties

    let url: URL

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: LaunchLedgerDefaults.queueLabel)

    /// The launch this process owns, or `nil` while it has not begun one.
    ///
    /// The gate, and deliberately the same gate `EventLog` already uses for its marker: a hosted
    /// test bundle returns out of `applicationDidFinishLaunching` before the lock, and an
    /// instance that lost the single-instance lock terminates above it, so neither ever begins a
    /// launch — and every checkpoint either of them might still reach is dropped here rather than
    /// guarded at each call site.
    private var openLaunch: OpenLaunch?

    /// Whether this process has already read, tombstoned and compacted. Separate from
    /// `openLaunch` because the two now happen at different moments: the mode this launch runs in
    /// is decided from what the first step returns, and only then can the second step write a
    /// `begin` that says which mode that was.
    private var hasOpened = false

    /// False once a read found damage it could not move aside. A store that cannot preserve what
    /// it is about to write over has one safe move, and it is to stop.
    private var writesAllowed = true

    private var handle: FileHandle?
    private var stabilityTimer: DispatchSourceTimer?

    private struct OpenLaunch {
        let id: String
        let bootID: String
        var hasEnded = false
    }

    // MARK: - Initialization

    init(url: URL = LaunchLedgerDefaults.defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    // MARK: - Public Methods

    /// Step one: reads what is there, tombstones whatever never came back, and compacts.
    ///
    /// Returns the history *as amended by the tombstones it just wrote*, so what the policy
    /// decides on and what is on disk cannot disagree.
    ///
    /// **Split from writing the `begin`, because the `begin` carries the mode and the mode is
    /// decided from what this returns.** One call could not do both without either deciding the
    /// mode before the history was read or writing the record before the mode was known. The two
    /// are joined by a token this file alone can construct, so a `begin` cannot be appended by
    /// anyone who has not first come through here — the ordering is unforgeable rather than a
    /// convention.
    ///
    /// Called at most once per process, for the reason it always was: a second call would
    /// tombstone the launch this very process is running.
    func openLaunch(
        previousOutcome: EventLog.PreviousLaunchOutcome
    ) -> LaunchLedgerOpening {
        queue.sync {
            guard !hasOpened else {
                // Refused, and said out loud. A second open writes nothing either way, so the
                // only trace a sequencing regression would otherwise leave is the *absence* of a
                // record — which is exactly what nobody notices during a live diagnosis.
                ThreadingLogger.session.error(
                    """
                    Refusing a second launch-ledger open: this process has already read, \
                    tombstoned and compacted, and opening again would tombstone its own launch.
                    """
                )
                return LaunchLedgerOpening(read: .missing, bootID: "", isValid: false)
            }
            hasOpened = true

            let bootID = Self.bootIdentifier()
            var read = readLedger()

            if case .valid(var history) = read {
                let tombstones = tombstones(
                    for: history,
                    previousOutcome: previousOutcome,
                    bootID: bootID
                )
                apply(tombstones, to: &history)
                compactIfNeeded(history)
                for record in tombstones { append(record) }
                read = .valid(history)
            }

            return LaunchLedgerOpening(read: read, bootID: bootID, isValid: true)
        }
    }

    /// Step two: writes this launch's first record, in the mode the caller chose.
    ///
    /// A no-op for an opening this ledger did not hand out, and for a second call — a launch
    /// begins once, and a second `begin` would leave the reader choosing.
    func beginLaunch(
        _ opening: LaunchLedgerOpening,
        id: String?,
        mode: LaunchMode = .normal,
        fingerprint: BuildFingerprint = .current
    ) {
        queue.sync {
            // `hasOpened` as well as the token: the token says *an* opening happened, and this
            // says it happened here. One shared ledger makes the difference academic today and
            // exact tomorrow, when a supervisor holds a second one over the same file.
            guard opening.isValid, hasOpened, openLaunch == nil else {
                ThreadingLogger.session.error(
                    """
                    Refusing a launch-ledger begin: opening valid=\
                    \(opening.isValid, privacy: .public), opened here=\
                    \(self.hasOpened, privacy: .public), already begun=\
                    \(self.openLaunch != nil, privacy: .public). No record is written, so the \
                    launch will read as one that never started.
                    """
                )
                return
            }

            let launchID = id ?? UUID().uuidString
            openLaunch = OpenLaunch(id: launchID, bootID: opening.bootID)
            append(record(
                kind: .begin,
                launch: launchID,
                bootID: opening.bootID,
                build: fingerprint.build,
                fingerprint: fingerprint.token,
                mode: mode.rawValue,
                writer: LaunchLedgerWriter.app.rawValue,
                pid: ProcessInfo.processInfo.processIdentifier
            ))
        }
    }

    /// Records one startup checkpoint. A no-op for a process that never began a launch.
    func record(_ checkpoint: StartupCheckpoint, detail: [String: String] = [:]) {
        queue.sync {
            guard let openLaunch else { return }
            append(record(
                kind: .checkpoint,
                launch: openLaunch.id,
                bootID: openLaunch.bootID,
                checkpoint: checkpoint.rawValue,
                detail: detail.isEmpty ? nil : detail
            ))
        }
    }

    /// Closes this launch on purpose. A no-op for a process that never began one, and for a
    /// second call — a launch ends once, and a second `end` would leave the reader choosing.
    func endLaunch(_ disposition: LaunchDisposition, systemInitiated: Bool = false) {
        queue.sync {
            guard var open = openLaunch, !open.hasEnded else { return }
            open.hasEnded = true
            openLaunch = open

            cancelStabilityTimerLocked()
            append(record(
                kind: .end,
                launch: open.id,
                bootID: open.bootID,
                disposition: disposition.token,
                systemInitiated: systemInitiated
            ))
        }
    }

    /// Arms the ten-minute stability checkpoint. Called once the first window is on screen.
    ///
    /// **On the main queue, deliberately.** `stable` is a claim that the app was usable for ten
    /// minutes, and a main thread wedged for ten minutes must not be the thing that certifies it:
    /// a utility queue would keep ticking through a hang and clear a crash count on behalf of an
    /// app nobody could use. A `DispatchTime` deadline also does not advance while the Mac
    /// sleeps, so this is ten *interactive* minutes rather than ten minutes of wall clock.
    func armStabilityCheckpoint() {
        queue.sync {
            guard openLaunch != nil, stabilityTimer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                deadline: DispatchTime.now()
                    + .seconds(LaunchLedgerDefaults.stableAfterInteractiveSeconds),
                leeway: .seconds(LaunchLedgerDefaults.stabilityLeewaySeconds)
            )
            timer.setEventHandler { [weak self] in
                self?.record(.stable)
                self?.cancelStabilityCheckpoint()
            }
            stabilityTimer = timer
            timer.resume()
        }
    }

    func cancelStabilityCheckpoint() {
        queue.sync { cancelStabilityTimerLocked() }
    }

    /// What is on disk. The support report's seam, and how a test asks without beginning a launch.
    func read() -> LaunchLedgerRead {
        queue.sync { readLedger() }
    }

    /// Whether a read has blocked writes for the rest of this launch. A test seam.
    var isWriteBlocked: Bool {
        queue.sync { !writesAllowed }
    }

    // MARK: - Private Methods — Tombstones

    /// One tombstone per `begin` that never received an ending.
    ///
    /// The newest takes the marker's answer, because `EventLog` is the one thing that actually
    /// knows how the last launch ended. Older ones are inferred `unclean` from their own missing
    /// `end`: that absence is the evidence, and it needs no marker — which matters, because the
    /// case that produces an older unfinished `begin` is a successor that died before it could
    /// write anything at all.
    ///
    /// A marker outcome with no unfinished `begin` to attach to writes **nothing**. Inventing a
    /// target, or attaching an outcome to a launch that already ended, would make the file say
    /// something nobody observed.
    private func tombstones(
        for history: LaunchLedgerHistory,
        previousOutcome: EventLog.PreviousLaunchOutcome,
        bootID: String
    ) -> [LaunchLedgerRecord] {
        let unfinished = history.launches.filter { $0.ending == nil }
        guard let newest = unfinished.last else { return [] }

        return unfinished.map { launch in
            let disposition: LaunchDisposition = launch.id == newest.id
                ? Self.disposition(for: previousOutcome)
                : .unclean
            return record(
                kind: .outcome,
                launch: launch.id,
                bootID: bootID,
                disposition: disposition.token
            )
        }
    }

    /// `unknown` becomes `unclean` rather than nothing: it means no marker *and* no journal, and
    /// a `begin` sitting here without an ending is itself the evidence that launch never came
    /// back. The two only ever disagree when the journal directory has been removed under a
    /// ledger that survived.
    private static func disposition(
        for outcome: EventLog.PreviousLaunchOutcome
    ) -> LaunchDisposition {
        switch outcome {
        case .clean: return .clean
        case .intentional(let reason): return .intentional(reason)
        case .unclean, .unknown: return .unclean
        }
    }

    private func apply(_ tombstones: [LaunchLedgerRecord], to history: inout LaunchLedgerHistory) {
        for tombstone in tombstones {
            guard let index = history.launches.firstIndex(where: { $0.id == tombstone.launch })
            else { continue }
            history.launches[index].ending = LaunchEnding(
                disposition: LaunchDisposition(token: tombstone.disposition ?? ""),
                systemInitiated: false
            )
        }
        history.records.append(contentsOf: tombstones)
    }

    // MARK: - Private Methods — Reading

    private func readLedger() -> LaunchLedgerRead {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return .missing }

        switch LaunchLedgerParser.parse(data) {
        case .valid(let history):
            return .valid(history)
        case .unsupportedVersion(let newest):
            return .unsupportedVersion(newestFormatSeen: newest)
        case .corrupt:
            return .corrupt(quarantinedAt: quarantine())
        }
    }

    /// Moves damage aside before anything is written over it, and stops writing if it cannot.
    private func quarantine() -> URL? {
        closeHandle()

        let destination = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(LaunchLedgerDefaults.fileStem)"
                    + ".\(LaunchLedgerDefaults.quarantineInfix)-\(Self.quarantineStamp())"
                    + ".\(LaunchLedgerDefaults.fileExtension)"
            )

        do {
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            writesAllowed = false
            ThreadingLogger.session.error(
                """
                Could not move the damaged launch ledger aside: \
                \(error.localizedDescription, privacy: .public). Later records are refused.
                """
            )
            return nil
        }
    }

    // MARK: - Private Methods — Compaction

    /// Rewrites the file to the newest launches, at the one moment it is safe to rewrite it: a
    /// single writer, before this launch has recorded anything worth losing, and with a failure
    /// that simply leaves the old file in place to be appended to.
    ///
    /// **Eviction is by launch, never by line.** Half a launch reads as a launch that died, so a
    /// line budget alone would manufacture the exact fact this file exists to report. In Phase 3
    /// this moves to the supervisor with `begin` and `outcome`; `writer` is what will make that
    /// handoff readable afterwards.
    private func compactIfNeeded(_ history: LaunchLedgerHistory) {
        guard writesAllowed else { return }
        let keep = Self.recordsToKeep(from: history)
        guard keep.count != history.records.count else { return }

        var text = ""
        for record in keep {
            guard let line = encode(record) else { continue }
            text += line + "\n"
        }

        closeHandle()
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent("\(LaunchLedgerDefaults.fileStem).\(UUID().uuidString)")
        do {
            try ensureDirectoryExists()
            try Data(text.utf8).write(to: staging, options: .atomic)
            _ = try fileManager.replaceItemAt(url, withItemAt: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            ThreadingLogger.session.error(
                "Could not compact the launch ledger: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func recordsToKeep(from history: LaunchLedgerHistory) -> [LaunchLedgerRecord] {
        var keptIDs: Set<String> = []
        var count = 0

        for launch in history.launches.reversed() {
            guard keptIDs.count < LaunchLedgerDefaults.maximumLaunches else { break }
            let records = history.records.filter { $0.launch == launch.id }.count
            guard count + records <= LaunchLedgerDefaults.maximumRecords else { break }
            keptIDs.insert(launch.id)
            count += records
        }

        return history.records.filter { keptIDs.contains($0.launch) }
    }

    // MARK: - Private Methods — Writing

    private func record(
        kind: LaunchLedgerRecord.Kind,
        launch: String,
        bootID: String,
        build: String? = nil,
        fingerprint: String? = nil,
        mode: String? = nil,
        writer: String? = nil,
        pid: Int32? = nil,
        checkpoint: String? = nil,
        detail: [String: String]? = nil,
        disposition: String? = nil,
        systemInitiated: Bool? = nil
    ) -> LaunchLedgerRecord {
        LaunchLedgerRecord(
            version: LaunchLedgerDefaults.formatVersion,
            kind: kind,
            launch: launch,
            at: Self.timestampFormatter.string(from: Date()),
            uptime: ProcessInfo.processInfo.systemUptime,
            boot: bootID,
            build: build,
            fingerprint: fingerprint,
            mode: mode,
            writer: writer,
            pid: pid,
            checkpoint: checkpoint,
            detail: detail,
            disposition: disposition,
            systemInitiated: systemInitiated
        )
    }

    private func append(_ record: LaunchLedgerRecord) {
        guard writesAllowed, let line = encode(record) else { return }
        guard let data = (line + "\n").data(using: .utf8), let handle = openHandle() else { return }

        do {
            try handle.write(contentsOf: data)
        } catch {
            ThreadingLogger.session.error(
                "Launch ledger write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func encode(_ record: LaunchLedgerRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A descriptor whose every write lands at the end *as one operation*, for the reason
    /// `EventLog.openForAppending` states: more than one process writes into this directory, and
    /// two handles holding two offsets over one file write straight through each other.
    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        try? ensureDirectoryExists()

        let descriptor = open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT,
            LaunchLedgerDefaults.fileMode
        )
        guard descriptor >= 0 else { return nil }

        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func cancelStabilityTimerLocked() {
        stabilityTimer?.cancel()
        stabilityTimer = nil
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Private Methods — Clocks

    /// When this Mac booted, to the second. Two uptimes are only comparable within one boot, and
    /// rounding is what keeps the identity stable while `systemUptime` drifts against `Date`.
    static func bootIdentifier() -> String {
        let booted = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        return String(Int(booted.timeIntervalSince1970.rounded()))
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private static func quarantineStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = LaunchLedgerDefaults.quarantineStampFormat
        return formatter.string(from: Date())
    }
}

// MARK: - Launch Ledger Defaults

enum LaunchLedgerDefaults {

    /// Its own directory under Application Support ▸ Threading, so Reset Everything moves it
    /// aside with everything else and `EventLog`'s prune-by-extension cannot reach it.
    static let directoryName = "Launch"
    static let fileStem = "launch-ledger"
    static let fileExtension = "jsonl"
    static let quarantineInfix = "corrupt"
    static let quarantineStampFormat = "yyyy-MM-dd HH-mm-ss"

    static let queueLabel = "codes.threading.launch-ledger"

    /// Raised only when a record's shape changes. A reader skips any record above its own.
    static let formatVersion = 1

    /// Owner's to read and write, readable by anyone handed a support report — `EventLog`'s.
    static let fileMode: mode_t = 0o644

    /// Enough launches to see a loop and the healthy runs on either side of it, few enough that
    /// the file stays a page long.
    static let maximumLaunches = 20

    /// The second guard, against one pathological launch recording far more than the nine
    /// checkpoints a launch has. Whichever budget binds first decides.
    static let maximumRecords = 512

    /// Ten interactive minutes: long enough that nothing about a launch is still in doubt, short
    /// enough that a user who fixed the problem is not still being counted an hour later.
    static let stableAfterInteractiveSeconds = 10 * 60
    static let stabilityLeewaySeconds = 30

    static let readMissingToken = "missing"
    static let readValidToken = "valid"
    static let readUnsupportedToken = "unsupported"
    static let readCorruptToken = "corrupt"

    static let dispositionClean = "clean"
    static let dispositionUnclean = "unclean"
    static let dispositionUnknown = "ended"
    static let dispositionIntentionalPrefix = "intentional:"

    static let unknownVersion = "?"

    /// The scratch name a hosted test bundle writes under. The tests run inside the shipping app,
    /// so a test that begins a launch must not append to the ledger the developer's own next
    /// launch will decide a crash loop from — `AgentChildLedgerDefaults`' rule, for its reason.
    static let hostedTestDirectoryName = "LaunchLedgerHostedTests"

    static var defaultURL: URL {
        let directory = AppDataLocations.supportDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        let fileName = "\(fileStem).\(fileExtension)"

        guard NSClassFromString("XCTestCase") != nil else {
            return directory.appendingPathComponent(fileName)
        }
        return directory
            .appendingPathComponent(hostedTestDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
