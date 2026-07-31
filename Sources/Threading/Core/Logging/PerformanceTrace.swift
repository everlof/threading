import Foundation
import OSLog

/// A low-overhead, always-on record of coarse operations.
///
/// Every span is also an OS signpost, so Instruments and `xctrace` can correlate our semantic
/// operation names with CPU, allocation, and hitch data. The bounded in-memory copy exists for
/// the other direction: when the main thread stalls, the app can write a Chrome Trace file
/// without requiring Instruments to have been attached before the problem happened.
///
/// Metadata must remain aggregate and low-cardinality. Paths, diff contents, prompts, and other
/// user data do not belong here.
final class PerformanceRecorder: @unchecked Sendable {

    struct Configuration: Sendable {
        var eventCapacity = 4_096
        var reportLimit = 20
        var slowMainThreadMilliseconds = 100.0
        var automaticExportCooldownSeconds = 30.0
    }

    static let shared = PerformanceRecorder()

    let directory: URL

    private let configuration: Configuration
    private let signposter = OSSignposter(
        subsystem: "codes.threading",
        category: .pointsOfInterest
    )
    private let exportQueue = DispatchQueue(
        label: "codes.threading.performance.export",
        qos: .utility
    )

    /// Guards `events`, `activeSpans`, and the automatic-export cooldown.
    private let lock = NSLock()
    private var events: [TraceEvent] = []
    private var activeSpans: [UUID: ActiveSpan] = [:]
    private var lastAutomaticExportNanoseconds: UInt64 = 0

    init(directory: URL? = nil, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.directory = directory ?? AppDataLocations.supportDirectory
            .appendingPathComponent("Performance", isDirectory: true)
            .appendingPathComponent("Traces", isDirectory: true)
    }

    /// Begins a span that may cross a queue or actor boundary.
    ///
    /// The name is a `StaticString` because signpost names are part of the trace schema, not
    /// arbitrary runtime data. Put counts and state in metadata instead.
    func begin(
        _ name: StaticString,
        category: StaticString,
        metadata: [String: String] = [:]
    ) -> PerformanceSpan {
        let id = UUID()
        let start = DispatchTime.now().uptimeNanoseconds
        let threadID = Self.currentThreadID()
        let sanitizedMetadata = Self.sanitized(metadata)
        let signpostState = signposter.beginInterval(name)

        let active = ActiveSpan(
            id: id,
            name: String(describing: name),
            category: String(describing: category),
            startNanoseconds: start,
            threadID: threadID,
            metadata: sanitizedMetadata,
            beganOnMainThread: Thread.isMainThread
        )

        withLock {
            // Runaway active spans would otherwise defeat the recorder's bounded-memory promise.
            if activeSpans.count >= 256, let oldest = activeSpans.values.min(
                by: { $0.startNanoseconds < $1.startNanoseconds }
            ) {
                activeSpans.removeValue(forKey: oldest.id)
            }
            activeSpans[id] = active
        }

        return PerformanceSpan(
            recorder: self,
            id: id,
            name: name,
            signpostState: signpostState
        )
    }

    /// Measures a synchronous operation while preserving its return value and thrown error.
    @discardableResult
    func measure<T>(
        _ name: StaticString,
        category: StaticString,
        metadata: [String: String] = [:],
        operation: () throws -> T
    ) rethrows -> T {
        let span = begin(name, category: category, metadata: metadata)
        defer { span.end() }
        return try operation()
    }

    /// Writes the current bounded history and in-flight spans as a Chrome Trace JSON file.
    ///
    /// This is synchronous for explicit support/debug actions and deterministic tests. Automatic
    /// stall exports use `requestAutomaticExport`, which moves file I/O to a utility queue.
    @discardableResult
    func export(reason: String) throws -> URL {
        let document = snapshot(reason: reason)
        return try write(document)
    }

