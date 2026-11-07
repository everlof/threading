import SwiftUI
import ThreadingMarkdownModel

// MARK: - Markdown

/// Agent-written Markdown on the phone: a workroom question, its background and evidence, and the
/// agent's messages, drawn the way the agent's terminal draws them — emphasis, highlighted code,
/// headings, lists, quotes and tables — in the app's theme.
///
/// It reads `MarkdownDocument`, the model the workroom portal draws as HTML, so the phone and the
/// web page cannot disagree about what a question says. A wide table or code block scrolls
/// sideways inside the page instead of widening it, and only a web URL becomes a link. What a
/// person writes is never passed through here: it is shown as typed.
struct MobileMarkdownView: View {
    @Environment(\.remoteTheme) private var theme
    let text: String
    var font: Font = .body
    /// Off only where the whole table has to be drawn at once — a rendering test.
    var scrollsTables = true

    init(_ text: String, font: Font = .body, scrollsTables: Bool = true) {
        self.text = text
        self.font = font
        self.scrollsTables = scrollsTables
    }

    var body: some View {
        let document = MobileMarkdownCache.document(for: text)
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: MarkdownBlockNode) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(attributed(runs)).font(font).textSelection(.enabled)
        case .heading(let level, let runs):
            Text(attributed(runs))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, MobileDesign.Spacing.tight)
        case .bullets(let items):
            list(items.map { (MobileMarkdownDefaults.bullet, $0) })
        case .ordered(let start, let items):
            list(items.enumerated().map { ("\(start + $0.offset).", $0.element) })
        case .quote(let runs):
            HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                RoundedRectangle(cornerRadius: MobileMarkdownDefaults.quoteBarWidth / 2, style: .continuous)
                    .fill(theme.divider)
                    .frame(width: MobileMarkdownDefaults.quoteBarWidth)
                Text(attributed(runs)).font(font).foregroundStyle(theme.secondaryLabel).textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(theme.label)
                    .textSelection(.enabled)
                    .padding(MobileDesign.Spacing.medium)
            }
            .modifier(MobileHardScrollEdges())
            .background(theme.controlResting, in: RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
        case .table(let table):
            tableView(table)
        case .rule:
            Divider().overlay(theme.divider)
        }
    }

    private func list(_ items: [(marker: String, runs: [MarkdownInline])]) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: MobileDesign.Spacing.small) {
                    Text(verbatim: item.marker)
                        .font(font.monospacedDigit())
                        .foregroundStyle(theme.secondaryLabel)
                    Text(attributed(item.runs)).font(font).textSelection(.enabled)
                }
            }
        }
    }

    /// A header band, banded rows and a rule between columns, as a terminal table reads, scrolling
    /// sideways inside the page. A long cell wraps at a readable width instead of making the table
    /// a screen wide per word, and each column keeps the alignment its separator row asked for.
    @ViewBuilder
    private func tableView(_ table: MarkdownTableNode) -> some View {
        if scrollsTables {
            ScrollView(.horizontal, showsIndicators: true) { tableGrid(table) }
                .modifier(MobileHardScrollEdges())
        } else {
            tableGrid(table)
        }
    }

    private func tableGrid(_ table: MarkdownTableNode) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    cell(header, table: table, column: column, row: nil)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                        cell(value, table: table, column: column, row: index)
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(theme.border, lineWidth: 1))
    }

    /// `row` is nil for the header.
    private func cell(_ runs: [MarkdownInline], table: MarkdownTableNode, column: Int, row: Int?) -> some View {
        let alignment = alignment(table, column)
        let frame = Alignment(horizontal: alignment, vertical: .top)
        let band: Color = row.map { $0.isMultiple(of: 2) ? Color.clear : theme.controlResting } ?? theme.controlHover
        return MobileReadableWidth(maximum: MobileMarkdownDefaults.cellReadableWidth) {
            Text(attributed(runs))
                .font(row == nil ? .subheadline.weight(.semibold) : .subheadline.monospacedDigit())
                .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, MobileDesign.Spacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frame)
        .background(band)
        .overlay(alignment: .leading) {
            if column > 0 { Rectangle().fill(theme.border).frame(width: 1) }
        }
        .overlay(alignment: .bottom) {
            if row == nil { Rectangle().fill(theme.border).frame(height: 1) }
        }
        .gridColumnAlignment(alignment)
    }

    private func alignment(_ table: MarkdownTableNode, _ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    // MARK: Inline

    private func attributed(_ runs: [MarkdownInline]) -> AttributedString {
        var result = AttributedString()
        append(runs, to: &result, intent: [])
        return result
    }

    private func append(_ runs: [MarkdownInline], to result: inout AttributedString, intent: InlinePresentationIntent,
                        link: URL? = nil) {
        for run in runs {
            switch run {
            case .text(let text):
                result += piece(text, intent: intent, link: link)
            case .code(let code):
                // As a terminal sets inline code apart: its own face and ink on a chip.
                var span = piece(code, intent: intent.union(.code), link: link)
                span.backgroundColor = theme.controlResting
                if link == nil { span.foregroundColor = theme.accent }
                result += span
            case .strong(let inner):
                append(inner, to: &result, intent: intent.union(.stronglyEmphasized), link: link)
            case .emphasis(let inner):
                append(inner, to: &result, intent: intent.union(.emphasized), link: link)
            case .strikethrough(let inner):
                append(inner, to: &result, intent: intent.union(.strikethrough), link: link)
            case .lineBreak:
                result += AttributedString("\n")
            case let .link(label, url):
                append(label, to: &result, intent: intent, link: MarkdownLinkPolicy.webURL(url) ?? link)
            }
        }
    }

    private func piece(_ text: String, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        var span = AttributedString(text)
        if !intent.isEmpty { span.inlinePresentationIntent = intent }
        if let link {
            span.link = link
            span.foregroundColor = theme.accent
            span.underlineStyle = .single
        }
        return span
    }
}

