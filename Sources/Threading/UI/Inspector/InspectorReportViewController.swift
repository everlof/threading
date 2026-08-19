import AppKit

/// The report sheet: the window screenshot with the capture marked, the text that names it, a
/// description, and the two things worth doing with it — copying the complete local evidence into
/// a session, or sending a bounded copy to Threading's private developer inbox.
///
/// The markdown carries the screenshot's *path* rather than embedding the image — a path is
/// the one form of an image the agent CLIs can act on, so the copied report pastes straight
/// into a session composer. The description leads the copied text for the same reason: a chat
/// reads the instruction before the evidence, and so does a person reading a report.
///
/// **The description comes before the evidence on screen, too.** It was under a 170-point block
/// of read-only markdown in a box one line tall, which is the layout of a form whose last field
/// is an afterthought — and it read as one. What the user has to write is the largest thing
/// here; what the app measured sits below it, quotable but quiet.
///
/// **The environment is held apart from the report rather than baked into it**, because it is
/// said in three places and must not be said twice in any of them: the details box shows it under
/// the capture, Copy Report carries it into the chat, and the private report closes with it under
/// report composer. A report string that already contained it would arrive twice.
final class InspectorReportViewController: NSViewController {

    // MARK: - Properties

    private let heading: String
    private let subheading: String
    private let markdown: String

    /// What the app was wearing when the capture was made — `InspectorEnvironment.markdown`, or
    /// empty when there was no window to read it from.
    private let environment: String

    private let screenshot: NSImage?
    /// The temporary PNG behind `screenshot`. Keeping the value beside the decoded image lets
    /// the shared media inspector offer zoom and file actions without parsing prose for a path.
    private let screenshotURL: URL?

    private let noteField = PromptView()
    /// The sheet's one action, and the other ways to take it. Three buttons in a row said a
    /// finished report was three decisions; it is one decision taken three ways, and the way
    /// taken last is the one the press offers next time.
    private lazy var actionsControl: DeveloperReportSubmitControl = {
        var available: [DeveloperReportAction] = [.send, .copy]
#if DEBUG
        available.append(.chat)
#endif
        let control = DeveloperReportSubmitControl(available: available)
        control.onPerform = { [weak self] action in self?.perform(action) }
        return control
    }()
    private let statusView = SubmissionStatusView()

    private let imageView = AnnotatedImageView()
    private let annotationRail = ImageAnnotationRailView()
    private let sideColumn = NSStackView()
    /// The caption-and-rail pair, shown only once something has been marked. Named apart from
    /// `annotationSection`, which is the same marks as prose.
    private weak var annotationSectionView: NSView?
    /// The evidence box, kept so a new mark can be written into it. Weak-by-optional rather than
    /// force-unwrapped: the box exists only once the view is loaded.
    private weak var detailsTextView: NSTextView?

    /// The marks, owned here because three views show them: the picture, the rail, and — once
    /// the capture is opened full size — the inspector's own canvas and rail.
    private(set) var annotations: [ImageAnnotation] = []

    private var isSubmitting = false

#if DEBUG
#endif

    /// Called when the sheet is done, however it was closed.
    var onDone: (() -> Void)?

    /// Sends the reviewed report. Injected rather than reached for, so the sheet can be driven in
    /// a test without a network or application composition root.
    var onSubmitReport: (
        (DeveloperIssueReportDraft, NSImage?) async -> DeveloperIssueReportSubmission
    )?

#if DEBUG
    /// Opens a chat on the same reviewed report. Injected for the reason above, and synchronous
    /// because nothing here crosses a network: the chat is created, launched and selected in one
    /// main-actor pass. See `DeveloperReportChat`.
    var onSendToChat: ((DeveloperReportChatRequest) -> DeveloperReportChatOutcome)?
#endif

    // MARK: - Initialization

