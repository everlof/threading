import Foundation

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
final class EventLog {

    // MARK: - Types

    /// What a record is about. One case per subsystem a failure gets reconstructed from.
    enum Category: String {
        case app
        case session
        case composer
        case mcp

        /// Agent hooks. Its own category because a hook is invisible by construction — a curl
        /// in a subprocess whose output is discarded — so when one stops working there is
        /// nothing on screen, and nothing in the agent's own output, to say so.
        case hooks

        /// Remote access. Its own category because it is the one surface reachable from off the
        /// machine, so a security question ("who connected, when, with what capability, and did
        /// they type into it") must have a durable answer that outlives the live log.
        case remote
    }

    // MARK: - Singleton

    static let shared = EventLog()

    // MARK: - Properties

    /// Where the journals live. Surfaced by Help ▸ Reveal Diagnostics Log.
    let directory: URL

    /// Today's journal, which is what the menu item reveals.
    var currentJournalURL: URL {
        journalURL(forDay: dayStamp(Date()))
    }

    /// Serialises appends and guards the cached handle. Everything below `record` runs here.
    private let queue = DispatchQueue(label: EventLogDefaults.queueLabel)

    private var openDay: String?
    private var openHandle: FileHandle?

    // MARK: - Initialization

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
            .appendingPathComponent(EventLogDefaults.directoryName)
    }

    // MARK: - Public Methods

    /// Appends one record. Never throws and never traps: a journal that cannot be written
    /// must not take the app down with it.
    func record(_ category: Category, _ message: String, _ detail: [String: String] = [:]) {
        let line = line(category: category, message: message, detail: detail)
        queue.sync { append(line) }
    }

    /// Opens a launch: drops expired journals, says how the *previous* launch ended, and
    /// leaves a marker behind that only a deliberate quit removes.
    func beginLaunch() {
        queue.sync {
            pruneExpiredJournals()

            // Written before the launch record, so the journal reads in the order the events
            // happened: the previous launch's ending, then this one's beginning.
            if let previous = previousLaunch() {
                append(line(
                    category: .app,
                    message: EventLogDefaults.uncleanExitMessage,
                    detail: previous
                ))
            }

            append(line(category: .app, message: "Launched", detail: [
                "pid": String(ProcessInfo.processInfo.processIdentifier),
                "version": versionString
            ]))

            writeMarker()
        }
    }

    /// Closes a launch. The marker's *absence* is what tells the next launch this one ended
    /// on purpose rather than by dying.
    func endLaunch() {
        queue.sync {
            append(line(category: .app, message: "Quit", detail: [:]))
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    // MARK: - Private Methods

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8),
              let handle = handle(forDay: dayStamp(Date())) else { return }

        do {
            try handle.write(contentsOf: data)
        } catch {
            // Deliberately not recursive: the journal is what just failed.
            ThreadingLogger.session.error(
                "Event log write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The open handle for a day's journal, reopening when the day rolls over mid-launch.
    private func handle(forDay day: String) -> FileHandle? {
        if let openHandle, openDay == day { return openHandle }

        try? openHandle?.close()
        openHandle = nil
        openDay = nil

        let url = journalURL(forDay: day)
        ensureDirectoryExists()

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }

        handle.seekToEndOfFile()
        openHandle = handle
        openDay = day

        return handle
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
        ensureDirectoryExists()

        let marker: [String: String] = [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "startedAt": timestamp(),
            "version": versionString
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: marker,
            options: [.sortedKeys]
        ) else { return }

        try? data.write(to: markerURL, options: .atomic)
    }

    /// The previous launch's marker, if it never got cleaned up — which is exactly the case
    /// where the app did not live long enough to quit. Consumed on read, so an unclean exit
    /// is reported once rather than at every launch after it.
    private func previousLaunch() -> [String: String]? {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        try? FileManager.default.removeItem(at: markerURL)

        var detail = marker
        detail["previousPID"] = detail.removeValue(forKey: "pid")
        detail["previousVersion"] = detail.removeValue(forKey: "version")

        // A journal saying "this launch never came back" is more use pointing at the report
        // than making whoever reads it go and find the matching one by hand.
        if let report = crashReport(matching: marker["startedAt"]) {
            detail["crashReport"] = report
        }

        return detail
    }

    /// The newest crash report macOS wrote for us at or after a launch's start.
    private func crashReport(matching startedAt: String?) -> String? {
        guard let startedAt, let start = timestampFormatter.date(from: startedAt) else {
            return nil
        }

        guard let reports = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(EventLogDefaults.diagnosticReportsPath),
            let contents = try? FileManager.default.contentsOfDirectory(
                at: reports,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return nil }

        let ours = contents.filter {
            $0.lastPathComponent.hasPrefix(EventLogDefaults.crashReportPrefix)
                && $0.pathExtension == EventLogDefaults.crashReportExtension
        }

        let newest = ours.compactMap { url -> (URL, Date)? in
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified >= start else { return nil }
            return (url, modified)
        }.max { $0.1 < $1.1 }

        return newest?.0.path
    }

    // MARK: - Housekeeping

    /// Drops journals past the retention window. Runs once per launch, which is often enough
    /// for a file per day.
    private func pruneExpiredJournals() {
        let cutoff = Date().addingTimeInterval(-EventLogDefaults.retention)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for url in contents where url.pathExtension == EventLogDefaults.fileExtension {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else { continue }

            try? FileManager.default.removeItem(at: url)
        }
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
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
    static let queueLabel = "codes.threading.eventlog"

    /// Long enough to cover "it happened some time last week", short enough that the folder
    /// never needs managing.
    static let retention: TimeInterval = 14 * 24 * 60 * 60

    static let uncleanExitMessage = "Previous launch did not quit cleanly"

    /// Relative to `~/Library`.
    static let diagnosticReportsPath = "Logs/DiagnosticReports"
    static let crashReportPrefix = "Threading-"
    static let crashReportExtension = "ips"
}
