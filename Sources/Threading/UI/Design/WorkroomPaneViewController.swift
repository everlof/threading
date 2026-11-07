import AppKit

// MARK: - Presentation

/// What the Workroom pane shows for one chat, already in words.
///
/// Built by `WorkroomPaneFeed` off the main actor from bounded reads, so the pane never sizes
/// itself from the store: the rooms and questions arrive capped, and an equal value is not drawn
/// again.
struct WorkroomPanePresentation: Equatable {
    enum Notice: Equatable {
        /// The first read has not come back. Nothing is drawn: it takes a frame or two, and a
        /// placeholder that flashes and goes says less than an empty pane.
        case loading
        /// Settings ▸ Workrooms is off.
        case off
        /// The chat runs on another Mac, whose store holds its rooms.
        case elsewhere
        case failure(String)
    }

    struct Room: Equatable {
        let id: String
        let title: String
        let status: String
        let canClose: Bool
        let people: [Person]
    }

    struct Person: Equatable {
        let id: String
        let name: String
        let status: String
        /// False for the owner, whose own paired iPhone already shows every question.
        let canInvite: Bool
    }

    struct Question: Equatable {
        let id: String
        let title: String
        let status: String
    }

    struct Detail: Equatable {
        let id: String
        let title: String
        let status: String
        let prompt: String
        let entries: [Entry]
        /// Who reads a comment, for the line under the composer; nil when the question no longer
        /// takes one.
        let commentReaders: String?
        var failure: String?
    }

    /// One step of a question's conversation: who and when, what they chose, what they wrote.
    struct Entry: Equatable {
        let id: String
        let heading: String
        let lines: [String]
        let text: String
        /// The agent's and the owner's words are Markdown; the person's are shown as typed.
        var isMarkdown = false
    }

    var chatTitle = ""
    var notice: Notice?
    var rooms: [Room] = []
    var questions: [Question] = []
    var moreQuestions = false
    var detail: Detail?
}

/// What the owner asked the pane for. The feed performs it; the pane only reports it.
enum WorkroomPaneAction: Equatable {
    case openQuestion(String)
    case showQuestions
    case closeRoom(String)
    case inviteToApp(person: String)
    case comment(question: String, text: String)
    case openSettings
}

// MARK: - Workroom Pane

/// One chat's Linked Workrooms, beside the chat: the rooms it works in and who is in them, the
/// questions it asked, and one question's conversation with a place for the owner to comment.
///
/// Settings ▸ Workrooms answers what this Mac publishes and to whom. Nothing answered what *this*
/// chat is waiting for, from whom, and whether that person can even see the question — which is
/// the thing the owner wants while working in the chat. So the room's people carry their app
/// status and the invitation beside it, and the questions open into their conversation in place.
///
/// A presentation in, actions out: the pane reads nothing. A rebuild is bounded by the capped
/// presentation and happens only when the value changed, so a refresh that found nothing new
/// keeps the scroll position, the hover and a comment half written.
@MainActor
final class WorkroomPaneViewController: NSViewController {

    // MARK: - Properties

    var onAction: ((WorkroomPaneAction) -> Void)?

    /// Asked to read again: the pane came on screen, so what it shows may be old.
    var onRefresh: (() -> Void)?

    /// Draws agent-written Markdown — the question and the agent's messages — the way the chat
    /// draws a reply. Supplied by the owner, so this component does not depend on the chat's
    /// renderer; without it the text is shown as written.
    var makeMarkdownView: ((String) -> NSView)?

    private(set) var presentation = WorkroomPanePresentation(notice: .loading)
    private var hasRendered = false
    private var buttonActions: [ObjectIdentifier: WorkroomPaneAction] = [:]

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Workroom"))
        label.applyFont(.emphasizedBody)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var settingsButton: ThemedButton = {
        let button = ThemedButton(title: L10n.string("Settings…"), target: self, action: #selector(buttonPressed(_:)))
        button.emphasis = .tertiary
        button.toolTip = L10n.string("People, links and the public address, in Settings ▸ Workrooms")
        button.setAccessibilityIdentifier(WorkroomPaneIdentifiers.settings)
        return button
    }()

    private let list = PanelListView(rowSpacing: Design.Spacing.small)

    /// One composer for the pane's life, so a refresh that rebuilds the conversation keeps what is
    /// being written. Cleared only when the feed says the comment was stored.
    private lazy var composer: PromptView = {
        let prompt = PromptView()
        prompt.placeholder = L10n.string("Write a comment")
        prompt.textAccessibilityLabel = L10n.string("Comment")
        prompt.minimumHeight = WorkroomPaneDefaults.composerHeight
        prompt.setAccessibilityIdentifier(WorkroomPaneIdentifiers.composer)
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.onSubmit = { [weak self] text in self?.submitComment(text) }
        return prompt
    }()

    private var composerQuestionID: String?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier(WorkroomPaneIdentifiers.pane)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        [titleLabel, subtitleLabel, settingsButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        list.setAccessibilityIdentifier(WorkroomPaneIdentifiers.list)
        view.addSubview(list)
        setupConstraints()
        render()
    }

    // MARK: - Public Methods

    /// Shows a new reading. The same reading again changes nothing on screen.
    func apply(_ presentation: WorkroomPanePresentation) {
        guard presentation != self.presentation || !hasRendered else { return }
        let page = self.presentation.detail?.id
        self.presentation = presentation
        render()
        if page != presentation.detail?.id { list.scrollToTop() }
    }

    /// The pane is on screen; its owner reads again.
    func refresh() {
        onRefresh?()
    }

    /// The feed stored the comment: the composer empties and takes the next one.
    func commentDidSend() {
        composer.stringValue = ""
        composer.isSubmissionEnabled = true
    }

    /// The feed could not store the comment; what was written stays to be sent again.
    func commentDidFail() {
        composer.isSubmissionEnabled = true
    }

    /// The arranged rows, for tests that assert what a reading produced.
    var rows: [NSView] { list.rows }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        hasRendered = true
        subtitleLabel.stringValue = presentation.chatTitle
        let composing = composer.window?.firstResponder.map { responder in
            (responder as? NSView)?.isDescendant(of: composer) ?? false
        } ?? false
        list.clear()
        buttonActions = [ObjectIdentifier(settingsButton): .openSettings]
        if let notice = presentation.notice {
            addNotice(notice)
        } else if let detail = presentation.detail {
            addDetail(detail)
            if composing, composer.superview != nil { composer.focusAtEnd() }
        } else {
            addOverview()
        }
    }

