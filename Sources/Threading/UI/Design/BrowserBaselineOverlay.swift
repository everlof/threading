import AppKit

// MARK: - Content

/// The baseline being held over the live page.
struct BrowserBaselineOverlayContent: Equatable {
    let image: NSImage
    /// The name the user gave it, drawn in the mode badge so it is never ambiguous which approved
    /// picture is on screen.
    let name: String
    let captureKind: BrowserBaselineCaptureKind
    /// The document scroll offset the capture was taken at, in CSS pixels.
    let capturedScroll: CGPoint
    /// The capture's own size in CSS pixels.
    let captureSize: CGSize

    static func == (
        lhs: BrowserBaselineOverlayContent,
        rhs: BrowserBaselineOverlayContent
    ) -> Bool {
        lhs.image === rhs.image
            && lhs.name == rhs.name
            && lhs.captureKind == rhs.captureKind
            && lhs.capturedScroll == rhs.capturedScroll
            && lhs.captureSize == rhs.captureSize
    }
}

/// How the baseline is held against the page.
enum BrowserBaselineOverlayMode: String, CaseIterable {
    /// A vertical seam: baseline to its left, live page to its right.
    case wipe
    /// The whole baseline, semi-transparent, over the whole page.
    case fade

    var localizedName: String {
        switch self {
        case .wipe: return L10n.string("Wipe")
        case .fade: return L10n.string("Fade")
        }
    }
}

// MARK: - Overlay

/// An approved baseline drawn over the live page, with the page still live underneath it.
///
/// **A sibling of `BrowserAnnotationOverlay`, not a variant of it.** They share the infrastructure
/// that matters — a native layer above WebKit, the document-scroll observation in the isolated
/// client world, the accent mode frame and badge that say the surface is in a mode — and they
/// deliberately do not share hit testing. Annotation mode *takes* page clicks, because a click is
/// how a pin is placed. This overlay must pass every click through except on its own handle: the
/// entire point is that the user and the agent keep working on the live page while watching the
/// seam. Reusing the annotation overlay's behaviour wholesale would have made the page beneath it
/// unusable, which is the one thing it exists to avoid.
///
/// **It is native, and that is a contract.** Nothing here reaches the DOM, so `browser_screenshot`
/// and every baseline capture taken while it is up contain the page and not the overlay. Baking an
/// overlay into page pixels is already a documented non-goal, and this is the component most able
/// to break it by accident.
///
/// **Scroll validity is stated, not assumed.** A full-page baseline covers the document, so it can
/// track scrolling over its own captured extent. A viewport baseline is only true at the offset it
/// was captured at — scrolling away does not slide the missing pixels into view, and the overlay
/// says so rather than showing a confidently misaligned picture.
@MainActor
final class BrowserBaselineOverlay: NSView {

    @MainActor
    private enum Layout {
        static var frameWidth: CGFloat { Design.Accessibility.focusRingWidth }
        static var seamWidth: CGFloat { ImageCompareDefaults.seamWidth }
        static var handleDiameter: CGFloat { ImageCompareDefaults.handleDiameter }
        static let badgeHeight: CGFloat = Design.Size.chipHeight
        static let badgeInset: CGFloat = Design.Spacing.medium
        static let badgePadding: CGFloat = Design.Spacing.small
        /// How far off its captured offset a viewport baseline may be before the overlay says the
        /// two are not aligned. One CSS pixel, because that is the smallest misalignment a
        /// comparison would count as a difference.
        static let scrollTolerance: CGFloat = 1
    }

    // MARK: - Properties

    var content: BrowserBaselineOverlayContent? {
        didSet {
            guard content != oldValue else { return }
            handle.isHidden = content == nil
            layoutHandle()
            updateAccessibility()
            needsDisplay = true
        }
    }

    var mode: BrowserBaselineOverlayMode = .wipe {
        didSet {
            guard mode != oldValue else { return }
            handle.isHidden = content == nil
            updateAccessibility()
            needsDisplay = true
        }
    }

