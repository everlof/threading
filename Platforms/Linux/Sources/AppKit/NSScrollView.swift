import Foundation

/// Document views with viewport-owned children use this hook to recycle those children after
/// scrolling or resizing. It is internal to the shim; callers use the ordinary scroll APIs.
@MainActor
protocol NSClipViewDocumentObserver: AnyObject {
    func clipViewViewportDidChange(_ clipView: NSClipView)
}

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
            let previous = storedDocumentView
            previous?.removeFromSuperview()
            storedDocumentView = newValue
            if let newValue { addSubview(newValue) }
            (previous as? NSClipViewDocumentObserver)?.clipViewViewportDidChange(self)
            scroll(to: bounds.origin)
            (newValue as? NSClipViewDocumentObserver)?.clipViewViewportDidChange(self)
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
            (documentView as? NSClipViewDocumentObserver)?.clipViewViewportDidChange(self)
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
        (documentView as? NSClipViewDocumentObserver)?.clipViewViewportDidChange(self)
    }
}

/// A small AppKit-compatible scroll owner. It does not build document rows: a table or sidebar
/// supplies only its visible children and uses the clip view's bounds as the viewport.
public enum NSBorderType: Equatable, Sendable {
    case noBorder, lineBorder, bezelBorder, grooveBorder
}

@MainActor
open class NSScrollView: NSView {
    public enum Elasticity: Equatable, Sendable {
        case automatic, allowed, none
    }

    private var storedContentView: NSClipView
    private var viewportConstraints: [NSLayoutConstraint] = []

    open var contentView: NSClipView {
        get { storedContentView }
        set {
            guard storedContentView !== newValue else { return }
            let document = storedContentView.documentView
            storedContentView.documentView = nil
            NSLayoutConstraint.deactivate(viewportConstraints)
            storedContentView.removeFromSuperview()
            storedContentView = newValue
            addSubview(newValue)
            newValue.documentView = document
            constrainViewport()
            tile()
        }
    }

    open var documentView: NSView? {
        get { contentView.documentView }
        set { contentView.documentView = newValue }
    }

    open var drawsBackground = false
    /// The Linux host draws no bezel; themed scroll views state `.noBorder`, and other kinds
    /// are refused rather than silently dropped.
    open var borderType: NSBorderType = .noBorder {
        didSet { precondition(borderType == .noBorder, "Linux NSScrollView draws no bezel border") }
    }
    open var hasVerticalScroller = false
    open var autohidesScrollers = false
    open var hasHorizontalScroller = false
    /// Breathing belongs inside the scroll surface; the clip, not the scroll view, is inset.
    open var contentInsets = NSEdgeInsets() {
        didSet {
            constrainViewport()
            tile()
        }
    }
    /// Elasticity is a request; this renderer currently keeps the viewport clamped.
    open var horizontalScrollElasticity: Elasticity = .none
    /// The clip view clamps to the document bounds; there is no rubber-band animation in the
    /// Linux host. Let shared views request that behavior explicitly, and reject other modes.
    open var verticalScrollElasticity: Elasticity = .none {
        didSet { precondition(verticalScrollElasticity == .none,
                              "Linux NSScrollView does not support elastic scrolling") }
    }
    open var verticalLineScroll: CGFloat = 10
    open var horizontalLineScroll: CGFloat = 10

    public override init(frame frameRect: NSRect) {
        storedContentView = NSClipView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        addSubview(storedContentView)
        constrainViewport()
    }

    public required init?(coder: NSCoder) {
        storedContentView = NSClipView(frame: .zero)
        super.init(coder: coder)
        addSubview(storedContentView)
        constrainViewport()
    }

    private func constrainViewport() {
        NSLayoutConstraint.deactivate(viewportConstraints)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        viewportConstraints = [
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInsets.bottom)
        ]
        NSLayoutConstraint.activate(viewportConstraints)
    }

    open override var frame: NSRect {
        didSet {
            guard frame.size != oldValue.size else { return }
            tile()
        }
    }

    open func tile() {
        let viewport = bounds.inset(by: contentInsets)
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
            y: before.y + event.scrollingDeltaY * verticalLineScroll * (contentView.isFlipped ? -1 : 1)
        )
        contentView.scroll(to: target)
        if contentView.bounds.origin != before {
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
