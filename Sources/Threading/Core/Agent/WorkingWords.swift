import Foundation

/// What the conversation's status line says while a turn is in flight.
///
/// The word is drawn once, when the turn starts, and kept until the turn ends. That is the
/// whole rule: the status line is how a user knows the session is busy, so a label that
/// rewrote itself mid-turn would read as *something happened* when nothing had. A new turn
/// draws a new word, which is where the variety belongs — between turns, not within one.
///
/// This also settles an asymmetry between the two transports. The status used to be raised by
/// whatever each CLI happened to report: a transport streaming reasoning deltas flipped to
/// "Thinking…" immediately while one reporting only finished reasoning stayed on "Working…".
/// The same wait was described two different ways for no reason a user could see. A word chosen
/// at submit is transport independent by construction — neither CLI is asked.
enum WorkingWords {

    /// Twenty of them, so a working session does not repeat itself within a sitting.
    ///
    /// Each has to read as *busy* first and as fun second: this is the only thing on screen
    /// saying the turn has not stalled. Every one is a present participle or a gerund phrase
    /// for that reason — a noun or an adjective would describe a state rather than an activity.
    static let all: [String] = [
        "Thinking…",
        "Pondering…",
        "Ruminating…",
        "Cogitating…",
        "Mulling it over…",
        "Noodling…",
        "Percolating…",
        "Puzzling…",
        "Untangling…",
        "Deliberating…",
        "Scheming…",
        "Plotting…",
        "Tinkering…",
        "Whirring…",
        "Brewing…",
        "Chewing on it…",
        "Sharpening pencils…",
        "Connecting dots…",
        "Doing the reading…",
        "Consulting the oracle…"
    ]
}

/// Draws working words so that every one is used before any is used twice.
///
/// A plain random pick is the obvious implementation and is the wrong one: independent draws
/// repeat, and two identical words in consecutive turns read as the label having failed to
/// update rather than as chance. This is the shuffle-bag a game would use for the same
/// reason — shuffle the whole list, deal it out, reshuffle when it is empty.
///
/// The one seam between bags is handled explicitly: the last word of one bag can otherwise be
/// the first of the next, which is the exact repeat the bag exists to prevent.
struct WorkingWordCycle {

    // MARK: - Properties

    private let words: [String]

    /// Words not yet dealt from the current bag, in the order they will be dealt.
    private var remaining: [String] = []

    /// The word dealt most recently, kept only to keep it off the top of the next bag.
    private var lastDealt: String?

    // MARK: - Initialization

    init(words: [String] = WorkingWords.all) {
        // An empty list would make `next()` unanswerable, and the caller wants *a* word rather
        // than an optional it has no sensible way to render.
        self.words = words.isEmpty ? WorkingWords.all : words
    }

    // MARK: - Public Methods

    /// The next word, refilling and reshuffling when the bag runs out.
    mutating func next() -> String {
        if remaining.isEmpty { refill() }

        let word = remaining.removeLast()
        lastDealt = word
        return word
    }

    // MARK: - Private Methods

    private mutating func refill() {
        remaining = words.shuffled()

        // Words are dealt off the end, so the bag's first word is the array's last. With only
        // one word there is nothing to swap with and a repeat is not avoidable.
        guard let lastDealt, remaining.count > 1, remaining.last == lastDealt else { return }
        remaining.swapAt(remaining.count - 1, 0)
    }
}

// MARK: - Turn Receipt

/// Provider-neutral copy for the native conversation's one-line live status and last-turn
/// receipt. Kept out of AppKit so exact duration/token formatting is independently testable.
enum TurnStatusText {

    static func working(word: String, elapsed: TimeInterval, effort: String?) -> String {
        var details = [duration(elapsed)]
        if let effort = clean(effort) { details.append("\(effort) effort") }
        return "\(word)  (\(details.joined(separator: " · ")))"
    }

