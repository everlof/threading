import AppKit
import ThreadingMarkdownKit

// MARK: - Markdown Defaults

enum MarkdownDefaults {
    static let codeFontSize: CGFloat = 12
    static let headingBump: CGFloat = 3
    /// A code block's inset from its plate. `inset` rather than a tight 8: with the prose at
    /// its reading leading, code pressed to its plate's edge read as the denser of the two.
    @MainActor static var codePadding: CGFloat { Design.Spacing.inset }
    static let listIndent: CGFloat = 18
    /// The conversation's answer rhythm, so a document's blocks and an answer split into rows
    /// are spaced by one token — see `Design.Chat.Rhythm`.
    @MainActor static var blockSpacing: CGFloat { Design.Chat.blockSpacing }
    static let quoteBarWidth: CGFloat = 2
    static let tableColumnWidth: CGFloat = 180

    /// AppKit work a single markdown surface may materialize at once. The source document stays
    /// complete and the pager reaches every block; these are view/constraint budgets, not content
    /// truncation limits.
    static let maximumBlocksPerPage = 48
    static let maximumSourceLinesPerPage = 96
    static let maximumListItemsPerPage = 64
    static let maximumTableRowsPerPage = 48
    static let maximumTableColumnsPerPage = 8
    /// Recursion and repeated grapheme materialization allowed within one provider-authored line.
    static let maximumInlineNestingDepth = MarkdownParsingLimits.maximumInlineNestingDepth
}
