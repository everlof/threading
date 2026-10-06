import AppKit
import XCTest
@testable import Threading

/// The three process-wide values a theme change moves in the hosted app, captured together so a
/// test can put back — and prove it put back — exactly what it moved.
///
/// They have three owners. `AppThemeLibrary.current` is the installed theme;
/// `AppThemePalette.current` is what every themed colour resolves through; `NSApp.appearance` is
/// what the library pins from the installed theme's mode, and so the `effectiveAppearance` of
/// every window a later test builds. `AppThemePalette.set` moves the first alone and
/// `AppThemeLibrary.installResolved` moves all three, so a restore has to go back through the
/// owner the change went through, from a value read from that owner.
///
/// The bug this exists for crossed three classes. One test set the palette to a *light* theme
/// and left it there; the next captured that palette as "the old theme" and restored it through
/// the library, which installed it and pinned `NSApp.appearance` to Aqua; a third reset only the
/// palette. Every window built afterwards was Light under a Dark system, so the composer's
/// drop-affordance tests — which resolve their expected colours in the ambient Dark appearance —
/// failed several hundred tests away from the cause.
@MainActor
struct HostedThemeState {
    let theme: AppTheme
    let palette: AppTheme
    let appAppearance: NSAppearance?

    static func capture() -> HostedThemeState {
        HostedThemeState(
            theme: AppThemeLibrary.current,
            palette: AppThemePalette.current,
            appAppearance: NSApp.appearance
        )
    }

    /// Library first, because installing re-states the palette and the app appearance from the
    /// installed theme; the captured palette and appearance then go back exactly, even where they
    /// already disagreed with the library when they were captured.
    func restore() {
        AppThemeLibrary.installResolved(theme)
        AppThemePalette.set(palette)
        NSApp.appearance = appAppearance
    }

    /// Fails the calling test when any of the three is not what was captured.
    func assertUnchanged(by test: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            AppThemeLibrary.current == theme,
            "\(test) left the installed theme at \(AppThemeLibrary.current.id) (was \(theme.id))",
            file: file,
            line: line
        )
        XCTAssertTrue(
            AppThemePalette.current == palette,
            "\(test) left the palette at \(AppThemePalette.current.id) (was \(palette.id))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            NSApp.appearance?.name,
            appAppearance?.name,
            "\(test) left NSApp.appearance pinned, so every later window inherits it",
            file: file,
            line: line
        )
    }
}
