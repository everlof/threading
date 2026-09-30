import ThreadingRemoteKit
import UIKit

/// The dashboard's stationary ground. One layer fills the viewport independently of its
/// virtualized rows. Themes supply decoration; the host retains hit testing, navigation,
/// accessibility, power policy and the exact scroll position.
final class MobileThemeBackdropView: UIView {
    private let gradient = CAGradientLayer()
    private lazy var animator = ThemeGradientAnimator(layer: gradient)
    private var recipe: RemoteThemeGradient?
#if DEBUG
    private static let evidencePhase: Double? = {
        guard let id = ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] else { return nil }
        return id.contains("drift-quarter") ? 0.25 : 0
    }()
#endif
    var isPresentationActive = false { didSet { refreshMotion() } }
    var permitsMotion: () -> Bool = {
        !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    var sceneIsActive: (UIWindow) -> Bool = { $0.windowScene?.activationState == .foregroundActive }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        gradient.isHidden = true
        layer.addSublayer(gradient)
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification,
                     UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); refreshMotion() }

    override var isHidden: Bool { didSet { refreshMotion() } }

    func apply(_ theme: RemoteThemePalette, frozenPhase: Double? = nil) {
        var phase = frozenPhase
#if DEBUG
        phase = phase ?? Self.evidencePhase
#endif
        backgroundColor = theme.uiGround
        let candidate = theme.source?.material.backdropGradient
        let valid = candidate.flatMap { $0.hasValidGeometry ? $0 : nil }
        // Only a theme replacement sorts/decodes stops. Routine catalogue updates keep both
        // the layer and its animation, and cannot reset the phase.
        if valid != recipe {
            recipe = valid
            let ordered = valid?.stops.sorted { $0.position < $1.position } ?? []
            let colors = ordered.compactMap { UIColor(remoteHex: $0.color)?.cgColor }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.isHidden = colors.isEmpty || colors.count != ordered.count
            gradient.colors = gradient.isHidden ? nil : colors
            gradient.locations = ordered.map { NSNumber(value: $0.position) }
            CATransaction.commit()
        }
        animator.configure(
            angleDegrees: valid?.angleDegrees ?? 180, flipped: true,
            drift: valid?.drift, frozenPhase: phase
        )
        refreshMotion()
    }

    @objc private func environmentChanged(_ notification: Notification) {
        // willDeactivate is delivered before activationState changes. Stop immediately, and
        // only resume on didActivate once this particular scene reports itself active.
        if notification.name == UIScene.willDeactivateNotification,
           let scene = notification.object as? UIScene, scene === window?.windowScene {
            animator.setActive(false)
        } else {
            refreshMotion()
        }
    }

    func refreshMotion() {
        animator.setActive(
            isPresentationActive && !gradient.isHidden && !isHidden
                && window.map(sceneIsActive) == true && permitsMotion()
        )
    }

    @objc nonisolated private func powerStateChanged() {
        Task { @MainActor [weak self] in self?.refreshMotion() }
    }

    var isAnimating: Bool { gradient.animation(forKey: ThemeGradientAnimator.animationKey) != nil }
    var showsGradient: Bool { !gradient.isHidden }
}
