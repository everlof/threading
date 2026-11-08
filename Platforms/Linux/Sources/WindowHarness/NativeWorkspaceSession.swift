#if os(Linux)
import AppKit
import Foundation
import Glibc
import ThreadingPTYClient
import ThreadingPTYHostKit
@testable import CoreSlice

struct NativeConfigurationChoice {
    let id: String?
    let title: String
    let detail: String?
    let selected: Bool
    var enabled = true
}

enum NativeSessionActivity: Equatable {
    case idle
    case loading
    case working
    case readyWithBackgroundWork
    case awaitingUser

    var showsWorkingMark: Bool { self == .loading || self == .working }
}

/// A saved native conversation in the ordinary workspace. File/account/replay work and durable
/// updates use one serial worker per retained runtime. Idle residency is bounded by the shared
/// process-retention policy, while unfinished work remains protected.
@MainActor
final class NativeWorkspaceSession {
    private struct Prepared: Sendable {
        var session: AgentSession
        let projectID: ProjectID
        let directory: String
        let plan: AgentLaunchPlan
        var fastServiceTier: String?
        let appDefaultPermissionMode: AgentPermissionMode?
        let speedCatalogue: ComposerModelCatalog
        let hiddenModelIDs: Set<String>
        let observedTranscriptURL: URL?
        let observedTranscriptStartingLength: UInt64
        var events: [StreamEvent]
        let truncated: Bool
        /// The provider replays this conversation's history itself, over its protocol, once the
        /// agent starts; there is no local transcript to read.
        let replaysOverProtocol: Bool
    }

    let id: SessionID
    private let store: String
    private let socket: String
    private let shell: String
    private let executables: [AgentKind: String]
    private let worker: DispatchQueue
    private var prepared: Prepared?
    private var stream: (any ConversationStreamSession)?
    private var timeline: ConversationTimeline
    private var attachmentScanner: LinuxNativeAttachmentScanner?
    private var initialPrompt: String?
    private var restoreAtStartup: Bool
    private var waitForHostedStop: Bool
    private(set) var revision = 0
    private(set) var status = "Loading conversation…"
    private(set) var failure: String?
    private(set) var stopped = false
    var onRow: ((Int, ConversationTimeline.Row, [[String]]?) -> Void)?
    var onStreaming: ((String?) -> Void)?
    var onChange: (() -> Void)?
    var onRetentionChange: (() -> Void)?
    var onSnoozeWakeReason: ((SessionWakeReason) -> Void)?
    private var observedPermissionID: Int?
    private var observedQuestionIDs: Set<UUID> = []
    private var lastPendingOutcome: Bool?
    private var lastRetentionFacts: SessionProcessRetentionCandidate?
    private var lastCompletedTurns = 0
    private var completionAwaitingOutcome = false
    /// Fired when the request at the head of the permission queue changes.
    var onPermissionChange: (() -> Void)?
    private struct PendingPermission {
        let id: Int
        let request: PermissionRequest
        let decide: PermissionBroker.Completion
    }
    /// Requests the provider is blocked on, answered one at a time in arrival order.
    private var permissionQueue: [PendingPermission] = []
    private var permissionSerial = 0
    /// The posture actually sent to this process. An inherited setting edited while it runs
    /// cannot change the permission broker until the next launch.
    private var runningPermissionMode: AgentPermissionMode?
    /// The head of the queue: the one request the pane presents.
    var pendingPermission: (id: Int, request: PermissionRequest)? {
        permissionQueue.first.map { ($0.id, $0.request) }
    }
    /// Fired when a provider question arrives or leaves.
    var onQuestionsChange: (() -> Void)?
    /// Questions the provider asked, in arrival order, each with its one-shot answer.
    private(set) var questions: [(request: ConversationQuestionRequest, answer: ([String: String]?) -> Void)] = []
    /// The session's own mode, for a runtime that has modes; nil asks for everything else.
    var permissionMode: AgentPermissionMode? {
        if stream?.isRunning == true { return runningPermissionMode }
        return prepared.flatMap { prepared in
            guard prepared.session.kind.supportsPermissionModes else { return nil }
            return NewChatDefaults.permissionMode(selected: prepared.session.permissionMode,
                appDefault: prepared.appDefaultPermissionMode)
        }
    }
    private var pendingRenderBytes = 0
    private var pendingRenderCount = 0
    private var launching = false
    private var replaying = true
    /// The agent is running and its provider is replaying the saved history to it.
    private var loadingHistory = false
    /// Claude restates the complete in-flight task list; a completed foreground turn can
    /// still continue through one of those tasks while the composer accepts input.
    private var backgroundTaskCount = 0
    private var launchRecordedAt: Date?
    private var speedChangeInFlight = false
    private var modelChangeInFlight = false
    private var effortChangeInFlight = false
    private var modeChangeInFlight = false
    private var observedMode: AgentPermissionMode?
    private var observedFileLength: UInt64 = 0
    private var observedScanScheduled = false
    private var observedScanInFlight = false
    private var observedScanNeeded = false
    private(set) var completedTurns = 0
    /// The newest provider reading survives a later Ready status with no usage fields.
    private(set) var contextReading: (tokens: Int, window: Int?)?
    var rowsPrepared: Bool { !replaying && pendingRenderCount == 0 }
    // Rows are an immutable value snapshot; none of the worker's copies is mutated by the UI.
    private struct RowSnapshot: @unchecked Sendable { let rows: [ConversationTimeline.Row] }
    var canSend: Bool {
        !stopped && !waitForHostedStop && !launching && !replaying && !loadingHistory
            && failure == nil && prepared != nil && (stream?.canSend ?? true)
    }
    /// Row presentation follows the provider process or its in-flight launch, not whether
    /// this reusable pane remains cached after the provider exits.
    var presentsActiveAgent: Bool {
        !stopped && (replaying || launching || stream?.isRunning == true)
    }
    var canInterrupt: Bool { stream?.canInterrupt ?? false }
    /// The same foreground/continuation distinction used by macOS Snooze. Startup history
    /// replay and launch are not a new turn and cannot later spend a completion wake.
    var hasPendingOutcome: Bool {
        stream?.hasActiveTurn == true || backgroundTaskCount > 0
    }
    var conversationUseAt: Date? { prepared?.session.lastUsedAt }
    /// Already-owned facts only: retention must never open a transcript or build a pane.
    func retentionCandidate(lastWarmUseAt: Date, isLocallyVisible: Bool)
        -> SessionProcessRetentionCandidate? {
        guard let prepared, !stopped else { return nil }
        let process: SessionProcessState = launching || replaying || loadingHistory
            || waitForHostedStop ? .starting
            : stream?.isRunning == true ? .ready : .dormant
        let turn: SessionTurnState = stream?.hasActiveTurn == true
            ? .inFlight(.reported) : .none
        let blocker: SessionRuntimeBlocker = pendingPermission != nil || !questions.isEmpty
            ? .awaitingUser : .none
        let runtime = SessionRuntimeSnapshot(
            process: process, turn: turn,
            continuation: backgroundTaskCount > 0 ? .delegated : .none,
            blocker: blocker, activity: .idle, reportsOwnTurns: true)
        return SessionProcessRetentionCandidate(
            sessionID: id, lastWarmUseAt: lastWarmUseAt,
            isResumable: prepared.session.resumeState.isResumable,
            isHostBacked: rootProcessIdentifier != nil, runtime: runtime,
            isLocallyVisible: isLocallyVisible, hasRemoteViewers: false,
            hasPendingInput: !canSend, hasPendingCheckoutMove: prepared.session.pendingCheckoutMove != nil)
    }
    var activity: NativeSessionActivity {
        guard !stopped, failure == nil else { return .idle }
        if pendingPermission != nil || !questions.isEmpty { return .awaitingUser }
        if launching || replaying || loadingHistory { return .loading }
        if stream?.hasActiveTurn == true { return .working }
        return stream?.isRunning == true && backgroundTaskCount > 0
            ? .readyWithBackgroundWork : .idle
    }
    /// The selected sidebar row uses the same beam view as macOS. Its facts come from the
    /// already loaded session catalogue, so repainting a row never reads provider files.
    var sidebarWorkload: AgentWorkload {
        // The row's loading mark is useful during history replay, but macOS measures the beam
        // only for a provider turn that is actually working.
        guard activity == .working else { return .none }
        guard let prepared else {
            return AgentWorkload(workingCount: 1, anyAtTopEffort: false)
        }
        let catalogue = prepared.speedCatalogue
        let option = catalogue.option(for: prepared.session.model ?? catalogue.defaultModel)
        let inherited = catalogue.defaultEffort.flatMap { effort in
            option?.supports(reasoningEffort: effort) == true ? effort : nil
        }
        let effectiveEffort = prepared.session.reasoningEffort ?? inherited
            ?? option?.defaultReasoningLevel
        let atTopEffort = option?.reasoningLevels.last?.effort == effectiveEffort
            && effectiveEffort != nil
        return AgentWorkload(workingCount: 1, anyAtTopEffort: atTopEffort)
    }
    var rootProcessIdentifier: Int32? { stream?.rootProcessIdentifier }
    var sessionKind: AgentKind? { prepared?.session.kind }
    var speedChoice: (title: String, symbolName: String, selected: Bool?, enabled: Bool)? {
        guard let prepared,
              prepared.speedCatalogue.supportsFastMode(kind: prepared.session.kind,
                                                        model: prepared.session.model) else { return nil }
        let chip = ConversationSpeedMenuContent.chip(
            effective: LinuxGeneralSettings.effectiveSpeed(selected: prepared.session.fastMode,
                kind: prepared.session.kind,
                configured: prepared.speedCatalogue.inheritedFastMode))
        return (chip.title, chip.symbolName,
                prepared.session.fastMode, !stopped && !launching && !speedChangeInFlight
                    && !modelChangeInFlight && !effortChangeInFlight
                    && !modeChangeInFlight
                    && (stream == nil || stream is FastModeConversation || stream?.canSend == true))
    }

