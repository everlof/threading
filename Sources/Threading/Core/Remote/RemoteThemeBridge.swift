import AppKit
import ThreadingRemoteKit

/// Turns the Mac's resolved theme state into platform-neutral wire values.
///
/// Remote clients intentionally receive resolved colours, not a variant document. Custom themes
/// exist only on this Mac, and adaptive themes may change variant with its appearance; resolving
/// here makes both portable while preserving session/project terminal overrides.
@MainActor
enum RemoteThemeBridge {

    static func appTheme() -> RemoteThemeDTO {
        appTheme(AppThemeLibrary.current)
    }

    static func catalog() -> RemoteThemeCatalogDTO {
        RemoteThemeCatalogDTO(
            appThemes: AppThemeLibrary.all.map(appTheme),
            terminalThemes: ThemeAssignments.selectableThemes.map(terminalTheme)
        )
    }

    /// The chrome block and the material's bevel are deliberately not projected: the remote
    /// client has no window frame to dress and no bevel interpreter, and a DTO field nothing
    /// renders is churn. The two bevel roles ride along in the resolved colour map like every
    /// role — harmless, and a future client that learns to bevel finds its colours waiting.
    static func appTheme(_ theme: AppTheme) -> RemoteThemeDTO {
        var colors: [String: String] = [:]
        var mode = theme.mode.rawValue
        var glowColor: String?
        var material = AppTheme.Material.system
        let appearance = drawingAppearance(for: theme)

        appearance.performAsCurrentDrawingAppearance {
            if theme.isAdaptive {
                mode = NSAppearance.currentDrawing()
                    .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? "dark"
                    : "light"
            }
            material = theme.variant(for: appearance)?.material ?? theme.material
            for role in AppThemeRole.allCases {
                var resolved = theme.resolved(role, appearance: appearance)
                // The Mac holds every rule to `Material.ruleInkBudget` at draw time
                // (`Design.Surface.divider`); remote clients draw their rules straight from
                // this value, so the projection carries the capped ink rather than each
                // client re-learning the budget.
                if role == .divider, let srgb = resolved.usingColorSpace(.sRGB) {
                    resolved = srgb.withAlphaComponent(
                        min(srgb.alphaComponent, material.ruleInkCeiling)
                    )
                }
                colors[role.wireName] = resolved.hexString
            }
            if let glow = material.glow {
                glowColor = theme.resolved(glow.role, appearance: appearance).hexString
            }
        }

        let glow = material.glow.flatMap { materialGlow in
            glowColor.map {
                RemoteThemeDTO.Material.Glow(
                    color: $0,
                    radius: Double(materialGlow.radius),
                    opacity: materialGlow.opacity,
                    offsetX: Double(materialGlow.offsetX),
                    offsetY: Double(materialGlow.offsetY)
                )
            }
        }
        return RemoteThemeDTO(
            id: theme.id.rawValue,
            name: theme.name,
            mode: mode,
            colors: colors,
            material: .init(
                panelRadius: Double(material.panelRadius),
                controlRadius: Double(material.controlRadius),
                borderWidth: Double(material.borderWidth),
                glow: glow,
                textScale: Double(material.textScale),
                typeface: material.typeface.rawValue,
                fontFamily: material.fontFamily
            )
        )
    }

    static func terminalTheme(for sessionID: SessionID) -> RemoteTerminalThemeDTO {
        terminalTheme(ThemeAssignments.theme(for: sessionID))
    }

    static func terminalTheme(_ theme: TerminalTheme) -> RemoteTerminalThemeDTO {
        return RemoteTerminalThemeDTO(
            id: theme.id.rawValue,
            name: theme.name,
            foreground: theme.foreground.hexString,
            background: theme.background.hexString,
            cursor: theme.cursor.hexString,
            selection: theme.selection.hexString,
            ansi: [
                theme.black, theme.red, theme.green, theme.yellow,
                theme.blue, theme.magenta, theme.cyan, theme.white,
                theme.brightBlack, theme.brightRed, theme.brightGreen, theme.brightYellow,
                theme.brightBlue, theme.brightMagenta, theme.brightCyan, theme.brightWhite,
            ].map(\.hexString)
        )
    }

    /// A fixed app theme pins `NSApp.appearance`; using that pinned appearance to preview an
    /// inactive adaptive choice would resolve the wrong variant. Read the user's global mode
    /// for adaptive catalogue entries unless one is already active.
    private static func drawingAppearance(for theme: AppTheme) -> NSAppearance {
        guard theme.isAdaptive else { return theme.mode.appearance ?? NSApp.effectiveAppearance }
        if AppThemeLibrary.current.isAdaptive { return NSApp.effectiveAppearance }
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
    }

    static func update(for sessionID: SessionID) -> RemoteThemeUpdateDTO {
        RemoteThemeUpdateDTO(
            theme: appTheme(),
            terminalTheme: terminalTheme(for: sessionID)
        )
    }
}
