import AppKit

// MARK: - Capture Geometry

/// What the overlay's floating panels must not cover.
///
/// The **target and its badge**, deliberately — not every level that is outlined. Under ⌃ the
/// chain runs all the way out to the window's own frame view, so "avoid every level" reports
/// every corner as covered and no placement can improve on any other. What the eye is actually
/// on is the filled rectangle and the label naming it.
@MainActor
enum InspectorCaptureGeometry {

    /// The rectangle the capture is *about*, which is also what a panel's preferred corner is
    /// chosen away from.
    static func subject(of indicator: InspectorIndicator) -> NSRect {
        switch indicator {
        case .element(let levels, _):
            return levels.first?.rect ?? .zero
        case .region(let rect, _):
            return rect
        case .point(let point, _):
            let radius = InspectorDefaults.markerRadius
            return NSRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    static func obstacles(for indicator: InspectorIndicator, within bounds: NSRect) -> [NSRect] {
        switch indicator {
        case .element(let levels, _):
            guard let target = levels.first else { return [] }
            return obstacles(
                for: target.rect,
                label: InspectorHierarchyDrawing.badgeLabel(for: target),
                within: bounds
            )

        case .region(let rect, let label):
            return obstacles(for: rect, label: label, within: bounds)

        case .point(let point, let label):
            // The badge hangs off the marker exactly as `drawPoint` places it, so the panel
            // dodges the label rather than the pixel under the pointer.
            let anchor = NSRect(
                origin: NSPoint(x: point.x + Design.Spacing.medium, y: point.y),
                size: .zero
            )
            return [
                subject(of: indicator),
                InspectorDrawing.badgeRect(label, above: anchor, within: bounds)
            ]
        }
    }

    static func obstacles(for rect: NSRect, label: String, within bounds: NSRect) -> [NSRect] {
        [rect, InspectorDrawing.badgeRect(label, above: rect, within: bounds)]
    }
}

// MARK: - Panel Placement

enum InspectorPanelCorner: CaseIterable {
    case bottomLeading
    case bottomTrailing
    case topLeading
    case topTrailing

    /// The other corner along the same edge — how the two panels divide the window between
    /// them without either consulting the other's position.
    var mirrored: InspectorPanelCorner {
        switch self {
        case .bottomLeading: return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        case .topLeading: return .topTrailing
        case .topTrailing: return .topLeading
        }
    }
}

/// Where a panel floating over the window goes: a preferred corner, and the first alternative
/// that is clear when the preferred one is covered by what is being captured.
///
/// **The search cannot oscillate**, which is why no hysteresis is needed: a panel's position
/// never feeds back into the obstacles it is dodging. The capture rectangle is whatever the
/// pointer is on, the key is placed before the hint and never told where the hint went, so
/// each frame's answer depends only on that frame's pointer.
///
/// Geometry only, and deliberately not actor-isolated: `InspectorLegendPlacement` is the same,
/// and a placement rule that can be evaluated off the main thread is a placement rule a test
/// can assert without a window.
enum InspectorPanelPlacement {

    struct Placement {
        let rect: NSRect

        /// True when every corner was covered and the preferred one was taken anyway. The
        /// caller draws it faded rather than looking for a fifth position.
        let isObstructed: Bool
    }

    static func rect(
        size: NSSize,
        corner: InspectorPanelCorner,
        within bounds: NSRect
    ) -> NSRect {
        let inset = Design.Spacing.inset
        let x: CGFloat
        let y: CGFloat

        switch corner {
        case .bottomLeading, .topLeading:
            x = bounds.minX + inset
        case .bottomTrailing, .topTrailing:
            x = bounds.maxX - inset - size.width
        }

        switch corner {
        case .bottomLeading, .bottomTrailing:
            y = bounds.minY + inset
        case .topLeading, .topTrailing:
            y = bounds.maxY - inset - size.height
        }

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func place(
        size: NSSize,
        preferring preferred: InspectorPanelCorner,
        avoiding obstacles: [NSRect],
        within bounds: NSRect
    ) -> Placement {
        // The preferred corner first, then the rest in a fixed order — bottom before top,
        // since the top of this window is chrome and a panel there reads as an alert.
        let order = [preferred] + InspectorPanelCorner.allCases.filter { $0 != preferred }

        for corner in order {
            let candidate = rect(size: size, corner: corner, within: bounds)
            guard isCovered(candidate, by: obstacles) else {
                return Placement(rect: candidate, isObstructed: false)
            }
        }

        return Placement(
            rect: rect(size: size, corner: preferred, within: bounds),
            isObstructed: true
        )
    }

    private static func isCovered(_ rect: NSRect, by obstacles: [NSRect]) -> Bool {
        let clearance = InspectorDefaults.panelClearance
        let padded = rect.insetBy(dx: -clearance, dy: -clearance)
        return obstacles.contains { !$0.isEmpty && $0.intersects(padded) }
    }

    /// Runs the drawing inside `body` at a reduced alpha — the last resort when a panel has
    /// nowhere clear to go.
    @MainActor
    static func withAlpha(_ alpha: CGFloat, _ body: () -> Void) {
        guard alpha < 1 else {
            body()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Hint Tokens

/// One control on the hint line, and how live it is right now.
struct InspectorHintToken: Equatable {

    enum Emphasis {
        /// Held at this moment — the hint doubles as a readout of what is on.
        case held
        /// Offered, and would do something if pressed.
        case available
        /// Does nothing in the mode currently showing, so it is legible but plainly off.
        case inapplicable
    }

    let text: String
    let emphasis: Emphasis
}

/// The line that says the overlay's controls exist at all.
///
/// It is drawn whether anything is held or not, and in **both** modes — a modifier nothing
/// mentions is a feature nobody finds, and with the two commands collapsed into one there is
/// no menu item left to name freeflow. It was the one thing the old freeflow overlay never
/// said: nothing on screen suggested that a drag meant a region.
///
/// **It is not part of the capture.** The colour key is — the report's text names those hues,
/// so anyone holding only the picture and the markdown needs both halves. A hint about working
/// an overlay that is gone by the time the issue is read is noise in a filed screenshot, and
/// it was being baked into every one of them.
@MainActor
enum InspectorHint {

    static func tokens(for indicator: InspectorIndicator) -> [InspectorHintToken] {
        switch indicator {
        case .element(_, let layers):
            return [
                InspectorHintToken(text: InspectorStrings.pointHint, emphasis: .available),
                InspectorHintToken(text: InspectorStrings.regionHint, emphasis: .available),
                InspectorHintToken(
                    text: InspectorStrings.hierarchyHint,
                    emphasis: layers.contains(.hierarchy) ? .held : .available
                ),
                InspectorHintToken(
                    text: InspectorStrings.spacingHint,
                    emphasis: layers.contains(.spacing) ? .held : .available
                ),
                InspectorHintToken(text: InspectorStrings.exitHint, emphasis: .available)
            ]

        // Nothing is detected under ⇧ or mid-drag, so there is no element for ⌃ and ⌥ to layer
        // onto. They stay on the line — a control that vanishes reads as a control that broke —
        // and say so by being drawn plainly off.
        case .point, .region:
            return [
                InspectorHintToken(
                    text: InspectorStrings.pointHint,
                    emphasis: isPoint(indicator) ? .held : .available
                ),
                InspectorHintToken(
                    text: InspectorStrings.regionHint,
                    emphasis: isPoint(indicator) ? .available : .held
                ),
                InspectorHintToken(text: InspectorStrings.hierarchyHint, emphasis: .inapplicable),
                InspectorHintToken(text: InspectorStrings.spacingHint, emphasis: .inapplicable),
                InspectorHintToken(text: InspectorStrings.exitHint, emphasis: .available)
            ]
        }
    }

    /// The corner the hint wants: the bottom one the *key* does not want, so the two divide the
    /// window between them and neither jumps when ⌃ is pressed.
    static func preferredCorner(
        for indicator: InspectorIndicator,
        within bounds: NSRect
    ) -> InspectorPanelCorner {
        InspectorLegendPlacement
            .preferredCorner(target: InspectorCaptureGeometry.subject(of: indicator), within: bounds)
            .mirrored
    }

    private static func isPoint(_ indicator: InspectorIndicator) -> Bool {
        if case .point = indicator { return true }
        return false
    }
}

// MARK: - Hint Drawing

@MainActor
enum InspectorHintDrawing {

    private static let separator = " · "

    static func draw(
        for indicator: InspectorIndicator,
        avoiding occupied: [NSRect],
        within bounds: NSRect
    ) {
        let text = attributed(InspectorHint.tokens(for: indicator))
        let textSize = text.size()

        let size = NSSize(
            width: min(
                ceil(textSize.width) + Design.Spacing.medium * 2,
                max(0, bounds.width - Design.Spacing.inset * 2)
            ),
            height: InspectorDefaults.legendRowHeight + Design.Spacing.medium * 2
        )
        guard size.width > 0, size.height > 0 else { return }

        let placement = InspectorPanelPlacement.place(
            size: size,
            preferring: InspectorHint.preferredCorner(for: indicator, within: bounds),
            avoiding: InspectorCaptureGeometry.obstacles(for: indicator, within: bounds) + occupied,
            within: bounds
        )

        let alpha = placement.isObstructed ? InspectorDefaults.obstructedPanelAlpha : 1
        InspectorPanelPlacement.withAlpha(alpha) {
            InspectorDrawing.panel(
                placement.rect,
                radius: Design.Radius.panel,
                border: Design.Surface.border
            )

            text.draw(in: placement.rect.insetBy(
                dx: Design.Spacing.medium,
                dy: Design.Spacing.medium
            ))
        }
    }

    /// One attributed string rather than a token-by-token layout: the panel is sized from this
    /// very string, and measuring the parts separately is how a line ends up a hair wider than
    /// the box drawn for it.
    static func attributed(_ tokens: [InspectorHintToken]) -> NSAttributedString {
        let line = NSMutableAttributedString()

        for (index, token) in tokens.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(
                    string: separator,
                    attributes: attributes(for: .inapplicable)
                ))
            }
            line.append(NSAttributedString(
                string: token.text,
                attributes: attributes(for: token.emphasis)
            ))
        }

        return line
    }

    private static func attributes(
        for emphasis: InspectorHintToken.Emphasis
    ) -> [NSAttributedString.Key: Any] {
        InspectorDrawing.textAttributes(
            font: Design.Typography.detail(),
            color: color(for: emphasis),
            truncating: true
        )
    }

    private static func color(for emphasis: InspectorHintToken.Emphasis) -> NSColor {
        switch emphasis {
        case .held: return Design.Text.label
        case .available: return Design.Text.secondary
        case .inapplicable: return Design.Text.tertiary
        }
    }
}
