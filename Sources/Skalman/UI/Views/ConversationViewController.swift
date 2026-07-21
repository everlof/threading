import AppKit

/// Renders an agent conversation natively, in place of the agent's terminal: user turns as
/// bubbles, the agent's replies as markdown, tool calls as collapsible rows, approvals as
/// inline cards. This controller drives the stream; the drawing lives in `ConversationRendering`.
final class ConversationViewController: NSViewController {

    // MARK: - Properties

    let agentSession: AgentSession
    private let project: Project

    private let stream: ConversationStreamSession

    var scrollView: NSScrollView!
    var stack: NSStackView!
    private var promptView: PromptView!
    var statusLabel: NSTextField!

    /// The view showing the assistant's current message while its tokens arrive.
    ///
    /// Streaming text has no identity of its own: it is replaced wholesale once the finished
    /// message lands, which is the authoritative copy.
    var streamingLabel: NSTextField?
    var streamingText = ""

    /// Suppresses per-item scrolling while a transcript is being replayed: four hundred items
    /// each scheduling their own scroll is four hundred layout passes to reach one position.
    var isReplaying = false

    /// Tool call rows, keyed by tool-use id, so a result can be attached to the call that
    /// asked for it rather than appended as a separate item.
    private var toolViews: [String: ToolCallView] = [:]

    /// The approval card on screen, if any. Only one is shown at a time.
    var activePermissionCard: PermissionRequestView?

    /// Requests waiting their turn, shown one after another: an agent can fire several tool
    /// calls at once, but a wall of cards is answered out of context, so they queue.
    var permissionQueue: [(request: PermissionRequest, decide: (PermissionDecision) -> Void)] = []

    /// Whether anything is waiting on the user, on screen or queued behind it.
    private var hasPendingPermission: Bool {
        activePermissionCard != nil || !permissionQueue.isEmpty
    }

    weak var delegate: ConversationViewControllerDelegate?

    var sessionID: UUID { agentSession.id }
    var isRunning: Bool { stream.isRunning }

