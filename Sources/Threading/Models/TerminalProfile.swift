import Foundation
import AppKit

/// User preferences for a terminal session.
/// A profile is a value snapshot. Its only AppKit-bearing values are the immutable colours held by
/// `TerminalTheme`; the computed `NSFont` is created on demand and is never part of the snapshot.
public struct TerminalProfile: Codable, Equatable, @unchecked Sendable {

    // MARK: - Properties

    public var name: String
    public var fontName: String
    public var fontSize: CGFloat
    public var theme: TerminalTheme
    public var shellPath: String
    public var shellArguments: [String]
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    public var scrollbackLines: Int

    // MARK: - Cursor Style

    public enum CursorStyle: String, Codable, CaseIterable {
        case block
        case underline
        case bar

        public var displayName: String {
            switch self {
            case .block: return "Block"
            case .underline: return "Underline"
            case .bar: return "Bar"
            }
        }
    }

    // MARK: - Default Profile

    /// **The default terminal palette follows the app theme.**
    ///
    /// It used to be `.basic` — white on black, whatever the chrome was doing. That made the
    /// designed pairing in every stock theme (`AppTheme.terminalPalette`, sixteen ANSI colours
    /// written out per style precisely because deriving them from eleven roles gives eight
    /// near-hues) invisible unless the user went looking for it in a submenu, and it left a
    /// light-mode window holding a black terminal, which is the one thing `WindowBackdrop` and
    /// the OSC 11 reply exist to keep coherent. It also made the chain's default the one scope
    /// that could not move: with every session and project on Inherit — the shipped state —
    /// switching app theme changed the window and not the terminal inside it.
    ///
    /// Nothing is taken away: naming a palette at any scope still wins over this, and the
    /// narrowest scope still decides.
    public static let `default` = TerminalProfile(
        name: "Default",
        fontName: TerminalDefaults.defaultFont,
        fontSize: TerminalDefaults.defaultFontSize,
        theme: .followsAppTheme,
        shellPath: TerminalDefaults.defaultShell,
        shellArguments: ["-l"],
        cursorStyle: .block,
        cursorBlink: true,
        scrollbackLines: TerminalDefaults.scrollbackLines
    )

    // MARK: - Font

    public var font: NSFont {
        if let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}

// MARK: - Profile Storage

@MainActor
public final class ProfileStorage {

    // MARK: - Keys

    private enum Keys {
        static let profiles = "terminalProfiles"
        static let defaultProfileName = "defaultProfileName"
    }

    // MARK: - Singleton

    public static let shared = ProfileStorage()

    // MARK: - Storage

    /// The profile carries the app-wide default *theme* as well as font and shell, so it is a
    /// recorded choice and goes through `PreferenceStore` — the hosted tests set the default
    /// theme and would otherwise set the user's.
    private let defaults: UserDefaults
    private let persistence: RecoverableDefaultsStore<[TerminalProfile]>
    private var storedProfiles: [TerminalProfile]

    // Not published: the default argument names the application's own preference store.
    init(defaults: UserDefaults = PreferenceStore.shared) {
        self.defaults = defaults
        self.persistence = RecoverableDefaultsStore(
            defaults: defaults,
            key: Keys.profiles,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.storedProfiles = persistence.load(defaultValue: [.default]).value
    }

    public var profiles: [TerminalProfile] {
        get { storedProfiles }
        set {
            if persistence.save(newValue) {
                storedProfiles = newValue
            }
        }
    }

    public var defaultProfile: TerminalProfile {
        get {
            let name = defaults.string(forKey: Keys.defaultProfileName) ?? TerminalProfile.default.name
            return profiles.first { $0.name == name } ?? .default
        }
        set {
            var candidate = storedProfiles
            if !candidate.contains(where: { $0.name == newValue.name }) {
                candidate.append(newValue)
            }
            guard persistence.save(candidate) else { return }

            storedProfiles = candidate
            defaults.set(newValue.name, forKey: Keys.defaultProfileName)
        }
    }

    @discardableResult
    private func persist(_ candidate: [TerminalProfile]) -> Bool {
        guard persistence.save(candidate) else { return false }
        storedProfiles = candidate
        return true
    }

    public func save(_ profile: TerminalProfile) {
        var candidate = storedProfiles
        if let index = candidate.firstIndex(where: { $0.name == profile.name }) {
            candidate[index] = profile
        } else {
            candidate.append(profile)
        }
        if persist(candidate) {
            NotificationCenter.default.post(ProfileDidChange(profile: profile))
        }
    }

    public func delete(_ profile: TerminalProfile) {
        persist(storedProfiles.filter { $0.name != profile.name })
    }

    /// Update the theme for the default profile and notify terminals
    public func setTheme(_ theme: TerminalTheme) {
        var profile = defaultProfile
        profile.theme = theme
        save(profile)
        if storedProfiles.contains(where: { $0.name == profile.name }) {
            defaults.set(profile.name, forKey: Keys.defaultProfileName)
        }
    }
}

// MARK: - Change Event

/// Posted when the terminal profile changes.
///
/// Declared here rather than beside the other settings events because its payload is a
/// `TerminalProfile`, and this file imports AppKit. In `SettingsEvents.swift` it made that whole
/// file AppKit-bearing, which put AppKit in the closure of everything posting an ordinary settings
/// change — including the persisted `LimitRecoveryPolicy` on `Project`.
public struct ProfileDidChange: AppEvent {
    public static let name = Notification.Name("profileDidChange")
    public let profile: TerminalProfile
}
