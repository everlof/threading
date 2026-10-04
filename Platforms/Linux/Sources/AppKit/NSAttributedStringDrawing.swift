#if os(Linux)
import Foundation
import AppKitTextBridge

public extension NSAttributedString.Key {
    static let font = NSAttributedString.Key("NSFont")
    static let foregroundColor = NSAttributedString.Key("NSColor")
    static let backgroundColor = NSAttributedString.Key("NSBackgroundColor")
    static let kern = NSAttributedString.Key("NSKern")
    static let underlineStyle = NSAttributedString.Key("NSUnderline")
    static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
}

public extension NSMutableAttributedString {
    /// Darwin Foundation supplies the empty convenience initializer used by menu rows.
    convenience init() { self.init(string: "") }
}

open class NSParagraphStyle: NSObject {
    open var alignment: NSTextAlignment = .natural
    open var lineBreakMode: NSLineBreakMode = .byWordWrapping
}

open class NSMutableParagraphStyle: NSParagraphStyle {}

/// The attributed drawing leaf keeps byte count, style count, line count and raster area
/// independent of a file or transcript's total length. Layout and render share the same Pango
/// run attributes, and both pass the complete attributed string to one Pango layout.
enum AttributedTextDrawing {
    static let maximumUTF8Bytes = 4096
    static let maximumSpans = 64
    static let maximumRasterWidth = 2048
    static let maximumRasterHeight = 128

    struct Prepared {
        var utf8: [UInt8]
        var spans: [TATStyleSpan]

