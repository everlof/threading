import AppKit

/// Decides whether the main window wears its native AppKit frame or the active theme's own
/// chrome, and performs the exchange in both directions.
///
/// A theme opts in by stating a `WindowChromeStyle` (see that type); everything here is the
/// *mechanics* of honouring it. The takeover keeps every style-mask bit AppKit can still serve
/// behind a frameless window — `.resizable` is the platform's edge-resize, `.miniaturizable`
/// the Dock genie, `.closable` what `performClose` requires — and gives up exactly two:
/// `.titled`, which is the traffic lights, the rounded corners and the toolbar mount, and
/// `.fullSizeContentView`, which without a titlebar means nothing.
///
/// **Ordering in the flips is load-bearing.** A toolbar must leave before `.titled` does and
/// return only after it is back — an attached `NSToolbar` on an untitled window is an AppKit
/// exception, not a no-op. The mask assignment may nudge the frame and drop key status, so
/// both are captured before and re-asserted after. And a window inside fullscreen never has
/// its mask touched: the change is parked and completed from `windowDidExitFullScreen`,
/// because a mid-fullscreen mask flip detaches the window from its space.
@MainActor
final class WindowChromeCoordinator {

    /// What the window controller lends the coordinator. Closures rather than a delegate: the
    /// three of them are the entire surface, and each is stated where the coordinator is made.
    struct Callbacks {
        /// Detach the toolbar entirely (`window.toolbar = nil`).
        let removeToolbar: () -> Void
        /// Rebuild the toolbar and its style — runs only while the window is titled.
        let reinstallToolbar: () -> Void
        /// The frame changed hands: install or retire the app-drawn chrome and re-run the
        /// measurements that assumed the other frame.
        let takeoverDidChange: (Bool) -> Void
    }

    // MARK: - Masks

    /// The window as `createWindow` has always made it.
    static let nativeMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView
    ]

    /// Frameless, with everything AppKit can still do for a frameless window left in.
    static let takeoverMask: NSWindow.StyleMask = [
        .closable, .miniaturizable, .resizable
    ]

    /// Whether the theme currently in force asks for the takeover. Read from
    /// `AppThemePalette` rather than `AppThemeLibrary` because the palette is what every
    /// drawing component follows — and what a hosted test can set without touching the
    /// user's stored choice.
    static var takeoverRequested: Bool {
        AppThemePalette.current.takesOverWindowChrome
    }

    // MARK: - Properties

    private weak var window: TitlebarActionWindow?
    private let callbacks: Callbacks
    private let appEvents = AppEventObservations()

    /// Which frame the window is wearing now — the coordinator's own record, initialised from
    /// the mask the window was created with rather than assumed, so a window created straight
    /// into takeover (theme active at launch) starts out agreeing with itself.
    private(set) var isTakeoverActive: Bool

    /// A frame exchange that arrived while the window was fullscreen, completed on the way
    /// out. `nil` means nothing is parked.
    private(set) var pendingChange: Bool?

    /// The collection behaviour the window had before takeover inserted `.fullScreenPrimary`,
    /// put back exactly on exit.
    private var savedCollectionBehavior: NSWindow.CollectionBehavior?
    private var savedIsOpaque: Bool?
    private var savedBackgroundColor: NSColor?

    /// How the coordinator asks whether the window is inside fullscreen. A closure because a
    /// test cannot put a real window there: AppKit refuses `.fullScreen` set on a mask
    /// outside a genuine transition, loudly enough to fail the test that tried.
    var isInFullscreen: (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) }

    // MARK: - Initialization

    init(window: TitlebarActionWindow, callbacks: Callbacks) {
        self.window = window
        self.callbacks = callbacks
        isTakeoverActive = !window.styleMask.contains(.titled)

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
    }

    // MARK: - Applying

    /// Brings the window's frame in line with the current theme. Idempotent: called on every
    /// theme change, acts only when the frame must actually change hands.
    func applyCurrentTheme() {
        let wanted = Self.takeoverRequested
        guard wanted != isTakeoverActive else {
            // A parked change the theme has since walked back — un-park it.
            pendingChange = nil
            if wanted, let window {
                // Takeover → takeover can still exchange a full-width band for a shaped tab.
                // The mask stays put, but the window's opaque backing must follow the shape.
                applyTakeoverSurface(to: window)
            }
            return
        }
        guard let window else { return }

        guard !isInFullscreen(window) else {
            // Fullscreen has no visible frame to exchange, and exchanging the invisible one
            // detaches the window from its space. Park the change; `windowDidExitFullScreen`
            // completes it.
            pendingChange = wanted
            return
        }

        pendingChange = nil
        if wanted {
            enterTakeover(window)
        } else {
            exitTakeover(window)
        }
    }

    /// The window controller forwards its `windowDidExitFullScreen` here.
    func windowDidExitFullScreen() {
        guard pendingChange != nil else { return }
        applyCurrentTheme()
    }

    // MARK: - The Exchange

    private func enterTakeover(_ window: TitlebarActionWindow) {
        let frame = window.frame
        let wasKey = window.isKeyWindow

        // The toolbar first: it may only exist on a titled window.
        callbacks.removeToolbar()
        savedIsOpaque = window.isOpaque
        savedBackgroundColor = window.backgroundColor
        window.styleMask = Self.takeoverMask
        // The mask assignment can nudge the frame (titled and frameless content geometry
        // differ); the window the user had is the window they keep.
        window.setFrame(frame, display: false)

        // A frameless window is not fullscreen-capable by default; the menu item and ⌃⌘F
        // still have to work. Saved so exit restores whatever the window had.
        savedCollectionBehavior = window.collectionBehavior
        window.collectionBehavior.insert(.fullScreenPrimary)
        applyTakeoverSurface(to: window)

        isTakeoverActive = true
        callbacks.takeoverDidChange(true)

        // The flip drops key status. Only re-taken for a window actually on screen — a
        // hosted test's unshown window must not be ordered front by a theme change.
        if wasKey, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func exitTakeover(_ window: TitlebarActionWindow) {
        let frame = window.frame
        let wasKey = window.isKeyWindow

        window.styleMask = Self.nativeMask
        // Re-asserted rather than assumed: a mask flip may rebuild the frame view, and these
        // two are what the native chrome's whole layout story rests on (`createWindow`).
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        // The toolbar last: `.titled` is back, so it has somewhere to live.
        callbacks.reinstallToolbar()
        window.setFrame(frame, display: false)

        if let saved = savedCollectionBehavior {
            window.collectionBehavior = saved
            savedCollectionBehavior = nil
        }
        if let savedIsOpaque {
            window.isOpaque = savedIsOpaque
            self.savedIsOpaque = nil
        }
        if let savedBackgroundColor {
            window.backgroundColor = savedBackgroundColor
            self.savedBackgroundColor = nil
        }
        window.invalidateShadow()

        isTakeoverActive = false
        callbacks.takeoverDidChange(false)

        if wasKey, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A shaped title tab needs transparent shoulders so the window shadow follows the actual
    /// BeOS outline. Full-width takeover themes retain the window's original opaque backing.
    private func applyTakeoverSurface(to window: TitlebarActionWindow) {
        let isShaped = WindowChromeAppearance.resolve()?.shape == .leadingTab
        if isShaped {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = savedIsOpaque ?? true
            window.backgroundColor = savedBackgroundColor ?? Design.Surface.ground
        }
        window.invalidateShadow()
    }
}
