import AppKit
import Foundation

@MainActor private final class KeyLoopControl: NSControl {
    override var acceptsFirstResponder: Bool { isEnabled }
}

@MainActor
private final class PlaceholderInk: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        "Describe your task".draw(
            at: NSPoint(x: 4, y: 4),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.black]
        )
    }
}

@MainActor
private final class FieldNotices: NSTextFieldDelegate {
    var began = 0, changes: [String] = [], ended: [Int] = []
    func controlTextDidBeginEditing(_ obj: Notification) { began += 1 }
    func controlTextDidChange(_ obj: Notification) {
        changes.append((obj.object as? NSTextField)?.stringValue ?? "")
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        ended.append(obj.userInfo?["NSTextMovement"] as? Int ?? -1)
    }
}

@MainActor
private final class PromptTextNotices: NSTextViewDelegate {
    let manager = UndoManager()
    var changes: [String] = []

    func undoManager(for textView: NSTextView) -> UndoManager? { manager }
    func textDidChange(_ notification: Notification) {
        changes.append((notification.object as? NSTextView)?.string ?? "")
    }
}

@main
@MainActor
enum Fixture {
    static func main() {
        let view = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 64), textContainer: nil)
        precondition(view.textContainer != nil)
        precondition(view.layoutManager != nil)
        precondition(view.textStorage != nil)
        precondition(view.textContainer?.layoutManager === view.layoutManager)
        precondition(view.layoutManager?.textStorage === view.textStorage)
        precondition(view.accessibilityRole() == .textArea)

        view.insertText("A👩‍🚀é", replacementRange: NSRange(location: 0, length: 0))
        precondition(view.string == "A👩‍🚀é")
        precondition(view.selectedRange().location == (view.string as NSString).length)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 117))
        precondition(view.string == "Aé", "forward delete must remove a whole joined emoji")
        view.undo(nil)
        precondition(view.string == "A👩‍🚀é")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.deleteBackward(nil)
        precondition(view.string == "A👩‍🚀")
        view.deleteBackward(nil)
        precondition(view.string == "A", "backspace must remove a whole joined emoji")
        view.insertText("é🙂", replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: 1, length: 1))
        view.insertText("z", replacementRange: view.selectedRange())
        precondition(view.string == "Az🙂")
        precondition(view.accessibilityValue() as? String == "Az🙂")

        let window = NSWindow()
        window.contentView = view
        precondition(window.makeFirstResponder(view))
        precondition(window.firstResponder === view)
        _ = window.makeFirstResponder(nil)
        view.mouseDown(with: NSEvent(type: .leftMouseDown, window: window,
                                     locationInWindow: NSPoint(x: 10, y: 10)))
        precondition(window.firstResponder === view, "click must focus editor")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, window: window,
                                   charactersIgnoringModifiers: "q"))
        precondition(view.string == "Az🙂q", "focused keyboard input must edit storage")
        view.keyDown(with: NSEvent(type: .keyDown, window: window, keyCode: 51))
        precondition(view.string == "Az🙂", "backspace key must edit storage")
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.string == "か" && view.hasMarkedText())
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.string == "かな" && view.markedRange().length == 2,
                     "revised preedit must replace earlier preedit")
        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.string == "仮名" && !view.hasMarkedText(),
                     "commit must replace marked text exactly once")
        view.undo(nil)
        precondition(view.string == "Az🙂", "IME commit must undo as one edit")
        view.redo(nil)
        precondition(view.string == "仮名", "IME commit must redo as one edit")
        view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(view.string == "仮名" && !view.hasMarkedText(),
                     "empty preedit must cancel provisional text")
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, window: window,
                                   modifierFlags: [.control], charactersIgnoringModifiers: "z"))
        precondition(view.string == "仮名", "Ctrl+Z must undo an edit")
        view.keyDown(with: NSEvent(type: .keyDown, window: window,
                                   modifierFlags: [.control, .shift],
                                   charactersIgnoringModifiers: "z"))
        precondition(view.string == "仮名!", "Ctrl+Shift+Z must redo an edit")

        let scroll = ThemedTextView.scrolling()
        scroll.frame = NSRect(x: 0, y: 0, width: 180, height: 58)
        scroll.textView.textContainerInset = NSSize(width: 8, height: 6)
        precondition(scroll.textView.frame.width == 180, "document width must track viewport")
        scroll.textView.string = (0..<15).map {
            "Line \($0) 🙂 wraps here and keeps going for quite some time"
        }.joined(separator: "\n")
        let used = scroll.textView.layoutManager!.usedRect(for: scroll.textView.textContainer!)
        precondition(used.height > scroll.frame.height, "text must grow beyond the viewport")
        precondition(scroll.textView.frame.height >= used.height, "document must grow to text")
        scroll.textView.setSelectedRange(NSRange(location: (scroll.textView.string as NSString).length,
                                                length: 0))
        precondition(scroll.contentView.bounds.minY > 0, "caret must scroll into view")
        let tallHeight = scroll.textView.frame.height
        scroll.frame.size.width = 360
        let wideHeight = scroll.textView.layoutManager!.usedRect(for: scroll.textView.textContainer!).height
        precondition(wideHeight < tallHeight, "wider viewport must reflow text")
        scroll.textView.insertText("\nTail", replacementRange: NSRange(
            location: (scroll.textView.string as NSString).length, length: 0))
        let appendedHeight = scroll.textView.layoutManager!.usedRect(for: scroll.textView.textContainer!).height
        precondition(appendedHeight > wideHeight, "incremental edit must grow layout")
        let endSelection = scroll.textView.selectedRange().location
        scroll.textView.keyDown(with: NSEvent(type: .keyDown, keyCode: 82))
        precondition(scroll.textView.selectedRange().location < endSelection,
                     "SDL up arrow must move through visual lines")

        let prompt = PromptTextView.scrollingPrompt()
        prompt.frame = NSRect(x: 0, y: 0, width: 180, height: 58)
        precondition(!prompt.hasVerticalScroller,
                     "production prompt hides the scroll chrome")
        prompt.textView.string = (0..<15).map { "Prompt line \($0) 🙂" }.joined(separator: "\n")
        prompt.textView.setSelectedRange(NSRange(
            location: (prompt.textView.string as NSString).length, length: 0))
        precondition(prompt.contentView.bounds.minY > 0,
                     "production prompt must reveal its caret in a fixed-height viewport")
        let promptWindow = NSWindow()
        promptWindow.contentView = prompt
        precondition(promptWindow.makeFirstResponder(prompt.textView))
        let tailOrigin = prompt.contentView.bounds.origin
        let tailSelection = prompt.textView.selectedRange()
        promptWindow.dispatchToContent(NSEvent(type: .scrollWheel,
            locationInWindow: NSPoint(x: 90, y: 29), scrollingDeltaY: 2.5))
        precondition(prompt.contentView.bounds.minY == tailOrigin.y - 25,
                     "wheel hit on prompt text must reach its enclosing clip viewport")
        precondition(prompt.textView.selectedRange() == tailSelection,
                     "scrolling must preserve the caret")
        promptWindow.dispatchToContent(NSEvent(type: .scrollWheel,
            locationInWindow: NSPoint(x: 90, y: 29), scrollingDeltaY: -2.5))
        precondition(prompt.contentView.bounds.origin == tailOrigin,
                     "opposite wheel input must return to the same viewport")
        promptWindow.dispatchToContent(NSEvent(type: .scrollWheel,
            locationInWindow: NSPoint(x: 90, y: 29), scrollingDeltaY: 1000))
        precondition(prompt.contentView.bounds.minY == 0,
                     "wheel input must clamp at the document start")
        prompt.textView.insertText("!", replacementRange: tailSelection)
        precondition(prompt.contentView.bounds.minY > 0,
                     "typing after a scroll must reveal the retained caret again")
        let promptText = prompt.textView
        promptText.string = "Short draft"
        prompt.frame.size.height = 20
        let shortUsed = promptText.textUsedRect
        prompt.frame.size.height = 100
        precondition(promptText.frame.height == 100,
                     "height-only viewport growth must extend the cached document hit area")
        precondition(promptText.textUsedRect == shortUsed,
                     "height-only growth must preserve text layout")
        promptWindow.makeFirstResponder(nil)
        promptWindow.dispatchToContent(NSEvent(type: .leftMouseDown,
            locationInWindow: NSPoint(x: 90, y: 50)))
        promptWindow.dispatchToContent(NSEvent(type: .leftMouseUp,
            locationInWindow: NSPoint(x: 90, y: 50)))
        precondition(promptWindow.firstResponder === promptText,
                     "blank viewport below a short draft must take typing focus after growth")
        var submitIntents: [PromptSubmitIntent] = []
        promptText.onSubmit = { submitIntents.append($0) }
        promptText.string = "Draft"
        promptText.setSelectedRange(NSRange(location: 5, length: 0))
        promptText.submitsOnReturn = { true }
        promptText.keyDown(with: NSEvent(type: .keyDown, keyCode: 36,
                                        charactersIgnoringModifiers: "\n"))
        precondition(submitIntents == [.standard] && promptText.string == "Draft",
                     "bare Return must submit without changing the draft")
        promptText.keyDown(with: NSEvent(type: .keyDown, modifierFlags: [.command],
                                        keyCode: 36, charactersIgnoringModifiers: "\n"))
        precondition(submitIntents == [.standard, .immediate],
                     "Command-Return must request immediate submit")
        promptText.keyDown(with: NSEvent(type: .keyDown, modifierFlags: [.shift],
                                        keyCode: 36, charactersIgnoringModifiers: "\n"))
        precondition(promptText.string == "Draft\n" && submitIntents.count == 2,
                     "Shift-Return must insert a newline without submitting")
        promptText.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        promptText.keyDown(with: NSEvent(type: .keyDown, keyCode: 36,
                                        charactersIgnoringModifiers: "\n"))
        precondition(promptText.hasMarkedText() && promptText.string == "Draft\nか"
                     && submitIntents.count == 2,
                     "IME Return must wait for committed text instead of sending or inserting")
        promptText.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(promptText.string == "Draft\n仮名" && !promptText.hasMarkedText(),
                     "the committed IME candidate must replace provisional text once")
        promptText.submitsOnReturn = { false }
        promptText.keyDown(with: NSEvent(type: .keyDown, keyCode: 36,
                                        charactersIgnoringModifiers: "\n"))
        precondition(promptText.string == "Draft\n仮名\n" && submitIntents.count == 2,
                     "an external-submit composer must use bare Return for a newline")
        promptText.keyDown(with: NSEvent(type: .keyDown, keyCode: 36,
                                        charactersIgnoringModifiers: "\r"))
        precondition(promptText.string == "Draft\n仮名\n\n",
                     "native Return characters must insert a newline, not a carriage return")

        verifyKeyLoop()
        verifyNavigationKeys()
        verifyEditableField()
        verifyPromptTextDelegate()

        let paint = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 40),
                                   textContainer: nil)
        paint.string = "Ink selected"
        paint.setSelectedRange(NSRange(location: 4, length: 8))
        let bitmap = Bitmap(width: 180, height: 40, background: (1, 1, 1, 1))
        paint.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        let colored = stride(from: 0, to: bitmap.pixels.count, by: 4).reduce(0) { count, index in
            let red = bitmap.pixels[index], green = bitmap.pixels[index + 1]
            let blue = bitmap.pixels[index + 2]
            return count + (red < 245 || green < 245 || blue < 245 ? 1 : 0)
        }
        precondition(colored > 100, "Pango text and selection must paint pixels")
        let placeholder = PlaceholderInk(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        let placeholderBitmap = Bitmap(width: 180, height: 40, background: (1, 1, 1, 1))
        placeholder.render(in: NSGraphicsContext(bitmap: placeholderBitmap, scale: 1))
        let placeholderInk = stride(from: 0, to: placeholderBitmap.pixels.count, by: 4)
            .reduce(0) { count, index in
                count + (placeholderBitmap.pixels[index] < 245 ? 1 : 0)
            }
        precondition(placeholderInk > 50,
                     "a Swift String placeholder must draw through the AppKit shim")
        let placeholderOutput = URL(fileURLWithPath: "/repo/Platforms/Linux/out/text-editor-placeholder.png")
        try! PNGWriter.write(placeholderBitmap, to: placeholderOutput)
        let output = URL(fileURLWithPath: "/repo/Platforms/Linux/out/text-editor-fixture.png")
        try! PNGWriter.write(bitmap, to: output)
        print("text editor fixture passed; rendered \(output.path)")
        if ProcessInfo.processInfo.environment["THREADING_EDITOR_SCROLL_BENCHMARK"] == "1" {
            benchmarkScroll(lineCount: 170)
            benchmarkScroll(lineCount: 1700)
        }
    }

    /// AppKit's editable field: focus lands on its field editor, edits notify the delegate,
    /// Return sends the action and keeps editing, Tab moves on and commits, and the editor leaves.
    private static func verifyEditableField() {
        let window = NSWindow(backingScaleFactor: 1)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let field = NSTextField(string: "")
        let next = KeyLoopControl()
        let notices = FieldNotices()
        var actions = 0
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 22)
        field.placeholderString = "Write your answer…"
        field.delegate = notices
        field.action = { actions += 1 }
        field.nextKeyView = next
        next.nextKeyView = field
        root.addSubview(field)
        root.addSubview(next)
        window.contentView = root
        precondition(field.isEditable && field.isSelectable,
                     "editable=\(field.isEditable) selectable=\(field.isSelectable)")
        precondition(field.accessibilityRole() == .textField, "role \(String(describing: field.accessibilityRole()))")
        precondition(field.intrinsicContentSize.width == NSView.noIntrinsicMetric,
                     "an editable field takes its width from layout")

        let empty = Bitmap(width: 240, height: 80, background: (1, 1, 1, 1))
        root.render(in: NSGraphicsContext(bitmap: empty, scale: 1))
        let placeholderInk = empty.pixels.indices.filter { $0 % 4 == 0 && empty.pixels[$0] < 245 }.count
        precondition(placeholderInk > 20, "an empty field draws its placeholder")

        precondition(window.makeFirstResponder(field))
        guard let editor = window.firstResponder as? NSTextView else {
            preconditionFailure("focusing an editable field focuses its field editor")
        }
        precondition(field.currentEditor() === editor && editor.superview === field)
        editor.insertText("Line one\nline two", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(field.stringValue == "Line one line two", "a single-line field turns a break into a space")
        precondition(notices.began == 1 && notices.changes == ["Line one line two"], "\(notices.changes)")
        editor.keyDown(with: NSEvent(type: .keyDown, window: window, keyCode: 36))
        precondition(actions == 1 && notices.ended == [NSTextMovement.return.rawValue],
                     "Return sends the action and ends this edit")
        precondition(window.firstResponder === editor && editor.selectedRange().length == 17,
                     "Return keeps the editor with its text selected")
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: NSEvent(type: .keyDown, window: window, keyCode: 48))
        precondition(window.firstResponder === next, "Tab moves to the next key view")
        precondition(field.currentEditor() == nil && editor.superview == nil, "the editor leaves when editing ends")
        precondition(field.stringValue == "é" && notices.began == 2
                     && notices.ended.last == NSTextMovement.tab.rawValue, "\(notices.ended)")

        precondition(window.makeFirstResponder(field))
        precondition(field.abortEditing() && field.currentEditor() == nil && window.firstResponder !== field)
        print("PASS editable NSTextField: field editor focus, delegate notices, single line, Return, Tab and abort")
    }

    private static func verifyPromptTextDelegate() {
        let view = ThemedTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 40),
                                  textContainer: nil)
        let notices = PromptTextNotices()
        view.delegate = notices
        view.allowsUndo = true
        view.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        precondition(notices.changes == ["draft"], "the composer delegate missed an edit")
        view.breakUndoCoalescing()
        notices.manager.removeAllActions()
        view.undo(nil)
        precondition(view.string == "draft", "a replaced draft kept a stale undo action")
        view.string = "new"
        precondition(notices.changes == ["draft"], "programmatic replacement notified the delegate")
        view.insertText("!", replacementRange: NSRange(location: 3, length: 0))
        view.undo(nil)
        precondition(view.string == "new" && notices.changes == ["draft", "new!", "new"],
                     "the new draft did not own its undo and change notices")
        print("PASS prompt text delegate and draft undo ownership")
    }

    private static func verifyKeyLoop() {
        let window = NSWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let first = KeyLoopControl(), second = KeyLoopControl(), submit = KeyLoopControl()
        let editor = PromptTextView(frame: .zero, textContainer: nil)
        for view in [first, second, editor, submit] { root.addSubview(view) }
        first.nextKeyView = second
        second.nextKeyView = editor
        editor.nextKeyView = submit
        submit.nextKeyView = first
        window.contentView = root
        window.initialFirstResponder = editor
        window.selectNextKeyView(nil)
        precondition(window.firstResponder === editor)
        submit.isEnabled = false
        window.selectNextKeyView(nil)
        precondition(window.firstResponder === first, "disabled submit must leave the loop")
        window.selectPreviousKeyView(nil)
        precondition(window.firstResponder === editor, "reverse traversal must skip disabled submit")
        second.isHidden = true
        window.selectPreviousKeyView(nil)
        precondition(window.firstResponder === first, "hidden choices must leave the loop")
        second.isHidden = false
        second.removeFromSuperview()
        window.selectNextKeyView(nil)
        precondition(window.firstResponder === editor, "detached choices must leave the loop")
        first.isEnabled = false
        window.selectNextKeyView(nil)
        precondition(window.firstResponder === editor, "a single eligible member keeps focus")
        editor.isEditable = false
        editor.isSelectable = false
        precondition(editor.nextValidKeyView == nil && editor.previousValidKeyView == nil,
                     "an ineligible cycle must terminate")
        print("PASS explicit key-view loop: forward/reverse, disabled, hidden, detached and empty")
    }

    private static func verifyNavigationKeys() {
        let prompt = PromptTextView.scrollingPrompt()
        prompt.frame = NSRect(x: 0, y: 0, width: 360, height: 58)
        let view = prompt.textView
        let second = "Second👩‍🚀line"
        let first = "One🙂\n"
        let source = first + second + "\nLast"
        view.string = source
        let start = first.utf16.count
        view.setSelectedRange(NSRange(location: start + 4, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 115))
        precondition(view.selectedRange().location == start, "Home must reach the visual line start")
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 119))
        precondition(view.selectedRange().location == start + second.utf16.count,
                     "End must reach the visual line end without inserting a control byte")
        view.keyDown(with: NSEvent(type: .keyDown, modifierFlags: [.control], keyCode: 115))
        precondition(view.selectedRange().location == 0, "Ctrl+Home must reach the document start")
        view.keyDown(with: NSEvent(type: .keyDown, modifierFlags: [.control, .shift], keyCode: 119))
        precondition(view.selectedRange() == NSRange(location: 0, length: source.utf16.count),
                     "Ctrl+Shift+End must extend selection through joined Unicode")
        precondition(view.string == source, "navigation must preserve the draft")
        let longLine = "0123👩‍🚀5678"
        view.string = longLine + "\nx\n" + longLine
        let column = "0123👩‍🚀5".utf16.count
        view.setSelectedRange(NSRange(location: column, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 125))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 125))
        precondition(view.selectedRange().location == longLine.utf16.count + 3 + column,
                     "vertical navigation must retain its Unicode column across a short line")
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 126))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 126))
        precondition(view.selectedRange().location == column,
                     "vertical round trip must not shift the caret left")
        view.string = (0..<40).map { "Line \($0)" }.joined(separator: "\n")
        let length = view.string.utf16.count
        view.setSelectedRange(NSRange(location: length, length: 0))
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 116))
        precondition(view.selectedRange().location < length, "Page Up must move through visual lines")
        view.keyDown(with: NSEvent(type: .keyDown, keyCode: 121))
        precondition(view.selectedRange().location == length, "Page Down must reach the original tail")
        print("PASS Unicode line/document boundaries and viewport-sized page navigation")
    }

    /// Manufacture and layout are measured separately. Warm scroll/draw must visit only the
    /// fixed viewport, with 170 typical or 1,700 stress lines and no text or width mutation.
    private static func benchmarkScroll(lineCount: Int) {
        let start = ProcessInfo.processInfo.systemUptime
        let prompt = PromptTextView.scrollingPrompt()
        prompt.frame = NSRect(x: 0, y: 0, width: 180, height: 58)
        prompt.textView.string = (0..<lineCount).map { "Line \($0) scroll" }.joined(separator: "\n")
        let height = prompt.textView.textUsedRect.height
        let prepared = ProcessInfo.processInfo.systemUptime - start
        let bitmap = Bitmap(width: 180, height: 58, background: (1, 1, 1, 1))
        let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
        var samples: [Double] = []
        for sample in 0..<35 {
            let before = ProcessInfo.processInfo.systemUptime
            prompt.contentView.scroll(to: NSPoint(x: 0,
                y: max(0, height - 58) * CGFloat(sample % 3) / 2))
            prompt.render(in: context)
            if sample >= 5 {
                samples.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            }
        }
        samples.sort()
        print(String(format: "EDITOR_SCROLL lines=%d prepare_ms=%.2f median_ms=%.2f p95_ms=%.2f max_ms=%.2f",
            lineCount, prepared * 1000, samples[samples.count / 2],
            samples[Int(Double(samples.count - 1) * 0.95)], samples.last!))
    }
}
