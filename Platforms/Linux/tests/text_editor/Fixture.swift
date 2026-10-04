import AppKit
import Foundation

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
        let promptText = prompt.textView
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
    }
}
