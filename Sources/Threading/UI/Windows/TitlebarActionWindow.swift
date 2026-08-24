import AppKit

/// The window that performs its own titlebar double-click, because this window's titlebar never
/// sees one.
///
/// `.fullSizeContentView` and `titlebarAppearsTransparent` are each harmless alone and together
/// take the gesture away. Measured across all four combinations of the two flags in a window
/// otherwise identical to this one, a click 22pt below the top edge hit-tests to `NSTitlebarView`
/// in three of them and to the **content view** in the fourth — which is this window's pair. Zoom
/// on double-click is AppKit's, and it lives in the titlebar the click no longer reaches, so the
/// window quietly lost a gesture every other Mac window has: the strip beside the traffic lights
/// swallowed the double-click and did nothing with it.
///
/// Neither flag is negotiable (see `docs/architecture/window-chrome.md`): the first is what lets
/// the sidebar run the full height under the traffic lights, and the second is what keeps the
/// toolbar from drawing a material bar between the window's rounded corner and the content. So the
/// gesture is restored here rather than traded away.
///
/// **`mouseDown` on the window is the one place it can go.** AppKit calls it only for a click that
/// no view claimed, which means a double-click on a toolbar item, a traffic light, or anything a
/// pane puts under the strip has already been handled and never arrives. There is nothing to
/// hit-test and nothing to steal — the window is asked last, exactly as the responder chain
/// intends.
final class TitlebarActionWindow: NSWindow {

    /// The strip has no resting affordance because its other job is ordinary window chrome.
    /// This design-system view is mounted only when a drag proves it is carrying one reportable
    /// image, then paints the accepted target without taking titlebar hit-testing from AppKit.
    private let screenshotDropIndicator = ScreenshotReportDropTargetView()
    private let screenshotDropDestination = ScreenshotReportDropDestinationView()
    private var screenshotDropDestinationConstraints: [NSLayoutConstraint] = []

    /// What a double-click performs, as a closure so a test can state the answer rather than
    /// inherit whichever setting the machine running it happens to carry — the gesture is only
    /// worth asserting against a known one.
    var doubleClickAction: () -> TitlebarDoubleClick.Action = { TitlebarDoubleClick.preferredAction }

    /// `NSWindow` answers `false` to both of these the moment `.titled` leaves the style mask,
    /// which under a chrome-takeover theme (`WindowChromeCoordinator`) would leave the app's
    /// only window unable to take keyboard focus at all.
    ///
    /// Deliberately **conditional**, not a bare `true`: a titled window keeps AppKit's own
    /// answer. The first version answered `true` unconditionally on the grounds that a titled
    /// window "already answered true" — but AppKit's answer consults state the documentation
    /// does not name, and overriding it for titled windows shifted `zoom()`'s animation path
    /// on unshown fixtures enough to surface a use-after-free in
    /// `_NSWindowTransformAnimation` two test suites away. Only the frameless case, where the
    /// default is a hard `false`, gets the override.
    ///
    /// In takeover the rest of this class is inert by geometry rather than by flag: a
    /// frameless window's `contentLayoutRect` is its whole content, so `isInTitlebarStrip` is
    /// never true, `mouseDown` always falls through to `super`, and the double-click gesture
    /// belongs to the app-drawn title band instead — which reads the same
    /// `TitlebarDoubleClick.preferredAction`.
    override var canBecomeKey: Bool {
        styleMask.contains(.titled) ? super.canBecomeKey : true
    }
    override var canBecomeMain: Bool {
        styleMask.contains(.titled) ? super.canBecomeMain : true
    }

    /// Holds the window on its screen while it wears the theme's own chrome.
    ///
    /// `super`'s answer *is* this, for a titled window: sized down to the visible frame, then
    /// moved inside it. For a frameless one it is the argument, unchanged — so under a takeover
    /// theme a window may be set to any size, anywhere, including two thousand points below the
    /// bottom of the display where its composer cannot be read or dragged back. The titled case
    /// keeps AppKit's answer, for the same reason `canBecomeKey` does: it consults state the
    /// documentation does not name, and this override only exists to fill in for a default that
    /// declines to act at all.
    ///
    /// Fullscreen is left alone. AppKit sizes a fullscreen window to the screen's *full* frame,
    /// menu bar included, and holding that inside `visibleFrame` would shrink the window the
    /// platform had just sized on purpose.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard !styleMask.contains(.titled),
              !styleMask.contains(.fullScreen),
              let bounds = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else {
            return super.constrainFrameRect(frameRect, to: screen)
        }