    var modelChoice: (title: String, enabled: Bool)? {
        guard let prepared, !prepared.speedCatalogue.options.isEmpty else { return nil }
        let selected = prepared.session.model ?? prepared.speedCatalogue.defaultModel
        let title = prepared.speedCatalogue.option(for: selected)?.displayName
            ?? selected ?? "Default model"
        let canChange = stream?.acceptsConfigurationChange ?? true
        return (title, !stopped && !launching && !replaying && !modelChangeInFlight
                && !speedChangeInFlight && !effortChangeInFlight && !modeChangeInFlight && canChange)
    }

    var modelChoices: [NativeConfigurationChoice] {
        guard let prepared else { return [] }
        let catalogue = prepared.speedCatalogue
        let selected = prepared.session.model
        let defaultModel = catalogue.defaultModel
        let markedDefault = catalogue.option(for: defaultModel) != nil
        var rows: [NativeConfigurationChoice] = []
        if !markedDefault {
            rows.append(NativeConfigurationChoice(id: nil, title: "Default model",
                detail: "Uses the agent's configured model.", selected: selected == nil))
        }
        if let selected, catalogue.option(for: selected) == nil {
            rows.append(NativeConfigurationChoice(id: selected, title: selected,
                detail: "This model is no longer in the account catalogue.", selected: true))
        }
        for option in catalogue.options {
            let isDefault = option.identifier == defaultModel
            guard isDefault || option.identifier == selected ||
                !prepared.hiddenModelIDs.contains(option.identifier) else { continue }
            rows.append(NativeConfigurationChoice(id: isDefault ? nil : option.identifier,
                title: option.displayName,
                detail: isDefault ? "Account default" : nil,
                selected: isDefault ? (selected == nil || selected == option.identifier)
                    : selected == option.identifier))
        }
        return rows
    }

    var effortChoice: (title: String, enabled: Bool)? {
        guard let prepared, prepared.session.kind == .codex,
              let option = prepared.speedCatalogue.option(for:
                  prepared.session.model ?? prepared.speedCatalogue.defaultModel),
              !option.reasoningLevels.isEmpty else { return nil }
        let selected = prepared.session.reasoningEffort
        let inherited = prepared.speedCatalogue.defaultEffort.flatMap { option.supports(reasoningEffort: $0) ? $0 : nil }
            ?? option.defaultReasoningLevel
        let effective = selected ?? inherited
        let title = option.reasoningLevels.first(where: { $0.effort == effective })?.displayName
            ?? effective.map { AgentReasoningLevel(effort: $0, description: "").displayName }
            ?? "Default effort"
        let canChange = stream?.canSend ?? true
        return (title, !stopped && !launching && !replaying && !modelChangeInFlight
                && !speedChangeInFlight && !effortChangeInFlight && !modeChangeInFlight && canChange)
    }

    var modeChoice: (title: String, enabled: Bool)? {
        guard let prepared else { return nil }
        let kind = prepared.session.kind
        guard kind.supportsPermissionModes else { return nil }
        let selected = prepared.session.permissionMode
        let inherited = prepared.appDefaultPermissionMode
            ?? prepared.speedCatalogue.inheritedPermissionMode
        let observed = stream?.isRunning == true ? observedMode : nil
        let title = PermissionModeMenuContent.chipTitle(for: kind, selected: selected,
            nameableMode: inherited ?? observed)
        return (title, !stopped && !launching && !replaying && !modeChangeInFlight
                && !modelChangeInFlight && !effortChangeInFlight && !speedChangeInFlight)
    }

