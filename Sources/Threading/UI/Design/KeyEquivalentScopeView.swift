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

    /// Answers `true` when it handled the chord. Only consulted while this scope owns focus.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    /// A related control outside the content tree, such as the tab that selects this pane.
    /// Weak ownership lets a moved or removed tab stop participating without retaining its strip.
    weak var additionalKeyboardFocusOwner: NSView?

    /// Whether the window's first responder belongs to this view or its related control.
    /// Editing a text field hands focus to the shared field editor, counted by its delegate.
    var containsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        let focusedView: NSView?
        if let editor = responder as? NSText, let owner = editor.delegate as? NSView {
            focusedView = owner
        } else {
            focusedView = responder as? NSView
        }
        guard let focusedView else { return false }
        if focusedView === self || focusedView.isDescendant(of: self) { return true }
        guard let owner = additionalKeyboardFocusOwner, owner.window === window else { return false }
        return focusedView === owner || focusedView.isDescendant(of: owner)
    }

    // MARK: - Key Equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if containsKeyboardFocus, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
