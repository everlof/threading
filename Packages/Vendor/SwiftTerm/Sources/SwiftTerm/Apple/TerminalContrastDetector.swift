//
//  TerminalContrastDetector.swift
//  SwiftTerm
//

#if os(macOS)
import AppKit
import Foundation

/// Finds severe foreground/background collisions in immutable renderer input.
///
/// Detection belongs beside the snapshot renderer rather than the view: the
/// Metal layer can prepare and draw a frame off the main thread, and no view or
/// AppKit state may be reached from there. The result is a checked-Sendable
/// value delivered with the rest of the frame's main-actor effects.
enum TerminalContrastDetector {
    static func detect (snapshot: TerminalSnapshot,
                        context: SnapshotRenderContext) -> [TerminalTextColorConflict] {
        var conflicts: [TerminalTextColorConflict] = []
        var seen: Set<TerminalTextContrastPair> = []

        for row in snapshot.rows {
            var column = 0
            var runAttribute: Attribute?
            var runText = ""

            func flushRun () {
                guard let attribute = runAttribute,
                      let finding = conflict(
                        in: runText, attribute: attribute, context: context)
                else {
                    runText.removeAll(keepingCapacity: true)
                    return
                }
                let pair = TerminalTextContrastPair(
                    foregroundSource: finding.foregroundSource,
                    backgroundSource: finding.backgroundSource,
                    foreground: finding.foreground,
                    background: finding.background)
                if seen.insert(pair).inserted {
                    conflicts.append(finding)
                }
                runText.removeAll(keepingCapacity: true)
            }

            while column < min(snapshot.cols, row.line.count) {
                let cell = row.line.packedView(at: column)
                let attribute = cell.attribute
                if let previous = runAttribute, previous != attribute {
                    flushRun()
                }
                runAttribute = attribute
                runText.append(row.character(at: column, cell: cell))
                column += max(1, Int(cell.width))
            }
            flushRun()
        }
        return conflicts
    }

    private static func conflict (in string: String, attribute: Attribute,
                                  context: SnapshotRenderContext)
        -> TerminalTextColorConflict? {
        guard !attribute.style.contains(.invisible),
              containsMeaningfulText(string) else { return nil }

        var foreground = attribute.fg
        var background = attribute.bg
        if attribute.style.contains(.inverse) {
            swap(&foreground, &background)
            if foreground == .defaultColor { foreground = .defaultInvertedColor }
            if background == .defaultColor { background = .defaultInvertedColor }
        }

        let isBold = attribute.style.contains(.bold)
        let foregroundSource = renderedColorSource(
            foreground, isForeground: true, isBold: isBold, context: context)
        switch foregroundSource {
        case .ansi256, .trueColor:
            break
        case .defaultForeground, .defaultBackground,
             .invertedDefaultForeground, .invertedDefaultBackground:
            return nil
        }
        let backgroundSource = renderedColorSource(
            background, isForeground: false, isBold: false, context: context)

        var foregroundColor = resolvedColor(
            foreground, isForeground: true, isBold: isBold, context: context)
        let backgroundColor = resolvedColor(
            background, isForeground: false, isBold: false, context: context)
        if attribute.style.contains(.dim) {
            foregroundColor = foregroundColor.dimmedColor(towards: backgroundColor)
        }
        guard let foregroundRGB = foregroundColor.usingColorSpace(.sRGB),
              let backgroundRGB = backgroundColor.usingColorSpace(.sRGB) else { return nil }
        let flattenedForeground = composite(foregroundRGB, over: backgroundRGB)
        let ratio = contrastRatio(flattenedForeground, backgroundRGB)
        guard ratio < 1.25 else { return nil }

        return TerminalTextColorConflict(
            foregroundSource: foregroundSource,
            backgroundSource: backgroundSource,
            foreground: renderedColor(flattenedForeground),
            background: renderedColor(backgroundRGB),
            contrastRatio: ratio,
            sample: contrastSample(from: string))
    }

