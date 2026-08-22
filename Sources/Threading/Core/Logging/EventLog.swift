import Foundation

// MARK: - Intentional Exit Reason

/// Why a launch left without going down the quit path.
///
/// A type rather than a `Bool` because the answer belongs in a support report: "the app restarted
/// because you reset it" and "the app died" are the same missing quit and want opposite words on
/// screen. Top-level rather than nested because both the marker and the launch ledger record it,
/// and neither owns the other.
///
/// The second case is what made the type earn itself. Both reasons are deliberate restarts, and
/// `LaunchRestorationPlan` treats them **oppositely**: a reset comes back to a workspace it is
/// safe to reopen, and a recovery relaunch comes back to one the app has been dying in. A `Bool`
/// could not have told them apart.
enum IntentionalExitReason: String, Equatable, Sendable {

    /// `AppRelaunch.PreparedRelaunch.commit`, which both resets take.
    case reset

    /// The recovery surface's "Try Normal Launch Once".
    case recoveryRelaunch
}

/// A durable, append-only record of what the app was doing, meant to be read *after*
/// something has already gone wrong.
///
/// `ThreadingLogger` is the live view — `log stream` while a bug reproduces. It is the wrong
/// tool for a post-mortem: `os_log` keeps `.debug` and `.info` in a memory ring buffer that
/// is evicted within minutes, and only `.error`/`.fault` ever reach disk. Measured after the
/// crash of 22 July 2026: `log show --predicate 'subsystem == "codes.threading"'` returned not a
/// single line for the minute the app died in, so nothing could say which session had just
/// been started, or what it had been asked to do.
///
/// The two stay separate rather than becoming one wrapper on purpose. `Logger`'s privacy
/// annotations (`\(id, privacy: .public)`) live inside the `OSLogMessage` literal and cannot
/// be rendered back out as a string, so a type that fed both would have to drop them from
/// every existing call site.
///
/// Records are appended **synchronously**, with an unbuffered write. What is journalled here
/// is lifecycle — a handful of records a minute — and the record that matters most is always
/// the one written immediately before the process died, which an asynchronous hand-off is
/// exactly what would lose.
final class EventLog: @unchecked Sendable {

    // MARK: - Types

    /// What a record is about. One case per subsystem a failure gets reconstructed from.
    enum Category: String {
        case app
        case session
        case composer
        case mcp
        /// Extension installation and host/runtime state transitions.
        case extensions

        /// Agent hooks. Its own category because a hook is invisible by construction — a curl
        /// in a subprocess whose output is discarded — so when one stops working there is
        /// nothing on screen, and nothing in the agent's own output, to say so.
        case hooks

        /// Remote access. Its own category because it is the one surface reachable from off the
        /// machine, so a security question ("who connected, when, with what capability, and did
        /// they type into it") must have a durable answer that outlives the live log.
        case remote

        /// Usage-limit recovery. Its own category because it acts precisely when nobody is
        /// watching — reading a refusal, typing into a chooser, scheduling a continuation —
        /// and a run that misfired unobserved can only be reconstructed from what it wrote
        /// down. See `limit-recovery.md`.
        case limitRecovery

        /// Curfews. Its own category for `limitRecovery`'s reason, one degree further: a curfew
        /// acts by definition when nobody is watching — it sends a wrap-up, holds a session
        /// against its own outbox, and types an Escape into a terminal at four in the morning —
        /// so a run that misfired unobserved can only be reconstructed from what it wrote down.
        /// See `curfew.md`.
        case curfew
    }

    /// How the launch before this one ended, as *this* launch found it.
    ///
    /// A typed answer rather than the `Bool?` it used to be, because the interesting case
    /// carries evidence with it and the uninteresting one is not a "no". `nil` meant three
    /// different things at three call sites — never ran, quit cleanly, or nothing to say —
    /// and the one consumer that existed had to re-derive which. See
    /// `docs/architecture/reliability-and-type-safety.md`: an availability state the UI has to
    /// render is a type, not a nullable primitive.
    ///
    /// It lives for exactly this launch. The marker it is read from is **consumed on read**, so
    /// the one-shot lifetime is already the mechanism's; nothing new is written down to give it
    /// one.
    enum PreviousLaunchOutcome: Equatable {

