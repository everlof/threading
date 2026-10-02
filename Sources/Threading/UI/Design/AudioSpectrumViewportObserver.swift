import AppKit

/// A clipped-out decorative consumer is not visible demand. Observe enclosing clip views so
/// scrolling a cached settings page past its preview releases capture without a frame timer.
@MainActor
final class AudioSpectrumViewportObserver {
    private var tokens: [NSObjectProtocol] = []

    /// NSView.visibleRect can extend beyond a view's bounds when self-clipping is disabled.
    /// Intersect the view's actual bounds with its enclosing clips to measure visible demand.
    static func intersectsViewport(_ view: NSView) -> Bool {
        var visible = view.bounds
        guard !visible.isEmpty else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if let clip = current as? NSClipView {
                visible = visible.intersection(view.convert(clip.bounds, from: clip))
                if visible.isEmpty { return false }
            }
            ancestor = current.superview
        }
        return true
    }

    init(view: NSView, changed: @escaping @MainActor () -> Void) {
        var ancestor = view.superview
        while let current = ancestor {
            if let clip = current as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                tokens.append(NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                ) { _ in MainActor.assumeIsolated { changed() } })
            }
            ancestor = current.superview
        }
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
