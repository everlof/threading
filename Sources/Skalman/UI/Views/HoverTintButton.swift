import AppKit

/// Borderless footer button that brightens under the pointer, so it reads as interactive
/// without carrying a bezel. Used by the sidebar's footer controls.
final class HoverTintButton: NSButton {

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Also tint the *title*, for the buttons that are text rather than a symbol.
    ///
    /// `contentTintColor` colours a template image and leaves a title at full strength, which
    /// is how a quiet action ends up as loud as the content it sits beside. Setting this
    /// applies the resting tint at once, so the button starts quiet.
    var tintsTitle = false {
        didSet { applyTint(Design.Text.secondary) }
    }

    override func mouseEntered(with event: NSEvent) {
        applyTint(Design.Text.label)
    }

    override func mouseExited(with event: NSEvent) {
        applyTint(Design.Text.secondary)
    }

    private func applyTint(_ color: NSColor) {
        contentTintColor = color

        guard tintsTitle, !title.isEmpty else { return }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
    }
}
