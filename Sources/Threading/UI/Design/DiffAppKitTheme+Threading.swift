import AppKit
import NativeDiffAppKit

@MainActor
extension DiffAppKitTheme {

    /// The renderer's theme, with every colour that depends on the ground resolved against the
    /// one this diff is actually drawn on — see `Design.Diff.on(_:)`.
    static func threading(on ground: NSColor = Design.Surface.ground) -> DiffAppKitTheme {
        let diff = Design.Diff.on(ground)

        return DiffAppKitTheme(
            font: Design.Typography.code(),
            label: Design.Text.label,
            secondaryLabel: Design.Text.secondary,
            tertiaryLabel: Design.Text.tertiary,
            // NativeDiffKit v0.1 has one changed-line colour for both the sign and the body.
            // Prefer the body — the semantic wash and the +/− shape still carry the change.
            added: diff.addedText,
            removed: diff.removedText,
            addedBackground: diff.addedWash,
            removedBackground: diff.removedWash,
            syntaxKeyword: Design.Syntax.keyword,
            syntaxType: Design.Syntax.type,
            syntaxString: Design.Syntax.string,
            syntaxNumber: Design.Syntax.number,
            syntaxComment: Design.Text.secondary
        )
    }
}
