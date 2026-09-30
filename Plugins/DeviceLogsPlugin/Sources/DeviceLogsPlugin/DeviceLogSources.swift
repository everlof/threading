import Darwin
import Foundation
import ThreadingDesignKit
import TimberLineParser

// MARK: - Row

/// One log line, kept as a value.
///
/// Externally sized content never becomes a view until the table asks for the row that holds it,
/// which is the whole reason this is a value and the pane is a table. See
/// [`device-and-simulator-logs.md`](../../../../docs/feature-drafts/device-and-simulator-logs.md).
public struct DeviceLogRow {
    public let time: String
    public let level: String
    public let process: String
    /// Absent when a source carries no label. The modern live-device route keeps its subsystem
    /// and category here as `subsystem / category`; the legacy relay can only offer sender image.
    /// Optional rather than empty so the difference stays visible.
    public let subsystem: String?
    public let message: String

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

    public init(
        time: String,
        level: String,
        process: String,
        subsystem: String?,
        message: String,
        timestamp: Date? = nil
    ) {
        self.time = time
        self.level = level
        self.process = process
        self.subsystem = subsystem
        self.message = message
        self.timestamp = timestamp
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
    /// Called once, off the main thread, when the source stops producing on its own.
    ///
    /// A reader that has died looks exactly like a device that has gone quiet, and the pane cannot
    /// tell them apart without being told. Not called for `stop()`, which the pane asked for.
    var onStreamEnded: ((String) -> Void)? { get set }
}

/// Shared batching and bounded handoff. Every source is a producer on its own queue and the pane
/// is a consumer on the main one; this is the only place that boundary is implemented.
public class BufferedDeviceLogSource: DeviceLogRowSource {
    public static let handoffCapacity = 20_000

    private var pending: [DeviceLogRow] = []
    private let lock = NSLock()
    private var droppedCount = 0

    public var onStreamEnded: ((String) -> Void)?

    public var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }

    public func start() {}
    public func stop() {}

    public func drain() -> [DeviceLogRow] {
        lock.lock()
        defer { lock.unlock() }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        return rows
    }

    public func enqueue(_ rows: [DeviceLogRow]) {
        guard !rows.isEmpty else { return }
        lock.lock()
        let room = Self.handoffCapacity - pending.count
        if room >= rows.count {
            pending.append(contentsOf: rows)
        } else {
            if room > 0 { pending.append(contentsOf: rows.prefix(room)) }
            droppedCount += rows.count - max(0, room)
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
public final class DeviceLogLineReader {
    private let queue: DispatchQueue
    private var process: Process?

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
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
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
        task.terminationHandler = { finished in
            errors.fileHandleForReading.readabilityHandler = nil
            guard let ending else { return }
            let reason = diagnostics.text()
            ending.call(reason.isEmpty
                ? "the reader exited with status \(finished.terminationStatus)"
                : reason)
        }
        process = task

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
    }

    /// A reader released without `stop()` would otherwise leave its child running, and for the
    /// device relay that is not a tidy-up detail: see `DeviceRelayReclaim`.
    deinit {
        process?.terminationHandler = nil
        process?.terminate()
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
        var reclaimed = 0
        for pid in orphanPIDs(udid: udid, toolPath: toolPath) {
            if kill(pid, SIGTERM) == 0 { reclaimed += 1 }
        }
        return reclaimed
    }

    /// Which of `ps -Ao pid=,ppid=,args=` output names a reader we abandoned.
    ///
    /// Pure so the rule can be tested without killing anything, because the rule is the whole
    /// safety of this: too loose and it kills a reader the user is running on purpose.
    public static func orphanPIDs(in listing: String, udid: String, toolPath: String) -> [pid_t] {
        listing.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let parent = pid_t(fields[1]),
                  // Orphaned to launchd: its owner is gone, so nobody is reading it.
                  parent == 1,
                  pid != getpid(),
                  line.contains(toolPath),
                  line.contains(udid)
            else { return nil }
            return pid
        }
    }

    private static func orphanPIDs(udid: String, toolPath: String) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,ppid=,args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let listing = String(data: data, encoding: .utf8) else { return [] }
        return orphanPIDs(in: listing, udid: udid, toolPath: toolPath)
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
    /// Listing or copying inside an app container talks to the device over its own transport, so
    /// it gets a longer leash than a local `simctl` call — and still a deadline.
    public static let containerDeadline: TimeInterval = 40
}

/// Runs one finite device-discovery command while draining its output concurrently.
///
/// Reading `FileHandle.availableData` on the caller blocks until bytes arrive. Doing that inside a
/// deadline loop made the deadline fictional for the most important failure shape: a child that
/// stayed alive and said nothing. The reader has its own worker now, so the caller can enforce the
/// timeout and reclaim the child independently of whether stdout ever becomes readable.
enum BoundedDeviceLogCommand {
    private static let terminationGrace: TimeInterval = 0.5

