import AppKit

/// A clip view whose default is the only background a themed scroll surface wants: none.
///
/// Kept separate because conversations replace the ordinary clip view with a flipped subclass.
/// Subclassing this preserves the invariant without every call site remembering to turn the
/// AppKit background off after construction.
class ThemedClipView: NSClipView, ThemedComponent {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A scroll view that starts transparent, replacing `NSScrollView`.
///
/// The stock default is the erosion: `drawsBackground` is true, so a scroll view someone
/// forgot to configure paints `controlBackgroundColor` — a *system* surface — behind
/// whatever the themed pane put there. Ten of the app's twelve scroll views were switching
/// it off by hand and two had forgotten, which is exactly the argument for a type: the
/// correct state becomes the starting state, and the two forgotten ones were fixed by the
/// rename alone.
///
/// Only the background is claimed. Scrollers stay the system's on purpose — they are
/// overlay chrome the platform draws, dims and fades itself, and a themed scroller would
/// buy drift from that behaviour with nothing gained.
class ThemedScrollView: NSScrollView, ThemedComponent, SystemChromeBoundary {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView = ThemedClipView(frame: contentView.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A table with a header makes AppKit insert a second clip view beside `contentView`.
    /// It is framework-owned and cannot be replaced through the public API, but its stock
    /// background is still ours to neutralise.
    override func tile() {
        super.tile()
        for case let clip as NSClipView in subviews where clip !== contentView {
            clip.drawsBackground = false
        }
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        if view is NSScroller { return true }

        // The only raw clip AppKit may add is the direct, transparent header clip described
        // above. This does not grant permission to a raw clip in the document subtree.
        guard let clip = view as? NSClipView else { return false }
        return clip.superview === self && !clip.drawsBackground
    }
}
