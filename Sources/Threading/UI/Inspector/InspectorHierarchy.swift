import AppKit

// MARK: - Layers

/// What element mode draws on top of the target, chosen by what is held down while hovering.
///
/// Two orthogonal questions, one modifier each: **⌃ how many levels** (the target alone, or
/// every ancestor above it) and **⌥ whether the gaps between them are measured**. Holding ⌥
/// alone is the common ask — "why is this inset like that" — so it draws the target and its
/// parent and nothing else, rather than requiring the whole chain first.
struct InspectorLayers: OptionSet {

    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Every ancestor outlined, coloured by depth.
    static let hierarchy = InspectorLayers(rawValue: 1 << 0)

    /// The gaps between each drawn level and the one outside it, measured.
    static let spacing = InspectorLayers(rawValue: 1 << 1)

    /// Read from the keyboard rather than stored: modifiers are transient state that AppKit
    /// already tracks, and a copy of it is a copy that can be wrong.
    static func held(_ flags: NSEvent.ModifierFlags) -> InspectorLayers {
        var layers: InspectorLayers = []
        if flags.contains(.control) { layers.insert(.hierarchy) }
        if flags.contains(.option) { layers.insert(.spacing) }
        return layers
    }
}

// MARK: - Level

/// One rectangle in the hierarchy overlay.
///
/// A *level* is not a view: a run of views sharing one rectangle is one level, because the
/// screen shows one rectangle and giving it several outlines and several legend rows claims
/// there are several things to look at. The classes that share it are all named on the one
/// row instead, which is the answer to "which of these is doing the layout".
struct InspectorLevel: Equatable {

    /// 0 is the target. Each step out is the next ancestor that occupies its *own* area.
    let depth: Int

    /// In window coordinates.
    let rect: NSRect

    /// The classes sharing this rectangle, innermost first.
    let classNames: [String]

    /// The innermost view's address, so two instances of one class can be told apart — and
    /// so a chat about the report can name the object an `lldb` session would print.
    let address: String

    /// A chosen identifier, if the innermost view carries one.
    let identifier: String?

    /// The hue that outlines this level and names it in the legend.
    var hue: Design.Categorical.Hue { Design.Categorical.hue(at: depth) }

    /// The classes, innermost first — `NSStackView = NSView` when a wrapper is coincident.
    var title: String { classNames.joined(separator: " = ") }

    var size: String { InspectorGeometry.describe(rect.size) }
}

// MARK: - Hierarchy

@MainActor
enum InspectorHierarchy {

    /// The target and every ancestor above it, leaf first, coincident levels coalesced.
    static func levels(for view: NSView) -> [InspectorLevel] {
        var levels: [InspectorLevel] = []
        var current: NSView? = view

        while let subject = current {
            let rect = subject.convert(subject.bounds, to: nil)
            let className = String(describing: type(of: subject))

            if let last = levels.last, coincide(last.rect, rect) {
                // The wrapper adds a name, not a rectangle.
                levels[levels.count - 1] = InspectorLevel(
                    depth: last.depth,
                    rect: last.rect,
                    classNames: last.classNames + [className],
                    address: last.address,
                    identifier: last.identifier
                )
            } else {
                levels.append(InspectorLevel(
                    depth: levels.count,
                    rect: rect,
                    classNames: [className],
                    address: address(of: subject),
                    identifier: chosenIdentifier(of: subject)
                ))
            }

            current = subject.superview
        }

        return levels
    }

    /// The levels actually drawn for a set of layers: the whole chain under ⌃, and the target
    /// with the one level it sits in under ⌥ alone — a measure needs something to measure to.
    static func shown(_ levels: [InspectorLevel], for layers: InspectorLayers) -> [InspectorLevel] {
        if layers.contains(.hierarchy) { return levels }
        if layers.contains(.spacing) { return Array(levels.prefix(2)) }
        return Array(levels.prefix(1))
    }

