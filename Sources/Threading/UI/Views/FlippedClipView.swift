import AppKit

// MARK: - Flipped Clip View

/// Makes the scroll view fill from the top, so a short conversation sits under the toolbar
/// rather than floating at the bottom of the pane.
final class FlippedClipView: ThemedClipView {
    override var isFlipped: Bool { true }
}
