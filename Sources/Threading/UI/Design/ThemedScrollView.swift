import AppKit

/// The scroll thumb and track owned by Threading's chrome.
///
/// System remains exactly AppKit's scroller: its drawing methods are handed straight back to
/// `NSScroller`. Authored themes replace only those two drawing parts, which is AppKit's public
/// customization seam and leaves its geometry, hit testing, dragging, user-selected
/// overlay/legacy style, and separate fade animations intact.
///
/// The ink source matters for the terminal. Ordinary scroll views sit on app-owned chrome;
/// SwiftTerm's scroller sits on the terminal palette that also paints the window backdrop. One
/// component takes that difference as data rather than introducing a second scrollbar.
final class ThemedScroller: NSScroller, ThemedComponent, InkSourced {

    let inkSource: InkSource

    private var themeRedraw: ThemeRedraw?
    private let backdropEvents = AppEventObservations()

    override class var isCompatibleWithOverlayScrollers: Bool {
        self == ThemedScroller.self
    }

    /// The identity theme owns no scrollbar appearance; AppKit draws both parts.
    var delegatesDrawingToAppKit: Bool {
        AppThemePalette.current.isSystem
    }

    override init(frame frameRect: NSRect) {
        inkSource = .chrome
        super.init(frame: frameRect)
        observeAppearance()
    }

    init(frame frameRect: NSRect, inkSource: InkSource) {
        self.inkSource = inkSource
        super.init(frame: frameRect)
        observeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeAppearance() {
        themeRedraw = ThemeRedraw(self)
        backdropEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            guard self?.inkSource == .backdrop else { return }
            self?.needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawKnob() {
        guard !delegatesDrawingToAppKit else {
            super.drawKnob()
            return
        }

        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        draw(inkSource.ink.secondary, in: knob)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !delegatesDrawingToAppKit else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }

        let ink = inkSource.ink
        draw(flag ? ink.surfaceHover : ink.surface, in: slotRect)
    }

    private func draw(_ color: NSColor, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setFill()
        let shortSide = min(rect.width, rect.height)
        let radius = Design.Radius.pill(height: shortSide)
        NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

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
/// Scrollers retain AppKit's behavior and presentation policy while `ThemedScroller` replaces
/// their two drawing parts under an authored theme. System delegates those parts straight back
/// to AppKit, so the identity theme remains genuinely native rather than an imitation.
class ThemedScrollView: NSScrollView, ThemedComponent, SystemChromeBoundary {

    /// Hands vertical-dominant gestures to the nearest enclosing scroll view.
    ///
    /// Opt this in for a nested, horizontal-only viewport such as a Markdown code block. AppKit
    /// otherwise sends the whole trackpad gesture to the view beneath the pointer, even when
    /// that view has no vertical range, which makes the surrounding conversation appear stuck.
    /// Horizontal-dominant gestures remain local.
    var forwardsVerticalScrollToAncestor = false

    /// Reports a wheel or trackpad event before it scrolls, momentum included.
    ///
    /// This is how a caller tells the user's hand from its own `setBoundsOrigin`: AppKit
    /// routes only real gestures through here, so no generation counter is needed to keep
    /// programmatic scrolls from being mistaken for the user leaving. Scroller-thumb drags
    /// never pass through `scrollWheel` — watch the live-scroll notifications for those.
    var onUserScroll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView = ThemedClipView(frame: contentView.frame)
        verticalScroller = ThemedScroller(frame: .zero)
        horizontalScroller = ThemedScroller(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsVerticalScrollToAncestor,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           let ancestorScrollView {
            ancestorScrollView.scrollWheel(with: event)
            return
        }

        onUserScroll?()
        super.scrollWheel(with: event)
    }

    private var ancestorScrollView: NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
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
        // macOS 26 inserts visual-effect views into overlay-scrolling chrome. Depending on
        // the scroll view's state, the effect is either direct or nested under private
        // NSScrollPocket/NSHardPocketView wrappers. Permit that AppKit-owned side of the tree
        // while refusing effects in contentView/documentView, where application content lives.
        if view is NSVisualEffectView {
            var ancestor = view.superview
            while let current = ancestor, current !== self {
                if current === contentView || current === documentView {
                    return false
                }
                ancestor = current.superview
            }
            return ancestor === self
        }

        // The only raw clip AppKit may add is the direct, transparent header clip described
        // above. This does not grant permission to a raw clip in the document subtree.
        guard let clip = view as? NSClipView else { return false }
        return clip.superview === self && !clip.drawsBackground
    }
}
