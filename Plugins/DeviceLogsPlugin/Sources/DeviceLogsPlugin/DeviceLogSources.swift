import Darwin
import Foundation
import ThreadingDesignKit
import ThreadingPluginKit
import TimberLineParser

// MARK: - Row

/// The origin the transport can actually distinguish. A merged console is deliberately distinct
/// from stdout and stderr: observing a system log is never evidence that stdout was captured.
public enum DeviceLogRecordSource: String, Codable, CaseIterable, Sendable {
    case system, stdout, stderr, console, appLog, bluetooth, unknown
}

public struct DeviceLogCaptureAvailability: Equatable, Sendable {
    public let availableSources: [DeviceLogRecordSource]
    public let unavailableSources: [DeviceLogRecordSource]
    public let detail: String
}

/// One log line, kept as a value.
///
/// Externally sized content never becomes a view until the table asks for the row that holds it,
/// which is the whole reason this is a value and the pane is a table. See
/// [`device-and-simulator-logs.md`](../../../../docs/feature-drafts/device-and-simulator-logs.md).
public struct DeviceLogRow: Sendable {
    /// Assigned once when decoded, and retained by projection, recording and subsequent reads.
    public let id: String
    public let time: String
    public let level: String
    public let process: String
    public let processPath: String?
    /// The original subsystem; category remains a separate field for exact filtering.
    public let subsystem: String?
    public let category: String?
    public let message: String
    public let rawLine: String
    public let deviceID: String?
    public let bundleID: String?
    public let pid: Int?
    public let source: DeviceLogRecordSource

    /// Conservative payload accounting for aggregate stream budgets. Shared String storage may
    /// use less memory, but the bound never depends on that implementation detail or deduplication.
    public var estimatedRetainedBytes: Int {
        let fixedMetadataBytes = 256
        return fixedMetadataBytes + id.utf8.count + time.utf8.count + level.utf8.count
            + process.utf8.count + (processPath?.utf8.count ?? 0)
            + (subsystem?.utf8.count ?? 0) + (category?.utf8.count ?? 0)
            + message.utf8.count + rawLine.utf8.count + (deviceID?.utf8.count ?? 0)
            + (bundleID?.utf8.count ?? 0) + (link?.utf8.count ?? 0)
    }

    public var subsystemLabel: String? {
        let parts = [subsystem, category].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// When the line was written, as an instant.
    ///
    /// Separate from `time` on purpose, and they answer different questions. `time` is the
    /// characters the file wrote, which is what a reader checking a timestamp wants. This is an
    /// instant that sorts and subtracts, which is what a range query wants — "everything between
    /// 14:02 and 14:05", the shape an agent asks in.
    ///
    /// `nil` when the line carries no stamp at all: a file's opening banner, a continuation line.
    /// A stamp naming no zone is read as UTC by convention; see `TimestampParser`.
    public let timestamp: Date?

    /// A Bluetooth app packet's link for `logs:` rules (characteristic, operation, key values);
    /// nil for every other row. See `BluetoothLogLink`.
    public var link: String?

    public init(
        time: String,
        level: String,
        process: String,
        subsystem: String?,
        message: String,
        timestamp: Date? = nil,
        link: String? = nil,
        id: String = UUID().uuidString,
        deviceID: String? = nil,
        bundleID: String? = nil,
        pid: Int? = nil,
        category: String? = nil,
        source: DeviceLogRecordSource = .unknown,
        rawLine: String? = nil,
        processPath: String? = nil
    ) {
        self.id = id
        self.link = link
        self.time = time
        self.level = level
        self.process = process
        self.processPath = processPath
        self.subsystem = subsystem
        self.message = message
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.bundleID = bundleID
        self.pid = pid
        self.category = category
        self.source = source
        self.rawLine = rawLine ?? message
    }

    func withCaptureContext(deviceID: String?, bundleID: String?, source: DeviceLogRecordSource?) -> Self {
        Self(time: time, level: level, process: process, subsystem: subsystem, message: message,
             timestamp: timestamp, link: link, id: id, deviceID: self.deviceID ?? deviceID,
             bundleID: self.bundleID ?? bundleID, pid: pid, category: category,
             source: source ?? self.source, rawLine: rawLine, processPath: processPath)
    }

    /// Ordering for the level filter. `log` and the syslog relay use different vocabularies for
    /// the same idea, so both are mapped here rather than at each call site.
    public var severity: Int {
        switch level {
        case "Fault", "Emergency", "Alert", "Critical": return 4
        case "Error": return 3
        case "Default", "Notice", "Warning": return 2
        case "Info": return 1
        default: return 0
        }
    }
}

// MARK: - Source contract

/// Somewhere log rows come from.
///
/// Sources hand rows over in batches rather than calling back per row: the pane drains on a timer,
/// so one batch of main-thread work happens per tick no matter how fast the source runs.
public protocol DeviceLogRowSource: AnyObject {
    func start()
    func stop()
    /// Everything produced since the last drain.
    func drain() -> [DeviceLogRow]
    /// Rows produced but never collected because the handoff was full. A drop is the honest signal
    /// that the consumer is behind; growing the buffer would only hide it in memory.
    var dropped: Int { get }
    /// Valid transport input before severity/process filtering. A selected app can be quiet while
    /// the phone's reader is healthy; admitted rows alone cannot distinguish those conditions.
    var lastTransportActivity: Date? { get }
    /// Called once, off the main thread, when the source stops producing on its own.
    ///
    /// A reader that has died looks exactly like a device that has gone quiet, and the pane cannot
    /// tell them apart without being told. Not called for `stop()`, which the pane asked for.
    var onStreamEnded: ((String) -> Void)? { get set }
}

public extension DeviceLogRowSource {
    var lastTransportActivity: Date? { nil }
}

/// Shared batching and bounded handoff. Every source is a producer on its own queue and the pane
/// is a consumer on the main one; this is the only place that boundary is implemented.
public class BufferedDeviceLogSource: DeviceLogRowSource {
    public static let handoffCapacity = 20_000
    public static let handoffByteCapacity = 16 * 1_048_576

    private var pending: [DeviceLogRow] = []
    private var pendingBytes = 0
    private var transportActivity: Date?
    private let lock = NSLock()
    private var droppedCount = 0
    private let captureDeviceID: String?
    private let captureBundleID: String?
    private let captureSource: DeviceLogRecordSource?
    private let captureIdentity: DeviceLogProcessIdentity?

    public init(deviceID: String? = nil, bundleID: String? = nil, source: DeviceLogRecordSource? = nil,
                processIdentity: DeviceLogProcessIdentity? = nil) {
        captureDeviceID = deviceID
        captureBundleID = bundleID
        captureSource = source
        captureIdentity = processIdentity
    }

    public var onStreamEnded: ((String) -> Void)?

    public var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }

    public var lastTransportActivity: Date? {
        lock.lock()
        defer { lock.unlock() }
        return transportActivity
    }

    public func markTransportActivity() {
        lock.lock()
        transportActivity = Date()
        lock.unlock()
    }

    public func start() { resetTransportActivity() }
    public func stop() {}

    public func resetTransportActivity() {
        lock.lock()
        transportActivity = nil
        lock.unlock()
    }

    public func drain() -> [DeviceLogRow] {
        lock.lock()
        defer { lock.unlock() }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        return rows
    }

    public func enqueue(_ rows: [DeviceLogRow]) {
        guard !rows.isEmpty else { return }
        markTransportActivity()
        let matchingRows = captureIdentity.map { identity in rows.filter(identity.matches) } ?? rows
        let rows = captureDeviceID != nil || captureBundleID != nil || captureSource != nil
            ? matchingRows.map { row in
                let bundleID = captureIdentity.map { $0.provesBundleIdentity(of: row) ? captureBundleID : nil } ?? captureBundleID
                return row.withCaptureContext(deviceID: captureDeviceID, bundleID: bundleID, source: captureSource)
            }
            : matchingRows
        lock.lock()
        for row in rows {
            let bytes = row.estimatedRetainedBytes
            guard pending.count < Self.handoffCapacity,
                  bytes <= Self.handoffByteCapacity - pendingBytes else {
                droppedCount += 1
                continue
            }
            pending.append(row)
            pendingBytes += bytes
        }
        lock.unlock()
    }

    public func enqueue(_ row: DeviceLogRow) { enqueue([row]) }
}

// MARK: - Process plumbing

/// Runs a command and hands whole stdout lines to a parser, off the main thread.
///
/// A partial tail waits for the next chunk; an absurdly long line is dropped rather than grown
/// without limit, because a log source is externally sized and one pathological line must not
/// become unbounded memory.
/// Ties a long-lived reader to Threading's lifetime, however Threading ends.
///
/// A reader started with `Process` outlives a Threading that quits, crashes or is replaced by an
/// update: macOS has no parent-death signal, and `idevicebtlogger` ignores `SIGPIPE`, so writing
/// into a pipe nobody reads does not stop it. The orphan then keeps the phone's Bluetooth log
/// relay, and the next Threading's capture receives nothing — an update in the middle of a
/// firmware-update test showed exactly that, with every packet the user produced missing.
///
/// So the reader runs under a small `/bin/sh` tether whose standard input is a pipe only Threading
/// holds the write end of. A watcher in the tether blocks reading it; when Threading ends in any
/// way the kernel closes that end, the read returns, and the watcher ends the reader. Stopping
/// closes the end too, so a tether that had to be killed outright still takes its reader with
/// it. The reader's own exit status passes through unchanged.
enum TetheredReader {
    static let shell = "/bin/sh"