    var modeChoices: [NativeConfigurationChoice] {
        guard let prepared else { return [] }
        let kind = prepared.session.kind
        guard kind.supportsPermissionModes else { return [] }
        let inherited = prepared.appDefaultPermissionMode
            ?? prepared.speedCatalogue.inheritedPermissionMode
        let observed = stream?.isRunning == true ? observedMode : nil
        let lastUsed = inherited == nil ? observed ?? prepared.speedCatalogue.lastUsedPermissionMode : nil
        let selected = prepared.session.permissionMode
        let appliesOnRestart = !(stream?.acceptsConfigurationChange == true
            && stream is PermissionModeSwitchableConversation)
        let note = appliesOnRestart ? L10n.string("Applies the next time this chat starts.") : nil
        return PermissionModeMenuContent.rows(for: kind, selected: selected,
            governingMode: inherited, reportedMode: lastUsed, note: note).compactMap { entry in
            guard case .item(let item) = entry else { return nil }
            let mode = item.representedValue as? AgentPermissionMode
            return NativeConfigurationChoice(id: mode?.rawValue, title: item.title,
                detail: item.subtitle, selected: item.isSelected, enabled: item.isEnabled)
        }
    }

    var effortChoices: [NativeConfigurationChoice] {
        guard let prepared,
              let option = prepared.speedCatalogue.option(for:
                  prepared.session.model ?? prepared.speedCatalogue.defaultModel) else { return [] }
        let inherited = prepared.speedCatalogue.defaultEffort.flatMap { option.supports(reasoningEffort: $0) ? $0 : nil }
            ?? option.defaultReasoningLevel
        let inheritedName = option.reasoningLevels.first(where: { $0.effort == inherited })?.displayName
            ?? "Default effort"
        var rows = [NativeConfigurationChoice(id: nil, title: inheritedName,
            detail: "Uses the account or model default.", selected: prepared.session.reasoningEffort == nil)]
        rows += option.reasoningLevels.map { level in
            NativeConfigurationChoice(id: level.effort, title: level.displayName,
                detail: level.description.isEmpty ? nil : level.description,
                selected: prepared.session.reasoningEffort == level.effort)
        }
        return rows
    }

    init(store: String, socket: String, id: SessionID, shell: String,
         executables: [AgentKind: String], initialPrompt: String? = nil,
         restoreAtStartup: Bool = false, waitForHostedStop: Bool = false) {
        self.store = store
        self.socket = socket
        self.shell = shell
        self.executables = executables
        self.id = id
        self.initialPrompt = initialPrompt
        self.restoreAtStartup = restoreAtStartup
        self.waitForHostedStop = waitForHostedStop
        worker = DispatchQueue(label: "codes.threading.linux.native-workspace.\(id.uuidString)", qos: .userInitiated)
        timeline = ConversationTimeline(sessionID: id, chartDecoder: { _, _ in nil })
        PermissionBroker.register(self)
        worker.async { [weak self] in
            let result = Result { try Self.prepare(store: store, id: id, shell: shell, executables: executables) }
            NativeConversationDelivery.callbacks.receive { self?.loaded(result) }
        }
    }

    private func loaded(_ result: Result<Prepared, Error>) {
        guard !stopped else { return }
        switch result {
        case .failure(let error): report(String(describing: error))
        case .success(let prepared):
            var retained = prepared
            retained.events = []
            observedMode = nil
            observedFileLength = prepared.observedTranscriptStartingLength
            self.prepared = retained
            attachmentScanner = LinuxNativeAttachmentScanner(
                sessionID: id, kind: prepared.session.kind)
            for event in prepared.events {
                retainContextReading(from: event)
                _ = timeline.apply(event)
            }
            let snapshot = RowSnapshot(rows: timeline.rows)
            let truncated = prepared.truncated
            worker.async { [weak self] in
                for (index, row) in snapshot.rows.enumerated() {
                    let pages = Self.markdownPages(for: row)
                    let single = RowSnapshot(rows: [row])
                    NativeConversationDelivery.callbacks.receive {
                        guard let self, !self.stopped else { return }
                        self.onRow?(index, single.rows[0], pages)
                        self.changed()
                    }
                }
                NativeConversationDelivery.callbacks.receive {
                    guard let self, !self.stopped else { return }
                    if truncated {
                        self.onRow?(Int.max, .notice("Earlier transcript content was truncated.", kind: .muted), nil)
                    }
                    self.replaying = false
                    self.status = self.waitForHostedStop ? "Waiting for prior agent…" : "Ready"
                    self.changed()
                    if let prompt = self.initialPrompt, !prepared.session.hasLaunched {
                        self.initialPrompt = nil
                        _ = self.send(prompt)
                    }
                    if let prepared = self.prepared,
                       !self.waitForHostedStop,
                       (self.restoreAtStartup || prepared.replaysOverProtocol),
                       prepared.session.hasLaunched, prepared.session.resumeState.isResumable {
                        self.launch(prompt: nil)
                    }
                }
            }
            changed()
        }
    }

    /// The daemon's pipe child has ended. Resume from the provider transcript through the
    /// normal saved-session launch; a fresh client cannot rejoin a half-finished wire stream.
    func resumeAfterHostedStop() {
        guard waitForHostedStop, !stopped else { return }
        waitForHostedStop = false
        restoreAtStartup = true
        guard !replaying, let prepared,
              prepared.session.hasLaunched, prepared.session.resumeState.isResumable else {
            changed()
            return
        }
        launch(prompt: nil)
    }

