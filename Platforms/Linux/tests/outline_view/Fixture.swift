import AppKit
import Foundation

@MainActor
private final class Node {
    let id: Int
    let children: [Node]

    init(id: Int, children: [Node] = []) {
        self.id = id
        self.children = children
    }
}

@MainActor
private final class RowView: NSView {
    var representedID = -1
}

@MainActor
private final class ChromeRowView: NSTableRowView {
    var representedID = -1
    private(set) var backgroundDraws = 0
    private(set) var selectionDraws = 0

    override func drawBackground(in dirtyRect: NSRect) { backgroundDraws += 1 }
    override func drawSelection(in dirtyRect: NSRect) { selectionDraws += 1 }
}

@MainActor
private final class TreeSource: NSOutlineViewDataSource, NSOutlineViewDelegate {
    let roots: [Node]
    private(set) var constructedViews = 0
    private(set) var configuredViews = 0
    private(set) var constructedChromeRows = 0
    private(set) var selectionChanges = 0
    private let identifier = NSUserInterfaceItemIdentifier("StressOutlineRow")
    private let chromeIdentifier = NSUserInterfaceItemIdentifier("StressOutlineChrome")

    init() {
        let children = (0..<1_024).map { Node(id: 10_000 + $0) }
        roots = (0..<5_100).map { Node(id: $0, children: $0 == 2_500 ? children : []) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? Node { return node.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as! Node).children.isEmpty)
    }

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let view: RowView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? RowView {
            view = recycled
        } else {
            constructedViews += 1
            view = RowView(frame: .zero)
            view.identifier = identifier
        }
        view.representedID = (item as! Node).id
        configuredViews += 1
        return view
    }

    func outlineView(_ outlineView: NSOutlineView,
                     rowViewForItem item: Any) -> NSTableRowView? {
        let row: ChromeRowView
        if let recycled = outlineView.makeView(withIdentifier: chromeIdentifier,
                                               owner: self) as? ChromeRowView {
            row = recycled
        } else {
            constructedChromeRows += 1
            row = ChromeRowView(frame: .zero)
            row.identifier = chromeIdentifier
        }
        row.representedID = (item as! Node).id
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionChanges += 1
    }
}

@MainActor
private func assertViewportBound(_ outline: NSOutlineView, _ scroll: NSScrollView,
                                 context: String) {
    let ceiling = Int(ceil(scroll.contentView.bounds.height / outline.rowHeight)) + 1
    precondition(outline.mountedViewCount <= ceiling,
                 "\(context): mounted \(outline.mountedViewCount) > \(ceiling)")
    precondition(outline.reusableViewCount <= max(8, ceiling + 2),
                 "\(context): unbounded reuse pool")
    precondition(outline.reusableRowViewCount <= ceiling + 2,
                 "\(context): unbounded default chrome reuse pool")
    precondition(outline.subviews.count == outline.mountedViewCount,
                 "\(context): table retained hidden row subviews")
    for row in outline.visibleRowIndexes {
        let item = outline.item(atRow: row) as! Node
        let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! RowView
        let chrome = outline.rowView(atRow: row, makeIfNecessary: true) as! ChromeRowView
        precondition(view.representedID == item.id, "\(context): recycled row has stale content")
        precondition(chrome.representedID == item.id, "\(context): recycled chrome has stale identity")
        precondition(chrome.frame == outline.rect(ofRow: row), "\(context): stale row geometry")
        precondition(view.frame == NSRect(origin: .zero, size: chrome.bounds.size),
                     "\(context): cell escaped row-local geometry")
        precondition(view.superview === chrome, "\(context): row chrome does not own cell")
        precondition(chrome.isSelected == (outline.selectedRow == row),
                     "\(context): row chrome selection is stale")
        if let root = scroll.superview {
            let viewport = scroll.convert(scroll.bounds, to: root)
            let converted = view.convert(view.bounds, to: root)
            precondition(!converted.intersection(viewport).isEmpty,
                         "\(context): mounted cell missed viewport: cell=\(converted), viewport=\(viewport)")
        }
    }
}

