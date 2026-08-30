import Foundation
import ThreadingExtensionKit

enum WorkspaceNavigatorPipelineSectionIdentity: Equatable, Hashable, Sendable {
    case unbucketed
    case fact(key: ExtensionFactKey, value: ExtensionFactValue?)
    case rule(id: String)
}

struct WorkspaceNavigatorPipelineItem: Equatable, Sendable {
    let sourceSessionID: String
    let projectID: String?
    let destination: ExtensionWorkspaceNavigatorDestination
    let snapshotRevision: UInt64
    let referenceDate: Date
}

struct WorkspaceNavigatorPipelineSection: Equatable, Sendable {
    let identity: WorkspaceNavigatorPipelineSectionIdentity
    let title: String?
    let items: [WorkspaceNavigatorPipelineItem]
}

struct WorkspaceNavigatorPipelineEvaluation: Equatable, Sendable {
    let snapshotRevision: UInt64
    let referenceDate: Date
    let sections: [WorkspaceNavigatorPipelineSection]
    let omittedItemCount: Int
    let emptyState: ExtensionWorkspaceNavigatorEmptyState?

    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

/// Flat, immutable table input prepared beside evaluation on the worker queue. AppKit receives
/// one array swap and asks for semantic rows only inside its viewport; it never materializes an
/// NSObject tree proportional to the evaluator's output on the main actor.
struct WorkspaceNavigatorPipelinePresentation: Equatable, Sendable {
    enum Row: Equatable, Sendable {
        case section(title: String)
        case item(WorkspaceNavigatorPipelineItem)
    }

    let evaluation: WorkspaceNavigatorPipelineEvaluation
    let rows: [Row]
    let rowBySourceSessionID: [String: Int]

    init(evaluation: WorkspaceNavigatorPipelineEvaluation) {
        self.evaluation = evaluation
        var rows: [Row] = []
        rows.reserveCapacity(evaluation.itemCount + evaluation.sections.count)
        var rowBySourceSessionID: [String: Int] = [:]
        rowBySourceSessionID.reserveCapacity(evaluation.itemCount)
        for section in evaluation.sections {
            if let title = section.title { rows.append(.section(title: title)) }
            for item in section.items {
                rowBySourceSessionID[item.sourceSessionID] = rows.count
                rows.append(.item(item))
            }
        }
        self.rows = rows
        self.rowBySourceSessionID = rowBySourceSessionID
    }
}

/// Keeps navigator work bounded under rapid search input or provider updates. One evaluation may
/// be running while every later submission collapses into a single newest pending request.
final class WorkspaceNavigatorPipelineEvaluationScheduler: @unchecked Sendable {
    struct Request: Sendable {
        let sequence: Int
        let pipeline: CompiledWorkspaceNavigatorPipeline
        let query: String
        let calendar: Calendar
        /// One host-owned clock sample shared by evaluation and the midnight scheduler.
        let referenceDate: Date

        init(
            sequence: Int,
            pipeline: CompiledWorkspaceNavigatorPipeline,
            query: String,
            calendar: Calendar,
            referenceDate: Date = Date()
        ) {
            self.sequence = sequence
            self.pipeline = pipeline
            self.query = query
            self.calendar = calendar
            self.referenceDate = referenceDate
        }
    }

    struct Output: Sendable {
        let sequence: Int
        let query: String
        /// The exact immutable program evaluated for this presentation. The main actor accepts
        /// the pair atomically; it never renders rows against whichever revision compiled later.
        let pipeline: CompiledWorkspaceNavigatorPipeline
        let presentation: WorkspaceNavigatorPipelinePresentation
    }

    typealias Evaluate = @Sendable (Request) -> WorkspaceNavigatorPipelinePresentation
    typealias Deliver = @MainActor @Sendable (Output) -> Void

