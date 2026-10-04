#if os(Linux)
import Foundation

/// The TextKit 1 ownership chain used by production themed editors. Storage is the editable
/// source of truth; the layout manager retains its containers and invalidates attached views.
@MainActor
open class NSTextStorage {
    private var contents = NSMutableAttributedString(string: "")
    private var managers: [NSLayoutManager] = []

    public init() {}
    open var string: String { contents.string }
    open var length: Int { contents.length }
    open var attributedString: NSAttributedString { contents.copy() as! NSAttributedString }

    open func addLayoutManager(_ manager: NSLayoutManager) {
        guard !managers.contains(where: { $0 === manager }) else { return }
        managers.append(manager)
        manager.textStorage = self
    }

    open func setAttributedString(_ string: NSAttributedString) {
        contents.setAttributedString(string)
        changed(editedAt: nil)
    }

    open func replaceCharacters(in range: NSRange, with string: String) {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= contents.length else { return }
        contents.replaceCharacters(in: range, with: string)
        changed(editedAt: range.location)
    }

    private func changed(editedAt location: Int?) {
        managers.forEach { $0.storageDidChange(editedAt: location) }
    }
}

@MainActor
open class NSLayoutManager {
    public weak var textStorage: NSTextStorage?
    private var containers: [NSTextContainer] = []

    public init() {}
    open func addTextContainer(_ container: NSTextContainer) {
        guard !containers.contains(where: { $0 === container }) else { return }
        containers.append(container)
        container.layoutManager = self
    }
    open func usedRect(for container: NSTextContainer) -> NSRect {
        container.textView?.textUsedRect ?? .zero
    }
    fileprivate func storageDidChange(editedAt location: Int?) {
        containers.forEach { $0.textView?.storageDidChange(editedAt: location) }
    }
}

@MainActor
open class NSTextContainer {
    open var size: NSSize { didSet { textView?.invalidateTextLayout() } }
    open var widthTracksTextView = false { didSet { textView?.invalidateTextLayout() } }
    open var heightTracksTextView = false
    open var lineFragmentPadding: CGFloat = 5 { didSet { textView?.invalidateTextLayout() } }
    public weak var layoutManager: NSLayoutManager?
    public weak var textView: NSTextView?

    public init(size: NSSize) { self.size = size }
}

/// A Pango-shaped editor. Layout is cached between edits and width changes; painting visits
/// only the visible lines, so a long prompt does not rasterize its hidden paragraphs.
@MainActor
open class NSTextView: NSText {
    private struct Line {
        let range: NSRange
        let y: CGFloat
        let width: CGFloat
        let text: String
    }
    private struct Edit {
        let range: NSRange
        let removed: String
        let inserted: String
        let selectionBefore: NSRange
        let selectionAfter: NSRange
        var byteCount: Int { removed.utf8.count + inserted.utf8.count }
    }
    private struct CompositionOriginal {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    private var ownedStorage: NSTextStorage?
    private var selected = NSRange(location: 0, length: 0)
    private var selectionAnchor: Int?
    private var marked: NSRange?
    private var compositionOriginal: CompositionOriginal?
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []
    private var undoBytes = 0
    private var applyingLocalChange = false
    private var lines: [Line] = []
    private var layoutWidth: CGFloat = -1
    private var dirtyLocation: Int?
    private var layoutHeight: CGFloat = 0
    private var lineHeight: CGFloat = 16
    private var layingOut = false

