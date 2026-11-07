import AppKit

// MARK: - Settings Page Root View

/// A settings page's root view, which a search can ask to bring a folded row on screen.
///
/// A page that folds rows away — a disclosure card whose detail rows exist only while it is open
/// — still owes the settings search every row its catalogue names. The page answers through
/// `onPrepareToReveal`, and this view adopts `SettingsRowRevealing` beside that protocol, so a
/// page needs no view subclass of its own to take part. The Tools, Keyboard and Extensions pages
/// each grew a private one before this existed.
final class SettingsPageRootView: NSView {
    /// Brings the row `title` names onto the page, and says whether anything changed.
    var onPrepareToReveal: ((String) -> Bool)?
}
