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

        // MARK: - Rebuilding

        /// A copy with only the stated pieces replaced.
        ///
        /// This is the one way an edit rebuilds a variant from an existing one. Constructing
        /// a fresh `Variant(...)` at an edit site is how the Current Theme page silently
        /// stripped the chrome block from every custom takeover theme it touched: the
        /// memberwise initializer defaults each regional block to nil, so a call written
        /// before a block existed keeps compiling and drops it. A copy carries every stored
        /// field by construction, so a future regional block rides through edit sites that
        /// have never heard of it — `WindowChromeStyleTests` sweeps the stock catalogue to
        /// hold `replacing()` to the identity.
        func replacing(
            roles: [AppThemeRole: NSColor]? = nil,
            terminalPalette: TerminalTheme? = nil,
            material: Material? = nil
        ) -> Variant {
            Variant(
                roles: roles ?? self.roles,
                terminalPalette: terminalPalette ?? self.terminalPalette,
                material: material ?? self.material,
                sidebar: sidebar,
                chrome: chrome
            )
        }

        /// The regional blocks get their own verbs because "set it to nil" must be sayable —
        /// an optional parameter on `replacing` could not tell "leave it alone" from "take it
        /// away", which is the exact distinction `AppThemeEditing.SidebarChange` exists for.
        func replacingSidebar(_ sidebar: SidebarStyle?) -> Variant {
            Variant(
                roles: roles,
                terminalPalette: terminalPalette,
                material: material,
                sidebar: sidebar,
                chrome: chrome
            )
        }

        func replacingChrome(_ chrome: WindowChromeStyle?) -> Variant {
            Variant(
                roles: roles,
                terminalPalette: terminalPalette,
                material: material,
                sidebar: sidebar,
                chrome: chrome
            )
        }
    }

    /// Radii, border weight, an optional panel shadow — and the typeface the chrome is set in.
    struct Material: Codable, Equatable {
        /// Containers holding content — cards, the prompt box.
        var panelRadius: CGFloat = 12
        /// Smaller things nested inside them — chips, swatches.
        var controlRadius: CGFloat = 8
        /// Structural rules and the borders around content-bearing surfaces.
        var borderWidth: CGFloat = 1

        /// The border around compact controls. Nil inherits `borderWidth`.
        ///
        /// Some source languages deliberately use two weights: Bauhaus rules cards in four
        /// pixels of ink but frames buttons in two. Keeping this optional preserves every
        /// existing theme document while making that measured distinction authorable.
        var controlBorderWidth: CGFloat?

        /// A restrained repeating treatment on the app's broad backdrop surfaces.
        ///
        /// The source styles use the page itself as material: Bauhaus has a dot field,
        /// Swiss and Cyberpunk expose their grid, and Art Deco lays a near-invisible diamond
        /// lattice into the lacquer. This is deliberately *not* an arbitrary image and it is
        /// never applied to cards or controls. A component opts in only when it is the broad
        /// ground behind the product UI, so custom themes can author that language without
        /// turning every nested surface into wallpaper.
        var backdropPattern: BackdropPattern?

        /// A theme-level multiplier for semantic app text. One preserves every historical
        /// theme; a deliberately dense visual language can compact the same roles without
        /// components inventing smaller point sizes. This composes with the user's text-size
        /// preference, which remains the final authority.
        var textScale: CGFloat = 1

        /// The closed height of a compact value chooser.
        ///
        /// Period controls do not merely use smaller type inside a modern box: Platinum's
        /// pop-up is a sixteen-point strip, BeOS uses an eighteen-point menu field, and Win32's
        /// combo box is taller again. Keeping the measure beside the chooser anatomy makes that
        /// distinction authorable without shrinking unrelated buttons, fields, or hit targets.
        var choiceHeight: CGFloat = 26

        /// A shadow behind opted-in panels, in one of the theme's own colours. A zero offset
        /// reads as a glow; a non-zero, zero-radius shadow gives Bauhaus and Neo Brutalism
        /// their hard printed lift without teaching feature views about either style. A glow
        /// may pair that shade with an opposing highlight shadow — the two-light construction
        /// used by clay and neumorphic materials.
        var glow: Glow?

        /// The complete visual grammar for app-owned anchored popovers.
        ///
        /// This is data rather than a theme-name branch in `ThemedPopover`: period chromes can
        /// remove the modern stem and ambient shadow, hard/soft materials can opt into their
        /// authored edge and depth, and contributed/custom themes use the same vocabulary.
        var popoverStyle: PopoverStyle = .system

        /// The same paired-shadow vocabulary at control scale. Kept separate from `glow`
        /// because the source materials do: a white card casts broad neutral depth, while a
        /// button casts a tighter accent-coloured shadow. Nil preserves the flat controls of
        /// every document written before this capability existed.
        var controlGlow: Glow?

        /// The visual and interactive grammar of an action button.
        ///
        /// Palette and radius alone cannot express the controls in the source styles: Art Deco
        /// and Vaporwave use outlined primary actions, Newsprint uses black rather than its red
        /// accent, and Neo Brutalism moves the face into its hard shadow on hover and press.
        /// Keeping those decisions together makes that grammar authorable by custom themes
        /// without teaching `ThemedButton` the name of any stock style.
        var buttonStyle: ButtonStyle = .system

        /// A display-face override for semantic headings.
        ///
        /// Most reference styles do not set all prose in one face: Botanical pairs a serif
        /// display face with sans body copy, while Art Deco keeps its headings substantially
        /// lighter than its controls. `typeface`/`fontFamily` remain the prose default; this
        /// optional recipe changes headings only and inherits every field it does not state.
        var headingStyle: HeadingStyle?

        /// Which of the platform's typeface designs the chrome is set in.
        ///
        /// The other half of a style brief: the styles these themes are drawn from state a
        /// typeface class as plainly as they state a palette — Newsprint is a serif style,
        /// Cyberpunk a mono one — and a theme that recolours SF Sans is typographically still
        /// System. The values are macOS's own font designs, so nothing is bundled and every
        /// weight exists; `Design.Typography` is the one interpreter. Code and the terminal
        /// deliberately do not follow it.
        var typeface: Typeface = .standard

        /// A raised-and-sunken edge treatment on every applied surface. A hard bevel is the
        /// vocabulary that makes mid-nineties chrome expressible as data; a soft bevel gives
        /// rounded materials the broad inset light and shade used by clay and neumorphic UI.
        ///
        /// Nil — every theme written before the field existed — draws exactly what
        /// `applySurface` always drew. Stated, a surface wears a two-tone edge in the
        /// `bevelHighlight`/`bevelShadow` roles: raised by default and sunken where a component
        /// says so (`SurfaceBevel.sunken` — text wells). Hard bevels require square corners;
        /// soft bevels follow the rounded silhouette instead.
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

        /// Ordered substitutes for `fontFamily`, used only when the preferred historical face is
        /// not installed.
        ///
        /// Retro interfaces named fonts that are no longer distributed with macOS — Charcoal,
        /// Swis721 BT, and Topaz among them. Replacing the preferred family with a modern face
        /// would make a later user-installed copy impossible to discover; falling straight to a
        /// broad `typeface` loses the nearest period-safe substitute. This ordered chain keeps
        /// both promises. Nothing is bundled or downloaded, and the first family CoreText can
        /// actually resolve wins.
        var fontFallbacks: [String] = []

        /// The named-family resolution order, with empty and duplicate entries removed without
        /// changing authors' preference order.
        var fontFamilies: [String] {
            var seen = Set<String>()
            return ([fontFamily].compactMap { $0 } + fontFallbacks).compactMap { family in
                let clean = family.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { return nil }
                return clean
            }
        }

        /// Which edge owns a managed scroll view's vertical scroller. AppKit's native answer
        /// remains the trailing edge; period systems such as OPENSTEP can state the leading
        /// edge without any feature view moving its own content.
        var scrollerPlacement: ScrollerPlacement = .trailing

        /// The material behind the scroll thumb. Most themes use a solid surface; a stippled
        /// track is the one-bit texture used by workstation-era interfaces.
        var scrollerTrackStyle: ScrollerTrackStyle = .solid

        /// The period-specific anatomy of a scrollbar: arrow placement, thumb construction,
        /// track relief, and (for Aqua) translucent gel. `automatic` keeps the app's modern
        /// proportional thumb and the user's overlay/legacy preference. Every other value is
        /// an explicitly authored desktop-era control and therefore occupies persistent
        /// legacy scrollbar space.
        var scrollerAppearance: ScrollerAppearance = .automatic

        /// The complete anatomy of app-owned menus. A menu is not merely the open half of a
        /// chooser: its frame, hard or ambient shadow, row rhythm, separators, selection, and
        /// submenu marks varied independently across the desktop systems the takeover themes
        /// reproduce. Keeping that family explicit lets stock, custom, and contributed themes
        /// select the same production implementation without a theme-name branch.
        var menuAppearance: MenuAppearance = .automatic

        /// How determinate progress is painted. Continuous is the cross-theme default;
        /// segmented is the classic Win32 block control, whose smooth form was opt-in.
        var progressStyle: ProgressStyle = .continuous

        /// The silhouette and internal anatomy of compact value choosers. A chip is the app's
        /// quiet modern default; a dropdown is the square, sunken value well with an independent
        /// raised arrow button used by desktop-era systems.
        var choiceStyle: ChoiceStyle = .chip

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

        enum ScrollerAppearance: String, Codable, CaseIterable {
            case automatic
            case windows98 = "windows_98"
            case platinum
            case beOS = "beos"
            case openStep = "openstep"
            case irix
            case amiga
            case aqua
            /// Mac OS X 10.4 Tiger's slimmer Aqua control: the blue gel belongs to the
            /// thumb while the two neutral arrow buttons sit together at the scrolling end.
            case aquaTiger = "aqua_tiger"

            var usesLegacyPresentation: Bool { self != .automatic }

            /// Classic Macintosh, OPENSTEP, and Amiga put both arrows together at the
            /// scrolling end. The others bookend the track.
            var groupsArrowsAtTrailingEnd: Bool {
                switch self {
                case .platinum, .openStep, .amiga, .aquaTiger: true
                default: false
                }
            }
        }

        enum MenuAppearance: String, Codable, CaseIterable {
            /// The modern rounded app menu grammar.
            case automatic
            case windows98 = "windows_98"
            case platinum
            case beOS = "beos"
            case openStep = "openstep"
            case irix
            case amiga
            case aqua
            case aquaTiger = "aqua_tiger"

            var isHistorical: Bool { self != .automatic }
        }

        enum ProgressStyle: String, Codable, CaseIterable {
            case continuous
            case segmented
        }

        enum ChoiceStyle: String, Codable, CaseIterable {
            case chip
            /// A sunken value well with a separately raised down-arrow button (Win32 combo box).
            case dropdown
            /// One raised face with a down-arrow segment (BeOS/workstation pop-up).
            case popup
            /// The Platinum pop-up: one raised face and paired up/down triangles.
            case doubleArrowPopup = "double_arrow_popup"
            /// Tiger Aqua's rounded silver value well with a blue gel up/down segment.
            case aquaPopup = "aqua_popup"
            /// An Amiga cycle gadget: one raised face with a cycling double-arrow mark.
            case cycle

            var isClassic: Bool { self != .chip }
        }

        struct BackdropPattern: Codable, Equatable {
            enum Kind: String, Codable, CaseIterable {
                case dots
                case grid
                case diagonalGrid = "diagonal_grid"
                case perspectiveGrid = "perspective_grid"
            }

            var kind: Kind
            /// The semantic ink used for the marks, resolved per appearance.
            var role: AppThemeRole
            /// Opacity of the pattern layer after the role's own alpha is resolved.
            var opacity: Double
            /// Distance between repeated marks, in points.
            var spacing: CGFloat
            /// Grid stroke width or dot diameter, in points.
            var lineWidth: CGFloat

            init(
                kind: Kind,
                role: AppThemeRole = .border,
                opacity: Double = 0.08,
                spacing: CGFloat = 20,
                lineWidth: CGFloat = 1
            ) {
                self.kind = kind
                self.role = role
                self.opacity = opacity
                self.spacing = spacing
                self.lineWidth = lineWidth
            }

            private enum CodingKeys: String, CodingKey {
                case kind, role, opacity, spacing, lineWidth
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .dots
                role = try container.decodeIfPresent(AppThemeRole.self, forKey: .role) ?? .border
                opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.08
                spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 20
                lineWidth = try container.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 1
            }
        }

        struct PopoverStyle: Codable, Equatable {
            enum Arrow: String, Codable, CaseIterable {
                case triangle
                case none
            }

            enum Edge: String, Codable, CaseIterable {
                /// A structural border in the theme's border role.
                case flat
                /// The material bevel when one exists, otherwise the structural border.
                case material
                case none
            }

            enum Shadow: String, Codable, CaseIterable {
                /// Use the authored panel shadow when present, otherwise the native window shadow.
                case automatic
                case system
                case material
                case none
            }

            enum Density: String, Codable, CaseIterable {
                case regular
                case compact
            }

            enum GlyphStyle: String, Codable, CaseIterable {
                case system
                case classic
            }

            var arrow: Arrow = .triangle
            var surfaceRole: AppThemeRole = .floatingSurface
            var edge: Edge = .flat
            var shadow: Shadow = .automatic
            var density: Density = .regular
            var glyphStyle: GlyphStyle = .system

            static let system = PopoverStyle()

            init(
                arrow: Arrow = .triangle,
                surfaceRole: AppThemeRole = .floatingSurface,
                edge: Edge = .flat,
                shadow: Shadow = .automatic,
                density: Density = .regular,
                glyphStyle: GlyphStyle = .system
            ) {
                self.arrow = arrow
                self.surfaceRole = surfaceRole
                self.edge = edge
                self.shadow = shadow
                self.density = density
                self.glyphStyle = glyphStyle
            }

            private enum CodingKeys: String, CodingKey {
                case arrow, surfaceRole, edge, shadow, density, glyphStyle
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                arrow = try container.decodeIfPresent(Arrow.self, forKey: .arrow) ?? .triangle
                surfaceRole = try container.decodeIfPresent(
                    AppThemeRole.self, forKey: .surfaceRole
                ) ?? .floatingSurface
                edge = try container.decodeIfPresent(Edge.self, forKey: .edge) ?? .flat
                shadow = try container.decodeIfPresent(Shadow.self, forKey: .shadow) ?? .automatic
                density = try container.decodeIfPresent(Density.self, forKey: .density) ?? .regular
                glyphStyle = try container.decodeIfPresent(
                    GlyphStyle.self, forKey: .glyphStyle
                ) ?? .system
            }
        }

        struct ButtonStyle: Codable, Equatable {
            enum TextTransform: String, Codable, CaseIterable {
                case none
                case uppercase
            }

            enum FontWeight: String, Codable, CaseIterable {
                case regular
                case medium
                case semibold
                case bold

                var appKitWeight: NSFont.Weight {
                    switch self {
                    case .regular: return .regular
                    case .medium: return .medium
                    case .semibold: return .semibold
                    case .bold: return .bold
                    }
                }
            }

            enum PrimaryTreatment: String, Codable, CaseIterable {
                case filled
                case outlined
                /// Keep the primary on the ordinary control face and distinguish it with the
                /// extra outer frame used by classic desktop default pushbuttons.
                case raised
            }

            /// Selects which authored material shadow an ordinary bordered action casts.
            /// Primary actions always use `material.controlGlow`; a reference can give its
            /// secondary actions the broader neutral panel relief or keep them flat.
            enum SecondaryShadow: String, Codable, CaseIterable {
                case control
                case panel
                case none
            }

            var textTransform: TextTransform = .none
            var fontWeight: FontWeight = .medium
            /// Nil inherits the material's prose face. A button may name its own face because
            /// display-led references commonly pair action labels with headings rather than
            /// with their reading copy.
            var typeface: Typeface?
            var fontFamily: String?
            /// Additional points between title glyphs. This is a compact-control value, not an
            /// em unit: it follows the app's semantic text scale without compounding it.
            var tracking: CGFloat = 0
            /// Multiplier over the semantic control size. Period web implementations state
            /// device-pixel text at 96 dpi; this preserves that ratio without replacing the
            /// app-wide type scale with a theme-name branch.
            var fontScale: CGFloat = 1
            /// Optional native pushbutton floors. Nil preserves the app's ordinary semantic
            /// size; a historical implementation may state its period control metrics.
            var minimumWidth: CGFloat?
            var minimumHeight: CGFloat?
            /// Classic disabled pushbuttons engrave shadow-coloured ink with a one-pixel lit
            /// echo instead of lowering the whole label's opacity.
            var embossesDisabledTitle: Bool = false
            /// Whether Core Graphics may soften the title's glyph edges. Bitmap-era systems
            /// such as Win32 and Workbench drew their small UI strikes on the device grid;
            /// turning this off preserves that construction without making modern themes jagged.
            var antialiasesTitle: Bool = true
            var primaryTreatment: PrimaryTreatment = .filled
            /// The semantic colour supplying a primary button's fill, border, and title.
            var primaryRole: AppThemeRole = .accent
            /// The face of an ordinary bordered action. Kept on the button style rather than
            /// the material's global control role because a reference may put raised white
            /// buttons beside recessed lavender fields without making either one lie.
            var secondaryRole: AppThemeRole = .controlResting
            /// Optional independent hover face. Defaults to the ordinary control-hover role;
            /// clay keeps its white body and reports hover through lift and shadow instead.
            var secondaryHoverRole: AppThemeRole = .controlHover
            /// The shadow vocabulary for an ordinary bordered action. Existing documents keep
            /// the historical compact-control shadow unless they state another source.
            var secondaryShadow: SecondaryShadow = .control
            /// An optional independent rule around a filled primary. Outlined primaries always
            /// use `primaryRole` for their rule.
            var primaryBorderRole: AppThemeRole?
            /// Visual travel in screen coordinates: positive Y moves down, matching CSS and the
            /// reference vocabulary even though AppKit's drawing coordinate is normally up.
            var hoverOffsetX: CGFloat = 0
            var hoverOffsetY: CGFloat = 0
            var pressedOffsetX: CGFloat = 0
            var pressedOffsetY: CGFloat = 0
            /// Hard-print controls collapse their offset shadow as the face moves into it.
            var collapseShadowOnHover: Bool = false

            static let system = ButtonStyle()

            init(
                textTransform: TextTransform = .none,
                fontWeight: FontWeight = .medium,
                typeface: Typeface? = nil,
                fontFamily: String? = nil,
                tracking: CGFloat = 0,
                fontScale: CGFloat = 1,
                minimumWidth: CGFloat? = nil,
                minimumHeight: CGFloat? = nil,
                embossesDisabledTitle: Bool = false,
                antialiasesTitle: Bool = true,
                primaryTreatment: PrimaryTreatment = .filled,
                primaryRole: AppThemeRole = .accent,
                secondaryRole: AppThemeRole = .controlResting,
                secondaryHoverRole: AppThemeRole = .controlHover,
                secondaryShadow: SecondaryShadow = .control,
                primaryBorderRole: AppThemeRole? = nil,
                hoverOffsetX: CGFloat = 0,
                hoverOffsetY: CGFloat = 0,
                pressedOffsetX: CGFloat = 0,
                pressedOffsetY: CGFloat = 0,
                collapseShadowOnHover: Bool = false
            ) {
                self.textTransform = textTransform
                self.fontWeight = fontWeight
                self.typeface = typeface
                self.fontFamily = fontFamily
                self.tracking = tracking
                self.fontScale = fontScale
                self.minimumWidth = minimumWidth
                self.minimumHeight = minimumHeight
                self.embossesDisabledTitle = embossesDisabledTitle
                self.antialiasesTitle = antialiasesTitle
                self.primaryTreatment = primaryTreatment
                self.primaryRole = primaryRole
                self.secondaryRole = secondaryRole
                self.secondaryHoverRole = secondaryHoverRole
                self.secondaryShadow = secondaryShadow
                self.primaryBorderRole = primaryBorderRole
                self.hoverOffsetX = hoverOffsetX
                self.hoverOffsetY = hoverOffsetY
                self.pressedOffsetX = pressedOffsetX
                self.pressedOffsetY = pressedOffsetY
                self.collapseShadowOnHover = collapseShadowOnHover
            }

            private enum CodingKeys: String, CodingKey {
                case textTransform, fontWeight, typeface, fontFamily, tracking
                case fontScale, minimumWidth, minimumHeight, embossesDisabledTitle
                case antialiasesTitle
                case primaryTreatment, primaryRole, secondaryRole, secondaryHoverRole
                case secondaryShadow
                case primaryBorderRole, hoverOffsetX, hoverOffsetY, pressedOffsetX
                case pressedOffsetY, collapseShadowOnHover
            }

            /// A partially written style is still a valid style. This matters for hand-authored
            /// theme documents just as much as the material's outer backwards-compatible decode.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                textTransform = try container.decodeIfPresent(
                    TextTransform.self, forKey: .textTransform
                ) ?? .none
                fontWeight = try container.decodeIfPresent(
                    FontWeight.self, forKey: .fontWeight
                ) ?? .medium
                typeface = try container.decodeIfPresent(Typeface.self, forKey: .typeface)
                fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
                tracking = try container.decodeIfPresent(CGFloat.self, forKey: .tracking) ?? 0
                fontScale = try container.decodeIfPresent(CGFloat.self, forKey: .fontScale) ?? 1
                minimumWidth = try container.decodeIfPresent(CGFloat.self, forKey: .minimumWidth)
                minimumHeight = try container.decodeIfPresent(CGFloat.self, forKey: .minimumHeight)
                embossesDisabledTitle = try container.decodeIfPresent(
                    Bool.self, forKey: .embossesDisabledTitle
                ) ?? false
                antialiasesTitle = try container.decodeIfPresent(
                    Bool.self, forKey: .antialiasesTitle
                ) ?? true
                primaryTreatment = try container.decodeIfPresent(
                    PrimaryTreatment.self, forKey: .primaryTreatment
                ) ?? .filled
                primaryRole = try container.decodeIfPresent(
                    AppThemeRole.self, forKey: .primaryRole
                ) ?? .accent
                secondaryRole = try container.decodeIfPresent(
                    AppThemeRole.self, forKey: .secondaryRole
                ) ?? .controlResting
                secondaryHoverRole = try container.decodeIfPresent(
                    AppThemeRole.self, forKey: .secondaryHoverRole
                ) ?? .controlHover
                secondaryShadow = try container.decodeIfPresent(
                    SecondaryShadow.self, forKey: .secondaryShadow
                ) ?? .control
                primaryBorderRole = try container.decodeIfPresent(
                    AppThemeRole.self, forKey: .primaryBorderRole
                )
                hoverOffsetX = try container.decodeIfPresent(CGFloat.self, forKey: .hoverOffsetX) ?? 0
                hoverOffsetY = try container.decodeIfPresent(CGFloat.self, forKey: .hoverOffsetY) ?? 0
                pressedOffsetX = try container.decodeIfPresent(
                    CGFloat.self, forKey: .pressedOffsetX
                ) ?? 0
                pressedOffsetY = try container.decodeIfPresent(
                    CGFloat.self, forKey: .pressedOffsetY
                ) ?? 0
                collapseShadowOnHover = try container.decodeIfPresent(
                    Bool.self, forKey: .collapseShadowOnHover
                ) ?? false
            }
        }

        struct HeadingStyle: Codable, Equatable {
            /// Nil inherits the material's prose typeface class.
            var typeface: Typeface?
            /// Nil inherits the material's prose family. An unavailable named family falls
            /// through to `typeface`, then to the material's prose answer.
            var fontFamily: String?
            /// Nil keeps the semantic role's ordinary weight.
            var fontWeight: ButtonStyle.FontWeight?
            /// Display italics are explicit; old and sparse documents remain upright.
            var italic: Bool = false

            init(
                typeface: Typeface? = nil,
                fontFamily: String? = nil,
                fontWeight: ButtonStyle.FontWeight? = nil,
                italic: Bool = false
            ) {
                self.typeface = typeface
                self.fontFamily = fontFamily
                self.fontWeight = fontWeight
                self.italic = italic
            }

            private enum CodingKeys: String, CodingKey {
                case typeface, fontFamily, fontWeight, italic
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                typeface = try container.decodeIfPresent(Typeface.self, forKey: .typeface)
                fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
                fontWeight = try container.decodeIfPresent(
                    ButtonStyle.FontWeight.self,
                    forKey: .fontWeight
                )
                italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            }
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

        /// The compact-control border after applying the backwards-compatible inheritance rule.
        var resolvedControlBorderWidth: CGFloat { controlBorderWidth ?? borderWidth }

        init(
            panelRadius: CGFloat = 12,
            controlRadius: CGFloat = 8,
            borderWidth: CGFloat = 1,
            controlBorderWidth: CGFloat? = nil,
            backdropPattern: BackdropPattern? = nil,
            textScale: CGFloat = 1,
            choiceHeight: CGFloat = 26,
            glow: Glow? = nil,
            popoverStyle: PopoverStyle = .system,
            controlGlow: Glow? = nil,
            buttonStyle: ButtonStyle = .system,
            headingStyle: HeadingStyle? = nil,
            bevel: Bevel? = nil,
            typeface: Typeface = .standard,
            fontFamily: String? = nil,
            fontFallbacks: [String] = [],
            scrollerPlacement: ScrollerPlacement = .trailing,
            scrollerTrackStyle: ScrollerTrackStyle = .solid,
            scrollerAppearance: ScrollerAppearance = .automatic,
            menuAppearance: MenuAppearance = .automatic,
            progressStyle: ProgressStyle = .continuous,
            choiceStyle: ChoiceStyle = .chip
        ) {
            self.panelRadius = panelRadius
            self.controlRadius = controlRadius
            self.borderWidth = borderWidth
            self.controlBorderWidth = controlBorderWidth
            self.backdropPattern = backdropPattern
            self.textScale = textScale
            self.choiceHeight = choiceHeight
            self.glow = glow
            self.popoverStyle = popoverStyle
            self.controlGlow = controlGlow
            self.buttonStyle = buttonStyle
            self.headingStyle = headingStyle
            self.bevel = bevel
            self.typeface = typeface
            self.fontFamily = fontFamily
            self.fontFallbacks = fontFallbacks
            self.scrollerPlacement = scrollerPlacement
            self.scrollerTrackStyle = scrollerTrackStyle
            self.scrollerAppearance = scrollerAppearance
            self.menuAppearance = menuAppearance
            self.progressStyle = progressStyle
            self.choiceStyle = choiceStyle
        }

        private enum CodingKeys: String, CodingKey {
            case panelRadius, controlRadius, borderWidth, controlBorderWidth, backdropPattern
            case textScale, choiceHeight
            case glow, popoverStyle, controlGlow, buttonStyle, headingStyle, bevel, typeface, fontFamily
            case fontFallbacks
            case scrollerPlacement, scrollerTrackStyle, scrollerAppearance, menuAppearance
            case progressStyle, choiceStyle
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
            controlBorderWidth = try container.decodeIfPresent(
                CGFloat.self, forKey: .controlBorderWidth
            )
            backdropPattern = try container.decodeIfPresent(
                BackdropPattern.self, forKey: .backdropPattern
            )
            textScale = try container.decodeIfPresent(CGFloat.self, forKey: .textScale) ?? 1
            choiceHeight = try container.decodeIfPresent(CGFloat.self, forKey: .choiceHeight) ?? 26
            glow = try container.decodeIfPresent(Glow.self, forKey: .glow)
            popoverStyle = try container.decodeIfPresent(
                PopoverStyle.self, forKey: .popoverStyle
            ) ?? .system
            controlGlow = try container.decodeIfPresent(Glow.self, forKey: .controlGlow)
            buttonStyle = try container.decodeIfPresent(
                ButtonStyle.self, forKey: .buttonStyle
            ) ?? .system
            headingStyle = try container.decodeIfPresent(
                HeadingStyle.self, forKey: .headingStyle
            )
            bevel = try container.decodeIfPresent(Bevel.self, forKey: .bevel)
            typeface = try container.decodeIfPresent(Typeface.self, forKey: .typeface) ?? .standard
            fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
            fontFallbacks = try container.decodeIfPresent(
                [String].self,
                forKey: .fontFallbacks
            ) ?? []
            scrollerPlacement = try container.decodeIfPresent(
                ScrollerPlacement.self,
                forKey: .scrollerPlacement
            ) ?? .trailing
            scrollerTrackStyle = try container.decodeIfPresent(
                ScrollerTrackStyle.self,
                forKey: .scrollerTrackStyle
            ) ?? .solid
            scrollerAppearance = try container.decodeIfPresent(
                ScrollerAppearance.self,
                forKey: .scrollerAppearance
            ) ?? .automatic
            menuAppearance = try container.decodeIfPresent(
                MenuAppearance.self,
                forKey: .menuAppearance
            ) ?? .automatic
            progressStyle = try container.decodeIfPresent(
                ProgressStyle.self,
                forKey: .progressStyle
            ) ?? .continuous
            choiceStyle = try container.decodeIfPresent(
                ChoiceStyle.self,
                forKey: .choiceStyle
            ) ?? .chip
        }
    }

    /// The measure and construction of a bevel material's edge. A struct rather than a bare
    /// width keeps the classic hard edge and the rounded soft relief in one wire vocabulary.
    struct Bevel: Codable, Equatable {
        /// Points per edge, bounded by validation to 1...3: one point is a whisper, two is
        /// the classic, and past three the edges stop framing a surface and start being one.
        var width: CGFloat = 2

        /// Hard is the crisp rectilinear construction shipped first. Soft is an antialiased,
        /// rounded inset gradient: light at the top-leading edge, shade at bottom-trailing.
        var style: Style = .hard

        enum Style: String, Codable, CaseIterable {
            case hard
            case soft
        }

        init(width: CGFloat = 2, style: Style = .hard) {
            self.width = width
            self.style = style
        }

        private enum CodingKeys: String, CodingKey {
            case width, style
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeIfPresent(CGFloat.self, forKey: .width) ?? 2
            style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .hard
        }
    }

    struct Glow: Codable, Equatable {
        let role: AppThemeRole
        let radius: CGFloat
        let opacity: Double
        let offsetX: CGFloat
        let offsetY: CGFloat
        let highlight: Highlight?

        /// The optional second outer shadow, normally a pale lift travelling opposite the
        /// primary shade. It deliberately has the same bounded vocabulary as the primary
        /// shadow but is nested so every document written before paired shadows still decodes.
        struct Highlight: Codable, Equatable {
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

        init(
            role: AppThemeRole,
            radius: CGFloat,
            opacity: Double,
            offsetX: CGFloat = 0,
            offsetY: CGFloat = 0,
            highlight: Highlight? = nil
        ) {
            self.role = role
            self.radius = radius
            self.opacity = opacity
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.highlight = highlight
        }

        private enum CodingKeys: String, CodingKey {
            case role, radius, opacity, offsetX, offsetY, highlight
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(AppThemeRole.self, forKey: .role)
            radius = try container.decode(CGFloat.self, forKey: .radius)
            opacity = try container.decode(Double.self, forKey: .opacity)
            offsetX = try container.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
            offsetY = try container.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0
            highlight = try container.decodeIfPresent(Highlight.self, forKey: .highlight)
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
        case .fieldSurface:
            return roles[.panel]
        case .floatingSurface:
            return roles[.elevated]
                ?? roles[.panel]?.lightened(by: kind == .dark ? 0.06 : -0.04)
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
