import AppKit
import ThreadingExtensionKit
import ThreadingPTYHostKit
import ThreadingRemoteKit

/// Incremental provider-neutral projection of the native timeline.
///
/// Timeline changes already name the exact appended or result-bearing row. Mirroring that edit
/// here avoids remapping the complete transcript every time `remoteSnapshot` is requested, which
/// streaming remote clients do up to twenty times a second.
struct RemoteConversationRowProjection {
    private let generation = UUID()
    private(set) var revision = 0
    private(set) var rows: [RemoteConversationRowDTO] = []

    var rowsRevision: RemoteConversationRowsRevision {
        RemoteConversationRowsRevision(generation: generation, value: revision)
    }

    mutating func apply(
        _ change: ConversationTimeline.Change,
        timelineRows: [ConversationTimeline.Row]
    ) {
        switch change {
        case .appended(let index):
            guard index == rows.count, timelineRows.indices.contains(index) else {
                rebuild(from: timelineRows)
                return
            }
            rows.append(Self.dto(for: timelineRows[index], at: index))
            revision &+= 1

        case .resultAttached(let index):
            guard rows.indices.contains(index), timelineRows.indices.contains(index) else {
                rebuild(from: timelineRows)
                return
            }
            rows[index] = Self.dto(for: timelineRows[index], at: index)
            revision &+= 1

        case .streaming, .status, .runProgress, .turnSettled, .adoptedSessionID:
            return
        }
    }

    mutating func rebuild(from timelineRows: [ConversationTimeline.Row]) {
        rows = timelineRows.enumerated().map { Self.dto(for: $0.element, at: $0.offset) }
        revision &+= 1
    }

    static func dto(
        for row: ConversationTimeline.Row,
        at index: Int
    ) -> RemoteConversationRowDTO {
        let id = String(index)
        switch row {
        case .userMessage(let message):
            return RemoteConversationRowDTO(
                id: id,
                kind: .user,
                text: message.text,
                contextAttachments: message.context.map(\.remoteDTO)
            )
        case .assistant(let markdown):
            return RemoteConversationRowDTO(id: id, kind: .assistant, text: markdown)
        case .thinking(let text):
            return RemoteConversationRowDTO(id: id, kind: .thinking, text: text)
        case .toolCall(let call):
            return RemoteConversationRowDTO(
                id: id,
                kind: .tool,
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
                kind: .notice,
                text: text,
                isError: kind == .error
            )
        case .turnOutcome(let outcome):
            let text = switch outcome {
            case .completed: L10n.string("Completed")
            case .stopped: L10n.string("Interrupted")
            case .failed: L10n.string("Failed")
            }
            return RemoteConversationRowDTO(
                id: id,
                kind: .notice,
                text: text,
                isError: outcome == .failed
            )
        }
    }
}

