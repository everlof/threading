import AppKit

/// A primary text input: a rounded container holding the field and its submit control.
///
/// Built as a container rather than a bordered `NSTextField` so the submit affordance can sit
/// inside it, which is what makes the whole thing read as one input rather than a form row.
///
/// The field is an `NSTextView`, not an `NSTextField`, for two reasons a single-line field
/// cannot serve: a task worth describing runs past one line, and what is dropped onto a
/// composer is as often an image as it is text. It **grows with its content** up to
/// `Design.Size.inputMaxHeight` and scrolls beyond that, so a long prompt stays visible
/// without the box eating the pane.
final class PromptView: NSView, ThemedComponent {

    // MARK: - Properties

    private let contentStack = NSStackView()
    private let contextRail = ConversationContextRailView(mode: .composer)
    private let attachmentScrollView = ThemedScrollView()
    private let attachmentStack = NSStackView()
    private let scrollView = ThemedScrollView()
    private let textView = PromptTextView(frame: .zero, textContainer: nil)
    private let submitButton = ThemedButton()

    /// The control row along the bottom of the box — see `SubmitPlacement.footer`.
    private let footerRow = NSStackView()

    /// What pushes the trailing group to the far edge of that row. A view rather than a
    /// stack-view distribution: the two groups are pinned to their own edges and the gap
    /// between them is whatever is left, which is the only arrangement that holds when the
    /// leading group empties itself down to nothing.
    private let footerSpacer = NSView()
    private let completionPresenter = PromptCompletionPresenter()
    private var attachments: [PromptImageAttachment] = []
    private(set) var contextAttachments: [ConversationContextAttachment] = []
    private var isTextFocused = false
    private var completionSuggestions: [ComposerCapability] = []
    private var completionQuery: ComposerCompletionQuery?
    private var selectedCompletionIndex = 0
    private var completionKindFilter: ComposerCapability.Kind?

    /// Drives the growth. Held so the height can be recomputed as the text changes.
    private var heightConstraint: NSLayoutConstraint?

    /// The two right-hand edges the text can have: short of the inline submit glyph, or the
    /// box's own inset once that glyph is gone. Held so the pair can be swapped rather than
    /// rebuilt, since only one may be active at a time.
    private var contentTrailingBesideSubmit: NSLayoutConstraint?
    private var contentTrailingToEdge: NSLayoutConstraint?

    /// What holds the submit glyph in the box's corner. Deactivated when the glyph moves into
    /// the control row, where the row places it instead.
    private var submitPinnedConstraints: [NSLayoutConstraint] = []

    /// The box's own top and bottom padding, held because a box with a control row under its
    /// text is padded differently from one whose only content is a single centred line.
    private var contentTop: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?

    /// Called when the prompt is submitted, by Return or by the button.
    var onSubmit: ((String) -> Void)?

    /// Called on every edit. Exists so what is typed can be kept somewhere it survives the
    /// app, rather than only in this field.
    var onChange: ((String) -> Void)?

    /// The prompt owns presentation and removal; its conversation owner supplies the short text
    /// prompt that turns an existing reference or image into a comment.
    var onRequestContextComment: ((ConversationContextAttachment) -> Void)?
    var onRequestImageComment: ((String) -> Void)?

    /// Disables only the send action. The editor remains live so a watcher can keep a private
    /// draft while somebody else controls the shared input stream.
    var isSubmissionEnabled = true {
        didSet { updateSubmitState() }
    }

    /// Why the send will not fire, said on the glyph rather than left to be guessed. Falls back
    /// to what the glyph says at rest — see `PromptViewDefaults.submitTitle`.
    var submissionDisabledReason: String? {
        didSet {
            submitButton.toolTip = submissionDisabledReason ?? PromptViewDefaults.submitTitle
            updateSubmitState()
        }
    }

    /// Actions advertised by the live provider. Assigning a replacement catalog immediately
    /// refreshes an open query, which matters when Claude broadcasts `commands_changed` or a
    /// Codex skill is enabled while this composer already contains its trigger.
    var composerCapabilities: [ComposerCapability] = [] {
        didSet { updateCompletions() }
    }

    /// Placeholder shown while empty. Set before the view is added.
    var placeholder: String = "" {
        didSet { textView.placeholder = placeholder }
    }

    /// Where the control that sends this prompt lives — and therefore what Return does *by
    /// default*, until `AppSettings.promptReturnKey` says otherwise.
    enum SubmitPlacement {
        /// The glyph inside the box. Return sends; Shift- or Option-Return breaks the line.
        /// The shape of a reply box, where a message is usually one line and sending it is
        /// the only thing that happens next.
        case inside

        /// Outside, as a button the owner places and titles. Return breaks the line and only
        /// ⌘Return sends.
        ///
        /// For the two *fields* that are not composers: the inspector's note and Help ▸ Report
        /// a Problem. Neither sends anywhere on its own — each is a paragraph attached to a
        /// report that the surrounding sheet submits — so there is no send to put in the box,
        /// and Return inside them is ordinary typing.
        ///
        /// It was the session composer's placement too, for a reason that no longer holds here:
        /// a brief is several lines and Return-sends turned each break into an accidental
        /// launch. `AppSettings.promptReturnKey` answers that now, and the composer shares the
        /// reply's box — see `docs/architecture/design-system.md`.
        case outside

        /// Inside, on a control row along the bottom of the box, at the end of it. Return
        /// sends, exactly as `.inside` — the send did not move, only the row it sits on.
        ///
        /// The row is what the placement is really for: the settings a message is sent *with*
        /// — which model, how hard it should think, how fast — belong to the message, so they
        /// belong inside the thing the message is written in. Left outside they became a strip
        /// of chips floating on the pane above the composer, reading as neither part of the
        /// conversation nor part of the input. Every chat client that has grown model choice
        /// has arrived at the same place: the box holds the text, the row under it holds what
        /// the text will be sent with, and the send closes the row.
        case footer
    }

