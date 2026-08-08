import Foundation

// MARK: - Exact file signals

/// The file-level facts an agent exposes without Threading guessing at shell behaviour.
enum AgentFileActivityKind: String, Codable, Equatable, Sendable {
    case read
    case edit
}

struct AgentFileActivitySignal: Equatable, Sendable {
    let kind: AgentFileActivityKind
    let path: String
}

enum AgentFileActivityClassifier {
    /// Classifies only structured, per-file tool input. Directory searches and shell commands
    /// stay in the work ribbon but do not light a file whose identity is not known exactly.
    static func signals(tool: ToolIdentity, input: [String: Any]) -> [AgentFileActivitySignal] {
        let kind: AgentFileActivityKind
        switch tool {
        case .read, .notebookRead:
            kind = .read
        case .edit, .multiEdit, .write, .notebookEdit:
            kind = .edit
        default:
            return []
        }

        if kind == .edit, let patch = input["patch"] as? String {
            let paths = CodexPatch.paths(in: patch)
            if !paths.isEmpty {
                return paths.map { AgentFileActivitySignal(kind: kind, path: $0) }
            }
        }

        for key in ["file_path", "notebook_path"] {
            if let path = input[key] as? String, !path.isEmpty {
                return [AgentFileActivitySignal(kind: kind, path: path)]
            }
        }
        return []
    }

    static func signals(
        tool: ToolIdentity,
        input: [String: JSONValue]
    ) -> [AgentFileActivitySignal] {
        signals(tool: tool, input: input.mapValues(\.foundationValue))
    }
}

// MARK: - Sparse observed work

/// A bounded chronological fact used by the non-file activity ribbon.
struct AgentWorkAction: Codable, Equatable, Sendable {
    let category: ExecutionAuditRecord.Category
    let operation: String
    let timestamp: Date
    let sessionID: SessionID?
}

struct AgentFileWork: Codable, Equatable, Sendable {
    var readCount = 0
    var editCount = 0
    var lastRead: Date?
    var lastEdit: Date?

    var isTouched: Bool { readCount > 0 || editCount > 0 }

    mutating func record(_ kind: AgentFileActivityKind, at date: Date) {
        switch kind {
        case .read:
            readCount += 1
            lastRead = max(lastRead ?? date, date)
        case .edit:
            editCount += 1
            lastEdit = max(lastEdit ?? date, date)
        }
    }

    mutating func merge(_ other: AgentFileWork) {
        readCount += other.readCount
        editCount += other.editCount
        if let date = other.lastRead { lastRead = max(lastRead ?? date, date) }
        if let date = other.lastEdit { lastEdit = max(lastEdit ?? date, date) }
    }
}

/// Everything retained for one conversation. File state is sparse: a 100,000-file repository
/// with twelve touched files stores twelve entries, not a second copy of the repository.
struct AgentSessionWorkTrace: Codable, Equatable, Sendable {
    enum Limits {
        static let recentActions = 96
    }

    var sessionTitle = ""
    var agentLabel = ""
    var files: [String: AgentFileWork] = [:]
    var categoryCounts: [ExecutionAuditRecord.Category: Int] = [:]
    var recentActions: [AgentWorkAction] = []
    var lastActivity: Date?

    var touchedFileCount: Int { files.count }
    var totalActionCount: Int { categoryCounts.values.reduce(0, +) }

    @discardableResult
    mutating func recordFile(
        _ kind: AgentFileActivityKind,
        path suppliedPath: String,
        root: String?,
        at date: Date
    ) -> String? {
        guard let path = AgentWorkPath.relative(suppliedPath, root: root) else { return nil }
        files[path, default: AgentFileWork()].record(kind, at: date)
        lastActivity = max(lastActivity ?? date, date)
        return path
    }

    mutating func recordAction(
        category: ExecutionAuditRecord.Category,
        operation: String,
        at date: Date,
        sessionID: SessionID? = nil
    ) {
        categoryCounts[category, default: 0] += 1
        recentActions.append(AgentWorkAction(
            category: category,
            operation: operation,
            timestamp: date,
            sessionID: sessionID
        ))
        if recentActions.count > Limits.recentActions {
            recentActions.removeFirst(recentActions.count - Limits.recentActions)
        }
        lastActivity = max(lastActivity ?? date, date)
    }

    mutating func merge(_ other: AgentSessionWorkTrace) {
        if sessionTitle.isEmpty { sessionTitle = other.sessionTitle }
        if agentLabel.isEmpty { agentLabel = other.agentLabel }
        for (path, work) in other.files { files[path, default: AgentFileWork()].merge(work) }
        for (category, count) in other.categoryCounts {
            categoryCounts[category, default: 0] += count
        }
        recentActions = Array(
            (recentActions + other.recentActions)
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(Limits.recentActions)
        )
        if let date = other.lastActivity { lastActivity = max(lastActivity ?? date, date) }
    }
}

