import AppKit

/// A live device framebuffer that remains a native Threading control.
///
/// The screen owns only presentation and input geometry. The Simulator feature owns the device,
/// consent decision and transport; keeping those out of this design component means a theme or
/// accessibility change cannot accidentally become another authority for device input.
final class SimulatorScreenView: ThemedControl {
    /// Whether the visible frame can accept input now or can safely use an input attempt to
    /// recover its direct transport. Recovery is deliberately distinct from `ready`: the pane
    /// may invite the gesture, but the feature controller must reconnect and authorize it before
    /// anything crosses the helper boundary.
    enum InteractionState: Equatable {
        case unavailable
        case recoverable
        case ready(touch: Bool, keyboard: Bool)

        var acceptsPointerRequests: Bool {
            switch self {
            case .unavailable: false
            case .recoverable: true
            case .ready(let touch, _): touch
            }
        }

        var acceptsKeyboardRequests: Bool {
            switch self {
            case .unavailable: false
            case .recoverable: true
            case .ready(_, let keyboard): keyboard
            }
        }
    }

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    var interactionState: InteractionState = .unavailable {
        didSet {
            guard interactionState != oldValue else { return }
            if !interactionState.acceptsPointerRequests { cancelPointerGesture() }
            updateAccessibilityContract()
            needsDisplay = true
        }
    }

    /// One element outline drawn over the live framebuffer for the accessibility inspector overlay.
    /// Kept as a presentation-only value so this Design component never imports the Simulator wire
    /// types: the feature controller resolves the tree and hands down normalized rectangles.
    struct ElementAnnotation: Equatable {
        /// The element's frame in the device's 0…1 space, top-left origin (the same space taps use).
        let normalizedFrame: CGRect
        let label: String?
        /// A short display name (ref + role + label) shown in the badge when this element is hovered.
        let name: String?
        /// A paste-ready target string copied when the element is clicked in inspect mode — a handle
        /// to hand the agent ("the Kronaby button, tap (0.9, 0.1)").
        let copyText: String?
        /// Interactive elements (buttons, fields) are drawn emphasized; static content is faint.
        let emphasized: Bool
    }

