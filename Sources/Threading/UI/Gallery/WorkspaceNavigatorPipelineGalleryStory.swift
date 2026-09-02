import AppKit
import ThreadingExtensionKit

/// Deterministic, interactive gallery fixture kept beside the pipeline's public design views.
///
/// The real host owns filtering and virtualization. This story keeps that boundary: it supplies
/// a bounded set of already-realized rows, then uses the persistent search band's callback to
/// exercise the results view's in-place empty-state transition.
@MainActor
enum WorkspaceNavigatorPipelineGalleryStory {
    private static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 42

    static func makeView() -> NSView {
        let releaseTitle = L10n.string("Release build")
        let browserTitle = L10n.string("Browser checks")
        let themeTitle = L10n.string("Theme audit")
        let matchTitles = [releaseTitle, browserTitle, themeTitle]

        let search = WorkspaceNavigatorPipelineSearchBandView(frame: .zero)
        search.configure(
            placeholder: L10n.string("Filter sessions"),
            accessibilityLabel: L10n.string("Filter workspace sessions"),
            query: ""
        )
        search.setPresented(true)
        search.widthAnchor.constraint(equalToConstant: width).isActive = true

        let rows = NSStackView(views: [
            row(title: releaseTitle, detail: "Codex", status: .positive),
            row(title: browserTitle, detail: "Claude", status: .neutral),
            row(title: themeTitle, detail: "Grok", status: .warning),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.hairline
        for row in rows.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        let results = WorkspaceNavigatorPipelineResultsView(
            content: rows,
            overflowText: L10n.string("2 more sessions are not shown")
        )
        results.widthAnchor.constraint(equalToConstant: width).isActive = true

        // A standing empty specimen keeps the placeholder visible while the populated result is
        // still available for comparison. Typing a query with no match also transitions the
        // populated instance in place, proving that the search field itself is not rebuilt.
        let emptyResults = WorkspaceNavigatorPipelineResultsView(
            content: NSView(),
            overflowText: nil
        )
        emptyResults.setEmptyState(
            title: L10n.string("No matching sessions"),
            detail: L10n.string("Try a broader workspace filter.")
        )
        emptyResults.widthAnchor.constraint(equalToConstant: width).isActive = true
        emptyResults.heightAnchor.constraint(equalToConstant: 92).isActive = true

        search.onQueryChange = { [weak results] query in
            let hasMatch = query.isEmpty
                || matchTitles.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
            results?.setEmptyState(
                title: hasMatch ? nil : L10n.string("No matching sessions"),
                detail: hasMatch ? nil : L10n.string("Try a broader workspace filter.")
            )
        }

        let stack = NSStackView(views: [search, results, emptyResults])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        return stack
    }

    private static func row(
        title: String,
        detail: String,
        status: ExtensionStatusRole
    ) -> WorkspaceNavigatorPipelineTemplateView {
        let node = WorkspaceNavigatorRealizedTemplateNode.stack(
            axis: .horizontal,
            spacing: .small,
            children: [
                .text(title, role: .compactBody),
                .text(detail, role: .compactDetail),
                .flexibleSpacer,
                .status(
                    status == .positive ? L10n.string("Ready") : L10n.string("Working"),
                    role: status
                ),
            ]
        )
        let view = WorkspaceNavigatorPipelineTemplateView(node: node) { _ in nil }
        view.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        return view
    }
}