    init(
        heading: String,
        subheading: String,
        markdown: String,
        environment: String,
        screenshot: NSImage?,
        screenshotURL: URL? = nil
    ) {
        self.heading = heading
        self.subheading = subheading
        self.markdown = markdown
        self.environment = environment
        self.screenshot = screenshot
        self.screenshotURL = screenshotURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let size = InspectorReportLayout.sheetSize(inWindowOf: availableSize)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        setupViews()

        // **Sized to the window rather than to its content**, which is the opposite of what this
        // sheet used to do and for a reason the content change made true: what the sheet is now
        // mostly showing is a *picture*, and a picture wants every point the window will give it.
        // Fitting to content sized the sheet to the sum of a fixed preview height and three
        // boxes — which is how the capture ended up 280 points tall inside a 900-point window,
        // small enough that marking anything on it meant guessing.
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(size)
    }

    /// The room the sheet may take, which only the presenting window knows.
    ///
    /// Nil in a fixture, where there is no window — `sheetSize(inWindowOf:)` then falls back to
    /// its own floor rather than to zero, so a render test draws the same sheet a small display
    /// would get instead of a sheet with no size at all.
    var availableSize: NSSize?

    override func viewDidAppear() {
        super.viewDidAppear()
        // The description is what the sheet is asking for, so the caret starts in it.
        //
        // Through the component's own `focus()`, because `PromptView` is a plain `NSView`
        // wrapping the text view that actually edits. `makeFirstResponder` on the box itself
        // *succeeds* — AppKit consults `acceptsFirstResponder` for the key-view loop and for a
        // click, not for an explicit request — so the container took the caret, had nothing to
        // do with a keystroke, and the sheet opened with a description that could not be typed
        // into while looking focused.
        noteField.focus()
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

        // **Two columns, because the picture and the words about it are read together.**
        //
        // Stacked, the capture and the field naming it competed for the same vertical space: the
        // image had to be short enough to leave room for the form, and the form scrolled the
        // image off the top the moment there were three annotations. Side by side, the picture
        // takes the height of the sheet and each note stays beside the pin it names.
        //
        // **Pinned rather than stacked, and that is the second attempt.** A horizontal
        // `NSStackView` distributes by hugging priority, and neither column here has an
        // intrinsic width worth ranking: the picture states none by design, the rail's is
        // whatever its longest line happens to be. Asked to `.fill`, it gave the capture about a
        // third of the room and settled it against the bottom of a sheet the sheet's own height
        // had been raised to provide. Four edges and one stated measure cannot be interpreted.
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let imageColumn = makeImageColumn()
        let rail = makeSideColumn()
        body.addSubview(imageColumn)
        body.addSubview(rail)

        let footer = makeFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = headings
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = makeStatusRow()

        for child in [headerRow, body, statusRow, footer] {
            view.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }

        let inset = Design.Spacing.pane
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            // The body is everything between the heading and the footer, and it takes every
            // point of that — which is what makes the capture as large as the window allows.
            body.topAnchor.constraint(
                equalTo: headerRow.bottomAnchor,
                constant: Design.Spacing.large
            ),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            body.bottomAnchor.constraint(
                equalTo: statusRow.topAnchor,
                constant: -Design.Spacing.medium
            ),

            statusRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            statusRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            statusRow.bottomAnchor.constraint(
                equalTo: footer.topAnchor,
                constant: -Design.Spacing.medium
            ),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),

            // The rail is a stated measure; the picture takes whatever is left. Sizing them by
            // content priority instead let a long class name in the captured details widen the
            // rail and squeeze the capture.
            rail.topAnchor.constraint(equalTo: body.topAnchor),
            rail.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            rail.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            rail.widthAnchor.constraint(
                equalToConstant: Design.Size.mediaInspectorAnnotationColumnWidth
            ),

