import AppKit
import SkalmanDiffAppKit
import SkalmanDiffCore

/// Skalman's theme/default adapter around the package renderer.
///
/// Git loading, staging and app theming stay in the app. The actual line rendering, syntax
/// highlighting, wrapping and sizing live in SkalmanDiffKit and are shared with the UIKit view.
final class DiffView: DiffAppKitView {
    convenience init(lines: [DiffLine], path: String? = nil, wraps: Bool = true) {
        self.init(
            lines: lines,
            path: path,
            configuration: .init(
                displayCap: DiffDefaults.displayCap,
                showsNumbers: false,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .skalman
        )
    }

    convenience init(
        gitLines: [GitDiffLine],
        displayCap: Int,
        path: String? = nil,
        wraps: Bool = true
    ) {
        self.init(
            lines: gitLines,
            path: path,
            configuration: .init(
                displayCap: displayCap,
                showsNumbers: true,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .skalman
        )
    }
}

private extension DiffAppKitTheme {
    static var skalman: DiffAppKitTheme {
        DiffAppKitTheme(
            font: Design.Typography.code(),
            label: Design.Text.label,
            secondaryLabel: Design.Text.secondary,
            tertiaryLabel: Design.Text.tertiary,
            added: Design.Diff.added,
            removed: Design.Diff.removed,
            addedBackground: Design.Diff.added.withAlphaComponent(DiffDefaults.addedAlpha),
            removedBackground: Design.Diff.removed.withAlphaComponent(DiffDefaults.removedAlpha),
            syntaxKeyword: Design.Syntax.keyword,
            syntaxType: Design.Syntax.type,
            syntaxString: Design.Syntax.string,
            syntaxNumber: Design.Syntax.number,
            syntaxComment: Design.Syntax.comment
        )
    }
}