        /// The previous launch removed its marker on the way out, which only `endLaunch` does.
        case clean

        /// The previous launch left **without** the quit path, on purpose — the reset flows, which
        /// `exit` rather than terminate because a polite quit would write the state they just
        /// moved aside straight back.
        ///
        /// It used to be indistinguishable from a crash, and that was a real bug: Reset Settings
        /// leaves the support directory alone, so the marker survived the restart and the next
        /// launch held the workspace back and put a crash notice across a window the user had
        /// just asked for. The marker is stamped with its disposition before the exit now, which
        /// is why this is a case rather than an inference.
        case intentional(reason: IntentionalExitReason)

        /// The marker was still lying there, which is the case where the app did not live long
        /// enough to quit. `crashReport` is the `.ips` macOS wrote for that launch, when one
        /// matched — absent for a kill, a power loss, or a report the system has not filed.
        case unclean(crashReport: URL?)

        /// Nothing to judge: no marker *and* no journal, which is a machine the app has never
        /// run on. Not a "quit cleanly" — a launch that answers this one has no previous launch.
        case unknown
    }

    /// The independent durable paths whose failures are deduplicated in the live log.
    private enum DiagnosticTarget: String {
        case journal
        case launchMarker = "launch_marker"
        case housekeeping
    }

    // MARK: - Singleton

    static let shared = EventLog()

    // MARK: - Properties

    /// Where the journals live. Surfaced by Help ▸ Reveal Diagnostics Log.
    let directory: URL

    /// Today's journal, which is what the menu item reveals.
    var currentJournalURL: URL {
        queue.sync { journalURL(forDay: dayStamp(Date())) }
    }

    /// Serialises appends and guards the cached handle. Everything below `record` runs here.
    private let queue = DispatchQueue(label: EventLogDefaults.queueLabel)

    private var openDay: String?
    private var openHandle: FileHandle?

    /// One live-log error per target and failure stage. A dead diagnostics directory can affect
    /// every lifecycle record; repeating the same error for each one buries the first cause.
    private var reportedFailureStages: [DiagnosticTarget: String] = [:]

    /// The marker *this* instance wrote, or `nil` while it has not begun a launch.
    ///
    /// The marker is one file shared by every process that runs against this directory, and a
    /// second instance is a normal event here: the app takes a `SingleInstanceLock`, so a
    /// double-click while it is running starts a process that shows an alert and quits, and a
    /// hosted XCTest bundle runs inside the real application. Removing that file on the way out
    /// is therefore only correct for the process that put it there — an instance that never
    /// began a launch deleting it would make the *running* instance's later crash invisible,
    /// which is the one thing the marker exists to catch.
    ///
    /// So ownership is held rather than assumed: `endLaunch` refuses without it, and removes
    /// only a file that still carries this launch's own token.
    private var ownedMarker: [String: String]?

    /// Where macOS leaves the `.ips` for a launch that did not come back. Injectable so the
    /// matcher can be held to a directory of fixtures rather than to whatever the developer's
    /// own machine crashed last.
    private let diagnosticReportsDirectory: URL?

    // MARK: - Initialization

    init(directory: URL? = nil, diagnosticReportsDirectory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(EventLogDefaults.directoryName)
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
            ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent(EventLogDefaults.diagnosticReportsPath)
    }

    // MARK: - Public Methods

    /// Appends one record. Never throws and never traps: a journal that cannot be written
    /// must not take the app down with it.
    func record(_ category: Category, _ message: String, _ detail: [String: String] = [:]) {
        queue.sync {
            append(line(category: category, message: message, detail: detail))
        }
    }

