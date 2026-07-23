import AppKit
import ThinkingOrbs

/// The dotted "working" thought-orb shown beside the conversation status while
/// a turn is in flight, tinted with the theme accent so it belongs to the
/// current app theme rather than drawing plain black-on-white.
///
/// This is the theme boundary for `ThinkingOrbs.ThinkingOrbView`: feature code
/// never constructs the orb directly, and the one thing the orb cannot do for
/// itself — know Skalman's accent — is wired here. The orb already follows
/// `effectiveAppearance` for light/dark on its own; what it lacks is the
/// *hue*, which the stock view only ever draws in grayscale. `tint` (the seam
/// added to the fork) takes the accent, and it is re-resolved on a live theme
/// switch and on an appearance change, since a CGColor cannot resolve itself
/// afterwards.
///
/// Whether the orb *animates* is not decided here. Visibility is the host's
/// call — the orb runs only while it is on screen and its display link idles
/// the moment it is hidden — so a caller shows it exactly while a turn is in
/// flight and hides it otherwise. Placed in a stack view, a hidden orb detaches
/// and the status text reflows to the leading edge with no reserved gap.
final class WorkingOrbView: NSView {

    // MARK: - Properties

    private let orb: ThinkingOrbView
    private let appEvents = AppEventObservations()
    private var hasPreparedVariant = false

    /// The animation currently drawn. A fixed state is useful to the component
    /// gallery; conversation code calls `selectRandomVariant()` once per turn.
    var state: OrbState { orb.state }

    // MARK: - Initialization

    init(state: OrbState) {
        orb = ThinkingOrbView(state: state, orbSize: .px20)
        super.init(frame: .zero)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        orb = ThinkingOrbView(state: .working, orbSize: .px20)
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        orb = ThinkingOrbView(state: .working, orbSize: .px20)
        super.init(coder: coder)
        commonInit()
    }

    /// Picks a variant for a newly-started working period. Once an orb has
    /// actually been selected, the next selection excludes it so consecutive
    /// turns never happen to show the same animation.
    func selectRandomVariant(
        choosingIndex: (Range<Int>) -> Int = { Int.random(in: $0) }
    ) {
        let candidates = hasPreparedVariant
            ? OrbState.allCases.filter { $0 != orb.state }
            : OrbState.allCases
        guard !candidates.isEmpty else { return }

        orb.state = candidates[choosingIndex(candidates.indices)]
        // These are visual variants of one host state, not semantic status
        // changes: VoiceOver should still hear that the agent is working.
        orb.setAccessibilityLabel(OrbState.working.label)
        hasPreparedVariant = true
    }

    /// Applies the user's choice for one newly-started turn. A fixed choice is
    /// deliberately re-used; Random delegates to the no-immediate-repeat path.
    func prepareForWorking(style: WorkingOrbStyle) {
        guard style != .random else {
            selectRandomVariant()
            return
        }
        guard let state = OrbState(rawValue: style.rawValue) else { return }

        orb.state = state
        orb.setAccessibilityLabel(OrbState.working.label)
        hasPreparedVariant = true
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        orb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(orb)

        // The orb's own intrinsic size (the 20pt preset) drives the wrapper, so
        // the row reserves exactly the orb's footprint and no token guess.
        NSLayoutConstraint.activate([
            orb.leadingAnchor.constraint(equalTo: leadingAnchor),
            orb.trailingAnchor.constraint(equalTo: trailingAnchor),
            orb.topAnchor.constraint(equalTo: topAnchor),
            orb.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        applyTint()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTint() }
    }

    // MARK: - Theme

    /// The accent resolves differently per appearance — a system accent, and a
    /// styled theme's own — so it is resolved under this view's appearance
    /// before being frozen into the CGColor the orb draws with.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        var resolved = Design.Surface.accent.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = Design.Surface.accent.cgColor
        }
        orb.tint = resolved
    }
}
