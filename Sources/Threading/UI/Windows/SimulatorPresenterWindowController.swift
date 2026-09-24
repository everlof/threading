import AppKit

/// A session's adopted Simulator in a window of its own, made to be shared.
///
/// Meet, Zoom and the like share one *window*, and the pane lives inside the main window beside
/// the conversation — so sharing the pane meant sharing everything around it. This window holds
/// only the device (with touch marks, when they are on), sized to the device, and titled with the
/// device's name so it is the obvious row in a share picker. It is a titled, ordinary-level window
/// on purpose: every picker lists those, and a frameless or panel-level window is exactly what a
/// picker tends to skip.
///
/// **Native chrome, deliberately** — the same reasoning `DetachedBrowserWindowController` gives:
/// the theme takeover belongs to the main window.
///
/// The pane owns this controller and everything behind it. Closing the window only stops the
/// mirror; closing the pane's tab closes the window.
@MainActor
final class SimulatorPresenterWindowController: ThemedWindowController {

    private enum Defaults {
        /// Tall enough to read an iPhone on a shared screen, short enough to sit beside the main
        /// window on a laptop display.
        static let preferredHeight: CGFloat = 760
        static let visibleHeightFraction: CGFloat = 0.8
        static let minimumSize = NSSize(width: 200, height: 320)
        static let gapFromMainWindow: CGFloat = 20
    }

    let content: SimulatorPresenterViewController

    var screenView: SimulatorScreenView { content.screenView }

    /// The window closed — by its own button, ⌘W, or the pane. The pane stops mirroring.
    var onClose: (() -> Void)?

    private var isClosing = false
    private var hasSizedToDevice = false

    /// Whether the window floats above other apps' windows. Off by default: a picker shares an
    /// occluded window just as well, and a floating one covers the person's own work.
    var keepsOnTop: Bool {
        get { window?.level == .floating }
        set { window?.level = newValue ? .floating : .normal }
    }

    // MARK: - Initialization

    init(deviceName: String) {
        content = SimulatorPresenterViewController()
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: SimulatorPresenterViewController.contentSize(
                    forImageSize: .zero,
                    height: Defaults.preferredHeight
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = Defaults.minimumSize
        // Screen-sharing and recording tools may capture this window; that is its purpose.
        window.sharingType = .readOnly
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = content
        super.init(window: window)
        window.delegate = self
        setDeviceName(deviceName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    /// The picker row: "iPhone 17 Pro Simulator" rather than the app's name.
    func setDeviceName(_ name: String) {
        window?.title = L10n.format("%@ Simulator", name)
    }

    /// Size the window to the device the first time a frame says what shape it is, then leave the
    /// person's own resizing alone. The aspect stays locked so a resize never letterboxes.
    func adoptFrameSize(_ imageSize: NSSize) {
        guard let window, imageSize.width > 0, imageSize.height > 0 else { return }
        let reference = SimulatorPresenterViewController.contentSize(
            forImageSize: imageSize,
            height: Defaults.preferredHeight
        )
        window.contentAspectRatio = reference
        guard !hasSizedToDevice else { return }
        hasSizedToDevice = true
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height
            ?? Defaults.preferredHeight
        let height = min(Defaults.preferredHeight, visibleHeight * Defaults.visibleHeightFraction)
        window.setContentSize(SimulatorPresenterViewController.contentSize(
            forImageSize: imageSize,
            height: height
        ))
    }

    /// Beside the main window when there is room, so it does not land on top of the pane it
    /// mirrors; centred otherwise.
    func placeBeside(_ mainWindow: NSWindow?) {
        guard let window else { return }
        guard let mainWindow, mainWindow !== window,
              let visible = (mainWindow.screen ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(
            x: mainWindow.frame.maxX + Defaults.gapFromMainWindow,
            y: mainWindow.frame.maxY - size.height
        )
        if origin.x + size.width > visible.maxX {
            origin.x = mainWindow.frame.minX - Defaults.gapFromMainWindow - size.width
        }
        guard origin.x >= visible.minX else {
            window.center()
            return
        }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(origin)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(screenView)
    }
}

// MARK: - Menu Commands

/// ⌘W closes this window. Menu items are nil-targeted, and without an answer here the command
/// walks past this window to the app delegate and closes a tab in the main window behind it —
/// the failure `DetachedBrowserWindowController` documents.
extension SimulatorPresenterWindowController {

    @objc func closeActiveTab() {
        close()
    }
}

// MARK: - Window Delegate

extension SimulatorPresenterWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        onClose?()
    }
}