    /// Whether this session is the one on screen, tracked so it only raises the sidebar's
    /// attention dot when a request is waiting *off* screen — on screen, the card is the cue.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            delegate?.conversationDidChangeActivity(self)
        }
    }

    /// What the sidebar shows for this session.
    var activity: SessionActivity {
        if hasPendingPermission && !isVisible { return .needsAttention }
        return stream.isRunning ? .idle : .dormant
    }

    // MARK: - Initialization

    init(agentSession: AgentSession, project: Project) {
        self.agentSession = agentSession
        self.project = project

        // Rebuild the plan for every turn. Claude asks only once, while Codex asks once per
        // child process; after `thread.started`, the latest stored identifier makes the next
        // Codex plan an `exec resume` automatically.
        let plan = {
            let current = ProjectStore.shared.session(withID: agentSession.id) ?? agentSession
            return AgentLauncher.streamPlan(for: current, in: project)
        }

        switch agentSession.kind {
        case .claude:
            self.stream = ClaudeStreamSession(sessionID: agentSession.id, plan: plan)
        case .codex:
            self.stream = CodexStreamSession(sessionID: agentSession.id, plan: plan)
        case .shell:
            preconditionFailure("Shell sessions do not support native conversation rendering")
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupStream()
    }

    // MARK: - Setup

    private func setupViews() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        clip.drawsBackground = false

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = stack

        promptView = PromptView()
        promptView.translatesAutoresizingMaskIntoConstraints = false
        promptView.placeholder = "Reply to \(agentSession.kind.displayName)"
        promptView.onSubmit = { [weak self] text in self?.submit(text) }

        statusLabel = NSTextField(labelWithString: "Starting…")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Design.Typography.subheading()
        statusLabel.textColor = .tertiaryLabelColor

        view.addSubview(scrollView)
        view.addSubview(promptView)
        view.addSubview(statusLabel)

        setupConstraints()
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Pinned to the safe area, which the toolbar insets: anchoring to the view's own
            // top would slide the first message under the toolbar.
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: statusLabel.topAnchor,
                constant: -Design.Spacing.small
            ),

            statusLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            statusLabel.bottomAnchor.constraint(
                equalTo: promptView.topAnchor,
                constant: -Design.Spacing.tight
            ),

            promptView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            promptView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            promptView.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Design.Spacing.inset
            ),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func setupStream() {
        stream.onEvent = { [weak self] event in self?.handle(event) }
        stream.onExit = { [weak self] status in self?.handleExit(status) }
    }

    // MARK: - Public Methods

    func launch() {
        guard !stream.isRunning else { return }

        ProjectStore.shared.update(sessionID: agentSession.id) {
            $0.hasLaunched = true
        }

        // Replay before starting, so past turns cannot interleave with new ones. The read is
        // off the main thread, and costs less than the CLI takes to boot.
        setStatus("Loading conversation…")
        TranscriptReplay.load(for: agentSession, in: project) { [weak self] events, isTruncated in
            guard let self else { return }

            if isTruncated {
                self.appendNotice(ConversationDefaults.truncated, color: .tertiaryLabelColor)
            }

            self.isReplaying = true
            for event in events { self.handle(event) }
            self.isReplaying = false
            self.scrollToBottom()

            self.stream.start()
            self.setStatus("Ready")
        }
    }

    func terminate() {
        // Anything still waiting on the user is denied rather than left to hang on the CLI's
        // timeout: the session it belonged to is going away. The card on screen resolves
        // visibly; the queued ones behind it are answered directly, having no card yet.
        activePermissionCard?.resolve(.deny(reason: "The session ended before the request was answered."))
        activePermissionCard = nil
        for pending in permissionQueue {
            pending.decide(.deny(reason: "The session ended before the request was answered."))
        }
        permissionQueue.removeAll()

        stream.terminate()
    }

    func focusPrompt() {
        promptView.focus()
    }

    /// Sends the composer's opening message as the conversation's first turn.
    ///
    /// A streaming session takes no positional prompt argument, so what the terminal path
    /// passes on the command line is simply sent down the pipe here instead.
    func sendInitialPrompt(_ text: String) {
        submit(text)
    }

    // MARK: - Input

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, stream.send(trimmed) else { return }

        appendUserBubble(trimmed)
        promptView.stringValue = ""
        setStatus("Working…")
    }

    // MARK: - Events

    private func handle(_ event: StreamEvent) {
        switch event {
        case .initialised(let sessionID, let model):
            adoptAgentSessionID(sessionID)
            // Codex reports `thread.started` at the beginning of every one-shot turn. Its id
            // must be adopted immediately, but calling that Ready would overwrite Working
            // while the model is still running.
            if let model {
                setStatus("Ready · \(model)")
            } else if stream.canSend {
                setStatus("Ready")
            }

        case .userMessage(let text):
            appendUserBubble(text)

        case .textDelta(let text):
            appendStreaming(text)

        case .thinkingDelta:
            // Thinking is streamed but not shown yet: rendering it needs a fold, and a fold
            // needs a design. It arrives in the finished message either way.
            setStatus("Thinking…")

        case .assistantMessage(let blocks):
            clearStreaming()
            for block in blocks { render(block) }

        case .toolResults(let results):
            for result in results { render(result) }

        case .turnFinished(let text, let isError):
            finishTurn(text: text, isError: isError)

        case .other:
            break
        }
    }

    private func finishTurn(text: String?, isError: Bool) {
        clearStreaming()

        // Only a failed turn is reported: a successful one's text is the assistant message
        // already rendered, and showing it twice reads as the agent repeating itself.
        if isError, let text {
            appendNotice(text, color: .systemRed)
        }

        setStatus("Ready")
    }

    /// The CLI's own identifier wins: a resume can settle on one other than the identifier we
    /// asked for, and resuming again must use what it actually used.
    private func adoptAgentSessionID(_ sessionID: String?) {
        guard let sessionID else { return }
        ProjectStore.shared.update(sessionID: agentSession.id) {
            $0.agentSessionID = sessionID
        }
    }

    private func render(_ block: ContentBlock) {
        switch block {
        case .text(let text) where !text.isEmpty:
            appendAssistant(markdown: text)

        case .thinking(let text) where !text.isEmpty:
            appendThinking(text)

        case .toolUse(let id, let name, let input):
            // The same one-line summary the permission sheet shows, for the same reason: the
            // command or path is what identifies the call, not its argument schema.
            let request = PermissionRequest(sessionID: agentSession.id, toolName: name, input: input)

            // An edit's arguments already carry the change, so its diff is drawn from the call
            // itself — the result only confirms it went through.
            let diff = EditDiff.lines(forTool: name, input: input)
            appendToolCall(id: id, name: name, summary: request.summary, diff: diff)

        default:
            break
        }
    }

    private func render(_ result: ToolResult) {
        // Still capped: collapsed output costs no screen space but a megabyte of text in a
        // text field costs layout either way.
        let text = result.text.count > ConversationDefaults.toolResultLimit
            ? String(result.text.prefix(ConversationDefaults.toolResultLimit)) + "\n…"
            : result.text

        guard let toolView = toolViews.removeValue(forKey: result.toolUseID) else {
            // A result with no call to attach to should still be visible rather than dropped.
            guard !text.isEmpty else { return }
            appendNotice(text, color: .tertiaryLabelColor)
            return
        }

        toolView.setResult(text, isError: result.isError)
        scrollToBottom()
    }

    /// Adds a collapsed row for a tool call, to be completed when its result arrives.
    private func appendToolCall(id: String, name: String, summary: String, diff: [DiffLine]?) {
        let toolView = ToolCallView(toolName: name, summary: summary, diff: diff)
        toolViews[id] = toolView
        addRow(toolView)
    }

    private func handleExit(_ status: Int32) {
        clearStreaming()
        setStatus(status == 0 ? "Session ended" : "Session ended (exit \(status))")
        promptView.isHidden = true
        delegate?.conversation(self, didExitWithCode: status)
    }
}
