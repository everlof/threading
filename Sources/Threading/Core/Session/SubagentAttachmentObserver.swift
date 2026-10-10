import Foundation

/// Routes child activity to the ordinary attachment detector. It owns scheduling and attribution,
/// not a second parser or file-admission policy. Typical sessions have 1–8 children; at most 64
/// recent children retain observers, each with one active scan and one coalesced rescan.
@MainActor
final class SubagentAttachmentObserver {
    struct Configuration {
        let kind: AgentKind
        let projectRoot: URL
    }

    @MainActor
    private final class Child {
        var descriptor: SubagentDescriptor
        let turnID: String?
        var working = false
        var receivesLiveEvents = false
        var transcript: TerminalTranscriptAttachmentObserver?
        var pendingTexts: [[String]] = []
        var recording: Task<Void, Never>?

        init(descriptor: SubagentDescriptor, turnID: String?) {
            self.descriptor = descriptor
            self.turnID = turnID
        }

        var context: AttachmentReferenceContext {
            AttachmentReferenceContext(sources: [AttachmentAgentSource(
                threadID: descriptor.threadID, name: descriptor.displayName
            )], turnID: turnID)
        }

        func invalidate() {
            transcript?.invalidate()
            recording?.cancel()
            pendingTexts.removeAll()
        }
    }

    private let sessionID: SessionID
    private let configuration: () -> Configuration?
    private let currentTurnID: () -> String?
    private let store: SessionAttachmentStore
    private let isEnabled: () -> Bool
    private var children: [String: Child] = [:]
    private var orderedIDs: [String] = []
    private var timer: Timer?

    init(
        sessionID: SessionID,
        store: SessionAttachmentStore = .shared,
        configuration: @escaping () -> Configuration?,
        currentTurnID: @escaping () -> String?,
        isEnabled: @escaping () -> Bool
    ) {
        self.sessionID = sessionID
        self.store = store
        self.configuration = configuration
        self.currentTurnID = currentTurnID
        self.isEnabled = isEnabled
    }

    func apply(_ event: SubagentEvent, timeline: SubagentTimeline) {
        let id: String
        switch event {
        case .discovered(let descriptor): id = descriptor.threadID
        case .state(let threadID, _, _), .conversation(let threadID, _),
             .progress(let threadID, _), .activity(let threadID, _): id = threadID
        }
        guard let agent = timeline.agent(threadID: id) else { return }
        let descriptor = agent.descriptor
        let child: Child
        if let existing = children[descriptor.threadID] {
            child = existing
        } else {
            child = Child(descriptor: descriptor, turnID: descriptor.parentTurnID ?? currentTurnID())
            if orderedIDs.count == AttachmentAgentSource.maximumChildren {
                let oldest = orderedIDs.removeFirst()
                children.removeValue(forKey: oldest)?.invalidate()
            }
            orderedIDs.append(descriptor.threadID)
            children[descriptor.threadID] = child
        }
        let pathChanged = child.descriptor.path != descriptor.path
        if child.descriptor.displayName != descriptor.displayName {
            store.updateAgentSource(.init(threadID: descriptor.threadID, name: descriptor.displayName),
                                    for: sessionID)
        }
        child.descriptor = descriptor
        child.working = agent.status.isWorking
        installTranscriptObserver(on: child)

        switch event {
        case .conversation(_, let event):
            child.receivesLiveEvents = true
            let texts = AttachmentDetection.assistantTexts(in: event)
            if !texts.isEmpty, isEnabled() {
                // Value batches only. The shared worker enforces the aggregate byte budget.
                child.pendingTexts.append(texts)
                if child.pendingTexts.count > Self.maximumPendingMessages {
                    child.pendingTexts.removeFirst()
                }
                drain(child)
            }
        case .state(_, let status, let message) where status.isDone:
            child.transcript?.noteTurnFinished(lastAssistantMessage: message)
        case .discovered:
            if pathChanged || !child.receivesLiveEvents {
                child.transcript?.noteTranscriptChanged()
            }
        default:
            break
        }
        updateTimer()
    }

    /// Restored descriptors provide the exact child files without enumerating provider trees.
    func restore(_ timeline: SubagentTimeline) {
        for agent in timeline.recentAgents(limit: AttachmentAgentSource.maximumChildren) {
            apply(.discovered(agent.descriptor), timeline: timeline)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for child in children.values { child.working = false }
    }

    func invalidate() {
        stop()
        children.values.forEach { $0.invalidate() }
        children.removeAll()
        orderedIDs.removeAll()
    }

    private func installTranscriptObserver(on child: Child) {
        guard child.transcript == nil, let config = configuration() else { return }
        child.transcript = TerminalTranscriptAttachmentObserver(
            sessionID: sessionID, kind: config.kind,
            projectRoot: { [weak self] in self?.configuration()?.projectRoot },
            currentDirectory: { nil },
            transcriptURL: { [weak child] in
                child?.descriptor.path.map { URL(fileURLWithPath: $0) }
            },
            isEnabled: isEnabled,
            context: { [weak child] in child?.context ?? .main },
            isChild: true, store: store
        )
    }

    private func drain(_ child: Child) {
        guard child.recording == nil else { return }
        child.recording = Task { [weak self, weak child] in
            guard let self, let child else { return }
            defer { child.recording = nil }
            while !Task.isCancelled, !child.pendingTexts.isEmpty {
                let texts = child.pendingTexts.removeFirst()
                guard let config = self.configuration() else { continue }
                await AttachmentDetection.record(
                    texts: texts, sessionID: self.sessionID, projectRoot: config.projectRoot,
                    context: child.context, store: self.store, shouldAdmit: self.isEnabled
                )
            }
        }
    }

    private func updateTimer() {
        let needsTimer = children.values.contains {
            $0.working && !$0.receivesLiveEvents && $0.descriptor.path != nil
        }
        guard needsTimer else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanWorkingChildren() }
        }
    }

    private func scanWorkingChildren() {
        guard isEnabled() else { return }
        for child in children.values where child.working && !child.receivesLiveEvents {
            child.transcript?.noteTranscriptChanged()
        }
    }

    private static let scanInterval: TimeInterval = 2
    private static let maximumPendingMessages = 32
}
