import AppKit
#if os(Linux)
import LinuxWindowBridge
@testable import CoreSlice
#endif

/// Exercises the production attachment shell against the Linux constraint solver.
@MainActor
enum AttachmentShellFixture {
    private final class TurnSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let sections: [SessionAttachmentTurnSection]
        var items: [SessionAttachmentTurnListItem]
        var collapsed: Set<SessionAttachmentTurnSection.ID> = []
        weak var table: ThemedTableView?

        init(attachment: SessionAttachment) {
            let previous = SessionAttachmentTurnBoundary(
                id: GitTurnCheckpointID(), ordinal: 1, userTurnID: "previous",
                requestedAt: attachment.referencedAt.addingTimeInterval(-10)
            )
            let latest = SessionAttachmentTurnBoundary(
                id: GitTurnCheckpointID(), ordinal: 2, userTurnID: "latest",
                requestedAt: attachment.referencedAt.addingTimeInterval(10)
            )
            sections = SessionAttachmentTurnSectioning.sections(
                attachments: [attachment], boundaries: [previous, latest]
            )
            items = SessionAttachmentTurnSectioning.items(sections: sections, collapsed: [])
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int)
            -> NSView? {
            guard items.indices.contains(row) else { return nil }
            if case .header(let section) = items[row] {
                return SessionAttachmentTurnHeaderView(
                    section: section, isExpanded: !collapsed.contains(section.id)
                ) { [weak self] expanded in
                    self?.set(section.id, expanded: expanded)
                }
            }
            guard let attachment = items[row].attachment else { return nil }
            return SessionAttachmentRowView(attachment: attachment, iconImage: nil)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard items.indices.contains(row) else { return SessionAttachmentListMetrics.rowHeight }
            if case .header = items[row] { return SessionAttachmentListMetrics.turnHeaderHeight }
            return SessionAttachmentListMetrics.rowHeight
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            items.indices.contains(row) && items[row].attachment != nil
        }