    /// Two rectangles the eye reads as one. Views land on half points routinely, so this is a
    /// tolerance rather than an equality.
    static func coincide(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance = InspectorDefaults.coincidentTolerance
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.maxX - rhs.maxX) <= tolerance
            && abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    // MARK: - Private Methods

    /// AppKit stamps `_NS:…` identifiers on views it manages itself; only a name someone
    /// chose is worth reporting. The same rule `ElementReport.node` applies.
    private static func chosenIdentifier(of view: NSView) -> String? {
        guard let value = view.identifier?.rawValue,
              !value.isEmpty,
              !value.hasPrefix("_NS") else { return nil }
        return value
    }

    private static func address(of view: NSView) -> String {
        "0x" + String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16)
    }
}

// MARK: - Gaps

/// One measured distance between a level and the level outside it: which edge, how far, and
/// the line to draw for it.
struct InspectorGap: Equatable {

    enum Edge: String {
        case leading
        case trailing
        case top
        case bottom
    }

    let edge: Edge

    /// Points from the outer edge to the inner one. **Negative means the inner rectangle
    /// overflows its parent on that side**, which is the one measurement here that is a bug
    /// on its own rather than a value to judge.
    let distance: CGFloat

    /// The measure line, in window coordinates.
    let start: NSPoint
    let end: NSPoint

    var label: String { "\(Int(distance.rounded()))" }

    var isHorizontal: Bool { edge == .leading || edge == .trailing }

    /// The end of the measure at the *parent's* edge, and the end at the child's. Which of
    /// `start`/`end` is which depends on the edge, and every placement rule needs to know:
    /// the room to put a label that will not fit in the gap is on the parent's side.
    var outerEnd: NSPoint { edge == .leading || edge == .bottom ? start : end }
    var innerEnd: NSPoint { edge == .leading || edge == .bottom ? end : start }

    var span: CGFloat {
        isHorizontal ? abs(end.x - start.x) : abs(end.y - start.y)
    }

    /// Where the number could go, best first.
    ///
    /// **Small components are the case this exists for.** A 13pt icon in a 30pt row has four
    /// gaps around it, none of them as wide as the chip naming one — so the first choice, the
    /// middle of the measure, is available almost never and a rule that stops there draws
    /// every number on top of the thing being measured. Past it the label steps out beyond the
    /// parent's edge, where a tight layout still has room, and then perpendicular in both
    /// directions. The caller takes the first that is clear of what it has already placed.
    func labelCandidates(size: NSSize) -> [NSPoint] {
        let clearance = InspectorDefaults.labelClearance
        let middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)

        let extent = isHorizontal ? size.width : size.height
        let step = (isHorizontal ? size.height : size.width) + clearance
        let outward: CGFloat = isHorizontal
            ? (outerEnd.x < innerEnd.x ? -1 : 1)
            : (outerEnd.y < innerEnd.y ? -1 : 1)
        let reach = extent / 2 + clearance

        let beyond = isHorizontal
            ? NSPoint(x: outerEnd.x + outward * reach, y: middle.y)
            : NSPoint(x: middle.x, y: outerEnd.y + outward * reach)

        func shifted(_ point: NSPoint, by offset: CGFloat) -> NSPoint {
            isHorizontal
                ? NSPoint(x: point.x, y: point.y + offset)
                : NSPoint(x: point.x + offset, y: point.y)
        }

        var candidates: [NSPoint] = []
        if extent + clearance * 2 <= span {
            candidates.append(middle)
        }
        candidates += [
            beyond,
            shifted(beyond, by: step),
            shifted(beyond, by: -step),
            shifted(middle, by: step),
            shifted(middle, by: -step),
            shifted(beyond, by: step * 2),
            shifted(beyond, by: -step * 2)
        ]
        return candidates
    }
}

enum InspectorSpacing {

