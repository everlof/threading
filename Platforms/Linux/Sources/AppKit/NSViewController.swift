import Foundation

/// Structural controller shim for shared AppKit view components. A host owns presentation.
@MainActor
open class NSViewController: NSResponder {
    private var loadedView: NSView?

    public init(nibName: String?, bundle: Bundle?) {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init()
    }

    open func loadView() {
        view = NSView()
    }

    open var view: NSView {
        get {
            if let loadedView { return loadedView }
            loadView()
            if let loadedView { return loadedView }
            let fallback = NSView()
            loadedView = fallback
            return fallback
        }
        set { loadedView = newValue }
    }
}

public enum NSRectEdge: Sendable {
    case minX, maxX, minY, maxY
}
