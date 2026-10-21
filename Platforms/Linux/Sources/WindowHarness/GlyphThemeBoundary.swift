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
        public let base: NSColor
        public let label: NSColor
        public let secondary: NSColor
        public let tertiary: NSColor
        public let quaternary: NSColor
        public let surface: NSColor
        public let surfaceHover: NSColor
        public let border: NSColor
        public let rule: NSColor

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
            base = label
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
            rule = LinuxTheme.color("divider")
        }

        public init(base: NSColor, label: NSColor, secondary: NSColor,
                    tertiary: NSColor, quaternary: NSColor) {
            self.base = base
            self.label = label
            self.secondary = secondary
            self.tertiary = tertiary
            self.quaternary = quaternary
            surface = Design.Surface.controlResting
            surfaceHover = Design.Surface.controlHover
            border = Design.Surface.border
            rule = Design.Surface.divider
        }

        public static var selection: Ink { Ink(on: Design.Surface.selectionFill) }
        public static var chrome: Ink {
            Ink(base: Design.Text.label, label: Design.Text.label,
                secondary: Design.Text.secondary, tertiary: Design.Text.tertiary,
                quaternary: Design.Text.quaternary)
        }
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
        public static var accentMuted: NSColor { LinuxTheme.color("accentMuted") }
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
    public enum Motion {
        public static let quick: TimeInterval = 0.15
        public static let reducesStatusMotion = ProcessInfo.processInfo.environment["THREADING_LINUX_REDUCE_MOTION"] == "1"
    }
    public enum Size {
        // Same derived Mac canvas: 300 summary + 32 pane + 64 axis + 620 plot + 12 axis.
        public static let settingsContentWidth: CGFloat = 1_028
        public static let glowGutter: CGFloat = 48
        public static let tabHeight: CGFloat = 28
        public static let footerHeight: CGFloat = 48
        public static let toolbarButtonWidth: CGFloat = 30
        public static let toolbarButtonHeight: CGFloat = 28
        public static let inlineButtonTarget: CGFloat = 20
        public static let promptAttachmentThumbnail: CGFloat = 80
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
        public enum Role { case toolbar, control, chevron
            public var pointSize: CGFloat {
                switch self {
                case .toolbar: 14
                case .control: 12
                case .chevron: 8
                }
            }
        }
        public static func slot(inControlOfHeight height: CGFloat) -> CGFloat { height - 10 }
        public static func role(forSlot slot: CGFloat) -> Role { slot >= 14 ? .toolbar : .control }

        /// Explicit diagnostic symbols for project actions and the saved-terminal identity.
        /// An unfamiliar name is a missing platform service and fails visibly.
        /// Images rasterize once per visible control at 2×, capped to a 44-point canvas.
        public static func image(_ name: String, slot: CGFloat, pointSize: CGFloat,
                                 weight: NSFont.Weight) -> NSImage? {
            precondition(name == "ellipsis" || name == "plus" || name == "terminal"
                         || name == "archivebox" || name == "pin" || name == "pin.slash"
                         || name == "pin.fill" || name == "moon.zzz" || name == "bell"
                         || name == "calendar"
                         || name == "chevron.down" || name == "chevron.right"
                         || name == "folder" || name == "doc.text" || name == "pencil"
                         || name == "arrow.up.forward.app"
                         || name == "text.bubble" || name == "bubble.left.and.text.bubble.right"
                         || name == "hand.raised" || name == "cpu" || name == "brain"
                         || name == "gauge" || name == "bolt.fill"
                         || name == "questionmark.bubble" || name == "circle"
                         || name == "eye.slash"
                         || name == "exclamationmark.triangle"
                         || name == "checkmark.circle.fill" || name == "return"
                         || name == "stop.fill" || name == "stop.circle"
                         || name == "arrow.clockwise.circle" || name == "xmark"
                         || name == "play.fill",
                         "No Linux diagnostic symbol artwork for \(name)")
            precondition(slot.isFinite && pointSize.isFinite && slot > 0 && pointSize > 0)
            // Keep the artwork at its optical point size inside the requested layout slot.
            // GlyphView's intrinsic width is the image canvas, and a header may require the
            // full 16pt slot even though the visible terminal mark is only 12pt wide.
            let canvasSide = min(44, max(4, slot))
            let side = min(canvasSide, max(4, pointSize))
            let origin = (canvasSide - side) / 2
            let weightFactor: CGFloat = weight.rawValue >= NSFont.Weight.bold.rawValue ? 1.25
                : weight.rawValue >= NSFont.Weight.semibold.rawValue ? 1.12 : 1
            let size = NSSize(width: canvasSide, height: canvasSide)
            let image = NSImage(size: size, flipped: false) { canvas in
                NSColor.white.setFill()
                if name == "xmark" {
                    let mark = NSBezierPath()
                    mark.move(to: NSPoint(x: origin + side * 0.22, y: origin + side * 0.22))
                    mark.line(to: NSPoint(x: origin + side * 0.78, y: origin + side * 0.78))
                    mark.move(to: NSPoint(x: origin + side * 0.22, y: origin + side * 0.78))
                    mark.line(to: NSPoint(x: origin + side * 0.78, y: origin + side * 0.22))
                    mark.lineWidth = max(0.8, side * 0.12 * weightFactor)
                    mark.lineCapStyle = .round
                    NSColor.white.setStroke()
                    mark.stroke()
                } else if name == "play.fill" {
                    let play = NSBezierPath()
                    play.move(to: NSPoint(x: origin + side * 0.26, y: origin + side * 0.15))
                    play.line(to: NSPoint(x: origin + side * 0.82, y: origin + side * 0.50))
                    play.line(to: NSPoint(x: origin + side * 0.26, y: origin + side * 0.85))
                    play.close()
                    play.fill()
                } else if name == "stop.fill" {
                    NSBezierPath(roundedRect: NSRect(x: origin + side * 0.18, y: origin + side * 0.18,
                        width: side * 0.64, height: side * 0.64), xRadius: side * 0.06, yRadius: side * 0.06).fill()
                } else if name == "stop.circle" {
                    let ring = NSBezierPath(ovalIn: NSRect(x: origin + side * 0.1,
                        y: origin + side * 0.1, width: side * 0.8, height: side * 0.8))
                    ring.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    NSColor.white.setStroke()
                    ring.stroke()
                    NSBezierPath(roundedRect: NSRect(x: origin + side * 0.37,
                        y: origin + side * 0.37, width: side * 0.26, height: side * 0.26),
                        xRadius: side * 0.02, yRadius: side * 0.02).fill()
                } else if name == "arrow.clockwise.circle" {
                    let ring = NSBezierPath(ovalIn: NSRect(x: origin + side * 0.08,
                        y: origin + side * 0.08, width: side * 0.84, height: side * 0.84))
                    ring.lineWidth = max(0.8, side * 0.06 * weightFactor)
                    NSColor.white.setStroke()
                    ring.stroke()
                    let arrow = NSBezierPath()
                    arrow.move(to: NSPoint(x: origin + side * 0.70, y: origin + side * 0.71))
                    arrow.curve(to: NSPoint(x: origin + side * 0.28, y: origin + side * 0.48),
                        controlPoint1: NSPoint(x: origin + side * 0.37, y: origin + side * 0.85),
                        controlPoint2: NSPoint(x: origin + side * 0.22, y: origin + side * 0.72))
                    arrow.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    arrow.lineCapStyle = .round
                    arrow.stroke()
                    let tip = NSBezierPath()
                    tip.move(to: NSPoint(x: origin + side * 0.69, y: origin + side * 0.71))
                    tip.line(to: NSPoint(x: origin + side * 0.52, y: origin + side * 0.72))
                    tip.line(to: NSPoint(x: origin + side * 0.65, y: origin + side * 0.57))
                    tip.close()
                    tip.fill()
                } else if name == "pencil" {
                    let pencil = NSBezierPath()
                    pencil.move(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.14))
                    pencil.line(to: NSPoint(x: origin + side * 0.28, y: origin + side * 0.44))
                    pencil.line(to: NSPoint(x: origin + side * 0.69, y: origin + side * 0.85))
                    pencil.line(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.69))
                    pencil.line(to: NSPoint(x: origin + side * 0.44, y: origin + side * 0.28))
                    pencil.close()
                    pencil.lineWidth = max(0.7, side * 0.055 * weightFactor)
                    pencil.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    pencil.stroke()
                    let tip = NSBezierPath()
                    tip.move(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.14))
                    tip.line(to: NSPoint(x: origin + side * 0.28, y: origin + side * 0.44))
                    tip.line(to: NSPoint(x: origin + side * 0.44, y: origin + side * 0.28))
                    tip.close()
                    tip.fill()
                } else if name == "pin" || name == "pin.slash" || name == "pin.fill" {
                    let pin = NSBezierPath()
                    pin.move(to: NSPoint(x: origin + side * 0.30, y: origin + side * 0.82))
                    pin.line(to: NSPoint(x: origin + side * 0.70, y: origin + side * 0.82))
                    pin.move(to: NSPoint(x: origin + side * 0.38, y: origin + side * 0.82))
                    pin.line(to: NSPoint(x: origin + side * 0.34, y: origin + side * 0.43))
                    pin.line(to: NSPoint(x: origin + side * 0.66, y: origin + side * 0.43))
                    pin.line(to: NSPoint(x: origin + side * 0.62, y: origin + side * 0.82))
                    pin.move(to: NSPoint(x: origin + side * 0.25, y: origin + side * 0.43))
                    pin.line(to: NSPoint(x: origin + side * 0.75, y: origin + side * 0.43))
                    pin.move(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.43))
                    pin.line(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.12))
                    if name == "pin.slash" {
                        pin.move(to: NSPoint(x: origin + side * 0.17, y: origin + side * 0.13))
                        pin.line(to: NSPoint(x: origin + side * 0.83, y: origin + side * 0.87))
                    }
                    pin.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    pin.lineCapStyle = .round
                    pin.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    pin.stroke()
                } else if name == "moon.zzz" {
                    let moon = NSBezierPath()
                    moon.move(to: NSPoint(x: origin + side * 0.56, y: origin + side * 0.91))
                    moon.curve(to: NSPoint(x: origin + side * 0.70, y: origin + side * 0.13),
                        controlPoint1: NSPoint(x: origin + side * 0.12, y: origin + side * 0.89),
                        controlPoint2: NSPoint(x: origin + side * 0.11, y: origin + side * 0.29))
                    moon.curve(to: NSPoint(x: origin + side * 0.56, y: origin + side * 0.91),
                        controlPoint1: NSPoint(x: origin + side * 0.32, y: origin + side * 0.36),
                        controlPoint2: NSPoint(x: origin + side * 0.57, y: origin + side * 0.68))
                    moon.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    moon.lineCapStyle = .round
                    NSColor.white.setStroke()
                    moon.stroke()
                    let sleep = NSBezierPath()
                    sleep.move(to: NSPoint(x: origin + side * 0.62, y: origin + side * 0.71))
                    sleep.line(to: NSPoint(x: origin + side * 0.79, y: origin + side * 0.71))
                    sleep.line(to: NSPoint(x: origin + side * 0.62, y: origin + side * 0.55))
                    sleep.line(to: NSPoint(x: origin + side * 0.79, y: origin + side * 0.55))
                    sleep.move(to: NSPoint(x: origin + side * 0.76, y: origin + side * 0.90))
                    sleep.line(to: NSPoint(x: origin + side * 0.91, y: origin + side * 0.90))
                    sleep.line(to: NSPoint(x: origin + side * 0.76, y: origin + side * 0.77))
                    sleep.line(to: NSPoint(x: origin + side * 0.91, y: origin + side * 0.77))
                    sleep.lineWidth = max(0.6, side * 0.055 * weightFactor)
                    sleep.lineJoinStyle = .round
                    sleep.stroke()
                } else if name == "bell" {
                    let bell = NSBezierPath()
                    bell.move(to: NSPoint(x: origin + side * 0.21, y: origin + side * 0.31))
                    bell.curve(to: NSPoint(x: origin + side * 0.33, y: origin + side * 0.57),
                        controlPoint1: NSPoint(x: origin + side * 0.30, y: origin + side * 0.40),
                        controlPoint2: NSPoint(x: origin + side * 0.27, y: origin + side * 0.50))
                    bell.curve(to: NSPoint(x: origin + side * 0.67, y: origin + side * 0.57),
                        controlPoint1: NSPoint(x: origin + side * 0.39, y: origin + side * 0.83),
                        controlPoint2: NSPoint(x: origin + side * 0.61, y: origin + side * 0.83))
                    bell.curve(to: NSPoint(x: origin + side * 0.79, y: origin + side * 0.31),
                        controlPoint1: NSPoint(x: origin + side * 0.73, y: origin + side * 0.50),
                        controlPoint2: NSPoint(x: origin + side * 0.70, y: origin + side * 0.40))
                    bell.close()
                    bell.move(to: NSPoint(x: origin + side * 0.43, y: origin + side * 0.19))
                    bell.curve(to: NSPoint(x: origin + side * 0.57, y: origin + side * 0.19),
                        controlPoint1: NSPoint(x: origin + side * 0.45, y: origin + side * 0.10),
                        controlPoint2: NSPoint(x: origin + side * 0.55, y: origin + side * 0.10))
                    bell.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    bell.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    bell.stroke()
                } else if name == "calendar" {
                    let calendar = NSBezierPath(roundedRect: NSRect(
                        x: origin + side * 0.14, y: origin + side * 0.14,
                        width: side * 0.72, height: side * 0.67),
                        xRadius: side * 0.06, yRadius: side * 0.06)
                    calendar.move(to: NSPoint(x: origin + side * 0.14, y: origin + side * 0.60))
                    calendar.line(to: NSPoint(x: origin + side * 0.86, y: origin + side * 0.60))
                    for x: CGFloat in [0.34, 0.66] {
                        calendar.move(to: NSPoint(x: origin + side * x,
                            y: origin + side * 0.73))
                        calendar.line(to: NSPoint(x: origin + side * x,
                            y: origin + side * 0.91))
                    }
                    calendar.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    calendar.lineCapStyle = .round
                    NSColor.white.setStroke()
                    calendar.stroke()
                    for x: CGFloat in [0.35, 0.58] {
                        for y: CGFloat in [0.33, 0.48] {
                            NSBezierPath(ovalIn: NSRect(x: origin + side * x,
                                y: origin + side * y, width: side * 0.08,
                                height: side * 0.08)).fill()
                        }
                    }
                } else if name == "archivebox" {
                    let box = NSBezierPath()
                    box.move(to: NSPoint(x: origin + side * 0.16, y: origin + side * 0.68))
                    box.line(to: NSPoint(x: origin + side * 0.21, y: origin + side * 0.16))
                    box.line(to: NSPoint(x: origin + side * 0.79, y: origin + side * 0.16))
                    box.line(to: NSPoint(x: origin + side * 0.84, y: origin + side * 0.68))
                    box.move(to: NSPoint(x: origin + side * 0.08, y: origin + side * 0.68))
                    box.line(to: NSPoint(x: origin + side * 0.92, y: origin + side * 0.68))
                    box.line(to: NSPoint(x: origin + side * 0.92, y: origin + side * 0.84))
                    box.line(to: NSPoint(x: origin + side * 0.08, y: origin + side * 0.84))
                    box.close()
                    box.move(to: NSPoint(x: origin + side * 0.39, y: origin + side * 0.48))
                    box.line(to: NSPoint(x: origin + side * 0.61, y: origin + side * 0.48))
                    box.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    box.lineJoinStyle = .round
                    box.lineCapStyle = .round
                    NSColor.white.setStroke()
                    box.stroke()
                } else if name == "exclamationmark.triangle" {
                    let outline = NSBezierPath()
                    outline.move(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.88))
                    outline.line(to: NSPoint(x: origin + side * 0.91, y: origin + side * 0.16))
                    outline.line(to: NSPoint(x: origin + side * 0.09, y: origin + side * 0.16))
                    outline.close()
                    outline.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    outline.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    outline.stroke()
                    let stem = NSBezierPath()
                    stem.move(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.60))
                    stem.line(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.39))
                    stem.lineWidth = max(0.8, side * 0.09 * weightFactor)
                    stem.lineCapStyle = .round
                    stem.stroke()
                    NSBezierPath(ovalIn: NSRect(x: origin + side * 0.46, y: origin + side * 0.25,
                        width: side * 0.08, height: side * 0.08)).fill()
                } else if name == "bolt.fill" {
                    let bolt = NSBezierPath()
                    bolt.move(to: NSPoint(x: origin + side * 0.56, y: origin + side * 0.94))
                    bolt.line(to: NSPoint(x: origin + side * 0.21, y: origin + side * 0.47))
                    bolt.line(to: NSPoint(x: origin + side * 0.47, y: origin + side * 0.47))
                    bolt.line(to: NSPoint(x: origin + side * 0.39, y: origin + side * 0.06))
                    bolt.line(to: NSPoint(x: origin + side * 0.79, y: origin + side * 0.57))
                    bolt.line(to: NSPoint(x: origin + side * 0.52, y: origin + side * 0.57))
                    bolt.close()
                    bolt.fill()
                } else if name == "gauge" {
                    let arc = NSBezierPath()
                    arc.move(to: NSPoint(x: origin + side * 0.15, y: origin + side * 0.42))
                    arc.curve(to: NSPoint(x: origin + side * 0.5, y: origin + side * 0.77),
                        controlPoint1: NSPoint(x: origin + side * 0.15, y: origin + side * 0.61),
                        controlPoint2: NSPoint(x: origin + side * 0.31, y: origin + side * 0.77))
                    arc.curve(to: NSPoint(x: origin + side * 0.85, y: origin + side * 0.42),
                        controlPoint1: NSPoint(x: origin + side * 0.69, y: origin + side * 0.77),
                        controlPoint2: NSPoint(x: origin + side * 0.85, y: origin + side * 0.61))
                    arc.lineWidth = max(1, side * 0.09 * weightFactor)
                    arc.lineCapStyle = .round
                    arc.stroke()
                    let needle = NSBezierPath()
                    needle.move(to: NSPoint(x: origin + side * 0.5, y: origin + side * 0.42))
                    needle.line(to: NSPoint(x: origin + side * 0.68, y: origin + side * 0.67))
                    needle.lineWidth = arc.lineWidth
                    needle.lineCapStyle = .round
                    needle.stroke()
                } else if name == "return" {
                    let mark = NSBezierPath()
                    mark.move(to: NSPoint(x: origin + side * 0.8, y: origin + side * 0.8))
                    mark.line(to: NSPoint(x: origin + side * 0.8, y: origin + side * 0.4))
                    mark.line(to: NSPoint(x: origin + side * 0.2, y: origin + side * 0.4))
                    mark.move(to: NSPoint(x: origin + side * 0.4, y: origin + side * 0.6))
                    mark.line(to: NSPoint(x: origin + side * 0.2, y: origin + side * 0.4))
                    mark.line(to: NSPoint(x: origin + side * 0.4, y: origin + side * 0.2))
                    mark.lineWidth = max(1, side * 0.09 * weightFactor)
                    NSColor.white.setStroke()
                    mark.stroke()
                } else if name == "bubble.left.and.text.bubble.right" {
                    let left = NSBezierPath()
                    left.move(to: NSPoint(x: origin + side * 0.08, y: origin + side * 0.38))
                    left.line(to: NSPoint(x: origin + side * 0.08, y: origin + side * 0.82))
                    left.line(to: NSPoint(x: origin + side * 0.62, y: origin + side * 0.82))
                    left.line(to: NSPoint(x: origin + side * 0.62, y: origin + side * 0.38))
                    left.line(to: NSPoint(x: origin + side * 0.30, y: origin + side * 0.38))
                    left.line(to: NSPoint(x: origin + side * 0.19, y: origin + side * 0.25))
                    left.line(to: NSPoint(x: origin + side * 0.19, y: origin + side * 0.38))
                    left.close()
                    left.lineWidth = max(0.8, side * 0.07 * weightFactor)
                    NSColor.white.setStroke()
                    left.stroke()
                    let right = NSBezierPath()
                    right.move(to: NSPoint(x: origin + side * 0.38, y: origin + side * 0.15))
                    right.line(to: NSPoint(x: origin + side * 0.38, y: origin + side * 0.30))
                    right.line(to: NSPoint(x: origin + side * 0.72, y: origin + side * 0.30))
                    right.line(to: NSPoint(x: origin + side * 0.83, y: origin + side * 0.42))
                    right.line(to: NSPoint(x: origin + side * 0.83, y: origin + side * 0.30))
                    right.line(to: NSPoint(x: origin + side * 0.92, y: origin + side * 0.30))
                    right.line(to: NSPoint(x: origin + side * 0.92, y: origin + side * 0.66))
                    right.line(to: NSPoint(x: origin + side * 0.68, y: origin + side * 0.66))
                    right.lineWidth = left.lineWidth
                    right.stroke()
                } else if name == "text.bubble" {
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
                } else if name == "eye.slash" {
                    let eye = NSBezierPath()
                    eye.move(to: NSPoint(x: origin + side * 0.10, y: origin + side * 0.50))
                    eye.curve(to: NSPoint(x: origin + side * 0.90, y: origin + side * 0.50),
                              controlPoint1: NSPoint(x: origin + side * 0.32, y: origin + side * 0.84),
                              controlPoint2: NSPoint(x: origin + side * 0.68, y: origin + side * 0.84))
                    eye.curve(to: NSPoint(x: origin + side * 0.10, y: origin + side * 0.50),
                              controlPoint1: NSPoint(x: origin + side * 0.68, y: origin + side * 0.16),
                              controlPoint2: NSPoint(x: origin + side * 0.32, y: origin + side * 0.16))
                    eye.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    eye.lineCapStyle = .round
                    NSColor.white.setStroke()
                    eye.stroke()
                    NSBezierPath(ovalIn: NSRect(x: origin + side * 0.43, y: origin + side * 0.43,
                                                width: side * 0.14, height: side * 0.14)).fill()
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: origin + side * 0.16, y: origin + side * 0.14))
                    slash.line(to: NSPoint(x: origin + side * 0.84, y: origin + side * 0.86))
                    slash.lineWidth = max(0.9, side * 0.10 * weightFactor)
                    slash.lineCapStyle = .round
                    slash.stroke()
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
                } else if name == "brain" {
                    let outline = NSBezierPath()
                    outline.move(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.18))
                    outline.curve(to: NSPoint(x: origin + side * 0.28, y: origin + side * 0.23),
                        controlPoint1: NSPoint(x: origin + side * 0.41, y: origin + side * 0.11),
                        controlPoint2: NSPoint(x: origin + side * 0.29, y: origin + side * 0.14))
                    outline.curve(to: NSPoint(x: origin + side * 0.16, y: origin + side * 0.45),
                        controlPoint1: NSPoint(x: origin + side * 0.12, y: origin + side * 0.25),
                        controlPoint2: NSPoint(x: origin + side * 0.10, y: origin + side * 0.38))
                    outline.curve(to: NSPoint(x: origin + side * 0.28, y: origin + side * 0.69),
                        controlPoint1: NSPoint(x: origin + side * 0.07, y: origin + side * 0.56),
                        controlPoint2: NSPoint(x: origin + side * 0.16, y: origin + side * 0.69))
                    outline.curve(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.82),
                        controlPoint1: NSPoint(x: origin + side * 0.29, y: origin + side * 0.86),
                        controlPoint2: NSPoint(x: origin + side * 0.44, y: origin + side * 0.88))
                    outline.curve(to: NSPoint(x: origin + side * 0.72, y: origin + side * 0.69),
                        controlPoint1: NSPoint(x: origin + side * 0.56, y: origin + side * 0.88),
                        controlPoint2: NSPoint(x: origin + side * 0.71, y: origin + side * 0.86))
                    outline.curve(to: NSPoint(x: origin + side * 0.84, y: origin + side * 0.45),
                        controlPoint1: NSPoint(x: origin + side * 0.84, y: origin + side * 0.69),
                        controlPoint2: NSPoint(x: origin + side * 0.93, y: origin + side * 0.56))
                    outline.curve(to: NSPoint(x: origin + side * 0.72, y: origin + side * 0.23),
                        controlPoint1: NSPoint(x: origin + side * 0.90, y: origin + side * 0.38),
                        controlPoint2: NSPoint(x: origin + side * 0.88, y: origin + side * 0.25))
                    outline.curve(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.18),
                        controlPoint1: NSPoint(x: origin + side * 0.71, y: origin + side * 0.14),
                        controlPoint2: NSPoint(x: origin + side * 0.59, y: origin + side * 0.11))
                    outline.move(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.81))
                    outline.line(to: NSPoint(x: origin + side * 0.50, y: origin + side * 0.18))
                    outline.move(to: NSPoint(x: origin + side * 0.23, y: origin + side * 0.48))
                    outline.curve(to: NSPoint(x: origin + side * 0.39, y: origin + side * 0.37),
                        controlPoint1: NSPoint(x: origin + side * 0.40, y: origin + side * 0.58),
                        controlPoint2: NSPoint(x: origin + side * 0.22, y: origin + side * 0.31))
                    outline.move(to: NSPoint(x: origin + side * 0.77, y: origin + side * 0.48))
                    outline.curve(to: NSPoint(x: origin + side * 0.61, y: origin + side * 0.37),
                        controlPoint1: NSPoint(x: origin + side * 0.60, y: origin + side * 0.58),
                        controlPoint2: NSPoint(x: origin + side * 0.78, y: origin + side * 0.31))
                    outline.lineWidth = max(0.8, side * 0.07 * weightFactor)
                    outline.lineCapStyle = .round
                    outline.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    outline.stroke()
                } else if name == "cpu" {
                    let chip = NSBezierPath(roundedRect: NSRect(x: origin + side * 0.22,
                        y: origin + side * 0.22, width: side * 0.56, height: side * 0.56),
                        xRadius: side * 0.06, yRadius: side * 0.06)
                    chip.append(NSBezierPath(rect: NSRect(x: origin + side * 0.36,
                        y: origin + side * 0.36, width: side * 0.28, height: side * 0.28)))
                    for fraction: CGFloat in [0.34, 0.50, 0.66] {
                        let offset = origin + side * fraction
                        for (a, b) in [(0.08, 0.22), (0.78, 0.92)] as [(CGFloat, CGFloat)] {
                            chip.move(to: NSPoint(x: origin + side * a, y: offset))
                            chip.line(to: NSPoint(x: origin + side * b, y: offset))
                            chip.move(to: NSPoint(x: offset, y: origin + side * a))
                            chip.line(to: NSPoint(x: offset, y: origin + side * b))
                        }
                    }
                    chip.lineWidth = max(0.8, side * 0.065 * weightFactor)
                    chip.lineCapStyle = .round
                    NSColor.white.setStroke()
                    chip.stroke()
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
                    drawTerminal(in: canvas, pointSize: side, weightFactor: weightFactor)
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
                    // Small chevrons need an open counter. The former 1.5pt floor filled
                    // the eight-point navigator mark into a triangle at either scale.
                    chevron.lineWidth = max(0.6, side * 0.08 * weightFactor)
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
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
                    chevron.lineWidth = max(0.6, side * 0.08 * weightFactor)
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    chevron.stroke()
                } else if name == "arrow.up.forward.app" {
                    let app = NSBezierPath()
                    app.move(to: NSPoint(x: origin + side * 0.68, y: origin + side * 0.52))
                    app.line(to: NSPoint(x: origin + side * 0.68, y: origin + side * 0.16))
                    app.line(to: NSPoint(x: origin + side * 0.16, y: origin + side * 0.16))
                    app.line(to: NSPoint(x: origin + side * 0.16, y: origin + side * 0.68))
                    app.line(to: NSPoint(x: origin + side * 0.52, y: origin + side * 0.68))
                    app.move(to: NSPoint(x: origin + side * 0.44, y: origin + side * 0.47))
                    app.line(to: NSPoint(x: origin + side * 0.86, y: origin + side * 0.86))
                    app.move(to: NSPoint(x: origin + side * 0.56, y: origin + side * 0.86))
                    app.line(to: NSPoint(x: origin + side * 0.86, y: origin + side * 0.86))
                    app.line(to: NSPoint(x: origin + side * 0.86, y: origin + side * 0.56))
                    app.lineWidth = max(0.8, side * 0.08 * weightFactor)
                    app.lineCapStyle = .round
                    app.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    app.stroke()
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

        /// Filled contours keep the screen border and open prompt distinct at small sizes.
        /// The 36pt mark occupies about 34×29pt inside the placeholder's 44pt image slot;
        /// the same proportions serve the 12pt sidebar mark without enlarging its stroke.
        private static func drawTerminal(in canvas: NSRect, pointSize: CGFloat,
                                         weightFactor: CGFloat) {
            let width = pointSize * 0.94
            let height = pointSize * 0.80
            let border = pointSize / 16 * weightFactor
            let radius = pointSize * 0.105
            let screen = NSRect(x: canvas.midX - width / 2, y: canvas.midY - height / 2,
                                width: width, height: height)
            let outline = NSBezierPath(roundedRect: screen, xRadius: radius, yRadius: radius)
            let innerRadius = max(0, radius - border)
            outline.append(NSBezierPath(roundedRect: screen.insetBy(dx: border, dy: border),
                                        xRadius: innerRadius, yRadius: innerRadius))
            outline.windingRule = .evenOdd
            outline.fill()

            let tip = NSPoint(x: screen.minX + width * 0.34, y: screen.minY + height * 0.66)
            let armWidth = pointSize * 0.15
            let armHeight = pointSize * 0.11
            let thickness = pointSize * 0.055 * weightFactor
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: tip.x - armWidth, y: tip.y + armHeight - thickness / 2))
            prompt.line(to: NSPoint(x: tip.x - armWidth + thickness / 2, y: tip.y + armHeight))
            prompt.line(to: NSPoint(x: tip.x + thickness / 2, y: tip.y + thickness / 2))
            prompt.line(to: NSPoint(x: tip.x + thickness / 2, y: tip.y - thickness / 2))
            prompt.line(to: NSPoint(x: tip.x - armWidth + thickness / 2, y: tip.y - armHeight))
            prompt.line(to: NSPoint(x: tip.x - armWidth, y: tip.y - armHeight + thickness / 2))
            prompt.line(to: NSPoint(x: tip.x - thickness, y: tip.y))
            prompt.close()
            prompt.fill()

            let cursor = NSRect(x: screen.minX + width * 0.38,
                                y: tip.y - armHeight - thickness / 2,
                                width: pointSize * 0.19, height: thickness)
            NSBezierPath(roundedRect: cursor, xRadius: thickness / 2,
                         yRadius: thickness / 2).fill()
        }
    }
}
