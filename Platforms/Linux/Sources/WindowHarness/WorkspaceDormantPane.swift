#if os(Linux)
import AppKit
import LinuxWindowBridge

/// The Mac session placeholder mounted below the same page header after an agent is closed.
@MainActor
final class WorkspaceDormantPane: WorkspacePane {
    let chrome: WorkspacePaneChrome
    private let owner = NSWindow(backingScaleFactor: WorkspaceDisplay.scale)
    private let root = NSView(frame: .zero)
    private let placeholder = SessionPlaceholderView(frame: .zero)
    private let heading: String
    private let detail: String
    private let actionTitle: String
    private var presentedSize = NSSize.zero
    private var displayRevision: UInt64 = 0
    private var needsPresentation = true
    private var resumeRequested = false

    var title: String { "Threading - \(heading)" }
    var needsPolling: Bool { false }
    func takeInitialViewport() -> (Int, Int)? { nil }

    init(pageName: String, displayTitle: String, pageIdentity: String,
         icon: NSImage?, supportsResume: Bool, canResume: Bool,
         onReveal: @escaping () -> Void) {
        heading = "\(displayTitle) ended"
        detail = canResume
            ? "The conversation is saved and will pick up where it left off."
            : supportsResume
                ? "No saved conversation was found, so this will start fresh."
                : "Starting again opens a new shell."
        actionTitle = canResume ? "Resume Session" : "Start Again"
        chrome = WorkspacePaneChrome(pageName: pageName, pageIdentity: pageIdentity,
            icon: icon, showsSessionActions: true, onReveal: onReveal)
        LinuxSymbols.install()
        placeholder.configure(symbolName: "arrow.clockwise.circle", title: heading,
                              detail: detail, actionTitle: actionTitle)
        placeholder.onAction = { [weak self] in self?.resumeRequested = true }
        placeholder.pin(to: root, contentTopAnchor: root.topAnchor)
        owner.contentView = root
        setThemeAppearance()
    }

    func takeResumeRequest() -> Bool {
        defer { resumeRequested = false }
        return resumeRequested
    }

    func pressAction() -> Bool { placeholder.actionAnchor.accessibilityPerformPress() }

    func setThemeAppearance() {
        root.appearance = LinuxTheme.appearance
        chrome.setThemeAppearance()
        needsPresentation = true
    }

    func focus(_ focused: Bool, window: OpaquePointer) {
        _ = tw_workspace_composer_mode(window, 0)
        chrome.focus(focused, window: window)
        if focused {
            _ = owner.makeFirstResponder(placeholder.actionAnchor)
            tw_title(window, title)
        } else {
            tw_accessibility_placeholder(window, nil, nil, nil, 0, 0, 0, 0, 0)
        }
    }

    func refresh(window: OpaquePointer, width: Int, height: Int, originX: Int,
                 focused: Bool) throws {
        try chrome.refresh(window: window, width: width, height: height, originX: originX)
        let contentHeight = max(1, height - WorkspacePaneChrome.headerPixelHeight)
        let scale = WorkspaceDisplay.scale
        let size = NSSize(width: CGFloat(width) / scale, height: CGFloat(contentHeight) / scale)
        guard needsPresentation || size != presentedSize
                || displayRevision != owner.displayRevision else { return }
        root.frame = NSRect(origin: .zero, size: size)
        owner.layoutIfNeeded()
        let bitmap = Bitmap(width: width, height: contentHeight,
                            background: LinuxTheme.components("ground"))
        root.render(in: NSGraphicsContext(bitmap: bitmap, scale: scale))
        let result = bitmap.pixels.withUnsafeBufferPointer {
            tw_present_pane(window, $0.baseAddress, Int32(width), Int32(contentHeight), 0)
        }
        guard result == 0 else { throw WindowFailure(String(cString: tw_error())) }

        let button = placeholder.actionAnchor.convert(placeholder.actionAnchor.bounds, to: root)
        let buttonX = originX + Int((button.minX * scale).rounded())
        let buttonY = WorkspacePaneChrome.headerPixelHeight
            + Int(((root.bounds.height - button.maxY) * scale).rounded())
        let buttonWidth = Int((button.width * scale).rounded())
        let buttonHeight = Int((button.height * scale).rounded())
        heading.withCString { name in
            detail.withCString { explanation in
                actionTitle.withCString { action in
                    tw_accessibility_placeholder(window, name, explanation, action, 1,
                        Int32(buttonX), Int32(buttonY), Int32(buttonWidth), Int32(buttonHeight))
                }
            }
        }
        let headingFrame = placeholder.convert(placeholder.titleFrame, to: root)
        tw_accessibility_placeholder_heading_bounds(window,
            Int32(originX + Int((headingFrame.minX * scale).rounded())),
            Int32(WorkspacePaneChrome.headerPixelHeight
                + Int(((root.bounds.height - headingFrame.maxY) * scale).rounded())),
            Int32((headingFrame.width * scale).rounded()),
            Int32((headingFrame.height * scale).rounded()))
        if focused { tw_title(window, title) }
        presentedSize = size
        displayRevision = owner.displayRevision
        needsPresentation = false
    }

    func handle(_ event: TWEvent, window: OpaquePointer) {
        let type: NSEvent.EventType
        switch event.kind {
        case 15 where event.key == 0:
            type = event.action == 1 ? .leftMouseDown : .leftMouseUp
        case 17:
            type = .leftMouseDragged
        case 7:
            let key = WindowHarness.composerKeyEvent(event)
            if key.keyCode == 36 || key.keyCode == 49 { _ = pressAction() }
            return
        default: return
        }
        let scale = WorkspaceDisplay.scale
        let pointer = NSEvent(type: type, locationInWindow: NSPoint(
            x: CGFloat(event.x) / scale,
            y: root.bounds.height - CGFloat(event.y) / scale))
        _ = owner.dispatchToContent(pointer)
        needsPresentation = true
    }
}
#endif
