import AppKit

/// A structural container whose chords apply only while keyboard focus is inside it.
///
/// AppKit offers a key equivalent to every view in the key window — focused or not — before it
/// reaches the main menu. That is what lets a pane answer a chord the app already binds (⌘R in a
/// browser reloads, where everywhere else it renames the session), and also why the pane has to
/// check focus itself: without it, a browser merely *on screen* would take ⌘R from a terminal the
/// person is typing in.
///
/// It draws nothing and chooses no styling, so it is not a themed component; the pane that owns
/// it applies its own surface.
final class KeyEquivalentScopeView: NSView {

    // MARK: - Properties

    /// Answers `true` when it handled the chord. Only consulted while focus is inside this view.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    /// Whether the window's first responder is this view or lives inside it. A text field being
    /// edited hands focus to the window's shared field editor, which is counted by its delegate.
    var containsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            return owner === self || owner.isDescendant(of: self)
        }
        guard let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }

    // MARK: - Key Equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if containsKeyboardFocus, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
