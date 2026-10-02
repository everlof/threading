import AppKit
import Foundation

@MainActor
enum BackingAlignmentTests {
    static func run() -> Bool {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let bitmap = Bitmap(width: 100, height: 100)
        let context = NSGraphicsContext(bitmap: bitmap, scale: 2)
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = nil }

        let proposed = NSRect(x: 0.2, y: 0.2, width: 4.6, height: 2.6)
        let aligned = view.backingAlignedRect(proposed, options: .alignAllEdgesInward)
        guard aligned == NSRect(x: 0.5, y: 0.5, width: 4, height: 2) else {
            print("backing alignment FAIL: inward 2× edges: \(aligned)")
            return false
        }

        context.saveGraphicsState()
        context.translateBy(x: 0.25, y: 0)
        let nested = view.backingAlignedRect(NSRect(x: 0, y: 0, width: 5, height: 5),
                                             options: .alignAllEdgesInward)
        context.restoreGraphicsState()
        guard nested == NSRect(x: 0.25, y: 0, width: 4.5, height: 5) else {
            print("backing alignment FAIL: nested fractional origin: \(nested)")
            return false
        }

        let tiny = view.backingAlignedRect(NSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                           options: .alignAllEdgesInward)
        guard tiny.width == 0, tiny.height == 0 else {
            print("backing alignment FAIL: subpixel image expanded: \(tiny)")
            return false
        }

        print("backing alignment: all cases pass")
        return true
    }
}