        private func set(_ id: SessionAttachmentTurnSection.ID, expanded: Bool) {
            if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            items = SessionAttachmentTurnSectioning.items(
                sections: sections, collapsed: collapsed
            )
            table?.reloadData()
        }
    }

    static func run() {
        let owner = NSWindow(backingScaleFactor: 2)
        let count = NSTextField(labelWithString: "Attachments 2")
        let filter = ThemedSegmentedControl()
        let filters = AttachmentFilter.visibleCases(hasSubagents: false)
        filter.configure(titles: filters.map(\.title))
        filter.setAccessibilityLabel("Show attachments from")
        let header = SessionAttachmentHeaderRow(count: count, filter: filter, spacing: 8)
        let list = SessionAttachmentListView(frame: .zero)
        let fold = PaneFoldDivider()
        let preview = NSView()
        let message = NSView()
        let footer = NSTextField(labelWithString: "Open")
        let scope = NSTextField(labelWithString: "Outside this project")
        let empty = NSView()
        let shell = SessionAttachmentsContentView(
            header: header, list: list, fold: fold, preview: preview,
            previewMessage: message, footer: footer, scopeBand: scope,
            emptyMessage: empty, listHeightPriority: .init(490)
        )
        shell.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
        owner.contentView = shell
        shell.listHeightConstraint.constant = 110

        func checkLayout(scopeVisible: Bool) {
            let result = LayoutEngine.layout(shell)
            precondition(result.solved, "shared attachment shell constraints did not solve")
            precondition(abs(header.frame.maxY - (shell.frame.height - 6)) < 0.001,
                         "header lost its top inset")
            precondition(abs(header.frame.minY - list.frame.maxY - 6) < 0.001,
                         "list lost its header gap")
            precondition(abs(fold.frame.maxY - list.frame.minY) < 0.001,
                         "fold moved away from the list")
            precondition(abs(preview.frame.maxY - fold.frame.minY) < 0.001,
                         "preview moved away from the fold")
            if scopeVisible {
                precondition(abs(footer.frame.minY - scope.frame.maxY) < 0.001,
                             "footer did not rise above scope band")
                precondition(abs(scope.frame.minY) < 0.001,
                             "scope band left the pane floor")
            } else {
                precondition(abs(footer.frame.minY) < 0.001,
                             "footer left the pane floor")
            }
        }

        checkLayout(scopeVisible: false)
        var foldTravel: [CGFloat] = []
        var foldResets = 0
        fold.onDrag = { foldTravel.append($0) }
        fold.onReset = { foldResets += 1 }
        precondition(fold.accessibilityRole() == .splitter
                     && fold.accessibilityOrientation() == .horizontal,
                     "shared fold lost its splitter semantics")
        precondition(fold.accessibilityPerformIncrement()
                     && fold.accessibilityPerformDecrement(),
                     "shared fold lost accessible height adjustment")
        let foldPoint = NSPoint(x: fold.frame.midX, y: fold.frame.midY)
        fold.mouseDown(with: NSEvent(type: .leftMouseDown, locationInWindow: foldPoint))
        fold.mouseDragged(with: NSEvent(type: .leftMouseDragged,
                                       locationInWindow: foldPoint, deltaY: 14))
        fold.mouseUp(with: NSEvent(type: .leftMouseUp, locationInWindow: foldPoint))
        fold.keyDown(with: NSEvent(type: .keyDown, keyCode: 126,
                                  charactersIgnoringModifiers: ""))
        fold.mouseDown(with: NSEvent(type: .leftMouseDown, locationInWindow: foldPoint,
                                    clickCount: 2))
        precondition(foldTravel == [PaneFoldDivider.Layout.coarseStep,
                                    -PaneFoldDivider.Layout.coarseStep, 14,
                                    -PaneFoldDivider.Layout.coarseStep]
                     && foldResets == 1,
                     "shared fold drag, keyboard or reset did not route")
        shell.setScopeBandVisible(true)
        checkLayout(scopeVisible: true)
        shell.setScopeBandVisible(false)
        checkLayout(scopeVisible: false)
        header.setFilterHidden(true)
        checkLayout(scopeVisible: false)
        precondition(filter.isHidden && header.intrinsicContentSize.height == count.intrinsicContentSize.height,
                     "shared header did not collapse to the count")
        header.setFilterHidden(false)
        checkLayout(scopeVisible: false)
        precondition(!filter.isHidden, "shared header did not restore the filter")

        let project = URL(fileURLWithPath: "/tmp/attachment-shell-fixture", isDirectory: true)
        let file = project.appendingPathComponent("diagram.png")
        let attachment = SessionAttachment(
            sessionID: SessionID(), root: project, url: file,
            relativePath: "diagram.png", sourcePath: file.path,
            kind: .image, origin: .agent,
            turnID: "previous",
            referencedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        precondition(filters == [.all, .agent, .user]
                     && filters[1].admits(attachment) && !filters[2].admits(attachment),
                     "shared attachment filter lost its fixed provider choices")
        precondition(filter.accessibilityRole() == .radioGroup,
                     "shared attachment filter lost its grouped accessibility role")
        let agentSegment = filter.segment(at: 1) as? ThemedControl
        precondition(agentSegment?.accessibilityPerformPress() == true
                     && filter.selectedIndex == 1,
                     "shared attachment filter did not route segment selection")
        agentSegment?.keyDown(with: NSEvent(type: .keyDown,
            charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        precondition(filter.selectedIndex == 0,
                     "shared attachment filter did not route arrow navigation")
        let source = TurnSource(attachment: attachment)
        source.table = list.tableView
        list.tableView.dataSource = source
        list.tableView.delegate = source
        list.tableView.reloadData()
        precondition(list.tableView.numberOfRows == 3,
                     "shared list did not mount an empty latest turn and previous file")
        precondition(!source.tableView(list.tableView, shouldSelectRow: 0),
                     "a turn header became selectable")
        precondition(source.tableView(list.tableView, shouldSelectRow: 2),
                     "the attachment row lost selection")
        let previousHeader = list.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
            as? SessionAttachmentTurnHeaderView
        precondition(previousHeader?.disclosure.performPrimaryAction() == true
                     && list.tableView.numberOfRows == 2,
                     "shared list constructed a collapsed file row")
        let collapsedHeader = list.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true)
            as? SessionAttachmentTurnHeaderView
        precondition(collapsedHeader?.disclosure.performPrimaryAction() == true
                     && list.tableView.numberOfRows == 3,
                     "shared list did not restore the expanded file row")
        precondition(list.tableView.rowView(atRow: 2, makeIfNecessary: true) is ThemedTableRowView,
                     "shared list did not use the themed selection row")
        let row = SessionAttachmentRowView(attachment: attachment, iconImage: nil)
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 42)
        let rowWindow = NSWindow(backingScaleFactor: 2)
        rowWindow.contentView = row
        precondition(LayoutEngine.layout(row).solved, "shared attachment row constraints did not solve")
        precondition(row.accessibilityLabel()?.contains("diagram.png") == true,
                     "shared row lost its file accessibility sentence")
        let detail = row.subviews.compactMap { $0 as? NSTextField }
            .first { $0.toolTip == "diagram.png" }
        precondition(detail != nil && detail?.isHidden == false,
                     "shared row did not show the relative path")
        row.isDropTarget = true
        precondition(detail?.isHidden == true,
                     "shared row did not replace the path under a comparison drop")
        row.isDropTarget = false
        precondition(detail?.isHidden == false,
                     "shared row did not restore the relative path")
        precondition(SessionAttachmentRowMetrics.height(for: 200) == 72
                     && SessionAttachmentRowMetrics.height(for: 420) == 42,
                     "shared row width classes drifted")
        row.setCompact(true)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 72)
        precondition(LayoutEngine.layout(row).solved, "compact attachment row constraints did not solve")
        let rowLabels = row.subviews.compactMap { $0 as? NSTextField }
        precondition(rowLabels.count >= 4
                     && rowLabels[0].frame.minY > rowLabels[1].frame.minY
                     && rowLabels[1].frame.minY > rowLabels[3].frame.minY,
                     "compact attachment metadata did not move below the file lines")

        let section = SessionAttachmentTurnSection(
            id: .checkpoint(GitTurnCheckpointID()), ordinal: 2,
            distanceFromLatest: 0, isLatest: true, attachments: [attachment]
        )
        var expanded = true
        let turnHeader = SessionAttachmentTurnHeaderView(section: section, isExpanded: true) {
            expanded = $0
        }
        turnHeader.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        let headerWindow = NSWindow(backingScaleFactor: 2)
        headerWindow.contentView = turnHeader
        precondition(LayoutEngine.layout(turnHeader).solved,
                     "shared turn header constraints did not solve")
        precondition(turnHeader.disclosure.accessibilityLabel()?.contains("Latest turn") == true,
                     "shared turn header lost its chronological label")
        precondition(turnHeader.disclosure.performPrimaryAction() && !expanded,
                     "shared turn header did not route its disclosure")
        print("PASS shared attachment shell/list/header/row/fold/turn disclosure and scope-band relayout")
    }

    /// Renders the unchanged shell in the third native workspace region. The two other solid
    /// regions make clipping and the terminal/display boundary visible in an installed capture.
    static func runNativeSplit() throws {
        let sidebarWidth = 240
        let terminalWidth = 530
        let displayWidth = 350
        let height = 700
        guard let native = tw_open_workspace("Threading attachment split fixture",
            Int32(sidebarWidth + terminalWidth + displayWidth), Int32(height),
            Int32(sidebarWidth)) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        tw_workspace_mode(native, Int32(sidebarWidth), 0)
        guard tw_workspace_set_display_width(native, Int32(displayWidth)) == 0,
              Int(tw_workspace_display_width(native)) == displayWidth else {
            throw WindowFailure("third workspace region was not reserved")
        }

        let sessionID = SessionID()
        let project = URL(fileURLWithPath: "/tmp/attachment-split-fixture", isDirectory: true)
        let file = project.appendingPathComponent("diagram.png")
        let attachment = SessionAttachment(
            sessionID: sessionID, root: project, url: file,
            relativePath: "diagram.png", sourcePath: file.path,
            kind: .image, origin: .agent,
            referencedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let source = TurnSource(attachment: attachment)
        let owner = NSWindow(backingScaleFactor: 1)
        let count = NSTextField(labelWithString: "ATTACHMENTS  1")
        count.applyFont(.caption)
        count.textColor = Design.Text.quaternary
        let filter = ThemedSegmentedControl()
        filter.configure(titles: AttachmentFilter.visibleCases(hasSubagents: false).map(\.title))
        filter.setAccessibilityLabel("Show attachments from")
        let header = SessionAttachmentHeaderRow(count: count, filter: filter, spacing: 8)
        let list = SessionAttachmentListView(frame: .zero)
        source.table = list.tableView
        list.tableView.dataSource = source
        list.tableView.delegate = source
        list.tableView.reloadData()
        let preview = NSView()
        let previewMessage = NSTextField(labelWithString: "Preview")
        previewMessage.applyFont(.detail())
        previewMessage.textColor = Design.Text.tertiary
        let footerLabel = NSTextField(labelWithString: "diagram.png")
        footerLabel.applyFont(.caption)
        footerLabel.textColor = Design.Text.label
        let footer = PaneFooterView(leading: [footerLabel], trailing: [], margin: .paneEdge)
        let scopeLabel = NSTextField(labelWithString: "OUTSIDE THIS PROJECT  1")
        scopeLabel.applyFont(.caption)
        scopeLabel.textColor = Design.Text.quaternary
        let scope = PaneFooterView(leading: [scopeLabel], trailing: [], margin: .paneEdge)
        let fold = PaneFoldDivider()
        let shell = SessionAttachmentsContentView(
            header: header, list: list, fold: fold, preview: preview,
            previewMessage: previewMessage, footer: footer, scopeBand: scope,
            emptyMessage: NSView(), listHeightPriority: .init(490)
        )
        shell.frame = NSRect(x: 0, y: 0, width: displayWidth, height: height)
        shell.listHeightConstraint.constant = 120
        shell.setScopeBandVisible(true)
        owner.contentView = shell
        shell.appearance = LinuxTheme.appearance
        owner.layoutIfNeeded()
        let display = Bitmap(width: displayWidth, height: height,
            background: LinuxTheme.components("ground"))
        shell.render(in: NSGraphicsContext(bitmap: display, scale: 1))

        let sidebar = Bitmap(width: sidebarWidth, height: height,
            background: (0.10, 0.32, 0.70, 1))
        let terminal = Bitmap(width: terminalWidth, height: height,
            background: (0.17, 0.20, 0.25, 1))
        func present(_ bitmap: Bitmap, sidebar: Int32) throws {
            let result = bitmap.pixels.withUnsafeBufferPointer {
                tw_present_pane(native, $0.baseAddress, Int32(bitmap.width),
                                Int32(bitmap.height), sidebar)
            }
            guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        }
        try present(sidebar, sidebar: 1)
        try present(terminal, sidebar: 0)
        let result = display.pixels.withUnsafeBufferPointer {
            tw_present_display_pane(native, $0.baseAddress,
                                    Int32(displayWidth), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        let foldRuleY = Int((CGFloat(height) - fold.frame.maxY).rounded())
        print("DISPLAY_PANE_FRAME sidebar=\(sidebarWidth) terminal=\(terminalWidth) "
            + "attachments=\(displayWidth) rows=\(list.tableView.numberOfRows) "
            + "foldRuleY=\(foldRuleY) filterSegments=\(filter.titles.count)")
        fflush(nil)
        filter.onSelect = { index in
            print("DISPLAY_FILTER_SELECTED index=\(index)")
            fflush(nil)
        }
        var previousPointerY: Int32?
        var presentedFilterIndex = filter.selectedIndex
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            var event = TWEvent()
            let received = tw_next_timeout(native, &event, 100)
            if received == 1, event.kind == 5 { break }
            if received == 1, event.kind == 1 { _ = tw_repaint(native) }
            guard received == 1, event.kind == 63 else { continue }
            let type: NSEvent.EventType
            switch event.action {
            case 1: type = .leftMouseDown
            case 2: type = .leftMouseDragged
            case 3: type = .leftMouseUp
            case 5: type = .rightMouseDown
            case 7: type = .scrollWheel
            default: type = .mouseMoved
            }
            let deltaY = previousPointerY.map { CGFloat(event.y - $0) } ?? 0
            previousPointerY = event.action == 3 || event.action == 4 ? nil : event.y
            let pointer = NSEvent(type: type,
                locationInWindow: NSPoint(x: CGFloat(event.x), y: CGFloat(height - Int(event.y))),
                scrollingDeltaX: CGFloat(event.scrollingDeltaX),
                scrollingDeltaY: CGFloat(event.scrollingDeltaY), deltaY: deltaY,
                clickCount: Int(event.clickCount))
            _ = owner.dispatchToContent(pointer)
            if event.action != 0 {
                print("DISPLAY_POINTER action=\(event.action) x=\(event.x) y=\(event.y)")
                fflush(nil)
            }
            let updated = Bitmap(width: displayWidth, height: height,
                background: LinuxTheme.components("ground"))
            shell.render(in: NSGraphicsContext(bitmap: updated, scale: 1))
            let presented = updated.pixels.withUnsafeBufferPointer {
                tw_present_display_pane(native, $0.baseAddress,
                    Int32(displayWidth), Int32(height))
            }
            guard presented == 0 else { throw WindowFailure(String(cString: tw_error())) }
            if filter.selectedIndex != presentedFilterIndex {
                presentedFilterIndex = filter.selectedIndex
                print("DISPLAY_FILTER_PRESENTED index=\(presentedFilterIndex)")
                fflush(nil)
            }
        }
    }
}