        return MainWindowFrame.held(frameRect, within: bounds)
    }

    /// What a picture dropped on the titlebar strip does, or nil while nothing is listening.
    ///
    /// The strip is the other half of "drop it on the icon": the Dock's icon is the one a person
    /// reaches for when Threading is behind the thing they photographed, and this is the one they
    /// reach for when it is already in front of them. Both open the same sheet.
    ///
    /// A closure rather than a delegate call, for `doubleClickAction`'s reason: the window is a
    /// piece of chrome and the report belongs to the controller, and a test can state the answer.
    var onScreenshotDropped: ((URL) -> Void)? {
        didSet {
            if onScreenshotDropped == nil {
                removeScreenshotDropDestination()
            } else {
                refreshScreenshotDropDestination()
            }
        }
    }

    /// Test seam for the destination methods below. The window deliberately is not registered
    /// for any drag type: registering `NSWindow` makes the whole window a candidate and prevents
    /// a child destination such as the terminal from owning the same file URL. In production
    /// AppKit calls these methods on `screenshotDropDestination`, whose bounds are the strip.
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isInTitlebarStrip(sender.draggingLocation) else {
            setScreenshotDropIndicatorPresented(false, animated: false)
            return []
        }
        return screenshotDropDestination.draggingEntered(sender)
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        screenshotDropDestination.draggingExited(sender)
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        setScreenshotDropIndicatorPresented(false, animated: false)
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        screenshotDropDestination.concludeDragOperation(sender)
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isInTitlebarStrip(sender.draggingLocation) else {
            setScreenshotDropIndicatorPresented(false, animated: false)
            return false
        }
        return screenshotDropDestination.performDragOperation(sender)
    }

    /// A render-test seam for the transient state. Production reaches the same method through
    /// `draggingEntered`/`draggingUpdated`; no synthetic pasteboard or wall-clock animation is
    /// needed to capture the real titlebar treatment at a stable frame.
    func setScreenshotDropIndicatorPresentation(_ presented: Bool) {
        setScreenshotDropIndicatorPresented(presented, animated: false)
    }

    var isScreenshotDropIndicatorPresented: Bool {
        screenshotDropIndicator.isPresented
    }

    /// Re-homes and remeasures the destination after the content root, toolbar, fullscreen state,
    /// or app-drawn frame changes. Its bounds, rather than a conditional answer from the whole
    /// window, are what let AppKit choose the terminal everywhere below the native strip.
    func refreshScreenshotDropDestination() {
        guard let onScreenshotDropped,
              let contentView else {
            removeScreenshotDropDestination()
            return
        }

        let stripHeight = titlebarStripHeight
        guard stripHeight > 0 else {
            removeScreenshotDropDestination()
            return
        }

        screenshotDropDestination.onDrop = onScreenshotDropped
        screenshotDropDestination.onPresentationChange = { [weak self] presented, animated in
            self?.setScreenshotDropIndicatorPresented(presented, animated: animated)
        }

        if screenshotDropDestination.superview !== contentView {
            NSLayoutConstraint.deactivate(screenshotDropDestinationConstraints)
            screenshotDropDestination.removeFromSuperview()
            screenshotDropDestination.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(screenshotDropDestination, positioned: .above, relativeTo: nil)
            screenshotDropDestinationConstraints = [
                screenshotDropDestination.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                screenshotDropDestination.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                screenshotDropDestination.topAnchor.constraint(equalTo: contentView.topAnchor),
            ]
            NSLayoutConstraint.activate(screenshotDropDestinationConstraints)
        }

        if screenshotDropIndicator.superview !== screenshotDropDestination {
            screenshotDropIndicator.removeFromSuperview()
            screenshotDropIndicator.translatesAutoresizingMaskIntoConstraints = false
            screenshotDropDestination.addSubview(screenshotDropIndicator)
            NSLayoutConstraint.activate([
                screenshotDropIndicator.leadingAnchor.constraint(
                    equalTo: screenshotDropDestination.leadingAnchor
                ),
                screenshotDropIndicator.trailingAnchor.constraint(
                    equalTo: screenshotDropDestination.trailingAnchor
                ),
                screenshotDropIndicator.topAnchor.constraint(
                    equalTo: screenshotDropDestination.topAnchor
                ),
                screenshotDropIndicator.bottomAnchor.constraint(
                    equalTo: screenshotDropDestination.bottomAnchor
                ),
            ])
        }

        screenshotDropDestination.setHeight(stripHeight)
    }

    var screenshotDropDestinationRegisteredTypes: [NSPasteboard.PasteboardType] {
        screenshotDropDestination.registeredDraggedTypes
    }

    var screenshotDropDestinationFrame: NSRect? {
        guard screenshotDropDestination.superview === contentView else { return nil }
        contentView?.layoutSubtreeIfNeeded()
        return screenshotDropDestination.frame
    }

    private func removeScreenshotDropDestination() {
        setScreenshotDropIndicatorPresented(false, animated: false)
        screenshotDropDestination.onDrop = nil
        screenshotDropDestination.onPresentationChange = nil
        NSLayoutConstraint.deactivate(screenshotDropDestinationConstraints)
        screenshotDropDestinationConstraints = []
        screenshotDropDestination.removeFromSuperview()
    }

    private func setScreenshotDropIndicatorPresented(_ presented: Bool, animated: Bool) {
        screenshotDropIndicator.setPresented(presented, animated: presented && animated)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == TitlebarDoubleClick.clickCount,
              isInTitlebarStrip(event.locationInWindow) else {
            super.mouseDown(with: event)
            return
        }

        perform(doubleClickAction())
    }

    /// Whether a window-relative point is in the band the platform holds back for the titlebar and
    /// toolbar — the band that, under `.fullSizeContentView`, is drawn *over* the content view
    /// rather than above it.
    ///
    /// `contentLayoutRect.height` is what the platform left for content. Its origin is deliberately
    /// not used: AppKit restates that origin after a transient view is mounted over the full-size
    /// root, while the held-back height remains stable. Subtracting that height from the window
    /// gives the strip on every toolbar style and leaves a frameless window with no strip at all.
    func isInTitlebarStrip(_ locationInWindow: NSPoint) -> Bool {
        let stripHeight = titlebarStripHeight
        return stripHeight > 0 && locationInWindow.y >= frame.height - stripHeight
    }

    private var titlebarStripHeight: CGFloat {
        guard styleMask.contains(.titled) else { return 0 }
        return max(0, min(frame.height, frame.height - contentLayoutRect.height))
    }

    private func perform(_ action: TitlebarDoubleClick.Action) {
        switch action {
        case .zoom:
            performZoom(nil)
        case .minimize:
            performMiniaturize(nil)
        case .doNothing:
            break
        }
    }
}