    /// `$@` is the reader and its arguments. Descriptor 3 is the tether, kept from the reader.
    static let script = #"""
        exec 3<&0
        "$@" </dev/null 3<&- &
        reader=$!
        ( read -r _ <&3; kill "$reader" 2>/dev/null; sleep 1; kill -9 "$reader" 2>/dev/null ) </dev/null &
        watcher=$!
        exec 3<&-
        trap 'kill "$reader" 2>/dev/null; kill "$watcher" 2>/dev/null; wait "$reader"; exit 143' TERM INT HUP
        wait "$reader"
        status=$?
        kill "$watcher" 2>/dev/null
        exit "$status"
        """#

    /// Points `task` at the tether running `executable` with `arguments`, and returns the handle
    /// Threading must keep: closing it — or Threading ending — ends the reader.
    static func configure(_ task: Process, executable: String, arguments: [String]) -> FileHandle {
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-c", script, "threading-reader", executable] + arguments
        let tether = Pipe()
        task.standardInput = tether
        // Only the tether may hold this end. Without close-on-exec, every process Threading starts
        // afterwards — terminals, agents, the PTY host — would inherit it and keep the reader alive.
        let writeEnd = tether.fileHandleForWriting
        _ = fcntl(writeEnd.fileDescriptor, F_SETFD, FD_CLOEXEC)
        return writeEnd
    }
}

public final class DeviceLogLineReader {
    private let queue: DispatchQueue
    private var process: Process?
    /// Threading's end of the reader's tether; see `TetheredReader`.
    private var tether: FileHandle?

    public init(label: String) {
        queue = DispatchQueue(label: "codes.threading.devicelog.\(label)")
    }

    /// The last of the child's diagnostics, kept so an exit can say why.
    ///
    /// Bounded, and deliberately small: this exists to carry one sentence such as "device is
    /// locked" or "application is not installed" into the pane's status line, not to mirror a
    /// second log stream into memory.
    public static let retainedErrorBytes = 4096

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onLine: @escaping (ArraySlice<UInt8>) -> Void,
        onEnd: ((String) -> Void)? = nil
    ) {
        stop()
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            onEnd?("\(executable) is not available on this Mac")
            return
        }
        let task = Process()
        let tether = TetheredReader.configure(task, executable: executable, arguments: arguments)
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        // Diagnostics used to go to /dev/null, so a device that was locked, an app that was not
        // installed, or a launch that simply failed all produced the same thing: silence, and a
        // pane that looked like it was listening.
        let errors = Pipe()
        task.standardError = errors
        let diagnostics = DiagnosticsBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnostics.append(chunk, limit: Self.retainedErrorBytes)
            }
        }
        let ending = onEnd.map(DeviceLogEndCallback.init)
        let deliveryQueue = queue
        task.terminationHandler = { finished in
            errors.fileHandleForReading.readabilityHandler = nil
            guard let ending else { return }
            let reason = diagnostics.text()
            let message = reason.isEmpty
                ? "the reader exited with status \(finished.terminationStatus)"
                : reason
            // EOF/exit races the stdout reader. Deliver the ending after all queued line
            // callbacks, or the structured route can fall back before seeing its first row.
            deliveryQueue.async { ending.call(message) }
        }
        process = task
        self.tether = tether

        queue.async {
            var buffer = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    onLine(ArraySlice(line))
                }
                if buffer.count > DeviceLogLimits.maximumLineBytes {
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        do {
            try task.run()
        } catch {
            task.terminationHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            onEnd?("could not start the reader: \(error.localizedDescription)")
        }
    }

    public func stop() {
        // A stop the pane asked for is not an ending worth reporting; clearing the handler first
        // is what keeps "you asked me to" out of the status line.
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        try? tether?.close()
        tether = nil
    }

    /// A reader released without `stop()` would otherwise leave its child running, and for the
    /// device relay that is not a tidy-up detail: see `DeviceRelayReclaim`.
    deinit {
        process?.terminationHandler = nil
        process?.terminate()
        try? tether?.close()
    }
}

/// `Process` invokes its termination handler on an arbitrary queue. The reader's public contract
/// already promises that `onEnd` runs off the main thread; this wrapper makes that established
/// boundary explicit to Swift's concurrency checker without changing the callback's executor.
private final class DeviceLogEndCallback: @unchecked Sendable {
    private let body: (String) -> Void

    init(_ body: @escaping (String) -> Void) {
        self.body = body
    }

    func call(_ reason: String) {
        body(reason)
    }
}

/// A small, locked tail of a child's diagnostics.
private final class DiagnosticsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data, limit: Int) {
        lock.lock()
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
        lock.unlock()
    }

    /// The last non-empty line, which is where a command-line tool puts the reason.
    func text() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }
}

/// Reclaims log readers this Mac leaked onto a device.
///
/// `com.apple.os_trace_relay` behaves as a single-client service: a second reader connects, is
/// acknowledged, and then receives nothing at all. So one abandoned `idevicesyslog` silently
/// poisons the device source for every later reader, with no error anywhere to say why.
///
/// This is not hypothetical. Three orphans accumulated during development — one from the previous
/// evening, two from a morning's test runs — and the resulting silence was diagnosed as a broken
/// device, which sent the whole feature down a redesign around archive pulls. Killing them restored
/// streaming immediately.
///
/// Only *orphans* are reclaimed: a process whose parent is `launchd` and whose arguments name this
/// exact tool and device. A reader the user started in their own terminal has their shell as its
/// parent and is left alone.
public enum DeviceRelayReclaim {

    @discardableResult
    public static func reclaimOrphanedReaders(udid: String, toolPath: String) -> Int {
        guard !udid.isEmpty, !toolPath.isEmpty else { return 0 }
        let resolvedPath = URL(fileURLWithPath: toolPath).resolvingSymlinksInPath().path
        let candidates = candidates(toolPath: resolvedPath)
        guard !candidates.isEmpty,
              let result = BoundedDeviceLogCommand.runResult(
                "/bin/ps", ["-p", candidates.map { String($0.pid) }.joined(separator: ","), "-o", "pid=,ppid=,args="],
                deadline: 0.5, maximumOutputBytes: 32 * 1_024
              ), result.exitStatus == 0 else { return 0 }
        let matches = Set(orphanPIDs(in: result.output, udid: udid, toolPath: toolPath)
            + orphanPIDs(in: result.output, udid: udid, toolPath: resolvedPath))
        var reclaimed = 0
        for candidate in candidates where matches.contains(candidate.pid) {
            // A pid may have been recycled during the bounded argv lookup. Revalidate its
            // kernel identity, owner, parent and executable before sending any signal.
            guard identity(pid: candidate.pid, toolPath: resolvedPath) == candidate else { continue }
            if kill(candidate.pid, SIGTERM) == 0 { reclaimed += 1 }
        }
        return reclaimed
    }

    /// Which rows from a scoped `ps -p <candidates> -o pid=,ppid=,args=` name an abandoned reader.
    ///
    /// Pure so the rule can be tested without killing anything, because the rule is the whole
    /// safety of this: too loose and it kills a reader the user is running on purpose.
    public static func orphanPIDs(in listing: String, udid: String, toolPath: String) -> [pid_t] {
        guard !udid.isEmpty, !toolPath.isEmpty else { return [] }
        return listing.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let parent = pid_t(fields[1]),
                  // Orphaned to launchd: its owner is gone, so nobody is reading it.
                  parent == 1,
                  pid != getpid(),
                  fields[2] == Substring(toolPath),
                  fields.indices.dropLast().contains(where: { index in
                      (fields[index] == "-u" || fields[index] == "--udid") && fields[index + 1] == Substring(udid)
                  })
            else { return nil }
            return pid
        }
    }

    private struct Identity: Equatable {
        let pid: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }

    /// Numeric inventory first; argv is never requested for unrelated processes. A global
    /// argv scan hung for 98–217 seconds on the reported machine, holding source teardown.
    private static func candidates(toolPath: String) -> [Identity] {
        let capacity = min(65_536, max(256, Int(proc_listallpids(nil, 0)) + 256))
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let deadline = DispatchTime.now() + .milliseconds(250)
        var result: [Identity] = []
        for pid in pids.prefix(min(count, capacity)) where pid > 0 && pid != getpid() {
            guard DispatchTime.now() < deadline, result.count < 32 else { break }
            if let candidate = identity(pid: pid, toolPath: toolPath) { result.append(candidate) }
        }
        return result
    }

    private static func identity(pid: pid_t, toolPath: String) -> Identity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_ppid == 1, info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro Swift cannot import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == toolPath else { return nil }
        return Identity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

public enum DeviceLogLimits {

    /// What the time column shows for a line that carries no stamp — a file's opening banner,
    /// or a continuation. Written once because two decoders and the fallback all compare it.
    public static let undatedTime = "--:--:--"

    /// Rows kept either side of a match when the rest is folded. Two is what makes a failure
    /// readable — the line before it is usually the cause.
    public static let foldContext = 2

    /// A single line longer than this is abandoned rather than accumulated.
    public static let maximumLineBytes = 1_048_576
    /// Rows retained by the pane. A firehose must not grow memory without limit.
    public static let ringCapacity = 50_000
    /// How long a discovery command may take before its answer is abandoned.
    public static let discoveryDeadline: TimeInterval = 6
    /// Discovery output is metadata, not a log stream. A tool returning more than this is either
    /// the wrong command or a changed protocol, and must not grow the plugin without limit.
    public static let maximumDiscoveryOutputBytes = 8 * 1_048_576
    /// Listing a device's apps talks to the device rather than to a local service, so it is given
    /// its own longer deadline. It still has one: a phone that stops answering must not stall a
    /// rescan.
    public static let appListDeadline: TimeInterval = 25
    /// Apps offered per device. Their own developer builds, so the list is short in practice.
    public static let maximumApps = 40
    public static let maximumMachines = 16
    public static let maximumProcesses = 256
    public static let maximumCatalogEntries = 16_384
    /// Listing or copying inside an app container talks to the device over its own transport, so
    /// it gets a longer leash than a local `simctl` call — and still a deadline.
    public static let containerDeadline: TimeInterval = 40
}

/// Runs one finite command on the discovery worker with a nonblocking, byte-bounded pipe drain.
/// The same worker owns reading and closing: a queued background reader must never outlive the
/// deadline and start using a FileHandle the caller has already closed.
enum BoundedDeviceLogCommand {
    private static let terminationGrace: TimeInterval = 0.5

    struct Result: Sendable {
        let output: String
        let exitStatus: Int32
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        deadline seconds: TimeInterval = DeviceLogLimits.discoveryDeadline
    ) -> String? {
        runResult(executable, arguments, deadline: seconds)?.output
    }

    static func runResult(
        _ executable: String,
        _ arguments: [String],
        deadline seconds: TimeInterval = DeviceLogLimits.discoveryDeadline,
        environment: [String: String]? = nil,
        includeStandardError: Bool = false,
        maximumOutputBytes: Int = DeviceLogLimits.maximumDiscoveryOutputBytes
    ) -> Result? {
        guard seconds.isFinite, seconds > 0,
              FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = environment
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        task.standardOutput = pipe
        task.standardError = includeStandardError ? pipe : FileHandle.nullDevice

        let processFinished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in processFinished.signal() }
        guard (try? task.run()) != nil else { return nil }
        try? pipe.fileHandleForWriting.close()

        var output = BoundedDeviceLogCommandOutput(maximumBytes: maximumOutputBytes)
        var buffer = [UInt8](repeating: 0, count: 32 * 1_024)
        var expiresAt = DispatchTime.now() + seconds
        var exited = false
        while DispatchTime.now() < expiresAt {
            switch output.drainAvailable(from: descriptor, buffer: &buffer) {
            case .failed:
                stop(task, processFinished: processFinished)
                return nil
            case .ended:
                if exited || processFinished.wait(timeout: expiresAt) == .success {
                    return output.text().map { Result(output: $0, exitStatus: task.terminationStatus) }
                }
                stop(task, processFinished: processFinished)
                return nil
            case .open:
                break
            }
            if !exited, processFinished.wait(timeout: .now()) == .success {
                exited = true
                // A descendant may retain stdout after the direct child exits. That pipe must
                // not keep discovery, or a second background reader, alive indefinitely.
                expiresAt = min(expiresAt, .now() + terminationGrace)
            }
            let now = DispatchTime.now()
            guard now < expiresAt else { break }
            let remaining = (expiresAt.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&readiness, 1, Int32(min(50, max(1, remaining))))
        }
        if !exited { stop(task, processFinished: processFinished) }
        return nil
    }

    private static func stop(_ task: Process, processFinished: DispatchSemaphore) {
        guard task.isRunning else { return }
        task.terminate()
        guard processFinished.wait(timeout: .now() + terminationGrace) != .success,
              task.isRunning
        else { return }

        _ = Darwin.kill(task.processIdentifier, SIGKILL)
        _ = processFinished.wait(timeout: .now() + terminationGrace)
    }
}

private struct BoundedDeviceLogCommandOutput {
    enum PipeState { case open, ended, failed }

    let maximumBytes: Int
    private var data = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func drainAvailable(from descriptor: Int32, buffer: inout [UInt8]) -> PipeState {
        // Check the process deadline after at most 256 KiB, even for a continuously writable child.
        for _ in 0..<8 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                append(buffer.prefix(count))
            } else if count == 0 {
                return .ended
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return .open
            } else if errno != EINTR {
                return .failed
            }
        }
        return .open
    }

    func text() -> String? {
        guard !exceededLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private mutating func append(_ chunk: ArraySlice<UInt8>) {
        guard !exceededLimit else { return }
        guard data.count + chunk.count <= maximumBytes else {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return
        }
        data.append(contentsOf: chunk)
    }
}

// MARK: - Simulator

/// `log stream --style=ndjson` from a booted simulator.
///
/// The predicate is pushed into the command rather than applied here, so the log daemon bounds the
/// scan. Filtering in this process would bound only the result.
public final class SimulatorLogRowSource: BufferedDeviceLogSource {
    private let reader = DeviceLogLineReader(label: "simulator")
    private let udid: String
    private let predicate: String?
    private let minimumSeverity: Int

    public init(udid: String, predicate: String?, minimumSeverity: Int = 0, bundleID: String? = nil,
                processIdentity: DeviceLogProcessIdentity? = nil) {
        self.udid = udid
        self.predicate = predicate
        self.minimumSeverity = minimumSeverity
        super.init(deviceID: udid, bundleID: bundleID, processIdentity: processIdentity)
    }

    var arguments: [String] {
        var arguments = [
            "simctl", "spawn", udid, "log", "stream", "--style=ndjson",
            "--level=\(Self.streamLevel(atLeast: minimumSeverity))",
        ]
        if let predicate, !predicate.isEmpty {
            arguments.append(contentsOf: ["--predicate", predicate])
        }
        return arguments
    }

    /// `log stream` produces Debug and Info only when asked, so a level the pane would hide is
    /// never read — the same reason the predicate is pushed into the command.
    static func streamLevel(atLeast severity: Int) -> String {
        switch severity {
        case ...0: return "debug"
        case 1: return "info"
        default: return "default"
        }
    }

    public override func start() {
        resetTransportActivity()
        reader.run(
            executable: "/usr/bin/xcrun",
            arguments: arguments,
            onLine: { [weak self] line in
                if let row = DeviceLogDecoding.ndjson(line) { self?.enqueue(row) }
            },
            onEnd: { [weak self] reason in self?.onStreamEnded?(reason) }
        )
    }

    public override func stop() { reader.stop() }
}

// MARK: - Real device

/// Cancels queued launches immediately without waiting for transport work on the lifecycle queue.
private final class DeviceLogLifecycleGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func contains(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }
}

/// `idevicesyslog` from a paired iPhone.
///
/// Text rather than NDJSON: the syslog relay flattens the unified log, so this is the one source
/// whose rows are parsed out of prose and the one with no subsystem. Whatever the device redacts
/// (`<private>`) stays redacted; only the app's own tap can publish those values, and it does so as
/// ordinary `os_log` entries which arrive here like any other line.
///
/// The tool is libimobiledevice's, never bundled, resolved on the user's `PATH`.
public final class PairedDeviceLogRowSource: BufferedDeviceLogSource, @unchecked Sendable {
    private let processName: String?
    /// The relay has no level option, so rows below the pane's level are dropped as they are
    /// decoded rather than queued, kept in the ring and recorded only to be hidden.
    private let minimumSeverity: Int
    private let reader = DeviceLogLineReader(label: "device")
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String
    private let lifecycle = DispatchQueue(label: "codes.threading.devicelog.legacy-lifecycle")
    private let generation = DeviceLogLifecycleGeneration()
    // Configure before start; the lifecycle queue owns this callback and the reader thereafter.
    var reclaimRelay: @Sendable (String, String) -> Void = { device, path in
        DeviceRelayReclaim.reclaimOrphanedReaders(udid: device, toolPath: path)
    }

    public init(udid: String, overNetwork: Bool, toolPath: String, processName: String? = nil, minimumSeverity: Int = 0, bundleID: String? = nil,
                processIdentity: DeviceLogProcessIdentity? = nil) {
        self.processName = processName
        self.minimumSeverity = minimumSeverity
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
        super.init(deviceID: udid, bundleID: bundleID, processIdentity: processIdentity)
    }

    public override func start() {
        resetTransportActivity()
        let request = generation.advance()
        lifecycle.async { [self] in startOnQueue(request: request) }
    }

    private func startOnQueue(request: Int) {
        guard generation.contains(request) else { return }
        // A reader we abandoned earlier still holds the relay, and the symptom is silence rather
        // than an error. Reclaim before connecting, or this source starts already broken.
        reclaimRelay(udid, toolPath)
        guard generation.contains(request) else { return }
        var arguments = ["-u", udid, "--no-colors"]
        if overNetwork { arguments.append("-n") }
        reader.run(
            executable: toolPath,
            arguments: arguments,
            onLine: { [weak self] line in
                if let self, self.generation.contains(request), let row = DeviceLogDecoding.syslog(line) {
                    self.markTransportActivity()
                    if row.severity >= self.minimumSeverity,
                   self.processName == nil || row.process == self.processName { self.enqueue(row) }
                }
            },
            onEnd: { [weak self] reason in
                guard let self, self.generation.contains(request) else { return }
                self.onStreamEnded?(reason)
            }
        )
    }

    public override func stop() {
        let request = generation.advance()
        lifecycle.async { [self] in
            guard generation.contains(request) else { return }
            reader.stop()
        }
    }
}

/// Structured unified-log entries from a paired iPhone through `pymobiledevice3`'s native RSD
/// route.
///
/// This is the live shape Apple's own console makes useful: process, level, message and the real
/// subsystem/category label arrive as data rather than prose. `--native` piggybacks the tunnel
/// macOS already owns, so it needs neither root nor a long-running tunnel helper. The executable
/// remains an external developer tool and is never bundled with Threading.
///
/// A phone older than iOS 17, or a native route that becomes unavailable, produces no structured
/// rows. In that case this source starts the existing `idevicesyslog` reader automatically rather
/// than turning an installed optional tool into a regression.
public final class StructuredPairedDeviceLogRowSource: BufferedDeviceLogSource, @unchecked Sendable {
    private let processName: String?
    private let minimumSeverity: Int
    private let structuredReader = DeviceLogLineReader(label: "device-structured")
    private let deviceServices: (any PluginDeviceServices)?
    private var hostStream: (any PluginDeviceLogStream)?
    private let fallbackReader = DeviceLogLineReader(label: "device-fallback")
    private let lifecycle = DispatchQueue(label: "codes.threading.devicelog.device-lifecycle")
    private let generation = DeviceLogLifecycleGeneration()
    private let decodedLock = NSLock()
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String?
    private let fallbackToolPath: String?
    private let structuredStartupDeadline: TimeInterval
    private var fallbackTimer: DispatchSourceTimer?
    private var stopped = true
    private var fallbackStarted = false
    private var decodedStructuredRows = 0
    var reclaimRelay: @Sendable (String, String) -> Void = { device, path in
        DeviceRelayReclaim.reclaimOrphanedReaders(udid: device, toolPath: path)
    }

    public init(
        udid: String,
        overNetwork: Bool,
        toolPath: String,
        fallbackToolPath: String?,
        structuredStartupDeadline: TimeInterval = 6,
        processName: String? = nil,
        minimumSeverity: Int = 0,
        bundleID: String? = nil,
        processIdentity: DeviceLogProcessIdentity? = nil
    ) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
        self.deviceServices = nil
        self.fallbackToolPath = fallbackToolPath
        self.structuredStartupDeadline = structuredStartupDeadline
        self.processName = processName
        self.minimumSeverity = minimumSeverity
        super.init(deviceID: udid, bundleID: bundleID, processIdentity: processIdentity)
    }

    public init(
        udid: String,
        overNetwork: Bool,
        deviceServices: any PluginDeviceServices,
        fallbackToolPath: String?,
        structuredStartupDeadline: TimeInterval = 6,
        processName: String? = nil,
        minimumSeverity: Int = 0,
        bundleID: String? = nil,
        processIdentity: DeviceLogProcessIdentity? = nil
    ) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = nil
        self.deviceServices = deviceServices
        self.fallbackToolPath = fallbackToolPath
        self.structuredStartupDeadline = structuredStartupDeadline
        self.processName = processName
        self.minimumSeverity = minimumSeverity
        super.init(deviceID: udid, bundleID: bundleID, processIdentity: processIdentity)
    }

    var structuredArguments: [String] {
        ["--no-color", "syslog", "live", "--native", "--format", "json"]
            + Self.levelArguments(atLeast: minimumSeverity)
    }

    /// The phone's Debug stream is most of what it sends: about 78% of 2,237 rows/s from an
    /// iPhone 16 Pro on 2026-10-18. These clear the stream flags the phone is asked for, so a level
    /// the pane would hide is never produced, sent, decoded, queued or recorded. Both flags exist
    /// in 11.13.1, the oldest version this route accepts.
    static func levelArguments(atLeast severity: Int) -> [String] {
        (severity >= 1 ? ["--no-debug"] : []) + (severity >= 2 ? ["--no-info"] : [])
    }

    public override func start() {
        resetTransportActivity()
        let request = generation.advance()
        lifecycle.async { [self] in
            guard generation.contains(request) else { return }
            structuredReader.stop()
            hostStream?.stop()
            hostStream = nil
            fallbackReader.stop()
            stopped = false
            fallbackStarted = false
            setDecodedStructuredRows(0)
            startStructuredReader(request: request)
            scheduleFallbackIfSilent(request: request)
        }
    }

    public override func stop() {
        let request = generation.advance()
        lifecycle.async { [self] in
            guard generation.contains(request) else { return }
            stopped = true
            cancelFallbackTimer()
            structuredReader.stop()
            hostStream?.stop()
            hostStream = nil
            fallbackReader.stop()
        }
    }

    /// Visible to the opt-in hardware test without exposing transport details to the pane.
    public var didDecodeStructuredRow: Bool {
        decodedLock.lock()
        defer { decodedLock.unlock() }
        return decodedStructuredRows > 0
    }

    private func startStructuredReader(request: Int) {
        if let deviceServices {
            hostStream = deviceServices.startStructuredSystemLog(
                deviceID: udid,
                minimumSeverity: minimumSeverity,
                onLine: { [weak self] line in
                    self?.receiveStructuredLine(ArraySlice(line), request: request)
                },
                onEnd: { [weak self] reason in
                    self?.structuredReaderEnded(reason: reason, request: request)
                }
            )
            if hostStream == nil {
                structuredReaderEnded(reason: "structured device log unavailable", request: request)
            }
            return
        }
        guard let toolPath else {
            structuredReaderEnded(reason: "structured device log unavailable", request: request)
            return
        }
        structuredReader.run(
            executable: toolPath,
            arguments: structuredArguments,
            environment: Self.environment(udid: udid),
            onLine: { [weak self] line in
                self?.receiveStructuredLine(line, request: request)
            },
            onEnd: { [weak self] reason in
                self?.structuredReaderEnded(reason: reason, request: request)
            }
        )
    }

    private func receiveStructuredLine(_ line: ArraySlice<UInt8>, request: Int) {
        guard generation.contains(request), let row = DeviceLogDecoding.pymobiledevice3(line) else { return }
        markTransportActivity()
        let isFirstStructuredRow = markDecodedStructuredRow()
        // Errors only still receives Notice rows: the tool can clear Debug and Info, not more.
        if row.severity >= minimumSeverity,
           processName == nil || row.process == processName { enqueue(row) }
        if isFirstStructuredRow {
            lifecycle.async { [weak self] in
                guard let self, self.generation.contains(request) else { return }
                self.cancelFallbackTimer()
            }
        }
    }

    private func structuredReaderEnded(reason: String, request: Int) {
        lifecycle.async { [weak self] in
            guard let self, self.generation.contains(request), !self.stopped else { return }
            self.cancelFallbackTimer()
            self.hostStream?.stop()
            self.hostStream = nil
            guard !self.didDecodeStructuredRow, let fallbackToolPath = self.fallbackToolPath else {
                self.onStreamEnded?(reason)
                return
            }
            self.startFallbackOnce(toolPath: fallbackToolPath, request: request)
        }
    }

    /// A command that stays alive but never produces a row is not a working route. This is the
    /// exact failure shape of a contended relay, and waiting forever would prevent the fallback
    /// from doing the one job it exists for.
    private func scheduleFallbackIfSilent(request: Int) {
        guard let fallbackToolPath else { return }
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now() + structuredStartupDeadline)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation.contains(request), !self.stopped, !self.didDecodeStructuredRow else { return }
            self.structuredReader.stop()
            self.hostStream?.stop()
            self.hostStream = nil
            self.startFallbackOnce(toolPath: fallbackToolPath, request: request)
        }
        fallbackTimer = timer
        timer.resume()
    }

    private func startFallbackOnce(toolPath: String, request: Int) {
        guard !fallbackStarted else { return }
        fallbackStarted = true
        cancelFallbackTimer()
        startFallbackReader(toolPath: toolPath, request: request)
    }

    private func cancelFallbackTimer() {
        fallbackTimer?.setEventHandler {}
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func startFallbackReader(toolPath: String, request: Int) {
        // The fallback is the same single-client relay as `PairedDeviceLogRowSource`, including
        // its orphan-reclaim rule. Skipping this step can make a successful fallback stay silent.
        reclaimRelay(udid, toolPath)
        guard generation.contains(request) else { return }
        var arguments = ["-u", udid, "--no-colors"]
        if overNetwork { arguments.append("-n") }
        fallbackReader.run(
            executable: toolPath,
            arguments: arguments,
            onLine: { [weak self] line in
                if let self, self.generation.contains(request), let row = DeviceLogDecoding.syslog(line) {
                    self.markTransportActivity()
                    if row.severity >= self.minimumSeverity,
                   self.processName == nil || row.process == self.processName { self.enqueue(row) }
                }
            },
            onEnd: { [weak self] fallbackReason in
                guard let self, self.generation.contains(request) else { return }
                self.onStreamEnded?(fallbackReason)
            }
        )
    }

    /// Target one phone and neutralise inherited transport selectors that conflict with
    /// `--native`. The host's other environment remains intact for Python and its virtualenv.
    static func environment(
        udid: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = inherited
        result["PYMOBILEDEVICE3_UDID"] = udid
        result.removeValue(forKey: "PYMOBILEDEVICE3_TUNNEL")
        result.removeValue(forKey: "PYMOBILEDEVICE3_USERSPACE")
        result.removeValue(forKey: "PYMOBILEDEVICE3_NATIVE")
        return result
    }

    private func setDecodedStructuredRows(_ count: Int) {
        decodedLock.lock()
        decodedStructuredRows = count
        decodedLock.unlock()
    }

    private func markDecodedStructuredRow() -> Bool {
        decodedLock.lock()
        decodedStructuredRows += 1
        let isFirst = decodedStructuredRows == 1
        decodedLock.unlock()
        return isFirst
    }
}

// MARK: - Device console

/// `devicectl device process launch --console`: the app's own `stdout` and `stderr`, live, from a
/// real device.
///
/// This is the best device route and it took a while to see. It is Apple's own tool, so it needs
/// no libimobiledevice; it is a stream rather than a 280 MB archive pull; and because `stdout` has
/// no privacy model at all, **nothing is redacted** — measured at 0 `<private>` against 94% on the
/// unified-log route. Stopping the reader does not stop the app.
///
/// Its one real constraint is that `devicectl` must *launch* the app, so output starts at that
/// launch. For watching a build you just made, which is the case, that is what Xcode does too.
///
/// The launch also sets `OS_ACTIVITY_DT_MODE`, as Xcode's Run does: the app's own `os_log` and
/// `Logger` lines are then copied to `stderr` in full, so the values the unified log shows as
/// `<private>` arrive here readable, with their subsystem and category.
public final class DeviceConsoleLogSource: BufferedDeviceLogSource {
    private let reader = DeviceLogLineReader(label: "console")
    private let deviceID: String
    private let bundleID: String
    private let appName: String

    /// `devicectl`'s own progress lines are not the app talking.
    private static let preamble = [
        "Acquired usage assertion", "Enabling developer disk image services",
        "Acquired tunnel connection", "Launched application with",
        "Waiting for the application to terminate",
    ]

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(deviceID: String, bundleID: String, appName: String) {
        self.deviceID = deviceID
        self.bundleID = bundleID
        self.appName = appName
        super.init(deviceID: deviceID, bundleID: bundleID)
    }

    public override func start() {
        resetTransportActivity()
        reader.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "process", "launch", "--device", deviceID,
                "--console", "--terminate-existing",
                "--environment-variables", Self.environment, bundleID,
            ],
            onLine: { [weak self] line in
                guard let self, let row = self.decode(line) else { return }
                self.enqueue(row)
            },
            onEnd: { [weak self] reason in self?.onStreamEnded?(reason) }
        )
    }

    public override func stop() { reader.stop() }

    /// What Xcode's Run sets so `os_log` is mirrored, unredacted, to the app's `stderr`.
    static let environment = #"{"OS_ACTIVITY_DT_MODE": "enable"}"#

    /// A mirrored `os_log` line: `2026-10-14 08:14:00.656123+0200 Ananke[423:9a1f] [sub:cat] text`.
    /// The tag is absent for a logger without a subsystem.
    private static let mirrored = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}\.\d{3})\d*[+-]\d{4}) ([^\[\s]+)\[(\d+):[0-9a-fx]+\] (?:\[([^\]]+)\] )?(.*)$"#
    )

    /// Plain console output carries no timestamp, level or subsystem of its own, so the row is
    /// stamped on arrival and attributed to the app. A mirrored `os_log` line keeps its own time
    /// and `subsystem:category`, so it filters like the same line in the system log.
    func decode(_ line: ArraySlice<UInt8>) -> DeviceLogRow? {
        guard let text = String(bytes: line, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !Self.preamble.contains(where: { trimmed.contains($0) }) else { return nil }
        var time = Self.clock.string(from: Date())
        var subsystem: String?
        var category: String?
        var pid: Int?
        var process = appName
        var timestamp: Date?
        var source: DeviceLogRecordSource = .console
        var message = trimmed
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = Self.mirrored.firstMatch(in: trimmed, range: whole) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) }
            }
            timestamp = DeviceLogDecoding.instant(in: group(1))
            time = group(2) ?? time
            process = group(3) ?? appName
            pid = group(4).flatMap(Int.init)
            let label = group(5)?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
            subsystem = label.first
            category = label.count > 1 ? label[1] : nil
            message = group(6) ?? trimmed
            source = .stderr
        }
        return DeviceLogRow(
            time: time,
            level: message.contains("[ERROR]") || message.contains("error:") ? "Error" : "Default",
            process: process,
            subsystem: subsystem,
            message: message,
            timestamp: timestamp,
            deviceID: deviceID,
            bundleID: bundleID,
            pid: pid,
            category: category,
            source: source,
            rawLine: text
        )
    }
}

// MARK: - App container log file

/// The app's own log file, pulled off the device with `devicectl`.
///
/// For any app with a logging facade that persists — which is most mature apps — this is the only
/// route that shows what the app actually recorded. Lotus writes to `os.Logger` *and* a file and
/// never to `stdout`, so its 16,036 structured lines with categories and `file:line` are invisible
/// to `--console` (77 lines of unrelated `NSLog` noise) and redacted in the unified log. They are
/// complete and unredacted here, because it is the app's own file.
///
/// Apple's own tooling throughout: no libimobiledevice, no root, no pairing beyond what Xcode
/// already established.
public final class AppContainerLogSource: BufferedDeviceLogSource {
    private let queue = DispatchQueue(label: "codes.threading.devicelog.container")
    private let deviceID: String
    private let bundleID: String
    private let appName: String
    private var stopped = false

    /// Re-listing is cheap next to re-copying, so the poll lists first and only pulls when the
    /// newest file's modification date moved. `devicectl` has no ranged read: a pull is the whole
    /// file, so doing it only on a change is what keeps this affordable.
    private static let pollInterval: TimeInterval = 4
    private var lastPulledPath: String?
    private var lastModified: String?
    private var emittedLines = 0

    public init(deviceID: String, bundleID: String, appName: String) {
        self.deviceID = deviceID
        self.bundleID = bundleID
        self.appName = appName
        super.init(deviceID: deviceID, bundleID: bundleID, source: .appLog)
    }

    public override func start() {
        resetTransportActivity()
        stopped = false
        queue.async { [weak self] in
            while let self, !self.stopped {
                self.pollOnce()
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }
    }

    public override func stop() { stopped = true }

    private func pollOnce() {
        guard let newest = DeviceLogSourceCatalog.newestContainerLog(
            deviceID: deviceID,
            bundleID: bundleID
        ) else { return }
        // A new file means a new app launch: start its lines from the top rather than carrying an
        // offset that belonged to the previous run.
        if newest.path != lastPulledPath {
            lastPulledPath = newest.path
            emittedLines = 0
            lastModified = nil
        }
        guard newest.modified != lastModified else { return }
        lastModified = newest.modified

        guard let text = DeviceLogSourceCatalog.copyContainerFile(
            deviceID: deviceID,
            bundleID: bundleID,
            source: newest.path
        ) else { return }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > emittedLines else { return }
        let fresh = lines[emittedLines...]
        emittedLines = lines.count
        enqueue(fresh.compactMap { DeviceLogDecoding.appLogLine(String($0), appName: appName) })
    }

}

// MARK: - Decoding

public enum DeviceLogDecoding {

    /// `2026-09-02T10:34:33.242Z [DEBUG] [kmp-interface] File.swift:26 fn(_:) - message`
    public static func appLogLine(_ line: String, appName: String) -> DeviceLogRow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("====") else { return nil }

        var rest = Substring(trimmed)
        var time = DeviceLogLimits.undatedTime
        // The banner lines a log file opens with have no stamp; they are still worth showing.
        if trimmed.count > 24, trimmed.hasPrefix("20"), let space = rest.firstIndex(of: " ") {
            let candidate = String(rest[rest.startIndex..<space].dropFirst(11).prefix(12))
            // `2026-09-02T10:34:33.242Z` carries the clock in one token; `2024-01-15 10:30:45`
            // does not, and slicing it the same way produced an empty column rather than a stamp.
            // Consume the token only when what came out is a time.
            if Self.isClockText(candidate) {
                time = candidate
                rest = rest[rest.index(after: space)...]
            }
        }
        var level = "Default"
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            level = appLogLevel(from: String(rest[rest.index(after: rest.startIndex)..<close]))
            rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        }
        var subsystem: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            subsystem = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        }

        // The shape above is one app's. Anything else — Android logcat, a bracketed stamp, plain
        // syslog, Apache — reached this point as an undated `Default` line, which is readable and
        // useless: no time column and nothing for the level filter to order. `TimberLineParser`
        // recognises eight stamp formats and a level vocabulary, so a log we have never seen still
        // arrives with the two columns that make it filterable.
        if time == DeviceLogLimits.undatedTime || time.isEmpty || level == "Default" {
            if time == DeviceLogLimits.undatedTime || time.isEmpty,
               let recovered = Self.clockText(in: trimmed) {
                time = recovered
            }
            if level == "Default" {
                level = Self.level(from: LevelDetector.detectLevel(bytes: Array(trimmed.utf8)))
            }
        }

        return DeviceLogRow(
            time: time,
            level: level,
            process: appName,
            subsystem: subsystem,
            message: String(rest),
            timestamp: instant(in: trimmed),
            source: .appLog,
            rawLine: line
        )
    }

    /// The instant a line was written, for the queries `time` cannot answer.
    ///
    /// `nil` rather than a guess when there is no stamp: a banner has no time, and inventing one
    /// would put it in a range it does not belong to.
    static func instant(in text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return TimestampParser.tryAllTimestampFormats(bytes: Array(text.utf8)).0
    }

    /// The parser's vocabulary as the rows spell it.
    ///
    /// It used to lose things: the detector knew five levels and Apple's `Notice`, `Fault`,
    /// `Critical`, `Alert` and `Emergency` all came back `unknown`, so a fault in an unfamiliar
    /// log read as no level at all. The detector carries both vocabularies now, so this maps
    /// rather than collapses.
    private static func level(from detected: LogLevel) -> String {
        switch detected {
        case .emergency: return "Emergency"
        case .alert: return "Alert"
        case .critical: return "Critical"
        case .fault: return "Fault"
        case .error: return "Error"
        case .warning: return "Warning"
        case .notice: return "Notice"
        case .info: return "Info"
        case .debug, .verbose, .trace: return "Debug"
        case .unknown: return "Default"
        }
    }

    /// Whether a slice is a wall clock, which is what decides that the first token was a stamp.
    private static func isClockText(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].count == 2, parts[1].count == 2 else { return false }
        return parts.allSatisfy { $0.first?.isNumber == true }
    }

    /// The wall clock a line wrote, taken as characters rather than reconstructed from a `Date`.
    ///
    /// `TimestampParser` reads eight formats and hands back a `Date`, which is the right answer for
    /// a time-range query and the wrong one for this column. A naive stamp carries no zone, so the
    /// `Date` is an interpretation: rendering `01-15 10:30:45.123` came back as `09:30:45.123`
    /// formatted locally and `08:30:45.123` formatted as UTC — both measured here, both an hour or
    /// two from what the file says. A log is where someone goes to check a time, so the column
    /// shows the file's own characters and leaves interpretation to whoever asks for a range.
    private static func clockText(in line: String) -> String? {
        let characters = Array(line)
        var index = 0
        while index + 8 <= characters.count {
            // Not inside a longer number: Apache writes `21/Nov/2024:10:30:45`, where a scan that
            // starts anywhere finds `24:10:30` in the year before it finds the clock.
            let startsANumber = index == 0 || !characters[index - 1].isNumber
            if startsANumber, characters[index].isNumber, characters[index + 1].isNumber,
               characters[index + 2] == ":", characters[index + 3].isNumber,
               characters[index + 4].isNumber, characters[index + 5] == ":",
               characters[index + 6].isNumber, characters[index + 7].isNumber,
               let hour = Int(String(characters[index...(index + 1)])), hour < 24 {
                var end = index + 8
                if end < characters.count, characters[end] == "." {
                    var fraction = end + 1
                    while fraction < characters.count, characters[fraction].isNumber { fraction += 1 }
                    end = min(fraction, end + 4)   // milliseconds, as the other routes show
                }
                return String(characters[index..<end])
            }
            index += 1
        }
        return nil
    }

    /// An app's own vocabulary mapped onto the one the level filter orders.
    private static func appLogLevel(from token: String) -> String {
        switch token.uppercased() {
        case "ERROR": return "Error"
        case "FAULT", "CRITICAL": return "Fault"
        case "WARN", "WARNING": return "Warning"
        case "INFO": return "Info"
        case "DEBUG", "TRACE", "VERBOSE": return "Debug"
        default: return "Default"
        }
    }

    /// `log stream --style=ndjson`, and `log show --archive --style ndjson`, which are the same
    /// schema. One parser therefore serves the simulator and a pulled device archive.
    public static func ndjson(_ line: ArraySlice<UInt8>) -> DeviceLogRow? {
        let data = Data(line)
        guard data.first == 0x7B,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let process = (object["processImagePath"] as? String)
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        var time = DeviceLogLimits.undatedTime
        if let raw = object["timestamp"] as? String, raw.count >= 23 {
            time = String(raw.dropFirst(11).prefix(12))
        }
        let subsystem = (object["subsystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let category = string(object["category"])
        let message = (object["eventMessage"] as? String) ?? ""
        return DeviceLogRow(
            time: time,
            level: (object["messageType"] as? String) ?? "Default",
            process: process,
            subsystem: subsystem,
            message: message,
            timestamp: instant(in: object["timestamp"] as? String),
            bundleID: string(object["bundleIdentifier"] ?? object["bundleID"]),
            pid: integer(object["processID"] ?? object["pid"]),
            category: category,
            source: recordSource(subsystem: subsystem, category: category, message: message),
            rawLine: String(decoding: line, as: UTF8.self),
            processPath: object["processImagePath"] as? String
        )
    }

    /// One NDJSON object emitted by `pymobiledevice3 syslog live --format json`.
    ///
    /// Captured from a physical iPhone on iOS 26.6.2. The label is nested rather than using the
    /// macOS `log stream` keys, and contains both subsystem and category. Their original fields
    /// remain distinct, while `subsystemLabel` combines them for the pane's one label column.
    public static func pymobiledevice3(_ line: ArraySlice<UInt8>) -> DeviceLogRow? {
        let data = Data(line)
        guard data.first == 0x7B,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return nil }

        let processPath = (object["filename"] as? String)
            ?? (object["image_name"] as? String)
        let process = processPath.map { ($0 as NSString).lastPathComponent } ?? "?"
        let rawTimestamp = object["timestamp"] as? String
        let time = rawTimestamp.map(Self.clockFromISO8601) ?? DeviceLogLimits.undatedTime
        let rawLevel = object["level"] as? String
        let level = rawLevel.map(Self.unifiedLogLevel) ?? "Default"
        let label = object["label"] as? [String: Any]
        let subsystem = string(label?["subsystem"])
        let category = string(label?["category"])

        return DeviceLogRow(
            time: time,
            level: level,
            process: process,
            subsystem: subsystem,
            message: message,
            timestamp: instant(in: rawTimestamp),
            bundleID: string(object["bundleIdentifier"] ?? object["bundle_id"]),
            pid: integer(object["pid"]),
            category: category,
            source: recordSource(subsystem: subsystem, category: category, message: message),
            rawLine: String(decoding: line, as: UTF8.self),
            processPath: processPath
        )
    }

    private static func clockFromISO8601(_ timestamp: String) -> String {
        guard timestamp.count >= 19 else { return DeviceLogLimits.undatedTime }
        return String(timestamp.dropFirst(11).prefix(12))
    }

    private static func unifiedLogLevel(_ raw: String) -> String {
        switch raw.uppercased() {
        case "EMERGENCY": return "Emergency"
        case "ALERT": return "Alert"
        case "CRITICAL": return "Critical"
        case "FAULT": return "Fault"
        case "ERROR": return "Error"
        case "WARNING", "WARN": return "Warning"
        case "NOTICE": return "Notice"
        case "INFO": return "Info"
        case "DEBUG": return "Debug"
        default: return "Default"
        }
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        return (value as? String).flatMap(Int.init)
    }

    /// Only the host's named tap proves which descriptor a unified-log entry came from. A
    /// message saying `[stdout]` in another subsystem is ordinary application text.
    static func recordSource(subsystem: String?, category: String?, message: String) -> DeviceLogRecordSource {
        guard subsystem == "codes.threading.logtap", category == "tap" else { return .system }
        if message.hasPrefix("[stdout] ") { return .stdout }
        if message.hasPrefix("[stderr] ") { return .stderr }
        if message.hasPrefix("[stdio] ") { return .console }
        return .system
    }

    /// `idevicesyslog` output, which looks like:
    ///
    ///     Sep  1 16:21:01.548727 AccessibilityUIServer(CoreMotion)[41737] <Debug>: message
    ///     Sep  1 16:21:01.549408 kernel[0] <Notice>: message
    ///
    /// The parenthesised part is the *sender image* (the library that logged), which is the closest
    /// thing the relay offers to a subsystem, so it is shown in that column.
    public static func syslog(_ line: ArraySlice<UInt8>) -> DeviceLogRow? {
        guard let text = String(bytes: line, encoding: .utf8), !text.isEmpty else { return nil }
        guard !text.hasPrefix("[connected"), !text.hasPrefix("[disconnected") else { return nil }

        // "Sep  1 16:21:01.548712 " — keep the clock, drop the date.
        var rest = Substring(text)
        guard let firstSpace = rest.firstIndex(of: " ") else { return nil }
        rest = rest[rest.index(after: firstSpace)...].drop(while: { $0 == " " })
        guard let secondSpace = rest.firstIndex(of: " ") else { return nil }
        rest = rest[rest.index(after: secondSpace)...]
        guard let thirdSpace = rest.firstIndex(of: " ") else { return nil }
        let stamp = String(rest[rest.startIndex..<thirdSpace].prefix(12))
        rest = rest[rest.index(after: thirdSpace)...]

        // "process(sender)[pid] <Level>: message"
        guard let separator = rest.range(of: ">: ") else { return nil }
        let head = rest[rest.startIndex..<separator.lowerBound]
        let message = String(rest[separator.upperBound...])
        guard let angle = head.range(of: " <") else { return nil }
        let level = String(head[head.index(angle.lowerBound, offsetBy: 2)...])
        var name = String(head[head.startIndex..<angle.lowerBound])
        var pid: Int?
        if let bracket = name.range(of: "[", options: .backwards) {
            pid = Int(name[bracket.upperBound...].dropLast())
            name = String(name[name.startIndex..<bracket.lowerBound])
        }
        var subsystem: String?
        if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
            subsystem = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            name = String(name[name.startIndex..<open])
        }
        return DeviceLogRow(
            time: stamp,
            level: level,
            process: name,
            subsystem: subsystem,
            message: message,
            timestamp: instant(in: text),
            pid: pid,
            source: .system,
            rawLine: text
        )
    }
}

// MARK: - Discovery

/// One thing the pane can be pointed at.
public struct DeviceLogSourceOption: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case simulator(udid: String)
        case device(udid: String, overNetwork: Bool)
        case bluetooth(udid: String, overNetwork: Bool, toolPath: String?)
        case structuredDevice(
            udid: String,
            overNetwork: Bool,
            toolPath: String,
            fallbackToolPath: String?
        )
        case brokeredStructuredDevice(
            udid: String,
            overNetwork: Bool,
            fallbackToolPath: String?
        )
        /// One app on a real device. Which of its two logs to read is `DeviceLogRoute`, chosen
        /// beside the source rather than by doubling every app into two entries.
        case app(deviceID: String, bundleID: String, appName: String)
    }

    /// The machine this source is read from.
    ///
    /// Grouping is the pane's business, but the *answer* is discovery's: only it knows a device's
    /// name, and recovering that name by parsing it back out of a source title is how a rename
    /// becomes a second device in the menu. It also gives identity somewhere to hang — two phones
    /// both offer "System log", and only the machine tells them apart.
    public struct Machine: Equatable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let isSimulator: Bool

        public init(id: String, title: String, isSimulator: Bool) {
            self.id = id
            self.title = title
            self.isSimulator = isSimulator
        }
    }

    public let machine: Machine
    /// What this source is called *within its machine* — "System log", or an app's name. The
    /// device it belongs to is `machine`, not a suffix on this.
    public let title: String
    public let kind: Kind
    public let application: DeviceLogApplication?
    public let processIdentity: DeviceLogProcessIdentity?
    public let catalogWarning: String?
    private let systemLogKind: Kind?

    public init(machine: Machine, title: String, kind: Kind, application: DeviceLogApplication? = nil,
                processIdentity: DeviceLogProcessIdentity? = nil, catalogWarning: String? = nil,
                systemLogKind: Kind? = nil) {
        self.machine = machine
        self.title = title
        self.kind = kind
        self.application = application
        self.processIdentity = processIdentity ?? application?.processIdentity
        self.catalogWarning = catalogWarning
        self.systemLogKind = systemLogKind
    }

    public var bundleID: String? {
        if let application { return application.bundleID }
        if case .app(_, let bundleID, _) = kind { return bundleID }
        return processIdentity?.bundleID
    }

    /// Whether an app entry reads the app's own persisted log or its live console. Two genuinely
    /// different contents, so it is a choice rather than a fallback.
    public enum Route: Int, CaseIterable {
        case appLog
        case console
        case system

        public var title: String {
            switch self {
            case .appLog: return L10n.string("App log")
            case .console: return L10n.string("Console")
            case .system: return L10n.string("System log")
            }
        }
    }

    public func captureAvailability(route: Route = .system) -> DeviceLogCaptureAvailability {
        let sources: [DeviceLogRecordSource]
        let detail: String
        if case .bluetooth = kind {
            sources = [.bluetooth]
            detail = "Bluetooth packet capture; application stdout and stderr are unavailable."
        } else if case .app = kind, route == .appLog {
            sources = [.appLog]
            detail = "The app's persisted log file; stdout and stderr are unavailable."
        } else if case .app = kind, route == .console {
            sources = [.console]
            detail = "Explicit app relaunch console. Plain stdout/stderr are merged; only mirrored system lines can be identified as stderr."
        } else {
            sources = [.system]
            detail = "Unified/system log. Application stdout and stderr are unavailable unless this capture observes descriptor-specific entries from codes.threading.logtap for the selected process."
        }
        return DeviceLogCaptureAvailability(availableSources: sources, unavailableSources: [.stdout, .stderr], detail: detail)
    }

    /// Whether this source leaves rows below the pane's level unread. The system logs are a
    /// firehose at Debug; Bluetooth packets have no level and an app's own log is not a firehose.
    public var readsAtLevel: Bool {
        switch kind {
        case .simulator, .device, .structuredDevice, .brokeredStructuredDevice: return true
        case .bluetooth, .app: return false
        }
    }

    public func readsAtLevel(route: Route) -> Bool {
        if case .app = kind { return route == .system }
        return readsAtLevel
    }

    public func makeSource(
        predicate: String?, route: Route = .system, processName: String? = nil,
        minimumSeverity: Int = 0, deviceServices: (any PluginDeviceServices)? = nil
    ) -> DeviceLogRowSource? {
        let severity = readsAtLevel(route: route) ? minimumSeverity : 0
        switch kind {
        case .simulator(let udid):
            let processPredicate: String?
            if let path = processIdentity?.executablePath {
                processPredicate = NSPredicate(format: "processImagePath == %@", path).predicateFormat
            } else {
                processPredicate = (processName ?? processIdentity?.name).map { NSPredicate(format: "process == %@", $0).predicateFormat }
            }
            let clauses = [predicate, processPredicate].compactMap { $0 }.filter { !$0.isEmpty }
            return SimulatorLogRowSource(
                udid: udid,
                predicate: clauses.isEmpty ? nil : clauses.map { "(\($0))" }.joined(separator: " AND "),
                minimumSeverity: severity, bundleID: bundleID, processIdentity: processIdentity
            )
        case .device(let udid, let overNetwork):
            guard let tool = DeviceLogSourceCatalog.syslogToolPath else { return nil }
            return PairedDeviceLogRowSource(
                udid: udid, overNetwork: overNetwork, toolPath: tool, processName: processName, minimumSeverity: severity,
                bundleID: bundleID, processIdentity: processIdentity
            )
        case .bluetooth(let udid, let overNetwork, let toolPath):
            return BluetoothLogRowSource(udid: udid, overNetwork: overNetwork, toolPath: toolPath)
        case .structuredDevice(let udid, let overNetwork, let tool, let fallbackTool):
            return StructuredPairedDeviceLogRowSource(
                udid: udid,
                overNetwork: overNetwork,
                toolPath: tool,
                fallbackToolPath: fallbackTool,
                processName: processName,
                minimumSeverity: severity, bundleID: bundleID, processIdentity: processIdentity
            )
        case .brokeredStructuredDevice(let udid, let overNetwork, let fallbackTool):
            guard let deviceServices else { return nil }
            return StructuredPairedDeviceLogRowSource(
                udid: udid, overNetwork: overNetwork, deviceServices: deviceServices,
                fallbackToolPath: fallbackTool, processName: processName,
                minimumSeverity: severity, bundleID: bundleID, processIdentity: processIdentity
            )
        case .app(let deviceID, let bundleID, let appName):
            switch route {
            case .appLog:
                return AppContainerLogSource(
                    deviceID: deviceID,
                    bundleID: bundleID,
                    appName: appName
                )
            case .console:
                return DeviceConsoleLogSource(
                    deviceID: deviceID,
                    bundleID: bundleID,
                    appName: appName
                )
            case .system:
                let identity = processIdentity ?? DeviceLogProcessIdentity(name: appName, bundleID: bundleID)
                let option = DeviceLogSourceOption(
                    machine: machine, title: title,
                    kind: systemLogKind ?? .brokeredStructuredDevice(
                        udid: deviceID, overNetwork: false, fallbackToolPath: DeviceLogSourceCatalog.syslogToolPath
                    ),
                    processIdentity: identity
                )
                return option.makeSource(predicate: predicate, processName: processName,
                                         minimumSeverity: minimumSeverity, deviceServices: deviceServices)
            }
        }
    }
}

/// Finds the booted simulators and paired devices worth offering.
///
/// Every call spawns a child process, so discovery never runs on the main actor and every command
/// has a deadline: a wedged `simctl` or a phone that stops answering must produce an empty list,
/// not a stalled pane.
public enum DeviceLogSourceCatalog {

    private static let pymobiledevice3Override = "THREADING_PHYSICAL_DEVICE_PROBE_PATH"
    static let minimumStructuredSyslogToolVersion = [11, 13, 1]

    /// `idevicesyslog` is libimobiledevice's, GPL-2.0 over an LGPL library, so it is never bundled.
    /// Its absence is a named state the pane can explain, not a silent empty list.
    public static var syslogToolPath: String? {
        ["/opt/homebrew/bin/idevicesyslog", "/usr/local/bin/idevicesyslog"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var bluetoothToolPath: String? {
        ["/opt/homebrew/bin/idevicebtlogger", "/usr/local/bin/idevicebtlogger"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var infoToolPath: String? {
        ["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var deviceIDToolPath: String? {
        ["/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A recent `pymobiledevice3` can expose the real unified-log fields over Apple's native RSD
    /// tunnel. Version probing happens inside background discovery, never while the pane starts a
    /// reader on the main actor.
    private static func structuredSyslogToolPath(preferredPath: String?) -> String? {
        let candidates = structuredSyslogCandidatePaths(
            preferredPath: preferredPath,
            environment: ProcessInfo.processInfo.environment
        )
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path),
                  let version = BoundedDeviceLogCommand.run(path, ["--no-color", "version"]),
                  structuredSyslogVersionIsSupported(version) == true
            else { continue }
            return path
        }
        return nil
    }

    static func structuredSyslogCandidatePaths(
        preferredPath: String?,
        environment: [String: String]
    ) -> [String] {
        var candidates: [String] = []
        if let configured = environment[pymobiledevice3Override], configured.hasPrefix("/") {
            candidates.append(configured)
        }
        if let preferredPath, preferredPath.hasPrefix("/") {
            candidates.append(preferredPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3",
            "/usr/bin/pymobiledevice3",
        ])

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func structuredSyslogVersionIsSupported(_ rawVersion: String) -> Bool? {
        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= minimumStructuredSyslogToolVersion.count else { return nil }

        let parsed = components.prefix(minimumStructuredSyslogToolVersion.count).map { component in
            Int(component.prefix(while: \Character.isNumber))
        }
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
            .lexicographicallyPrecedes(minimumStructuredSyslogToolVersion) == false
    }

    public static func discover(
        preferredPymobiledevice3Path: String? = nil,
        deviceServices: (any PluginDeviceServices)? = nil,
        completion: @escaping @Sendable ([DeviceLogSourceOption]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let hostStructured = deviceServices?.hasStructuredSystemLog() == true
            let structuredTool = deviceServices == nil ? structuredSyslogToolPath(
                preferredPath: preferredPymobiledevice3Path
            ) : nil
            let fallbackTool = syslogToolPath
            let bluetoothTool = bluetoothToolPath
            var options: [DeviceLogSourceOption] = []
            for simulator in bootedSimulators().prefix(DeviceLogLimits.maximumMachines) {
                let machine = DeviceLogSourceOption.Machine(id: simulator.udid, title: simulator.name, isSimulator: true)
                options.append(DeviceLogSourceOption(
                    machine: machine,
                    title: L10n.string("System log"),
                    kind: .simulator(udid: simulator.udid)
                ))
                for app in simulatorApplications(deviceID: simulator.udid) {
                    options.append(DeviceLogSourceOption(machine: machine, title: app.name,
                                                        kind: .simulator(udid: simulator.udid), application: app))
                }
            }
            let devices = pairedDevices()
            for device in devices.prefix(DeviceLogLimits.maximumMachines) {
                let transport = device.overNetwork ? "Wi-Fi" : "USB"
                let name = deviceName(udid: device.udid, overNetwork: device.overNetwork)
                    ?? String(device.udid.prefix(8)) + "…"
                // The device's name is the *machine's*, so it is stated once here rather than
                // repeated into every source title. The transport stays on the system log because
                // it describes that reader, not the phone.
                let machine = DeviceLogSourceOption.Machine(
                    id: device.udid,
                    title: name,
                    isSimulator: false
                )
                let systemLogKind: DeviceLogSourceOption.Kind
                if hostStructured {
                    systemLogKind = .brokeredStructuredDevice(
                        udid: device.udid,
                        overNetwork: device.overNetwork,
                        fallbackToolPath: fallbackTool
                    )
                } else if let structuredTool {
                    systemLogKind = .structuredDevice(
                        udid: device.udid,
                        overNetwork: device.overNetwork,
                        toolPath: structuredTool,
                        fallbackToolPath: fallbackTool
                    )
                } else {
                    systemLogKind = .device(
                        udid: device.udid,
                        overNetwork: device.overNetwork
                    )
                }
                options.append(DeviceLogSourceOption(
                    machine: machine,
                    title: L10n.format("System log (%@)", transport),
                    kind: systemLogKind
                ))
                options.append(DeviceLogSourceOption(
                    machine: machine,
                    title: L10n.format("Bluetooth (%@)", transport),
                    kind: .bluetooth(udid: device.udid, overNetwork: device.overNetwork, toolPath: bluetoothTool)
                ))
                // One entry per app the user builds themselves. This is the route worth reaching
                // for first: live, Apple-native, and unredacted, unlike the system log beside it.
                let processes = runningAppProcesses(deviceID: device.udid)
                let apps = developerApps(deviceID: device.udid, processes: processes)
                for app in apps {
                    options.append(DeviceLogSourceOption(
                        machine: machine,
                        title: app.name,
                        kind: .app(
                            deviceID: device.udid,
                            bundleID: app.bundleID,
                            appName: app.name
                        ),
                        application: app,
                        systemLogKind: systemLogKind
                    ))
                }
                for process in processes where !apps.contains(where: { $0.executablePath == process.executablePath }) {
                    options.append(DeviceLogSourceOption(
                        machine: machine, title: "\(process.name) (PID \(process.pid ?? 0))",
                        kind: systemLogKind, processIdentity: process,
                        catalogWarning: apps.isEmpty
                            ? "Installed-app metadata was unavailable or empty. Running process identity is available; its bundle ID is unknown."
                            : "This running process has no matching installed-app bundle identity."
                    ))
                }
            }
            let found = options
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func bootedSimulators() -> [(udid: String, name: String)] {
        guard let output = BoundedDeviceLogCommand.run(
            "/usr/bin/xcrun",
            ["simctl", "list", "devices", "booted", "-j"]
        ),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]]
        else { return [] }
        return byRuntime.values.flatMap { $0 }.compactMap {
            guard let udid = $0["udid"] as? String, let name = $0["name"] as? String else {
                return nil
            }
            return (udid, name)
        }
    }

    /// `idevice_id -l` lists devices reachable over USB and `-n` over the network. A phone moves
    /// between the two silently when it is unplugged, and `idevicesyslog` needs the matching flag,
    /// so which list a device came from is part of its identity here.
    private static func pairedDevices() -> [(udid: String, overNetwork: Bool)] {
        guard let tool = deviceIDToolPath else { return [] }
        let usb = (BoundedDeviceLogCommand.run(tool, ["-l"]) ?? "")
            .split(separator: "\n")
            .map(String.init)
        let network = (BoundedDeviceLogCommand.run(tool, ["-n"]) ?? "")
            .split(separator: "\n")
            .map(String.init)
        var seen = Set<String>()
        var result: [(String, Bool)] = []
        for udid in usb where !udid.isEmpty && seen.insert(udid).inserted {
            result.append((udid, false))
        }
        for udid in network where !udid.isEmpty && seen.insert(udid).inserted {
            result.append((udid, true))
        }
        return result
    }

    /// The name its owner gave the phone. `ideviceinfo` answers this on a locked device, unlike the
    /// syslog relay, so a named-but-silent source is a legible state rather than a puzzle.
    /// The route matters here exactly as it does for the log reader: `ideviceinfo` without `-n`
    /// answers "Device not found" for a phone that is only on Wi-Fi, and the pane then shows a
    /// truncated UDID where the owner's name should be.
    private static func deviceName(udid: String, overNetwork: Bool) -> String? {
        var arguments = ["-u", udid, "-k", "DeviceName"]
        if overNetwork { arguments.insert("-n", at: 0) }
        guard let tool = infoToolPath,
              let raw = BoundedDeviceLogCommand.run(tool, arguments)
        else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The apps on a device that its owner built, which is what a log pane is ever pointed at.
    ///
    /// `devicectl --device` accepts a UDID as well as its own identifier, so the same value that
    /// names a device to libimobiledevice names it here.
    private static func developerApps(deviceID: String, processes: [DeviceLogProcessIdentity]) -> [DeviceLogApplication] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard BoundedDeviceLogCommand.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "info", "apps", "--device", deviceID,
                "--json-output", output.path,
            ],
            deadline: DeviceLogLimits.appListDeadline
        ) != nil else { return [] }
        guard let data = boundedMetadata(at: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]]
        else { return [] }
        return apps.prefix(DeviceLogLimits.maximumCatalogEntries).compactMap { app -> DeviceLogApplication? in
            guard app["builtByDeveloper"] as? Bool == true,
                  let bundleID = app["bundleIdentifier"] as? String,
                  let name = app["name"] as? String
            else { return nil }
            let bundlePath = (app["url"] as? String).flatMap(URL.init(string:))?.path
            let executable = processes.first { process in
                guard let bundlePath, let path = process.executablePath else { return false }
                let root = DeviceLogProcessIdentity.normalized(bundlePath)
                return DeviceLogProcessIdentity.normalized(path).hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            return DeviceLogApplication(bundleID: bundleID, name: (app["displayName"] as? String) ?? name,
                                        executableName: executable?.name ?? name, executablePath: executable?.executablePath)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .prefix(DeviceLogLimits.maximumApps)
        .map { $0 }
    }

    private static func simulatorApplications(deviceID: String) -> [DeviceLogApplication] {
        guard let output = BoundedDeviceLogCommand.run("/usr/bin/xcrun", ["simctl", "listapps", deviceID]),
              let data = output.data(using: .utf8) else { return [] }
        return decodeSimulatorApplications(data)
    }

    static func decodeSimulatorApplications(_ data: Data) -> [DeviceLogApplication] {
        guard data.count <= DeviceLogLimits.maximumDiscoveryOutputBytes,
              let apps = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
        else { return [] }
        return apps.sorted { $0.key < $1.key }.prefix(DeviceLogLimits.maximumCatalogEntries).compactMap { bundleID, app in
            guard app["ApplicationType"] as? String != "System",
                  let executable = app["CFBundleExecutable"] as? String else { return nil }
            let path = (app["Path"] as? String) ?? (app["Bundle"] as? String).flatMap(URL.init(string:))?.path
            return DeviceLogApplication(bundleID: bundleID,
                                        name: (app["CFBundleDisplayName"] as? String) ?? (app["CFBundleName"] as? String) ?? executable,
                                        executableName: executable,
                                        executablePath: path.map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path })
        }.prefix(DeviceLogLimits.maximumApps).map { $0 }
    }

    private static func runningAppProcesses(deviceID: String) -> [DeviceLogProcessIdentity] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("threading-processes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard BoundedDeviceLogCommand.run("/usr/bin/xcrun", [
            "devicectl", "device", "info", "processes", "--device", deviceID,
            "--json-output", output.path,
        ], deadline: DeviceLogLimits.discoveryDeadline) != nil,
              let data = boundedMetadata(at: output) else { return [] }
        return decodeRunningAppProcesses(data)
    }

    static func decodeRunningAppProcesses(_ data: Data) -> [DeviceLogProcessIdentity] {
        guard data.count <= DeviceLogLimits.maximumDiscoveryOutputBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let processes = result["runningProcesses"] as? [[String: Any]] else { return [] }
        return processes.prefix(DeviceLogLimits.maximumCatalogEntries).compactMap { process in
            guard let raw = process["executable"] as? String,
                  let url = URL(string: raw), url.isFileURL,
                  url.path.contains(".app/"), let pid = process["processIdentifier"] as? Int else { return nil }
            return DeviceLogProcessIdentity(name: url.lastPathComponent, executablePath: url.path, pid: pid)
        }.sorted { ($0.name, $0.pid ?? 0) < ($1.name, $1.pid ?? 0) }
            .prefix(DeviceLogLimits.maximumProcesses).map { $0 }
    }

    private static func boundedMetadata(at url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= DeviceLogLimits.maximumDiscoveryOutputBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The newest `.log` in an app's data container, with the modification date that says whether
    /// it moved since last time.
    public static func newestContainerLog(
        deviceID: String,
        bundleID: String
    ) -> (path: String, modified: String)? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-container-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        guard BoundedDeviceLogCommand.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "info", "files", "--device", deviceID,
                "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                "--json-output", output.path,
            ],
            deadline: DeviceLogLimits.containerDeadline
        ) != nil else { return nil }
        guard let data = try? Data(contentsOf: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let files = result["files"] as? [[String: Any]]
        else { return nil }

        let logs = files.compactMap { file -> (String, String)? in
            guard let resources = file["resources"] as? [String: Any],
                  resources["isDirectory"] as? Bool == false,
                  let path = file["relativePath"] as? String,
                  path.hasSuffix(".log"),
                  let metadata = file["metadata"] as? [String: Any],
                  let modified = metadata["lastModDate"] as? String
            else { return nil }
            return (path, modified)
        }
        return logs.max { $0.1 < $1.1 }.map { (path: $0.0, modified: $0.1) }
    }

    /// Copy one container file off the device and read it. `devicectl` has no ranged read, so this
    /// is the whole file; the caller only asks when the file changed.
    public static func copyContainerFile(deviceID: String, bundleID: String, source: String) -> String? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: destination) }
        guard BoundedDeviceLogCommand.run(
            "/usr/bin/xcrun",
            [
                "devicectl", "device", "copy", "from", "--device", deviceID,
                "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                "--source", source, "--destination", destination.path,
            ],
            deadline: DeviceLogLimits.containerDeadline
        ) != nil else { return nil }
        return try? String(contentsOf: destination, encoding: .utf8)
    }

}
