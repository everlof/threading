import AppKit
import Foundation

@MainActor
private final class PaintedView: NSView {
    let ink: NSColor?
    let flipped: Bool
    let ownClip: NSRect?

    init(frame: NSRect, ink: NSColor? = nil, flipped: Bool, ownClip: NSRect? = nil) {
        self.ink = ink
        self.flipped = flipped
        self.ownClip = ownClip
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("view clipping fixture is created in code") }

    override var isFlipped: Bool { flipped }

    override func draw(_ dirtyRect: NSRect) {
        if let ownClip { NSBezierPath(rect: ownClip).addClip() }
        guard let ink else { return }
        ink.setFill()
        NSBezierPath.fill(bounds.insetBy(dx: -4, dy: -4))
    }
}

@MainActor
private func pixel(_ bitmap: Bitmap, _ x: Int, _ y: Int, flipped: Bool) -> [UInt8] {
    let deviceY = flipped ? y : bitmap.height - 1 - y
    let index = (deviceY * bitmap.width + x) * 4
    return Array(bitmap.pixels[index..<(index + 4)])
}

@MainActor
private func expect(_ bitmap: Bitmap, _ x: Int, _ y: Int, flipped: Bool,
                    equal expected: [UInt8], _ reason: String) {
    let actual = pixel(bitmap, x, y, flipped: flipped)
    precondition(actual == expected, "\(reason) at (\(x), \(y)): \(actual) != \(expected)")
}

@MainActor
private func checkNestedViews(flipped: Bool, ownClip: Bool) {
    let root = PaintedView(frame: NSRect(x: 0, y: 0, width: 24, height: 24), flipped: flipped)
    let parent = PaintedView(frame: NSRect(x: 4, y: 4, width: 12, height: 12),
                             ink: NSColor(red: 1, green: 0, blue: 0, alpha: 1), flipped: flipped,
                             ownClip: ownClip ? NSRect(x: 2, y: 2, width: 8, height: 8) : nil)
    let child = PaintedView(frame: NSRect(x: 7, y: 2, width: 10, height: 10),
                            ink: NSColor(red: 0, green: 0, blue: 1, alpha: 1), flipped: flipped)
    let grandchild = PaintedView(frame: NSRect(x: 2, y: 2, width: 8, height: 8),
                                 ink: NSColor(red: 0, green: 1, blue: 0, alpha: 1), flipped: flipped)
    let sibling = PaintedView(frame: NSRect(x: 18, y: 9, width: 4, height: 4),
                              ink: NSColor(red: 1, green: 1, blue: 0, alpha: 1), flipped: flipped)
    root.addSubview(parent)
    parent.addSubview(child)
    child.addSubview(grandchild)
    root.addSubview(sibling)

    let bitmap = Bitmap(width: 24, height: 24)
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))

    let clear: [UInt8] = [0, 0, 0, 0]
    let red: [UInt8] = [255, 0, 0, 255]
    let blue: [UInt8] = [0, 0, 255, 255]
    let green: [UInt8] = [0, 255, 0, 255]
    let yellow: [UInt8] = [255, 255, 0, 255]
    expect(bitmap, 3, 10, flipped: flipped, equal: clear, "parent drawing escaped left bound")
    expect(bitmap, 17, 8, flipped: flipped, equal: clear, "nested drawing escaped right bound")
    expect(bitmap, 14, 17, flipped: flipped, equal: clear, "nested drawing escaped top bound")
    expect(bitmap, 19, 10, flipped: flipped, equal: yellow, "parent clip leaked into sibling")
    if ownClip {
        expect(bitmap, 6, 6, flipped: flipped, equal: red, "custom clipped parent lost in-bounds ink")
        expect(bitmap, 12, 9, flipped: flipped, equal: blue, "custom clipped child lost in-bounds ink")
        expect(bitmap, 13, 9, flipped: flipped, equal: green, "custom clip lost grandchild ink")
        expect(bitmap, 15, 9, flipped: flipped, equal: clear, "custom clip failed on descendant")
    } else {
        expect(bitmap, 5, 5, flipped: flipped, equal: red, "parent lost in-bounds ink")
        expect(bitmap, 12, 9, flipped: flipped, equal: blue, "child lost in-bounds ink")
        expect(bitmap, 14, 9, flipped: flipped, equal: green, "grandchild lost in-bounds ink")
    }
}

@MainActor
private func checkSubviewOrdering() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
    let a = NSView(frame: root.bounds)
    let b = NSView(frame: root.bounds)
    let c = NSView(frame: root.bounds)
    let d = NSView(frame: root.bounds)
    let e = NSView(frame: root.bounds)
    let f = NSView(frame: root.bounds)
    root.addSubview(a)
    root.addSubview(b)
    root.addSubview(c, positioned: .above, relativeTo: nil)
    root.addSubview(d, positioned: .below, relativeTo: nil)
    root.addSubview(e, positioned: .above, relativeTo: a)
    root.addSubview(f, positioned: .below, relativeTo: a)
    let expected = [d, f, a, e, b, c]
    precondition(zip(root.subviews, expected).allSatisfy { $0.0 === $0.1 },
                 "subview order differs from AppKit")
    precondition(root.hitTest(NSPoint(x: 1, y: 1)) === c,
                 "top ordered subview must receive pointer hit")

    root.addSubview(c, positioned: .below, relativeTo: nil)
    precondition(root.subviews.first === c, "reordered subview must move below all siblings")
    precondition(root.hitTest(NSPoint(x: 1, y: 1)) === b,
                 "hit testing must use the reordered stack")
}

@main
private struct ViewClippingFixture {
    @MainActor static func main() {
        checkNestedViews(flipped: false, ownClip: false)
        checkNestedViews(flipped: true, ownClip: false)
        checkNestedViews(flipped: false, ownClip: true)
        checkNestedViews(flipped: true, ownClip: true)
        checkSubviewOrdering()
        print("PASS view bounds, descendant, explicit and sibling clipping in both orientations; ordered subviews")
    }
}
