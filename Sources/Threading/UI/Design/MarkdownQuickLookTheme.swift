import AppKit
import ThreadingMarkdownKit

/// The Design boundary resolves a read-only snapshot for the separately sandboxed preview.
@MainActor
enum MarkdownQuickLookTheme {
    static func snapshot() -> MarkdownPreviewThemes {
        MarkdownPreviewThemes(light: resolve(.aqua), dark: resolve(.darkAqua))
    }

    private static func resolve(_ name: NSAppearance.Name) -> MarkdownPreviewTheme {
        var snapshot = MarkdownPreviewTheme.system(dark: name == .darkAqua)
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            let font = Design.Typography.body(surface: .conversation)
            let codeFont = Design.Typography.inlineCode()
            let theme = AppThemePalette.current
            let appearance = NSAppearance.currentDrawing()
            let material = theme.material(for: appearance)
            let pattern = material.backdropPattern.map { marks in
                let ink = theme.resolved(marks.role, appearance: appearance).usingColorSpace(.sRGB) ?? .clear
                return MarkdownPreviewTheme.Pattern(
                    kind: marks.kind.rawValue,
                    color: ink.withAlphaComponent(ink.alphaComponent * marks.opacity).hexString,
                    spacing: Double(marks.spacing), width: Double(marks.lineWidth)
                )
            }
            snapshot = MarkdownPreviewTheme(
                background: Design.Surface.ground.hexString, text: Design.Text.label.hexString,
                secondary: Design.Text.secondary.hexString, panel: Design.Surface.panel.hexString,
                accent: Design.Surface.accent.hexString, border: Design.Surface.border.hexString,
                fontName: font.familyName ?? font.fontName, codeFontName: codeFont.familyName ?? codeFont.fontName,
                fontSize: max(16, Double(font.pointSize)), codeFontSize: max(13, Double(codeFont.pointSize)),
                radius: Double(Design.Radius.panel), pattern: pattern
            )
        }
        return snapshot
    }
}
