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
    /// Extra space between two lines of one paragraph, and between two lines of a code block.
    /// Zero leaves AppKit's own line box, which is what a host that states nothing gets.
    public var lineSpacing: CGFloat
    public var codeLineSpacing: CGFloat

    @MainActor
    public init(font: NSFont, textColor: NSColor, secondaryColor: NSColor,
                codeFont: NSFont, codeColor: NSColor, codeBackground: NSColor,
                linkColor: NSColor, headingFont: NSFont? = nil,
                lineSpacing: CGFloat = 0, codeLineSpacing: CGFloat = 0) {
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
        self.lineSpacing = lineSpacing
        self.codeLineSpacing = codeLineSpacing
    }

    /// The paragraph style prose is set in, or nil when the style states no spacing.
    public var paragraphStyle: NSParagraphStyle? {
        Self.paragraphStyle(lineSpacing: lineSpacing)
    }

    /// The same for a code block's lines, which never wrap.
    ///
    /// The line-break mode is stated because a paragraph style always carries one, and its
    /// default — word wrapping — overrides the clipping label it is set on: the label stops
    /// stating a width of its own, collapses to a few points inside its scroll view, and the
    /// block draws as an empty plate.
    public var codeParagraphStyle: NSParagraphStyle? {
        Self.paragraphStyle(lineSpacing: codeLineSpacing, lineBreakMode: .byClipping)
    }

    private static func paragraphStyle(
        lineSpacing: CGFloat,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSParagraphStyle? {
        guard lineSpacing > 0 else { return nil }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = lineBreakMode
        return style
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