@MainActor
private func run() {
    let source = TreeSource()
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: 248))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
    root.addSubview(scroll)
    let outline = NSOutlineView(frame: .zero)
    outline.rowHeight = 44
    outline.dataSource = source
    outline.delegate = source
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Tree"))
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.reloadData()
    precondition(outline.numberOfRows == 5_100, "collapsed project count")
    precondition(outline.mountedViewCount == 0, "detached outline eagerly built rows")
    scroll.documentView = outline
    assertViewportBound(outline, scroll, context: "first viewport")
    _ = root.layoutSubtreeIfNeeded()
    assertViewportBound(outline, scroll, context: "laid out first viewport")
    let initialChrome = outline.rowView(atRow: 0, makeIfNecessary: false) as! ChromeRowView
    initialChrome.draw(initialChrome.bounds)
    precondition(initialChrome.backgroundDraws == 1 && initialChrome.selectionDraws == 0,
                 "unselected row chrome drew selection")
    precondition(outline.visibleRowIndexes.first == 0, "initial viewport did not start at first row")
    let configurationsBeforeItemReload = source.configuredViews
    outline.reloadItem(source.roots[0])
    precondition(source.configuredViews == configurationsBeforeItemReload + 1,
                 "one-item reload rebuilt more than its changed row")
    let configurationsBeforeReload = source.configuredViews
    outline.reloadData()
    precondition(source.configuredViews == configurationsBeforeReload + outline.visibleRowIndexes.count,
                 "reload did not reconfigure mounted identities")

    let lastRoot = source.roots[5_099]
    outline.selectRowIndexes(IndexSet(integer: 5_099), byExtendingSelection: false)
    precondition(outline.selectedRow == 5_099, "offscreen selection was lost")
    outline.scrollRowToVisible(5_099)
    assertViewportBound(outline, scroll, context: "last viewport")
    let selectedChrome = outline.rowView(atRow: 5_099, makeIfNecessary: false) as! ChromeRowView
    precondition(selectedChrome.isSelected, "selected row chrome did not update")
    let selectionDraws = selectedChrome.selectionDraws
    selectedChrome.draw(selectedChrome.bounds)
    precondition(selectedChrome.selectionDraws == selectionDraws + 1,
                 "selected row chrome did not own selection drawing")
    precondition(outline.visibleRowIndexes.contains(5_099), "scrollRowToVisible missed last row")
    precondition(outline.item(atRow: outline.selectedRow) as? Node === lastRoot,
                 "selection changed identity during scroll")

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 2_500 * outline.rowHeight))
    assertViewportBound(outline, scroll, context: "middle viewport")
    precondition(outline.visibleRowIndexes.first == 2_500, "middle offset was not projected")
    let middleView = outline.view(atColumn: 0, row: 2_502, makeIfNecessary: false)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 2_501 * outline.rowHeight))
    precondition(outline.view(atColumn: 0, row: 2_502, makeIfNecessary: false) === middleView,
                 "overlapping row was reconstructed")

    let expandedRoot = source.roots[2_500]
    outline.selectRowIndexes(IndexSet(integer: 2_500), byExtendingSelection: false)
    outline.expandItem(expandedRoot)
    precondition(outline.numberOfRows == 6_124, "expanded row count")
    precondition(outline.row(forItem: expandedRoot) == 2_500, "root identity moved")
    precondition(outline.selectedRow == 2_500, "root selection lost during expansion")
    precondition(outline.level(forItem: expandedRoot.children[0]) == 1,
                 "child hierarchy level missing")
    precondition(outline.row(forItem: lastRoot) == 6_123,
                 "later stable item did not shift with expansion")
    assertViewportBound(outline, scroll, context: "expanded middle")

    let child = expandedRoot.children[800]
    let childRow = outline.row(forItem: child)
    precondition(childRow == 3_301, "bounded child projection order")
    outline.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
    outline.scrollRowToVisible(childRow)
    assertViewportBound(outline, scroll, context: "child viewport")
    precondition(outline.selectedRow == childRow, "child selection missed")

    scroll.frame.size.height = 132
    assertViewportBound(outline, scroll, context: "resized child viewport")
    precondition(outline.visibleRowIndexes.count <= 4, "resize retained old viewport cells")
    outline.collapseItem(expandedRoot)
    precondition(outline.numberOfRows == 5_100, "collapse retained child rows")
    precondition(outline.selectedRow == -1, "hidden child incorrectly mapped to visible row")
    assertViewportBound(outline, scroll, context: "collapsed viewport")
    outline.expandItem(expandedRoot)
    precondition(outline.selectedRow == childRow, "child identity not restored on expand")
    assertViewportBound(outline, scroll, context: "re-expanded viewport")

    let window = NSWindow()
    window.contentView = root
    let beforeWheel = scroll.contentView.bounds.minY
    window.dispatchToContent(NSEvent(type: .scrollWheel,
                                     locationInWindow: NSPoint(x: 100, y: 60),
                                     scrollingDeltaY: -1))
    precondition(scroll.contentView.bounds.minY > beforeWheel,
                 "wheel did not advance the clip viewport")
    assertViewportBound(outline, scroll, context: "wheel viewport")
    precondition(source.constructedViews <= 12, "view creation followed row count")
    precondition(source.constructedChromeRows <= 12, "chrome creation followed row count")
    precondition(source.selectionChanges == 3, "selection change notification count")
    scroll.documentView = nil
    precondition(outline.mountedViewCount == 0 && outline.subviews.isEmpty,
                 "detached outline retained active viewport cells")
    print("outline viewport fixture passed: 5,100 roots, 1,024 children, "
          + "\(source.constructedViews) cells constructed, "
          + "\(source.configuredViews) visible configurations")
}

@main
struct Fixture {
    @MainActor static func main() { run() }
}