        func measure(wrappingAt width: Int = 0, maximumLines: Int = 8,
                     characterWrapping: Bool = false) -> TATMetrics? {
            guard !utf8.isEmpty else { return TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0) }
            var result = TATMetrics(width: 0, height: 0, baseline: 0, glyphs: 0)
            let accepted = utf8.withUnsafeBufferPointer { text in
                spans.withUnsafeBufferPointer { styles in
                    if width > 0 {
                        return tat_attributed_measure_wrapped(
                            text.baseAddress, Int32(text.count), styles.baseAddress,
                            Int32(styles.count), Int32(width), Int32(maximumLines),
                            characterWrapping ? 1 : 0, &result)
                    }
                    return tat_attributed_measure(text.baseAddress, Int32(text.count),
                                                  styles.baseAddress, Int32(styles.count), &result)
                }
            }
            return accepted == 1 ? result : nil
        }
    }

    private static func unit(_ value: CGFloat) -> Double {
        value.isFinite ? Double(max(0, min(1, value))) : 0
    }

    private static func style(_ attributes: [NSAttributedString.Key: Any],
                              start: Int, end: Int, scale: CGFloat) -> TATStyleSpan {
        let font = (attributes[.font] as? NSFont) ?? .systemFont(ofSize: 13)
        let foreground = (attributes[.foregroundColor] as? NSColor) ?? .black
        let background = (attributes[.backgroundColor] as? NSColor) ?? .clear
        let weight = font.weight.rawValue
        var span = TATStyleSpan()
        span.start_byte = Int32(start)
        span.end_byte = Int32(end)
        span.monospace = font.familyName?.contains("Mono") == true ? 1 : 0
        span.weight = weight >= NSFont.Weight.bold.rawValue ? 3 :
            weight >= NSFont.Weight.semibold.rawValue ? 2 :
            weight >= NSFont.Weight.medium.rawValue ? 1 : 0
        span.underline = ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) > 0 ? 1 : 0
        span.pixel_size = Double(max(1, min(128, font.pointSize * scale)))
        let authoredKern = (attributes[.kern] as? NSNumber)?.doubleValue ?? 0
        span.kern = authoredKern.isFinite
            ? max(-64, min(64, authoredKern * Double(scale))) : 0
        span.foreground_red = unit(foreground.redComponent)
        span.foreground_green = unit(foreground.greenComponent)
        span.foreground_blue = unit(foreground.blueComponent)
        span.foreground_alpha = unit(foreground.alphaComponent)
        span.background_red = unit(background.redComponent)
        span.background_green = unit(background.greenComponent)
        span.background_blue = unit(background.blueComponent)
        span.background_alpha = unit(background.alphaComponent)
        return span
    }

    static func prepare(_ string: NSAttributedString, scale: CGFloat) -> Prepared {
        // Foundation may copy `string.string` in full. Read only the UTF-16 prefix needed to
        // fill the UTF-8 budget before iterating attributes on a main-actor drawing path.
        let prefixLength = min(string.length, maximumUTF8Bytes + 1)
        let source = string.attributedSubstring(from: NSRange(location: 0, length: prefixLength)).string
        let byteBudget = source.utf8.prefix(maximumUTF8Bytes + 1).count > maximumUTF8Bytes
            ? maximumUTF8Bytes - 3 : maximumUTF8Bytes
        var result = Prepared(utf8: [], spans: [])
        result.utf8.reserveCapacity(min(byteBudget, 256))
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        var stoppedEarly = string.length > prefixLength
        string.enumerateAttributes(in: fullRange, options: []) { attributes, range, stop in
            if result.spans.count >= maximumSpans - 1 {
                stoppedEarly = true
                stop.pointee = true
                return
            }
            guard let sourceRange = Range(range, in: source) else {
                stoppedEarly = true
                stop.pointee = true
                return
            }
            let start = result.utf8.count
            for scalar in source[sourceRange].unicodeScalars {
                let bytes = Array(String(scalar).utf8)
                if result.utf8.count > byteBudget - bytes.count {
                    stoppedEarly = true
                    stop.pointee = true
                    break
                }
                result.utf8.append(contentsOf: bytes)
            }
            if result.utf8.count > start {
                result.spans.append(style(attributes, start: start,
                                          end: result.utf8.count, scale: scale))
            }
        }
        if stoppedEarly {
            while result.utf8.count > maximumUTF8Bytes - 3 {
                var byte: UInt8
                repeat { byte = result.utf8.removeLast() } while byte & 0xc0 == 0x80
            }
            while let last = result.spans.last,
                  Int(last.start_byte) >= result.utf8.count {
                result.spans.removeLast()
            }
            if !result.spans.isEmpty {
                result.spans[result.spans.count - 1].end_byte = Int32(result.utf8.count)
            }
            let start = result.utf8.count
            result.utf8.append(contentsOf: "…".utf8)
            if result.spans.isEmpty {
                result.spans.append(style([:], start: start, end: result.utf8.count, scale: scale))
            } else {
                result.spans[result.spans.count - 1].end_byte = Int32(result.utf8.count)
            }
        }
        return result
    }

    static func draw(_ string: NSAttributedString, at point: NSPoint?, in rect: NSRect?,
                     lineBreakMode: NSLineBreakMode? = nil,
                     textAlignment: NSTextAlignment? = nil,
                     maximumLines: Int = 8,
                     truncatesLastVisibleLine: Bool = true) {
        guard let context = NSGraphicsContext.current, context.alpha > 0 else { return }
        let matrix = context.transform
        guard matrix.b == 0, matrix.c == 0, matrix.a.isFinite, matrix.d.isFinite,
              matrix.a > 0, abs(matrix.d) == matrix.a else { return }
        let scale = matrix.a
        let prepared = prepare(string, scale: scale)
        guard !prepared.utf8.isEmpty else { return }

        let localTop: CGFloat
        let localLeft: CGFloat
        let layoutWidth: Int32
        let rasterWidth: Int
        let rasterHeight: Int
        let mode: Int32
        let alignment: Int32
        if let rect {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0,
                  rect.width * scale <= 1_000_000,
                  rect.height * scale <= 1_000_000 else { return }
            localLeft = rect.minX
            localTop = matrix.d < 0 ? rect.maxY : rect.minY
            rasterWidth = min(maximumRasterWidth, Int(ceil(rect.width * scale)))
            rasterHeight = min(maximumRasterHeight, Int(ceil(rect.height * scale)))
            layoutWidth = Int32(rasterWidth)
            let paragraph = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
            switch lineBreakMode ?? paragraph?.lineBreakMode ?? .byWordWrapping {
            case .byClipping: mode = 0
            case .byTruncatingTail: mode = 1
            case .byWordWrapping: mode = truncatesLastVisibleLine ? 2 : 6
            case .byCharWrapping: mode = truncatesLastVisibleLine ? 3 : 7
            case .byTruncatingHead: mode = 4
            case .byTruncatingMiddle: mode = 5
            }
            switch textAlignment ?? paragraph?.alignment ?? .natural {
            case .left, .natural: alignment = 0
            case .center: alignment = 1
            case .right: alignment = 2
            case .justified: alignment = 3
            }
        } else if let point {
            guard let metric = prepared.measure(), metric.width > 0, metric.height > 0 else { return }
            localLeft = point.x
            localTop = matrix.d < 0 ? point.y + CGFloat(metric.height) / scale : point.y
            rasterWidth = min(maximumRasterWidth, Int(metric.width))
            rasterHeight = min(maximumRasterHeight, Int(metric.height))
            layoutWidth = 0
            mode = 0
            alignment = 0
        } else { return }

        let origin = matrix.apply(to: NSPoint(x: localLeft, y: localTop))
        guard origin.x.isFinite, origin.y.isFinite,
              abs(origin.x) <= 1_000_000, abs(origin.y) <= 1_000_000 else { return }
        let deviceLeft = Int(floor(origin.x)), deviceTop = Int(floor(origin.y))
        let left = max(0, deviceLeft), top = max(0, deviceTop)
        let right = min(context.bitmap.width, deviceLeft + rasterWidth)
        let bottom = min(context.bitmap.height, deviceTop + rasterHeight)
        guard left < right, top < bottom else { return }
        let width = right - left, height = bottom - top
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let accepted = prepared.utf8.withUnsafeBufferPointer { text in
            prepared.spans.withUnsafeBufferPointer { styles in
                rgba.withUnsafeMutableBufferPointer { pixels in
                    tat_attributed_render(pixels.baseAddress, Int32(pixels.count),
                                          Int32(width), Int32(height), layoutWidth,
                                          Int32(left - deviceLeft), Int32(top - deviceTop),
                                          mode, alignment, Int32(min(8, max(1, maximumLines))),
                                          context.antialiasesText ? 1 : 0,
                                          text.baseAddress, Int32(text.count),
                                          styles.baseAddress, Int32(styles.count))
                }
            }
        }
        guard accepted == 1 else { return }
        for row in 0..<height {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                let coverage = rgba[offset + 3]
                guard coverage > 0 else { continue }
                context.composite(x: left + column, y: top + row,
                                  color: (CGFloat(rgba[offset]) / 255,
                                          CGFloat(rgba[offset + 1]) / 255,
                                          CGFloat(rgba[offset + 2]) / 255,
                                          CGFloat(coverage) / 255 * context.alpha),
                                  coverage: 1)
            }
        }
    }
}

