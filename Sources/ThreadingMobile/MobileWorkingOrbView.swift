import SwiftUI
import ThinkingOrbs
import UIKit

/// The dotted "working" thought-orb, tinted with the remote theme's accent so it belongs to the
/// chrome the Mac sent rather than drawing plain black-on-white.
///
/// This is the mobile theme boundary for `ThinkingOrbs.ThinkingOrbView`, the counterpart of the
/// Mac's `WorkingOrbView`: feature code never constructs the orb directly, and the one thing the
/// orb cannot do for itself — know Threading's accent — is wired here. The phone's palette is
/// the Mac's resolved theme, not the system appearance, so the substrate is taken from
/// `RemoteThemePalette.colorScheme` rather than from `traitCollection`.
///
/// Whether the orb *animates* is not decided here. Visibility is the host's call — the orb runs
/// only while it is on screen and its display link idles the moment it is hidden — so a caller
/// shows it exactly while a turn is in flight and hides it otherwise. Inside a `UIStackView` a
/// hidden orb detaches and the row reflows with no reserved gap.
@MainActor
final class MobileWorkingOrbView: UIView {

    // MARK: - Properties

    private let orb: ThinkingOrbView
    private var hasPreparedVariant = false
    /// A screenshot fixture has to be the same picture on every run, which an orb that both
    /// animates and re-rolls its variant per turn never is. Pinned, it keeps one deterministic
    /// frame of one deterministic animation — still the real component, just stopped.
    private let isPinnedForEvidence: Bool

    /// Which of the nine animations is currently drawn, by name. The `OrbState` itself stays
    /// behind this boundary: this wrapper is the only place in the phone app that names a
    /// ThinkingOrbs type.
    var variantName: String { orb.state.rawValue }

    // MARK: - Initialization

    /// - Parameter diameter: the footprint the orb should occupy. The package ships two tuned
    ///   presets, 64pt and 20pt, and they are separate designs rather than one scale factor — so
    ///   a host asking for something between them gets the nearer preset drawn at that size
    ///   rather than a differently-tuned orb. Default is the preset's own 20pt, untouched.
    init(diameter: CGFloat = Constants.presetSize) {
        orb = ThinkingOrbView(state: .working, orbSize: .px20)
        isPinnedForEvidence =
            ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] != nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(orb)
        // The orb lays out at its own preset size and is scaled about its centre, because a
        // smaller frame would crop the drawing rather than shrink it: the engine always paints
        // the preset's diameter, centred in whatever bounds it is given. Auto Layout works on
        // the untransformed frame, so the constraints stay honest and only the pixels scale.
        NSLayoutConstraint.activate([
            orb.centerXAnchor.constraint(equalTo: centerXAnchor),
            orb.centerYAnchor.constraint(equalTo: centerYAnchor),
            orb.widthAnchor.constraint(equalToConstant: Constants.presetSize),
            orb.heightAnchor.constraint(equalTo: orb.widthAnchor),
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalTo: widthAnchor),
        ])
        if diameter != Constants.presetSize {
            let scale = diameter / Constants.presetSize
            orb.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        isAccessibilityElement = false
        orb.accessibilityLabel = MobileL10n.string("Working…")
        // Freezing the frame rather than hiding the orb keeps the evidence honest about what
        // the navigation title looks like mid-turn.
        if isPinnedForEvidence {
            orb.staticFrameTime = Constants.evidenceFrameTime
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Picks a variant for a newly-started working period, the way the Mac's Random motion
    /// preference does. Once a variant has actually been shown the next selection excludes it,
    /// so consecutive turns never happen to draw the same animation.
    func prepareForWorking(choosingIndex: (Range<Int>) -> Int = { Int.random(in: $0) }) {
        guard !isPinnedForEvidence else { return }
        let candidates = hasPreparedVariant
            ? OrbState.allCases.filter { $0 != orb.state }
            : OrbState.allCases
        guard !candidates.isEmpty else { return }

        orb.state = candidates[choosingIndex(candidates.indices)]
        // These are visual variants of one host state, not semantic status changes: VoiceOver
        // should still hear that the agent is working.
        orb.accessibilityLabel = MobileL10n.string("Working…")
        hasPreparedVariant = true
    }

    /// The accent is frozen into a `CGColor`, which cannot re-resolve itself, so this is called
    /// again from the host's own `applyTheme` whenever the Mac sends a new theme.
    func applyTheme(_ theme: RemoteThemePalette) {
        orb.tint = theme.uiAccent.resolvedColor(with: traitCollection).cgColor
        orb.theme = theme.colorScheme == .light ? .light : .dark
    }

    // MARK: - Constants

    private enum Constants {
        /// The inline preset this wrapper draws; the package's other one is the 64pt avatar.
        static let presetSize: CGFloat = 20
        /// The frame Reduce Motion and `ThinkingOrbFrame` both settle on.
        static let evidenceFrameTime = 0.6
    }
}

/// The working orb for a SwiftUI host: the dashboard row shows one at its trailing edge, in the
/// age's place, while the chat is mid-turn.
///
/// The row used to spell "Working" in its caption. The word cost the caption line its width and
/// said less than motion does in a list — a still row and a moving row are told apart from across
/// the room. The wrapper is the whole SwiftUI seam: it re-applies the theme when the Mac sends a
/// new one, and picks the turn's variant once when the orb comes on screen. A row is built lazily
/// and torn down when scrolled off, so the orb runs only while its row is visible.
struct MobileWorkingOrb: UIViewRepresentable {
    let diameter: CGFloat
    let theme: RemoteThemePalette

    func makeUIView(context: Context) -> MobileWorkingOrbView {
        let orb = MobileWorkingOrbView(diameter: diameter)
        orb.prepareForWorking()
        orb.applyTheme(theme)
        return orb
    }

    func updateUIView(_ orb: MobileWorkingOrbView, context: Context) {
        orb.applyTheme(theme)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MobileWorkingOrbView,
        context: Context
    ) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}
