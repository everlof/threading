#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import TerminalRuntime

enum SessionMenuCommand: String, CaseIterable {
    case copySessionID
    case copyProjectPath

    var title: String {
        switch self {
        case .copySessionID: "Copy Session ID"
        case .copyProjectPath: "Copy Project Path"
        }
    }
}

@MainActor
final class SessionMenuSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        ThemedSurface.draw(bounds.insetBy(dx: 0.5, dy: 0.5),
            fill: Design.Surface.elevated, border: Design.Text.tertiary,
            radius: Design.Radius.panel, borderWidth: 1)
    }
}

/// The visible terminal's presentation state. Runtime ownership stays in the app's bounded
/// catalogue; switching panes neither closes nor duplicates a daemon-backed session.
@MainActor
final class WorkspaceTerminalPane {
    static var headerPixelHeight: Int { Int((PaneHeaderView.bandHeight * 2).rounded()) }
    private static let visibleMenuRows = 6
    private var menuVisibleRows = 6

    struct OpenInChoice: Equatable {
        let id: String
        let name: String
    }

    private enum MenuContent: Equatable { case sessionActions, openIn }

    let session: GraphicalTerminal
    private let headerWindow = NSWindow(backingScaleFactor: 2)
    private let headerRoot = NSView(frame: .zero)
    private let pageTitle = PageTitleView(symbolName: "terminal", inkSource: .backdrop)
    private let openInAction = ThemedIconButton(
        symbolName: "folder", accessibility: "Open in external app",
        glyphMaterialization: .deferred)
    private let openInChooser = ThemedIconButton(
        symbolName: "chevron.down", accessibility: "Choose an app to open in",
        target: .splitMenu, glyphMaterialization: .deferred)
    private lazy var openInControl = SplitIconButtonView(
        action: openInAction, chevron: openInChooser)
    let pageIdentity: String
    private let menuWindow = NSWindow(backingScaleFactor: 2)
    private let menuRoot = SessionMenuSurface(frame: .zero)
    private var menuRows: [ThemedMenuRowView] = []
    private var menuPlan: ThemedMenuRowPlan?
    private var menuFirstVisible = 0
    private var menuOrigin = (x: 0, y: 0)
    private var menuSize = (width: 0, height: 0)
    private var menuSelected = 0
    private var menuContent: MenuContent = .sessionActions
    private var menuOpen = false
    private var menuNeedsPresentation = false
    private(set) var menuToggleRequested = false
    private(set) var chosenMenuCommand: SessionMenuCommand?
    private var openInChoices: [OpenInChoice] = []
    private var presentedOpenInChoices: [OpenInChoice] = []
    private var preferredOpenInID: String?
    private var requestedOpenInID: String?
    private var chosenOpenInID: String?
    private var openInChooserToggleRequested = false
    private var headerNeedsPresentation = true
    private var headerWidth = 0
    private var nextFrame: UInt64 = 0
    private var failure: String?
    private var failureNeedsDisplay = false
    private var size = (width: 0, height: 0)
    private var heldButtons: [Int: (x: Int, y: Int, modifiers: PTYEmulator.Modifiers)] = [:]
    private(set) var title = "Threading terminal - starting"
    var needsPolling: Bool { failure == nil }
    var hasSessionActions: Bool { !pageTitle.actionsAnchor.isHidden }
    var hasOpenMenu: Bool { menuOpen }
    var hasOpenInMenu: Bool { menuOpen && menuContent == .openIn }

