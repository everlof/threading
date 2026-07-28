import AppKit

/// Shows what a session is doing: a spinner while it works, a dot when it has finished
/// something you have not looked at yet, and nothing otherwise.
///
/// Running-versus-dormant is conveyed by the row's text colour rather than a permanent dot,
/// so the indicator is reserved for states that actually warrant attention.
final class SessionStatusIndicator: NSView {

    // MARK: - Properties

    private let spinner = ThemedSpinner()
    private let attentionDot = NSView()

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

        // Through `applySurface` rather than straight onto the layer: a `cgColor` resolves once,
        // and the dot would keep the previous theme's accent until the session changed state.
        attentionDot.applySurface(
            fill: Design.Surface.accent,
            radius: .fixed(StatusIndicatorDefaults.dotSize / 2)
        )
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.setAccessibilityElement(true)
        attentionDot.setAccessibilityRole(.staticText)
        attentionDot.setAccessibilityLabel(L10n.string("Session needs attention"))

        addSubview(spinner)
        addSubview(attentionDot)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize),
            spinner.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.spinnerSize),

            attentionDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            attentionDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            attentionDot.widthAnchor.constraint(equalToConstant: StatusIndicatorDefaults.dotSize),
            attentionDot.heightAnchor.constraint(equalToConstant: StatusIndicatorDefaults.dotSize)
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
            spinner.setAccessibilityLabel(L10n.string("Loading session"))
            spinner.isAnimating = true
            return
        }

        spinner.setAccessibilityLabel(L10n.string("Session working"))

        switch activity {
        case .working:
            attentionDot.isHidden = true
            spinner.isAnimating = true

        case .needsAttention:
            spinner.isAnimating = false
            // Faded in rather than snapped, so a session finishing catches the eye —
            // except on first configure, where the state is old news.
            showAttentionDot(animated: !isFirstUpdate)

        case .idle, .dormant:
            spinner.isAnimating = false
            attentionDot.isHidden = true
        }
    }

    // MARK: - Private Methods

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
        attentionDot.applySurface(
            fill: Design.Surface.accent,
            radius: .fixed(StatusIndicatorDefaults.dotSize / 2)
        )
    }
}

// MARK: - Status Indicator Defaults

enum StatusIndicatorDefaults {
    static let size: CGFloat = 12
    static let spinnerSize: CGFloat = 12
    static let dotSize: CGFloat = 6
}
