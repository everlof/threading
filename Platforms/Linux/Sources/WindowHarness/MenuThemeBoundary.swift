import AppKit
import CoreSlice

// The installed Linux preview consumes a checked production palette. These app-owned role values
// support the unchanged production menu row; no theme decisions belong in the AppKit shim.
@MainActor
public enum AppTheme {
    public struct Material {
        public enum IdentityMarks { case natural, tinted }
        public enum BadgeStyle { case none, sticker }
        public enum ChoiceStyle: Equatable {
            case chip, dropdown, popup, doubleArrowPopup, aquaPopup, cycle

            var isClassic: Bool { self != .chip }
        }
        public enum MenuAppearance {
            case automatic, windows98, platinum, beOS, openStep, irix, amiga, aqua, aquaTiger

            var isHistorical: Bool { self != .automatic }
        }
    }
}

extension AppThemePalette.Material {
    var identityMarks: AppTheme.Material.IdentityMarks { .natural }
    var badgeStyle: AppTheme.Material.BadgeStyle { .none }
    var menuAppearance: AppTheme.Material.MenuAppearance { .automatic }
    var choiceStyle: AppTheme.Material.ChoiceStyle { .chip }
}

extension AppThemePalette.Palette {
    func material(for appearance: NSAppearance) -> AppThemePalette.Material { material }
}

@MainActor
enum DesignSettings {
    struct Settings {
        let chromeFontFamily: String? = nil
        var promptReturnKey: PromptReturnKey {
            let stored = UserDefaults.standard.string(forKey: "promptReturnKey")
            return stored.flatMap(PromptReturnKey.init(rawValue:)) ?? .matchesComposer
        }
    }
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

    static func pill(height: CGFloat) -> CGFloat { max(0, height / 2) }

    static func edgeReach(of radius: CGFloat, clearing margin: CGFloat) -> CGFloat {
        guard radius > margin, margin >= 0 else { return 0 }
        return radius - (2 * radius * margin - margin * margin).squareRoot()
    }
}

extension Design.Surface {
    static var elevated: NSColor { LinuxTheme.color("elevated") }
    static var field: NSColor { LinuxTheme.color("fieldSurface") }
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
        static var label: NSColor { LinuxTheme.color("label") }
        static var selected: NSColor { Design.Ink.selection.label }
        static var secondary: NSColor { LinuxTheme.color("text.secondary") }
        static var tertiary: NSColor { LinuxTheme.color("text.tertiary") }
        static var quaternary: NSColor { LinuxTheme.color("text.quaternary") }
    }

    @MainActor enum Status {
        static var warning: NSColor { LinuxTheme.color("statusWarning") }
        static var negative: NSColor { LinuxTheme.color("statusNegative") }
    }

    enum Typography {
        static func body() -> NSFont { NSFont.systemFont(ofSize: 13, weight: .regular) }
        static func heading() -> NSFont { NSFont.systemFont(ofSize: 20, weight: .semibold) }
        static func subheading() -> NSFont { NSFont.systemFont(ofSize: 12, weight: .regular) }
        static func numericBody() -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular) }
        static func informationalMark() -> NSFont { NSFont.systemFont(ofSize: 20, weight: .bold) }

        static func control(weight: NSFont.Weight = .medium) -> NSFont {
            NSFont.systemFont(ofSize: 12, weight: weight)
        }

        static func controlRegular() -> NSFont { control(weight: .regular) }
        static func caption() -> NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }
        static func detail() -> NSFont { NSFont.systemFont(ofSize: 11) }
        static func numericDetail(weight: NSFont.Weight = .regular) -> NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: weight) }
        static func lineHeight(of font: NSFont) -> CGFloat {
            font.boundingRectForFont.height
        }
    }
}
