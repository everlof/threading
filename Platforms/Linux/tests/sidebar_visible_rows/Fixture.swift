import Foundation

// The projection only needs bounded IDs and counts from the store snapshot. Compile the exact
// production projection with this narrow snapshot shape, independent of the window bridge.
struct ProjectSnapshot {
    struct SavedRuntime {
        let id: String
    }
    let id: String
    let recentAgents: [SavedRuntime]
    let recentTerminals: [SavedRuntime]
}

@main
enum Fixture {
    static func main() {
        let projects = (0..<5_100).map { index in
            ProjectSnapshot(id: "p\(index)",
                recentAgents: index == 2_500
                    ? (0..<600).map { .init(id: "a\($0)") } : [],
                recentTerminals: index == 2_500
                    ? (0..<600).map { .init(id: "t\($0)") } : [])
        }

        let collapsed = SidebarVisibleRows(projects: projects, expandedProjectIndex: nil,
                                           first: 2_495, count: 20)
        precondition(collapsed.totalCount == 5_100 && collapsed.rows.count == 20)
        precondition(collapsed.rows[5] == .project(projectIndex: 2_500, id: "p2500"))

        let opened = SidebarVisibleRows(projects: projects, expandedProjectIndex: 2_500,
                                        first: 2_495, count: 20)
        precondition(opened.totalCount == 5_100 + 1_024)
        precondition(opened.rows.count == 20)
        precondition(opened.rows[5] == .project(projectIndex: 2_500, id: "p2500"))
        precondition(opened.rows[6] == .agent(projectIndex: 2_500, childIndex: 0, id: "a0"))
        precondition(opened.row(at: 2_500 + 512) ==
                     .agent(projectIndex: 2_500, childIndex: 511, id: "a511"))
        precondition(opened.row(at: 2_501 + 512) ==
                     .terminal(projectIndex: 2_500, childIndex: 0, id: "t0"))
        precondition(opened.row(at: 2_500 + 1_024) ==
                     .terminal(projectIndex: 2_500, childIndex: 511, id: "t511"))
        precondition(opened.row(at: 2_501 + 1_024) ==
                     .project(projectIndex: 2_501, id: "p2501"))
        precondition(opened.index(of: 2_501) == 2_501 + 1_024)
        precondition(opened.row(at: -1) == nil && opened.row(at: opened.totalCount) == nil)

        let selected: SidebarVisibleRows.Row = .agent(projectIndex: 2_500, childIndex: 12, id: "a12")
        var reordered = projects
        reordered.swapAt(2_500, 2_501)
        reordered[2_501] = ProjectSnapshot(id: "p2500",
            recentAgents: [.init(id: "inserted")] + projects[2_500].recentAgents,
            recentTerminals: projects[2_500].recentTerminals)
        let updated = SidebarVisibleRows(projects: reordered, expandedProjectIndex: 2_501,
                                         first: 0, count: 18)
        precondition(updated.index(of: selected) == 2_501 + 1 + 13)
        precondition(updated.index(of: .project(projectIndex: 2_500, id: "p2500")) == 2_501)
        precondition(updated.index(of: .terminal(projectIndex: 2_500, childIndex: 0, id: "t0")) ==
                     2_501 + 1 + 512)

        let tail = SidebarVisibleRows(projects: projects, expandedProjectIndex: 2_500,
                                      first: Int.max, count: Int.max)
        precondition(tail.rows.isEmpty)
        print("sidebar visible rows: 5,100 projects, 1,024 bounded children, 20 mounted rows")
    }
}
