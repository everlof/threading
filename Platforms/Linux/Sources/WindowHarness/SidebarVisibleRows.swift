import Foundation

/// The rows in the Linux navigator's current viewport.
///
/// The store snapshot has already put projects in display order and bounded each project's
/// recent runtimes. Only the selected project opens, with agents before standalone terminals,
/// matching the default project-child order in `SidebarTreeBuilder`. Planning reads counts; it
/// never creates a child presentation or view for a row outside the requested viewport.
struct SidebarVisibleRows {
    enum Row: Equatable, Sendable {
        case project(projectIndex: Int, id: String)
        case agent(projectIndex: Int, childIndex: Int, id: String)
        case terminal(projectIndex: Int, childIndex: Int, id: String)
    }

    // The Linux store's recent-runtime query uses the same per-kind limit. Keep this bound at
    // the projection too, so a wider input cannot turn one expanded project into an unbounded
    // navigator or make identity recovery scan every runtime.
    static let maximumChildrenPerKind = 512

    private let projects: [ProjectSnapshot]
    private let expandedProjectIndex: Int?
    private let agentCount: Int
    private let terminalCount: Int
    private let first: Int
    private let visibleCount: Int

    let totalCount: Int

    init(projects: [ProjectSnapshot], expandedProjectIndex: Int?, first: Int, count: Int) {
        self.projects = projects
        let expanded = expandedProjectIndex.flatMap { projects.indices.contains($0) ? $0 : nil }
        self.expandedProjectIndex = expanded
        let project = expanded.map { projects[$0] }
        agentCount = min(project?.recentAgents.count ?? 0, Self.maximumChildrenPerKind)
        terminalCount = min(project?.recentTerminals.count ?? 0, Self.maximumChildrenPerKind)
        totalCount = projects.count + agentCount + terminalCount
        self.first = min(max(0, first), totalCount)
        visibleCount = min(max(0, count), totalCount - self.first)
    }

    /// Resolves only the requested viewport. Callers can retain `Row` as a stable selection
    /// identity and use `index(of:)` after a store snapshot changes.
    var rows: [Row] {
        (first..<(first + visibleCount)).compactMap { row(at: $0) }
    }

    func row(at absoluteIndex: Int) -> Row? {
        guard (0..<totalCount).contains(absoluteIndex) else { return nil }
        guard let expandedProjectIndex else {
            return projectRow(at: absoluteIndex)
        }

        let firstChild = expandedProjectIndex + 1
        let firstTerminal = firstChild + agentCount
        let firstFollowingProject = firstTerminal + terminalCount
        if absoluteIndex < firstChild {
            return projectRow(at: absoluteIndex)
        }
        if absoluteIndex < firstTerminal {
            let childIndex = absoluteIndex - firstChild
            return .agent(projectIndex: expandedProjectIndex, childIndex: childIndex,
                          id: projects[expandedProjectIndex].recentAgents[childIndex].id)
        }
        if absoluteIndex < firstFollowingProject {
            let childIndex = absoluteIndex - firstTerminal
            return .terminal(projectIndex: expandedProjectIndex, childIndex: childIndex,
                             id: projects[expandedProjectIndex].recentTerminals[childIndex].id)
        }
        return projectRow(at: absoluteIndex - agentCount - terminalCount)
    }

    func index(of projectIndex: Int) -> Int? {
        guard projects.indices.contains(projectIndex) else { return nil }
        let openedChildrenBeforeProject = expandedProjectIndex.map { projectIndex > $0 } ?? false
        return projectIndex + (openedChildrenBeforeProject ? agentCount + terminalCount : 0)
    }

    /// Recovers a selected row by stable ID after projects or children are reordered.
    func index(of row: Row) -> Int? {
        switch row {
        case let .project(projectIndex, id):
            guard let currentProject = resolvedProjectIndex(matching: id, preferred: projectIndex) else {
                return nil
            }
            return index(of: currentProject)
        case let .agent(_, childIndex, id):
            guard let expandedProjectIndex else { return nil }
            let agents = projects[expandedProjectIndex].recentAgents
            let currentChild = childIndex < agentCount && childIndex >= 0 && agents[childIndex].id == id
                ? childIndex
                : agents.prefix(agentCount).firstIndex { $0.id == id }
            return currentChild.map { expandedProjectIndex + 1 + $0 }
        case let .terminal(_, childIndex, id):
            guard let expandedProjectIndex else { return nil }
            let terminals = projects[expandedProjectIndex].recentTerminals
            let currentChild = childIndex < terminalCount && childIndex >= 0 && terminals[childIndex].id == id
                ? childIndex
                : terminals.prefix(terminalCount).firstIndex { $0.id == id }
            return currentChild.map { expandedProjectIndex + 1 + agentCount + $0 }
        }
    }

    private func projectRow(at projectIndex: Int) -> Row {
        .project(projectIndex: projectIndex, id: projects[projectIndex].id)
    }

    private func projectID(for projectIndex: Int) -> String? {
        projects.indices.contains(projectIndex) ? projects[projectIndex].id : nil
    }

    private func resolvedProjectIndex(matching id: String, preferred index: Int) -> Int? {
        if projectID(for: index) == id { return index }
        return projects.firstIndex { $0.id == id }
    }
}
