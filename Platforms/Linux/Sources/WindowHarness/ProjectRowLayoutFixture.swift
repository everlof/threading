import AppKit

/// The production project content must let the retained pane header relayout when the first
/// terminal turns a full-width navigator into a 320-pixel sidebar.
@MainActor
enum ProjectRowLayoutFixture {
    static func run() {
        let owner = NSWindow(backingScaleFactor: 2)
        let root = Specimen.Window(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        owner.contentView = root
        let title = NSTextField(labelWithString: "Projects")
        let add = ThemedIconButton(symbolName: "plus", accessibility: "Add Project",
                                   target: .inline, inkSource: .chrome)
        let actions = ThemedIconButton(symbolName: "ellipsis", accessibility: "Actions",
                                       target: .inline, inkSource: .chrome)
        let header = PaneHeaderView(leading: [title], trailing: [add, actions], margin: .paneEdge)
        root.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor)
        ])

        let presentation = NavigatorProjectRowPresentation.project(name: "WaylandProject")
        let accent = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        var retainedRow: Specimen.Row?
        var retainedContent: ThemedProjectRowView?
        for width in [CGFloat(400), 160, 400] {
            root.prepareNavigatorFrame(NSRect(x: 0, y: 0, width: width, height: 240))
            root.mountNavigatorRow(frame: NSRect(x: 6, y: 175, width: width - 12, height: 22),
                                   accent: accent, selected: true, ink: Specimen.Ink(on: accent),
                                   showsMark: false)
            root.mountProjectContent(presentation: presentation, icon: nil, count: 3,
                                     projectID: "project", revealed: true, enabled: true)

            let diagnosis = LayoutEngine.layout(root)
            precondition(diagnosis.solved, "project count made the shared navigator layout unsatisfiable")
            precondition(abs(header.frame.width - width) < 0.001,
                         "pane header retained its old width after navigator resize")
            let button = actions.convert(actions.bounds, to: root)
            precondition(abs(button.maxX - (width - 8)) < 0.001,
                         "Actions button no longer fits inside the resized sidebar")
            guard let row = root.mountedRow(at: 0),
                  let content = row.subviews.compactMap({ $0 as? ThemedProjectRowView }).first,
                  let count = content.trailingSlotView.subviews.compactMap({ $0 as? NSTextField }).first
            else { preconditionFailure("production project row or count was not mounted") }
            let naturalTitleWidth = content.titleLabel.intrinsicContentSize.width
            guard let projectCreate = root.projectControl(at: 0, create: true),
                  let projectAction = root.projectControl(at: 0, create: false)
            else { preconditionFailure("production project controls were not mounted") }
            let createBounds = projectCreate.convert(projectCreate.bounds, to: root)
            let actionBounds = projectAction.convert(projectAction.bounds, to: root)
            precondition(actionBounds.minX > createBounds.maxX && actionBounds.maxX <= row.frame.maxX,
                         "project controls escaped or overlapped their production row")
            if width == 400 {
                precondition(content.titleLabel.frame.width + 0.5 >= naturalTitleWidth,
                             "project title was compressed despite available row width")
            } else {
                precondition(content.titleLabel.frame.width < naturalTitleWidth,
                             "narrow sidebar did not constrain a long project title")
            }
            precondition(count.frame.width > 0 && count.frame.maxX <= content.trailingSlotView.bounds.maxX,
                         "count escaped its production trailing slot")
            if let retainedRow { precondition(row === retainedRow, "row slot was rebuilt on resize") }
            if let retainedContent {
                precondition(content === retainedContent, "production content was rebuilt on resize")
            }
            retainedRow = row
            retainedContent = content
        }
        print("PASS production project row and pane header relayout at 800/320/800 pixels")
    }
}