    private let queue: DispatchQueue
    private let evaluate: Evaluate
    private let deliver: Deliver
    private let lock = NSLock()
    private var pending: Request?
    private var isDraining = false

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "codes.threading.workspace-navigator-evaluation",
            qos: .userInitiated
        ),
        evaluate: @escaping Evaluate = { request in
            let evaluation = WorkspaceNavigatorPipelineEvaluator(
                calendar: request.calendar,
                now: { request.referenceDate }
            ).evaluate(request.pipeline, query: request.query)
            return WorkspaceNavigatorPipelinePresentation(evaluation: evaluation)
        },
        deliver: @escaping Deliver
    ) {
        self.queue = queue
        self.evaluate = evaluate
        self.deliver = deliver
    }

    func submit(_ request: Request) {
        lock.lock()
        pending = request
        let shouldStart = !isDraining
        if shouldStart { isDraining = true }
        lock.unlock()

        guard shouldStart else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func invalidate() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    private func drain() {
        while let request = takePendingRequest() {
            let presentation = evaluate(request)
            let output = Output(
                sequence: request.sequence,
                query: request.query,
                pipeline: request.pipeline,
                presentation: presentation
            )
            DispatchQueue.main.async { [deliver] in deliver(output) }
        }
    }

    private func takePendingRequest() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending else {
            isDraining = false
            return nil
        }
        pending = nil
        return request
    }
}

/// Literal semantic content for one visible row. The renderer remains responsible for controls,
/// theme, accessibility mechanics, layout, and collection reuse.
indirect enum WorkspaceNavigatorRealizedTemplateNode: Equatable, Sendable {
    case text(String, role: ExtensionTextRole)
    case image(
        WorkspaceNavigatorRealizedImage,
        role: ExtensionImageRole,
        accessibilityLabel: String?
    )
    case status(String, role: ExtensionStatusRole)
    case activityIndicator(accessibilityLabel: String)
    case divider
    case spacer(ExtensionSpacing)
    case flexibleSpacer
    case stack(axis: ExtensionAxis, spacing: ExtensionSpacing, children: [Self])
}

/// An image plus the authority which owns a package-relative resource reference.
///
/// A `nil` source means the navigator declaration itself supplied the literal or fallback. A
/// fact-bound image retains the exact provider generation so the renderer cannot accidentally
/// resolve another extension's package, or a replacement generation of the same extension.
struct WorkspaceNavigatorRealizedImage: Equatable, Sendable {
    let reference: ExtensionImageReference
    let factSource: ExtensionFactResolutionSource?
}

struct WorkspaceNavigatorPipelineEvaluator: Sendable {
    let calendar: Calendar
    let now: @Sendable () -> Date

    init(
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.calendar = calendar
        self.now = now
    }

    /// Evaluates only structure and host routes. It deliberately does not realize row templates.
    func evaluate(
        _ pipeline: CompiledWorkspaceNavigatorPipeline,
        query: String = ""
    ) -> WorkspaceNavigatorPipelineEvaluation {
        guard pipeline.rowTemplate != nil else {
            let referenceDate = now()
            return .init(
                snapshotRevision: pipeline.snapshot.revision,
                referenceDate: referenceDate,
                sections: [],
                omittedItemCount: 0,
                emptyState: pipeline.output.emptyState
            )
        }

        let referenceDate = now()
        var candidates = pipeline.snapshot.sessionSubjects.compactMap { subject -> Candidate? in
            guard case let .session(id) = subject else { return nil }
            let projectID: String? = if case let .project(id)? = pipeline.snapshot.projectSubject(
                for: subject
            ) {
                id
            } else {
                nil
            }
            return Candidate(subject: subject, sessionID: id, projectID: projectID)
        }
        if let search = pipeline.search, !query.isEmpty {
            candidates.removeAll {
                !matchesSearch(
                    query,
                    fields: search.fields,
                    candidate: $0,
                    snapshot: pipeline.snapshot
                )
            }
        }
        for filter in pipeline.filters {
            candidates.removeAll {
                truth(
                    of: filter.predicate,
                    candidate: $0,
                    snapshot: pipeline.snapshot,
                    referenceDate: referenceDate
                ) != .true
            }
        }
        if let template = pipeline.rowTemplate {
            candidates.removeAll {
                !hasContent(
                    template,
                    candidate: $0,
                    snapshot: pipeline.snapshot,
                    referenceDate: referenceDate
                )
            }
        }
        candidates.sort {
            compare(
                $0,
                $1,
                clauses: pipeline.sort,
                snapshot: pipeline.snapshot
            )
        }

        let unboundedSections = sections(
            from: candidates,
            bucket: pipeline.bucket,
            snapshot: pipeline.snapshot,
            referenceDate: referenceDate
        )
        let eligibleCount = unboundedSections.reduce(0) { $0 + $1.candidates.count }
        var remaining = pipeline.output.itemLimit
        var sections: [WorkspaceNavigatorPipelineSection] = []
        for section in unboundedSections where remaining > 0 {
            let candidates = Array(section.candidates.prefix(remaining))
            guard !candidates.isEmpty else { continue }
            sections.append(.init(
                identity: section.identity,
                title: section.title,
                items: candidates.map {
                    .init(
                        sourceSessionID: $0.sessionID,
                        projectID: $0.projectID,
                        destination: pipeline.output.activation.destination(
                            sourceSessionID: $0.sessionID,
                            projectID: $0.projectID
                        ),
                        snapshotRevision: pipeline.snapshot.revision,
                        referenceDate: referenceDate
                    )
                }
            ))
            remaining -= candidates.count
        }
        return .init(
            snapshotRevision: pipeline.snapshot.revision,
            referenceDate: referenceDate,
            sections: sections,
            omittedItemCount: max(0, eligibleCount - pipeline.output.itemLimit),
            emptyState: sections.isEmpty ? pipeline.output.emptyState : nil
        )
    }

