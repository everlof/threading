import Foundation

/// Receives the host's theme and puts it in force for this process's copy of the design system.
///
/// The host and a plugin each compile their own `AppTheme`, so the value cannot simply be passed:
/// they are the same source but two types in two binaries. It travels encoded instead, which is
/// exact rather than approximate — every colour, radius, bevel and font arrives, not the handful a
/// token payload could name.
///
/// A plugin calls this from `apply(theme:)`, which the host invokes once after the pane is built
/// and again on every live theme change.
public enum HostThemeHandoff {

    public enum Failure: Error {
        /// The host had no theme to send. The stock theme stays in force; drawing continues.
        case absent
        /// The payload did not decode as a theme this build understands.
        case unreadable(underlying: Error)
    }

    /// Encodes the theme currently in force, for a host to hand over.
    public static func encodeCurrent() throws -> Data {
        try JSONEncoder().encode(AppThemePalette.current)
    }

    /// Puts an encoded theme in force. Returns the theme installed, so a caller can log which one.
    @discardableResult
    public static func install(encoded: Data?) throws -> AppTheme {
        guard let encoded else { throw Failure.absent }
        do {
            let theme = try JSONDecoder().decode(AppTheme.self, from: encoded)
            AppThemePalette.install(theme)
            return theme
        } catch {
            throw Failure.unreadable(underlying: error)
        }
    }
}
