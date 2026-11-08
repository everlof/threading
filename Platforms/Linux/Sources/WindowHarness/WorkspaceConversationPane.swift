#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import CoreSlice

@MainActor
private final class ConversationChoiceSession: ChipChoicePresentationSession {
    private var didDismiss: (() -> Void)?
    init(didDismiss: @escaping () -> Void) { self.didDismiss = didDismiss }
    func dismissChipChoicePresentation() {
        let callback = didDismiss
        didDismiss = nil
        callback?()
    }
}

/// Native conversation content in the ordinary workspace. The same chrome serves a terminal;
/// transcript cells and prompt controls come from the production Design sources.
@MainActor
final class WorkspaceConversationPane: WorkspacePane {
    let runtime: NativeWorkspaceSession
    let chrome: WorkspacePaneChrome
    private let owner = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let root = ConversationPaneContentView(frame: .zero)
    private let transcript = ConversationTranscriptTable<WorkspaceConversationPane>()
    private var scroll: ThemedScrollView { transcript.scrollView }
    private var table: ThemedTableView { transcript.tableView }
    var transcriptRows: [ConversationTimeline.Row] = []
    private var bufferedRows: [Int: (ConversationTimeline.Row, [[String]]?)] = [:]
    private var hasTruncationNotice = false
    private var preparedMarkdownPages: [Int: [[String]]] = [:]
    private var streamingLabel: ProseLabel?
    private var displayedDecisionIDs: [ObjectIdentifier] = []
    private let composer = PromptView(frame: .zero)
    private let modelChip = ChipView()
    private let modeChip = ChipView()
    private let effortChip = ChipView()
    private let speedChip = ChipView()
    private let contextLabel = NSTextField(labelWithString: "")
    private var configurationMenu: ThemedMenuSurfaceView?
    private var configurationMenuKey: [String] = []
    private var configurationHighlightedIndex: Int?
    private enum ConfigurationKind: Int { case model = 1, effort = 2, mode = 3 }
    private var configurationKind: ConfigurationKind?
    private var configurationChoices: [NativeConfigurationChoice] = []
    private var configurationRows: [ThemedMenuRowView] = []
    private var configurationSession: ConversationChoiceSession?
    private var configurationFirst = 0
    private var configurationSelected = 0
    private var configurationVisibleCount = 0
    private var configurationRowHeight: CGFloat = 44
    private var configurationWidth: CGFloat = 240
    private var speedMenu: ThemedMenuSurfaceView?
    private var speedSession: ConversationChoiceSession?
    private var speedSelected = 0
    private var speedOpen = false
    private var speedMenuHeight: CGFloat = 0
    private var speedMenuWidth: CGFloat = 300
    private var submit: ThemedButton { composer.linuxSubmitButton }
    private let status: NSTextField
    private lazy var composerColumnCap = composer.widthAnchor.constraint(
        lessThanOrEqualToConstant: ConversationPaneLayout.composerWidth)
    private lazy var composerColumnWidth: NSLayoutConstraint = {
        let constraint = composer.widthAnchor.constraint(
            equalToConstant: ConversationPaneLayout.composerWidth)
        constraint.priority = ConversationPaneLayout.statedColumnPriority
        return constraint
    }()
    private var needsPresentation = true
    private var presentedSize = NSSize.zero
    private var displayRevision: UInt64 = 0
    var onAgentActivityChange: (() -> Void)?
    private var lastPresentedActiveAgent: Bool?
    private var lastPresentedActivity: NativeSessionActivity?
    private var followTail = true
    private var focused = false
    private var presentedPermission: Int?
    private var permissionCard: PermissionRequestView?
    private var questionCards: [UUID: ConversationQuestionCard] = [:]
    /// Every decision card in arrival order, as the trailing transcript block shows them.
    private var decisionOrder: [NSView] = []
    var title: String { "Threading conversation · \(runtime.status)" }
    var activity: NativeSessionActivity { runtime.activity }
    // A measured tail can owe one more frame without another user or provider event.
    // Once it settles the native loop returns to its blocking idle wait.
    var needsPolling: Bool { needsPresentation }
    func takeInitialViewport() -> (Int, Int)? { nil }

