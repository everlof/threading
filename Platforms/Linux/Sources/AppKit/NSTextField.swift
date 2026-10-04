#if os(Linux)
import Foundation
import AppKitTextBridge

public enum NSTextAlignment: Int, Sendable { case left = 0, right = 1, center = 2, justified = 3, natural = 4 }
public enum NSLineBreakMode: Int, Sendable {
    case byWordWrapping = 0, byCharWrapping = 1, byClipping = 2
    case byTruncatingHead = 3, byTruncatingTail = 4, byTruncatingMiddle = 5
}

@MainActor
public final class NSTextFieldCell {
    weak var owner: NSTextField?
    /// Linux's Pango label has no private AppKit cell padding: its shaped bounds are its cell.
    public var cellSize: NSSize { owner?.intrinsicContentSize ?? .zero }
    public func cellSize(forBounds bounds: NSRect) -> NSSize { cellSize }
    public func titleRect(forBounds bounds: NSRect) -> NSRect { bounds }
    public var truncatesLastVisibleLine = false {
        didSet {
            owner?.needsDisplay = true
            owner?.invalidateIntrinsicContentSize()
        }
    }
}

/// A bounded, Pango-shaped label with attributed style runs. Text entry, selection, and IME
/// remain separate platform services; those properties are deliberately absent.
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

    private var textStorage = ""
    open var stringValue: String {
        get { textStorage }
        set {
            textStorage = newValue
            attributedStorage = nil
            setAccessibilityRole(.staticText)
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
    open var textColor: NSColor? = .labelColor { didSet { needsDisplay = true } }
    open var alignment: NSTextAlignment = .natural { didSet { needsDisplay = true } }
    open var lineBreakMode: NSLineBreakMode = .byClipping { didSet { invalidateTextMetrics() } }
    open var maximumNumberOfLines: Int = 0 { didSet { invalidateTextMetrics() } }
    open var usesSingleLineMode = false { didSet { invalidateTextMetrics() } }
    /// A wrapping label measures its intrinsic height at this width while its frame still
    /// comes from layout. Zero lets it report the natural, unwrapped line width.
    open var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet { invalidateTextMetrics() }
    }
    private lazy var labelCell: NSTextFieldCell = {
        let cell = NSTextFieldCell()
        cell.owner = self
        return cell
    }()
    open var cell: NSTextFieldCell? { labelCell }
    open var isEditable = false {
        didSet { precondition(!isEditable, "Linux NSTextField currently supports labels, not editing") }
    }
    open var isSelectable = false {
        didSet { precondition(!isSelectable, "Linux NSTextField currently supports labels, not selection") }
    }
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

    public convenience init(wrappingLabelWithString string: String) {
        self.init(labelWithString: string)
        lineBreakMode = .byWordWrapping
    }

    open override var isFlipped: Bool { true }

    open override var intrinsicContentSize: NSSize {
        let scale = window?.backingScaleFactor ?? 1
        let metric = metrics(at: scale)
        return NSSize(width: CGFloat(metric.width) / scale,
                      height: CGFloat(metric.height) / scale)
    }

    open override func viewDidMoveToWindow() {
        // A tight stack can measure before attachment. Its intrinsic width must be recomputed
        // at the scale used to shape pixels when the label gains or changes a window.
        invalidateIntrinsicContentSize()
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
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private func metrics(at scale: CGFloat) -> TATMetrics {
        if scale == 1, let naturalMetrics { return naturalMetrics }
        if let scaledMetrics, scaledMetrics.scale == scale { return scaledMetrics.metrics }
        let wraps = effectiveLineBreakMode == .byWordWrapping || effectiveLineBreakMode == .byCharWrapping
        let lineLimit = min(Self.maximumLines, max(1, maximumNumberOfLines == 0 ? Self.maximumLines : maximumNumberOfLines))
        let wrapWidth = wraps && preferredMaxLayoutWidth.isFinite && preferredMaxLayoutWidth > 0
            ? Int(ceil(min(CGFloat(Self.maximumRasterWidth), preferredMaxLayoutWidth * scale))) : 0
        if let attributedStorage {
            let result = AttributedTextDrawing.prepare(attributedStorage, scale: scale)
                .measure(wrappingAt: wrapWidth, maximumLines: lineLimit,
                         characterWrapping: effectiveLineBreakMode == .byCharWrapping)
                ?? TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
            if scale == 1 { naturalMetrics = result }
            else { scaledMetrics = (scale, result) }
            return result
        }
        var result = TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
        let size = max(1, min(128, (font?.pointSize ?? 13) * scale))
        var emptyByte: UInt8 = 0
        withUnsafePointer(to: &emptyByte) { emptyPointer in
            preparedUTF8.withUnsafeBufferPointer { bytes in
                if wraps {
                    if wrapWidth > 0 {
                        _ = tat_measure_wrapped(bytes.baseAddress ?? emptyPointer,
                                                Int32(bytes.count), isMonospace, pangoWeight,
                                                Double(size), Int32(lineLimit), Int32(wrapWidth),
                                                effectiveLineBreakMode == .byCharWrapping ? 1 : 0,
                                                &result)
                    } else {
                        _ = tat_measure_paragraphs(bytes.baseAddress ?? emptyPointer,
                                                   Int32(bytes.count), isMonospace, pangoWeight,
                                                   Double(size), Int32(lineLimit), &result)
                    }
                } else {
                    _ = tat_measure(bytes.baseAddress ?? emptyPointer, Int32(bytes.count),
                                    isMonospace, pangoWeight, Double(size), &result)
                }
            }
        }
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
                           Double(pixelSize), mode, horizontalAlignment, Int32(lineLimit))
            }
        }
        guard rendered != 0 else { return }
        let rgba = (color.redComponent, color.greenComponent, color.blueComponent,
                    color.alphaComponent * context.alpha)
        context.compositeCoverage(coverage, x: left, y: top, width: width, height: height,
                                  color: rgba)
    }
}
#endif
