import AppKit

// MARK: - Inspector Mode

/// The two ways to capture. Element mode detects and outlines the view under the pointer —
/// for referring to a *thing*. Freeflow mode detects nothing and records geometry the
/// pointer draws itself — a click for a *place*, a drag for a *region*: a gap, a
/// misalignment, the middle of a terminal that is one view however much it draws.
///
/// **Not a stored mode: a reading of the keyboard.** There is one inspect command, and ⇧ is
/// what suppresses detection while it is held — the same treatment `InspectorLayers` gives ⌃
/// and ⌥, for the same reason. Two commands meant two shortcuts, two menu items and a
/// switch-in-place rule to explain, for a distinction the hand can make while pointing.
///
/// It also means the chord that used to open freeflow directly still does: invoking the
/// command as ⌥⇧⌘I arrives with ⇧ already down, so the overlay opens reading exactly that.
enum InspectorMode {
    case element
    case freeflow

    static func held(_ flags: NSEvent.ModifierFlags) -> InspectorMode {
        flags.contains(.shift) ? .freeflow : .element
    }
}

// MARK: - Inspector Defaults

enum InspectorDefaults {
    /// Views at or below this alpha are invisible in practice. The sidebar crossfades its
    /// hover controls to zero rather than hiding them, and an inspector that picked one of
    /// those would report a control the user cannot see.
    static let minimumVisibleAlpha: CGFloat = 0.01

    static let strokeWidth: CGFloat = 2
    /// Ancestors are drawn lighter than the pick, so the target still reads as the target
    /// when nine outlines are on screen.
    static let ancestorStrokeWidth: CGFloat = 1.5
    static let fillAlpha: CGFloat = 0.12
    /// The freeflow guides span the whole window, so they rest well below the outline.
    static let guideAlpha: CGFloat = 0.35
    static let guideWidth: CGFloat = 1
    static let markerRadius: CGFloat = 4
    /// A press that travels further than this before release is a region, not a click.
    static let dragThreshold: CGFloat = 4
    static let escapeKeyCode: UInt16 = 53
    static let screenshotPrefix = "threading-inspect-"

    // MARK: - Hierarchy

    /// Two rectangles no further apart than this are one rectangle to the eye, so the views
    /// holding them are one level. Views land on half points routinely.
    static let coincidentTolerance: CGFloat = 0.5

    /// A gap smaller than this is a flush edge, and drawing `0` around a fitted view is four
    /// numbers saying nothing.
    static let minimumMeasuredGap: CGFloat = 0.5

    /// The depth number inside each outlined rectangle's top-leading corner.
    static let chipSize: CGFloat = 14
    static let chipInset: CGFloat = 2

    static let measureWidth: CGFloat = 1
    static let measureDash: [CGFloat] = [3, 2]
    /// The perpendicular end mark, so a two-point gap still reads as a span.
    static let measureTick: CGFloat = 8

    /// The room kept between two of the overlay's small labels, and between a label and the
    /// edge it steps past.
    static let labelClearance: CGFloat = 3

    /// A leader is a line saying which measure a displaced number belongs to, not a measure
    /// itself, so it rests well below the one it points at.
    static let leaderAlpha: CGFloat = 0.5

    static let legendRowHeight: CGFloat = 15
    static let legendSwatch: CGFloat = 9

    /// What a panel drops to when every corner is covered. A hint that keeps running away is
    /// worse than one you can read through, so the last resort is transparency rather than a
    /// fifth position.
    static let obstructedPanelAlpha: CGFloat = 0.25

    /// The room a panel keeps from the capture it is dodging, so "clear of it" means visibly
    /// clear rather than sharing an edge.
    static let panelClearance: CGFloat = 6

    /// Past this a class name is truncated rather than widening the key — one
    /// `ComponentContentContainerView = _NSCoreHostingView` would otherwise set the panel's
    /// width for every row under it.
    ///
    /// Both halves earn their keep. The **fraction** is what makes the cap answer the window
    /// rather than a guess: a real chain is eleven levels of composed AppKit class names, and a
    /// fixed 300 truncated most of them on a 1400pt window with half of it empty. The
    /// **ceiling** is what stops a wide window handing the key most of itself.
    static let legendTitleFraction: CGFloat = 0.42
    static let legendTitleWidth: CGFloat = 460

    /// Above this brightness a hue takes black ink rather than white.
    static let inkFlipBrightness: CGFloat = 0.6
}

// MARK: - Element Hit Test

/// Finds the view the pointer is over, the way an inspector means it rather than the way
/// event routing means it.
///
/// `NSView.hitTest(_:)` answers "who receives this click", which is the wrong question here:
/// a disabled control returns nil, an overlay redirects, and a view that draws but takes no
/// events vanishes. Nor is "frontmost wins" the answer, though it was the first version:
/// macOS layers pane-sized chrome *above* content — a `_NSCoreHostingView` glass sheet sat
/// over the whole sidebar, so every hover stopped at it and no row was ever reachable.
///
/// What the eye means by "that element" is the most *specific* thing under the pointer. So
/// every visible view containing the point is a candidate, and the smallest wins; among
/// equals the deeper wins, then the one drawn on top. A row's label beats the row, the row
/// beats the pane's glass, and the terminal still wins its own pane because nothing smaller
/// is there.
@MainActor
enum ElementHitTest {

