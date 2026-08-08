import AppKit

/// The report sheet: the window screenshot with the capture marked, the text that names it, a
/// description, and the two things worth doing with it — copying it into a session, or filing
/// it as a GitHub issue.
///
/// The markdown carries the screenshot's *path* rather than embedding the image — a path is
/// the one form of an image the agent CLIs can act on, so the copied report pastes straight
/// into a session composer. The description leads the copied text for the same reason: a chat
/// reads the instruction before the evidence, and so does a person reading a ticket.
///
/// **The description comes before the evidence on screen, too.** It was under a 170-point block
/// of read-only markdown in a box one line tall, which is the layout of a form whose last field
/// is an afterthought — and it read as one. What the user has to write is the largest thing
/// here; what the app measured sits below it, quotable but quiet.
///
/// **The environment is held apart from the report rather than baked into it**, because it is
/// said in three places and must not be said twice in any of them: the details box shows it under
/// the capture, Copy Report carries it into the chat, and the ticket closes with it under the
/// rule `GitHubIssueComposer` draws. A report string that already contained it would have
/// arrived on GitHub with the environment printed once in the evidence and again under the rule.
final class InspectorReportViewController: NSViewController {

    // MARK: - Properties

    private let heading: String
    private let subheading: String
    private let markdown: String

    /// What the app was wearing when the capture was made — `InspectorEnvironment.markdown`, or
    /// empty when there was no window to read it from.
    private let environment: String

    private let screenshot: NSImage?

    private let noteField = PromptView()
    private let copyButton = ThemedButton()
    private let submitButton = ThemedButton()
    private let statusView = SubmissionStatusView()

    private var isSubmitting = false

    /// Called when the sheet is done, however it was closed.
    var onDone: (() -> Void)?

    /// Files the issue. Injected rather than reached for, so the sheet can be driven in a test
    /// without a network, a token, or a repository.
    var onSubmitIssue: ((GitHubIssueDraft) async -> GitHubIssueSubmission)?

