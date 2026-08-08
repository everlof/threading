import AppKit

/// Shows what a session is doing: a spinner while it works, a mark when it wants the user, and
/// nothing otherwise.
///
/// Running-versus-dormant is conveyed by the row's text colour rather than a permanent dot,
/// so the indicator is reserved for states that actually warrant attention.
///
/// **The two dots are ranked by what they cost.** A session blocked on a question has stopped
/// until it is answered, so it takes the filled warning dot; one that merely finished off screen
/// is unread, not stuck, so it takes a hollow accent ring. Filled-versus-hollow carries the
/// distinction on its own, which is what keeps it legible under Differentiate Without Colour.
///
/// **A stop the user cannot answer leaves that ranking entirely** and takes a triangle. A session
/// refused for a spent usage limit is not waiting on anybody: no dot fits it, and the state it
/// used to wear instead — a spinner, because no hook fires for a refused turn — said the opposite
/// of what had happened for as long as the session was left alone. See
/// [`limit-recovery.md`](../../../../docs/architecture/limit-recovery.md).
final class SessionStatusIndicator: NSView {

    // MARK: - Properties

    private let spinner = ThemedSpinner()
    private let attentionDot = NSView()
    private let limitMark = ThemedWarningMark()

    /// A ground the containing row paints over the sidebar surface.
    ///
    /// Status colours are meaningful on the ordinary row, but an emphasized selection replaces
    /// that ground with the accent itself. The marks keep their distinct silhouettes and take the
    /// selection's legible ink while they are inside it.
    var hostGround: InkSource? {
        didSet {
            guard hostGround != oldValue else { return }
            spinner.hostGround = hostGround
            limitMark.hostGround = hostGround
            applyDotSurface()
        }
    }

    /// Which of the two marks the dot is currently drawn as.
    private enum DotStyle {
        /// A turn stopped on a question: filled, in the warning role.
        case blocked
        /// A turn that ended unseen: a hollow accent ring.
        case unread
    }

    /// Held rather than derived at draw time, because the appearance can change under a mark
    /// that is already showing and the surface has to be laid down again for the new theme.
    private var dotStyle: DotStyle = .unread

    /// Rows are reconfigured far more often than their state changes, so repeated updates
    /// for the same state are ignored — otherwise the dot's entrance would replay.
    private var currentState: (activity: SessionActivity, isLoading: Bool)?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: StatusIndicatorDefaults.size, height: StatusIndicatorDefaults.size)
    }

    // MARK: - Setup

    private func setupViews() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel(L10n.string("Session working"))

        applyDotSurface()
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.setAccessibilityElement(true)
        attentionDot.setAccessibilityRole(.staticText)
        attentionDot.setAccessibilityLabel(L10n.string("Session needs attention"))

        limitMark.isHidden = true
        limitMark.translatesAutoresizingMaskIntoConstraints = false
        limitMark.setAccessibilityLabel(L10n.string("Session stopped at its usage limit"))

        addSubview(spinner)
        addSubview(attentionDot)
        addSubview(limitMark)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize),
            spinner.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize),

            attentionDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            attentionDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            attentionDot.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.dotSize),
            attentionDot.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.dotSize),

            limitMark.centerXAnchor.constraint(equalTo: centerXAnchor),
            limitMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            limitMark.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size),
            limitMark.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.size)
        ])
    }

    // MARK: - Public Methods

    func update(for activity: SessionActivity, isLoading: Bool = false) {
        if let currentState,
           currentState.activity == activity,
           currentState.isLoading == isLoading {
            return
        }
        let isFirstUpdate = currentState == nil
        currentState = (activity, isLoading)

        // Session activation is separate from agent activity: a dormant conversation can still
        // be resolving the checkout summary needed by its chrome. The same themed spinner says
        // "work is pending" without adding a second competing status glyph to the row.
        if isLoading {
            attentionDot.isHidden = true
            limitMark.isHidden = true
            spinner.setAccessibilityLabel(L10n.string("Loading session"))
            spinner.isAnimating = true
            return
        }

        spinner.setAccessibilityLabel(L10n.string("Session working"))
        limitMark.isHidden = activity != .limitReached

        switch activity {
        case .working:
            attentionDot.isHidden = true
            spinner.isAnimating = true

        case .limitReached:
            // No fade. The other two marks are faded in because they mean something *just*
            // happened and the eye should catch it; this one is read minutes or hours later,
            // when the user comes back wondering why a session went quiet.
            spinner.isAnimating = false
            attentionDot.isHidden = true
            limitMark.alphaValue = 1

        case .awaitingUser, .needsAttention:
            spinner.isAnimating = false
            dotStyle = activity == .awaitingUser ? .blocked : .unread
            attentionDot.setAccessibilityLabel(
                activity == .awaitingUser
                    ? "Session waiting for an answer"
                    : "Session needs attention"
            )
            applyDotSurface()
            // Faded in rather than snapped, so a session finishing catches the eye —
            // except on first configure, where the state is old news.
            showAttentionDot(animated: !isFirstUpdate)

        case .idle, .dormant:
            spinner.isAnimating = false
            attentionDot.isHidden = true
        }
    }

    // MARK: - Private Methods

    /// Through `applySurface` rather than straight onto the layer: a `cgColor` resolves once,
    /// and the mark would keep the previous theme's colour until the session changed state.
    private func applyDotSurface() {
        let radius = SurfaceRadius.fixed(StatusIndicatorDefaults.dotSize / 2)
        let hostInk = hostGround?.ink.label

        switch dotStyle {
        case .blocked:
            attentionDot.applySurface(
                fill: hostInk ?? Design.Status.warning,
                radius: radius
            )
        case .unread:
            attentionDot.applySurface(
                fill: .clear,
                radius: radius,
                border: hostInk ?? Design.Surface.accent
            )
        }
    }

    private func showAttentionDot(animated: Bool) {
        attentionDot.isHidden = false

        guard animated else {
            attentionDot.alphaValue = 1
            return
        }

        attentionDot.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            attentionDot.animator().alphaValue = 1
        }
    }

    /// The dot's colour is set on its layer, which does not track appearance changes the
    /// way an `NSColor`-backed view would, so it is refreshed here.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDotSurface()
    }
}

// MARK: - Status Indicator Defaults

enum StatusIndicatorDefaults {
    static let size: CGFloat = 12
    static let spinnerSize: CGFloat = 12
    static let dotSize: CGFloat = 6
}