    /// Defaults to `.inside`, because that is what every composer here was before there was a
    /// choice. Set it before the view is measured.
    var submitPlacement: SubmitPlacement = .inside {
        didSet {
            guard submitPlacement != oldValue else { return }
            applySubmitPlacement()
        }
    }

    /// How tall the box is before any text is in it.
    ///
    /// A composer that owns its whole pane opens taller than one docked in a row: the size of
    /// the box is what says how much is expected of it, and a one-line slot in an empty pane
    /// asks for one line.
    var minimumHeight: CGFloat = Design.Size.inputHeight {
        didSet { updateHeight() }
    }

    /// Whether image files are represented by previews rather than literal text paths.
    ///
    /// Opted into by agent-message composers only. `PromptView` also serves commit messages and
    /// inspector notes, where turning a dropped path into hidden transport metadata would change
    /// the meaning of the field rather than improve its presentation.
    var showsImageAttachments = false

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.needsDisplay = true

            // A restored draft is read from its beginning. Setting the text leaves the view
            // scrolled to the end, which shows the tail of a long prompt and reads as though
            // the start of it had been lost.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

            updateSubmitState()
            updateHeight()
            updateCompletions()
        }
    }

    /// Images waiting beside the text, in the same order their paths will be sent.
    ///
    /// The paths stay out of `stringValue`: a filesystem name is transport detail, and putting
    /// it into the editor is what made a pasted screenshot look like accidental prompt text.
    var attachmentPaths: [String] {
        attachments.map(\.path)
    }

    /// What the agent receives: the words exactly as typed, followed by quoted image paths.
    ///
    /// Kept separate from `stringValue` so drafts, selection, and the visible prompt all remain
    /// ordinary text while the CLI still gets the only form of an image it can open.
    var submissionValue: String {
        appending(paths: attachmentPaths, to: textView.string)
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        updateSurface()

        setupTextView()
        setupAttachmentStrip()
        setupFooterRow()

        submitButton.image = NSImage(
            systemSymbolName: DesignSymbols.submit,
            accessibilityDescription: L10n.string("Start session")
        )
        submitButton.isBordered = false
        submitButton.contentTintColor = Design.Text.tertiary
        submitButton.toolTip = PromptViewDefaults.submitTitle
        submitButton.target = self
        submitButton.action = #selector(submit)
        submitButton.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Design.Spacing.medium
        contentStack.detachesHiddenViews = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(contextRail)
        contentStack.addArrangedSubview(attachmentScrollView)
        contentStack.addArrangedSubview(scrollView)
        contentStack.addArrangedSubview(footerRow)

        // The row takes the stack's own step rather than a tighter one. Closed up to `small` it
        // sat nearer the text than the box's padding held it off its own edges, and the two
        // rows read as crowded against each other inside a box with room to spare. Equal air
        // above the text, between the two rows, and under the pills is the whole rhythm.

        contextRail.onRemove = { [weak self] attachment in
            self?.removeContextAttachment(id: attachment.id)
        }
        contextRail.onComment = { [weak self] attachment in
            self?.onRequestContextComment?(attachment)
        }

        addSubview(contentStack)
        addSubview(submitButton)

        let height = heightAnchor.constraint(equalToConstant: minimumHeight)
        height.priority = .defaultHigh
        heightConstraint = height

        let top = contentStack.topAnchor.constraint(
            equalTo: topAnchor,
            constant: PromptViewDefaults.verticalInset
        )
        let bottom = contentStack.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -PromptViewDefaults.verticalInset
        )
        contentTop = top
        contentBottom = bottom

        submitPinnedConstraints = [
            submitButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            // Pinned to the bottom rather than centred: as the box grows the control stays
            // beside the line being typed, which is where the eye already is.
            submitButton.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -PromptViewDefaults.submitBottomInset
            )
        ]

        NSLayoutConstraint.activate([
            height,
            top,
            bottom,

            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.inset
            ),
            attachmentScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            attachmentScrollView.heightAnchor.constraint(
                equalToConstant: Design.Size.promptAttachmentThumbnail
            ),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footerRow.heightAnchor.constraint(equalToConstant: Design.Size.chipHeight),

            submitButton.widthAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize),
            submitButton.heightAnchor.constraint(equalToConstant: PromptViewDefaults.submitSize)
        ] + submitPinnedConstraints)

        contentTrailingBesideSubmit = contentStack.trailingAnchor.constraint(
            equalTo: submitButton.leadingAnchor,
            constant: -Design.Spacing.inset
        )
        contentTrailingToEdge = contentStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Design.Spacing.inset
        )
        applySubmitPlacement()
    }

    private func setupFooterRow() {
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = Design.Spacing.small
        footerRow.detachesHiddenViews = true
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.isHidden = true

        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerRow.addArrangedSubview(footerSpacer)
    }

    /// Puts the submit glyph where the placement says, and gives the text the width whatever
    /// left the box's trailing edge is no longer using.
    ///
    /// Every constraint exists from setup; only the pair matching the placement is ever active,
    /// because a placement can change after the box is on screen — the component gallery does
    /// exactly that.
    private func applySubmitPlacement() {
        let isInside = submitPlacement == .inside
        let isFooter = submitPlacement == .footer

        submitButton.isHidden = submitPlacement == .outside
        footerRow.isHidden = !isFooter

        // The glyph belongs to one host at a time. Reparented rather than duplicated so the
        // button keeps its target, its tooltip, and whatever enabled state it was left in.
        if isFooter, submitButton.superview !== footerRow {
            NSLayoutConstraint.deactivate(submitPinnedConstraints)
            submitButton.removeFromSuperview()
            footerRow.addArrangedSubview(submitButton)
        } else if !isFooter, submitButton.superview !== self {
            footerRow.removeArrangedSubview(submitButton)
            submitButton.removeFromSuperview()
            addSubview(submitButton)
            NSLayoutConstraint.activate(submitPinnedConstraints)
        }

        contentTrailingBesideSubmit?.isActive = isInside
        contentTrailingToEdge?.isActive = !isInside

        // A box with a row under its text is padded like a panel; one whose whole content is a
        // single line is padded to centre that line in `Design.Size.inputHeight`.
        contentTop?.constant = verticalInset
        contentBottom?.constant = -verticalInset

        needsLayout = true
        updateHeight()
    }

    /// The box's own top and bottom padding, which the control row changes — see
    /// `PromptViewDefaults.footerVerticalInset`.
    private var verticalInset: CGFloat {
        submitPlacement == .footer
            ? PromptViewDefaults.footerVerticalInset
            : PromptViewDefaults.verticalInset
    }

    /// Resolves the user's setting against this composer's own default, at the keystroke.
    ///
    /// Asked per Return rather than stored, because the Settings window is open *beside* the
    /// composer while the choice is made: a flag written in `applySubmitPlacement` would leave
    /// every already-built pane answering with whatever was true when it was built, and the one
    /// pane the user is looking at is exactly the one that would be stale.
    ///
    /// The mapping lives here rather than on `PromptReturnKey` so the setting stays a Core type
    /// that knows nothing about a view's submit affordance.
    private func submitsOnReturn() -> Bool {
        switch AppSettings.promptReturnKey {
        case .sends: true
        case .startsNewLine: false
        // `.footer` is `.inside` with the glyph on a row rather than in a corner: the send is
        // still in the box, so Return still sends.
        case .matchesComposer: submitPlacement != .outside
        }
    }

    private func setupAttachmentStrip() {
        attachmentStack.orientation = .horizontal
        attachmentStack.alignment = .centerY
        attachmentStack.spacing = Design.Spacing.small
        // The scroll view owns the document's frame. Auto Layout still owns each thumbnail
        // inside the stack, while `layoutAttachmentStrip` states the document's scrollable
        // width from their fixed semantic size.
        attachmentStack.translatesAutoresizingMaskIntoConstraints = true

        attachmentScrollView.documentView = attachmentStack
        attachmentScrollView.hasHorizontalScroller = false
        attachmentScrollView.hasVerticalScroller = false
        attachmentScrollView.horizontalScrollElasticity = .automatic
        attachmentScrollView.verticalScrollElasticity = .none
        attachmentScrollView.isHidden = true
        attachmentScrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Which surface this composer belongs to, so what is typed matches what it becomes.
    ///
    /// `.chrome` for the session composer and the commit message; the conversation's reply box
    /// sets `.conversation`, because the text goes straight into the thread as a user bubble and
    /// a composer in SF feeding a bubble in Baskerville changes font on submit — the one moment
    /// the user is looking at the words.
    var fontSurface: Design.Typography.FontSurface = .chrome {
        didSet {
            guard fontSurface != oldValue else { return }
            textView.applyFont(.body, in: fontSurface)
        }
    }

    private func setupTextView() {
        textView.delegate = self
        textView.placeholder = placeholder
        textView.applyFont(.body, in: fontSurface)
        textView.textColor = Design.Text.label
        // State these explicitly instead of inheriting NSTextView's initializer defaults.
        // This is the app's primary input and must never become read-only because an AppKit
        // default changes or a future shared text-view setup starts from a display surface.
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        // Straight quotes and hyphens: a prompt is read by a CLI as often as by a person, and
        // a smart-quoted path or flag is a different string from the one that was typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onCompletionKey = { [weak self] event in
            self?.handleCompletionKey(event) ?? false
        }
        textView.submitsOnReturn = { [weak self] in self?.submitsOnReturn() ?? true }
        textView.onAttach = { [weak self] paths in self?.insertAttachments(paths) }
        textView.onFocusChange = { [weak self] focused in
            guard let self, self.isTextFocused != focused else { return }
            self.isTextFocused = focused
            self.updateSurface()
            if !focused { self.dismissCompletions() }
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Layout

    /// Text height depends on the width the box was given, which is not known when the text
    /// is set — a draft restored before layout measured against a container of the wrong
    /// width and opened at the wrong height. Re-measuring here is what makes it right, and
    /// it converges because `updateHeight` only touches the constraint when the value moves.
    override func layout() {
        super.layout()
        layoutAttachmentStrip()
        updateHeight()
        completionPresenter.reposition()
    }

    /// Once thumbnails occupy the top of the composer, a second image can land on them rather
    /// than on the text view. Register the whole rounded surface so every visible part of the
    /// input remains a drop target; the text view keeps its own registration for paste and for
    /// AppKit's normal editor routing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        unregisterDraggedTypes()
        guard window != nil else {
            dismissCompletions()
            return
        }
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    // MARK: - Public Methods

    /// Takes the caret and leaves it where it was.
    ///
    /// For focus the user did not ask for: removing an attachment hands the editor back, and a
    /// caret that jumps out of the middle of a half-written sentence is worse than no focus.
    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Takes the caret and places it after whatever is already in the editor.
    ///
    /// For a composer being *put on screen*. `stringValue` leaves the selection at the start so
    /// a restored draft is read from its beginning; once that composer is focused the same
    /// position means something else — the next keystroke lands in front of the user's own
    /// sentence rather than continuing it.
    func focusAtEnd() {
        focus()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// The owner's controls on the box's bottom row, under `SubmitPlacement.footer`.
    ///
    /// `leading` reads as what the message will be sent *with* — model, effort, speed — and
    /// `trailing` as what it has cost so far, beside the send. Both are the owner's own views:
    /// this component owns the row's geometry and knows nothing about what a provider offers.
    ///
    /// A hidden control is detached rather than left as a gap, so a provider offering no
    /// choices at all leaves the row to the send glyph rather than to a row of holes.
    func setFooterControls(leading: [NSView], trailing: [NSView]) {
        for view in footerRow.arrangedSubviews
        where view !== footerSpacer && view !== submitButton {
            footerRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, view) in leading.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            footerRow.insertArrangedSubview(view, at: index)
        }

        // Placed against the spacer rather than at a counted index: the send glyph may or may
        // not be on this row, and the trailing group belongs beside it either way.
        let spacerIndex = footerRow.arrangedSubviews.firstIndex(of: footerSpacer) ?? leading.count
        for (offset, view) in trailing.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            footerRow.insertArrangedSubview(view, at: spacerIndex + 1 + offset)
        }

        needsLayout = true
        updateHeight()
    }

    /// Adds files through the same path used by paste and drop.
    ///
    /// Images become previews; anything else remains literal text because a source file or
    /// folder has no meaningful thumbnail in a chat composer.
    func attachFiles(at paths: [String]) {
        insertAttachments(paths)
    }

    /// Clears sent content without conflating an empty draft with attached images.
    func clear() {
        stringValue = ""
        clearAttachments()
        clearContextAttachments()
    }

    /// Stages one provider-neutral reference or comment. Duplicate ids are ignored so choosing
    /// Add to chat twice cannot silently send the same context twice.
    func addContextAttachment(_ attachment: ConversationContextAttachment) {
        guard !contextAttachments.contains(where: { $0.id == attachment.id }) else { return }
        contextAttachments = ConversationContextPolicy.normalized(contextAttachments + [attachment])
        contextRail.setAttachments(contextAttachments)
        updateSubmitState()
        updateHeight()
        focus()
    }

    func clearContextAttachments() {
        guard !contextAttachments.isEmpty else { return }
        contextAttachments.removeAll()
        contextRail.setAttachments([])
        updateSubmitState()
        updateHeight()
    }

    /// Opens the skill half of the live catalog from the app-owned `/skills` command. The
    /// provider's native trigger is inserted so accepting a row follows the exact same path as
    /// typing `$` by hand.
    func showSkillCompletions() {
        guard let trigger = composerCapabilities.first(where: {
            $0.isAvailableInSkillCatalog
        })?.trigger else {
            return
        }
        stringValue = String(trigger.prefix)
        focusAtEnd()
        completionKindFilter = .skill
        updateCompletions()
    }

    // MARK: - Command and Skill Completion

    private func updateCompletions() {
        guard textView.selectedRange().length == 0,
              let query = ComposerCompletionQuery.parse(
                  textView.string,
                  caretUTF16Offset: textView.selectedRange().location
              ) else {
            dismissCompletions()
            return
        }

        let previousSelectionID = completionSuggestions.indices.contains(selectedCompletionIndex)
            ? completionSuggestions[selectedCompletionIndex].id
            : nil
        let suggestions = query.suggestions(
            from: composerCapabilities,
            matching: completionKindFilter
        )
        guard !suggestions.isEmpty else {
            dismissCompletions()
            return
        }

        completionQuery = query
        completionSuggestions = suggestions
        if let previousSelectionID,
           let matchingIndex = suggestions.firstIndex(where: {
               $0.id == previousSelectionID && $0.isEnabled
           }) {
            selectedCompletionIndex = matchingIndex
        } else {
            selectedCompletionIndex = firstEnabledCompletionIndex(in: suggestions) ?? 0
        }

        completionPresenter.present(
            items: suggestions,
            selectedIndex: selectedCompletionIndex,
            from: self,
            onChoose: { [weak self] index in self?.acceptCompletion(at: index) },
            onDismiss: { [weak self] in self?.clearCompletionState() }
        )
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard completionPresenter.isVisible, !completionSuggestions.isEmpty else { return false }

        switch event.keyCode {
        case PromptViewDefaults.escapeKeyCode:
            dismissCompletions()
            return true
        case PromptViewDefaults.upArrowKeyCode:
            moveCompletionSelection(by: -1)
            return true
        case PromptViewDefaults.downArrowKeyCode:
            moveCompletionSelection(by: 1)
            return true
        case PromptViewDefaults.tabKeyCode, PromptViewDefaults.returnKeyCode,
             PromptViewDefaults.keypadEnterKeyCode:
            acceptCompletion(at: selectedCompletionIndex)
            return true
        default:
            return false
        }
    }

    private func moveCompletionSelection(by offset: Int) {
        guard !completionSuggestions.isEmpty else { return }
        var candidate = selectedCompletionIndex
        for _ in completionSuggestions.indices {
            candidate = (candidate + offset + completionSuggestions.count)
                % completionSuggestions.count
            if completionSuggestions[candidate].isEnabled {
                selectedCompletionIndex = candidate
                completionPresenter.select(candidate)
                return
            }
        }
    }

    private func acceptCompletion(at index: Int) {
        guard completionSuggestions.indices.contains(index),
              completionSuggestions[index].isEnabled,
              let completionQuery else { return }
        let capability = completionSuggestions[index]
        textView.insertText(
            capability.invocationText + " ",
            replacementRange: completionQuery.replacementRange
        )
        dismissCompletions()
    }

    private func firstEnabledCompletionIndex(in suggestions: [ComposerCapability]) -> Int? {
        suggestions.firstIndex(where: \.isEnabled)
    }

    private func dismissCompletions() {
        completionPresenter.dismiss()
        clearCompletionState()
    }

    private func clearCompletionState() {
        completionQuery = nil
        completionSuggestions = []
        selectedCompletionIndex = 0
        completionKindFilter = nil
    }

    /// Attachments are intentionally not drafts: raw clipboard images live in a temporary
    /// file, and silently carrying one from one project's composer to another is worse than
    /// asking for it again.
    func clearAttachments() {
        guard !attachments.isEmpty else { return }
        attachments.removeAll()
        attachmentStack.arrangedSubviews.forEach {
            attachmentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        attachmentScrollView.isHidden = true
        attachmentScrollView.contentView.scroll(to: .zero)
        updateSubmitState()
        updateHeight()
    }

    // MARK: - Dragging

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        PromptAttachment.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        PromptAttachment.canRead(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = PromptAttachment.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        insertAttachments(paths)
        return true
    }

    // MARK: - Actions

    /// Sends what is in the box, exactly as the inline glyph and the keyboard do.
    ///
    /// Reachable from outside for `SubmitPlacement.outside`, where the button belongs to the
    /// owner: it has to submit *this* prompt's value, attachments included, rather than reading
    /// `stringValue` and quietly dropping the images.
    @objc func submit() {
        guard isSubmissionEnabled else { return }
        onSubmit?(submissionValue)
    }

    /// Makes images visible as attachments while leaving other files as paths in the editor.
    ///
    /// Both cases still become paths before submission — neither CLI can see pixels that only
    /// existed on the pasteboard — but the distinction matters to the person composing the
    /// prompt. An image is something they should be able to recognise and remove at a glance;
    /// a source file's exact path is the useful content.
    private func insertAttachments(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        guard showsImageAttachments else {
            insertLiteralPaths(paths)
            return
        }

        var literalPaths: [String] = []

        for path in paths {
            guard let image = NSImage(contentsOfFile: path), image.isValid else {
                literalPaths.append(path)
                continue
            }

            let attachment = PromptImageAttachment(path: path, image: image)
            attachments.append(attachment)

            let thumbnail = PromptAttachmentThumbnail(attachment: attachment)
            thumbnail.inspectorSelectionProvider = { [weak self] in
                guard let self,
                      let selectedIndex = self.attachments.firstIndex(where: {
                          $0.id == attachment.id
                      })
                else { return nil }

                let items = self.attachments.map {
                    MediaInspectorItem(
                        url: URL(fileURLWithPath: $0.path),
                        title: $0.name,
                        image: $0.image
                    )
                }
                return MediaInspectorSelection(items: items, selectedIndex: selectedIndex)
            }
            thumbnail.onRemove = { [weak self, weak thumbnail] in
                guard let self, let thumbnail else { return }
                self.removeAttachment(id: attachment.id, thumbnail: thumbnail)
            }
            if onRequestImageComment != nil {
                thumbnail.onComment = { [weak self] in
                    self?.onRequestImageComment?(attachment.path)
                }
            }
            attachmentStack.addArrangedSubview(thumbnail)
        }

        if !attachments.isEmpty {
            attachmentScrollView.isHidden = false
            layoutAttachmentStrip()
        }

        insertLiteralPaths(literalPaths)
        updateSubmitState()
        updateHeight()
    }

    private func insertLiteralPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }

        let quoted = paths.map(Self.quotedPath)
        var addition = quoted.joined(separator: " ")

        let existing = textView.string
        if !existing.isEmpty, !existing.hasSuffix(" "), !existing.hasSuffix("\n") {
            addition = " " + addition
        }

        textView.insertText(addition, replacementRange: textView.selectedRange())
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func removeAttachment(id: UUID, thumbnail: PromptAttachmentThumbnail) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments.remove(at: index)
        attachmentStack.removeArrangedSubview(thumbnail)
        thumbnail.removeFromSuperview()
        attachmentScrollView.isHidden = attachments.isEmpty
        layoutAttachmentStrip()
        updateSubmitState()
        updateHeight()
        focus()
    }

    private func removeContextAttachment(id: UUID) {
        guard contextAttachments.contains(where: { $0.id == id }) else { return }
        contextAttachments.removeAll { $0.id == id }
        contextRail.setAttachments(contextAttachments)
        updateSubmitState()
        updateHeight()
        focus()
    }

    private static func quotedPath(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    private func appending(paths: [String], to text: String) -> String {
        guard !paths.isEmpty else { return text }

        let addition = paths.map(Self.quotedPath).joined(separator: " ")
        guard !text.isEmpty else { return addition }
        guard !text.hasSuffix(" "), !text.hasSuffix("\n") else {
            return text + addition
        }
        return text + " " + addition
    }

    private func layoutAttachmentStrip() {
        guard !attachments.isEmpty else {
            attachmentStack.frame = .zero
            return
        }

        let count = CGFloat(attachments.count)
        let contentWidth = count * Design.Size.promptAttachmentThumbnail
            + max(0, count - 1) * Design.Spacing.small
        attachmentStack.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(contentWidth, attachmentScrollView.contentSize.width),
                height: Design.Size.promptAttachmentThumbnail
            )
        )
        attachmentStack.layoutSubtreeIfNeeded()
    }

    /// The submit control brightens once there is something to send, which is the only cue
    /// that Return will do anything.
    private func updateSubmitState() {
        let hasText = !textView.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasContent = hasText || !attachments.isEmpty || !contextAttachments.isEmpty

        submitButton.isEnabled = hasContent && isSubmissionEnabled
        submitButton.contentTintColor = hasContent && isSubmissionEnabled
            ? Design.Surface.accent
            : Design.Text.tertiary
    }

    private func updateSurface() {
        // The prompt is where text is typed, so under a bevel material it reads sunken — a
        // carved well, like every text field.
        applySurface(
            fill: Design.Surface.field,
            radius: .panel,
            border: isTextFocused ? Design.Surface.accent : Design.Surface.border,
            borderWidth: isTextFocused
                ? Design.Accessibility.focusRingWidth
                : Design.Radius.border,
            glow: true,
            bevel: .sunken
        )
    }

    /// Sizes the box to its text, between one line and `inputMaxHeight`.
    private func updateHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        layoutManager.ensureLayout(for: container)
        let textHeight = layoutManager.usedRect(for: container).height
        let chrome = verticalInset * 2
        let attachmentHeight = attachments.isEmpty
            ? 0
            : Design.Size.promptAttachmentThumbnail + Design.Spacing.medium
        let contextHeight = contextAttachments.isEmpty
            ? 0
            : Design.Size.chipHeight + Design.Spacing.medium
        let footerHeight = footerRow.isHidden
            ? 0
            : Design.Size.chipHeight + contentStack.spacing

        // The control row comes *out of* the minimum rather than adding to it, which is the
        // opposite of the attachment strip above: a strip is content the user put there and
        // must not shrink the field they are typing in, while the row is the box's own chrome
        // and is present from the first keystroke. Adding it instead opened an empty reply box
        // at a hundred points — a paragraph of height asking for one line.
        let textFloor = max(0, minimumHeight - footerHeight)
        let cap = max(Design.Size.inputMaxHeight - footerHeight, textFloor)
        let textFitted = min(max(textHeight + chrome, textFloor), cap)

        let fitted = textFitted + attachmentHeight + contextHeight + footerHeight

        // Past the cap the box stops growing, so the scroller has to take over. Decided before
        // the height guard below, because the box is already at its cap by the time the text
        // that overflows it arrives — gated behind that guard, the run of edits that actually
        // needs a scroller is the one run that never reaches this line. Still compared before
        // assigning: `hasVerticalScroller` re-tiles the scroll view, and `layout()` calls
        // through here, so an unconditional write is a layout loop.
        let needsScroller = textFitted >= cap
        if scrollView.hasVerticalScroller != needsScroller {
            scrollView.hasVerticalScroller = needsScroller
        }

        guard heightConstraint?.constant != fitted else { return }
        heightConstraint?.constant = fitted
    }
}

