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

    public enum Accessibility { public static let focusRingWidth: CGFloat = 2 }
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
    @MainActor public enum Surface {
        public static var accent: NSColor { LinuxTheme.color("accent") }
        public static var bevelHighlight: NSColor { LinuxTheme.color("bevelHighlight") }
        public static var bevelShadow: NSColor { LinuxTheme.color("bevelShadow") }
        public static var divider: NSColor { LinuxTheme.color("divider") }
        public static var border: NSColor { LinuxTheme.color("border") }
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
                         || name == "chevron.down" || name == "folder",
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
                if name == "terminal" {
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
                } else if name == "chevron.down" {
                    let chevron = NSBezierPath()
                    chevron.move(to: NSPoint(x: origin + side * 0.22,
                                              y: origin + side * 0.39))
                    chevron.line(to: NSPoint(x: origin + side * 0.5,
                                              y: origin + side * 0.65))
                    chevron.line(to: NSPoint(x: origin + side * 0.78,
                                              y: origin + side * 0.39))
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
