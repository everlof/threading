import AppKit

/// A small filled disclosure cue painted inside an existing control surface. The owner chooses
/// its resolved ink, placement, state and action; this leaf owns only the shape and its optical
/// alignment. It can be used by a diagnostic backend without constructing an AppKit control.
@MainActor
enum DisclosureTriangleDrawing {
    enum Direction { case up, down }

    static func draw(in slot: NSRect, ink: NSColor, direction: Direction) {
        guard slot.width > 0, slot.height > 0 else { return }
        let side = min(slot.width, slot.height)
        let halfWidth = side * 0.4
        let halfHeight = side * 0.25
        let path = NSBezierPath()
        switch direction {
        case .up:
            path.move(to: NSPoint(x: -halfWidth, y: -halfHeight))
            path.line(to: NSPoint(x: halfWidth, y: -halfHeight))
            path.line(to: NSPoint(x: 0, y: halfHeight))
        case .down:
            path.move(to: NSPoint(x: -halfWidth, y: halfHeight))
            path.line(to: NSPoint(x: halfWidth, y: halfHeight))
            path.line(to: NSPoint(x: 0, y: -halfHeight))
        }
        path.close()
        ink.setFill()
        path.centringInk(in: slot).fill()
    }
}
