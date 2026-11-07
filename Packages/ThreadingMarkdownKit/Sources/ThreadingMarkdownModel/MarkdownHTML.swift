import Foundation

// MARK: - Markdown HTML

/// A `MarkdownDocument` as an HTML fragment, for a page that shows agent-written text — the
/// workroom portal's questions and messages.
///
/// Everything from the text is escaped; the only markup is what the renderer writes. There is no
/// `style` attribute, so a strict content-security policy needs nothing more than the page's own
/// stylesheet, which styles the `md-` classes. Headings start at `h3`, under the page's own `h1`
/// and `h2`. A link exists only where `MarkdownLinkPolicy` allows the URL, and it opens in a new
/// tab without a referrer.
public enum MarkdownHTML {

    public static func render(_ document: MarkdownDocument) -> String {
        document.blocks.map(block).joined()
    }

    public static func render(markdown: String) -> String {
        render(MarkdownDocument(parsing: markdown))
    }

    private static func block(_ block: MarkdownBlockNode) -> String {
        switch block {
        case .paragraph(let runs):
            return "<p>\(inline(runs))</p>"
        case .heading(let level, let runs):
            let tag = "h\(min(6, level + 2))"
            return "<\(tag) class=\"md-heading\">\(inline(runs))</\(tag)>"
        case .bullets(let items):
            return "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
        case .ordered(let start, let items):
            let attribute = start == 1 ? "" : " start=\"\(start)\""
            return "<ol\(attribute)>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ol>"
        case .quote(let runs):
            return "<blockquote>\(inline(runs))</blockquote>"
        case .code(let language, let text):
            let label = language.isEmpty ? "" : " data-language=\"\(escape(language))\""
            return "<pre class=\"md-code\"\(label)><code>\(escape(text))</code></pre>"
        case .table(let table):
            return self.table(table)
        case .rule:
            return "<hr>"
        }
    }

    /// Wrapped so a wide table scrolls sideways inside the page instead of widening it.
    private static func table(_ table: MarkdownTableNode) -> String {
        func cell(_ tag: String, _ runs: [MarkdownInline], _ column: Int) -> String {
            let alignment = column < table.alignments.count ? table.alignments[column] : .leading
            let attribute: String
            switch alignment {
            case .leading: attribute = ""
            case .center: attribute = " class=\"md-center\""
            case .trailing: attribute = " class=\"md-trailing\""
            }
            return "<\(tag)\(attribute)>\(inline(runs))</\(tag)>"
        }
        let head = table.headers.enumerated().map { cell("th", $0.element, $0.offset) }.joined()
        let body = table.rows.map { row in
            "<tr>" + row.enumerated().map { cell("td", $0.element, $0.offset) }.joined() + "</tr>"
        }.joined()
        return "<div class=\"md-table\"><table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table></div>"
    }

    private static func inline(_ runs: [MarkdownInline]) -> String {
        runs.map { run in
            switch run {
            case .text(let text): return escape(text)
            case .code(let code): return "<code>\(escape(code))</code>"
            case .strong(let inner): return "<strong>\(inline(inner))</strong>"
            case .emphasis(let inner): return "<em>\(inline(inner))</em>"
            case .strikethrough(let inner): return "<del>\(inline(inner))</del>"
            case .lineBreak: return "<br>"
            case .link(let label, let url):
                guard let target = MarkdownLinkPolicy.webURL(url) else { return inline(label) }
                return "<a href=\"\(escape(target.absoluteString))\" rel=\"noopener noreferrer nofollow\" target=\"_blank\">"
                    + inline(label) + "</a>"
            }
        }.joined()
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