    /// Returns the most specific visible descendant of `view` containing `point`, or `view`
    /// itself when no subview does. `point` is in `view`'s own coordinate space.
    static func topmost(in view: NSView, at point: NSPoint) -> NSView? {
        candidate(in: view, at: point, depth: 0)?.view
    }

    private struct Candidate {
        let view: NSView
        let area: CGFloat
        let depth: Int
    }

    private static func candidate(in view: NSView, at point: NSPoint, depth: Int) -> Candidate? {
        guard !view.isHidden,
              view.alphaValue > InspectorDefaults.minimumVisibleAlpha,
              view.bounds.contains(point) else { return nil }

        var best = Candidate(
            view: view,
            area: view.bounds.width * view.bounds.height,
            depth: depth
        )

        // Subviews are ordered back to front; the challenger taking ties is what lets the
        // frontmost of two equal siblings win.
        for subview in view.subviews {
            guard let challenger = candidate(
                in: subview,
                at: view.convert(point, to: subview),
                depth: depth + 1
            ) else { continue }

            best = better(current: best, challenger: challenger)
        }

        return best
    }

    private static func better(current: Candidate, challenger: Candidate) -> Candidate {
        if challenger.area != current.area {
            return challenger.area < current.area ? challenger : current
        }
        if challenger.depth != current.depth {
            return challenger.depth > current.depth ? challenger : current
        }
        return challenger
    }
}

// MARK: - Element Report

/// What one picked element is, said in the vocabulary a chat about this codebase already
/// uses: its class, where it sits, the view chain above it, and the controllers responsible.
@MainActor
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

    /// The rectangles the overlay drew, target first — the same coalescing and the same hues.
    let levels: [InspectorLevel]

    /// What was held when the pick was made, and therefore what the screenshot shows.
    let layers: InspectorLayers

    /// Set once the window snapshot lands on disk.
    var screenshotPath: String?

    // MARK: - Building

    static func build(for view: NSView, layers: InspectorLayers = []) -> ElementReport {
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
            levels: InspectorHierarchy.levels(for: view),
            layers: layers,
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

        lines.append(contentsOf: hierarchyLines)
        lines.append(contentsOf: spacingLines)

        if let screenshotPath {
            lines.append("- Window screenshot, target outlined: \(screenshotPath)")
        }

        return lines.joined(separator: "\n")
    }

    /// The colour key, in words.
    ///
    /// The screenshot carries the hierarchy as *colours*, which nobody reading the text can
    /// see and no agent can name. So each outline is spelled out here against the class it
    /// belongs to — which is what turns "the orange one is too wide" into a file to open.
    private var hierarchyLines: [String] {
        guard layers.contains(.hierarchy) || layers.contains(.spacing) else { return [] }

        let shown = InspectorHierarchy.shown(levels, for: layers)
        guard shown.count > 1 else { return [] }

        return ["- Hierarchy, target outward (outline colour · depth · class · frame):"]
            + shown.map { level in
                var row = "  - \(level.hue.name) · \(level.depth) · \(level.title)"
                row += " · \(InspectorGeometry.describe(level.rect))"
                if let identifier = level.identifier {
                    row += " · id \(identifier)"
                }
                return row + " · \(level.address)"
            }
    }

    /// What the measures on the screenshot say, per pair. The parent is named first because
    /// the layout that chose the gap almost always lives there.
    private var spacingLines: [String] {
        guard layers.contains(.spacing) else { return [] }

        let pairs = InspectorSpacing.gaps(across: InspectorHierarchy.shown(levels, for: layers))
        guard !pairs.isEmpty else { return [] }

        let shown = InspectorHierarchy.shown(levels, for: layers)
        return ["- Spacing, inside each parent (points):"]
            + pairs.enumerated().map { index, pair in
                "  - \(shown[index].title) inside \(pair.parent.title): "
                    + InspectorSpacing.describe(pair.gaps)
            }
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

// MARK: - Region Report

/// A freeflow drag: the rectangle the pointer drew, said in both of the coordinate spaces a
/// chat might use it in — the same pair as `PointReport`.
struct RegionReport {

    /// In window coordinates — bottom-left origin, the space AppKit code speaks.
    let rect: NSRect

    let windowSize: NSSize

    /// Set once the window snapshot lands on disk.
    var screenshotPath: String?

    /// The same region from the top-left, which is how anyone — or any agent — reading the
    /// screenshot will measure.
    var rectFromTopLeft: NSRect {
        NSRect(
            x: rect.minX,
            y: windowSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    var markdown: String {
        var lines = ["## Region report"]
        lines.append("- Region: \(InspectorGeometry.describe(rect)) in window, bottom-left origin")
        lines.append("- In the screenshot: \(InspectorGeometry.describe(rectFromTopLeft)) from top-left")
        lines.append(
            "- Window: \(Int(windowSize.width.rounded()))×\(Int(windowSize.height.rounded()))"
        )

        if let screenshotPath {
            lines.append("- Window screenshot, region marked: \(screenshotPath)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Geometry Descriptions

enum InspectorGeometry {

    static func describe(_ rect: NSRect) -> String {
        "\(describe(rect.size)) at \(describe(rect.origin))"
    }

    static func describe(_ point: NSPoint) -> String {
        "(\(Int(point.x.rounded())), \(Int(point.y.rounded())))"
    }

    static func describe(_ size: NSSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    /// The rectangle between two corners, whichever way the drag ran.
    static func rect(from anchor: NSPoint, to point: NSPoint) -> NSRect {
        NSRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }
}