    /// How the launch before this one ended.
    ///
    /// Read at `beginLaunch` and kept, because the marker it is derived from is consumed a few
    /// lines later. A support report and the window's own notice both want this exact fact and
    /// neither can recover it afterwards.
    var previousLaunchOutcome: PreviousLaunchOutcome {
        queue.sync { previousLaunchOutcomeStorage }
    }

    /// Whether the launch before this one ended on purpose — `nil` where there was no previous
    /// launch to judge. Derived rather than stored: the outcome above is the fact, and this is
    /// the shape `MacSupportReportDetails` has always reported it in.
    var previousLaunchEndedCleanly: Bool? {
        switch previousLaunchOutcome {
        // A reset relaunch ended on purpose, which is what this field has always been asking.
        // *Why* it ended on purpose is a different question, and the crash-loop fields answer it.
        case .clean, .intentional: true
        case .unclean: false
        case .unknown: nil
        }
    }

    /// The token this launch's marker carries, or `nil` while it has not begun one.
    ///
    /// Exposed so the launch ledger can file its records under the same launch the marker names.
    /// One id shared by the two, rather than a second one minted beside it: the whole reason the
    /// ledger can be told how a launch ended is that both mechanisms mean the same launch by it.
    var currentLaunchID: String? {
        queue.sync { ownedMarker?[EventLogDefaults.markerLaunchKey] }
    }

    private var previousLaunchOutcomeStorage: PreviousLaunchOutcome = .unknown

    /// Opens a launch: says how the *previous* launch ended, drops expired journals, and leaves
    /// a marker behind that only a deliberate quit removes.
    ///
    /// Called at most once per process — a second call is ignored rather than treated as a new
    /// launch. Beginning twice would read back the marker this same process had just written and
    /// report its own still-running launch as a crash.
    func beginLaunch() {
        queue.sync {
            guard ownedMarker == nil else { return }

            // **Asked before the prune, not after it.** A missing marker means either "exited
            // cleanly" or "never ran here", and only an existing journal separates the two — so
            // the question has to be put while the evidence is still on disk. Pruning first
            // deletes every journal on a machine the app has not been opened on for a fortnight,
            // and this same `beginLaunch` would then journal "Previous launch did not quit
            // cleanly" from a surviving marker while reporting the outcome as *unknown*.
            let hasRunHereBefore = journalExists()
            pruneExpiredJournals()

            // Read before the launch record is appended, so the journal reads in the order the
            // events happened: the previous launch's ending, then this one's beginning.
            let previous = consumePreviousMarker()

            // A marker that is still there was written by a launch that never came back — unless
            // that launch stamped it on its way out, which is the one way of leaving that removes
            // no marker and is not a crash. The journal only ever answers the *absence* of one.
            if let previous {
                let reason = previous[EventLogDefaults.markerDispositionKey]
                    .flatMap(IntentionalExitReason.init(rawValue:))

                if let reason {
                    previousLaunchOutcomeStorage = .intentional(reason: reason)
                    append(line(
                        category: .app,
                        message: EventLogDefaults.intentionalExitMessage,
                        detail: reportedDetail(from: previous, crashReport: nil)
                    ))
                } else {
                    // Only looked for on the branch that can have one. An `.ips` written by some
                    // other process and hung off a deliberate restart is the shape of mistake the
                    // pre-rename adoption already made once.
                    let report = crashReport(
                        matching: previous[EventLogDefaults.markerStartedAtKey],
                        previousPID: previous[EventLogDefaults.markerPIDKey]
                    )
                    previousLaunchOutcomeStorage = .unclean(
                        crashReport: report.map { URL(fileURLWithPath: $0) }
                    )
                    append(line(
                        category: .app,
                        message: EventLogDefaults.uncleanExitMessage,
                        detail: reportedDetail(from: previous, crashReport: report)
                    ))
                }
            } else {
                previousLaunchOutcomeStorage = hasRunHereBefore ? .clean : .unknown
            }

            append(line(category: .app, message: EventLogDefaults.launchedMessage, detail: [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "version": versionString
            ]))

            writeMarker()
        }
    }

