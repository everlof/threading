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
        public let quaternary: NSColor
        public let surface: NSColor
        public let surfaceHover: NSColor
        public let border: NSColor

        public init(on ground: NSColor) {
            let neutral = Specimen.Ink(on: ground)
            label = neutral.label
            secondary = neutral.secondary
            quaternary = neutral.secondary.withAlphaComponent(0.46)
            surface = ground.blended(withFraction: 0.11, of: .black)!
            surfaceHover = ground.blended(withFraction: 0.22, of: .black)!
            border = ground.blended(withFraction: 0.42, of: .black)!
        }
    }

    public enum Accessibility { public static let focusRingWidth: CGFloat = 2 }
    public enum Opacity { public static let disabledControl: CGFloat = 0.42 }
    public enum Radius {
        public static let border: CGFloat = 1
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
        public static let divider = Specimen.Ink(on: Specimen.headerGround).secondary
        public static let border = divider
    }
    public enum Spacing {
        public static let small: CGFloat = 6
        public static let inset: CGFloat = 12
    }
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

        /// Two explicit diagnostic symbols used by project-row actions. An unfamiliar name is
        /// a missing platform service and fails visibly; it is never substituted with a plus.
        /// Images rasterize once per visible control at 2×, capped to a 32-point canvas.
        public static func image(_ name: String, slot: CGFloat, pointSize: CGFloat,
                                 weight: NSFont.Weight) -> NSImage? {
            precondition(name == "ellipsis" || name == "plus",
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
