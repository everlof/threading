import AppKit

/// A window's content root that reserves chrome a covering surface must not swallow.
///
/// The window draws its content full-size under a transparent titlebar, so `contentView` reaches
/// the top of the window and the traffic lights float over it. A surface pinned to that view's
/// `topAnchor` therefore opens *under* the window's own buttons — the mistake this project's
/// panes each learned separately, and which the transient surfaces then made again.
@MainActor
protocol InWindowOverlayHosting: AnyObject {
    /// The rectangle a covering surface may take: the window's content, minus the chrome the
    /// user still has to be able to reach.
    var overlayArea: NSLayoutGuide { get }

    /// The rectangle the scrim under that surface may dim, which is deliberately *larger*.
    ///
    /// The surface stops below the window's chrome; the wash carries on up to whatever draws the
    /// window's own buttons, because the chrome between the two is exactly what has to be pushed
    /// back — left lit, the app's header band and the surface's own header stacked with a
    /// hairline between them and read as one window. In native dress the buttons are AppKit's,
    /// above the content view entirely, so this is the whole content view; in a takeover they are
    /// the app's own title band, so it starts under it. Dimming a way out of the window is
    /// allowed. Covering one is not.
    var overlayScrimArea: NSLayoutGuide { get }
}

/// Installs a transient surface over a window's content, on a scrim that dims what it covers.
///
/// One place decides where "over the window" starts, because there is one right answer and it is
/// not `contentView.topAnchor`: AppKit's titlebar strip in native dress (what `safeAreaLayoutGuide`
/// names, toolbar included), and the app's own title band in a takeover dress, which carries that
/// window's close, minimize and zoom. A modal that hides the way out of the window is not a modal.
///
/// One place also decides that the two views arrive and leave together. They did not: a session
/// removed the surface itself, so a scrim added beside it would have been one `removeFromSuperview`
/// away from outliving the thing it was dimming on every close, Escape and replacement path
/// separately. `install` hands back a `Presentation` that owns both, and nothing else may remove
/// either.
@MainActor
enum InWindowOverlay {

    /// One installed surface and the wash under it.
    ///
    /// A value rather than a component: it owns no drawing and no state of its own, only the
    /// fact that these two views were put in together and must come out together.
    @MainActor
    struct Presentation {
        /// The view they were installed in — the window's content.
        let root: NSView
        let surface: NSView
        let scrim: NSView

        func remove() {
            surface.removeFromSuperview()
            scrim.removeFromSuperview()
            // After both are out, so an arrival the surface held back and now pays reaches a
            // view that asks whether it is covered and is told the truth.
            CoveredWindowPointer.release(surface)
        }
    }

    /// Names the wash inside a window's content so a fixture can find it without the scrim's own
    /// type leaving this file. Nothing in the app reads it.
    static let scrimIdentifier = NSUserInterfaceItemIdentifier("threading.overlay.scrim")

    /// Adds `overlay` above everything in `window`'s content, on a scrim clicking which runs
    /// `onDismiss` — answering what was installed, or nil when the window has no content.
    ///
    /// `onDismiss` is required rather than defaulted: a scrim swallows every click it covers, so
    /// one installed without a dismissal is a window that has quietly stopped answering the
    /// pointer.
    @discardableResult
    static func install(
        _ overlay: NSView,
        in window: NSWindow,
        onDismiss: @escaping () -> Void
    ) -> Presentation? {
        guard let root = window.contentView else { return nil }
        let host = window.contentViewController as? InWindowOverlayHosting

        let scrim = InWindowOverlayScrim()
        scrim.identifier = scrimIdentifier
        scrim.onDismiss = onDismiss
        scrim.coveringSurface = overlay
        root.addSubview(scrim, positioned: .above, relativeTo: nil)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay, positioned: .above, relativeTo: nil)

        if let area = host?.overlayScrimArea {
            pin(scrim, to: area)
        } else {
            // A window whose root states nothing — a fixture, the component gallery — has no
            // app-drawn buttons inside its content, so the wash may take all of it.
            pin(scrim, toEdgesOf: root)
        }

        if let area = host?.overlayArea {
            pin(overlay, to: area)
        } else {
            // A root that states nothing still has the platform's own answer for the strip
            // above it.
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }

        root.layoutSubtreeIfNeeded()
        // The surface stands between the pointer and everything under the wash, and a tracking
        // area under it knows nothing about that: without this, the controls a modal dims still
        // lit as hovered under it. The cursor stays the surface's own — its search field and
        // handles register in the same window's list, which is why this is not `.arrow`; see
        // `CoveredWindowPointer`.
        CoveredWindowPointer.claim(overlay, covering: window, cursor: .surfaceOwned)
        return Presentation(root: root, surface: overlay, scrim: scrim)
    }

    private static func pin(_ view: NSView, to guide: NSLayoutGuide) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: guide.topAnchor),
            view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    private static func pin(_ view: NSView, toEdgesOf other: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: other.topAnchor),
            view.leadingAnchor.constraint(equalTo: other.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: other.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: other.bottomAnchor)
        ])
    }
}

// MARK: - Scrim

/// The wash under a covering surface.
///
/// It exists as a view rather than as a fill inside the surface because it does two things the
/// surface cannot do for itself. It dims the window's own chrome *above* the surface — the band
/// carrying the session tabs and the panel toggles stayed fully lit directly over the inspector's
/// header, and two rows of chrome separated by a hairline read as one continuous window rather
/// than as something opened in front of it. And it makes the ground around the surface a way out,
/// which is the click every covering surface in every other app answers.
///
/// A `ThemedControl` because it takes the pointer, which is the rule for anything in `UI/Design`
/// that does — but not an accessibility element: the dismissal it offers is a pointer shortcut for
/// Escape, and the surface in front of it already carries a close button with the name of what is
/// being closed. Exposed, it would put a second full-window "close" ahead of the thing the user
/// opened.
private final class InWindowOverlayScrim: ThemedControl {

    var onDismiss: (() -> Void)?
    weak var coveringSurface: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Focus belongs to the surface, which places it deliberately and hands it back on close. A
    /// dimmer in the key-view loop is a Tab stop that looks like nothing and shows nothing.
    override var acceptsFirstResponder: Bool { false }

    /// The window behind a surface opened from another app's foreground — an agent's own
    /// notification, a click into an inactive window — is not key, and the first click there is
    /// the one asking to leave.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.overlayScrim.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        // The wash extends under the surface so it can also dim the window chrome above it. It is
        // only a dismissal target where that surface is *not*, however. A transparent gap in a
        // descendant — the media inspector's thumbnail spacing is the reported case — must stay
        // inert even if AppKit routes the press to this sibling underneath. Decide that from the
        // surface's geometry rather than from the same descendant hit test that exposed the gap.
        if let coveringSurface,
           coveringSurface.window === window,
           coveringSurface.bounds.contains(
               coveringSurface.convert(event.locationInWindow, from: nil)
           ) {
            return
        }
        onDismiss?()
    }

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onDismiss?()
        return true
    }
}
