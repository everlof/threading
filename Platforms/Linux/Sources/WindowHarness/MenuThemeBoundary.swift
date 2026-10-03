import AppKit

// The installed Linux preview has one fixed diagnostic palette. These are app-owned role values
// for the unchanged production menu row; no theme decisions belong in the AppKit shim.
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
    static let elevated = Specimen.bodyGround
    static let controlResting = Specimen.bodyGround
    static let controlHover = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 0.23)
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
        static let label = Specimen.Ink(on: Specimen.bodyGround).label
        static let selected = Specimen.Ink(on: NSColor(red: 0.16, green: 0.42,
                                                       blue: 0.78, alpha: 1)).label
        static let secondary = Specimen.Ink(on: Specimen.bodyGround).secondary
        static let tertiary = secondary.withAlphaComponent(0.7)
    }

    enum Status {
        static let warning = NSColor(red: 0.48, green: 0.27, blue: 0.02, alpha: 1)
        static let negative = NSColor(red: 0.62, green: 0.12, blue: 0.12, alpha: 1)
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
        let fill = NSColor(red: 0.16, green: 0.42, blue: 0.78, alpha: 1)
        return SelectionSurface(fill: fill, ink: Design.Ink(on: fill))
    }
}
