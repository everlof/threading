import Foundation

// MARK: - Subagent Stream

/// A native conversation transport that can report child-agent work separately from the
/// parent's transcript.
///
/// Child events do not belong in `StreamEvent`: folding them into the parent would make a
/// delegated command, its output, and the parent's own work indistinguishable. The optional
/// capability keeps the ordinary conversation transport provider-neutral while letting Codex's
/// app-server and Claude's forwarded Task stream expose the hierarchies they already own.
protocol SubagentReportingConversation: AnyObject {
    var onSubagentEvent: ((SubagentEvent) -> Void)? { get set }
}

/// A provider that can rebuild child-agent state from its durable transcript store.
///
/// History is deliberately separate from live reporting: Codex app-server currently supplies
/// only the latter, while Claude persists one independently resumable JSONL file per child.
/// Callbacks arrive on the main queue so the conversation controller can fold them through the
/// same timeline used for live events.
protocol SubagentHistoryConversation: AnyObject {
    func loadSubagentHistory(completion: @escaping ([SubagentEvent]) -> Void)
    func loadSubagentTranscript(
        for descriptor: SubagentDescriptor,
        completion: @escaping (_ events: [StreamEvent], _ isTruncated: Bool) -> Void
    )
}

/// Provider-neutral lifecycle for one delegated agent.
enum SubagentStatus: String, Codable, Equatable {
    case pending
    case working
    case completed
    case interrupted
    case failed
    case stopped

    var isWorking: Bool {
        self == .pending || self == .working
    }

    var isDone: Bool {
        switch self {
        case .completed, .interrupted, .failed, .stopped:
            return true
        case .pending, .working:
            return false
        }
    }
}

/// Live work telemetry for one delegated agent.
///
/// Claude reports these fields over several independent messages (`task_progress`,
/// `tool_progress`, and `task_updated`). Optional properties let the timeline merge whichever
/// facts a given CLI release supplies without erasing earlier values.
struct SubagentProgress: Codable, Equatable {
    var taskID: String?
    var summary: String?
    var currentTool: String?
    var totalTokens: Int?
    var toolUses: Int?
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var isBackgrounded: Bool?

    init(
        taskID: String? = nil,
        summary: String? = nil,
        currentTool: String? = nil,
        totalTokens: Int? = nil,
        toolUses: Int? = nil,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval? = nil,
        isBackgrounded: Bool? = nil
    ) {
        self.taskID = taskID
        self.summary = summary
        self.currentTool = currentTool
        self.totalTokens = totalTokens
        self.toolUses = toolUses
        self.duration = duration
        self.elapsed = elapsed
        self.isBackgrounded = isBackgrounded
    }

    mutating func merge(_ newer: SubagentProgress) {
        taskID = newer.taskID ?? taskID
        summary = newer.summary ?? summary
        currentTool = newer.currentTool ?? currentTool
        totalTokens = newer.totalTokens ?? totalTokens
        toolUses = newer.toolUses ?? toolUses
        duration = newer.duration ?? duration
        elapsed = newer.elapsed ?? elapsed
        isBackgrounded = newer.isBackgrounded ?? isBackgrounded
    }

    /// Compact status text shared by the parent navigator and the selected-child header.
    var displayText: String? {
        var details: [String] = []
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            details.append(summary)
        } else if let currentTool, !currentTool.isEmpty {
            details.append(currentTool)
        }

        if let elapsed = [elapsed, duration].compactMap({ $0 }).max() {
            details.append(TurnStatusText.duration(elapsed))
        }
        if let toolUses {
            details.append("\(toolUses) \(toolUses == 1 ? "tool" : "tools")")
        }
        if let totalTokens {
            details.append("\(TurnStatusText.tokenCount(totalTokens)) tokens")
        }

        return details.isEmpty ? nil : details.joined(separator: " · ")
    }
}

/// Identity and launch context that remain stable while a child runs.
struct SubagentDescriptor: Codable, Equatable {
    let threadID: String
    /// Other provider-issued identities for this same child.
    ///
    /// Claude's terminal hook reports the agent id while its native stream and metadata index
    /// use the spawning tool-use id. Keeping the alias on the durable descriptor lets either
    /// surface reconcile the other without guessing from a title or launch order.
    var alternateThreadIDs: [String]?
    var parentThreadID: String?
    var nickname: String?
    var role: String?
    var path: String?
    var prompt: String?
    var model: String?
    var reasoningEffort: String?

