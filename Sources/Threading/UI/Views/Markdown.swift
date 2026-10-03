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
    /// `TerminalProfile`. `codeFont` stays code, here as everywhere.
    @MainActor
    static var assistant: MarkdownStyle {
        MarkdownStyle(
            font: Design.Typography.body(surface: .conversation),
            textColor: Design.Text.label,
            secondaryColor: Design.Text.secondary,
            codeFont: Design.Typography.inlineCode(),
            codeColor: Design.Text.label,
            codeBackground: Design.Surface.panel,
            linkColor: Design.Surface.accent,
            headingFont: Design.Typography.markdownHeading(
                from: Design.Typography.body(surface: .conversation), surface: .conversation
            )
        )
    }

    /// Provider reasoning uses the same Markdown vocabulary as the reply, but remains an aside.
    /// Parsing and presentation are separate decisions: markers carry structure while every ink
    /// role stays tertiary, so a bold summary does not compete with the answer it precedes.
    @MainActor
    static var thinking: MarkdownStyle {
        MarkdownStyle(
            font: Design.Typography.body(surface: .conversation),
            textColor: Design.Text.tertiary,
            secondaryColor: Design.Text.tertiary,
            codeFont: Design.Typography.inlineCode(),
            codeColor: Design.Text.tertiary,
            codeBackground: Design.Surface.panel,
            linkColor: Design.Text.tertiary,
            headingFont: Design.Typography.markdownHeading(
                from: Design.Typography.body(surface: .conversation), surface: .conversation
            )
        )
    }
}