    private func addNotice(_ notice: WorkroomPanePresentation.Notice) {
        switch notice {
        case .loading:
            return
        case .off:
            list.addNote(L10n.string(
                "Workrooms is off, so this chat cannot ask people outside this Mac. Turn it on in Settings ▸ Workrooms."
            ))
        case .elsewhere:
            list.addNote(L10n.string("This chat runs on another Mac. Its workrooms are on that Mac."))
        case .failure(let message):
            list.addSection(L10n.string("Workrooms cannot be read"))
            list.addNote(message)
        }
    }

    private func addOverview() {
        if presentation.rooms.isEmpty, presentation.questions.isEmpty {
            list.addNote(L10n.string(
                "This chat has no workroom yet. Ask the agent to create one, for example “Make a workroom and ask our accountant how VAT is rounded.” Nobody outside this Mac sees anything until you approve opening it."
            ))
            return
        }
        if !presentation.rooms.isEmpty {
            list.addSection(L10n.string("Rooms"))
            for room in presentation.rooms {
                var actions: [(String, String, WorkroomPaneAction)] = []
                if room.canClose {
                    actions.append((L10n.string("Close"), L10n.format("Close “%@” to everyone", room.title),
                                    .closeRoom(room.id)))
                }
                list.addRow(itemRow(symbol: WorkroomPaneSymbols.room, title: room.title, detail: room.status,
                                    indent: 0, actions: actions))
                for person in room.people {
                    let invite = (L10n.string("Invite to App…"), L10n.format("Invite %@ to the Threading app", person.name),
                                  WorkroomPaneAction.inviteToApp(person: person.id))
                    list.addRow(itemRow(symbol: WorkroomPaneSymbols.person, title: person.name, detail: person.status,
                                        indent: WorkroomPaneDefaults.textColumn,
                                        actions: person.canInvite ? [invite] : []))
                }
            }
        }
        list.addSection(L10n.string("Questions from this chat"))
        guard !presentation.questions.isEmpty else {
            list.addNote(L10n.string("This chat has not asked anything yet."))
            return
        }
        for question in presentation.questions {
            // Titles start on the rooms' title column, so the pane reads as one column of names.
            let row = SearchResultRowView(title: question.title, path: question.status, matching: "",
                                          leadingInset: WorkroomPaneDefaults.textColumn, inkSource: .chrome)
            row.onSelect = { [weak self] in self?.onAction?(.openQuestion(question.id)) }
            row.setAccessibilityIdentifier(WorkroomPaneIdentifiers.question)
            list.addRow(row)
        }
        if presentation.moreQuestions {
            list.addFootnote(L10n.format("The newest %d questions", presentation.questions.count))
        }
    }

