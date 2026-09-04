import Foundation

/// Proves that a visible direct stream is still delivering frames.
///
/// The helper captures at a fixed rate whenever the pane is visible, so silence is never a quiet
/// screen: it means the helper, its encoder or the framebuffer stopped. The stream's ready state
/// otherwise rests on the handshake alone, and a helper that hangs after one frame would keep the
/// pane's live label for as long as the tab stays open. A stall ends the stream through the same
/// failure path as a helper loss, so the pane shows a reason, falls back and offers retry.
///
/// Every method runs on `queue`; the stall callback is delivered on that queue too.
final class SimulatorFrameLivenessMonitor {
    static let defaultDeadline: DispatchTimeInterval = .seconds(4)

    private let queue: DispatchQueue
    private let deadline: DispatchTimeInterval
    private let onStall: () -> Void
    private var isVisible = false
    private var isInvalidated = false
    private var pending: DispatchWorkItem?

    init(
        queue: DispatchQueue,
        deadline: DispatchTimeInterval = SimulatorFrameLivenessMonitor.defaultDeadline,
        onStall: @escaping () -> Void
    ) {
        self.queue = queue
        self.deadline = deadline
        self.onStall = onStall
    }

    /// A visible stream owes a frame within the deadline; a hidden one owes nothing.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { arm() } else { disarm() }
    }

    func frameArrived() {
        guard isVisible else { return }
        arm()
    }

    func invalidate() {
        isInvalidated = true
        disarm()
    }

    private func arm() {
        guard !isInvalidated else { return }
        disarm()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isInvalidated, self.isVisible else { return }
            self.pending = nil
            self.onStall()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + deadline, execute: item)
    }

    private func disarm() {
        pending?.cancel()
        pending = nil
    }
}