/// The report target's drag ownership without any appearance of its own.
///
/// A destination receives drag callbacks for its bounds. That geometric fact is load-bearing:
/// `NSWindow.registerForDraggedTypes` made every file drag in the window a screenshot candidate,
/// including the same file URL the terminal had registered for. Returning `[]` from the window
/// outside the strip does not restart destination selection at the child beneath it. This view is
/// instead exactly as tall as the native strip, never participates in click hit-testing, and
/// hosts the design-system indicator only after it has accepted a reportable image.
@MainActor
private final class ScreenshotReportDropDestinationView: NSView {
    var onDrop: ((URL) -> Void)?
    var onPresentationChange: ((Bool, Bool) -> Void)?

    private var heightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setHeight(_ height: CGFloat) {
        if let heightConstraint {
            heightConstraint.constant = height
        } else {
            let constraint = heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            heightConstraint = constraint
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender, animated: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender, animated: true)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onPresentationChange?(false, false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        droppableScreenshot(in: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = droppableScreenshot(in: sender) else {
            onPresentationChange?(false, false)
            return false
        }
        onPresentationChange?(false, false)
        onDrop?(url)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onPresentationChange?(false, false)
    }

    private func dragOperation(
        for sender: any NSDraggingInfo,
        animated: Bool
    ) -> NSDragOperation {
        let acceptsScreenshot = droppableScreenshot(in: sender) != nil
        onPresentationChange?(acceptsScreenshot, animated)
        return acceptsScreenshot ? .copy : []
    }

    /// One image and nothing else. Refusing at the pasteboard boundary keeps this invisible
    /// destination from promising a report that cannot be opened.
    private func droppableScreenshot(in sender: any NSDraggingInfo) -> URL? {
        guard onDrop != nil,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              urls.count == 1,
              let url = urls.first,
              DroppedScreenshotReport.isReportable(url) else { return nil }
        return url
    }
}

// MARK: - The System's Own Setting

/// What a double-click on a titlebar does, as the user set it in System Settings.
///
/// Read rather than assumed. The point of restoring the gesture is that this window behaves like
/// every other one, which includes behaving like them when the user turned the gesture off — a
/// window that zooms after "Do Nothing" was chosen is a worse bug than the missing gesture, and
/// one nobody would think to look for here.
enum TitlebarDoubleClick {

    /// System Settings → Desktop & Dock → "Double-click a window's title bar to".
    ///
    /// Read from `UserDefaults.standard` on purpose: every app's search list includes the global
    /// domain, which is where the platform keeps this, and nothing in this app ever writes it.
    /// It is a *system* setting being read, not a user choice this app records, so it does not go
    /// through `PreferenceStore` (see `docs/architecture/persistence.md` for that line).
    static let preferenceKey = "AppleActionOnDoubleClick"

    /// A double-click, named so the guard reads as the gesture rather than as an integer.
    static let clickCount = 2

    enum Action: Equatable {
        case zoom
        case minimize
        case doNothing
    }

    /// Anything unrecognised zooms, because zoom is the platform's own default and this value has
    /// gained spellings before — recent System Settings offers "Fill" alongside the older
    /// "Maximize", and both mean "make it fill the screen", which is what `performZoom` does for a
    /// window that proposes no standard frame of its own. The two spellings that must not be
    /// guessed at are the ones that would surprise: turning the gesture off, and miniaturising.
    static func action(forPreference value: String?) -> Action {
        switch value {
        case "Minimize":
            return .minimize
        case "None":
            return .doNothing
        default:
            return .zoom
        }
    }

    static var preferredAction: Action {
        action(forPreference: UserDefaults.standard.string(forKey: preferenceKey))
    }
}