    /// The four gaps between `inner` and `outer`, dropping the flush ones.
    ///
    /// A flush edge is the common case — most views are pinned to at least one of their
    /// parent's edges — and drawing `0` four times around a fitted view is four numbers
    /// saying nothing. What is worth a line is a gap someone chose, or an overflow nobody did.
    static func gaps(from inner: NSRect, to outer: NSRect) -> [InspectorGap] {
        let measures: [(InspectorGap.Edge, CGFloat, NSPoint, NSPoint)] = [
            (
                .leading,
                inner.minX - outer.minX,
                NSPoint(x: outer.minX, y: inner.midY),
                NSPoint(x: inner.minX, y: inner.midY)
            ),
            (
                .trailing,
                outer.maxX - inner.maxX,
                NSPoint(x: inner.maxX, y: inner.midY),
                NSPoint(x: outer.maxX, y: inner.midY)
            ),
            // Horizontal pair then vertical, each named the way it is said aloud — "leading,
            // trailing, top, bottom" — since this order is also the order the key and the
            // report list them in.
            (
                .top,
                outer.maxY - inner.maxY,
                NSPoint(x: inner.midX, y: inner.maxY),
                NSPoint(x: inner.midX, y: outer.maxY)
            ),
            (
                .bottom,
                inner.minY - outer.minY,
                NSPoint(x: inner.midX, y: outer.minY),
                NSPoint(x: inner.midX, y: inner.minY)
            )
        ]

        return measures
            .filter { abs($0.1) > InspectorDefaults.minimumMeasuredGap }
            .map { InspectorGap(edge: $0.0, distance: $0.1, start: $0.2, end: $0.3) }
    }

    /// Every measured gap between consecutive drawn levels, outermost pair last.
    static func gaps(across levels: [InspectorLevel]) -> [(parent: InspectorLevel, gaps: [InspectorGap])] {
        guard levels.count > 1 else { return [] }

        return (0..<(levels.count - 1)).map { index in
            let inner = levels[index]
            let outer = levels[index + 1]
            return (parent: outer, gaps: gaps(from: inner.rect, to: outer.rect))
        }
    }

    /// The one-line form the report uses: `leading 12 · trailing 12 · top 8`.
    static func describe(_ gaps: [InspectorGap]) -> String {
        guard !gaps.isEmpty else { return InspectorStrings.flushOnEverySide }
        return gaps.map { "\($0.edge.rawValue) \($0.label)" }.joined(separator: " · ")
    }
}

// MARK: - Label Packing

/// Keeps the overlay's small labels off one another.
///
/// Everything the layers draw — the target's badge, a depth chip, a measured number — is a
/// little box that has to land near the thing it names, and around a small component they all
/// want the same few points. Placed independently they stack, and a stack of chips is worse
/// than no chips: the drawing looks like a rendering bug rather than a measurement.
///
/// So each label offers candidate positions in preference order and the packer takes the first
/// that is inside the window and clear of everything placed before it. **Order is therefore
/// priority**: the badge and the target's own gaps are placed first and keep the good spots.
struct InspectorLabelPacker {

    private(set) var placed: [NSRect] = []

    /// Reserves a rectangle already positioned by something else — the target's badge.
    mutating func reserve(_ rect: NSRect) {
        placed.append(rect)
    }

    /// The first candidate that fits and is clear, or the first one if none is.
    mutating func place(size: NSSize, candidates: [NSPoint], within bounds: NSRect) -> NSRect {
        var fallback: NSRect?

        for candidate in candidates {
            let rect = Self.rect(centeredAt: candidate, size: size, clampedTo: bounds)
            if fallback == nil { fallback = rect }

            let padded = rect.insetBy(
                dx: -InspectorDefaults.labelClearance,
                dy: -InspectorDefaults.labelClearance
            )
            guard !placed.contains(where: { $0.intersects(padded) }) else { continue }

            placed.append(rect)
            return rect
        }

        let rect = fallback ?? NSRect(origin: bounds.origin, size: size)
        placed.append(rect)
        return rect
    }

    static func rect(centeredAt point: NSPoint, size: NSSize, clampedTo bounds: NSRect) -> NSRect {
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }
}

// MARK: - Chip Placement

enum InspectorChipPlacement {