// MARK: - Prompt Image Attachment

private struct PromptImageAttachment {
    let id = UUID()
    let path: String
    let image: NSImage

    var name: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// One recognisable image with its removal control over the corner, matching the attachment
/// treatment in the chat composer rather than exposing a temporary path as if it were prose.
private final class PromptAttachmentThumbnail: ThemedControl {

    private let attachment: PromptImageAttachment
    private let removeButton: PromptAttachmentRemoveButton
    private var isPressed = false { didSet { needsDisplay = true } }
    private var menuSession: AnyObject?

    var onRemove: (() -> Void)?
    var onComment: (() -> Void)?
    var inspectorSelectionProvider: (() -> MediaInspectorSelection?)?

    init(attachment: PromptImageAttachment) {
        self.attachment = attachment
        removeButton = PromptAttachmentRemoveButton(
            accessibility: "Remove \(attachment.name)"
        )
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)

        removeButton.onPress = { [weak self] in self?.onRemove?() }
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            heightAnchor.constraint(equalToConstant: Design.Size.promptAttachmentThumbnail),
            removeButton.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),
            removeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.tight
            )
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let radius = Design.Radius.control
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let imageSize = attachment.image.size
        if imageSize.width > 0, imageSize.height > 0 {
            let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let destination = NSRect(
                x: bounds.midX - imageSize.width * scale / 2,
                y: bounds.midY - imageSize.height * scale / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            attachment.image.draw(
                in: destination,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            Design.Surface.controlResting.setFill()
            path.fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let borderWidth = Design.Radius.border
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            xRadius: max(0, radius - borderWidth / 2),
            yRadius: max(0, radius - borderWidth / 2)
        )
        let isHighlighted = isHovered || hasKeyboardFocus
        (isHighlighted ? Design.Surface.accent : Design.Surface.border).setStroke()
        borderPath.lineWidth = borderWidth
        borderPath.stroke()

        if isPressed {
            Design.Surface.controlHover.setFill()
            path.fill()
        }

        drawKeyboardFocus(
            around: ThemedSurface.Shape(rect: bounds, radius: radius),
            color: Design.Surface.accent
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldPreview = isPressed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldPreview { _ = performPrimaryAction() }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = presentContextMenu(at: .pointer(event.locationInWindow))
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    /// No pointer asked for this one, so it hangs from the thumbnail itself.
    override func accessibilityPerformShowMenu() -> Bool {
        presentContextMenu(at: .control)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { attachment.name }
    override func accessibilityHelp() -> String? {
        L10n.format("Press to inspect %@", attachment.name)
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled else { return false }
        window?.makeFirstResponder(self)

        let selection = inspectorSelectionProvider?()
            ?? existingFileURL.map {
                MediaInspectorSelection(
                    items: [MediaInspectorItem(
                        url: $0,
                        title: attachment.name,
                        image: attachment.image
                    )],
                    selectedIndex: 0
                )
            }
        guard let selection, MediaInspectorPresenter.present(selection, from: self) else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func presentContextMenu(at anchor: ThemedMenuAnchor) -> Bool {
        guard menuSession == nil else { return true }

        var entries: [ThemedMenuEntry] = [
            item("Inspect") { [weak self] in _ = self?.performPrimaryAction() }
        ]
        if onComment != nil {
            entries.append(item("Comment…") { [weak self] in self?.onComment?() })
        }
        entries += [
            item("Open in Default App") { [weak self] in self?.openInDefaultApp() },
            item("Reveal in Finder") { [weak self] in self?.revealInFinder() },
            .separator,
            item("Copy Image") { [weak self] in self?.copyImage() },
            item("Copy File Name") { [weak self] in self?.copyFileName() },
            item("Copy File Path") { [weak self] in self?.copyFilePath() },
            .separator,
            item("Open in System Quick Look") { [weak self] in self?.openQuickLook() },
            .separator,
            item("Remove Attachment") { [weak self] in self?.removeAttachment() }
        ]

        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 190),
            from: self,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
        return menuSession != nil
    }

    private func item(_ title: String, action: @escaping () -> Void) -> ThemedMenuEntry {
        .item(ThemedMenuItem(title: title, onChoose: action))
    }

    private func openQuickLook() {
        guard QuickLookPresenter.shared.present(existingFileURL) else {
            NSSound.beep()
            return
        }
    }

    private func openInDefaultApp() {
        guard let url = existingFileURL, NSWorkspace.shared.open(url) else {
            NSSound.beep()
            return
        }
    }

    private func revealInFinder() {
        guard let url = existingFileURL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([attachment.image])
    }

    private func copyFileName() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(attachment.name, forType: .string)
    }

    private func copyFilePath() {
        guard let url = existingFileURL else {
            NSSound.beep()
            return
        }

        // Keep the string useful in a terminal while the URL lets Finder and document apps
        // treat the same paste as a file.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.path, forType: .string)
    }

    private func removeAttachment() {
        onRemove?()
    }

    private var existingFileURL: URL? {
        guard FileManager.default.fileExists(atPath: attachment.path) else { return nil }
        return URL(fileURLWithPath: attachment.path)
    }
}

/// The close affordance floats over arbitrary pixels, so its fill is flattened to an opaque
/// themed colour before drawing. A translucent control surface here lets the screenshot change
/// the button's contrast from one attachment to the next.
private final class PromptAttachmentRemoveButton: ThemedControl {

    private let iconView = NSImageView()
    private let accessibilityName: String
    private var isPressed = false { didSet { needsDisplay = true } }

    var onPress: (() -> Void)?

    init(accessibility: String) {
        accessibilityName = accessibility
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: DesignSymbols.removeAttachment,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.control,
            weight: .medium
        )
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonTarget),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            iconView.heightAnchor.constraint(equalToConstant: Design.Symbol.control)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Design.Size.inlineButtonTarget,
            height: Design.Size.inlineButtonTarget
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let panel = Design.Surface.panel.composited(over: Design.Surface.ground)
        let resting = Design.Surface.elevated.composited(over: panel)
        let fill = isPressed || isHovered
            ? Design.Surface.controlHover.composited(over: resting)
            : resting
        let ink = Design.Text.on(fill)
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: ink.border,
            radius: Design.Radius.pill(height: bounds.height)
        )
        drawKeyboardFocus(around: shape, color: ink.label)
        iconView.contentTintColor = isEnabled ? ink.label : ink.quaternary
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFire = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if shouldFire { performPress() }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { performPress() }
    override func performPrimaryAction() -> Bool { performPress() }

    @discardableResult
    private func performPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}