enum AgentWorkPath {
    static func relative(_ suppliedPath: String, root suppliedRoot: String?) -> String? {
        let path = cleaned(suppliedPath)
        guard !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return path }
        guard let root = normalizedRoot(suppliedRoot), path.hasPrefix(root + "/") else {
            return nil
        }
        return String(path.dropFirst(root.count + 1))
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func normalizedRoot(_ suppliedRoot: String?) -> String? {
        guard var root = suppliedRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, root != "/" else { return nil }
        while root.hasSuffix("/") { root.removeLast() }
        return root.isEmpty ? nil : root
    }

    private static func cleaned(_ suppliedPath: String) -> String {
        var path = suppliedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path
    }
}

// MARK: - Project aggregate

struct AgentProjectFileWork: Equatable, Sendable {
    var work = AgentFileWork()
    var contributors: Set<SessionID> = []
}

/// The live project view's incrementally maintained aggregate. It is rebuilt off-main from the
/// persisted session traces once, then each event changes only the named path and session.
struct AgentProjectWorkAggregate: Equatable, Sendable {
    var files: [String: AgentProjectFileWork] = [:]
    var categoryCounts: [ExecutionAuditRecord.Category: Int] = [:]
    var recentActions: [AgentWorkAction] = []
    var contributingSessionIDs: Set<SessionID> = []

    init(traces: [SessionID: AgentSessionWorkTrace] = [:]) {
        for (sessionID, trace) in traces {
            merge(trace, sessionID: sessionID)
        }
    }

    mutating func merge(_ trace: AgentSessionWorkTrace, sessionID: SessionID) {
        if !trace.files.isEmpty || !trace.categoryCounts.isEmpty {
            contributingSessionIDs.insert(sessionID)
        }
        for (path, work) in trace.files {
            files[path, default: AgentProjectFileWork()].work.merge(work)
            files[path, default: AgentProjectFileWork()].contributors.insert(sessionID)
        }
        for (category, count) in trace.categoryCounts {
            categoryCounts[category, default: 0] += count
        }
        recentActions = Array(
            (recentActions + trace.recentActions)
                .sorted { $0.timestamp < $1.timestamp }
                .suffix(AgentSessionWorkTrace.Limits.recentActions)
        )
    }

    /// Removes one session without rebuilding every file in the project. File repair visits only
    /// its paths and their contributors; the ribbon re-merges each session's bounded 96 actions.
    mutating func remove(
        _ trace: AgentSessionWorkTrace,
        sessionID: SessionID,
        remainingTraces: [SessionID: AgentSessionWorkTrace]
    ) {
        contributingSessionIDs.remove(sessionID)

        for (path, removedWork) in trace.files {
            guard var file = files[path] else { continue }
            file.contributors.remove(sessionID)
            guard !file.contributors.isEmpty else {
                files.removeValue(forKey: path)
                continue
            }

            file.work.readCount = max(0, file.work.readCount - removedWork.readCount)
            file.work.editCount = max(0, file.work.editCount - removedWork.editCount)
            if file.work.lastRead == removedWork.lastRead {
                file.work.lastRead = file.contributors.compactMap {
                    remainingTraces[$0]?.files[path]?.lastRead
                }.max()
            }
            if file.work.lastEdit == removedWork.lastEdit {
                file.work.lastEdit = file.contributors.compactMap {
                    remainingTraces[$0]?.files[path]?.lastEdit
                }.max()
            }
            files[path] = file
        }

        for (category, count) in trace.categoryCounts {
            let remaining = max(0, categoryCounts[category, default: 0] - count)
            if remaining == 0 {
                categoryCounts.removeValue(forKey: category)
            } else {
                categoryCounts[category] = remaining
            }
        }
        recentActions = []
        for remaining in remainingTraces.values where !remaining.recentActions.isEmpty {
            recentActions = Array(
                (recentActions + remaining.recentActions)
                    .sorted { $0.timestamp < $1.timestamp }
                    .suffix(AgentSessionWorkTrace.Limits.recentActions)
            )
        }
    }

    mutating func recordFile(
        _ kind: AgentFileActivityKind,
        path: String,
        sessionID: SessionID,
        at date: Date
    ) {
        files[path, default: AgentProjectFileWork()].work.record(kind, at: date)
        files[path, default: AgentProjectFileWork()].contributors.insert(sessionID)
        contributingSessionIDs.insert(sessionID)
    }

