import AppKit

/// Resolved presentation values; the host owns its theme and font resolution.
public struct MarkdownStyle {
    public var font: NSFont
    public var headingFont: NSFont
    public var textColor: NSColor
    public var secondaryColor: NSColor
    public var codeFont: NSFont
    public var codeColor: NSColor
    public var codeBackground: NSColor
    public var linkColor: NSColor

    @MainActor
    public init(font: NSFont, textColor: NSColor, secondaryColor: NSColor,
                codeFont: NSFont, codeColor: NSColor, codeBackground: NSColor,
                linkColor: NSColor, headingFont: NSFont? = nil) {
        self.font = font
        self.headingFont = headingFont ?? NSFontManager.shared.convert(
            NSFontManager.shared.convert(font, toSize: font.pointSize + 3), toHaveTrait: .boldFontMask
        )
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.codeFont = codeFont
        self.codeColor = codeColor
        self.codeBackground = codeBackground
        self.linkColor = linkColor
    }
}

public enum MarkdownParsingLimits {
    public static let maximumInlineNestingDepth = 32
}

/// The shared external-navigation policy for native and Quick Look documents.
public enum MarkdownExternalURLPolicy {
    public static func externalWebURL(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return externalWebURL(url)
    }

    public static func externalWebURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