// MARK: - NSTextViewDelegate

extension PromptView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        updateSubmitState()
        updateHeight()
        updateCompletions()
        onChange?(textView.string)
    }
}

// MARK: - Prompt Text View

/// The editable surface inside a `PromptView`.
///
/// Exists for three behaviours `NSTextView` does not have: a placeholder, Return meaning
/// *submit* rather than *newline*, and files arriving by drag or paste becoming prompt
/// attachments or paths instead of being refused (images) or pasted as attachment cells.
private final class PromptTextView: ThemedTextView {

    // MARK: - Properties

    var placeholder: String = "" { didSet { needsDisplay = true } }

    /// Return, without a modifier — or ⌘Return, always.
    var onSubmit: (() -> Void)?

    /// Gives the owning composer first refusal for navigation/acceptance while a completion
    /// panel is visible. Marked text bypasses this hook so IME candidate selection remains
    /// entirely inside the input method.
    var onCompletionKey: ((NSEvent) -> Bool)?

    /// Whether a bare Return sends, asked at the keystroke. Answering `false` leaves Return to
    /// the editor and keeps ⌘Return as the only way to send from the keyboard.
    ///
    /// A closure rather than a flag because the answer is a user setting as well as a property
    /// of the surface; see `PromptView.submitsOnReturn()`.
    var submitsOnReturn: () -> Bool = { true }

