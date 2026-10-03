import Foundation

/// Only resolved presentation crosses into Quick Look. No document or session state is shared.
public struct MarkdownPreviewTheme: Codable, Sendable {
    public var background, text, secondary, panel, accent, border: String
    public var fontName, codeFontName: String
    public var fontSize, codeFontSize, radius: Double
    public var pattern: Pattern?

    public struct Pattern: Codable, Sendable {
        public var kind, color: String
        public var spacing, width: Double
        public init(kind: String, color: String, spacing: Double, width: Double) {
            self.kind = kind; self.color = color; self.spacing = spacing; self.width = width
        }
    }

    public init(background: String, text: String, secondary: String, panel: String,
                accent: String, border: String, fontName: String, codeFontName: String,
                fontSize: Double, codeFontSize: Double, radius: Double, pattern: Pattern? = nil) {
        self.background = background; self.text = text; self.secondary = secondary
        self.panel = panel; self.accent = accent; self.border = border
        self.fontName = fontName; self.codeFontName = codeFontName
        self.fontSize = fontSize; self.codeFontSize = codeFontSize; self.radius = radius
        self.pattern = pattern
    }

    public static func system(dark: Bool) -> Self {
        Self(background: dark ? "#1e1e1e" : "#ffffff", text: dark ? "#f2f2f2" : "#202020",
             secondary: dark ? "#aaaaaa" : "#606060", panel: dark ? "#292929" : "#f3f3f3",
             accent: dark ? "#6ca8ff" : "#0066cc", border: dark ? "#444444" : "#dddddd",
             fontName: "-apple-system", codeFontName: "Menlo", fontSize: 16, codeFontSize: 13, radius: 8)
    }
}

public struct MarkdownPreviewThemes: Codable, Sendable {
    public static let groupIdentifier = "SMQ3E8Y57T.codes.threading.markdown"
    public static let filename = "markdown-preview-theme.json"
    public let light, dark: MarkdownPreviewTheme
    public init(light: MarkdownPreviewTheme, dark: MarkdownPreviewTheme) { self.light = light; self.dark = dark }
}
