import Foundation

// MARK: - Session Usage Projection

/// A provider-neutral receipt for one Threading session and the delegated work beneath it.
///
/// Indexed token categories and prices come only from the transcript usage ledger. A provider's
/// live child counter may be newer than that index; the difference is retained separately as
/// `unindexedTokens` so the UI can show the freshest honest total without pretending to know its
/// input/output split or price.
struct SessionUsageSnapshot: Equatable, Sendable {
    enum IndexedRange: Equatable, Sendable {
        case lifetime
        case lastNinetyDays
        case unavailable
    }

    struct Model: Equatable, Sendable {
        let name: String
        let tokens: UsageTokenCounts
        let cost: UsageReportSelection.CostQuality
        let records: Int
    }

    struct Reading: Equatable, Sendable {
        var tokens = UsageTokenCounts()
        var unindexedTokens: Int64 = 0
        var cost = UsageReportSelection.CostQuality()
        var records = 0
        var models: [Model] = []
        var remainingModelCount = 0

        /// Everything known to have been processed. The unindexed portion is deliberately not
        /// folded into any token category above.
        var processedTokens: Int64 { tokens.processed + unindexedTokens }
        var isEmpty: Bool { processedTokens == 0 && records == 0 }
    }

    let sessionID: SessionID
    let total: Reading
    let main: Reading
    let subagents: Reading
    let children: [String: Reading]
    let indexedRange: IndexedRange
    let builtAt: Date?
    let pricingCatalogVersion: String?
    let coverage: UsageSourceCoverage?
}

enum SessionUsageDefaults {
    /// The detailed Info view is a fixed form, not another Usage dashboard. Aggregate the full
    /// model set off-main, then retain only the leading rows before any AppKit views are built.
    nonisolated static let maximumModelRows = 6
    /// Selection is the only lifetime this derived cache needs. Keeping a small recent working
    /// set covers multiple windows without re-projecting every session a person has ever opened.
    nonisolated static let maximumRememberedSessions = 32
}

enum SessionUsageProjector {
    struct Child: Equatable, Sendable {
        let id: String
        let identities: Set<String>
        let observedProcessedTokens: Int64?

        init(id: String, identities: Set<String>, observedProcessedTokens: Int64? = nil) {
            self.id = id
            self.identities = identities
            self.observedProcessedTokens = observedProcessedTokens.map { max(0, $0) }
        }
    }

    struct Input: Equatable, Sendable {
        let sessionID: SessionID
        let runtimeID: String
        let mainIdentities: Set<String>
        let children: [Child]
    }

    /// The machine-wide report is indexed once per completed transcript scan. Session refreshes
    /// then visit only the parent and child identities they own rather than every session cell.
    struct Index: Sendable {
        fileprivate let cellsBySessionID: [String: [TranscriptUsageReport.SessionCell]]
        fileprivate let childCellsByParentSessionID: [String: [TranscriptUsageReport.SessionCell]]
        fileprivate let indexedRange: SessionUsageSnapshot.IndexedRange
        fileprivate let builtAt: Date?
        fileprivate let pricingCatalogVersion: String?
        fileprivate let coverage: [UsageSourceCoverage]

        init(report: TranscriptUsageReport?) {
            let cells: [TranscriptUsageReport.SessionCell]
            if let lifetime = report?.sessionCells {
                cells = lifetime
                indexedRange = .lifetime
            } else if let recent = report?.cells {
                cells = recent.compactMap { cell in
                    guard let sessionID = cell.sessionID else { return nil }
                    return TranscriptUsageReport.SessionCell(
                        sessionID: sessionID,
                        origin: cell.origin,
                        accountID: cell.accountID,
                        accountName: cell.accountName,
                        model: cell.model,
                        tokens: cell.tokens,
                        providerReportedCostUSD: cell.providerReportedCostUSD,
                        catalogCostUSD: cell.catalogCostUSD,
                        unpricedTokens: cell.unpricedTokens,
                        cacheSavingsUSD: cell.cacheSavingsUSD,
                        records: cell.records
                    )
                }
                indexedRange = .lastNinetyDays
            } else {
                cells = []
                indexedRange = .unavailable
            }

            cellsBySessionID = Dictionary(grouping: cells) {
                SessionUsageProjector.normalize($0.sessionID)
            }
            var childrenByParent: [String: [TranscriptUsageReport.SessionCell]] = [:]
            for cell in cells where cell.sessionKind == .subagent {
                guard let parent = cell.parentSessionID.map(SessionUsageProjector.normalize),
                      !parent.isEmpty else { continue }
                childrenByParent[parent, default: []].append(cell)
            }
            childCellsByParentSessionID = childrenByParent
            builtAt = report?.builtAt
            pricingCatalogVersion = report?.pricingCatalogVersion
            coverage = report?.coverage ?? []
        }
    }

    private struct Accumulator {
        var tokens = UsageTokenCounts()
        var cost = UsageReportSelection.CostQuality()
        var records = 0
        var models: [String: ModelAccumulator] = [:]

