import AppKit

final class ThemedMenuSeparatorView: NSView, ThemedComponent {
    override func draw(_ dirtyRect: NSRect) {
        if ThemedMenuMetrics.appearance == .platinum {
            let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
            let shadowY = isFlipped ? bounds.minY : bounds.maxY - 1
            let highlightY = isFlipped ? bounds.minY + 1 : bounds.maxY - 2
            NSColor(srgbRed: 136 / 255, green: 136 / 255, blue: 136 / 255, alpha: 1)
                .setFill()
            NSRect(x: bounds.minX, y: shadowY, width: bounds.width, height: 1).fill()
            Design.Surface.bevelHighlight.setFill()
            NSRect(x: bounds.minX, y: highlightY, width: bounds.width, height: 1).fill()
            return
        }
        // Inset to the rows' own content padding, so the rule reads as part of the column
        // of text it divides rather than a wall-to-wall strut.
        let rect = NSRect(
            x: ThemedMenuMetrics.contentInset,
            y: bounds.midY - Design.Radius.border / 2,
            width: max(0, bounds.width - ThemedMenuMetrics.contentInset * 2),
            height: Design.Radius.border
        )
        if ThemedMenuMetrics.usesClassicGrammar {
            // Win32's separator is an etched pair: BTNSHADOW followed by BTNHIGHLIGHT. A single
            // translucent divider reads like a modern list rule against the flat button face.
            Design.Surface.bevelShadow.setFill()
            rect.fill()
            Design.Surface.bevelHighlight.setFill()
            rect.offsetBy(dx: 0, dy: 1).fill()
        } else {
            Design.Surface.divider.setFill()
            rect.fill()
        }
    }
}
