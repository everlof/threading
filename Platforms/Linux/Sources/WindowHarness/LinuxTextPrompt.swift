#if os(Linux)
import AppKit
import Foundation
import LinuxWindowBridge
@testable import CoreSlice

/// Runs one design-system text prompt in its own SDL process. The importing window can keep
/// pumping while the worker waits for this process, as it does for the system folder picker.
@MainActor
enum LinuxTextPrompt {
    private struct Request {
        let prompt: TextPromptRequest
        let identity: String
        let fieldID: String
        let fieldDescription: String
        var suppressionPrompt: ConfirmationPrompt? = nil
        var showsField = true
        var warning = false

        var title: String { prompt.title }
        var message: String { prompt.message ?? "" }
        var placeholder: String { prompt.placeholder }
        var confirmTitle: String { prompt.confirmTitle }
        var current: String { prompt.current }
        var clearTitle: String? { prompt.clearTitle }
        var allowsEmpty: Bool { prompt.allowsEmpty }
    }

    static func runWorktree() throws -> String? {
        try run(Request(prompt: WorktreePromptSpec.request,
            identity: "linux.prompt.worktree", fieldID: "linux.prompt.branch",
            fieldDescription: "Branch for the new worktree."))
    }

    static func runRename(displayTitle: String, currentTitle: String) throws -> String? {
        let prompt = TextPromptRequest(
            title: "Rename Session", message: nil, confirmTitle: "Rename",
            clearTitle: currentTitle.isEmpty ? nil : "Use Agent's Name",
            current: currentTitle, placeholder: displayTitle, allowsEmpty: true)
        return try run(Request(prompt: prompt,
            identity: "linux.prompt.rename-session", fieldID: "linux.prompt.session-name",
            fieldDescription: "Custom session name. Leave empty to use the agent's name."))
    }

    static func runConfirmation(title: String, message: String,
                                confirmTitle: String) throws -> Bool {
        let prompt = TextPromptRequest(title: title, message: message,
                                       confirmTitle: confirmTitle, allowsEmpty: true)
        return try run(Request(prompt: prompt,
            identity: "linux.prompt.close-session", fieldID: "", fieldDescription: "",
            suppressionPrompt: .closeRunningSession,
            showsField: false, warning: true)) != nil
    }

