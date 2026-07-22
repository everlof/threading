import AppKit

// MARK: - Theme Identity

/// A theme's durable identity, distinct from the name shown to the user.
///
/// Terminal themes are keyed by their display name, which was fine for four built-ins that
/// never move. A *shipped library* cannot work that way: renaming a stock theme in some future
/// release would silently reset every assignment naming it, because the re-point in
/// `ProjectStore.renameTheme` only runs when the user renames one. A slug costs nothing now and
/// is the thing that cannot be retrofitted later.
struct AppThemeID: Hashable, Codable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    /// The identity theme: every role answers with the system colour it always did.
    static let system = AppThemeID("system")
}

// MARK: - App Theme

/// A named set of answers for the app's own chrome.
///
/// What a theme deliberately does **not** carry is layout or motion. The design styles these
/// are drawn from are briefs for marketing pages — hero splits, pricing tables, glitch
/// animations — and Skalman's layout is its product rather than its decoration. A theme that
/// moved the sidebar would not be a theme. So the promise is the one VS Code makes: an app that
/// *reads as* Cyberpunk, not Cyberpunk recreated.
struct AppTheme: Codable, Equatable {

    let id: AppThemeID
    let name: String

    /// Light or dark. Drives the window's `NSAppearance` too, or a dark theme gets the
    /// system's light scrollers and menus drawn over it.
    let mode: Mode

    /// One line, shown under the name where a theme is chosen.
    let summary: String?

    /// The roles this theme states. Everything absent is derived — see `resolved`.
    let roles: [AppThemeRole: NSColor]

    enum Mode: String, Codable {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }
    }

    // MARK: - The System Theme

    /// The app as it was before any of this: every role answers with its system colour, so
    /// light and dark and the user's own accent all keep working.
    static let system = AppTheme(
        id: .system,
        name: "System",
        mode: .light,
        summary: "Follows macOS — light, dark, and your accent colour.",
        roles: [:]
    )

    var isSystem: Bool { id == .system }

    // MARK: - Resolution

    /// The colour for a role: what the theme states, else what can be derived from what it
    /// states, else the system colour.
    ///
    /// Derivation is what keeps a theme document to a dozen values instead of twenty-five, and
    /// it is not optional politeness: a style that stated a fixed dark ground and let the
    /// *labels* fall back to the system's would flip half the window when macOS switched
    /// appearance. A themed role never falls back to a dynamic system colour.
    func resolved(_ role: AppThemeRole) -> NSColor {
        if let stated = roles[role] { return stated }
        guard !isSystem, let derived = derive(role) else { return role.systemColor }
        return derived
    }

    private func derive(_ role: AppThemeRole) -> NSColor? {
        switch role {
        case .elevated:
            return roles[.panel]?.lightened(by: mode == .dark ? 0.06 : -0.04)
        case .controlResting:
            return roles[.label].map { $0.withAlphaComponent(0.08) }
        case .controlHover:
            return roles[.label].map { $0.withAlphaComponent(0.14) }
        case .divider:
            return roles[.border].map { $0.withAlphaComponent(0.5) }
        case .secondaryLabel:
            return roles[.label].map { $0.withAlphaComponent(0.7) }
        case .tertiaryLabel:
            return roles[.label].map { $0.withAlphaComponent(0.45) }
        case .quaternaryLabel:
            return roles[.label].map { $0.withAlphaComponent(0.25) }
        case .accentMuted:
            return roles[.accent].map { $0.withAlphaComponent(0.22) }
        case .selection:
            return roles[.accent].map { $0.withAlphaComponent(0.35) }
        case .diffAdded:
            return roles[.statusPositive]
        case .diffRemoved:
            return roles[.statusNegative]
        case .syntaxComment:
            return roles[.label].map { $0.withAlphaComponent(0.45) }
        case .surface:
            return roles[.ground]
        case .panel:
            return roles[.surface]?.lightened(by: mode == .dark ? 0.05 : -0.03)
        default:
            return nil
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, summary, roles
    }

    init(
        id: AppThemeID,
        name: String,
        mode: Mode,
        summary: String?,
        roles: [AppThemeRole: NSColor]
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.summary = summary
        self.roles = roles
    }

    /// Roles are written as a hex map keyed by the role's own name, so a theme document is
    /// hand-writable and reviewable in a diff — the same reason `TerminalTheme` stores hex.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppThemeID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(Mode.self, forKey: .mode)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)

        let hexes = try container.decodeIfPresent([String: String].self, forKey: .roles) ?? [:]
        var parsed: [AppThemeRole: NSColor] = [:]
        for (key, hex) in hexes {
            // An unknown role name is skipped rather than thrown: a document written by a later
            // release should lose the role it names, not fail to load at all.
            guard let role = AppThemeRole(rawValue: key), let color = NSColor(hex: hex) else { continue }
            parsed[role] = color
        }
        roles = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(summary, forKey: .summary)

        var hexes: [String: String] = [:]
        for (role, color) in roles { hexes[role.rawValue] = color.hexString }
        try container.encode(hexes, forKey: .roles)
    }
}

// MARK: - Colour Helpers

extension NSColor {

    /// Moves a colour toward white (positive) or black (negative), in sRGB.
    ///
    /// Used only for *derived* roles, where the alternative is making every theme state a panel
    /// fill that is obviously its surface a little lighter.
    func lightened(by amount: CGFloat) -> NSColor {
        guard let srgb = usingColorSpace(.sRGB) else { return self }
        let target: CGFloat = amount >= 0 ? 1 : 0
        let t = abs(amount)

        return NSColor(
            srgbRed: srgb.redComponent + (target - srgb.redComponent) * t,
            green: srgb.greenComponent + (target - srgb.greenComponent) * t,
            blue: srgb.blueComponent + (target - srgb.blueComponent) * t,
            alpha: srgb.alphaComponent
        )
    }
}
