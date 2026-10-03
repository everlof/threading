import AppKit
import Foundation

/// Contracts used by the unchanged production menu row. The important interaction is two
/// overlapping tracking areas on one view: the accessory crossing must name its own area.
@MainActor
enum MenuPlatformLeafTests {
    private static var failures: [String] = []

    static func run() -> Bool {
        failures = []
        trackingCrossingsRetainAreaIdentity()
        accessibilityLinksAndAction()
        descriptorAndGraphicsState()
        indexedTextRasterUsesGraphicsState()

        if failures.isEmpty {
            print("menu platform leaves: all cases pass")
            return true
        }
        for failure in failures { print("menu platform leaves FAIL: \(failure)") }
        return false
    }

    private static func trackingCrossingsRetainAreaIdentity() {
        let window = NSWindow()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let row = OverlappingTrackingView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(row)
        window.contentView = root
        defer { window.contentView = nil }

        for x in [100.0, 180, 100, 220] {
            window.dispatchToContent(NSEvent(type: .mouseMoved,
                                             locationInWindow: NSPoint(x: x, y: 20)))
        }
        expect("row and accessory crossings are separate",
               row.crossings == ["row entered", "accessory entered",
                                 "accessory exited", "row exited"])
        expect("crossing preserves physical window location", row.lastWindowPoint?.y == 20)
    }

    private static func accessibilityLinksAndAction() {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let submenu = NSView(frame: .zero)
        let preview = NSView(frame: .zero)
        row.addSubview(preview)
        row.setAccessibilityRole(.menuItem)
        submenu.setAccessibilityRole(.menu)
        submenu.setAccessibilityParent(row)
        expect("menu role", submenu.accessibilityRole() == .menu)
        expect("menu item role", row.accessibilityRole() == .menuItem)
        expect("submenu's explicit parent", submenu.accessibilityParent() as? NSView === row)
        expect("default child tree follows view tree", row.accessibilityChildren()?.count == 1)
        expect("default child tree returns preview", row.accessibilityChildren()?.first as? NSView === preview)
        submenu.setAccessibilityParent(nil)
        expect("cleared explicit parent", submenu.accessibilityParent() == nil)

        var called = 0
        let action = NSAccessibilityCustomAction(name: "Preview") {
            called += 1
            return true
        }
        expect("custom action retains name", action.name == "Preview")
        expect("custom action invokes closure", action.perform() && called == 1)
    }

    private static func descriptorAndGraphicsState() {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let resized = NSFont(descriptor: font.fontDescriptor, size: 14)
        expect("descriptor preserves family", resized?.familyName == font.familyName)
        expect("descriptor preserves weight", resized?.weight == font.weight)
        expect("descriptor applies requested size", resized?.pointSize == 14)
        expect("descriptor rejects invalid size", NSFont(descriptor: font.fontDescriptor, size: .infinity) == nil)

        let context = NSGraphicsContext(bitmap: Bitmap(width: 48, height: 20), scale: 1)
        let graphics = context.cgContext
        expect("text antialiases by default", context.antialiasesText)
        context.saveGraphicsState()
        graphics.setShouldAntialias(false)
        graphics.setAllowsAntialiasing(false)
        graphics.setShouldSmoothFonts(false)
        graphics.setAllowsFontSmoothing(false)
        expect("indexed text disables smoothing", !context.antialiasesText)
        context.restoreGraphicsState()
        expect("graphics restore returns smooth text", context.antialiasesText)
    }

    private static func indexedTextRasterUsesGraphicsState() {
        func alphas(antialias: Bool) -> [UInt8] {
            let bitmap = Bitmap(width: 64, height: 24)
            let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = context
            defer { NSGraphicsContext.current = previous }
            context.cgContext.setShouldAntialias(antialias)
            context.cgContext.setAllowsAntialiasing(antialias)
            context.cgContext.setShouldSmoothFonts(antialias)
            context.cgContext.setAllowsFontSmoothing(antialias)
            NSAttributedString(string: "Menu", attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.black
            ]).draw(in: NSRect(x: 0, y: 0, width: 64, height: 24))
            return stride(from: 3, to: bitmap.pixels.count, by: 4)
                .map { bitmap.pixels[$0] }
        }

        let smooth = alphas(antialias: true)
        let indexed = alphas(antialias: false)
        expect("smooth text paints glyphs", smooth.contains(255))
        expect("smooth text has edge coverage", smooth.contains { $0 > 0 && $0 < 255 })
        expect("indexed text paints glyphs", indexed.contains(255))
        expect("indexed text has only whole-pixel coverage",
               indexed.allSatisfy { $0 == 0 || $0 == 255 })
    }

    private static func expect(_ name: String, _ condition: Bool) {
        if !condition { failures.append(name) }
    }
}

@MainActor
private final class OverlappingTrackingView: NSView {
    var crossings: [String] = []
    var lastWindowPoint: NSPoint?
    private var rowArea: NSTrackingArea?
    private var accessoryArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rowArea { removeTrackingArea(rowArea) }
        if let accessoryArea { removeTrackingArea(accessoryArea) }
        rowArea = NSTrackingArea(rect: bounds,
                                 options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                 owner: self)
        accessoryArea = NSTrackingArea(rect: NSRect(x: 170, y: 10, width: 20, height: 20),
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self)
        addTrackingArea(rowArea!)
        addTrackingArea(accessoryArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        record(event, verb: "entered")
    }

    override func mouseExited(with event: NSEvent) {
        record(event, verb: "exited")
    }

    private func record(_ event: NSEvent, verb: String) {
        lastWindowPoint = event.locationInWindow
        let area = event.trackingArea === accessoryArea ? "accessory" :
                   event.trackingArea === rowArea ? "row" : "unknown"
        crossings.append("\(area) \(verb)")
    }
}
