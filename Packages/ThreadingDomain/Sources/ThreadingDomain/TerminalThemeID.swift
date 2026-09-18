import Foundation

// A terminal theme's identity, and the one reserved name the migration from name-keyed state
// recognises.
//
// These lived in the app's `Models/TerminalTheme.swift`, beside the theme's colours and its
// SwiftTerm colour bridge — so the file opened with `import AppKit` and `import SwiftTerm`, and
// every type needing only the identity inherited both. `Project` and `AgentSession` decode a
// `TerminalThemeID` (and call `migratedFromName`) while loading persisted state, which put a UI
// framework and a terminal emulator in the transitive closure of reading the project database.
// Both types are Foundation-only, so they belong with the other stable identities here.
//
// `TerminalThemeNames.followsAppTheme` is a label rather than an identity, and lives here only
// because `migratedFromName` must recognise it in state written before IDs existed.

// MARK: - Identity

/// A terminal theme's durable identity, separate from its editable display name.
public struct TerminalThemeID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let basic = TerminalThemeID("basic")
    public static let pro = TerminalThemeID("pro")
    public static let homebrew = TerminalThemeID("homebrew")
    public static let ocean = TerminalThemeID("ocean")
    public static let roseMoon = TerminalThemeID("rose-moon")
    public static let followsAppTheme = TerminalThemeID("follow-app-theme")

    public static func makeCustom() -> TerminalThemeID {
        TerminalThemeID("custom-\(UUID().uuidString.lowercased())")
    }

    /// State written before IDs existed is tagged with its old name. The tag cannot collide
    /// with a real ID and lets the assignment layer resolve it once against the theme library.
    public static func legacyName(_ name: String) -> TerminalThemeID {
        TerminalThemeID("legacy-name-\(encodedComponent(name))")
    }

    /// A deterministic replacement for a persisted custom theme that claims an ID already in
    /// use. Migration used a fresh UUID here; if its best-effort rewrite failed, the in-memory ID
    /// changed again on every launch and any project assignment saved meanwhile became dangling.
    public static func recoveredFromCollision(name: String, ordinal: Int) -> TerminalThemeID {
        TerminalThemeID("recovered-custom-\(encodedComponent(name))-\(ordinal)")
    }

    public var legacyName: String? {
        let prefix = "legacy-name-"
        guard rawValue.hasPrefix(prefix) else { return nil }
        var encoded = String(rawValue.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func migratedFromName(_ name: String) -> TerminalThemeID {
        switch name {
        case "Basic": return .basic
        case "Pro": return .pro
        case "Homebrew": return .homebrew
        case "Ocean": return .ocean
        case TerminalThemeNames.followsAppTheme: return .followsAppTheme
        default: return .legacyName(name)
        }
    }

    private static func encodedComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Reserved Entry

public enum TerminalThemeNames: Sendable {
    /// The terminal-theme list's first entry: draw with the palette the *app* theme states.
    ///
    /// The ID is the identity; this name is only the label shown to people and older clients.
    public static let followsAppTheme = "Follow App Theme"
}