    /// The seam position in wipe mode, and the baseline's opacity in fade mode. One value across
    /// both, like `ImageCompareView`'s, so switching modes keeps the user's place.
    var fraction: CGFloat = 0.5 {
        didSet {
            let clamped = min(max(newFractionValue(fraction), 0), 1)
            if clamped != fraction {
                fraction = clamped
                return
            }
            guard fraction != oldValue else { return }
            layoutHandle()
            updateAccessibility()
            needsDisplay = true
        }
    }

    /// The live page's current document scroll, in CSS pixels. Fed by the browser's own scroll
    /// observer — the same isolated-world channel annotation mode already uses, which carries
    /// coordinates and nothing else.
    var documentScroll: CGPoint = .zero {
        didSet {
            guard documentScroll != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Where the page moved under the reader, in viewport CSS pixels.
    ///
    /// Drawn by the same surface as a held baseline because it answers the same shape of question —
    /// "what is not where it should be" — and because it must obey the same two contracts: it
    /// passes clicks through, and it never reaches the DOM, so a screenshot taken with it up is of
    /// the page rather than of the annotation.
    var layoutShifts: [BrowserLayoutShiftRegion] = [] {
        didSet {
            guard layoutShifts != oldValue else { return }
            handle.isHidden = content == nil
            updateAccessibility()
            needsDisplay = true
        }
    }

    /// Raised when the user dismisses the overlay from its own surface.
    var onDismiss: (() -> Void)?

    private lazy var handle: BrowserBaselineOverlayHandle = {
        let handle = BrowserBaselineOverlayHandle()
        handle.onScrub = { [weak self] fraction in self?.fraction = fraction }
        handle.onDismiss = { [weak self] in self?.onDismiss?() }
        handle.isHidden = true
        return handle
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(handle)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Baseline overlay"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - Hit testing

    /// Everything but the handle passes straight through to the page.
    ///
    /// This is the whole behavioural difference from annotation mode, and it is why the handle is a
    /// real subview rather than something drawn: a drawn control would need this method to answer
    /// "yes" over a region, which is one refactor away from swallowing a click on a link.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard content != nil || !layoutShifts.isEmpty, !handle.isHidden else { return nil }
        // `hitTest` takes the point in the *superview's* space, and `handle.hitTest` wants it in
        // the handle's superview — which is this view. Converting a second time, into the handle's
        // own coordinates, is the mistake that made the handle unclickable while every test that
        // only checked "the page still gets its clicks" passed.
        let local = convert(point, from: superview)
        guard handle.frame.contains(local) else { return nil }
        return handle.hitTest(local) ?? handle
    }

    override func layout() {
        super.layout()
        layoutHandle()
    }

    /// The overlay is frame-positioned by its host rather than constrained, so `layout()` is not
    /// guaranteed to run when it resizes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHandle()
    }

    private func layoutHandle() {
        let diameter = Layout.handleDiameter
        handle.frame = CGRect(
            x: seamX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private var seamX: CGFloat {
        switch mode {
        case .wipe: return bounds.width * fraction
        // In fade mode the handle is an opacity slider and sits where the fraction puts it along
        // the bottom edge, so the gesture is the same drag in both modes.
        case .fade: return bounds.width * fraction
        }
    }

    private func newFractionValue(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0.5
    }

    // MARK: - Alignment

    /// Where the baseline's own origin sits, in overlay coordinates, and whether it is aligned.
    ///
    /// A full-page baseline is anchored to the document, so its origin travels with the scroll. A
    /// viewport baseline is anchored to a moment: it is only the truth at the offset it was taken
    /// at, and scrolling does not reveal pixels it never contained.
    var alignment: (origin: CGPoint, isAligned: Bool) {
        guard let content else { return (.zero, false) }
        switch content.captureKind {
        case .fullPage:
            let origin = CGPoint(x: -documentScroll.x, y: -documentScroll.y)
            // Aligned as long as the visible band is inside what the capture actually covers.
            let withinCapture = documentScroll.y >= -Layout.scrollTolerance
                && documentScroll.y <= content.captureSize.height + Layout.scrollTolerance
            return (origin, withinCapture)
        case .viewport, .element:
            let dx = documentScroll.x - content.capturedScroll.x
            let dy = documentScroll.y - content.capturedScroll.y
            let aligned = abs(dx) <= Layout.scrollTolerance && abs(dy) <= Layout.scrollTolerance
            // Deliberately *not* offset by the drift: sliding a viewport capture around would
            // present pixels at positions they were never captured at.
            return (.zero, aligned)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let content else {
            if !layoutShifts.isEmpty {
                drawModeFrame()
                drawLayoutShifts()
                drawShiftBadge()
            }
            return
        }

        let placement = alignment
        let imageRect = CGRect(
            origin: placement.origin,
            size: content.captureSize == .zero ? content.image.size : content.captureSize
        )

        NSGraphicsContext.saveGraphicsState()
        switch mode {
        case .wipe:
            NSBezierPath(rect: CGRect(
                x: 0,
                y: 0,
                width: max(0, seamX),
                height: bounds.height
            )).addClip()
            content.image.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: placement.isAligned ? 1 : 0.5
            )
        case .fade:
            content.image.draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: (placement.isAligned ? 1 : 0.5) * fraction
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        drawModeFrame()
        if mode == .wipe { drawSeam() }
        drawLayoutShifts()
        drawBadge(for: content, isAligned: placement.isAligned)
    }

    /// Outlines where content used to be before it moved.
    ///
    /// The *previous* rectangle, not the current one, because that is where the reader was looking
    /// when the page pulled it away. Opacity follows the shift's own score, so a comparison between
    /// a jolt and a hairline is visible rather than every rectangle shouting equally.
    private func drawLayoutShifts() {
        guard !layoutShifts.isEmpty else { return }
        let loudest = layoutShifts.map(\.value).max() ?? 0
        for shift in layoutShifts {
            let rect = CGRect(x: shift.x, y: shift.y, width: shift.width, height: shift.height)
                .intersection(bounds)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }

            let weight = loudest > 0 ? max(0.25, min(1, shift.value / loudest)) : 1
            let shape = ThemedSurface.Shape(
                rect: rect,
                radius: Design.Radius.control(fitting: rect.size)
            ).inset(by: Layout.frameWidth / 2)
            Design.Status.warning.withAlphaComponent(0.18 * weight).setFill()
            shape.path.fill()
            Design.Status.warning.withAlphaComponent(0.7 + 0.3 * weight).setStroke()
            let path = shape.path
            path.lineWidth = Layout.frameWidth
            path.stroke()
        }
    }

    /// Names what the rectangles are, when they are the only thing on the surface.
    private func drawShiftBadge() {
        let total = layoutShifts.reduce(0) { $0 + $1.value }
        let title = L10n.format(
            "Layout shift · %@ · %lld places",
            String(format: "%.3f", total),
            Int64(layoutShifts.count)
        )
        drawBadge(titled: title)
    }

    /// The same frame annotation mode draws, for the same reason: the surface is in a mode, and
    /// what is on screen is not only the page.
    private func drawModeFrame() {
        let width = Layout.frameWidth
        let shape = ThemedSurface.Shape(
            rect: bounds,
            radius: Design.Radius.control(fitting: bounds.size)
        ).inset(by: width / 2)
        Design.Surface.accent.setStroke()
        let path = shape.path
        path.lineWidth = width
        path.stroke()
    }

    private func drawSeam() {
        let width = Layout.seamWidth
        Design.Surface.accent.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: seamX, y: 0))
        path.line(to: CGPoint(x: seamX, y: bounds.height))
        path.lineWidth = width
        path.stroke()
    }

    /// Names the baseline, and says plainly when the page has been scrolled away from it.
    ///
    /// The misalignment notice is the honest half of this component. A viewport baseline held over
    /// a page scrolled somewhere else looks like a page that has changed enormously, and without
    /// this the overlay would be quietly lying at exactly the moment someone is deciding whether
    /// something regressed.
    private func drawBadge(for content: BrowserBaselineOverlayContent, isAligned: Bool) {
        var title = L10n.format("Baseline · %@", content.name)
        if !isAligned {
            title += " · " + L10n.string("scrolled away from where this was captured")
        }
        drawBadge(titled: title)
    }

    private func drawBadge(titled title: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(weight: .semibold),
            .foregroundColor: Design.Text.selected
        ]
        let textSize = title.size(withAttributes: attributes)
        let badge = CGRect(
            x: Layout.badgeInset,
            y: bounds.height - Layout.badgeInset - Layout.badgeHeight,
            width: min(
                Layout.badgePadding * 2 + textSize.width,
                max(0, bounds.width - Layout.badgeInset * 2)
            ),
            height: Layout.badgeHeight
        )
        guard badge.minY > 0, badge.width > Layout.badgePadding * 2 else { return }

        Design.Surface.accent.setFill()
        ThemedSurface.Shape(
            rect: badge,
            radius: Design.Radius.pill(height: badge.height)
        ).path.fill()
        title.draw(
            in: CGRect(
                x: badge.minX + Layout.badgePadding,
                y: floor(badge.midY - textSize.height / 2),
                width: badge.width - Layout.badgePadding * 2,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        handle.setAccessibilityValue(Int((fraction * 100).rounded()))
        handle.setAccessibilityLabel(
            mode == .wipe
                ? L10n.string("Baseline wipe position")
                : L10n.string("Baseline opacity")
        )
        setAccessibilityValue(content?.name ?? "")
    }
}

// MARK: - Handle

/// The one thing on the overlay a click can land on.
///
/// A `ThemedControl` so it takes focus, answers arrow keys and reports itself as a slider — the
/// overlay is otherwise invisible to the keyboard and to VoiceOver, which for a surface drawn over
/// the user's page is not acceptable.
@MainActor
final class BrowserBaselineOverlayHandle: ThemedControl {

    var onScrub: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    /// The nudge one arrow key makes, as a fraction of the overlay's width. `ImageCompareView`'s
    /// step, so the two scrubbing surfaces in the app move by the same amount.
    private var step: CGFloat { ImageCompareDefaults.keyboardStep }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.slider)
        setAccessibilityHelp(
            L10n.string("Drag or use the arrow keys to move the baseline against the live page")
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility

    /// A slider, and its press is the mid-point reset — the one action a scrub surface has that is
    /// not a scrub. VoiceOver otherwise reaches a control it can focus and cannot act on.
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }

    override func accessibilityPerformPress() -> Bool {
        performPrimaryAction()
    }

    override func performPrimaryAction() -> Bool {
        onScrub?(0.5)
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        scrub(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        scrub(to: event)
    }

    private func scrub(to event: NSEvent) {
        guard let host = superview, host.bounds.width > 0 else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        onScrub?(min(max(point.x / host.bounds.width, 0), 1))
    }

    override func keyDown(with event: NSEvent) {
        guard let host = superview, host.bounds.width > 0 else {
            super.keyDown(with: event)
            return
        }
        let current = (frame.midX) / host.bounds.width
        switch event.keyCode {
        case 123: onScrub?(max(0, current - step))       // left
        case 124: onScrub?(min(1, current + step))       // right
        case 53: onDismiss?()                            // escape
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shape = ThemedSurface.Shape(
            rect: bounds,
            radius: Design.Radius.pill(height: bounds.height)
        )
        Design.Surface.accent.setFill()
        shape.path.fill()
        Design.Surface.ground.setStroke()
        let path = shape.inset(by: Design.Radius.border / 2).path
        path.lineWidth = Design.Radius.border
        path.stroke()
        drawKeyboardFocus(around: shape)
    }
}

// MARK: - Layout Shift

/// One place the page moved under the reader, in the overlay's own coordinates.
///
/// A plain value rather than the bridge's decoded report, because the overlay is a Design component
/// and must not know the shape of a browser bridge payload. The browser converts.
struct BrowserLayoutShiftRegion: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// The shift score this rectangle belonged to; drives how loudly it is drawn.
    let value: Double
}
