import AppKit

/// One line reporting how something the user submitted ended: in flight, done, or refused.
///
/// A component rather than two labels in two sheets, for the reason the design system states
/// about repeated geometry: the glyph size, the gap, the baseline alignment and the wrapping
/// limit are one decision, and a second sheet restating them is where they start to drift.
///
/// The outcome is carried by **wording and glyph as well as colour**. A red line that says
/// "Filed as issue #42" would be unreadable to a viewer who cannot separate the two hues, and
/// unreadable to VoiceOver in either case — which is why showing a status also announces it.
final class SubmissionStatusView: NSView, ThemedComponent {

    // MARK: - Properties

    enum Tone {
        /// Under way. No glyph: nothing has happened yet to mark.
        case working
        case done
        case failed
    }

    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let appEvents = AppEventObservations()

    /// What the line currently says, for tests and for a caller restoring it.
    private(set) var message: String = ""
    private(set) var tone: Tone = .working

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()

        // The ink is a theme role and a theme can change while a sheet is open — a report being
        // written is exactly the kind of surface that outlives one.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTone() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyTone()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    func show(_ message: String, tone: Tone) {
        self.message = message
        self.tone = tone

        label.stringValue = message
        isHidden = message.isEmpty
        applyTone()
        announce(message)
    }

    func clear() {
        show("", tone: .working)
    }

    /// How many lines a long outcome may take before it is cut. A sheet keeps the default; a
    /// pane with room to spare may allow more, so a refusal's reason is read to its end.
    var maximumNumberOfLines: Int {
        get { label.maximumNumberOfLines }
        set {
            label.maximumNumberOfLines = newValue
            label.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Layout

    /// The line wraps at the width it is given, never at the width its words would like.
    ///
    /// A label with no stated width reports its whole sentence as one line of intrinsic width,
    /// and at the default compression resistance that outranks a window keeping its size. A
    /// refusal beside a chat in the display panel — "No opted-in phone has a live connection or
    /// usable push registration…" — pushed the panel across half the window and squeezed the
    /// conversation to make room for one unwrapped line. So the label yields its width, and each
    /// pass tells it the column it actually got.
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - SubmissionStatusDefaults.glyphSize - Design.Spacing.small)
        guard width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 else { return }
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
    }

    // MARK: - Private Methods

    private func setupViews() {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityElement(false)

        label.applyFont(.caption)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = SubmissionStatusDefaults.maximumLines
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier(SubmissionStatusDefaults.labelIdentifier)

        addSubview(glyph)
        addSubview(label)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor),
            glyph.widthAnchor.constraint(equalToConstant: SubmissionStatusDefaults.glyphSize),
            glyph.heightAnchor.constraint(equalToConstant: SubmissionStatusDefaults.glyphSize),

            label.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor,
                constant: Design.Spacing.small
            ),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        isHidden = true
        applyTone()
    }

    private func applyTone() {
        switch tone {
        case .working:
            label.textColor = Design.Text.secondary
            glyph.image = nil
        case .done:
            label.textColor = Design.Status.positive
            glyph.image = NSImage(
                systemSymbolName: DesignSymbols.reportFiled,
                accessibilityDescription: nil
            )
            glyph.contentTintColor = Design.Status.positive
        case .failed:
            label.textColor = Design.Status.negative
            glyph.image = NSImage(
                systemSymbolName: DesignSymbols.reportRefused,
                accessibilityDescription: nil
            )
            glyph.contentTintColor = Design.Status.negative
        }
    }

    /// The line appears far from the pointer and takes no focus, so without this it is
    /// invisible to the part of the audience that cannot glance at it — the same reason
    /// `Toast` announces itself.
    private func announce(_ message: String) {
        guard !message.isEmpty, let window else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

enum SubmissionStatusDefaults {
    static let glyphSize: CGFloat = 13
    static let maximumLines = 3
    static let labelIdentifier = "submission.status"
}
