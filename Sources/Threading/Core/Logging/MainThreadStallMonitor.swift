import Foundation

/// Posted on the main queue once a stall the watchdog saw has ended.
///
/// The incident file and the trace beside it remain the durable record. This exists so a build
/// can say so on screen while the freeze is still the thing the user was looking at, instead of
/// the evidence only being discoverable afterwards by someone who already suspected it.
struct MainThreadStallDidOccur: AppEvent {
    static let name = Notification.Name("mainThreadStallDidOccur")

    let durationMilliseconds: Double

    /// The recorder's bounded semantic span names that were in flight when the stall was seen.
    ///
    /// Empty is the informative case rather than a gap: it means the blocking work is covered by
    /// no span at all, so the owner is somewhere the recorder does not instrument.
    let operationNames: [String]
}

/// Detects long periods in which the main dispatch queue cannot service a trivial ping.
///
/// Its ordinary path does not sample stacks; MetricKit and the bounded semantic trace remain the
/// zero-configuration evidence. A developer can opt into one `/usr/bin/sample` capture per live
/// incident with `THREADING_STALL_SAMPLE=1`, which makes a newly discovered uninstrumented stall
/// actionable without making process launch part of the shipping hot path.
final class MainThreadStallMonitor: @unchecked Sendable {

    static let shared = MainThreadStallMonitor()

    private struct PendingPing {
        let id: UUID
        let sentAtNanoseconds: UInt64
        var detected = false
        var incidentID: UUID?
        /// Captured at detection, because by the time the queue answers the spans that were
        /// blocking it have usually ended.
        var operationNames: [String] = []
    }

    private let recorder: PerformanceRecorder
    private let incidentStore: MainThreadStallIncidentStore
    private let stackSampler: MainThreadStackSampler
    private let thresholdNanoseconds: UInt64
    private let thresholdMilliseconds: Double
    private let queue = DispatchQueue(
        label: "codes.threading.performance.main-thread-watchdog",
        qos: .utility
    )

    /// Accessed only on `queue`.
    private var timer: DispatchSourceTimer?
    private var pendingPing: PendingPing?
    private var mainThreadID: UInt64 = 0

    init(
        recorder: PerformanceRecorder = .shared,
        incidentStore: MainThreadStallIncidentStore = .shared,
        stackSampler: MainThreadStackSampler = MainThreadStackSampler(),
        thresholdMilliseconds: Double = 250
    ) {
        self.recorder = recorder
        self.incidentStore = incidentStore
        self.stackSampler = stackSampler
        if thresholdMilliseconds <= 0 || thresholdMilliseconds.isNaN {
            thresholdNanoseconds = 0
            self.thresholdMilliseconds = 0
        } else if !thresholdMilliseconds.isFinite
                    || thresholdMilliseconds >= Double(UInt64.max) / 1_000_000 {
            thresholdNanoseconds = .max
            self.thresholdMilliseconds = Double(UInt64.max) / 1_000_000
        } else {
            thresholdNanoseconds = UInt64(thresholdMilliseconds * 1_000_000)
            self.thresholdMilliseconds = thresholdMilliseconds
        }
    }

    /// Starts after the first window is visible, excluding deliberate launch setup from stalls.
    /// Must be called from the main thread so the resulting trace carries its real thread ID.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let capturedMainThreadID = PerformanceRecorder.currentThreadID()

        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.mainThreadID = capturedMainThreadID

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.pendingPing = nil
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds

        if var pendingPing {
            if !pendingPing.detected, now &- pendingPing.sentAtNanoseconds >= thresholdNanoseconds {
                pendingPing.detected = true
                let activeOperations = recorder.activeSpanSnapshots()
                pendingPing.operationNames = activeOperations.map(\.name)
                pendingPing.incidentID = incidentStore.begin(
                    thresholdMilliseconds: thresholdMilliseconds,
                    mainThreadID: mainThreadID,
                    activeOperations: activeOperations
                )
                if let incidentID = pendingPing.incidentID {
                    stackSampler.captureIfEnabled(
                        incidentID: incidentID,
                        in: incidentStore.directory
                    )
                }
                self.pendingPing = pendingPing
                recorder.requestAutomaticExport(reason: "main-thread-stall-detected")
                ThreadingLogger.performance.error(
                    "Main thread unresponsive for at least \(self.thresholdMilliseconds, privacy: .public) ms"
                )
            }
            return
        }

        let ping = PendingPing(id: UUID(), sentAtNanoseconds: now, incidentID: nil)
        pendingPing = ping

        DispatchQueue.main.async { [weak self] in
            let answeredAt = DispatchTime.now().uptimeNanoseconds
            self?.queue.async { [weak self] in
                self?.finishPing(id: ping.id, answeredAtNanoseconds: answeredAt)
            }
        }
    }

    private func finishPing(id: UUID, answeredAtNanoseconds: UInt64) {
        guard let ping = pendingPing, ping.id == id else { return }
        pendingPing = nil
        guard ping.detected else { return }

        let elapsed = answeredAtNanoseconds &- ping.sentAtNanoseconds
        let durationMilliseconds = Double(elapsed) / 1_000_000
        if let incidentID = ping.incidentID {
            incidentStore.complete(
                id: incidentID,
                durationMilliseconds: durationMilliseconds
            )
        }
        recorder.recordCompletedInterval(
            "main-thread.stall",
            category: "responsiveness",
            startNanoseconds: ping.sentAtNanoseconds,
            endNanoseconds: answeredAtNanoseconds,
            threadID: mainThreadID,
            metadata: ["duration_ms": String(format: "%.1f", durationMilliseconds)]
        )
        recorder.requestAutomaticExport(reason: "main-thread-stall-completed")

        // Announced only after the queue answered, so the duration is the real one rather than
        // the threshold. Posting onto the queue that just unblocked costs one hop and cannot
        // itself extend the stall it is reporting.
        let operationNames = ping.operationNames
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                MainThreadStallDidOccur(
                    durationMilliseconds: durationMilliseconds,
                    operationNames: operationNames
                )
            )
        }
    }
}

/// Developer-only stack evidence for a live hang, admitted without touching the main actor.
/// One blocked `sample` process cannot create a queue of more samplers behind itself.
final class MainThreadStackSampler: @unchecked Sendable {
    private let enabled: Bool
    private let queue = DispatchQueue(
        label: "codes.threading.performance.main-thread-sample",
        qos: .utility
    )
    private let lock = NSLock()
    private var isSampling = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
#if DEBUG
        enabled = environment["THREADING_STALL_SAMPLE"] == "1"
#else
        enabled = false
#endif
    }

    func captureIfEnabled(incidentID: UUID, in directory: URL) {
        guard enabled else { return }
        lock.lock()
        guard !isSampling else {
            lock.unlock()
            return
        }
        isSampling = true
        lock.unlock()

        queue.async { [self] in
            defer {
                lock.lock()
                isSampling = false
                lock.unlock()
            }
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let destination = directory.appendingPathComponent(
                    "stall-\(incidentID.uuidString.lowercased()).sample.txt"
                )
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = [
                    String(ProcessInfo.processInfo.processIdentifier),
                    "1",
                    "1",
                    "-file",
                    destination.path
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    try? FileManager.default.removeItem(at: destination)
                    return
                }
                if let bytes = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   bytes > 4 * 1_024 * 1_024 {
                    try? FileManager.default.removeItem(at: destination)
                }
            } catch {
                ThreadingLogger.performance.error(
                    "Main-thread stack sample failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }
}
