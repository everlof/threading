#if os(Linux)
import Foundation
import LinuxWindowBridge
@testable import TerminalRuntime

/// The visible terminal's presentation state. Runtime ownership stays in the app's bounded
/// catalogue; switching panes neither closes nor duplicates a daemon-backed session.
@MainActor
final class WorkspaceTerminalPane {
    let session: GraphicalTerminal
    private var nextFrame: UInt64 = 0
    private var failure: String?
    private var failureNeedsDisplay = false
    private var size = (width: 0, height: 0)
    private var heldButtons: [Int: (x: Int, y: Int, modifiers: PTYEmulator.Modifiers)] = [:]
    private(set) var title = "Threading terminal - starting"
    var needsPolling: Bool { failure == nil }

    init(_ session: GraphicalTerminal) {
        self.session = session
        session.setPreedit(nil)
        session.invalidateFrame()
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        if !focused {
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
        if size.width != width || size.height != height {
            size = (width, height)
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
                                                   height: height, workspace: true, focused: focused)
            failureNeedsDisplay = false
        }
        if let frame = prepared, frame.width == width && frame.height == height {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = frame.pixels.withUnsafeBytes {
                tw_present_pane(window, $0.bindMemory(to: UInt8.self).baseAddress,
                                Int32(width), Int32(height), 0)
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
                    : height - WindowHarness.terminalCellHeight
                tw_text_input_rect(window,
                    Int32(originX + max(0, min(width - WindowHarness.terminalCellWidth, x))),
                    Int32(max(0, min(height - WindowHarness.terminalCellHeight, y))),
                    Int32(WindowHarness.terminalCellWidth), Int32(WindowHarness.terminalCellHeight))
                tw_title(window, title)
            }
            print("TERMINAL_FRAME \(width)x\(height) \(title) drawMs=\(frame.drawMilliseconds) presentMs=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
            fflush(nil)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if failure == nil && now >= nextFrame {
            session.requestFrame(width: width, height: height)
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
