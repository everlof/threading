import AppKit
import Foundation

// Link the exact native source and row resolver against the shim, with only the store's
// bounded value shape supplied here. Expansion and viewport mounting are real NSOutlineView.
struct ProjectSnapshot {
    struct SavedRuntime { let id: String }
    let id: String
    let recentAgents: [SavedRuntime]
    let recentTerminals: [SavedRuntime]
}

enum SidebarDefaults {
    static let rowHeight: CGFloat = 28
    static let projectCompactRowHeight: CGFloat = 30
}

@main
@MainActor
enum Fixture {
    static func main() {
        let projects = (0..<5_100).map { index in
            let hasChildren = index == 2_500 || index == 3_000
            return ProjectSnapshot(id: "p\(index)",
                recentAgents: hasChildren ? (0..<600).map { .init(id: "p\(index)-a\($0)") } : [],
                recentTerminals: hasChildren ? (0..<600).map { .init(id: "p\(index)-t\($0)") } : [])
        }
        let source = NavigatorOutlineSource()
        source.projects = projects
        source.projectIndexes = Dictionary(uniqueKeysWithValues:
            projects.enumerated().map { ($0.element.id, $0.offset) })
        let outline = NSOutlineView(frame: .zero)
        outline.dataSource = source
        outline.delegate = source
        let identifier = NSUserInterfaceItemIdentifier("project-runtime")
        var createdViews = 0
        source.makeRow = { outline, _ in
            if let retained = outline.makeView(withIdentifier: identifier, owner: source) { return retained }
            createdViews += 1
            let view = NSView(frame: .zero)
            view.identifier = identifier
            return view
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        scroll.documentView = outline
        outline.reloadData()
        var rows = SidebarVisibleRows(outline: outline, projects: projects,
                                       projectIndexes: source.projectIndexes)
        precondition(rows.totalCount == 5_100)
        precondition(rows.row(at: -1) == nil && rows.row(at: 5_100) == nil)

        let alpha = NavigatorOutlineItem(projectID: "p2500", projectIndex: 2_500)
        let beta = NavigatorOutlineItem(projectID: "p3000", projectIndex: 3_000)
        let empty = NavigatorOutlineItem(projectID: "p0", projectIndex: 0)
        precondition(outline.isExpandable(empty), "empty project lost its disclosure affordance")
        outline.expandItem(empty)
        precondition(outline.isItemExpanded(empty) && rows.totalCount == 5_100)
        outline.expandItem(alpha)
        outline.expandItem(beta)
        precondition(outline.isItemExpanded(alpha) && outline.isItemExpanded(beta))
        precondition(rows.totalCount == 5_100 + 2_048)
        precondition(rows.row(at: 2_501) == .agent(projectIndex: 2_500, childIndex: 0, id: "p2500-a0"))
        precondition(rows.row(at: 2_501 + 512) == .terminal(projectIndex: 2_500, childIndex: 0, id: "p2500-t0"))
        precondition(rows.index(of: 3_000) == 3_000 + 1_024)
        precondition(rows.row(at: 3_001 + 1_024) == .agent(projectIndex: 3_000, childIndex: 0, id: "p3000-a0"))
        let selected = NavigatorOutlineItem(kind: .terminal, projectID: "p3000", id: "p3000-t12",
                                            projectIndex: 3_000, childIndex: 12)
        precondition(rows.index(of: selected) == 3_001 + 1_024 + 512 + 12)
        outline.scrollRowToVisible(rows.index(of: selected)!)
        precondition((1...19).contains(outline.mountedViewCount) && createdViews <= 38,
                     "expanded children materialized outside the viewport")
        precondition(outline.visibleRowIndexes.contains(rows.index(of: selected)!),
                     "selected child did not enter the actual viewport")
        print("MULTI_PROJECT_VIEWPORT mounted=\(outline.mountedViewCount) created=\(createdViews)")
        outline.collapseItem(alpha)
        precondition(rows.totalCount == 6_124 && outline.isItemExpanded(beta))
        precondition(rows.index(of: selected) == 3_001 + 512 + 12)

        var reordered = projects
        reordered.swapAt(2_500, 3_000)
        reordered[2_500] = ProjectSnapshot(id: "p3000",
            recentAgents: reordered[2_500].recentAgents,
            recentTerminals: [.init(id: "inserted")] + reordered[2_500].recentTerminals)
        source.projects = reordered
        source.projectIndexes = Dictionary(uniqueKeysWithValues:
            reordered.enumerated().map { ($0.element.id, $0.offset) })
        outline.reloadData()
        rows = SidebarVisibleRows(outline: outline, projects: reordered,
                                  projectIndexes: source.projectIndexes)
        precondition(rows.index(of: selected) == 2_501 + 512 + 13,
                     "selection followed a stale project/child position")
        precondition(rows.row(at: rows.index(of: selected)!) ==
            .terminal(projectIndex: 2_500, childIndex: 13, id: "p3000-t12"))
        precondition(outline.isItemExpanded(beta) && !outline.isItemExpanded(alpha))
        outline.collapseItem(beta)
        precondition(rows.totalCount == 5_100 && rows.index(of: selected) == nil)
        precondition(rows.navigate(.left, from: beta) == beta)
        precondition(rows.navigate(.right, from: beta) == beta && outline.isItemExpanded(beta))
        precondition(rows.navigate(.right, from: beta) == beta, "Right on an open project moved selection")
        let child = outline.item(atRow: rows.index(of: beta)! + 1) as! NavigatorOutlineItem
        precondition(child.kind == .agent && child.projectID == beta.projectID)
        precondition(rows.navigate(.right, from: child) == child, "Right on a leaf changed selection")
        precondition(rows.navigate(.left, from: child) == beta, "Left did not reach the actual parent")
        precondition(rows.navigate(.left, from: beta) == beta && !outline.isItemExpanded(beta))
        precondition(rows.navigate(.left, from: empty) == empty && !outline.isItemExpanded(empty))
        precondition(rows.navigate(.right, from: empty) == empty && outline.isItemExpanded(empty))
        precondition(rows.navigate(.right, from: empty) == empty, "Right on an empty project entered its sibling")
        print("PASS outline Left/Right: expand, open-project no-op, parent, collapse, empty and leaf boundaries")
        print("PASS native outline row resolver: 5,100 projects, 2,048 bounded children, independent/empty expansion, stable selection after reorder, viewport-only views")
    }
}