    private func addDetail(_ detail: WorkroomPanePresentation.Detail) {
        let back = ThemedButton(symbol: WorkroomPaneSymbols.back, accessibility: L10n.string("All Questions"),
                                target: self, action: #selector(buttonPressed(_:)))
        back.title = L10n.string("All Questions")
        back.emphasis = .tertiary
        back.setAccessibilityIdentifier(WorkroomPaneIdentifiers.back)
        buttonActions[ObjectIdentifier(back)] = .showQuestions
        list.addRow(leading(back))

        let title = wrapping(detail.title, role: .heading, color: Design.Text.label)
        title.isSelectable = true
        list.addRow(title)
        list.addRow(wrapping(detail.status, role: .caption, color: Design.Text.tertiary))
        if !detail.prompt.isEmpty {
            list.addRow(markdown(detail.prompt) ?? selectableWrapping(detail.prompt, color: Design.Text.secondary))
        }

        list.addSection(L10n.string("Conversation"))
        if detail.entries.isEmpty { list.addNote(L10n.string("No answer yet.")) }
        for entry in detail.entries {
            list.addRow(wrapping(entry.heading, role: .detail(), color: Design.Text.tertiary))
            for line in entry.lines {
                let shown = wrapping(line, role: .subheading, color: Design.Text.label)
                shown.isSelectable = true
                list.addRow(shown)
            }
            if !entry.text.isEmpty {
                let drawn = entry.isMarkdown ? markdown(entry.text) : nil
                list.addRow(drawn ?? selectableWrapping(entry.text, color: Design.Text.label))
            }
        }

        guard let readers = detail.commentReaders else { return }
        list.addSection(L10n.string("Comment"))
        if composerQuestionID != detail.id {
            composerQuestionID = detail.id
            composer.stringValue = ""
            composer.isSubmissionEnabled = true
        }
        list.addRow(composer)
        list.addFootnote(detail.failure ?? readers)
    }

    // MARK: - Rows

    /// A glyph, a name over one line of state, and the row's own verbs at the end. The words give
    /// way to the buttons: they truncate rather than push the verbs out of the pane.
    private func itemRow(symbol: String, title: String, detail: String, indent: CGFloat,
                         actions: [(title: String, accessibility: String, action: WorkroomPaneAction)]) -> NSView {
        let glyph = GlyphView()
        glyph.setSymbol(symbol, slot: WorkroomPaneDefaults.glyphSlot)
        glyph.tint = Design.Text.tertiary
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.applyFont(.subheading)
        name.textColor = Design.Text.label
        let state = NSTextField(labelWithString: detail)
        state.applyFont(.caption)
        state.textColor = Design.Text.tertiary
        for label in [name, state] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(Design.Priority.belowFittingSize, for: .horizontal)
        }
        let words = NSStackView(views: [name, state])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = Design.Spacing.hairline
        // The words take the row's slack, which is what puts the verbs at the trailing edge
        // however short the name before them.
        words.setHuggingPriority(.defaultLow, for: .horizontal)

        let buttons: [NSView] = actions.map { action in
            let button = ThemedButton(title: action.title, target: self, action: #selector(buttonPressed(_:)))
            button.emphasis = .tertiary
            // A titled button speaks its title; the row's own label says whose it is, and the
            // help tag says the whole thing for a pointer.
            button.toolTip = action.accessibility
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttonActions[ObjectIdentifier(button)] = action.action
            return button
        }
        let row = NSStackView(views: [glyph, words] + buttons)
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: WorkroomPaneDefaults.glyphSlot),
            glyph.heightAnchor.constraint(equalToConstant: WorkroomPaneDefaults.glyphSlot)
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        return row
    }

    private func markdown(_ text: String) -> NSView? {
        guard let view = makeMarkdownView?(text) else { return nil }
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func selectableWrapping(_ text: String, color: NSColor) -> NSTextField {
        let label = wrapping(text, role: .subheading, color: color)
        label.isSelectable = true
        return label
    }

    /// A control kept to its own width at the leading edge of a full-width list row.
    private func leading(_ control: NSView) -> NSView {
        let row = NSStackView(views: [control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Wraps at the pane's width, and never sets that width: its fitting size is the list's.
    private func wrapping(_ text: String, role: Design.FontRole, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(role)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(Design.Priority.belowFittingSize, for: .horizontal)
        return label
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset
        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top slides the header
            // underneath it.
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Design.Spacing.small),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor,
                                                 constant: -Design.Spacing.tight),
            settingsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Design.Spacing.hairline),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -inset),
            list.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: Design.Spacing.small),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func buttonPressed(_ sender: ThemedButton) {
        guard let action = buttonActions[ObjectIdentifier(sender)] else { return }
        onAction?(action)
    }

    private func submitComment(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let question = presentation.detail?.id else { return }
        composer.isSubmissionEnabled = false
        onAction?(.comment(question: question, text: trimmed))
    }
}

// MARK: - Fixed-Size Host

extension WorkroomPaneViewController {
    /// The pane held at a fixed size, for a surface that lays out by constraints instead of
    /// handing it a split item: the component gallery's story. The caller keeps this controller.
    func fixedSizeHost(_ size: NSSize) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }
}

// MARK: - Defaults

enum WorkroomPaneDefaults {
    static let glyphSlot: CGFloat = 14
    /// Where a room's title starts: its people stand on this column, and so do the questions.
    static let textColumn: CGFloat = glyphSlot + Design.Spacing.small
    static let composerHeight: CGFloat = 56
}

enum WorkroomPaneSymbols {
    /// The tab, the `+` menu and the command: a conversation with someone outside this Mac.
    static let tab = "bubble.left.and.bubble.right"
    static let room = "door.left.hand.open"
    static let person = "person"
    static let back = "chevron.left"
}

enum WorkroomPaneIdentifiers {
    static let pane = "workroom.pane"
    static let list = "workroom.pane.list"
    static let settings = "workroom.pane.settings"
    static let question = "workroom.pane.question"
    static let back = "workroom.pane.back"
    static let composer = "workroom.pane.composer"
}
