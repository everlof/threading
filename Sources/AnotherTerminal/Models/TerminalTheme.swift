import AppKit

/// Color scheme for terminal rendering.
struct TerminalTheme: Codable, Equatable {

    // MARK: - Properties

    var name: String
    var foreground: NSColor
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
        case name, foreground, background, cursor, selection
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow
        case brightBlue, brightMagenta, brightCyan, brightWhite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        foreground = try Self.decodeColor(from: container, forKey: .foreground)
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

        try container.encode(name, forKey: .name)
        try Self.encodeColor(foreground, to: &container, forKey: .foreground)
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

    private static func decodeColor(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> NSColor {
        let hex = try container.decode(String.self, forKey: key)
        return NSColor(hex: hex) ?? .white
    }

    private static func encodeColor(_ color: NSColor, to container: inout KeyedEncodingContainer<CodingKeys>, forKey key: CodingKeys) throws {
        try container.encode(color.hexString, forKey: key)
    }

    // MARK: - Initializer

    init(
        name: String,
        foreground: NSColor,
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
        self.name = name
        self.foreground = foreground
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
        name: "Basic",
        foreground: .white,
        background: .black,
        cursor: .white,
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

    static let pro = TerminalTheme(
        name: "Pro",
        foreground: NSColor(hex: "#F2F2F2")!,
        background: NSColor(hex: "#1A1A1A")!,
        cursor: NSColor(hex: "#4D4D4D")!,
        selection: NSColor(hex: "#414141")!,
        black: .black,
        red: NSColor(hex: "#FF6B6B")!,
        green: NSColor(hex: "#69FF94")!,
        yellow: NSColor(hex: "#FFFFA5")!,
        blue: NSColor(hex: "#6FB3D2")!,
        magenta: NSColor(hex: "#D78CFF")!,
        cyan: NSColor(hex: "#85E0FF")!,
        white: NSColor(hex: "#F8F8F2")!,
        brightBlack: NSColor(hex: "#545454")!,
        brightRed: NSColor(hex: "#FF9494")!,
        brightGreen: NSColor(hex: "#A0FFA0")!,
        brightYellow: NSColor(hex: "#FFFFB3")!,
        brightBlue: NSColor(hex: "#A0D0F0")!,
        brightMagenta: NSColor(hex: "#E8B0FF")!,
        brightCyan: NSColor(hex: "#B0F0FF")!,
        brightWhite: .white
    )

    static let homebrew = TerminalTheme(
        name: "Homebrew",
        foreground: NSColor(hex: "#00FF00")!,
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
        name: "Ocean",
        foreground: NSColor(hex: "#C0C5CE")!,
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

    static let allThemes: [TerminalTheme] = [.basic, .pro, .homebrew, .ocean]
}
