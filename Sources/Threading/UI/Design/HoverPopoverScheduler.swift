import Foundation

/// When a hover-presented popover opens and closes, stated as one configured policy per site.
///
/// Every hover popover in the app answers the same three questions: how long the pointer must
/// dwell on the anchor before the popover appears, how long the popover survives the pointer
/// leaving, and whether resting on the popover itself counts as staying. Four sites each
/// answered them with their own timers and work items, so a site's feel could only be read out
/// of its timer code — and the sites drifted apart. The scheduler owns the timing; the owner
/// keeps deciding what to present and how to dismiss it.
@MainActor
final class HoverPopoverScheduler {

    /// A site's answers, defined beside its other measurements.
    struct Policy: Equatable {
        /// Dwell before the popover opens, so it does not flash while the pointer is only
        /// crossing the anchor on its way somewhere else. Zero opens on entry.
        let openDelay: TimeInterval

        /// Grace after the pointer leaves the anchor before the popover closes — room to cross
        /// the gap onto the popover, or to clip the anchor's edge without losing the reading.
        /// Zero closes on exit.
        let closeGrace: TimeInterval

        /// Whether the pointer resting on the popover itself holds it open. Right for a
        /// popover that carries actions; meaningless without a `closeGrace` to cross the
        /// gap under.
        let holdsWhilePointerOnPopover: Bool

        /// Visible exactly while the pointer is on the anchor: instant in, instant out, and
        /// the popover itself holds nothing open.
        static let whilePointerOnAnchor = Policy(
            openDelay: 0,
            closeGrace: 0,
            holdsWhilePointerOnPopover: false
        )
    }

    /// Mutable because a site's right answers can follow its content: the usage pill is a
    /// plain reading until an extension composes actionable content into its popover, and a
    /// surface that closes as you reach for its button cannot be operated. A change applies
    /// from the next scheduling decision; work already pending keeps the timing it was
    /// scheduled under.
    var policy: Policy

    /// The owner presents its popover. Re-entrant calls are the owner's to guard: presenting
    /// is idempotent at every site because an open popover is checked before a second one.
    var onPresent: (() -> Void)?
    /// The owner dismisses its popover.
    var onDismiss: (() -> Void)?

    private var pendingOpen: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?

    init(policy: Policy) {
        self.policy = policy
    }

    /// The pointer arrived on the anchor.
    func pointerEntered() {
        cancel(&pendingClose)
        cancel(&pendingOpen)
        if policy.openDelay > 0 {
            pendingOpen = schedule(after: policy.openDelay) { $0.onPresent?() }
        } else {
            onPresent?()
        }
    }

    /// The pointer left the anchor.
    func pointerExited() {
        cancel(&pendingOpen)
        scheduleClose()
    }

    /// The pointer moved onto or off the presented popover itself. Ignored unless the policy
    /// says the popover holds.
    func popoverHoverChanged(_ hovering: Bool) {
        guard policy.holdsWhilePointerOnPopover else { return }
        if hovering {
            cancel(&pendingClose)
        } else {
            scheduleClose()
        }
    }

    /// Drops pending work without presenting or dismissing anything: for row reuse, an anchor
    /// leaving its window, or a click that takes the decision over from the pointer.
    func cancelPendingWork() {
        cancel(&pendingOpen)
        cancel(&pendingClose)
    }

    private func scheduleClose() {
        cancel(&pendingClose)
        if policy.closeGrace > 0 {
            pendingClose = schedule(after: policy.closeGrace) { $0.onDismiss?() }
        } else {
            onDismiss?()
        }
    }

    /// Zero-delay work does not come through here: it runs synchronously at the call site — an
    /// exit with no grace must close the popover before whatever the pointer went on to do —
    /// and it runs *after* the pending slot is settled. Every owner's dismiss re-enters
    /// `cancelPendingWork`, so a synchronous callback made while a slot is still being written
    /// (say, through an `inout` parameter) is two accesses to the same property at once.
    private func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor (HoverPopoverScheduler) -> Void
    ) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    private func cancel(_ slot: inout DispatchWorkItem?) {
        slot?.cancel()
        slot = nil
    }
}