    /// Paths for whatever was dropped or pasted, already written to disk.
    var onAttach: (([String]) -> Void)?

    /// Lets the owning surface draw focus around the whole composer, not merely blink a caret
    /// inside one descendant.
    var onFocusChange: ((Bool) -> Void)?

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // While focused the accent border and insertion caret are the cue. Drawing the
        // placeholder at the selection origin after `super` can cover that caret and make a
        // successfully focused editor appear inert.
        guard window?.firstResponder !== self,
              string.isEmpty,
              !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Design.Typography.body(),
            .foregroundColor: Design.Text.tertiary
        ]

        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            needsDisplay = true
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            needsDisplay = true
            onFocusChange?(false)
        }
        return resigned
    }

    /// A view taken out of its window loses the first responder without ever being *asked* to
    /// resign it, so the two callbacks above do not cover every way the caret leaves. Left
    /// alone the composer keeps drawing its accent ring around a box nothing is typing into,
    /// which is the one state a focus ring may never describe.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // The drag overrides below are inert until AppKit registers the view as a drag
        // destination, and `NSTextView` never registers one built the way this one is:
        // programmatic text network, plain text, hosted in a scroll view. The measured state
        // was `registeredDraggedTypes == []`, which is not "refuses images" — it is the
        // window server never routing the drag here at all, so `acceptableDragTypes` was
        // never read and `readSelection` never called. The composer therefore refused every
        // dropped image while ⌘V of the same image worked, since paste reaches
        // `readSelection` without going near drag registration.
        //
        // **This has to be here rather than in setup.** Registering before the view has a
        // window leaves `registeredDraggedTypes` empty just the same; only a call once the
        // view is in a window sticks.
        updateDragTypeRegistration()

        onFocusChange?(window?.firstResponder === self)
    }

    // MARK: - Key Handling

    /// Two rules hold whatever the surface and whatever the user has set, so there is always a
    /// key that cannot surprise: **⌘Return sends**, and **Shift- or Option-Return breaks the
    /// line**. What a bare Return does is the only part that varies, and `submitsOnReturn`
    /// answers it — the composer's own default unless `AppSettings.promptReturnKey` overrides.
    ///
    /// ⌘Return is handled here as well as by whatever button names it, because a prompt is
    /// used without one — the chord belongs to the *field*, and only reaches a key equivalent
    /// when someone put one in the same window.
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onCompletionKey?(event) == true {
            return
        }
        guard event.keyCode == PromptViewDefaults.returnKeyCode else {
            super.keyDown(with: event)
            return
        }

        // Return belongs to the input method for as long as one has marked text: with a
        // Japanese, Chinese or Korean IME, Return is how a conversion candidate is *accepted*,
        // and it arrives here long before the user has finished the word. Sending on it posts
        // a half-written prompt — and worse, one missing the very characters still uncommitted,
        // since marked text is not yet in `string`. This is the same bug filed against Claude
        // Code, Copilot Chat, Cursor and JetBrains' AI assistant; the fix everywhere is to let
        // the composition have the key. ⌘Return is included deliberately: a send that drops
        // the uncommitted tail is the defect, not the modifier.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            onSubmit?()
            return
        }

        let wantsNewline = !submitsOnReturn()
            || modifiers.contains(.shift)
            || modifiers.contains(.option)

        if wantsNewline {
            super.keyDown(with: event)
            return
        }

        onSubmit?()
    }

    // MARK: - Drag and Paste

    /// Both drops and pastes arrive here, so one implementation serves the pointer and the
    /// keyboard alike.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let paths = PromptAttachment.paths(from: pboard)

        guard !paths.isEmpty else {
            return super.readSelection(from: pboard, type: type)
        }

        onAttach?(paths)
        return true
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.acceptableDragTypes
    }
}