    /// Element outlines for the inspector overlay. Empty hides the overlay.
    var annotations: [ElementAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            if annotations.isEmpty { hoveredAnnotationIndex = nil }
            updateInspectionTracking()
            needsDisplay = true
        }
    }

    /// The element under the pointer while inspecting — outlined and named. Client-side hit-test
    /// against the fetched tree (smallest containing rect), so pointer motion needs no round-trip.
    private var hoveredAnnotationIndex: Int?
    private var inspectionTrackingArea: NSTrackingArea?
    /// Briefly true after an inspect-mode copy, so the badge confirms it.
    private var showingCopyConfirmation = false
    private var copyConfirmationTimer: Timer?

    /// The person's own pinned notes, drawn as numbered pins over the framebuffer. Distinct from the
    /// accessibility overlay above: these are user-authored, the pins use the app's shared annotation
    /// vocabulary, and they persist per device.
    var noteMarks: [ImageAnnotation] = [] {
        didSet {
            guard noteMarks != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedNoteID: ImageAnnotation.ID? {
        didSet {
            guard selectedNoteID != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Input made visible — tap ripples and swipe trails over the framebuffer. Driven by the pane
    /// from the same touches it sends (yours and the agent's).
    var touchIndicators: SimulatorTouchIndicators? {
        didSet {
            guard touchIndicators != oldValue else { return }
            needsDisplay = true
        }
    }

    /// While on, a click pins or selects a note instead of touching the device.
    var isAnnotatingNotes = false

    /// A click at a normalized point that hit no existing pin — the caller pins a new note there.
    var onAddNote: ((CGPoint) -> Void)?
    /// A click on an existing pin (or empty space, giving nil) while annotating.
    var onSelectNote: ((ImageAnnotation.ID?) -> Void)?
    /// ⌘Return while annotating — the host sends the pending notes.
    var onCommandReturn: (() -> Void)?

    var onTap: ((CGPoint) -> Void)?
    /// Phases of a live, finger-following touch driven by a click-drag or a trackpad scroll. The
    /// feature controller streams these to the device so panning follows the input in real time
    /// instead of firing one discrete swipe.
    var onTouchBegan: ((CGPoint) -> Void)?
    var onTouchMoved: ((CGPoint) -> Void)?
    var onTouchEnded: ((CGPoint) -> Void)?
    var onText: ((String) -> Void)?

    private var pointerStart: (location: CGPoint, time: TimeInterval)?
    /// Whether the current mouse gesture has crossed the tap threshold and become a streamed touch.
    private var isStreamingTouch = false
    /// Fires when the pointer has been held still past the long-press threshold, turning a stationary
    /// hold into a held-down contact (press-and-hold: context menus, edit mode, icon jiggle).
    private var holdTimer: Timer?
    /// The synthetic contact point a trackpad scroll drives; nil when no scroll gesture is active.
    private var scrollPoint: CGPoint?

    var imageRect: NSRect {
        guard let image else { return .zero }
        return ThemedImagePreview.fittedRect(
            for: image.size,
            in: bounds,
            allowsUpscaling: true
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.string("Simulator screen"))
        updateAccessibilityContract()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        isEnabled
            && image != nil
            && (interactionState.acceptsPointerRequests
                || interactionState.acceptsKeyboardRequests)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let target = imageRect
        guard !target.isEmpty else { return }
        let shape = ThemedSurface.Shape(rect: target, radius: Design.Radius.control)

        NSGraphicsContext.saveGraphicsState()
        shape.path.addClip()
        image.draw(
            in: target,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        // No hover wash over a live device — it read as an odd white overlay on the real screen.
        // Keyboard focus is still indicated (subtle, and only while typing).
        drawKeyboardFocus(around: shape)

        drawAnnotations(in: target)
        drawNoteMarks(in: target)

        if let touchIndicators {
            NSGraphicsContext.saveGraphicsState()
            ThemedSurface.Shape(rect: target, radius: Design.Radius.control).path.addClip()
            SimulatorTouchMarks.draw(touchIndicators, in: target)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The person's numbered note pins, in the app's shared annotation vocabulary. The view is not
    /// flipped, so `isFlipped: false` matches the framebuffer draw above.
    private func drawNoteMarks(in target: NSRect) {
        guard !noteMarks.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        ThemedSurface.Shape(rect: target, radius: Design.Radius.control).path.addClip()
        ImageAnnotationMarks.draw(
            noteMarks,
            in: target,
            isFlipped: false,
            selected: selectedNoteID
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw the inspector overlay: every element's bounds faintly as context (the Phase 1
    /// coordinate-mapping tripwire — a rectangle that does not sit on the control it names means the
    /// device-points → framebuffer mapping is wrong), and the hovered element outlined bright with a
    /// name badge.
    private func drawAnnotations(in target: NSRect) {
        guard !annotations.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        ThemedSurface.Shape(rect: target, radius: Design.Radius.control).path.addClip()

        for (index, annotation) in annotations.enumerated() where index != hoveredAnnotationIndex {
            let rect = viewRect(for: annotation.normalizedFrame, in: target).insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 1, rect.height > 1 else { continue }
            let color = annotation.emphasized ? Design.Surface.accent : Design.Surface.border
            let path = roundedPath(rect)
            path.lineWidth = 1
            color.withAlphaComponent(annotation.emphasized ? 0.4 : 0.28).setStroke()
            path.stroke()
        }

        if let index = hoveredAnnotationIndex, annotations.indices.contains(index) {
            let annotation = annotations[index]
            let rect = viewRect(for: annotation.normalizedFrame, in: target).insetBy(dx: 0.5, dy: 0.5)
            if rect.width > 1, rect.height > 1 {
                let path = roundedPath(rect)
                path.lineWidth = 1.5
                Design.Surface.accent.withAlphaComponent(0.12).setFill()
                path.fill()
                Design.Surface.accent.setStroke()
                path.stroke()
                let badgeText = showingCopyConfirmation ? L10n.string("Copied") : annotation.name
                if let badgeText, !badgeText.isEmpty {
                    drawBadge(badgeText, above: rect, in: target)
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    /// Map a normalized (device 0…1, y-down) frame to this view's coordinates (y-up), the inverse of
    /// the tap normalization.
    private func viewRect(for normalized: CGRect, in target: NSRect) -> NSRect {
        NSRect(
            x: target.minX + normalized.minX * target.width,
            y: target.maxY - (normalized.minY + normalized.height) * target.height,
            width: normalized.width * target.width,
            height: normalized.height * target.height
        )
    }

    private func roundedPath(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: rect,
            xRadius: Design.Radius.controlBorder,
            yRadius: Design.Radius.controlBorder
        )
    }

    private func drawBadge(_ text: String, above rect: NSRect, in target: NSRect) {
        let font = Design.Typography.caption()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Design.Text.label,
        ]
        let padding = Design.Spacing.small
        let textSize = (text as NSString).size(withAttributes: attributes)
        var badge = NSRect(
            x: rect.minX,
            y: rect.maxY + 2,
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )
        // Prefer above the element; drop below when there is no room, and keep it inside the screen.
        if badge.maxY > target.maxY { badge.origin.y = rect.minY - badge.height - 2 }
        badge.origin.y = max(target.minY, badge.origin.y)
        badge.origin.x = min(max(target.minX, badge.origin.x), target.maxX - badge.width)

        let badgePath = roundedPath(badge)
        Design.Surface.floating.setFill()
        badgePath.fill()
        Design.Surface.border.setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()
        (text as NSString).draw(
            at: NSPoint(x: badge.minX + padding, y: badge.minY + padding / 2),
            withAttributes: attributes
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateInspectionTracking()
    }

    private func updateInspectionTracking() {
        if let inspectionTrackingArea {
            removeTrackingArea(inspectionTrackingArea)
            self.inspectionTrackingArea = nil
        }
        guard !annotations.isEmpty else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        inspectionTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !annotations.isEmpty else {
            super.mouseMoved(with: event)
            return
        }
        // A position under a covering surface (a menu, a popover) is not this view's to read.
        guard let point = uncoveredPointerLocation(in: event) else {
            if hoveredAnnotationIndex != nil {
                hoveredAnnotationIndex = nil
                needsDisplay = true
            }
            return
        }
        updateHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredAnnotationIndex != nil {
            hoveredAnnotationIndex = nil
            needsDisplay = true
        }
    }

    private func flashCopyConfirmation() {
        showingCopyConfirmation = true
        needsDisplay = true
        copyConfirmationTimer?.invalidate()
        // `.common` mode so it fires during mouse tracking; `assumeIsolated` because it is added to
        // this main-thread run loop.
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showingCopyConfirmation = false
                self.needsDisplay = true
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        copyConfirmationTimer = timer
    }

    private func updateHover(at point: CGPoint) {
        let index = annotationIndex(under: point)
        if index != hoveredAnnotationIndex {
            hoveredAnnotationIndex = index
            needsDisplay = true
        }
    }

    /// The innermost annotation whose bounds contain a view-local point — the smallest containing
    /// rect, the way Accessibility Inspector picks — or nil off the framebuffer. Internal so the
    /// hit-test can be verified without AppKit event plumbing.
    func annotationIndex(under point: CGPoint) -> Int? {
        let target = imageRect
        guard !target.isEmpty, target.contains(point) else { return nil }
        var best: Int?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (index, annotation) in annotations.enumerated() {
            let rect = viewRect(for: annotation.normalizedFrame, in: target)
            guard rect.contains(point) else { continue }
            let area = rect.width * rect.height
            if area < bestArea {
                bestArea = area
                best = index
            }
        }
        return best
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Annotate mode pins or selects a note instead of touching the device.
        if isAnnotatingNotes {
            guard imageRect.contains(location) else {
                onSelectNote?(nil)
                return
            }
            if let hit = ImageAnnotationGeometry.annotationID(
                at: location, among: noteMarks, in: imageRect, isFlipped: false
            ) {
                onSelectNote?(hit)
            } else if let point = ImageAnnotationGeometry.normalizedPoint(
                for: location, in: imageRect, isFlipped: false
            ) {
                onAddNote?(point)
            }
            return
        }

        // Inspect mode grabs targets rather than driving the device: a click copies the hovered
        // element's paste-ready handle to the clipboard. Turn the overlay off to tap again.
        if !annotations.isEmpty {
            if let index = hoveredAnnotationIndex, annotations.indices.contains(index),
               let copyText = annotations[index].copyText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                flashCopyConfirmation()
            }
            return
        }

        guard isEnabled,
              interactionState.acceptsPointerRequests,
              imageRect.contains(location) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        pointerStart = (location, event.timestamp)
        isStreamingTouch = false
        // A held-still press becomes a held-down contact. The timer is added to `.common` modes so
        // it fires during the mouse-tracking loop, and starting the touch here (rather than at
        // mouse-up) is what lets the device recognise a long-press.
        let origin = location
        let timer = Timer(timeInterval: Self.longPressDuration, repeats: false) { [weak self] _ in
            // The timer is scheduled on this view's (main) run loop, so it fires on the main actor.
            MainActor.assumeIsolated {
                guard let self, self.pointerStart != nil, !self.isStreamingTouch else { return }
                self.isStreamingTouch = true
                self.onTouchBegan?(self.clampedNormalizedPoint(origin))
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pointerStart else { return }
        let location = convert(event.locationInWindow, from: nil)
        // Cross the tap threshold once, then stream the touch so it follows the pointer live.
        if !isStreamingTouch,
           hypot(location.x - start.location.x, location.y - start.location.y) >= Self.tapThreshold {
            holdTimer?.invalidate() // it moved before the hold fired — this is a drag, not a press
            holdTimer = nil
            isStreamingTouch = true
            onTouchBegan?(clampedNormalizedPoint(start.location))
        }
        if isStreamingTouch {
            onTouchMoved?(clampedNormalizedPoint(location))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pointerStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        defer { cancelPointerGesture() }
        if isStreamingTouch {
            onTouchEnded?(clampedNormalizedPoint(end))
        } else if let from = normalizedPoint(start.location) {
            onTap?(from)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Only precise (trackpad) scrolling drives panning; a notched mouse wheel falls through.
        guard isEnabled,
              !isAnnotatingNotes,
              interactionState.acceptsPointerRequests,
              event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }
        switch event.phase {
        case .began:
            let origin = clamp(convert(event.locationInWindow, from: nil), to: imageRect)
            scrollPoint = origin
            onTouchBegan?(clampedNormalizedPoint(origin))
        case .changed:
            guard var point = scrollPoint else { return }
            // A trackpad scroll moves the content; the finger follows it. Screen y grows downward,
            // so a positive scrolling delta pushes the contact down, matching a natural swipe.
            point.x += event.scrollingDeltaX
            point.y += event.scrollingDeltaY
            point = clamp(point, to: imageRect)
            scrollPoint = point
            onTouchMoved?(clampedNormalizedPoint(point))
        case .ended, .cancelled:
            if let point = scrollPoint { onTouchEnded?(clampedNormalizedPoint(point)) }
            scrollPoint = nil
        default:
            // Momentum phases are left to a later increment (see the controls draft's arm64
            // momentum note); a scroll that never reported a begin phase is ignored.
            break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return sends the pending notes while annotating, wherever focus sits in the pane — the
        // same chord the browser's annotation overlay uses.
        if isAnnotatingNotes,
           event.modifierFlags.intersection(KeyboardShortcut.eventModifierMask) == .command,
           event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !isAnnotatingNotes,
              interactionState.acceptsKeyboardRequests,
              event.modifierFlags.intersection([.command, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 51 {
            // The helper's typed keyboard envelope uses USB HID usage values; U+0008 is its
            // explicit backspace spelling and never crosses the process boundary as a key code.
            onText?("\u{8}")
        } else if let text = event.characters, !text.isEmpty {
            onText?(text)
        } else {
            super.keyDown(with: event)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled,
              image != nil,
              interactionState.acceptsPointerRequests else { return false }
        onTap?(CGPoint(x: 0.5, y: 0.5))
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? { L10n.string("Simulator screen") }

    override var restingPointer: NSCursor? { .arrow }

    private static let tapThreshold: CGFloat = 4
    private static let longPressDuration: TimeInterval = 0.5

    private func normalizedPoint(_ point: CGPoint) -> CGPoint? {
        let target = imageRect
        guard !target.isEmpty, target.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - target.minX) / target.width)),
            y: min(1, max(0, (target.maxY - point.y) / target.height))
        )
    }

    /// Normalizes a point into the device's 0…1 space, clamping rather than rejecting one outside
    /// the image — a streamed touch that runs past the edge should land at the edge, not vanish.
    private func clampedNormalizedPoint(_ point: CGPoint) -> CGPoint {
        let target = imageRect
        guard !target.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(1, max(0, (point.x - target.minX) / target.width)),
            y: min(1, max(0, (target.maxY - point.y) / target.height))
        )
    }

    private func clamp(_ point: CGPoint, to rect: NSRect) -> CGPoint {
        guard !rect.isEmpty else { return point }
        return CGPoint(
            x: min(rect.maxX, max(rect.minX, point.x)),
            y: min(rect.maxY, max(rect.minY, point.y))
        )
    }

    private func cancelPointerGesture() {
        holdTimer?.invalidate()
        holdTimer = nil
        pointerStart = nil
        isStreamingTouch = false
        needsDisplay = true
    }

    private func updateAccessibilityContract() {
        let help: String
        switch interactionState {
        case .unavailable:
            help = L10n.string("Simulator control is unavailable.")
        case .recoverable:
            help = L10n.string("Press to reconnect and control the Simulator.")
        case .ready:
            help = L10n.string("Tap, drag, or type to control the Simulator.")
        }
        setAccessibilityHelp(help)
        setAccessibilityEnabled(interactionState != .unavailable)
    }
}
