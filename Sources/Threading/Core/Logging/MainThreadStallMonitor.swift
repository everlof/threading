import Foundation

/// Detects long periods in which the main dispatch queue cannot service a trivial ping.
///
/// This deliberately does not sample stacks; MetricKit, `sample` and `xctrace` do that without
/// private APIs. Its job is to immediately persist the app-level operation that was in flight,
/// then leave the richer timestamped trace beside it.
final class MainThreadStallMonitor: @unchecked Sendable {

    static let shared = MainThreadStallMonitor()

    private struct PendingPing {
        let id: UUID
        let sentAtNanoseconds: UInt64
        var detected = false
        var incidentID: UUID?
    }

    private let recorder: PerformanceRecorder
    private let incidentStore: MainThreadStallIncidentStore
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
        thresholdMilliseconds: Double = 250
    ) {
        self.recorder = recorder
        self.incidentStore = incidentStore
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
                pendingPing.incidentID = incidentStore.begin(
                    thresholdMilliseconds: thresholdMilliseconds,
                    mainThreadID: mainThreadID,
                    activeOperations: recorder.activeSpanSnapshots()
                )
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
    }
}