            imageColumn.topAnchor.constraint(equalTo: body.topAnchor),
            imageColumn.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            imageColumn.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            imageColumn.trailingAnchor.constraint(
                equalTo: rail.leadingAnchor,
                constant: -Design.Spacing.large
            )
        ])
    }

    // MARK: - The Picture

    /// The capture, as large as the sheet can make it, with the line that says it can be marked.
    private func makeImageColumn() -> NSView {
        imageView.image = screenshot
        imageView.fileURL = screenshotURL
        imageView.setAccessibilityIdentifier(ImageAnnotationIdentifiers.image)
        imageView.onAddAnnotation = { [weak self] point in self?.addAnnotation(at: point) }
        imageView.onSelectAnnotation = { [weak self] id in
            guard let self else { return }
            self.annotationRail.selectedAnnotationID = id
            if let id { self.annotationRail.focusNote(for: id) }
        }
        // The picture opens into the same inspector every other image in the app opens into,
        // handing it this sheet as the annotation host — so a pin dropped at 400% arrives in the
        // rail behind it, and comes back with the sheet when the overlay closes.
        imageView.onOpenFullSize = { [weak self] in self?.openFullSize() }

        // **No plate behind it.** A panel fill under a picture that is scaled to fit and pinned
        // to the top edge draws an empty box wherever the picture is shorter than the column,
        // which on a wide capture is most of the column. The picture carries its own silhouette;
        // the inspector's canvas grounds an image the same way.
        let hint = NSTextField(labelWithString: ImageAnnotationStrings.addHint)
        hint.applyFont(.caption)
        hint.textColor = Design.Text.tertiary
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Pinned rather than stacked, for the reason the two columns are: the picture must take
        // every point the column is not spending on the caption, and a stack decides that by
        // hugging priorities the picture deliberately has no opinion about.
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(imageView)
        column.addSubview(hint)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: column.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            imageView.bottomAnchor.constraint(
                equalTo: hint.topAnchor,
                constant: -Design.Spacing.small
            ),
            hint.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: column.bottomAnchor)
        ])
        return column
    }

    // MARK: - The Rail

    /// Description, then the annotations, then the evidence — in the order they are written.
    private func makeSideColumn() -> NSView {
        annotationRail.onNoteChange = { [weak self] id, note in
            self?.updateAnnotation(id: id) { $0.note = note }
        }
        annotationRail.onRemove = { [weak self] id in
            guard let self else { return }
            self.applyAnnotations(self.annotations.filter { $0.id != id })
        }
        annotationRail.onFocus = { [weak self] id in
            self?.imageView.selectedAnnotationID = id
        }

        // Hidden until there is a mark. A caption standing over an empty rail is a section that
        // has nothing to say, and the invitation to make one is already under the picture, which
        // is where the gesture is.
        let marksSection = section(
            caption: ImageAnnotationStrings.caption,
            content: annotationRail
        )
        marksSection.isHidden = true
        annotationSectionView = marksSection

        sideColumn.orientation = .vertical
        sideColumn.alignment = .leading
        sideColumn.spacing = Design.Spacing.medium
        sideColumn.translatesAutoresizingMaskIntoConstraints = false
        for view in [makeNoteField(), marksSection, makeReportText()] {
            sideColumn.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sideColumn.widthAnchor).isActive = true
        }
        return sideColumn
    }

    // MARK: - Annotating

    /// Exactly one already-decoded window capture lives here (ordinary 2–8 MP; a maximized
    /// high-density display is the stress case), and at most
    /// `ImageAnnotationDefaults.maximumCount` marks on it. `AnnotatedImageView` states no
    /// intrinsic size, so those pixels cannot drive the sheet's width, and a click mutates one
    /// small array rather than decoding or rebuilding anything proportional to the picture.
    private func addAnnotation(at point: CGPoint) {
        guard annotations.count < ImageAnnotationDefaults.maximumCount else {
            statusView.show(ImageAnnotationStrings.fullCount, tone: .failed)
            return
        }
        let annotation = ImageAnnotation(point: point)
        applyAnnotations(annotations + [annotation])
        imageView.selectedAnnotationID = annotation.id
        annotationRail.selectedAnnotationID = annotation.id
        annotationRail.focusNote(for: annotation.id)
    }

    private func updateAnnotation(
        id: ImageAnnotation.ID,
        _ change: (inout ImageAnnotation) -> Void
    ) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var updated = annotations
        change(&updated[index])
        applyAnnotations(updated)
    }

    /// The one write. Both views are told, and the evidence box is rewritten, because the
    /// captured details are what Copy Report copies and what the private report files — a mark
    /// the user can see on the picture and cannot find in the report is a mark that did nothing.
    ///
    /// Not private: the fullscreen inspector writes through it as this sheet's annotation host,
    /// and a render fixture states a marked-up sheet the same way rather than through a second
    /// door of its own.
    func applyAnnotations(_ updated: [ImageAnnotation]) {
        annotations = updated
        imageView.annotations = updated
        annotationRail.setAnnotations(updated)
        annotationSectionView?.isHidden = updated.isEmpty
        detailsTextView?.string = details
    }

    /// Opens the capture in the app's own image inspector, with this sheet as the annotation
    /// host. Marks made there arrive through `inspector(didChange:for:image:)` and are already
    /// in the rail by the time the overlay closes.
    /// Needs the capture's *file*, not only its pixels: the inspector refuses an item whose URL
    /// is not on disk, which is right — its file actions and its rail are about a file. A
    /// capture whose PNG could not be written stays markable here and simply does not open.
    private func openFullSize() {
        guard let screenshot, let screenshotURL else { return }
        MediaInspectorPresenter.present(
            MediaInspectorItem(
                url: screenshotURL,
                title: subheading,
                image: screenshot,
                content: .image
            ),
            from: imageView,
            annotationHost: self
        )
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

        let textView = scrollView.textView
        detailsTextView = textView
        textView.string = details
        textView.isEditable = false
        textView.isSelectable = true
        textView.applyFont(.code())
        textView.textContainerInset = NSSize(
            width: Design.Spacing.small,
            height: Design.Spacing.small
        )

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        // The one elastic row in the rail: the description is as tall as a description, the
        // marks are as tall as there are marks, and what is left belongs to the evidence.
        box.setContentHuggingPriority(.defaultLow, for: .vertical)
        box.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        box.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        box.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // A floor, not a height. The rail runs the full depth of the sheet now, and a
            // fixed 150-point box left the evidence clipped mid-line with empty rail under it.
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: InspectorReportLayout.textHeight),
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
    /// It opens at several lines rather than one because the sheet now files reports, and a
    /// report is a paragraph. `submitPlacement` moves to `.outside` for the same reason the
    /// session composer uses it: Return-sends turns every line break in a description into an
    /// accidental submission, and here the thing submitted is private and retained.
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
        let closeButton = ThemedButton(
            title: InspectorStrings.closeTitle,
            target: self,
            action: #selector(close)
        )
        closeButton.keyEquivalent = "\u{1b}"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [spacer, closeButton, actionsControl])
        footer.orientation = .horizontal
        footer.spacing = Design.Spacing.small

        return footer
    }

    /// The dispatcher the control calls. It owns *which* action is offered; this owns what each
    /// one does, which is the only half a sheet can answer.
    private func perform(_ action: DeveloperReportAction) {
        switch action {
        case .send:
            submitIssue()
        case .copy:
            copyReport()
        case .chat:
#if DEBUG
            sendToChat()
#else
            break
#endif
        }
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
        actionsControl.flashTitle(
            InspectorStrings.copiedTitle,
            restoringAfter: InspectorReportLayout.copiedResetDelay
        )
    }