    /// Where a level's depth chip could go, best first.
    ///
    /// Inside the top-leading corner when the rectangle has room for it — and **outside** when
    /// it does not, which for a 13pt icon is always: a chip is 14pt, so drawn inside it would
    /// cover the element whole and hide the outline it belongs to.
    static func candidates(for rect: NSRect, size: NSSize) -> [NSPoint] {
        let inset = InspectorDefaults.chipInset
        let clearance = InspectorDefaults.labelClearance

        let fitsInside = rect.width >= size.width + inset * 2
            && rect.height >= size.height + inset * 2

        let inside = NSPoint(
            x: rect.minX + inset + size.width / 2,
            y: rect.maxY - inset - size.height / 2
        )
        let above = NSPoint(x: rect.minX + size.width / 2, y: rect.maxY + clearance + size.height / 2)
        let leading = NSPoint(x: rect.minX - clearance - size.width / 2, y: rect.maxY - size.height / 2)
        let below = NSPoint(x: rect.minX + size.width / 2, y: rect.minY - clearance - size.height / 2)

        return (fitsInside ? [inside] : []) + [above, leading, below]
    }
}

// MARK: - Legend Placement

/// Where the colour key sits, kept apart from the drawing because the rule is invisible in a
/// screenshot of any one window: **the corner furthest from what is being looked at**, so a
/// key never covers the thing it is a key to.
enum InspectorLegendPlacement {

    /// One line of the key: the hue it names, or none when the line is the fold.
    struct Row: Equatable {
        let hue: Design.Categorical.Hue?
        let title: String
    }

    static func origin(size: NSSize, target: NSRect, within bounds: NSRect) -> NSPoint {
        let onLeft = target.midX > bounds.midX
        return NSPoint(
            x: onLeft
                ? bounds.minX + Design.Spacing.inset
                : bounds.maxX - Design.Spacing.inset - size.width,
            y: bounds.minY + Design.Spacing.inset
        )
    }

    /// The rows the window has room for, target first, with anything past that folded into a
    /// last line saying how much was left out.
    ///
    /// **Every level is still outlined** — the fold bounds the key, not the drawing, and the
    /// report's own legend lists all of them because text has no corner to fit into. A key
    /// that ran off the bottom of the window would take the deepest rows with it silently,
    /// which is the one failure worse than saying "and four more".
    ///
    /// The measurements are restated here, and that is the answer to the case the numbers on
    /// the canvas cannot serve: **around a small element there is nowhere legible to put
    /// them**. A 13pt icon in a 30pt row has four gaps, three of them narrower than the chip
    /// naming one, so the chips step aside and end up as four numbers near a corner, correct
    /// and hard to read. The key has room, always, whatever is being pointed at — so the
    /// drawing keeps the numbers *where* they are and the key says which is which.
    static func rows(
        for levels: [InspectorLevel],
        layers: InspectorLayers,
        within bounds: NSRect
    ) -> [Row] {
        var rows = levels.map { Row(hue: $0.hue, title: title(for: $0)) }

        if layers.contains(.spacing) {
            rows += InspectorSpacing.gaps(across: levels).enumerated().map { index, pair in
                // No swatch: a measurement is about two of the colours above rather than being
                // a colour of its own, and a repeated swatch would say it named one.
                Row(
                    hue: nil,
                    title: "\(index) in \(pair.parent.depth) · "
                        + InspectorSpacing.describe(pair.gaps)
                )
            }
        }

        let rowHeight = InspectorDefaults.legendRowHeight
        let chrome = Design.Spacing.inset * 2 + Design.Spacing.medium * 2 + rowHeight
        let capacity = max(1, Int((bounds.height - chrome) / rowHeight))

        guard rows.count > capacity else { return rows }

        let shown = rows.prefix(max(1, capacity - 1))
        return Array(shown)
            + [Row(hue: nil, title: InspectorStrings.legendFold(rows.count - shown.count))]
    }

    private static func title(for level: InspectorLevel) -> String {
        "\(level.depth) · \(level.title) — \(level.size)"
    }
}