    open private(set) var textContainer: NSTextContainer?
    open var layoutManager: NSLayoutManager? { textContainer?.layoutManager }
    open var textStorage: NSTextStorage? { layoutManager?.textStorage }
    open var string: String {
        get { textStorage?.string ?? "" }
        set {
            marked = nil
            compositionOriginal = nil
            clearHistory()
            applyingLocalChange = true
            ensureStorage().setAttributedString(NSAttributedString(string: newValue))
            applyingLocalChange = false
            setSelectedRange(NSRange(location: min(selected.location, (newValue as NSString).length), length: 0))
        }
    }
    open var drawsBackground = true { didSet { needsDisplay = true } }
    open var backgroundColor: NSColor = .white { didSet { needsDisplay = true } }
    open var textColor: NSColor? = .black { didSet { needsDisplay = true } }
    open var font: NSFont? = .systemFont(ofSize: 13) { didSet { invalidateTextLayout() } }
    open var insertionPointColor: NSColor = .black { didSet { needsDisplay = true } }
    open var selectedTextAttributes: [NSAttributedString.Key: Any] = [:] { didSet { needsDisplay = true } }
    open var isEditable = true
    open var isSelectable = true
    /// This renderer stores and edits plain text only. Refuse opt-ins whose TextKit behavior
    /// the shim cannot provide, while allowing shared prompt setup to state its plain-text
    /// contract explicitly.
    open var isRichText = false {
        didSet { precondition(!isRichText, "Linux NSTextView does not support rich-text editing") }
    }
    open var isAutomaticQuoteSubstitutionEnabled = false {
        didSet { precondition(!isAutomaticQuoteSubstitutionEnabled,
                              "Linux NSTextView does not support automatic quote substitution") }
    }
    open var isAutomaticDashSubstitutionEnabled = false {
        didSet { precondition(!isAutomaticDashSubstitutionEnabled,
                              "Linux NSTextView does not support automatic dash substitution") }
    }
    open var isAutomaticTextReplacementEnabled = false {
        didSet { precondition(!isAutomaticTextReplacementEnabled,
                              "Linux NSTextView does not support automatic text replacement") }
    }
    open var allowsUndo = false { didSet { if !allowsUndo { clearHistory() } } }
    open var isVerticallyResizable = false { didSet { invalidateTextLayout() } }
    open var isHorizontallyResizable = false
    open var textContainerInset: NSSize = .zero { didSet { invalidateTextLayout() } }
    open var minSize: NSSize = .zero { didSet { invalidateTextLayout() } }
    open var maxSize: NSSize = .zero { didSet { invalidateTextLayout() } }

    public init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        textContainer = container
        super.init(frame: frameRect)
        container?.textView = self
        setAccessibilityRole(.textArea)
        setAccessibilityValue("")
    }

    public override convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frameRect.width,
                                                    height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        self.init(frame: frameRect, textContainer: container)
        ownedStorage = storage
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    open override var isFlipped: Bool { true }
    open override var acceptsFirstResponder: Bool { isEditable || isSelectable }
    open override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    open override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    open override var frame: NSRect {
        didSet {
            if frame.width != oldValue.width { invalidateTextLayout() }
        }
    }

