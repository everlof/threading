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

    /// The half beside the send that offers to send it later. Built lazily and only ever added
    /// once a `scheduleMenuProvider` exists, so a box with nothing to schedule carries no extra
    /// view at all.
    private lazy var scheduleChevron: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: PromptViewDefaults.scheduleChevronSymbol,
            accessibility: L10n.string("Send later"),
            target: .compactSplitMenu
        )
        button.toolTip = L10n.string("Send later")
        button.onPress = { [weak self] in self?.presentScheduleMenu() }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("composer.schedule")
        return button
    }()

    /// What holds the text clear of the chevron when it is present, swapped for the plain
    /// beside-the-send constraint when it is not. Held as a pair for the same reason the two
    /// trailing edges below are: only one may be active at a time.
    private var contentTrailingBesideChevron: NSLayoutConstraint?
    /// The chevron is overlaid beside an inline send, but is an arranged peer of a footer send.
    /// Retaining the inline pair lets placement changes migrate it without accumulating dormant
    /// constraints between two different ownership trees.
    private var scheduleInlineConstraints: [NSLayoutConstraint] = []

    /// The control row along the bottom of the box — see `SubmitPlacement.footer`.
    private let footerRow = NSStackView()

    /// Whether anything has been put on that row. The row is the *controls'*, not the send's:
    /// a box can carry what its message will be sent with and still have its send button
    /// outside, which is the session brief. Kept as a flag rather than counted off
    /// `arrangedSubviews`, since the spacer and the glyph are on the row either way.
    private var hasFooterControls = false

    /// What pushes the trailing group to the far edge of that row. A view rather than a
    /// stack-view distribution: the two groups are pinned to their own edges and the gap
    /// between them is whatever is left, which is the only arrangement that holds when the
    /// leading group empties itself down to nothing.
    private let footerSpacer = NSView()
    private let completionPresenter = PromptCompletionPresenter()
    private var attachments: [PromptImageAttachment] = []
    private(set) var contextAttachments: [ConversationContextAttachment] = []
    private var isTextFocused = false

    /// Whether a drag the composer can take is over the box right now.
    ///
    /// One flag for two destinations: the rounded surface registers for drags (see
    /// `viewDidMoveToWindow`) and the text view keeps its own registration, so a pointer
    /// crossing from padding to editor moves between *views* without ever leaving the *box*.
    /// Both report here, and the surface answers as one input — a state that lit only the half
    /// the pointer happened to be over would read as two drop targets where there is one.
    private var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            updateSurface()
        }
    }

    private enum CompletionAction {
        case capability(ComposerCapability)
        case workspaceFile(WorkspaceFileReference)
    }
    private var completionItems: [PromptCompletionItem] = []
    private var completionActions: [CompletionAction] = []
    private var completionQuery: ComposerCompletionQuery?
    private var workspaceFileQuery: WorkspaceFileMentionQuery?
    private var workspaceSearchGeneration = 0
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

    /// Called when ⌘Return asks for the message to join the turn already running.
    ///
    /// Only ever fired in `.working(canSteer: true)`. A composer whose transport cannot steer
    /// does not offer the chord at all rather than quietly doing something else with it.
    var onSteer: ((String) -> Void)?

    /// Called when the glyph, now a Stop, is pressed.
    var onStop: (() -> Void)?

    /// The other ways to take a send: later, at a time chosen from a menu.
    ///
    /// **Nil means no chevron at all**, which is what keeps every other box in the app exactly as
    /// it was — the inspector's note and Help ▸ Report a Problem have nothing to schedule, and a
    /// chevron beside their send would be offering a feature that does not apply to them.
    ///
    /// The chevron is drawn only while the glyph is a **Send**. In `.working` the glyph is a
    /// Stop, and a chevron welded to a Stop reads as "stop, in other ways" — which is not a
    /// sentence, and not what the menu does.
    var scheduleMenuProvider: (() -> [ThemedMenuEntry])? {
        didSet { updateSubmitState() }
    }

    /// ↑ in an empty box. Answering true consumes the key.
    ///
    /// The composer offers the gesture and the owner decides what "back" means — for a
    /// conversation it is the last queued message, which is Claude Code's own affordance
    /// ("Press up to edit queued messages"). An empty box is the whole condition: ↑ has to keep
    /// moving the caret in a draft, or a multi-line prompt becomes uneditable.
    var onRecallPrevious: (() -> Bool)?

    /// What the composer is for at this moment.
    ///
    /// The box knows nothing about providers, transports or queues: the owner resolves all three
    /// into this one value, and the glyph, the tooltip and what ⌘Return does follow from it. That
    /// boundary is why adding a fourth runtime cannot reach into here.
    var composerMode: PromptComposerMode = .ready {
        didSet {
            guard composerMode != oldValue else { return }
            updateSubmitState()
        }
    }

    /// Called on every edit. Exists so what is typed can be kept somewhere it survives the
    /// app, rather than only in this field.
    var onChange: ((String) -> Void)?

    /// Mirrors whether the prompt can be submitted for an owner whose primary action lives
    /// outside the box.
    ///
    /// `PromptView` owns more than text: an image or a context reference is submittable content
    /// too, and either can change without `onChange` firing. An outside button that inferred its
    /// state from the string therefore disagreed with the box. This callback is emitted from the
    /// same calculation that drives the built-in send, so both actions keep one answer.
    var onSubmissionAvailabilityChange: ((Bool) -> Void)?

    /// Context has draft semantics too. Keeping this separate from `onChange` lets an owner
    /// persist a chip removal even when no editable character changed.
    var onContextAttachmentsChange: (([ConversationContextAttachment]) -> Void)?

    /// The prompt owns presentation and removal; its conversation owner supplies the short text
    /// prompt that turns an existing reference or image into a comment.
    var onRequestContextComment: ((ConversationContextAttachment) -> Void)?

    /// Opens the editable source behind a linked receipt, such as an image annotation document.
    var isContextAttachmentOpenable: ((ConversationContextAttachment) -> Bool)? {
        didSet { contextRail.isOpenable = isContextAttachmentOpenable }
    }
    var onOpenContextAttachment: ((ConversationContextAttachment) -> Void)? {
        didSet { contextRail.onOpen = onOpenContextAttachment }
    }
    var onRequestImageComment: ((String) -> Void)?

    /// Sidebar sessions dropped on the box, in drag order.
    ///
    /// The owner turns them into receipts (`SessionReferenceHandoff`) and stages them, because
    /// what a reference says depends on which session is reading it and the prompt does not
    /// know whose it is. Nil — a composer with no session behind it — refuses the drag
    /// outright, so the pointer says no rather than the drop doing nothing.
    var onSessionReferenceDrop: (([SessionID]) -> Void)?

    /// Disables only the send action. The editor remains live so a watcher can keep a private
    /// draft while somebody else controls the shared input stream.
    var isSubmissionEnabled = true {
        didSet { updateSubmitState() }
    }

    /// Why the send will not fire, said on the glyph rather than left to be guessed. Falls back
    /// to what the glyph says at rest — see `refreshSubmitTitle`.
    var submissionDisabledReason: String? {
        didSet { updateSubmitState() }
    }

    /// Actions advertised by the live provider. Assigning a replacement catalog immediately
    /// refreshes an open query, which matters when Claude broadcasts `commands_changed` or a
    /// Codex skill is enabled while this composer already contains its trigger.
    var composerCapabilities: [ComposerCapability] = [] {
        didSet { updateCompletions() }
    }

    /// Frontend-neutral workspace operation supplied by the conversation host. The prompt can
    /// request relative references; it never receives a root URL or arbitrary read capability.
    var workspaceFileSearch: (@MainActor @Sendable (
        String,
        @escaping @MainActor @Sendable (
            Result<[WorkspaceFileReference], WorkspaceFileSearchFailure>
        ) -> Void
    ) -> Void)? {
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
        /// For the *fields* that are not composers: the inspector's note and Help ▸ Report a
        /// Problem. Neither sends anywhere on its own — each is a paragraph attached to a report
        /// that the surrounding sheet submits — so there is no send to put in the box, and
        /// Return inside them is ordinary typing.
        ///
        /// And for the session brief, for the reason that has always applied to it: a brief is
        /// several lines, often a pasted paragraph, and a Return that sends spends one of those
        /// breaks on an accidental launch. It sent on Return for one commit — the send had moved
        /// onto the control row, and this enum was reading "the send is in the box" as "Return
        /// sends" — while its tooltip went on promising ⌘Return, which is the one thing a send
        /// may not do. The button outside says the chord on its face instead.
        ///
        /// It costs the box nothing: `setFooterControls` decides whether there is a control row,
        /// not this. See `docs/architecture/design-system.md`.
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
        ///
        /// This case is only about the *send*, though. A box gets its row from
        /// `setFooterControls`, so `.outside` keeps whatever was put on it.
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

    /// The answer used by both an in-box submit and an owner-provided outside action.
    var isSubmissionAvailable: Bool {
        hasSubmittableContent && isSubmissionEnabled
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
        refreshSubmitTitle()
        submitButton.target = self
        submitButton.action = #selector(primaryAction)
        submitButton.setAccessibilityIdentifier("composer.prompt.submit")
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
        // **Below every member of the row**, which `defaultLow` was not: it is the usage
        // reading's own compression resistance to the point, so the gap between the two runs and
        // the reading beside it were two claims on the same slack at the same priority, and an
        // ambiguous system resolves that however it likes. It resolved it by squeezing the
        // reading to a third of its width and handing the difference to the gap — a row visibly
        // holding 90 spare points while the number in it read `5h 86…`. The empty middle is
        // never the thing worth keeping, so it stretches last and collapses first.
        // `PromptViewDefaults.spacerPriority` is the composer's `spacerPriority`, for the same
        // reason and stated the same way.
        footerSpacer.setContentHuggingPriority(PromptViewDefaults.spacerPriority, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(
            PromptViewDefaults.spacerPriority,
            for: .horizontal
        )
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
        footerRow.isHidden = !showsFooterRow

        // Break the inline bridge before the send is moved into its own content stack. Leaving
        // it active for even that reparenting turn creates a cycle: the content stack must end
        // before the chevron, while the send inside that same stack must begin after it.
        if isFooter {
            NSLayoutConstraint.deactivate(scheduleInlineConstraints)
            contentTrailingBesideChevron?.isActive = false
        }

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

        updateScheduleChevron(
            hasContent: hasSubmittableContent,
            isStop: composerMode.canStop
        )
        needsLayout = true
        updateHeight()
    }

    /// Whether the box draws a control row under its text: because the send sits on one, or
    /// because the owner put its own controls there.
    private var showsFooterRow: Bool {
        submitPlacement == .footer || hasFooterControls
    }

    /// The box's own top and bottom padding, which the control row changes — see
    /// `PromptViewDefaults.footerVerticalInset`.
    private var verticalInset: CGFloat {
        showsFooterRow
            ? PromptViewDefaults.footerVerticalInset
            : PromptViewDefaults.verticalInset
    }

    /// How tall the box stands with nothing in it.
    ///
    /// A field with no control row centres one line in `Design.Size.inputHeight`, which is what
    /// `minimumHeight` has always meant. A box with a row under its text is not that shape: it is
    /// a small panel, and the number that sized a single-line field says nothing about how much
    /// typing room a *reply* is worth. Left at 44 the resting reply box came out at roughly one
    /// line of prose over a chip row — a box that looked like it wanted a sentence, in a place
    /// people write paragraphs.
    ///
    /// Stated in lines rather than as a constant so it stays right when the conversation's font
    /// or size changes; the chrome and the row are added on top by `updateHeight`.
    private var restingHeight: CGFloat {
        guard showsFooterRow else { return minimumHeight }
        let line = Design.FontRole.body.resolved(in: fontSurface).boundingRectForFont.height
        let text = (line * PromptViewDefaults.restingLines).rounded()
        return max(
            minimumHeight,
            text + verticalInset * 2 + Design.Size.chipHeight + contentStack.spacing
        )
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
        textView.setAccessibilityIdentifier("composer.prompt.text")
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

        textView.onSubmit = { [weak self] intent in self?.submit(intent: intent) }
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
        textView.onDropTargetChange = { [weak self] active in self?.isDropTarget = active }

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
        registerForDraggedTypes([.fileURL, .png, .tiff, SessionReferencePasteboard.type])
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

    /// The owner's controls on the box's bottom row.
    ///
    /// `leading` reads as what the message will be sent *with* — model, effort, speed — and
    /// `trailing` as what it has cost so far, beside the send. Both are the owner's own views:
    /// this component owns the row's geometry and knows nothing about what a provider offers.
    ///
    /// A hidden control is detached rather than left as a gap, so a provider offering no
    /// choices at all leaves the row to the send glyph rather than to a row of holes.
    ///
    /// Calling this is what gives a box its row, whatever `submitPlacement` says: the brief
    /// keeps its controls where the reply has them while its send stays outside the box.
    func setFooterControls(leading: [NSView], trailing: [NSView]) {
        hasFooterControls = !leading.isEmpty || !trailing.isEmpty

        for view in footerRow.arrangedSubviews
        where view !== footerSpacer && view !== submitButton && view !== scheduleChevron {
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

        // The row may have just appeared under a box that has no send in it, which also changes
        // how that box is padded.
        applySubmitPlacement()
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

    /// Stages one provider-neutral reference or comment. A repeated id updates its receipt in
    /// place, which is how a new immutable annotation revision replaces the old draft revision
    /// without adding a second comment pill.
    func addContextAttachment(_ attachment: ConversationContextAttachment) {
        if let index = contextAttachments.firstIndex(where: { $0.id == attachment.id }) {
            guard contextAttachments[index] != attachment else { return }
            contextAttachments[index] = attachment
        } else {
            contextAttachments.append(attachment)
        }
        contextAttachments = ConversationContextPolicy.normalized(contextAttachments)
        contextRail.setAttachments(contextAttachments)
        updateSubmitState()
        updateHeight()
        onContextAttachmentsChange?(contextAttachments)
        focus()
    }

    /// Restores a saved structured draft without pretending each item was newly staged.
    func setContextAttachments(_ attachments: [ConversationContextAttachment]) {
        contextAttachments = ConversationContextPolicy.normalized(attachments)
        contextRail.setAttachments(contextAttachments)
        updateSubmitState()
        updateHeight()
    }

    func clearContextAttachments() {
        guard !contextAttachments.isEmpty else { return }
        contextAttachments.removeAll()
        contextRail.setAttachments([])
        updateSubmitState()
        updateHeight()
        onContextAttachmentsChange?(contextAttachments)
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

    // MARK: - Command, Skill and Workspace Completion

    private func updateCompletions() {
        guard textView.selectedRange().length == 0 else {
            dismissCompletions()
            return
        }

        let caret = textView.selectedRange().location
        if let query = ComposerCompletionQuery.parse(
            textView.string,
            caretUTF16Offset: caret
        ) {
            updateCapabilityCompletions(query)
            return
        }

        if let query = WorkspaceFileMentionQuery.parse(
            text: textView.string,
            caretUTF16Offset: caret
        ), let workspaceFileSearch {
            updateWorkspaceFileCompletions(query, search: workspaceFileSearch)
            return
        }

        dismissCompletions()
    }

    private func updateCapabilityCompletions(_ query: ComposerCompletionQuery) {
        workspaceSearchGeneration += 1

        let previousSelectionID = completionItems.indices.contains(selectedCompletionIndex)
            ? completionItems[selectedCompletionIndex].id
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
        workspaceFileQuery = nil
        completionActions = suggestions.map(CompletionAction.capability)
        completionItems = suggestions.map(PromptCompletionItem.init(capability:))
        if let previousSelectionID,
           let matchingIndex = completionItems.firstIndex(where: {
               $0.id == previousSelectionID && $0.isEnabled
           }) {
            selectedCompletionIndex = matchingIndex
        } else {
            selectedCompletionIndex = firstEnabledCompletionIndex(in: suggestions) ?? 0
        }

        completionPresenter.present(
            items: completionItems,
            selectedIndex: selectedCompletionIndex,
            from: self,
            onChoose: { [weak self] index in self?.acceptCompletion(at: index) },
            onDismiss: { [weak self] in self?.clearCompletionState() }
        )
    }

    private func updateWorkspaceFileCompletions(
        _ query: WorkspaceFileMentionQuery,
        search: @escaping @MainActor @Sendable (
            String,
            @escaping @MainActor @Sendable (
                Result<[WorkspaceFileReference], WorkspaceFileSearchFailure>
            ) -> Void
        ) -> Void
    ) {
        completionQuery = nil
        workspaceFileQuery = query
        workspaceSearchGeneration += 1
        let generation = workspaceSearchGeneration
        search(query.term) { @MainActor @Sendable [weak self] result in
            guard let self, generation == self.workspaceSearchGeneration,
                  self.workspaceFileQuery == query else { return }
            guard case .success(let references) = result, !references.isEmpty else {
                self.dismissCompletions()
                return
            }
            self.completionActions = references.map(CompletionAction.workspaceFile)
            self.completionItems = references.map { reference in
                PromptCompletionItem(
                    id: reference.path,
                    title: "@" + reference.path,
                    detail: L10n.string("Workspace file reference — contents are not pasted"),
                    kind: L10n.string("File"),
                    isEnabled: true
                )
            }
            self.selectedCompletionIndex = 0
            self.completionPresenter.present(
                items: self.completionItems,
                selectedIndex: 0,
                from: self,
                onChoose: { [weak self] index in self?.acceptCompletion(at: index) },
                onDismiss: { [weak self] in self?.clearCompletionState() }
            )
        }
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        // Esc stops the agent, but only once it has nothing nearer to dismiss. An open
        // completion list owns it first, which is why this is decided here rather than in
        // `keyDown`: the list is the thing the key was most recently made to mean.
        guard completionPresenter.isVisible, !completionItems.isEmpty else {
            switch event.keyCode {
            case PromptViewDefaults.escapeKeyCode where composerMode.canStop:
                onStop?()
                return true
            case PromptViewDefaults.upArrowKeyCode where textView.string.isEmpty:
                return onRecallPrevious?() ?? false
            default:
                return false
            }
        }

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
        guard !completionItems.isEmpty else { return }
        var candidate = selectedCompletionIndex
        for _ in completionItems.indices {
            candidate = (candidate + offset + completionItems.count)
                % completionItems.count
            if completionItems[candidate].isEnabled {
                selectedCompletionIndex = candidate
                completionPresenter.select(candidate)
                return
            }
        }
    }

    private func acceptCompletion(at index: Int) {
        guard completionItems.indices.contains(index),
              completionActions.indices.contains(index),
              completionItems[index].isEnabled else { return }
        switch completionActions[index] {
        case .capability(let capability):
            guard let completionQuery else { return }
            textView.insertText(
                capability.invocationText + " ",
                replacementRange: completionQuery.replacementRange
            )
        case .workspaceFile(let reference):
            guard let workspaceFileQuery else { return }
            textView.insertText(
                "@" + reference.path + " ",
                replacementRange: workspaceFileQuery.replacementRange
            )
            addContextAttachment(ConversationContextAttachment(
                kind: .reference,
                source: .workspaceFile,
                title: (reference.path as NSString).lastPathComponent,
                locator: reference.path
            ))
        }
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
        workspaceSearchGeneration += 1
        completionQuery = nil
        workspaceFileQuery = nil
        completionItems = []
        completionActions = []
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
        let canRead = canAcceptDrop(sender.draggingPasteboard)
        isDropTarget = canRead
        return canRead ? .copy : []
    }

    /// Files always; a dragged sidebar session only when an owner is there to brief it.
    private func canAcceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        if PromptAttachment.canRead(pasteboard) { return true }
        return onSessionReferenceDrop != nil && SessionReferencePasteboard.canRead(pasteboard)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    /// `draggingExited` is only the pointer leaving; a drag released over the box, or cancelled
    /// with it still inside, ends without ever exiting. Without this the accent well outlives
    /// the gesture it was describing — the one state a drop affordance may never hold.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptDrop(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        if let onSessionReferenceDrop {
            let sessions = SessionReferencePasteboard.sessionIDs(from: sender.draggingPasteboard)
            if !sessions.isEmpty {
                onSessionReferenceDrop(sessions)
                return true
            }
        }
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
        submit(intent: .standard)
    }

    /// What the glyph does, which is not always send.
    ///
    /// One control rather than two, because a send and a stop are never both meaningful and a
    /// second button is a second thing to aim at. The glyph is already reparented between
    /// placements, so it has the seam for this.
    @objc private func primaryAction() {
        if composerMode.canStop {
            onStop?()
            return
        }
        submit(intent: .standard)
    }

    private func submit(intent: PromptSubmitIntent) {
        guard isSubmissionEnabled else { return }

        // ⌘Return joins the running turn where the transport allows it. Everywhere else it is an
        // ordinary send — which, while a turn is in flight, the owner reads as "queue this".
        if intent == .immediate, composerMode.canSteer, onSteer != nil {
            let value = submissionValue
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !contextAttachments.isEmpty else { return }
            onSteer?(value)
            return
        }

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
            guard let image = BoundedImageDecoder.image(
                at: URL(fileURLWithPath: path),
                policy: .composerPreview
            ), image.isValid else {
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

    @discardableResult
    func removeContextAttachment(id: UUID) -> Bool {
        guard contextAttachments.contains(where: { $0.id == id }) else { return false }
        contextAttachments.removeAll { $0.id == id }
        contextRail.setAttachments(contextAttachments)
        updateSubmitState()
        updateHeight()
        onContextAttachmentsChange?(contextAttachments)
        focus()
        return true
    }

    private static func quotedPath(_ path: String) -> String {
        PromptAttachment.quotedPath(path)
    }

    private func appending(paths: [String], to text: String) -> String {
        PromptAttachment.appending(paths: paths, to: text)
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
    ///
    /// While a turn is running and the transport can stop it, the same control is a Stop and its
    /// rules invert: it is live whether or not anything is typed, because what it acts on is the
    /// agent rather than the box, and it is always tinted — a Stop the eye has to hunt for is a
    /// Stop nobody finds when they need it.
    private func updateSubmitState() {
        let hasContent = hasSubmittableContent
        let isStop = composerMode.canStop
        let canSubmit = isSubmissionAvailable

        submitButton.image = NSImage(
            systemSymbolName: isStop ? DesignSymbols.stop : DesignSymbols.submit,
            accessibilityDescription: isStop
                ? L10n.string("Stop")
                : L10n.string("Start session")
        )
        submitButton.isEnabled = isStop || canSubmit
        submitButton.contentTintColor = isStop || canSubmit
            ? Design.Surface.accent
            : Design.Text.tertiary
        refreshSubmitTitle()
        updateScheduleChevron(hasContent: hasContent, isStop: isStop)
        onSubmissionAvailabilityChange?(canSubmit)
    }

    /// Shows the chevron only where scheduling is both offered and meaningful.
    ///
    /// Three conditions, and each is a different sentence: there has to be somewhere for a
    /// scheduled message to go (`scheduleMenuProvider`), something to schedule (`hasContent`),
    /// and a send to hang it off — never a Stop.
    private func updateScheduleChevron(hasContent: Bool, isStop: Bool) {
        let offered = scheduleMenuProvider != nil && !isStop && submitPlacement != .outside

        guard offered else {
            if scheduleChevron.superview != nil {
                NSLayoutConstraint.deactivate(scheduleInlineConstraints)
                if footerRow.arrangedSubviews.contains(scheduleChevron) {
                    footerRow.removeArrangedSubview(scheduleChevron)
                }
                scheduleChevron.removeFromSuperview()
                contentTrailingBesideChevron?.isActive = false
                contentTrailingBesideSubmit?.isActive = submitPlacement == .inside
            }
            return
        }

        if submitPlacement == .footer {
            NSLayoutConstraint.deactivate(scheduleInlineConstraints)
            contentTrailingBesideChevron?.isActive = false
            contentTrailingBesideSubmit?.isActive = false
            if scheduleChevron.superview !== footerRow {
                scheduleChevron.removeFromSuperview()
                let submitIndex = footerRow.arrangedSubviews.firstIndex(of: submitButton)
                    ?? footerRow.arrangedSubviews.count
                footerRow.insertArrangedSubview(scheduleChevron, at: submitIndex)
            }
        } else if scheduleChevron.superview !== self {
            if footerRow.arrangedSubviews.contains(scheduleChevron) {
                footerRow.removeArrangedSubview(scheduleChevron)
            }
            scheduleChevron.removeFromSuperview()
            addSubview(scheduleChevron)
            if scheduleInlineConstraints.isEmpty {
                let trailing = contentStack.trailingAnchor.constraint(
                    equalTo: scheduleChevron.leadingAnchor,
                    constant: -Design.Spacing.inset
                )
                contentTrailingBesideChevron = trailing
                scheduleInlineConstraints = [
                    scheduleChevron.trailingAnchor.constraint(
                    equalTo: submitButton.leadingAnchor,
                    constant: -Design.Spacing.tight
                ),
                    scheduleChevron.centerYAnchor.constraint(equalTo: submitButton.centerYAnchor)
                ]
            }
            NSLayoutConstraint.activate(scheduleInlineConstraints)
            // The text has to clear the chevron as well as the send, or a long line runs
            // underneath it. Swapped rather than added, since only one trailing edge may hold.
            contentTrailingBesideSubmit?.isActive = false
            contentTrailingBesideChevron?.isActive = true
        }

        scheduleChevron.isEnabled = hasContent && isSubmissionEnabled
    }

    private var hasSubmittableContent: Bool {
        !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || !contextAttachments.isEmpty
    }

    private func presentScheduleMenu() {
        guard let entries = scheduleMenuProvider?(), !entries.isEmpty else { return }
        ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 0),
            from: scheduleChevron,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: {}
        )
    }

    /// The glyph names **the key that sends it**, which is the setting's answer for this box and
    /// not a constant.
    ///
    /// A tooltip is the only name a glyph has, so it is also the accessible one — and a send
    /// that fires on a key its own label does not name is the defect this exists to prevent. It
    /// shipped in the opposite direction: a composer sending on Return while its glyph promised
    /// ⌘Return. Recomputed here rather than stored because `AppSettings.promptReturnKey` is read
    /// at the keystroke, and this is called on every edit, every enable change and every
    /// placement change — so the words follow the setting without observing it.
    private func refreshSubmitTitle() {
        submitButton.toolTip = submissionDisabledReason ?? submitTitle
    }

    /// The glyph's own name, which changes with what it will do.
    ///
    /// Every reading names its chord, because a glyph has no face to write one on. The queueing
    /// reading matters most: a Return that adds to a list instead of sending is a different
    /// promise, and leaving it saying "Send" is how somebody comes to believe a queued message
    /// was handed over.
    private var submitTitle: String {
        if composerMode.canStop { return PromptViewDefaults.stopTitle }

        let returnKey = submitsOnReturn()
            ? PromptViewDefaults.returnSubmitTitle
            : PromptViewDefaults.submitTitle

        guard composerMode.isWorking else { return returnKey }

        return composerMode.canSteer
            ? PromptViewDefaults.queueWithSteerTitle
            : PromptViewDefaults.queueTitle
    }

    private func updateSurface() {
        // The prompt is where text is typed, so under a bevel material it reads sunken — a
        // carved well, like every text field.
        //
        // While a drag it can take is over it, the well tints with the drop wash and takes the
        // accent ring at focus width: the ring is the focus ring's own geometry saying "aiming
        // at", and the tinted fill is what tells the two states apart. Quiet on purpose — the
        // travelling thumbnail already says a drop is happening, the surface only answers
        // *here* — and a wash rather than a plate, because a draft may be under it.
        let isEmphasized = isTextFocused || isDropTarget
        applySurface(
            fill: isDropTarget ? Design.Surface.fieldDropTarget : Design.Surface.field,
            radius: .panel,
            border: isEmphasized ? Design.Surface.accent : Design.Surface.border,
            borderWidth: isEmphasized
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
        //
        // What that left behind was a floor *below a single line*: 44 − 36 = 8, so the resting
        // height of a box with a control row was decided entirely by how tall one line of body
        // text happens to be, and nothing stated how much room a reply is worth. `restingLines`
        // states it. The row still comes out of the total — the arithmetic is unchanged — it is
        // the minimum the row is subtracted from that now knows there is a row.
        let textFloor = max(0, restingHeight - footerHeight)
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

        // Growth is a preference; the resting size is the promise. AppKit derives a window's
        // minimum content size from the constraints at `windowSizeStayPut` (500) and above, so a
        // box held at its cap by a long draft sits below that line and a box at rest does not —
        // otherwise typing is what decides how short a window may be dragged. The composer is
        // where this shows: chips, box and an action row asked for 316 points inside a window
        // the app lets the user drag to `WindowDefaults.minHeight`, and the window stopped 16
        // points above its own floor as soon as there was a draft in the box.
        let priority: NSLayoutConstraint.Priority = fitted > restingHeight
            ? PromptViewDefaults.grownHeightPriority
            : .defaultHigh
        if heightConstraint?.priority != priority {
            heightConstraint?.priority = priority
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
    var onSubmit: ((PromptSubmitIntent) -> Void)?

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

    /// Lets the owning surface light as one drop target while a drag the composer can take is
    /// over the editor — the same reason as `onFocusChange`: AppKit routes the drag to the
    /// deepest registered view, so over the text this view is the destination and the box
    /// around it would otherwise never hear about the pointer it is supposed to answer.
    var onDropTargetChange: ((Bool) -> Void)?

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
            onSubmit?(.immediate)
            return
        }

        let wantsNewline = !submitsOnReturn()
            || modifiers.contains(.shift)
            || modifiers.contains(.option)

        if wantsNewline {
            super.keyDown(with: event)
            return
        }

        onSubmit?(.standard)
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

    /// Reported by what the composer would *take*, not by what the editor would accept:
    /// `super` answers yes to a plain-text drag too, and a box that lights its attachment
    /// affordance for text it will simply insert is promising the wrong thing.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropTargetChange?(PromptAttachment.canRead(sender.draggingPasteboard))
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChange?(false)
        super.draggingExited(sender)
    }

    /// A drop or a cancel ends the drag without exiting — see `PromptView.draggingEnded`.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargetChange?(false)
        super.draggingEnded(sender)
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

    /// Custody and spelling live in `ComposerAttachmentHandover`, which the paired phone's
    /// composer also submits through. What stays here is the half that needs a pasteboard.
    @MainActor
    @discardableResult
    static func record(
        paths: [String],
        sessionID: SessionID,
        projectRoot: URL
    ) -> [SessionAttachment] {
        ComposerAttachmentHandover.record(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot
        )
    }

    @MainActor
    static func handOver(paths: [String], sessionID: SessionID, projectRoot: URL) -> [String] {
        ComposerAttachmentHandover.handOver(
            paths: paths,
            sessionID: sessionID,
            projectRoot: projectRoot
        )
    }

    static func appending(paths: [String], to text: String) -> String {
        ComposerAttachmentHandover.appending(paths: paths, to: text)
    }

    static func quotedPath(_ path: String) -> String {
        ComposerAttachmentHandover.quotedPath(path)
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
                "Failed to write dropped image: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }
}

// MARK: - Composer Mode

/// What the composer's controls mean right now.
///
/// Deliberately two cases and not three booleans. The owner resolves the transport's capabilities
/// into this before handing it over, so `PromptView` never asks who the provider is — the whole
/// reason a fourth runtime can be added without touching the box.
enum PromptComposerMode: Equatable {
    /// Nothing is running. The glyph sends and Return hands the turn over.
    case ready

    /// A turn is in flight.
    ///
    /// - `canStop`: the glyph becomes a Stop. False where the transport cannot interrupt, in
    ///   which case the glyph stays a send and the message queues — a Stop that does nothing is
    ///   worse than no Stop.
    /// - `canSteer`: ⌘Return adds the message to the running turn instead of queueing it. False
    ///   where the transport has no steering primitive, and then the chord is simply an ordinary
    ///   send, which queues. Nothing here promises what the wire cannot do.
    case working(canStop: Bool, canSteer: Bool)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var canStop: Bool {
        if case .working(let canStop, _) = self { return canStop }
        return false
    }

    var canSteer: Bool {
        if case .working(_, let canSteer) = self { return canSteer }
        return false
    }
}

/// Which of a composer's two affirmatives was asked for.
///
/// ⌘Return has one meaning across this app: **the more committed of two**. `ContextCommentAlert`
/// established it — Return parks the comment beside the prompt, ⌘Return hands it over now — and
/// the composer reuses it rather than inventing a second idea for the same chord.
enum PromptSubmitIntent: Equatable {
    /// A bare Return, or the send glyph.
    case standard

    /// ⌘Return.
    case immediate
}

// MARK: - Prompt View Defaults

enum PromptViewDefaults {
    static let submitSize = Design.Size.compactSubmitHeight

    /// Below every control the footer row can hold, so the empty middle between the two runs is
    /// what stretches when there is room and what disappears when there is not. Any real
    /// priority leaves the row's own members bidding against a gap for their width — see
    /// `setupFooterRow`.
    static let spacerPriority = NSLayoutConstraint.Priority(1)

    /// The chevron beside the send. Deliberately narrower than the glyph it sits next to: the
    /// press is the point of the pair and the chevron is the day the answer is different, which
    /// is the same ranking `SplitIconButtonView` draws with `Design.Size.splitMenuWidth`.
    static let scheduleChevronWidth = Design.Size.compactSplitMenuWidth

    static let scheduleChevronSymbol = "chevron.down"

    /// What the send glyph says when it is asked, and the only name it has.
    ///
    /// A glyph has no face to write a chord on — which is the one thing a titled button beside
    /// the box can do — so the tooltip carries the chord instead. It doubles as the control's
    /// accessible name: `ThemedButton` reads the tooltip for a button with no title, and an
    /// unnamed send is unusable from VoiceOver.
    ///
    /// Two of them, because the key that sends is the box's own answer: naming the chord in a
    /// box where a bare Return also sends is how a composer came to send on a key nothing in
    /// front of the user mentioned. See `PromptView.refreshSubmitTitle`.
    static var submitTitle: String { L10n.string("Send · ⌘Return") }

    static var returnSubmitTitle: String { L10n.string("Send · Return") }

    /// What the same glyph says once it is a Stop. The chord matches both CLIs.
    static var stopTitle: String { L10n.string("Stop · Esc") }

    /// While a turn is running on a transport that cannot take additions.
    static var queueTitle: String { L10n.string("Add to queue · Return") }

    /// While a turn is running on one that can. Both chords, because a pair nobody can see is a
    /// pair nobody finds — the same rule `ThemedAlert.resolvedChords` follows.
    static var queueWithSteerTitle: String {
        L10n.string("Add to queue · Return   Send to this turn · ⌘Return")
    }

    /// How many lines of prose a box with a control row stands open at.
    ///
    /// Two, not one. A box that opens at a single line reads as a search field — it says a
    /// sentence is expected, in the place people write paragraphs — and the resting height was
    /// not chosen at all before this: it fell out of `Design.Size.inputHeight` minus the row,
    /// leaving a text floor of eight points, below one line.
    ///
    /// Two rather than three, deliberately. Three is where this stops being a taller box and
    /// starts being the hundred-point one the control row was moved *out of* the minimum to
    /// avoid — the note on `updateHeight` records that regression. Two adds exactly one line.
    ///
    /// It is only a resting size: `Design.Size.inputMaxHeight` is still the ceiling and the box
    /// grows between them, so nothing here costs anyone room to read the conversation.
    static let restingLines: CGFloat = 2

    /// Keeps a one-line prompt vertically centred in `Design.Size.inputHeight`.
    static let verticalInset: CGFloat = 13
    static let submitBottomInset: CGFloat = 13

    /// The padding a box with a control row uses instead.
    ///
    /// 13 exists to centre one line in a 44pt box and means nothing once there is a second row
    /// under that line: kept, it padded the text by a line's worth of air at the top and left
    /// the row crowding the bottom edge. A panel's own step reads as one box holding two rows.
    static let footerVerticalInset: CGFloat = Design.Spacing.medium

    /// What the box's height asks for once its content has grown it past `minimumHeight`.
    ///
    /// Under `NSLayoutConstraint.Priority.windowSizeStayPut` (500), which is the line AppKit
    /// derives a window's minimum content size from: above it a height is part of what the
    /// window must be able to show, below it a preference the window may leave unmet. Growth
    /// belongs on the second side of that line — see `updateHeight`.
    static let grownHeightPriority = NSLayoutConstraint.Priority(490)

    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53
    static let upArrowKeyCode: UInt16 = 126
    static let downArrowKeyCode: UInt16 = 125

    /// Shared with every other composer through `ComposerAttachmentDefaults` — the phone's
    /// uploads are written under the same prefix, so one rule decides what counts as a file the
    /// app generated rather than one the person already had a name for.
    static let attachmentPrefix = ComposerAttachmentDefaults.generatedPrefix
    static let attachmentExtension = ComposerAttachmentDefaults.generatedImageExtension
}
