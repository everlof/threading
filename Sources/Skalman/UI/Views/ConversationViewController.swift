import AppKit

/// Renders an agent conversation natively, in place of the agent's terminal: user turns as
/// bubbles, the agent's replies as markdown, tool calls as collapsible rows, approvals as
/// inline cards. This controller drives the stream; the drawing lives in `ConversationRendering`.
final class ConversationViewController: NSViewController {

    // MARK: - Properties

    let agentSession: AgentSession
    private let project: Project

    let stream: ConversationStreamSession

    /// What the conversation *is*, derived from the stream without touching AppKit. The view
    /// tree follows the changes it reports rather than being built straight from events, so
    /// every decision about the shape of a row is testable on its own.
    var timeline: ConversationTimeline

    var scrollView: NSScrollView!
    var stack: NSStackView!

    /// Fills the scroll view so the column can be capped inside it rather than being the
    /// document itself.
    private var documentView: NSView!

    /// The turn rail in the gutter beside the column.
    private var minimap: ConversationMinimapView!
    private var minimapWidth: NSLayoutConstraint!
    private var minimapLeading: NSLayoutConstraint!
    private var promptView: PromptView!
    var statusLabel: NSTextField!

    /// The view showing the assistant's current message while its tokens arrive.
    ///
    /// Streaming text has no identity of its own: it is replaced wholesale once the finished
    /// message lands, which is the authoritative copy. The text itself lives on the timeline.
    var streamingLabel: NSTextField?

    /// Suppresses per-item scrolling while a transcript is being replayed: four hundred items
    /// each scheduling their own scroll is four hundred layout passes to reach one position.
    var isReplaying = false

    /// Views for rows that can still change, keyed by their index in `timeline.rows` — which is
    /// only tool calls, awaiting their result. Entries are dropped once resolved, so this holds
    /// the handful of calls in flight rather than the whole conversation.
    var rowViews: [Int: NSView] = [:]

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

    var sessionID: SessionID { agentSession.id }
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
        self.timeline = ConversationTimeline(sessionID: agentSession.id)

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

        // The stack is centred inside a full-width document view rather than being the
        // document view itself, so the column can be capped while the scroll view still fills
        // the pane. The space this leaves is what the turn rail lives in.
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = document
        self.documentView = document

        minimap = ConversationMinimapView()
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.onSelect = { [weak self] rowIndex in self?.scrollToRow(rowIndex) }

        promptView = PromptView()
        promptView.translatesAutoresizingMaskIntoConstraints = false
        promptView.placeholder = "Reply to \(agentSession.kind.displayName)"
        promptView.onSubmit = { [weak self] text in self?.submit(text) }

        statusLabel = NSTextField(labelWithString: "Starting…")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = Design.Typography.subheading()
        statusLabel.textColor = .tertiaryLabelColor

        view.addSubview(scrollView)
        view.addSubview(minimap)
        view.addSubview(promptView)
        view.addSubview(statusLabel)

