import AppKit

// MARK: - Inspector Mode

/// The two ways to capture. Element mode detects and outlines the view under the pointer —
/// for referring to a *thing*. Freeflow mode detects nothing and records the pointer's own
/// position — for referring to a *place*: a gap, a misalignment, the middle of a terminal
/// that is one view however much it draws.
enum InspectorMode {
    case element
    case freeflow
}

// MARK: - Inspector Defaults

enum InspectorDefaults {
    /// Views at or below this alpha are invisible in practice. The sidebar crossfades its
    /// hover controls to zero rather than hiding them, and an inspector that picked one of
    /// those would report a control the user cannot see.
    static let minimumVisibleAlpha: CGFloat = 0.01

    static let strokeWidth: CGFloat = 2
    static let fillAlpha: CGFloat = 0.12
    /// The freeflow guides span the whole window, so they rest well below the outline.
    static let guideAlpha: CGFloat = 0.35
    static let guideWidth: CGFloat = 1
    static let markerRadius: CGFloat = 4
    static let escapeKeyCode: UInt16 = 53
    static let screenshotPrefix = "skalman-inspect-"
}

// MARK: - Element Hit Test

/// Finds the view the pointer is over, the way an inspector means it rather than the way
/// event routing means it.
///
/// `NSView.hitTest(_:)` answers "who receives this click", which is the wrong question here:
/// a disabled control returns nil, an overlay redirects, and a view that draws but takes no
/// events vanishes. This walk answers "what is visually topmost" — the deepest, frontmost
/// descendant whose bounds contain the point — skipping only what cannot be seen.
enum ElementHitTest {

    /// Returns the topmost visible descendant of `view` containing `point`, or `view` itself
    /// when no subview does. `point` is in `view`'s own coordinate space.
    static func topmost(in view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden,
              view.alphaValue > InspectorDefaults.minimumVisibleAlpha,
              view.bounds.contains(point) else { return nil }

        // Subviews draw back to front, so the reversed order asks the frontmost first and
        // the first hit wins.
        for subview in view.subviews.reversed() {
            if let hit = topmost(in: subview, at: view.convert(point, to: subview)) {
                return hit
            }
        }

        return view
    }
}

// MARK: - Element Report

/// What one picked element is, said in the vocabulary a chat about this codebase already
/// uses: its class, where it sits, the view chain above it, and the controllers responsible.
struct ElementReport {

    struct Node {
        let className: String
        /// In window coordinates.
        let frame: NSRect
        let identifier: String?
    }

    let target: Node

    /// Leaf to root, target first.
    let viewChain: [Node]

    /// Every view and window controller on the target's responder chain, nearest first.
    /// This is the half of the report that maps a pixel to a source file: the view chain
    /// names AppKit plumbing, the controllers name types this project defines.
    let controllers: [String]

    /// Set once the window snapshot lands on disk.
    var screenshotPath: String?

    // MARK: - Building

    static func build(for view: NSView) -> ElementReport {
        var chain: [Node] = []
        var currentView: NSView? = view
        while let current = currentView {
            chain.append(node(for: current))
            currentView = current.superview
        }

        // A view controller sits on its view's responder chain, so walking it recovers the
        // ownership the superview chain cannot see.
        var controllers: [String] = []
        var responder: NSResponder? = view
        while let current = responder {
            if current is NSViewController || current is NSWindowController {
                controllers.append(String(describing: type(of: current)))
            }
            responder = current.nextResponder
        }

        return ElementReport(
            target: chain[0],
            viewChain: chain,
            controllers: controllers,
            screenshotPath: nil
        )
    }

    private static func node(for view: NSView) -> Node {
        // AppKit stamps `_NS:…` identifiers on views it manages itself; only a name someone
        // chose is worth reporting.
        var identifier = view.identifier?.rawValue
        if let value = identifier, value.isEmpty || value.hasPrefix("_NS") {
            identifier = nil
        }

        return Node(
            className: String(describing: type(of: view)),
            frame: view.convert(view.bounds, to: nil),
            identifier: identifier
        )
    }

    // MARK: - Rendering

    /// The pasteable form. The screenshot rides along as a *path* rather than an embedded
    /// image, because a path is the one form of an image the agent CLIs can act on — the
    /// same reasoning as the composer's pasted-image handling.
    var markdown: String {
        var lines = ["## Element report — \(target.className)"]
        lines.append("- Frame: \(InspectorGeometry.describe(target.frame)) in window")

        if let identifier = target.identifier {
            lines.append("- Identifier: \(identifier)")
        }

        lines.append(
            "- View chain (leaf → root): "
                + viewChain.map(\.className).joined(separator: " → ")
        )

        if !controllers.isEmpty {
            lines.append("- Controllers: " + controllers.joined(separator: " → "))
        }

        if let screenshotPath {
            lines.append("- Window screenshot, target outlined: \(screenshotPath)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Point Report

/// A freeflow capture: the pointer's position, said in both of the coordinate spaces a chat
/// might use it in.
struct PointReport {

    /// In window coordinates — bottom-left origin, the space AppKit code speaks.
    let point: NSPoint

    let windowSize: NSSize

    /// Set once the window snapshot lands on disk.
    var screenshotPath: String?

    /// The same point from the top-left, which is how anyone — or any agent — reading the
    /// screenshot will count.
    var pointFromTopLeft: NSPoint {
        NSPoint(x: point.x, y: windowSize.height - point.y)
    }

    var markdown: String {
        var lines = ["## Point report"]
        lines.append("- Point: \(InspectorGeometry.describe(point)) in window, bottom-left origin")
        lines.append("- In the screenshot: \(InspectorGeometry.describe(pointFromTopLeft)) from top-left")
        lines.append(
            "- Window: \(Int(windowSize.width.rounded()))×\(Int(windowSize.height.rounded()))"
        )

        if let screenshotPath {
            lines.append("- Window screenshot, point marked: \(screenshotPath)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Geometry Descriptions

enum InspectorGeometry {

    static func describe(_ rect: NSRect) -> String {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        return "\(width)×\(height) at \(describe(rect.origin))"
    }

    static func describe(_ point: NSPoint) -> String {
        "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
    }
}