        mutating func add(_ cell: TranscriptUsageReport.SessionCell) {
            tokens += cell.tokens
            cost.providerReportedUSD += cell.providerReportedCostUSD
            cost.catalogPricedUSD += cell.catalogCostUSD
            cost.unpricedTokens += cell.unpricedTokens
            cost.cacheSavingsUSD += cell.cacheSavingsUSD
            records += cell.records

            var model = models[cell.model] ?? ModelAccumulator()
            model.tokens += cell.tokens
            model.cost.providerReportedUSD += cell.providerReportedCostUSD
            model.cost.catalogPricedUSD += cell.catalogCostUSD
            model.cost.unpricedTokens += cell.unpricedTokens
            model.cost.cacheSavingsUSD += cell.cacheSavingsUSD
            model.records += cell.records
            models[cell.model] = model
        }

        func reading(unindexedTokens: Int64 = 0) -> SessionUsageSnapshot.Reading {
            let sorted = models.map { name, value in
                SessionUsageSnapshot.Model(
                    name: name,
                    tokens: value.tokens,
                    cost: value.cost,
                    records: value.records
                )
            }.sorted { lhs, rhs in
                if lhs.tokens.processed != rhs.tokens.processed {
                    return lhs.tokens.processed > rhs.tokens.processed
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            let retained = Array(sorted.prefix(SessionUsageDefaults.maximumModelRows))
            return SessionUsageSnapshot.Reading(
                tokens: tokens,
                unindexedTokens: max(0, unindexedTokens),
                cost: cost,
                records: records,
                models: retained,
                remainingModelCount: max(0, sorted.count - retained.count)
            )
        }
    }

    private struct ModelAccumulator {
        var tokens = UsageTokenCounts()
        var cost = UsageReportSelection.CostQuality()
        var records = 0
    }

    private enum Owner: Hashable {
        case main
        case child(String)
    }

    private struct IndexedCellKey: Hashable {
        let sessionID: String
        let origin: UsageOrigin
        let accountID: String
        let model: String
        let sessionKind: UsageSessionKind?
        let parentSessionID: String?

        init(_ cell: TranscriptUsageReport.SessionCell) {
            sessionID = SessionUsageProjector.normalize(cell.sessionID)
            origin = cell.origin
            accountID = cell.accountID
            model = cell.model
            sessionKind = cell.sessionKind
            parentSessionID = cell.parentSessionID.map(SessionUsageProjector.normalize)
        }
    }

    nonisolated static func project(
        report: TranscriptUsageReport?,
        input: Input
    ) -> SessionUsageSnapshot {
        project(index: Index(report: report), input: input)
    }

    nonisolated static func project(
        index: Index,
        input: Input
    ) -> SessionUsageSnapshot {

        var owners: [String: Owner] = [:]
        for identity in input.mainIdentities {
            let key = normalize(identity)
            guard !key.isEmpty else { continue }
            owners[key] = .main
        }
        // A child identity is more specific than the parent's aliases. Let it win if a provider
        // has repeated an identifier in both sets rather than charging delegated work to main.
        for child in input.children {
            for identity in child.identities {
                let key = normalize(identity)
                guard !key.isEmpty else { continue }
                owners[key] = .child(child.id)
            }
        }

        var main = Accumulator()
        var subagents = Accumulator()
        var total = Accumulator()
        var children: [String: Accumulator] = [:]
        for child in input.children { children[child.id] = Accumulator() }

        var admitted = Set<IndexedCellKey>()
        func add(_ cell: TranscriptUsageReport.SessionCell, owner: Owner?) {
            guard admitted.insert(IndexedCellKey(cell)).inserted else { return }
            switch owner {
            case .main:
                main.add(cell)
                total.add(cell)
            case .child(let id):
                children[id, default: Accumulator()].add(cell)
                subagents.add(cell)
                total.add(cell)
            case nil:
                // The transcript proves this is delegated work for the parent, but no live or
                // persisted navigator identity currently names a row for it. Keep the exact
                // parent/subagent receipt without manufacturing presentation state.
                subagents.add(cell)
                total.add(cell)
            }
        }

        let parentIdentities = Set(input.mainIdentities.map(normalize).filter { !$0.isEmpty })
        for parent in parentIdentities {
            for cell in index.childCellsByParentSessionID[parent] ?? [] {
                let explicitOwner: Owner?
                if case .child(let id)? = owners[normalize(cell.sessionID)] {
                    explicitOwner = .child(id)
                } else {
                    explicitOwner = nil
                }
                add(cell, owner: explicitOwner)
            }
        }
        for identity in Set(owners.keys) {
            for cell in index.cellsBySessionID[identity] ?? [] {
                guard let owner = owners[normalize(cell.sessionID)] else { continue }
                add(cell, owner: owner)
            }
        }

        var childReadings: [String: SessionUsageSnapshot.Reading] = [:]
        var observedDelta: Int64 = 0
        for child in input.children {
            let indexed = children[child.id]?.tokens.processed ?? 0
            let delta = max(0, (child.observedProcessedTokens ?? 0) - indexed)
            observedDelta += delta
            childReadings[child.id] = (children[child.id] ?? Accumulator())
                .reading(unindexedTokens: delta)
        }

        return SessionUsageSnapshot(
            sessionID: input.sessionID,
            total: total.reading(unindexedTokens: observedDelta),
            main: main.reading(),
            subagents: subagents.reading(unindexedTokens: observedDelta),
            children: childReadings,
            indexedRange: index.indexedRange,
            builtAt: index.builtAt,
            pricingCatalogVersion: index.pricingCatalogVersion,
            coverage: index.coverage.first { $0.runtimeID == input.runtimeID }
        )
    }

    private nonisolated static func normalize(_ identity: String) -> String {
        identity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Session Usage Service

/// Queue-confined cache. The containing service schedules every access on one serial queue.
private final class SessionUsageProjectionWorker: @unchecked Sendable {
    private var reportGeneration = -1
    private var index = SessionUsageProjector.Index(report: nil)

    func project(
        report: TranscriptUsageReport?,
        reportGeneration: Int,
        input: SessionUsageProjector.Input
    ) -> SessionUsageSnapshot {
        if reportGeneration != self.reportGeneration {
            index = SessionUsageProjector.Index(report: report)
            self.reportGeneration = reportGeneration
        }
        return SessionUsageProjector.project(index: index, input: input)
    }
}

/// Keeps session projections off the main actor and republishes only immutable snapshots.
@MainActor
final class SessionUsageService {
    static let shared = SessionUsageService()

    private let usageService: TranscriptUsageService
    private let queue = DispatchQueue(label: "codes.threading.session-usage", qos: .utility)
    private let projectionWorker = SessionUsageProjectionWorker()
    private let appEvents = AppEventObservations()
    private var requestedSessionIDs: [SessionID] = []
    private var generations: [SessionID: Int] = [:]
    private var snapshots: [SessionID: SessionUsageSnapshot] = [:]
    private var reportGeneration = 0

    init(usageService: TranscriptUsageService = .shared) {
        self.usageService = usageService
        appEvents.observe(TranscriptUsageDidChange.self) { [weak self] _ in
            self?.reportGeneration += 1
            self?.reprojectRequestedSessions()
        }
    }

    func snapshot(for sessionID: SessionID) -> SessionUsageSnapshot? {
        snapshots[sessionID]
    }

    /// Requests the newest indexed receipt. `forceIndex` is reserved for a turn-finished edge;
    /// ordinary selection honors the usage index's staleness window.
    func refresh(_ sessionID: SessionID, forceIndex: Bool = false) {
        remember(sessionID)
        usageService.refresh(force: forceIndex)
        project(sessionID)
    }

    /// Child counters move independently of the transcript index and can be projected at once.
    func subagentsDidChange(for sessionID: SessionID) {
        guard requestedSessionIDs.contains(sessionID) else { return }
        project(sessionID)
    }

    private func reprojectRequestedSessions() {
        for sessionID in requestedSessionIDs {
            project(sessionID)
        }
    }

    private func remember(_ sessionID: SessionID) {
        requestedSessionIDs.removeAll { $0 == sessionID }
        requestedSessionIDs.append(sessionID)
        while requestedSessionIDs.count > SessionUsageDefaults.maximumRememberedSessions {
            let removed = requestedSessionIDs.removeFirst()
            snapshots.removeValue(forKey: removed)
            generations.removeValue(forKey: removed)
        }
    }

    private func project(_ sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            snapshots.removeValue(forKey: sessionID)
            return
        }

        let timeline = AgentRuntime.shared.subagentState(for: sessionID).timeline
        let children = timeline.agents.map { agent -> SessionUsageProjector.Child in
            let descriptor = agent.descriptor
            var identities = Set([descriptor.threadID])
            identities.formUnion(descriptor.alternateThreadIDs ?? [])
            if let path = descriptor.path, !path.isEmpty {
                identities.insert(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            }
            return SessionUsageProjector.Child(
                id: descriptor.threadID,
                identities: identities,
                observedProcessedTokens: agent.progress?.totalTokens.map(Int64.init)
            )
        }
        let input = SessionUsageProjector.Input(
            sessionID: sessionID,
            runtimeID: session.kind.rawValue,
            mainIdentities: [session.externalIdentifier, session.threadingIdentifier],
            children: children
        )
        let report = usageService.report
        let reportGeneration = reportGeneration
        let projectionWorker = projectionWorker
        let generation = (generations[sessionID] ?? 0) + 1
        generations[sessionID] = generation

        queue.async { [weak self] in
            let snapshot = projectionWorker.project(
                report: report,
                reportGeneration: reportGeneration,
                input: input
            )
            Task { @MainActor [weak self] in
                guard let self, self.generations[sessionID] == generation else { return }
                guard self.snapshots[sessionID] != snapshot else { return }
                self.snapshots[sessionID] = snapshot
                NotificationCenter.default.post(SessionUsageDidChange(sessionID: sessionID))
            }
        }
    }
}
