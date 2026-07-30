import AppKit

/// An account's pressure drawn as a ring, small enough to sit beside its name in a menu.
///
/// `5h 0% · 7d 90%` is four numbers and two window names, and choosing between three accounts
/// means reading twelve of them and holding the comparison in your head. A ring is read at a
/// glance and compares without arithmetic: the fullest ring is the busiest account, and the
/// colour says whether that matters. The numbers stay — they are the precise answer — but they
/// stop being the *only* answer.
///
/// Drawn rather than built from views because a 14pt menu-row mark should be one reusable image,
/// which is the same reason `ThemeSwatchImage` exists.
enum UsageRingImage {

    private enum Layout {
        static let size = NSSize(width: 14, height: 14)
        static let lineWidth: CGFloat = 2
        /// Below this the arc is a smudge rather than a reading, so it draws as an empty
        /// track — which is the honest picture of "barely used" anyway.
        static let minimumVisibleFraction = 0.02
    }

    /// The ring for the window that binds a session running `model` on this account, or nil when
    /// there is nothing to show — the same silence the toolbar pill keeps for an account with no
    /// usage source.
    ///
    /// With no model named it gauges the account's peak, which is the honest reading when the
    /// model is not yet part of the question. Naming one includes that model's own window, so a
    /// menu comparing logins compares the number each will actually stop at.
    static func make(for usage: AccountUsage, at now: Date = Date(), metering model: String? = nil) -> NSImage? {
        guard let window = usage.bindingWindow(at: now, metering: model),
              let fraction = window.fraction else {
            return nil
        }
        return make(fraction: fraction, tint: UsageSeverity.from(fraction: fraction).glyphColor)
    }

    static func make(fraction: Double, tint: NSColor) -> NSImage {
        let image = NSImage(size: Layout.size, flipped: false) { rect in
            let inset = Layout.lineWidth / 2
            let box = rect.insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: box.midX, y: box.midY)
            let radius = min(box.width, box.height) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = Layout.lineWidth
            Design.Text.quaternary.setStroke()
            track.stroke()

            guard fraction >= Layout.minimumVisibleFraction else { return true }

            // From twelve o'clock, clockwise — the same direction as the toolbar's gauge, so
            // the two read as one control rather than two conventions.
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - 360 * min(fraction, 1),
                clockwise: true
            )
            progress.lineWidth = Layout.lineWidth
            progress.lineCapStyle = .round
            tint.setStroke()
            progress.stroke()

            return true
        }

        // Not a template: the tint carries the severity, which a template would flatten to one
        // colour and lose the only thing the ring says beyond "how full".
        image.isTemplate = false
        return image
    }
}
