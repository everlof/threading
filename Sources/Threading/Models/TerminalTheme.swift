import AppKit
import SwiftTerm

// MARK: - Identity

/// A terminal theme's durable identity, separate from its editable display name.
struct TerminalThemeID: Hashable, Codable, RawRepresentable, CustomStringConvertible {
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

    static let basic = TerminalThemeID("basic")
    static let pro = TerminalThemeID("pro")
    static let homebrew = TerminalThemeID("homebrew")
    static let ocean = TerminalThemeID("ocean")
    static let roseMoon = TerminalThemeID("rose-moon")
    static let followsAppTheme = TerminalThemeID("follow-app-theme")

    static func makeCustom() -> TerminalThemeID {
        TerminalThemeID("custom-\(UUID().uuidString.lowercased())")
    }

    /// State written before IDs existed is tagged with its old name. The tag cannot collide
    /// with a real ID and lets the assignment layer resolve it once against the theme library.
    static func legacyName(_ name: String) -> TerminalThemeID {
        TerminalThemeID("legacy-name-\(encodedComponent(name))")
    }

    /// A deterministic replacement for a persisted custom theme that claims an ID already in
    /// use. Migration used a fresh UUID here; if its best-effort rewrite failed, the in-memory ID
    /// changed again on every launch and any project assignment saved meanwhile became dangling.
    static func recoveredFromCollision(name: String, ordinal: Int) -> TerminalThemeID {
        TerminalThemeID("recovered-custom-\(encodedComponent(name))-\(ordinal)")
    }

