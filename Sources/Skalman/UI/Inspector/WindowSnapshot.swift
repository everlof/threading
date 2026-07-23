import AppKit

/// Captures the window as an image, draws the inspector's marker onto it, and lands it in
/// the temporary directory as a PNG.
///
/// `cacheDisplay` on our own view tree, deliberately not ScreenCaptureKit: capturing views
/// the app owns needs no Screen Recording permission, and no other window can leak into the
/// shot. The cost is honesty about out-of-process content — a `WKWebView`'s page may render
/// blank. The overlay is a child window, so it is never in this tree; the marker is drawn
/// onto the bitmap instead.
enum WindowSnapshot {

    /// Captures from the window's frame view rather than `contentView`, so the toolbar is in
    /// the shot. The indicator is in window coordinates, which are also the frame view's —
    /// `cacheDisplay` renders the tree upright, so window space maps straight onto the
    /// unflipped bitmap context.
    static func capture(window: NSWindow, annotating indicator: InspectorIndicator?) -> NSBitmapImageRep? {
        guard let contentView = window.contentView else { return nil }
        let frameView = contentView.superview ?? contentView
        let bounds = frameView.bounds

        guard bounds.width > 0, bounds.height > 0,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }

        frameView.cacheDisplay(in: bounds, to: rep)

        // Points, not pixels: this is what keeps the PNG tagged with its real scale and what
        // sizes the `NSImage` the sheet previews.
        rep.size = bounds.size

        if let indicator {
            annotate(rep, with: indicator, within: bounds)
        }

        return rep
    }

    private static func annotate(
        _ rep: NSBitmapImageRep,
        with indicator: InspectorIndicator,
        within bounds: NSRect
    ) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // No scale transform, deliberately: the context speaks the rep's `size` units — the
        // point space set above — and maps them onto the backing pixels itself. Scaling here
        // as well drew every marker displaced and doubled on retina. Measured, and pinned by
        // `testBitmapContextSpeaksTheRepsSizeUnits`.
        InspectorIndicatorDrawing.draw(indicator, within: bounds)

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Written to the temporary directory: a report is an ephemeral thing made to be pasted
    /// into a chat within the minute. The timestamped name says which capture is which when
    /// several accumulate.
    static func writePNG(_ rep: NSBitmapImageRep) -> URL? {
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }

        let name = InspectorDefaults.screenshotPrefix + Self.timestamp.string(from: Date()) + ".png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        // Pinned, or the filename inherits the user's numerals and calendar — a Buddhist-era
        // year is a valid path and a wrong name.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
