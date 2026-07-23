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

    /// The status text and, ahead of it, the working orb — shown only while a
    /// turn is in flight (`showWorkingOrb`).
    private var statusRow: NSStackView!
    let orbView = WorkingOrbView()
    var statusLabel: NSTextField!
    private let modelChip = ChipView()

    /// The Fast/Standard picker: Codex's tri-state Fast/Standard/Account-default tier and Claude's
    /// live on/off fast mode, offered on the same chip so the two providers read alike.
    private let speedChip = ChipView()
    private var isChangingConversationConfiguration = false
    private var reportedModel: String?

    /// The view showing the assistant's current message while its tokens arrive.
    ///
    /// Streaming text has no identity of its own: it is replaced wholesale once the finished
    /// message lands, which is the authoritative copy. The text itself lives on the timeline.
    var streamingLabel: NSTextField?

    /// Words for the status line while a turn is in flight, one drawn per turn. Per session, so
    /// two conversations working at once are unlikely to be saying the same thing.
    var workingWords = WorkingWordCycle()
    private let account: AgentAccount?
    let configuredEffort: String?
    var workingStartedAt: TimeInterval?
    var workingStatusTimer: Timer?

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
        let account = AgentAccountDiscovery.account(
            for: agentSession.kind,
            handle: agentSession.accountHandle
        )
        self.account = account
        let configuredEffort = AgentModels.defaultEffort(
            for: agentSession.kind,
            account: account
        )
        self.configuredEffort = configuredEffort

        // Rebuild the plan for every turn. Claude asks only once, while Codex asks once per
        // child process; after `thread.started`, the latest stored identifier makes the next
        // Codex plan an `exec resume` automatically.
        let plan = {
            let current = ProjectStore.shared.session(withID: agentSession.id) ?? agentSession
            return AgentLauncher.streamPlan(for: current, in: project)
        }

        switch agentSession.kind {
        case .claude:
            self.stream = ClaudeStreamSession(
                sessionID: agentSession.id,
                effort: configuredEffort,
                plan: plan
            )
        case .codex:
            self.stream = CodexStreamSession(
                sessionID: agentSession.id,
                effort: configuredEffort,
                plan: plan
            )
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        workingStatusTimer?.invalidate()
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

        scrollView = ThemedScrollView()
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
        statusLabel.textColor = Design.Text.tertiary
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        wireConversationControls()
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The orb leads the status text and is shown only while a turn is in
        // flight. A stack detaches a hidden arranged view, so idle status sits
        // flush at the leading edge rather than behind a reserved orb-sized gap.
        orbView.isHidden = true
        statusRow = NSStackView(views: [
            orbView, statusLabel, statusSpacer, modelChip, speedChip
        ])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = Design.Spacing.tight
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        view.addSubview(minimap)
        view.addSubview(promptView)
        view.addSubview(statusRow)

        // The preview hangs off the pane, not off the rail: it is wider than the rail and
        // would be clipped inside it, and it has to float over the conversation.
        minimap.attachPreview(to: view)

        setupConstraints()
    }

    /// Codex's native transport starts a new process for every turn. These controls edit the
    /// persisted session while it is idle; the plan closure reads that record synchronously
    /// when the next turn launches, so `exec resume` keeps the thread and changes only its
    /// model/tier.
    private func wireConversationControls() {
        modelChip.itemsProvider = { [weak self] in self?.modelItems() ?? [] }
        modelChip.onSelect = { [weak self] item in
            self?.selectModel(item.representedValue as? String)
        }
        speedChip.itemsProvider = { [weak self] in self?.speedItems() ?? [] }
        speedChip.onSelect = { [weak self] item in
            guard let fast = item.representedValue as? Bool else { return }
            self?.selectFastMode(fast)
        }

        modelChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        speedChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshConversationControls()
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Pinned to the safe area, which the toolbar insets: anchoring to the view's own
            // top would slide the first message under the toolbar.
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: statusRow.topAnchor,
                constant: -Design.Spacing.small
            ),

            statusRow.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            statusRow.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            statusRow.bottomAnchor.constraint(
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
        stream.onSendAvailabilityChange = { [weak self] in
            self?.refreshConversationControls()
        }

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
            self?.scrollView.reflectScrolledClipView(self?.scrollView.contentView ?? ThemedClipView())
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
            self.apply(.status(.ready(model: nil, lastTurn: nil)))
            self.restoreConversationConfiguration()
            self.refreshConversationControls()
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
        refreshConversationControls()

        // Echoed locally as it is sent. The stream never reports a live user turn back —
        // `.userMessage` exists only for replay — so producing it here is what draws it once.
        apply(timeline.apply(.userMessage(trimmed)))

        // Drawn here, which is the moment the turn starts and the only place the status enters
        // `working` — so the word is fixed for the whole wait and a new one arrives with the
        // next turn.
        apply(.status(.working(word: workingWords.next())))
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
        if case .initialised(_, let model) = event, let model {
            reportedModel = model
        }
        for change in timeline.apply(event) { apply(change) }
        refreshConversationControls()
    }

    private func handleExit(_ status: Int32) {
        clearStreaming()
        apply(.status(.ended(code: status)))
        promptView.isHidden = true
        delegate?.conversation(self, didExitWithCode: status)
    }

    // MARK: - Mid-conversation Configuration

    private var storedSession: AgentSession {
        ProjectStore.shared.session(withID: agentSession.id) ?? agentSession
    }

    private var activeModel: String? {
        let session = storedSession
        return session.model
            ?? reportedModel
            ?? AgentModels.defaultModel(for: session.kind, account: account)
    }

    private func refreshConversationControls() {
        let canConfigure: Bool
        switch agentSession.kind {
        case .claude:
            // Claude accepts control requests while a turn is active; they apply to its next
            // model round-trip without restarting the persistent process.
            canConfigure = stream.isRunning
        case .codex:
            // Codex has no persistent input channel. Its choice changes only at the clean
            // boundary between one `exec` child and the next.
            canConfigure = stream.canSend
        }

        let session = storedSession
        let options = AgentModels.options(for: session.kind, account: account)
        guard !options.isEmpty else {
            modelChip.isHidden = true
            speedChip.isHidden = true
            return
        }

        let model = activeModel

        modelChip.isHidden = false
        modelChip.isEnabled = canConfigure && !isChangingConversationConfiguration
        modelChip.configure(
            symbolName: ConversationControlDefaults.modelSymbol,
            title: model.map(ModelName.display) ?? ConversationControlDefaults.defaultModel
        )

        speedChip.isHidden = !supportsFastMode(model: model, kind: session.kind)
        speedChip.isEnabled = canConfigure && !isChangingConversationConfiguration

        let inherited = AgentModels.defaultFastMode(
            for: session.kind,
            model: model,
            account: account
        )
        // Claude's print transport starts with Fast off unless Skalman sends its flag control.
        // Codex can inherit Fast from its account or model catalog.
        let effective = session.fastMode ?? inherited ?? (
            session.kind == .claude ? false : nil
        )
        let speedTitle: String
        switch effective {
        case true: speedTitle = ConversationControlDefaults.fast
        case false: speedTitle = ConversationControlDefaults.standard
        case nil: speedTitle = ConversationControlDefaults.accountDefault
        }
        speedChip.configure(
            symbolName: ConversationControlDefaults.speedSymbol,
            title: speedTitle
        )
    }

    private func modelItems() -> [ThemedMenuEntry] {
        let session = storedSession
        let configured = AgentModels.defaultModel(for: session.kind, account: account)
        let defaultTitle = configured.map {
            "\(ModelName.display(for: $0))\(ConversationControlDefaults.accountDefaultSuffix)"
        } ?? ConversationControlDefaults.defaultModel

        var items: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: defaultTitle,
                representedValue: nil,
                isSelected: session.model == nil
            ))
        ]

        var options = AgentModels.options(for: session.kind, account: account)
        if let selected = session.model,
           !options.contains(where: { $0.identifier == selected }) {
            options.insert(
                AgentModelOption(
                    identifier: selected,
                    displayName: ModelName.display(for: selected),
                    fastServiceTier: nil,
                    defaultServiceTier: nil
                ),
                at: 0
            )
        }

        items += options.map { option in
            .item(ThemedMenuItem(
                title: option.displayName,
                representedValue: option.identifier,
                isSelected: option.identifier == session.model
            ))
        }
        return items
    }

    private func speedItems() -> [ThemedMenuEntry] {
        let session = storedSession
        let inherited = AgentModels.defaultFastMode(
            for: session.kind,
            model: activeModel,
            account: account
        )
        let effective = session.fastMode ?? inherited ?? (
            session.kind == .claude ? false : nil
        )

        return [
            .item(ThemedMenuItem(
                title: ConversationControlDefaults.standard,
                subtitle: ConversationControlDefaults.standardDetail,
                representedValue: false,
                isSelected: effective == false
            )),
            .item(ThemedMenuItem(
                title: ConversationControlDefaults.fast,
                subtitle: ConversationControlDefaults.fastDetail,
                representedValue: true,
                isSelected: effective == true
            ))
        ]
    }

    private func selectModel(_ model: String?) {
        guard !isChangingConversationConfiguration else { return }

        let session = storedSession
        let resolved = model ?? AgentModels.defaultModel(for: session.kind, account: account)
        let supportsFast = supportsFastMode(model: resolved, kind: session.kind)
        let wasFast = storedSession.fastMode ?? AgentModels.defaultFastMode(
            for: session.kind,
            model: activeModel,
            account: account
        ) ?? false

        let persist = { [weak self] in
            guard let self else { return }
            ProjectStore.shared.update(sessionID: self.agentSession.id) {
                $0.model = model
                // Both provider pickers turn Fast off when the newly selected model cannot
                // run it. For Codex, explicit Standard also overrides an account Fast default.
                if wasFast, !supportsFast { $0.fastMode = false }
            }
            self.reportedModel = resolved
            self.isChangingConversationConfiguration = false
            self.refreshConversationControls()
        }

        switch session.kind {
        case .claude:
            guard let switcher = stream as? ModelSwitchableConversation else { return }
            isChangingConversationConfiguration = true
            refreshConversationControls()
            switcher.setModel(model) { [weak self] result in
                switch result {
                case .success:
                    // Fast is independent process state in Claude. An unsupported model ignores
                    // the flag, but leaving it enabled would make Fast silently return if the
                    // conversation later switched back to Opus.
                    if wasFast, !supportsFast,
                       let speedSwitcher = self?.stream as? FastModeConversation {
                        speedSwitcher.setFastMode(false) { [weak self] result in
                            switch result {
                            case .success:
                                persist()
                            case .failure(let error):
                                // The model change already landed. Record that part while leaving
                                // the still-enabled Fast flag truthful, then surface the partial
                                // failure.
                                guard let self else { return }
                                ProjectStore.shared.update(sessionID: self.agentSession.id) {
                                    $0.model = model
                                }
                                self.reportedModel = resolved
                                self.configurationChangeFailed(error)
                            }
                        }
                    } else {
                        persist()
                    }
                case .failure(let error):
                    self?.configurationChangeFailed(error)
                }
            }

        case .codex:
            guard stream.canSend else { return }
            persist()
        }
    }

    private func selectFastMode(_ fast: Bool) {
        guard !isChangingConversationConfiguration else { return }

        let persist = { [weak self] in
            guard let self else { return }
            ProjectStore.shared.update(sessionID: self.agentSession.id) {
                $0.fastMode = fast
            }
            self.isChangingConversationConfiguration = false
            self.refreshConversationControls()
        }

        switch storedSession.kind {
        case .claude:
            guard let switcher = stream as? FastModeConversation else { return }
            isChangingConversationConfiguration = true
            refreshConversationControls()
            switcher.setFastMode(fast) { [weak self] result in
                switch result {
                case .success:
                    persist()
                case .failure(let error):
                    self?.configurationChangeFailed(error)
                }
            }
        case .codex:
            guard stream.canSend else { return }
            persist()
        }
    }

    private func supportsFastMode(model: String?, kind: AgentKind) -> Bool {
        switch kind {
        case .claude:
            return AgentModels.claudeSupportsFastMode(model)
        case .codex:
            return AgentModels.option(
                identifier: model,
                for: .codex,
                account: account
            )?.supportsFastMode == true
        }
    }

    /// Model is already present on Claude's launch line. Fast mode has no launch flag in the
    /// persistent print transport, so an explicit saved choice is restored over its control
    /// channel once that process is ready.
    private func restoreConversationConfiguration() {
        guard storedSession.kind == .claude,
              let fast = storedSession.fastMode,
              let switcher = stream as? FastModeConversation
        else { return }

        switcher.setFastMode(fast) { [weak self] result in
            if case .failure(let error) = result {
                self?.configurationChangeFailed(error)
            }
        }
    }

    private func configurationChangeFailed(_ error: Error) {
        isChangingConversationConfiguration = false
        refreshConversationControls()
        appendNotice(
            "Could not change conversation settings: \(error.localizedDescription)",
            kind: .error
        )
    }
}

private enum ConversationControlDefaults {
    static let modelSymbol = "cpu"
    static let speedSymbol = "bolt.fill"
    static let defaultModel = "Default model"
    static let accountDefault = "Account default"
    static let accountDefaultSuffix = "  (account default)"
    static let standard = "Standard"
    static let fast = "Fast"
    static let standardDetail = "Normal speed and usage"
    static let fastDetail = "1.5× speed, increased usage"
}
