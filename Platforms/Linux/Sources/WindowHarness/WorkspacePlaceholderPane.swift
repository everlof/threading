#if os(Linux)
import AppKit
import Foundation
import Glibc
import LinuxWindowBridge

/// The idle workspace's bounded production content view. It keeps one view tree and texture
/// while project rows change, and repaints only for resize or interaction.
@MainActor
final class WorkspacePlaceholderPane {
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var actionTitle = ""

    private let window = NSWindow(backingScaleFactor: 2)
    private let placeholderRoot = SessionPlaceholderView(frame: .zero)
    private let composerRoot = NSView(frame: .zero)
    private let composerHero = SessionPlaceholderView(frame: .zero)
    private let composerEditor = PromptTextView.scrollingPrompt()
    private var showsComposer = false
    private(set) var composerIdentity: String?
    private var root: NSView { showsComposer ? composerRoot : placeholderRoot }
    private var actionAnchor: ThemedButton {
        showsComposer ? composerHero.actionAnchor : placeholderRoot.actionAnchor
    }
    private var presentedSize = NSSize.zero
    private var needsPresentation = true

    init(hasProjects: Bool, onAction: @escaping () -> Void,
         onSubmit: @escaping () -> Void) {
        NSImage.systemSymbolProvider = { name, _ in
            Design.Symbol.image(name, slot: PlaceholderDefaults.iconSize,
                                pointSize: 36, weight: .regular)
        }
        placeholderRoot.onAction = onAction
        composerHero.onAction = onAction
        composerRoot.addSubview(composerHero)
        composerRoot.addSubview(composerEditor)
        composerEditor.textView.placeholder = "Describe a task or ask a question"
        composerEditor.textView.submitsOnReturn = { false }
        composerEditor.textView.onSubmit = { _ in onSubmit() }
        composerEditor.textView.drawsBackground = true
        composerEditor.textView.backgroundColor = LinuxTheme.color("fieldSurface")
        composerEditor.textView.textContainerInset = NSSize(width: 10, height: 8)
        window.contentView = placeholderRoot
        setThemeAppearance()
        configure(hasProjects: hasProjects)
    }

    func setThemeAppearance() {
        placeholderRoot.appearance = LinuxTheme.appearance
        composerRoot.appearance = LinuxTheme.appearance
        needsPresentation = true
    }

    func configure(hasProjects: Bool) {
        showsComposer = false
        composerIdentity = nil
        window.contentView = placeholderRoot
        title = hasProjects ? "No Session Selected" : "No Projects Yet"
        detail = hasProjects ? "Select a session in the sidebar, or start one here."
                             : "Add a project folder to start a session."
        actionTitle = hasProjects ? "New Session" : "Add Project"
        placeholderRoot.configure(symbolName: "terminal", title: title, detail: detail,
                       actionTitle: actionTitle)
        needsPresentation = true
    }

    func showComposer(projectName: String, providerName: String) {
        showsComposer = true
        composerIdentity = UUID().uuidString
        title = "Start a \(providerName) session"
        detail = "In \(projectName). Write a brief below."
        actionTitle = "Start Session"
        composerHero.configure(symbolName: "terminal", title: title, detail: detail,
                               actionTitle: actionTitle)
        composerEditor.textView.string = ""
        window.contentView = composerRoot
        _ = window.makeFirstResponder(composerEditor.textView)
        needsPresentation = true
    }

    var isComposing: Bool { showsComposer }
    var editorHasFocus: Bool { showsComposer && window.firstResponder === composerEditor.textView }
    var composedPrompt: String { composerEditor.textView.string }

    func focusEditor() {
        guard showsComposer else { return }
        _ = window.makeFirstResponder(composerEditor.textView)
        needsPresentation = true
    }

    func focusAction() {
        guard showsComposer else { return }
        _ = window.makeFirstResponder(actionAnchor)
        needsPresentation = true
    }

