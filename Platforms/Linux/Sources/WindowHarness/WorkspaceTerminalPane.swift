#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import TerminalRuntime

/// The visible terminal's presentation state. Runtime ownership stays in the app's bounded
/// catalogue; switching panes neither closes nor duplicates a daemon-backed session.
@MainActor
final class WorkspaceTerminalPane {
    static var headerPixelHeight: Int { Int((PaneHeaderView.bandHeight * 2).rounded()) }

    let session: GraphicalTerminal
    private let headerWindow = NSWindow(backingScaleFactor: 2)
    private let headerRoot = NSView(frame: .zero)
    private let pageTitle = PageTitleView(symbolName: "terminal", inkSource: .backdrop)
    private var headerNeedsPresentation = true
    private var headerWidth = 0
    private var nextFrame: UInt64 = 0
    private var failure: String?
    private var failureNeedsDisplay = false
    private var size = (width: 0, height: 0)
    private var heldButtons: [Int: (x: Int, y: Int, modifiers: PTYEmulator.Modifiers)] = [:]
    private(set) var title = "Threading terminal - starting"
    var needsPolling: Bool { failure == nil }

    init(_ session: GraphicalTerminal, pageName: String, pageIdentity: String,
         icon: NSImage? = nil,
         onReveal: @escaping () -> Void) {
        self.session = session
        pageTitle.update(title: pageName, symbolName: "terminal", identity: pageIdentity)
        if let icon { pageTitle.setIcon(icon) }
        pageTitle.onReveal = onReveal
        // Linux has no session-actions menu yet. The title still reveals its navigator row.
        pageTitle.actionsAnchor.isHidden = true
        let header = PaneHeaderView(leading: [pageTitle], margin: .paneEdge)
        headerRoot.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerRoot.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerRoot.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerRoot.topAnchor)
        ])
        headerWindow.contentView = headerRoot
        headerWindow.isKeyWindow = true
        session.setPreedit(nil)
        session.invalidateFrame()
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

    private func presentHeader(window: OpaquePointer, width: Int) throws {
        guard headerNeedsPresentation || headerWidth != width else { return }
        headerNeedsPresentation = false
        headerWidth = width
        headerRoot.frame = NSRect(x: 0, y: 0, width: CGFloat(width) / 2,
                                  height: PaneHeaderView.bandHeight)
        pageTitle.maxWidth = max(0, headerRoot.bounds.width - 2 * PaneHeaderView.contentInset)
        let bitmap = Bitmap(width: width, height: Self.headerPixelHeight,
                            background: InkSource.backdropGround.components)
        headerRoot.render(in: NSGraphicsContext(bitmap: bitmap, scale: 2))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_terminal_header(window, $0.baseAddress,
                                       Int32(width), Int32(Self.headerPixelHeight))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        headerWindow.isKeyWindow = focused
        if !focused {
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
        let contentHeight = max(1, height - Self.headerPixelHeight)
        tw_workspace_terminal_top_inset(window, Int32(Self.headerPixelHeight))
        try presentHeader(window: window, width: width)
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
