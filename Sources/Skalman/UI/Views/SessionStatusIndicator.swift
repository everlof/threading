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
    /// for the same activity are ignored — otherwise the dot's entrance would replay.
    private var currentActivity: SessionActivity?

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

        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = StatusIndicatorDefaults.dotSize / 2
        attentionDot.layer?.backgroundColor = Design.Surface.accent.cgColor
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false

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

    func update(for activity: SessionActivity) {
        guard activity != currentActivity else { return }
        let isFirstUpdate = currentActivity == nil
        currentActivity = activity

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
            context.duration = StatusIndicatorDefaults.appearDuration
            attentionDot.animator().alphaValue = 1
        }
    }

    /// The dot's colour is set on its layer, which does not track appearance changes the
    /// way an `NSColor`-backed view would, so it is refreshed here.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        attentionDot.layer?.backgroundColor = Design.Surface.accent.cgColor
    }
}

// MARK: - Status Indicator Defaults

enum StatusIndicatorDefaults {
    static let size: CGFloat = 12
    static let spinnerSize: CGFloat = 12
    static let dotSize: CGFloat = 6
    static let appearDuration: TimeInterval = 0.25
}
