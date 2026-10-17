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

@MainActor
private func checkLayerBackgrounds(flipped: Bool) {
    let root = PaintedView(frame: NSRect(x: 0, y: 0, width: 24, height: 24), flipped: flipped)
    let parent = PaintedView(frame: NSRect(x: 4, y: 4, width: 12, height: 12), flipped: flipped)
    parent.wantsLayer = true
    parent.layer?.backgroundColor = NSColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor
    let child = PaintedView(frame: NSRect(x: 7, y: 2, width: 10, height: 10), flipped: flipped)
    child.wantsLayer = true
    child.layer?.backgroundColor = NSColor(red: 0, green: 0, blue: 1, alpha: 1).cgColor
    let painted = PaintedView(frame: NSRect(x: 2, y: 2, width: 4, height: 4),
                              ink: .black, flipped: flipped)
    painted.wantsLayer = true
    painted.layer?.backgroundColor = NSColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor
    root.addSubview(parent)
    parent.addSubview(child)
    parent.addSubview(painted)
    let bitmap = Bitmap(width: 24, height: 24, background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    expect(bitmap, 5, 5, flipped: flipped, equal: [255, 0, 0, 255], "backing-layer fill absent")
    expect(bitmap, 12, 9, flipped: flipped, equal: [0, 0, 255, 255], "nested layer fill absent")
    expect(bitmap, 7, 7, flipped: flipped, equal: [0, 0, 0, 255], "layer painted over view contents")
    expect(bitmap, 17, 8, flipped: flipped, equal: [255, 255, 255, 255], "layer escaped ancestor clip")
    parent.alphaValue = 0.5
    let faded = Bitmap(width: 24, height: 24, background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: faded, scale: 1))
    expect(faded, 5, 5, flipped: flipped, equal: [255, 128, 128, 255], "layer ignored view alpha")
    let copy = CALayer(layer: parent.layer!)
    precondition(copy.backgroundColor == parent.layer!.backgroundColor, "copied layer lost its fill")
    parent.wantsLayer = false
    let detached = Bitmap(width: 24, height: 24, background: (1, 1, 1, 1))
    root.render(in: NSGraphicsContext(bitmap: detached, scale: 1))
    expect(detached, 5, 5, flipped: flipped, equal: [255, 255, 255, 255], "removed backing layer still painted")
}

@MainActor
private func expectNear(_ bitmap: Bitmap, _ x: Int, _ y: Int, flipped: Bool,
                        _ expected: [Int], _ reason: String) {
    let actual = pixel(bitmap, x, y, flipped: flipped).map(Int.init)
    precondition(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1 },
                 "\(reason) at (\(x), \(y)): \(actual) != \(expected)")
}

/// The production long-message fade: opaque, then the last quarter falling to clear, along unit
/// y from 0 to 1. Unit y = 0 is the view's top when it is flipped and its bottom otherwise.
@MainActor
private func checkGradientMasks(flipped: Bool) {
    let root = PaintedView(frame: NSRect(x: 0, y: 0, width: 24, height: 24), flipped: flipped)
    let masked = PaintedView(frame: NSRect(x: 2, y: 2, width: 20, height: 20), ink: .black, flipped: flipped)
    let child = PaintedView(frame: NSRect(x: 12, y: 0, width: 8, height: 20),
                            ink: NSColor(red: 0, green: 0, blue: 1, alpha: 1), flipped: flipped)
    masked.addSubview(child)
    root.addSubview(masked)
    masked.wantsLayer = true
    let fade = CAGradientLayer()
    fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
    fade.locations = [0, 0.75, 1]
    fade.frame = masked.bounds
    masked.layer?.mask = fade

    func render() -> Bitmap {
        let bitmap = Bitmap(width: 24, height: 24, background: (1, 1, 1, 1))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
        return bitmap
    }
    // Root coordinates grow downward when flipped, so unit y = 0 is at root y 2 either way
    // for the flipped view, and at root y 2 from the bottom for the unflipped one.
    var bitmap = render()
    expect(bitmap, 6, 3, flipped: flipped, equal: [0, 0, 0, 255], "opaque mask start lost ink")
    expectNear(bitmap, 6, 18, flipped: flipped, [77, 77, 77, 255], "fade midpoint")
    expectNear(bitmap, 6, 21, flipped: flipped, [230, 230, 230, 255], "fade end")
    expectNear(bitmap, 16, 18, flipped: flipped, [77, 77, 255, 255], "mask skipped a subview")
    expect(bitmap, 1, 1, flipped: flipped, equal: [255, 255, 255, 255], "masked view escaped its frame")

    masked.alphaValue = 0.5
    bitmap = render()
    expectNear(bitmap, 6, 3, flipped: flipped, [128, 128, 128, 255], "mask ignored view alpha")
    masked.alphaValue = 1

    fade.frame = NSRect(x: 0, y: 0, width: 10, height: 20)
    bitmap = render()
    expect(bitmap, 16, 3, flipped: flipped, equal: [255, 255, 255, 255],
           "content outside the mask frame was drawn")
    expect(bitmap, 6, 3, flipped: flipped, equal: [0, 0, 0, 255], "mask frame lost its interior")

    let plain = CALayer()
    plain.frame = masked.bounds
    plain.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
    masked.layer?.mask = plain
    bitmap = render()
    expectNear(bitmap, 6, 10, flipped: flipped, [128, 128, 128, 255], "plain mask alpha")

    masked.layer?.mask = nil
    bitmap = render()
    expect(bitmap, 6, 21, flipped: flipped, equal: [0, 0, 0, 255], "removed mask still faded")
}

