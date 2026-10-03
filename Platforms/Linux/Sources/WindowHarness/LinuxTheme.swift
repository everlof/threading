import AppKit
import Foundation

/// App-owned bridge from the production Threading style to the Linux AppKit shim. The checked
/// snapshot is exported by LinuxThemeSnapshotTests on macOS; the shim owns no palette policy.
@MainActor
enum LinuxTheme {
    private static let palettes: [String: [String: [Double]]] = {
        guard let url = Bundle.module.url(forResource: "threading", withExtension: "json",
                                          subdirectory: "Theme"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(
                [String: [String: [Double]]].self, from: data) else {
            preconditionFailure("Missing bundled production Threading theme snapshot")
        }
        return value
    }()

    /// A visible list can ask for the same role many times per frame. Build each named provider
    /// once, then let its appearance closure choose between the two fixed export values.
    private static let namedColors: [String: NSColor] = {
        guard let roles = palettes["light"] else {
            preconditionFailure("Missing light Threading theme snapshot")
        }
        return Dictionary(uniqueKeysWithValues: roles.keys.map { role in
            let light = fixedColor(role, dark: false)
            let dark = fixedColor(role, dark: true)
            let color = NSColor(name: NSColor.Name("threading.linux.\(role)")) { appearance in
                appearance.name == .darkAqua ? dark : light
            }
            return (role, color)
        })
    }()

    private(set) static var isDark = false

    static var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    static func setDark(_ dark: Bool) {
        isDark = dark
    }

    /// A named color stays live when the root view's appearance changes. Bitmap fills use
    /// `components` instead because they must be resolved at the moment the bitmap is seeded.
    static func color(_ role: String) -> NSColor {
        guard let color = namedColors[role] else {
            preconditionFailure("Missing Threading theme role: \(role)")
        }
        return color
    }

    static func components(_ role: String) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        fixedColor(role, dark: isDark).components
    }

    static func neutralInk(on ground: NSColor, dark: Bool) -> Specimen.Ink {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var result: Specimen.Ink!
        appearance.performAsCurrentDrawingAppearance {
            result = Specimen.Ink(on: ground)
        }
        return result
    }

    private static func fixedColor(_ role: String, dark: Bool) -> NSColor {
        let mode = dark ? "dark" : "light"
        guard let values = palettes[mode]?[role], values.count == 4 else {
            preconditionFailure("Missing Threading \(mode) theme role: \(role)")
        }
        return NSColor(red: values[0], green: values[1], blue: values[2], alpha: values[3])
    }
}
