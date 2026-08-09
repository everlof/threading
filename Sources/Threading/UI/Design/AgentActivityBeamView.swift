import AppKit
import BorderBeamKit

enum ActivityBeamDefaults {
    /// One working agent reads clearly (the beam library's own playground
    /// defaults to 0.7); each additional agent adds a step until the cap of 1.
    static let baseStrength: Double = 0.3
    static let strengthPerAdditionalAgent: Double = 0.1
}

/// The breathing border ring that says "agents are working somewhere in this
/// app" — the theme boundary for `BorderBeamKit`, the way `WorkingOrbView` is
/// for ThinkingOrbs. A host pins this view over the surface to ring and
/// restates the workload; everything visual is decided here: the
/// count-to-strength curve, the adaptive mono ring escalating to colorful
/// when any working session runs at the top of its provider's reasoning
/// ladder, and the theme and motion gates.
///
/// The beam belongs to the stock look only. A styled theme — every retro
/// chrome especially — states its own idea of depth and glow, and a breathing
/// gradient over a Platinum bevel would be nobody's. Anything but System
/// therefore removes the ring outright (`AppThemePalette.current.isSystem`,
/// re-read on `AppThemeDidChange` like every themed surface), immediately
/// rather than through the beam's own fade: the theme sweep repaints the
/// window in one pass, and a half-second of trailing glow would tail it.
///
/// Under Reduce Motion the ring stays (an indeterminate status view may
/// remain visible) but renders a genuinely static frame — the host view's
/// paused mode, not an animation drawing identical frames. On macOS 13 the
/// Shader API does not exist and the view is simply empty.
final class AgentActivityBeamView: NSView {

    // MARK: - Properties

    private let appEvents = AppEventObservations()
    private var workload: AgentWorkload = .none
    /// `BorderBeamHostView` behind its availability gate; nil until first
    /// needed, and forever on macOS 13.
    private var beamHost: NSView?
    /// The curve's last non-zero answer, kept so the fade-out after the count
    /// reaches zero keeps its brightness instead of snapping to the floor.
    private var lastStrength = ActivityBeamDefaults.baseStrength

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
    }

    // MARK: - Public Methods

    /// Restates the facts the ring draws. Equal restatements cost nothing.
    func update(workload: AgentWorkload) {
        guard workload != self.workload else { return }
        self.workload = workload
        apply()
    }

    // MARK: - Decorative contract

    /// Never claims a click; the surface this rings stays interactive.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Private Methods

    private func apply() {
        guard #available(macOS 14.0, *) else { return }
        let onSystemTheme = AppThemePalette.current.isSystem
        let working = workload.workingCount > 0

        // Nothing to draw and nothing drawn: stay empty rather than mounting
        // a host to tell it to be inactive.
        guard working || beamHost != nil else { return }

        let host = ensureBeamHost()
        host.isHidden = !onSystemTheme
        if working {
            lastStrength = min(
                ActivityBeamDefaults.baseStrength
                    + ActivityBeamDefaults.strengthPerAdditionalAgent
                    * Double(workload.workingCount - 1),
                1
            )
        }
        host.configuration = BorderBeamHostView.Configuration(
            size: .pulseInner,
            colorVariant: workload.anyAtTopEffort ? .colorful : .mono,
            theme: .auto,
            active: working && onSystemTheme,
            borderRadius: Double(SurfaceRadius.panel.current),
            strength: lastStrength
        )
        host.rendersStatically = Design.Motion.reducesMotion
    }

    @available(macOS 14.0, *)
    private func ensureBeamHost() -> BorderBeamHostView {
        if let host = beamHost as? BorderBeamHostView { return host }
        let host = BorderBeamHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        beamHost = host
        return host
    }

    // MARK: - Test seams

    // The judgement rather than the pixels, in plain types: the package must
    // not leak through this component's surface even to a test — containment
    // includes API shape. All nil while nothing has ever needed drawing (and
    // forever on macOS 13).

    @available(macOS 14.0, *)
    private var hostForTesting: BorderBeamHostView? { beamHost as? BorderBeamHostView }

    var appliedStrengthForTesting: Double? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.configuration.strength
    }

    var appliedActiveForTesting: Bool? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.configuration.active
    }

    var appliedVariantIsColorfulForTesting: Bool? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.configuration.colorVariant == .colorful
    }

    var appliedVariantIsMonoForTesting: Bool? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.configuration.colorVariant == .mono
    }

    var appliedBorderRadiusForTesting: Double? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.configuration.borderRadius
    }

    var appliedRendersStaticallyForTesting: Bool? {
        guard #available(macOS 14.0, *) else { return nil }
        return hostForTesting?.rendersStatically
    }

    var isBeamMountedAndShowingForTesting: Bool {
        guard let beamHost else { return false }
        return !beamHost.isHidden
    }
}