    private static func run(_ request: Request) throws -> String? {
        try WorkspaceDisplay.configureForApp()
        NSFont.prepareSystemFonts()
        LinuxTheme.setDark(ProcessInfo.processInfo.environment["THREADING_LINUX_PROMPT_DARK"] == "1")

        let view = LinuxThemedTextPromptView(
            title: request.title, message: request.message,
            placeholder: request.placeholder, confirmTitle: request.confirmTitle,
            cancelTitle: request.prompt.cancelTitle,
            current: request.current, clearTitle: request.clearTitle,
            showsField: request.showsField, warning: request.warning,
            suppressionTitle: request.suppressionPrompt == nil ? nil : "Don't ask again")
        view.appearance = LinuxTheme.appearance
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let scale = WorkspaceDisplay.scale
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let native = tw_open(request.title, Int32(width), Int32(height)) else {
            throw WindowFailure(String(cString: tw_error()))
        }
        defer { tw_close(native) }
        guard tw_prompt_mode(native) == 0 else {
            throw WindowFailure("Could not enable text input for \(request.title).")
        }
        tw_title(native, request.title)
        NSPasteboard.general.writeString = { text in
            let bytes = Array(text.utf8)
            return bytes.withUnsafeBufferPointer {
                tw_clipboard_write($0.baseAddress, Int32($0.count)) == 0
            }
        }
        NSPasteboard.general.readString = {
            var bytes = [UInt8](repeating: 0, count: 4_096)
            let count = bytes.withUnsafeMutableBufferPointer {
                tw_clipboard_read($0.baseAddress, Int32($0.count))
            }
            return count >= 0 ? String(bytes: bytes.prefix(Int(count)), encoding: .utf8) : nil
        }

        let window = NSWindow(backingScaleFactor: scale)
        window.contentView = view
        window.initialFirstResponder = view.initialResponder
        _ = window.makeFirstResponder(view.initialResponder)

        var finished = false
        var answer: String?
        view.onConfirm = {
            let value = request.showsField
                ? view.inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if request.allowsEmpty || !value.isEmpty {
                if let prompt = request.suppressionPrompt, view.suppressionChecked {
                    LinuxConfirmationSettings.setAsks(false, before: prompt)
                }
                answer = value
            }
            finished = true
        }
        view.onCancel = { finished = true }
        view.onClear = { answer = ""; finished = true }

        var needsPresentation = true
        var pressing = false
        while !finished {
            if needsPresentation {
                let bitmap = Bitmap(width: width, height: height,
                                    background: LinuxTheme.components("floatingSurface"))
                view.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
                let result = bitmap.pixels.withUnsafeBufferPointer {
                    tw_present(native, $0.baseAddress, Int32(width), Int32(height))
                }
                guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
                if request.showsField {
                    let field = view.inputField.convert(view.inputField.bounds, to: view)
                    tw_text_input_rect(native, Int32(field.minX * scale),
                                       Int32((size.height - field.maxY) * scale),
                                       Int32(field.width * scale), Int32(field.height * scale))
                }
                publishAccessibility(native: native, view: view, window: window,
                                     scale: scale, request: request)
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
            case 6:
                guard request.showsField else { continue }
                handleText(&event, field: view.inputField, native: native)
                needsPresentation = true
            case 7:
                guard event.action != 3 else { continue }
                let key = WindowHarness.composerKeyEvent(event)
                if key.keyCode == 53 { finished = true }
                else if key.keyCode == 36 && view.focusKind(in: window) != 4 {
                    view.onConfirm?()
                }
                else { _ = window.dispatchToContent(key) }
                needsPresentation = true
            case 14:
                guard request.showsField else { continue }
                paste(field: view.inputField, native: native)
                needsPresentation = true
            case 18:
                guard request.showsField else { continue }
                (view.inputField.currentEditor() as? NSTextView)?.copy(nil)
            case 15:
                guard event.key == 0 else { continue }
                pressing = event.action == 1
                let type: NSEvent.EventType = pressing ? .leftMouseDown : .leftMouseUp
                _ = window.dispatchToContent(pointer(type, event: event, size: size, scale: scale))
                needsPresentation = true
            case 17:
                let type: NSEvent.EventType = pressing ? .leftMouseDragged : .mouseMoved
                _ = window.dispatchToContent(pointer(type, event: event, size: size, scale: scale))
                needsPresentation = true
            case 19:
                guard request.showsField else { continue }
                updatePreedit(&event, field: view.inputField)
                needsPresentation = true
            case 49:
                guard request.showsField else { continue }
                applyAccessibilityEdit(event, native: native,
                                       field: view.inputField, window: window,
                                       identity: request.identity)
                needsPresentation = true
            case 61:
                if event.action == 0 { view.onCancel?() }
                else if event.action == 1 { view.onConfirm?() }
                else if event.action == 2 { view.onClear?() }
            case 45:
                if event.action == 0 { window.cancelPointerGesture(); pressing = false }
                needsPresentation = true
            default: break
            }
        }
        return answer
    }

    private static func pointer(_ type: NSEvent.EventType, event: TWEvent,
                                size: NSSize, scale: CGFloat) -> NSEvent {
        NSEvent(type: type, locationInWindow: NSPoint(x: CGFloat(event.x) / scale,
            y: size.height - CGFloat(event.y) / scale))
    }

