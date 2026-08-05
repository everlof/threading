import AppKit

/// Captures the window as an image, draws the inspector's marker onto it, and lands it in
/// the temporary directory as a PNG.
///
/// `cacheDisplay` on our own view tree, deliberately not ScreenCaptureKit: capturing views
/// the app owns needs no Screen Recording permission, and no other window can leak into the
/// shot. The cost is honesty about out-of-process content — a `WKWebView`'s page may render
/// blank. The overlay is a child window, so it is never in this tree; the marker is drawn
/// onto the bitmap instead.
@MainActor
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

        repaintMaterialPanes(in: rep, window: window, frameView: frameView)

        if let indicator {
            annotate(rep, with: indicator, within: bounds)
        }

        return rep
    }

    /// Supplies the ground a system-material pane draws on, which the capture cannot see.
    ///
    /// A `.sidebar` or `.inspector` split item's material is **not in the view tree** — measured
    /// on this macOS, a window built that way contains zero `NSVisualEffectView`s, and the region
    /// is painted for the window from outside the process. `cacheDisplay` therefore writes opaque
    /// *white* across the whole column, and the pane's own rows — light text, drawn correctly,
    /// on top — disappear into it. Every inspector report was shipping a screenshot with a blank
    /// band where the sidebar should be.
    ///
    /// So the ground is painted here from `WindowBackdrop`, which is the app's own record of what
    /// the window is painted with, and the pane is drawn over it again. Three things this got
    /// wrong first, each measured:
    ///
    /// - **The column, not the pane.** Under `.fullSizeContentView` such a pane runs the window's
    ///   full height with the traffic lights floating over it, so the strip *above* the pane is
    ///   missing its ground too and stayed white when only the pane was repainted.
    /// - **The traffic lights are not the pane's.** They live in the window's titlebar
    ///   container, so the fill covers them; redrawing that container restores them, and the clip
    ///   is what stops a window-wide view from touching the panes beside it.
    /// - **A bare `NSBitmapImageRep` draws as a copy**, which puts the pane's own transparency
    ///   straight back over the ground just painted for it. It goes through an `NSImage` and
    ///   `.sourceOver` instead.
    ///
    /// **The main window no longer has such a pane**: its sidebar is a plain split item painting
    /// its own opaque ground, so it captures correctly with no help — see
    /// `MainWindowController.setupSplitViewController`. This is kept because it is a property of
    /// `cacheDisplay` and system materials rather than of one window, and any pane that adopts a
    /// system material later would silently lose its ground in every report without it.
    private static func repaintMaterialPanes(
        in rep: NSBitmapImageRep,
        window: NSWindow,
        frameView: NSView
    ) {
        let sidebars = (window.contentViewController as? NSSplitViewController)?
            .splitViewItems
            .filter { $0.behavior == .sidebar && !$0.isCollapsed }
            .map(\.viewController.view) ?? []

        guard !sidebars.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let titlebar = window.standardWindowButton(.closeButton)?.superview

        for sidebar in sidebars {
            let pane = sidebar.convert(sidebar.bounds, to: frameView)
            guard pane.width > 0, pane.height > 0 else { continue }

            let column = NSRect(
                x: pane.minX,
                y: pane.minY,
                width: pane.width,
                height: frameView.bounds.maxY - pane.minY
            )

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: column).setClip()

            WindowBackdrop.color.setFill()
            column.fill()

            draw(sidebar, at: pane)
            if let titlebar {
                draw(titlebar, at: titlebar.convert(titlebar.bounds, to: frameView))
            }

            NSGraphicsContext.restoreGraphicsState()
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(_ view: NSView, at rect: NSRect) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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
        //
        // No hint: the colour key is evidence the report's text refers to, the keyboard hint is
        // an instruction for an overlay nobody reading the filed issue can still see.
        InspectorIndicatorDrawing.draw(indicator, within: bounds, showingHint: false)

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
