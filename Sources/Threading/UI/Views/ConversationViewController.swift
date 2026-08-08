import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

enum ConversationComposerCommands {
    static let skillsID = RemoteComposerCatalog.skillsCommandID
    static let statusID = "threading.command:status"
    static let skills = ComposerCapability(
        id: skillsID,
        name: "skills",
        description: L10n.string("Browse skills available in this conversation"),
        kind: .command,
        trigger: .slash,
        presentation: .command
    )
    static let status = ComposerCapability(
        id: statusID,
        name: "status",
        description: L10n.string("Show native session status"),
        kind: .command,
        trigger: .slash,
        presentation: .command
    )

    /// Provider catalogs win when they can execute a command. Otherwise Threading replaces a
    /// disabled expectation with the local equivalent, which is how Codex's documented
    /// terminal-only `/status` becomes useful without pretending app-server implements it.
    static func addingAppCommands(
        to providerCapabilities: [ComposerCapability]
    ) -> [ComposerCapability] {
        var capabilities = providerCapabilities
        replaceDisabledOrInsert(status, in: &capabilities)

        if capabilities.contains(where: \.isAvailableInSkillCatalog) {
            replaceDisabledOrInsert(skills, in: &capabilities)
        }
        return capabilities
    }

    private static func replaceDisabledOrInsert(
        _ appCommand: ComposerCapability,
        in capabilities: inout [ComposerCapability]
    ) {
        let matches: (ComposerCapability) -> Bool = { capability in
            guard capability.trigger == appCommand.trigger else { return false }
            return capability.name.caseInsensitiveCompare(appCommand.name) == .orderedSame
                || capability.aliases.contains { alias in
                    alias.caseInsensitiveCompare(appCommand.name) == .orderedSame
                }
        }
        if capabilities.contains(where: { matches($0) && $0.isEnabled }) { return }
        if let index = capabilities.firstIndex(where: matches) {
            capabilities[index] = appCommand
        } else {
            capabilities.insert(appCommand, at: 0)
        }
    }
}

enum ConversationTransportText {
    /// Slash syntax is positional in Claude: a participant envelope before the leading token
    /// turns a command into ordinary prose. Keep the provider payload exact and leave remote
    /// attribution to Threading's participant state for command-shaped submissions.
    static func message(
        _ text: String,
        participantDisplayName: String?,
        preservesLeadingSlash: Bool
    ) -> String {
        guard let participantDisplayName,
              !(preservesLeadingSlash && text.hasPrefix("/")) else { return text }
        return "Message from \(participantDisplayName) in the shared chat:\n\(text)"
    }
}

/// Renders an agent conversation natively, in place of the agent's terminal: user turns as
/// bubbles, the agent's replies as markdown, tool calls as collapsible rows, approvals as
/// inline cards. This controller drives the stream; the drawing lives in `ConversationRendering`.
final class ConversationViewController: NSViewController {

    // MARK: - Properties

    let agentSession: AgentSession
    private let project: Project

    let stream: ConversationStreamSession

    /// The one catalog consumed by the local composer and projected to remote clients. Provider
    /// metadata remains authoritative; Threading contributes only actions it implements itself.
    var composerCapabilities: [ComposerCapability] {
        ConversationComposerCommands.addingAppCommands(
            to: (stream as? ComposerCapabilityProviding)?.composerCapabilities ?? []
        )
    }

    /// What the conversation *is*, derived from the stream without touching AppKit. The view
    /// tree follows the changes it reports rather than being built straight from events, so
    /// every decision about the shape of a row is testable on its own.
    var timeline: ConversationTimeline
    private let subagentState: SubagentSessionState
    var subagents: SubagentTimeline { subagentState.timeline }
    var selectedSubagentThreadID: String? { subagentState.selectedThreadID }

