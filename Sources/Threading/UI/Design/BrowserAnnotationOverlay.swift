import AppKit

/// A user-owned annotation layer that sits above live browser content without entering its DOM.
///
/// The page can neither inspect nor alter the notes. Outside annotation mode the overlay declines
/// hit testing entirely, so the visible pins do not interfere with links or browser automation.
struct BrowserAnnotationMarker: Equatable {
    let id: Int
    let point: CGPoint
}

/// The page component under the pointer while a pin is being placed.
///
/// A pin is dropped at a *point*, but the user is aiming at a *thing* — a button, a row, a field —
/// and a bare crosshair over live content says nothing about which one a click will be read as.
/// The rect arrives in the overlay's own coordinates, converted from CSS pixels by the browser so
/// page zoom is already accounted for, and the label is page-authored text the bridge has already
/// collapsed to one bounded line.
struct BrowserAnnotationTarget: Equatable {
    let rect: CGRect
    let label: String
}

final class BrowserAnnotationOverlay: ThemedControl {

    @MainActor
    private enum Layout {
        static let markerDiameter: CGFloat = Design.Size.chipHeight
        /// Computed, not stored: a `static let` resolves once and keeps the weight of whichever
        /// theme happened to be current at first draw — for the rest of the process, not merely
        /// until the next layout. The diameter and the inset above are fixed tokens and may store.
        static var markerBorderWidth: CGFloat { Design.Radius.border }
        static let markerHitInset: CGFloat = Design.Spacing.tight

        /// The target outline is drawn at the focus ring's weight, and for the focus ring's
        /// reason: both say "this is the thing the next action lands on". It also inherits that
        /// token's answer to Increase Contrast, where a 2pt line over an arbitrary page is thin.
        static var targetOutlineWidth: CGFloat { Design.Accessibility.focusRingWidth }
        static let targetLabelHeight: CGFloat = Design.Size.chipHeight
        static let targetLabelInset: CGFloat = Design.Spacing.small
        static let targetLabelGap: CGFloat = Design.Spacing.hairline

        /// The mode frame is the same weight as the outline inside it: one line says "this
        /// surface is in a mode", the other says "this is the part of it you are on".
        static var modeFrameWidth: CGFloat { Design.Accessibility.focusRingWidth }
        static let modeBadgeHeight: CGFloat = Design.Size.chipHeight
        static let modeBadgeInset: CGFloat = Design.Spacing.medium
        static let modeBadgePadding: CGFloat = Design.Spacing.small
        static let modeBadgeGlyphGap: CGFloat = Design.Spacing.tight
        static var modeBadgeGlyphSize: CGFloat { Design.Symbol.control }
    }

