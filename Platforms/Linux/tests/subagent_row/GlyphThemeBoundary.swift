import AppKit

/// The Linux diagnostic shell has fixed grounds, not the macOS theme engine. Its retained icon
/// buttons still use the exact production Design control; these are the measured host roles it
/// reads. Geometry matches the production default theme, while ink is resolved from Specimen's
/// header and body grounds. This file belongs only to WindowHarness; the generic Harness keeps
/// its separate symbol trap.
@MainActor
public protocol ThemeDerivedContent: AnyObject {
    func rederiveThemedContent()
}

@MainActor
public enum Design {
    public struct Ink {
        public let label: NSColor
        public let secondary: NSColor
        public let tertiary: NSColor
        public let quaternary: NSColor
        public let surface: NSColor
        public let surfaceHover: NSColor
        public let border: NSColor

        public init(on ground: NSColor) {
            let neutral = Specimen.Ink(on: ground)
            label = neutral.label
            secondary = neutral.secondary
            tertiary = neutral.secondary.withAlphaComponent(0.72)
            quaternary = neutral.secondary.withAlphaComponent(0.46)
            surface = ground.blended(withFraction: 0.11, of: .black)!
            surfaceHover = ground.blended(withFraction: 0.22, of: .black)!
            border = ground.blended(withFraction: 0.42, of: .black)!
        }
    }

    public enum Accessibility { public static let focusRingWidth: CGFloat = 2 }
    public enum Spacing {
        public static let small: CGFloat = 5
        public static let hairline: CGFloat = 1
        public static let inset: CGFloat = 12
    }
    @MainActor public enum Status {
        public static let warning = NSColor(red: 0.51, green: 0.33, blue: 0.04, alpha: 1)
        public static let positive = NSColor(red: 0.10, green: 0.38, blue: 0.19, alpha: 1)
        public static let negative = NSColor(red: 0.56, green: 0.14, blue: 0.13, alpha: 1)
    }
    @MainActor public enum Text {
        public static let label = Ink(on: Specimen.headerGround).label
        public static let tertiary = Ink(on: Specimen.headerGround).tertiary
        public static func on(_ ground: NSColor) -> Ink { Ink(on: ground) }
    }
    @MainActor public enum Typography {
        public enum FontSurface { case chrome, conversation }
    }
    @MainActor public enum FontRole {
        case control, controlRegular, caption, subheading
        case detail(weight: NSFont.Weight = .regular)
        public func resolved(in surface: Typography.FontSurface = .chrome) -> NSFont {
            let size: CGFloat
            let weight: NSFont.Weight
            switch self {
            case .control: size = 12; weight = .semibold
            case .controlRegular: size = 12; weight = .regular
            case .caption: size = 11; weight = .regular
            case .subheading: size = 12; weight = .semibold
            case .detail(let detailWeight): size = 11; weight = detailWeight
            }
            return .systemFont(ofSize: size, weight: weight)
        }
    }
    public enum Opacity { public static let disabledControl: CGFloat = 0.42 }
    public enum Radius {
        public static let control: CGFloat = 4
        public static let controlBorder: CGFloat = 1
        public static func control(fitting size: NSSize) -> CGFloat {
            min(control, max(0, min(size.width, size.height) / 2))
        }
    }
    @MainActor public enum Surface {
        public static let accent = Specimen.Ink(on: Specimen.headerGround).label
        public static let bevelHighlight = NSColor.white
        public static let bevelShadow = NSColor.black
    }
    public enum Size {
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

        /// The project-row marks plus the folder used by the production subagent row.
        /// Images rasterize once per visible control at 2×, capped to a 32-point canvas.
        public static func image(_ name: String, slot: CGFloat, pointSize: CGFloat,
                                 weight: NSFont.Weight) -> NSImage? {
            precondition(name == "ellipsis" || name == "plus" || name == "folder",
                         "No Linux diagnostic symbol artwork for \(name)")
            precondition(slot.isFinite && pointSize.isFinite && slot > 0 && pointSize > 0)
            let side = min(32, max(4, min(slot, pointSize)))
            let weightFactor: CGFloat = weight.rawValue >= NSFont.Weight.bold.rawValue ? 1.25
                : weight.rawValue >= NSFont.Weight.semibold.rawValue ? 1.12 : 1
            let size = NSSize(width: side, height: side)
            let image = NSImage(size: size, flipped: false) { canvas in
                NSColor.white.setFill()
                if name == "plus" {
                    let stroke = max(1.5, side * 0.15 * weightFactor)
                    let span = side * 0.72
                    NSRect(x: canvas.midX - span / 2, y: canvas.midY - stroke / 2,
                           width: span, height: stroke).fill()
                    NSRect(x: canvas.midX - stroke / 2, y: canvas.midY - span / 2,
                           width: stroke, height: span).fill()
                } else if name == "folder" {
                    let stroke = max(1.4, side * 0.12 * weightFactor)
                    let left = side * 0.11
                    let bottom = side * 0.18
                    let width = side * 0.78
                    let height = side * 0.55
                    NSRect(x: left, y: bottom, width: width, height: stroke).fill()
                    NSRect(x: left, y: bottom + height - stroke, width: width, height: stroke).fill()
                    NSRect(x: left, y: bottom, width: stroke, height: height).fill()
                    NSRect(x: left + width - stroke, y: bottom, width: stroke, height: height).fill()
                    NSRect(x: left + stroke, y: bottom + height,
                           width: side * 0.30, height: stroke).fill()
                } else {
                    let dot = max(1.5, side * 0.19 * weightFactor)
                    for fraction in [CGFloat(0.23), 0.5, 0.77] {
                        NSBezierPath(ovalIn: NSRect(x: side * fraction - dot / 2,
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