    private static func resolvedColor (_ color: Attribute.Color,
                                       isForeground: Bool,
                                       isBold: Bool,
                                       context: SnapshotRenderContext) -> NSColor {
        if case .trueColor(let red, let green, let blue) = color,
           !isForeground, let transform = context.trueColorBackgroundTransform {
            let rendered = transform.transform(TerminalRenderedColor(
                red: red, green: green, blue: blue))
            return NSColor(srgbRed: CGFloat(rendered.red) / 255,
                           green: CGFloat(rendered.green) / 255,
                           blue: CGFloat(rendered.blue) / 255,
                           alpha: 1)
        }
        return mapColor(color: color, isFg: isForeground, isBold: isBold,
                        context: context)
    }

    private static func renderedColorSource (
        _ color: Attribute.Color,
        isForeground: Bool,
        isBold: Bool,
        context: SnapshotRenderContext
    ) -> TerminalRenderedColorSource {
        switch color {
        case .ansi256(let rawIndex):
            let index: UInt8
            if context.useBrightColors, rawIndex < 8, isBold {
                index = rawIndex + 8
            } else if !context.useBrightColors, rawIndex > 7 {
                index = rawIndex - 8
            } else {
                index = rawIndex
            }
            return .ansi256(index: index)
        case .trueColor(let red, let green, let blue):
            return .trueColor(red: red, green: green, blue: blue)
        case .defaultColor:
            return isForeground ? .defaultForeground : .defaultBackground
        case .defaultInvertedColor:
            return isForeground
                ? .invertedDefaultForeground : .invertedDefaultBackground
        }
    }

    private static func containsMeaningfulText (_ string: String) -> Bool {
        var sampled = 0
        var printable = 0
        var containsLetterOrNumber = false
        for scalar in string.unicodeScalars {
            sampled += 1
            if isRenderable(scalar),
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                printable += 1
                containsLetterOrNumber = containsLetterOrNumber
                    || CharacterSet.alphanumerics.contains(scalar)
            }
            if printable >= 4, containsLetterOrNumber { return true }
            if sampled >= TerminalContrastSample.scanLimit { return false }
        }
        return false
    }

    private static func contrastSample (from string: String) -> String {
        var kept: [Unicode.Scalar] = []
        var scanned = 0
        var pendingSpace = false
        var truncated = false

        for scalar in string.unicodeScalars {
            scanned += 1
            if scanned > TerminalContrastSample.scanLimit {
                truncated = true
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !kept.isEmpty
                continue
            }
            guard isRenderable(scalar) else { continue }
            guard kept.count + (pendingSpace ? 1 : 0)
                    < TerminalContrastSample.characterLimit else {
                truncated = true
                break
            }
            if pendingSpace {
                kept.append(" ")
                pendingSpace = false
            }
            kept.append(scalar)
        }

        guard !kept.isEmpty else { return "" }
        var sample = String(String.UnicodeScalarView(kept))
        if truncated { sample.append(TerminalContrastSample.ellipsis) }
        return sample
    }

    private static func isRenderable (_ scalar: Unicode.Scalar) -> Bool {
        guard !CharacterSet.controlCharacters.contains(scalar) else { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return false
        default:
            return true
        }
    }

    private static func composite (_ foreground: NSColor,
                                   over background: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        guard alpha < 1 else { return foreground }
        return NSColor(srgbRed: foreground.redComponent * alpha
            + background.redComponent * (1 - alpha),
                       green: foreground.greenComponent * alpha
            + background.greenComponent * (1 - alpha),
                       blue: foreground.blueComponent * alpha
            + background.blueComponent * (1 - alpha),
                       alpha: 1)
    }

    private static func contrastRatio (_ first: NSColor,
                                       _ second: NSColor) -> Double {
        func luminance (_ color: NSColor) -> Double {
            func linear (_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let firstLuminance = luminance(first)
        let secondLuminance = luminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func renderedColor (_ color: NSColor) -> TerminalRenderedColor {
        func byte (_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, Int((value * 255).rounded()))))
        }
        return TerminalRenderedColor(red: byte(color.redComponent),
                                     green: byte(color.greenComponent),
                                     blue: byte(color.blueComponent))
    }
}
#endif