    init(_ session: GraphicalTerminal, pageName: String, pageIdentity: String,
         icon: NSImage? = nil,
         showsSessionActions: Bool = false,
         onReveal: @escaping () -> Void) {
        self.session = session
        self.pageIdentity = pageIdentity
        pageTitle.update(title: pageName, symbolName: "terminal", identity: pageIdentity)
        if let icon { pageTitle.setIcon(icon) }
        pageTitle.onReveal = onReveal
        pageTitle.actionsAnchor.isHidden = !showsSessionActions
        pageTitle.onActions = { [weak self] _ in self?.menuToggleRequested = true }
        openInAction.onPress = { [weak self] in
            guard let self else { return }
            self.requestedOpenInID = self.preferredOpenInID
        }
        openInChooser.toolTip = "Choose an app to open in"
        openInChooser.presentsMenu = true
        openInChooser.onPress = { [weak self] in self?.openInChooserToggleRequested = true }
        openInControl.isHidden = true
        let header = PaneHeaderView(leading: [pageTitle], trailing: [openInControl],
                                    margin: .paneEdge)
        headerRoot.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRoot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerRoot.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerRoot.topAnchor)
        ])
        headerWindow.contentView = headerRoot
        headerWindow.isKeyWindow = true
        menuWindow.contentView = menuRoot
        setThemeAppearance()
        session.setPreedit(nil)
        session.invalidateFrame()
    }

    func setThemeAppearance() {
        let appearance = LinuxTheme.appearance
        headerRoot.appearance = appearance
        menuRoot.appearance = appearance
        openInControl.invalidateBackdropInk()
        let ansiRoles = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                         "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
                         "brightMagenta", "brightCyan", "brightWhite"]
        session.setThemeColors(
            foregroundRGB: Self.rgb("terminal.foreground"),
            backgroundRGB: Self.rgb("terminal.background"),
            ansiRGB: ansiRoles.map { Self.rgb("terminal.\($0)") })
        headerNeedsPresentation = true
        menuNeedsPresentation = menuOpen
    }

    private static func rgb(_ role: String) -> UInt32 {
        let (red, green, blue, _) = LinuxTheme.components(role)
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((max(0, min(1, value)) * 255).rounded())
        }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    /// Desktop discovery and launch authority belong to the host. Keep its bounded catalogue as
    /// values; only six production row views exist at once in the chooser viewport.
    func configureOpenIn(preferredID: String?, icon: NSImage?, choices: [OpenInChoice]) {
        openInChoices = Array(choices.prefix(64)).filter {
            !$0.id.isEmpty && $0.id.utf8.count < 128 && !$0.id.utf8.contains(0)
                && !$0.name.isEmpty && $0.name.utf8.count <= 400
                && !$0.name.utf8.contains(0)
        }
        let preferred = openInChoices.first(where: { $0.id == preferredID })
            ?? openInChoices.first
        preferredOpenInID = preferred?.id
        let available = preferred != nil
        openInControl.isHidden = !available
        openInAction.isEnabled = available
        openInChooser.isEnabled = available
        if let preferred {
            let label = "Open in \(preferred.name)"
            if preferred.id == preferredID, let icon {
                openInAction.setImage(icon, accessibility: label)
            }
            else { openInAction.setSymbol("folder", accessibility: label) }
            openInAction.toolTip = label
            // This control starts hidden. Materialize its visible halves before the shim's
            // first layout solve so GlyphView contributes its intrinsic size to that pass.
            openInAction.materializeGlyphIfNeeded()
            openInChooser.materializeGlyphIfNeeded()
        }
        headerNeedsPresentation = true
    }

    func pressOpenInAction() -> Bool {
        guard preferredOpenInID != nil else { return false }
        return openInAction.accessibilityPerformPress()
    }

    func pressOpenInChooser() -> Bool {
        guard !openInChoices.isEmpty else { return false }
        return openInChooser.accessibilityPerformPress()
    }

    func takeOpenInPressRequest() -> String? {
        defer { requestedOpenInID = nil }
        return requestedOpenInID
    }

    func takeOpenInChooserToggleRequest() -> Bool {
        defer { openInChooserToggleRequested = false }
        return openInChooserToggleRequested
    }

    func takeOpenInChoiceRequest() -> String? {
        defer { chosenOpenInID = nil }
        return chosenOpenInID
    }

    func handleHeader(_ input: TWEvent) {
        let eventType: NSEvent.EventType
        switch input.action {
        case 1: eventType = .leftMouseDown
        case 2: eventType = .leftMouseDragged
        case 3: eventType = .leftMouseUp
        default: eventType = .mouseMoved
        }
        let point = NSPoint(x: CGFloat(input.x) / 2,
                            y: PaneHeaderView.bandHeight - CGFloat(input.y) / 2)
        _ = headerWindow.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
        if input.action == 4 { headerWindow.cancelPointerGesture() }
        headerNeedsPresentation = true
    }

    func pressPageTitle() -> Bool { pageTitle.accessibilityPerformPress() }

    func pressSessionActions() -> Bool {
        guard hasSessionActions else { return false }
        return pageTitle.actionsAnchor.accessibilityPerformPress()
    }

    func takeMenuToggleRequest() -> Bool {
        defer { menuToggleRequested = false }
        return menuToggleRequested
    }

    func takeMenuCommand() -> SessionMenuCommand? {
        defer { chosenMenuCommand = nil }
        return chosenMenuCommand
    }

    func toggleMenu(window: OpaquePointer, paneWidth: Int) {
        if menuOpen {
            let wasSessionMenu = menuContent == .sessionActions
            dismissMenu(window: window)
            if wasSessionMenu { return }
        }
        guard hasSessionActions, paneWidth >= 280 else { return }
        openMenu(.sessionActions, paneWidth: paneWidth)
    }

    func toggleOpenInMenu(window: OpaquePointer, paneWidth: Int) {
        if menuOpen {
            let wasOpenInMenu = menuContent == .openIn
            dismissMenu(window: window)
            if wasOpenInMenu { return }
        }
        guard !openInChoices.isEmpty, paneWidth >= 280 else { return }
        openMenu(.openIn, paneWidth: paneWidth)
    }

    private func openMenu(_ content: MenuContent, paneWidth: Int) {
        menuVisibleRows = Self.visibleMenuRows
        menuContent = content
        chosenMenuCommand = nil
        chosenOpenInID = nil
        let entries: [ThemedMenuEntry]
        let selectedEntryIndex: Int?
        switch content {
        case .sessionActions:
            entries = SessionMenuCommand.allCases.map {
                .item(ThemedMenuItem(title: $0.title, representedValue: $0.rawValue))
            }
            selectedEntryIndex = nil
        case .openIn:
            presentedOpenInChoices = openInChoices
            entries = presentedOpenInChoices.map {
                .item(ThemedMenuItem(title: $0.name, representedValue: $0.id))
            }
            selectedEntryIndex = presentedOpenInChoices.firstIndex { $0.id == preferredOpenInID }
        }
        menuPlan = ThemedMenuRowPlan(entries: entries, selectedEntryIndex: selectedEntryIndex)
        menuSelected = selectedEntryIndex ?? 0
        menuFirstVisible = min(menuSelected, max(0, entries.count - menuVisibleRows))
        let menuWidth = min(CGFloat(228), CGFloat(paneWidth) / 2 - 8)
        menuSize.width = Int(menuWidth * 2)
        rebuildVisibleMenuRows()
        headerWindow.layoutIfNeeded()
        let x: Int
        switch content {
        case .sessionActions:
            let anchor = pageTitle.actionsAnchor.convert(pageTitle.actionsAnchor.bounds,
                                                          to: headerRoot)
            x = Int((anchor.minX * 2).rounded())
            pageTitle.actionsAnchor.isSelected = true
        case .openIn:
            let anchor = openInChooser.convert(openInChooser.bounds, to: headerRoot)
            x = Int((anchor.maxX * 2).rounded()) - menuSize.width
            openInChooser.isSelected = true
        }
        menuOrigin = (max(0, min(paneWidth - menuSize.width, x)), Self.headerPixelHeight)
        headerNeedsPresentation = true
        menuOpen = true
        menuNeedsPresentation = true
    }

    private func rebuildVisibleMenuRows() {
        guard let plan = menuPlan else { return }
        let last = min(plan.heights.count, menuFirstVisible + menuVisibleRows)
        let visible = menuFirstVisible..<last
        let padding: CGFloat = 6
        let menuHeight = visible.reduce(2 * padding) { $0 + plan.heights[$1] }
        menuSize.height = Int(menuHeight * 2)
        let menuWidth = CGFloat(menuSize.width) / 2
        menuRoot.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight)
        for row in menuRows { row.removeFromSuperview() }
        menuRows.removeAll(keepingCapacity: true)
        var top = padding
        for index in visible {
            guard let row = plan.row(at: index) else { continue }
            let rowHeight = plan.heights[index]
            row.frame = NSRect(x: padding, y: menuHeight - top - rowHeight,
                               width: menuWidth - padding * 2, height: rowHeight)
            row.onChoose = { [weak self] selected, _ in
                self?.recordMenuSelection(at: selected)
            }
            row.onHighlight = { [weak self] selected in self?.highlightMenuRow(selected) }
            menuRoot.addSubview(row)
            menuRows.append(row)
            top += rowHeight
        }
        for row in menuRows {
            row.isKeyboardHighlighted = row.entryIndex == menuSelected
        }
        menuNeedsPresentation = true
    }

    func dismissMenu(window: OpaquePointer) {
        guard menuOpen else { return }
        menuOpen = false
        menuNeedsPresentation = false
        switch menuContent {
        case .sessionActions: pageTitle.actionsAnchor.isSelected = false
        case .openIn: openInChooser.isSelected = false
        }
        headerNeedsPresentation = true
        menuWindow.cancelPointerGesture()
        tw_hide_session_menu(window)
    }

    private func highlightMenuRow(_ index: Int) {
        guard menuOpen, let plan = menuPlan, plan.heights.indices.contains(index) else { return }
        menuSelected = index
        if index < menuFirstVisible {
            menuFirstVisible = index
            rebuildVisibleMenuRows()
        } else if index >= menuFirstVisible + menuRows.count {
            menuFirstVisible = index - menuVisibleRows + 1
            rebuildVisibleMenuRows()
        } else {
            for row in menuRows {
                row.isKeyboardHighlighted = row.entryIndex == index
            }
        }
        menuNeedsPresentation = true
    }

    private func recordMenuSelection(at index: Int) {
        guard menuOpen, let plan = menuPlan, plan.heights.indices.contains(index) else { return }
        switch menuContent {
        case .sessionActions:
            chosenMenuCommand = SessionMenuCommand.allCases[index]
        case .openIn:
            chosenOpenInID = presentedOpenInChoices[index].id
        }
    }

    func handleMenu(_ input: TWEvent, window: OpaquePointer) {
        guard menuOpen else { return }
        switch input.action {
        case 4, 6:
            dismissMenu(window: window)
        case 7:
            highlightMenuRow(max(0, menuSelected - 1))
        case 8:
            highlightMenuRow(min((menuPlan?.heights.count ?? 1) - 1, menuSelected + 1))
        case 9:
            recordMenuSelection(at: menuSelected)
        case 10, 12:
            if menuContent == .openIn {
                let step = input.action == 10 ? menuVisibleRows : max(1, Int(input.key))
                highlightMenuRow(max(0, menuSelected - step))
            }
        case 11, 13:
            if menuContent == .openIn {
                let step = input.action == 11 ? menuVisibleRows : max(1, Int(input.key))
                highlightMenuRow(min((menuPlan?.heights.count ?? 1) - 1,
                                     menuSelected + step))
            }
        default:
            let eventType: NSEvent.EventType
            switch input.action {
            case 1: eventType = .leftMouseDown
            case 2: eventType = .leftMouseDragged
            case 3: eventType = .leftMouseUp
            default: eventType = .mouseMoved
            }
            let point = NSPoint(x: CGFloat(input.x) / 2,
                                y: menuRoot.bounds.height - CGFloat(input.y) / 2)
            _ = menuWindow.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
            menuNeedsPresentation = true
        }
    }

    func chooseMenuRow(_ slot: Int, identity: String) {
        guard menuOpen, identity == pageIdentity,
              menuRows.indices.contains(slot) else { return }
        recordMenuSelection(at: menuRows[slot].entryIndex)
    }

    private func presentMenu(window: OpaquePointer, originX: Int) throws {
        guard menuOpen, menuNeedsPresentation else { return }
        menuNeedsPresentation = false
        let bitmap = Bitmap(width: menuSize.width, height: menuSize.height)
        menuRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: 2))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_session_menu(window, $0.baseAddress,
                                    Int32(menuSize.width), Int32(menuSize.height),
                                    Int32(menuOrigin.x), Int32(menuOrigin.y))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        pageIdentity.withCString { identity in
            tw_accessibility_session_menu_begin(window, identity,
                Int32(originX + menuOrigin.x), Int32(menuOrigin.y),
                Int32(menuSize.width), Int32(menuSize.height))
        }
        if menuContent == .openIn {
            tw_accessibility_session_menu_label(window, "Open In applications")
        }
        for row in menuRows {
            let bounds = row.convert(row.bounds, to: menuRoot)
            let x = originX + menuOrigin.x + Int((bounds.minX * 2).rounded())
            let y = menuOrigin.y + Int(((menuRoot.bounds.height - bounds.maxY) * 2).rounded())
            let rowID: String
            switch menuContent {
            case .sessionActions: rowID = SessionMenuCommand.allCases[row.entryIndex].rawValue
            // ATK row IDs are bounded display tokens. The real desktop ID stays in the
            // pane-side choice snapshot and is resolved only after a validated row press.
            case .openIn: rowID = "open-in.choice.\(row.entryIndex)"
            }
            _ = rowID.withCString { identifier in
                row.item.title.withCString { name in
                    tw_accessibility_session_menu_add_row(window, identifier, name,
                        row.entryIndex == menuSelected ? 1 : 0, 1, Int32(x), Int32(y),
                        Int32((bounds.width * 2).rounded()), Int32((bounds.height * 2).rounded()))
                }
            }
        }
        tw_accessibility_session_menu_end(window)
    }

    private func presentHeader(window: OpaquePointer, width: Int, originX: Int) throws {
        guard headerNeedsPresentation || headerWidth != width else { return }
        headerNeedsPresentation = false
        headerWidth = width
        headerRoot.frame = NSRect(x: 0, y: 0, width: CGFloat(width) / 2,
                                  height: PaneHeaderView.bandHeight)
        let openInWidth = Design.Size.toolbarButtonWidth + Design.Size.splitMenuWidth
            + PaneHeaderView.itemSpacing
        pageTitle.maxWidth = max(0, headerRoot.bounds.width
            - 2 * PaneHeaderView.contentInset - openInWidth)
        let bitmap = Bitmap(width: width, height: Self.headerPixelHeight,
                            background: LinuxTheme.components("terminal.background"))
        headerRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: 2))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_terminal_header(window, $0.baseAddress,
                                       Int32(width), Int32(Self.headerPixelHeight))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        let titleBounds = pageTitle.convert(pageTitle.bounds, to: headerRoot)
        let left = Int((titleBounds.minX * 2).rounded(.down))
        let top = Int((titleBounds.maxY * 2).rounded(.up))
        let actionsBounds = pageTitle.actionsAnchor.convert(pageTitle.actionsAnchor.bounds,
                                                              to: headerRoot)
        let right = Int(((hasSessionActions ? min(titleBounds.maxX, actionsBounds.minX)
                           : titleBounds.maxX) * 2).rounded(.up))
        let bottom = Int((titleBounds.minY * 2).rounded(.down))
        pageIdentity.withCString { identity in
            pageTitle.title.withCString { name in
                tw_accessibility_page_title(window, identity, name,
                    Int32(originX + left), Int32(Self.headerPixelHeight - top),
                    Int32(right - left), Int32(top - bottom))
            }
        }
        if hasSessionActions {
            let actionX = Int((actionsBounds.minX * 2).rounded(.down))
            let actionTop = Int((actionsBounds.maxY * 2).rounded(.up))
            pageIdentity.withCString { identity in
                tw_accessibility_page_actions(window, identity, "Session context menu",
                    Int32(originX + actionX), Int32(Self.headerPixelHeight - actionTop),
                    Int32((actionsBounds.width * 2).rounded()),
                    Int32((actionsBounds.height * 2).rounded()))
            }
        } else {
            tw_accessibility_page_actions(window, nil, nil, 0, 0, 0, 0)
        }
        if preferredOpenInID != nil {
            let primary = openInAction.convert(openInAction.bounds, to: headerRoot)
            let chooser = openInChooser.convert(openInChooser.bounds, to: headerRoot)
            let primaryTop = Int((primary.maxY * 2).rounded(.up))
            let chooserTop = Int((chooser.maxY * 2).rounded(.up))
            pageIdentity.withCString { identity in
                (openInAction.accessibilityTitle() ?? "Open in external app").withCString { label in
                    (openInChooser.accessibilityTitle() ?? "Choose an app to open in")
                        .withCString { chooserLabel in
                            tw_accessibility_open_in(window, identity, label, chooserLabel, 1,
                                Int32(originX + Int((primary.minX * 2).rounded(.down))),
                                Int32(Self.headerPixelHeight - primaryTop),
                                Int32((primary.width * 2).rounded()),
                                Int32((primary.height * 2).rounded()),
                                Int32(originX + Int((chooser.minX * 2).rounded(.down))),
                                Int32(Self.headerPixelHeight - chooserTop),
                                Int32((chooser.width * 2).rounded()),
                                Int32((chooser.height * 2).rounded()))
                        }
                }
            }
        } else {
            tw_accessibility_open_in(window, nil, nil, nil, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        headerWindow.isKeyWindow = focused
        if !focused {
            dismissMenu(window: window)
            headerWindow.makeFirstResponder(nil)
            headerWindow.cancelPointerGesture()
            session.setPreedit(nil)
            // Complete each gesture on its original runtime before another pane can own input.
            for (button, point) in heldButtons {
                session.mouseButton(x: point.x, y: point.y, button: button,
                                    release: true, modifiers: point.modifiers)
            }
            heldButtons.removeAll(keepingCapacity: true)
        }
        else {
            session.invalidateFrame()
            tw_title(window, title)
        }
    }

    /// No wait or nested event loop: the workspace services both panes on one UI turn.
    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int,
                 focused: Bool) throws {
        if menuOpen && headerWidth != width { dismissMenu(window: window) }
        if menuOpen, let plan = menuPlan {
            let available = CGFloat(max(0, height - Self.headerPixelHeight)) / 2
            var rows = 0
            var used: CGFloat = 12
            for rowHeight in plan.heights.prefix(Self.visibleMenuRows) {
                guard used + rowHeight <= available else { break }
                used += rowHeight
                rows += 1
            }
            if rows == 0 {
                dismissMenu(window: window)
            } else if rows != menuVisibleRows {
                menuVisibleRows = rows
                menuFirstVisible = min(menuFirstVisible, max(0, plan.heights.count - rows))
                if menuSelected < menuFirstVisible { menuFirstVisible = menuSelected }
                if menuSelected >= menuFirstVisible + rows {
                    menuFirstVisible = menuSelected - rows + 1
                }
                rebuildVisibleMenuRows()
            }
        }
        let contentHeight = max(1, height - Self.headerPixelHeight)
        tw_workspace_terminal_top_inset(window, Int32(Self.headerPixelHeight))
        try presentHeader(window: window, width: width, originX: originX)
        try presentMenu(window: window, originX: originX)
        if size.width != width || size.height != contentHeight {
            size = (width, contentHeight)
            failureNeedsDisplay = failure != nil
        }
        if let copy = session.takeCopyResult() {
            switch copy {
            case .text(let bytes):
                let wrote = bytes.withUnsafeBytes {
                    tw_clipboard_write($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count))
                }
                print(wrote == 0 ? "CLIPBOARD_COPIED \(bytes.count)" : "CLIPBOARD_REFUSED native write failed")
            case .empty: print("CLIPBOARD_REFUSED no selection")
            case .oversized: print("CLIPBOARD_REFUSED selection exceeds 1 MiB")
            }
            fflush(nil)
        }
        var prepared: GraphicalTerminal.Frame?
        if failure == nil {
            do { prepared = try session.takeFrame() }
            catch {
                failure = String(describing: error)
                title = "Threading terminal - unavailable"
                failureNeedsDisplay = true
                session.stop()
            }
        }
        if let failure, failureNeedsDisplay {
            try WindowHarness.showTerminalFailure(failure, window: window, width: width,
                                                   height: contentHeight, workspace: true,
                                                   focused: focused)
            failureNeedsDisplay = false
        }
        if let frame = prepared, frame.width == width && frame.height == contentHeight {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = frame.pixels.withUnsafeBytes {
                tw_present_pane(window, $0.bindMemory(to: UInt8.self).baseAddress,
                                Int32(width), Int32(contentHeight), 0)
            }
            guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
            title = frame.title
            title.withCString { tw_accessibility_show_terminal(window, $0) }
            let runs = frame.accessibleRuns.map {
                TWTextRun(offset: $0.offset, characters: $0.characters,
                          column: $0.column, row: $0.row, cells: $0.cells)
            }
            frame.accessibleText.withCString { text in
                runs.withUnsafeBufferPointer {
                    tw_accessibility_terminal_text(window, text, Int32(frame.accessibleText.utf8.count),
                        Int32(frame.accessibleCaret), $0.baseAddress, Int32($0.count))
                }
            }
            if focused {
                let x = frame.cursorColumn >= 0 ? frame.cursorColumn * WindowHarness.terminalCellWidth : 8
                let y = frame.cursorColumn >= 0 ? frame.cursorRow * WindowHarness.terminalCellHeight
                    : contentHeight - WindowHarness.terminalCellHeight
                tw_text_input_rect(window,
                    Int32(originX + max(0, min(width - WindowHarness.terminalCellWidth, x))),
                    Int32(Self.headerPixelHeight + max(0,
                        min(contentHeight - WindowHarness.terminalCellHeight, y))),
                    Int32(WindowHarness.terminalCellWidth), Int32(WindowHarness.terminalCellHeight))
                tw_title(window, title)
            }
            print("TERMINAL_FRAME \(width)x\(contentHeight) \(title) drawMs=\(frame.drawMilliseconds) presentMs=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
            fflush(nil)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if failure == nil && now >= nextFrame {
            session.requestFrame(width: width, height: contentHeight)
            nextFrame = now + 33_000_000
        }
    }

    func handle(_ input: TWEvent, window: OpaquePointer) {
        guard failure == nil else { return }
        var event = input
        switch event.kind {
        case 19:
            let text = String(validatingCString: tw_event_text(&event)) ?? "[invalid composition]"
            session.setPreedit(text, cursor: Int(event.textCursor), selectionLength: Int(event.textSelectionLength))
            print("IME_PREEDIT bytes=\(text.utf8.count)"); fflush(nil)
        case 6:
            session.setPreedit(nil)
            if let text = String(validatingCString: tw_event_text(&event)) {
                session.send(Data(text.utf8))
                if event.action == 1 { print("IME_COMMIT bytes=\(text.utf8.count)"); fflush(nil) }
            }
        case 7: WindowHarness.sendFunctional(event, to: session)
        case 14: WindowHarness.pasteClipboard(into: session, window: window)
        case 15:
            let button = Int(event.key)
            if event.action == 3 {
                guard heldButtons.removeValue(forKey: button) != nil else { return }
            } else {
                guard (0...2).contains(button) else { return }
                heldButtons[button] = (Int(event.x), Int(event.y), WindowHarness.modifiers(event))
            }
            session.mouseButton(x: Int(event.x), y: Int(event.y), button: Int(event.key),
                release: event.action == 3, modifiers: WindowHarness.modifiers(event))
        case 16:
            session.mouseWheel(x: Int(event.x), y: Int(event.y), steps: Int(event.key),
                modifiers: WindowHarness.modifiers(event))
        case 17:
            guard var point = heldButtons[0] else { return }
            point.x = Int(event.x); point.y = Int(event.y)
            heldButtons[0] = point
            session.mouseMotion(x: point.x, y: point.y)
        case 18: session.requestCopySelection()
        default: break
        }
    }
}
#endif