public extension NSAttributedString {
    func size() -> NSSize {
        guard let metric = AttributedTextDrawing.prepare(self, scale: 1).measure() else { return .zero }
        var width = CGFloat(metric.width)
        var height = CGFloat(metric.height)
        // Pango rounds a shaped line to device pixels. A single-line control that measures
        // at 1× and draws at the Linux window's 2× backing scale can need one more device
        // pixel than twice its measured width. That is enough for tail ellipsizing to replace
        // several visible letters on a button sized to its own intrinsic content.
        let paragraph = length > 0
            ? attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil
        if paragraph?.lineBreakMode == .byTruncatingTail ||
            paragraph?.lineBreakMode == .byClipping,
           let backing = AttributedTextDrawing.prepare(self, scale: 2).measure() {
            width = max(width, ceil(CGFloat(backing.width) / 2))
            height = max(height, ceil(CGFloat(backing.height) / 2))
        }
        return NSSize(width: width, height: height)
    }

    func draw(at point: NSPoint) {
        AttributedTextDrawing.draw(self, at: point, in: nil)
    }

    func draw(in rect: NSRect) {
        AttributedTextDrawing.draw(self, at: nil, in: rect)
    }
}

public extension NSString {
    private func boundedAttributed(_ attributes: [NSAttributedString.Key: Any]?) -> NSAttributedString {
        let count = min(length, AttributedTextDrawing.maximumUTF8Bytes)
        let prefix = substring(to: count)
        let text = count < length ? prefix + "…" : prefix
        return NSAttributedString(string: text, attributes: attributes)
    }

    func size(withAttributes attributes: [NSAttributedString.Key: Any]? = nil) -> NSSize {
        boundedAttributed(attributes).size()
    }

    func draw(at point: NSPoint, withAttributes attributes: [NSAttributedString.Key: Any]? = nil) {
        boundedAttributed(attributes).draw(at: point)
    }

    func draw(in rect: NSRect, withAttributes attributes: [NSAttributedString.Key: Any]? = nil) {
        boundedAttributed(attributes).draw(in: rect)
    }
}

public extension String {
    /// AppKit exposes NSString's drawing methods on Swift strings through bridging. Linux
    /// Foundation has no Objective-C bridge, so keep the same call available to shared views.
    func draw(at point: NSPoint, withAttributes attributes: [NSAttributedString.Key: Any]? = nil) {
        (self as NSString).draw(at: point, withAttributes: attributes)
    }
}
#endif