    /// Asks for a best-effort trace without blocking the caller. Requests are rate-limited so a
    /// persistent stall does not turn into a disk-write storm.
    func requestAutomaticExport(reason: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let cooldown = Self.nanoseconds(seconds: configuration.automaticExportCooldownSeconds)

        let shouldExport = withLock { () -> Bool in
            guard lastAutomaticExportNanoseconds == 0
                    || now &- lastAutomaticExportNanoseconds >= cooldown else {
                return false
            }
            lastAutomaticExportNanoseconds = now
            return true
        }
        guard shouldExport else { return }

        let document = snapshot(reason: reason)
        exportQueue.async { [weak self] in
            guard let self else { return }
            do {
                let url = try self.write(document)
                ThreadingLogger.performance.notice(
                    "Automatic performance trace: \(url.path, privacy: .public)"
                )
            } catch {
                ThreadingLogger.performance.error(
                    "Performance trace export failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Adds an interval discovered after it completed, used by the main-thread watchdog.
    func recordCompletedInterval(
        _ name: String,
        category: String,
        startNanoseconds: UInt64,
        endNanoseconds: UInt64,
        threadID: UInt64,
        metadata: [String: String] = [:]
    ) {
        guard endNanoseconds >= startNanoseconds else { return }

        append(TraceEvent(
            name: name,
            category: category,
            startNanoseconds: startNanoseconds,
            durationNanoseconds: endNanoseconds - startNanoseconds,
            processID: ProcessInfo.processInfo.processIdentifier,
            threadID: threadID,
            metadata: Self.sanitized(metadata),
            incomplete: false
        ))
    }

    fileprivate func end(
        id: UUID,
        name: StaticString,
        signpostState: OSSignpostIntervalState,
        metadata: [String: String]
    ) {
        signposter.endInterval(name, signpostState)
        let end = DispatchTime.now().uptimeNanoseconds
        let endedOnMainThread = Thread.isMainThread

        guard var active = withLock({ activeSpans.removeValue(forKey: id) }) else { return }
        active.metadata.merge(Self.sanitized(metadata), uniquingKeysWith: { _, new in new })

        let event = TraceEvent(
            name: active.name,
            category: active.category,
            startNanoseconds: active.startNanoseconds,
            durationNanoseconds: end &- active.startNanoseconds,
            processID: ProcessInfo.processInfo.processIdentifier,
            threadID: active.threadID,
            metadata: active.metadata,
            incomplete: false
        )
        append(event)

        let slowThreshold = Self.nanoseconds(
            seconds: configuration.slowMainThreadMilliseconds / 1_000
        )
        // A cross-queue operation can be enqueued from main and finish on a worker. Its elapsed
        // time is useful, but it did not occupy main for that interval. Requiring both endpoints
        // keeps the automatic stall signal about synchronous main-thread work.
        if active.beganOnMainThread, endedOnMainThread,
           event.durationNanoseconds >= slowThreshold {
            requestAutomaticExport(reason: "slow-main-span:\(active.name)")
        }
    }

    static func currentThreadID() -> UInt64 {
        var identifier: UInt64 = 0
        pthread_threadid_np(nil, &identifier)
        return identifier
    }

    /// Saturating conversion for configuration values. `UInt64(Double.infinity)` traps, and a
    /// diagnostic facility should never be able to take the app down because a threshold was
    /// deliberately disabled with a very large value.
    private static func nanoseconds(seconds: Double) -> UInt64 {
        guard seconds.isFinite else { return seconds.sign == .minus ? 0 : .max }
        guard seconds > 0 else { return 0 }

        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds < Double(UInt64.max) else { return .max }
        return UInt64(nanoseconds)
    }

    private func append(_ event: TraceEvent) {
        withLock {
            events.append(event)
            let overflow = events.count - max(configuration.eventCapacity, 1)
            if overflow > 0 {
                events.removeFirst(overflow)
            }
        }
    }

    private func snapshot(reason: String) -> TraceDocument {
        let now = DispatchTime.now().uptimeNanoseconds

        return withLock {
            var snapshotEvents = events
            snapshotEvents.append(contentsOf: activeSpans.values.map { span in
                TraceEvent(
                    name: span.name,
                    category: span.category,
                    startNanoseconds: span.startNanoseconds,
                    durationNanoseconds: now &- span.startNanoseconds,
                    processID: ProcessInfo.processInfo.processIdentifier,
                    threadID: span.threadID,
                    metadata: span.metadata,
                    incomplete: true
                )
            })
            snapshotEvents.sort { $0.startNanoseconds < $1.startNanoseconds }

            return TraceDocument(
                traceEvents: snapshotEvents.map(ChromeTraceEvent.init),
                displayTimeUnit: "ms",
                otherData: [
                    "reason": String(reason.prefix(160)),
                    "process": ProcessInfo.processInfo.processName
                ]
            )
        }
    }

    private func write(_ document: TraceDocument) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent(
            "trace-\(milliseconds)-\(UUID().uuidString.lowercased()).json"
        )
        try data.write(to: url, options: .atomic)
        pruneReports()
        return url
    }

    private func pruneReports() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "json" }) else { return }

        let ordered = candidates.sorted {
            let left = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let right = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }

        for url in ordered.dropFirst(max(configuration.reportLimit, 1)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func sanitized(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }).prefix(16) {
            // Two long keys may share the same 64-character prefix. Assignment deliberately
            // makes that collision deterministic rather than letting Dictionary's
            // `uniqueKeysWithValues` initializer trap inside the diagnostic path.
            result[String(key.prefix(64))] = String(value.prefix(160))
        }
        return result
    }
}

