import AppKit

/// One colour in a theme, named once for everything that has to talk about it.
///
/// The settings editor kept a `[String: NSColorWell]` and a per-colour `switch` to put a
/// changed colour back; the MCP tools need the same mapping from a name a model wrote to the
/// property it sets. Both are a key path, so this is that key path with its two names attached
/// — `displayName` for a label, `wireName` for the tool schema, where snake case is what a
/// model reaches for unprompted.
public enum ThemeColorKey: String, CaseIterable {
    case foreground, boldForeground, background, cursor, selection
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    // MARK: - Groups

    /// The five that are not ANSI indices: what text, bold text, ground, caret and selection
    /// are drawn in.
    public static let main: [ThemeColorKey] = [
        .foreground, .boldForeground, .background, .cursor, .selection
    ]

    /// ANSI 0–7, in index order — the order every terminal palette is written in.
    public static let normal: [ThemeColorKey] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white
    ]

    /// ANSI 8–15, index-aligned with `normal` so the two rows read as a grid.
    public static let bright: [ThemeColorKey] = [
        .brightBlack, .brightRed, .brightGreen, .brightYellow,
        .brightBlue, .brightMagenta, .brightCyan, .brightWhite
    ]

    // MARK: - Naming

    public var keyPath: WritableKeyPath<TerminalTheme, NSColor> {
        switch self {
        case .foreground: return \.foreground
        case .boldForeground: return \.boldForeground
        case .background: return \.background
        case .cursor: return \.cursor
        case .selection: return \.selection
        case .black: return \.black
        case .red: return \.red
        case .green: return \.green
        case .yellow: return \.yellow
        case .blue: return \.blue
        case .magenta: return \.magenta
        case .cyan: return \.cyan
        case .white: return \.white
        case .brightBlack: return \.brightBlack
        case .brightRed: return \.brightRed
        case .brightGreen: return \.brightGreen
        case .brightYellow: return \.brightYellow
        case .brightBlue: return \.brightBlue
        case .brightMagenta: return \.brightMagenta
        case .brightCyan: return \.brightCyan
        case .brightWhite: return \.brightWhite
        }
    }

    /// Title case, splitting the `bright` prefix out: "Bright Magenta".
    public var displayName: String {
        switch self {
        case .foreground: return L10n.string("Text")
        case .boldForeground: return L10n.string("Bold Text")
        case .background: return L10n.string("Background")
        case .cursor: return L10n.string("Cursor")
        case .selection: return L10n.string("Selection")
        case .black: return L10n.string("Black")
        case .red: return L10n.string("Red")
        case .green: return L10n.string("Green")
        case .yellow: return L10n.string("Yellow")
        case .blue: return L10n.string("Blue")
        case .magenta: return L10n.string("Magenta")
        case .cyan: return L10n.string("Cyan")
        case .white: return L10n.string("White")
        case .brightBlack: return L10n.format("Bright %@", L10n.string("Black"))
        case .brightRed: return L10n.format("Bright %@", L10n.string("Red"))
        case .brightGreen: return L10n.format("Bright %@", L10n.string("Green"))
        case .brightYellow: return L10n.format("Bright %@", L10n.string("Yellow"))
        case .brightBlue: return L10n.format("Bright %@", L10n.string("Blue"))
        case .brightMagenta: return L10n.format("Bright %@", L10n.string("Magenta"))
        case .brightCyan: return L10n.format("Bright %@", L10n.string("Cyan"))
        case .brightWhite: return L10n.format("Bright %@", L10n.string("White"))
        }
    }

    /// Snake case, which is what a model writes without being asked: `bright_magenta`.
    ///
    /// Only the `bright` prefix is decomposed automatically; anything else that is two words in
    /// Swift states its wire spelling here, because a raw value's camel case is not snake case
    /// and `named(_:)` has to round-trip.
    public var wireName: String {
        if self == .boldForeground { return "bold_foreground" }
        guard let bright = brightBase else { return rawValue }
        return "bright_\(bright)"
    }

    private var brightBase: String? {
        guard rawValue.hasPrefix("bright") else { return nil }
        return rawValue.dropFirst("bright".count).lowercased()
    }

    public static func named(_ wireName: String) -> ThemeColorKey? {
        allCases.first { $0.wireName == wireName.lowercased() }
    }

    // MARK: - Reading a Stated Palette

    /// Whether a `{name: hex}` map an agent wrote names this colour, however it spelled the key.
    fileprivate func isStated(in values: [String: String]) -> Bool {
        values.keys.contains { ThemeColorKey.named($0) == self }
    }

    /// This colour out of a `{name: hex}` map, if it is named there and parses.
    fileprivate func statedColour(in values: [String: String]) -> NSColor? {
        guard let hex = values.first(where: { ThemeColorKey.named($0.key) == self })?.value else {
            return nil
        }
        return NSColor(hex: hex)
    }
}

// MARK: - Merging an Agent's Palette

extension TerminalTheme {

    /// This palette with its bold text following a stated text colour.
    ///
    /// The tools merge what an agent stated onto a base palette, so a caller that moves the
    /// text colour and says nothing about bold would otherwise keep the *base's* heading ink,
    /// chosen for a palette this one has just stopped being. A caller that states neither keeps
    /// both, which is what makes a theme derived from a stock one inherit the stock pairing.
    public func adoptingBoldForeground(from values: [String: String]) -> TerminalTheme {
        guard let foreground = ThemeColorKey.foreground.statedColour(in: values),
              !ThemeColorKey.boldForeground.isStated(in: values)
        else { return self }

        var copy = self
        copy.boldForeground = foreground
        return copy
    }
}

// MARK: - Theme Access

extension TerminalTheme {

    public subscript(key: ThemeColorKey) -> NSColor {
        get { self[keyPath: key.keyPath] }
        set { self[keyPath: key.keyPath] = newValue }
    }
}