    static func ready(model: String?, lastTurn: TurnMetrics?) -> String {
        guard let lastTurn, !lastTurn.isEmpty else {
            guard let model = clean(model) else { return "Ready" }
            return "Ready · \(model)"
        }

        var details: [String] = []
        // Sub-second wrapper measurements round down to `0s`, which is bookkeeping noise rather
        // than a useful receipt. Keep the other facts if present; otherwise the status is simply
        // Ready instead of the misleading “last turn 0s”.
        if let value = lastTurn.duration, value >= 1 { details.append(duration(value)) }
        if let tokens = lastTurn.outputTokens {
            details.append("↓ \(tokenCount(tokens)) tokens")
        }
        if let effort = clean(lastTurn.effort) { details.append("\(effort) effort") }

        guard !details.isEmpty else { return "Ready" }
        return "Ready · last turn \(details.joined(separator: " · "))"
    }

    /// Past this share of the window, the context reading changes voice — t3code paints its
    /// donut red past 90%, and the number is the same warning here.
    static let contextWarningFraction = 0.9

    /// The context meter's text: a percentage where the provider states the window (Codex),
    /// an absolute count where it does not (Claude). Never over 100 — a reading past the
    /// window is the accounting drifting, not a number a user can act on.
    static func context(tokens: Int, window: Int?) -> String {
        guard let window, window > 0 else { return "\(tokenCount(tokens)) context" }
        let percent = min(100, Int((Double(tokens) / Double(window) * 100).rounded()))
        return "\(percent)% context"
    }

    static func contextIsNearlyFull(tokens: Int, window: Int?) -> Bool {
        guard let window, window > 0 else { return false }
        return Double(tokens) / Double(window) >= contextWarningFraction
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func tokenCount(_ count: Int) -> String {
        let count = max(0, count)
        if count < 1_000 { return String(count) }
        if count < 1_000_000 {
            return compact(Double(count) / 1_000) + "k"
        }
        return compact(Double(count) / 1_000_000) + "m"
    }

    private static func compact(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Run Progress

/// Admission limits for provider-owned checklist state.
///
/// The detail surfaces virtualize their rows, but the reducer, compact tooltip and remote mirror
/// all retain the value model. These limits therefore belong at the provider-neutral boundary,
/// before any transport or UI can accidentally turn an unbounded payload into durable state.
enum RunProgressLimits {
    static let maximumSteps = 256
    static let maximumTitleUTF8Bytes = 4_096
    static let maximumIdentifierUTF8Bytes = 1_024
    static let maximumPendingMutations = 512
    static let maximumObservedMutationsPerTurn = 4_096

    static func title(_ value: String) -> String {
        let ellipsis = "…"
        let budget = maximumTitleUTF8Bytes - ellipsis.utf8.count
        var byteCount = 0
        var admitted = String.UnicodeScalarView()

        for scalar in value.unicodeScalars {
            let nextCount = byteCount + scalar.utf8.count
            if nextCount > budget {
                return String(admitted) + ellipsis
            }
            admitted.append(scalar)
            byteCount = nextCount
        }
        return value
    }

    static func acceptsIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var byteCount = 0
        for scalar in value.unicodeScalars {
            byteCount += scalar.utf8.count
            if byteCount > maximumIdentifierUTF8Bytes { return false }
        }
        return true
    }
}

/// A provider-neutral position inside the plan an agent reports while a turn is running.
///
/// Codex reports complete ordered snapshots. Claude can do the same through `TodoWrite`, while
/// current releases build a task list incrementally with `TaskCreate` and `TaskUpdate`.
/// `RunProgressReducer` reconciles those wire shapes; this value is only their presentation.
struct RunProgress: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case pending
            case inProgress
            case completed

            init?(providerValue: String) {
                switch providerValue {
                case "pending":
                    self = .pending
                case "inProgress", "in_progress":
                    self = .inProgress
                case "completed":
                    self = .completed
                default:
                    return nil
                }
            }
        }

        let id: String?
        let title: String
        let status: Status