    /// Resolves one row on demand after collection virtualization decides it is visible.
    func realizeVisibleRow(
        _ item: WorkspaceNavigatorPipelineItem,
        in pipeline: CompiledWorkspaceNavigatorPipeline
    ) -> WorkspaceNavigatorRealizedTemplateNode? {
        guard item.snapshotRevision == pipeline.snapshot.revision,
              let template = pipeline.rowTemplate else { return nil }
        let candidate = Candidate(
            subject: .session(item.sourceSessionID),
            sessionID: item.sourceSessionID,
            projectID: item.projectID
        )
        return realize(
            template,
            candidate: candidate,
            snapshot: pipeline.snapshot,
            referenceDate: item.referenceDate
        )
    }

    private func sections(
        from candidates: [Candidate],
        bucket: ExtensionWorkspaceNavigatorBucketStrategy?,
        snapshot: ExtensionFactSnapshot,
        referenceDate: Date
    ) -> [CandidateSection] {
        guard let bucket else {
            return candidates.isEmpty ? [] : [.init(
                identity: .unbucketed,
                title: nil,
                candidates: candidates
            )]
        }
        switch bucket {
        case let .fact(operand, direction, explicitOrder):
            return factSections(
                candidates,
                operand: operand,
                direction: direction,
                explicitOrder: explicitOrder,
                snapshot: snapshot
            )
        case let .rules(rules, unmatched):
            return ruleSections(
                candidates,
                rules: rules,
                unmatched: unmatched,
                snapshot: snapshot,
                referenceDate: referenceDate
            )
        }
    }

