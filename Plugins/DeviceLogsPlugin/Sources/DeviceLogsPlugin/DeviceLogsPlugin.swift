import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

// MARK: - Constants

enum LogStreamDefaults {
    /// Rows held for display. A log is unbounded and a table is not: the oldest go first, and the
    /// count of what was dropped is not hidden.
    static let rowCapacity = 20_000
    /// Rows drained onto the main thread per tick. The stream arrives faster than a table can be
    /// asked to redraw, so it is coalesced rather than followed line by line.
    static let drainInterval: TimeInterval = 0.1
    static let rowHeight: CGFloat = 16
    static let timeColumnWidth: CGFloat = 82
    static let processColumnWidth: CGFloat = 150
    static let messageColumnMinimumWidth: CGFloat = 320
    static let filterWidth: CGFloat = 180
}

// MARK: - A row

struct LogRow {
    let time: String
    let level: String
    let process: String
    let message: String
}

// MARK: - The source

/// One `log stream` process, decoded off the main thread.
///
/// The bound is on the buffer rather than on the reader: `log stream` does not stop because a
/// table is busy, so the handoff drops the oldest rows and says how many.
final class LogStreamSource {

    private let process = Process()
    private let queue = DispatchQueue(label: "codes.threading.plugin.devicelogs.reader")
    private var pending: [LogRow] = []
    private let lock = NSLock()
    private(set) var dropped = 0

    let title: String
    private let arguments: [String]

    init(title: String, arguments: [String]) {
        self.title = title
        self.arguments = arguments
    }

    func start() {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.decode(data) }
        }
        try? process.run()
    }

    func stop() {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    /// Takes everything buffered so far, and reports nothing twice.
    func drain() -> [LogRow] {
        lock.lock(); defer { lock.unlock() }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        return rows
    }

    private var carry = Data()

    private func decode(_ data: Data) {
        carry.append(data)
        var rows: [LogRow] = []
        while let newline = carry.firstIndex(of: UInt8(ascii: "\n")) {
            let line = carry[carry.startIndex..<newline]
            carry = carry[carry.index(after: newline)...]
            if let row = Self.row(from: line) { rows.append(row) }
        }
        guard !rows.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: rows)
        if pending.count > LogStreamDefaults.rowCapacity {
            let excess = pending.count - LogStreamDefaults.rowCapacity
            pending.removeFirst(excess)
            dropped += excess
        }
        lock.unlock()
    }

    /// `log stream --style=ndjson` writes one JSON object per line, plus a preamble line that is
    /// not one. A line that does not decode is skipped rather than guessed at.
    static func row(from line: Data) -> LogRow? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["eventMessage"] as? String else { return nil }
        let stamp = object["timestamp"] as? String ?? ""
        let time = stamp.count >= 23 ? String(stamp.dropFirst(11).prefix(12)) : "--:--:--"
        let path = object["processImagePath"] as? String ?? ""
        return LogRow(
            time: time,
            level: object["messageType"] as? String ?? "Default",
            process: (path as NSString).lastPathComponent,
            message: message
        )
    }
}