    /// Where a created issue — or the prefilled form standing in for one — is opened.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Puts the capture where ⌘V can reach it. The GitHub API takes markdown and nothing else:
    /// image upload is a web-UI endpoint that refuses token auth, so the shortest honest path
    /// from this sheet to a picture in the issue is the clipboard and one keystroke.
    var copyImageToPasteboard: (NSImage) -> Void = { image in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // MARK: - Initialization

    init(
        heading: String,
        subheading: String,
        markdown: String,
        environment: String,
        screenshot: NSImage?
    ) {
        self.heading = heading
        self.subheading = subheading
        self.markdown = markdown
        self.environment = environment
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

        // Sized to what is in it rather than to a number. A guessed height leaves slack, and a
        // stack pinned top and bottom spends slack on the gaps between fields — which reads as
        // a form with a hole in it, and moves as soon as the status line appears.
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(NSSize(
            width: InspectorReportLayout.sheetWidth,
            height: view.fittingSize.height
        ))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The description is what the sheet is asking for, so the caret starts in it.
        view.window?.makeFirstResponder(noteField)
    }

    // MARK: - Setup

    private func setupViews() {
        // The sheet is its own little window, and a window the theme does not reach is a
        // system panel floating over a styled app. Ground, matching the chrome it slid out of.
        view.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )

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
        content.append(makeNoteField())
        content.append(makeReportText())
        content.append(makeStatusRow())
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

    /// The surface goes on a container, not on the scroll view.
    ///
    /// A scroll view given `applySurface` directly did not paint it — the layer background is
    /// there and the rendered sheet shows white where the panel should be, in both appearances.
    /// A plain view carrying the fill and holding the scroller inside it draws every time, and
    /// costs one view. The evidence looked like loose text on the ground until it had one.
    private func makeReportText() -> NSView {
        let scrollView = ThemedTextView.scrolling()
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        if let textView = scrollView.documentView as? ThemedTextView {
            textView.string = details
            textView.isEditable = false
            textView.isSelectable = true
            textView.applyFont(.code())
            textView.textContainerInset = NSSize(
                width: Design.Spacing.small,
                height: Design.Spacing.small
            )
        }

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        box.addSubview(scrollView)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: InspectorReportLayout.textHeight),
            scrollView.topAnchor.constraint(equalTo: box.topAnchor, constant: Design.Spacing.tight),
            scrollView.bottomAnchor.constraint(
                equalTo: box.bottomAnchor,
                constant: -Design.Spacing.tight
            ),
            scrollView.leadingAnchor.constraint(
                equalTo: box.leadingAnchor,
                constant: Design.Spacing.tight
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: box.trailingAnchor,
                constant: -Design.Spacing.tight
            )
        ])

        return section(caption: InspectorStrings.detailsCaption, content: box)
    }

    /// The composer's own input, not a one-line field.
    ///
    /// A note was assumed to be one sentence — "make this padding smaller" — and often is not:
    /// a second line went on being typed into a box with no room for it and was clipped mid-
    /// glyph, which is a field losing text the user can see it has. `PromptView` grows with what
    /// is in it and already answers Return and Shift-Return the way every composer here does, so
    /// the sheet inherits the behaviour rather than restating it.
    ///
    /// It opens at several lines rather than one because the sheet now files tickets, and a
    /// ticket is a paragraph. `submitPlacement` moves to `.outside` for the same reason the
    /// session composer uses it: Return-sends turns every line break in a description into an
    /// accidental submission, and here the thing submitted is public and permanent.
    private func makeNoteField() -> NSView {
        noteField.placeholder = InspectorStrings.notePlaceholder
        noteField.submitPlacement = .outside
        noteField.minimumHeight = InspectorReportLayout.noteHeight
        noteField.onSubmit = { [weak self] _ in self?.submitIssue() }
        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.setAccessibilityIdentifier(InspectorReportIdentifiers.note)

        // Said rather than left to be discovered: a growing box is the only clue that a second
        // line is possible, and it appears after the key that would have submitted was pressed.
        // Yields its width rather than driving the sheet's, the same reason the environment
        // line in `ReportProblemViewController` does: a wide-monospace theme makes one line of
        // caption longer than the sheet, and a label that will not compress breaks a pin.
        let hint = NSTextField(labelWithString: InspectorStrings.noteHint)
        hint.applyFont(.caption)
        hint.textColor = Design.Text.tertiary
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [noteField, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        noteField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return section(caption: InspectorStrings.descriptionCaption, content: stack)
    }

    /// A caption over its field. Two of these are what turned a stack of boxes into a form
    /// where the eye knows which one is being asked for.
    private func section(caption: String, content: NSView) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary

        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func makeStatusRow() -> NSView {
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.setAccessibilityIdentifier(InspectorReportIdentifiers.status)
        return statusView
    }

    private func makeFooter() -> NSView {
        submitButton.title = InspectorStrings.submitTitle
        submitButton.isProminent = true
        submitButton.target = self
        submitButton.action = #selector(submitIssue)
        submitButton.setAccessibilityIdentifier(InspectorReportIdentifiers.submit)

        copyButton.title = InspectorStrings.copyTitle
        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.setAccessibilityIdentifier(InspectorReportIdentifiers.copy)

        let closeButton = ThemedButton(
            title: InspectorStrings.closeTitle,
            target: self,
            action: #selector(close)
        )
        closeButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, closeButton, copyButton, submitButton])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    // MARK: - Actions

    @objc private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            InspectorReportComposer.compose(note: noteField.stringValue, markdown: details),
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

    @objc func submitIssue() {
        guard !isSubmitting, let onSubmitIssue else { return }

        let draft = issueDraft()
        beginSubmitting()

        Task { @MainActor [weak self] in
            let outcome = await onSubmitIssue(draft)
            self?.finishSubmitting(outcome)
        }
    }

    /// What gets filed: the description leads, the capture follows, the environment closes.
    ///
    /// The captured environment is the one the sheet was given, which already opens with the
    /// three facts `GitHubIssueEnvironment` states and adds what the capture itself needed. A
    /// sheet built without one still files the plain line rather than an empty rule.
    func issueDraft() -> GitHubIssueDraft {
        GitHubIssueDraft(
            title: GitHubIssueComposer.title(
                fromNote: noteField.stringValue,
                fallback: L10n.format("%@ — %@", heading, subheading)
            ),
            body: GitHubIssueComposer.body(
                note: noteField.stringValue,
                report: markdown,
                environment: environment.isEmpty
                    ? GitHubIssueEnvironment.markdown()
                    : environment
            ),
            labels: [GitHubIssueKind.problem.label]
        )
    }

    /// The capture and what it was captured under, in the order they are read. One blank line
    /// between them: the environment is a different kind of fact from the geometry above it, and
    /// a flat list of eighteen bullets is one nobody finishes.
    var details: String {
        guard !environment.isEmpty else { return markdown }
        return markdown + "\n\n" + environment
    }

    @objc private func close() {
        onDone?()
    }

    // MARK: - Private Methods

    private func beginSubmitting() {
        isSubmitting = true
        submitButton.isEnabled = false
        submitButton.title = InspectorStrings.submittingTitle
        statusView.show(InspectorStrings.submittingStatus, tone: .working)
    }

    private func finishSubmitting(_ outcome: GitHubIssueSubmission) {
        isSubmitting = false
        submitButton.isEnabled = true
        submitButton.title = InspectorStrings.submitTitle

        switch outcome {
        case .created(let url, let number, _):
            handOffScreenshot()
            statusView.show(InspectorStrings.created(issue: number), tone: .done)
            openURL(url)

        case .webForm(let url, let message):
            handOffScreenshot()
            statusView.show(message + " " + InspectorStrings.pasteHint, tone: .working)
            openURL(url)

        case .failed(let message):
            statusView.show(message, tone: .failed)
        }
    }

    /// The capture leaves with the user: on the clipboard, one ⌘V from being in the issue that
    /// just opened. Done for the web form too — that page has the same comment box.
    private func handOffScreenshot() {
        guard let screenshot else { return }
        copyImageToPasteboard(screenshot)
    }

    /// What the sheet is showing, for the tests that drive a submission without a network.
    var statusMessage: String { statusView.message }
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
    static let sheetWidth: CGFloat = 640
    static let sheetHeight: CGFloat = 800
    static let previewHeight: CGFloat = 280
    static let textHeight: CGFloat = 150
    /// Several lines, opened rather than grown into: the box's size is what says how much is
    /// expected of it, and a ticket is a paragraph.
    static let noteHeight: CGFloat = 120
    static let reportFontSize: CGFloat = 11
    static let copiedResetDelay: TimeInterval = 1.5
}