        init(id: String?, title: String, status: Status) {
            self.id = id.flatMap { RunProgressLimits.acceptsIdentifier($0) ? $0 : nil }
            self.title = RunProgressLimits.title(title)
            self.status = status
        }
    }

    private enum Presentation: Equatable, Sendable {
        case step(Int)
        case tasks(completed: Int, active: Int)
    }

    private let presentation: Presentation
    /// The provider's complete ordered checklist. Legacy summary-only initializers leave this
    /// empty; every structured plan/todo path retains the exact rows it reduced.
    let steps: [Step]
    let total: Int

    var completed: Int {
        if !steps.isEmpty { return steps.count { $0.status == .completed } }
        switch presentation {
        case .step(let step): return max(0, step - 1)
        case .tasks(let completed, _): return completed
        }
    }

    var active: Int {
        if !steps.isEmpty { return steps.count { $0.status == .inProgress } }
        switch presentation {
        case .step: return total > 0 ? 1 : 0
        case .tasks(_, let active): return active
        }
    }

    /// The first active row, or the first unfinished row when a provider has not marked one
    /// active yet. A completed plan keeps its last row as the compact subject until the turn
    /// boundary clears the plan.
    var currentStep: Step? {
        steps.first { $0.status == .inProgress }
            ?? steps.first { $0.status != .completed }
            ?? steps.last
    }

    /// One-based provider order for the compact counter and remote status strip.
    var currentPosition: Int {
        if let step { return step }
        if let currentStep,
           let index = steps.firstIndex(of: currentStep) {
            return index + 1
        }
        return max(1, min(total, completed + 1))
    }

    var compactLabel: String {
        guard let title = currentStep?.title else { return label }
        return L10n.format(
            "%@ · %lld of %lld",
            title,
            Int64(currentPosition),
            Int64(total)
        )
    }

    var step: Int? {
        guard case .step(let value) = presentation else { return nil }
        return value
    }

    var label: String {
        switch presentation {
        case .step(let step):
            return L10n.format(
                "Step %lld / %lld",
                Int64(step),
                Int64(total)
            )
        case .tasks(let completed, let active):
            let activeLabel = active == 1
                ? L10n.string("1 active")
                : L10n.format("%lld active", Int64(active))
            return L10n.format(
                "%lld / %lld done · %@",
                Int64(completed),
                Int64(total),
                activeLabel
            )
        }
    }

    init(step: Int, total: Int) {
        let total = max(1, total)
        self.presentation = .step(min(max(1, step), total))
        self.steps = []
        self.total = total
    }

    init(completed: Int, active: Int, total: Int) {
        self.presentation = .tasks(
            completed: min(max(0, completed), max(0, total)),
            active: max(0, active)
        )
        self.steps = []
        self.total = max(0, total)
    }

    init?(steps: [Step]) {
        guard !steps.isEmpty, steps.count <= RunProgressLimits.maximumSteps else { return nil }

        let activeIndices = steps.indices.filter { steps[$0].status == .inProgress }
        if activeIndices.count > 1 {
            self.presentation = .tasks(
                completed: steps.count { $0.status == .completed },
                active: activeIndices.count
            )
            self.steps = steps
            self.total = steps.count
            return
        }

        let next = activeIndices.first
            ?? steps.firstIndex { $0.status != .completed }
            ?? (steps.count - 1)
        self.presentation = .step(next + 1)
        self.steps = steps
        self.total = steps.count
    }

    init?(tool: ToolIdentity, input: [String: Any]) {
        guard let steps = Self.steps(tool: tool, input: input), !steps.isEmpty else {
            return nil
        }
        self.init(steps: steps)
    }

    /// The checklist a plan or todo tool call states, or nil when it does not state one.
    ///
    /// Both containers stay all-or-nothing. The compact summary and disclosed checklist share
    /// this exact value, so dropping an unreadable element would both move the denominator and
    /// omit a row the agent reported. The loop already returns nil for one entry whose status
    /// does not read, for the same reason; an element that is not an object at all says no less.
    static func steps(tool: ToolIdentity, input: [String: Any]) -> [Step]? {
        let items: [[String: Any]]
        let titleKey: String
        switch tool {
        case .plan:
            guard let plan = input["plan"] as? [[String: Any]] else { return nil }
            items = plan
            titleKey = "step"
        case .todoWrite:
            guard let todos = input["todos"] as? [[String: Any]] else { return nil }
            items = todos
            titleKey = "content"
        default:
            return nil
        }

        guard items.count <= RunProgressLimits.maximumSteps else { return nil }

        var steps: [Step] = []
        steps.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let statusValue = item["status"] as? String,
                  let status = Step.Status(providerValue: statusValue) else {
                return nil
            }
            let title = (item[titleKey] as? String)
                ?? (item["activeForm"] as? String)
                ?? "Step \(index + 1)"
            let id = item["id"] as? String
            if let id, !RunProgressLimits.acceptsIdentifier(id) { return nil }
            steps.append(Step(
                id: id,
                title: title,
                status: status
            ))
        }
        return steps
    }
}

