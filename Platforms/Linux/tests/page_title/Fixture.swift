import AppKit
import Foundation

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), "Page title contract: \(message)")
}

@MainActor private final class TerminalGround: NSView {
    override func draw(_ dirtyRect: NSRect) {
        InkSource.backdropGround.setFill()
        bounds.fill()
    }
}

@MainActor private func capture(_ root: NSView, to url: URL) throws -> [UInt8] {
#if os(Linux)
    let black = CGFloat(24) / 255
    let bitmap = Bitmap(width: Int(root.bounds.width), height: Int(root.bounds.height),
                        background: (black, black, black, 1))
    root.render(in: NSGraphicsContext(bitmap: bitmap, scale: 1))
    try PNGWriter.write(bitmap, to: url)
    return bitmap.pixels
#else
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
        fatalError("AppKit did not allocate a title image")
    }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("AppKit did not encode the title image")
    }
    try png.write(to: url)
    return []
#endif
}

@MainActor private func titlePoint(_ title: PageTitleView, in root: NSView) -> NSPoint {
    root.convert(NSPoint(x: 8, y: title.bounds.midY), from: title)
}

@MainActor private func actionsPoint(_ title: PageTitleView, in root: NSView) -> NSPoint {
    root.convert(NSPoint(x: title.actionsAnchor.bounds.midX,
                         y: title.actionsAnchor.bounds.midY), from: title.actionsAnchor)
}

#if os(Linux)
@MainActor private func event(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint) -> NSEvent {
    NSEvent(type: type, window: window, locationInWindow: point)
}
#endif

@main struct PageTitleHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: PageTitleHarness OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let root = TerminalGround(frame: NSRect(x: 0, y: 0, width: 340, height: 96))
#if os(Linux)
        let window = NSWindow()
#else
        _ = NSApplication.shared
        let window = NSWindow(contentRect: root.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
#endif
        window.contentView = root
        let title = PageTitleView(symbolName: "terminal", inkSource: .backdrop)
        title.update(title: "A long terminal conversation title", symbolName: "terminal",
                     identity: "conversation-1")
        title.maxWidth = 260
        title.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(title)
        title.frame = NSRect(x: 16, y: 34, width: title.intrinsicContentSize.width, height: 28)

        var reveals = 0
        var actions = 0
        title.onReveal = { reveals += 1 }
        title.onActions = { anchor in
            require(anchor === title.actionsAnchor, "Actions callback lost its anchor")
            actions += 1
        }
#if os(Linux)
        let rootDiagnosis = root.layoutSubtreeIfNeeded()
        require(rootDiagnosis?.solved != false, "Linux shim could not solve the title subtree")
#else
        root.layoutSubtreeIfNeeded()
#endif
        require(title.frame.width <= 260.1 && title.frame.height > 20,
                "title ignored its width cap or lost its height")
        require(title.actionsAnchor.frame.width >= 20,
                "Actions target was compressed")
        require(title.accessibilityRole() == .button &&
                title.accessibilityTitle() == "A long terminal conversation title",
                "title accessibility is missing")
        require(title.actionsAnchor.accessibilityTitle() == "Session context menu",
                "Actions accessibility is missing")
        let wide = try capture(root, to: output.appendingPathComponent("wide.png"))
#if os(Linux)
        let bright = stride(from: 0, to: wide.count, by: 4).reduce(0) { count, i in
            count + (wide[i] > 170 && wide[i + 1] > 170 && wide[i + 2] > 170 ? 1 : 0)
        }
        require(bright > 45, "terminal-ground title has no readable bright ink")

        let revealPoint = titlePoint(title, in: root)
        _ = window.dispatchToContent(event(.mouseMoved, window: window, point: revealPoint))
        require(title.isHovered, "title hover was not tracked")
        let hover = try capture(root, to: output.appendingPathComponent("hover.png"))
        require(hover != wide, "hover plate changed no pixels")
        require(window.dispatchToContent(event(.leftMouseDown, window: window,
                                               point: revealPoint)) === title,
                "title press did not hit the reveal target")
        _ = window.dispatchToContent(event(.leftMouseUp, window: window, point: revealPoint))
        require(reveals == 1, "title press did not reveal exactly once")

        let actionPoint = actionsPoint(title, in: root)
        require(window.dispatchToContent(event(.leftMouseDown, window: window,
                                               point: actionPoint)) === title.actionsAnchor,
                "Actions press was swallowed by title")
        _ = window.dispatchToContent(event(.leftMouseUp, window: window, point: actionPoint))
        require(actions == 1 && reveals == 1, "Actions press routed to wrong callback")
#endif
        require(title.accessibilityPerformPress(), "accessible title press failed")
        require(title.actionsAnchor.accessibilityPerformPress(), "accessible Actions press failed")
#if os(Linux)
        require(reveals == 2 && actions == 2, "accessibility activation reached wrong callback")
#else
        require(reveals == 1 && actions == 1, "accessibility activation reached wrong callback")
#endif

        title.maxWidth = 136
        title.frame.size.width = title.intrinsicContentSize.width
        root.frame.size.width = 168
        root.layoutSubtreeIfNeeded()
        require(title.frame.width <= 136.1 && title.actionsAnchor.frame.width >= 20,
                "narrow width hid the Actions target")
        require(title.frame.maxX <= root.bounds.maxX - 16 + 0.1,
                "narrow title escaped the pane")
        _ = try capture(root, to: output.appendingPathComponent("narrow.png"))

        title.update(title: "Second page", symbolName: "plus", identity: "conversation-2")
        title.frame.size.width = title.intrinsicContentSize.width
        root.layoutSubtreeIfNeeded()
        require(title.title == "Second page" && title.accessibilityTitle() == "Second page",
                "title update kept the old name")
        let updated = try capture(root, to: output.appendingPathComponent("updated.png"))
        let providerIcon = NSImage(size: NSSize(width: 48, height: 24), flipped: false) { canvas in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: canvas.minX + 4, y: canvas.minY + 2,
                                        width: canvas.width - 8, height: canvas.height - 4)).fill()
            return true
        }
        providerIcon.isTemplate = true
        title.setIcon(providerIcon)
        title.frame.size.width = title.intrinsicContentSize.width
        root.layoutSubtreeIfNeeded()
        let branded = try capture(root, to: output.appendingPathComponent("branded.png"))
#if os(Linux)
        require(branded != updated, "provider image did not replace the symbol mark")
#endif
        let oldActionPoint = actionsPoint(title, in: root)
        title.actionsAnchor.isHidden = true
        root.layoutSubtreeIfNeeded()
        require(title.hitTest(oldActionPoint) !== title.actionsAnchor,
                "hidden Actions remained a pointer target")
        require(title.accessibilityChildren()?.contains { ($0 as? NSView) === title.actionsAnchor } != true,
                "hidden Actions remained in the accessible children")
        _ = try capture(root, to: output.appendingPathComponent("actions-hidden.png"))
        print("PASS production PageTitleView: title/icon update, narrow layout, terminal contrast, hover/reveal, Actions and accessibility")
    }
}
