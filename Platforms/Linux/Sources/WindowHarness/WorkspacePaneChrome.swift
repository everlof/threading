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

/// Shared pane header and bounded menus. The content runtime owns input and lifecycle.
@MainActor
final class WorkspacePaneChrome {
    static var headerPixelHeight: Int { Int((PaneHeaderView.bandHeight * WorkspaceDisplay.scale).rounded()) }
    private static let visibleMenuRows = 6
    private var menuVisibleRows = 6

    struct OpenInChoice: Equatable {
        let id: String
        let name: String
    }

    private enum MenuContent: Equatable { case sessionActions, openIn }

    private let headerWindow = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
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
    private lazy var openInSlot: NSStackView = {
        let stack = NSStackView(views: [openInControl])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        return stack
    }()
    private(set) var pageIdentity: String
    private var pageSymbolName: String
    private let menuWindow = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let menuRoot = ThemedMenuPanelView(frame: .zero)
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
    var hasSessionActions: Bool { !pageTitle.actionsAnchor.isHidden }
    var hasOpenMenu: Bool { menuOpen }
    var hasOpenInMenu: Bool { menuOpen && menuContent == .openIn }

    init(pageName: String, pageIdentity: String, symbolName: String = "terminal",
         icon: NSImage? = nil,
         showsSessionActions: Bool = false,
         onReveal: @escaping () -> Void) {
        self.pageIdentity = pageIdentity
        self.pageSymbolName = symbolName
        pageTitle.update(title: pageName, symbolName: symbolName, identity: pageIdentity)
        if let icon { pageTitle.setIcon(icon) }
        pageTitle.onReveal = onReveal
        pageTitle.actionsAnchor.isHidden = !showsSessionActions
        pageTitle.onActions = { [weak self] _ in self?.menuToggleRequested = true }
        pageTitle.maxWidth = PageTitleView.maximumWidth
        NSLayoutConstraint.activate([
            pageTitle.widthAnchor.constraint(lessThanOrEqualToConstant: PageTitleView.maximumWidth)
        ])
        openInAction.onPress = { [weak self] in
            guard let self else { return }
            self.requestedOpenInID = self.preferredOpenInID
        }
        openInChooser.toolTip = "Choose an app to open in"
        openInChooser.presentsMenu = true
        openInChooser.onPress = { [weak self] in self?.openInChooserToggleRequested = true }
        openInControl.isHidden = true
        let header = PaneHeaderView(leading: [pageTitle], trailing: [openInSlot],
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
    }

    func setThemeAppearance() {
        let appearance = LinuxTheme.appearance
        headerRoot.appearance = appearance
        menuRoot.appearance = appearance
        openInControl.invalidateBackdropInk()
        headerNeedsPresentation = true
        menuNeedsPresentation = menuOpen
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
        let point = NSPoint(x: CGFloat(input.x) / WorkspaceDisplay.scale,
                            y: PaneHeaderView.bandHeight - CGFloat(input.y) / WorkspaceDisplay.scale)
        _ = headerWindow.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
        if input.action == 4 { headerWindow.cancelPointerGesture() }
        headerNeedsPresentation = true
    }

    func pressPageTitle() -> Bool { pageTitle.accessibilityPerformPress() }

    /// A new shell acquires its durable identity on a worker after this header is mounted.
    /// Update the existing control, without replacing its terminal pane or input ownership.
    func updateTerminalPage(name: String, identity: String, window: OpaquePointer,
                            onReveal: @escaping () -> Void) {
        guard pageIdentity != identity else { return }
        dismissMenu(window: window)
        headerWindow.cancelPointerGesture()
        menuToggleRequested = false
        openInChooserToggleRequested = false
        requestedOpenInID = nil
        chosenOpenInID = nil
        pageIdentity = identity
        pageSymbolName = "terminal"
        pageTitle.update(title: name, symbolName: "terminal", identity: identity)
        pageTitle.onReveal = onReveal
        headerNeedsPresentation = true
    }

    func updatePageName(_ name: String) {
        pageTitle.update(title: name, symbolName: pageSymbolName, identity: pageIdentity)
        headerNeedsPresentation = true
    }

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
        let menuWidth = min(CGFloat(228), CGFloat(paneWidth) / WorkspaceDisplay.scale - 8)
        menuSize.width = Int(menuWidth * WorkspaceDisplay.scale)
        rebuildVisibleMenuRows()
        headerWindow.layoutIfNeeded()
        let x: Int
        switch content {
        case .sessionActions:
            let anchor = pageTitle.actionsAnchor.convert(pageTitle.actionsAnchor.bounds,
                                                          to: headerRoot)
            x = Int((anchor.minX * WorkspaceDisplay.scale).rounded())
            pageTitle.actionsAnchor.isSelected = true
        case .openIn:
            let anchor = openInChooser.convert(openInChooser.bounds, to: headerRoot)
            x = Int((anchor.maxX * WorkspaceDisplay.scale).rounded()) - menuSize.width
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
        menuSize.height = Int(menuHeight * WorkspaceDisplay.scale)
        let menuWidth = CGFloat(menuSize.width) / WorkspaceDisplay.scale
        menuRoot.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight)
        menuRows.removeAll(keepingCapacity: true)
        var heights: [CGFloat] = []
        for index in visible {
            guard let row = plan.row(at: index) else { continue }
            row.onChoose = { [weak self] selected, _ in
                self?.recordMenuSelection(at: selected)
            }
            row.onHighlight = { [weak self] selected in self?.highlightMenuRow(selected) }
            menuRows.append(row)
            heights.append(plan.heights[index])
        }
        menuRoot.setRows(menuRows, heights: heights, padding: padding)
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
            let point = NSPoint(x: CGFloat(input.x) / WorkspaceDisplay.scale,
                                y: menuRoot.bounds.height - CGFloat(input.y) / WorkspaceDisplay.scale)
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
        menuRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: WorkspaceDisplay.scale))
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
            let x = originX + menuOrigin.x + Int((bounds.minX * WorkspaceDisplay.scale).rounded())
            let y = menuOrigin.y + Int(((menuRoot.bounds.height - bounds.maxY) * WorkspaceDisplay.scale).rounded())
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
                        Int32((bounds.width * WorkspaceDisplay.scale).rounded()), Int32((bounds.height * WorkspaceDisplay.scale).rounded()))
                }
            }
        }
        tw_accessibility_session_menu_end(window)
    }

    private func presentHeader(window: OpaquePointer, width: Int, originX: Int) throws {
        guard headerNeedsPresentation || headerWidth != width else { return }
        headerNeedsPresentation = false
        headerWidth = width
        headerRoot.frame = NSRect(x: 0, y: 0, width: CGFloat(width) / WorkspaceDisplay.scale,
                                  height: PaneHeaderView.bandHeight)
        // This is the SDL bitmap viewport. PaneHeaderView's shared constraints divide its
        // width between the page title and the optional trailing control.
        let bitmap = Bitmap(width: width, height: Self.headerPixelHeight,
                            background: LinuxTheme.components("terminal.background"))
        headerRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: WorkspaceDisplay.scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_terminal_header(window, $0.baseAddress,
                                       Int32(width), Int32(Self.headerPixelHeight))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        let titleBounds = pageTitle.convert(pageTitle.bounds, to: headerRoot)
        let left = Int((titleBounds.minX * WorkspaceDisplay.scale).rounded(.down))
        let top = Int((titleBounds.maxY * WorkspaceDisplay.scale).rounded(.up))
        let actionsBounds = pageTitle.actionsAnchor.convert(pageTitle.actionsAnchor.bounds,
                                                              to: headerRoot)
        let right = Int(((hasSessionActions ? min(titleBounds.maxX, actionsBounds.minX)
                           : titleBounds.maxX) * WorkspaceDisplay.scale).rounded(.up))
        let bottom = Int((titleBounds.minY * WorkspaceDisplay.scale).rounded(.down))
        pageIdentity.withCString { identity in
            pageTitle.title.withCString { name in
                tw_accessibility_page_title(window, identity, name,
                    Int32(originX + left), Int32(Self.headerPixelHeight - top),
                    Int32(right - left), Int32(top - bottom))
            }
        }
        if hasSessionActions {
            let actionX = Int((actionsBounds.minX * WorkspaceDisplay.scale).rounded(.down))
            let actionTop = Int((actionsBounds.maxY * WorkspaceDisplay.scale).rounded(.up))
            pageIdentity.withCString { identity in
                tw_accessibility_page_actions(window, identity, "Session context menu",
                    Int32(originX + actionX), Int32(Self.headerPixelHeight - actionTop),
                    Int32((actionsBounds.width * WorkspaceDisplay.scale).rounded()),
                    Int32((actionsBounds.height * WorkspaceDisplay.scale).rounded()))
            }
        } else {
            tw_accessibility_page_actions(window, nil, nil, 0, 0, 0, 0)
        }
        if preferredOpenInID != nil {
            let primary = openInAction.convert(openInAction.bounds, to: headerRoot)
            let chooser = openInChooser.convert(openInChooser.bounds, to: headerRoot)
            let primaryTop = Int((primary.maxY * WorkspaceDisplay.scale).rounded(.up))
            let chooserTop = Int((chooser.maxY * WorkspaceDisplay.scale).rounded(.up))
            pageIdentity.withCString { identity in
                (openInAction.accessibilityTitle() ?? "Open in external app").withCString { label in
                    (openInChooser.accessibilityTitle() ?? "Choose an app to open in")
                        .withCString { chooserLabel in
                            tw_accessibility_open_in(window, identity, label, chooserLabel, 1,
                                Int32(originX + Int((primary.minX * WorkspaceDisplay.scale).rounded(.down))),
                                Int32(Self.headerPixelHeight - primaryTop),
                                Int32((primary.width * WorkspaceDisplay.scale).rounded()),
                                Int32((primary.height * WorkspaceDisplay.scale).rounded()),
                                Int32(originX + Int((chooser.minX * WorkspaceDisplay.scale).rounded(.down))),
                                Int32(Self.headerPixelHeight - chooserTop),
                                Int32((chooser.width * WorkspaceDisplay.scale).rounded()),
                                Int32((chooser.height * WorkspaceDisplay.scale).rounded()))
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
        }
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int) throws {
        if menuOpen && headerWidth != width { dismissMenu(window: window) }
        if menuOpen, let plan = menuPlan {
            let available = CGFloat(max(0, height - Self.headerPixelHeight)) / WorkspaceDisplay.scale
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
        tw_workspace_terminal_top_inset(window, Int32(Self.headerPixelHeight))
        try presentHeader(window: window, width: width, originX: originX)
        try presentMenu(window: window, originX: originX)
    }
}
#endif
