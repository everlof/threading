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

    let session: GraphicalTerminal
    private let headerWindow = NSWindow(backingScaleFactor: 2)
    private let headerRoot = NSView(frame: .zero)
    private let pageTitle = PageTitleView(symbolName: "terminal", inkSource: .backdrop)
    let pageIdentity: String
    private let menuWindow = NSWindow(backingScaleFactor: 2)
    private let menuRoot = SessionMenuSurface(frame: .zero)
    private var menuRows: [ThemedMenuRowView] = []
    private var menuOrigin = (x: 0, y: 0)
    private var menuSize = (width: 0, height: 0)
    private var menuSelected = 0
    private var menuOpen = false
    private var menuNeedsPresentation = false
    private(set) var menuToggleRequested = false
    private(set) var chosenMenuCommand: SessionMenuCommand?
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
        let header = PaneHeaderView(leading: [pageTitle], margin: .paneEdge)
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
        if menuOpen { dismissMenu(window: window); return }
        guard hasSessionActions, paneWidth >= 280 else { return }
        let commands = SessionMenuCommand.allCases
        let entries = commands.map {
            ThemedMenuEntry.item(ThemedMenuItem(title: $0.title, representedValue: $0.rawValue))
        }
        let plan = ThemedMenuRowPlan(entries: entries)
        let menuWidth = min(CGFloat(228), CGFloat(paneWidth) / 2 - 8)
        let padding: CGFloat = 6
        let menuHeight = plan.heights.reduce(0, +) + padding * 2
        menuSize = (Int(menuWidth * 2), Int(menuHeight * 2))
        menuRoot.frame = NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight)
        for row in menuRows { row.removeFromSuperview() }
        menuRows.removeAll(keepingCapacity: true)
        var top = padding
        for index in commands.indices {
            guard let row = plan.row(at: index) else { continue }
            let rowHeight = plan.heights[index]
            row.frame = NSRect(x: padding, y: menuHeight - top - rowHeight,
                               width: menuWidth - padding * 2, height: rowHeight)
            row.onChoose = { [weak self] selected, _ in
                self?.chosenMenuCommand = commands[selected]
            }
            row.onHighlight = { [weak self] selected in self?.highlightMenuRow(selected) }
            menuRoot.addSubview(row)
            menuRows.append(row)
            top += rowHeight
        }
        menuSelected = 0
        highlightMenuRow(0)
        headerWindow.layoutIfNeeded()
        let anchor = pageTitle.actionsAnchor.convert(pageTitle.actionsAnchor.bounds, to: headerRoot)
        let x = Int((anchor.minX * 2).rounded())
        menuOrigin = (max(0, min(paneWidth - menuSize.width, x)), Self.headerPixelHeight)
        pageTitle.actionsAnchor.isSelected = true
        headerNeedsPresentation = true
        menuOpen = true
        menuNeedsPresentation = true
    }

    func dismissMenu(window: OpaquePointer) {
        guard menuOpen else { return }
        menuOpen = false
        menuNeedsPresentation = false
        pageTitle.actionsAnchor.isSelected = false
        headerNeedsPresentation = true
        menuWindow.cancelPointerGesture()
        tw_hide_session_menu(window)
    }

    private func highlightMenuRow(_ index: Int) {
        guard menuRows.indices.contains(index) else { return }
        menuSelected = index
        for (slot, row) in menuRows.enumerated() {
            row.isKeyboardHighlighted = slot == index
        }
        menuNeedsPresentation = true
    }

    func handleMenu(_ input: TWEvent, window: OpaquePointer) {
        guard menuOpen else { return }
        switch input.action {
        case 4, 6:
            dismissMenu(window: window)
        case 7:
            highlightMenuRow(max(0, menuSelected - 1))
        case 8:
            highlightMenuRow(min(menuRows.count - 1, menuSelected + 1))
        case 9:
            chosenMenuCommand = SessionMenuCommand.allCases[menuSelected]
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
              SessionMenuCommand.allCases.indices.contains(slot) else { return }
        chosenMenuCommand = SessionMenuCommand.allCases[slot]
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
        for (slot, row) in menuRows.enumerated() {
            let bounds = row.convert(row.bounds, to: menuRoot)
            let x = originX + menuOrigin.x + Int((bounds.minX * 2).rounded())
            let y = menuOrigin.y + Int(((menuRoot.bounds.height - bounds.maxY) * 2).rounded())
            _ = SessionMenuCommand.allCases[slot].rawValue.withCString { identifier in
                row.item.title.withCString { name in
                    tw_accessibility_session_menu_add_row(window, identifier, name,
                        slot == menuSelected ? 1 : 0, 1, Int32(x), Int32(y),
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
        pageTitle.maxWidth = max(0, headerRoot.bounds.width - 2 * PaneHeaderView.contentInset)
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
