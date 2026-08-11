import AppKit

/// The one way a workspace pane comes and goes.
///
/// Three panes can leave the main window — the sidebar, the display panel and the shell
/// drawer — and they used to leave three different ways: the sidebar slid when its toolbar
/// toggle asked and snapped when its divider did, the panel always snapped, and the drawer
/// jumped between its two heights. Each surface had restated "how a pane moves" for itself,
/// which is how they drifted. This type is the single statement: every reveal and every
/// dismissal, whatever mechanism drives it — a split item's collapse or a height constraint's
/// constant — runs through `run`, and every divider that can push a pane away asks
/// `dragShutsPane` the same question.
///
/// Under Reduce Motion `Design.Motion.standard` is zero, so the transition is immediate and
/// callers keep one path and one final state.
@MainActor
enum PaneTransition {

#if DEBUG
    struct SynchronousPhaseDurations {
        var changesNanoseconds: UInt64 = 0
        var layoutNanoseconds: UInt64 = 0
        var animationGroupNanoseconds: UInt64 = 0
    }

    private(set) static var lastSynchronousPhaseDurations = SynchronousPhaseDurations()
#endif

    /// How far past its floor a divider must be pushed before the pane shuts instead of
    /// stopping dead.
    ///
    /// Past the floor the pane stops moving under the pointer, so this distance is travelled
    /// with no feedback at all: short enough that carrying on past the stop is the whole
    /// gesture, long enough that letting go a little early does not lose the pane. AppKit's
    /// own rule is *half* the floor — about a hundred points on the sidebar, far enough into
    /// the blind zone that the gesture read as gone.
    static let shutOvershoot: CGFloat = 60

    /// Whether a drag released at `thickness` — the pane the pointer's position would leave —
    /// has pushed far enough past the pane's `floor` to mean "shut".
    ///
    /// The overshoot is capped at half the floor so a shallow pane stays shuttable: the
    /// display panel's floor is its 48pt chrome, and a full overshoot past that lies 12pt
    /// *outside the window* — a release the pointer cannot reach when the window's edge meets
    /// the screen's.
    static func dragShutsPane(thickness: CGFloat, floor: CGFloat) -> Bool {
        thickness < floor - min(shutOvershoot, floor / 2)
    }

    /// Runs a pane's geometry change as the standard transition.
    ///
    /// `changes` applies the new state — a split item's collapse, a constraint's constant —
    /// inside one animation group with implicit animation on, so geometry that depends on the
    /// change moves with it. `view` is the pane's surface: its subtree is laid out inside the
    /// group, which is what makes a bare constraint change animate at all.
    ///
    /// `completion` runs one main-loop turn after the animation's own completion handler,
    /// because AppKit's fires before the final model frames are committed — measured on the
    /// split view, and kept as this route's contract so no caller measures a frame that is
    /// not there yet. `animated: false` keeps the whole contract, including the deferred
    /// completion, and only skips the motion.
    ///
    /// **A window nobody can see gets the final state at once.** Motion there is waste, and
    /// worse than waste: AppKit has been measured withholding an off-screen window's resize
    /// notifications and animation completions (see `MainWindowController.toggleSidebar`),
    /// and every completion below carries real work — a restored width, a cleared guard flag,
    /// a hidden band. This is also what keeps hosted tests deterministic: their windows are
    /// built and never shown, so a fixture asserts final state without waiting out a slide.
    static func run(
        in view: NSView,
        animated: Bool = true,
        changes: () -> Void,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
#if DEBUG
        let runStarted = DispatchTime.now().uptimeNanoseconds
        var changesNanoseconds: UInt64 = 0
        var layoutNanoseconds: UInt64 = 0
#endif
        guard animated, view.window?.isVisible == true else {
            // Still a group, so a caller's `animator()` proxy applies its change immediately
            // instead of reaching for AppKit's default quarter second.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Design.Motion.immediate
#if DEBUG
                let changesStarted = DispatchTime.now().uptimeNanoseconds
#endif
                changes()
#if DEBUG
                changesNanoseconds = DispatchTime.now().uptimeNanoseconds - changesStarted
                let layoutStarted = DispatchTime.now().uptimeNanoseconds
#endif
                view.layoutSubtreeIfNeeded()
#if DEBUG
                layoutNanoseconds = DispatchTime.now().uptimeNanoseconds - layoutStarted
#endif
            }
#if DEBUG
            lastSynchronousPhaseDurations = SynchronousPhaseDurations(
                changesNanoseconds: changesNanoseconds,
                layoutNanoseconds: layoutNanoseconds,
                animationGroupNanoseconds: DispatchTime.now().uptimeNanoseconds - runStarted
            )
#endif
            if let completion { settle(completion) }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
#if DEBUG
            let changesStarted = DispatchTime.now().uptimeNanoseconds
#endif
            changes()
#if DEBUG
            changesNanoseconds = DispatchTime.now().uptimeNanoseconds - changesStarted
            let layoutStarted = DispatchTime.now().uptimeNanoseconds
#endif
            view.layoutSubtreeIfNeeded()
#if DEBUG
            layoutNanoseconds = DispatchTime.now().uptimeNanoseconds - layoutStarted
#endif
        }, completionHandler: completion.map { completion in
            { @Sendable in settle(completion) }
        })
#if DEBUG
        lastSynchronousPhaseDurations = SynchronousPhaseDurations(
            changesNanoseconds: changesNanoseconds,
            layoutNanoseconds: layoutNanoseconds,
            animationGroupNanoseconds: DispatchTime.now().uptimeNanoseconds - runStarted
        )
#endif
    }

    /// The deferred turn, through the main *queue* rather than a main-actor `Task`. AppKit
    /// schedules its own post-collapse layout work on the queue, and only queueing behind it
    /// guarantees the completion runs after that work — the ordering the panel's width
    /// restore was written against; a task hop holds no such promise.
    private nonisolated static func settle(
        _ completion: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.async { MainActor.assumeIsolated(completion) }
    }
}