    open override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = superview as? NSClipView, autoresizingMask.contains(.width),
           frame.width != clip.bounds.width {
            frame.size.width = clip.bounds.width
        }
    }

    open var textUsedRect: NSRect {
        ensureLayout()
        return NSRect(x: 0, y: 0, width: max(0, layoutWidth), height: layoutHeight)
    }

    open func selectedRange() -> NSRange { selected }
    open func setSelectedRange(_ range: NSRange) {
        let length = textStorage?.length ?? 0
        let start = min(max(0, range.location), length)
        let end = min(max(start, NSMaxRange(range)), length)
        selected = NSRange(location: start, length: end - start)
        selectionAnchor = nil
        needsDisplay = true
        scrollRangeToVisible(selected)
    }

    open func insertText(_ value: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let inserted: String
        if let string = value as? String { inserted = string }
        else if let attributed = value as? NSAttributedString { inserted = attributed.string }
        else { return }
        let source = textStorage?.string ?? ""
        let sourceLength = (source as NSString).length
        let requested = replacementRange.location == NSNotFound ? selected : replacementRange
        let effectiveRange: NSRange
        let original: CompositionOriginal?
        if let marked,
           replacementRange.location == NSNotFound ||
            (requested.location >= marked.location && NSMaxRange(requested) <= NSMaxRange(marked)) {
            effectiveRange = marked
            original = compositionOriginal
        } else {
            effectiveRange = requested
            original = nil
        }
        guard effectiveRange.location >= 0, effectiveRange.length >= 0,
              NSMaxRange(effectiveRange) <= sourceLength else { return }
        let removed = original?.text ?? (source as NSString).substring(with: effectiveRange)
        let recordedRange = original?.range ?? effectiveRange
        let before = original?.selection ?? selected
        marked = nil
        compositionOriginal = nil
        replaceLocally(effectiveRange, with: inserted)
        let after = NSRange(location: effectiveRange.location + (inserted as NSString).length,
                            length: 0)
        setSelectedRange(after)
        register(Edit(range: recordedRange, removed: removed, inserted: inserted,
                      selectionBefore: before, selectionAfter: after))
    }

    open func setMarkedText(_ value: Any, selectedRange: NSRange,
                            replacementRange: NSRange) {
        guard isEditable else { return }
        let provisional: String
        if let string = value as? String { provisional = string }
        else if let attributed = value as? NSAttributedString { provisional = attributed.string }
        else { return }
        let target = marked ?? (replacementRange.location == NSNotFound ? selected : replacementRange)
        if provisional.isEmpty, marked == nil { return }
        guard target.location >= 0, target.length >= 0,
              NSMaxRange(target) <= (textStorage?.length ?? 0) else { return }
        if marked == nil, !provisional.isEmpty {
            let previous = (string as NSString).substring(with: target)
            compositionOriginal = CompositionOriginal(range: target, text: previous,
                                                      selection: selected)
        }
        if provisional.isEmpty, let original = compositionOriginal, marked != nil {
            replaceLocally(target, with: original.text)
            marked = nil
            compositionOriginal = nil
            setSelectedRange(original.selection)
            return
        }
        replaceLocally(target, with: provisional)
        let length = (provisional as NSString).length
        marked = length > 0 ? NSRange(location: target.location, length: length) : nil
        let relativeStart = min(max(0, selectedRange.location), length)
        let relativeEnd = min(max(relativeStart, NSMaxRange(selectedRange)), length)
        setSelectedRange(NSRange(location: target.location + relativeStart,
                                 length: relativeEnd - relativeStart))
    }

    open func hasMarkedText() -> Bool { marked != nil }
    open func markedRange() -> NSRange { marked ?? NSRange(location: NSNotFound, length: 0) }
    open func unmarkText() {
        if let marked, let original = compositionOriginal {
            let final = (string as NSString).substring(with: marked)
            register(Edit(range: original.range, removed: original.text, inserted: final,
                          selectionBefore: original.selection, selectionAfter: selected))
        }
        marked = nil
        compositionOriginal = nil
        needsDisplay = true
    }

    open func deleteBackward(_ sender: Any?) {
        if marked != nil {
            setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        guard isEditable, let storage = textStorage else { return }
        let range: NSRange
        if selected.length > 0 { range = selected }
        else if selected.location > 0 {
            range = (storage.string as NSString).rangeOfComposedCharacterSequence(at: selected.location - 1)
        } else { return }
        deleteText(in: range, storage: storage)
    }

    open func deleteForward(_ sender: Any?) {
        if marked != nil {
            setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        guard isEditable, let storage = textStorage else { return }
        let range: NSRange
        if selected.length > 0 { range = selected }
        else if selected.location < storage.length {
            range = (storage.string as NSString).rangeOfComposedCharacterSequence(at: selected.location)
        } else { return }
        deleteText(in: range, storage: storage)
    }

    private func deleteText(in range: NSRange, storage: NSTextStorage) {
        let removed = (storage.string as NSString).substring(with: range)
        let before = selected
        replaceLocally(range, with: "")
        let after = NSRange(location: range.location, length: 0)
        setSelectedRange(after)
        register(Edit(range: range, removed: removed, inserted: "",
                      selectionBefore: before, selectionAfter: after))
    }

    open func scrollRangeToVisible(_ range: NSRange) {
        guard let clip = superview as? NSClipView else { return }
        ensureLayout()
        let caret = caretRect(at: min(range.location, textStorage?.length ?? 0))
        var origin = clip.bounds.origin
        if caret.minY < origin.y { origin.y = caret.minY }
        if caret.maxY > origin.y + clip.bounds.height {
            origin.y = caret.maxY - clip.bounds.height
        }
        clip.scroll(to: origin)
    }

    open override func keyDown(with event: NSEvent) {
        guard isEditable || isSelectable else { return }
        // SDL reports IME composition through TEXTEDITING and the final candidate through
        // TEXTINPUT. Its intervening keydown belongs to the input method, including Return,
        // arrows and Backspace; applying it here would replace the provisional text or send
        // a prompt before the committed candidate arrives.
        if marked != nil { return }
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
            if characters.lowercased() == "z" || event.keyCode == 29 {
                if event.modifierFlags.contains(.shift) { redo(nil) }
                else { undo(nil) }
                return
            }
            if characters.lowercased() == "y" { redo(nil); return }
        }
        if event.keyCode == 117 {
            deleteForward(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 42 || characters == "\u{7f}" {
            deleteBackward(nil)
            return
        }
        if [123, 124, 79, 80].contains(event.keyCode) {
            moveCaret(left: event.keyCode == 123 || event.keyCode == 80,
                      extending: event.modifierFlags.contains(.shift))
            return
        }
        if [125, 126, 81, 82].contains(event.keyCode) {
            moveVertically(up: event.keyCode == 126 || event.keyCode == 82,
                           extending: event.modifierFlags.contains(.shift))
            return
        }
        guard isEditable, !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control), !characters.isEmpty else { return }
        insertText(characters, replacementRange: selected)
    }

    open override func mouseDown(with event: NSEvent) {
        guard isSelectable else { return }
        _ = window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndex(at: point)
        setSelectedRange(NSRange(location: offset, length: 0))
        selectionAnchor = offset
    }

    open override func mouseDragged(with event: NSEvent) {
        guard isSelectable, let anchor = selectionAnchor else { return }
        let offset = characterIndex(at: convert(event.locationInWindow, from: nil))
        selected = NSRange(location: min(anchor, offset), length: abs(anchor - offset))
        needsDisplay = true
        scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    open override func mouseUp(with event: NSEvent) { selectionAnchor = nil }

    open override func accessibilityValue() -> Any? { string }

    open func undo(_ sender: Any?) {
        guard allowsUndo, let edit = undoEdits.popLast() else { return }
        undoBytes -= edit.byteCount
        let range = NSRange(location: edit.range.location,
                            length: (edit.inserted as NSString).length)
        replaceLocally(range, with: edit.removed)
        setSelectedRange(edit.selectionBefore)
        redoEdits.append(edit)
    }

    open func redo(_ sender: Any?) {
        guard allowsUndo, let edit = redoEdits.popLast() else { return }
        replaceLocally(edit.range, with: edit.inserted)
        setSelectedRange(edit.selectionAfter)
        undoEdits.append(edit)
        undoBytes += edit.byteCount
    }

    private func replaceLocally(_ range: NSRange, with text: String) {
        applyingLocalChange = true
        ensureStorage().replaceCharacters(in: range, with: text)
        applyingLocalChange = false
    }

    private func register(_ edit: Edit) {
        guard allowsUndo, edit.removed != edit.inserted else { return }
        redoEdits.removeAll()
        undoEdits.append(edit)
        undoBytes += edit.byteCount
        while undoEdits.count > 128 || (undoBytes > 8_000_000 && undoEdits.count > 1) {
            undoBytes -= undoEdits.removeFirst().byteCount
        }
    }

    private func clearHistory() {
        undoEdits.removeAll()
        redoEdits.removeAll()
        undoBytes = 0
    }

    fileprivate func storageDidChange(editedAt location: Int?) {
        let length = textStorage?.length ?? 0
        marked = nil
        if !applyingLocalChange {
            compositionOriginal = nil
            clearHistory()
        }
        if NSMaxRange(selected) > length {
            selected = NSRange(location: min(selected.location, length), length: 0)
        }
        if let location, layoutWidth >= 0 {
            dirtyLocation = min(dirtyLocation ?? location, location)
            needsDisplay = true
            invalidateIntrinsicContentSize()
        } else {
            invalidateTextLayout()
        }
    }

    fileprivate func invalidateTextLayout() {
        layoutWidth = -1
        dirtyLocation = nil
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private func ensureStorage() -> NSTextStorage {
        if let storage = textStorage { return storage }
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frame.width,
                                                    height: .greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        container.textView = self
        textContainer = container
        ownedStorage = storage
        return storage
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 13),
         .foregroundColor: textColor ?? NSColor.black]
    }

    private func measuredWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: textAttributes).width
    }

    private func ensureLayout() {
        let padding = max(0, textContainer?.lineFragmentPadding ?? 5)
        let horizontalInset = max(0, textContainerInset.width)
        let verticalInset = max(0, textContainerInset.height)
        let proposed = textContainer?.widthTracksTextView == true
            ? frame.width : (textContainer?.size.width ?? frame.width)
        let width = max(1, proposed - (padding + horizontalInset) * 2)
        guard layoutWidth != width || dirtyLocation != nil else { return }
        let source = (textStorage?.string ?? "") as NSString
        lineHeight = max(1, ("Mg" as NSString).size(withAttributes: textAttributes).height)
        var location = 0
        var y = verticalInset
        if layoutWidth == width, let dirtyLocation {
            let affected = min(max(0, dirtyLocation), source.length)
            let newline = source.range(of: "\n", options: .backwards,
                                       range: NSRange(location: 0, length: affected))
            location = newline.location == NSNotFound ? 0 : newline.location + 1
            var low = 0
            var high = lines.count
            while low < high {
                let middle = low + (high - low) / 2
                if lines[middle].range.location < location { low = middle + 1 }
                else { high = middle }
            }
            lines.removeSubrange(low..<lines.count)
            if let last = lines.last { y = last.y + lineHeight }
        } else {
            lines.removeAll(keepingCapacity: true)
        }
        layoutWidth = width
        dirtyLocation = nil
        while location < source.length {
            let remaining = source.length - location
            let paragraph = source.range(of: "\n", options: [],
                                            range: NSRange(location: location, length: remaining))
            let paragraphEnd = paragraph.location == NSNotFound ? source.length : paragraph.location
            if location == paragraphEnd {
                lines.append(Line(range: NSRange(location: location, length: 0), y: y,
                                  width: 0, text: ""))
                y += lineHeight
            }
            while location < paragraphEnd {
                let end = fittedEnd(in: source, from: location, through: paragraphEnd, width: width)
                let range = NSRange(location: location, length: end - location)
                let text = source.substring(with: range)
                lines.append(Line(range: range, y: y, width: measuredWidth(text), text: text))
                location = end
                y += lineHeight
            }
            if paragraph.location == NSNotFound { break }
            location = paragraph.location + 1
        }
        if source.length == 0 || source.character(at: source.length - 1) == 10 {
            lines.append(Line(range: NSRange(location: source.length, length: 0), y: y,
                              width: 0, text: ""))
            y += lineHeight
        }
        layoutHeight = y + verticalInset
        if isVerticallyResizable, !layingOut {
            let minimum = max(minSize.height, (superview as? NSClipView)?.bounds.height ?? 0)
            let maximum = maxSize.height > 0 ? maxSize.height : .greatestFiniteMagnitude
            let target = min(max(max(layoutHeight, minimum), 0), maximum)
            if target.isFinite, frame.height != target {
                layingOut = true
                frame.size.height = target
                layingOut = false
            }
        }
    }

    private func fittedEnd(in source: NSString, from start: Int, through end: Int,
                           width: CGFloat) -> Int {
        let cap = min(end, start + 1024)
        let firstEnd = source.rangeOfComposedCharacterSequence(at: start).upperBound
        var low = firstEnd
        var high = cap
        var fitted = firstEnd
        while low <= high {
            let middle = low + (high - low) / 2
            let safe = source.rangeOfComposedCharacterSequence(at: middle - 1).upperBound
            let candidate = min(safe, end)
            let fragment = source.substring(with: NSRange(location: start,
                                                         length: candidate - start))
            if measuredWidth(fragment) <= width {
                fitted = candidate
                low = candidate + 1
            } else {
                high = middle - 1
            }
        }
        if fitted >= end { return end }
        let fragment = source.substring(with: NSRange(location: start, length: fitted - start))
        if let whitespace = fragment.range(of: " ", options: .backwards),
           whitespace.upperBound != fragment.startIndex {
            let prefix = fragment[..<whitespace.upperBound]
            let breakAt = start + String(prefix).utf16.count
            if breakAt > start { return breakAt }
        }
        return fitted
    }

    private func line(at location: Int) -> Line {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(lines[middle].range) < location { low = middle + 1 }
            else { high = middle }
        }
        let index = min(low, lines.count - 1)
        let end = NSMaxRange(lines[index].range)
        if location == end, index + 1 < lines.count,
           lines[index + 1].range.location == end {
            return lines[index + 1]
        }
        return lines[index]
    }

    private func caretRect(at location: Int) -> NSRect {
        ensureLayout()
        let line = line(at: location)
        let prefixLength = max(0, min(location - line.range.location, line.range.length))
        let prefix = (line.text as NSString).substring(to: prefixLength)
        let x = max(0, textContainer?.lineFragmentPadding ?? 5) +
            max(0, textContainerInset.width) + measuredWidth(prefix)
        return NSRect(x: x, y: line.y, width: 1, height: lineHeight)
    }

    open var insertionPointRect: NSRect { caretRect(at: NSMaxRange(selected)) }

    private func characterIndex(at point: NSPoint) -> Int {
        ensureLayout()
        let row = min(max(0, Int(floor((point.y - max(0, textContainerInset.height)) /
                                        lineHeight))), lines.count - 1)
        let line = lines[row]
        let target = point.x - max(0, textContainer?.lineFragmentPadding ?? 5) -
            max(0, textContainerInset.width)
        let source = line.text as NSString
        var offset = 0
        while offset < source.length {
            let next = source.rangeOfComposedCharacterSequence(at: offset).upperBound
            let prefix = source.substring(to: next)
            if measuredWidth(prefix) >= target { break }
            offset = next
        }
        return line.range.location + offset
    }

    private func moveCaret(left: Bool, extending: Bool) {
        guard isSelectable else { return }
        let source = string as NSString
        let active = activeCaret(towardStart: left, extending: extending)
        let next: Int
        if left, active > 0 { next = source.rangeOfComposedCharacterSequence(at: active - 1).location }
        else if !left, active < source.length {
            next = source.rangeOfComposedCharacterSequence(at: active).upperBound
        } else { next = active }
        selectCaret(at: next, extending: extending)
    }

    private func moveVertically(up: Bool, extending: Bool) {
        guard isSelectable else { return }
        let active = activeCaret(towardStart: up, extending: extending)
        let caret = caretRect(at: active)
        let point = NSPoint(x: caret.minX, y: caret.midY + (up ? -lineHeight : lineHeight))
        selectCaret(at: characterIndex(at: point), extending: extending)
    }

    private func activeCaret(towardStart: Bool, extending: Bool) -> Int {
        guard extending else {
            return towardStart ? selected.location : NSMaxRange(selected)
        }
        let anchor = selectionAnchor ?? selected.location
        return selected.location == anchor ? NSMaxRange(selected) : selected.location
    }

    private func selectCaret(at next: Int, extending: Bool) {
        if extending {
            let anchor = selectionAnchor ?? selected.location
            selectionAnchor = anchor
            selected = NSRange(location: min(anchor, next), length: abs(anchor - next))
            needsDisplay = true
            scrollRangeToVisible(NSRange(location: next, length: 0))
        } else {
            setSelectedRange(NSRange(location: next, length: 0))
        }
    }

    open override func draw(_ dirtyRect: NSRect) {
        ensureLayout()
        if drawsBackground {
            backgroundColor.setFill()
            NSBezierPath.fill(bounds)
        }
        let visible = visibleRect
        let padding = max(0, textContainer?.lineFragmentPadding ?? 5) +
            max(0, textContainerInset.width)
        for line in lines where line.y + lineHeight >= visible.minY && line.y <= visible.maxY {
            let start = max(selected.location, line.range.location)
            let end = min(NSMaxRange(selected), NSMaxRange(line.range))
            if end > start {
                let before = (line.text as NSString).substring(to: start - line.range.location)
                let selectedText = (line.text as NSString).substring(with:
                    NSRange(location: start - line.range.location, length: end - start))
                let x = padding + measuredWidth(before)
                let width = measuredWidth(selectedText)
                (selectedTextAttributes[.backgroundColor] as? NSColor ??
                    NSColor(red: 0.65, green: 0.76, blue: 0.96, alpha: 1)).setFill()
                NSBezierPath.fill(NSRect(x: x, y: line.y, width: width, height: lineHeight))
            }
            if let marked {
                let markStart = max(marked.location, line.range.location)
                let markEnd = min(NSMaxRange(marked), NSMaxRange(line.range))
                if markEnd > markStart {
                    let before = (line.text as NSString).substring(to: markStart - line.range.location)
                    let provisional = (line.text as NSString).substring(with: NSRange(
                        location: markStart - line.range.location, length: markEnd - markStart))
                    (textColor ?? .black).setFill()
                    NSBezierPath.fill(NSRect(x: padding + measuredWidth(before),
                                             y: line.y + lineHeight - 1,
                                             width: measuredWidth(provisional), height: 1))
                }
            }
            guard !line.text.isEmpty else { continue }
            NSAttributedString(string: line.text, attributes: textAttributes)
                .draw(at: NSPoint(x: padding, y: line.y))
            if end > start, let ink = selectedTextAttributes[.foregroundColor] as? NSColor {
                let before = (line.text as NSString).substring(to: start - line.range.location)
                let selectedText = (line.text as NSString).substring(with:
                    NSRange(location: start - line.range.location, length: end - start))
                NSAttributedString(string: selectedText, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13),
                                                                     .foregroundColor: ink])
                    .draw(at: NSPoint(x: padding + measuredWidth(before), y: line.y))
            }
        }
        if selected.length == 0, isEditable, window?.firstResponder === self {
            insertionPointColor.setFill()
            NSBezierPath.fill(caretRect(at: selected.location))
        }
    }
}
#endif
