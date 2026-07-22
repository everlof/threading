import AppKit
import ObjectiveC

// MARK: - Surface Recording

/// The tokens a view's layer was filled with, remembered so they can be applied again.
///
/// A `CALayer` resolves its `backgroundColor` to a `CGColor` at assignment and keeps that
/// value — measured, and the same trap that made the terminal's pane keep a stale colour. A
/// dynamic `NSColor` cannot help, because the layer never asks it again. So the view remembers
/// the `NSColor` *objects* it was given and re-reads `.cgColor` from them on a theme change,
/// which is where the dynamic provider runs a second time.
///
/// Recording the object rather than the role means this works for static colours too: a view
/// filled with a terminal theme's background re-applies the same value harmlessly.
private final class RecordedSurface {
    let fill: NSColor
    let border: NSColor?

    init(fill: NSColor, border: NSColor?) {
        self.fill = fill
        self.border = border
    }
}

private var recordedSurfaceKey: UInt8 = 0

extension NSView {

    fileprivate var recordedSurface: RecordedSurface? {
        get { objc_getAssociatedObject(self, &recordedSurfaceKey) as? RecordedSurface }
        set { objc_setAssociatedObject(self, &recordedSurfaceKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// Re-applies whatever `applySurface` last set, resolving its colours again.
    fileprivate func reapplyRecordedSurface() {
        guard let recorded = recordedSurface else { return }
        layer?.backgroundColor = recorded.fill.cgColor
        if let border = recorded.border { layer?.borderColor = border.cgColor }
    }

    /// Remembers the colours a surface was drawn with. Called by `applySurface`, so its
    /// eighteen call sites need no change of their own.
    func recordSurface(fill: NSColor, border: NSColor?) {
        recordedSurface = RecordedSurface(fill: fill, border: border)
    }

    /// The re-apply on its own, for the test that pins the `CGColor` freeze this exists to fix.
    /// The sweep itself needs a window, which a unit test has no business standing up.
    func reapplyRecordedSurfaceForTesting() {
        reapplyRecordedSurface()
    }
}

// MARK: - Refresh

/// Repaints what is already on screen after the app's theme changes.
///
/// Two different jobs, because the two halves of the app's colour fail differently:
///
/// - **Text, strokes and fills drawn in `draw(_:)`** resolve their colour every time they are
///   drawn, so marking the view dirty is the whole fix.
/// - **Layer background and border colours** were frozen at assignment and have to be set
///   again from the colours the view recorded.
///
/// A theme change is rare and this walk is cheap, so it is deliberately a full sweep rather
/// than a subscription every view has to remember to join — the failure mode of the latter is
/// one view in the corner keeping the old theme, which is exactly the kind of bug nobody
/// notices until a screenshot.
@MainActor
enum AppThemeRefresh {

    static func repaintEverything() {
        for window in NSApp.windows {
            window.appearance = NSApp.appearance
            guard let root = window.contentView else { continue }
            repaint(root)
            window.invalidateShadow()
        }
    }

    private static func repaint(_ view: NSView) {
        view.reapplyRecordedSurface()
        view.needsDisplay = true

        // Effect views and anything else deriving from the appearance need their own nudge, and
        // a view that draws into its layer will not redraw from `needsDisplay` alone.
        if view.wantsLayer, view.layerContentsRedrawPolicy != .never {
            view.layer?.setNeedsDisplay()
        }

        for subview in view.subviews { repaint(subview) }
    }
}
