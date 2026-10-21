#if os(Linux)
import Foundation
import AppKitTextBridge

public enum NSTextAlignment: Int, Sendable { case left = 0, right = 2, center = 1, justified = 3, natural = 4 }
public enum NSLineBreakMode: Int, Sendable {
    case byWordWrapping = 0, byCharWrapping = 1, byClipping = 2
    case byTruncatingHead = 3, byTruncatingTail = 4, byTruncatingMiddle = 5
}

@MainActor
open class NSTextFieldCell {
    /// The field this cell measures for; a themed cell reads its font.
    public internal(set) weak var owner: NSTextField?
    public required init() {}
    public var wraps: Bool {
        guard let owner, !owner.usesSingleLineMode else { return false }
        return owner.lineBreakMode == .byWordWrapping || owner.lineBreakMode == .byCharWrapping
    }
    /// Linux's Pango label has no private AppKit cell padding: its shaped bounds are its cell.
    public var cellSize: NSSize { owner?.intrinsicContentSize ?? .zero }
    public func cellSize(forBounds bounds: NSRect) -> NSSize { cellSize }
    public func titleRect(forBounds bounds: NSRect) -> NSRect { bounds }
    /// Where an editable field draws its text and places its field editor. A themed cell
    /// insets this from the bezel it draws; a label's shaped bounds are its cell.
    open func drawingRect(forBounds bounds: NSRect) -> NSRect { bounds }
    public var truncatesLastVisibleLine = false {
        didSet {
            owner?.needsDisplay = true
            owner?.invalidateIntrinsicContentSize()
        }
    }
}

/// A bounded, Pango-shaped label with attributed style runs and read-only selection.
/// Editing and IME remain the separate NSTextView/platform input path.
@MainActor
open class NSTextField: NSView {
    private static let maximumUTF8Bytes = 4096
    private static let maximumRasterWidth = 2048
    private static let maximumRasterHeight = 128
    private static let maximumLines = 8

    private var preparedUTF8: [UInt8] = []
    private var attributedStorage: NSAttributedString?
    private var naturalMetrics: TATMetrics?
    private var scaledMetrics: (scale: CGFloat, metrics: TATMetrics)?
    private var unwrappedWidth: (scale: CGFloat, width: CGFloat)?
    private var automaticLayoutWidth: CGFloat = 0
    private var labelLayout: SelectableLabelLayout?
    private var selectionAnchor: Int?
    private var draggingSelection = false
    private var textGeneration: UInt64 = 0
    private var completeLabel: CompletePlainLabelState?
    private var completeDragStart: CGPoint?
    private var completeDragAnchor: Int?
    public private(set) var selectedTextRange = NSRange(location: 0, length: 0)