/// Reconstructs the current run plan from both snapshot and incremental provider events.
///
/// Claude's own 2.1.220 client follows the same lifecycle: a `TaskCreate` is held by tool-use
/// id until its result returns `Task #<id> created successfully`, then later `TaskUpdate`
/// calls mutate or delete that stable id. Mirroring that state machine is more reliable than
/// parsing the prose Claude draws around its checklist and works unchanged during JSONL replay.
struct RunProgressReducer {
    enum Update {
        case unchanged
        case changed(RunProgress?)
    }

    private var tasks: [String: RunProgress.Step] = [:]
    private var order: [String] = []
    private var pendingTaskKeyByToolUseID: [String: String] = [:]
    private var pendingTaskUpdateToolUseIDs: Set<String> = []
    private var requiresSnapshot = false

    mutating func reset() -> Update {
        let hadProgress = progress != nil
        clearStorage()
        requiresSnapshot = false
        return hadProgress ? .changed(nil) : .unchanged
    }

    mutating func apply(plan steps: [RunProgress.Step]) -> Update {
        guard steps.count <= RunProgressLimits.maximumSteps else {
            return invalidateUntilSnapshot()
        }
        requiresSnapshot = false
        replace(with: steps)
        return .changed(progress)
    }

    mutating func apply(
        toolUseID: String,
        tool: ToolIdentity,
        input: [String: Any]
    ) -> Update {
        if tool == .plan || tool == .todoWrite {
            guard let steps = RunProgress.steps(tool: tool, input: input) else {
                return invalidateUntilSnapshot()
            }
            requiresSnapshot = false
            replace(with: steps)
            return .changed(progress)
        }

        guard !requiresSnapshot else { return .unchanged }

        switch tool {
        case .taskCreate:
            guard RunProgressLimits.acceptsIdentifier(toolUseID) else {
                return invalidateUntilSnapshot()
            }
            guard let title = nonEmpty(input["subject"] as? String)
                    ?? nonEmpty(input["activeForm"] as? String) else {
                return .unchanged
            }
            let key = "pending:\(toolUseID)"
            let step = RunProgress.Step(id: nil, title: title, status: .pending)
            if tasks[key] == nil {
                guard tasks.count < RunProgressLimits.maximumSteps else {
                    return invalidateUntilSnapshot()
                }
                order.append(key)
            }
            tasks[key] = step
            pendingTaskKeyByToolUseID[toolUseID] = key
            return .changed(progress)

        case .taskUpdate:
            guard RunProgressLimits.acceptsIdentifier(toolUseID) else {
                return invalidateUntilSnapshot()
            }
            guard let taskID = nonEmpty(input["taskId"] as? String)
                    ?? nonEmpty(input["task_id"] as? String)
                    ?? nonEmpty(input["id"] as? String) else {
                return .unchanged
            }
            guard RunProgressLimits.acceptsIdentifier(taskID) else {
                return invalidateUntilSnapshot()
            }
            if !pendingTaskUpdateToolUseIDs.contains(toolUseID),
               pendingTaskUpdateToolUseIDs.count >= RunProgressLimits.maximumPendingMutations {
                return invalidateUntilSnapshot()
            }
            pendingTaskUpdateToolUseIDs.insert(toolUseID)
            let key = "task:\(taskID)"
            let statusValue = input["status"] as? String

            if statusValue == "deleted" {
                remove(key)
                return .changed(progress)
            }

            let existing = tasks[key]
            let status: RunProgress.Step.Status
            if let statusValue {
                guard let reported = RunProgress.Step.Status(providerValue: statusValue) else {
                    return invalidateUntilSnapshot()
                }
                status = reported
            } else {
                status = existing?.status ?? .pending
            }
            let title = nonEmpty(input["subject"] as? String)
                ?? nonEmpty(input["activeForm"] as? String)
                ?? existing?.title
                ?? taskID

            if existing == nil {
                guard tasks.count < RunProgressLimits.maximumSteps else {
                    return invalidateUntilSnapshot()
                }
                order.append(key)
            }
            tasks[key] = RunProgress.Step(id: taskID, title: title, status: status)
            return .changed(progress)

        default:
            return .unchanged
        }
    }

