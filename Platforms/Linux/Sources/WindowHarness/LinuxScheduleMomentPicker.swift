#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge

/// Drives the shared custom-time sheet body in a separate SDL window while the workspace
/// continues polling its bounded workers. The durable snooze decision stays in the parent.
@MainActor
enum LinuxScheduleMomentPicker {
    static func runSnooze() throws -> Date? {
        try WorkspaceDisplay.configureForApp()
        NSFont.prepareSystemFonts()
        LinuxTheme.setDark(ProcessInfo.processInfo.environment["THREADING_LINUX_PROMPT_DARK"] == "1")

        let scale = WorkspaceDisplay.scale
        let view = ScheduleMomentPickerView(
            title: L10n.string("Snooze session"),
            note: ScheduleMomentPickerStrings.note(
                L10n.string("The session keeps running while snoozed."), locale: .current),
            confirmTitle: L10n.string("Snooze"))
        view.appearance = LinuxTheme.appearance
        let size = view.frame.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let native = tw_open("Snooze session", Int32(width), Int32(height)) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        guard tw_prompt_mode(native) == 0 else {
            throw WindowFailure("Could not enable input for Snooze session.")
        }
        tw_title(native, "Snooze session")

        let window = NSWindow(backingScaleFactor: scale)
        window.contentView = view
        var finished = false
        var answer: Date?
        view.onConfirm = { date in answer = date; finished = true }
        view.onCancel = { finished = true }

        var needsPresentation = true
        var pressing = false
        while !finished {
            if needsPresentation {
                let bitmap = Bitmap(width: width, height: height,
                                    background: LinuxTheme.components("surface"))
                view.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    tw_present(native, $0.baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                needsPresentation = false
            }

            var event = TWEvent()
            guard tw_next(native, &event) == 1 else {
                throw WindowFailure(String(cString: tw_error()))
            }
            switch event.kind {
            case 1:
                needsPresentation = true
            case 5:
                finished = true
            case 7:
                guard event.action != 3 else { continue }
                let key = WindowHarness.composerKeyEvent(event)
                if ProcessInfo.processInfo.environment["THREADING_LINUX_PICKER_TRACE"] == "1" {
                    FileHandle.standardError.write(Data(
                        "PICKER_KEY raw=\(event.key) mapped=\(key.keyCode) action=\(event.action)\n".utf8))
                }
                switch key.keyCode {
                case 53: finished = true
                case 36, 76:
                    if let selected = view.selectedMoment {
                        answer = selected
                        finished = true
                    }
                case 125: view.moveSelection(by: 1)
                case 126: view.moveSelection(by: -1)
                case 48, 123, 124: view.switchColumn()
                default: break
                }
                needsPresentation = true
            case 15, 17, 16:
                let type: NSEvent.EventType
                if event.kind == 16 { type = .scrollWheel }
                else if event.kind == 17 { type = pressing ? .leftMouseDragged : .mouseMoved }
                else {
                    pressing = event.action == 1
                    type = pressing ? .leftMouseDown : .leftMouseUp
                }
                let point = NSPoint(x: CGFloat(event.x) / scale,
                    y: size.height - CGFloat(event.y) / scale)
                _ = window.dispatchToContent(NSEvent(type: type, locationInWindow: point,
                    scrollingDeltaY: event.kind == 16 ? CGFloat(event.key) : 0))
                needsPresentation = true
            case 45:
                if event.action == 0 { window.cancelPointerGesture(); pressing = false }
                needsPresentation = true
            default: break
            }
        }
        return answer
    }
}
#endif
