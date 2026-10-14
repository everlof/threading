import AppKit
@_exported import ThreadingMarkdownKit

typealias Markdown = ThreadingMarkdownKit.Markdown
typealias MarkdownStyle = ThreadingMarkdownKit.MarkdownStyle
typealias MarkdownBlock = ThreadingMarkdownKit.MarkdownBlock
typealias MarkdownTable = ThreadingMarkdownKit.MarkdownTable

// MARK: - Markdown Style

/// The fonts and colours a rendered document draws with.
///
/// Passed in rather than read from `Design` directly, so the same renderer can draw an
/// assistant message in full colour and a quieter thing — a quoted reply, a tool note — by
/// handing it a dimmer palette.
extension MarkdownStyle {
    /// The agent's prose, and the one place the conversation's own font is chosen for it.
    ///
    /// `.conversation` rather than `.chrome`: this is the transcript, which the reader may want
    /// set differently from the app around it — the same say the terminal has always had through
    /// `TerminalProfile`. `codeFont` stays code, here as everywhere, at the reading size's step.
    @MainActor
    static var assistant: MarkdownStyle {
        reading(
            textColor: Design.Text.label,
            secondaryColor: Design.Text.secondary,
            codeColor: Design.Text.label,
            linkColor: Design.Surface.accent
        )
    }

    /// Provider reasoning uses the same Markdown vocabulary as the reply, but remains an aside.
    /// Parsing and presentation are separate decisions: markers carry structure while every ink
    /// role stays tertiary, so a bold summary does not compete with the answer it precedes.
    @MainActor
    static var thinking: MarkdownStyle {
        reading(
            textColor: Design.Text.tertiary,
            secondaryColor: Design.Text.tertiary,
            codeColor: Design.Text.tertiary,
            linkColor: Design.Text.tertiary
        )
    }

    /// The conversation's reading face and leading, which only the inks vary between: a reply
    /// and its reasoning are set alike so neither changes shape when the other is beside it.
    @MainActor
    private static func reading(
        textColor: NSColor,
        secondaryColor: NSColor,
        codeColor: NSColor,
        linkColor: NSColor
    ) -> MarkdownStyle {
        let body = Design.Typography.reading()
        let code = Design.Typography.readingCode()
        return MarkdownStyle(
            font: body,
            textColor: textColor,
            secondaryColor: secondaryColor,
            codeFont: code,
            codeColor: codeColor,
            codeBackground: Design.Surface.panel,
            linkColor: linkColor,
            headingFont: Design.Typography.markdownHeading(from: body, surface: .conversation),
            lineSpacing: Design.Chat.lineSpacing(for: body, multiple: Design.Chat.readingLineHeight),
            codeLineSpacing: Design.Chat.lineSpacing(for: code, multiple: Design.Chat.codeLineHeight)
        )
    }
}

// MARK: - Plain Text

/// A rendered document as the reader sees it, without its markers: what a selection copies for
/// a block that is not on screen to be read from.
///
/// Blocks are separated by a blank line, list items and table rows by a line break, table
/// cells by a tab — the same separators `TranscriptTextSegments` derives from the rows that are
/// on screen, so a copy reads the same whichever way each part of it was found.
enum MarkdownPlainText {
    @MainActor
    static func text(of source: String, style: MarkdownStyle) -> String {
        Markdown.parse(source, style: style).map(text(of:)).joined(separator: "\n\n")
    }

    static func text(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let text), .heading(let text), .quote(let text):
            return text.string
        case .bullets(let items), .ordered(let items):
            return items.map(\.string).joined(separator: "\n")
        case .code(let code):
            return code
        case .table(let table):
            let header = table.headers.map(\.string).joined(separator: "\t")
            let rows = table.rows.map { $0.map(\.string).joined(separator: "\t") }
            return ([header] + rows).joined(separator: "\n")
        }
    }
}