    mutating func apply(result: ToolResult) -> Update {
        guard !requiresSnapshot else { return .unchanged }
        guard RunProgressLimits.acceptsIdentifier(result.toolUseID) else {
            return invalidateUntilSnapshot()
        }
        if pendingTaskUpdateToolUseIDs.remove(result.toolUseID) != nil {
            // TaskUpdate is drawn optimistically so a live checklist moves with the tool call.
            // Its failure carries no authoritative replacement state; clearing is more honest
            // than retaining a mutation Claude rejected. A later snapshot/update rebuilds it.
            return result.isError ? reset() : .unchanged
        }
        guard let pendingKey = pendingTaskKeyByToolUseID[result.toolUseID] else {
            return .unchanged
        }

        if result.isError {
            pendingTaskKeyByToolUseID.removeValue(forKey: result.toolUseID)
            remove(pendingKey)
            return .changed(progress)
        }

        guard let taskID = Self.createdTaskID(in: result.text),
              let pending = tasks[pendingKey] else {
            return invalidateUntilSnapshot()
        }

        pendingTaskKeyByToolUseID.removeValue(forKey: result.toolUseID)
        let stableKey = "task:\(taskID)"
        if let existing = tasks[stableKey] {
            tasks[stableKey] = RunProgress.Step(
                id: taskID,
                title: existing.title == taskID ? pending.title : existing.title,
                status: existing.status
            )
            remove(pendingKey)
        } else {
            tasks.removeValue(forKey: pendingKey)
            tasks[stableKey] = RunProgress.Step(
                id: taskID,
                title: pending.title,
                status: pending.status
            )
            if let index = order.firstIndex(of: pendingKey) {
                order[index] = stableKey
            } else {
                order.append(stableKey)
            }
        }
        return .changed(progress)
    }

    private var progress: RunProgress? {
        RunProgress(steps: order.compactMap { tasks[$0] })
    }

    var snapshot: RunProgress? { progress }

    private mutating func replace(with steps: [RunProgress.Step]) {
        clearStorage()

        for (index, step) in steps.enumerated() {
            let base = step.id.map { "task:\($0)" } ?? "snapshot:\(index)"
            var key = base
            var duplicate = 2
            while tasks[key] != nil {
                key = "\(base):\(duplicate)"
                duplicate += 1
            }
            tasks[key] = step
            order.append(key)
        }
    }

    private mutating func remove(_ key: String) {
        tasks.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func createdTaskID(in text: String) -> String? {
        let prefix = "Task #"
        guard text.hasPrefix(prefix),
              let suffix = text.range(
                  of: " created successfully",
                  range: text.index(text.startIndex, offsetBy: prefix.count)..<text.endIndex
              ) else { return nil }
        let id = text[text.index(text.startIndex, offsetBy: prefix.count)..<suffix.lowerBound]
        let value = String(id)
        return RunProgressLimits.acceptsIdentifier(value) ? value : nil
    }

    private mutating func clearStorage() {
        tasks.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        pendingTaskKeyByToolUseID.removeAll(keepingCapacity: true)
        pendingTaskUpdateToolUseIDs.removeAll(keepingCapacity: true)
    }

    private mutating func invalidateUntilSnapshot() -> Update {
        let hadProgress = progress != nil
        clearStorage()
        requiresSnapshot = true
        return hadProgress ? .changed(nil) : .unchanged
    }
}
