import AppKit

/// The Linux shell maps the roles read by retained production controls to a checked export of
/// the Threading theme. Geometry remains the production default. This host adapter belongs only
/// to WindowHarness; the generic Harness keeps its separate symbol trap.
@MainActor
public protocol ThemeDerivedContent: AnyObject {
    func rederiveThemedContent()
}

@MainActor
public enum Design {
    @MainActor public struct Ink {
        public let label: NSColor
        public let secondary: NSColor
        public let tertiary: NSColor
        public let quaternary: NSColor
        public let surface: NSColor
        public let surfaceHover: NSColor
        public let border: NSColor

        public init(on ground: NSColor, surface customSurface: NSColor? = nil) {
            let light = LinuxTheme.neutralInk(on: ground, dark: false)
            let dark = LinuxTheme.neutralInk(on: ground, dark: true)
            let lightLabel = light.label
            let darkLabel = dark.label
            let lightSecondary = light.secondary
            let darkSecondary = dark.secondary
            let lightTertiary = light.tertiary
            let darkTertiary = dark.tertiary
            let lightQuaternary = light.quaternary
            let darkQuaternary = dark.quaternary
            label = NSColor(name: NSColor.Name("threading.linux.ink.label")) { appearance in
                appearance.name == .darkAqua ? darkLabel : lightLabel
            }
            secondary = NSColor(name: NSColor.Name("threading.linux.ink.secondary")) { appearance in
                appearance.name == .darkAqua ? darkSecondary : lightSecondary
            }
            tertiary = NSColor(name: NSColor.Name("threading.linux.ink.tertiary")) { appearance in
                appearance.name == .darkAqua ? darkTertiary : lightTertiary
            }
            quaternary = NSColor(name: NSColor.Name("threading.linux.ink.quaternary")) { appearance in
                appearance.name == .darkAqua ? darkQuaternary : lightQuaternary
            }
            surface = customSurface ?? LinuxTheme.color("controlResting")
            surfaceHover = LinuxTheme.color("controlHover")
            border = LinuxTheme.color("border")
        }

        public static var selection: Ink { Ink(on: Design.Surface.selectionFill) }
    }

    public enum Accessibility {
        public static let focusRingWidth: CGFloat = 2
        public static let increasesContrast = false
    }
    public enum Opacity { public static let disabledControl: CGFloat = 0.42 }
    public enum Radius {
        public static let border: CGFloat = 1
        // AppThemeStyles.threading gives both light and dark variants a 7pt control corner.
        public static let control: CGFloat = 7
        public static let controlBorder: CGFloat = 1
        public static func control(fitting size: NSSize) -> CGFloat {
            min(control, max(0, min(size.width, size.height) / 2))
        }
    }
    public enum Surface {
        public static var accent: NSColor { LinuxTheme.color("accent") }
        public static var bevelHighlight: NSColor { LinuxTheme.color("bevelHighlight") }
        public static var bevelShadow: NSColor { LinuxTheme.color("bevelShadow") }
        public static var divider: NSColor { LinuxTheme.color("divider") }
        public static var border: NSColor { LinuxTheme.color("border") }
        // Owned beside `Ink.selection`, which reads it, so every target linking this boundary
        // has the selected-row ground without also linking the sidebar host's vocabulary.
        public static var selectionFill: NSColor { LinuxTheme.color("accent") }
        public static var selectionFillUnemphasized: NSColor { LinuxTheme.color("accentMuted") }
    }
    public enum Spacing {
        public static let small: CGFloat = 6
        public static let inset: CGFloat = 12
    }
    public enum Motion { public static let quick: TimeInterval = 0.15 }
    public enum Size {
        public static let tabHeight: CGFloat = 28
        public static let footerHeight: CGFloat = 48
        public static let toolbarButtonWidth: CGFloat = 30
        public static let toolbarButtonHeight: CGFloat = 28
        public static let inlineButtonTarget: CGFloat = 20
        public static let splitMenuWidth: CGFloat = 24
        public static let chipHeight: CGFloat = 26
        public static let compactSplitMenuWidth: CGFloat = 12
        public static let compactSubmitHeight: CGFloat = 18
        public static let deviceControlButtonSize: CGFloat = 40
        public static let tabIconSlot: CGFloat = 16
        public static let inlineButtonGlyph: CGFloat = 12
        public static let deviceControlButtonGlyph: CGFloat = 22
    }