    static func run(
        _ executable: String,
        _ arguments: [String],
        deadline seconds: TimeInterval = DeviceLogLimits.discoveryDeadline
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        let processFinished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in processFinished.signal() }
        guard (try? task.run()) != nil else { return nil }

        let output = BoundedDeviceLogCommandOutput()
        let outputFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.drain(pipe.fileHandleForReading)
            outputFinished.signal()
        }

        guard processFinished.wait(timeout: .now() + seconds) == .success else {
            stop(task, processFinished: processFinished)
            try? pipe.fileHandleForReading.close()
            _ = outputFinished.wait(timeout: .now() + terminationGrace)
            return nil
        }

        guard outputFinished.wait(timeout: .now() + terminationGrace) == .success else {
            try? pipe.fileHandleForReading.close()
            return nil
        }
        return output.text()
    }

    private static func stop(_ task: Process, processFinished: DispatchSemaphore) {
        task.terminate()
        guard processFinished.wait(timeout: .now() + terminationGrace) != .success,
              task.isRunning
        else { return }

        _ = Darwin.kill(task.processIdentifier, SIGKILL)
        _ = processFinished.wait(timeout: .now() + terminationGrace)
    }
}

private final class BoundedDeviceLogCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceededLimit = false

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            append(chunk)
        }
    }

    func text() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        guard data.count + chunk.count <= DeviceLogLimits.maximumDiscoveryOutputBytes else {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return
        }
        data.append(chunk)
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

    public init(udid: String, predicate: String?) {
        self.udid = udid
        self.predicate = predicate
    }

    public override func start() {
        var arguments = [
            "simctl", "spawn", udid, "log", "stream", "--style=ndjson", "--level=debug",
        ]
        if let predicate, !predicate.isEmpty {
            arguments.append(contentsOf: ["--predicate", predicate])
        }
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

/// `idevicesyslog` from a paired iPhone.
///
/// Text rather than NDJSON: the syslog relay flattens the unified log, so this is the one source
/// whose rows are parsed out of prose and the one with no subsystem. Whatever the device redacts
/// (`<private>`) stays redacted; only the app's own tap can publish those values, and it does so as
/// ordinary `os_log` entries which arrive here like any other line.
///
/// The tool is libimobiledevice's, never bundled, resolved on the user's `PATH`.
public final class PairedDeviceLogRowSource: BufferedDeviceLogSource {
    private let reader = DeviceLogLineReader(label: "device")
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String

    public init(udid: String, overNetwork: Bool, toolPath: String) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
    }

    public override func start() {
        // A reader we abandoned earlier still holds the relay, and the symptom is silence rather
        // than an error. Reclaim before connecting, or this source starts already broken.
        DeviceRelayReclaim.reclaimOrphanedReaders(udid: udid, toolPath: toolPath)
        var arguments = ["-u", udid, "--no-colors"]
        if overNetwork { arguments.append("-n") }
        reader.run(
            executable: toolPath,
            arguments: arguments,
            onLine: { [weak self] line in
                if let row = DeviceLogDecoding.syslog(line) { self?.enqueue(row) }
            },
            onEnd: { [weak self] reason in self?.onStreamEnded?(reason) }
        )
    }

    public override func stop() { reader.stop() }
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
    private let structuredReader = DeviceLogLineReader(label: "device-structured")
    private let fallbackReader = DeviceLogLineReader(label: "device-fallback")
    private let lifecycle = DispatchQueue(label: "codes.threading.devicelog.device-lifecycle")
    private let decodedLock = NSLock()
    private let udid: String
    private let overNetwork: Bool
    private let toolPath: String
    private let fallbackToolPath: String?
    private let structuredStartupDeadline: TimeInterval
    private var fallbackTimer: DispatchSourceTimer?
    private var stopped = true
    private var fallbackStarted = false
    private var decodedStructuredRows = 0

    public init(
        udid: String,
        overNetwork: Bool,
        toolPath: String,
        fallbackToolPath: String?,
        structuredStartupDeadline: TimeInterval = 6
    ) {
        self.udid = udid
        self.overNetwork = overNetwork
        self.toolPath = toolPath
        self.fallbackToolPath = fallbackToolPath
        self.structuredStartupDeadline = structuredStartupDeadline
    }

    public override func start() {
        lifecycle.sync {
            structuredReader.stop()
            fallbackReader.stop()
            stopped = false
            fallbackStarted = false
            setDecodedStructuredRows(0)
            startStructuredReader()
            scheduleFallbackIfSilent()
        }
    }

    public override func stop() {
        lifecycle.sync {
            stopped = true
            cancelFallbackTimer()
            structuredReader.stop()
            fallbackReader.stop()
        }
    }

    /// Visible to the opt-in hardware test without exposing transport details to the pane.
    public var didDecodeStructuredRow: Bool {
        decodedLock.lock()
        defer { decodedLock.unlock() }
        return decodedStructuredRows > 0
    }

    private func startStructuredReader() {
        structuredReader.run(
            executable: toolPath,
            arguments: [
                "--no-color", "syslog", "live", "--native", "--format", "json",
            ],
            environment: Self.environment(udid: udid),
            onLine: { [weak self] line in
                guard let self, let row = DeviceLogDecoding.pymobiledevice3(line) else { return }
                let isFirstStructuredRow = self.markDecodedStructuredRow()
                self.enqueue(row)
                if isFirstStructuredRow {
                    self.lifecycle.async { [weak self] in self?.cancelFallbackTimer() }
                }
            },
            onEnd: { [weak self] reason in
                self?.structuredReaderEnded(reason: reason)
            }
        )
    }

    private func structuredReaderEnded(reason: String) {
        lifecycle.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.cancelFallbackTimer()
            guard !self.didDecodeStructuredRow, let fallbackToolPath = self.fallbackToolPath else {
                self.onStreamEnded?(reason)
                return
            }
            self.startFallbackOnce(toolPath: fallbackToolPath)
        }
    }

    /// A command that stays alive but never produces a row is not a working route. This is the
    /// exact failure shape of a contended relay, and waiting forever would prevent the fallback
    /// from doing the one job it exists for.
    private func scheduleFallbackIfSilent() {
        guard let fallbackToolPath else { return }
        let timer = DispatchSource.makeTimerSource(queue: lifecycle)
        timer.schedule(deadline: .now() + structuredStartupDeadline)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, !self.didDecodeStructuredRow else { return }
            self.structuredReader.stop()
            self.startFallbackOnce(toolPath: fallbackToolPath)
        }
        fallbackTimer = timer
        timer.resume()
    }

    private func startFallbackOnce(toolPath: String) {
        guard !fallbackStarted else { return }
        fallbackStarted = true
        cancelFallbackTimer()
        startFallbackReader(toolPath: toolPath)
    }

    private func cancelFallbackTimer() {
        fallbackTimer?.setEventHandler {}
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func startFallbackReader(toolPath: String) {
        // The fallback is the same single-client relay as `PairedDeviceLogRowSource`, including
        // its orphan-reclaim rule. Skipping this step can make a successful fallback stay silent.
        DeviceRelayReclaim.reclaimOrphanedReaders(udid: udid, toolPath: toolPath)
        var arguments = ["-u", udid, "--no-colors"]
        if overNetwork { arguments.append("-n") }
        fallbackReader.run(
            executable: toolPath,
            arguments: arguments,
            onLine: { [weak self] line in
                if let row = DeviceLogDecoding.syslog(line) { self?.enqueue(row) }
            },
            onEnd: { [weak self] fallbackReason in
                self?.onStreamEnded?(fallbackReason)
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
    }

    public override func start() {
        reader.run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "device", "process", "launch", "--device", deviceID,
                "--console", "--terminate-existing", bundleID,
            ],
            onLine: { [weak self] line in
                guard let self, let row = self.decode(line) else { return }
                self.enqueue(row)
            },
            onEnd: { [weak self] reason in self?.onStreamEnded?(reason) }
        )
    }

    public override func stop() { reader.stop() }

    /// Raw console output carries no timestamp, level or subsystem of its own, so the row is
    /// stamped on arrival and attributed to the app. A line the app prefixed itself is left alone.
    private func decode(_ line: ArraySlice<UInt8>) -> DeviceLogRow? {
        guard let text = String(bytes: line, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !Self.preamble.contains(where: { trimmed.contains($0) }) else { return nil }
        return DeviceLogRow(
            time: Self.clock.string(from: Date()),
            level: trimmed.contains("[ERROR]") || trimmed.contains("error:") ? "Error" : "Default",
            process: appName,
            subsystem: nil,
            message: trimmed
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
    }

    public override func start() {
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
            timestamp: instant(in: trimmed)
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
        return DeviceLogRow(
            time: time,
            level: (object["messageType"] as? String) ?? "Default",
            process: process,
            subsystem: subsystem,
            message: (object["eventMessage"] as? String) ?? "",
            timestamp: instant(in: object["timestamp"] as? String)
        )
    }

    /// One NDJSON object emitted by `pymobiledevice3 syslog live --format json`.
    ///
    /// Captured from a physical iPhone on iOS 26.6.2. The label is nested rather than using the
    /// macOS `log stream` keys, and contains both subsystem and category. The pane has one label
    /// column, so both are retained there as `subsystem / category`; this also makes either value
    /// searchable and records both in SQLite without a schema fork for one source.
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
        let subsystem = Self.combinedLabel(label)

        return DeviceLogRow(
            time: time,
            level: level,
            process: process,
            subsystem: subsystem,
            message: message,
            timestamp: instant(in: rawTimestamp)
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

    private static func combinedLabel(_ label: [String: Any]?) -> String? {
        guard let label else { return nil }
        let subsystem = (label["subsystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let category = (label["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let components = [subsystem, category].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " / ")
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
        if let bracket = name.range(of: "[", options: .backwards) {
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
            timestamp: instant(in: text)
        )
    }
}

// MARK: - Discovery

/// One thing the pane can be pointed at.
public struct DeviceLogSourceOption: Equatable {
    public enum Kind: Equatable {
        case simulator(udid: String)
        case device(udid: String, overNetwork: Bool)
        case structuredDevice(
            udid: String,
            overNetwork: Bool,
            toolPath: String,
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
    public struct Machine: Equatable, Hashable {
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

    /// Whether an app entry reads the app's own persisted log or its live console. Two genuinely
    /// different contents, so it is a choice rather than a fallback.
    public enum Route: Int, CaseIterable {
        case appLog
        case console

        public var title: String {
            switch self {
            case .appLog: return L10n.string("App log")
            case .console: return L10n.string("Console")
            }
        }
    }

    public func makeSource(predicate: String?, route: Route = .appLog) -> DeviceLogRowSource? {
        switch kind {
        case .simulator(let udid):
            return SimulatorLogRowSource(udid: udid, predicate: predicate)
        case .device(let udid, let overNetwork):
            guard let tool = DeviceLogSourceCatalog.syslogToolPath else { return nil }
            return PairedDeviceLogRowSource(udid: udid, overNetwork: overNetwork, toolPath: tool)
        case .structuredDevice(let udid, let overNetwork, let tool, let fallbackTool):
            return StructuredPairedDeviceLogRowSource(
                udid: udid,
                overNetwork: overNetwork,
                toolPath: tool,
                fallbackToolPath: fallbackTool
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
        completion: @escaping @Sendable ([DeviceLogSourceOption]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let structuredTool = structuredSyslogToolPath(
                preferredPath: preferredPymobiledevice3Path
            )
            let fallbackTool = syslogToolPath
            // A simulator is its own machine and offers exactly one thing to read, so it is a
            // group of one rather than a special case in the menu.
            var options = bootedSimulators().map {
                DeviceLogSourceOption(
                    machine: .init(id: $0.udid, title: $0.name, isSimulator: true),
                    title: L10n.string("System log"),
                    kind: .simulator(udid: $0.udid)
                )
            }
            let devices = pairedDevices()
            for device in devices {
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
                if let structuredTool {
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
                // One entry per app the user builds themselves. This is the route worth reaching
                // for first: live, Apple-native, and unredacted, unlike the system log beside it.
                for app in developerApps(deviceID: device.udid) {
                    options.append(DeviceLogSourceOption(
                        machine: machine,
                        title: app.name,
                        kind: .app(
                            deviceID: device.udid,
                            bundleID: app.bundleID,
                            appName: app.name
                        )
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
    private static func developerApps(deviceID: String) -> [(name: String, bundleID: String)] {
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
        guard let data = try? Data(contentsOf: output),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]]
        else { return [] }
        return apps.compactMap { app -> (String, String)? in
            guard app["builtByDeveloper"] as? Bool == true,
                  let bundleID = app["bundleIdentifier"] as? String,
                  let name = app["name"] as? String
            else { return nil }
            return (name, bundleID)
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        .prefix(DeviceLogLimits.maximumApps)
        .map { (name: $0.0, bundleID: $0.1) }
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