enum InspectorReportIdentifiers {
    static let note = "inspector.report.note"
    static let copy = "inspector.report.copy"
    static let submit = "inspector.report.submit"
    static let status = "inspector.report.status"
}

// MARK: - Report Strings

enum InspectorStrings {
    static var elementHeading: String { L10n.string("Element Report") }
    static var pointHeading: String { L10n.string("Point Report") }
    static var regionHeading: String { L10n.string("Region Report") }
    static var notePlaceholder: String {
        L10n.string("Describe what's wrong, or what should change")
    }
    static var noteHint: String {
        L10n.string("⌘Return submits the issue · Return adds a line")
    }
    static var descriptionCaption: String { L10n.string("Description") }
    static var detailsCaption: String { L10n.string("Captured details") }
    static var copyTitle: String { L10n.string("Copy Report") }
    static var copiedTitle: String { L10n.string("Copied") }
    static var closeTitle: String { L10n.string("Close") }
    static var submitTitle: String { L10n.string("Submit Issue") }
    static var submittingTitle: String { L10n.string("Submitting…") }
    static var submittingStatus: String { L10n.string("Filing the issue on GitHub…") }

    /// GitHub answers with the number; a reading that could not find one still means the issue
    /// exists, so the receipt says so without inventing a number for it.
    static func created(issue number: Int) -> String {
        guard number > 0 else {
            return L10n.string(
                "Filed on GitHub. The screenshot is on the clipboard — ⌘V adds it in the browser."
            )
        }
        return L10n.format(
            "Filed as issue #%lld. The screenshot is on the clipboard — ⌘V adds it in the browser.",
            number
        )
    }
    static var pasteHint: String {
        L10n.string("The screenshot is on the clipboard — ⌘V adds it.")
    }

    /// The overlay's control line, one token each. Drawn whether anything is held or not, in
    /// both modes — with the two inspect commands collapsed into one there is no menu item left
    /// to name freeflow, so this is the only place the app says ⇧ and a drag mean anything.
    ///
    /// Separate keys rather than one sentence because each is coloured by whether it currently
    /// applies, which makes the line a readout of what is held as well as a list of what could
    /// be. `InspectorHint` decides that; these are only the words.
    static var pointHint: String { L10n.string("⇧ point") }
    static var regionHint: String { L10n.string("drag region") }
    static var hierarchyHint: String { L10n.string("⌃ hierarchy") }
    static var spacingHint: String { L10n.string("⌥ spacing") }
    static var exitHint: String { L10n.string("esc exits") }
    static var flushOnEverySide: String { L10n.string("flush on every side") }

    /// The key is bounded by the window; the drawing and the report are not.
    static func legendFold(_ count: Int) -> String {
        "+\(count) more — see the report"
    }
}