    private var textStorage = ""
    open var stringValue: String {
        get { textStorage }
        set {
            textStorage = newValue
            textGeneration &+= 1
            attributedStorage = nil
            selectedTextRange = NSRange(location: 0, length: 0)
            selectionAnchor = nil
            setAccessibilityRole(isEditable ? .textField : .staticText)
            setAccessibilityLabel(newValue)
            let prefix = Array(newValue.utf8.prefix(Self.maximumUTF8Bytes + 1))
            if prefix.count <= Self.maximumUTF8Bytes {
                preparedUTF8 = prefix
            } else {
                // The prefix is decoded before appending an ellipsis so a cut multi-byte scalar
                // remains valid UTF-8. 4088 leaves room for one replacement scalar too.
                preparedUTF8 = Array((String(decoding: prefix.prefix(4088), as: UTF8.self) + "…").utf8)
            }
            invalidateTextMetrics()
        }
    }
    open var attributedStringValue: NSAttributedString {
        get {
            if let attributedStorage { return attributedStorage }
            return NSAttributedString(string: stringValue, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: textColor ?? NSColor.labelColor
            ])
        }
        set {
            stringValue = newValue.string
            // The drawing leaf reads only a bounded prefix. A full immutable copy here would
            // synchronously duplicate an arbitrarily long source before the first paint.
            attributedStorage = newValue
            invalidateTextMetrics()
        }
    }
    open var font: NSFont? = .systemFont(ofSize: 13) { didSet { invalidateTextMetrics() } }
    open var textColor: NSColor? = .labelColor { didSet { labelLayout = nil; needsDisplay = true } }
    open var alignment: NSTextAlignment = .natural { didSet { labelLayout = nil; needsDisplay = true } }
    open var lineBreakMode: NSLineBreakMode = .byClipping { didSet { invalidateTextMetrics() } }
    open var maximumNumberOfLines: Int = 0 { didSet { invalidateTextMetrics() } }
    open var usesSingleLineMode = false { didSet { invalidateTextMetrics() } }
    /// A wrapping label measures its intrinsic height at this width while its frame still
    /// comes from layout. Zero lets it report the natural, unwrapped line width.
    open var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet { invalidateTextMetrics() }
    }
    private lazy var labelCell: NSTextFieldCell = {
        let cell = type(of: self).cellClass.init()
        cell.owner = self
        return cell
    }()
    open var cell: NSTextFieldCell? { labelCell }
    open class var cellClass: NSTextFieldCell.Type { NSTextFieldCell.self }

    // MARK: Editing

    /// An editable field edits through a field editor, as AppKit's does: while editing, the
    /// window's first responder is that `NSTextView`, placed over the cell's drawing rect.
    open var isEditable = false {
        didSet { if isEditable != oldValue { editabilityDidChange() } }
    }

    /// Initializers set the property without its observer, so they call this directly.
    private func editabilityDidChange() {
        if isEditable { isSelectable = true } else { abortEditing() }
        setAccessibilityRole(isEditable ? .textField : .staticText)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    open weak var delegate: NSTextFieldDelegate?
    open var placeholderString: String? {
        didSet {
            placeholderAttributedString = nil
            needsDisplay = true
        }
    }
    open var placeholderAttributedString: NSAttributedString? { didSet { needsDisplay = true } }
    /// Sent when Return ends editing. This field is not an `NSControl` here, so it owns the
    /// pair itself; on Linux a `Selector` is the closure.
    open var action: Selector?
    open weak var target: AnyObject?
    var fieldEditor: NSTextFieldEditor?
    open var isSelectable = false {
        didSet {
            if !isSelectable {
                selectedTextRange = NSRange(location: 0, length: 0)
                selectionAnchor = nil
                if window?.firstResponder === self { _ = window?.makeFirstResponder(nil) }
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    open var selectedTextAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: NSColor.controlAccentColor, .foregroundColor: NSColor.white
    ] { didSet { needsDisplay = true } }
    open var isBordered = false {
        didSet { precondition(!isBordered, "Linux NSTextField label has no control border") }
    }
    open var drawsBackground = false {
        didSet { precondition(!drawsBackground, "Linux NSTextField label has no control background") }
    }

    public convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    public convenience init(labelWithAttributedString string: NSAttributedString) {
        self.init(frame: .zero)
        attributedStringValue = string
    }

    public convenience init(wrappingLabelWithString string: String) {
        self.init(labelWithString: string)
        lineBreakMode = .byWordWrapping
    }

    /// AppKit's editable single-line field. The host theme draws its bezel through its cell.
    public convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        isEditable = true
        editabilityDidChange()
    }

    open override var isFlipped: Bool { true }

    open override var intrinsicContentSize: NSSize {
        if isEditable { return editableIntrinsicSize }
        let scale = window?.backingScaleFactor ?? 1
        let metric = metrics(at: scale)
        let width = wrapsAtLayoutWidth ? naturalWidth(at: scale) : CGFloat(metric.width) / scale
        return NSSize(width: width, height: CGFloat(metric.height) / scale)
    }

    /// A label whose wrap width comes from layout rather than `preferredMaxLayoutWidth`.
    private var wrapsAtLayoutWidth: Bool {
        !translatesAutoresizingMaskIntoConstraints && preferredMaxLayoutWidth == 0
            && (effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping)
    }

    /// AppKit gives such a label its single-line natural width as its intrinsic width, and only
    /// its height follows the solved width. Reporting the width it wrapped to instead would let
    /// one narrow pass pin it narrow: hugging could never ask for the room to grow back. A
    /// complete document's layout says whether it wrapped; when it did, the text wants all the
    /// room there is, and its constraints decide how much that is.
    private func naturalWidth(at scale: CGFloat) -> CGFloat {
        if usesCompletePlainText, let complete = completePlainText(at: scale), let metrics = complete.metrics {
            return metrics.wrapped ? CGFloat(Self.maximumRasterWidth) / scale : CGFloat(metrics.width) / scale
        }
        if let unwrappedWidth, unwrappedWidth.scale == scale { return unwrappedWidth.width }
        let width = CGFloat(metrics(at: scale, unwrapped: true).width) / scale
        unwrappedWidth = (scale, width)
        return width
    }

    open override func layout() {
        super.layout()
        layoutFieldEditor()
    }

    open override func viewDidMoveToWindow() {
        // A tight stack can measure before attachment. Its intrinsic width must be recomputed
        // at the scale used to shape pixels when the label gains or changes a window.
        invalidateIntrinsicContentSize()
    }

    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateTextMetrics()
    }

    open override var firstBaselineMetric: NSBaselineMetric { baselineMetric }
    open override var lastBaselineMetric: NSBaselineMetric { baselineMetric }

    private var baselineMetric: NSBaselineMetric {
        let scale = window?.backingScaleFactor ?? 1
        let metric = metrics(at: scale)
        let baseline = CGFloat(metric.baseline) / scale
        let height = CGFloat(metric.height) / scale
        if effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping {
            // The first line is top-aligned. A last-line baseline depends on the width being
            // solved, so this label-only path exposes the first line for both anchors.
            return NSBaselineMetric(heightFraction: 0, offset: baseline)
        }
        return NSBaselineMetric(heightFraction: 0.5, offset: baseline - height / 2)
    }

    private func invalidateTextMetrics() {
        naturalMetrics = nil
        scaledMetrics = nil
        unwrappedWidth = nil
        labelLayout = nil
        if !usesCompletePlainText { completeLabel?.suspend() }
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    func commitAutomaticLayoutWidth(_ width: CGFloat) -> Bool {
        guard !translatesAutoresizingMaskIntoConstraints, preferredMaxLayoutWidth == 0,
              effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping,
              width > 0, abs(automaticLayoutWidth - width) > 0.5 else { return false }
        let before = intrinsicContentSize
        automaticLayoutWidth = width
        invalidateTextMetrics()
        return intrinsicContentSize != before
    }

    /// `unwrapped` measures the bounded label paths with no wrap width and leaves the cached
    /// layout-width metrics alone; it is how `naturalWidth(at:)` reads a line's natural width.
    private func metrics(at scale: CGFloat, unwrapped: Bool = false) -> TATMetrics {
        if !unwrapped, let complete = completePlainText(at: scale), let metrics = complete.metrics {
            return TATMetrics(width: Int32(metrics.width), height: Int32(metrics.height),
                              baseline: Int32(metrics.baseline), glyphs: 0)
        }
        if !unwrapped, scale == 1, let naturalMetrics { return naturalMetrics }
        if !unwrapped, let scaledMetrics, scaledMetrics.scale == scale { return scaledMetrics.metrics }
        let wraps = effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping
        let lineLimit = min(Self.maximumLines, max(1, maximumNumberOfLines == 0 ? Self.maximumLines : maximumNumberOfLines))
        let measuredWidth = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : automaticLayoutWidth
        let wrapWidth = !unwrapped && wraps && measuredWidth.isFinite && measuredWidth > 0
            ? Int(ceil(min(CGFloat(Self.maximumRasterWidth), measuredWidth * scale))) : 0
        if attributedStorage != nil || isSelectable {
            let source = attributedStorage ?? NSAttributedString(
                string: String(decoding: preparedUTF8, as: UTF8.self), attributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 13),
                    .foregroundColor: textColor ?? NSColor.labelColor
                ])
            let result = AttributedTextDrawing.prepare(source, scale: scale)
                .measure(wrappingAt: wrapWidth, maximumLines: lineLimit,
                         characterWrapping: effectiveLineBreakMode == .byCharWrapping,
                         completeLabelHeight: isSelectable)
                ?? TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
            if unwrapped { return result }
            if scale == 1 { naturalMetrics = result }
            else { scaledMetrics = (scale, result) }
            return result
        }
        var result = TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
        let size = max(1, min(128, (font?.pointSize ?? 13) * scale))
        var emptyByte: UInt8 = 0
        withUnsafePointer(to: &emptyByte) { emptyPointer in
            preparedUTF8.withUnsafeBufferPointer { bytes in
                let hasParagraphs = !usesSingleLineMode && maximumNumberOfLines != 1
                    && preparedUTF8.contains(10)
                if wraps || hasParagraphs {
                    if wrapWidth > 0 {
                        _ = tat_measure_wrapped(bytes.baseAddress ?? emptyPointer,
                                                Int32(bytes.count), isMonospace, pangoWeight,
                                                font?.isItalic == true ? 1 : 0,
                                                Double(size), Int32(lineLimit), Int32(wrapWidth),
                                                effectiveLineBreakMode == .byCharWrapping ? 1 : 0,
                                                &result)
                    } else {
                        _ = tat_measure_paragraphs(bytes.baseAddress ?? emptyPointer,
                                                   Int32(bytes.count), isMonospace, pangoWeight,
                                                   font?.isItalic == true ? 1 : 0,
                                                   Double(size), Int32(lineLimit), &result)
                    }
                } else {
                    _ = tat_measure(bytes.baseAddress ?? emptyPointer, Int32(bytes.count),
                                    isMonospace, pangoWeight, font?.isItalic == true ? 1 : 0,
                                    Double(size), &result)
                }
            }
        }
        if unwrapped { return result }
        if scale == 1 { naturalMetrics = result }
        else { scaledMetrics = (scale, result) }
        return result
    }

    private var isMonospace: Int32 { font?.familyName?.contains("Mono") == true ? 1 : 0 }
    private var effectiveLineBreakMode: NSLineBreakMode {
        if usesSingleLineMode && (lineBreakMode == .byWordWrapping || lineBreakMode == .byCharWrapping) {
            return .byClipping
        }
        return lineBreakMode
    }
    private var pangoWeight: Int32 {
        let value = font?.weight.rawValue ?? NSFont.Weight.regular.rawValue
        if value >= NSFont.Weight.bold.rawValue { return 3 }
        if value >= NSFont.Weight.semibold.rawValue { return 2 }
        if value >= NSFont.Weight.medium.rawValue { return 1 }
        return 0
    }

    open override func draw(_ dirtyRect: NSRect) {
        if isEditable {
            drawEditableContent()
            return
        }
        if isSelectable {
            drawSelectableLabel()
            return
        }
        if let attributedStorage {
            guard attributedStorage.length > 0,
                  let context = NSGraphicsContext.current, context.alpha > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            let scale = context.scale
            let metric = metrics(at: scale)
            let wraps = effectiveLineBreakMode == .byWordWrapping ||
                        effectiveLineBreakMode == .byCharWrapping
            let lineHeight = CGFloat(metric.height) / scale
            let top = wraps ? 0 : max(0, (bounds.height - lineHeight) / 2)
            let height = wraps ? bounds.height : min(bounds.height - top, lineHeight)
            guard height > 0 else { return }
            let lineLimit = min(Self.maximumLines,
                                max(1, maximumNumberOfLines == 0 ? Self.maximumLines : maximumNumberOfLines))
            AttributedTextDrawing.draw(attributedStorage, at: nil,
                                       in: NSRect(x: 0, y: top, width: bounds.width, height: height),
                                       lineBreakMode: effectiveLineBreakMode,
                                       textAlignment: alignment, maximumLines: lineLimit,
                                       truncatesLastVisibleLine: labelCell.truncatesLastVisibleLine)
            return
        }
        guard !preparedUTF8.isEmpty, let color = textColor,
              let context = NSGraphicsContext.current,
              color.alphaComponent > 0, context.alpha > 0 else { return }
        let matrix = context.transform
        guard matrix.b == 0, matrix.c == 0, matrix.a.isFinite, matrix.d.isFinite,
              matrix.a > 0, matrix.d > 0 else { return }
        let scale = matrix.a
        let pixelSize = max(1, min(128, (font?.pointSize ?? 13) * scale))
        let origin = matrix.apply(to: .zero)
        // Keep conversion to Int and the intersection arithmetic bounded even if a caller
        // accidentally hands the label enormous or non-finite geometry.
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) <= 1_000_000,
              abs(origin.y) <= 1_000_000, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 0, bounds.height >= 0,
              bounds.width * scale <= 1_000_000,
              bounds.height * scale <= 1_000_000 else { return }
        let fieldLeft = Int(floor(origin.x)), fieldTop = Int(floor(origin.y))
        let fieldWidth = max(0, Int(ceil(bounds.width * scale)))
        let fieldHeight = max(0, Int(ceil(bounds.height * scale)))
        let layoutWidth = min(Self.maximumRasterWidth, fieldWidth)
        guard layoutWidth > 0, fieldHeight > 0 else { return }

        let metric = metrics(at: scale)
        let wraps = effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping
        let textTop = fieldTop + (wraps ? 0 : (fieldHeight - Int(metric.height)) / 2)
        let textLimit = wraps ? Self.maximumRasterHeight : min(Self.maximumRasterHeight, Int(metric.height))
        let left = max(0, fieldLeft)
        let right = min(context.bitmap.width, fieldLeft + layoutWidth)
        let top = max(0, fieldTop, textTop)
        let bottom = min(context.bitmap.height, fieldTop + fieldHeight, textTop + textLimit)
        guard left < right, top < bottom else { return }
        let width = right - left, height = bottom - top
        var coverage = [UInt8](repeating: 0, count: width * height)
        let mode: Int32
        switch effectiveLineBreakMode {
        case .byClipping: mode = 0
        case .byTruncatingTail: mode = 1
        case .byWordWrapping: mode = labelCell.truncatesLastVisibleLine ? 2 : 6
        case .byCharWrapping: mode = labelCell.truncatesLastVisibleLine ? 3 : 7
        case .byTruncatingHead: mode = 4
        case .byTruncatingMiddle: mode = 5
        }
        let horizontalAlignment: Int32
        switch alignment {
        case .left, .natural: horizontalAlignment = 0
        case .center: horizontalAlignment = 1
        case .right: horizontalAlignment = 2
        case .justified: horizontalAlignment = 3
        }
        let lineLimit = min(Self.maximumLines, max(1, maximumNumberOfLines == 0 ? Self.maximumLines : maximumNumberOfLines))
        let rendered = preparedUTF8.withUnsafeBufferPointer { bytes in
            coverage.withUnsafeMutableBufferPointer { destination in
                tat_render(destination.baseAddress, Int32(destination.count), Int32(width), Int32(height),
                           Int32(layoutWidth), Int32(left - fieldLeft), Int32(top - textTop),
                           bytes.baseAddress, Int32(bytes.count), isMonospace, pangoWeight,
                           font?.isItalic == true ? 1 : 0,
                           Double(pixelSize), mode, horizontalAlignment, Int32(lineLimit))
            }
        }
        guard rendered != 0 else { return }
        let rgba = (color.redComponent, color.greenComponent, color.blueComponent,
                    color.alphaComponent * context.alpha)
        context.compositeCoverage(coverage, x: left, y: top, width: width, height: height,
                                  color: rgba)
    }

    open override var acceptsFirstResponder: Bool { isSelectable }
    open override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    open override func resignFirstResponder() -> Bool { selectionAnchor = nil; needsDisplay = true; return true }

    open override func resetCursorRects() {
        if isSelectable { addCursorRect(bounds, cursor: .iBeam) }
    }

    open override func mouseDown(with event: NSEvent) {
        guard isSelectable else { super.mouseDown(with: event); return }
        _ = window?.makeFirstResponder(self)
        if let fieldEditor {
            fieldEditor.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let complete = completePlainText(at: window?.backingScaleFactor ?? 1) {
            let scale = window?.backingScaleFactor ?? 1
            completeDragStart = CGPoint(x: point.x * scale, y: point.y * scale)
            completeDragAnchor = event.modifierFlags.contains(.shift) ? selectionAnchor ?? selectedTextRange.location : nil
            complete.action(.pointer(start: completeDragStart!, end: completeDragStart!, anchor: completeDragAnchor))
            draggingSelection = true
            return
        }
        let offset = textOffset(at: convert(event.locationInWindow, from: nil))
        let anchor = event.modifierFlags.contains(.shift)
            ? selectionAnchor ?? selectedTextRange.location : offset
        select(from: anchor, to: offset)
        selectionAnchor = anchor
        draggingSelection = true
    }

    open override func mouseDragged(with event: NSEvent) {
        if let fieldEditor {
            fieldEditor.mouseDragged(with: event)
            return
        }
        if isSelectable, draggingSelection, let start = completeDragStart,
           let complete = completePlainText(at: window?.backingScaleFactor ?? 1) {
            let point = convert(event.locationInWindow, from: nil)
            let scale = window?.backingScaleFactor ?? 1
            complete.action(.pointer(start: start, end: CGPoint(x: point.x * scale, y: point.y * scale), anchor: completeDragAnchor))
            return
        }
        guard isSelectable, draggingSelection, let anchor = selectionAnchor else { return }
        select(from: anchor, to: textOffset(at: convert(event.locationInWindow, from: nil)))
    }

    open override func mouseUp(with event: NSEvent) { draggingSelection = false }

    open override func keyDown(with event: NSEvent) {
        guard isSelectable else { super.keyDown(with: event); return }
        let chord = !event.modifierFlags.intersection([.command, .control]).isEmpty
        let key = event.charactersIgnoringModifiers?.lowercased()
        if chord, key == "a" { selectAll(nil); return }
        if chord, key == "c" { copy(nil); return }
        guard [123, 124, 115, 119].contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        if let complete = completePlainText(at: window?.backingScaleFactor ?? 1) {
            complete.action(.arrow(left: event.keyCode == 123 || event.keyCode == 115,
                                   edge: event.keyCode == 115 || event.keyCode == 119,
                                   extends: event.modifierFlags.contains(.shift)))
            return
        }
        let source = stringValue as NSString
        let extends = event.modifierFlags.contains(.shift)
        let left = event.keyCode == 123 || event.keyCode == 115
        let cursor = selectionAnchor == selectedTextRange.location
            ? NSMaxRange(selectedTextRange) : selectedTextRange.location
        let next: Int
        if event.keyCode == 115 || event.keyCode == 119 {
            next = left ? 0 : source.length
        } else if !extends && selectedTextRange.length > 0 {
            next = left ? selectedTextRange.location : NSMaxRange(selectedTextRange)
        } else if left && cursor > 0 {
            next = source.rangeOfComposedCharacterSequence(at: cursor - 1).location
        } else if !left && cursor < source.length {
            next = NSMaxRange(source.rangeOfComposedCharacterSequence(at: cursor))
        } else { next = cursor }
        let anchor = extends ? selectionAnchor ?? cursor : next
        select(from: anchor, to: next)
        selectionAnchor = extends ? anchor : nil
    }

    public func selectAll(_ sender: Any?) {
        guard isSelectable else { return }
        if let complete = completePlainText(at: window?.backingScaleFactor ?? 1) {
            complete.action(.selectAll)
            return
        }
        select(from: 0, to: (stringValue as NSString).length)
        selectionAnchor = 0
    }

    public func copy(_ sender: Any?) {
        if isSelectable, let complete = completePlainText(at: window?.backingScaleFactor ?? 1) {
            complete.action(.copy)
            return
        }
        guard isSelectable, selectedTextRange.length > 0,
              selectedTextRange.length <= 65_536 else { return }
        let value = (stringValue as NSString).substring(with: selectedTextRange)
        _ = NSPasteboard.general.setString(value, forType: .string)
    }

    private func select(from anchor: Int, to cursor: Int) {
        selectedTextRange = NSRange(location: min(anchor, cursor), length: abs(cursor - anchor))
        needsDisplay = true
    }

    private func selectableLayout(at scale: CGFloat) -> SelectableLabelLayout? {
        let width = min(Self.maximumRasterWidth, max(1, Int(ceil(bounds.width * scale))))
        if let labelLayout, labelLayout.scale == scale, labelLayout.width == width { return labelLayout }
        let source = attributedStorage ?? NSAttributedString(
            string: String(decoding: preparedUTF8, as: UTF8.self), attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: textColor ?? NSColor.labelColor
            ])
        var prepared: AttributedTextDrawing.Prepared!
        effectiveAppearance.performAsCurrentDrawingAppearance {
            prepared = AttributedTextDrawing.prepare(source, scale: scale)
        }
        let lines = min(Self.maximumLines, max(1, maximumNumberOfLines == 0 ? Self.maximumLines : maximumNumberOfLines))
        labelLayout = SelectableLabelLayout(prepared: prepared, original: stringValue,
            scale: scale, width: width, mode: effectiveLineBreakMode,
            alignment: alignment, lines: lines, truncates: labelCell.truncatesLastVisibleLine)
        return labelLayout
    }

    private func textTop(at scale: CGFloat) -> CGFloat {
        if effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping { return 0 }
        return max(0, (bounds.height - CGFloat(metrics(at: scale).height) / scale) / 2)
    }

    private func textOffset(at point: NSPoint) -> Int {
        let scale = window?.backingScaleFactor ?? 1
        guard let layout = selectableLayout(at: scale) else { return 0 }
        return layout.textOffset(x: point.x * scale, y: (point.y - textTop(at: scale)) * scale)
    }

    private func drawSelectableLabel() {
        if let context = NSGraphicsContext.current,
           let complete = completePlainText(at: context.scale), let color = textColor,
           complete.draw(in: context, rect: visibleRect, color: color,
                         selection: window?.firstResponder === self ? selectedTextRange : NSRange(location: 0, length: 0),
                         attributes: selectedTextAttributes) { return }
        guard let context = NSGraphicsContext.current,
              let layout = selectableLayout(at: context.scale) else { return }
        layout.draw(in: context, bounds: bounds, top: textTop(at: context.scale),
            selection: window?.firstResponder === self ? selectedTextRange : NSRange(location: 0, length: 0),
            attributes: selectedTextAttributes)
    }

    private var usesCompletePlainText: Bool {
        isSelectable && attributedStorage == nil && maximumNumberOfLines == 0 && !usesSingleLineMode &&
            (effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping)
    }

    /// The raster host can observe settling without touching a Pango handle or scanning source.
    public var isCompleteTextLayoutReady: Bool { completeLabel?.isReady ?? false }
    public var isCompleteTextViewportReady: Bool { completeLabel?.isViewportReady ?? false }
    /// A viewport is requested when the label draws. One hidden or clipped out by every
    /// ancestor, such as a retained row scrolled past, draws nothing and so awaits nothing.
    public var isWaitingForCompleteTextViewport: Bool {
        usesCompletePlainText && !preparedUTF8.isEmpty && !isHiddenOrHasHiddenAncestor
            && !visibleRect.isEmpty && !(completeLabel?.isViewportReady ?? false)
    }

    /// On macOS a label's wrapped size is known when its table row is measured. A complete
    /// layout arrives here later, from its worker, so the automatic-height row holding it is
    /// re-measured when it does, through the same call a Mac caller makes after a change.
    private func noteEnclosingRowHeightChanged() {
        var ancestor = superview
        while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
        guard let table = ancestor as? NSTableView, table.usesAutomaticRowHeights else { return }
        let row = table.row(for: self)
        if row >= 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
    }

    private func completePlainText(at scale: CGFloat) -> CompletePlainLabelState? {
        guard usesCompletePlainText, !preparedUTF8.isEmpty else { return nil }
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth :
            (automaticLayoutWidth > 0 ? automaticLayoutWidth : bounds.width)
        guard width.isFinite, width > 0, scale.isFinite, scale > 0,
              width * scale < Double(Int32.max / 1024) else { return nil }
        if completeLabel == nil {
            completeLabel = CompletePlainLabelState { [weak self] sizeChanged in
                guard let self, let complete = completeLabel else { return }
                selectedTextRange = complete.selectedRange
                selectionAnchor = complete.anchor
                if sizeChanged {
                    naturalMetrics = nil
                    scaledMetrics = nil
                    invalidateIntrinsicContentSize()
                    noteEnclosingRowHeightChanged()
                }
                needsDisplay = true
            }
        }
        let horizontal: Int32
        switch alignment {
        case .left, .natural: horizontal = 0
        case .center: horizontal = 1
        case .right: horizontal = 2
        case .justified: horizontal = 3
        }
        let recipe = CompleteTextRecipe(generation: textGeneration, width: Int(ceil(width * scale)),
            scale: Double(scale), size: Double(max(1, min(128, (font?.pointSize ?? 13) * scale))),
            monospace: isMonospace, weight: pangoWeight, italic: font?.isItalic == true ? 1 : 0,
            characterWrapping: effectiveLineBreakMode == .byCharWrapping ? 1 : 0, alignment: horizontal)
        completeLabel?.update(recipe, text: textStorage)
        return completeLabel
    }
}
#endif