    /// Closes a launch. The marker's *absence* is what tells the next launch this one ended
    /// on purpose rather than by dying.
    ///
    /// A no-op for a process that never began one. That is the second-instance case: the
    /// instance that loses the `SingleInstanceLock` puts up an alert and terminates, and the
    /// quit path it goes down must not remove the marker belonging to the instance that is
    /// still running — a crash of that one would then read as a clean quit. Today it returns
    /// before reaching here at all; this makes the protection a property of the mechanism
    /// rather than of one `guard` in `applicationShouldTerminate`.
    func endLaunch(detail: [String: String] = [:]) {
        queue.sync {
            guard ownedMarker != nil else { return }

            append(line(category: .app, message: EventLogDefaults.quitMessage, detail: detail))
            removeOwnedMarker()
        }
    }

    /// Stamps the marker with the reason this process is about to leave without quitting.
    ///
    /// The marker is **kept**, not removed. Removing it would say "quit cleanly", which is what
    /// the quit path means and this is not; leaving it untouched says "crashed", which is what
    /// Reset Settings looked like for as long as the two were the only answers. Stamped, the next
    /// launch reads a third thing and consumes the file exactly as it always has.
    ///
    /// Written as late as the process can manage — `AppRelaunch` calls this immediately before
    /// `exit` — because everything after it is a window in which a real crash would be reported
    /// as a deliberate restart.
    func recordIntentionalExit(_ reason: IntentionalExitReason) {
        queue.sync {
            guard var marker = ownedMarker else { return }

            append(line(
                category: .app,
                message: EventLogDefaults.leavingIntentionallyMessage,
                detail: [EventLogDefaults.markerDispositionKey: reason.rawValue]
            ))

            marker[EventLogDefaults.markerDispositionKey] = reason.rawValue
            ownedMarker = marker
            persistMarker(marker)
        }
    }

    // MARK: - Private Methods

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else {
            reportEncodingFault(target: .journal)
            return
        }
        guard let handle = handle(forDay: dayStamp(Date())) else { return }