    /// A background runtime has no transcript view. Build its retained rows only when a pane
    /// actually attaches; the worker prepares Markdown and the UI receives ordered row values.
    func replayCurrentRows() {
        let snapshot = RowSnapshot(rows: timeline.rows)
        let truncated = prepared?.truncated == true
        worker.async { [weak self] in
            for (index, row) in snapshot.rows.enumerated() {
                let pages = Self.markdownPages(for: row)
                let single = RowSnapshot(rows: [row])
                NativeConversationDelivery.callbacks.receive {
                    guard let self, !self.stopped else { return }
                    self.onRow?(index, single.rows[0], pages)
                }
            }
            if truncated {
                NativeConversationDelivery.callbacks.receive { [weak self] in
                    self?.onRow?(Int.max,
                        .notice("Earlier transcript content was truncated.", kind: .muted), nil)
                }
            }
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard canSend, prepared != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.prefix(65_537).count <= 65_536 else { return false }
        if stream == nil {
            noteWork(started: true)
            apply(.userMessage(text))
            launch(prompt: text)
            return true
        }
        guard stream?.send(text) == true else { changed(); return false }
        noteWork(started: true)
        apply(.userMessage(text))
        status = "Working"
        changed()
        return true
    }

    /// Starts the agent with the turn that asked for it, or with none for a conversation whose
    /// history the provider replays over its protocol.
    private func launch(prompt: String?) {
        guard let prepared, stream == nil, !launching else { return }
        launching = true
        status = prompt == nil ? "Loading conversation…" : "Starting agent…"
        changed()
        let store = store, socket = socket
        worker.async { [weak self] in
            let result = Result {
                let child = try ConversationPreparedChild(plan: prepared.plan, sessionID: prepared.session.id,
                    host: Self.hostPlan(prepared, socket: socket))
                let date = Date()
                try Self.withDatabase(store: store) { database in
                    guard let record = try database.sessionRecord(id: prepared.session.id),
                          record.project.id == prepared.projectID,
                          record.session.usesNativeUI,
                          record.session.kind == prepared.session.kind,
                          record.session.accountHandle == prepared.session.accountHandle,
                          record.session.lastActiveAt == prepared.session.lastActiveAt else {
                        throw WindowFailure("Saved conversation changed before launch admission.")
                    }
                    var session = record.session
                    AgentLaunchRecording.apply(prepared.plan, to: &session, at: date)
                    try database.saveSession(session, in: record.project.id, position: record.position)
                }
                return Started(child: child, recordedAt: date)
            }
            NativeConversationDelivery.callbacks.receive {
                self?.started(result, prepared: prepared, prompt: prompt)
            }
        }
    }

    private struct Started: Sendable {
        let child: ConversationPreparedChild
        let recordedAt: Date
    }

    private func started(_ result: Result<Started, Error>, prepared: Prepared, prompt: String?) {
        guard !stopped else { return }
        launching = false
        switch result {
        case .failure(let error):
            if prompt != nil { apply(.turnFinished(text: nil, outcome: .failed, metrics: .empty)) }
            report(String(describing: error))
        case .success(let started):
            launchRecordedAt = started.recordedAt
            let stream = makeStream(prepared, child: started.child)
            backgroundTaskCount = 0
            runningPermissionMode = prepared.session.kind.supportsPermissionModes
                ? NewChatDefaults.permissionMode(selected: prepared.session.permissionMode,
                    appDefault: prepared.appDefaultPermissionMode)
                : nil
            self.stream = stream
            stream.onEvent = { [weak self] in self?.apply($0) }
            stream.onInteractionAvailabilityChange = { [weak self] in self?.interactionChanged() }
            stream.onLaunchFailure = { [weak self] in self?.report(String(describing: $0)) }
            if let asking = stream as? QuestionAskingConversation {
                asking.onQuestion = { [weak self] request, answer in
                    guard let self else { answer(nil); return }
                    self.receiveQuestion(request, answer: answer)
                }
                asking.onQuestionResolved = { [weak self] in self?.retireQuestion($0) }
            }
            stream.onExit = { [weak self] status in
                guard let self else { return }
                self.status = "Agent exited (\(status))"
                self.observedMode = nil
                self.runningPermissionMode = nil
                self.observedScanNeeded = false
                self.settlePermissions(reason: "Denied — the agent exited.")
                self.retireQuestions()
                self.changed()
                self.persist { session in session.lastExitCode = status; session.lastActiveAt = Date() }
            }
            stream.start()
            if let fastMode = ComposerSpeedLaunch.launchOverride(
                selected: prepared.session.fastMode, kind: prepared.session.kind,
                model: prepared.session.model, catalogue: prepared.speedCatalogue),
               let claude = stream as? ClaudeStreamSession {
                claude.setFastMode(fastMode) { [weak self] result in
                    if case .failure(let error) = result {
                        NativeConversationDelivery.callbacks.receive {
                            self?.report("Could not apply conversation speed: \(error)")
                        }
                    }
                }
            }
            guard let prompt else {
                loadingHistory = true
                interactionChanged()
                return
            }
            if stream.send(prompt) { noteWork(started: true); status = "Working"; changed() }
            else { report("The agent refused the opening message.") }
        }
    }

    /// A provider replaying history accepts a turn once the replay is over; that is when the
    /// conversation is ready.
    private func interactionChanged() {
        // ACP and Codex accept a queued prompt before their resume handshake finishes. Their
        // canSend flag alone does not prove an old session has actually been loaded.
        let waitsForSessionHandshake = stream is ACPStreamSession || stream is CodexStreamSession
        if loadingHistory, !waitsForSessionHandshake, stream?.canSend == true {
            loadingHistory = false
            status = "Ready"
        }
        requestObservedModeScan()
        changed()
    }

    func interrupt() {
        guard let stream, stream.canInterrupt else { return }
        stream.interrupt { [weak self] receipt in
            if case .failed(let reason) = receipt { self?.report(reason) }
            else { self?.changed() }
        }
    }

    /// Keep the saved startup choice and the active transport in step. Inheritance from the
    /// provider has no live reset request; that choice takes effect on the next launch.
    func selectModel(_ model: String?) {
        guard let prepared, modelChoice?.enabled == true,
              model == nil || prepared.speedCatalogue.option(for: model) != nil,
              model != prepared.session.model else { return }
        let selectedOption = prepared.speedCatalogue.option(for: model ?? prepared.speedCatalogue.defaultModel)
        let wasFast = LinuxGeneralSettings.effectiveSpeed(selected: prepared.session.fastMode,
            kind: prepared.session.kind,
            configured: prepared.speedCatalogue.inheritedFastMode) ?? false
        let resetFast = wasFast && !prepared.speedCatalogue.supportsFastMode(
            kind: prepared.session.kind, model: model)
        let resetEffort = prepared.session.reasoningEffort.map { effort in
            selectedOption.map { !$0.reasoningLevels.isEmpty && !$0.supports(reasoningEffort: effort) } ?? false
        } ?? false
        modelChangeInFlight = true
        changed()
        if let switcher = stream as? ModelSwitchableConversation {
            switcher.setModel(model) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.applyModelChange(model, resetFast: resetFast, resetEffort: resetEffort)
                case .failure(let error):
                    self.modelChangeInFlight = false
                    self.appendLocalNotice("Could not change conversation model: \(error)", kind: .error)
                }
            }
        } else {
            applyModelChange(model, resetFast: resetFast, resetEffort: resetEffort)
        }
    }

    private func applyModelChange(_ model: String?, resetFast: Bool, resetEffort: Bool) {
        if resetFast, let switcher = stream as? FastModeConversation {
            switcher.setFastMode(false) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.saveModel(model, resetFast: true, resetEffort: resetEffort)
                case .failure(let error):
                    self.saveModel(model, resetFast: false, resetEffort: resetEffort,
                        warning: "The model changed, but Fast could not be turned off: \(error)")
                }
            }
        } else {
            saveModel(model, resetFast: resetFast, resetEffort: resetEffort)
        }
    }

    private func saveModel(_ model: String?, resetFast: Bool, resetEffort: Bool,
                           warning: String? = nil) {
        saveSessionConfiguration({ session in
            session.model = model
            if resetFast { session.fastMode = false }
            if resetEffort { _ = session.setReasoningEffort(nil) }
        }) { [weak self] result in
            guard let self else { return }
            self.modelChangeInFlight = false
            switch result {
            case .success:
                if let warning { self.appendLocalNotice(warning, kind: .error) }
                else { self.changed() }
            case .failure(let error):
                self.appendLocalNotice("Could not save conversation model: \(error)", kind: .error)
            }
        }
    }

    func selectEffort(_ effort: String?) {
        guard let prepared, effortChoice?.enabled == true,
              let option = prepared.speedCatalogue.option(for:
                  prepared.session.model ?? prepared.speedCatalogue.defaultModel),
              effort == nil || option.supports(reasoningEffort: effort),
              effort != prepared.session.reasoningEffort else { return }
        effortChangeInFlight = true
        changed()
        saveSessionConfiguration({ session in _ = session.setReasoningEffort(effort) }) { [weak self] result in
            guard let self else { return }
            self.effortChangeInFlight = false
            switch result {
            case .success: self.changed()
            case .failure(let error):
                self.appendLocalNotice("Could not save conversation effort: \(error)", kind: .error)
            }
        }
    }

    func selectMode(_ mode: AgentPermissionMode?) {
        guard let prepared, modeChoice?.enabled == true,
              mode != prepared.session.permissionMode else { return }
        modeChangeInFlight = true
        changed()
        let persist = { [weak self] (changedLiveAgent: Bool) in
            guard let self else { return }
            self.saveSessionConfiguration({ $0.permissionMode = mode }) { [weak self] result in
                guard let self else { return }
                self.modeChangeInFlight = false
                switch result {
                case .success: self.changed()
                case .failure(let error):
                    self.appendLocalNotice("Could not save conversation mode: \(error)", kind: .error)
                    if changedLiveAgent {
                        self.appendLocalNotice("The agent changed mode, but the saved session did not.", kind: .error)
                    }
                }
            }
        }
        guard stream?.acceptsConfigurationChange == true,
              let switcher = stream as? PermissionModeSwitchableConversation else {
            persist(false)
            return
        }
        guard let resolved = mode else {
            persist(false)
            let note = prepared.appDefaultPermissionMode == nil
                ? "This chat keeps the permission mode it is running with. The agent's own setting applies the next time it starts."
                : "This chat keeps the permission mode it is running with. The default in Settings ▸ Chats applies the next time it starts."
            appendLocalNotice(note, kind: .muted)
            return
        }
        switcher.setPermissionMode(resolved) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.observedMode = resolved
                self.runningPermissionMode = resolved
                self.requestObservedModeScan()
                persist(true)
            case .failure(let error):
                self.modeChangeInFlight = false
                self.appendLocalNotice("Could not change conversation mode: \(error)", kind: .error)
            }
        }
    }

    private struct SavedConfiguration: Sendable {
        let session: AgentSession
        let refreshed: Prepared?
    }

    private func saveSessionConfiguration(
        _ edit: @escaping @Sendable (inout AgentSession) -> Void,
        completion: @escaping @MainActor @Sendable (Result<AgentSession, Error>) -> Void
    ) {
        guard let prepared else { return }
        let store = store, id = id, shell = shell, executables = executables
        let launchedAt = launchRecordedAt
        let hasStream = stream != nil
        worker.async { [weak self] in
            let result = Result { () throws -> SavedConfiguration in
                let updated = try Self.withDatabase(store: store) { database in
                    guard let record = try database.sessionRecord(id: id),
                          record.project.id == prepared.projectID,
                          record.session.usesNativeUI,
                          record.session.kind == prepared.session.kind,
                          record.session.accountHandle == prepared.session.accountHandle,
                          (record.session.lastActiveAt == prepared.session.lastActiveAt
                              || launchedAt.map { record.session.lastActiveAt == $0 } == true)
                    else { throw WindowFailure("Conversation changed before its configuration could be saved.") }
                    var session = record.session
                    edit(&session)
                    try database.saveSession(session, in: record.project.id, position: record.position)
                    return session
                }
                let refreshed = hasStream ? nil : try Self.prepare(store: store, id: id,
                    shell: shell, executables: executables)
                return SavedConfiguration(session: updated, refreshed: refreshed)
            }
            NativeConversationDelivery.callbacks.receive { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let saved):
                    if var refreshed = saved.refreshed {
                        refreshed.events = []
                        self.prepared = refreshed
                    } else {
                        self.prepared?.session = saved.session
                        if let fastMode = saved.session.fastMode,
                           let catalogue = self.prepared?.speedCatalogue {
                            self.prepared?.fastServiceTier = ComposerSpeedLaunch.codexServiceTier(
                                fastMode, model: saved.session.model, catalogue: catalogue)
                        }
                    }
                    completion(.success(saved.session))
                }
            }
        }
    }

    func selectSpeed(_ choice: Bool?) {
        guard let prepared, speedChoice?.enabled == true else { return }
        guard choice != prepared.session.fastMode else { return }
        speedChangeInFlight = true
        changed()
        let liveSpeed = LinuxGeneralSettings.startupSpeed(for: prepared.session.kind)
            .resolve(selected: choice, configured: nil)
        if let liveSpeed, let claude = stream as? FastModeConversation {
            claude.setFastMode(liveSpeed) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.saveSpeed(choice)
                case .failure(let error):
                    self.speedChangeInFlight = false
                    self.appendLocalNotice("Could not change conversation speed: \(error)", kind: .error)
                }
            }
        } else {
            saveSpeed(choice)
        }
    }

    private func saveSpeed(_ choice: Bool?) {
        guard let prepared else { return }
        let store = store, id = id, shell = shell
        let hasStream = stream != nil
        let executables = executables
        let launchedAt = launchRecordedAt
        worker.async { [weak self] in
            let result = Result { () throws -> Prepared? in
                try Self.withDatabase(store: store) { database in
                    guard let record = try database.sessionRecord(id: id),
                          record.project.id == prepared.projectID,
                          record.session.kind == prepared.session.kind,
                          record.session.accountHandle == prepared.session.accountHandle,
                          (record.session.lastActiveAt == prepared.session.lastActiveAt
                              || launchedAt.map { record.session.lastActiveAt == $0 } == true)
                    else { throw WindowFailure("Conversation changed before its speed could be saved.") }
                    var session = record.session
                    session.fastMode = choice
                    try database.saveSession(session, in: record.project.id, position: record.position)
                }
                return hasStream ? nil : try Self.prepare(store: store, id: id,
                    shell: shell, executables: executables)
            }
            NativeConversationDelivery.callbacks.receive { [weak self] in
                guard let self else { return }
                self.speedChangeInFlight = false
                switch result {
                case .failure(let error):
                    self.appendLocalNotice("Could not save conversation speed: \(error)", kind: .error)
                case .success(let refreshed):
                    if var refreshed {
                        refreshed.events = []
                        self.prepared = refreshed
                    }
                    else {
                        self.prepared?.session.fastMode = choice
                        if self.prepared?.session.kind == .codex,
                           let current = self.prepared {
                            let launchSpeed = ComposerSpeedLaunch.launchOverride(
                                selected: choice, kind: current.session.kind,
                                model: current.session.model, catalogue: current.speedCatalogue)
                            // Provider inheritance has no live reset request. Keep the tier
                            // already running until relaunch when General also defers to it.
                            if let launchSpeed {
                                self.prepared?.fastServiceTier = ComposerSpeedLaunch.codexServiceTier(
                                    launchSpeed, model: current.session.model,
                                    catalogue: current.speedCatalogue)
                            }
                        }
                    }
                    if choice == nil, hasStream,
                       LinuxGeneralSettings.startupSpeed(for: prepared.session.kind) == .agentSetting {
                        self.appendLocalNotice("This chat keeps its current speed. The agent's setting applies the next time it starts.", kind: .muted)
                    } else { self.changed() }
                }
            }
        }
    }

    private func appendLocalNotice(_ message: String, kind: ConversationTimeline.NoticeKind) {
        let change = timeline.appendNotice(message, kind: kind)
        if case .appended(let index) = change { onRow?(index, timeline.rows[index], nil) }
        changed()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stream?.terminate()
        stream = nil
        runningPermissionMode = nil
        endPermissions()
        changed()
    }

    func closeForQuit(by deadline: Date, idleExpiresAt: Date? = nil) {
        guard !stopped else { return }
        if stream?.detachFromBackgroundHost(by: deadline, idleExpiresAt: idleExpiresAt) != true {
            stream?.terminate()
        }
        stopped = true
        stream = nil
        runningPermissionMode = nil
        endPermissions()
    }

    // MARK: - Permissions

    func requestPermission(_ request: PermissionRequest, completion: @escaping PermissionBroker.Completion) {
        guard !stopped else {
            completion(.deny(reason: "Denied — session ended."))
            return
        }
        permissionSerial += 1
        permissionQueue.append(PendingPermission(id: permissionSerial, request: request, decide: completion))
        if permissionQueue.count == 1 { permissionChanged() }
    }

    /// Answers the presented request, then settles any queued request that policy now answers
    /// before the next card is shown.
    func answerPermission(id: Int, _ decision: PermissionDecision) {
        guard let head = permissionQueue.first, head.id == id else { return }
        permissionQueue.removeFirst()
        head.decide(decision)
        while let next = permissionQueue.first,
              let automatic = PermissionBroker.automaticDecision(for: next.request, mode: permissionMode) {
            permissionQueue.removeFirst()
            next.decide(automatic)
        }
        permissionChanged()
    }

    /// A provider blocked on a card must not outlive the session that would have answered it.
    private func endPermissions() {
        PermissionBroker.unregister(id)
        settlePermissions(reason: "Denied — session ended.")
        retireQuestions()
    }

    // MARK: - Questions

    /// Bounded as the Mac bounds it; a duplicate or an overflow is declined at once.
    private func receiveQuestion(_ request: ConversationQuestionRequest,
                                 answer: @escaping ([String: String]?) -> Void) {
        guard !stopped, questions.count < ConversationQuestionRequest.Limits.pendingRequests,
              !questions.contains(where: { $0.request.id == request.id }) else {
            answer(nil)
            return
        }
        questions.append((request, answer))
        questionsChanged()
    }

    /// The card's answer, or nil for Cancel. The transport validates and replies once.
    func answerQuestion(_ id: UUID, _ answers: [String: String]?) {
        guard let index = questions.firstIndex(where: { $0.request.id == id }) else { return }
        let question = questions.remove(at: index)
        question.answer(answers)
        questionsChanged()
    }

    /// The provider settled or withdrew it; there is nothing left to answer.
    private func retireQuestion(_ id: UUID) {
        guard let index = questions.firstIndex(where: { $0.request.id == id }) else { return }
        questions.remove(at: index)
        questionsChanged()
    }

    /// A transport invalidates its own pending questions when it ends; only the cards go.
    private func retireQuestions() {
        guard !questions.isEmpty else { return }
        questions.removeAll()
        questionsChanged()
    }

    private func questionsChanged() {
        let current = Set(questions.map(\.request.id))
        if !current.subtracting(observedQuestionIDs).isEmpty {
            onSnoozeWakeReason?(.inputRequested)
        }
        observedQuestionIDs = current
        onQuestionsChange?()
        changed()
    }

    private func settlePermissions(reason: String) {
        let pending = permissionQueue
        permissionQueue.removeAll()
        for request in pending { request.decide(.deny(reason: reason)) }
        if !pending.isEmpty { permissionChanged() }
    }

    private func permissionChanged() {
        let current = pendingPermission?.id
        if current != nil && current != observedPermissionID {
            onSnoozeWakeReason?(.approvalRequested)
        }
        observedPermissionID = current
        onPermissionChange?()
        changed()
    }

    private nonisolated static func hostPlan(_ prepared: Prepared, socket: String) -> PTYHostChildPlan {
        PTYHostChildPlan(identity: .agentSession(prepared.session.id), factory: { events in
            let client = PTYHostClient(socketPath: socket, build: "linux-native-workspace",
                events: events, journal: { _, _ in })
            try client.connect()
            return client
        }, workingDirectory: prepared.directory)
    }

    private func makeStream(_ prepared: Prepared, child: ConversationPreparedChild) -> any ConversationStreamSession {
        let session = prepared.session
        let plan = prepared.plan
        let directory = prepared.directory
        switch session.kind {
        case .claude:
            return ClaudeStreamSession(sessionID: session.id, callbackDelivery: NativeConversationDelivery.callbacks,
                preparedChild: child, effort: session.reasoningEffort, plan: { plan })
        case .codex:
            return CodexStreamSession(sessionID: session.id, callbackDelivery: NativeConversationDelivery.callbacks,
                preparedChild: child, workingDirectory: directory, configurationProvider: { [weak self] in
                    CodexTurnConfiguration(model: self?.prepared?.session.model,
                        effort: self?.prepared?.session.reasoningEffort,
                        serviceTier: self?.prepared?.fastServiceTier)
                }, plan: { plan })
        case .grok, .cursor:
            // The working directory is the session's own checkout every time, fresh or resumed:
            // `session/load` accepts any cwd and rebinds the live session to whatever it is given.
            return ACPStreamSession(sessionID: session.id, callbackDelivery: NativeConversationDelivery.callbacks,
                preparedChild: child, workingDirectory: directory,
                profile: session.kind == .grok ? .grok : .cursor, plan: { plan })
        case .openCode:
            // Preparation refuses OpenCode before a child exists; see `prepare`.
            preconditionFailure("unsupported workspace native preparation")
        }
    }

    /// Coalesce streamed events into one bounded transcript read on this runtime's file worker.
    /// The process must have appended after preparation before an observation can name its mode.
    private func requestObservedModeScan() {
        guard prepared?.observedTranscriptURL != nil, stream?.isRunning == true else { return }
        observedScanNeeded = true
        guard !observedScanScheduled, !observedScanInFlight else { return }
        observedScanScheduled = true
        worker.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            NativeConversationDelivery.callbacks.receive { [weak self] in
                self?.startObservedModeScan()
            }
        }
    }

    private func startObservedModeScan() {
        observedScanScheduled = false
        guard observedScanNeeded, !observedScanInFlight,
              let prepared, let url = prepared.observedTranscriptURL,
              stream?.isRunning == true else { return }
        observedScanNeeded = false
        observedScanInFlight = true
        let startingLength = prepared.observedTranscriptStartingLength
        let previousLength = observedFileLength
        let previousMode = observedMode
        worker.async { [weak self] in
            let length = Self.fileLength(at: url)
            let mode: AgentPermissionMode? = if length <= startingLength {
                nil
            } else if length == previousLength {
                previousMode
            } else {
                ComposerRecentPermissionMode.read(at: url)
            }
            NativeConversationDelivery.callbacks.receive { [weak self] in
                guard let self else { return }
                self.observedScanInFlight = false
                guard self.prepared?.observedTranscriptURL == url,
                      self.stream?.isRunning == true else { return }
                self.observedFileLength = length
                if self.observedMode != mode {
                    self.observedMode = mode
                    if let mode { self.runningPermissionMode = mode }
                    self.changed()
                }
                if self.observedScanNeeded { self.requestObservedModeScan() }
            }
        }
    }

    private nonisolated static func fileLength(at url: URL) -> UInt64 {
        guard let length = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return UInt64(max(0, length))
    }

    private func apply(_ event: StreamEvent) {
        if case .initialised = event, loadingHistory {
            loadingHistory = false
            status = "Ready"
        }
        if case .backgroundWork(let inFlight) = event {
            backgroundTaskCount = inFlight.count
        }
        retainContextReading(from: event)
        if !replaying, !loadingHistory, let prepared {
            let root = URL(fileURLWithPath: prepared.directory, isDirectory: true)
            attachmentScanner?.note(event, projectRoot: root)
        }
        let changes = timeline.apply(event)
        for change in changes {
            switch change {
            case .appended(let index), .resultAttached(let index):
                guard timeline.rows.indices.contains(index) else { continue }
                prepareRow(timeline.rows[index], at: index)
            case .streaming(let text): onStreaming?(text)
            case .turnSettled:
                // A replayed turn is history, not a turn completed in this process.
                guard !loadingHistory else { continue }
                completedTurns += 1
                status = "Ready"
                noteWork(started: false)
            case .adoptedSessionID(let id):
                self.prepared?.session.resumeState = .resumable(id)
                persist { $0.resumeState = .resumable(id) }
            default: break
            }
        }
        requestObservedModeScan()
        changed()
    }

    private func retainContextReading(from event: StreamEvent) {
        guard case .turnFinished(_, _, let metrics) = event,
              let tokens = metrics.contextTokens else { return }
        contextReading = (tokens, metrics.contextWindow)
    }

    /// All row jobs use one ordered, paced lane. Page boundaries are prepared here so the
    /// shared viewport row parses and builds only its active page on the UI actor. Byte/count
    /// admission bounds how much provider text may await UI delivery.
    private func prepareRow(_ row: ConversationTimeline.Row, at index: Int) {
        let source: String?
        switch row {
        case .assistant(let text), .thinking(let text): source = text
        default: source = nil
        }
        let bytes = source?.utf8.count ?? 0
        guard pendingRenderCount < 64, bytes <= 32 * 1_024 * 1_024 - pendingRenderBytes else {
            stream?.terminate()
            report("The conversation exceeded its row preparation budget.")
            return
        }
        pendingRenderCount += 1
        pendingRenderBytes += bytes
        let snapshot = RowSnapshot(rows: [row])
        worker.async { [weak self] in
            let pages = source.map { MarkdownView.preparePages($0) }
            NativeConversationDelivery.callbacks.receive {
                guard let self else { return }
                self.pendingRenderCount -= 1
                self.pendingRenderBytes -= bytes
                guard !self.stopped else { return }
                self.onRow?(index, snapshot.rows[0], pages)
                self.changed()
            }
        }
    }

    private func changed() {
        let pendingOutcome = hasPendingOutcome
        if completedTurns > lastCompletedTurns { completionAwaitingOutcome = true }
        if lastPendingOutcome == true, !pendingOutcome {
            if completionAwaitingOutcome { onSnoozeWakeReason?(.turnCompleted) }
            else if failure != nil { onSnoozeWakeReason?(.failed) }
            completionAwaitingOutcome = false
        }
        lastPendingOutcome = pendingOutcome
        lastCompletedTurns = completedTurns
        revision += 1
        let retentionFacts = retentionCandidate(
            lastWarmUseAt: prepared?.session.lastUsedAt ?? .distantPast,
            isLocallyVisible: false)
        if retentionFacts != lastRetentionFacts {
            lastRetentionFacts = retentionFacts
            onRetentionChange?()
        }
        onChange?()
    }
    private func report(_ message: String) { failure = message; status = message; changed() }

    private nonisolated static func markdownPages(for row: ConversationTimeline.Row) -> [[String]]? {
        switch row {
        case .assistant(let text), .thinking(let text): return MarkdownView.preparePages(text)
        default: return nil
        }
    }

    private func persist(_ mutate: @escaping @Sendable (inout AgentSession) -> Void) {
        guard let prepared else { return }
        let store = store, id = id
        let launchedAt = launchRecordedAt
        worker.async { [weak self] in
            do {
                try Self.withDatabase(store: store) { database in
                    guard let record = try database.sessionRecord(id: id), record.session.usesNativeUI,
                          record.project.id == prepared.projectID,
                          record.session.kind == prepared.session.kind,
                          record.session.accountHandle == prepared.session.accountHandle,
                          record.session.lastActiveAt == prepared.session.lastActiveAt
                            || launchedAt.map({ record.session.lastActiveAt == $0 }) == true else {
                        throw WindowFailure("Saved conversation changed before update.")
                    }
                    var session = record.session
                    mutate(&session)
                    try database.saveSession(session, in: record.project.id, position: record.position)
                }
            } catch {
                let message = "Could not save conversation state: \(error)"
                NativeConversationDelivery.callbacks.receive { self?.report(message) }
            }
        }
    }

    private func noteWork(started: Bool, at date: Date = Date()) {
        guard prepared != nil else { return }
        prepared?.session.noteWork(at: date, startsTurn: started)
        persist { session in
            session.noteWork(at: date, startsTurn: started)
        }
    }

    nonisolated static func withDatabase<T>(store: String, body: (ProjectDatabase) throws -> T) throws -> T {
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let lease = try LinuxStoreMutation.acquire(at: root)
        defer { lease.close() }
        let database = try ProjectDatabase(url: root.appendingPathComponent("threading.db"))
        defer { database.close() }
        return try body(database)
    }

    private nonisolated static func prepare(store: String, id: SessionID, shell: String,
                                            executables: [AgentKind: String]) throws -> Prepared {
        let record = try withDatabase(store: store) { database in
            guard let record = try database.sessionRecord(id: id), record.session.usesNativeUI,
                  record.session.kind.supportsNativeUI else { throw WindowFailure("Saved native conversation is unavailable.") }
            return record
        }
        let session = record.session
        guard let directory = ProjectDirectory.existing(at: session.workingDirectory(in: record.project)),
              shell.hasPrefix("/") else { throw WindowFailure("Conversation checkout or login shell is unavailable.") }
        guard let executable = executables[session.kind], executable.hasPrefix("/") else {
            throw WindowFailure("\(session.kind.displayName) executable is unavailable.")
        }
        let accountPath: String
        let url: URL?
        let replaysOverProtocol: Bool
        switch session.kind {
        case .claude, .codex:
            replaysOverProtocol = false
            accountPath = try GraphicalTerminal.accountPath(for: session.kind, handle: session.accountHandle)
            let account = AgentAccount(provider: session.kind, handle: session.accountHandle, configPath: accountPath)
            url = session.kind == .claude
                ? session.resumeState.transcriptID.flatMap {
                    ClaudeTranscript.storageSlot(sessionID: $0, account: account, in: record.project)?.resolve()
                }
                : session.resumeState.transcriptID.flatMap { CodexTranscript.url(sessionID: $0, account: account) }
            if session.hasLaunched {
                guard let url, FileManager.default.fileExists(atPath: url.path) else {
                    throw WindowFailure("Saved conversation history is missing from its account.")
                }
            }
        case .grok, .cursor:
            // One login per CLI, and history arrives over the protocol: `session/load` replays it.
            accountPath = ""
            url = nil
            replaysOverProtocol = true
        case .openCode:
            throw WindowFailure("This provider's native workspace launch is not available yet.")
        }
        let agentCommand: ShellCommand
        let resumeState: ResumeState
        let fastServiceTier: String?
        let speedCatalogue: ComposerModelCatalog
        var environment: [String: String] = [:]
        let appDefaultPermissionMode = LinuxGeneralSettings.defaultPermissionMode
        let mode = session.kind.supportsPermissionModes
            ? NewChatDefaults.permissionMode(selected: session.permissionMode,
                appDefault: appDefaultPermissionMode) : nil
        switch session.kind {
        case .claude:
            speedCatalogue = ComposerModelCatalog.read(provider: .claude,
                directory: URL(fileURLWithPath: accountPath, isDirectory: true),
                projectDirectory: directory.path)
            var flags = ClaudeLaunchCommand.streamProtocolFlags()
            let launchSpeed = ComposerSpeedLaunch.launchOverride(selected: session.fastMode,
                kind: session.kind, model: session.model, catalogue: speedCatalogue)
            flags.append(contentsOf: try ComposerSpeedLaunch.claudeFlags(
                launchSpeed, store: store, id: session.id))
            let pair = ClaudeLaunchCommand.terminalPair(for: session, executable: executable,
                permissionMode: mode, prompt: nil,
                integrationFlags: flags)
            agentCommand = session.hasLaunched ? pair.resume : pair.fresh
            resumeState = .resumable(pair.transcriptID)
            fastServiceTier = nil
        case .codex:
            let catalogue = ComposerModelCatalog.read(provider: .codex,
                directory: URL(fileURLWithPath: accountPath, isDirectory: true),
                projectDirectory: directory.path)
            speedCatalogue = catalogue
            let launchSpeed = ComposerSpeedLaunch.launchOverride(selected: session.fastMode,
                kind: session.kind, model: session.model, catalogue: catalogue)
            agentCommand = CodexLaunchCommand.appServer(executable: executable, model: session.model,
                conversationOverrides: ComposerSpeedLaunch.codexOverrides(
                    launchSpeed, model: session.model, catalogue: catalogue),
                permissionMode: mode)
            resumeState = session.resumeState
            fastServiceTier = ComposerSpeedLaunch.codexServiceTier(
                launchSpeed, model: session.model, catalogue: catalogue)
        case .grok:
            speedCatalogue = .empty
            agentCommand = ACPLaunchCommand.grok(executable: executable, model: session.model, permissionMode: mode)
            resumeState = session.resumeState
            fastServiceTier = nil
        case .cursor:
            speedCatalogue = .empty
            agentCommand = ACPLaunchCommand.cursor(executable: executable)
            resumeState = session.resumeState
            environment = AgentDefaults.cursorLaunchEnvironment
            fastServiceTier = nil
        case .openCode:
            throw WindowFailure("This provider's native workspace launch is not available yet.")
        }
        var command = AgentAccountRoute.prefix(for: session.kind, handle: session.accountHandle, configPath: accountPath)
        command.append(contentsOf: agentCommand)
        let replay = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? TranscriptReplay.read(at: $0, kind: session.kind) : nil }
            ?? ([], false)
        let plan = AgentLaunchPlan.inLoginShell(command: command, in: directory.path,
            shellPath: shell, resumeState: resumeState, environmentOverrides: environment)
        let hiddenModelIDs: Set<String> = switch session.kind {
        case .codex, .claude:
            ComposerModelVisibilityStore.hiddenModelIDs(for:
                AccountID(provider: session.kind, handle: session.accountHandle))
        case .grok, .openCode, .cursor: []
        }
        let observedTranscriptURL = session.kind == .claude
            ? resumeState.transcriptID.map {
                ClaudeTranscript.StorageSlot(sessionID: $0, configPath: accountPath,
                    folderPath: directory.path).resolve()
            }
            : nil
        return Prepared(session: session, projectID: record.project.id, directory: directory.path,
            plan: plan, fastServiceTier: fastServiceTier,
            appDefaultPermissionMode: appDefaultPermissionMode,
            speedCatalogue: speedCatalogue,
            hiddenModelIDs: hiddenModelIDs,
            observedTranscriptURL: observedTranscriptURL,
            observedTranscriptStartingLength: observedTranscriptURL.map { fileLength(at: $0) } ?? 0,
            events: replay.0,
            truncated: replay.1, replaysOverProtocol: replaysOverProtocol)
    }
}
#endif