    init(
        threadID: String,
        alternateThreadIDs: [String]? = nil,
        parentThreadID: String? = nil,
        nickname: String? = nil,
        role: String? = nil,
        path: String? = nil,
        prompt: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.threadID = threadID
        self.alternateThreadIDs = alternateThreadIDs
        self.parentThreadID = parentThreadID
        self.nickname = nickname
        self.role = role
        self.path = path
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    var displayName: String {
        for candidate in [nickname, role] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return L10n.format("Agent %@", String(threadID.prefix(8)))
    }

    /// Adds newly learned metadata without erasing facts an earlier event already supplied.
    mutating func merge(_ newer: SubagentDescriptor) {
        let mergedAliases = Set(alternateThreadIDs ?? [])
            .union(newer.alternateThreadIDs ?? [])
            .subtracting([threadID])
        alternateThreadIDs = mergedAliases.isEmpty ? nil : mergedAliases.sorted()
        parentThreadID = newer.parentThreadID ?? parentThreadID
        nickname = newer.nickname ?? nickname
        role = newer.role ?? role
        path = newer.path ?? path
        prompt = newer.prompt ?? prompt
        model = newer.model ?? model
        reasoningEffort = newer.reasoningEffort ?? reasoningEffort
    }
}

/// One child-agent fact emitted by a provider adapter.
enum SubagentEvent {
    case discovered(SubagentDescriptor)
    case state(threadID: String, status: SubagentStatus, message: String?)
    case progress(threadID: String, progress: SubagentProgress)
    case conversation(threadID: String, event: StreamEvent)
    case activity(threadID: String, text: String)
}

// MARK: - Subagent Timeline

/// The child-agent hierarchy as a small, independently testable projection.
///
/// Each child owns a normal `ConversationTimeline`, so the drill-in surface reuses the exact
/// rows used for the parent instead of inventing a second transcript renderer.
struct SubagentTimeline {

    /// The compact durable form of a child timeline.
    ///
    /// Full child conversations stay in the providers' own transcript files. Persisting them
    /// again would duplicate an unbounded JSONL in Application Support and create two sources
    /// of truth. This snapshot keeps the navigator facts needed before a transcript is opened.
    struct Snapshot: Codable, Equatable {
        let version: Int
        var agents: [AgentSnapshot]

        init(version: Int = SubagentDefaults.snapshotVersion, agents: [AgentSnapshot]) {
            self.version = version
            self.agents = agents
        }
    }

    struct AgentSnapshot: Codable, Equatable {
        var descriptor: SubagentDescriptor
        var status: SubagentStatus
        var message: String?
        var progress: SubagentProgress?
        var activity: [String]
    }

    struct Agent {
        var descriptor: SubagentDescriptor
        var status: SubagentStatus
        var message: String?
        var progress: SubagentProgress?
        var runProgress: RunProgress?
        var conversation: ConversationTimeline
        var activity: [String]