    private func factSections(
        _ candidates: [Candidate],
        operand: ExtensionWorkspaceNavigatorFactOperand,
        direction: ExtensionWorkspaceNavigatorSortDirection,
        explicitOrder: [ExtensionFactValue],
        snapshot: ExtensionFactSnapshot
    ) -> [CandidateSection] {
        var groups: [FactBucket: [Candidate]] = [:]
        for candidate in candidates {
            let value = resolvedValue(operand, candidate: candidate, snapshot: snapshot)
            groups[value.map(FactBucket.value) ?? .unknown, default: []].append(candidate)
        }
        let explicitRanks = Dictionary(
            explicitOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedKeys = groups.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.unknown, .unknown):
                return false
            case (.unknown, _):
                return false
            case (_, .unknown):
                return true
            case let (.value(lhsValue), .value(rhsValue)):
                let lhsRank = explicitRanks[lhsValue]
                let rhsRank = explicitRanks[rhsValue]
                switch (lhsRank, rhsRank) {
                case let (.some(lhsRank), .some(rhsRank)):
                    return lhsRank < rhsRank
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    let order = compareValues(lhsValue, rhsValue)
                    return direction == .ascending ? order < 0 : order > 0
                }
            }
        }
        return orderedKeys.compactMap { key in
            guard let members = groups[key], !members.isEmpty else { return nil }
            switch key {
            case .unknown:
                return .init(
                    identity: .fact(key: operand.fact.key, value: nil),
                    title: nil,
                    candidates: members
                )
            case let .value(value):
                let title = members.lazy.compactMap {
                    resolvedFact(operand.fact, candidate: $0, snapshot: snapshot)?.fact.label
                }.first ?? text(for: value)
                return .init(
                    identity: .fact(key: operand.fact.key, value: value),
                    title: title,
                    candidates: members
                )
            }
        }
    }

    private func ruleSections(
        _ candidates: [Candidate],
        rules: [ExtensionWorkspaceNavigatorBucketRule],
        unmatched: ExtensionWorkspaceNavigatorUnmatchedBucket,
        snapshot: ExtensionFactSnapshot,
        referenceDate: Date
    ) -> [CandidateSection] {
        var groups: [String: [Candidate]] = [:]
        var order: [(id: String, title: String)] = rules.map { ($0.id, $0.title) }
        let unmatchedIdentity: (id: String, title: String)? = switch unmatched {
        case .omit:
            nil
        case let .bucket(id, title):
            (id, title)
        }
        if let unmatchedIdentity {
            order.append(unmatchedIdentity)
        }

        for candidate in candidates {
            if let rule = rules.first(where: {
                truth(
                    of: $0.predicate,
                    candidate: candidate,
                    snapshot: snapshot,
                    referenceDate: referenceDate
                ) == .true
            }) {
                groups[rule.id, default: []].append(candidate)
            } else if let unmatchedIdentity {
                groups[unmatchedIdentity.id, default: []].append(candidate)
            }
        }
        return order.compactMap { identity in
            guard let members = groups[identity.id], !members.isEmpty else { return nil }
            return .init(
                identity: .rule(id: identity.id),
                title: identity.title,
                candidates: members
            )
        }
    }

    private func matchesSearch(
        _ query: String,
        fields: [ExtensionWorkspaceNavigatorFactReference],
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> Bool {
        fields.contains { field in
            guard case let .string(value)? = resolvedFact(
                field,
                candidate: candidate,
                snapshot: snapshot
            )?.fact.value else { return false }
            return value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    private func compare(
        _ lhs: Candidate,
        _ rhs: Candidate,
        clauses: [ExtensionWorkspaceNavigatorSortClause],
        snapshot: ExtensionFactSnapshot
    ) -> Bool {
        for clause in clauses {
            let lhsValue = resolvedValue(clause.operand, candidate: lhs, snapshot: snapshot)
            let rhsValue = resolvedValue(clause.operand, candidate: rhs, snapshot: snapshot)
            switch (lhsValue, rhsValue) {
            case (nil, nil):
                continue
            case (nil, _):
                return false
            case (_, nil):
                return true
            case let (.some(lhsValue), .some(rhsValue)):
                let order = compareValues(lhsValue, rhsValue)
                guard order != 0 else { continue }
                return clause.direction == .ascending ? order < 0 : order > 0
            }
        }
        return lhs.sessionID < rhs.sessionID
    }

    private func truth(
        of predicate: ExtensionWorkspaceNavigatorPredicate,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot,
        referenceDate: Date
    ) -> PredicateTruth {
        switch predicate {
        case let .comparison(operand, operation, expected):
            guard let value = resolvedValue(
                operand,
                candidate: candidate,
                snapshot: snapshot
            ) else { return .unknown }
            let order = compareValues(value, expected)
            let matches = switch operation {
            case .equal: order == 0
            case .notEqual: order != 0
            case .lessThan: order < 0
            case .lessThanOrEqual: order <= 0
            case .greaterThan: order > 0
            case .greaterThanOrEqual: order >= 0
            }
            return .init(matches: matches)
        case let .isPresent(reference):
            return .init(matches: resolvedFact(
                reference,
                candidate: candidate,
                snapshot: snapshot
            ) != nil)
        case let .relativeDate(operand, range):
            guard case let .date(value)? = resolvedValue(
                operand,
                candidate: candidate,
                snapshot: snapshot
            ), let interval = dateInterval(for: range, referenceDate: referenceDate) else {
                return .unknown
            }
            return .init(matches: interval.contains(value))
        case let .all(predicates):
            var sawUnknown = false
            for child in predicates {
                switch truth(
                    of: child,
                    candidate: candidate,
                    snapshot: snapshot,
                    referenceDate: referenceDate
                ) {
                case .false: return .false
                case .unknown: sawUnknown = true
                case .true: break
                }
            }
            return sawUnknown ? .unknown : .true
        case let .any(predicates):
            var sawUnknown = false
            for child in predicates {
                switch truth(
                    of: child,
                    candidate: candidate,
                    snapshot: snapshot,
                    referenceDate: referenceDate
                ) {
                case .true: return .true
                case .unknown: sawUnknown = true
                case .false: break
                }
            }
            return sawUnknown ? .unknown : .false
        case let .not(predicate):
            return truth(
                of: predicate,
                candidate: candidate,
                snapshot: snapshot,
                referenceDate: referenceDate
            ).negated
        }
    }

    private func dateInterval(
        for range: ExtensionWorkspaceNavigatorRelativeDateRange,
        referenceDate: Date
    ) -> DateInterval? {
        let today = calendar.startOfDay(for: referenceDate)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return nil
        }
        switch range {
        case .today:
            return .init(start: today, end: tomorrow)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return nil
            }
            return .init(start: yesterday, end: today)
        case let .lastDays(days):
            guard days > 0,
                  let start = calendar.date(byAdding: .day, value: -(days - 1), to: today)
            else { return nil }
            return .init(start: start, end: tomorrow)
        }
    }

    private func realize(
        _ node: ExtensionWorkspaceNavigatorTemplateNode,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot,
        referenceDate: Date
    ) -> WorkspaceNavigatorRealizedTemplateNode? {
        switch node {
        case let .text(binding, role):
            guard let value = resolveText(binding, candidate: candidate, snapshot: snapshot) else {
                return nil
            }
            return .text(value, role: role)
        case let .image(binding, role, accessibilityLabel):
            guard let value = resolveImage(binding, candidate: candidate, snapshot: snapshot) else {
                return nil
            }
            return .image(value, role: role, accessibilityLabel: accessibilityLabel)
        case let .status(binding, role):
            guard let value = resolveText(binding, candidate: candidate, snapshot: snapshot) else {
                return nil
            }
            return .status(
                value,
                role: resolveStatus(role, candidate: candidate, snapshot: snapshot)
            )
        case let .activityIndicator(accessibilityLabel):
            return .activityIndicator(accessibilityLabel: accessibilityLabel)
        case let .conditional(predicate, content):
            guard truth(
                of: predicate,
                candidate: candidate,
                snapshot: snapshot,
                referenceDate: referenceDate
            ) == .true else { return nil }
            return realize(
                content,
                candidate: candidate,
                snapshot: snapshot,
                referenceDate: referenceDate
            )
        case .divider:
            return .divider
        case let .spacer(spacing):
            return .spacer(spacing)
        case .flexibleSpacer:
            return .flexibleSpacer
        case let .stack(axis, spacing, children):
            let children = children.compactMap {
                realize(
                    $0,
                    candidate: candidate,
                    snapshot: snapshot,
                    referenceDate: referenceDate
                )
            }
            guard !children.isEmpty else { return nil }
            return .stack(axis: axis, spacing: spacing, children: children)
        }
    }

    /// Tests semantic presence without allocating a realized tree for every source subject.
    /// Structure evaluation must remove an empty row before it becomes selectable, while actual
    /// strings, image values, and view trees remain visible-row work.
    private func hasContent(
        _ node: ExtensionWorkspaceNavigatorTemplateNode,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot,
        referenceDate: Date
    ) -> Bool {
        switch node {
        case let .text(binding, _), let .status(binding, _):
            resolveText(binding, candidate: candidate, snapshot: snapshot) != nil
        case let .image(binding, _, _):
            resolveImage(binding, candidate: candidate, snapshot: snapshot) != nil
        case .activityIndicator, .divider, .spacer, .flexibleSpacer:
            true
        case let .conditional(predicate, content):
            truth(
                of: predicate,
                candidate: candidate,
                snapshot: snapshot,
                referenceDate: referenceDate
            ) == .true && hasContent(
                content,
                candidate: candidate,
                snapshot: snapshot,
                referenceDate: referenceDate
            )
        case let .stack(_, _, children):
            children.contains {
                hasContent(
                    $0,
                    candidate: candidate,
                    snapshot: snapshot,
                    referenceDate: referenceDate
                )
            }
        }
    }

    private func resolveText(
        _ binding: ExtensionWorkspaceNavigatorTextBinding,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> String? {
        switch binding {
        case let .literal(value):
            return value
        case let .fact(reference, facet, fallback):
            guard let fact = resolvedFact(reference, candidate: candidate, snapshot: snapshot) else {
                return fallback
            }
            switch facet {
            case .value:
                return text(for: fact.fact.value)
            case .label:
                return fact.fact.label ?? fallback
            }
        }
    }

    private func resolveImage(
        _ binding: ExtensionWorkspaceNavigatorImageBinding,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> WorkspaceNavigatorRealizedImage? {
        switch binding {
        case let .literal(value):
            return .init(reference: value, factSource: nil)
        case let .factIcon(reference, fallback):
            if let fact = resolvedFact(reference, candidate: candidate, snapshot: snapshot),
               let icon = fact.fact.icon
            {
                return .init(reference: icon, factSource: fact.source)
            }
            return fallback.map { .init(reference: $0, factSource: nil) }
        }
    }

    private func resolveStatus(
        _ binding: ExtensionWorkspaceNavigatorStatusBinding,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> ExtensionStatusRole {
        switch binding {
        case let .literal(value):
            return value
        case let .factStatus(reference, fallback):
            return resolvedFact(reference, candidate: candidate, snapshot: snapshot)?.fact.status
                ?? fallback
        }
    }

    private func resolvedValue(
        _ operand: ExtensionWorkspaceNavigatorFactOperand,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> ExtensionFactValue? {
        resolvedFact(operand.fact, candidate: candidate, snapshot: snapshot)?.fact.value
            ?? operand.fallback
    }

    private func resolvedFact(
        _ reference: ExtensionWorkspaceNavigatorFactReference,
        candidate: Candidate,
        snapshot: ExtensionFactSnapshot
    ) -> ExtensionResolvedFact? {
        switch reference.scope {
        case .item:
            return snapshot.fact(reference.key, for: candidate.subject)
        case .project:
            guard let project = snapshot.projectSubject(for: candidate.subject) else { return nil }
            return snapshot.fact(reference.key, for: project)
        }
    }
}

private struct Candidate: Sendable {
    let subject: ExtensionFactSubject
    let sessionID: String
    let projectID: String?
}

private struct CandidateSection {
    let identity: WorkspaceNavigatorPipelineSectionIdentity
    let title: String?
    let candidates: [Candidate]
}

private enum FactBucket: Hashable {
    case value(ExtensionFactValue)
    case unknown
}

private enum PredicateTruth {
    case `false`
    case `true`
    case unknown

    init(matches: Bool) {
        self = matches ? .true : .false
    }

    var negated: Self {
        switch self {
        case .false: .true
        case .true: .false
        case .unknown: .unknown
        }
    }
}

private func compareValues(_ lhs: ExtensionFactValue, _ rhs: ExtensionFactValue) -> Int {
    switch (lhs, rhs) {
    case let (.string(lhs), .string(rhs)):
        compare(lhs, rhs)
    case let (.boolean(lhs), .boolean(rhs)):
        compare(lhs ? 1 : 0, rhs ? 1 : 0)
    case let (.integer(lhs), .integer(rhs)):
        compare(lhs, rhs)
    case let (.number(lhs), .number(rhs)):
        compare(lhs, rhs)
    case let (.date(lhs), .date(rhs)):
        compare(lhs, rhs)
    default:
        lhs.type.rawValue < rhs.type.rawValue ? -1 : 1
    }
}

private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
    if lhs < rhs { return -1 }
    if lhs > rhs { return 1 }
    return 0
}

private func text(for value: ExtensionFactValue) -> String {
    switch value {
    case let .string(value): value
    case let .boolean(value): value ? "true" : "false"
    case let .integer(value): String(value)
    case let .number(value): String(value)
    case let .date(value): ISO8601DateFormatter().string(from: value)
    }
}
