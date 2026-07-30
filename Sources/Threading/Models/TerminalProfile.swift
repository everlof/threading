import Foundation
import AppKit

/// User preferences for a terminal session.
struct TerminalProfile: Codable, Equatable {

    // MARK: - Properties

    var name: String
    var fontName: String
    var fontSize: CGFloat
    var theme: TerminalTheme
    var shellPath: String
    var shellArguments: [String]
    var cursorStyle: CursorStyle
    var cursorBlink: Bool
    var scrollbackLines: Int

    // MARK: - Cursor Style

    enum CursorStyle: String, Codable, CaseIterable {
        case block
        case underline
        case bar

        var displayName: String {
            switch self {
            case .block: return "Block"
            case .underline: return "Underline"
            case .bar: return "Bar"
            }
        }
    }

    // MARK: - Default Profile

    static let `default` = TerminalProfile(
        name: "Default",
        fontName: TerminalDefaults.defaultFont,
        fontSize: TerminalDefaults.defaultFontSize,
        theme: .basic,
        shellPath: TerminalDefaults.defaultShell,
        shellArguments: ["-l"],
        cursorStyle: .block,
        cursorBlink: true,
        scrollbackLines: TerminalDefaults.scrollbackLines
    )

    // MARK: - Font

    var font: NSFont {
        if let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}

// MARK: - Profile Storage

@MainActor
final class ProfileStorage {

    // MARK: - Keys

    private enum Keys {
        static let profiles = "terminalProfiles"
        static let defaultProfileName = "defaultProfileName"
    }

    // MARK: - Singleton

    static let shared = ProfileStorage()

    private init() {}

    // MARK: - Storage

    /// The profile carries the app-wide default *theme* as well as font and shell, so it is a
    /// recorded choice and goes through `PreferenceStore` — the hosted tests set the default
    /// theme and would otherwise set the user's.
    private let defaults = PreferenceStore.shared

    var profiles: [TerminalProfile] {
        get {
            guard let data = defaults.data(forKey: Keys.profiles),
                  let profiles = try? JSONDecoder().decode([TerminalProfile].self, from: data) else {
                return [.default]
            }
            return profiles
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.profiles)
            }
        }
    }

    var defaultProfile: TerminalProfile {
        get {
            let name = defaults.string(forKey: Keys.defaultProfileName) ?? TerminalProfile.default.name
            return profiles.first { $0.name == name } ?? .default
        }
        set {
            defaults.set(newValue.name, forKey: Keys.defaultProfileName)
            if !profiles.contains(where: { $0.name == newValue.name }) {
                profiles.append(newValue)
            }
        }
    }

    func save(_ profile: TerminalProfile) {
        var currentProfiles = profiles
        if let index = currentProfiles.firstIndex(where: { $0.name == profile.name }) {
            currentProfiles[index] = profile
        } else {
            currentProfiles.append(profile)
        }
        profiles = currentProfiles
        NotificationCenter.default.post(ProfileDidChange(profile: profile))
    }

    func delete(_ profile: TerminalProfile) {
        profiles = profiles.filter { $0.name != profile.name }
    }

    /// Update the theme for the default profile and notify terminals
    func setTheme(_ theme: TerminalTheme) {
        var profile = defaultProfile
        profile.theme = theme
        save(profile)
        defaultProfile = profile
    }
}
