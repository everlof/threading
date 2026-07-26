import AppKit

// MARK: - Theme Identity

/// A theme's durable identity, distinct from the name shown to the user.
///
/// App and terminal themes both use stable IDs. A *shipped library* cannot rely on display
/// names: renaming a stock theme in some future release must not silently reset assignments.
/// The slug is persistence identity; `name` is presentation and may change independently.
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

    /// Adaptive, light, or dark. Fixed themes pin the window's `NSAppearance`; an adaptive
    /// theme leaves it unpinned and resolves its matching variant as macOS changes appearance.
    let mode: Mode

    /// One line, shown under the name where a theme is chosen.
    let summary: String?

    /// One or both authored appearances. Existing fixed themes carry one; adaptive themes carry
    /// both. System carries neither because its roles are AppKit's own dynamic colours.
    let variants: [VariantKind: Variant]

    /// Compatibility projections for the rest of the app. Feature views ask for the material,
    /// palette, or roles that match the appearance currently drawing; they do not need to know
    /// whether the theme stored one variant or two.
    var roles: [AppThemeRole: NSColor] { activeVariant?.roles ?? [:] }
    var terminalPalette: TerminalTheme {
        activeVariant?.terminalPalette ?? TerminalTheme.basic.renamed(name)
    }
    var material: Material { activeVariant?.material ?? .system }

    enum VariantKind: String, Codable, CaseIterable, Hashable {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }

        init(mode: Mode) {
            self = mode == .dark ? .dark : .light
        }

        static func current(in appearance: NSAppearance = NSAppearance.currentDrawing()) -> Self {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    /// Everything whose authored values may genuinely differ between light and dark.
    ///
    /// Material is variant-owned too: a pale paper style may need a hard ink shadow while its
    /// night counterpart needs a restrained glow. The paired terminal palette must vary because
    /// its foreground, background, selection, and all sixteen ANSI colours are one contrast set.
    struct Variant: Codable, Equatable {
        let roles: [AppThemeRole: NSColor]
        let terminalPalette: TerminalTheme
        let material: Material

        private enum CodingKeys: String, CodingKey {
            case roles, terminalPalette
            case material
        }

        init(
            roles: [AppThemeRole: NSColor],
            terminalPalette: TerminalTheme,
            material: Material
        ) {
            self.roles = roles
            self.terminalPalette = terminalPalette
            self.material = material
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let hexes = try container.decodeIfPresent([String: String].self, forKey: .roles) ?? [:]
            var parsed: [AppThemeRole: NSColor] = [:]
            for (key, hex) in hexes {
                guard let role = AppThemeRole(rawValue: key),
                      let color = NSColor(hex: hex) else { continue }
                parsed[role] = color
            }
            roles = parsed
            material = try container.decodeIfPresent(Material.self, forKey: .material) ?? .system
            terminalPalette = try container.decode(TerminalTheme.self, forKey: .terminalPalette)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                Dictionary(uniqueKeysWithValues: roles.map { ($0.key.rawValue, $0.value.hexString) }),
                forKey: .roles
            )
            try container.encode(material, forKey: .material)
            try container.encode(terminalPalette, forKey: .terminalPalette)
        }
    }

    /// Radii, border weight and an optional panel shadow.
    struct Material: Codable, Equatable {
        /// Containers holding content — cards, the prompt box.
        var panelRadius: CGFloat = 12
        /// Smaller things nested inside them — chips, swatches.
        var controlRadius: CGFloat = 8
        var borderWidth: CGFloat = 1

        /// A shadow behind opted-in panels, in one of the theme's own colours. A zero offset
        /// reads as a glow; a non-zero, zero-radius shadow gives Bauhaus and Neo Brutalism
        /// their hard printed lift without teaching feature views about either style.
        var glow: Glow?

        static let system = Material()
    }

    struct Glow: Codable, Equatable {
        let role: AppThemeRole
        let radius: CGFloat
        let opacity: Double
        let offsetX: CGFloat
        let offsetY: CGFloat

        init(
            role: AppThemeRole,
            radius: CGFloat,
            opacity: Double,
            offsetX: CGFloat = 0,
            offsetY: CGFloat = 0
        ) {
            self.role = role
            self.radius = radius
            self.opacity = opacity
            self.offsetX = offsetX
            self.offsetY = offsetY
        }

        private enum CodingKeys: String, CodingKey {
            case role, radius, opacity, offsetX, offsetY
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(AppThemeRole.self, forKey: .role)
            radius = try container.decode(CGFloat.self, forKey: .radius)
            opacity = try container.decode(Double.self, forKey: .opacity)
            offsetX = try container.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
            offsetY = try container.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0
        }
    }

    enum Mode: String, Codable {
        case system, light, dark

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }

        /// The agent-facing term is “adaptive”; `system` survives in persisted documents for
        /// compatibility with the original System-only implementation.
        var appearanceName: String { self == .system ? "adaptive" : rawValue }
    }

    // MARK: - The System Theme

    /// The app as it was before any of this: every role answers with its system colour, so
    /// light and dark and the user's own accent all keep working.
    static let system = AppTheme(
        id: .system,
        name: "System",
        mode: .system,
        summary: "Follows macOS — light, dark, and your accent colour.",
        roles: [:],
        // The palette the app has always defaulted to, so "Follow App Theme" under the System
        // theme is not a change of appearance — it is the same terminal, said differently.
        terminalPalette: TerminalTheme.basic.renamed("System"),
        material: .system
    )

    var isSystem: Bool { id == .system }
    var isAdaptive: Bool { mode == .system }
    var availableVariants: [VariantKind] {
        VariantKind.allCases.filter { variants[$0] != nil }
    }

    func variant(_ kind: VariantKind) -> Variant? {
        variants[kind]
    }

    func variantKind(for appearance: NSAppearance = NSAppearance.currentDrawing()) -> VariantKind {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return .current(in: appearance)
        }
    }

    func variant(for appearance: NSAppearance = NSAppearance.currentDrawing()) -> Variant? {
        let preferred = variantKind(for: appearance)
        return variants[preferred]
            ?? variants[preferred == .light ? .dark : .light]
    }

    private var activeVariant: Variant? {
        variant()
    }

    // MARK: - Resolution

    /// The colour for a role: what the theme states, else what can be derived from what it
    /// states, else the system colour.
    ///
    /// Derivation is what keeps a theme document to a dozen values instead of twenty-five, and
    /// it is not optional politeness: a style that stated a fixed dark ground and let the
    /// *labels* fall back to the system's would flip half the window when macOS switched
    /// appearance. A themed role never falls back to a dynamic system colour.
    func resolved(
        _ role: AppThemeRole,
        appearance: NSAppearance = NSAppearance.currentDrawing()
    ) -> NSColor {
        guard let variant = variant(for: appearance) else { return role.systemColor }
        if let stated = variant.roles[role] { return stated }
        guard let derived = derive(role, from: variant, kind: variantKind(for: appearance)) else {
            return role.systemColor
        }
        return derived
    }

    private func derive(
        _ role: AppThemeRole,
        from variant: Variant,
        kind: VariantKind
    ) -> NSColor? {
        let roles = variant.roles
        switch role {
        case .elevated:
            return roles[.panel]?.lightened(by: kind == .dark ? 0.06 : -0.04)
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
            return roles[.surface]?.lightened(by: kind == .dark ? 0.05 : -0.03)
        default:
            return nil
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, mode, summary, variants
        // Legacy single-variant document fields.
        case roles, material, terminalPalette
    }

    init(
        id: AppThemeID,
        name: String,
        mode: Mode,
        summary: String?,
        roles: [AppThemeRole: NSColor],
        terminalPalette: TerminalTheme = TerminalTheme.basic,
        material: Material = .system
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.summary = summary
        if id == .system && mode == .system && roles.isEmpty {
            variants = [:]
        } else {
            let kind = VariantKind(mode: mode)
            variants = [
                kind: Variant(
                    roles: roles,
                    terminalPalette: terminalPalette,
                    material: material
                )
            ]
        }
    }

    init(
        id: AppThemeID,
        name: String,
        mode: Mode,
        summary: String?,
        variants: [VariantKind: Variant]
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.summary = summary
        self.variants = variants
    }

    /// Roles are written as a hex map keyed by the role's own name, so a theme document is
    /// hand-writable and reviewable in a diff — the same reason `TerminalTheme` stores hex.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AppThemeID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(Mode.self, forKey: .mode)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)

        if let encoded = try container.decodeIfPresent(
            [String: Variant].self,
            forKey: .variants
        ) {
            variants = Dictionary(uniqueKeysWithValues: encoded.compactMap { raw, variant in
                VariantKind(rawValue: raw).map { ($0, variant) }
            })
            return
        }

        // Legacy documents stored one palette at the top level. Decode them into the equivalent
        // single variant, so existing custom themes need no eager migration or version flag.
        let hexes = try container.decodeIfPresent([String: String].self, forKey: .roles) ?? [:]
        var parsed: [AppThemeRole: NSColor] = [:]
        for (key, hex) in hexes {
            guard let role = AppThemeRole(rawValue: key), let color = NSColor(hex: hex) else { continue }
            parsed[role] = color
        }
        let legacyMaterial = try container.decodeIfPresent(Material.self, forKey: .material) ?? .system
        // A theme document written before palettes existed keeps the app's own default, which is
        // what a terminal following it drew with anyway.
        let legacyTerminal = try container.decodeIfPresent(TerminalTheme.self, forKey: .terminalPalette)
            ?? TerminalTheme.basic.renamed(name)
        if id == .system && mode == .system && parsed.isEmpty {
            variants = [:]
        } else {
            variants = [
                VariantKind(mode: mode): Variant(
                    roles: parsed,
                    terminalPalette: legacyTerminal,
                    material: legacyMaterial
                )
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(summary, forKey: .summary)

        try container.encode(
            Dictionary(uniqueKeysWithValues: variants.map { ($0.key.rawValue, $0.value) }),
            forKey: .variants
        )
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