#if DEBUG
    /// Hands the *local* report to a chat: the note, the whole capture, and the screenshot's
    /// path — deliberately `details` rather than `publicDetails`, which strips the path because
    /// a temporary file on this machine means nothing to an intake service and everything to an
    /// agent standing next to it.
    ///
    /// The sheet closes on success. The new chat coming up selected is the receipt, and a sheet
    /// left over a conversation the user asked to watch is one more thing to dismiss.
    @objc func sendToChat() {
        guard !isSubmitting, let onSendToChat else { return }

        statusView.show(DeveloperReportChatStrings.startingStatus, tone: .working)
        switch onSendToChat(chatRequest()) {
        case .started(let projectName):
            statusView.show(DeveloperReportChatStrings.started(projectName: projectName), tone: .done)
            onDone?()
        case .failed(let message):
            statusView.show(message, tone: .failed)
        }
    }

    /// Titled exactly the way `reportDraft` titles the private report, so the same note names
    /// the chat and the report it would have filed.
    func chatRequest() -> DeveloperReportChatRequest {
        DeveloperReportChatRequest(
            title: DeveloperIssueReportComposer.title(
                fromNote: noteField.stringValue,
                fallback: L10n.format("%@ — %@", heading, subheading)
            ),
            report: InspectorReportComposer.compose(
                note: noteField.stringValue,
                markdown: details
            )
        )
    }