        do {
            try handle.write(contentsOf: data)
            reportRecovery(target: .journal)
            repairMissingOwnedMarker()
        } catch {
            // Reopen on the next record. A descriptor can remain valid after one failed write
            // while every later write to it fails in exactly the same way.
            try? openHandle?.close()
            openHandle = nil
            openDay = nil
            reportFailure(target: .journal, stage: "write", error: error)
        }
    }

    /// The open handle for a day's journal, reopening when the day rolls over mid-launch.
    private func handle(forDay day: String) -> FileHandle? {
        if let openHandle, openDay == day { return openHandle }

        do {
            try openHandle?.close()
        } catch {
            reportWarning(target: .journal, stage: "close", error: error)
        }
        openHandle = nil
        openDay = nil

        guard ensureDirectoryExists(target: .journal) else { return nil }

        guard let handle = openForAppending(journalURL(forDay: day)) else { return nil }

        openHandle = handle
        openDay = day

        return handle
    }

    /// A descriptor whose every write lands at the end *as one operation*, rather than at an
    /// offset this process is remembering.
    ///
    /// `FileHandle(forWritingTo:)` plus `seekToEndOfFile` records where the end was when the
    /// journal was opened, and more than one process writes this file: a hosted XCTest bundle
    /// runs inside the real application, so a test run uses this same type against this same
    /// directory. Two handles then hold two offsets over one file and write straight through
    /// each other's records — measured on the 5 August 2026 journal, 23 lines were left
    /// unparseable and a quit's own record was overwritten mid-line by a concurrent test run,
    /// which reads as "the quit never happened" to anyone reconstructing the failure
    /// afterwards. `O_APPEND` moves the seek into the kernel, where it is atomic with the
    /// write, and `O_CREAT` is also what makes the file on a first launch.
    ///
    /// `O_CLOEXEC` because this handle is held for the process's lifetime and this process spawns
    /// agent children through `forkpty`, which duplicates the whole descriptor table. An inherited
    /// journal descriptor does not block anything the way an inherited `flock` does — see
    /// `SingleInstanceLock` — but it does leak the app's diagnostics file into every agent CLI,
    /// and it keeps the inode alive in orphans long after the launch that opened it. The rule here
    /// is that a long-lived descriptor is closed on exec unless a child is meant to have it.
    private func openForAppending(_ url: URL) -> FileHandle? {
        let descriptor = open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC,
            EventLogDefaults.fileMode
        )
        guard descriptor >= 0 else {
            reportFailure(target: .journal, stage: "open", errnoCode: errno)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func line(
        category: Category,
        message: String,
        detail: [String: String]
    ) -> String {
        var record: [String: Any] = [
            "t": timestamp(),
            "category": category.rawValue,
            "message": message
        ]

        if !detail.isEmpty {
            record["detail"] = detail
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return #"{"category":"\#(category.rawValue)","message":"unencodable record"}"#
        }

        return json
    }

    // MARK: - Launch Marker

    private var markerURL: URL {
        directory.appendingPathComponent(EventLogDefaults.markerFileName)
    }

    private func writeMarker() {
        let marker: [String: String] = [
            // Minted per launch rather than derived from the pid: a pid is reused by the system,
            // and a hosted test bundle shares one with the application hosting it, so it cannot
            // say *which* launch a marker belongs to. This can.
            EventLogDefaults.markerLaunchKey: UUID().uuidString,
            EventLogDefaults.markerPIDKey: String(ProcessInfo.processInfo.processIdentifier),
            EventLogDefaults.markerStartedAtKey: timestamp(),
            EventLogDefaults.markerVersionKey: versionString
        ]

        // Held before the write rather than after it: a marker that could not be written is
        // still this process's launch, and `endLaunch` has to know it began one so it appends
        // its `Quit` record. Removing a file that is not there is what a no-op looks like.
        ownedMarker = marker

        persistMarker(marker)
    }

    private func persistMarker(_ marker: [String: String]) {
        guard ensureDirectoryExists(target: .launchMarker) else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: marker,
            options: [.sortedKeys]
        ) else {
            reportEncodingFault(target: .launchMarker)
            return
        }

        do {
            try data.write(to: markerURL, options: .atomic)
            reportRecovery(target: .launchMarker)
        } catch {
            reportFailure(target: .launchMarker, stage: "write", error: error)
        }
    }

    /// If startup could not put its marker down, the first later journal write retries it. The
    /// existing-file guard is the ownership boundary: another fail-open instance may have put a
    /// different launch there, and this process must never overwrite that evidence.
    private func repairMissingOwnedMarker() {
        guard let ownedMarker,
              !FileManager.default.fileExists(atPath: markerURL.path) else { return }
        persistMarker(ownedMarker)
    }

    /// Removes the marker only while it is still the one this launch wrote.
    ///
    /// A marker carrying someone else's token was written by a launch that is still running —
    /// the app is single-instance by lock rather than by construction, and the lock fails open —
    /// and deleting it would hand that launch a clean bill of health it has not earned yet.
    private func removeOwnedMarker() {
        guard let ownedMarker,
              let data = try? BoundedFileReader.read(
                  markerURL,
                  maximumBytes: EventLogDefaults.maximumMarkerBytes
              ),
              let onDisk = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              onDisk[EventLogDefaults.markerLaunchKey]
                == ownedMarker[EventLogDefaults.markerLaunchKey]
        else { return }

        do {
            try FileManager.default.removeItem(at: markerURL)
            reportRecovery(target: .launchMarker)
        } catch {
            reportWarning(target: .launchMarker, stage: "remove", error: error)
        }
    }

    /// The previous launch's marker, if it never got cleaned up — which is the case where the app
    /// did not live long enough to quit, *or* left deliberately without the quit path and stamped
    /// the file to say so. Consumed on read, so either is reported once rather than at every
    /// launch after it.
    ///
    /// The raw marker rather than a journal detail: only the caller knows which of the two it is
    /// looking at, and only one of them should go looking for a crash report.
    private func consumePreviousMarker() -> [String: String]? {
        guard let data = try? BoundedFileReader.read(
                  markerURL,
                  maximumBytes: EventLogDefaults.maximumMarkerBytes
              ),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        do {
            try FileManager.default.removeItem(at: markerURL)
        } catch {
            reportWarning(target: .launchMarker, stage: "consume", error: error)
        }
        return marker
    }

    /// The marker as the journal reports it: the previous launch's facts, without the bookkeeping.
    private func reportedDetail(
        from marker: [String: String],
        crashReport report: String?
    ) -> [String: String] {
        var detail = marker
        // The token says which launch owns the file, which is a question for `endLaunch` and not
        // a fact about the launch being reported. The disposition is already the message.
        detail.removeValue(forKey: EventLogDefaults.markerLaunchKey)
        detail.removeValue(forKey: EventLogDefaults.markerDispositionKey)
        detail["previousPID"] = detail.removeValue(forKey: EventLogDefaults.markerPIDKey)
        detail["previousVersion"] = detail.removeValue(forKey: EventLogDefaults.markerVersionKey)

        // A journal saying "this launch never came back" is more use pointing at the report
        // than making whoever reads it go and find the matching one by hand.
        if let report {
            detail[EventLogDefaults.crashReportKey] = report
        }

        return detail
    }

    /// The crash report macOS wrote for the launch that did not come back.
    ///
    /// **The time window alone is not enough, and that is not theoretical.** The unit-test bundle
    /// is hosted *in this app*, so a test that traps writes `Threading-<stamp>.ips` under the
    /// same name as the shipping app — and a run of the suite while the real app is open puts
    /// several of those into the window a genuine launch would match. The report then attached to
    /// the user's launch is a stack from a test host, which is a worse answer than no report at
    /// all: it is a plausible one.
    ///
    /// So a candidate is attached only when its own recorded pid is the pid the marker named. A
    /// candidate whose pid parses and differs is skipped and the scan continues, because the real
    /// report may be older than it. A candidate whose pid cannot be read is skipped too — fail
    /// closed — and said out loud once, since a format change would otherwise turn every crash
    /// silently unattributable.
    ///
    /// A marker with no pid predates the field. That launch keeps the old time-window behaviour
    /// rather than losing its report: compatibility for one launch, not a standing exception.
    private func crashReport(matching startedAt: String?, previousPID: String?) -> String? {
        guard let startedAt, let start = timestampFormatter.date(from: startedAt) else {
            return nil
        }

        guard let reports = diagnosticReportsDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: reports,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else { return nil }

        let candidates = contents.filter {
            $0.lastPathComponent.hasPrefix(EventLogDefaults.crashReportPrefix)
                && $0.pathExtension == EventLogDefaults.crashReportExtension
        }.compactMap { url -> (URL, Date)? in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified >= start else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }

        guard let wanted = previousPID.flatMap(Int32.init) else {
            return candidates.first?.0.path
        }

        var reportedUnparseable = false
        for candidate in candidates {
            guard let pid = Self.recordedPID(in: candidate.0) else {
                if !reportedUnparseable {
                    reportedUnparseable = true
                    append(line(
                        category: .app,
                        message: EventLogDefaults.unreadableCrashReportMessage,
                        detail: ["report": candidate.0.lastPathComponent]
                    ))
                }
                continue
            }
            if pid == wanted { return candidate.0.path }
        }

        return nil
    }

    /// The process id an `.ips` records, or `nil` for anything that cannot be believed.
    ///
    /// An `.ips` is one JSON header line followed by a JSON body, and the pid is a top-level key
    /// of the body — about 400 bytes in, whatever the report's size. Only a bounded prefix is
    /// read, which is why the body is parsed as JSON *if it fits* and scanned for the key if it
    /// does not: a 40 MB spin report must not be loaded to answer a question the first kilobyte
    /// already answers.
    private static func recordedPID(in url: URL) -> Int32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(
            upToCount: EventLogDefaults.maximumCrashReportPrefixBytes
        ), let newline = prefix.firstIndex(of: UInt8(ascii: "\n")) else { return nil }

        let body = prefix[prefix.index(after: newline)...]
        if let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
           let pid = object["pid"] as? Int {
            return Int32(exactly: pid)
        }
        return scannedPID(in: body)
    }

    /// The first `"pid" : <digits>` in a body that would not parse, which is the truncated case.
    ///
    /// The quoted key is what keeps this off `"byPid"` and every other key ending in the same
    /// three letters, and the first occurrence is the top-level one in every report format macOS
    /// writes today.
    private static func scannedPID(in body: Data) -> Int32? {
        guard let key = body.range(of: Data(EventLogDefaults.crashReportPIDKey.utf8)) else {
            return nil
        }

        var cursor = key.upperBound
        while cursor < body.endIndex,
              body[cursor] == UInt8(ascii: " ") || body[cursor] == UInt8(ascii: ":") {
            cursor = body.index(after: cursor)
        }

        var digits = ""
        while cursor < body.endIndex, body[cursor] >= UInt8(ascii: "0"),
              body[cursor] <= UInt8(ascii: "9") {
            digits.append(Character(UnicodeScalar(body[cursor])))
            cursor = body.index(after: cursor)
        }
        return digits.isEmpty ? nil : Int32(digits)
    }

    // MARK: - Housekeeping

    /// Whether any journal from a previous launch survives. Called before this launch appends
    /// *and* before the prune, so it answers "has this app ever run here" rather than "is there
    /// a journal the retention window still likes".
    private func journalExists() -> Bool {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch where !FileManager.default.fileExists(atPath: directory.path) {
            return false
        } catch {
            reportWarning(target: .housekeeping, stage: "enumerate", error: error)
            return false
        }

        return contents.contains { $0.pathExtension == EventLogDefaults.fileExtension }
    }

    /// Drops journals past the retention window. Runs once per launch, which is often enough
    /// for a file per day.
    private func pruneExpiredJournals() {
        let cutoff = Date().addingTimeInterval(-EventLogDefaults.retention)

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch where !FileManager.default.fileExists(atPath: directory.path) {
            return
        } catch {
            reportWarning(target: .housekeeping, stage: "prune_enumerate", error: error)
            return
        }

        for url in contents where url.pathExtension == EventLogDefaults.fileExtension {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else { continue }

            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                reportWarning(target: .housekeeping, stage: "prune_remove", error: error)
            }
        }
    }

    private func ensureDirectoryExists(target: DiagnosticTarget) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            reportFailure(target: target, stage: "directory", error: error)
            return false
        }
    }

    // MARK: - Live Diagnostics Fallback

    /// These deliberately bypass the durable journal: the durable journal is the component
    /// reporting that it cannot perform its job.
    private func reportFailure(target: DiagnosticTarget, stage: String, error: Error) {
        guard reportedFailureStages[target] != stage else { return }
        reportedFailureStages[target] = stage
        ThreadingLogger.app.error(
            "Event log unavailable target=\(target.rawValue, privacy: .public) stage=\(stage, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
    }

    private func reportFailure(target: DiagnosticTarget, stage: String, errnoCode: Int32) {
        guard reportedFailureStages[target] != stage else { return }
        reportedFailureStages[target] = stage
        ThreadingLogger.app.error(
            "Event log unavailable target=\(target.rawValue, privacy: .public) stage=\(stage, privacy: .public) errno=\(errnoCode, privacy: .public)"
        )
    }

    private func reportWarning(target: DiagnosticTarget, stage: String, error: Error) {
        guard reportedFailureStages[target] != stage else { return }
        reportedFailureStages[target] = stage
        ThreadingLogger.app.warning(
            "Event log maintenance failed target=\(target.rawValue, privacy: .public) stage=\(stage, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
    }

    private func reportEncodingFault(target: DiagnosticTarget) {
        let stage = "encoding"
        guard reportedFailureStages[target] != stage else { return }
        reportedFailureStages[target] = stage
        ThreadingLogger.app.fault(
            "Event log invariant failed target=\(target.rawValue, privacy: .public) stage=\(stage, privacy: .public)"
        )
    }

    private func reportRecovery(target: DiagnosticTarget) {
        guard let stage = reportedFailureStages.removeValue(forKey: target) else { return }
        ThreadingLogger.app.notice(
            "Event log recovered target=\(target.rawValue, privacy: .public) after=\(stage, privacy: .public)"
        )
    }

    private func journalURL(forDay day: String) -> URL {
        directory.appendingPathComponent(
            "\(EventLogDefaults.filePrefix)\(day).\(EventLogDefaults.fileExtension)"
        )
    }

    // MARK: - Formatting

    /// Local time with its offset, matching how macOS stamps its own crash reports — the
    /// journal is read side by side with them.
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = EventLogDefaults.dayFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private func dayStamp(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Event Log Defaults

enum EventLogDefaults {
    /// Under Application Support ▸ Threading, alongside the stores it explains.
    static let directoryName = "Logs"

    static let filePrefix = "threading-"
    static let fileExtension = "jsonl"
    static let dayFormat = "yyyy-MM-dd"

    static let markerFileName = "launch.json"
    static let maximumMarkerBytes = 16 * 1_024
    static let queueLabel = "codes.threading.eventlog"

    /// What the marker carries. `markerLaunchKey` is the ownership token `endLaunch` checks
    /// before removing the file; the other three are the facts the next launch reports.
    static let markerLaunchKey = "launch"
    static let markerPIDKey = "pid"
    static let markerStartedAtKey = "startedAt"
    static let markerVersionKey = "version"

    /// Stamped into the marker by a launch that is leaving without the quit path. Its presence is
    /// what separates a deliberate restart from a crash; its absence is unchanged and still means
    /// the launch never came back.
    static let markerDispositionKey = "disposition"

    /// The journal's permissions when `O_CREAT` makes it: the owner's to read and write, and
    /// readable by anyone the user hands a support report to.
    static let fileMode: mode_t = 0o644

    /// Long enough to cover "it happened some time last week", short enough that the folder
    /// never needs managing.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    /// The pair the whole marker mechanism is read through: a `Launched` with no `Quit` after
    /// it is a launch that did not come back.
    static let launchedMessage = "Launched"
    static let quitMessage = "Quit"

    static let uncleanExitMessage = "Previous launch did not quit cleanly"

    /// The pair the third disposition is read through: one written by the launch that is leaving,
    /// one by the launch that finds the stamp.
    static let leavingIntentionallyMessage = "Leaving without quitting, on purpose"
    static let intentionalExitMessage = "Previous launch left on purpose without quitting"

    /// Where the matching `.ips` path is carried, in the journal's detail and in the outcome
    /// read back from it. One spelling, because the two are the same fact.
    static let crashReportKey = "crashReport"

    /// What the launch after a crash records instead of restoring. Journalled so the decision
    /// is in the same place as the crash it answers — a support report that says the workspace
    /// came back is a different bug report from one that says it was held.
    static let heldBackWorkspaceMessage = "Held the workspace back after an unclean exit"

    /// Said once per launch when a report in the window could not be pinned to a pid. Without it
    /// a format change turns every crash silently unattributable, which looks exactly like
    /// "macOS wrote no report".
    static let unreadableCrashReportMessage = "Skipped a crash report whose process id could not be read"

    /// Relative to `~/Library`.
    static let diagnosticReportsPath = "Logs/DiagnosticReports"
    static let crashReportPrefix = "Threading-"
    static let crashReportExtension = "ips"

    /// The top-level key in an `.ips` body, quoted, so a scan cannot land on `"byPid"`.
    static let crashReportPIDKey = "\"pid\""

    /// Enough for the header line and the body's leading scalars, which is where the pid is in
    /// every format macOS writes. A spin report runs to tens of megabytes and must not be read to
    /// answer this.
    static let maximumCrashReportPrefixBytes = 512 * 1_024
}
