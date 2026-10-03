#if os(Linux)
import AppKit
import Foundation
import Glibc
import LinuxWindowBridge

/// The idle workspace's bounded production content view. It keeps one view tree and texture
/// while project rows change, and repaints only for resize or interaction.
@MainActor
final class WorkspacePlaceholderPane {
    private(set) var title = ""
    private(set) var detail = ""
    private(set) var actionTitle = ""

    private let window = NSWindow(backingScaleFactor: 2)
    private let root = SessionPlaceholderView(frame: .zero)
    private var presentedSize = NSSize.zero
    private var needsPresentation = true

    init(hasProjects: Bool, onAction: @escaping () -> Void) {
        NSImage.systemSymbolProvider = { name, _ in
            Design.Symbol.image(name, slot: PlaceholderDefaults.iconSize,
                                pointSize: 36, weight: .regular)
        }
        root.onAction = onAction
        window.contentView = root
        setThemeAppearance()
        configure(hasProjects: hasProjects)
    }

    func setThemeAppearance() {
        root.appearance = LinuxTheme.appearance
        needsPresentation = true
    }

    func configure(hasProjects: Bool) {
        title = hasProjects ? "No Session Selected" : "No Projects Yet"
        detail = hasProjects ? "Select a session in the sidebar, or start one here."
                             : "Add a project folder to start a session."
        actionTitle = hasProjects ? "New Session" : "Add Project"
        root.configure(symbolName: "terminal", title: title, detail: detail,
                       actionTitle: actionTitle)
        needsPresentation = true
    }

    func focus(_ focused: Bool) {
        window.isKeyWindow = focused
        if !focused {
            window.makeFirstResponder(nil)
            window.cancelPointerGesture()
        }
        needsPresentation = true
    }

    func handle(_ input: TWEvent) {
        let eventType: NSEvent.EventType
        switch input.action {
        case 1: eventType = .leftMouseDown
        case 2: eventType = .leftMouseDragged
        case 3: eventType = .leftMouseUp
        default: eventType = .mouseMoved
        }
        let point = NSPoint(x: CGFloat(input.x) / 2,
                            y: root.bounds.height - CGFloat(input.y) / 2)
        _ = window.dispatchToContent(NSEvent(type: eventType, locationInWindow: point))
        if input.action == 4 { window.cancelPointerGesture() }
        needsPresentation = true
    }

    func cancelHover() {
        window.cancelPointerGesture()
        needsPresentation = true
    }

    @discardableResult
    func pressAction() -> Bool {
        let pressed = root.actionAnchor.accessibilityPerformPress()
        needsPresentation = true
        return pressed
    }

    func present(nativeWindow: OpaquePointer, width: Int, height: Int,
                 originX: Int) throws {
        let size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        guard needsPresentation || presentedSize != size else { return }
        root.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()

        let button = root.actionAnchor.convert(root.actionAnchor.bounds, to: root)
        let scale = window.backingScaleFactor
        let buttonX = originX + Int((button.minX * scale).rounded())
        let buttonY = Int(((root.bounds.height - button.maxY) * scale).rounded())
        let buttonWidth = Int((button.width * scale).rounded())
        let buttonHeight = Int((button.height * scale).rounded())

        let bitmap = Bitmap(width: width, height: height,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_placeholder(nativeWindow, $0.baseAddress,
                                   Int32(width), Int32(height))
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }
        title.withCString { name in
            detail.withCString { explanation in
                actionTitle.withCString { action in
                    tw_accessibility_placeholder(nativeWindow, name, explanation, action,
                        Int32(buttonX), Int32(buttonY), Int32(buttonWidth), Int32(buttonHeight))
                }
            }
        }
        presentedSize = size
        needsPresentation = false
        print("IDLE_PANE_FRAME \(width)x\(height) action=\(actionTitle)")
        fflush(nil)
    }
}
#endif
