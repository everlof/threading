import AppKit

/// One colour in a theme, named once for everything that has to talk about it.
///
/// The settings editor kept a `[String: NSColorWell]` and a twenty-case `switch` to put a
/// changed colour back; the MCP tools need the same mapping from a name a model wrote to the
/// property it sets. Both are a key path, so this is that key path with its two names attached
/// — `displayName` for a label, `wireName` for the tool schema, where snake case is what a
/// model reaches for unprompted.
enum ThemeColorKey: String, CaseIterable {
    case foreground, background, cursor, selection
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    // MARK: - Groups

    /// The four that are not ANSI indices: what text, ground, caret and selection are drawn in.
    static let main: [ThemeColorKey] = [.foreground, .background, .cursor, .selection]

    /// ANSI 0–7, in index order — the order every terminal palette is written in.
    static let normal: [ThemeColorKey] = [
        .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white
    ]

    /// ANSI 8–15, index-aligned with `normal` so the two rows read as a grid.
    static let bright: [ThemeColorKey] = [
        .brightBlack, .brightRed, .brightGreen, .brightYellow,
        .brightBlue, .brightMagenta, .brightCyan, .brightWhite
    ]

    // MARK: - Naming

    var keyPath: WritableKeyPath<TerminalTheme, NSColor> {
        switch self {
        case .foreground: return \.foreground
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
    var displayName: String {
        switch self {
        case .foreground: return L10n.string("Text")
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
    var wireName: String {
        guard let bright = brightBase else { return rawValue }
        return "bright_\(bright)"
    }

    private var brightBase: String? {
        guard rawValue.hasPrefix("bright") else { return nil }
        return rawValue.dropFirst("bright".count).lowercased()
    }

    static func named(_ wireName: String) -> ThemeColorKey? {
        allCases.first { $0.wireName == wireName.lowercased() }
    }
}

// MARK: - Theme Access

extension TerminalTheme {

    subscript(key: ThemeColorKey) -> NSColor {
        get { self[keyPath: key.keyPath] }
        set { self[keyPath: key.keyPath] = newValue }
    }
}
