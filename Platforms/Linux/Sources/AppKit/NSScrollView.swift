import Foundation

/// The clipping viewport for a document view. Scrolling changes the bounds origin, so the
/// document keeps stable geometry and callers can retain only the views intersecting `bounds`.
@MainActor
open class NSClipView: NSView {
    private var storedDocumentView: NSView?

    open override var isFlipped: Bool { documentView?.isFlipped ?? super.isFlipped }

    open var documentView: NSView? {
        get { storedDocumentView }
        set {
            guard storedDocumentView !== newValue else { return }
            storedDocumentView?.removeFromSuperview()
            storedDocumentView = newValue
            if let newValue { addSubview(newValue) }
            scroll(to: bounds.origin)
        }
    }

    open var documentRect: NSRect { documentView?.frame ?? .zero }

    open var documentVisibleRect: NSRect {
        guard let documentView else { return .zero }
        let visible = bounds.intersection(documentRect)
        return visible.offsetBy(dx: -documentView.frame.minX, dy: -documentView.frame.minY)
    }

    open var drawsBackground = false

    open override var frame: NSRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            scroll(to: bounds.origin)
        }
    }

    open func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        let document = documentRect
        guard documentView != nil else {
            return NSRect(origin: .zero, size: proposedBounds.size)
        }
        let maxX = max(document.maxX - proposedBounds.width, document.minX)
        let maxY = max(document.maxY - proposedBounds.height, document.minY)
        let origin = NSPoint(
            x: min(max(proposedBounds.minX, document.minX), maxX),
            y: min(max(proposedBounds.minY, document.minY), maxY)
        )
        return NSRect(origin: origin, size: proposedBounds.size)
    }

    open func scroll(to point: NSPoint) {
        let proposed = NSRect(origin: point, size: bounds.size)
        let constrained = constrainBoundsRect(proposed)
        guard constrained.origin != bounds.origin else { return }
        setBoundsOrigin(constrained.origin)
    }
}

/// A small AppKit-compatible scroll owner. It does not build document rows: a table or sidebar
/// supplies only its visible children and uses the clip view's bounds as the viewport.
@MainActor
open class NSScrollView: NSView {
    private var storedContentView: NSClipView

    open var contentView: NSClipView {
        get { storedContentView }
        set {
            guard storedContentView !== newValue else { return }
            let document = storedContentView.documentView
            storedContentView.documentView = nil
            storedContentView.removeFromSuperview()
            storedContentView = newValue
            addSubview(newValue)
            newValue.documentView = document
            tile()
        }
    }

    open var documentView: NSView? {
        get { contentView.documentView }
        set { contentView.documentView = newValue }
    }

    open var drawsBackground = false
    open var hasVerticalScroller = false
    open var hasHorizontalScroller = false
    open var verticalLineScroll: CGFloat = 10
    open var horizontalLineScroll: CGFloat = 10

    public override init(frame frameRect: NSRect) {
        storedContentView = NSClipView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        addSubview(storedContentView)
    }

    public required init?(coder: NSCoder) {
        storedContentView = NSClipView(frame: .zero)
        super.init(coder: coder)
        addSubview(storedContentView)
    }

    open override var frame: NSRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            tile()
        }
    }

    open func tile() {
        let viewport = NSRect(origin: .zero, size: bounds.size)
        guard contentView.frame != viewport else { return }
        contentView.frame = viewport
    }

    open func reflectScrolledClipView(_ clipView: NSClipView) {
        guard clipView === contentView else { return }
        needsDisplay = true
    }

    open override func scrollWheel(with event: NSEvent) {
        let before = contentView.bounds.origin
        let target = NSPoint(
            x: before.x - event.scrollingDeltaX * horizontalLineScroll,
            y: before.y - event.scrollingDeltaY * verticalLineScroll
        )
        contentView.scroll(to: target)
        if contentView.bounds.origin != before {
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
