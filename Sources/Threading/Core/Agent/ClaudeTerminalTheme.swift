import Foundation

// MARK: - Claude Terminal Theme

/// Which of Claude's own UI themes a terminal session launches with, so its TUI draws in the
/// session's terminal palette instead of over it.
///
/// Claude's ordinary themes — `auto` (its shipped default), `dark`, `light` and the
/// colour-blind pair — paint every accent, border and diff in fixed 24-bit colours. The
/// terminal palette then reaches only the ground and plain text, so the palette an app theme
/// pairs with its chrome never touches the program that fills the terminal. Claude's two
/// "ANSI colors only" themes draw in the sixteen palette slots instead. Measured against CLI
/// 2.1.287 in a PTY: under `auto` and `dark` its opening screen carries `38;2;…` foregrounds
/// and no sixteen-colour ones; under `dark-ansi` and `light-ansi`, the reverse.
///
/// The variant is chosen by the same paper-or-ink test `TerminalTheme.colorFGBG` reports, from
/// the palette the session's terminal actually draws with, and stated in the per-session
/// `--settings` file — which outranks the account's own `theme` without editing it — while
/// `AppSettings.agentsUseTerminalPalette` is on. Its colours then follow every later palette
/// change live, because the TUI names slots rather than colours; only the dark-or-light choice
/// of slots waits for the next launch or resume.
enum ClaudeTerminalTheme {

    /// Claude's settings key for its UI theme.
    static let settingsKey = "theme"
    static let darkANSI = "dark-ansi"
    static let lightANSI = "light-ansi"

    /// The ANSI theme for a terminal drawing with `palette`.
    static func ansi(for palette: TerminalTheme) -> String {
        palette.hasDarkBackground ? darkANSI : lightANSI
    }
}