        // The preview hangs off the pane, not off the rail: it is wider than the rail and
        // would be clipped inside it, and it has to float over the conversation.
        minimap.attachPreview(to: view)

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

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),

            // Capped, not fixed: in a pane narrower than the cap the column simply fills it,
            // which is also where `ConversationMinimap` reports no room for a rail.
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Design.Size.readableWidth),
            stack.widthAnchor.constraint(lessThanOrEqualTo: documentView.widthAnchor),

            // Anchored to the *pane*, not to the column. The column is centred, so a rail
            // hanging off its leading edge drifts inward as the window grows and strands
            // itself in the middle of an empty margin. `railLeading` keeps it by the pane's
            // edge and only pulls it back when the gutter is too tight for both.
            minimap.topAnchor.constraint(equalTo: scrollView.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        minimapLeading = minimap.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        minimapLeading.isActive = true

        // Beats the cap when the pane is wide, so the column reaches `readableWidth` rather
        // than hugging its content — but yields to it, so it never overflows a narrow pane.
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: Design.Size.readableWidth)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true

        minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
        minimapWidth.isActive = true
    }

    private func setupStream() {
        stream.onEvent = { [weak self] event in self?.handle(event) }
        stream.onExit = { [weak self] status in self?.handleExit(status) }

        // The rail brightens the turns on screen, which only means anything if it is told when
        // that changes. `postsBoundsChangedNotifications` is off by default on a clip view.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleRegionChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func visibleRegionChanged() {
        updateVisibleTurns()
    }

    // MARK: - Minimap

    override func viewDidLayout() {
        super.viewDidLayout()
        updateMinimapWidth()
        updateVisibleTurns()
    }

    /// The rail gets whatever gutter the capped column leaves, and nothing when there is none.
    private func updateMinimapWidth() {
        let width = ConversationMinimap.railWidth(
            paneWidth: view.bounds.width,
            columnWidth: Design.Size.readableWidth
        )
        let leading = ConversationMinimap.railLeading(
            paneWidth: view.bounds.width,
            columnWidth: Design.Size.readableWidth
        )

        if minimapWidth.constant != width { minimapWidth.constant = width }
        if minimapLeading.constant != leading { minimapLeading.constant = leading }
        minimap.setAvailableWidth(width, paneWidth: view.bounds.width)
    }

    /// Rebuilds the rail from the timeline. Cheap: turns are derived from rows, and a
    /// conversation is hundreds of rows.
    func refreshMinimap() {
        minimap.setTurns(timeline.turns)
        updateVisibleTurns()
    }

    /// Which turns are on screen, so the rail can say where you are as well as what is there.
    private func updateVisibleTurns() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        var indices: Set<Int> = []

        for (index, turn) in timeline.turns.enumerated() {
            guard let rowView = rowViews[turn.rowIndex] else { continue }
            let frame = rowView.convert(rowView.bounds, to: documentView)
            if frame.intersects(visibleRect) { indices.insert(index) }
        }

        minimap.setVisibleTurnIndices(indices)
    }

    /// Brings a row to the top of the pane, a little below it so it does not sit against the
    /// toolbar's edge.
    private func scrollToRow(_ index: Int) {
        guard let rowView = rowViews[index] else { return }

        let frame = rowView.convert(rowView.bounds, to: documentView)
        let target = max(0, frame.minY - Design.Spacing.large)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            self?.scrollView.reflectScrolledClipView(self?.scrollView.contentView ?? NSClipView())
            self?.updateVisibleTurns()
        }
    }

    // MARK: - Public Methods

    func launch() {
        guard !stream.isRunning else { return }

        ProjectStore.shared.update(sessionID: agentSession.id) {
            $0.hasLaunched = true
        }

        // Replay before starting, so past turns cannot interleave with new ones. The read is
        // off the main thread, and costs less than the CLI takes to boot.
        apply(.status(.loading))
        TranscriptReplay.load(for: agentSession, in: project) { [weak self] events, isTruncated in
            guard let self else { return }

            if isTruncated {
                self.appendNotice(ConversationDefaults.truncated, kind: .muted)
            }

            self.isReplaying = true
            for event in events { self.handle(event) }
            self.isReplaying = false
            self.scrollToBottom()

            self.stream.start()
            self.apply(.status(.ready(model: nil)))
        }
    }

    func terminate() {
        // Anything still waiting on the user is denied rather than left to hang on the CLI's
        // timeout: the session it belonged to is going away. The card on screen resolves
        // visibly; the queued ones behind it are answered directly, having no card yet.
        // Empty the queue first: resolving the active card normally promotes the next request,
        // which would otherwise create a new unresolved card in the middle of shutdown.
        let queuedPermissions = permissionQueue
        permissionQueue.removeAll()

        activePermissionCard?.resolve(.deny(reason: "The session ended before the request was answered."))
        activePermissionCard = nil
        for pending in queuedPermissions {
            pending.decide(.deny(reason: "The session ended before the request was answered."))
        }

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

        // Echoed locally as it is sent. The stream never reports a live user turn back —
        // `.userMessage` exists only for replay — so producing it here is what draws it once.
        apply(timeline.apply(.userMessage(trimmed)))
        apply(.status(.working))
        promptView.stringValue = ""
    }

    private func apply(_ changes: [ConversationTimeline.Change]) {
        for change in changes { apply(change) }
    }

    // MARK: - Events

    /// Folds an event into the timeline, then brings the views in line with what changed.
    ///
    /// The controller decides nothing about content here: what a row is, whether a tool result
    /// belongs to an earlier call, and when a streamed placeholder is thrown away are all
    /// `ConversationTimeline`'s, and tested there.
    private func handle(_ event: StreamEvent) {
        for change in timeline.apply(event) { apply(change) }
    }

    private func handleExit(_ status: Int32) {
        clearStreaming()
        apply(.status(.ended(code: status)))
        promptView.isHidden = true
        delegate?.conversation(self, didExitWithCode: status)
    }
}