#endif

    @objc func submitIssue() {
        guard !isSubmitting, let onSubmitReport else { return }

        let draft = reportDraft()
        beginSubmitting()

        // The *marked* capture, not the bare one. The preview is the only picture the private
        // report carries, and one showing none of the marks the report's own text refers to
        // would leave a reader looking for a pin that is not there.
        let picture = annotatedScreenshot
        Task { @MainActor [weak self] in
            let outcome = await onSubmitReport(draft, picture)
            self?.finishSubmitting(outcome)
        }
    }

    /// The capture with the marks drawn in, or the capture unchanged when nothing was marked.
    var annotatedScreenshot: NSImage? {
        guard let screenshot else { return nil }
        return ImageAnnotationFlattening.flattened(screenshot, annotations: annotations)
    }

    /// What reaches the private inbox: the description leads, bounded structural evidence and
    /// the environment follow. The temporary screenshot path is deliberately removed; the small
    /// reviewed JPEG preview is a separate field and the full PNG remains local.
    ///
    /// The captured environment is the one the sheet was given, which already opens with the
    /// three facts the shared environment summary states and adds what the capture itself needed. A
    /// sheet built without one still files the plain line rather than an empty rule.
    func reportDraft() -> DeveloperIssueReportDraft {
        DeveloperIssueReportDraft(
            kind: .problem,
            title: DeveloperIssueReportComposer.title(
                fromNote: noteField.stringValue,
                fallback: L10n.format("%@ — %@", heading, subheading)
            ),
            details: InspectorReportComposer.compose(
                note: noteField.stringValue,
                markdown: publicDetails
            ),
            // Both readings of the same sheet, handed over together: the reviewed one for a
            // service, and the one that keeps the capture's path for the folder an agent reads.
            local: DeveloperIssueReportDraft.Local(
                details: InspectorReportComposer.compose(
                    note: noteField.stringValue,
                    markdown: details
                ),
                screenshotURL: screenshotURL
            )
        )
    }

    private var publicDetails: String {
        let safeCapture = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !InspectorReportComposer.localPathMarkers.contains { line.contains($0) }
            }
            .joined(separator: "\n")
        let capturedEnvironment = environment.isEmpty
            ? DeveloperIssueReportComposer.environment()
            : environment
        return join(safeCapture, annotationSection, capturedEnvironment)
    }

    /// The capture, the marks made on it, and what it was captured under — in the order they are
    /// read. One blank line between each: the environment is a different kind of fact from the
    /// geometry above it, and a flat list of eighteen bullets is one nobody finishes.
    var details: String {
        join(markdown, annotationSection, environment.isEmpty ? nil : environment)
    }

    /// The marks as prose, positioned in the *image's own pixels*.
    ///
    /// Coordinates as well as a flattened picture, and both on purpose: the picture shows where,
    /// and the numbers let a reader who is measuring the PNG — an agent counting pixels, a person
    /// checking a frame against the geometry three lines above — land on the same spot without
    /// eyeballing a disc.
    private var annotationSection: String? {
        guard let screenshot else { return nil }
        return ImageAnnotationSummary.section(annotations, imageSize: screenshot.size)
    }

    private func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    @objc private func close() {
        onDone?()
    }

    // MARK: - Private Methods

    private func beginSubmitting() {
        isSubmitting = true
        actionsControl.setBusy(true, title: InspectorStrings.submittingTitle)
        statusView.show(InspectorStrings.submittingStatus, tone: .working)
    }

    private func finishSubmitting(_ outcome: DeveloperIssueReportSubmission) {
        isSubmitting = false
        actionsControl.setBusy(false)

        switch outcome {
        case .delivered(let reference):
            statusView.show(InspectorStrings.received(reference: reference), tone: .done)
        case .saved(let records):
            statusView.show(InspectorStrings.saved(records: records), tone: .done)
        case .queued:
            statusView.show(InspectorStrings.queued, tone: .working)
        case .failed(let message):
            statusView.show(message, tone: .failed)
        }
    }

    /// What the sheet is showing, for the tests that drive a submission without a network.
    var statusMessage: String { statusView.message }
}