    func selectAllText() {
        guard showsComposer else { return }
        let length = (composerEditor.textView.string as NSString).length
        composerEditor.textView.setSelectedRange(NSRange(location: 0, length: length))
        needsPresentation = true
    }

    var selectedText: String? {
        guard showsComposer else { return nil }
        let range = composerEditor.textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (composerEditor.textView.string as NSString).substring(with: range)
    }

    func deleteSelection() {
        guard showsComposer else { return }
        composerEditor.textView.insertText("",
            replacementRange: composerEditor.textView.selectedRange())
        needsPresentation = true
    }

    func insertCommittedText(_ text: String) {
        guard showsComposer else { return }
        composerEditor.textView.insertText(text,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        needsPresentation = true
    }

    /// Apply a bounded AT-SPI edit to the same TextKit view that handles keyboard input.
    /// AT-SPI offsets count Unicode scalars; TextKit replacement ranges count UTF-16 units.
    @discardableResult
    func applyAccessibilityEdit(operation: Int32, start: Int32, end: Int32,
                                text: String) -> Bool {
        guard showsComposer, let range = textRange(forScalarStart: Int(start),
                                                   end: Int(end)) else { return false }
        let view = composerEditor.textView
        let source = view.string as NSString
        switch operation {
        case 1:
            let remaining = source.replacingCharacters(in: range, with: text)
            guard remaining.utf8.count <= 65_536 else { return false }
            view.insertText(text, replacementRange: range)
        case 2:
            view.setSelectedRange(range)
        case 3, 4:
            guard range.length > 0 else { return true }
            let bytes = Array(source.substring(with: range).utf8)
            let wrote = bytes.withUnsafeBufferPointer {
                tw_clipboard_write($0.baseAddress, Int32($0.count))
            }
            guard wrote == 0 else { return false }
            if operation == 4 { view.insertText("", replacementRange: range) }
        case 5:
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = bytes.withUnsafeMutableBufferPointer {
                tw_clipboard_read($0.baseAddress, Int32($0.count))
            }
            guard count >= 0,
                  let pasted = String(bytes: bytes.prefix(Int(count)), encoding: .utf8),
                  source.replacingCharacters(in: range, with: pasted).utf8.count <= 65_536
            else { return false }
            view.insertText(pasted, replacementRange: range)
        default: return false
        }
        needsPresentation = true
        return true
    }

    private func textRange(forScalarStart start: Int, end: Int) -> NSRange? {
        guard start >= 0, end >= start else { return nil }
        let scalars = Array(composerEditor.textView.string.unicodeScalars)
        guard end <= scalars.count else { return nil }
        let lower = scalars[..<start].reduce(0) { $0 + String($1).utf16.count }
        let upper = scalars[start..<end].reduce(lower) { $0 + String($1).utf16.count }
        return NSRange(location: lower, length: upper - lower)
    }

    func updatePreedit(_ text: String, selectedRange: NSRange) {
        guard showsComposer else { return }
        composerEditor.textView.setMarkedText(text, selectedRange: selectedRange,
            replacementRange: NSRange(location: NSNotFound, length: 0))
        needsPresentation = true
    }

    func cancelMarkedText() -> Bool {
        guard showsComposer, composerEditor.textView.hasMarkedText() else { return false }
        composerEditor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        needsPresentation = true
        return true
    }

    func handleEditorKey(_ event: NSEvent) {
        guard showsComposer else { return }
        _ = window.dispatchToContent(event)
        needsPresentation = true
    }

    func focus(_ focused: Bool) {
        window.isKeyWindow = focused
        if !focused {
            window.makeFirstResponder(nil)
            window.cancelPointerGesture()
        }
        needsPresentation = true
    }

    func handle(_ input: TWEvent) {
        let eventType: NSEvent.EventType
        switch input.action {
        case 1: eventType = .leftMouseDown
        case 2: eventType = .leftMouseDragged
        case 3: eventType = .leftMouseUp
        default: eventType = .mouseMoved
        }
        let point = NSPoint(x: CGFloat(input.x) / 2,
                            y: root.bounds.height - CGFloat(input.y) / 2)
        _ = window.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
        if input.action == 4 { window.cancelPointerGesture() }
        needsPresentation = true
    }

    func cancelHover() {
        window.cancelPointerGesture()
        needsPresentation = true
    }

    @discardableResult
    func pressAction() -> Bool {
        let pressed = actionAnchor.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    func present(nativeWindow: OpaquePointer, width: Int, height: Int,
                 originX: Int) throws {
        let size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        guard needsPresentation || presentedSize != size else { return }
        root.frame = NSRect(origin: .zero, size: size)
        if showsComposer {
            let horizontalInset: CGFloat = 24
            let bottomInset: CGFloat = 8
            let editorHeight = min(108, max(44, size.height * 0.25))
            let heroBottom = bottomInset + editorHeight + 4
            composerEditor.frame = NSRect(x: horizontalInset, y: bottomInset,
                width: max(1, size.width - horizontalInset * 2), height: editorHeight)
            composerHero.frame = NSRect(x: 0, y: heroBottom,
                width: size.width, height: max(0, size.height - heroBottom))
        }
        window.layoutIfNeeded()

        let button = actionAnchor.convert(actionAnchor.bounds, to: root)
        let scale = window.backingScaleFactor
        let buttonX = originX + Int((button.minX * scale).rounded())
        let buttonY = Int(((root.bounds.height - button.maxY) * scale).rounded())
        let buttonWidth = Int((button.width * scale).rounded())
        let buttonHeight = Int((button.height * scale).rounded())

        let bitmap = Bitmap(width: width, height: height,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_placeholder(nativeWindow, $0.baseAddress,
                                   Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        title.withCString { name in
            detail.withCString { explanation in
                actionTitle.withCString { action in
                    tw_accessibility_placeholder(nativeWindow, name, explanation, action,
                        Int32(buttonX), Int32(buttonY), Int32(buttonWidth), Int32(buttonHeight))
                }
            }
        }
        if showsComposer {
            let view = composerEditor.textView
            let value = view.string
            let byteCount = value.utf8.prefix(65_537).count
            let frame = composerEditor.convert(composerEditor.bounds, to: root)
            let editorX = originX + Int((frame.minX * scale).rounded())
            let editorY = Int(((root.bounds.height - frame.maxY) * scale).rounded())
            if editorHasFocus {
                let caret = view.convert(view.insertionPointRect, to: root)
                tw_text_input_rect(nativeWindow,
                    Int32(originX + Int((caret.minX * scale).rounded())),
                    Int32((root.bounds.height - caret.maxY) * scale),
                    Int32(max(1, (caret.width * scale).rounded())),
                    Int32(max(1, (caret.height * scale).rounded())))
            }
            if byteCount <= 65_536, let identity = composerIdentity {
                let source = value as NSString
                let selection = view.selectedRange()
                let start = source.substring(to: selection.location).unicodeScalars.count
                let end = source.substring(to: NSMaxRange(selection)).unicodeScalars.count
                identity.withCString { editorID in
                    value.withCString { text in
                        tw_accessibility_composer_editor(nativeWindow, editorID, text,
                            Int32(byteCount), Int32(start), Int32(end), editorHasFocus ? 1 : 0,
                            Int32(editorX), Int32(editorY),
                            Int32((frame.width * scale).rounded()),
                            Int32((frame.height * scale).rounded()))
                    }
                }
            } else {
                tw_accessibility_composer_editor(nativeWindow, nil, nil, 0, 0, 0, 0, 0, 0, 0, 0)
            }
        } else {
            tw_accessibility_composer_editor(nativeWindow, nil, nil, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        presentedSize = size
        needsPresentation = false
        print("IDLE_PANE_FRAME \(width)x\(height) action=\(actionTitle)")
        fflush(nil)
    }
}
#endif
