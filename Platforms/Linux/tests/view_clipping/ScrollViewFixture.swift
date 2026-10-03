import AppKit
import Foundation

@MainActor
private class StripeDocument: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 8, height: 8))
        NSColor(red: 0, green: 0, blue: 1, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 8, width: 8, height: 8))
    }
}

@MainActor
private final class FlippedStripeDocument: StripeDocument {
    override var isFlipped: Bool { true }
}

@MainActor
private func viewportPixel(_ root: NSView) -> [UInt8] {
    let bitmap = Bitmap(width: 20, height: 20)
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    let index = ((bitmap.height - 1 - 3) * bitmap.width + 3) * 4
    return Array(bitmap.pixels[index..<(index + 4)])
}

@MainActor
func checkScrollViewport() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let scroll = NSScrollView(frame: NSRect(x: 2, y: 2, width: 8, height: 8))
    let document = StripeDocument(frame: NSRect(x: 0, y: 0, width: 8, height: 20))
    root.addSubview(scroll)
    scroll.documentView = document

    precondition(viewportPixel(root) == [255, 0, 0, 255], "initial document stripe missing")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 8))
    precondition(scroll.contentView.bounds.origin == NSPoint(x: 0, y: 8), "clip did not scroll")
    precondition(document.visibleRect == NSRect(x: 0, y: 8, width: 8, height: 8),
                 "document visible rect ignored clip bounds origin")
    precondition(scroll.contentView.documentVisibleRect == document.visibleRect,
                 "clip documentVisibleRect differs from actual visibility")
    precondition(document.convert(NSPoint(x: 1, y: 9), to: root) == NSPoint(x: 3, y: 3),
                 "point conversion ignored clip bounds origin")
    precondition(root.hitTest(NSPoint(x: 3, y: 3)) === document,
                 "hit testing missed scrolled document")
    precondition(viewportPixel(root) == [0, 0, 255, 255], "scrolled stripe did not render")

    let window = NSWindow()
    window.contentView = root
    window.dispatchToContent(NSEvent(type: .scrollWheel, locationInWindow: NSPoint(x: 3, y: 3),
                                     scrollingDeltaY: -1))
    precondition(scroll.contentView.bounds.origin.y == 12, "wheel did not clamp at document end")
    window.dispatchToContent(NSEvent(type: .scrollWheel, locationInWindow: NSPoint(x: 3, y: 3),
                                     scrollingDeltaY: 1))
    precondition(scroll.contentView.bounds.origin.y == 2, "wheel did not travel toward beginning")

    scroll.contentView.scroll(to: NSPoint(x: 0, y: 12))
    scroll.frame.size.height = 12
    precondition(scroll.contentView.frame.height == 12, "viewport did not resize with scroll view")
    precondition(scroll.contentView.bounds.origin.y == 8, "resize did not clamp scroll position")
    scroll.documentView = nil
    precondition(scroll.contentView.bounds.origin == .zero && document.superview == nil,
                 "detaching document retained old scroll geometry or parent")

    let flippedRoot = NSView(frame: root.frame)
    let flippedScroll = NSScrollView(frame: NSRect(x: 2, y: 2, width: 8, height: 8))
    let flippedDocument = FlippedStripeDocument(frame: document.frame)
    flippedRoot.addSubview(flippedScroll)
    flippedScroll.documentView = flippedDocument
    flippedScroll.contentView.scroll(to: NSPoint(x: 0, y: 8))
    precondition(flippedScroll.contentView.isFlipped, "clip did not inherit document orientation")
    precondition(flippedDocument.visibleRect == NSRect(x: 0, y: 8, width: 8, height: 8),
                 "flipped document visibility ignored scroll offset")
    precondition(flippedDocument.convert(NSPoint(x: 1, y: 15), to: flippedRoot)
                 == NSPoint(x: 3, y: 3), "flipped point conversion ignored scroll offset")
    precondition(flippedRoot.hitTest(NSPoint(x: 3, y: 3)) === flippedDocument,
                 "flipped hit test missed scrolled document")
    precondition(viewportPixel(flippedRoot) == [0, 0, 255, 255],
                 "flipped scrolled stripe did not render")
}
