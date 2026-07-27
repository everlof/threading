import AppKit

/// The report sheet: the window screenshot with the capture marked, the text that names it,
/// a note field, and a copy button putting the whole thing on the clipboard as markdown.
///
/// The markdown carries the screenshot's *path* rather than embedding the image — a path is
/// the one form of an image the agent CLIs can act on, so the copied report pastes straight
/// into a session composer. The note leads the copied text for the same reason: a chat reads
/// the instruction before the evidence.
final class InspectorReportViewController: NSViewController {

    // MARK: - Properties

    private let heading: String
    private let subheading: String
    private let markdown: String
    private let screenshot: NSImage?

    private let noteField = PromptView()
    private let copyButton = ThemedButton()

    /// Called when the sheet is done, however it was closed.
    var onDone: (() -> Void)?

    // MARK: - Initialization

    init(heading: String, subheading: String, markdown: String, screenshot: NSImage?) {
        self.heading = heading
        self.subheading = subheading
        self.markdown = markdown
        self.screenshot = screenshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(
            x: 0, y: 0,
            width: InspectorReportLayout.sheetWidth,
            height: InspectorReportLayout.sheetHeight
        ))
        setupViews()
    }

    // MARK: - Setup

    private func setupViews() {
        // The sheet is its own little window, and a window the theme does not reach is a
        // system panel floating over a styled app. Ground, matching the chrome it slid out of.
        view.applySurface(fill: Design.Surface.ground, radius: .fixed(0))

        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.applyFont(.heading)
        headingLabel.textColor = Design.Text.label

        let subheadingLabel = NSTextField(labelWithString: subheading)
        subheadingLabel.applyFont(.subheading)
        subheadingLabel.textColor = Design.Text.secondary
        subheadingLabel.lineBreakMode = .byTruncatingTail

        let headings = NSStackView(views: [headingLabel, subheadingLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = Design.Spacing.hairline

        var content: [NSView] = [headings]
        if let preview = makePreview() {
            content.append(preview)
        }
        content.append(makeReportText())
        content.append(makeNoteField())
        content.append(makeFooter())

        let stack = NSStackView(views: content)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.pane)
        ])

        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makePreview() -> NSView? {
        guard let screenshot else { return nil }

        let imageView = NSImageView()
        imageView.image = screenshot
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // An image view's intrinsic size is the image's own, and a window screenshot is a
        // window wide — floored, or the preview drives the sheet. The display pane learned
        // this the hard way.
        imageView.setContentHuggingPriority(.init(1), for: .horizontal)
        imageView.setContentHuggingPriority(.init(1), for: .vertical)
        imageView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        imageView.heightAnchor
            .constraint(equalToConstant: InspectorReportLayout.previewHeight)
            .isActive = true

        imageView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )

        return imageView
    }

    private func makeReportText() -> NSView {
        let scrollView = ThemedTextView.scrolling()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        scrollView.heightAnchor
            .constraint(equalToConstant: InspectorReportLayout.textHeight)
            .isActive = true

        if let textView = scrollView.documentView as? ThemedTextView {
            textView.string = markdown
            textView.isEditable = false
            textView.isSelectable = true
            textView.applyFont(.code())
            textView.textContainerInset = NSSize(
                width: Design.Spacing.medium,
                height: Design.Spacing.medium
            )
        }

        return scrollView
    }

    /// The composer's own input, not a one-line field.
    ///
    /// A note was assumed to be one sentence — "make this padding smaller" — and often is not:
    /// a second line went on being typed into a box with no room for it and was clipped mid-
    /// glyph, which is a field losing text the user can see it has. `PromptView` grows with what
    /// is in it and already answers Return and Shift-Return the way every composer here does, so
    /// the sheet inherits the behaviour rather than restating it.
    private func makeNoteField() -> NSView {
        noteField.placeholder = InspectorStrings.notePlaceholder
        noteField.onSubmit = { [weak self] _ in self?.copyReport() }
        noteField.translatesAutoresizingMaskIntoConstraints = false

        // Said rather than left to be discovered: a growing box is the only clue that a second
        // line is possible, and it appears after the key that would have submitted was pressed.
        let hint = NSTextField(labelWithString: InspectorStrings.noteHint)
        hint.applyFont(.caption)
        hint.textColor = Design.Text.tertiary

        let stack = NSStackView(views: [noteField, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        noteField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func makeFooter() -> NSView {
        copyButton.title = InspectorStrings.copyTitle
        copyButton.isProminent = true
        copyButton.keyEquivalent = "\r"
        copyButton.target = self
        copyButton.action = #selector(copyReport)

        let closeButton = ThemedButton(
            title: InspectorStrings.closeTitle,
            target: self,
            action: #selector(close)
        )
        closeButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, closeButton, copyButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    // MARK: - Actions

    @objc private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            InspectorReportComposer.compose(note: noteField.stringValue, markdown: markdown),
            forType: .string
        )

        // The button is its own receipt; the sheet stays up in case the screenshot or the
        // chain still wants reading.
        copyButton.title = InspectorStrings.copiedTitle
        DispatchQueue.main.asyncAfter(
            deadline: .now() + InspectorReportLayout.copiedResetDelay
        ) { [weak self] in
            self?.copyButton.title = InspectorStrings.copyTitle
        }
    }

    @objc private func close() {
        onDone?()
    }
}

// MARK: - Report Composition

enum InspectorReportComposer {

    /// What Copy Report actually copies: the user's note first — a chat reads the
    /// instruction before the evidence — then the report. An empty note adds nothing.
    static func compose(note: String, markdown: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return markdown }
        return trimmed + "\n\n" + markdown
    }
}

// MARK: - Report Layout

enum InspectorReportLayout {
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 660
    static let previewHeight: CGFloat = 260
    static let textHeight: CGFloat = 170
    static let reportFontSize: CGFloat = 11
    static let copiedResetDelay: TimeInterval = 1.5
}

// MARK: - Report Strings

enum InspectorStrings {
    static let elementHeading = "Element Report"
    static let pointHeading = "Point Report"
    static let regionHeading = "Region Report"
    static let notePlaceholder = "Add a note — it leads the copied report"
    static let noteHint = "Return copies the report · ⇧Return adds a line"
    static let copyTitle = "Copy Report"
    static let copiedTitle = "Copied"
    static let closeTitle = "Close"

    /// Drawn on the overlay whether anything is held or not: a modifier nothing mentions is a
    /// feature nobody finds, and element mode is where the question it answers gets asked.
    static let layerHint = "⌃ hierarchy · ⌥ spacing"
    static let flushOnEverySide = "flush on every side"

    /// The key is bounded by the window; the drawing and the report are not.
    static func legendFold(_ count: Int) -> String {
        "+\(count) more — see the report"
    }
}
