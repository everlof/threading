import Darwin
import Foundation

// MARK: - Events

/// Everything the daemon writes down, as a token.
///
/// Tokens rather than sentences, for the reason the error frame gives: these lines reach a
/// support report, so a line may carry an identifier, a pid and a number, and must never carry a
/// sentence somebody wrote or a path the user chose. `detail` is the one bounded exception, and
/// it holds a machine token — the guard clause that refused, the `errno` name.
enum PTYHostJournalEvent: String {
    case started
    case listening
    case stateLineSkipped
    case lostSession
    case lostSessionStillRunning
    case connectionOpened
    case connectionClosed
    case connectionRefused
    case frameRefused
    case backpressureClosed
    case inputDropped
    case spawned
    case spawnRefused
    case spawnFailed
    case attached
    case detached
    case resized
    case killRequested
    case killEscalated
    case exited
    case released
    case ringShrunk
    case ringBudgetOverridden
    case retiring
    case retired
}

// MARK: - Journal

/// The daemon's own log: one JSON object per line, in its own directory, pruned by itself.
///
/// Named for the file rather than for the frame, because `PTYHostJournal` is already the wire
/// type carrying a bounded tail of this file to the app.
///
/// **Its own directory is the point.** The app's journal prunes *any* `.jsonl` it finds in its
/// log directory past the retention window, so a daemon writing there would have its record
/// deleted by a process it cannot see; and the app's own journal descriptor is `O_APPEND`
/// precisely because more than one process writes it and interleaving has damaged it before.
/// The app reads a bounded tail of this file through a `journalTail` frame instead of sharing it.
///
/// Confined to the host queue: every call comes from there, so the file offset and the counters
/// need no lock of their own.
final class PTYHostJournalFile: @unchecked Sendable {

    // MARK: - Properties

    private let directory: URL
    private let mirrorsToStandardError: Bool
    private var descriptor: Int32 = -1
    private var openedDay: String?
    private var diagnosticsWritten = 0

    /// Bounded stderr mirroring, for a daemon started by hand. A daemon that flaps for an hour
    /// must not write a gigabyte of identical lines, so the stream is capped and says so once
    /// when it stops. The file itself is not capped — it is what the failure model reads.
    private static let maximumDiagnosticLines = 200

    // MARK: - Initialization

    init(directory: URL, mirrorsToStandardError: Bool = true) {
        self.directory = directory
        self.mirrorsToStandardError = mirrorsToStandardError
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    // MARK: - Public Methods

    /// Appends one line. Never throws and never fails loudly: a daemon that cannot write its log
    /// still holds working agents, and dropping the line is the smaller loss.
    func record(_ event: PTYHostJournalEvent, _ fields: [String: String] = [:]) {
        // Every value is bounded here rather than at each call site. One of them is a path the
        // user chose, and a journal line is a thing that reaches a support report.
        var object = fields.mapValues { value in
            value.utf8.count <= PTYHostDefaults.maximumJournalDetailBytes
                ? value
                : String(value.prefix(PTYHostDefaults.maximumJournalDetailBytes))
        }
        object[Key.event] = event.rawValue
        object[Key.at] = Self.timestamp.string(from: Date())
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return }

        var line = data
        line.append(Self.newline)
        write(line)
        mirror(event, object)
    }

    /// The last `maxBytes` of today's file, split into whole lines.
    ///
    /// Today's file only, and bounded twice — by the caller's ask and by the daemon's own cap —
    /// because this answer crosses the socket into a diagnostics view, and "the tail of the log"
    /// must not be a way to ask for the whole log.
    func tail(maxBytes: Int) -> [String] {
        let bound = min(max(maxBytes, 0), PTYHostDefaults.maximumJournalTailBytes)
        guard bound > 0 else { return [] }
        let url = fileURL(for: Self.day.string(from: Date()))
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(bound) ? end - UInt64(bound) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        // A tail taken by byte offset begins mid-line unless it began at the file's start.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Deletes journal files older than the retention window. Called once at startup: the daemon
    /// is long-lived but its files are per-day, so there is nothing to prune between midnights
    /// that will not be pruned at the next start.
    func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(
            -Double(PTYHostDefaults.journalRetentionDays) * 24 * 60 * 60
        )
        let cutoffDay = Self.day.string(from: cutoff)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(PTYHostDefaults.journalFilePrefix),
                  name.hasSuffix(PTYHostDefaults.journalFileSuffix) else { continue }
            let day = String(
                name.dropFirst(PTYHostDefaults.journalFilePrefix.count)
                    .dropLast(PTYHostDefaults.journalFileSuffix.count)
            )
            guard day < cutoffDay else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Private Methods

    private enum Key {
        static let event = "event"
        static let at = "at"
    }

    private static let newline = Data([0x0A])

    /// Confined to the host queue with everything else in this file; the annotation says so
    /// rather than paying for a formatter per line.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func fileURL(for day: String) -> URL {
        directory.appendingPathComponent(
            PTYHostDefaults.journalFilePrefix + day + PTYHostDefaults.journalFileSuffix
        )
    }

    /// Opens today's file, rolling over when the day changes under a long-lived daemon.
    ///
    /// `O_APPEND` so every write lands at the end whatever else holds the file open, and
    /// `O_CLOEXEC` because this daemon is about to become the parent of agent CLIs — ten of them
    /// once inherited the app's lock descriptor and held it open long after the app was gone.
    private func write(_ line: Data) {
        let today = Self.day.string(from: Date())
        if openedDay != today || descriptor < 0 {
            if descriptor >= 0 { close(descriptor) }
            descriptor = open(
                fileURL(for: today).path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                PTYHostDefaults.filePermissions
            )
            openedDay = descriptor >= 0 ? today : nil
        }
        guard descriptor >= 0 else { return }

        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                return
            }
        }
    }

    private func mirror(_ event: PTYHostJournalEvent, _ object: [String: String]) {
        guard mirrorsToStandardError, diagnosticsWritten < Self.maximumDiagnosticLines else {
            return
        }
        diagnosticsWritten += 1
        let suffix = diagnosticsWritten == Self.maximumDiagnosticLines
            ? " (further diagnostics suppressed)"
            : ""
        let fields = object
            .filter { $0.key != Key.event && $0.key != Key.at }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        FileHandle.standardError.write(
            Data("threading-ptyd: \(event.rawValue) \(fields)\(suffix)\n".utf8)
        )
    }
}