/// A manually-ended span token. Deinitialization closes abandoned spans so recorder state stays
/// bounded even when an early return forgets to do so explicitly.
final class PerformanceSpan: @unchecked Sendable {

    private weak var recorder: PerformanceRecorder?
    private let id: UUID
    private let name: StaticString
    private let signpostState: OSSignpostIntervalState

    /// Guards `hasEnded`; ending from an async completion and cancellation may race.
    private let lock = NSLock()
    private var hasEnded = false

    fileprivate init(
        recorder: PerformanceRecorder,
        id: UUID,
        name: StaticString,
        signpostState: OSSignpostIntervalState
    ) {
        self.recorder = recorder
        self.id = id
        self.name = name
        self.signpostState = signpostState
    }

    func end(metadata: [String: String] = [:]) {
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        lock.unlock()

        recorder?.end(
            id: id,
            name: name,
            signpostState: signpostState,
            metadata: metadata
        )
    }

    deinit {
        end(metadata: ["result": "abandoned"])
    }
}

private struct ActiveSpan {
    let id: UUID
    let name: String
    let category: String
    let startNanoseconds: UInt64
    let threadID: UInt64
    var metadata: [String: String]
    let beganOnMainThread: Bool
}

private struct TraceEvent {
    let name: String
    let category: String
    let startNanoseconds: UInt64
    let durationNanoseconds: UInt64
    let processID: Int32
    let threadID: UInt64
    let metadata: [String: String]
    let incomplete: Bool
}

private struct TraceDocument: Encodable, Sendable {
    let traceEvents: [ChromeTraceEvent]
    let displayTimeUnit: String
    let otherData: [String: String]
}

private struct ChromeTraceEvent: Encodable, Sendable {
    let name: String
    let cat: String
    let ph = "X"
    let ts: Double
    let dur: Double
    let pid: Int32
    let tid: UInt64
    let args: [String: String]

    init(_ event: TraceEvent) {
        name = event.name
        cat = event.category
        ts = Double(event.startNanoseconds) / 1_000
        dur = Double(event.durationNanoseconds) / 1_000
        pid = event.processID
        tid = event.threadID

        var arguments = event.metadata
        if event.incomplete {
            arguments["incomplete"] = "true"
        }
        args = arguments
    }
}