    public enum Symbol {
        public enum Role { case toolbar, control
            public var pointSize: CGFloat { self == .toolbar ? 14 : 12 }
        }
        public static func slot(inControlOfHeight height: CGFloat) -> CGFloat { height - 10 }
        public static func role(forSlot slot: CGFloat) -> Role { slot >= 14 ? .toolbar : .control }

        /// Explicit diagnostic symbols for project actions and the saved-terminal identity.
        /// An unfamiliar name is a missing platform service and fails visibly.
        /// Images rasterize once per visible control at 2×, capped to a 32-point canvas.
        public static func image(_ name: String, slot: CGFloat, pointSize: CGFloat,
                                 weight: NSFont.Weight) -> NSImage? {
            precondition(name == "ellipsis" || name == "plus" || name == "terminal"
                         || name == "chevron.down" || name == "chevron.right"
                         || name == "folder" || name == "doc.text"
                         || name == "text.bubble" || name == "hand.raised"
                         || name == "questionmark.bubble" || name == "circle"
                         || name == "checkmark.circle.fill",
                         "No Linux diagnostic symbol artwork for \(name)")
            precondition(slot.isFinite && pointSize.isFinite && slot > 0 && pointSize > 0)
            // Keep the artwork at its optical point size inside the requested layout slot.
            // GlyphView's intrinsic width is the image canvas, and a header may require the
            // full 16pt slot even though the visible terminal mark is only 12pt wide.
            let canvasSide = min(32, max(4, slot))
            let side = min(canvasSide, max(4, pointSize))
            let origin = (canvasSide - side) / 2
            let weightFactor: CGFloat = weight.rawValue >= NSFont.Weight.bold.rawValue ? 1.25
                : weight.rawValue >= NSFont.Weight.semibold.rawValue ? 1.12 : 1
            let size = NSSize(width: canvasSide, height: canvasSide)
            let image = NSImage(size: size, flipped: false) { canvas in
                NSColor.white.setFill()
                if name == "text.bubble" {
                    let bubble = NSBezierPath()
                    bubble.move(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.82))
                    bubble.line(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.82))
                    bubble.line(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.42, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.25, y: origin + side * 0.10))
                    bubble.line(to: NSPoint(x: origin + side * 0.25, y: origin + side * 0.25))
                    bubble.close()
                    bubble.lineWidth = max(1, side * 0.07 * weightFactor)
                    NSColor.white.setStroke()
                    bubble.stroke()
                    let text = NSBezierPath()
                    for height: CGFloat in [0.65, 0.49] {
                        text.move(to: NSPoint(x: origin + side * 0.28, y: origin + side * height))
                        text.line(to: NSPoint(x: origin + side * 0.72, y: origin + side * height))
                    }
                    text.lineWidth = bubble.lineWidth
                    text.stroke()
                } else if name == "circle" || name == "checkmark.circle.fill" {
                    // A question choice's radio mark: an open ring, or a filled disc with the
                    // check knocked out of it once chosen.
                    let disc = NSRect(x: origin + side * 0.1, y: origin + side * 0.1,
                                      width: side * 0.8, height: side * 0.8)
                    if name == "circle" {
                        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: side * 0.04, dy: side * 0.04))
                        ring.lineWidth = max(1, side * 0.08 * weightFactor)
                        NSColor.white.setStroke()
                        ring.stroke()
                    } else {
                        NSBezierPath(ovalIn: disc).fill()
                        let check = NSBezierPath()
                        check.move(to: NSPoint(x: origin + side * 0.3, y: origin + side * 0.5))
                        check.line(to: NSPoint(x: origin + side * 0.44, y: origin + side * 0.35))
                        check.line(to: NSPoint(x: origin + side * 0.7, y: origin + side * 0.64))
                        check.lineWidth = max(1, side * 0.1 * weightFactor)
                        check.lineCapStyle = .round
                        NSGraphicsContext.current?.compositingOperation = .copy
                        NSColor.clear.setStroke()
                        check.stroke()
                        NSGraphicsContext.current?.compositingOperation = .sourceOver
                    }
                } else if name == "questionmark.bubble" {
                    // The question card's mark: the conversation bubble around a question mark.
                    let bubble = NSBezierPath()
                    bubble.move(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.85))
                    bubble.line(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.85))
                    bubble.line(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.42, y: origin + side * 0.25))
                    bubble.line(to: NSPoint(x: origin + side * 0.25, y: origin + side * 0.10))
                    bubble.line(to: NSPoint(x: origin + side * 0.25, y: origin + side * 0.25))
                    bubble.close()
                    bubble.lineWidth = max(1, side * 0.07 * weightFactor)
                    NSColor.white.setStroke()
                    bubble.stroke()
                    let mark = NSBezierPath()
                    mark.move(to: NSPoint(x: origin + side * 0.4, y: origin + side * 0.66))
                    mark.curve(to: NSPoint(x: origin + side * 0.5, y: origin + side * 0.45),
                               controlPoint1: NSPoint(x: origin + side * 0.42, y: origin + side * 0.8),
                               controlPoint2: NSPoint(x: origin + side * 0.66, y: origin + side * 0.62))
                    mark.lineWidth = bubble.lineWidth
                    mark.lineCapStyle = .round
                    mark.stroke()
                    NSBezierPath(ovalIn: NSRect(x: origin + side * 0.46, y: origin + side * 0.31,
                                                width: side * 0.08, height: side * 0.08)).fill()
                } else if name == "hand.raised" {
                    // The permission card's mark: an open palm, four raised fingers and a thumb.
                    let hand = NSBezierPath(roundedRect: NSRect(
                        x: origin + side * 0.26, y: origin + side * 0.08,
                        width: side * 0.5, height: side * 0.46),
                        xRadius: side * 0.16, yRadius: side * 0.16)
                    for (x, top) in [(0.33, 0.84), (0.46, 0.92), (0.59, 0.88), (0.71, 0.76)] as [(CGFloat, CGFloat)] {
                        hand.move(to: NSPoint(x: origin + side * x, y: origin + side * 0.48))
                        hand.line(to: NSPoint(x: origin + side * x, y: origin + side * top))
                    }
                    hand.move(to: NSPoint(x: origin + side * 0.27, y: origin + side * 0.32))
                    hand.line(to: NSPoint(x: origin + side * 0.12, y: origin + side * 0.50))
                    hand.lineWidth = max(1, side * 0.08 * weightFactor)
                    hand.lineCapStyle = .round
                    NSColor.white.setStroke()
                    hand.stroke()
                } else if name == "doc.text" {
                    let paper = NSBezierPath()
                    paper.move(to: NSPoint(x: origin + side * 0.22, y: origin + side * 0.08))
                    paper.line(to: NSPoint(x: origin + side * 0.78, y: origin + side * 0.08))
                    paper.line(to: NSPoint(x: origin + side * 0.78, y: origin + side * 0.70))
                    paper.line(to: NSPoint(x: origin + side * 0.60, y: origin + side * 0.90))
                    paper.line(to: NSPoint(x: origin + side * 0.22, y: origin + side * 0.90))
                    paper.close()
                    paper.lineWidth = max(1, side * 0.07 * weightFactor)
                    NSColor.white.setStroke()
                    paper.stroke()
                    let detail = NSBezierPath()
                    detail.move(to: NSPoint(x: origin + side * 0.60, y: origin + side * 0.90))
                    detail.line(to: NSPoint(x: origin + side * 0.60, y: origin + side * 0.70))
                    detail.line(to: NSPoint(x: origin + side * 0.78, y: origin + side * 0.70))
                    for height: CGFloat in [0.55, 0.40, 0.25] {
                        detail.move(to: NSPoint(x: origin + side * 0.34, y: origin + side * height))
                        detail.line(to: NSPoint(x: origin + side * 0.66, y: origin + side * height))
                    }
                    detail.lineWidth = paper.lineWidth
                    detail.stroke()
                } else if name == "terminal" {
                    let screen = NSBezierPath(roundedRect: NSRect(
                        x: origin + side * 0.1, y: origin + side * 0.16,
                        width: side * 0.8, height: side * 0.68),
                        xRadius: side * 0.08, yRadius: side * 0.08)
                    screen.lineWidth = max(1, side * 0.11 * weightFactor)
                    NSColor.white.setStroke()
                    screen.stroke()

                    let prompt = NSBezierPath()
                    prompt.move(to: NSPoint(x: origin + side * 0.27, y: origin + side * 0.61))
                    prompt.line(to: NSPoint(x: origin + side * 0.42, y: origin + side * 0.5))
                    prompt.line(to: NSPoint(x: origin + side * 0.27, y: origin + side * 0.39))
                    prompt.move(to: NSPoint(x: origin + side * 0.5, y: origin + side * 0.38))
                    prompt.line(to: NSPoint(x: origin + side * 0.69, y: origin + side * 0.38))
                    prompt.lineWidth = max(1, side * 0.1 * weightFactor)
                    prompt.stroke()
                } else if name == "plus" {
                    let stroke = max(1.5, side * 0.15 * weightFactor)
                    let span = side * 0.72
                    NSRect(x: canvas.midX - span / 2, y: canvas.midY - stroke / 2,
                           width: span, height: stroke).fill()
                    NSRect(x: canvas.midX - stroke / 2, y: canvas.midY - span / 2,
                           width: stroke, height: span).fill()
                } else if name == "chevron.right" {
                    // A collapsed tool row's disclosure: `chevron.down` turned to point along the row.
                    let chevron = NSBezierPath()
                    chevron.move(to: NSPoint(x: origin + side * 0.39, y: origin + side * 0.22))
                    chevron.line(to: NSPoint(x: origin + side * 0.65, y: origin + side * 0.5))
                    chevron.line(to: NSPoint(x: origin + side * 0.39, y: origin + side * 0.78))
                    chevron.lineWidth = max(1.5, side * 0.15 * weightFactor)
                    NSColor.white.setStroke()
                    chevron.stroke()
                } else if name == "chevron.down" {
                    // The canvas is unflipped, so the point sits below the arms. It was drawn the
                    // other way up, and every chip's menu chevron pointed up.
                    let chevron = NSBezierPath()
                    chevron.move(to: NSPoint(x: origin + side * 0.22,
                                              y: origin + side * 0.61))
                    chevron.line(to: NSPoint(x: origin + side * 0.5,
                                              y: origin + side * 0.35))
                    chevron.line(to: NSPoint(x: origin + side * 0.78,
                                              y: origin + side * 0.61))
                    // ChipView asks for semibold at a nine-point slot. The provider is
                    // materialized before image configuration, so author that weight here.
                    chevron.lineWidth = max(1.5, side * 0.15 * weightFactor)
                    NSColor.white.setStroke()
                    chevron.stroke()
                } else if name == "folder" {
                    let folder = NSBezierPath()
                    folder.move(to: NSPoint(x: origin + side * 0.1,
                                             y: origin + side * 0.28))
                    folder.line(to: NSPoint(x: origin + side * 0.1,
                                             y: origin + side * 0.72))
                    folder.line(to: NSPoint(x: origin + side * 0.9,
                                             y: origin + side * 0.72))
                    folder.line(to: NSPoint(x: origin + side * 0.9,
                                             y: origin + side * 0.36))
                    folder.line(to: NSPoint(x: origin + side * 0.56,
                                             y: origin + side * 0.36))
                    folder.line(to: NSPoint(x: origin + side * 0.45,
                                             y: origin + side * 0.28))
                    folder.close()
                    folder.lineWidth = max(1.5, side * 0.09 * weightFactor)
                    NSColor.white.setStroke()
                    folder.stroke()
                } else {
                    let dot = max(1.5, side * 0.19 * weightFactor)
                    for fraction in [CGFloat(0.23), 0.5, 0.77] {
                        NSBezierPath(ovalIn: NSRect(x: origin + side * fraction - dot / 2,
                                                    y: canvas.midY - dot / 2,
                                                    width: dot, height: dot)).fill()
                    }
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }
}
