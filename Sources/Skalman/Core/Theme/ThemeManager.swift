import Foundation
import AppKit

/// Manages terminal themes, including built-in themes, custom themes, and imports.
final class ThemeManager {

    // MARK: - Singleton

    static let shared = ThemeManager()

    // MARK: - Keys

    private enum Keys {
        static let customThemes = "customTerminalThemes"
    }

    // MARK: - Properties

    private let defaults = UserDefaults.standard

    /// Built-in themes that cannot be deleted
    let builtInThemes: [TerminalTheme] = [.basic, .pro, .homebrew, .ocean]

    /// Custom user themes (persisted)
    private(set) var customThemes: [TerminalTheme] {
        get {
            guard let data = defaults.data(forKey: Keys.customThemes),
                  let themes = try? JSONDecoder().decode([TerminalTheme].self, from: data) else {
                return []
            }
            return themes
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.customThemes)
            }
            NotificationCenter.default.post(ThemesDidChange())
        }
    }

    /// All available themes (built-in + custom)
    var allThemes: [TerminalTheme] {
        builtInThemes + customThemes
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Theme Management

    /// Check if a theme is built-in (cannot be deleted)
    func isBuiltIn(_ theme: TerminalTheme) -> Bool {
        builtInThemes.contains { $0.name == theme.name }
    }

    /// The one name a custom theme may not take: the list's app-theme entry is a *name*, and a
    /// user theme wearing it would shadow the entry at every scope that chose it.
    func isReserved(_ name: String) -> Bool {
        name == TerminalThemeNames.followsAppTheme
    }

    /// Add a new custom theme
    func addTheme(_ theme: TerminalTheme) {
        guard !isReserved(theme.name) else { return }
        var themes = customThemes
        // Replace if exists, otherwise append
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            themes[index] = theme
        } else {
            themes.append(theme)
        }
        customThemes = themes
    }

    /// Delete a custom theme (cannot delete built-in themes)
    func deleteTheme(_ theme: TerminalTheme) -> Bool {
        guard !isBuiltIn(theme) else { return false }
        var themes = customThemes
        themes.removeAll { $0.name == theme.name }
        customThemes = themes
        return true
    }

    /// Rename a custom theme
    func renameTheme(_ theme: TerminalTheme, to newName: String) -> Bool {
        guard !isBuiltIn(theme), !isReserved(newName) else { return false }
        guard !allThemes.contains(where: { $0.name == newName }) else { return false }

        var themes = customThemes
        if let index = themes.firstIndex(where: { $0.name == theme.name }) {
            themes[index].name = newName
            customThemes = themes
            return true
        }
        return false
    }

    /// Get a theme by name
    func theme(named name: String) -> TerminalTheme? {
        allThemes.first { $0.name == name }
    }

    /// Duplicate a theme with a new name
    func duplicateTheme(_ theme: TerminalTheme) -> TerminalTheme {
        var newTheme = theme
        var counter = 1
        var newName = "\(theme.name) Copy"

        while allThemes.contains(where: { $0.name == newName }) {
            counter += 1
            newName = "\(theme.name) Copy \(counter)"
        }

        newTheme.name = newName
        addTheme(newTheme)
        return newTheme
    }

    // MARK: - Apple Terminal Import

    /// Import a theme from Apple Terminal's .terminal file
    func importAppleTerminalTheme(from url: URL) throws -> TerminalTheme {
        let data = try Data(contentsOf: url)

        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ThemeImportError.invalidFormat
        }

        // Extract theme name from filename or plist
        let themeName = plist["name"] as? String ?? url.deletingPathExtension().lastPathComponent

        // Ensure unique name
        var finalName = themeName
        var counter = 1
        while allThemes.contains(where: { $0.name == finalName }) {
            counter += 1
            finalName = "\(themeName) \(counter)"
        }

        // Extract colors
        let foreground = try extractColor(from: plist, key: "TextColor") ?? .white
        let background = try extractColor(from: plist, key: "BackgroundColor") ?? .black
        let cursor = try extractColor(from: plist, key: "CursorColor") ?? foreground
        let selection = try extractColor(from: plist, key: "SelectionColor") ?? NSColor(white: 0.3, alpha: 1.0)

        // Extract ANSI colors
        let ansiColors = try extractANSIColors(from: plist)

        let theme = TerminalTheme(
            name: finalName,
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: selection,
            black: ansiColors[0],
            red: ansiColors[1],
            green: ansiColors[2],
            yellow: ansiColors[3],
            blue: ansiColors[4],
            magenta: ansiColors[5],
            cyan: ansiColors[6],
            white: ansiColors[7],
            brightBlack: ansiColors[8],
            brightRed: ansiColors[9],
            brightGreen: ansiColors[10],
            brightYellow: ansiColors[11],
            brightBlue: ansiColors[12],
            brightMagenta: ansiColors[13],
            brightCyan: ansiColors[14],
            brightWhite: ansiColors[15]
        )

        addTheme(theme)
        return theme
    }

    // MARK: - Private Helpers

    private func extractColor(from plist: [String: Any], key: String) throws -> NSColor? {
        guard let colorData = plist[key] as? Data else {
            return nil
        }

        // Apple Terminal stores colors as NSKeyedArchiver data
        // Try the standard unarchiver first
        if let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            return color.usingColorSpace(.sRGB) ?? color
        }

        // Fallback: manually parse the archived plist to extract RGB components
        if let plist = try? PropertyListSerialization.propertyList(from: colorData, format: nil) as? [String: Any],
           let objects = plist["$objects"] as? [Any] {
            for obj in objects {
                if let dict = obj as? [String: Any] {
                    // Prefer NSComponents (calibrated colors) - this is what Terminal.app displays
                    // NSComponents is in calibrated RGB which matches visual appearance
                    if let compData = dict["NSComponents"] as? Data {
                        let text = String(data: compData, encoding: .ascii)?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        let parts = text.split(separator: " ")
                        if parts.count >= 3,
                           let r = Double(parts[0]),
                           let g = Double(parts[1]),
                           let b = Double(parts[2]) {
                            // Use calibratedRGB to match Terminal.app's display color space
                            return NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
                        }
                    }
                    // Fallback to NSRGB if no NSComponents
                    if let rgbData = dict["NSRGB"] as? Data {
                        let text = String(data: rgbData, encoding: .ascii)?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        let parts = text.split(separator: " ")
                        if parts.count >= 3,
                           let r = Double(parts[0]),
                           let g = Double(parts[1]),
                           let b = Double(parts[2]) {
                            return NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0)
                        }
                    }
                }
            }
        }

        return nil
    }

    private func extractANSIColors(from plist: [String: Any]) throws -> [NSColor] {
        var colors: [NSColor] = []

        // Terminal.app uses ANSIBlackColor, ANSIRedColor, etc.
        let colorNames = [
            "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
            "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
            "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
            "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor"
        ]

        // Terminal.app's actual default ANSI colors (from Pro profile defaults)
        let defaultColors: [NSColor] = [
            NSColor(hex: "#000000")!,       // Black
            NSColor(hex: "#990000")!,       // Red
            NSColor(hex: "#00A600")!,       // Green
            NSColor(hex: "#999900")!,       // Yellow
            NSColor(hex: "#0000B2")!,       // Blue
            NSColor(hex: "#B200B2")!,       // Magenta
            NSColor(hex: "#00A6B2")!,       // Cyan
            NSColor(hex: "#BFBFBF")!,       // White
            NSColor(hex: "#666666")!,       // Bright Black
            NSColor(hex: "#E50000")!,       // Bright Red
            NSColor(hex: "#00D900")!,       // Bright Green
            NSColor(hex: "#E5E500")!,       // Bright Yellow
            NSColor(hex: "#0000FF")!,       // Bright Blue
            NSColor(hex: "#E500E5")!,       // Bright Magenta
            NSColor(hex: "#00E5E5")!,       // Bright Cyan
            NSColor(hex: "#E5E5E5")!        // Bright White
        ]

        for (index, colorName) in colorNames.enumerated() {
            if let color = try extractColor(from: plist, key: colorName) {
                colors.append(color)
            } else {
                colors.append(defaultColors[index])
            }
        }

        return colors
    }
}

// MARK: - Theme Import Error

enum ThemeImportError: LocalizedError {
    case invalidFormat
    case missingColors
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "The file is not a valid Terminal theme file."
        case .missingColors:
            return "The theme file is missing required color definitions."
        case .fileNotFound:
            return "The theme file could not be found."
        }
    }
}