    /// The transcript is a view-based table rather than one retained stack. AppKit therefore
    /// owns a bounded set of row hosts near the viewport, while `presentationItems` remains the
    /// complete, cheap ordering model for exact jumps and minimap navigation.
    lazy var tableView: ThemedTableView = {
        let table = ThemedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ConversationContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ConversationDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private var documentView: NSView { tableView }
    lazy var scrollView: ThemedScrollView = {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        return scroll
    }()

    /// The turn rail in the gutter beside the column.
    private lazy var minimap: ConversationMinimapView = {
        let minimap = ConversationMinimapView()
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.onSelect = { [weak self] rowIndex in self?.scrollToRow(rowIndex) }
        return minimap
    }()
    private var minimapTurns: [ConversationTimeline.Turn] = []
    private lazy var minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
    private lazy var minimapLeading = minimap.leadingAnchor.constraint(equalTo: view.leadingAnchor)
    private lazy var promptView: PromptView = {
        let prompt = PromptView()
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.fontSurface = .conversation
        prompt.showsImageAttachments = true
        // The model, effort and speed a reply is sent with live on the box's own bottom row —
        // see `PromptView.SubmitPlacement.footer`.
        prompt.submitPlacement = .footer
        prompt.placeholder = L10n.format("Reply to %@", agentSession.kind.displayName)
        prompt.onSubmit = { [weak self] text in
            guard let self else { return }
            // Read before submitting, which is what clears the strip. Recorded here rather than
            // when the image was attached: an attachment removed before sending was never handed
            // over, and listing it would be the pane reporting an intention.
            PromptAttachment.record(
                paths: self.promptView.attachmentPaths,
                sessionID: self.sessionID,
                projectRoot: URL(fileURLWithPath: self.project.folderPath, isDirectory: true)
            )
            _ = self.submit(text, context: self.promptView.contextAttachments)
        }
        prompt.onRequestContextComment = { [weak self] attachment in
            self?.requestComment(on: attachment)
        }
        prompt.onRequestImageComment = { [weak self] path in
            guard let self else { return }
            self.requestComment(on: self.attachmentContext(path: path))
        }
        prompt.onChange = { [weak self] text in
            guard let self else { return }
            SessionContinuityStore.shared.setConversationDraft(text, for: self.sessionID)
        }
        return prompt
    }()
    private lazy var promptContentContainer: ComponentContentContainer = {
        let container = ComponentContentContainer(defaultContent: promptView)
        container.setAccessibilityIdentifier("composer.conversation-reply.content")
        return container
    }()
    /// The box the composer-to-conversation handoff animates into.
    ///
    /// The container rather than the `PromptView` inside it, mirroring the composer's own
    /// `promptHandoffView`: an extension may have composed accessories around the native
    /// prompt, and what the box the user typed in becomes has to be the whole box it becomes.
    /// Read by the pane that swaps the composer for this conversation.
    var promptHandoffView: NSView { promptContentContainer }

    private lazy var promptCustomizationHost = ComponentCustomizationHost(
        target: .conversationReplyComposer(
            sessionID: agentSession.id.uuidString.lowercased()
        ),
        contentContainer: promptContentContainer,
        lookup: customizationLookup,
        imageResolver: ExtensionComponentResourceResolver.image,
        onAction: { [weak self] action in
            guard let self else { return }
            if let onCustomizationAction {
                onCustomizationAction(action)
            } else {
                ComponentCustomizationProviderSlot.shared.perform(action)
            }
        }
    )
    private var selectedSubagentID: String?
    private var subagentTranscriptLoads = SubagentTranscriptLoadCache()
    private var transcriptRecheckGeneration: [String: Int] = [:]
    let customizationLookup: ComponentCustomizationHost.Lookup
    private let appEvents = AppEventObservations()

    /// Invoked for semantic actions in extension-provided reply accessories.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    /// One line of narration above the composer: what the turn is doing, and after it what the
    /// last one cost. The working orb leads it and is shown only while a turn is in flight.
    ///
    /// Narration only. Everything the user can *change* about the next message — model, effort,
    /// speed — sits on the composer's own bottom row instead, because a control that edits what
    /// you are about to send belongs inside the thing you are sending. Left here they read as a
    /// strip of chips floating between the conversation and the input, belonging to neither.
    private lazy var statusRow: NSStackView = {
        let row = NSStackView(views: [orbView, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.tight
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }()
    let orbView = WorkingOrbView()
    lazy var statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Starting…"))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.subheading)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()
    private let modelChip = ChipView()

    /// How much this conversation may do before it has to ask. Second on the row because that
    /// is where the opening composer puts it: model then mode is the pair both composers lead
    /// with, and two surfaces answering the same questions in a different order is the thing
    /// worth spending the slot on. Catalog-backed effort follows on both; speed is reply-only.
    private let modeChip = ChipView()

    /// Reasoning levels belong to model metadata. Whether they can be changed after launch is
    /// the transport's separate `ReasoningEffortConfigurableConversation` promise.
    private let effortChip = ChipView()

    /// The Fast/Standard picker: Codex's tri-state Fast/Standard/Account-default tier and Claude's
    /// live on/off fast mode, offered on the same chip so the two providers read alike.
    private let speedChip = ChipView()

    /// The context meter — how full the model's window is, updated at each turn boundary.
    /// Distinct from the account usage pill, which is quota; this is the conversation's own
    /// weight. Hidden until the stream has reported a reading.
    let contextLabel = NSTextField(labelWithString: "")

    /// The newest context reading, kept apart from `Status` so a later status that carries
    /// no metrics — the post-replay Ready, a model change — cannot blank the meter.
    var lastContextReading: (tokens: Int, window: Int?)?
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
    var workingStartedAt: TimeInterval?
    nonisolated(unsafe) var workingStatusTimer: Timer?

    /// The structured plan position most recently reported in this turn.
    var runProgress: RunProgress?

    /// Unlike `stream.isRunning`, this is one user turn currently awaiting its terminal event.
    /// Both native transports keep their process open between turns.
    var isTurnInFlight = false

    /// The prompt has been accepted locally but is held behind the git-baseline barrier. During
    /// this short window neither the local composer nor a remote mirror may start another turn.
    private var isPreparingTurn = false

    /// The backgrounded shells, children and monitors the agent currently has running.
    ///
    /// Claude restates the whole list whenever it changes; Codex has no equivalent, so its
    /// sessions leave this empty. Read at the turn boundary, never as it arrives — see
    /// `handle(_:)`.
    var backgroundWorkInFlight: [String] = []

    /// Whether the turn that just ended was waiting on work it had started itself.
    ///
    /// Separate from the turn on purpose: the turn really does end, the composer really can be
    /// typed into — what has not happened is the *session* finishing, because this work speaks
    /// back into the conversation on its own.
    var pausedOnOwnWork = false

    /// Tells work a turn started from work parked in an earlier one — see
    /// `BackgroundWorkLedger`, which the terminal surface judges by too.
    private var backgroundWork = BackgroundWorkLedger()

    /// A turn opened or closed, which is the only moment the in-flight list is read.
    ///
    /// Called from the status edge in `ConversationRendering` rather than as the list arrives,
    /// so a task finishing between turns cannot momentarily declare the session done.
    func noteTurnBoundary() {
        pausedOnOwnWork = isTurnInFlight
            ? false
            : backgroundWork.turnEnded(leaving: backgroundWorkInFlight)
    }

    /// Batches replay-only UI work. Four hundred items must not each scroll, rebuild controls,
    /// publish a remote snapshot, or attach work that the completed turn will immediately fold.
    var isReplaying = false

    /// Whether new content may move the view — see `ConversationAutoScroll`.
    var autoScroll = ConversationAutoScroll()

    /// When the user's hand last touched the scroll view, so a bounds change can be read as
    /// theirs rather than as one of our own scrolls landing.
    var lastUserScrollAt: TimeInterval = 0
    private var viewportSaveWorkItem: DispatchWorkItem?
    private var didRestoreContinuityViewport = false

    enum PresentationID: Hashable {
        case handoff
        case timeline(Int)
        case divider(turnStart: Int)
        case fold(turnStart: Int)
        case retained(UUID)
        case streaming
    }

    struct ExactNavigationMeasurements {
        let geometryNanoseconds: UInt64
        let landingLayoutNanoseconds: UInt64
        let correctionNanoseconds: UInt64
        let visibleTurnsNanoseconds: UInt64
        let totalNanoseconds: UInt64
    }

    struct PresentationItem {
        enum Content {
            case timeline(Int)
            case divider
            case fold(
                turnStart: Int,
                hiddenIndices: [Int],
                duration: TimeInterval?,
                stopped: Bool
            )
            case retained(NSView)
            case streaming(NSTextField)
        }

        let id: PresentationID
        let content: Content
        let opensTurn: Bool
    }

    /// Complete ordering without a complete view tree. Timeline rows carry only their stable
    /// integer identity; expensive Markdown/tool views are constructed when the table requests
    /// a viewport row and released when that host is reused.
    var presentationItems: [PresentationItem] = []

    /// Exact timeline identity → table row lookup. Replay leaves it empty while folding mutates
    /// the presentation and builds it once at the final reload; live structural edits rebuild it
    /// at their existing reload boundary.
    var presentationRowsByTimelineIndex: [Int: Int] = [:]

    /// Currently materialized timeline rows. This is intentionally viewport-sized; it exists
    /// for live result delivery and diagnostics, not as the transcript's ownership graph.
    var rowViews: [Int: NSView] = [:]

    /// A diagnostic mirror of the identities AppKit has measured at the current readable width.
    /// `NSTableView` owns the automatic-height cache used for layout; unknown rows use its
    /// estimate during a deep jump and the landing is corrected after the target materializes.
    var rowHeightCache: [PresentationID: CGFloat] = [:]
    var rowHeightCacheWidth: CGFloat = 0

    /// Disclosure state belongs outside recyclable views, so scrolling a row away and back does
    /// not collapse something the user opened.
    var expandedTurnStarts: Set<Int> = []
    var expandedToolRows: Set<Int> = []
    var expandedUserRows: Set<Int> = []

    /// Turns already folded, by the row index of their opening user message, so a fold is
    /// never inserted twice.
    var foldedTurnStarts: Set<Int> = []

    /// An interrupted turn waiting to fold. It stays expanded so the user keeps their place;
    /// the next turn folds it.
    var pendingFold: (startIndex: Int, interrupted: Bool)?

    /// Turns whose changed-files card was already requested, so a repeated settle event
    /// cannot append twins.
    var changedFilesCardTurns: Set<Int> = []

    /// The newest turn's card — the only one whose View diff still describes what Git
    /// Review's Last Turn scope shows. Superseded cards lose the button.
    weak var latestChangedFilesCard: ChangedFilesCardView?

    /// Visible native tool rows waiting for their asynchronous result. Offscreen calls need no
    /// retained view: their result is already authoritative in `timeline` and is picked up when
    /// the row next materializes.
    var pendingToolViews: [Int: ToolCallView] = [:]

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
    ///
    /// A request pending inside a turn is the blocked state, not the unread one: the turn has
    /// stopped until it is answered. Off screen only, as before — on screen the permission card
    /// is the cue, and a second mark in the sidebar would only repeat it.
    ///
    /// Work left running outranks `idle` for the same reason it does in `SessionActivityTracker`:
    /// a turn that ends on top of a backgrounded shell is not the session finishing, and saying
    /// it is posts "finished its turn" for an answer the agent is still about to give.
    var activity: SessionActivity {
        if hasPendingPermission, !isVisible {
            return isTurnInFlight ? .awaitingUser : .needsAttention
        }
        if isTurnInFlight { return .working }
        guard stream.isRunning else { return .dormant }
        return pausedOnOwnWork ? .working : .idle
    }

    // MARK: - Initialization

    init(
        agentSession: AgentSession,
        project: Project,
        subagentState: SubagentSessionState? = nil,
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        self.agentSession = agentSession
        self.project = project
        self.customizationLookup = customizationLookup
        self.timeline = ConversationTimeline(sessionID: agentSession.id)
        self.subagentState = subagentState
            ?? SubagentSessionState(sessionID: agentSession.id)
        let account = AgentAccountDiscovery.account(
            for: agentSession.kind,
            handle: agentSession.accountHandle
        )
        self.account = account
        let launchModel = agentSession.model
            ?? AgentModels.defaultModel(for: agentSession.kind, account: account)
        let launchEffort = AgentModels.effectiveEffort(
            for: agentSession,
            model: launchModel,
            account: account
        )

        // Claude and Codex each launch one persistent transport process. The closure is still
        // resolved at launch time so account routing and a newly stored resume identifier are
        // current when a dormant native conversation is reopened.
        let plan = {
            let current = ProjectStore.shared.session(withID: agentSession.id) ?? agentSession
            return AgentLauncher.streamPlan(for: current, in: project)
        }

        switch agentSession.kind {
        case .claude:
            self.stream = ClaudeStreamSession(
                sessionID: agentSession.id,
                effort: launchEffort,
                subagentTranscriptPlan: {
                    let current = ProjectStore.shared.session(withID: agentSession.id)
                        ?? agentSession
                    guard let transcriptID = current.resumeState.transcriptID,
                          let transcriptAccount = AgentAccountDiscovery.account(
                              for: current.kind,
                              handle: current.accountHandle
                          ) else { return nil }
                    return ClaudeSubagentTranscriptPlan(
                        rootThreadID: transcriptID.rawValue,
                        directory: ClaudeTranscript.subagentsDirectory(
                            sessionID: transcriptID,
                            account: transcriptAccount,
                            in: project
                        )
                    )
                },
                plan: plan
            )
        case .codex:
            self.stream = CodexStreamSession(
                sessionID: agentSession.id,
                workingDirectory: project.folderPath,
                configurationProvider: {
                    let current = ProjectStore.shared.session(withID: agentSession.id)
                        ?? agentSession
                    let model = current.model
                        ?? AgentModels.defaultModel(for: current.kind, account: account)
                    let effort = AgentModels.effectiveEffort(
                        for: current,
                        model: model,
                        account: account
                    )
                    let serviceTier: String?
                    if let fastMode = current.fastMode {
                        if fastMode {
                            serviceTier = AgentModels.option(
                                identifier: model,
                                for: current.kind,
                                account: account
                            )?.fastServiceTier ?? AgentDefaults.codexFastServiceTier
                        } else {
                            serviceTier = AgentDefaults.codexStandardServiceTier
                        }
                    } else {
                        serviceTier = nil
                    }
                    return CodexTurnConfiguration(
                        model: model,
                        effort: effort,
                        serviceTier: serviceTier
                    )
                },
                plan: plan
            )
        case .grok:
            self.stream = GrokACPStreamSession(
                sessionID: agentSession.id,
                workingDirectory: project.folderPath,
                plan: plan
            )
        case .openCode:
            preconditionFailure("This agent runtime uses the terminal surface")
        }
        super.init(nibName: nil, bundle: nil)
        if let handoff = agentSession.handoff {
            let canOpenSource = handoff.source.flatMap {
                ProjectStore.shared.session(withID: $0.sessionID)
            } != nil
            let handoffView = ConversationHandoffView(
                handoff: handoff,
                canOpenSource: canOpenSource,
                onOpenSource: { [weak self] sessionID in
                    guard let self else { return }
                    self.delegate?.conversation(self, didRequestOpenSession: sessionID)
                }
            )
            presentationItems.append(PresentationItem(
                id: .handoff,
                content: .retained(handoffView),
                opensTurn: false
            ))
        }
        appEvents.observe(ComponentCustomizationDidChange.self) { [weak self] event in
            self?.refreshConversationRowsIfCustomizationChanged(event)
        }
        appEvents.observe(SessionInputControlDidChange.self) { [weak self] event in
            guard event.sessionID == self?.sessionID else { return }
            self?.refreshInputControl()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        viewportSaveWorkItem?.cancel()
        saveConversationViewport()
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
        // Each virtual row centres a capped content view inside the full-width table. The
        // resulting gutter is what the turn rail lives in.
        // What is typed here becomes a bubble in the thread, so it is set in the thread's font.
        setupPromptCustomization()

        let continuity = SessionContinuityStore.shared.state(for: sessionID)
        if !continuity.conversationDraft.isEmpty {
            promptView.stringValue = continuity.conversationDraft
        }

        wireConversationControls()

        contextLabel.applyFont(.subheading)
        contextLabel.textColor = Design.Text.tertiary
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        contextLabel.isHidden = true

        // The orb leads the status text and is shown only while a turn is in
        // flight. A stack detaches a hidden arranged view, so idle status sits
        // flush at the leading edge rather than behind a reserved orb-sized gap.
        orbView.isHidden = true

        view.addSubview(scrollView)
        view.addSubview(minimap)
        view.addSubview(promptContentContainer)
        view.addSubview(statusRow)

        // The preview hangs off the pane, not off the rail: it is wider than the rail and
        // would be clipped inside it, and it has to float over the conversation.
        minimap.attachPreview(to: view)

        setupConstraints()
    }

    /// Wraps only the prompt's visual body. Stream state, permission cards, keyboard routing and
    /// submission stay on this controller and `PromptView`; hooks can add compact controls beside
    /// `.proceed` but cannot replace or overlay it.
    private func setupPromptCustomization() {
        promptCustomizationHost.refresh()
    }

    /// Applies a row contract while retaining the exact native view that owns message text,
    /// tool expansion/result state, or permission decisions.
    func customizeConversationRow(
        _ nativeContent: NSView,
        target: ExtensionComponentTarget
    ) -> NSView {
        // No extension owns this row in the normal case. A composition container, host and
        // notification observer around every viewport row made a cold jump rebuild machinery
        // that would render exactly the native subtree it was handed.
        let resolution = customizationLookup(target)
        guard target.component == .conversationPermissionCard || !resolution.isEmpty else {
            return nativeContent
        }

        return ConversationRowCustomizationView(
            nativeContent: nativeContent,
            target: target,
            lookup: customizationLookup,
            onAction: { [weak self] action in
                guard let self else { return }
                if let onCustomizationAction {
                    onCustomizationAction(action)
                } else {
                    ComponentCustomizationProviderSlot.shared.perform(action)
                }
            }
        )
    }

    /// Rows which were native-only when materialized still need to acquire a wrapper if an
    /// extension is installed later, and an emptied row should shed one. One controller observer
    /// handles those structural transitions; an already-customized wrapper handles content-only
    /// refresh itself. Permission cards stay wrapped because they are rare retained interactions.
    private func refreshConversationRowsIfCustomizationChanged(
        _ event: ComponentCustomizationDidChange
    ) {
        guard isViewLoaded else { return }
        let wrapperStateChanged = rowViews.contains { timelineIndex, view in
            guard timeline.rows.indices.contains(timelineIndex),
                  let target = componentTarget(for: timeline.rows[timelineIndex]),
                  customizationChange(event, affects: target) else { return false }
            let shouldWrap = !customizationLookup(target).isEmpty
            let customizationContent = (view as? ConversationMessageContextView)?.content ?? view
            let isWrapped = customizationContent is ConversationRowCustomizationView
            return shouldWrap != isWrapped
        }

        if wrapperStateChanged { reloadConversationRows() }
    }

    private func customizationChange(
        _ event: ComponentCustomizationDidChange,
        affects target: ExtensionComponentTarget
    ) -> Bool {
        event.targets?.contains { changed in
            changed.component == target.component
                && changed.contractVersion == target.contractVersion
                && (changed.entityID == nil || changed.entityID == target.entityID)
        } ?? true
    }

    /// These controls edit the persisted session while it is idle. Claude uses its control
    /// channel; Codex reads the same record into the next app-server `turn/start` request.
    private func wireConversationControls() {
        modelChip.itemsProvider = { [weak self] in self?.modelItems() ?? [] }
        modelChip.onSelect = { [weak self] item in
            self?.selectModel(item.representedValue as? String)
        }
        modeChip.itemsProvider = { [weak self] in self?.permissionModeItems() ?? [] }
        modeChip.onSelect = { [weak self] item in
            // Nil is a real answer here — the inherit row — so this reads "not a mode" as
            // inherit rather than falling back to one.
            self?.selectPermissionMode(item.representedValue as? AgentPermissionMode)
        }
        effortChip.itemsProvider = { [weak self] in self?.effortItems() ?? [] }
        effortChip.onSelect = { [weak self] item in
            self?.selectEffort(item.representedValue as? String)
        }
        speedChip.itemsProvider = { [weak self] in self?.speedItems() ?? [] }
        speedChip.onSelect = { [weak self] item in
            guard let fast = item.representedValue as? Bool else { return }
            self?.selectFastMode(fast)
        }

        modelChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        modeChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        effortChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        speedChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        // What the reply will be sent with, on the leading side; what it has cost so far, on
        // the trailing side beside the send. The composer places them — see
        // `PromptView.setFooterControls(leading:trailing:)`.
        //
        // Model then mode first, because that is the pair the opening composer leads with and
        // keeping those two slots identical across the two composers is the point. Effort and
        // speed have no opening-composer counterpart, so they follow.
        promptView.setFooterControls(
            leading: [modelChip, modeChip, effortChip, speedChip],
            trailing: [contextLabel]
        )
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

            // Both edges pinned, not one: the line is a single truncating label now, and a row
            // free to size itself to its content is what let the controls it used to carry
            // cluster against the leading edge instead of reaching the pane's trailing one.
            //
            // Twice the inset, so the narration starts on the same vertical as the text in the
            // box below it — the box is inset from the pane, and its text inset again from the
            // box. Aligned by ink rather than by frame.
            statusRow.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset * 2
            ),
            statusRow.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            statusRow.bottomAnchor.constraint(
                equalTo: promptContentContainer.topAnchor,
                constant: -Design.Spacing.small
            ),

            promptContentContainer.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            promptContentContainer.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            promptContentContainer.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -Design.Spacing.inset
            ),

            // Anchored to the *pane*, not to the column. The column is centred, so a rail
            // hanging off its leading edge drifts inward as the window grows and strands
            // itself in the middle of an empty margin. `railLeading` keeps it by the pane's
            // edge and only pulls it back when the gutter is too tight for both.
            minimap.topAnchor.constraint(equalTo: scrollView.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])

        minimapLeading.isActive = true

        minimapWidth.isActive = true
    }

    private func setupStream() {
        subagentState.onChange = { [weak self] in
            guard let self else { return }
            self.refreshSubagentState()
            guard !self.isReplaying else { return }
            self.notifySelectedSubagentUpdated()
        }
        selectedSubagentID = subagentState.selectedThreadID
        refreshSubagentState()

        if let reporting = stream as? ProviderExecutionReportingConversation {
            reporting.onProviderExecution = { [weak self] event in
                guard let self else { return }
                ExecutionAuditStore.shared.record(
                    providerEvent: event,
                    sessionID: self.sessionID,
                    provider: self.agentSession.kind
                )
            }
        }

        stream.onEvent = { [weak self] event in
            guard let self else { return }
            ExecutionAuditStore.shared.record(
                streamEvent: event,
                sessionID: self.sessionID,
                provider: self.agentSession.kind
            )
            self.handle(event)
        }
        stream.onExit = { [weak self] status in self?.handleExit(status) }
        stream.onSendAvailabilityChange = { [weak self] in
            self?.refreshConversationControls()
            guard let self else { return }
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }
        if let capabilities = stream as? ComposerCapabilityProviding {
            capabilities.onComposerCapabilitiesChange = { [weak self] in
                guard let self else { return }
                self.refreshComposerCapabilitySurfaces()
            }
        }
        refreshComposerCapabilitySurfaces()
        if let reporting = stream as? SubagentReportingConversation {
            reporting.onSubagentEvent = { [weak self] event in
                self?.handleSubagent(event)
            }
        }
        if let reporting = stream as? SessionTitleReportingConversation {
            let source = reporting.sessionTitleSource
            reporting.onSessionTitleChange = { [weak self] title in
                guard let self else { return }
                ProjectStore.shared.updateAgentTitle(
                    title,
                    for: self.sessionID,
                    source: source
                )
            }
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

        // Both roads a gesture arrives by: wheel and trackpad through the scroll view's own
        // event, scroller-thumb drags through the live-scroll notifications. Programmatic
        // scrolls pass through neither, which is what lets a bounds change be attributed.
        scrollView.onUserScroll = { [weak self] in
            self?.lastUserScrollAt = ProcessInfo.processInfo.systemUptime
        }
        for name in [
            NSScrollView.willStartLiveScrollNotification,
            NSScrollView.didLiveScrollNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userScrolled),
                name: name,
                object: scrollView
            )
        }
    }

