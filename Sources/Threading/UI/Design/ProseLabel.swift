import AppKit

/// Plain conversation prose — a user's message, a reply still streaming — set in the reading
/// face *and* its leading.
///
/// A wrapping label can record a font role for the app-theme sweep, but it cannot state line
/// spacing: only an attributed string carries a paragraph style. And an attributed label is
/// exactly what the font sweep does not reach — assigning `font` to an `NSTextField` leaves its
/// runs' own fonts where they were. So this view owns the string, builds the attributed value
/// from the reading face, its leading and its ink as they resolve now, and builds it again when
/// the sweep or an appearance flip comes past. Rendered Markdown does the same through
/// `MarkdownStyle.assistant`, so a reply that streams in here settles into Markdown on the same
/// line box instead of jumping when it finishes.
@MainActor
final class ProseLabel: NSView, ThemedComponent {

    // MARK: - Properties

    var text: String {
        didSet {
            guard text != oldValue else { return }
            restyle()
        }
    }

    /// Zero for no limit, as on the label it wraps.
    var maximumNumberOfLines: Int {
        get { field.maximumNumberOfLines }
        set {
            field.maximumNumberOfLines = newValue
            invalidateIntrinsicContentSize()
        }
    }

    /// The text as it is drawn, with the face, leading and ink it was last set in.
    var attributedText: NSAttributedString { field.attributedStringValue }

    private let ink: @MainActor () -> NSColor
    private let field = NSTextField(wrappingLabelWithString: "")

    // MARK: - Initialization

    /// `ink` is a role read at every restyle rather than a colour captured once, so a theme
    /// switch re-resolves it with the face.
    init(text: String, ink: @escaping @MainActor () -> NSColor = { Design.Text.label }) {
        self.text = text
        self.ink = ink
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.isSelectable = true
        field.identifier = .transcriptText
        // This view is the one element VoiceOver reads; see the Accessibility overrides.
        field.setAccessibilityElement(false)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: - Accessibility

    /// One static text carrying the whole message, stated by this view rather than left to the
    /// label inside it, whose cell-backed answer varies with where the label is hosted.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }

    // MARK: - Private Methods

    private func restyle() {
        let font = Design.Typography.reading()
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink()
        ]
        let spacing = Design.Chat.lineSpacing(for: font, multiple: Design.Chat.readingLineHeight)
        if spacing > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = spacing
            attributes[.paragraphStyle] = paragraph
        }
        field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - ThemeDerivedContent

extension ProseLabel: ThemeDerivedContent {
    func rederiveThemedContent() {
        restyle()
    }
}

// MARK: - Transcript Text

extension NSUserInterfaceItemIdentifier {
    /// Marks a label as conversation prose — a run a transcript's own text selection may begin
    /// in and pass through (`TranscriptTextSelection`). Opt-in, because a row also holds labels
    /// that are a control's title, and a press on one of those belongs to the control.
    static let transcriptText = NSUserInterfaceItemIdentifier("conversation.transcriptText")
}
