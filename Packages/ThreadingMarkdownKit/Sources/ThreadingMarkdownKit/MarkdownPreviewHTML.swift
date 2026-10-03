import AppKit

/// Quick Look's data-based HTML is a presentation of the native parser's blocks and inline runs.
/// Raw HTML stays escaped text. There are no scripts, external images or resource requests.
@MainActor
public enum MarkdownPreviewHTML {
    public static func render(_ document: MarkdownPreviewDocument, themes: MarkdownPreviewThemes?, title: String,
                              excerptMessage: String) -> String {
        let light = themes?.light ?? .system(dark: false)
        let dark = themes?.dark ?? .system(dark: true)
        let style = markdownStyle(light)
        let body = document.blocks.flatMap { source in
            Markdown.parse(source, style: style).map { blockHTML($0, source: source) }
        }.joined(separator: "\n")
        let notice = document.isExcerpt ? "<aside>\(escaped(excerptMessage))</aside>" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escaped(title))</title><style>
        :root { \(variables(light)) }
        @media (prefers-color-scheme: dark) { :root { \(variables(dark)) } }
        * { box-sizing: border-box; }
        html { background: var(--ground); color: var(--ink); }
        body { margin: 0; padding: 32px clamp(20px, 5vw, 52px); background-image: var(--pattern); background-size: var(--pattern-size); }
        article { max-width: 840px; margin: auto; font-family: var(--font), -apple-system, sans-serif; font-size: var(--size); line-height: 1.65; overflow-wrap: anywhere; }
        article > :first-child { margin-top: 0; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.4em 0 .55em; font-weight: 650; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3,h4,h5,h6 { font-size: 1.15em; }
        p,ul,ol,blockquote,pre,.table { margin: 0 0 1em; }
        ul,ol { padding-left: 1.7em; } li { padding-left: .2em; }
        blockquote { color: var(--secondary); border-left: 3px solid var(--accent); padding: .2em 1em; }
        a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 3px; }
        code,pre { font-family: var(--code-font), monospace; font-size: var(--code-size); }
        code { background: var(--panel); border-radius: 3px; padding: .13em .3em; }
        pre { background: var(--panel); border: 1px solid var(--border); border-radius: var(--radius); padding: 16px; overflow: auto; white-space: pre; overflow-wrap: normal; }
        pre code { padding: 0; background: none; font-size: inherit; }
        .table { overflow-x: auto; } table { border-collapse: collapse; width: 100%; font-size: .95em; }
        th,td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); }
        th { background: var(--panel); font-weight: 650; }
        aside { margin-top: 28px; padding: 14px 16px; color: var(--secondary); border: 1px solid var(--border); border-radius: var(--radius); background: var(--panel); }
        </style></head><body><article>\(body)\(notice)</article></body></html>
        """
    }

    private static func markdownStyle(_ theme: MarkdownPreviewTheme) -> MarkdownStyle {
        MarkdownStyle(font: NSFont(name: theme.fontName, size: 16) ?? .systemFont(ofSize: 16),
                      textColor: .labelColor, secondaryColor: .secondaryLabelColor,
                      codeFont: NSFont(name: theme.codeFontName, size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                      codeColor: .labelColor, codeBackground: .textBackgroundColor, linkColor: .linkColor)
    }

    private static func blockHTML(_ block: MarkdownBlock, source: String) -> String {
        switch block {
        case .paragraph(let text): return "<p>\(inlineHTML(text))</p>"
        case .heading(let text):
            let level = min(6, max(1, source.prefix { $0 == "#" }.count))
            return "<h\(level)>\(inlineHTML(text))</h\(level)>"
        case .bullets(let items): return list(items, tag: "ul")
        case .ordered(let items): return list(items, tag: "ol")
        case .code(let text): return "<pre><code>\(escaped(text))</code></pre>"
        case .quote(let text): return "<blockquote>\(inlineHTML(text))</blockquote>"
        case .table(let table):
            let heading = table.headers.map { "<th>\(inlineHTML($0))</th>" }.joined()
            let rows = table.rows.map { row in
                "<tr>" + row.enumerated().map { column, text in
                    let alignment = table.alignments[column] == .right ? "right" : table.alignments[column] == .center ? "center" : "left"
                    return "<td style=\"text-align:\(alignment)\">\(inlineHTML(text))</td>"
                }.joined() + "</tr>"
            }.joined()
            return "<div class=\"table\"><table><thead><tr>\(heading)</tr></thead><tbody>\(rows)</tbody></table></div>"
        }
    }

    private static func list(_ items: [NSAttributedString], tag: String) -> String {
        "<\(tag)>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</\(tag)>"
    }

    private static func inlineHTML(_ text: NSAttributedString) -> String {
        var html = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var run = escaped(text.attributedSubstring(from: range).string)
            if attributes[.backgroundColor] != nil { run = "<code>\(run)</code>" }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { run = "<strong>\(run)</strong>" }
                if traits.contains(.italic) { run = "<em>\(run)</em>" }
            }
            if let url = attributes[.link] as? URL, MarkdownExternalURLPolicy.externalWebURL(url) != nil {
                run = "<a href=\"\(escaped(url.absoluteString))\">\(run)</a>"
            }
            html += run
        }
        return html
    }

    private static func variables(_ theme: MarkdownPreviewTheme) -> String {
        let size = theme.fontSize.isFinite ? min(24, max(14, theme.fontSize)) : 16
        let codeSize = theme.codeFontSize.isFinite ? min(20, max(12, theme.codeFontSize)) : 13
        let radius = theme.radius.isFinite ? min(24, max(0, theme.radius)) : 8
        var pattern = "none", patternSize = "auto"
        if let marks = theme.pattern, marks.spacing.isFinite, marks.width.isFinite {
            let spacing = min(64, max(8, marks.spacing)), width = min(6, max(0.5, marks.width))
            let ink = color(marks.color)
            if marks.kind == "dots" {
                pattern = "radial-gradient(circle, \(ink) \(width / 2)px, transparent \(width / 2)px)"
            } else if marks.kind == "grid" || marks.kind == "diagonal_grid" || marks.kind == "perspective_grid" {
                let angle = marks.kind == "diagonal_grid" ? 45 : 0
                pattern = "linear-gradient(\(angle)deg, \(ink) \(width)px, transparent \(width)px),linear-gradient(\(angle + 90)deg, \(ink) \(width)px, transparent \(width)px)"
            }
            patternSize = "\(spacing)px \(spacing)px"
        }
        return """
        --ground:\(color(theme.background));--ink:\(color(theme.text));--secondary:\(color(theme.secondary));
        --panel:\(color(theme.panel));--accent:\(color(theme.accent));--border:\(color(theme.border));
        --font:\(fontFamily(theme.fontName));--code-font:\(fontFamily(theme.codeFontName));
        --size:\(size)px;--code-size:\(codeSize)px;--radius:\(radius)px;--pattern:\(pattern);--pattern-size:\(patternSize);
        """
    }

    private static func color(_ value: String) -> String {
        let digits = value.dropFirst()
        guard value.first == "#", [6, 8].contains(digits.count), digits.allSatisfy({ $0.isHexDigit }) else { return "currentColor" }
        return value
    }

    private static func fontFamily(_ value: String) -> String {
        if value == "-apple-system" { return value }
        let safe = value.filter { $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } }
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "<", with: "\\3c ")
        return "'\(safe)'"
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