// MARK: - Prompt Attachment

/// Turns whatever is on a pasteboard into file paths an agent can open.
enum PromptAttachment {

    /// Paths for the pasteboard's contents: dropped files as they are, and raw image data
    /// written out first, since a screenshot on the pasteboard has no path of its own.
    static func paths(from pasteboard: NSPasteboard) -> [String] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL).map(\.path)
        }

        guard let data = imageData(from: pasteboard), let path = write(data) else { return [] }
        return [path]
    }

    /// Files the user handed to a session, filed so they sit beside what the agent made of them.
    ///
    /// The one rename: a pasted screenshot is written under a generated name, which is right for
    /// a file that only has to outlive the turn and unreadable as a row someone is scanning. A
    /// dropped file keeps the name it already had.
    @MainActor
    static func record(paths: [String], sessionID: SessionID, projectRoot: URL) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let isGenerated = url.lastPathComponent.hasPrefix(PromptViewDefaults.attachmentPrefix)
            SessionAttachmentStore.shared.record(
                declared: url,
                sessionID: sessionID,
                projectRoot: projectRoot,
                origin: .user,
                preferredName: isGenerated ? L10n.string("Pasted image") : nil
            )
        }
    }

    /// Whether `paths` would find anything, without doing the work.
    ///
    /// A drag is answered continuously while the pointer moves, and answering it by writing a
    /// screenshot to the temporary directory would leave a file per frame of the gesture.
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    // MARK: - Private Methods

    /// PNG as offered, else whatever the image is re-encoded as PNG — one format on disk
    /// keeps the extension honest.
    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }

        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        return bitmap.representation(using: .png, properties: [:])
    }

    /// Written to the temporary directory, which is where the agent CLIs put their own
    /// pasted images: the file only has to outlive the turn that names it.
    private static func write(_ data: Data) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(PromptViewDefaults.attachmentPrefix)\(UUID().uuidString)")
            .appendingPathExtension(PromptViewDefaults.attachmentExtension)

        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            ThreadingLogger.session.error(
                "Failed to write dropped image: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Prompt View Defaults

enum PromptViewDefaults {
    static let submitSize: CGFloat = 18

    /// What the send glyph says when it is asked, and the only name it has.
    ///
    /// A glyph has no face to write a chord on — which is the one thing the titled button that
    /// used to sit outside the session composer could do — so the tooltip carries `⌘Return`
    /// instead. It doubles as the control's accessible name: `ThemedButton` reads the tooltip
    /// for a button with no title, and an unnamed send is unusable from VoiceOver.
    static var submitTitle: String { L10n.string("Send · ⌘Return") }

    /// Keeps a one-line prompt vertically centred in `Design.Size.inputHeight`.
    static let verticalInset: CGFloat = 13
    static let submitBottomInset: CGFloat = 13

    /// The padding a box with a control row uses instead.
    ///
    /// 13 exists to centre one line in a 44pt box and means nothing once there is a second row
    /// under that line: kept, it padded the text by a line's worth of air at the top and left
    /// the row crowding the bottom edge. A panel's own step reads as one box holding two rows.
    static let footerVerticalInset: CGFloat = Design.Spacing.medium

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125

    static let attachmentPrefix = "threading-attachment-"
    static let attachmentExtension = "png"
}
