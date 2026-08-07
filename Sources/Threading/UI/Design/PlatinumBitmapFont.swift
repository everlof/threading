import AppKit

/// The open one-bit UI face used when Platinum cannot resolve Apple's Charcoal.
///
/// This is a Swift port of Systemless 0.2.1's Jarrah 12 artwork. Jarrah is independently
/// hand-drawn under OFL-1.1, with its advances and bearings conformed to the classic Mac 12px
/// system strike. That makes it a materially closer legal substitute than asking modern
/// CoreText to smooth Geneva: it preserves QuickDraw's hard pixel contract and period metrics
/// without redistributing any Apple font data. The reserved Systemless/Jarrah names are not
/// presented as the name of this modified, embedded representation.
///
/// Source: `systemless-0.2.1/src/quickdraw/fonts/pixel_font/chicago12.rs`.
/// Copyright (c) 2026 Ben Letchford. Licensed under SIL OFL 1.1; the complete license and
/// source record ship beside the app's other font notices.
@MainActor
enum PlatinumBitmapFont {
    private struct Glyph {
        let advance: Int
        let width: Int
        let height: Int
        let xOffset: Int
        let yOffset: Int
        let rows: [UInt16]
    }

    private struct Face {
        let ascent: Int
        let descent: Int
        let glyphs: [UInt32: Glyph]
    }