    mutating func recordAction(
        category: ExecutionAuditRecord.Category,
        operation: String,
        sessionID: SessionID,
        at date: Date
    ) {
        categoryCounts[category, default: 0] += 1
        recentActions.append(AgentWorkAction(
            category: category,
            operation: operation,
            timestamp: date,
            sessionID: sessionID
        ))
        if recentActions.count > AgentSessionWorkTrace.Limits.recentActions {
            recentActions.removeFirst(
                recentActions.count - AgentSessionWorkTrace.Limits.recentActions
            )
        }
        contributingSessionIDs.insert(sessionID)
    }
}

struct AgentProjectWorkFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var sessions: [SessionID: AgentSessionWorkTrace] = [:]
}

// MARK: - Shared repository atlas

/// Immutable topology shared by every session in a checkout. Standard projections are built
/// once with device-bounded bin counts; no drawing or row-configure path iterates `paths`.
struct RepositoryFileAtlas: Sendable {
    enum Limits {
        static let railBins = 192
        static let detailBins = 512
    }

    struct Seed: Equatable, Sendable {
        let firstPath: String
        let lastPath: String
        let directory: String
        let fileCount: Int
        let runOrdinal: Int
        let isOverflow: Bool
    }

    struct Topology: Equatable, Sendable {
        let seeds: [Seed]
        let repositoryFileCount: Int
        let ordinaryBinCount: Int
        let hasOverflowBin: Bool

        func binIndex(for path: String, rank: Int?) -> Int? {
            if let rank, repositoryFileCount > 0, ordinaryBinCount > 0 {
                return min(
                    ordinaryBinCount - 1,
                    rank * ordinaryBinCount / repositoryFileCount
                )
            }
            return hasOverflowBin ? seeds.indices.last : nil
        }
    }

    let paths: [String]
    let indexByPath: [String: Int]
    let rail: Topology
    let detail: Topology

    init(files: [String]) {
        var seen = Set<String>()
        let paths = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
        self.paths = paths
        self.indexByPath = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
        rail = Self.makeTopology(paths: paths, maximumBins: Limits.railBins)
        detail = Self.makeTopology(paths: paths, maximumBins: Limits.detailBins)
    }

    func topology(detail requestedDetail: Bool) -> Topology {
        requestedDetail ? detail : rail
    }

    func binIndex(for path: String, detail requestedDetail: Bool) -> Int? {
        topology(detail: requestedDetail).binIndex(for: path, rank: indexByPath[path])
    }

    private static func makeTopology(paths: [String], maximumBins: Int) -> Topology {
        guard maximumBins > 0 else {
            return Topology(
                seeds: [], repositoryFileCount: paths.count,
                ordinaryBinCount: 0, hasOverflowBin: false
            )
        }

        // A permanent final bin is the stable landing place for files created after the atlas.
        // It remains present (and quiet) before the first such touch, so the axis never shifts.
        let hasOverflow = true
        let ordinaryCount = min(paths.count, max(0, maximumBins - 1))
        var seeds: [Seed] = []
        seeds.reserveCapacity(ordinaryCount + 1)

        // Calculated once in a linear pass. Asking for the run ordinal separately per bin
        // makes atlas construction O(files × bins), which is visible at monorepo scale.
        var runOrdinals = Array(repeating: 0, count: paths.count)
        if paths.count > 1 {
            var ordinal = 0
            var previous = AgentWorkPath.parent(of: paths[0])
            for index in 1..<paths.count {
                let parent = AgentWorkPath.parent(of: paths[index])
                if parent != previous {
                    ordinal += 1
                    previous = parent
                }
                runOrdinals[index] = ordinal
            }
        }

        if ordinaryCount > 0 {
            for bin in 0..<ordinaryCount {
                let lower = bin * paths.count / ordinaryCount
                let upper = ((bin + 1) * paths.count / ordinaryCount) - 1
                let first = paths[lower]
                let last = paths[max(lower, upper)]
                seeds.append(Seed(
                    firstPath: first,
                    lastPath: last,
                    directory: commonDirectory(first, last),
                    fileCount: max(1, upper - lower + 1),
                    runOrdinal: runOrdinals[lower],
                    isOverflow: false
                ))
            }
        }

        seeds.append(Seed(
            firstPath: "",
            lastPath: "",
            directory: "",
            fileCount: 0,
            runOrdinal: ordinaryCount,
            isOverflow: true
        ))
        return Topology(
            seeds: seeds,
            repositoryFileCount: paths.count,
            ordinaryBinCount: ordinaryCount,
            hasOverflowBin: hasOverflow
        )
    }