    var legacyName: String? {
        let prefix = "legacy-name-"
        guard rawValue.hasPrefix(prefix) else { return nil }
        var encoded = String(rawValue.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func migratedFromName(_ name: String) -> TerminalThemeID {
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

enum TerminalThemeNames {
    /// The terminal-theme list's first entry: draw with the palette the *app* theme states.
    ///
    /// The ID is the identity; this name is only the label shown to people and older clients.
    static let followsAppTheme = "Follow App Theme"
}

/// Color scheme for terminal rendering.
struct TerminalTheme: Codable, Equatable {

    // MARK: - Properties

    var id: TerminalThemeID
    var name: String
    var foreground: NSColor
    /// Terminal.app's "Bold Text": what SGR 1 drawn with the *default* foreground uses.
    ///
    /// A palette states it because weight alone cannot carry a heading. Claude Code writes body
    /// copy in the default foreground and headings as bold in the same colour, so on a palette
    /// whose foreground is already its brightest tone the two rendered identically. Bold with an
    /// *explicit* ANSI colour keeps its bright shift and never comes here.
    var boldForeground: NSColor
    var background: NSColor
    var cursor: NSColor
    var selection: NSColor

    // ANSI Colors (0-15)
    var black: NSColor
    var red: NSColor
    var green: NSColor
    var yellow: NSColor
    var blue: NSColor
    var magenta: NSColor
    var cyan: NSColor
    var white: NSColor

    // Bright variants
    var brightBlack: NSColor
    var brightRed: NSColor
    var brightGreen: NSColor
    var brightYellow: NSColor
    var brightBlue: NSColor
    var brightMagenta: NSColor
    var brightCyan: NSColor
    var brightWhite: NSColor

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, name, foreground, boldForeground, background, cursor, selection
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow
        case brightBlue, brightMagenta, brightCyan, brightWhite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(TerminalThemeID.self, forKey: .id)
            ?? TerminalThemeID.migratedFromName(name)
        foreground = try Self.decodeColor(from: container, forKey: .foreground)
        // A palette written before the role existed keeps drawing exactly as it did: bold text
        // takes the foreground, which is what SwiftTerm did for it anyway. Only an absent key
        // means that; a present-but-unparseable value goes through the same role fallback as
        // every other colour.
        boldForeground = container.contains(.boldForeground)
            ? try Self.decodeColor(from: container, forKey: .boldForeground)
            : foreground
        background = try Self.decodeColor(from: container, forKey: .background)
        cursor = try Self.decodeColor(from: container, forKey: .cursor)
        selection = try Self.decodeColor(from: container, forKey: .selection)

        black = try Self.decodeColor(from: container, forKey: .black)
        red = try Self.decodeColor(from: container, forKey: .red)
        green = try Self.decodeColor(from: container, forKey: .green)
        yellow = try Self.decodeColor(from: container, forKey: .yellow)
        blue = try Self.decodeColor(from: container, forKey: .blue)
        magenta = try Self.decodeColor(from: container, forKey: .magenta)
        cyan = try Self.decodeColor(from: container, forKey: .cyan)
        white = try Self.decodeColor(from: container, forKey: .white)

        brightBlack = try Self.decodeColor(from: container, forKey: .brightBlack)
        brightRed = try Self.decodeColor(from: container, forKey: .brightRed)
        brightGreen = try Self.decodeColor(from: container, forKey: .brightGreen)
        brightYellow = try Self.decodeColor(from: container, forKey: .brightYellow)
        brightBlue = try Self.decodeColor(from: container, forKey: .brightBlue)
        brightMagenta = try Self.decodeColor(from: container, forKey: .brightMagenta)
        brightCyan = try Self.decodeColor(from: container, forKey: .brightCyan)
        brightWhite = try Self.decodeColor(from: container, forKey: .brightWhite)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try Self.encodeColor(foreground, to: &container, forKey: .foreground)
        try Self.encodeColor(boldForeground, to: &container, forKey: .boldForeground)
        try Self.encodeColor(background, to: &container, forKey: .background)
        try Self.encodeColor(cursor, to: &container, forKey: .cursor)
        try Self.encodeColor(selection, to: &container, forKey: .selection)

        try Self.encodeColor(black, to: &container, forKey: .black)
        try Self.encodeColor(red, to: &container, forKey: .red)
        try Self.encodeColor(green, to: &container, forKey: .green)
        try Self.encodeColor(yellow, to: &container, forKey: .yellow)
        try Self.encodeColor(blue, to: &container, forKey: .blue)
        try Self.encodeColor(magenta, to: &container, forKey: .magenta)
        try Self.encodeColor(cyan, to: &container, forKey: .cyan)
        try Self.encodeColor(white, to: &container, forKey: .white)

        try Self.encodeColor(brightBlack, to: &container, forKey: .brightBlack)
        try Self.encodeColor(brightRed, to: &container, forKey: .brightRed)
        try Self.encodeColor(brightGreen, to: &container, forKey: .brightGreen)
        try Self.encodeColor(brightYellow, to: &container, forKey: .brightYellow)
        try Self.encodeColor(brightBlue, to: &container, forKey: .brightBlue)
        try Self.encodeColor(brightMagenta, to: &container, forKey: .brightMagenta)
        try Self.encodeColor(brightCyan, to: &container, forKey: .brightCyan)
        try Self.encodeColor(brightWhite, to: &container, forKey: .brightWhite)
    }

    /// A stored colour that cannot be parsed falls back to the stock palette's colour for the
    /// **same role**, and says so in the log.
    ///
    /// It used to fall back to white, which is the one answer that can make the terminal unusable:
    /// a dark theme whose `background` failed to parse drew *paper*, and the palette written to
    /// read on a dark ground was suddenly invisible on it. White is also indistinguishable from a
    /// theme that really is white, so nothing anywhere reported that a colour had been lost — the
    /// user saw a broken terminal and the app believed it had loaded a theme.
    ///
    /// The role is what makes the fallback usable rather than merely safe: `background` falls back
    /// to a background, `red` to a red. A key the palette does not name at all keeps the old
    /// answer, since there is no role to borrow from.
    private static func decodeColor(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> NSColor {
        let hex = try container.decode(String.self, forKey: key)
        if let colour = NSColor(hex: hex) { return colour }

        guard let role = ThemeColorKey(rawValue: key.stringValue) else {
            ThreadingLogger.terminal.warning(
                "Theme colour \(key.stringValue, privacy: .public) is unparseable and unnamed."
            )
            return .white
        }

        ThreadingLogger.terminal.warning(
            """
            Theme colour \(key.stringValue, privacy: .public) could not be parsed; \
            using the stock palette's own value for that role.
            """
        )
        return TerminalTheme.basic[keyPath: role.keyPath]
    }

    private static func encodeColor(_ color: NSColor, to container: inout KeyedEncodingContainer<CodingKeys>, forKey key: CodingKeys) throws {
        try container.encode(color.hexString, forKey: key)
    }

    // MARK: - Initializer

    init(
        id: TerminalThemeID = .makeCustom(),
        name: String,
        foreground: NSColor,
        /// Defaulted so a caller that has no opinion keeps the old behaviour — bold text drawn
        /// in the foreground. Every palette this app ships states one; the sweep in
        /// `TerminalBoldTextSweepTests` is what holds them to it.
        boldForeground: NSColor? = nil,
        background: NSColor,
        cursor: NSColor,
        selection: NSColor,
        black: NSColor,
        red: NSColor,
        green: NSColor,
        yellow: NSColor,
        blue: NSColor,
        magenta: NSColor,
        cyan: NSColor,
        white: NSColor,
        brightBlack: NSColor,
        brightRed: NSColor,
        brightGreen: NSColor,
        brightYellow: NSColor,
        brightBlue: NSColor,
        brightMagenta: NSColor,
        brightCyan: NSColor,
        brightWhite: NSColor
    ) {
        self.id = id
        self.name = name
        self.foreground = foreground
        self.boldForeground = boldForeground ?? foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.black = black
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.magenta = magenta
        self.cyan = cyan
        self.white = white
        self.brightBlack = brightBlack
        self.brightRed = brightRed
        self.brightGreen = brightGreen
        self.brightYellow = brightYellow
        self.brightBlue = brightBlue
        self.brightMagenta = brightMagenta
        self.brightCyan = brightCyan
        self.brightWhite = brightWhite
    }
}

// MARK: - Built-in Themes

extension TerminalTheme {

    static let basic = TerminalTheme(
        id: .basic,
        name: "Basic",
        // Body text is the ramp's own `white` (index 7) so the heading can have pure white.
        // Terminal.app's Pro has the same idea, #F2F2F2 text and #FFFFFF bold; Pro's step is
        // smaller, at ΔE 4.5 against this pair's 19.8.
        foreground: NSColor(hex: "#C7C7C7")!,
        boldForeground: .white,
        background: .black,
        cursor: NSColor(hex: "#C7C7C7")!,  // The body's ink, as every paired palette's is
        selection: NSColor(white: 0.3, alpha: 1.0),
        black: .black,
        red: NSColor(hex: "#C91B00")!,
        green: NSColor(hex: "#00C200")!,
        yellow: NSColor(hex: "#C7C400")!,
        blue: NSColor(hex: "#0225C7")!,
        magenta: NSColor(hex: "#C930C7")!,
        cyan: NSColor(hex: "#00C5C7")!,
        white: NSColor(hex: "#C7C7C7")!,
        brightBlack: NSColor(hex: "#676767")!,
        brightRed: NSColor(hex: "#FF6D67")!,
        brightGreen: NSColor(hex: "#5FF967")!,
        brightYellow: NSColor(hex: "#FEFB67")!,
        brightBlue: NSColor(hex: "#6871FF")!,
        brightMagenta: NSColor(hex: "#FF76FF")!,
        brightCyan: NSColor(hex: "#5FFDFF")!,
        brightWhite: .white
    )

    /// Pro theme - matches Terminal.app's Pro profile colors
    static let pro = TerminalTheme(
        id: .pro,
        name: "Pro",
        foreground: NSColor(hex: "#5ADB57")!,  // Green text like Terminal Pro_DUP
        boldForeground: NSColor(hex: "#FFFFFF")!,  // Pro_DUP's own Bold Text
        background: NSColor(hex: "#20222B")!,  // Dark blue-gray background
        cursor: NSColor(hex: "#4D4D4D")!,
        selection: NSColor(hex: "#414141")!,
        black: NSColor(hex: "#000000")!,
        red: NSColor(hex: "#FF2600")!,
        green: NSColor(hex: "#3AFF00")!,
        yellow: NSColor(hex: "#FFFC00")!,
        blue: NSColor(hex: "#1478FF")!,
        magenta: NSColor(hex: "#FF00FF")!,
        cyan: NSColor(hex: "#00FCFF")!,
        white: NSColor(hex: "#F2F2F2")!,
        brightBlack: NSColor(hex: "#808080")!,
        brightRed: NSColor(hex: "#FF6B6B")!,   // Bright red matching Terminal.app
        brightGreen: NSColor(hex: "#51C34E")!, // From Pro_DUP
        brightYellow: NSColor(hex: "#FEFE67")!,
        brightBlue: NSColor(hex: "#2943F1")!,  // From Pro_DUP
        brightMagenta: NSColor(hex: "#FF77FF")!,
        brightCyan: NSColor(hex: "#68FDFE")!,
        brightWhite: NSColor(hex: "#FFFFFF")!
    )

    static let homebrew = TerminalTheme(
        id: .homebrew,
        name: "Homebrew",
        foreground: NSColor(hex: "#00FF00")!,
        // Phosphor bloom: the same green pushed to the top of the tube rather than a neutral,
        // which would read as a second terminal pasted into this one.
        boldForeground: NSColor(hex: "#CCFFCC")!,
        background: .black,
        cursor: NSColor(hex: "#00FF00")!,
        selection: NSColor(hex: "#004400")!,
        black: .black,
        red: NSColor(hex: "#990000")!,
        green: NSColor(hex: "#00A600")!,
        yellow: NSColor(hex: "#999900")!,
        blue: NSColor(hex: "#0000B2")!,
        magenta: NSColor(hex: "#B200B2")!,
        cyan: NSColor(hex: "#00A6B2")!,
        white: NSColor(hex: "#BFBFBF")!,
        brightBlack: NSColor(hex: "#666666")!,
        brightRed: NSColor(hex: "#E50000")!,
        brightGreen: NSColor(hex: "#00D900")!,
        brightYellow: NSColor(hex: "#E5E500")!,
        brightBlue: NSColor(hex: "#0000FF")!,
        brightMagenta: NSColor(hex: "#E500E5")!,
        brightCyan: NSColor(hex: "#00E5E5")!,
        brightWhite: NSColor(hex: "#E5E5E5")!
    )

    static let ocean = TerminalTheme(
        id: .ocean,
        name: "Ocean",
        foreground: NSColor(hex: "#C0C5CE")!,
        boldForeground: NSColor(hex: "#EFF1F5")!,  // The ramp's own lightest tone
        background: NSColor(hex: "#2B303B")!,
        cursor: NSColor(hex: "#C0C5CE")!,
        selection: NSColor(hex: "#4F5B66")!,
        black: NSColor(hex: "#2B303B")!,
        red: NSColor(hex: "#BF616A")!,
        green: NSColor(hex: "#A3BE8C")!,
        yellow: NSColor(hex: "#EBCB8B")!,
        blue: NSColor(hex: "#8FA1B3")!,
        magenta: NSColor(hex: "#B48EAD")!,
        cyan: NSColor(hex: "#96B5B4")!,
        white: NSColor(hex: "#C0C5CE")!,
        brightBlack: NSColor(hex: "#65737E")!,
        brightRed: NSColor(hex: "#BF616A")!,
        brightGreen: NSColor(hex: "#A3BE8C")!,
        brightYellow: NSColor(hex: "#EBCB8B")!,
        brightBlue: NSColor(hex: "#8FA1B3")!,
        brightMagenta: NSColor(hex: "#B48EAD")!,
        brightCyan: NSColor(hex: "#96B5B4")!,
        brightWhite: NSColor(hex: "#EFF1F5")!
    )

    /// A muted, warm dark palette in the Rosé Pine register: a blue-black ground, cool
    /// lavender text, and desaturated rose/gold/sage/sky/violet accents rather than the primary
    /// brights the classic ramps use. Where `Ocean` is Nord's cool blue-grey, this leans warm.
    /// Rosé Pine has no true green, so `green` is a legible sage so `git`/`ls`/added lines still
    /// read as green rather than teal.
    ///
    /// **The heading is warm where the body is cool**, which is this palette's own distinction
    /// rather than a brighter shade of the same ink. It shipped as `#F4F2FF` — `brightWhite`,
    /// the classic pairing — and against a body that is *already* pale lavender that is ΔE 8.3,
    /// half the floor: legible, and invisible as a heading. The warm off-white is 23.2 from the
    /// body and 21.2 from the nearest coloured slot, so it can be neither mistaken for ordinary
    /// text nor read as output a program coloured. Terminal.app's Grass does the same thing with
    /// its amber bold, and for the same reason.
    static let roseMoon = TerminalTheme(
        id: .roseMoon,
        name: "Rosé Moon",
        foreground: NSColor(hex: "#E0DEF4")!,
        boldForeground: NSColor(hex: "#FBEBD6")!,
        background: NSColor(hex: "#1B1D2A")!,
        cursor: NSColor(hex: "#EA9A97")!,
        selection: NSColor(hex: "#3B3854")!,
        black: NSColor(hex: "#393552")!,
        red: NSColor(hex: "#EB6F92")!,
        green: NSColor(hex: "#A3BE9C")!,
        yellow: NSColor(hex: "#F6C177")!,
        blue: NSColor(hex: "#7FB4CA")!,
        magenta: NSColor(hex: "#C4A7E7")!,
        cyan: NSColor(hex: "#9CCFD8")!,
        white: NSColor(hex: "#C9C7DB")!,
        brightBlack: NSColor(hex: "#6E6A86")!,
        brightRed: NSColor(hex: "#F08FA6")!,
        brightGreen: NSColor(hex: "#B7D1A8")!,
        brightYellow: NSColor(hex: "#FBD9A0")!,
        brightBlue: NSColor(hex: "#A5C9DE")!,
        brightMagenta: NSColor(hex: "#D6BEF0")!,
        brightCyan: NSColor(hex: "#B3E0E8")!,
        brightWhite: NSColor(hex: "#F4F2FF")!
    )

    /// All available themes (use ThemeManager.shared.allThemes for the full list including custom themes)
    static let builtInThemes: [TerminalTheme] = [.basic, .pro, .homebrew, .ocean, .roseMoon]

    // MARK: - The System App Theme's Pair

    /// The palettes the **System app theme** pairs with macOS's two appearances.
    ///
    /// Deliberately not in `builtInThemes`: they are not entries in the terminal-theme list but
    /// the answer "Follow App Theme" resolves to under System, the way every styled theme states
    /// a palette per variant. Both are Terminal.app's Basic ramp — the ramp `basic` already
    /// carries — so a terminal that stops following the app theme and picks Basic keeps its
    /// colours and changes only its ground.
    ///
    /// The dark ground is the measured dark `windowBackgroundColor` rather than pure black, so
    /// a session and the chrome beside it read as one surface with the divider as their seam —
    /// pure black next to the chrome's near-black was a hole in the window, and in light mode it
    /// painted the whole backdrop black behind a light app. That seam is the System theme's own
    /// idea applied to the terminal: the palette follows the appearance, like every role does.
    static let systemLight = TerminalTheme(
        id: TerminalThemeID("system-light"),
        name: "System",
        // A step back from the ramp's `black`, which the heading keeps. The step sits above the
        // palette's own `brightBlack`, so text dimmed to index 8 stays tellable from body copy.
        foreground: NSColor(hex: "#333333")!,
        boldForeground: .black,
        background: .white,
        cursor: NSColor(white: 0.35, alpha: 1.0),
        selection: NSColor(hex: "#B3D7FF")!,
        black: .black,
        red: NSColor(hex: "#C91B00")!,
        green: NSColor(hex: "#00C200")!,
        yellow: NSColor(hex: "#C7C400")!,
        blue: NSColor(hex: "#0225C7")!,
        magenta: NSColor(hex: "#C930C7")!,
        cyan: NSColor(hex: "#00C5C7")!,
        white: NSColor(hex: "#C7C7C7")!,
        brightBlack: NSColor(hex: "#676767")!,
        brightRed: NSColor(hex: "#FF6D67")!,
        brightGreen: NSColor(hex: "#5FF967")!,
        brightYellow: NSColor(hex: "#FEFB67")!,
        brightBlue: NSColor(hex: "#6871FF")!,
        brightMagenta: NSColor(hex: "#FF76FF")!,
        brightCyan: NSColor(hex: "#5FFDFF")!,
        brightWhite: .white
    )

    /// The app-theme entry in **stored** form, for the one place that must hold a palette rather
    /// than resolve one: the default profile embeds its theme instead of naming it, so that a
    /// terminal keeps drawing after the theme it named has been deleted.
    ///
    /// Only the reserved ID is load-bearing here — `ThemeAssignments.palette(withID:)` answers it
    /// from the live app theme, so these colours are never what a terminal draws with. They are
    /// `systemDark`'s so that anything reading a raw profile without resolving it still gets the
    /// palette the System theme pairs with rather than a blank one. A static snapshot cannot be
    /// appearance-aware; the resolved answer is, which is the whole reason the ID is stored.
    static let followsAppTheme = systemDark.identified(
        .followsAppTheme,
        named: TerminalThemeNames.followsAppTheme
    )

    static let systemDark = TerminalTheme(
        id: TerminalThemeID("system-dark"),
        name: "System",
        foreground: NSColor(hex: "#C7C7C7")!,  // The ramp's own `white`, as in Basic
        boldForeground: NSColor(hex: "#FFFFFF")!,
        background: NSColor(hex: "#1E1E1E")!,
        cursor: NSColor(hex: "#C7C7C7")!,
        selection: NSColor(white: 0.32, alpha: 1.0),
        black: .black,
        red: NSColor(hex: "#C91B00")!,
        green: NSColor(hex: "#00C200")!,
        yellow: NSColor(hex: "#C7C400")!,
        blue: NSColor(hex: "#0225C7")!,
        magenta: NSColor(hex: "#C930C7")!,
        cyan: NSColor(hex: "#00C5C7")!,
        white: NSColor(hex: "#C7C7C7")!,
        brightBlack: NSColor(hex: "#676767")!,
        brightRed: NSColor(hex: "#FF6D67")!,
        brightGreen: NSColor(hex: "#5FF967")!,
        brightYellow: NSColor(hex: "#FEFB67")!,
        brightBlue: NSColor(hex: "#6871FF")!,
        brightMagenta: NSColor(hex: "#FF76FF")!,
        brightCyan: NSColor(hex: "#5FFDFF")!,
        brightWhite: .white
    )

    /// The same palette under another name. An app theme's palette is named after the *theme*,
    /// so anything that reports which colours a terminal drew with names the thing the user
    /// chose rather than the built-in it happens to equal.
    func renamed(_ newName: String) -> TerminalTheme {
        var copy = self
        copy.name = newName
        return copy
    }

    /// A new editable theme copied from this palette. Unlike `renamed`, this is a new identity.
    func duplicated(named newName: String) -> TerminalTheme {
        var copy = self
        copy.id = .makeCustom()
        copy.name = newName
        return copy
    }

    /// Gives a virtual palette, such as Follow App Theme, its reserved identity.
    func identified(_ id: TerminalThemeID, named newName: String? = nil) -> TerminalTheme {
        var copy = self
        copy.id = id
        if let newName { copy.name = newName }
        return copy
    }

    /// Convenience accessor - prefer ThemeManager.shared.allThemes
    @MainActor
    static var allThemes: [TerminalTheme] {
        ThemeManager.shared.allThemes
    }

    /// Convert theme to SwiftTerm Color array (16 ANSI colors)
    func asSwiftTermColors() -> [Color] {
        return [
            black.asSwiftTermColor(),
            red.asSwiftTermColor(),
            green.asSwiftTermColor(),
            yellow.asSwiftTermColor(),
            blue.asSwiftTermColor(),
            magenta.asSwiftTermColor(),
            cyan.asSwiftTermColor(),
            white.asSwiftTermColor(),
            brightBlack.asSwiftTermColor(),
            brightRed.asSwiftTermColor(),
            brightGreen.asSwiftTermColor(),
            brightYellow.asSwiftTermColor(),
            brightBlue.asSwiftTermColor(),
            brightMagenta.asSwiftTermColor(),
            brightCyan.asSwiftTermColor(),
            brightWhite.asSwiftTermColor()
        ]
    }

    /// Whether this palette's page is the dark one.
    ///
    /// The same test `Design.Diff.on(_:)` uses, and for the same reason: measuring the contrast
    /// against both extremes answers for a mid-tone background, where a luminance threshold has
    /// to guess.
    var hasDarkBackground: Bool {
        ThemeContrast.ratio(.white, background) >= ThemeContrast.ratio(.black, background)
    }

    /// What this palette says through `COLORFGBG` — the **second** way a terminal tells the
    /// program running in it whether it is paper or ink, and the one that does not need a reply
    /// to arrive in time.
    ///
    /// Answering `OSC 11 ; ? ST` — `docs/architecture/dependencies.md` — is the first way, and
    /// it is a handshake: the program asks in its first few bytes, waits,
    /// and assumes **dark** if it hears nothing it can use. Measured against Claude Code 2.1.220
    /// in a PTY, the reply this app sends is byte-for-byte one it accepts — and sessions launched
    /// from a build that sends it still came up in the dark palette. A handshake that early has
    /// too many ways to be missed to be the only answer.
    ///
    /// So the same fact is also stated up front, in the environment, where nothing can race it.
    /// Claude Code reads `COLORFGBG` as the fallback behind its own query (`"theme": "auto"`,
    /// which is the shipped default and is *not* "follow macOS"), and it is rxvt's long-standing
    /// convention that vim, less and delta read too. It is deliberately only a *fallback*: a
    /// person who has set a theme by hand keeps it, because this describes the terminal rather
    /// than choosing for the program.
    ///
    /// The value is `<foreground>;<background>` as ANSI indices, and only the background is ever
    /// read — every consumer takes the last field and asks whether it is a dark slot. Reporting
    /// the palette's *own* nearest index would be a worse answer than it looks: Bauhaus's slot 7
    /// is a dark grey-brown, so a warm-paper theme would have described itself with a colour
    /// nothing on screen is. `0;15` and `15;0` are what a terminal with default colours reports,
    /// and they carry exactly the one bit anybody asks for.
    var colorFGBG: String {
        hasDarkBackground ? "15;0" : "0;15"
    }
}

// MARK: - NSColor to SwiftTerm Color

extension NSColor {
    func asSwiftTermColor() -> Color {
        guard let rgb = usingColorSpace(.sRGB) else {
            return Color(red: 0, green: 0, blue: 0)
        }
        return Color(
            red: UInt16(rgb.redComponent * 65535),
            green: UInt16(rgb.greenComponent * 65535),
            blue: UInt16(rgb.blueComponent * 65535)
        )
    }
}