    @objc private func userScrolled() {
        lastUserScrollAt = ProcessInfo.processInfo.systemUptime
    }

    @objc private func visibleRegionChanged() {
        // A bounds change on the user's own heels is the user leaving or returning; one from
        // our scrolls landing is not, and must never release the pin — the failure mode
        // behind t3code's own auto-scroll bug.
        let sinceGesture = ProcessInfo.processInfo.systemUptime - lastUserScrollAt
        if sinceGesture < ConversationDefaults.gestureAttribution {
            autoScroll.noteUserScrolled(nearBottom: isNearConversationBottom)
            scheduleConversationViewportSave()
        }
        updateVisibleTurns()
    }

    private func scheduleConversationViewportSave() {
        viewportSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveConversationViewport()
        }
        viewportSaveWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SessionContinuityDefaults.viewportSaveDelay,
            execute: work
        )
    }

    private func saveConversationViewport() {
        guard isViewLoaded else { return }
        viewportSaveWorkItem?.cancel()
        viewportSaveWorkItem = nil
        let overflow = max(0, documentView.bounds.height - scrollView.contentSize.height)
        let progress = overflow > 0
            ? Double(min(max(scrollView.contentView.bounds.origin.y / overflow, 0), 1))
            : 1
        SessionContinuityStore.shared.setConversationViewport(
            progress: progress,
            followsBottom: isNearConversationBottom,
            for: sessionID
        )
    }

    @discardableResult
    private func restoreConversationViewportIfAvailable() -> Bool {
        guard !didRestoreContinuityViewport else { return false }
        didRestoreContinuityViewport = true
        let continuity = SessionContinuityStore.shared.state(for: sessionID)
        guard !continuity.conversationFollowsBottom,
              let progress = continuity.conversationViewportProgress else { return false }

        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        let overflow = max(0, documentView.bounds.height - scrollView.contentSize.height)
        guard overflow > 0 else { return false }
        scrollView.contentView.setBoundsOrigin(NSPoint(
            x: 0,
            y: overflow * min(max(progress, 0), 1)
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        autoScroll.noteUserScrolled(nearBottom: false)
        return true
    }

    // MARK: - Minimap

    override func viewDidLayout() {
        super.viewDidLayout()
        invalidateConversationHeightCacheIfNeeded()
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
        minimapTurns = timeline.turns
        minimap.setTurns(minimapTurns)
        updateVisibleTurns()
    }

    /// A live user message closes the preceding preview and opens exactly one new rail entry.
    /// Replay still replaces the complete rail once at its boundary; live traffic never needs
    /// to re-derive or copy every historical turn.
    func noteMinimapTurnStarted(at startIndex: Int) {
        if let previousPosition = minimapTurns.indices.last,
           minimapTurns[previousPosition].rowIndex != startIndex,
           let previous = timeline.turn(startingAt: minimapTurns[previousPosition].rowIndex) {
            minimapTurns[previousPosition] = previous
            minimap.replaceTurn(previous, at: previousPosition)
        }

        guard let current = timeline.turn(startingAt: startIndex) else {
            updateVisibleTurns()
            return
        }
        if let lastPosition = minimapTurns.indices.last,
           minimapTurns[lastPosition].rowIndex == startIndex {
            minimapTurns[lastPosition] = current
            minimap.replaceTurn(current, at: lastPosition)
        } else {
            minimapTurns.append(current)
            minimap.appendTurn(current)
        }
        updateVisibleTurns()
    }

    /// Settlement supplies the final assistant preview and duration for the current mark.
    func noteMinimapTurnSettled(at startIndex: Int) {
        guard let lastPosition = minimapTurns.indices.last,
              minimapTurns[lastPosition].rowIndex == startIndex,
              let settled = timeline.turn(startingAt: startIndex) else { return }
        minimapTurns[lastPosition] = settled
        minimap.replaceTurn(settled, at: lastPosition)
        updateVisibleTurns()
    }

    /// Stable diagnostics used by the generated-chat contract without exposing the rail view.
    var minimapTurnCount: Int { minimapTurns.count }
    var lastMinimapTurn: ConversationTimeline.Turn? { minimapTurns.last }

    /// Which turns are on screen, so the rail can say where you are as well as what is there.
    private func updateVisibleTurns() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        let visibleRows = tableView.rows(in: visibleRect)
        var indices: Set<Int> = []

        guard visibleRows.location != NSNotFound else {
            minimap.setVisibleTurnIndices(indices)
            return
        }

        for (index, turn) in minimapTurns.enumerated() {
            guard let tableRow = presentationRow(forTimelineIndex: turn.rowIndex) else { continue }
            if NSLocationInRange(tableRow, visibleRows) { indices.insert(index) }
        }

        minimap.setVisibleTurnIndices(indices)
    }

    /// Brings a row to the top of the pane, a little below it so it does not sit against the
    /// toolbar's edge.
    private func scrollToRow(_ index: Int) {
        scrollToTimelineRow(index, animated: true)
    }

    /// Exact row navigation does not depend on the target having a materialized view. The table
    /// resolves its rect from cached and estimated heights, then a second correction after the
    /// animated landing accounts for any newly measured rows around the target.
    @discardableResult
    func scrollToTimelineRow(
        _ index: Int,
        animated: Bool
    ) -> ExactNavigationMeasurements? {
        guard let tableRow = presentationRow(forTimelineIndex: index) else { return nil }

        // The user deliberately went somewhere; only their own gesture re-pins.
        autoScroll.noteJumpedToRow()

        let started = DispatchTime.now().uptimeNanoseconds
        let geometryStarted = DispatchTime.now().uptimeNanoseconds
        let target = max(0, tableView.rect(ofRow: tableRow).minY - Design.Spacing.large)
        let geometryEnded = DispatchTime.now().uptimeNanoseconds

        guard animated else {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let layoutStarted = DispatchTime.now().uptimeNanoseconds
            view.layoutSubtreeIfNeeded()
            let layoutEnded = DispatchTime.now().uptimeNanoseconds
            let settlement = settleTimelineScroll(to: index, measuring: true)
            let ended = DispatchTime.now().uptimeNanoseconds
            return ExactNavigationMeasurements(
                geometryNanoseconds: geometryEnded - geometryStarted,
                landingLayoutNanoseconds: layoutEnded - layoutStarted,
                correctionNanoseconds: settlement.correctionNanoseconds,
                visibleTurnsNanoseconds: settlement.visibleTurnsNanoseconds,
                totalNanoseconds: ended - started
            )
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.settleTimelineScroll(to: index) }
        }
        return nil
    }

    @discardableResult
    private func settleTimelineScroll(
        to index: Int,
        measuring: Bool = false
    ) -> (correctionNanoseconds: UInt64, visibleTurnsNanoseconds: UInt64) {
        let correctionStarted = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        guard let correctedRow = presentationRow(forTimelineIndex: index) else { return (0, 0) }
        let correctedTarget = max(
            0,
            tableView.rect(ofRow: correctedRow).minY - Design.Spacing.large
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: correctedTarget))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let correctionEnded = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        updateVisibleTurns()
        let visibleTurnsEnded = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        return (
            correctionNanoseconds: measuring ? correctionEnded - correctionStarted : 0,
            visibleTurnsNanoseconds: measuring ? visibleTurnsEnded - correctionEnded : 0
        )
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
            let performanceSpan = PerformanceRecorder.shared.begin(
                "conversation.replay.render",
                category: "conversation.ui",
                metadata: [
                    "events": String(events.count),
                    "truncated": String(isTruncated)
                ]
            )
            for event in events { self.handle(event) }
            self.finishReplayRendering()
            performanceSpan.end(metadata: [
                "rows": String(self.timeline.rows.count),
                "materialized_rows": String(self.rowViews.count),
                "presentation_rows": String(self.presentationItems.count),
                "cached_heights": String(self.rowHeightCache.count),
                "folded_turns": String(self.foldedTurnStarts.count)
            ])
            self.replaySubagentHistoryAndStart()
        }
    }

    private func replaySubagentHistoryAndStart() {
        guard let history = stream as? SubagentHistoryConversation else {
            finishReplayAndStart()
            return
        }
        history.loadSubagentHistory { [weak self] events in
            guard let self else { return }
            for event in events { self.handleSubagent(event) }
            self.finishReplayAndStart()
        }
    }

    private func finishReplayAndStart() {
        finishReplayRendering()
        isReplaying = false
        // Replay changes the rail, controls and remote snapshot many times but exposes only the
        // completed transcript. Publish that one state instead of rebuilding and mirroring each
        // intermediate prefix on the main thread.
        refreshMinimap()
        autoScroll.noteReplayFinished()
        if !restoreConversationViewportIfAvailable() {
            scrollToBottom()
        }
        stream.start()
        apply(.status(.ready(model: nil, lastTurn: nil)))
        restoreConversationConfiguration()
        refreshConversationControls()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
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
        _ = submit(text)
    }

    /// The same input path as the local composer, exposed narrowly to the authenticated remote
    /// mirror so validation, local echo, working state, and provider transport cannot diverge.
    @discardableResult
    func sendRemotePrompt(
        _ text: String,
        context: [ConversationContextAttachment] = [],
        authorization: RemoteAuthorization
    ) -> Bool {
        submit(text, context: context, authorization: authorization)
    }

    /// A prompt the app composed on the user's behalf — the sidebar's "Rename with Agent".
    ///
    /// Deliberately the ordinary `submit`, so the request is echoed into the transcript as a
    /// user turn like any other. An instruction sent to an agent invisibly is one the user
    /// cannot see, correct, or account for when the reply arrives, and this one costs them a
    /// turn of their own usage.
    @discardableResult
    func sendAppPrompt(_ text: String) -> Bool {
        submit(text)
    }

    /// Provider-neutral rows for mobile/web conversation clients. Tool inputs have already
    /// been reduced to their safe one-line summary; raw provider arguments never cross this
    /// boundary accidentally.
    var remoteSnapshot: RemoteConversationSnapshotDTO {
        let rows = timeline.rows.enumerated().map { index, row in
            let id = String(index)
            switch row {
            case .userMessage(let message):
                return RemoteConversationRowDTO(
                    id: id,
                    kind: "user",
                    text: message.text,
                    contextAttachments: message.context.map(\.remoteDTO)
                )
            case .assistant(let markdown):
                return RemoteConversationRowDTO(id: id, kind: "assistant", text: markdown)
            case .thinking(let text):
                return RemoteConversationRowDTO(id: id, kind: "thinking", text: text)
            case .toolCall(let call):
                return RemoteConversationRowDTO(
                    id: id,
                    kind: "tool",
                    toolName: call.name,
                    summary: call.summary,
                    result: call.result?.text,
                    // The settled outcome, not the raw wire flag, so a sniffed failure reads
                    // as failed on remote clients too.
                    isError: call.result?.outcome == .failed
                )
            case .notice(let text, let kind):
                return RemoteConversationRowDTO(
                    id: id,
                    kind: "notice",
                    text: text,
                    isError: kind == .error
                )
            }
        }
        return RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: timeline.streamingText,
            canSend: stream.canSend && !isPreparingTurn,
            composerCapabilities: composerCapabilities.map { capability in
                RemoteComposerCapabilityDTO(
                    id: capability.id,
                    name: capability.name,
                    displayName: capability.displayName,
                    description: capability.description,
                    argumentHint: capability.argumentHint,
                    aliases: capability.aliases,
                    kind: capability.kind.rawValue,
                    isAvailableInSkillCatalog: capability.isAvailableInSkillCatalog,
                    trigger: capability.trigger.rawValue,
                    presentation: capability.presentation.rawValue,
                    isEnabled: capability.isEnabled,
                    unavailableReason: capability.unavailableReason
                )
            },
            permission: activePermissionCard?.remoteRequest
        )
    }

    private func refreshComposerCapabilitySurfaces() {
        if isViewLoaded {
            promptView.composerCapabilities = composerCapabilities
        }
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    /// Resolves only the permission card that is currently visible. Queued requests remain
    /// ordered and receive their own fresh id when promoted.
    func resolveRemotePermission(id: String, decision: String) -> Bool {
        activePermissionCard?.resolveRemote(id: id, decision: decision) ?? false
    }

    // MARK: - Context Attachments

    /// One staging door for messages, diffs, images, the attachments pane, and remote clients.
    /// The prompt owns the receipt UI; the controller owns session routing and focus.
    func stageContextAttachment(_ attachment: ConversationContextAttachment) {
        guard RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) else {
            refreshInputControl()
            return
        }
        promptView.addContextAttachment(attachment)
        SessionContinuityStore.shared.setConversationDraft(promptView.stringValue, for: sessionID)
    }

    func requestComment(on attachment: ConversationContextAttachment) {
        let request = TextPromptRequest(
            title: L10n.format("Comment on %@", attachment.title),
            message: attachment.excerpt,
            confirmTitle: L10n.string("Add to Chat"),
            placeholder: L10n.string("What should change?")
        )
        guard case .text(let body)? = TextPromptAlert.ask(request) else { return }
        stageContextAttachment(attachment.commenting(body))
    }

    func attachmentContext(path: String, displayPath: String? = nil) -> ConversationContextAttachment {
        let locator = displayPath ?? projectRelativePath(for: path)
        return ConversationContextAttachment(
            kind: .reference,
            source: .attachment,
            title: URL(fileURLWithPath: path).lastPathComponent,
            excerpt: locator,
            locator: locator
        )
    }

    /// Wires the contextual action shell after row virtualization creates it. The model values
    /// stay in the timeline; a recycled view owns no durable callback state of its own.
    func configureContextActions(
        in view: NSView,
        row: ConversationTimeline.Row,
        rowIndex: Int
    ) {
        if let toolView = view as? ToolCallView {
            toolView.onAddContextAttachment = { [weak self] attachment in
                self?.stageContextAttachment(attachment)
            }
            toolView.onRequestContextComment = { [weak self] attachment in
                self?.requestComment(on: attachment)
            }
            return
        }
        guard let messageView = view as? ConversationMessageContextView else { return }

        let title: String
        let excerpt: String
        switch row {
        case .userMessage(let message):
            title = L10n.string("Your earlier message")
            excerpt = message.text
        case .assistant(let markdown):
            title = L10n.string("Agent response")
            excerpt = markdown
        default:
            return
        }

        let reference = ConversationContextAttachment(
            kind: .reference,
            source: .message,
            title: title,
            excerpt: excerpt,
            locator: "conversation-row:\(rowIndex)"
        )
        messageView.onReferenceMessage = { [weak self] in
            self?.stageContextAttachment(reference)
        }
        messageView.onCommentMessage = { [weak self] in
            self?.requestComment(on: reference)
        }
        messageView.onReferenceContext = { [weak self] attachment in
            self?.stageContextAttachment(attachment)
        }
        messageView.onCommentContext = { [weak self] attachment in
            self?.requestComment(on: attachment)
        }
    }

    private func projectRelativePath(for path: String) -> String {
        let root = URL(fileURLWithPath: project.folderPath, isDirectory: true)
            .standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else {
            return URL(fileURLWithPath: candidate).lastPathComponent
        }
        return String(candidate.dropFirst(prefix.count))
    }

    // MARK: - Input

    @discardableResult
    private func submit(
        _ text: String,
        context: [ConversationContextAttachment] = [],
        authorization: RemoteAuthorization? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = ConversationContextPolicy.normalized(context)
        guard !trimmed.isEmpty || !context.isEmpty else { return false }
        guard !isPreparingTurn else { return false }
        if authorization == nil,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            refreshInputControl()
            return false
        }

        // A reference/comment turn is ordinary model input. Treating its leading `/word` as a
        // session command would drop the sidecar context at the provider's command boundary.
        let invocation = context.isEmpty
            ? ComposerCapabilityResolver.invocation(
                in: trimmed,
                capabilities: composerCapabilities
            )
            : nil

        // `/skills` belongs to Threading's composer, not either provider. Remote clients render
        // the same catalog themselves; only a local invocation has a picker to open here.
        if invocation?.capability.id == ConversationComposerCommands.skillsID {
            guard authorization == nil else { return false }
            promptView.showSkillCompletions()
            return true
        }

        // Codex app-server exposes status ingredients rather than a `/status` RPC. Claude's
        // live catalog remains authoritative when it advertises its own enabled command; this
        // fallback is used only when the provider has no native implementation.
        if invocation?.capability.id == ConversationComposerCommands.statusID {
            apply(timeline.appendNotice(nativeStatusText, kind: .muted))
            if authorization == nil {
                promptView.clear()
                SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
            }
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return true
        }

        if let invocation, !invocation.capability.isEnabled {
            let reason = invocation.capability.unavailableReason
                ?? L10n.string("This command is not available in native Chat")
            apply(timeline.appendNotice(reason, kind: .error))
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return false
        }

        guard stream.canSend else { return false }

        let localPrompt = ConversationPrompt(text: trimmed, context: context)
        let transportedText: String
        if let authorization, let member = authorization.member {
            RemoteNotificationService.shared.recordInteraction(
                sessionID: sessionID,
                authorization: authorization
            )
            // The provider transport has no participant-metadata channel. A short, explicit
            // envelope lets the agent understand who "me" and another named member refer to,
            // while the locally rendered bubble remains the person's original message.
            transportedText = ConversationTransportText.message(
                localPrompt.visibleText,
                participantDisplayName: member.displayName,
                preservesLeadingSlash: agentSession.kind.supports(.slashCommandPrefix)
            )
        } else {
            RemoteNotificationService.shared.recordOwnerInteraction(sessionID: sessionID)
            transportedText = trimmed
        }

        let transportedPrompt = ConversationPrompt(text: transportedText, context: context)

        isPreparingTurn = true
        latestChangedFilesCard?.hideViewDiff()
        refreshInputControl()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)

        GitTurnBaselineStore.shared.prepareTurn(sessionID: sessionID) { [weak self] in
            guard let self else { return }
            self.isPreparingTurn = false
            self.sendPreparedTurn(
                localPrompt: localPrompt,
                transportedPrompt: transportedPrompt,
                invocation: invocation,
                sourceText: trimmed
            )
        }
        return true
    }

    /// Releases one accepted prompt after its immutable turn-start tree has been recorded.
    private func sendPreparedTurn(
        localPrompt: ConversationPrompt,
        transportedPrompt: ConversationPrompt,
        invocation: ComposerInvocation?,
        sourceText: String
    ) {
        let sent: Bool
        if let invocation,
           let capabilityStream = stream as? ComposerCapabilityProviding {
            // Provider actions are syntax-bearing protocol messages. Do not prepend the shared
            // chat participant envelope or reconstruct their arguments; the resolver has kept
            // the exact trimmed source for this purpose.
            sent = capabilityStream.send(invocation)
        } else {
            sent = stream.send(transportedPrompt)
        }
        guard sent else {
            refreshInputControl()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return
        }
        refreshConversationControls()
        runProgress = nil

        if invocation?.capability.presentation == .command {
            apply(timeline.appendNotice(sourceText, kind: .muted))
        } else {
            // Echoed locally as it is sent. The stream never reports a live user turn back —
            // `.userMessage` exists only for replay — so producing it here is what draws it
            // once. Anchoring is decided before the echo lands so its `addRow` cannot yank the
            // view to the bottom first.
            autoScroll.noteMessageSent()
            apply(timeline.appendUserMessage(localPrompt.userMessage))
            anchorSentMessage(at: timeline.rows.count - 1)
        }

        // Drawn here, which is the moment the turn starts and the only place the status enters
        // `working` — so the word is fixed for the whole wait and a new one arrives with the
        // next turn.
        apply(.status(.working(word: workingWords.next())))
        promptView.clear()
        SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    private var nativeStatusText: String {
        let model = activeModel.map(ModelName.display) ?? ConversationControlDefaults.defaultModel
        let activity: String
        if isTurnInFlight {
            activity = L10n.string("Working…")
        } else if stream.isRunning {
            activity = L10n.string("Ready")
        } else {
            activity = L10n.string("Stopped")
        }
        let context = lastContextReading.map {
            TurnStatusText.context(tokens: $0.tokens, window: $0.window)
        } ?? L10n.string("Context not reported yet")
        return L10n.format(
            "Native Chat status · %@ · %@ · %@ · %@",
            agentSession.kind.displayName,
            model,
            activity,
            context
        )
    }

    private func apply(_ changes: [ConversationTimeline.Change]) {
        for change in changes { apply(change) }
    }

    /// Scrolls the just-sent bubble toward the top of the pane, where the reply will stream
    /// in below it while it holds still.
    ///
    /// "Toward": no blank space is reserved below short content, so the bubble rises as far
    /// as the content allows — the clip view clamps the rest — and holds the top once enough
    /// reply has arrived to put it there.
    private func anchorSentMessage(at index: Int) {
        // After layout, or the target is the frame the row had before it existed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoScroll.mode == .anchored,
                  let tableRow = self.presentationRow(forTimelineIndex: index) else { return }

            let target = max(
                0,
                self.tableView.rect(ofRow: tableRow).minY - Design.Spacing.large
            )
            self.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
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
            if storedSession.isCrossProviderContinuation {
                ProjectStore.shared.update(sessionID: sessionID) {
                    $0.recordHandoffTargetModel(model)
                }
            }
            // Only an unpinned session speaks for the account: one running an explicit choice
            // reports that choice, which says nothing about what "no model chosen" resolves to.
            if storedSession.model == nil, let account {
                AccountPreferencesStore.shared.setLastReportedModel(model, for: account.id)
            }
        }
        // Recorded, deliberately not announced. Work can only be backgrounded from inside a
        // turn, so the rise never changes the activity; the fall arrives in the gap between a
        // task finishing and the CLI waking the agent with its result, and announcing *that*
        // would post "finished its turn" microseconds before the turn resumed. The level is
        // read where it matters, at the turn boundary in `ConversationRendering`.
        if case .backgroundWork(let inFlight) = event {
            backgroundWorkInFlight = inFlight
        }
        recordAttachments(in: event)
        for change in timeline.apply(event) { apply(change) }
        if !isReplaying {
            refreshConversationControls()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        }
    }

    private func handleSubagent(_ event: SubagentEvent) {
        subagentState.apply(event)
    }

    private func notifySelectedSubagentUpdated() {
        guard let selectedSubagentID,
              let selected = subagents.agents.first(where: {
                  $0.descriptor.threadID == selectedSubagentID
              }) else { return }
        delegate?.conversation(self, didUpdateSelectedSubagent: selected)
    }

    private func refreshSubagentState() {
        let agents = subagents.agents
        guard !agents.isEmpty else {
            selectedSubagentID = nil
            delegate?.conversationSubagentsDidChange(self)
            return
        }

        if let selectedSubagentID,
           let selected = agents.first(where: {
               $0.descriptor.threadID == selectedSubagentID
           }) {
            // A Codex stop hook can add the first real transcript filename after selection.
            loadSubagentTranscriptIfNeeded(selected)
        }
        delegate?.conversationSubagentsDidChange(self)
    }

    func selectSubagent(_ threadID: String?) {
        guard let threadID,
              let selected = subagents.agents.first(where: {
                  $0.descriptor.threadID == threadID
              }) else { return }
        selectedSubagentID = threadID
        subagentState.select(threadID: threadID)
        delegate?.conversation(self, didSelectSubagent: selected)
        loadSubagentTranscriptIfNeeded(selected)
    }

    private var isNearConversationBottom: Bool {
        guard isViewLoaded else { return true }
        let overflow = documentView.bounds.height - scrollView.contentSize.height
        return overflow <= 0
            || scrollView.contentView.bounds.origin.y
                >= overflow - ConversationDefaults.bottomTolerance
    }

    private func loadSubagentTranscriptIfNeeded(_ agent: SubagentTimeline.Agent) {
        let threadID = agent.descriptor.threadID
        guard agent.status.isDone,
              let signature = SubagentTranscriptLoader.signature(for: agent.descriptor),
              subagentTranscriptLoads.begin(
                  threadID: threadID,
                  signature: signature
              ) else {
            return
        }

        let completion: @MainActor @Sendable ([StreamEvent], Bool) -> Void = {
            [weak self] events, isTruncated in
            guard let self else { return }
            switch self.subagentTranscriptLoads.finish(
                threadID: threadID,
                signature: signature,
                eventCount: events.count
            ) {
            case .retryAfter(let delay):
                self.scheduleTranscriptRecheck(threadID: threadID, after: delay)
                return
            case .unavailable:
                return
            case .loaded:
                break
            }
            self.subagentState.replaceTranscriptConversation(
                threadID: threadID,
                events: events
            ) { [weak self] in
                guard let self else { return }
                if isTruncated {
                    self.handleSubagent(.activity(
                        threadID: threadID,
                        text: ClaudeSubagentHistoryDefaults.truncatedActivity
                    ))
                }
                self.scheduleTranscriptStabilityChecks(threadID: threadID)
            }
        }

        if let history = stream as? SubagentHistoryConversation {
            history.loadSubagentTranscript(for: agent.descriptor, completion: completion)
        } else {
            SubagentTranscriptLoader.load(
                descriptor: agent.descriptor,
                kind: agentSession.kind,
                completion: completion
            )
        }
    }

    private func scheduleTranscriptRecheck(threadID: String, after delay: TimeInterval) {
        let generation = (transcriptRecheckGeneration[threadID] ?? 0) + 1
        transcriptRecheckGeneration[threadID] = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.transcriptRecheckGeneration[threadID] == generation,
                  let agent = self.subagents.agents.first(where: {
                      $0.descriptor.threadID == threadID
                  }) else {
                return
            }
            self.loadSubagentTranscriptIfNeeded(agent)
        }
    }

    private func scheduleTranscriptStabilityChecks(threadID: String) {
        let generation = (transcriptRecheckGeneration[threadID] ?? 0) + 1
        transcriptRecheckGeneration[threadID] = generation
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.transcriptRecheckGeneration[threadID] == generation,
                      let agent = self.subagents.agents.first(where: {
                          $0.descriptor.threadID == threadID
                      }) else {
                    return
                }
                self.loadSubagentTranscriptIfNeeded(agent)
            }
        }
    }

    /// Native output is already structured, so only finished assistant prose is inspected.
    /// Tool output and thinking may contain hundreds of incidental asset paths and are not the
    /// agent telling the user that a visual deliverable exists.
    private func recordAttachments(in event: StreamEvent) {
        guard AppSettings.shared.detectsAttachmentReferences(for: agentSession.kind) else {
            return
        }

        let texts: [String]
        switch event {
        case .assistantMessage(let blocks):
            texts = blocks.compactMap {
                if case .text(let text) = $0 { return text }
                return nil
            }
        case .turnFinished(let text, _, _):
            texts = text.map { [$0] } ?? []
        default:
            return
        }

        let root = URL(fileURLWithPath: project.folderPath, isDirectory: true)
        for text in texts {
            SessionAttachmentStore.shared.recordReferences(
                in: text,
                sessionID: sessionID,
                projectRoot: root
            )
        }
    }

    private func handleExit(_ status: Int32) {
        clearStreaming()
        // The process that owned those tasks is gone, and nothing will report them ending.
        backgroundWorkInFlight = []
        pausedOnOwnWork = false
        backgroundWork.forget()
        apply(.status(.ended(code: status)))
        promptContentContainer.isHidden = true
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
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

    /// What the menu's "leave it to the CLI" row names, and where that name came from.
    ///
    /// The chip resolves through `activeModel` while the row used to consult only the account's
    /// config file, so the two disagreed in the one case that matters: an account naming no
    /// model of its own ran a session whose chip read `Opus · 1M` — reported by the CLI when it
    /// started — above a row still reading "Default model". Same question, two answers, one
    /// click apart. The rule itself lives in `AgentModels` and is tested there.
    private var resolvedDefaultModel: ResolvedDefaultModel {
        AgentModels.resolvedDefault(
            sessionModel: storedSession.model,
            reportedModel: reportedModel,
            configuredModel: AgentModels.defaultModel(
                for: storedSession.kind,
                account: account
            ),
            rememberedModel: account.flatMap {
                AccountPreferencesStore.shared.lastReportedModel(for: $0.id)
                    ?? ClaudeAccountLastRunModel.lastRunModel(account: $0)
            }
        )
    }

    /// Read at the point a turn starts, so changing effort while idle updates both the launch
    /// plan and the working/last-turn status for that turn.
    var effectiveEffort: String? {
        AgentModels.effectiveEffort(
            for: storedSession,
            model: activeModel,
            account: account
        )
    }

    private func refreshConversationControls() {
        refreshInputControl()
        // The transport answers this, not the runtime: when a change lands is a property of
        // the wire protocol carrying it. See `ConversationStreamSession`.
        let canConfigure = stream.acceptsConfigurationChange

        let session = storedSession

        // Configured before the catalog guard below, because the permission posture is not a
        // property of the model: a runtime that publishes no model catalog still has one.
        //
        // Not gated on `canConfigure` either. Model, effort and speed have meaning only on a
        // live transport, but the mode also has a durable record that states the next launch —
        // which is the whole of what it means on a dormant conversation, and the session row's
        // own Permission Mode item is editable at exactly those times. Two entrances to one
        // setting must not disagree about whether it can be changed at all. Only a change
        // already in flight closes it.
        modeChip.isHidden = !session.kind.supportsPermissionModes
        modeChip.isEnabled = !isChangingConversationConfiguration
        modeChip.configure(
            symbolName: PermissionModePresentation.symbol,
            title: PermissionModePresentation.chipTitle(
                selected: session.permissionMode,
                inherited: PermissionModePresentation.appDefault
            )
        )

        let options = AgentModels.options(for: session.kind, account: account)
        guard !options.isEmpty else {
            modelChip.isHidden = true
            effortChip.isHidden = true
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

        let modelOption = ReasoningEffortPresentation.option(
            kind: session.kind,
            model: model,
            account: account
        )
        // The catalog decides whether levels exist; the transport separately promises that a
        // choice reaches the next turn. Claude currently has only a launch flag, so its opening
        // composer offers effort without this reply composer implying a live change.
        effortChip.isHidden = modelOption == nil
            || !(stream is ReasoningEffortConfigurableConversation)
        effortChip.isEnabled = canConfigure && !isChangingConversationConfiguration
        effortChip.configure(
            symbolName: ReasoningEffortPresentation.symbol,
            title: ReasoningEffortPresentation.title(
                selected: session.reasoningEffort,
                kind: session.kind,
                model: model,
                account: account
            )
        )

        speedChip.isHidden = !AgentModels.supportsFastMode(
            kind: session.kind,
            model: model,
            account: account
        )
        speedChip.isEnabled = canConfigure && !isChangingConversationConfiguration

        let effective = AgentModels.effectiveFastMode(
            for: session,
            model: model,
            account: account
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

    private func refreshInputControl() {
        guard isViewLoaded else { return }
        let state = RemoteSessionMirrorRegistry.shared.ownerInputControlState(for: sessionID)
        promptView.isSubmissionEnabled = state.canWrite && !isPreparingTurn
        if isPreparingTurn {
            promptView.submissionDisabledReason = L10n.string("Preparing turn…")
        } else if !state.canWrite {
            promptView.submissionDisabledReason = L10n.format(
                "%@ is controlling this chat. Your draft stays here.",
                state.controllerDisplayName ?? L10n.string("Another participant")
            )
        } else {
            promptView.submissionDisabledReason = nil
        }
    }

    private func modelItems() -> [ThemedMenuEntry] {
        let session = storedSession
        let resolved = resolvedDefaultModel
        let defaultTitle = resolved.identifier.map {
            "\(ModelName.display(for: $0))\(ConversationControlDefaults.suffix(for: resolved.source))"
        } ?? ConversationControlDefaults.defaultModel

        // The same readings the composer's model menu carries. Switching model mid-conversation
        // is exactly the move a spent window calls for, and this menu used to be the one place
        // that made it without saying what any of the choices cost — the numbers were on the
        // toolbar pill for the model already running, and nowhere for the ones on offer.
        //
        // One refresh for the whole menu, not one per row: the service throttles either way, but
        // a list is not a reason to ask the network once per item.
        if let account { AccountUsageService.shared.refresh(account) }

        var defaultItem = ThemedMenuItem(
            title: defaultTitle,
            representedValue: nil,
            isSelected: session.model == nil
        )
        if let account {
            AccountUsageMenu.decorate(&defaultItem, forModel: resolved.meteredIdentifier, on: account)
        }

        var items: [ThemedMenuEntry] = [.item(defaultItem)]

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
            var item = ThemedMenuItem(
                title: option.displayName,
                representedValue: option.identifier,
                isSelected: option.identifier == session.model
            )
            if let account {
                AccountUsageMenu.decorate(&item, forModel: option.identifier, on: account)
            }
            return .item(item)
        }
        return items
    }

    /// The same rows the session row's menu and the opening composer offer, from one builder —
    /// three menus for one setting could otherwise disagree about what the app-wide default is
    /// called. Only the timing is this surface's own.
    private func permissionModeItems() -> [ThemedMenuEntry] {
        PermissionModePresentation.rows(
            for: storedSession.kind,
            selected: storedSession.permissionMode,
            inherited: PermissionModePresentation.appDefault,
            timing: permissionModeTiming
        )
    }

    /// When a mode chosen on this chip starts to apply.
    ///
    /// The transport answers it, not the runtime's name — the same rule the other three chips
    /// follow. A Claude conversation that is running carries the change on its control channel;
    /// a dormant one, and every transport that cannot be asked mid-conversation, records it for
    /// the next launch instead.
    private var permissionModeTiming: PermissionModePresentation.Timing {
        stream.acceptsConfigurationChange && stream is PermissionModeSwitchableConversation
            ? .immediately
            : .whenTheChatRestarts
    }

    private func effortItems() -> [ThemedMenuEntry] {
        let session = storedSession
        return ReasoningEffortPresentation.rows(
            selected: session.reasoningEffort,
            kind: session.kind,
            model: activeModel,
            account: account
        )
    }

    private func speedItems() -> [ThemedMenuEntry] {
        let effective = AgentModels.effectiveFastMode(
            for: storedSession,
            model: activeModel,
            account: account
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

    private func selectEffort(_ effort: String?) {
        guard !isChangingConversationConfiguration,
              stream.canSend,
              stream is ReasoningEffortConfigurableConversation,
              let option = AgentModels.option(
                identifier: activeModel,
                for: storedSession.kind,
                account: account
              ),
              effort == nil || option.supports(reasoningEffort: effort)
        else { return }

        ProjectStore.shared.update(sessionID: agentSession.id) {
            $0.setReasoningEffort(effort)
        }
        refreshConversationControls()
    }

    /// How much this conversation may do before it has to ask.
    ///
    /// Claude carries it live: `set_permission_mode` rides the same control channel `set_model`
    /// does, and a mode the CLI will not take comes back as an error rather than being silently
    /// dropped, so a refusal surfaces instead of reading as success. Every other transport
    /// records the choice for the next launch, which is what the session row's own item has
    /// always meant — the mode is stated in the flags of the process this configures at startup.
    ///
    /// Inherit has no value on the wire: the control request names one mode and the CLI has no
    /// "return to whatever you were configured with". Resolving it the way the launch line
    /// resolves it is as far as this can honestly go, and where that resolves to nothing only
    /// the record changes — which the conversation is told rather than left to infer from a chip
    /// that now reads Agent's Setting.
    private func selectPermissionMode(_ mode: AgentPermissionMode?) {
        guard !isChangingConversationConfiguration,
              storedSession.kind.supportsPermissionModes else { return }

        let persist = { [weak self] in
            guard let self else { return }
            ProjectStore.shared.setPermissionMode(mode, for: self.agentSession.id)
            self.isChangingConversationConfiguration = false
            self.refreshConversationControls()
        }

        guard permissionModeTiming == .immediately,
              let switcher = stream as? PermissionModeSwitchableConversation
        else {
            persist()
            return
        }

        guard let resolved = mode ?? PermissionModePresentation.appDefault else {
            persist()
            appendNotice(PermissionModePresentation.inheritRecordedOnly, kind: .muted)
            return
        }

        isChangingConversationConfiguration = true
        refreshConversationControls()
        switcher.setPermissionMode(resolved) { [weak self] result in
            switch result {
            case .success:
                persist()
            case .failure(let error):
                self?.configurationChangeFailed(error)
            }
        }
    }

    private func selectModel(_ model: String?) {
        guard !isChangingConversationConfiguration else { return }

        let session = storedSession
        let resolved = model ?? AgentModels.defaultModel(for: session.kind, account: account)
        let supportsFast = AgentModels.supportsFastMode(
            kind: session.kind,
            model: resolved,
            account: account
        )
        let selectedOption = AgentModels.option(
            identifier: resolved,
            for: session.kind,
            account: account
        )
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
                // Effort capabilities belong to the model. Reset an explicit Ultra/Max choice
                // when the new model does not advertise it, returning to its inherited default.
                if let effort = $0.reasoningEffort,
                   selectedOption?.reasoningLevels.isEmpty == false,
                   selectedOption?.supports(reasoningEffort: effort) != true {
                    $0.setReasoningEffort(nil)
                }
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

        case .grok, .openCode:
            // Unreachable today, and deliberately not silent. The chip is already hidden when
            // `AgentModels.options(for:)` is empty, which is every runtime here — so a runtime
            // that starts publishing a model catalog would reach this line, and returning
            // without a word is a control that takes a press and does nothing. It needs a
            // branch stating how its transport carries the change, the way the two above do.
            // (Effort is different and needs no branch: it has one storage path, guarded by
            // the configuration itself. Model and Fast each have two.)
            return
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

        case .grok, .openCode:
            // Unreachable today, and deliberately not silent. The chip is already hidden when
            // `AgentModels.options(for:)` is empty, which is every runtime here — so a runtime
            // that starts publishing a model catalog would reach this line, and returning
            // without a word is a control that takes a press and does nothing. It needs a
            // branch stating how its transport carries the change, the way the two above do.
            // (Effort is different and needs no branch: it has one storage path, guarded by
            // the configuration itself. Model and Fast each have two.)
            return
        }
    }

    /// Model and permission mode are already present on the launch line. Fast mode has no launch
    /// flag in a persistent print transport, so an explicit saved choice is restored over its
    /// control channel once that process is ready.
    ///
    /// The transport's own conformance is the test, not the runtime's name: a transport that
    /// cannot be asked mid-conversation does not conform, and one that can needs no entry here.
    private func restoreConversationConfiguration() {
        guard let fast = storedSession.fastMode,
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
    /// The last resort, reached only by a login that has never run this agent anywhere — no
    /// configuration, no organisation default, no transcript to read. "Default model" was the
    /// wrong words for it: it reads as a setting whose value is being withheld, when the truth
    /// is that nothing has chosen yet and the agent will decide at launch. Naming the decider is
    /// the most this can honestly say; the CLI's own fallback is negotiated per subscription and
    /// is not written down on this machine.
    static var defaultModel: String { L10n.string("Agent's choice") }
    static var accountDefault: String { L10n.string("Account default") }
    static var accountDefaultSuffix: String { L10n.string("  (account default)") }
    static var runningModelSuffix: String { L10n.string("  (in use)") }
    static var lastUsedSuffix: String { L10n.string("  (last used)") }

    /// How the default row qualifies the model it names. A configured model is a setting the
    /// user can go and change; one the runtime reported is a fact about this session only.
    static func suffix(for source: ResolvedDefaultModel.Source) -> String {
        switch source {
        case .accountConfiguration: return accountDefaultSuffix
        case .reportedByRuntime: return runningModelSuffix
        case .rememberedFromEarlierRun: return lastUsedSuffix
        }
    }
    static var standard: String { L10n.string("Standard") }
    static var fast: String { L10n.string("Fast") }
    static var standardDetail: String { L10n.string("Normal speed and usage") }
    static var fastDetail: String { L10n.string("1.5× speed, increased usage") }
}