enum ConversationComposerCommands {
    static let skillsID = RemoteComposerCatalog.skillsCommandID
    static let statusID = "threading.command:status"
    static let usageID = "threading.command:usage"
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
    static let usage = ComposerCapability(
        id: usageID,
        name: "usage",
        description: L10n.string("Open usage, limits, and banked resets"),
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
        replaceDisabledOrInsert(usage, in: &capabilities)

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
final class ConversationViewController: NSViewController, RemoteConversationSurface {

    // MARK: - Properties

    let sessionID: SessionID
    let agentKind: AgentKind
    private let project: Project
    private let currentSessionProjection: CurrentSessionProjection

    func projectedSession(for sessionID: SessionID) -> AgentSession? {
        currentSessionProjection.session(for: sessionID)
    }

    func projectedWorkingDirectory(for sessionID: SessionID) -> String? {
        currentSessionProjection.workingDirectory(for: sessionID)
    }

    let stream: ConversationStreamSession
    private var pendingInitialPrompt: String?

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
    var remoteRowProjection = RemoteConversationRowProjection()
    private let subagentState: SubagentSessionState
    var subagents: SubagentTimeline { subagentState.timeline }
    var selectedSubagentThreadID: String? { subagentState.selectedThreadID }

    /// The transcript is a view-based table rather than one retained stack. AppKit therefore
    /// owns a bounded set of row hosts near the viewport, while the table's items remain the
    /// complete, cheap ordering model for exact jumps and minimap navigation. The mechanism is
    /// shared with the child transcript; see `ConversationTranscriptTable`.
    let transcript = ConversationTranscriptTable<ConversationViewController>()

    var tableView: ThemedTableView { transcript.tableView }
    var scrollView: ThemedScrollView { transcript.scrollView }
    private var documentView: NSView { tableView }

    /// The items only this pane presents beside the shared timeline, divider and tool-fold
    /// identities: the handoff banner, a settled turn's fold, a retained card, the streaming
    /// placeholder.
    enum SurfaceItemID: Hashable {
        case handoff
        case fold(turnStart: Int)
        case retained(UUID)
        case streaming
    }

    enum SurfaceItemContent {
        case fold(
            turnStart: Int,
            hiddenIndices: [Int],
            duration: TimeInterval?,
            outcome: TurnOutcome
        )
        case retained(NSView)
        case streaming(NSTextField)
    }

    typealias PresentationID = ConversationTranscriptTable<ConversationViewController>.ItemID
    typealias PresentationItem = ConversationTranscriptTable<ConversationViewController>.Item

    /// The complete ordering, read for navigation and by tests. Mutation goes through
    /// `transcript`, which keeps AppKit and the identity index in step.
    var presentationItems: [PresentationItem] { transcript.items }

    /// Currently materialized timeline rows — viewport-sized by construction.
    var rowViews: [Int: NSView] { transcript.rowViews }

    var expandedToolGroups: Set<Int> { transcript.expandedToolGroups }

    func presentationRow(forTimelineIndex index: Int) -> Int? {
        transcript.row(forTimelineIndex: index)
    }

    func reloadConversationRows() {
        transcript.reload()
    }

    lazy var jumpToEndButton: ThemedButton = {
        let button = ThemedButton.floatingScrollToEnd(
            accessibility: L10n.string("Scroll to end"),
            target: self,
            action: #selector(scrollToConversationEnd)
        )
        button.isHidden = true
        return button
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
    /// The reply box's stated column — `updateComposerColumnWidth` keeps the constant at what
    /// the pane can actually give, so the constraint never pulls on the pane itself.
    private lazy var composerColumnWidth: NSLayoutConstraint = {
        let constraint = promptContentContainer.widthAnchor.constraint(
            equalToConstant: ConversationDefaults.composerWidth
        )
        constraint.priority = ConversationDefaults.statedColumnPriority
        return constraint
    }()
    private lazy var minimapLeading = minimap.leadingAnchor.constraint(equalTo: view.leadingAnchor)

    /// The transcript normally starts at the pane's content edge. While a limit refusal stands,
    /// the ribbon takes that edge and the transcript begins below it instead. Swapping the two
    /// constraints keeps hidden composer geometry entirely out of this decision.
    private lazy var transcriptBelowPaneTop = scrollView.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor
    )
    private lazy var transcriptBelowLimitRibbon = scrollView.topAnchor.constraint(
        equalTo: limitEscapeStrip.bottomAnchor
    )

    /// Which tool call the reader is currently inside, pinned to the top of the pane.
    private lazy var stickyStep: ConversationStickyStepView = {
        let header = ConversationStickyStepView()
        header.alphaValue = 0
        header.onSelect = { [weak self] rowIndex in self?.scrollToRow(rowIndex) }
        return header
    }()

    /// The row the header last resolved from, so the walk back through the turn runs on a change
    /// of viewport rather than on every scroll event.
    private var stickyStepTopRow: Int?
    private var stickyStepRow: Int?
    private lazy var workspaceFilePlane = WorkspaceFileSearchPlane { sessionID in
        ProjectStore.shared.executionProject(forSessionID: sessionID)?.folderURL
    }
    lazy var promptView: PromptView = {
        let prompt = PromptView()
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.fontSurface = .conversation
        prompt.showsImageAttachments = true
        prompt.showsMovieAttachments = true
        // The model, effort and speed a reply is sent with live on the box's own bottom row —
        // see `PromptView.SubmitPlacement.footer`.
        prompt.submitPlacement = .footer
        prompt.placeholder = L10n.format("Reply to %@", agentKind.displayName)
        prompt.onSubmit = { [weak self] text in
            guard let self, let session = self.currentSession else { return }
            // Read before submitting, which is what clears the strip. Recorded here rather than
            // when the image was attached: an attachment removed before sending was never handed
            // over, and listing it would be the pane reporting an intention.
            let attachments = PromptAttachment.record(
                paths: self.promptView.attachmentPaths,
                sessionID: self.sessionID,
                projectRoot: URL(
                    fileURLWithPath: session.workingDirectory(in: self.project),
                    isDirectory: true
                ),
                turnPlacement: .next
            )
            _ = self.submit(
                text,
                context: self.promptView.contextAttachments,
                attachmentIDs: attachments.map(\.id)
            )
        }
        prompt.onSteer = { [weak self] text in
            guard let self, let session = self.currentSession else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = self.promptView.contextAttachments
            guard !trimmed.isEmpty || !context.isEmpty else { return }
            let attachments = PromptAttachment.record(
                paths: self.promptView.attachmentPaths,
                sessionID: self.sessionID,
                projectRoot: URL(
                    fileURLWithPath: session.workingDirectory(in: self.project),
                    isDirectory: true
                ),
                turnPlacement: .current
            )
            self.steerValidatingWorkspaceFiles(
                ConversationPrompt(text: trimmed, context: context),
                attachmentIDs: attachments.map(\.id)
            )
        }
        prompt.onStop = { [weak self] in
            self?.stopCurrentTurn()
        }
        prompt.onRecallPrevious = { [weak self] in
            self?.editLastQueuedMessage() ?? false
        }
        prompt.onRequestContextComment = { [weak self] attachment in
            self?.requestComment(on: attachment)
        }
        prompt.isContextAttachmentOpenable = { [weak self] attachment in
            guard let self else { return false }
            return SessionContinuityStore.shared.imageAnnotationDocument(
                forContextAttachmentID: attachment.id,
                in: self.sessionID
            ) != nil
        }
        prompt.onOpenContextAttachment = { [weak self, weak prompt] attachment in
            guard let self, let prompt else { return }
            self.openImageAnnotations(for: attachment, from: prompt)
        }
        prompt.onRequestImageComment = { [weak self] path in
            guard let self else { return }
            self.requestComment(on: self.attachmentContext(path: path))
        }
        prompt.onChange = { [weak self, weak prompt] text in
            guard let self, let prompt else { return }
            SessionContinuityStore.shared.setConversationDraft(
                text,
                context: prompt.contextAttachments,
                for: self.sessionID
            )
        }
        prompt.onContextAttachmentsChange = { [weak self, weak prompt] context in
            guard let self, let prompt else { return }
            SessionContinuityStore.shared.setConversationDraft(
                prompt.stringValue,
                context: context,
                for: self.sessionID
            )
        }
        prompt.workspaceFileSearch = { [weak self] query, completion in
            guard let self else {
                completion(.failure(.sessionUnavailable))
                return
            }
            self.workspaceFilePlane.search(
                sessionID: self.sessionID,
                query: query,
                completion: completion
            )
        }
        prompt.onSessionReferenceDrop = { [weak self] sessionIDs in
            self?.stageSessionReferences(sessionIDs)
        }
        return prompt
    }()
    private lazy var promptContentContainer: ComponentContentContainer = {
        let container = ComponentContentContainer(defaultContent: promptView)
        container.setAccessibilityIdentifier("composer.conversation-reply.content")
        return container
    }()
    private lazy var activityBeamView = AgentActivityBeamView()
    /// The box the composer-to-conversation handoff animates into.
    ///
    /// The container rather than the `PromptView` inside it, mirroring the composer's own
    /// `promptHandoffView`: an extension may have composed accessories around the native
    /// prompt, and what the box the user typed in becomes has to be the whole box it becomes.
    /// Read by the pane that swaps the composer for this conversation.
    var promptHandoffView: NSView { promptContentContainer }

    private lazy var promptCustomizationHost = ComponentCustomizationHost(
        target: .conversationReplyComposer(
            sessionID: sessionID.uuidString.lowercased()
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
        let row = NSStackView(views: [orbView, statusLabel, runPlanDisclosure])
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
    lazy var runPlanDisclosure: RunPlanDisclosureView = {
        let disclosure = RunPlanDisclosureView()
        disclosure.preferredEdge = .maxY
        disclosure.isHidden = true
        disclosure.setAccessibilityIdentifier("conversation.status.run-plan")
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        disclosure.setContentCompressionResistancePriority(.required, for: .horizontal)
        return disclosure
    }()
    private let modelChip = ChipView()

    /// How much this conversation may do before it has to ask. Second on the row because that
    /// is where the opening composer puts it: model then mode is the pair both composers lead
    /// with, and two surfaces answering the same questions in a different order is the thing
    /// worth spending the slot on. Catalog-backed effort and speed follow on both.
    private let modeChip = ChipView()

    /// Reasoning levels belong to model metadata. Whether they can be changed after launch is
    /// the transport's separate `ReasoningEffortConfigurableConversation` promise.
    private let effortChip = ChipView()

    /// The Fast/Standard picker: Codex's tri-state Fast/Standard/Account-default tier and Claude's
    /// live on/off fast mode, offered on the same chip so the two providers read alike.
    private let speedChip = ChipView()

    /// When this conversation stops being spent — **last on the row, and present only while a
    /// curfew actually resolves.**
    ///
    /// The four chips before it answer *what the next reply is sent with*; this one answers *how
    /// long there will be replies at all*, which is a different question and the reason it is not
    /// mixed in among them. It is also the only one of the five that is usually absent: a chat
    /// with no curfew is the ordinary case, and a chip reading "No curfew" on every conversation
    /// forever would spend a permanent slot naming a rule nobody set.
    ///
    /// The schedule chevron beside the send stays "send later". Two clocks on one composer are
    /// only confusable while they answer the same question, and these answer opposite ones —
    /// when the next message goes out, and when the last one will.
    let curfewChip = ChipView()

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
    var workingStatusTimer: Timer?

    /// The structured plan position most recently reported in this turn.
    var runProgress: RunProgress? {
        didSet {
            guard isViewLoaded else { return }
            runPlanDisclosure.update(isTurnInFlight ? runProgress : nil)
        }
    }

    /// Unlike `stream.isRunning`, this is one user turn currently awaiting its terminal event.
    /// Both native transports keep their process open between turns.
    var isTurnInFlight = false

    /// A turn boundary is held behind its git checkpoint. This covers both admission's before
    /// capture and completion's final capture; during either window another turn must not start.
    var isPreparingTurn = false

    /// Passed synchronously through `timeline.apply(.turnFinished)` so the changed-files card
    /// binds to the exact checkpoint that settled, even if another turn is queued immediately.
    var settlingGitCheckpointID: GitTurnCheckpointID?

    /// The backgrounded shells, children and monitors the agent currently has running.
    ///
    /// Claude restates the whole list whenever it changes; Codex has no equivalent, so its
    /// sessions leave this empty. Read at the turn boundary, never as it arrives — see
    /// `handle(_:)`.
    var backgroundWorkInFlight: [BackgroundTask] = []

    /// Whether the turn that just ended was waiting on work it had started itself.
    ///
    /// Separate from the turn on purpose: the turn really does end, the composer really can be
    /// typed into — what has not happened is the *session* finishing, because this work speaks
    /// back into the conversation on its own.
    var pausedOnOwnWork = false

    /// Tells work a turn started from work parked in an earlier one — see
    /// `BackgroundWorkLedger`, which the terminal surface judges by too.
    private var backgroundWork = BackgroundWorkLedger()

    /// The refusal the last turn failed on, when it failed for a spent usage limit.
    ///
    /// The native half of `limit-recovery.md`. A terminal session's refusal has to be read out
    /// of its transcript because the CLI only prints it; here the same refusal arrives on the
    /// stream as the turn's own failure text, so there is nothing to poll and nothing to infer —
    /// which is why `ObservedUsageLimit` names no source for a rendered conversation.
    private(set) var usageLimit: UsageLimitStop?

    /// A turn opened or closed, which is the only moment the in-flight list is read.
    ///
    /// Called from the status edge in `ConversationRendering` rather than as the list arrives,
    /// so a task finishing between turns cannot momentarily declare the session done.
    func noteTurnBoundary() {
        pausedOnOwnWork = isTurnInFlight
            ? false
            : backgroundWork.turnEnded(leaving: backgroundWorkInFlight)
        if !isReplaying, !isTurnInFlight, !pausedOnOwnWork {
            onAttention?()
        }
        // A turn beginning is the limit lifting, whoever asked for it. Cleared on the opening
        // edge only: the closing edge is where a refusal is *recorded*, and clearing there
        // would wipe the state one event after setting it.
        if isTurnInFlight {
            usageLimit = nil
            LimitEscapeSuggestionStore.shared.refusalCleared(for: sessionID)
            refreshLimitEscapeStrip()
        }
    }

    // MARK: - The Limit Escape Ribbon

    /// Draws the escape offer from the store, and reports both gestures back to it.
    ///
    /// The same store the terminal path feeds, so a spent login is ranked once and the offer
    /// reads the same on either surface. Pressing is an announcement rather than an action:
    /// migrating a conversation and reopening it belongs to `SessionCoordinator`.
    func wireLimitEscapeStrip() {
        limitEscapeStrip.onContinue = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitEscapeRequested(sessionID: self.sessionID))
        }
        // Reachable here too, and it does less than it does over a terminal: there is no chooser
        // to answer on this surface, so the press files the continuation and nothing is typed.
        limitEscapeStrip.onWaitForReset = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitWaitForResetRequested(sessionID: self.sessionID))
        }
        limitEscapeStrip.onUseBankedReset = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(LimitBankedResetRequested(sessionID: self.sessionID))
        }
        limitEscapeStrip.onDismiss = { [weak self] in
            guard let self else { return }
            LimitEscapeSuggestionStore.shared.dismiss(self.sessionID)
        }
        // A park's own Continue Anyway. Routed here rather than into the escape store because a
        // park is not a suggestion the store holds — it is a standing state of the account, and
        // answering it writes an override scoped to this turn of the window.
        limitEscapeStrip.onContinueAnyway = { [weak self] in
            guard let self else { return }
            CustomLimitParkPolicy.continueAnyway(sessionID: self.sessionID)
            self.refreshLimitEscapeStrip()
            self.flushOutboxIfReady()
        }
        appEvents.observe(CustomLimitsDidChange.self) { [weak self] _ in
            self?.refreshLimitEscapeStrip()
        }
        appEvents.observe(AgentModelsDidChange.self) { [weak self] _ in
            self?.refreshConversationControls()
        }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in
            self?.refreshLimitEscapeStrip()
        }
        appEvents.observe(LimitEscapeSuggestionDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.refreshLimitEscapeStrip()
        }
        // Lifting is the one answer a curfew's strip carries, and it is the user's own rule
        // ending rather than an exception being made to somebody else's — see
        // `LimitEscapeStripView.Offer.Source`.
        limitEscapeStrip.onLiftCurfew = { [weak self] in
            guard let self else { return }
            SessionCurfewCenter.shared.lift(sessionID: self.sessionID)
        }
        // A curfew engaging or being lifted is the one thing that moves the queue's hold without
        // anything else changing: no usage reading moved, no suggestion arrived. Without this,
        // a lifted curfew would leave the messages behind it sitting until the next turn ended.
        appEvents.observe(CurfewDidChange.self) { [weak self] event in
            guard let self, event.sessionID == self.sessionID else { return }
            self.flushOutboxIfReady()
            self.refreshLimitEscapeStrip()
            self.refreshCurfewChip()
        }
        // The standing window is a curfew for every session that never answered for itself, so
        // switching it on or moving it changes what this chat is under without any event naming
        // this chat.
        appEvents.observe(CurfewSettingsDidChange.self) { [weak self] _ in
            self?.refreshLimitEscapeStrip()
            self?.refreshCurfewChip()
        }
        refreshLimitEscapeStrip()
    }

    func refreshLimitEscapeStrip() {
        guard isViewLoaded else { return }

        // A provider refusal outranks a park, because it is the one the user cannot answer: with
        // both standing, telling somebody about their own line while the provider has stopped
        // them would be the smaller fact on top of the larger one.
        if let suggestion = LimitEscapeSuggestionStore.shared.offer(for: sessionID) {
            applyLimitEscapeOffer(LimitEscapeStripView.Offer(suggestion))
            return
        }

        // A park outranks a curfew for the same reason, one step down: a park is a line drawn
        // against an account's spend that this conversation cannot move on its own, while a
        // curfew is this conversation's own clock and the strip's Lift ends it. Both are the
        // user's, so the ranking is which one the reader can do least about.
        let park = CustomLimitParkPolicy.hold(sessionID: sessionID)
        if let rule = park.rule {
            applyLimitEscapeOffer(LimitEscapeStripView.Offer(
                source: .ownLimit,
                resetHint: parkResetHint(for: rule)
            ))
            return
        }

        applyLimitEscapeOffer(curfewOffer())
    }

    /// The strip's curfew state, or nil while nothing is holding this conversation.
    ///
    /// Only a **held** curfew draws. An armed one is a fact about tonight rather than a state the
    /// pane is in, and a ribbon standing over the transcript all afternoon to say so would be the
    /// loudest thing on screen for the least reason — the footer chip is where an armed curfew
    /// belongs, and it says the same thing in the space a plan deserves.
    ///
    /// The hold carries its own resolution and state, so nothing here re-reads the record: a
    /// sentence assembled from a second read could disagree with the decision that produced it.
    func curfewOffer() -> LimitEscapeStripView.Offer? {
        let now = Date()
        guard case .held(_, let curfew, let state) = CurfewHoldPolicy.hold(
            sessionID: sessionID,
            at: now
        ) else { return nil }

        return .curfew(line: CurfewReceiptWords.stripSentence(
            curfew: curfew,
            state: state,
            canTellWorking: SessionCurfewCenter.shared.canTellWorking(sessionID: sessionID),
            now: now
        ))
    }

    /// Applies one resolved offer to both the ribbon and the pane geometry. Kept as the single
    /// seam for the store path and rendered product-shell fixtures: appearance tests must be able
    /// to reproduce the exited-conversation state without fabricating account discovery.
    func applyLimitEscapeOffer(_ offer: LimitEscapeStripView.Offer?) {
        limitEscapeStrip.setOffer(offer)

        let isShowing = offer != nil
        guard transcriptBelowLimitRibbon.isActive != isShowing else { return }

        // Deactivate before activating the replacement: two top edges on the transcript are an
        // unsatisfiable pair, and the refusal arriving should cause one deterministic resize.
        if isShowing {
            transcriptBelowPaneTop.isActive = false
            transcriptBelowLimitRibbon.isActive = true
        } else {
            transcriptBelowLimitRibbon.isActive = false
            transcriptBelowPaneTop.isActive = true
        }
    }

    /// When the window a park is waiting on comes back, in the strip's own vocabulary.
    private func parkResetHint(for rule: CustomLimit) -> String? {
        guard let session = currentSession,
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ),
              let resetsAt = AccountUsageService.shared.usage(for: account)?
                  .allWindows.first(where: { $0.id == rule.windowID })?
                  .resetsAt else { return nil }
        return UsageFormat.remaining(until: resetsAt)
    }

    /// Batches replay-only UI work. Four hundred items must not each scroll, rebuild controls,
    /// publish a remote snapshot, or attach work that the completed turn will immediately fold.
    var isReplaying = false {
        didSet { transcript.suspendsUpdates = isReplaying }
    }

    /// Whether new content may move the view — see `ConversationAutoScroll`.
    var autoScroll = ConversationAutoScroll()

    /// Streaming can ask to follow once per token. One main-queue pass both lands a following
    /// transcript and refreshes the floating return control for a reader who stayed elsewhere.
    var pendingScrollToBottom = false

    /// When the user's hand last touched the scroll view, so a bounds change can be read as
    /// theirs rather than as one of our own scrolls landing.
    var lastUserScrollAt: TimeInterval = 0
    private var hasBracketedLiveScroll = false
    private var userScrollEndedAwaitingElasticSettle = false
    private var legacyUserScrollEndWorkItem: DispatchWorkItem?
    private var viewportSaveWorkItem: DispatchWorkItem?
    private var didRestoreContinuityViewport = false

    struct ExactNavigationMeasurements {
        let geometryNanoseconds: UInt64
        let landingLayoutNanoseconds: UInt64
        let correctionNanoseconds: UInt64
        let visibleTurnsNanoseconds: UInt64
        let totalNanoseconds: UInt64
    }

    #if DEBUG
    struct TerminationMeasurements {
        var viewportNanoseconds: UInt64 = 0
        var permissionsNanoseconds: UInt64 = 0
        var streamNanoseconds: UInt64 = 0
    }

    private(set) var lastTerminationMeasurements = TerminationMeasurements()
    #endif

    /// Which settled turns the reader has opened. Tool and long-message disclosure state lives
    /// on `transcript`; this is the one disclosure only the main conversation has.
    var expandedTurnStarts: Set<Int> = []

    /// Turns already folded, by the row index of their opening user message, so a fold is
    /// never inserted twice.
    var foldedTurnStarts: Set<Int> = []

    /// A turn that ended early, waiting to fold. It stays expanded so the user keeps their
    /// place; the next turn folds it, with the outcome it actually had.
    var pendingFold: (startIndex: Int, outcome: TurnOutcome)?

    /// Turns whose changed-files card was already requested, so a repeated settle event
    /// cannot append twins.
    var changedFilesCardTurns: Set<Int> = []

    /// Messages written while the agent was busy, in the order they will be sent.
    ///
    /// Threading's own, even where the provider keeps one — see `ConversationOutbox`. It lives on
    /// the controller rather than in the transport because the controller outlives a turn and is
    /// what `AgentRuntime` caches, so a queue survives switching panes.
    var outbox = ConversationOutbox()

    /// Between asking the transport to stop and its receipt arriving. Keeps the Stop from being
    /// pressed twice into a transport that is already stopping.
    var isStoppingTurn = false

    /// The waiting messages, between the transcript and the composer.
    lazy var outboxRail: ConversationOutboxRailView = {
        let rail = ConversationOutboxRailView()
        rail.setAccessibilityIdentifier("composer.conversation-reply.queue")
        return rail
    }()

    /// What is waiting for a later moment, above the queue that is waiting only for this turn.
    ///
    /// Two strips rather than one list, and the order is the argument: the queue goes next, the
    /// schedule goes eventually, so the further-off thing sits further from the box. See
    /// `ScheduledMessageStripView` for why they are not one view.
    lazy var scheduledStrip: ScheduledMessageStripView = {
        let strip = ScheduledMessageStripView()
        strip.setAccessibilityIdentifier("composer.conversation-reply.scheduled")
        return strip
    }()

    /// The one-tap way past a spent usage limit, above everything else waiting on this composer.
    ///
    /// Furthest from the box for the same reason the schedule sits above the queue: what is in
    /// the way of the *next* message sits nearest what will send it, and this is a condition of
    /// the conversation rather than something queued in it.
    lazy var limitEscapeStrip = LimitEscapeStripView()

    /// The newest turn's card — the only one whose View diff still describes what Git
    /// Review's Last Turn scope shows. Superseded cards lose the button.
    weak var latestChangedFilesCard: ChangedFilesCardView?

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

    /// The runtime owns participant receipts; the renderer reports only that a new result exists.
    var onAttention: (() -> Void)?

    var isRunning: Bool { stream.isRunning }

    /// Whether this session is the one on screen. Visibility still feeds activity refreshes and
    /// read receipts, but it does not erase an operational state such as a pending permission:
    /// the sidebar must keep saying that the turn is blocked until the request is answered.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            delegate?.conversationDidChangeActivity(self)
        }
    }

    /// What the sidebar shows for this session.
    ///
    /// A request pending inside a turn is the blocked state, not the unread one: the turn has
    /// stopped until it is answered. This remains true while the conversation is visible. The
    /// inline card explains what needs an answer; the sidebar mark answers whether the session
    /// is working or waiting, and showing a spinner there would state the opposite.
    ///
    /// Work left running outranks `idle` for the same reason it does in `SessionActivityTracker`:
    /// a turn that ends on top of a backgrounded shell is not the session finishing, and saying
    /// it is posts "finished its turn" for an answer the agent is still about to give.
    ///
    /// A usage-limit refusal outranks that same work, and for the tracker's reason: a task the
    /// refused turn left running cannot wake an agent whose account has nothing left to spend.
    /// It sits under `dormant` because a dead process is the more useful thing to say — the row
    /// is dimmed, resuming is the offer, and the refusal is still the newest thing in the
    /// transcript when it comes back.
    var activity: SessionActivity {
        if hasPendingPermission {
            return isTurnInFlight ? .awaitingUser : .needsAttention
        }
        if isTurnInFlight { return .working }
        guard stream.isRunning else { return .dormant }
        if usageLimit != nil { return .limitReached }
        return pausedOnOwnWork ? .readyWithBackgroundWork : .idle
    }

    var runtimeSnapshot: SessionRuntimeSnapshot {
        let continuation: SessionContinuationState = if pausedOnOwnWork {
            backgroundWorkInFlight.contains { $0.kind == .delegated } ? .delegated : .standing
        } else {
            .none
        }
        let blocker: SessionRuntimeBlocker = if hasPendingPermission {
            .awaitingUser
        } else if usageLimit != nil {
            .usageLimit
        } else {
            .none
        }
        return SessionRuntimeSnapshot(
            process: stream.isRunning ? .ready : .dormant,
            turn: isTurnInFlight ? .inFlight(.reported) : .none,
            continuation: continuation,
            blocker: blocker,
            activity: activity,
            reportsOwnTurns: true
        )
    }

    // MARK: - Initialization

    init?(
        agentSession: AgentSession,
        project: Project,
        currentSessionProjection: CurrentSessionProjection,
        subagentState: SubagentSessionState? = nil,
        launchPlanProvider: AgentLaunchPlanProvider? = nil,
        customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
            ComponentCustomizationProviderSlot.shared.customization(for: $0)
        }
    ) {
        // Persistence and the composer clamp this today, but the controller is also constructed
        // by runtime coordination and tests. Refuse at the object boundary so a future caller
        // cannot turn an ordinary unsupported session into a process-ending switch case.
        guard agentSession.kind.supportsNativeUI else { return nil }
        let sessionID = agentSession.id
        self.sessionID = sessionID
        self.agentKind = agentSession.kind
        self.project = project
        self.currentSessionProjection = currentSessionProjection
        self.customizationLookup = customizationLookup
        self.timeline = ConversationTimeline(sessionID: sessionID)
        self.subagentState = subagentState
            ?? SubagentSessionState(sessionID: sessionID)
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
            let current = try currentSessionProjection.requireSession(for: sessionID)
            if let launchPlanProvider {
                return try launchPlanProvider(current, project, nil)
            }
            return try AgentLauncher.streamPlan(for: current, in: project)
        }
        let mcpBinding = {
            let decision = MCPBridgeDecision.live(
                settings: AppSettings.shared,
                server: MCPServer.shared,
                bundle: Bundle.main
            )
            return MCPSessionRegistry.binding(for: sessionID, decision: decision)
        }

        // Whether this conversation's CLI belongs in `threading-ptyd`, asked exactly once per
        // launch and asked *here*, because this is the surface that owns the conversation record.
        // A selected host that is unavailable throws into the stream's ordinary launch-failure
        // path; only a deliberate local route supplies nil. The working directory is stated
        // because a daemon started by launchd is somewhere else entirely.
        let hostPlan = { () throws -> PTYHostChildPlan? in
            let identity = TerminalInstanceIdentity.agentSession(sessionID)
            switch PTYHostPolicy.launchRoute(
                for: identity,
                session: currentSessionProjection.session(for: sessionID)
            ) {
            case .local:
                return nil
            case .hosted(let factory):
                return PTYHostChildPlan(
                    identity: PTYHostSessionIdentity(identity),
                    factory: factory
                )
            case .unavailable(let failure):
                throw failure
            }
        }

        switch agentSession.kind {
        case .claude:
            self.stream = ClaudeStreamSession(
                sessionID: sessionID,
                effort: launchEffort,
                subagentTranscriptPlan: {
                    guard let current = currentSessionProjection.session(for: sessionID),
                          let transcriptID = current.resumeState.transcriptID,
                          let transcriptAccount = AgentAccountDiscovery.account(
                              for: current.kind,
                              handle: current.accountHandle
                          ), let root = SessionTranscript.url(
                              sessionID: transcriptID,
                              for: current,
                              in: project,
                              account: transcriptAccount
                          ) else { return nil }
                    return ClaudeSubagentTranscriptPlan(
                        rootThreadID: transcriptID.rawValue,
                        directory: ClaudeTranscript.subagentsDirectory(forRoot: root)
                    )
                },
                hostPlan: hostPlan,
                plan: plan
            )
        case .codex:
            self.stream = CodexStreamSession(
                sessionID: sessionID,
                workingDirectory: agentSession.workingDirectory(in: project),
                configurationProvider: {
                    guard let current = currentSessionProjection.session(for: sessionID)
                    else { return .inherited }
                    let model = current.model
                        ?? AgentModels.defaultModel(for: current.kind, account: account)
                    let effort = AgentModels.effectiveEffort(
                        for: current,
                        model: model,
                        account: account
                    )
                    let serviceTier: String?
                    if let fastMode = AgentLauncher.fastModeAtStartup(for: current) {
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
                hostPlan: hostPlan,
                plan: plan
            )
        case .grok:
            self.stream = ACPStreamSession(
                sessionID: sessionID,
                workingDirectory: agentSession.workingDirectory(in: project),
                profile: .grok,
                mcpBinding: mcpBinding(),
                hostPlan: hostPlan,
                plan: plan
            )
        case .cursor:
            // The second ACP provider, and the whole of what that costs: one profile value.
            // The working directory is the session's own checkout every time, fresh or resumed,
            // because `session/load` accepts any cwd and silently rebinds the live session to
            // whatever it is handed (§10.4) — nothing on the agent side will catch a mismatch.
            self.stream = ACPStreamSession(
                sessionID: sessionID,
                workingDirectory: agentSession.workingDirectory(in: project),
                profile: .cursor,
                mcpBinding: mcpBinding(),
                hostPlan: hostPlan,
                plan: plan
            )
        case .openCode:
            return nil
        }
        super.init(nibName: nil, bundle: nil)
        transcript.surface = self
        if let handoff = agentSession.handoff {
            let canOpenSource = handoff.source.flatMap {
                currentSessionProjection.session(for: $0.sessionID)
            } != nil
            let handoffView = ConversationHandoffView(
                handoff: handoff,
                canOpenSource: canOpenSource,
                onOpenSource: { [weak self] sessionID in
                    guard let self else { return }
                    self.delegate?.conversation(self, didRequestOpenSession: sessionID)
                }
            )
            transcript.append(PresentationItem(
                id: .surface(.handoff),
                content: .surface(.retained(handoffView))
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

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        transcript.activate()
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
        if !continuity.conversationContext.isEmpty {
            promptView.setContextAttachments(continuity.conversationContext)
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
        view.addSubview(jumpToEndButton, positioned: .above, relativeTo: scrollView)
        // Above the scroll view in z, and pinned to its top edge: it overlays the transcript
        // rather than insetting it, because insetting would move the content under an anchored
        // auto-scroll and make arriving output jump by the header's height.
        view.addSubview(stickyStep, positioned: .above, relativeTo: scrollView)
        view.addSubview(promptContentContainer)
        installActivityBeam()
        view.addSubview(statusRow)
        view.addSubview(outboxRail)
        view.addSubview(scheduledStrip)
        view.addSubview(limitEscapeStrip)

        // Install the pane's two alternative transcript top edges before the store can choose
        // between them. Wiring the offer first would activate the ribbon edge and then install
        // the ordinary edge beside it, leaving the transcript with two tops on first display.
        setupConstraints()

        wireOutboxRail()
        wireScheduledStrip()
        wireLimitEscapeStrip()
        promptView.scheduleMenuProvider = { [weak self] in
            self?.scheduleMenuEntries() ?? []
        }
        // The strip is drawn from a store nothing else here writes to — a send delivered by the
        // scheduler, or unscheduled from another window, has to reach this view somehow, and
        // `refreshOutboxRail`'s callers know nothing about it.
        appEvents.observe(ScheduledMessagesDidChange.self) { [weak self] _ in
            self?.refreshScheduledStrip()
        }
        refreshScheduledStrip()
        refreshComposerMode()

        // The preview hangs off the pane, not off the rail: it is wider than the rail and
        // would be clipped inside it, and it has to float over the conversation.
        minimap.attachPreview(to: view)
    }

    /// Wraps only the prompt's visual body. Stream state, permission cards, keyboard routing and
    /// submission stay on this controller and `PromptView`; hooks can add compact controls beside
    /// `.proceed` but cannot replace or overlay it.
    /// Rings the reply box with the ambient agent-activity beam — the same overlay the opening
    /// composer carries, pinned over the container as a sibling so an extension swapping the
    /// composed content cannot take the ring with it. Decorative; swallows no events.
    private func installActivityBeam() {
        view.addSubview(activityBeamView)
        NSLayoutConstraint.activate([
            activityBeamView.leadingAnchor.constraint(equalTo: promptContentContainer.leadingAnchor),
            activityBeamView.trailingAnchor.constraint(equalTo: promptContentContainer.trailingAnchor),
            activityBeamView.topAnchor.constraint(equalTo: promptContentContainer.topAnchor),
            activityBeamView.bottomAnchor.constraint(equalTo: promptContentContainer.bottomAnchor)
        ])
        activityBeamView.update(workload: AgentWorkloadMonitor.shared.workload)
        appEvents.observe(AgentWorkloadDidChange.self) { [weak self] event in
            self?.activityBeamView.update(workload: event.workload)
        }
    }

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
            // Nil is a real answer here — the row marked as the default, or Use Agent's
            // Setting where there is none — so this reads "not a mode" as inherit rather than
            // falling back to one.
            self?.selectPermissionMode(item.representedValue as? AgentPermissionMode)
        }
        effortChip.itemsProvider = { [weak self] in self?.effortItems() ?? [] }
        effortChip.onSelect = { [weak self] item in
            self?.selectEffort(item.representedValue as? String)
        }
        speedChip.itemsProvider = { [weak self] in self?.speedItems() ?? [] }
        speedChip.onSelect = { [weak self] item in
            guard let choice = item.representedValue as? ConversationSpeedChoice else { return }
            self?.selectFastMode(choice.fastMode)
        }

        // No `onSelect`: `CurfewMenu` builds rows that carry their own answer, so the choice is
        // routed by the row rather than decoded back out of a represented value here.
        curfewChip.itemsProvider = { [weak self] in self?.curfewMenuEntries() ?? [] }

        // The split divider owns the pane's width. These labels therefore truncate when all
        // four choices no longer fit, using `ChipView`'s tooltip and hover expansion to reveal
        // the full value. Marking every chip required made their combined fitting width a
        // 590-point minimum on the conversation pane, so a divider dragged past that point
        // sprang back even though the prompt box itself had already yielded.
        for chip in [modelChip, modeChip, effortChip, speedChip, curfewChip] {
            chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // What the reply will be sent with, on the leading side; what it has cost so far, on
        // the trailing side beside the send. The composer places them — see
        // `PromptView.setFooterControls(leading:trailing:)`.
        //
        // Model then mode first, because that is the pair the opening composer leads with and
        // keeping those two slots identical across the two composers is the point. Effort and
        // speed follow in the same order on both.
        promptView.setFooterControls(
            leading: [modelChip, modeChip, effortChip, speedChip, curfewChip],
            trailing: [contextLabel]
        )
        refreshConversationControls()
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Normally pinned to the safe area, which the toolbar insets. A standing limit
            // ribbon swaps this for `transcriptBelowLimitRibbon` instead.
            transcriptBelowPaneTop,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: statusRow.topAnchor,
                constant: -Design.Spacing.small
            ),

            // Directly above the box, below the status line. The two lines answer different
            // questions and belong on different sides of that boundary: the status line is the
            // *turn* talking — the orb, the word, what the last one cost — and reads with the
            // transcript, while the queue is what happens next and belongs to the composer.
            // Put above the status line, the queue sat across a sentence about the past.
            //
            // On the box's column rather than the pane's, so the tray and the box share one edge.
            outboxRail.leadingAnchor.constraint(equalTo: promptContentContainer.leadingAnchor),
            outboxRail.trailingAnchor.constraint(equalTo: promptContentContainer.trailingAnchor),
            outboxRail.bottomAnchor.constraint(
                equalTo: promptContentContainer.topAnchor,
                constant: -Design.Spacing.tight
            ),

            // Above the queue, on the same column: what goes next sits nearest the box, and what
            // goes later sits behind it.
            scheduledStrip.leadingAnchor.constraint(equalTo: promptContentContainer.leadingAnchor),
            scheduledStrip.trailingAnchor.constraint(
                equalTo: promptContentContainer.trailingAnchor
            ),
            scheduledStrip.bottomAnchor.constraint(
                equalTo: outboxRail.topAnchor,
                constant: -Design.Spacing.tight
            ),

            // The refusal is pane chrome, not another retained composer row. Full-width and
            // top-anchored means the ordinary refusal path may hide the reply composer without
            // moving this standing condition into the middle of the empty pane.
            limitEscapeStrip.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            limitEscapeStrip.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            limitEscapeStrip.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor
            ),

            // Both edges pinned, not one: the line is a single truncating label now, and a row
            // free to size itself to its content is what let the controls it used to carry
            // cluster against the leading edge instead of reaching the pane's trailing one.
            //
            // Inset from the *box* rather than from the pane, because the box is no longer the
            // pane's width: the narration starts on the same vertical as the text under it, and
            // both sit on the transcript's column. Aligned by ink rather than by frame.
            statusRow.leadingAnchor.constraint(
                equalTo: promptContentContainer.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            statusRow.trailingAnchor.constraint(
                equalTo: promptContentContainer.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            statusRow.bottomAnchor.constraint(
                equalTo: promptContentContainer.topAnchor,
                constant: -Design.Spacing.small
            ),

            // The reply box stands on a *stated* column, the way the transcript's rows do: the
            // cap and the insets are required, and `updateComposerColumnWidth` states the width
            // the pane's current size leaves for it. Deliberately not an equality to the pane's
            // own width — see `ConversationDefaults.statedColumnPriority` for the two ways
            // that constraint fails, one of them by resizing the pane.
            promptContentContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            promptContentContainer.widthAnchor.constraint(
                lessThanOrEqualToConstant: ConversationDefaults.composerWidth
            ),
            composerColumnWidth,
            promptContentContainer.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            promptContentContainer.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
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
            minimap.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            // Pane-wide. The band spans the pane and puts its *content* on the column itself
            // (see `ConversationStickyStepView`), which is the difference between aligning the
            // box and aligning the ink — held to the column, the strip read as a transcript row
            // that had drifted to the top, and its first glyph sat 15pt inside every other line.
            stickyStep.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stickyStep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyStep.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            jumpToEndButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpToEndButton.bottomAnchor.constraint(
                equalTo: scrollView.bottomAnchor,
                constant: -Design.Spacing.inset
            )
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
                guard let self, let session = self.currentSession else { return }
                AgentWorkTraceStore.shared.record(
                    providerEvent: event,
                    projectID: self.project.id,
                    session: session,
                    rootPath: self.project.folderPath
                )
                ExecutionAuditStore.shared.record(
                    providerEvent: event,
                    sessionID: self.sessionID,
                    provider: self.agentKind
                )
                // The tool call is exactly attributed but blind to shell edits; the turn's tree
                // pair is complete but attributes nothing. Recording what this chat's edit tools
                // named lets Git Review cross the two. Only a live turn reaches here — the store
                // ignores claims with no checkpoint in flight.
                if let claimed = AgentFileActivityClassifier.claimedEditPaths(in: event) {
                    GitTurnBaselineStore.shared.recordClaimedEdits(
                        sessionID: self.sessionID,
                        paths: claimed
                    )
                }
            }
        }

        stream.onEvent = { [weak self] event in
            guard let self, let session = self.currentSession else { return }
            AgentWorkTraceStore.shared.record(
                streamEvent: event,
                projectID: self.project.id,
                session: session,
                rootPath: self.project.folderPath
            )
            ExecutionAuditStore.shared.record(
                streamEvent: event,
                sessionID: self.sessionID,
                provider: self.agentKind
            )
            // The same claims through the transport that reports tool calls in its stream rather
            // than through a provider callback. Recording a path twice is idempotent.
            if let claimed = AgentFileActivityClassifier.claimedEditPaths(in: event) {
                GitTurnBaselineStore.shared.recordClaimedEdits(
                    sessionID: self.sessionID,
                    paths: claimed
                )
            }
            self.handle(event)
        }
        stream.onExit = { [weak self] status in self?.handleExit(status) }
        stream.onLaunchFailure = { [weak self] error in self?.handleLaunchFailure(error) }
        stream.onInteractionAvailabilityChange = { [weak self] in
            guard let self else { return }
            self.submitPendingInitialPromptIfReady()
            self.refreshConversationControls()
            // Availability is the one signal every transport has for "the turn ended", however
            // it ended, so it is where the queue drains rather than off a terminal event some
            // provider might not send. Mode first: `flushOutboxIfReady` no-ops unless the
            // transport is genuinely ready, and the composer must not sit showing a Stop for a
            // turn that is already over.
            self.refreshComposerMode()
            self.flushOutboxIfReady()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }

        if let reporting = stream as? MessageLifecycleReportingConversation {
            reporting.onMessageLifecycle = { [weak self] id, state in
                self?.applyMessageLifecycle(id, state)
            }
        }
        if let capabilities = stream as? ComposerCapabilityProviding {
            capabilities.onComposerCapabilitiesChange = { [weak self] in
                guard let self else { return }
                self.refreshComposerCapabilitySurfaces()
                self.submitPendingInitialPromptIfReady()
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

        // The event seam timestamps every wheel and momentum event before its bounds change.
        // AppKit brackets gesture scrolls and scroller tracking with live-scroll notifications;
        // legacy mice are explicitly not guaranteed that pair, so their events use the existing
        // short attribution window as an end fallback. Programmatic scrolls pass through neither.
        scrollView.onUserScroll = { [weak self] in
            self?.userScrollEventArrived()
        }
        appEvents.observe(
            NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        ) { [weak self] in
            self?.userScrollWillStart()
        }
        appEvents.observe(NSScrollView.didLiveScrollNotification, object: scrollView) {
            [weak self] in
            self?.userScrollEventArrived()
        }
        appEvents.observe(NSScrollView.didEndLiveScrollNotification, object: scrollView) {
            [weak self] in
            self?.userScrollDidEnd()
        }
    }

    private func userScrollWillStart() {
        legacyUserScrollEndWorkItem?.cancel()
        legacyUserScrollEndWorkItem = nil
        hasBracketedLiveScroll = true
        beginUserScroll()
    }

    private func userScrollEventArrived() {
        lastUserScrollAt = ProcessInfo.processInfo.systemUptime
        guard !hasBracketedLiveScroll else { return }
        beginUserScroll()

        // AppKit documents legacy mice as the exception to its start/end notification pair.
        // Treat quiet after their last event as the end, while bracketed gestures always wait
        // for AppKit's authoritative did-end notification.
        legacyUserScrollEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasBracketedLiveScroll else { return }
            self.legacyUserScrollEndWorkItem = nil
            self.finishUserScrollWhenSettled()
        }
        legacyUserScrollEndWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ConversationDefaults.gestureAttribution,
            execute: work
        )
    }

    private func beginUserScroll() {
        lastUserScrollAt = ProcessInfo.processInfo.systemUptime
        userScrollEndedAwaitingElasticSettle = false
        autoScroll.noteUserScrollBegan()
    }

    private func userScrollDidEnd() {
        legacyUserScrollEndWorkItem?.cancel()
        legacyUserScrollEndWorkItem = nil
        hasBracketedLiveScroll = false
        lastUserScrollAt = ProcessInfo.processInfo.systemUptime
        finishUserScrollWhenSettled()
    }

    private func finishUserScrollWhenSettled() {
        guard autoScroll.isUserScrolling else { return }
        guard !isConversationRubberBanding else {
            userScrollEndedAwaitingElasticSettle = true
            return
        }

        userScrollEndedAwaitingElasticSettle = false
        let shouldCatchUp = autoScroll.noteUserScrollEnded()
        scheduleConversationViewportSave()
        if shouldCatchUp {
            scrollToBottom()
        }
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
        if userScrollEndedAwaitingElasticSettle {
            finishUserScrollWhenSettled()
        }
        updateVisibleTurns()
        updateStickyStep()
        updateScrollToEndControl()
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
        updateScrollToEndControl()
        return true
    }

    // MARK: - Minimap

    override func viewDidLayout() {
        super.viewDidLayout()
        transcript.layoutColumn()
        updateComposerColumnWidth()
        updateMinimapWidth()
        updateVisibleTurns()
        // A layout pass can move rows under a stationary viewport, so the header is re-resolved
        // here as well as on scroll; the cached top row makes the common case a comparison.
        updateStickyStep()
        updateScrollToEndControl()
    }

    /// States the reply box's column for the pane's current width: the readable measure where
    /// the pane affords it, whatever remains inside the insets where it does not. A constant the
    /// layout has already made satisfiable, so the box follows the pane and can never resize
    /// it — see `ConversationDefaults.statedColumnPriority`.
    private func updateComposerColumnWidth() {
        let width = min(
            ConversationDefaults.composerWidth,
            view.bounds.width - Design.Spacing.inset * 2
        )
        guard width > 0, abs(composerColumnWidth.constant - width) > 0.5 else { return }
        composerColumnWidth.constant = width
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

    // MARK: - Sticky Step

    /// Names the tool call the top of the viewport currently sits inside, or hides.
    ///
    /// **Chrome at the top means hide.** A divider, a fold, a permission card or the streaming
    /// placeholder at the top of the pane is a *boundary*, and a boundary is already telling the
    /// reader where they are — naming a step over it would be a second, quieter answer to a
    /// question that had already been answered louder.
    func updateStickyStep() {
        guard isViewLoaded else { return }

        let visibleRows = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visibleRows.location != NSNotFound,
              presentationItems.indices.contains(visibleRows.location) else {
            setStickyStep(nil)
            return
        }

        // Resolved only when the top row changes. Scrolling inside one tall row fires this
        // continuously, and the walk back through the turn is the one part worth not repeating.
        let topRow = visibleRows.location
        guard topRow != stickyStepTopRow else { return }
        stickyStepTopRow = topRow

        guard let timelineIndex = presentationItems[topRow].content.timelineIndex else {
            setStickyStep(nil)
            return
        }
        setStickyStep(timeline.currentStep(atOrBefore: timelineIndex))
    }

    private func setStickyStep(_ rowIndex: Int?) {
        guard rowIndex != stickyStepRow else { return }
        stickyStepRow = rowIndex

        if let rowIndex,
           timeline.rows.indices.contains(rowIndex),
           case .toolCall(let call) = timeline.rows[rowIndex] {
            stickyStep.show(tool: call.tool, subject: call.summary, atRow: rowIndex)
        } else {
            stickyStepRow = nil
        }

        let wanted: CGFloat = stickyStepRow == nil ? 0 : 1
        guard stickyStep.alphaValue != wanted else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            stickyStep.animator().alphaValue = wanted
        }
    }

    /// Whether the header is currently naming a step, and which. Read by tests, which cannot ask
    /// an alpha-faded view what it means.
    var stickyStepRowIndex: Int? { stickyStepRow }

    /// How far above a jump target to stop.
    ///
    /// The usual gap, plus the header's own height when landing there will pin one — otherwise
    /// the row a reader deliberately navigated to is delivered underneath the strip that names
    /// it, which is the one place the overlay would actively cost them something.
    private func landingClearance(for index: Int) -> CGFloat {
        guard timeline.currentStep(atOrBefore: index) != nil else { return Design.Spacing.large }
        return Design.Spacing.large + stickyStep.fittingSize.height
    }

    // MARK: - Turn and Step Navigation

    /// The timeline row at the top of the viewport, which every jump is measured from.
    private var topVisibleTimelineIndex: Int? {
        let visibleRows = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visibleRows.location != NSNotFound else { return nil }

        for row in visibleRows.location..<(visibleRows.location + max(visibleRows.length, 1)) {
            guard presentationItems.indices.contains(row) else { break }
            if let index = presentationItems[row].content.timelineIndex { return index }
        }
        return nil
    }

    /// Moves to the exchange before or after the one at the top of the pane.
    ///
    /// Relative to the viewport rather than to a selection, because the conversation has no
    /// selection: what the reader is looking at is the only thing "current" can mean here.
    @discardableResult
    func goToAdjacentTurn(forward: Bool) -> Bool {
        let starts = timeline.turns.map(\.rowIndex)
        guard !starts.isEmpty else { return false }
        let top = topVisibleTimelineIndex ?? 0

        let target: Int?
        if forward {
            target = starts.first { $0 > top }
        } else {
            // Strictly before the *turn's own opening row*, so a reader partway down a turn goes
            // to that turn's top first rather than skipping over it to the previous one.
            let enclosing = starts.last { $0 <= top }
            target = enclosing == top ? starts.last { $0 < top } : enclosing
        }

        guard let target else { return false }
        scrollToTimelineRow(target, animated: true)
        return true
    }

    /// Moves to the tool call before or after the top of the pane.
    ///
    /// Walked over the **presentation** rather than the timeline, which makes a settled turn's
    /// folded work skip while a compact live tool group can expand at an exact target.
    @discardableResult
    func goToAdjacentStep(forward: Bool) -> Bool {
        let top = topVisibleTimelineIndex
        var target: Int?

        for item in forward ? presentationItems : presentationItems.reversed() {
            let toolIndices: [Int]
            switch item.content {
            case .timeline(let index):
                guard timeline.rows.indices.contains(index),
                      case .toolCall = timeline.rows[index] else { continue }
                toolIndices = [index]
            case .toolFold(let indices):
                toolIndices = forward ? indices : Array(indices.reversed())
            case .markdown, .divider, .surface:
                continue
            }

            for index in toolIndices {
                guard let top else { target = index; break }
                if forward ? index > top : index < top { target = index; break }
            }
            if target != nil { break }
        }

        guard let target else { return false }
        scrollToTimelineRow(target, animated: true)
        return true
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
        transcript.revealToolGroup(containing: index)
        guard let tableRow = presentationRow(forTimelineIndex: index) else { return nil }

        // The user deliberately went somewhere; only their own gesture re-pins.
        autoScroll.noteJumpedToRow()

        let started = DispatchTime.now().uptimeNanoseconds
        let geometryStarted = DispatchTime.now().uptimeNanoseconds
        let target = max(0, tableView.rect(ofRow: tableRow).minY - landingClearance(for: index))
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
            tableView.rect(ofRow: correctedRow).minY - landingClearance(for: index)
        )
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: correctedTarget))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let correctionEnded = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        updateVisibleTurns()
        updateStickyStep()
        let visibleTurnsEnded = measuring ? DispatchTime.now().uptimeNanoseconds : 0
        return (
            correctionNanoseconds: measuring ? correctionEnded - correctionStarted : 0,
            visibleTurnsNanoseconds: measuring ? visibleTurnsEnded - correctionEnded : 0
        )
    }

    // MARK: - Public Methods

    func launch() {
        guard !stream.isRunning else { return }

        // The native surface's half of the same line `AgentSessionViewController.launch` holds:
        // recovery starts no agent by any route, and this one would also write `hasLaunched`
        // into a store a recovery launch is only reading.
        guard !RecoveryMode.isActive else {
            RecoveryMode.refuse("a native conversation launch")
            return
        }

        guard let session = currentSession else {
            appendNotice("Could not start the conversation: the session no longer exists.", kind: .error)
            return
        }

        let launchRecord = ProjectStore.shared.update(sessionID: sessionID) {
            $0.hasLaunched = true
        }
        guard launchRecord.succeeded else {
            appendNotice(
                "Could not start the conversation: the project data could not be saved.",
                kind: .error
            )
            return
        }

        // Replay before starting, so past turns cannot interleave with new ones. The read is
        // off the main thread, and costs less than the CLI takes to boot.
        apply(.status(.loading))
        TranscriptReplay.load(for: session, in: project) { [weak self] events, isTruncated in
            guard let self else { return }

            AgentWorkTraceStore.shared.seedReplayIfEmpty(
                events,
                projectID: self.project.id,
                session: session,
                rootPath: self.project.folderPath
            )

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

    func terminate(preservingViewport: Bool = true) {
        // Runtime ownership has an explicit end edge (`discard` and `terminateAll` both come
        // through here), so actor-isolated UI state is settled there rather than from `deinit`.
        // Swift 6 correctly treats a class deinitializer as nonisolated: the previous workaround
        // marked the timer `nonisolated(unsafe)` and still raced the pending DispatchWorkItem.
        // Saving before the stream is stopped also preserves the last viewport if termination
        // synchronously changes presentation state.
        #if DEBUG
        let viewportStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        if preservingViewport {
            saveConversationViewport()
        } else {
            viewportSaveWorkItem?.cancel()
            viewportSaveWorkItem = nil
        }
        workingStatusTimer?.invalidate()
        workingStatusTimer = nil
        #if DEBUG
        let viewportEnded = DispatchTime.now().uptimeNanoseconds
        #endif

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

        #if DEBUG
        let permissionsEnded = DispatchTime.now().uptimeNanoseconds
        #endif
        stream.terminate()
        #if DEBUG
        let streamEnded = DispatchTime.now().uptimeNanoseconds
        lastTerminationMeasurements = TerminationMeasurements(
            viewportNanoseconds: viewportEnded - viewportStarted,
            permissionsNanoseconds: permissionsEnded - viewportEnded,
            streamNanoseconds: streamEnded - permissionsEnded
        )
        #endif
    }

    func focusPrompt() {
        promptView.focus()
    }

    /// Sends the composer's opening message as the conversation's first turn.
    ///
    /// A streaming session takes no positional prompt argument, so what the terminal path
    /// passes on the command line is sent down the pipe here. Command-shaped text waits for the
    /// provider's opening catalog, because sending `/review` or `/compact` as ordinary text
    /// during that handshake would bypass the same semantic dispatch and native safety policy
    /// used by every later composer submission. Ordinary opening prose remains immediate.
    func sendInitialPrompt(_ text: String) {
        if ComposerCapabilityResolver.hasLeadingTrigger(in: text),
           let capabilities = stream as? ComposerCapabilityProviding,
           !capabilities.isComposerCapabilityCatalogReady {
            pendingInitialPrompt = text
            return
        }
        _ = submit(text)
    }

    private func submitPendingInitialPromptIfReady() {
        guard let text = pendingInitialPrompt else { return }
        guard stream.isRunning else { return }
        if let capabilities = stream as? ComposerCapabilityProviding,
           !capabilities.isComposerCapabilityCatalogReady { return }
        pendingInitialPrompt = nil
        if !submit(text) {
            pendingInitialPrompt = text
        }
    }

    /// A catalog that never arrives must not take the opening message with it. Put it back in
    /// the durable composer before the ended surface hides that composer. If somebody managed to
    /// start another draft while the process was booting, the command stays first so its leading
    /// trigger keeps its meaning and neither piece of user-authored text is overwritten.
    private func restorePendingInitialPromptToComposer() {
        guard let opening = pendingInitialPrompt else { return }
        pendingInitialPrompt = nil

        let currentDraft = promptView.stringValue
        if currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptView.stringValue = opening
        } else if currentDraft != opening {
            promptView.stringValue = "\(opening)\n\n\(currentDraft)"
        }
        SessionContinuityStore.shared.setConversationDraft(
            promptView.stringValue,
            context: promptView.contextAttachments,
            for: sessionID
        )
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
    func sendAppPrompt(
        _ text: String,
        context: [ConversationContextAttachment] = [],
        attachmentIDs: [String] = []
    ) -> Bool {
        submit(text, context: context, attachmentIDs: attachmentIDs)
    }

    /// Provider-neutral rows for mobile/web conversation clients. Tool inputs have already
    /// been reduced to their safe one-line summary; raw provider arguments never cross this
    /// boundary accidentally.
    var remoteProjection: RemoteConversationProjection {
        RemoteConversationProjection(
            snapshot: RemoteConversationSnapshotDTO(
                rows: remoteRowProjection.rows,
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
                        kind: RemoteComposerCapabilityKind(rawValue: capability.kind.rawValue),
                        isAvailableInSkillCatalog: capability.isAvailableInSkillCatalog,
                        trigger: RemoteComposerCapabilityTrigger(
                            rawValue: capability.trigger.rawValue
                        ),
                        presentation: RemoteComposerCapabilityPresentation(
                            rawValue: capability.presentation.rawValue
                        ),
                        isEnabled: capability.isEnabled,
                        unavailableReason: capability.unavailableReason
                    )
                },
                permission: activePermissionCard?.remoteRequest
            ),
            rowsRevision: remoteRowProjection.rowsRevision
        )
    }

    var remoteSnapshot: RemoteConversationSnapshotDTO {
        remoteProjection.snapshot
    }

    private func refreshComposerCapabilitySurfaces() {
        if isViewLoaded {
            promptView.composerCapabilities = composerCapabilities
        }
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
    }

    /// Resolves only the permission card that is currently visible. Queued requests remain
    /// ordered and receive their own fresh id when promoted.
    func resolveRemotePermission(id: String, decision: RemotePermissionDecision) -> Bool {
        activePermissionCard?.resolveRemote(id: id, decision: decision) ?? false
    }

    /// Manager decisions share the active-card identity gate but retain distinct audit wording.
    func resolveManagerPermission(id: String, decision: ControlPermissionDecision) -> Bool {
        activePermissionCard?.resolveManager(id: id, decision: decision) ?? false
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
        SessionContinuityStore.shared.setConversationDraft(
            promptView.stringValue,
            context: promptView.contextAttachments,
            for: sessionID
        )
    }

    /// Sidebar sessions dropped on the composer, staged as reference receipts.
    ///
    /// Briefed for *this* session (`SessionReferenceHandoff`): the same row says "reach it with
    /// send_to_session" here and "it is in another project" in a composer elsewhere. Through
    /// `stageContextAttachment`, so a drop obeys the same write gate as every other door. The
    /// caret then goes to the end of the box — a drop is a deliberate act on the composer, and
    /// what follows a dropped reference is the sentence about it.
    func stageSessionReferences(_ sessionIDs: [SessionID]) {
        let attachments = SessionReferenceHandoff.contextAttachments(
            referencing: sessionIDs,
            readBy: sessionID
        )
        guard !attachments.isEmpty else { return }
        for attachment in attachments {
            stageContextAttachment(attachment)
        }
        promptView.focusAtEnd()
    }

    /// Stages the context and hands the turn over immediately — the ⌘Return half of the comment
    /// sheet, and the pane menus' **Send** entry.
    ///
    /// Sent *with* whatever is already in the box rather than instead of it: a person who typed
    /// half a sentence and then commented on the file it is about meant one turn, and dropping
    /// their prose to send only the comment would be the composer discarding work.
    func sendContextAttachment(_ attachment: ConversationContextAttachment) {
        guard RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) else {
            refreshInputControl()
            return
        }
        promptView.addContextAttachment(attachment)
        _ = submit(promptView.stringValue, context: promptView.contextAttachments)
    }

    @discardableResult
    func removeContextAttachment(id: UUID) -> Bool {
        guard RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) else {
            refreshInputControl()
            return false
        }
        let removed = promptView.removeContextAttachment(id: id)
        if removed {
            SessionContinuityStore.shared.setConversationDraft(
                promptView.stringValue,
                context: promptView.contextAttachments,
                for: sessionID
            )
        }
        return removed
    }

    func requestComment(
        on attachment: ConversationContextAttachment,
        preview: CodeContextPreview? = nil
    ) {
        ContextCommentAlert.request(on: attachment, preview: preview, for: sessionID)
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
            toolView.onRequestContextComment = { [weak self] attachment, preview in
                self?.requestComment(on: attachment, preview: preview)
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
        messageView.isContextOpenable = { [weak self] attachment in
            guard let self else { return false }
            return SessionContinuityStore.shared.imageAnnotationDocument(
                forContextAttachmentID: attachment.id,
                in: self.sessionID
            ) != nil
        }
        messageView.onOpenContext = { [weak self, weak messageView] attachment in
            guard let self, let messageView else { return }
            self.openImageAnnotations(for: attachment, from: messageView)
        }
    }

    private func openImageAnnotations(
        for attachment: ConversationContextAttachment,
        from source: NSView
    ) {
        guard let document = SessionContinuityStore.shared.imageAnnotationDocument(
            forContextAttachmentID: attachment.id,
            in: sessionID
        ) else { return }
        let stored = document.sourceAttachmentID.flatMap {
            SessionAttachmentStore.shared.attachment(for: sessionID, id: $0)
        }
        let url = stored?.url ?? URL(fileURLWithPath: document.sourcePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = MediaInspectorPresenter.present(
            MediaInspectorItem(
                url: url,
                title: document.title,
                content: .image,
                annotationAssetID: stored?.id
            ),
            from: source,
            annotationHost: ChatImageAnnotationHost(sessionID: sessionID)
        )
    }

    private func projectRelativePath(for path: String) -> String {
        guard let session = currentSession else {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let root = URL(
            fileURLWithPath: session.workingDirectory(in: project),
            isDirectory: true
        )
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
        authorization: RemoteAuthorization? = nil,
        workspaceFilesValidated: Bool = false,
        attachmentIDs: [String] = []
    ) -> Bool {
        guard currentSession != nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = ConversationContextPolicy.normalized(context)
        guard !trimmed.isEmpty || !context.isEmpty else { return false }
        guard !isPreparingTurn else { return false }
        if authorization == nil,
           !RemoteSessionMirrorRegistry.shared.ownerCanWrite(to: sessionID) {
            refreshInputControl()
            return false
        }

        let workspaceFiles = workspaceReferences(in: context)
        if !workspaceFilesValidated, !workspaceFiles.isEmpty {
            isPreparingTurn = true
            refreshInputControl()
            workspaceFilePlane.validate(
                sessionID: sessionID,
                references: workspaceFiles
            ) { [weak self] result in
                guard let self else { return }
                self.isPreparingTurn = false
                switch result {
                case .success:
                    _ = self.submit(
                        text,
                        context: context,
                        authorization: authorization,
                        workspaceFilesValidated: true,
                        attachmentIDs: attachmentIDs
                    )
                case .failure(let failure):
                    self.presentWorkspaceFileFailure(failure)
                    self.refreshInputControl()
                    RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
                }
            }
            return true
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

        // Native `/usage` is navigation, not an agent turn. A paired participant cannot make
        // the owner's Mac leave its current surface, so the remote route refuses it while the
        // phone keeps its own dedicated Usage screen.
        if invocation?.capability.id == ConversationComposerCommands.usageID {
            guard authorization == nil else { return false }
            promptView.clear()
            SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
            let accountID = currentSession.map {
                AccountID(provider: $0.kind, handle: $0.accountHandle)
            }
            delegate?.conversation(self, didRequestUsageFor: accountID)
            return true
        }

        if let invocation, !invocation.capability.isEnabled {
            let reason = invocation.capability.unavailableReason
                ?? L10n.string("This command is not available in native Chat")
            apply(timeline.appendNotice(reason, kind: .error))
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return false
        }

        // The agent is busy. This used to `return false` and the Return did nothing visible —
        // the text stayed in the box and nothing said whether it had been taken. It queues now,
        // which is the whole point of the outbox.
        guard stream.canSend else {
            guard authorization == nil else { return false }
            return enqueue(
                ConversationPrompt(text: trimmed, context: context),
                attachmentIDs: attachmentIDs
            )
        }

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
                preservesLeadingSlash: agentKind.supports(.slashCommandPrefix)
            )
        } else {
            RemoteNotificationService.shared.recordOwnerInteraction(sessionID: sessionID)
            transportedText = trimmed
        }

        let transportedPrompt = ConversationPrompt(text: transportedText, context: context)

        let messageID = ConversationMessageID()
        SessionAttachmentStore.shared.associate(
            attachmentIDs: attachmentIDs,
            withTurnID: messageID.wireValue,
            for: sessionID
        )
        isPreparingTurn = true
        refreshInputControl()
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)

        NativeGitTurnAdmission.admit(
            sessionID: sessionID,
            userTurnID: messageID.wireValue,
            transport: { [weak self] _ in
                guard let self else { return false }
                return self.sendPreparedTurn(
                    localPrompt: localPrompt,
                    transportedPrompt: transportedPrompt,
                    invocation: invocation,
                    sourceText: trimmed,
                    messageID: messageID
                )
            }
        ) { [weak self] _, _ in
            guard let self else { return }
            self.isPreparingTurn = false
            self.refreshInputControl()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
        }
        return true
    }

    private func workspaceReferences(
        in context: [ConversationContextAttachment]
    ) -> [WorkspaceFileReference] {
        context.compactMap { attachment in
            guard attachment.source == .workspaceFile,
                  let path = attachment.locator,
                  !path.isEmpty else { return nil }
            return WorkspaceFileReference(path: path)
        }
    }

    func validateWorkspaceFiles(
        in prompt: ConversationPrompt,
        completion: @escaping WorkspaceFileSearchPlane.ValidationCompletion
    ) {
        let references = workspaceReferences(in: prompt.context)
        guard !references.isEmpty else {
            completion(.success(()))
            return
        }
        workspaceFilePlane.validate(
            sessionID: sessionID,
            references: references,
            completion: completion
        )
    }

    private func steerValidatingWorkspaceFiles(
        _ prompt: ConversationPrompt,
        attachmentIDs: [String] = []
    ) {
        let references = workspaceReferences(in: prompt.context)
        guard !references.isEmpty else {
            steer(prompt, attachmentIDs: attachmentIDs)
            return
        }
        guard !isPreparingTurn else { return }
        isPreparingTurn = true
        refreshInputControl()
        validateWorkspaceFiles(in: prompt) { [weak self] result in
            guard let self else { return }
            self.isPreparingTurn = false
            switch result {
            case .success:
                self.steer(prompt, attachmentIDs: attachmentIDs)
            case .failure(let failure):
                self.presentWorkspaceFileFailure(failure)
                self.refreshInputControl()
                RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
            }
        }
    }

    func presentWorkspaceFileFailure(_ failure: WorkspaceFileSearchFailure) {
        let message: String
        switch failure {
        case .fileUnavailable(let path):
            message = L10n.format(
                "The workspace file “%@” was moved, deleted, or is outside this checkout. Remove it and add the current file before sending.",
                path
            )
        case .indexTooLarge(let limit):
            message = L10n.format(
                "This checkout has more than %lld visible files, so workspace mentions are unavailable.",
                Int64(limit)
            )
        case .sessionUnavailable, .checkoutUnavailable:
            message = L10n.string("The session’s execution checkout is no longer available.")
        case .repositoryUnavailable:
            message = L10n.string("Threading could not refresh this checkout’s visible files.")
        }
        apply(timeline.appendNotice(message, kind: .error))
    }

    /// Releases one accepted prompt after its immutable turn-start tree has been recorded.
    private func sendPreparedTurn(
        localPrompt: ConversationPrompt,
        transportedPrompt: ConversationPrompt,
        invocation: ComposerInvocation?,
        sourceText: String,
        messageID: ConversationMessageID
    ) -> Bool {
        let sent: Bool
        if let invocation,
           let capabilityStream = stream as? ComposerCapabilityProviding {
            // Provider actions are syntax-bearing protocol messages. Do not prepend the shared
            // chat participant envelope or reconstruct their arguments; the resolver has kept
            // the exact trimmed source for this purpose.
            sent = capabilityStream.send(invocation, identifiedBy: messageID)
        } else {
            sent = stream.send(transportedPrompt, identifiedBy: messageID)
        }
        guard sent else {
            refreshInputControl()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
            return false
        }
        // Native transports do not emit the hook edge terminal sessions use for this durable
        // timestamp. The accepted send is their authoritative submitted-turn edge.
        ProjectStore.shared.noteTurnStarted(sessionID: sessionID)
        refreshConversationControls()
        runProgress = nil

        if invocation?.capability.presentation == .command {
            apply(timeline.appendNotice(sourceText, kind: .muted))
            apply(.status(.working(word: workingWords.next())))
        } else {
            recordSentTurn(localPrompt)
        }

        promptView.clear()
        SessionContinuityStore.shared.setConversationDraft("", for: sessionID)
        RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        return true
    }

    /// Draws a user turn that has just gone over the wire.
    ///
    /// Shared by the three ways a message reaches a provider — typed and sent, drained from the
    /// queue, or steered into a running turn — because all three owe the transcript the same
    /// thing. Before this was one place, a queued message reached the agent without ever being
    /// echoed, and the conversation showed an answer to a question nobody could see.
    func recordSentTurn(_ prompt: ConversationPrompt) {
        refreshConversationControls()
        runProgress = nil

        // Echoed locally as it is sent. The stream never reports a live user turn back —
        // `.userMessage` exists only for replay — so producing it here is what draws it
        // once. Anchoring is decided before the echo lands so its `addRow` cannot yank the
        // view to the bottom first.
        autoScroll.noteMessageSent()
        apply(timeline.appendUserMessage(prompt.userMessage))
        anchorSentMessage(at: timeline.rows.count - 1)

        // Drawn here, which is the moment the turn starts and the only place the status enters
        // `working` — so the word is fixed for the whole wait and a new one arrives with the
        // next turn.
        apply(.status(.working(word: workingWords.next())))
    }

    private var nativeStatusText: String {
        let model = activeModel.map { AgentModels.displayName(for: $0, account: account) }
            ?? ConversationControlDefaults.defaultModel
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
            agentKind.displayName,
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
    func anchorSentMessage(at index: Int) {
        guard autoScroll.mode == .anchored else { return }

        // Land once immediately. Deferring the first pass leaves a newly inserted bubble below
        // the viewport until the main queue gets back to us, even though the state machine has
        // already entered anchored mode.
        landSentMessageAnchor(at: index)

        // Scrolling materializes and measures the rows around the destination. Correct once on
        // the next turn, against that updated document height, rather than looping on AppKit's
        // layout as an end condition.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoScroll.mode == .anchored else { return }
            self.landSentMessageAnchor(at: index)
            self.updateScrollToEndControl()
        }
    }

    private func landSentMessageAnchor(at index: Int) {
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        guard let tableRow = presentationRow(forTimelineIndex: index) else { return }

        // A raw clip-view offset is clamped to the table's current estimated document height.
        // Reveal through NSTableView first so it materializes the destination and guarantees the
        // bubble is visible; the measured pass below can then place it toward the top.
        tableView.scrollRowToVisible(tableRow)
        tableView.layoutSubtreeIfNeeded()
        let target = max(0, tableView.rect(ofRow: tableRow).minY - Design.Spacing.large)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Events

    /// Folds an event into the timeline, then brings the views in line with what changed.
    ///
    /// The controller decides nothing about content here: what a row is, whether a tool result
    /// belongs to an earlier call, and when a streamed placeholder is thrown away are all
    /// `ConversationTimeline`'s, and tested there.
    private func handle(_ event: StreamEvent) {
        if !isReplaying, case .turnFinished = event {
            isPreparingTurn = true
            refreshInputControl()
            GitTurnBaselineStore.shared.finishTurn(sessionID: sessionID) { [weak self] checkpoint in
                guard let self else { return }
                self.isPreparingTurn = false
                self.settlingGitCheckpointID = checkpoint?.id
                self.applyHandledEvent(event)
                self.settlingGitCheckpointID = nil
                self.refreshComposerMode()
                self.flushOutboxIfReady()
                self.refreshInputControl()
                RemoteSessionMirrorRegistry.shared.sessionConversationChanged(self.sessionID)
            }
            return
        }
        applyHandledEvent(event)
    }

    private func applyHandledEvent(_ event: StreamEvent) {
        recordAgentActivity(in: event)
        if case .initialised(_, let model) = event, let model {
            reportedModel = model
            // What the alias this session launched as resolved to, remembered for the login so
            // the picker's "Opus" row can say which Opus. The store keeps aliases only, so a
            // session pinned to an id that names its own version teaches it nothing.
            if let account,
               let launched = currentSession?.model ?? AgentModels.defaultModel(
                for: currentSession?.kind ?? agentKind,
                account: account
               ) {
                ModelAliasResolutionStore.shared.record(
                    model,
                    forLaunched: launched,
                    in: account.id
                )
            }
            if currentSession?.isCrossProviderContinuation == true {
                ProjectStore.shared.update(sessionID: sessionID) {
                    $0.recordHandoffTargetModel(model)
                }
            }
            // Only an unpinned session speaks for the account: one running an explicit choice
            // reports that choice, which says nothing about what "no model chosen" resolves to.
            if currentSession?.model == nil, let account {
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
        // Only a *failed* turn is asked. A provider's refusal arrives through the same channel
        // as a network fault and as the user's own Stop, and only the outcome tells them apart
        // — matching the words alone would stop a session for having written about limits.
        if case .turnFinished(let text, let outcome, _) = event {
            if !isReplaying {
                CompletedTurnSnapshotStore.shared.captureCompletedTurn(
                    sessionID: sessionID,
                    finalAssistantText: text,
                    isReliable: outcome == .completed
                )
            }
            if outcome == .failed {
                if !isReplaying {
                    SessionSnoozeCenter.shared.record(.failed, for: sessionID)
                }
                // Replay still restores the existing usage-limit state; it just must not turn
                // that historical failure into a fresh Snooze wake edge.
                usageLimit = UsageLimitStop.recognised(in: text)
                if let usageLimit {
                    EventLog.shared.record(.limitRecovery, "Native turn refused for a usage limit", [
                        "session": sessionID.uuidString,
                        "message": usageLimit.message,
                        "resetHint": usageLimit.resetHint ?? ""
                    ])
                    // The offer over the composer. Nothing recovers a rendered conversation
                    // automatically — `LimitRecoveryPolicy` acts on terminal sessions only — so
                    // this surface is exactly the `flagOnly` case the escape is written for.
                    LimitEscapeSuggestionStore.shared.refusalStands(usageLimit, for: sessionID)
                }
            } else if !isReplaying {
                SessionSnoozeCenter.shared.record(.turnCompleted, for: sessionID)
            }
        }
        recordAttachments(in: event)
        for change in timeline.apply(event) { apply(change) }
        if !isReplaying {
            refreshConversationControls()
            RemoteSessionMirrorRegistry.shared.sessionConversationChanged(sessionID)
        }
    }

    /// Feeds the app-wide activity envelope from provider-neutral stream semantics. Replay is a
    /// historical read, not live work; completion metrics are receipts rather than activity.
    /// Text sizes are logarithmically compressed by `AgentActivityPulse`, while tool and plan
    /// edges use fixed bounded weights so no provider's wire chunking becomes the visual scale.
    private func recordAgentActivity(in event: StreamEvent) {
        guard !isReplaying else { return }

        let magnitude: Double?
        switch event {
        case .textDelta(let text):
            magnitude = AgentActivityPulse.output(byteCount: text.utf8.count)
        case .thinkingDelta(let text):
            magnitude = AgentActivityPulse.thinking(byteCount: text.utf8.count)
        case .assistantMessage(let blocks):
            magnitude = blocks.contains {
                if case .toolUse = $0 { return true }
                return false
            } ? AgentActivityPulse.toolTransition : AgentActivityPulse.assistantMessage
        case .toolResults:
            magnitude = AgentActivityPulse.toolTransition
        case .runPlanUpdated, .backgroundWork:
            magnitude = AgentActivityPulse.planOrBackgroundChange
        case .initialised, .userMessage, .transcriptNotice, .turnFinished, .unknown:
            magnitude = nil
        }

        guard let magnitude else { return }
        AgentWorkloadMonitor.shared.recordActivity(sessionID: sessionID, magnitude: magnitude)
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

    /// Whether the clip view currently sits outside the range its own constraint method permits.
    /// That difference is AppKit's elastic offset; writing the exact end while it exists is the
    /// abrupt snap this gate prevents.
    private var isConversationRubberBanding: Bool {
        guard isViewLoaded else { return false }
        let bounds = scrollView.contentView.bounds
        let constrained = scrollView.contentView.constrainBoundsRect(bounds)
        return abs(bounds.origin.y - constrained.origin.y) > 0.5
    }

    @objc func scrollToConversationEnd() {
        autoScroll.noteJumpedToBottom()
        view.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumConversationScrollOffsetY()))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateScrollToEndControl()
        scheduleConversationViewportSave()
    }

    func updateScrollToEndControl() {
        guard isViewLoaded else { return }
        jumpToEndButton.setFloatingPresence(!isNearConversationBottom)
    }

    func maximumConversationScrollOffsetY() -> CGFloat {
        guard scrollView.documentView != nil else { return 0 }
        let bounds = scrollView.contentView.bounds
        let proposed = NSRect(
            x: bounds.minX,
            y: (scrollView.documentView?.frame.maxY ?? 0) + bounds.height,
            width: bounds.width,
            height: bounds.height
        )
        return max(scrollView.contentView.constrainBoundsRect(proposed).origin.y, 0)
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
                kind: agentKind,
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
        guard let session = currentSession,
              AppSettings.shared.detectsAttachmentReferences(for: session.kind) else {
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

        let root = URL(
            fileURLWithPath: session.workingDirectory(in: project),
            isDirectory: true
        )
        let scanned = texts.joined(separator: "\n")
        let sessionID = sessionID
        let agentKindRawValue = session.kind.rawValue
        Task.detached(priority: .userInitiated) {
            let resolution = AttachmentReferenceDetector.resolve(
                text: scanned,
                projectRoot: root,
                currentDirectory: nil
            )
            guard !resolution.isEmpty, !Task.isCancelled else { return }
            _ = await SessionAttachmentStore.shared.recordScanned(
                resolved: resolution,
                sessionID: sessionID,
                projectRoot: root,
                shouldAdmit: {
                    guard let kind = AgentKind(rawValue: agentKindRawValue) else { return false }
                    return AppSettings.shared.detectsAttachmentReferences(for: kind)
                }
            )
        }
    }

    /// Kept internal so shipping-host renders can cross the same exit boundary as the stream
    /// instead of reproducing its hidden-composer result by reaching into the view hierarchy.
    func handleExit(_ status: Int32) {
        clearStreaming()
        restorePendingInitialPromptToComposer()
        // The process that owned those tasks is gone, and nothing will report them ending.
        backgroundWorkInFlight = []
        pausedOnOwnWork = false
        backgroundWork.forget()
        apply(.status(.ended(code: status)))
        promptContentContainer.isHidden = true
        RemoteSessionMirrorRegistry.shared.sessionDiscarded(sessionID)
        delegate?.conversation(self, didExitWithCode: status)
    }

    private func handleLaunchFailure(_ error: Error) {
        let hostFailure = error as? PTYHostLaunchError
        let failure = SessionLaunchFailure(
            origin: .preflight,
            summary: hostFailure == nil
                ? L10n.string("Its agent could not be started.")
                : L10n.string("Couldn’t start this background session."),
            detail: [error.localizedDescription],
            knownCause: hostFailure.map { "ptyHost.\($0.cause)" }
        )
        ProjectStore.shared.update(sessionID: sessionID) { stored in
            stored.lastLaunchFailure = failure
        }
        handleExit(AgentChildProcessDefaults.spawnFailureStatus)
    }

    // MARK: - Mid-conversation Configuration

    /// Mutable session state comes from the application boundary, never from the construction
    /// snapshot. Tests exercise this directly so a future convenience fallback cannot quietly
    /// reintroduce the stale-record ownership bug.
    var currentSession: AgentSession? {
        currentSessionProjection.session(for: sessionID)
    }

    private var activeModel: String? {
        currentSession?.model
            ?? reportedModel
            ?? AgentModels.defaultModel(for: currentSession?.kind ?? agentKind, account: account)
    }

    /// What the menu's "leave it to the CLI" row names, and where that name came from.
    ///
    /// The chip resolves through `activeModel` while the row used to consult only the account's
    /// config file, so the two disagreed in the one case that matters: an account naming no
    /// model of its own ran a session whose chip read `Opus · 1M` — reported by the CLI when it
    /// started — above a row still reading "Default model". Same question, two answers, one
    /// click apart. The rule itself lives in `AgentModels` and is tested there.
    private var resolvedDefaultModel: ResolvedDefaultModel {
        let session = currentSession
        return AgentModels.resolvedDefault(
            sessionModel: session?.model,
            reportedModel: reportedModel,
            configuredModel: AgentModels.defaultModel(
                for: session?.kind ?? agentKind,
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
        guard let session = currentSession else { return nil }
        return AgentModels.effectiveEffort(
            for: session,
            model: activeModel,
            account: account
        )
    }

    private func refreshConversationControls() {
        refreshInputControl()
        // Ahead of the guards below, because a curfew is not a property of the model catalog: a
        // runtime that publishes no models, and a conversation whose record has gone, both still
        // have a clock — and both would otherwise return before this ran, freezing the chip on
        // whatever it last said.
        refreshCurfewChip()
        // The transport answers this, not the runtime: when a change lands is a property of
        // the wire protocol carrying it. See `ConversationStreamSession`.
        let canConfigure = stream.acceptsConfigurationChange

        guard let session = currentSession else {
            modeChip.isHidden = true
            modelChip.isHidden = true
            effortChip.isHidden = true
            speedChip.isHidden = true
            return
        }

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
        let inheritedMode = inheritedPermissionMode(for: session)
        modeChip.configure(
            symbolName: PermissionModePresentation.symbol,
            title: PermissionModePresentation.chipTitle(
                for: session.kind,
                selected: session.permissionMode,
                inherited: inheritedMode
            )
        )
        // `configure` puts the title on the tooltip, so whose value it is has to be said after.
        if let tooltip = PermissionModePresentation.chipTooltip(
            for: session.kind,
            selected: session.permissionMode,
            inherited: inheritedMode
        ) {
            modeChip.toolTip = tooltip
        }

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
            title: model.map { AgentModels.displayName(for: $0, account: account) }
                ?? ConversationControlDefaults.defaultModel
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

        let speed = ConversationSpeedPresentation.chip(
            selected: session.fastMode,
            kind: session.kind,
            model: model,
            account: account,
            projectDirectory: session.workingDirectory(in: project)
        )
        speedChip.configure(symbolName: speed.symbolName, title: speed.title)
    }

    func refreshInputControl() {
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
        guard let session = currentSession else { return [] }
        let resolved = resolvedDefaultModel

        // The same readings the composer's model menu carries. Switching model mid-conversation
        // is exactly the move a spent window calls for, and this menu used to be the one place
        // that made it without saying what any of the choices cost — the numbers were on the
        // toolbar pill for the model already running, and nowhere for the ones on offer.
        //
        // One refresh for the whole menu, not one per row: the service throttles either way, but
        // a list is not a reason to ask the network once per item.
        if let account { AccountUsageService.shared.refresh(account) }

        // `including:` rather than inserting the pinned model here: a conversation running a
        // model this login's catalog no longer lists still needs a row of its own, but it belongs
        // in the same order as the rest. Put at the front it would sit above the most capable
        // model on offer and read as the recommendation rather than as what happens to be running.
        let options = AgentModels.options(
            for: session.kind,
            account: account,
            including: session.model
        )

        // "Leave it to the CLI" is marked on the model it resolves to rather than named again
        // above the list — the composer's model menu and the permission menu mark their default
        // the same way, because a row that repeats one the list already carries reads as a
        // seventh model rather than as the same one twice.
        let markedInList = options.contains { $0.identifier == resolved.identifier }
        func markedTitle(_ model: String) -> String {
            "\(AgentModels.displayName(for: model, account: account))\(ConversationControlDefaults.suffix(for: resolved.source))"
        }

        var items: [ThemedMenuEntry] = []

        // The account's own windows, once. They are identical under every model by
        // construction, so the rows carry only the windows scoped to them — and the header is
        // what lets a row with no line of its own read as "nothing beyond this" rather than as
        // a failed lookup.
        if let account, let header = AccountUsageMenu.modelMenuHeader(for: account) {
            items.append(.item(header))
            items.append(.separator)
        }

        // Kept for the two cases the list cannot mark: nothing has named a model at all, and a
        // model this catalog does not carry.
        if !markedInList {
            var defaultItem = ThemedMenuItem(
                title: resolved.identifier.map(markedTitle) ?? ConversationControlDefaults.defaultModel,
                representedValue: nil,
                isSelected: session.model == nil
            )
            if let account {
                AccountUsageMenu.decorate(&defaultItem, forModel: resolved.meteredIdentifier, on: account)
            }
            items.append(.item(defaultItem))
        }

        items += options.map { option in
            // The marked row *is* the default row, so it answers nil: the conversation goes on
            // following what the account resolves to rather than pinning today's answer to it.
            let isDefault = markedInList && option.identifier == resolved.identifier
            var item = ThemedMenuItem(
                title: isDefault ? markedTitle(option.identifier) : option.displayName,
                representedValue: isDefault ? nil : option.identifier,
                isSelected: isDefault
                    ? (session.model == nil || session.model == option.identifier)
                    : option.identifier == session.model
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
        guard let session = currentSession else { return [] }
        return PermissionModePresentation.rows(
            for: session.kind,
            selected: session.permissionMode,
            inherited: inheritedPermissionMode(for: session),
            timing: permissionModeTiming
        )
    }

    /// What this conversation runs in when it has pinned nothing of its own.
    ///
    /// The observed source is this session's own transcript, which is the one thing that can
    /// answer for a conversation whose login configures no mode — and it is read from memory
    /// only. `refreshConversationControls()` runs on every streamed event, so a scan here would
    /// be a file read per event; the background re-read belongs to the surfaces that already own
    /// one, and this picks up whatever they have found.
    ///
    /// Offered only while the agent is *running*, because that is the whole of what
    /// `observedInThisConversation` claims: the posture in force now. Past the exit the same
    /// reading describes a process that is gone, and the next launch will take whatever the
    /// settings say — so a dormant conversation resolves without it rather than showing a mode it
    /// would not start in. Not `canSend`: mid-turn is still running, and a chip that changed its
    /// mind for the length of a turn would be reporting the transport, not the posture.
    private func inheritedPermissionMode(for session: AgentSession) -> ResolvedPermissionMode {
        ResolvedPermissionMode.inherited(
            for: session.kind,
            account: account,
            projectDirectory: session.workingDirectory(in: project),
            observed: stream.isRunning
                ? ObservedPermissionMode.known(for: session, in: project)
                : nil
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
        guard let session = currentSession else { return [] }
        return ReasoningEffortPresentation.rows(
            selected: session.reasoningEffort,
            kind: session.kind,
            model: activeModel,
            account: account
        )
    }

    private func speedItems() -> [ThemedMenuEntry] {
        guard let session = currentSession else { return [] }
        return ConversationSpeedPresentation.rows(
            selected: session.fastMode,
            kind: session.kind,
            timing: .whileRunning
        )
    }

    private func selectEffort(_ effort: String?) {
        guard !isChangingConversationConfiguration,
              stream.canSend,
              stream is ReasoningEffortConfigurableConversation,
              let session = currentSession,
              let option = AgentModels.option(
                identifier: activeModel,
                for: session.kind,
                account: account
              ),
              effort == nil || option.supports(reasoningEffort: effort)
        else { return }

        let mutation = ProjectStore.shared.update(sessionID: sessionID) {
            $0.setReasoningEffort(effort)
        }
        guard mutation.succeeded else {
            configurationChangeFailed(projectPersistenceFailure(changedLiveAgent: false))
            return
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
              let session = currentSession,
              session.kind.supportsPermissionModes else { return }

        let persist = { [weak self] (changedLiveAgent: Bool) in
            guard let self else { return }
            let result = ProjectStore.shared.setPermissionMode(mode, for: self.sessionID)
            guard result.succeeded else {
                self.configurationChangeFailed(self.projectPersistenceFailure(
                    changedLiveAgent: changedLiveAgent
                ))
                return
            }
            self.isChangingConversationConfiguration = false
            self.refreshConversationControls()
        }

        guard permissionModeTiming == .immediately,
              let switcher = stream as? PermissionModeSwitchableConversation
        else {
            persist(false)
            return
        }

        guard let resolved = mode ?? PermissionModePresentation.appDefault else {
            persist(false)
            appendNotice(PermissionModePresentation.inheritRecordedOnly, kind: .muted)
            return
        }

        isChangingConversationConfiguration = true
        refreshConversationControls()
        switcher.setPermissionMode(resolved) { [weak self] result in
            switch result {
            case .success:
                persist(true)
            case .failure(let error):
                self?.configurationChangeFailed(error)
            }
        }
    }

    private func selectModel(_ model: String?) {
        guard !isChangingConversationConfiguration,
              let session = currentSession else { return }
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
        let wasFast = AgentModels.effectiveFastMode(
            for: session,
            model: activeModel,
            account: account,
            startupSpeed: AppSettings.shared.startupSpeed(for: session.kind)
        ) ?? false

        let persist = { [weak self] (changedLiveAgent: Bool) in
            guard let self else { return }
            let mutation = ProjectStore.shared.update(sessionID: self.sessionID) {
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
            guard mutation.succeeded else {
                self.configurationChangeFailed(self.projectPersistenceFailure(
                    changedLiveAgent: changedLiveAgent
                ))
                return
            }
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
                                persist(true)
                            case .failure(let error):
                                // The model change already landed. Record that part while leaving
                                // the still-enabled Fast flag truthful, then surface the partial
                                // failure.
                                guard let self else { return }
                                let mutation = ProjectStore.shared.update(
                                    sessionID: self.sessionID
                                ) {
                                    $0.model = model
                                }
                                self.reportedModel = resolved
                                self.configurationChangeFailed(
                                    mutation.succeeded
                                        ? error
                                        : self.projectPersistenceFailure(changedLiveAgent: true)
                                )
                            }
                        }
                    } else {
                        persist(true)
                    }
                case .failure(let error):
                    self?.configurationChangeFailed(error)
                }
            }

        case .codex:
            guard stream.canSend else { return }
            persist(false)

        case .grok, .openCode, .cursor:
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

    private func selectFastMode(_ fast: Bool?) {
        guard !isChangingConversationConfiguration,
              let session = currentSession else { return }

        let persist = { [weak self] (changedLiveAgent: Bool) in
            guard let self else { return }
            let mutation = ProjectStore.shared.update(sessionID: self.sessionID) {
                $0.fastMode = fast
            }
            guard mutation.succeeded else {
                self.configurationChangeFailed(self.projectPersistenceFailure(
                    changedLiveAgent: changedLiveAgent
                ))
                return
            }
            self.isChangingConversationConfiguration = false
            self.refreshConversationControls()
        }

        // Standard and Fast have live representations. Following an explicit General default
        // resolves to one of those too. Agent's Setting has no generic "restore provider
        // config" control request, so only the record changes until the next launch.
        guard let resolved = fast
            ?? AppSettings.shared.startupSpeed(for: session.kind).fastModeOverride
        else {
            persist(false)
            appendNotice(ConversationSpeedPresentation.inheritRecordedOnly, kind: .muted)
            return
        }

        switch session.kind {
        case .claude:
            guard let switcher = stream as? FastModeConversation else { return }
            isChangingConversationConfiguration = true
            refreshConversationControls()
            switcher.setFastMode(resolved) { [weak self] result in
                switch result {
                case .success:
                    persist(true)
                case .failure(let error):
                    self?.configurationChangeFailed(error)
                }
            }
        case .codex:
            guard stream.canSend else { return }
            persist(false)

        case .grok, .openCode, .cursor:
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

    /// Model and permission mode are already present on the launch line. Fast mode also rides
    /// Claude's per-session settings layer, then is restated over the live control channel once
    /// the persistent print transport is ready so the running process and the saved startup
    /// choice cannot drift.
    ///
    /// The transport's own conformance is the test, not the runtime's name: a transport that
    /// cannot be asked mid-conversation does not conform, and one that can needs no entry here.
    private func restoreConversationConfiguration() {
        guard let session = currentSession,
              let fast = AgentLauncher.fastModeAtStartup(for: session),
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

    private func projectPersistenceFailure(changedLiveAgent: Bool) -> Error {
        let message = changedLiveAgent
            ? "The live agent changed, but the project data could not be saved; the setting "
                + "may revert after relaunch."
            : "The project data could not be saved."
        return NSError(
            domain: "ProjectStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private enum ConversationControlDefaults {
    static let modelSymbol = "cpu"
    /// The last resort, reached only by a login that has never run this agent anywhere — no
    /// configuration, no organisation default, no transcript to read. "Default model" was the
    /// wrong words for it: it reads as a setting whose value is being withheld, when the truth
    /// is that nothing has chosen yet and the agent will decide at launch. Naming the decider is
    /// the most this can honestly say; the CLI's own fallback is negotiated per subscription and
    /// is not written down on this machine.
    static var defaultModel: String { L10n.string("Agent's choice") }
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
}

// MARK: - Agent Runtime Composition

extension ConversationViewController: AgentConversationRuntimeSurface {
    var conversationRootProcessIdentifier: pid_t? {
        stream.rootProcessIdentifier
    }

    var isHostBacked: Bool { stream.isHostBacked }

    var hasPendingInputForRetirement: Bool {
        pendingInitialPrompt != nil || checkoutMoveOutboxSnapshot()?.isEmpty == false
    }

    /// A quit hands this conversation's CLI over rather than ending it.
    ///
    /// The viewport is still saved, because the conversation is coming back: the next launch
    /// resumes it, and a scroll position lost at a quit is lost whether or not the child
    /// survived. Nothing else about the teardown runs — no permission is denied and no stream is
    /// stopped — because nothing is ending.
    func detachFromBackgroundHost(by deadline: Date) -> Bool {
        detachFromBackgroundHost(by: deadline, idleExpiresAt: nil)
    }

    func detachFromBackgroundHost(by deadline: Date, idleExpiresAt: Date?) -> Bool {
        guard stream.detachFromBackgroundHost(
            by: deadline,
            idleExpiresAt: idleExpiresAt
        ) else { return false }
        saveConversationViewport()
        return true
    }

    func removeFromPresentation() {
        view.removeFromSuperview()
    }
}

extension AgentRuntime {
    /// UI's concrete adapter lookup. Core and remote transport use the narrower runtime
    /// capabilities on `AgentRuntime` and never acquire this controller.
    func conversation(for sessionID: SessionID) -> ConversationViewController? {
        conversationRuntimeSurface(for: sessionID) as? ConversationViewController
    }

    /// Returns the cached conversation for a session, creating it at the UI composition edge.
    func makeConversation(
        for agentSession: AgentSession,
        in project: Project
    ) -> ConversationViewController? {
        if let existing = conversation(for: agentSession.id) {
            return existing
        }

        guard let conversation = ConversationViewController(
            agentSession: agentSession,
            project: project,
            currentSessionProjection: conversationSessionProjection(),
            subagentState: subagentState(for: agentSession.id),
            launchPlanProvider: fixtureLaunchPlanProvider(for: agentSession.id)
        ) else { return nil }
        if let outbox = takeCheckoutMoveOutbox(sessionID: agentSession.id) {
            conversation.restoreCheckoutMoveOutbox(outbox)
        }
        precondition(
            registerConversationRuntimeSurface(conversation, for: agentSession.id),
            "A conversation runtime must have one UI adapter"
        )
        return conversation
    }
}
