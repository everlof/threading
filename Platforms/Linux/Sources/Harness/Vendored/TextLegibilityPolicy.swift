import Foundation

/// Existing text-legibility budgets, shared without importing AppKit or theme state.
///
/// Mac APIs retain their names as aliases. Platform adapters pass these values to NeutralInk;
/// a renderer must not restate them or promote the terminal floor to the chrome's body-text one.
enum TextLegibilityPolicy {
    /// WCAG AA body text, used for chrome that is read and selected-row titles.
    static let readingRatio: CGFloat = 4.5

    /// WCAG AA large text, also the existing floor for an authored terminal palette.
    static let glanceRatio: CGFloat = 3.0

    /// Alpha increments when a quiet text rung needs more strength.
    /// Other 24-step algorithms retain their own independent policy names.
    static let strengthSteps = 24
}