// MARK: - Scroll Edges

/// A table's bands and a code block's chip run to their edges. iOS 26 softens what scrolls
/// sideways under an edge, which rounded every band where it met the scroll view's side.
private struct MobileHardScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .horizontal)
        } else {
            content
        }
    }
}

// MARK: - Readable Width

/// Lays its content out no wider than `maximum`, and measures it at that width.
///
/// A table scrolls sideways, so its cells are asked for their size with no width to keep to. A
/// `frame(maxWidth:)` would narrow the cell but report the height of the text on one line, and
/// the grid would then place the next row over the wrapped second line. This measures the text
/// at the width it will be drawn at, so a wrapped cell makes its row as tall as it needs.
struct MobileReadableWidth: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: width(for: proposal, content), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: min(bounds.width, maximum), height: nil))
    }

    /// The width it would take on one line, the width offered, or `maximum`, whichever is least.
    private func width(for proposal: ProposedViewSize, _ content: LayoutSubview) -> CGFloat {
        let ideal = content.sizeThatFits(.unspecified).width
        return min(ideal, proposal.width ?? ideal, maximum)
    }
}

// MARK: - Cache

/// Parsed documents by their text, so a screen that redraws — a poll, a keystroke in the
/// composer — does not read the same question again. Bounded by count; workroom texts are at
/// most a few KiB each.
@MainActor
enum MobileMarkdownCache {
    private static var documents: [String: MarkdownDocument] = [:]
    private static var order: [String] = []

    static func document(for text: String) -> MarkdownDocument {
        if let cached = documents[text] { return cached }
        let document = MarkdownDocument(parsing: text)
        documents[text] = document
        order.append(text)
        if order.count > MobileMarkdownDefaults.cachedDocuments {
            documents[order.removeFirst()] = nil
        }
        return document
    }
}

enum MobileMarkdownDefaults {
    static let bullet = "•" // localization-ignore: a list marker, not copy
    static let quoteBarWidth: CGFloat = 3
    static let cachedDocuments = 64
    /// Wider than a phone's half, so a short table stays on one line per row, and narrow enough
    /// that a long explanation wraps instead of scrolling a sentence off the screen.
    static let cellReadableWidth: CGFloat = 240
}

// MARK: - Links in Safari

extension View {
    /// Opens a tapped web link in Safari inside the app, so reading a source does not leave the
    /// question; anything else goes to the system as usual.
    func opensWebLinksInApp() -> some View {
        modifier(MobileInAppSafariLinks())
    }
}

private struct MobileInAppSafariLinks: ViewModifier {
    private struct Page: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @State private var page: Page?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard MarkdownLinkPolicy.webURL(url.absoluteString) != nil else { return .systemAction }
                page = Page(url: url)
                return .handled
            })
            .fullScreenCover(item: $page) { page in
                MobileSystemBrowser(url: page.url).ignoresSafeArea()
            }
    }
}
