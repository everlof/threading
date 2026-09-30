import AppKit
import ThreadingRemoteKit

/// A non-drawing lifecycle observer for a backdrop layer. A zero-size child gets AppKit's
/// attach/detach and ancestor-hide callbacks without moving or reparenting the real content.
/// Only an authored moving gradient installs one; static themes keep their existing view tree.
final class ThemeBackdropMotionView: NSView, ThemedComponent {
    private let animator: ThemeGradientAnimator
    var permitsMotion: () -> Bool = {
        !Design.Motion.reducesMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    var windowIsVisible: (NSWindow) -> Bool = {
        $0.occlusionState.contains(.visible) && !$0.isMiniaturized
    }

    init(gradient: CAGradientLayer) {
        animator = ThemeGradientAnimator(layer: gradient)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(angleDegrees: Double, drift: ThemeGradientDrift, frozenPhase: Double? = nil) {
        animator.configure(angleDegrees: angleDegrees, flipped: false, drift: drift, frozenPhase: frozenPhase)
        refreshMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(refreshMotion), name: name, object: window
                )
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(powerStateChanged),
                name: .NSProcessInfoPowerStateDidChange, object: nil
            )
        }
        refreshMotion()
    }

    override func viewDidHide() { super.viewDidHide(); refreshMotion() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshMotion() }

    @objc func refreshMotion() {
        animator.setActive(
            window.map(windowIsVisible) == true && !isHiddenOrHasHiddenAncestor && permitsMotion()
        )
    }

    @objc nonisolated private func powerStateChanged() {
        Task { @MainActor [weak self] in self?.refreshMotion() }
    }

    func stop() {
        animator.stop()
        removeFromSuperview()
    }
}