@MainActor
private final class TrackedDocument: NSView {
    var moves = 0, entries = 0, exits = 0
    var dirtyRects: [NSRect] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { dirtyRects.append(dirtyRect) }
    override func mouseMoved(with event: NSEvent) { moves += 1 }
    override func mouseEntered(with event: NSEvent) { entries += 1 }
    override func mouseExited(with event: NSEvent) { exits += 1 }
}

@MainActor
private func checkTrackedDocumentViewport() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
    let scroll = NSScrollView(frame: NSRect(x: 10, y: 10, width: 100, height: 80))
    let document = TrackedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 48_000))
    root.addSubview(scroll)
    scroll.documentView = document
    let window = NSWindow()
    window.contentView = root
    window.isKeyWindow = true
    root.layoutSubtreeIfNeeded()
    document.addTrackingArea(NSTrackingArea(rect: .zero,
        options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: document))
    let target = NSRect(x: 280, y: 24_000, width: 60, height: 48)
    precondition(document.scrollToVisible(target), "far focused cell must reveal both axes")
    precondition(document.visibleRect.contains(target), "focused cell remains clipped after reveal")
    precondition(!document.scrollToVisible(target), "revealing a visible cell must not scroll again")
    let bitmap = Bitmap(width: 160, height: 120)
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    precondition(document.dirtyRects == [document.visibleRect],
                 "a large document must receive the viewport dirty rect, not all 1,000 rows")
    let point = document.convert(NSPoint(x: target.midX, y: target.midY), to: nil)
    let event = NSEvent(type: .mouseMoved, window: window, locationInWindow: point)
    _ = window.dispatchToContent(event)
    _ = window.dispatchToContent(event)
    precondition(document.moves == 2 && document.entries == 1 && document.exits == 0,
                 "movement inside one tracking area must deliver every move without duplicate entry")
    let cover = NSView(frame: scroll.frame)
    root.addSubview(cover)
    _ = window.dispatchToContent(event)
    precondition(document.moves == 2 && document.exits == 1, "covered document received a pointer move")
    cover.removeFromSuperview()
    window.isKeyWindow = false
    _ = window.dispatchToContent(event)
    precondition(document.moves == 2, "inactive tracking area received a move")
    window.isKeyWindow = true
    _ = window.dispatchToContent(event)
    precondition(document.moves == 3 && document.entries == 2, "reactivated tracking area did not recover")
}

@MainActor
private func checkRadialGradientAndSymbolPalette() {
    let bitmap = Bitmap(width: 80, height: 80)
    let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = nil }
    context.translateBy(x: 4, y: 6)
    context.alpha = 0.5
    let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 20, height: 16))
    let gradient = NSGradient(starting: NSColor(red: 1, green: 0, blue: 0, alpha: 0.8),
                              ending: NSColor(red: 0, green: 0, blue: 1, alpha: 0))!
    gradient.draw(in: path, relativeCenterPosition: .zero)
    // Device point (28.5, 51.5) is user point (10.25, 8.25), close to the radial center.
    let center = pixel(bitmap, 28, 51, flipped: true).map(Int.init)
    let fraction = hypot(0.25, 0.25) / hypot(10, 8)
    let expected = [Int((255 * (1 - fraction)).rounded()), 0,
                    Int((255 * fraction).rounded()), Int((255 * 0.4 * (1 - fraction)).rounded())]
    precondition(zip(center, expected).allSatisfy { abs($0 - $1) <= 1 },
                 "radial interpolation, transform or inherited alpha differs: \(center) != \(expected)")
    expect(bitmap, 8, 67, flipped: true, equal: [0, 0, 0, 0], "halo escaped its oval clip")
    precondition(bitmap.pixels.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element <= 102 },
                 "translucent radial halo accumulated overlapping fills")

    let source = NSImage(rgba: [0, 0, 0, 255, 0, 0, 0, 128], width: 2, height: 1,
                         size: NSSize(width: 2, height: 1))!
    source.isTemplate = true
    let ink = NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.5)
    let palette = NSImage.SymbolConfiguration(paletteColors: [ink])
    let tinted = source.withSymbolConfiguration(palette)
    precondition(tinted.size == source.size && !tinted.isTemplate,
                 "palette-only configuration changed artwork geometry or left its ink as a template")
    let composed = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(palette)
    precondition(composed.pointSize == 12 && composed.weight == .medium,
                 "palette composition discarded symbol size/weight")
    let destination = Bitmap(width: 2, height: 1)
    NSGraphicsContext.current = NSGraphicsContext(bitmap: destination, scale: 1)
    tinted.draw(in: NSRect(x: 0, y: 0, width: 2, height: 1))
    expect(destination, 0, 0, flipped: true, equal: [51, 153, 255, 128], "palette ink was not applied")
    expect(destination, 1, 0, flipped: true, equal: [51, 153, 255, 64], "palette discarded source alpha")
}

@main
private struct ViewClippingFixture {
    @MainActor static func main() {
        checkNestedViews(flipped: false, ownClip: false)
        checkNestedViews(flipped: true, ownClip: false)
        checkNestedViews(flipped: false, ownClip: true)
        checkNestedViews(flipped: true, ownClip: true)
        checkSubviewOrdering()
        checkLayerBackgrounds(flipped: false)
        checkLayerBackgrounds(flipped: true)
        checkGradientMasks(flipped: false)
        checkGradientMasks(flipped: true)
        checkScrollViewport()
        checkTrackedDocumentViewport()
        checkRadialGradientAndSymbolPalette()
        print("PASS view bounds, clipping, ordering, layer masks, and scroll viewport geometry, rendering and wheel routing")
    }
}