    private static func publishAccessibility(native: OpaquePointer,
                                             view: LinuxThemedTextPromptView,
                                             window: NSWindow, scale: CGFloat,
                                             request: Request) {
        let value = request.showsField ? view.inputField.stringValue : ""
        guard value.utf8.count <= 4_096 else { return }
        let selection = (view.inputField.currentEditor() as? NSTextView)?.selectedRange()
            ?? NSRange(location: (value as NSString).length, length: 0)
        let first = scalarOffset(selection.location, in: value)
        let last = scalarOffset(NSMaxRange(selection), in: value)
        let field = pixelFrame(view.inputField.frame, height: view.bounds.height, scale: scale)
        let cancel = pixelFrame(view.cancelFrame, height: view.bounds.height, scale: scale)
        let confirm = pixelFrame(view.confirmFrame, height: view.bounds.height, scale: scale)
        let titleFrame = pixelFrame(view.titleFrame, height: view.bounds.height, scale: scale)
        let messageFrame = view.messageFrame.map {
            pixelFrame($0, height: view.bounds.height, scale: scale)
        } ?? (0, 0, 0, 0)
        let clear = view.clearFrame.map {
            pixelFrame($0, height: view.bounds.height, scale: scale)
        } ?? (0, 0, 0, 0)
        request.identity.withCString { identity in
            request.fieldID.withCString { fieldID in
                request.fieldDescription.withCString { fieldDescription in
                    request.confirmTitle.withCString { confirmTitle in
                        (request.clearTitle ?? "").withCString { clearTitle in
                            request.title.withCString { heading in
                                request.message.withCString { explanation in
                                    request.placeholder.withCString { fieldLabel in
                                        value.withCString { text in
                                            tw_accessibility_text_prompt(native, identity, fieldID,
                                                fieldLabel, fieldDescription, heading, explanation,
                                                confirmTitle, clearTitle, text,
                                                Int32(value.utf8.count), Int32(first), Int32(last),
                                                view.focusKind(in: window),
                                                titleFrame.x, titleFrame.y,
                                                titleFrame.width, titleFrame.height,
                                                messageFrame.0, messageFrame.1,
                                                messageFrame.2, messageFrame.3,
                                                field.x, field.y, field.width, field.height,
                                                cancel.x, cancel.y, cancel.width, cancel.height,
                                                confirm.x, confirm.y, confirm.width, confirm.height,
                                                clear.0, clear.1, clear.2, clear.3)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func pixelFrame(_ frame: NSRect, height: CGFloat, scale: CGFloat)
        -> (x: Int32, y: Int32, width: Int32, height: Int32) {
        (Int32(frame.minX * scale), Int32((height - frame.maxY) * scale),
         Int32(frame.width * scale), Int32(frame.height * scale))
    }

    private static func scalarOffset(_ utf16: Int, in text: String) -> Int {
        let source = text as NSString
        return source.substring(to: min(max(0, utf16), source.length)).unicodeScalars.count
    }

    private static func textRange(start: Int, end: Int, in text: String) -> NSRange? {
        let scalars = Array(text.unicodeScalars)
        guard start >= 0, end >= start, end <= scalars.count else { return nil }
        let lower = scalars[..<start].reduce(0) { $0 + String($1).utf16.count }
        let upper = scalars[start..<end].reduce(lower) { $0 + String($1).utf16.count }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func applyAccessibilityEdit(_ event: TWEvent, native: OpaquePointer,
                                               field: ThemedTextField, window: NSWindow,
                                               identity expectedIdentity: String) {
        var operation: Int32 = 0
        var start: Int32 = 0
        var end: Int32 = 0
        var identity = [CChar](repeating: 0, count: 128)
        var payload = [CChar](repeating: 0, count: 65_537)
        let count = tw_accessibility_take_composer_edit(native, event.key,
            &operation, &start, &end, &identity, Int32(identity.count),
            &payload, Int32(payload.count))
        guard count >= 0,
              String(bytes: identity.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                     encoding: .utf8) == expectedIdentity,
              let replacement = String(bytes: payload.prefix(Int(count)).map(UInt8.init(bitPattern:)),
                                       encoding: .utf8) else { return }
        _ = window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView,
              let range = textRange(start: Int(start), end: Int(end), in: editor.string) else { return }
        let source = editor.string as NSString
        switch operation {
        case 1:
            guard source.replacingCharacters(in: range, with: replacement).utf8.count <= 4_096
            else { return }
            editor.insertText(replacement, replacementRange: range)
        case 2:
            editor.setSelectedRange(range)
        case 3, 4:
            guard range.length > 0 else { return }
            guard NSPasteboard.general.setString(source.substring(with: range), forType: .string)
            else { return }
            if operation == 4 { editor.insertText("", replacementRange: range) }
        case 5:
            guard let pasted = NSPasteboard.general.string(forType: .string),
                  source.replacingCharacters(in: range, with: pasted).utf8.count <= 4_096
            else { return }
            editor.insertText(pasted, replacementRange: range)
        default: break
        }
    }

    private static func handleText(_ event: inout TWEvent, field: ThemedTextField,
                                   native: OpaquePointer) {
        guard let text = String(validatingCString: tw_event_text(&event)),
              let editor = field.currentEditor() as? NSTextView else { return }
        switch text {
        case "\u{01}": editor.selectAll(nil)
        case "\u{03}": editor.copy(nil)
        case "\u{16}": paste(field: field, native: native)
        default: editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    private static func paste(field: ThemedTextField, native: OpaquePointer) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBufferPointer {
            tw_clipboard_read($0.baseAddress, Int32($0.count))
        }
        guard count >= 0, let value = String(bytes: bytes.prefix(Int(count)), encoding: .utf8)
        else { return }
        editor.insertText(value, replacementRange: editor.selectedRange())
    }

    private static func updatePreedit(_ event: inout TWEvent, field: ThemedTextField) {
        guard let text = String(validatingCString: tw_event_text(&event)),
              let editor = field.currentEditor() as? NSTextView else { return }
        let lengths = text.unicodeScalars.map { String($0).utf16.count }
        let start = min(max(0, Int(event.textCursor)), lengths.count)
        let end = min(max(start, start + Int(event.textSelectionLength)), lengths.count)
        editor.setMarkedText(text,
            selectedRange: NSRange(location: lengths.prefix(start).reduce(0, +),
                                   length: lengths[start..<end].reduce(0, +)),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
#endif
