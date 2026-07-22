import AppKit

/// The graph column beside one commit row: the lines crossing it, and this commit's node.
///
/// Drawn rather than built from subviews. A rail is a handful of strokes and a dot, and a
/// hundred-commit page would otherwise be several hundred more views in a list that already
/// carries four labels a row.
///
/// The rail runs edge to edge vertically, which is why the history list closes its row gaps:
/// a line that stops short of the row below reads as a history that ended there.
final class GitGraphRailView: NSView {

    // MARK: - Properties

    private let row: GitGraphRow
    private let laneCount: Int

    // MARK: - Initialization

    /// `laneCount` is the whole page's width, not this row's, so nodes line up down the column.
    init(row: GitGraphRow, laneCount: Int) {
        self.row = row
        self.laneCount = max(laneCount, 1)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(forLanes: laneCount), height: NSView.noIntrinsicMetric)
    }

    /// What a rail of this many lanes occupies. The pane is narrow, so the graph is capped:
    /// past the cap the lines still draw, overlapping at the last column rather than pushing
    /// the subject off the row.
    static func width(forLanes lanes: Int) -> CGFloat {
        let shown = min(max(lanes, 1), GitGraphDefaults.maximumLanes)
        return CGFloat(shown) * GitGraphDefaults.laneWidth
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let top = bounds.maxY
        let middle = bounds.midY
        let bottom = bounds.minY

        for segment in row.incoming {
            stroke(from: NSPoint(x: x(of: segment.from), y: top),
                   to: NSPoint(x: x(of: segment.to), y: middle),
                   lane: segment.to)
        }
        for segment in row.outgoing {
            stroke(from: NSPoint(x: x(of: segment.from), y: middle),
                   to: NSPoint(x: x(of: segment.to), y: bottom),
                   lane: segment.to)
        }

        drawNode(at: NSPoint(x: x(of: row.lane), y: middle))
    }

    /// A straight run for a lane that continues, an S-curve where it bends — a diagonal would
    /// meet the vertical lines above and below it at a corner, which reads as a crossing
    /// rather than as the same line moving over.
    private func stroke(from start: NSPoint, to end: NSPoint, lane: Int) {
        let path = NSBezierPath()
        path.move(to: start)

        if abs(start.x - end.x) < 0.5 {
            path.line(to: end)
        } else {
            let midY = (start.y + end.y) / 2
            path.curve(
                to: end,
                controlPoint1: NSPoint(x: start.x, y: midY),
                controlPoint2: NSPoint(x: end.x, y: midY)
            )
        }

        path.lineWidth = GitGraphDefaults.lineWidth
        path.lineCapStyle = .round
        color(for: lane).setStroke()
        path.stroke()
    }

    /// A filled dot for an ordinary commit; a ring for a merge, which is the one row where
    /// what happened is not "one more change" but "two histories became one".
    private func drawNode(at centre: NSPoint) {
        let radius = row.isMerge ? GitGraphDefaults.mergeNodeRadius : GitGraphDefaults.nodeRadius
        let rect = NSRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = NSBezierPath(ovalIn: rect)
        let tint = color(for: row.lane)

        if row.isMerge {
            // The pane's own background shows through the ring, so the fill is the surface
            // under it rather than a colour of its own.
            NSColor.textBackgroundColor.setFill()
            path.fill()
            tint.setStroke()
            path.lineWidth = GitGraphDefaults.lineWidth
            path.stroke()
        } else {
            tint.setFill()
            path.fill()
        }
    }

    private func x(of lane: Int) -> CGFloat {
        let clamped = min(lane, GitGraphDefaults.maximumLanes - 1)
        return (CGFloat(clamped) + 0.5) * GitGraphDefaults.laneWidth
    }

    /// Lanes are told apart by colour, which is the only thing that lets a branch be followed
    /// down a page. System colours, so both appearances resolve them.
    private func color(for lane: Int) -> NSColor {
        GitGraphDefaults.laneColors[lane % GitGraphDefaults.laneColors.count]
    }
}

// MARK: - Defaults

enum GitGraphDefaults {
    /// One column. Narrow enough that a linear history costs almost nothing beside the subject.
    static let laneWidth: CGFloat = 14

    /// Past this the rail would take more of a narrow pane than the commit messages do; extra
    /// lanes fold onto the last column.
    static let maximumLanes = 5

    static let lineWidth: CGFloat = 1.5
    static let nodeRadius: CGFloat = 3
    static let mergeNodeRadius: CGFloat = 3.5

    /// Cycled by lane index. Ordered so neighbouring lanes are never near-hues of each other.
    static let laneColors: [NSColor] = [
        .systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemIndigo
    ]
}