    /// Record: codepoint:u16, advance:u8, width:u8, height:u8, x/y offsets:i8,
    /// then one right-aligned u16 bitmap per top-to-bottom row. The three-byte header is
    /// record count, ascent, descent. Encoding the readable upstream rows keeps this file
    /// compact while the decoder remains simple enough to audit against the source.
    private static let encoded = """
    XwwDACAEAAAE/wAhBgIIAvcAAwADAAMAAwADAAMAAAADACIHBQMC9wAbABsAGwAjCgcFAfgANgB/ADYAfwA2ACQHBQcB9wAEAA8AFAAOAAUAHgAE
    ACULBgcB9wAxADIABAAIABMAIwADACYKBwgB9wA4AGwAbAA4AHMAZgBzAD0AJwMCAwH3AAMAAwADACgFAwkB9wABAAMABgAGAAYABgAGAAMAAQAp
    BQMJAfcABAAGAAMAAwADAAMAAwAGAAQAKgcFAwH3ABUADgAVACsHBQUB+QAEAAQAHwAEAAQALAQCAwH+AAMAAwACAC0HBQEB+wAfAC4EAgIB/gAD
    AAMALwcGCAH3AAMABgAMAAwAGAAYADAAMAAwCAYJAfcAHgAzADcANwA7ADsAMwAzAB4AMQgECQL3AAYADgAGAAYABgAGAAYABgAPADIIBgkB9wAe
    ADMAAwAGAAwAGAAwADAAPwAzCAYJAfcAHgAzAAMADgADAAMAAwAzAB4ANAgGCQH3AAcADwAbADMAPwA/AAMAAwADADUIBgkB9wA/ADAAMAA+AAMA
    AwADADMAHgA2CAYJAfcADgAYADAAPgAzADMAMwAzAB4ANwgGCQH3AD8AAwAGAAYADAAMABgAGAAYADgIBgkB9wAeADMAMwAeADMAMwAzADMAHgA5
    CAYJAfcAHgAzADMAMwAfAAMAAwAGABwAOgQCBwH6AAMAAwAAAAAAAAADAAMAOwQCBwH6AAMAAwAAAAAAAwADAAIAPAYEBwD4AAEAAgAEAAgABAAC
    AAEAPQgFAwH5AB8AAAAfAD4GBAcA+AAIAAQAAgABAAIABAAIAD8IBgkB9wAeADMAAwAGAAwADAAAAAwADABACwgGAfcAfgDDANsA3gDAAH4AQQgG
    CQH3AAwAHgAeADMAMwA/AD8AMwAzAEIIBgkB9wA+ADMAMwA+ADMAMwAzADMAPgBDCAYJAfcAHwAxADAAMAAwADAAMAAxAB8ARAgGCQH3AD4AMwAz
    ADMAMwAzADMAMwA+AEUHBgkB9wA/ADAAMAAwAD4AMAAwADAAPwBGBwYJAfcAPwAwADAAMAA+ADAAMAAwADAARwgGCQH3AB8AMQAwADAANwAzADMA
    MQAfAEgIBgkB9wAzADMAMwAzAD8AMwAzADMAMwBJBgIJAvcAAwADAAMAAwADAAMAAwADAAMASgcFCQD3AAMAAwADAAMAAwADABsAGwAOAEsJBgkB
    9wAzADYAPAA4ADgAPAA2ADMAMwBMBwYJAfcAMAAwADAAMAAwADAAMAAwAD8ATQwKCQH3A4cDzwN7A3sDMwMzAwMDAwMDAE4JBwkB9wBjAHMAewBv
    AGcAYwBjAGMAYwBPCAYJAfcAHgAzADMAMwAzADMAMwAzAB4AUAgGCQH3AD4AMwAzADMAPgAwADAAMAAwAFEIBgkB9wAeADMAMwAzADMAMwA3ADYA
    HwBSCAYJAfcAPgAzADMAMwA+ADgANgAzADMAUwcGCQH3AB8AMQAwAB4AAwAjACMAMwAeAFQGBgkA9wA/AAwADAAMAAwADAAMAAwADABVCAYJAfcA
    MwAzADMAMwAzADMAMwAzAB4AVggGCQH3ADMAMwAzADMAHgAeAAwADAAMAFcMCgkB9wMzAzMDMwMzA3sDewO3AYYBhgBYCAYJAfcAMwAzAB4ADAAM
    AB4AMwAzADMAWQgGCQH3ADMAMwAeAB4ADAAMAAwADAAMAFoIBgkB9wA/AAMABgAMAAwAGAAwADAAPwBbBQMLAfYABwAGAAYABgAGAAYABgAGAAYA
    BgAHAFwHBgkB9wAwADAAGAAYAAwADAAGAAYAAwBdBQMLAfYABwADAAMAAwADAAMAAwADAAMAAwAHAF4IBQMC9wAEAAoAEQBfCAgBAAIA/wBgBgMC
    AfYABgADAGEIBgcB+QAeAAMAHwAzADMANwAbAGIIBgkB9wAwADAAPgAzADMAMwAzADMAPgBjBwUHAfkADwAZABgAGAAYABkADwBkCAYJAfcAAwAD
    AB8AMwAzADMAMwAzAB8AZQgGBwH5AB4AMwAzAD8AMAAxAB4AZgYECQH3AAcADAAPAAwADAAMAAwADAAMAGcIBgkB+QAfADMAMwAzAB8AAwAzADMA
    HgBoCAYJAfcAMAAwAD4AMwAzADMAMwAzADMAaQQCCQH3AAMAAAADAAMAAwADAAMAAwADAGoGBAwA9wADAAAAAwADAAMAAwADAAMAAwADAA4ADABr
    CAYJAfcAMAAwADMANgA8ADgAPAA2ADMAbAQCCQH3AAMAAwADAAMAAwADAAMAAwADAG0MCgcB+QP/AzMDMwMzAzMDMwMzAG4IBgcB+QA+ADMAMwAz
    ADMAMwAzAG8IBgcB+QAeADMAMwAzADMAMwAeAHAIBgkB+QA+ADMAMwAzADMAMwA+ADAAMABxCAYJAfkAHwAzADMAMwAzADMAHwADAAMAcgYFBwH5
    ABsAHQAYABgAGAAYABgAcwcFBwH5AA8AGQAcAA4ABwATAB4AdAYECQH3AAwADAAPAAwADAAMAAwADQAHAHUIBgcB+QAzADMAMwAzADMANwAbAHYI
    BgcB+QAzADMAMwAeAB4ADAAMAHcMCgcB+QMzAzMDMwN7A3sDtwGGAHgIBgcB+QAzAB4ADAAMAAwAHgAzAHkIBggB+QAzADMAMwAzAB8AAwAzAB4A
    eggGBwH5AD8ABgAMABgAMAAwAD8AewUECgH2AAMABgAGAAYADAAGAAYABgAGAAMAfAUCCwL2AAMAAwADAAMAAwADAAMAAwADAAMAAwB9BQQKAfYA
    DAAGAAYABgADAAYABgAGAAYADAB+CAcCAfsAMQBO
    """

    private static let commandGlyph = Glyph(
        advance: 12,
        width: 9,
        height: 9,
        xOffset: 1,
        yOffset: -9,
        rows: [0x0C6, 0x115, 0x115, 0x0FE, 0x028, 0x0FE, 0x115, 0x115, 0x0C6]
    )