// MARK: - Media Inspector Annotation Host

/// The sheet stays the owner of the marks while the picture is open full size.
///
/// This is the whole point of the host seam: the inspector is a *second view* of the list in the
/// rail behind it, not a place that collects marks of its own and hands them back at the end. A
/// pin dropped at 400% is in the rail before the overlay closes, and the report text under it is
/// already rewritten — so closing the inspector is a dismissal rather than a commit, and
/// dismissing it by Escape cannot lose work.
extension InspectorReportViewController: MediaInspectorAnnotationHost {

    func annotations(for item: MediaInspectorItem) -> [ImageAnnotation] {
        annotations
    }

    func inspector(
        didChange annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    ) {
        applyAnnotations(annotations)
    }
}

// MARK: - Report Composition

enum InspectorReportComposer {

    /// Lines that name a file on this machine, and therefore never cross the wire.
    ///
    /// A list rather than one string because there are two ways a capture gets into this sheet
    /// and they cannot say the same sentence: one was taken from the window and marked at a
    /// point, the other was taken by macOS and dropped in. Both keep their path locally for the
    /// same reason, so both are stripped here by the same rule.
    static let localPathMarkers = ["Window screenshot,", "Dropped screenshot,"]


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
    /// The floor, and what a fixture with no window gets. Two columns need the side rail's
    /// stated measure plus a picture worth looking at beside it; below this the capture is
    /// smaller than it was before the sheet grew, which would be a regression dressed as one.
    static let minimumSheetWidth: CGFloat = 900
    static let minimumSheetHeight: CGFloat = 620

    /// How much of the window a sheet may take. Not all of it: a sheet flush with its window's
    /// edges stops reading as a sheet, and the strip of window left around it is what says the
    /// report is *over* the thing being reported on.
    static let windowFraction: CGFloat = 0.88

    /// As large as the window allows, between the floor above and the window itself.
    static func sheetSize(inWindowOf available: NSSize?) -> NSSize {
        guard let available, available.width > 0, available.height > 0 else {
            return NSSize(width: minimumSheetWidth, height: minimumSheetHeight)
        }
        return NSSize(
            width: max(minimumSheetWidth, (available.width * windowFraction).rounded(.down)),
            height: max(minimumSheetHeight, (available.height * windowFraction).rounded(.down))
        )
    }

    /// The evidence box's floor. It grows into whatever the rail does not spend above it.
    static let textHeight: CGFloat = 150
    /// Several lines, opened rather than grown into: the box's size is what says how much is
    /// expected of it, and a report is a paragraph.
    static let noteHeight: CGFloat = 120
    static let reportFontSize: CGFloat = 11
    static let copiedResetDelay: TimeInterval = 1.5
}

enum InspectorReportIdentifiers {
    static let note = "inspector.report.note"
    static let copy = "inspector.report.copy"
    static let submit = "inspector.report.submit"
    static let status = "inspector.report.status"
#if DEBUG
    static let chat = "inspector.report.chat"
#endif
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
        L10n.string("⌘Return sends the report · Return adds a line")
    }
    static var descriptionCaption: String { L10n.string("Description") }
    static var detailsCaption: String { L10n.string("Captured details") }
    static var copiedTitle: String { L10n.string("Copied") }
    static var closeTitle: String { L10n.string("Close") }
    static var submittingTitle: String { L10n.string("Sending…") }
    static var submittingStatus: String { L10n.string("Sending to Threading’s private inbox…") }

    static func received(reference: String) -> String {
        L10n.format("Report received. Reference: %@", reference)
    }
    /// The count is the receipt. Filing several of these in a row is the expected way to use an
    /// outbox nobody is collecting from, and a number that goes up is what says the last one
    /// landed somewhere real.
    static func saved(records: Int) -> String {
        L10n.format("Saved to your outbox (%lld).", records)
    }

    static var queued: String {
        L10n.string("Report saved securely and queued for retry when Threading is active.")
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
