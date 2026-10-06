#if os(Linux)
import Foundation
import AppKitTextBridge

/// The current label leaf's 4096-byte/64-style/8-line budget remains explicit. This cache
/// makes pointer hit testing independent of the complete source and preserves grapheme edges.
final class SelectableLabelLayout {
    let scale: CGFloat
    let width: Int
    private let handle: OpaquePointer
    private let boundaries: [(byte: Int, utf16: Int)]

    init?(prepared: AttributedTextDrawing.Prepared, original: String,
          scale: CGFloat, width: Int, mode: NSLineBreakMode,
          alignment: NSTextAlignment, lines: Int, truncates: Bool) {
        let lineMode: Int32
        switch mode {
        case .byClipping: lineMode = lines > 1 && prepared.utf8.contains(10) ? 8 : 0
        case .byTruncatingTail: lineMode = 1
        case .byWordWrapping: lineMode = truncates ? 2 : 6
        case .byCharWrapping: lineMode = truncates ? 3 : 7
        case .byTruncatingHead: lineMode = 4
        case .byTruncatingMiddle: lineMode = 5
        }
        let textAlignment: Int32
        switch alignment {
        case .left, .natural: textAlignment = 0
        case .center: textAlignment = 1
        case .right: textAlignment = 2
        case .justified: textAlignment = 3
        }
        let created = prepared.utf8.withUnsafeBufferPointer { text in
            prepared.spans.withUnsafeBufferPointer { spans in
                tat_label_create(text.baseAddress, Int32(text.count), spans.baseAddress,
                    Int32(spans.count), Int32(width), lineMode, textAlignment, Int32(lines))
            }
        }
        guard let created else { return nil }
        handle = created
        self.scale = scale
        self.width = width

        // A drawn ellipsis is synthetic. Clamp its hit to the real source prefix rather than
        // copying the ellipsis or admitting a split scalar/grapheme into a selection.
        var commonBytes = 0
        for (source, drawn) in zip(original.utf8, prepared.utf8) {
            guard source == drawn else { break }
            commonBytes += 1
        }
        var prefix = String(bytes: prepared.utf8.prefix(commonBytes), encoding: .utf8)
        while prefix == nil && commonBytes > 0 {
            commonBytes -= 1
            prefix = String(bytes: prepared.utf8.prefix(commonBytes), encoding: .utf8)
        }
        var values: [(byte: Int, utf16: Int)] = [(0, 0)]
        var byte = 0, utf16 = 0
        for character in prefix ?? "" {
            let value = String(character)
            byte += value.utf8.count
            utf16 += value.utf16.count
            values.append((byte, utf16))
        }
        if original.utf8.prefix(commonBytes + 1).count > commonBytes, values.count > 1 {
            values.removeLast()
        }
        boundaries = values
    }

    deinit { tat_label_destroy(handle) }

    func textOffset(x: CGFloat, y: CGFloat) -> Int {
        let byte = Int(tat_label_hit(handle, Double(x), Double(y)))
        guard byte >= 0 else { return 0 }
        let index = boundaryIndex { $0.byte >= byte }
        return boundaries[index].utf16
    }

    private func boundaryIndex(_ after: ((byte: Int, utf16: Int)) -> Bool) -> Int {
        var low = 0, high = boundaries.count - 1
        while low < high {
            let middle = low + (high - low) / 2
            if after(boundaries[middle]) { high = middle }
            else { low = middle + 1 }
        }
        return low
    }

    @MainActor
    func draw(in context: NSGraphicsContext, bounds: NSRect, top textTop: CGFloat,
              selection: NSRange, attributes: [NSAttributedString.Key: Any]) {
        let matrix = context.transform
        guard matrix.b == 0, matrix.c == 0, matrix.a > 0, matrix.d == matrix.a,
              bounds.width.isFinite, bounds.height.isFinite, bounds.height > textTop else { return }
        let origin = matrix.apply(to: NSPoint(x: 0, y: textTop))
        guard origin.x.isFinite, origin.y.isFinite,
              abs(origin.x) <= 1_000_000, abs(origin.y) <= 1_000_000 else { return }
        let deviceLeft = Int(floor(origin.x)), deviceTop = Int(floor(origin.y))
        let availableHeight = min(2048, max(0, Int(ceil(min(1_000_000, (bounds.height - textTop) * scale)))))
        let left = max(0, deviceLeft), top = max(0, deviceTop)
        let right = min(context.bitmap.width, deviceLeft + width)
        let bottom = min(context.bitmap.height, deviceTop + availableHeight)
        guard left < right, top < bottom else { return }
        let drawWidth = right - left
        let start = boundaries[boundaryIndex { $0.utf16 >= selection.location }].byte
        let end = boundaries[boundaryIndex { $0.utf16 >= NSMaxRange(selection) }].byte
        let background = (attributes[.backgroundColor] as? NSColor) ?? .controlAccentColor
        let foreground = (attributes[.foregroundColor] as? NSColor) ?? .white
        var ink = TATSelectionInk()
        ink.background_red = Double(background.redComponent)
        ink.background_green = Double(background.greenComponent)
        ink.background_blue = Double(background.blueComponent)
        ink.background_alpha = Double(background.alphaComponent)
        ink.foreground_red = Double(foreground.redComponent)
        ink.foreground_green = Double(foreground.greenComponent)
        ink.foreground_blue = Double(foreground.blueComponent)
        ink.foreground_alpha = Double(foreground.alphaComponent)
        for tileTop in stride(from: top, to: bottom, by: 128) {
            let drawHeight = min(128, bottom - tileTop)
            var rgba = [UInt8](repeating: 0, count: drawWidth * drawHeight * 4)
            let accepted = rgba.withUnsafeMutableBufferPointer {
                tat_label_render(handle, $0.baseAddress, Int32($0.count), Int32(drawWidth), Int32(drawHeight),
                    Int32(left - deviceLeft), Int32(tileTop - deviceTop), context.antialiasesText ? 1 : 0,
                    Int32(start), Int32(end), ink)
            }
            guard accepted == 1 else { return }
            for row in 0..<drawHeight {
                for column in 0..<drawWidth {
                    let offset = (row * drawWidth + column) * 4
                    guard rgba[offset + 3] > 0 else { continue }
                    context.composite(x: left + column, y: tileTop + row,
                        color: (CGFloat(rgba[offset]) / 255, CGFloat(rgba[offset + 1]) / 255,
                                CGFloat(rgba[offset + 2]) / 255, CGFloat(rgba[offset + 3]) / 255 * context.alpha),
                        coverage: 1)
                }
            }
        }
    }
}
#endif
