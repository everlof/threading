import AppKit
import Foundation

@MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("IconButton contract: \(message)") }
}

@MainActor private func render(_ root: NSView, to url: URL) throws -> Bitmap {
    let bitmap = Bitmap(width: 160, height: 96, background: (1, 1, 1, 1))
    let context = NSGraphicsContext(bitmap: bitmap, scale: 1)
    root.render(in: context)
    try PNGWriter.write(bitmap, to: url)
    return bitmap
}

@MainActor private func sample(_ bitmap: Bitmap, x: Int, y: Int) -> [UInt8] {
    let start = (y * bitmap.width + x) * 4
    return Array(bitmap.pixels[start..<(start + 4)])
}

@MainActor private func sample(_ bitmap: Bitmap, in view: NSView,
                               x: Int, y: Int) -> [UInt8] {
    // AppKit frames are y-up; bitmap rows are stored from the top down.
    sample(bitmap, x: Int(view.frame.minX) + x,
           y: bitmap.height - Int(view.frame.minY) - y)
}

@MainActor private func event(_ type: NSEvent.EventType, _ window: NSWindow,
                              x: CGFloat, y: CGFloat, characters: String? = nil) -> NSEvent {
    NSEvent(type: type, window: window, locationInWindow: NSPoint(x: x, y: y),
            charactersIgnoringModifiers: characters)
}

@MainActor private final class BackgroundCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

@main struct IconButtonHarness {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: IconButtonHarness OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let root = BackgroundCursorView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
        let window = NSWindow()
        window.screenOrigin = NSPoint(x: 40, y: 70)
        window.contentView = root

        let button = ThemedIconButton(symbolName: "plus", accessibility: "Add project",
                                      target: .toolbar, inkSource: .chrome)
        var presses = 0
        button.onPress = { presses += 1 }
        root.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            button.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)
        ])

        let menu = ThemedIconButton(symbolName: "ellipsis", accessibility: "Project actions",
                                    target: .inline, inkSource: .chrome,
                                    glyphMaterialization: .deferred)
        require(!menu.hasMaterializedGlyph, "deferred row glyph materialized before first draw")
        root.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 70),
            menu.topAnchor.constraint(equalTo: root.topAnchor, constant: 20)
        ])

        let rest = try render(root, to: output.appendingPathComponent("rest.png"))
        require(button.frame.width == 30 && button.frame.height == 28,
                "production target geometry did not solve")
        require(menu.frame.width == 20 && menu.frame.height == 20,
                "production inline target geometry did not solve")
        require(menu.hasMaterializedGlyph, "visible row glyph did not materialize on draw")
        require(button.accessibilityRole() == .button, "role is not button")
        require(button.accessibilityTitle() == "Add project", "accessible title was lost")
        require(button.isAccessibilityElement(), "button is absent from accessibility")
        let restFill = sample(rest, in: button, x: 8, y: 8)
        require(sample(rest, in: button, x: 16, y: 14) != [255, 255, 255, 255],
                "unchanged GlyphView rendered no visible mark")
        let maxDotRuns = (0..<Int(menu.frame.height)).map { y in
            (0..<Int(menu.frame.width)).reduce(into: (count: 0, inkBefore: false)) {
                result, x in
                let ink = sample(rest, in: menu, x: x, y: y) != [255, 255, 255, 255]
                if ink && !result.inkBefore { result.count += 1 }
                result.inkBefore = ink
            }.count
        }.max() ?? 0
        require(maxDotRuns == 3, "ellipsis artwork did not render as three separate dots")

        let inside = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let screenInside = window.convertPoint(toScreen: inside)
        require((root.accessibilityHitTest(screenInside) as? NSView) === button,
                "decorative glyph displaced the button's accessible hit")
        let moved = event(.mouseMoved, window, x: inside.x, y: inside.y)
        _ = window.dispatch(moved)
        require(button.isHovered, "tracking area did not enter the button")
        let hover = try render(root, to: output.appendingPathComponent("hover.png"))
        let hoverFill = sample(hover, in: button, x: 8, y: 8)
        require(hoverFill != restFill, "hover did not change visible surface pixels")
        require(window.cursor(atWindowPoint: inside) == .arrow,
                "frontmost button claim did not win over the background")
        require(window.cursor(atWindowPoint: NSPoint(x: 100, y: 70)) == .crosshair,
                "background cursor claim was lost")

        let down = event(.leftMouseDown, window, x: inside.x, y: inside.y)
        require(window.dispatchToContent(down) === button,
                "the native event path did not route through the decorative glyph")
        require(button.isPressed, "press state did not begin")
        let pressed = try render(root, to: output.appendingPathComponent("pressed.png"))
        require(sample(pressed, in: button, x: 8, y: 8) != restFill,
                "press did not change visible surface pixels")
        _ = window.dispatchToContent(event(.leftMouseDragged, window, x: 100, y: 70))
        require(!button.isPressed, "drag out did not cancel the held visual state")
        _ = window.dispatchToContent(event(.leftMouseUp, window, x: 100, y: 70))
        require(presses == 0, "drag-out release fired an action")

        // The production control watches release at application scope so reuse cannot swallow a
        // press. Detach between down/up and make sure the captured action fires exactly once.
        _ = window.dispatchToContent(down)
        button.removeFromSuperview()
        _ = window.dispatchToContent(event(.leftMouseUp, window, x: inside.x, y: inside.y))
        _ = window.dispatchToContent(event(.leftMouseUp, window, x: inside.x, y: inside.y))
        require(presses == 1, "detached release failed or action fired twice")

        root.addSubview(button)
        _ = window.dispatchToContent(down)
        require(button.isPressed, "press did not re-arm after reattachment")
        window.cancelPointerGesture()
        require(!button.isPressed, "focus-loss cancellation left a held button")
        _ = window.dispatchToContent(event(.leftMouseUp, window, x: inside.x, y: inside.y))
        require(presses == 1, "release after focus loss fired a cancelled action")

        window.makeFirstResponder(button)
        require(button.hasKeyboardFocus, "window did not grant focus")
        _ = window.dispatchToContent(event(.keyDown, window, x: 0, y: 0, characters: " "))
        require(presses == 2, "Space did not take the same primary action")
        require(button.accessibilityPerformPress(), "accessibility press was not accepted")
        require(presses == 3, "accessibility press did not take the same action")
        let focused = try render(root, to: output.appendingPathComponent("focused.png"))
        require(focused.pixels != rest.pixels, "focus ring made no visible change")

        button.isEnabled = false
        require(!button.isAccessibilityEnabled(), "disabled button still reports enabled")
        require(!button.accessibilityPerformPress(), "disabled accessibility press was accepted")
        _ = window.dispatchToContent(event(.keyDown, window, x: 0, y: 0, characters: "\r"))
        require(presses == 3, "disabled button performed an action")
        _ = try render(root, to: output.appendingPathComponent("disabled.png"))

        // NSControl's closure action is real, independent of the icon button's own onPress.
        let generic = NSControl(frame: .zero)
        var genericActions = 0
        generic.action = { genericActions += 1 }
        require(generic.sendAction(generic.action, to: nil), "NSControl action was not sent")
        generic.isEnabled = false
        require(!generic.sendAction(generic.action, to: nil) && genericActions == 1,
                "disabled NSControl sent its action")

        print("PASS IconButtonHarness: unchanged ThemedControl/ThemedIconButton/GlyphView rendered; hover, drag cancel, detached release, keyboard, accessibility and disabled actions verified")
    }
}
