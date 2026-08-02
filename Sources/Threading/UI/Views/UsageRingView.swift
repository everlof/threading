import AppKit

/// A small circular gauge: a quiet full track with the spent fraction drawn over it.
///
/// Its own file because it is drawn on **two different grounds**: the toolbar pill floats on the
/// window's backdrop and hands it ink from there, while the usage popover and the composer sit on
/// the chrome and leave the defaults alone. Keeping it out of `AccountUsageItemView.swift` is
/// also what lets the overlay rule read that file as a whole — see
/// `ThemedControlTests.testBackdropOverlaysDoNotReadChromeRoles`.
final class UsageRingView: NSView {

    // MARK: - Properties

    var fraction: Double? { didSet { needsDisplay = true } }
    var tint: NSColor = Design.Text.secondary { didSet { needsDisplay = true } }

    /// The unfilled part of the ring. Set by the pill from its backdrop ink rather than read
    /// from `Design`, since this sits on the same foreign ground the pill does.
    var trackColor: NSColor = Design.Text.quaternary { didSet { needsDisplay = true } }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth = AccountUsageItemDefaults.ringLineWidth
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath()
        track.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360
        )
        track.lineWidth = lineWidth
        trackColor.setStroke()
        track.stroke()

        guard let fraction, fraction > 0 else { return }

        // From twelve o'clock, clockwise, like every gauge the user already reads.
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - 360 * min(fraction, 1),
            clockwise: true
        )
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        tint.setStroke()
        progress.stroke()
    }
}

// MARK: - Account Usage Item Defaults

enum AccountUsageItemDefaults {
    static let height: CGFloat = 20
    static let horizontalPadding: CGFloat = 8
    static let ringSize: CGFloat = 12
    static let ringLineWidth: CGFloat = 1.5

    /// Shown when a window's percentage is unknown, e.g. after its reset has passed.
    static let unknownValue = "—"

    /// Between window segments in the pill's summary.
    static let segmentSeparator = " · "

    /// While the popover shows only the native reading: visible exactly while the pointer is
    /// on the pill — instant in, instant out, nothing in it to reach for.
    static let readingPopoverPolicy = HoverPopoverScheduler.Policy.whilePointerOnAnchor

    /// The moment an extension composes content into the popover it may carry actions, and a
    /// surface that closes as the pointer reaches for it cannot be operated: still instant to
    /// open, but with the same gap-crossing grace an extension's detail grants, held while
    /// the pointer rests on the popover.
    static let actionablePopoverPolicy = HoverPopoverScheduler.Policy(
        openDelay: 0,
        closeGrace: ExtensionDisclosureDefaults.popoverPolicy.closeGrace,
        holdsWhilePointerOnPopover: true
    )
}