    var markers: [BrowserAnnotationMarker] = [] {
        didSet {
            setAccessibilityValue(
                L10n.format("%lld annotations", Int64(markers.count))
            )
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// The component the pointer is over, or nil when it is over nothing the page names.
    ///
    /// Held rather than derived because resolving it is a round trip into WebKit: the browser
    /// probes on movement and hands the answer back, so drawing stays synchronous.
    var hoveredTarget: BrowserAnnotationTarget? {
        didSet {
            guard hoveredTarget != oldValue else { return }
            needsDisplay = true
        }
    }

    var isAnnotating = false {
        didSet {
            guard isAnnotating != oldValue else { return }
            setAccessibilityEnabled(isAnnotating)
            selectsDeepestElement = isAnnotating && NSEvent.modifierFlags.contains(.option)
            if !isAnnotating { hoveredTarget = nil }
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
            needsDisplay = true
        }
    }

    /// The badge's glyph, resolved per draw: the same mark the toolbar's control wears while the
    /// mode is on, so the two readings of "annotating" are visibly the same statement.
    private var modeBadgeGlyph: NSImage? {
        Design.Symbol.image(
            DesignSymbols.annotating,
            slot: Layout.modeBadgeGlyphSize,
            pointSize: Design.Symbol.control
        )
    }

    private(set) var selectsDeepestElement = false

    var onAdd: ((CGPoint) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    /// Where the pointer is while annotating, and nil when it leaves. The browser answers with a
    /// `target`; the overlay deliberately does not resolve one for itself.
    var onTargetProbe: ((CGPoint?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.string("Browser Annotation Canvas"))
        setAccessibilityHelp(
            L10n.string("Click to annotate. Hold Option to target the innermost element. Scroll to move the page; Escape to finish.")
        )
        setAccessibilityEnabled(false)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isAnnotating }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A real wheel must enter WebKit through AppKit exactly once. Returning nil during the
        // original window dispatch lets AppKit choose and latch WebKit for the whole gesture,
        // preserving precision and momentum while this overlay keeps keyboard focus for Option
        // and Escape. The dispatch-scoped context matters: NSApplication.currentEvent remains
        // the last dequeued event after dispatch and would make unrelated later hit tests stale.
        if let dispatch = ApplicationEventDispatchContext.current,
           let dispatchWindow = dispatch.window,
           dispatch.type == .scrollWheel,
           dispatchWindow === window {
            return nil
        }
        guard isAnnotating, bounds.contains(point) else { return nil }
        return self
    }

    /// **Nothing at rest while the overlay is only watching.** It is a transparent sheet over a
    /// live web page, and the page's own answers — a link's hand, an I-beam over its text, a
    /// field's caret — are the right ones there. `nil` is the statement that this view is not
    /// opaque; see `PointerClaiming`. While a mark can be placed the sheet does own the pointer,
    /// and says crosshair.
    override var restingPointer: NSCursor? { isAnnotating ? .crosshair : nil }

    /// The marks that can be picked up, claimed before the crosshair behind them — the order that
    /// used to be left to AppKit, which documents overlapping rectangles as undefined.
    override var pointerClaims: [PointerClaim] {
        guard isAnnotating else { return [] }
        return markers.map { marker in
            PointerClaim(
                markerRect(for: marker)
                    .insetBy(dx: -Layout.markerHitInset, dy: -Layout.markerHitInset),
                .pointingHand
            )
        }
    }

    // MARK: - Pointer

    /// Movement is tracked only while annotating, so an ordinary browsing session installs no
    /// per-move work at all — and the moment the mode ends, the tracking that drove the highlight
    /// is gone rather than merely ignored.
    private var moveTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let moveTrackingArea {
            removeTrackingArea(moveTrackingArea)
            self.moveTrackingArea = nil
        }
        guard isAnnotating else { return }

        // Movement only. Entering and leaving are already `ThemedControl`'s tracking, and asking
        // for them twice delivers `mouseExited` twice for one crossing.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        moveTrackingArea = area
    }

    /// Where the pointer is right now, or nil when it is not on the overlay.
    ///
    /// Read when the *page* moves under a stationary pointer — a scroll — which produces no
    /// mouse event at all, and so no chance for movement tracking to notice that the component
    /// under the pointer has changed.
    var pointerLocation: CGPoint? {
        guard isAnnotating, isPointerInside, let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        // A position under an open dropdown is the menu's, not the page's — see
        // `NSView.uncoveredPointerLocation(in:)`.
        guard isAnnotating, let point = uncoveredPointerLocation(in: event) else { return }
        selectsDeepestElement = event.modifierFlags.contains(.option)
        onTargetProbe?(point)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isAnnotating else { super.flagsChanged(with: event); return }
        selectsDeepestElement = event.modifierFlags.contains(.option)
        onTargetProbe?(pointerLocation)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isAnnotating else { return }
        hoveredTarget = nil
        onTargetProbe?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        if let marker = marker(at: point) {
            onSelect?(marker.id)
        } else {
            onAdd?(point)
        }
    }

    override func performPrimaryAction() -> Bool {
        guard isAnnotating else { return false }
        onAdd?(CGPoint(x: bounds.midX, y: bounds.midY))
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isAnnotating, event.keyCode == 53 {
            onDismiss?()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        L10n.string("Browser Annotation Canvas")
    }

    // MARK: - Drawing

    /// Accent and its measured opposite make a two-tone edge on arbitrary page pixels.
    /// The same ink labels the opaque badges; selection ink assumes an AppKit selection ground.
    var annotationInk: NSColor { Design.Text.on(Design.Surface.accent).label }

    private func strokeAnnotation(_ path: NSBezierPath, width: CGFloat) {
        annotationInk.setStroke()
        path.lineWidth = width + Design.Spacing.hairline * 2
        path.stroke()
        Design.Surface.accent.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func fillAnnotationBadge(_ path: NSBezierPath) {
        Design.Surface.accent.setFill()
        path.fill()
        annotationInk.setStroke()
        path.lineWidth = Design.Spacing.hairline
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isAnnotating {
            drawModeFrame()
        }
        if isAnnotating, let hoveredTarget {
            draw(hoveredTarget)
        }
        for marker in markers where markerRect(for: marker).intersects(dirtyRect) {
            draw(marker)
        }
        if isAnnotating {
            // Last, so the badge stays readable over a component outline that covers the page —
            // a highlighted `<body>` is a rectangle the size of everything.
            drawModeBadge()
            drawKeyboardFocus(
                around: ThemedSurface.Shape(rect: bounds, radius: 0)
            )
        }
    }

    private func marker(at point: CGPoint) -> BrowserAnnotationMarker? {
        markers.last {
            markerRect(for: $0)
                .insetBy(dx: -Layout.markerHitInset, dy: -Layout.markerHitInset)
                .contains(point)
        }
    }

    private func markerRect(for marker: BrowserAnnotationMarker) -> CGRect {
        CGRect(
            x: marker.point.x - Layout.markerDiameter / 2,
            y: marker.point.y - Layout.markerDiameter / 2,
            width: Layout.markerDiameter,
            height: Layout.markerDiameter
        )
    }

    private func draw(_ marker: BrowserAnnotationMarker) {
        let rect = markerRect(for: marker)
        let path = NSBezierPath(ovalIn: rect)
        Design.Surface.accent.setFill()
        path.fill()
        annotationInk.setStroke()
        path.lineWidth = Layout.markerBorderWidth
        path.stroke()

        let value = "\(marker.id)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.numericDetail(weight: .semibold),
            .foregroundColor: annotationInk
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: CGPoint(
                x: floor(rect.midX - size.width / 2),
                y: floor(rect.midY - size.height / 2)
            ),
            withAttributes: attributes
        )
    }

    /// States on the browser surface itself that the surface is in a mode.
    ///
    /// The toolbar button already changes, but the pointer is over the *page* for the whole of
    /// annotation mode, and a crosshair is a cursor rather than a statement — a click that lands
    /// on a note instead of a link should not be a surprise. Drawn as a frame around the viewport
    /// rather than as a wash over it: a tint would recolour the page the user came here to look
    /// at, which is the one thing an annotation surface must not do.
    private func drawModeFrame() {
        let width = Layout.modeFrameWidth
        let shape = ThemedSurface.Shape(
            rect: bounds,
            radius: Design.Radius.control(fitting: bounds.size)
        ).inset(by: width / 2)
        strokeAnnotation(shape.path, width: width)
    }

    /// Names the mode in the corner, in the same accent pill vocabulary as the pins.
    ///
    /// Bottom-left because that is where a browser already puts transient status, and because
    /// the hovered component's own label is drawn *above* its outline: two labels that never
    /// contend for the same strip of page.
    private func drawModeBadge() {
        let title = L10n.string("Annotating · ⌥ precise")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(weight: .semibold),
            .foregroundColor: annotationInk
        ]
        let textSize = title.size(withAttributes: attributes)
        let glyphWidth = modeBadgeGlyph == nil ? 0 : Layout.modeBadgeGlyphSize + Layout.modeBadgeGlyphGap
        let width = Layout.modeBadgePadding * 2 + glyphWidth + textSize.width
        let badge = CGRect(
            x: Layout.modeBadgeInset,
            y: bounds.height - Layout.modeBadgeInset - Layout.modeBadgeHeight,
            width: width,
            height: Layout.modeBadgeHeight
        )
        guard badge.minY > 0, badge.maxX < bounds.width else { return }

        fillAnnotationBadge(ThemedSurface.Shape(
            rect: badge,
            radius: Design.Radius.pill(height: badge.height)
        ).path)

        var textX = badge.minX + Layout.modeBadgePadding
        if let glyph = modeBadgeGlyph {
            TemplateImageDrawing.draw(
                glyph,
                in: CGRect(
                    x: textX,
                    y: floor(badge.midY - Layout.modeBadgeGlyphSize / 2),
                    width: Layout.modeBadgeGlyphSize,
                    height: Layout.modeBadgeGlyphSize
                ),
                tint: annotationInk
            )
            textX += Layout.modeBadgeGlyphSize + Layout.modeBadgeGlyphGap
        }
        title.draw(
            at: CGPoint(x: textX, y: floor(badge.midY - textSize.height / 2)),
            withAttributes: attributes
        )
    }

    /// Outlines the component under the pointer and names it beside the outline.
    ///
    /// Clipped to the overlay rather than drawn as the page reported it: an element may begin
    /// above the viewport or run past its bottom, and a stroke laid down out there returns as a
    /// line along the overlay's edge that belongs to nothing on screen.
    private func draw(_ target: BrowserAnnotationTarget) {
        let width = Layout.targetOutlineWidth
        let visible = target.rect.intersection(bounds)
        guard !visible.isNull, visible.width > width, visible.height > width else { return }

        let shape = ThemedSurface.Shape(
            rect: visible,
            radius: Design.Radius.control(fitting: visible.size)
        ).inset(by: width / 2)
        strokeAnnotation(shape.path, width: width)

        drawLabel(target.label, above: visible)
    }

    /// Places the name above the outline, or inside its top edge when the component is against
    /// the top of the viewport — the one case where "above" is off screen.
    private func drawLabel(_ label: String, above rect: CGRect) {
        guard !label.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(weight: .semibold),
            .foregroundColor: annotationInk,
            .paragraphStyle: paragraph
        ]

        let textWidth = label.size(withAttributes: attributes).width
        let maximumWidth = bounds.width - Layout.targetLabelInset * 2
        let chipWidth = min(textWidth + Layout.targetLabelInset * 2, maximumWidth)
        guard chipWidth > 0 else { return }

        let above = rect.minY - Layout.targetLabelHeight - Layout.targetLabelGap
        let chip = CGRect(
            x: min(max(0, rect.minX), max(0, bounds.width - chipWidth)),
            y: above >= 0 ? above : min(rect.minY + Layout.targetLabelGap, max(0, bounds.height - Layout.targetLabelHeight)),
            width: chipWidth,
            height: Layout.targetLabelHeight
        )

        fillAnnotationBadge(ThemedSurface.Shape(
            rect: chip,
            radius: Design.Radius.pill(height: chip.height)
        ).path)

        let textHeight = label.size(withAttributes: attributes).height
        label.draw(
            in: CGRect(
                x: chip.minX + Layout.targetLabelInset,
                y: floor(chip.midY - textHeight / 2),
                width: chip.width - Layout.targetLabelInset * 2,
                height: textHeight
            ),
            withAttributes: attributes
        )
    }
}
