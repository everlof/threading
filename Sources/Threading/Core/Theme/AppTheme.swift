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
/// animations — and Threading's layout is its product rather than its decoration. A theme that
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

    /// The palette a terminal following this theme draws with right now.
    ///
    /// Anchored to the **application's** effective appearance, not to
    /// `NSAppearance.currentDrawing()`: a palette is consumed as data — fixed colours pushed
    /// into a terminal — from notification handlers and session setup, where the ambient
    /// drawing appearance is whatever AppKit last had in hand rather than what the window
    /// wears. Resolving there chose a dark terminal in a light app. A caller resolving for a
    /// specific appearance — a preview, the remote bridge — says so with `terminalPalette(for:)`.
    @MainActor
    var terminalPalette: TerminalTheme {
        terminalPalette(for: NSApplication.shared.effectiveAppearance)
    }

    func terminalPalette(for appearance: NSAppearance) -> TerminalTheme {
        if let variant = variant(for: appearance) { return variant.terminalPalette }
        // The identity theme pairs a palette per appearance the way its roles resolve per
        // appearance: black-on-white beside a light chrome, near-window dark beside a dark one.
        // Pure black next to either was the one surface in the window that followed nothing —
        // see `TerminalTheme.systemDark`.
        let palette: TerminalTheme =
            VariantKind.current(in: appearance) == .dark ? .systemDark : .systemLight
        return palette.renamed(name)
    }
    var material: Material { activeVariant?.material ?? .system }

    /// The material for a stated appearance, for callers consuming it as data rather than while
    /// drawing — `Design.Typography` resolves fonts through this anchored to the application's
    /// appearance, the same distinction `terminalPalette` draws above. The ambient `material`
    /// stays for radii and glow, which are read at draw time where the ambient appearance is
    /// the right question.
    func material(for appearance: NSAppearance) -> Material {
        variant(for: appearance)?.material ?? .system
    }

    /// The chrome block for the appearance the app currently wears — consumed as data by the
    /// coordinator and the band, so it anchors to the application's appearance the way
    /// `terminalPalette` does, not to whatever `NSAppearance.currentDrawing()` last held.
    @MainActor
    var windowChrome: WindowChromeStyle? {
        windowChrome(for: NSApplication.shared.effectiveAppearance)
    }

    func windowChrome(for appearance: NSAppearance) -> WindowChromeStyle? {
        variant(for: appearance)?.chrome
    }

    /// Whether this theme opts the main window out of its native frame. Asked of the theme,
    /// not of a variant: validation holds an adaptive theme to chrome-in-both-or-neither, so
    /// any variant answers for all of them.
    var takesOverWindowChrome: Bool {
        variants.values.contains { $0.chrome != nil }
    }

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

        /// The sidebar's dressing — background layers and the brand row. Optional and variant-
        /// owned like the material, because a gradient authored for a dark ground is wrong on a
        /// pale one. Absent means the sidebar as it always was.
        let sidebar: SidebarStyle?

        /// The window frame's dressing — and, by its presence, the opt-in to drawing the whole
        /// frame. Variant-owned like the sidebar, but validation additionally requires an
        /// adaptive theme to state it in both variants or neither: band colours may differ by
        /// appearance, whether the window wears its own frame may not.
        let chrome: WindowChromeStyle?

        private enum CodingKeys: String, CodingKey {
            case roles, terminalPalette
            case material, sidebar, chrome
        }

        init(
            roles: [AppThemeRole: NSColor],
            terminalPalette: TerminalTheme,
            material: Material,
            sidebar: SidebarStyle? = nil,
            chrome: WindowChromeStyle? = nil
        ) {
            self.roles = roles
            self.terminalPalette = terminalPalette
            self.material = material
            self.sidebar = sidebar
            self.chrome = chrome
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
            sidebar = try container.decodeIfPresent(SidebarStyle.self, forKey: .sidebar)
            chrome = try container.decodeIfPresent(WindowChromeStyle.self, forKey: .chrome)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                Dictionary(uniqueKeysWithValues: roles.map { ($0.key.rawValue, $0.value.hexString) }),
                forKey: .roles
            )
            try container.encode(material, forKey: .material)
            try container.encode(terminalPalette, forKey: .terminalPalette)
            try container.encodeIfPresent(sidebar, forKey: .sidebar)
            try container.encodeIfPresent(chrome, forKey: .chrome)
        }
    }

    /// Radii, border weight, an optional panel shadow — and the typeface the chrome is set in.
    struct Material: Codable, Equatable {
        /// Containers holding content — cards, the prompt box.
        var panelRadius: CGFloat = 12
        /// Smaller things nested inside them — chips, swatches.
        var controlRadius: CGFloat = 8
        var borderWidth: CGFloat = 1

        /// A theme-level multiplier for semantic app text. One preserves every historical
        /// theme; a deliberately dense visual language can compact the same roles without
        /// components inventing smaller point sizes. This composes with the user's text-size
        /// preference, which remains the final authority.
        var textScale: CGFloat = 1

        /// A shadow behind opted-in panels, in one of the theme's own colours. A zero offset
        /// reads as a glow; a non-zero, zero-radius shadow gives Bauhaus and Neo Brutalism
        /// their hard printed lift without teaching feature views about either style.
        var glow: Glow?

        /// Which of the platform's typeface designs the chrome is set in.
        ///
        /// The other half of a style brief: the styles these themes are drawn from state a
        /// typeface class as plainly as they state a palette — Newsprint is a serif style,
        /// Cyberpunk a mono one — and a theme that recolours SF Sans is typographically still
        /// System. The values are macOS's own font designs, so nothing is bundled and every
        /// weight exists; `Design.Typography` is the one interpreter. Code and the terminal
        /// deliberately do not follow it.
        var typeface: Typeface = .standard

        /// A raised-and-sunken edge treatment on every applied surface — the vocabulary that
        /// makes a mid-nineties chrome expressible as data instead of as components.
        ///
        /// Nil — every theme written before the field existed — draws exactly what
        /// `applySurface` always drew. Stated, every surface whose resolved corner is square
        /// wears a two-tone edge in the `bevelHighlight`/`bevelShadow` roles: raised by
        /// default, sunken where a component says so (`SurfaceBevel.sunken` — text wells),
        /// never on a shape with a rounded corner, whose offset curve a rectilinear bevel
        /// cannot draw. Validation therefore requires a bevel material to author square radii.
        var bevel: Bevel?

        /// A named font family, for a theme whose identity is a *particular* face rather than a
        /// typeface class.
        ///
        /// The four designs cover the classes, which is what a style brief states — but a theme
        /// is free to be more specific than its brief, and "Newsprint, set in Baskerville" is not
        /// expressible as one of four. So a family may be named, and it wins over `typeface`
        /// where it resolves.
        ///
        /// **A name that resolves to nothing is not an error.** Families live on the machine, not
        /// in the document, so a theme authored elsewhere — or one whose font the user later
        /// removed — names something absent. That degrades to `typeface`, which is the same rule
        /// terminal-theme assignments already follow for a deleted theme: an unknown name is
        /// indistinguishable from never having chosen, and the next scope out answers.
        ///
        /// Nothing bundled still holds. This names a family the machine already has.
        var fontFamily: String?

        /// Which edge owns a managed scroll view's vertical scroller. AppKit's native answer
        /// remains the trailing edge; period systems such as OPENSTEP can state the leading
        /// edge without any feature view moving its own content.
        var scrollerPlacement: ScrollerPlacement = .trailing

        /// The material behind the scroll thumb. Most themes use a solid surface; a stippled
        /// track is the one-bit texture used by workstation-era interfaces.
        var scrollerTrackStyle: ScrollerTrackStyle = .solid

        enum Typeface: String, Codable, CaseIterable {
            /// SF Sans — the platform default, and the System theme's answer.
            case standard = "default"
            /// New York.
            case serif
            /// SF Rounded.
            case rounded
            /// SF Mono.
            case monospaced

            var systemDesign: NSFontDescriptor.SystemDesign {
                switch self {
                case .standard: return .default
                case .serif: return .serif
                case .rounded: return .rounded
                case .monospaced: return .monospaced
                }
            }
        }

        enum ScrollerPlacement: String, Codable, CaseIterable {
            case trailing
            case leading
        }

        enum ScrollerTrackStyle: String, Codable, CaseIterable {
            case solid
            case stippled
        }

        static let system = Material()

        /// The heaviest a *rule* may read, in points of fully-opaque ink.
        ///
        /// A rule and the text beside it are weighed by the same eye, and the anchor is the
        /// text: the body face's stem is ~1.25pt (SF 13 regular, measured by rasterising),
        /// so a rule carrying more ink than that stops reading as a rule between things and
        /// starts reading as a bar across them. Perceived weight is thickness × ink strength,
        /// which is why this is a budget rather than a width: a 1pt rule may be fully inked
        /// (Swiss Minimalist's brief is exactly that), while a 3pt rule must hold back to
        /// ~0.43 — which is, to the point, what Industrial already authored by hand.
        static let ruleInkBudget: CGFloat = 1.3

        /// The strongest ink a rule of this material's weight may carry.
        ///
        /// Derived rather than authored, so a theme — stock, custom, or contributed — states
        /// only `borderWidth` and can never state its way past the budget. The floor of 1 in
        /// the divisor mirrors `ThemedSplitView.minimumGrab`: a sub-point rule is drawn at a
        /// point, so it is judged at a point.
        var ruleInkCeiling: CGFloat {
            min(1, Self.ruleInkBudget / max(1, borderWidth))
        }

        init(
            panelRadius: CGFloat = 12,
            controlRadius: CGFloat = 8,
            borderWidth: CGFloat = 1,
            textScale: CGFloat = 1,
            glow: Glow? = nil,
            bevel: Bevel? = nil,
            typeface: Typeface = .standard,
            fontFamily: String? = nil,
            scrollerPlacement: ScrollerPlacement = .trailing,
            scrollerTrackStyle: ScrollerTrackStyle = .solid
        ) {
            self.panelRadius = panelRadius
            self.controlRadius = controlRadius
            self.borderWidth = borderWidth
            self.textScale = textScale
            self.glow = glow
            self.bevel = bevel
            self.typeface = typeface
            self.fontFamily = fontFamily
            self.scrollerPlacement = scrollerPlacement
            self.scrollerTrackStyle = scrollerTrackStyle
        }

        private enum CodingKeys: String, CodingKey {
            case panelRadius, controlRadius, borderWidth, textScale
            case glow, bevel, typeface, fontFamily
            case scrollerPlacement, scrollerTrackStyle
        }

        /// Every field is optional on the wire: a document written before a field existed
        /// decodes to the value the app used then. The synthesized decoder threw on the
        /// missing key instead, and the throw was swallowed upstream by a `?? .system`
        /// fallback — which would have silently discarded the user's whole authored material.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            panelRadius = try container.decodeIfPresent(CGFloat.self, forKey: .panelRadius) ?? 12
            controlRadius = try container.decodeIfPresent(CGFloat.self, forKey: .controlRadius) ?? 8
            borderWidth = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? 1
            textScale = try container.decodeIfPresent(CGFloat.self, forKey: .textScale) ?? 1
            glow = try container.decodeIfPresent(Glow.self, forKey: .glow)
            bevel = try container.decodeIfPresent(Bevel.self, forKey: .bevel)
            typeface = try container.decodeIfPresent(Typeface.self, forKey: .typeface) ?? .standard
            fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
            scrollerPlacement = try container.decodeIfPresent(
                ScrollerPlacement.self,
                forKey: .scrollerPlacement
            ) ?? .trailing
            scrollerTrackStyle = try container.decodeIfPresent(
                ScrollerTrackStyle.self,
                forKey: .scrollerTrackStyle
            ) ?? .solid
        }
    }

    /// The measure of a bevel material's edge. A struct rather than a bare width so the
    /// vocabulary can grow — a two-line outer/inner treatment, a corner style — without a
    /// second wire format.
    struct Bevel: Codable, Equatable {
        /// Points per edge, bounded by validation to 1...3: one point is a whisper, two is
        /// the classic, and past three the edges stop framing a surface and start being one.
        var width: CGFloat = 2

        init(width: CGFloat = 2) {
            self.width = width
        }

        private enum CodingKeys: String, CodingKey {
            case width
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeIfPresent(CGFloat.self, forKey: .width) ?? 2
        }
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
        // No terminal palette stated here: System stores no variants, so its palette is answered
        // adaptively by `terminalPalette` — `TerminalTheme.systemLight`/`.systemDark` per the
        // current appearance, the way every role resolves.
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
        case .bevelHighlight:
            return roles[.surface]?.lightened(by: 0.45)
        case .bevelShadow:
            return roles[.surface]?.lightened(by: -0.45)
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

    /// The colour actually seen where a — usually translucent — overlay is drawn on this base,
    /// alpha-composited in sRGB.
    ///
    /// This is what lets a translucent line be *measured* against its ground: contrast asked of
    /// the overlay's stored value answers for the colour nobody sees.
    func composited(under overlay: NSColor) -> NSColor {
        guard let base = usingColorSpace(.sRGB),
              let top = overlay.usingColorSpace(.sRGB) else { return overlay }
        let alpha = top.alphaComponent

        return NSColor(
            srgbRed: top.redComponent * alpha + base.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + base.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + base.blueComponent * (1 - alpha),
            alpha: base.alphaComponent
        )
    }

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