    init(runtime: NativeWorkspaceSession, pageName: String, icon: NSImage?, onReveal: @escaping () -> Void) {
        self.runtime = runtime
        chrome = WorkspacePaneChrome(pageName: pageName, pageIdentity: runtime.id.uuidString,
            symbolName: "text.bubble", icon: icon, showsSessionActions: true, onReveal: onReveal)
        status = NSTextField(labelWithString: runtime.status)
        status.applyFont(.subheading, in: .conversation)
        status.textColor = Design.Text.tertiary
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.isSelectable = true
        transcript.surface = self
        transcript.activate()
        composer.placeholder = "Reply to this conversation"
        composer.fontSurface = .conversation
        composer.submitPlacement = .footer
        composer.showsImageAttachments = true
        composer.onSubmit = { [weak self] value in self?.send(value) }
        composer.onStop = { [weak self] in self?.runtime.interrupt() }
        composer.onChange = { [weak self] _ in self?.updateState() }
        composer.onContentHeightChange = { [weak self] _ in self?.needsPresentation = true }
        composer.onSubmissionAvailabilityChange = { [weak self] _ in self?.needsPresentation = true }
        submit.setAccessibilityIdentifier("composer.conversation-reply.submit")
        composer.linuxEditor.nextKeyView = modelChip
        modelChip.nextKeyView = modeChip
        modeChip.nextKeyView = effortChip
        effortChip.nextKeyView = speedChip
        speedChip.nextKeyView = submit
        submit.nextKeyView = composer.linuxEditor
        root.mount(transcript: scroll, status: status, composer: composer)
        modelChip.configure(symbolName: "cpu", title: "Default model")
        modelChip.isHidden = true
        modelChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openConfigurationChoice(.model, didDismiss: didDismiss)
        }
        modeChip.configure(symbolName: "hand.raised", title: "Agent's Setting")
        modeChip.isHidden = true
        modeChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openConfigurationChoice(.mode, didDismiss: didDismiss)
        }
        effortChip.configure(symbolName: "brain", title: "Default effort")
        effortChip.isHidden = true
        effortChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openConfigurationChoice(.effort, didDismiss: didDismiss)
        }
        let initialSpeed = ConversationSpeedMenuContent.chip(effective: nil)
        speedChip.configure(symbolName: initialSpeed.symbolName, title: initialSpeed.title)
        speedChip.isHidden = true
        speedChip.choicePresentationProvider = { [weak self] _, didDismiss in
            self?.openSpeedChoice(didDismiss: didDismiss)
        }
        // The Mac reply footer compresses chip labels before letting the send control escape
        // a narrow pane. Keep the same priorities in the Linux layout island.
        for chip in [modelChip, modeChip, effortChip, speedChip] {
            chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        contextLabel.applyFont(.subheading)
        contextLabel.textColor = Design.Text.tertiary
        contextLabel.isHidden = true
        contextLabel.setAccessibilityIdentifier("conversation.context")
        composer.setFooterControls(leading: [modelChip, modeChip, effortChip, speedChip],
                                   trailing: [contextLabel])
        root.constrain(
            transcriptTop: scroll.topAnchor.constraint(equalTo: root.topAnchor),
            composerBottom: root.bottomAnchor,
            columnCap: composerColumnCap,
            columnWidth: composerColumnWidth
        )
        owner.contentView = root
        runtime.onRow = { [weak self] index, row, pages in
            guard let self else { return }
            self.present(row, at: index, preparedPages: pages)
            self.needsPresentation = true
        }
        runtime.onStreaming = { [weak self] text in
            guard let self else { return }
            self.presentStreaming(text.flatMap { $0.isEmpty ? nil : $0 })
            self.needsPresentation = true
        }
        runtime.onChange = { [weak self] in self?.updateState() }
        runtime.onPermissionChange = { [weak self] in self?.updatePermission() }
        runtime.onQuestionsChange = { [weak self] in self?.updateQuestions() }
        setThemeAppearance()
        updatePermission()
        updateQuestions()
        updateState()
    }

    private func present(_ row: ConversationTimeline.Row, at index: Int,
                         preparedPages: [[String]]?) {
        if index == Int.max {
            guard !hasTruncationNotice else { return }
            hasTruncationNotice = true
            transcript.append(.init(id: .surface(.truncation),
                content: .surface(.truncation(ConversationRowView.make(for: row).view))))
            return
        }
        if index > transcriptRows.count {
            bufferedRows[index] = (row, preparedPages)
            return
        }
        precondition(index >= 0 && index <= transcriptRows.count,
            "native transcript row delivery must be ordered")
        if index < transcriptRows.count {
            preparedMarkdownPages[index] = preparedPages
            transcriptRows[index] = row
            if case .toolCall = row { transcript.applyToolResult(at: index) }
            else { transcript.reload() }
            return
        }
        appendPresentedRow(row, preparedPages: preparedPages)
        while let next = bufferedRows.removeValue(forKey: transcriptRows.count) {
            appendPresentedRow(next.0, preparedPages: next.1)
        }
    }

    private func appendPresentedRow(_ row: ConversationTimeline.Row,
                                    preparedPages: [[String]]?) {
        // Surface items trail the canonical timeline. Move only this small, host-owned tail
        // while the shared table appends the row with its normal divider and tool grouping.
        let index = transcriptRows.count
        preparedMarkdownPages[index] = preparedPages
        let streaming = streamingLabel
        let cards = decisionOrder
        if streaming != nil { transcript.remove(.surface(.streaming)) }
        for id in displayedDecisionIDs { transcript.remove(.surface(.decision(id))) }
        transcriptRows.append(row)
        transcript.appendTimelineRow(at: index)
        if let streaming { appendStreaming(streaming) }
        for card in cards { appendDecision(card) }
    }

    private func presentStreaming(_ text: String?) {
        guard let text else {
            transcript.remove(.surface(.streaming))
            streamingLabel = nil
            return
        }
        if let streamingLabel {
            streamingLabel.text = text
            transcript.noteHeightChanged(of: .surface(.streaming))
            return
        }
        let label = ConversationRowView.streaming(text)
        streamingLabel = label
        appendStreaming(label)
    }

    private func appendStreaming(_ label: ProseLabel) {
        let item = ConversationTranscriptTable<WorkspaceConversationPane>.Item(
            id: .surface(.streaming), content: .surface(.streaming(label)))
        let position = transcript.items.firstIndex { item in
            if case .surface(.decision) = item.id { return true }
            return false
        } ?? transcript.items.count
        transcript.insert([item], at: position)
    }

    private func appendDecision(_ card: NSView) {
        let id = ObjectIdentifier(card)
        transcript.append(.init(id: .surface(.decision(id)), content: .surface(.decision(card))))
    }

    private func syncDecisionItems() {
        let wanted = decisionOrder.map(ObjectIdentifier.init)
        let wantedSet = Set(wanted)
        for id in displayedDecisionIDs where !wantedSet.contains(id) {
            transcript.remove(.surface(.decision(id)))
        }
        let shown = Set(displayedDecisionIDs)
        for card in decisionOrder where !shown.contains(ObjectIdentifier(card)) {
            appendDecision(card)
        }
        displayedDecisionIDs = wanted
    }

    /// The queue's head as the production card, after the transcript as the Mac shows it. An
    /// answered card leaves; the next request, if any, replaces it.
    private func updatePermission() {
        let pending = runtime.pendingPermission
        guard pending?.id != presentedPermission else { return }
        presentedPermission = pending?.id
        let card = pending.map { pending in
            PermissionRequestView(request: pending.request) { [weak self] decision in
                self?.runtime.answerPermission(id: pending.id, decision)
            }
        }
        if let permissionCard { retire(permissionCard, returningFocus: false) }
        permissionCard = card
        if let card { decisionOrder.append(card) }
        syncDecisionItems()
        followTail = true
        needsPresentation = true
    }

    /// Each provider question as the production card. A card the provider withdrew leaves.
    private func updateQuestions() {
        let live = Set(runtime.questions.map(\.request.id))
        for (id, card) in questionCards where !live.contains(id) {
            card.invalidate()
            questionCards[id] = nil
            retire(card, returningFocus: true)
        }
        for question in runtime.questions where questionCards[question.request.id] == nil {
            let id = question.request.id
            let card = ConversationQuestionCard(request: question.request) { [weak self] answers in
                self?.runtime.answerQuestion(id, answers)
            }
            card.onLayoutChange = { [weak self, weak card] in
                guard let self, let card else { return }
                let row = table.row(for: card)
                if row >= 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
                needsPresentation = true
            }
            questionCards[id] = card
            decisionOrder.append(card)
        }
        syncDecisionItems()
        followTail = true
        needsPresentation = true
    }

    /// Removes a card from the block. The Mac returns focus held inside a question card to the
    /// prompt, and leaves it where it was for a permission card; both are kept.
    private func retire(_ card: NSView, returningFocus: Bool) {
        decisionOrder.removeAll { $0 === card }
        if returningFocus, let responder = owner.firstResponder as? NSView, responder.isDescendant(of: card) {
            _ = owner.makeFirstResponder(composer.linuxEditor)
        }
    }

    private func updateState() {
        let activeAgent = runtime.presentsActiveAgent
        let activity = runtime.activity
        if (lastPresentedActiveAgent != nil && lastPresentedActiveAgent != activeAgent)
            || (lastPresentedActivity != nil && lastPresentedActivity != activity) {
            onAgentActivityChange?()
        }
        lastPresentedActiveAgent = activeAgent
        lastPresentedActivity = activity
        status.stringValue = runtime.pendingPermission != nil ? "Waiting for permission"
            : runtime.questions.isEmpty ? runtime.status : "Waiting for your answer"
        status.textColor = runtime.failure == nil ? Design.Text.secondary : Design.Status.negative
        if let reading = runtime.contextReading {
            contextLabel.stringValue = TurnStatusText.context(tokens: reading.tokens, window: reading.window)
            contextLabel.textColor = TurnStatusText.contextIsNearlyFull(
                tokens: reading.tokens, window: reading.window)
                ? Design.Status.warning : Design.Text.tertiary
            contextLabel.isHidden = false
        } else {
            contextLabel.isHidden = true
        }
        composer.composerMode = activeAgent
            ? .working(canStop: runtime.canInterrupt, canSteer: false) : .ready
        composer.isSubmissionEnabled = runtime.canSend && !composer.linuxEditor.hasMarkedText()
        if let choice = runtime.modelChoice {
            modelChip.configure(symbolName: "cpu", title: choice.title)
            modelChip.isHidden = false
            modelChip.isEnabled = choice.enabled
        } else {
            modelChip.isHidden = true
            if configurationKind == .model { dismissConfigurationChoice() }
        }
        if let choice = runtime.modeChoice {
            modeChip.configure(symbolName: "hand.raised", title: choice.title)
            modeChip.isHidden = false
            modeChip.isEnabled = choice.enabled
        } else {
            modeChip.isHidden = true
            if configurationKind == .mode { dismissConfigurationChoice() }
        }
        if let choice = runtime.effortChoice {
            effortChip.configure(symbolName: "brain", title: choice.title)
            effortChip.isHidden = false
            effortChip.isEnabled = choice.enabled
        } else {
            effortChip.isHidden = true
            if configurationKind == .effort { dismissConfigurationChoice() }
        }
        if let choice = runtime.speedChoice {
            speedChip.configure(symbolName: choice.symbolName, title: choice.title)
            speedChip.isHidden = false
            speedChip.isEnabled = choice.enabled
        } else {
            speedChip.isHidden = true
            if speedOpen { dismissSpeedChoice() }
        }
        needsPresentation = true
    }

    private func openConfigurationChoice(_ kind: ConfigurationKind,
        didDismiss: @escaping () -> Void) -> ChipChoicePresentationSession? {
        let available: Bool?
        let choices: [NativeConfigurationChoice]
        switch kind {
        case .model: available = runtime.modelChoice?.enabled; choices = runtime.modelChoices
        case .mode: available = runtime.modeChoice?.enabled; choices = runtime.modeChoices
        case .effort: available = runtime.effortChoice?.enabled; choices = runtime.effortChoices
        }
        guard available == true else { return nil }
        dismissSpeedChoice()
        dismissConfigurationChoice()
        guard !choices.isEmpty else { return nil }
        configurationKind = kind
        configurationChoices = choices
        configurationMenuKey = []
        configurationHighlightedIndex = nil
        configurationSelected = choices.firstIndex(where: \.selected) ?? 0
        configurationFirst = max(0, configurationSelected - 2)
        let entries = choices.map { choice in
            ThemedMenuEntry.item(ThemedMenuItem(title: choice.title, subtitle: choice.detail,
                isSelected: choice.selected, isEnabled: choice.enabled))
        }
        configurationRowHeight = ThemedMenuMetrics.heights(for: entries).max() ?? 44
        configurationWidth = kind == .model ? 320 : kind == .mode ? 340 : 280
        let session = ConversationChoiceSession(didDismiss: didDismiss)
        configurationSession = session
        layoutConfigurationMenu()
        needsPresentation = true
        return session
    }

    private func layoutConfigurationMenu() {
        guard let kind = configurationKind, !configurationChoices.isEmpty else { return }
        owner.layoutIfNeeded()
        let chip: ChipView
        switch kind {
        case .model: chip = modelChip
        case .mode: chip = modeChip
        case .effort: chip = effortChip
        }
        let source = chip.convert(chip.bounds, to: root)
        let outerInset = ThemedMenuMetrics.verticalOuterInset * 2
        let placement = ThemedMenuLayout.frame(anchor: source,
            desiredSize: NSSize(width: configurationWidth,
                height: CGFloat(configurationChoices.count) * configurationRowHeight + outerInset),
            in: root.bounds, flipped: root.isFlipped)
        let rowCapacity = max(1, Int((placement.height - outerInset) / configurationRowHeight))
        configurationVisibleCount = min(6, configurationChoices.count, rowCapacity)
        configurationFirst = min(configurationFirst,
            max(0, configurationChoices.count - configurationVisibleCount))
        let end = min(configurationChoices.count, configurationFirst + configurationVisibleCount)
        let visibleChoices = Array(configurationChoices[configurationFirst..<end])
        let entries = visibleChoices.map { choice in
            ThemedMenuEntry.item(ThemedMenuItem(title: choice.title, subtitle: choice.detail,
                isSelected: choice.selected, isEnabled: choice.enabled))
        }
        let frame = ThemedMenuLayout.frame(anchor: source,
            desiredSize: NSSize(width: configurationWidth,
                height: ThemedMenuMetrics.height(for: entries)),
            in: root.bounds, flipped: root.isFlipped)
        let key = [String(kind.rawValue), String(configurationFirst),
            String(describing: frame.width)] + visibleChoices.map { choice in
                "\(choice.id ?? ""):\(choice.title):\(choice.detail ?? ""):\(choice.selected):\(choice.enabled)"
            }
        let selectedEntry = configurationSelected - configurationFirst
        if configurationMenuKey != key || configurationMenu == nil {
            configurationMenu?.removeFromSuperview()
            let surface = ThemedMenuSurfaceView(
                frame: NSRect(origin: .zero, size: frame.size), entries: entries,
                selectedEntryIndex: nil)
            surface.appearance = LinuxTheme.appearance
            surface.onChoose = { [weak self] entry, _ in
                guard let self else { return }
                self.chooseConfiguration(self.configurationFirst + entry)
            }
            surface.onHighlight = { [weak self] entry in
                guard let self else { return }
                self.highlightConfiguration(self.configurationFirst + entry)
            }
            surface.onScrolled = { [weak self] in self?.needsPresentation = true }
            configurationMenu = surface
            configurationMenuKey = key
            configurationHighlightedIndex = nil
            root.addSubview(surface)
        }
        if let surface = configurationMenu {
            surface.frame = frame
            surface.appearance = LinuxTheme.appearance
            if configurationHighlightedIndex != selectedEntry {
                surface.highlight(selectedEntry)
                configurationHighlightedIndex = selectedEntry
            }
            configurationRows = entries.indices.compactMap { surface.row(at: $0) }
        }
    }

    private func highlightConfiguration(_ index: Int) {
        guard configurationKind != nil, configurationChoices.indices.contains(index) else { return }
        let selectable = configurationChoices.indices.filter { configurationChoices[$0].enabled }
        guard let target = selectable.first(where: { $0 >= index }) ?? selectable.last else { return }
        configurationSelected = target
        if target < configurationFirst { configurationFirst = target; layoutConfigurationMenu() }
        else if target >= configurationFirst + configurationVisibleCount {
            configurationFirst = target - configurationVisibleCount + 1
            layoutConfigurationMenu()
        } else {
            let selectedEntry = target - configurationFirst
            configurationMenu?.highlight(selectedEntry)
            configurationHighlightedIndex = selectedEntry
        }
        needsPresentation = true
    }

    private func chooseConfiguration(_ index: Int) {
        guard let kind = configurationKind, configurationChoices.indices.contains(index),
              configurationChoices[index].enabled else { return }
        let id = configurationChoices[index].id
        dismissConfigurationChoice()
        switch kind {
        case .model: runtime.selectModel(id)
        case .mode: runtime.selectMode(id.flatMap(AgentPermissionMode.init(rawValue:)))
        case .effort: runtime.selectEffort(id)
        }
        _ = owner.makeFirstResponder(composer.linuxEditor)
        needsPresentation = true
    }

    private func dismissConfigurationChoice() {
        guard configurationKind != nil else { return }
        configurationKind = nil
        configurationMenu?.removeFromSuperview()
        configurationMenu = nil
        configurationMenuKey = []
        configurationHighlightedIndex = nil
        configurationRows.removeAll(keepingCapacity: true)
        configurationChoices.removeAll(keepingCapacity: true)
        configurationVisibleCount = 0
        let session = configurationSession
        configurationSession = nil
        session?.dismissChipChoicePresentation()
        needsPresentation = true
    }

    @discardableResult
    func pressConfiguration(kind: Int, identity: String) -> Bool {
        guard identity == runtime.id.uuidString, let configuration = ConfigurationKind(rawValue: kind) else {
            return false
        }
        let chip: ChipView
        switch configuration {
        case .model: chip = modelChip
        case .mode: chip = modeChip
        case .effort: chip = effortChip
        }
        guard !chip.isHidden, chip.isEnabled else { return false }
        if configurationKind == configuration { dismissConfigurationChoice(); return true }
        let pressed = chip.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    @discardableResult
    func chooseConfiguration(kind: Int, index: Int, identity: String) -> Bool {
        guard identity == runtime.id.uuidString, configurationKind?.rawValue == kind,
              (configurationFirst..<configurationFirst + configurationVisibleCount).contains(index),
              configurationChoices.indices.contains(index),
              configurationChoices[index].enabled else { return false }
        chooseConfiguration(index)
        return true
    }

    var hasOpenConfigurationChoice: Bool { configurationKind != nil }

    private func openSpeedChoice(didDismiss: @escaping () -> Void) -> ChipChoicePresentationSession? {
        guard let choice = runtime.speedChoice, choice.enabled else { return nil }
        dismissConfigurationChoice()
        dismissSpeedChoice()
        let entries = speedEntries(selected: choice.selected)
        speedMenuHeight = ThemedMenuMetrics.height(for: entries)
        speedSelected = choice.selected.map { $0 ? 2 : 1 } ?? 0
        speedMenuWidth = ThemedMenuMetrics.width(for: entries, minimum: 300,
            selectedEntryIndex: speedSelected)
        let surface = ThemedMenuSurfaceView(frame: NSRect(x: 0, y: 0, width: speedMenuWidth,
            height: speedMenuHeight), entries: entries, selectedEntryIndex: nil)
        surface.appearance = LinuxTheme.appearance
        surface.onChoose = { [weak self] index, _ in self?.chooseSpeed(index) }
        surface.onHighlight = { [weak self] index in self?.highlightSpeed(index) }
        surface.onScrolled = { [weak self] in self?.needsPresentation = true }
        speedMenu = surface
        root.addSubview(surface)
        speedOpen = true
        let session = ConversationChoiceSession(didDismiss: didDismiss)
        speedSession = session
        layoutSpeedMenu()
        highlightSpeed(speedSelected)
        needsPresentation = true
        return session
    }

    private func speedEntries(selected: Bool?) -> [ThemedMenuEntry] {
        let startupSpeed = runtime.sessionKind.map(LinuxGeneralSettings.startupSpeed(for:))
            ?? .agentSetting
        let detail = ConversationSpeedMenuContent.followGeneralDetail(
            startupSpeed: startupSpeed, whileRunning: true)
        return ConversationSpeedMenuContent.rows(selected: selected,
            inheritTitle: ConversationSpeedMenuContent.followGeneralTitle,
            inheritDetail: detail)
    }

    private func layoutSpeedMenu() {
        guard speedOpen, let speedMenu else { return }
        owner.layoutIfNeeded()
        let source = speedChip.convert(speedChip.bounds, to: root)
        speedMenu.frame = ThemedMenuLayout.frame(anchor: source,
            desiredSize: NSSize(width: speedMenuWidth,
                height: speedMenuHeight),
            in: root.bounds, flipped: root.isFlipped)
    }

    private func highlightSpeed(_ index: Int) {
        guard (0..<3).contains(index) else { return }
        speedSelected = index
        speedMenu?.highlight(index)
        needsPresentation = true
    }

    private func chooseSpeed(_ index: Int) {
        guard speedOpen, (0..<3).contains(index) else { return }
        dismissSpeedChoice()
        runtime.selectSpeed(index == 0 ? nil : index == 2)
        _ = owner.makeFirstResponder(composer.linuxEditor)
        needsPresentation = true
    }

    @discardableResult
    func pressSpeed(identity: String) -> Bool {
        guard identity == runtime.id.uuidString, !speedChip.isHidden, speedChip.isEnabled else { return false }
        if speedOpen { dismissSpeedChoice(); return true }
        let pressed = speedChip.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    @discardableResult
    func chooseSpeed(index: Int, identity: String) -> Bool {
        guard identity == runtime.id.uuidString, speedOpen, (0..<3).contains(index) else { return false }
        chooseSpeed(index)
        return true
    }

    var hasOpenSpeedChoice: Bool { speedOpen }

    private func dismissSpeedChoice() {
        guard speedOpen else { return }
        speedOpen = false
        speedMenu?.removeFromSuperview()
        speedMenu = nil
        let session = speedSession
        speedSession = nil
        session?.dismissChipChoicePresentation()
        needsPresentation = true
    }

    private func send(_ value: String) {
        guard !composer.isPreparingAttachments, !composer.linuxEditor.hasMarkedText(),
              runtime.send(value) else { updateState(); return }
        composer.clear()
        followTail = true
        updateState()
    }

    @discardableResult
    func removeAttachment(id: String) -> Bool { composer.removeLinuxAttachment(id: id) }

    func drainAttachments() {}

    func acceptFileDrop(_ path: String, windowX: Int, windowY: Int,
                        originX: Int, wakeIdentity: UInt64) -> Bool {
        let point = NSPoint(x: CGFloat(windowX - originX) / WorkspaceDisplay.scale,
            y: root.bounds.height - CGFloat(windowY - WorkspacePaneChrome.headerPixelHeight)
                / WorkspaceDisplay.scale)
        guard composer.frame.contains(point) else { return false }
        composer.acceptDroppedPaths([path])
        return true
    }

    func setThemeAppearance() {
        chrome.setThemeAppearance()
        root.appearance = LinuxTheme.appearance
        speedMenu?.appearance = LinuxTheme.appearance
        configurationMenu?.appearance = LinuxTheme.appearance
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        refreshComposerSurface()
        transcript.invalidateStyleCaches()
        NotificationCenter.default.post(AppThemeDidChange())
        transcript.reload()
        needsPresentation = true
    }

    private func refreshComposerSurface() {
        needsPresentation = true
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        self.focused = focused
        chrome.focus(focused, window: window)
        owner.isKeyWindow = focused
        _ = tw_workspace_composer_mode(window, 1)
        if focused { _ = owner.makeFirstResponder(composer.linuxEditor) }
        else { owner.cancelPointerGesture(); _ = owner.makeFirstResponder(nil) }
        _ = tw_workspace_editor_focus(window, focused ? 1 : 0)
        needsPresentation = true
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int, focused: Bool) throws {
        try chrome.refresh(window: window, width: width, height: height, originX: originX)
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        let size = NSSize(width: CGFloat(width) / WorkspaceDisplay.scale, height: CGFloat(contentHeight) / WorkspaceDisplay.scale)
        let inset = Design.Spacing.inset
        let statusHeight = status.intrinsicContentSize.height
        let hasImages = !composer.linuxAttachmentTiles.isEmpty
        let attachmentHeight = hasImages
            ? Design.Size.promptAttachmentThumbnail + Design.Spacing.medium : 0
        let attachedMinimumContentHeight = composer.minimumHeight + attachmentHeight
            + 2 * inset + statusHeight
            + 2 * Design.Spacing.small + Design.Size.chipHeight
        let minimumWindowHeight = hasImages
            ? Int((attachedMinimumContentHeight * WorkspaceDisplay.scale).rounded(.up))
                + WorkspacePaneChrome.headerPixelHeight : 180
        tw_workspace_minimum_height(window, Int32(minimumWindowHeight))
        guard height >= minimumWindowHeight else { needsPresentation = true; return }
        guard needsPresentation || size != presentedSize || displayRevision != owner.displayRevision else { return }
        root.frame = NSRect(origin: .zero, size: size)
        let columnCap = ConversationPaneLayout.composerWidth(inPane: size.width)
        let composerWidth = max(1, ConversationPaneLayout.measuredComposerWidth(in: size.width))
        if composerColumnCap.constant != columnCap { composerColumnCap.constant = columnCap }
        if composerColumnWidth.constant != composerWidth {
            composerColumnWidth.constant = composerWidth
        }
        owner.layoutIfNeeded()
        // The clip view already sizes its document to the viewport, so the table's own width is
        // no signal; the column's is. Cells read it when they are built and state it as theirs.
        if table.tableColumns.first?.width != scroll.bounds.width || table.frame.width != scroll.bounds.width {
            table.tableColumns.first?.width = scroll.bounds.width
            table.frame.size.width = scroll.bounds.width
            transcript.layoutColumn()
        }
        owner.layoutIfNeeded()
        layoutSpeedMenu()
        layoutConfigurationMenu()
        if followTail {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.frame.height - scroll.contentView.bounds.height)))
        }
        let bitmap = Bitmap(width: width, height: contentHeight, background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: WorkspaceDisplay.scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_pane(window, $0.baseAddress, Int32(width), Int32(contentHeight), 0)
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        if focused {
            tw_title(window, title)
            let caret = activeTextView.convert(activeTextView.insertionPointRect, to: root)
            tw_text_input_rect(window, Int32(originX + Int(caret.minX * WorkspaceDisplay.scale)),
                Int32(WorkspacePaneChrome.headerPixelHeight + Int((size.height - caret.maxY) * WorkspaceDisplay.scale)),
                Int32(max(1, caret.width * WorkspaceDisplay.scale)), Int32(max(1, caret.height * WorkspaceDisplay.scale)))
        }
        tw_accessibility_show_conversation(window, title)
        ComposerAttachmentAccessibility.publish(window: window, prompt: composer,
            owner: runtime.id.uuidString, scope: 2, root: root, originX: originX,
            topInset: WorkspacePaneChrome.headerPixelHeight)
        publishConfigurationAccessibility(window: window, originX: originX, size: size)
        publishSpeedAccessibility(window: window, originX: originX, size: size)
        publishContextAccessibility(window: window, originX: originX, size: size)
        // Revealing an estimated tail row can measure it during this paint and grow the
        // document after the earlier scroll. Keep a frame owed until that measured tail
        // is visible; consuming the invalidation here stranded tall question cards below
        // the composer. Each pass still materializes only the viewport's rows.
        let tailNeedsLayout = followTail && scroll.contentView.bounds.maxY < table.frame.maxY - 1
        needsPresentation = tailNeedsLayout
        presentedSize = size
        displayRevision = owner.displayRevision
        func waiting(_ view: NSView) -> Bool {
            (view as? NSTextField)?.isWaitingForCompleteTextViewport == true || view.subviews.contains(where: waiting)
        }
        let prepared = runtime.rowsPrepared && !tailNeedsLayout
            && !waiting(table) && !status.isWaitingForCompleteTextViewport
        let composerTop = WorkspacePaneChrome.headerPixelHeight + Int((size.height - composer.frame.maxY) * WorkspaceDisplay.scale)
        let sendPoint = submit.convert(NSPoint(x: submit.bounds.midX, y: submit.bounds.midY), to: root)
        print("COMPOSER_FRAME x=\(originX + Int(composer.frame.minX * WorkspaceDisplay.scale)) y=\(composerTop) width=\(Int(composer.bounds.width * WorkspaceDisplay.scale)) height=\(Int(composer.bounds.height * WorkspaceDisplay.scale)) send=\(originX + Int(sendPoint.x * WorkspaceDisplay.scale)),\(WorkspacePaneChrome.headerPixelHeight + Int((size.height - sendPoint.y) * WorkspaceDisplay.scale)) enabled=\(submit.isEnabled) focused=\(owner.firstResponder === composer.linuxEditor) scrolls=\(composer.linuxEditorScrollView.hasVerticalScroller)")
        for card in decisionOrder where card.window != nil {
            // Window-pixel centres of a decision card's controls, for journeys that use them.
            var controls: [String] = []
            func centre(_ name: String, _ view: NSView) {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root)
                let x = originX + Int(point.x * WorkspaceDisplay.scale)
                let y = WorkspacePaneChrome.headerPixelHeight + Int((size.height - point.y) * WorkspaceDisplay.scale)
                controls.append("\(name.replacingOccurrences(of: " ", with: "_"))=\(x),\(y)")
            }
            func walk(_ view: NSView) {
                guard !view.isHidden else { return }
                if let button = view as? ThemedButton {
                    if button.isEnabled { centre(button.title, button) }
                    return
                }
                if let choice = view as? ConversationChoiceRow { centre(choice.accessibilityLabel() ?? "", choice); return }
                if let field = view as? NSTextField, field.isEditable { centre("field", field); return }
                view.subviews.forEach(walk)
            }
            walk(card)
            let kind = card === permissionCard ? "PERMISSION_FRAME \(presentedPermission ?? 0)" : "QUESTION_FRAME"
            print("\(kind) \(controls.joined(separator: " "))")
        }
        // Window-pixel centre and height of each mounted tool row, for journeys that open one.
        func tools(_ view: NSView) -> [ToolCallView] {
            ((view as? ToolCallView).map { [$0] } ?? []) + view.subviews.flatMap(tools)
        }
        for tool in tools(table) where !tool.visibleRect.isEmpty {
            let point = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: root)
            print("TOOL_FRAME \(originX + Int(point.x * WorkspaceDisplay.scale)),\(WorkspacePaneChrome.headerPixelHeight + Int((size.height - point.y) * WorkspaceDisplay.scale)) height=\(Int(tool.bounds.height)) open=\(transcript.expandedToolRows.count)")
        }
        print("CONVERSATION_FRAME \(runtime.id.uuidString) rows=\(table.numberOfRows) mounted=\(table.mountedViewCount) turns=\(runtime.completedTurns) prepared=\(prepared) dark=\(LinuxTheme.isDark) status=\(runtime.status)")
        fflush(nil)
    }

    private func publishSpeedAccessibility(window: OpaquePointer, originX: Int, size: NSSize) {
        guard let choice = runtime.speedChoice, !speedChip.isHidden else {
            tw_accessibility_conversation_speed(window, nil, nil, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            return
        }
        func pixels(_ view: NSView) -> (Int32, Int32, Int32, Int32) {
            let rect = view.convert(view.bounds, to: root)
            return (Int32(originX + Int(rect.minX * WorkspaceDisplay.scale)),
                Int32(WorkspacePaneChrome.headerPixelHeight + Int((size.height - rect.maxY) * WorkspaceDisplay.scale)),
                Int32(rect.width * WorkspaceDisplay.scale), Int32(rect.height * WorkspaceDisplay.scale))
        }
        let chip = pixels(speedChip)
        let menu = speedMenu.map(pixels) ?? (Int32(0), Int32(0), Int32(0), Int32(0))
        runtime.id.uuidString.withCString { identity in
            choice.title.withCString { title in
                tw_accessibility_conversation_speed(window, identity, title,
                    choice.enabled ? 1 : 0, owner.firstResponder === speedChip ? 1 : 0,
                    chip.0, chip.1, chip.2, chip.3,
                    menu.0, menu.1, menu.2, menu.3,
                    Int32(choice.selected.map { $0 ? 2 : 1 } ?? 0), Int32(speedSelected))
            }
        }
        if let speedMenu {
            for index in 0..<3 {
                guard let item = speedMenu.row(at: index)?.item else { continue }
                item.title.withCString { title in
                    (item.subtitle ?? "").withCString { detail in
                        tw_accessibility_conversation_speed_row(window, Int32(index), title, detail)
                    }
                }
            }
        }
    }

    private func publishContextAccessibility(window: OpaquePointer, originX: Int, size: NSSize) {
        guard !contextLabel.isHidden else {
            tw_accessibility_conversation_context(window, nil, nil, 0, 0, 0, 0)
            return
        }
        let rect = contextLabel.convert(contextLabel.bounds, to: root)
        let x = Int32(originX + Int(rect.minX * WorkspaceDisplay.scale))
        let y = Int32(WorkspacePaneChrome.headerPixelHeight
            + Int((size.height - rect.maxY) * WorkspaceDisplay.scale))
        runtime.id.uuidString.withCString { identity in
            contextLabel.stringValue.withCString { title in
                tw_accessibility_conversation_context(window, identity, title, x, y,
                    Int32(rect.width * WorkspaceDisplay.scale),
                    Int32(rect.height * WorkspaceDisplay.scale))
            }
        }
    }

    private func publishConfigurationAccessibility(window: OpaquePointer, originX: Int, size: NSSize) {
        func pixels(_ view: NSView) -> (Int32, Int32, Int32, Int32) {
            let rect = view.convert(view.bounds, to: root)
            return (Int32(originX + Int(rect.minX * WorkspaceDisplay.scale)),
                Int32(WorkspacePaneChrome.headerPixelHeight + Int((size.height - rect.maxY) * WorkspaceDisplay.scale)),
                Int32(rect.width * WorkspaceDisplay.scale), Int32(rect.height * WorkspaceDisplay.scale))
        }
        let identity = runtime.id.uuidString
        for kind in [ConfigurationKind.model, .mode, .effort] {
            let choice: (title: String, enabled: Bool)?
            let chip: ChipView
            switch kind {
            case .model: choice = runtime.modelChoice; chip = modelChip
            case .mode: choice = runtime.modeChoice; chip = modeChip
            case .effort: choice = runtime.effortChoice; chip = effortChip
            }
            guard let choice, !chip.isHidden else {
                tw_accessibility_conversation_configuration_chip(window, nil,
                    Int32(kind.rawValue), nil, 0, 0, 0, 0, 0, 0)
                continue
            }
            let bounds = pixels(chip)
            identity.withCString { key in
                choice.title.withCString { title in
                    tw_accessibility_conversation_configuration_chip(window, key,
                        Int32(kind.rawValue), title, choice.enabled ? 1 : 0,
                        owner.firstResponder === chip ? 1 : 0,
                        bounds.0, bounds.1, bounds.2, bounds.3)
                }
            }
        }
        guard let kind = configurationKind, let configurationMenu else {
            tw_accessibility_conversation_configuration_menu(window, nil, 0, 0, 0, 0, 0, 0)
            return
        }
        let menu = pixels(configurationMenu)
        identity.withCString { key in
            tw_accessibility_conversation_configuration_menu(window, key,
                Int32(kind.rawValue), menu.0, menu.1, menu.2, menu.3,
                Int32(configurationFirst))
        }
        for (slot, row) in configurationRows.enumerated() {
            let index = configurationFirst + slot
            guard configurationChoices.indices.contains(index) else { continue }
            let choice = configurationChoices[index]
            let bounds = pixels(row)
            choice.title.withCString { title in
                (choice.detail ?? "").withCString { detail in
                    tw_accessibility_conversation_configuration_row(window, Int32(index),
                        title, detail, choice.selected ? 1 : 0, choice.enabled ? 1 : 0,
                        index == configurationSelected ? 1 : 0,
                        bounds.0, bounds.1, bounds.2, bounds.3)
                }
            }
        }
    }

    func handle(_ input: TWEvent, window: OpaquePointer) {
        var input = input
        switch input.kind {
        case 6, 46:
            if configurationKind != nil { dismissConfigurationChoice() }
            if let text = String(validatingCString: tw_event_text(&input)) {
                activeTextView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case 19, 47:
            if let text = String(validatingCString: tw_event_text(&input)) {
                let lengths = text.unicodeScalars.map { String($0).utf16.count }
                let start = min(max(0, Int(input.textCursor)), lengths.count)
                let end = min(start + max(0, Int(input.textSelectionLength)), lengths.count)
                activeTextView.setMarkedText(text, selectedRange: NSRange(location: lengths.prefix(start).reduce(0, +),
                    length: lengths[start..<end].reduce(0, +)), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case 7, 48:
            guard input.action != 3 else { return }
            let event = WindowHarness.composerKeyEvent(input)
            if configurationKind != nil {
                switch event.keyCode {
                case 53: dismissConfigurationChoice()
                case 126: highlightConfiguration(max(0, configurationSelected - 1))
                case 125: highlightConfiguration(min(configurationChoices.count - 1, configurationSelected + 1))
                case 115: highlightConfiguration(0)
                case 119: highlightConfiguration(configurationChoices.count - 1)
                case 116: highlightConfiguration(max(0, configurationSelected - configurationVisibleCount))
                case 121: highlightConfiguration(min(configurationChoices.count - 1,
                    configurationSelected + configurationVisibleCount))
                case 36, 49, 76: chooseConfiguration(configurationSelected)
                default: dismissConfigurationChoice()
                }
            } else if speedOpen {
                switch event.keyCode {
                case 53: dismissSpeedChoice()
                case 126: highlightSpeed(max(0, speedSelected - 1))
                case 125: highlightSpeed(min(2, speedSelected + 1))
                case 36, 49, 76: chooseSpeed(speedSelected)
                default: dismissSpeedChoice()
                }
            } else if input.modifiers & (4 | 8) != 0, Int(input.key) == 118 {
                paste(window: window)
            }
            else if input.modifiers & (4 | 8) != 0, Int(input.key) == 97,
                    owner.firstResponder is ThemedTableView {
                _ = owner.dispatchToContent(event)
            }
            else if input.modifiers & (4 | 8) != 0, Int(input.key) == 97 {
                activeTextView.selectAll(nil)
            }
            else { _ = owner.dispatchToContent(event) }
        case 14: paste(window: window)
        case 15, 17, 16:
            if input.kind == 16, configurationKind != nil {
                let step = input.key > 0 ? -1 : 1
                highlightConfiguration(max(0, min(configurationChoices.count - 1,
                    configurationSelected + step)))
                updateState()
                return
            }
            let type: NSEvent.EventType = input.kind == 16 ? .scrollWheel
                : input.kind == 17 ? .leftMouseDragged
                : input.action == 3 ? .leftMouseUp : .leftMouseDown
            let point = NSPoint(x: CGFloat(input.x) / WorkspaceDisplay.scale, y: root.bounds.height - CGFloat(input.y) / WorkspaceDisplay.scale)
            var modifiers: NSEvent.ModifierFlags = []
            if input.modifiers & 1 != 0 { modifiers.insert(.shift) }
            if input.modifiers & 2 != 0 { modifiers.insert(.option) }
            if input.modifiers & 4 != 0 { modifiers.insert(.control) }
            if input.modifiers & 8 != 0 { modifiers.insert(.command) }
            _ = owner.dispatchToContent(NSEvent(type: type, locationInWindow: point,
                modifierFlags: modifiers,
                scrollingDeltaY: input.kind == 16 ? CGFloat(input.key) : 0,
                clickCount: max(1, Int(input.clickCount))))
            if input.kind == 16 {
                followTail = scroll.contentView.bounds.maxY >= table.frame.maxY - 1
            }
            _ = tw_workspace_editor_focus(window, owner.firstResponder is NSTextView ? 1 : 0)
        default: break
        }
        updateState()
    }

    private func paste(window: OpaquePointer) {
        let view = activeTextView
        guard view === composer.linuxEditor else { view.paste(nil); return }
        ComposerClipboardPaste.paste(into: composer)
    }

    /// Native text input reaches the focused text view: a decision card's field editor while
    /// one is editing, the prompt otherwise.
    private var activeTextView: NSTextView { (owner.firstResponder as? NSTextView) ?? composer.linuxEditor }
}

extension WorkspaceConversationPane: ConversationTranscriptSurface {
    func transcriptPreparedPages(at index: Int) -> [[String]]? {
        preparedMarkdownPages[index]
    }

    enum SurfaceItemID: Hashable {
        case streaming
        case decision(ObjectIdentifier)
        case truncation
    }

    enum SurfaceItemContent {
        case streaming(ProseLabel)
        case decision(NSView)
        case truncation(NSView)
    }

    func transcriptView(for content: SurfaceItemContent, id: SurfaceItemID) -> NSView {
        switch content {
        case .streaming(let view): return view
        case .decision(let view), .truncation(let view): return view
        }
    }

    func transcriptRhythm(for content: SurfaceItemContent, id: SurfaceItemID) -> Design.Chat.Rhythm {
        switch content {
        case .streaming: return .answer
        case .decision: return .chrome
        case .truncation: return .chrome
        }
    }
}
#endif