        /// The concise live line shared by the parent navigator and selected-child header.
        ///
        /// Provider task telemetry and the child's own plan are independent signals. Keep both
        /// when available rather than letting a duration update erase `Step n / total`.
        var statusDetail: String? {
            var parts: [String] = []
            if let label = runProgress?.label, !label.isEmpty {
                parts.append(label)
            }
            if let telemetry = progress?.displayText, !telemetry.isEmpty {
                parts.append(telemetry)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private let sessionID: SessionID
    private var agentsByID: [String: Agent] = [:]
    private var orderedIDs: [String] = []
    private var canonicalIDByAlias: [String: String] = [:]

    init(sessionID: SessionID) {
        self.sessionID = sessionID
    }

    /// Restores navigator state after a relaunch.
    ///
    /// A process from the previous app lifetime cannot still be observed by this runtime, so
    /// an unfinished child is restored as stopped rather than left spinning forever. A renderer
    /// switch does not take this path: both renderers share one live `SubagentSessionState`.
    init(sessionID: SessionID, snapshot: Snapshot) {
        self.sessionID = sessionID

        guard snapshot.version == SubagentDefaults.snapshotVersion else { return }
        for stored in snapshot.agents {
            let threadID = stored.descriptor.threadID
            let restoredStatus = stored.status.isWorking ? .stopped : stored.status
            let restoredMessage = stored.message
                .map(SubagentDefaults.compactActivity)
                .flatMap { $0.isEmpty ? nil : $0 }
            var restoredActivity: [String] = []
            for text in stored.activity {
                let compacted = SubagentDefaults.compactActivity(text)
                guard !compacted.isEmpty, restoredActivity.last != compacted else { continue }
                restoredActivity.append(compacted)
            }
            orderedIDs.append(threadID)
            agentsByID[threadID] = Agent(
                descriptor: stored.descriptor,
                status: restoredStatus,
                message: restoredMessage,
                progress: stored.progress,
                runProgress: nil,
                conversation: ConversationTimeline(sessionID: sessionID),
                activity: Array(restoredActivity.suffix(SubagentDefaults.activityLimit))
            )
            registerAliases(for: stored.descriptor, canonicalID: threadID)
        }
    }

    var agents: [Agent] {
        orderedIDs.compactMap { agentsByID[$0] }
    }

    var workingCount: Int {
        agents.lazy.filter { $0.status.isWorking }.count
    }

    var doneCount: Int {
        agents.lazy.filter { $0.status.isDone }.count
    }

    var snapshot: Snapshot {
        Snapshot(agents: agents.map {
            var descriptor = $0.descriptor
            if let parent = descriptor.parentThreadID,
               let canonicalParent = canonicalID(for: parent) {
                descriptor.parentThreadID = canonicalParent
            }
            return AgentSnapshot(
                descriptor: descriptor,
                status: $0.status,
                message: $0.message,
                progress: $0.progress,
                activity: $0.activity
            )
        })
    }

    mutating func apply(_ event: SubagentEvent) {
        switch event {
        case .discovered(let descriptor):
            let threadID = ensureAgent(for: descriptor)
            agentsByID[threadID]?.descriptor.merge(descriptor)
            if let merged = agentsByID[threadID]?.descriptor {
                registerAliases(for: merged, canonicalID: threadID)
            }

        case .state(let threadID, let status, let message):
            let threadID = ensureAgent(threadID)
            agentsByID[threadID]?.status = status
            if status.isDone {
                agentsByID[threadID]?.runProgress = nil
            }
            if let message, !message.isEmpty {
                let compacted = SubagentDefaults.compactActivity(message)
                if !compacted.isEmpty {
                    agentsByID[threadID]?.message = compacted
                    appendActivity(compacted, to: threadID)
                }
            }

        case .progress(let threadID, let progress):
            let threadID = ensureAgent(threadID)
            if agentsByID[threadID]?.progress == nil {
                agentsByID[threadID]?.progress = progress
            } else {
                agentsByID[threadID]?.progress?.merge(progress)
            }

        case .conversation(let threadID, let event):
            let threadID = ensureAgent(threadID)
            let changes = agentsByID[threadID]?.conversation.apply(event) ?? []
            for change in changes {
                if case .runProgress(let progress) = change {
                    // Claude history is loaded lazily after the terminal lifecycle snapshot.
                    // Replaying old TaskCreate/TaskUpdate records must not make a completed
                    // child look live again in the navigator or transcript header.
                    guard agentsByID[threadID]?.status.isDone != true else { continue }
                    agentsByID[threadID]?.runProgress = progress
                }
            }
            if case .turnFinished = event {
                agentsByID[threadID]?.runProgress = nil
            }

        case .activity(let threadID, let text):
            let threadID = ensureAgent(threadID)
            appendActivity(text, to: threadID)
        }
    }

    @discardableResult
    private mutating func ensureAgent(_ threadID: String) -> String {
        if let canonical = canonicalID(for: threadID) {
            return canonical
        }

        orderedIDs.append(threadID)
        agentsByID[threadID] = Agent(
            descriptor: SubagentDescriptor(threadID: threadID),
            status: .pending,
            message: nil,
            progress: nil,
            runProgress: nil,
            conversation: ConversationTimeline(sessionID: sessionID),
            activity: []
        )
        canonicalIDByAlias[threadID] = threadID
        return threadID
    }

    @discardableResult
    private mutating func ensureAgent(for descriptor: SubagentDescriptor) -> String {
        let identities = [descriptor.threadID] + (descriptor.alternateThreadIDs ?? [])
        let existing = identities.compactMap(canonicalID(for:)).first
            ?? descriptor.path.flatMap { path in
                agents.first {
                    $0.descriptor.path == path
                }?.descriptor.threadID
            }

        let canonical = existing ?? ensureAgent(descriptor.threadID)
        var reconciled = descriptor
        if canonical != descriptor.threadID {
            var aliases = Set(reconciled.alternateThreadIDs ?? [])
            aliases.insert(descriptor.threadID)
            reconciled.alternateThreadIDs = aliases.sorted()
        }
        if let parent = reconciled.parentThreadID,
           let canonicalParent = canonicalID(for: parent) {
            reconciled.parentThreadID = canonicalParent
        }
        canonicalIDByAlias[descriptor.threadID] = canonical
        for alias in descriptor.alternateThreadIDs ?? [] {
            canonicalIDByAlias[alias] = canonical
        }
        agentsByID[canonical]?.descriptor.merge(reconciled)
        return canonical
    }

    private func canonicalID(for threadID: String) -> String? {
        if agentsByID[threadID] != nil { return threadID }
        if let canonical = canonicalIDByAlias[threadID] { return canonical }
        return agents.first {
            $0.descriptor.alternateThreadIDs?.contains(threadID) == true
        }?.descriptor.threadID
    }

    private mutating func registerAliases(
        for descriptor: SubagentDescriptor,
        canonicalID: String
    ) {
        canonicalIDByAlias[descriptor.threadID] = canonicalID
        for alias in descriptor.alternateThreadIDs ?? [] {
            canonicalIDByAlias[alias] = canonicalID
        }
    }

    private mutating func appendActivity(_ text: String, to threadID: String) {
        let compacted = SubagentDefaults.compactActivity(text)
        guard !compacted.isEmpty else { return }

        var activity = agentsByID[threadID]?.activity ?? []
        if activity.last != compacted { activity.append(compacted) }
        if activity.count > SubagentDefaults.activityLimit {
            activity.removeFirst(activity.count - SubagentDefaults.activityLimit)
        }
        agentsByID[threadID]?.activity = activity
    }

    mutating func replaceConversation(
        threadID: String,
        events: [StreamEvent]
    ) {
        let threadID = ensureAgent(threadID)
        var conversation = ConversationTimeline(sessionID: sessionID)
        var runProgress: RunProgress?
        for event in events {
            for change in conversation.apply(event) {
                if case .runProgress(let progress) = change {
                    runProgress = progress
                }
            }
            if case .turnFinished = event {
                runProgress = nil
            }
        }
        agentsByID[threadID]?.conversation = conversation
        let isDone = agentsByID[threadID]?.status.isDone == true
        agentsByID[threadID]?.runProgress = isDone ? nil : runProgress
    }
}

enum SubagentDefaults {
    /// Enough context for a useful drill-in without turning a summary card into a second scroll
    /// view. The complete child transcript remains in `Agent.conversation`.
    static let activityLimit = 12

    static let snapshotVersion = 1
    static let applicationDirectoryName = "Skalman"
    static let snapshotDirectoryName = "Subagents"
    static let snapshotExtension = "json"
    static let persistenceDelay: TimeInterval = 0.35
    static let activityCharacterLimit = 1_000

    static func compactActivity(_ text: String) -> String {
        let presented = providerActivityPresentation(text)
        let compacted = presented.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compacted.count > activityCharacterLimit else { return compacted }
        return String(compacted.prefix(activityCharacterLimit)) + "…"
    }

    /// A Claude lifecycle hook has been observed reporting a leading `<analysis>` wrapper in
    /// `last_assistant_message`. The documented thinking stream is structured, not XML-shaped,
    /// and neither `<thinking>` nor `<final>` occurs in the measured transcript corpus. Keep
    /// this compatibility seam to the one observed spelling so ordinary angle-bracket prose
    /// remains intact.
    ///
    /// A stop report is capped before it reaches the app on some Claude releases, so a missing
    /// closing tag is expected and receives the same treatment as a complete wrapper.
    private static func providerActivityPresentation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<analysis>"
        guard trimmed.hasPrefix(opening) else { return trimmed }

        var content = String(trimmed.dropFirst(opening.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = "</analysis>"
        if content.hasSuffix(closing) {
            content = String(content.dropLast(closing.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty else { return "" }
        return L10n.format("Reasoning: %@", content)
    }
}

// MARK: - Shared Session State

/// One session's child hierarchy, shared by its native and terminal renderers.
///
/// A renderer is disposable: switching surface terminates one controller and constructs the
/// other. The hierarchy is not. Keeping it here lets both renderers observe the same timeline,
/// while the small snapshot store lets the navigator survive a full app relaunch as well.
@MainActor
final class SubagentSessionState {

    let sessionID: SessionID
    private(set) var timeline: SubagentTimeline
    private(set) var selectedThreadID: String?

    /// At most one renderer is live for a session, so one change observer is sufficient.
    var onChange: (() -> Void)?

    private let store: SubagentStateStore?
    private var persistenceTimer: Timer?
    private var persistenceDirty = false
    private var isInvalidated = false

    init(
        sessionID: SessionID,
        store: SubagentStateStore? = nil
    ) {
        self.sessionID = sessionID
        self.store = store
        if let snapshot = store?.load(sessionID: sessionID) {
            self.timeline = SubagentTimeline(sessionID: sessionID, snapshot: snapshot)
        } else {
            self.timeline = SubagentTimeline(sessionID: sessionID)
        }
    }

    func apply(_ event: SubagentEvent) {
        guard !isInvalidated else { return }
        timeline.apply(event)

        // Conversation rows are recoverable from the descriptor's provider transcript and
        // intentionally absent from the compact snapshot. Avoid rewriting the same snapshot
        // for every streamed token and tool result.
        switch event {
        case .conversation:
            // Still notify the selected-child view: its full transcript is live state.
            break
        default:
            schedulePersistence()
        }

        onChange?()
    }

    func select(threadID: String?) {
        guard !isInvalidated else { return }
        selectedThreadID = threadID.flatMap { candidate in
            timeline.agents.contains {
                $0.descriptor.threadID == candidate
            } ? candidate : nil
        }
    }

    /// Settles children whose owning process is being torn down.
    ///
    /// This is especially important during a renderer switch: the next renderer keeps the
    /// hierarchy, but it must not imply that work from the terminated process is still live.
    func stopWorking(message: String? = nil) {
        guard !isInvalidated else { return }
        let working = timeline.agents.filter(\.status.isWorking)
        guard !working.isEmpty else { return }

        for agent in working {
            timeline.apply(.state(
                threadID: agent.descriptor.threadID,
                status: .stopped,
                message: message
            ))
        }
        persistenceDirty = true
        flushPersistence()
        onChange?()
    }

    /// Replaces a replayed provider transcript atomically.
    ///
    /// A file can grow between a lifecycle hook and the reader. Replacing the prior replay
    /// avoids duplicate rows when a changed file signature triggers a second read.
    func replaceConversation(threadID: String, events: [StreamEvent]) {
        guard !isInvalidated else { return }
        timeline.replaceConversation(threadID: threadID, events: events)
        onChange?()
    }

    /// Commits any coalesced navigator update before app shutdown or renderer disposal.
    func flushPersistence() {
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        guard persistenceDirty, !isInvalidated else { return }
        persistenceDirty = false
        store?.save(timeline.snapshot, sessionID: sessionID)
    }

    /// Makes late provider callbacks harmless after the owning session has been deleted.
    func invalidate() {
        isInvalidated = true
        onChange = nil
        persistenceTimer?.invalidate()
        persistenceTimer = nil
        persistenceDirty = false
    }

    private func schedulePersistence() {
        guard store != nil else { return }
        persistenceDirty = true
        persistenceTimer?.invalidate()
        persistenceTimer = Timer.scheduledTimer(
            withTimeInterval: SubagentDefaults.persistenceDelay,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPersistence()
            }
        }
    }
}

/// The compact on-disk child navigator store.
///
/// One file per session keeps deletion and corruption local. Provider transcripts remain the
/// authoritative full history; this is only the cross-surface, early-render index.
@MainActor
final class SubagentStateStore {

    static let shared = SubagentStateStore()

    private let fileManager: FileManager
    private let directory: URL
    private var writesBlocked: Set<SessionID> = []

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                SubagentDefaults.applicationDirectoryName,
                isDirectory: true
            )
        self.directory = root.appendingPathComponent(
            SubagentDefaults.snapshotDirectoryName,
            isDirectory: true
        )
    }

    func load(sessionID: SessionID) -> SubagentTimeline.Snapshot? {
        let file = url(for: sessionID)
        guard fileManager.fileExists(atPath: file.path) else { return nil }

        do {
            let data = try Data(contentsOf: file)
            let snapshot = try JSONDecoder().decode(
                SubagentTimeline.Snapshot.self,
                from: data
            )
            guard snapshot.version == SubagentDefaults.snapshotVersion else {
                throw SubagentStateStoreError.unsupportedVersion(snapshot.version)
            }
            return snapshot
        } catch {
            quarantine(file, sessionID: sessionID, error: error)
            return nil
        }
    }

    func save(_ snapshot: SubagentTimeline.Snapshot, sessionID: SessionID) {
        guard !writesBlocked.contains(sessionID) else { return }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url(for: sessionID), options: .atomic)
        } catch {
            SkalmanLogger.agent.error(
                "Failed to save subagents for \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func retainOnly(sessionIDs: Set<SessionID>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let retained = Set(sessionIDs.map(\.uuidString))
        for file in files {
            let sessionName = file.lastPathComponent.split(separator: ".", maxSplits: 1).first
                .map(String.init) ?? ""
            guard UUID(uuidString: sessionName) != nil,
                  !retained.contains(sessionName) else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
        writesBlocked = writesBlocked.filter { sessionIDs.contains($0) }
    }

    private func url(for sessionID: SessionID) -> URL {
        directory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(SubagentDefaults.snapshotExtension)
    }

    private func quarantine(_ file: URL, sessionID: SessionID, error: Error) {
        let destination = directory.appendingPathComponent(
            "\(file.lastPathComponent).unreadable-\(UUID().uuidString)"
        )
        do {
            try fileManager.moveItem(at: file, to: destination)
            writesBlocked.remove(sessionID)
            SkalmanLogger.agent.error(
                "Quarantined unreadable subagent state for \(sessionID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        } catch {
            writesBlocked.insert(sessionID)
            SkalmanLogger.agent.error(
                "Could not quarantine subagent state for \(sessionID.uuidString, privacy: .public); writes blocked: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

private enum SubagentStateStoreError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return L10n.format("Unsupported subagent snapshot version %lld.", Int64(version))
        }
    }
}

// MARK: - Provider Transcript Loading

/// Loads one child transcript without requiring its renderer's live transport to still exist.
///
/// Native Claude already exposes the same operation through `SubagentHistoryConversation`;
/// terminal mode has no structured transport object, and a renderer switch deliberately
/// destroys the old one. Routing from the descriptor path keeps drill-in available on either
/// side of the switch.
enum SubagentTranscriptLoader {

    static func isLoadable(_ descriptor: SubagentDescriptor) -> Bool {
        signature(for: descriptor) != nil
    }

    static func signature(
        for descriptor: SubagentDescriptor
    ) -> SubagentTranscriptSignature? {
        guard let url = transcriptURL(for: descriptor),
              let values = try? url.resourceValues(forKeys: [
                  .fileSizeKey,
                  .contentModificationDateKey
              ]) else {
            return nil
        }
        return SubagentTranscriptSignature(
            byteCount: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate
        )
    }

    @MainActor
    static func load(
        descriptor: SubagentDescriptor,
        kind: AgentKind,
        completion: @escaping (_ events: [StreamEvent], _ isTruncated: Bool) -> Void
    ) {
        guard let url = transcriptURL(for: descriptor) else {
            completion([], false)
            return
        }

        switch kind {
        case .claude:
            ClaudeSubagentTranscriptReplay.loadConversation(at: url, completion: completion)
        case .codex:
            DispatchQueue.global(qos: .userInitiated).async {
                let replay = TranscriptReplay.read(at: url, kind: .codex)
                DispatchQueue.main.async {
                    completion(replay.0, replay.1)
                }
            }
        }
    }

    static func transcriptURL(for descriptor: SubagentDescriptor) -> URL? {
        guard let path = descriptor.path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isDirectoryKey
        ]), values.isRegularFile == true, values.isDirectory != true else {
            return nil
        }
        return url
    }
}

struct SubagentTranscriptSignature: Equatable {
    let byteCount: Int
    let modifiedAt: Date?
}

/// Prevents concurrent duplicate reads without treating an empty/failed replay as permanent.
struct SubagentTranscriptLoadCache {
    enum Finish {
        case loaded
        case retryAfter(TimeInterval)
        case unavailable
    }

    private var loading: Set<String> = []
    private var loadedSignatures: [String: SubagentTranscriptSignature] = [:]
    private var emptyAttempts: [String: Int] = [:]

    mutating func begin(
        threadID: String,
        signature: SubagentTranscriptSignature
    ) -> Bool {
        guard loadedSignatures[threadID] != signature else { return false }
        return loading.insert(threadID).inserted
    }

    mutating func finish(
        threadID: String,
        signature: SubagentTranscriptSignature,
        eventCount: Int
    ) -> Finish {
        loading.remove(threadID)
        guard eventCount > 0 else {
            let previousAttempts = emptyAttempts[threadID] ?? 0
            guard previousAttempts < 3 else { return .unavailable }
            let attempt = previousAttempts + 1
            emptyAttempts[threadID] = attempt
            return .retryAfter(0.35 * pow(2, Double(attempt - 1)))
        }

        emptyAttempts[threadID] = nil
        loadedSignatures[threadID] = signature
        return .loaded
    }
}

// MARK: - Provider Usage Loading

/// Reads the raw token count one completed child consumed from its own transcript.
///
/// Claude's stable message usage schema is shared with the account usage index. Codex's
/// rollout schema is explicitly isolated here: child rollouts copy parent context, so summing
/// `total_token_usage` would attribute the parent to every child. The per-request
/// `last_token_usage` records after the child communication boundary are the child work.
enum SubagentUsageReader {

    @MainActor
    static func load(
        path: String,
        kind: AgentKind,
        completion: @escaping (Int?) -> Void
    ) {
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .utility).async {
            let tokens = read(at: url, kind: kind)
            DispatchQueue.main.async { completion(tokens) }
        }
    }

    static func read(at url: URL, kind: AgentKind) -> Int? {
        switch kind {
        case .claude:
            var seen: Set<String> = []
            let total = TranscriptUsageIndex
                .entries(inTranscriptAt: url, seen: &seen)
                .reduce(Int64(0)) {
                    $0 + $1.usage.billedTokens + $1.usage.cachedTokens
                }
            return total > 0 && total <= Int64(Int.max) ? Int(total) : nil

        case .codex:
            return readCodex(at: url)
        }
    }

    private static func readCodex(at url: URL) -> Int? {
        var crossedBoundary = false
        var sawBoundary = false
        var allLastUsage: [Int64] = []
        var childLastUsage: [Int64] = []
        var totalBeforeBoundary: Int64?
        var lastTotalAfterBoundary: Int64?

        JSONLReader.forEachRecord(at: url, limit: .max) { record in
            if record["type"] as? String == "inter_agent_communication_metadata" {
                crossedBoundary = true
                sawBoundary = true
                return true
            }

            guard record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else {
                return true
            }

            if let last = info["last_token_usage"] as? [String: Any],
               let tokens = integer(last["total_tokens"]), tokens > 0 {
                allLastUsage.append(tokens)
                if crossedBoundary { childLastUsage.append(tokens) }
            }

            if let total = info["total_token_usage"] as? [String: Any],
               let tokens = integer(total["total_tokens"]) {
                if crossedBoundary {
                    lastTotalAfterBoundary = tokens
                } else {
                    totalBeforeBoundary = tokens
                }
            }
            return true
        }

        let requestUsage = sawBoundary ? childLastUsage : allLastUsage
        if !requestUsage.isEmpty {
            let total = requestUsage.reduce(Int64(0), +)
            return total <= Int64(Int.max) ? Int(total) : nil
        }

        // Version-tolerant fallback for a rollout that omits `last_token_usage`: only a delta
        // across a witnessed child boundary is attributable without counting copied context.
        if sawBoundary, let before = totalBeforeBoundary, let after = lastTotalAfterBoundary {
            let delta = max(0, after - before)
            return delta > 0 && delta <= Int64(Int.max) ? Int(delta) : nil
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }
}