    private static func commonDirectory(_ first: String, _ last: String) -> String {
        let a = AgentWorkPath.parent(of: first).split(separator: "/")
        let b = AgentWorkPath.parent(of: last).split(separator: "/")
        let shared = zip(a, b).prefix { $0 == $1 }.map { String($0.0) }
        return shared.joined(separator: "/")
    }

}

// MARK: - Bounded presentation

struct AgentWorkProjectionBin: Equatable, Sendable {
    let seed: RepositoryFileAtlas.Seed
    var touchedFileCount = 0
    var readCount = 0
    var editCount = 0
    var lastRead: Date?
    var lastEdit: Date?
    var contributorCount = 0

    mutating func record(_ work: AgentFileWork, contributors: Int) {
        if work.isTouched { touchedFileCount += 1 }
        readCount += work.readCount
        editCount += work.editCount
        if let date = work.lastRead { lastRead = max(lastRead ?? date, date) }
        if let date = work.lastEdit { lastEdit = max(lastEdit ?? date, date) }
        contributorCount = max(contributorCount, contributors)
    }

    mutating func record(_ kind: AgentFileActivityKind, at date: Date, isFirstTouch: Bool) {
        if isFirstTouch { touchedFileCount += 1 }
        switch kind {
        case .read:
            readCount += 1
            lastRead = max(lastRead ?? date, date)
        case .edit:
            editCount += 1
            lastEdit = max(lastEdit ?? date, date)
        }
    }
}

struct AgentWorkContributor: Equatable, Sendable {
    let sessionID: SessionID
    var sessionTitle: String
    var agentLabel: String
    var touchedFileCount: Int
    var actionCount: Int
    var lastActivity: Date?
}

/// The only model a view draws. Both arrays are hard-bounded independently of repository size.
struct AgentWorkPresentation: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case session(SessionID)
        case project(ProjectID)
    }

    let scope: Scope
    let isDetailed: Bool
    var bins: [AgentWorkProjectionBin]
    var repositoryFileCount: Int
    var touchedFileCount: Int
    var categoryCounts: [ExecutionAuditRecord.Category: Int]
    var recentActions: [AgentWorkAction]
    var recentContributors: [AgentWorkContributor]

    var totalActionCount: Int { categoryCounts.values.reduce(0, +) }

    static func session(
        _ trace: AgentSessionWorkTrace,
        sessionID: SessionID,
        atlas: RepositoryFileAtlas,
        detailed: Bool
    ) -> AgentWorkPresentation {
        let topology = atlas.topology(detail: detailed)
        var bins = topology.seeds.map { AgentWorkProjectionBin(seed: $0) }
        for (path, work) in trace.files {
            guard let index = atlas.binIndex(for: path, detail: detailed) else { continue }
            bins[index].record(work, contributors: 1)
        }
        return AgentWorkPresentation(
            scope: .session(sessionID), isDetailed: detailed, bins: bins,
            repositoryFileCount: topology.repositoryFileCount,
            touchedFileCount: trace.touchedFileCount,
            categoryCounts: trace.categoryCounts,
            recentActions: trace.recentActions,
            recentContributors: []
        )
    }

    static func project(
        _ aggregate: AgentProjectWorkAggregate,
        traces: [SessionID: AgentSessionWorkTrace],
        projectID: ProjectID,
        atlas: RepositoryFileAtlas,
        detailed: Bool
    ) -> AgentWorkPresentation {
        let topology = atlas.topology(detail: detailed)
        var bins = topology.seeds.map { AgentWorkProjectionBin(seed: $0) }
        for (path, value) in aggregate.files {
            guard let index = atlas.binIndex(for: path, detail: detailed) else { continue }
            bins[index].record(value.work, contributors: value.contributors.count)
        }
        let contributors = traces.map { sessionID, trace in
            AgentWorkContributor(
                sessionID: sessionID,
                sessionTitle: trace.sessionTitle,
                agentLabel: trace.agentLabel,
                touchedFileCount: trace.touchedFileCount,
                actionCount: trace.totalActionCount,
                lastActivity: trace.lastActivity
            )
        }
        .filter { $0.touchedFileCount > 0 || $0.actionCount > 0 }
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }

        return AgentWorkPresentation(
            scope: .project(projectID), isDetailed: detailed, bins: bins,
            repositoryFileCount: topology.repositoryFileCount,
            touchedFileCount: aggregate.files.count,
            categoryCounts: aggregate.categoryCounts,
            recentActions: aggregate.recentActions,
            recentContributors: Array(contributors.prefix(8))
        )
    }
}
