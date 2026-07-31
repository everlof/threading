import Foundation

/// Detects long periods in which the main dispatch queue cannot service a trivial ping.
///
/// This deliberately does not sample stacks; `sample` and `xctrace` do that better and without
/// private APIs. Its job is to leave a timestamped trace of the app-level operation that was in
/// flight, then let a repeatable CLI capture explain the stack.
final class MainThreadStallMonitor: @unchecked Sendable {

    static let shared = MainThreadStallMonitor()

    private struct PendingPing {
        let id: UUID
        let sentAtNanoseconds: UInt64
        var detected = false
    }

    private let recorder: PerformanceRecorder
    private let thresholdNanoseconds: UInt64
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
        thresholdMilliseconds: Double = 250
    ) {
        self.recorder = recorder
        if thresholdMilliseconds <= 0 || thresholdMilliseconds.isNaN {
            thresholdNanoseconds = 0
        } else if !thresholdMilliseconds.isFinite
                    || thresholdMilliseconds >= Double(UInt64.max) / 1_000_000 {
            thresholdNanoseconds = .max
        } else {
            thresholdNanoseconds = UInt64(thresholdMilliseconds * 1_000_000)
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
                self.pendingPing = pendingPing
                recorder.requestAutomaticExport(reason: "main-thread-stall-detected")
                ThreadingLogger.performance.error("Main thread unresponsive for at least 250 ms")
            }
            return
        }

        let ping = PendingPing(id: UUID(), sentAtNanoseconds: now)
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
        recorder.recordCompletedInterval(
            "main-thread.stall",
            category: "responsiveness",
            startNanoseconds: ping.sentAtNanoseconds,
            endNanoseconds: answeredAtNanoseconds,
            threadID: mainThreadID,
            metadata: ["duration_ms": String(format: "%.1f", Double(elapsed) / 1_000_000)]
        )
        recorder.requestAutomaticExport(reason: "main-thread-stall-completed")
    }
}