    private static let face: Face? = {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              data.count >= 3 else { return nil }
        var cursor = data.startIndex
        func byte() -> UInt8? {
            guard cursor < data.endIndex else { return nil }
            defer { cursor += 1 }
            return data[cursor]
        }
        guard let rawCount = byte(), let rawAscent = byte(), let rawDescent = byte() else {
            return nil
        }
        var glyphs: [UInt32: Glyph] = [:]
        for _ in 0..<Int(rawCount) {
            guard let high = byte(), let low = byte(),
                  let advance = byte(), let width = byte(), let height = byte(),
                  let xOffset = byte(), let yOffset = byte() else { return nil }
            var rows: [UInt16] = []
            rows.reserveCapacity(Int(height))
            for _ in 0..<Int(height) {
                guard let rowHigh = byte(), let rowLow = byte() else { return nil }
                rows.append((UInt16(rowHigh) << 8) | UInt16(rowLow))
            }
            glyphs[(UInt32(high) << 8) | UInt32(low)] = Glyph(
                advance: Int(advance),
                width: Int(width),
                height: Int(height),
                xOffset: Int(Int8(bitPattern: xOffset)),
                yOffset: Int(Int8(bitPattern: yOffset)),
                rows: rows
            )
        }
        glyphs[0x2318] = commandGlyph
        return Face(ascent: Int(rawAscent), descent: Int(rawDescent), glyphs: glyphs)
    }()

    static func advance(of text: String) -> Int? {
        guard let face else { return nil }
        let scalars = Array(text.unicodeScalars)
        var result = 0
        for (index, scalar) in scalars.enumerated() {
            guard let glyph = face.glyphs[scalar.value] else { return nil }
            // Multiple spaces in imported menu specimens represent a trailing shortcut
            // column. QuickDraw's menu manager expands that run; the semantic menu API will
            // eventually carry the shortcut separately, but preserving the expansion here
            // keeps arbitrary ordinary spaces at the face's authored four-pixel advance.
            let isExpandedSpace = scalar.value == 0x20
                && ((index > 0 && scalars[index - 1].value == 0x20)
                    || (index + 1 < scalars.count && scalars[index + 1].value == 0x20))
            result += isExpandedSpace ? 6 : glyph.advance
        }
        return result
    }

    /// Draws at a top-down QuickDraw baseline and returns false for unsupported Unicode so
    /// the caller can preserve the user's ordinary AppKit fallback.
    @discardableResult
    static func draw(
        _ text: String,
        penX: CGFloat,
        baselineFromTop: CGFloat,
        in rect: NSRect,
        ink: NSColor
    ) -> Bool {
        guard let face else { return false }
        let scalars = Array(text.unicodeScalars)
        guard scalars.allSatisfy({ face.glyphs[$0.value] != nil }) else { return false }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        var x = floor(penX)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        ink.setFill()

        for (index, scalar) in scalars.enumerated() {
            guard let glyph = face.glyphs[scalar.value] else { return false }
            let glyphTop = baselineFromTop + CGFloat(glyph.yOffset)
            for (rowIndex, bits) in glyph.rows.enumerated() {
                let visualY = glyphTop + CGFloat(rowIndex)
                let y = isFlipped
                    ? rect.minY + visualY
                    : rect.maxY - visualY - 1
                for column in 0..<glyph.width where
                    bits & (UInt16(1) << (glyph.width - column - 1)) != 0 {
                    NSRect(
                        x: x + CGFloat(glyph.xOffset + column),
                        y: y,
                        width: 1,
                        height: 1
                    ).fill()
                }
            }
            let isExpandedSpace = scalar.value == 0x20
                && ((index > 0 && scalars[index - 1].value == 0x20)
                    || (index + 1 < scalars.count && scalars[index + 1].value == 0x20))
            x += CGFloat(isExpandedSpace ? 6 : glyph.advance)
        }
        return true
    }

    static func centeredBaseline(in rect: NSRect, offset: CGFloat = 0) -> CGFloat? {
        guard let face else { return nil }
        let lineHeight = face.ascent + face.descent
        return floor((rect.height - CGFloat(lineHeight)) / 2) + CGFloat(face.ascent) + offset
    }
}
