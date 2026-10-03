import AppKit

// The installed Linux preview consumes a checked production palette. These app-owned role values
// support the unchanged production menu row; no theme decisions belong in the AppKit shim.
@MainActor
public enum AppTheme {
    public enum Material {
        public enum MenuAppearance {
            case automatic, windows98, platinum, beOS, openStep, irix, amiga, aqua, aquaTiger

            var isHistorical: Bool { self != .automatic }
        }
    }
}

extension AppThemePalette.Material {
    var menuAppearance: AppTheme.Material.MenuAppearance { .automatic }
}

@MainActor
enum DesignSettings {
    struct Settings { let chromeFontFamily: String? = nil }
    static let current = Settings()
}

extension Design.Spacing {
    static let hairline: CGFloat = 2
    static let tight: CGFloat = 4
    static let medium: CGFloat = 10
    static let large: CGFloat = 20
}

extension Design.Radius {
    static let panel: CGFloat = 10

    static func edgeReach(of radius: CGFloat, clearing margin: CGFloat) -> CGFloat {
        guard radius > margin, margin >= 0 else { return 0 }
        return radius - (2 * radius * margin - margin * margin).squareRoot()
    }
}

extension Design.Surface {
    static var elevated: NSColor { LinuxTheme.color("elevated") }
    static var controlResting: NSColor { LinuxTheme.color("controlResting") }
    static var controlHover: NSColor { LinuxTheme.color("controlHover") }
}

extension Design.Symbol {
    static let control: CGFloat = 12
    static func pointSize(forSlot slot: CGFloat) -> CGFloat { min(control, slot) }

    static func image(_ name: String, slot: CGFloat, pointSize: CGFloat) -> NSImage? {
        image(name, slot: slot, pointSize: pointSize, weight: .regular)
    }
}

extension Design {
    @MainActor enum Text {
        private static let chromeInk = Design.Ink(on: LinuxTheme.color("ground"))
        static var label: NSColor { LinuxTheme.color("label") }
        static var selected: NSColor { Design.Ink.selection.label }
        static var secondary: NSColor { chromeInk.secondary }
        static var tertiary: NSColor { chromeInk.tertiary }
    }

    @MainActor enum Status {
        static var warning: NSColor { LinuxTheme.color("statusWarning") }
        static var negative: NSColor { LinuxTheme.color("statusNegative") }
    }

    enum Typography {
        static func control(weight: NSFont.Weight = .medium) -> NSFont {
            NSFont.systemFont(ofSize: 12, weight: weight)
        }

        static func controlRegular() -> NSFont { control(weight: .regular) }
        static func caption() -> NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }
        static func detail() -> NSFont { NSFont.systemFont(ofSize: 11) }
        static func numericDetail() -> NSFont { NSFont.monospacedSystemFont(ofSize: 11) }
        static func lineHeight(of font: NSFont) -> CGFloat {
            font.boundingRectForFont.height
        }
    }
}

@MainActor
struct SelectionSurface {
    let fill: NSColor
    let ink: Design.Ink

    static func stated(over ground: NSColor) -> SelectionSurface {
        let fill = LinuxTheme.color("selection")
        return SelectionSurface(fill: fill, ink: .selection)
    }
}
