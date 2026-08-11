import AppKit

/// The scroll thumb and track owned by Threading's chrome.
///
/// System remains exactly AppKit's scroller: its drawing methods are handed straight back to
/// `NSScroller`. An ordinary authored theme replaces only the proportional thumb and track.
/// A theme that explicitly names a period appearance also supplies the missing pre-Lion
/// anatomy — end arrows, square track, era-specific thumb, and matching hit geometry — while
/// the `NSScroller` still owns the value and knob drag.
///
/// The ink source matters for the terminal. Ordinary scroll views sit on app-owned chrome;
/// SwiftTerm's scroller sits on the terminal palette that also paints the window backdrop. One
/// component takes that difference as data rather than introducing a second scrollbar.
///
/// A scroller that stands alone — outside any `NSScrollView` — additionally owns its own fade;
/// see `isUnmanaged`.
final class ThemedScroller: NSScroller, ThemedComponent, InkSourced {

    let inkSource: InkSource

    /// Reports a proportional-thumb action immediately before the scroll view receives it.
    /// `NSScrollView`'s live-scroll notification arrives after tracking has started, which is
    /// too late for a large virtualized document to choose cheap transient rows before the first
    /// jump. Line buttons and track clicks deliberately stay on the ordinary scroll path.
    var onWillScrollWithKnob: (() -> Void)?

    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()
    private var hoverTracking: NSTrackingArea?
    private var isHovered = false
    private var hideWork: DispatchWorkItem?

    override class var isCompatibleWithOverlayScrollers: Bool {
        self == ThemedScroller.self
    }

    /// The identity theme owns no scrollbar appearance; AppKit draws both parts.
    var delegatesDrawingToAppKit: Bool {
        AppThemePalette.current.isSystem
    }

    var scrollerAppearance: AppTheme.Material.ScrollerAppearance {
        AppThemePalette.current.material(for: effectiveAppearance).scrollerAppearance
    }

    override init(frame frameRect: NSRect) {
        inkSource = .chrome
        super.init(frame: frameRect)
        observeAppearance()
    }

    init(frame frameRect: NSRect, inkSource: InkSource) {
        self.inkSource = inkSource
        super.init(frame: frameRect)
        observeAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func observeAppearance() {
        themeRedraw = ThemeRedraw(self)
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            guard self?.inkSource == .backdrop else { return }
            self?.needsDisplay = true
        }
        appEvents.observe(NSScroller.preferredScrollerStyleDidChangeNotification) { [weak self] in
            self?.settleVisibility()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Standing Alone

    /// Whether nothing but this view decides when the scrollbar is on screen.
    ///
    /// A scroll view owns its scrollers: it fades them, and while they are faded it does not
    /// call their drawing parts at all — which is why every scroll surface in the app keeps
    /// AppKit's overlay behaviour for free. SwiftTerm's scroller has no such owner. It is a bare
    /// `NSScroller` the terminal positions, sizes and drives itself, so its `draw(_:)` runs on
    /// every display pass and calls both parts unconditionally.
    ///
    /// AppKit's own parts answer that by painting nothing whatsoever — measured, a standalone
    /// `NSScroller` covers zero pixels in either style, whatever the user's scroll-bar
    /// preference. That is why the terminal had no visible scrollbar at all before this
    /// component drew one, and why the one it drew stayed up forever: unconditional drawing is
    /// correct only for a scroller somebody else is fading.
    private var isUnmanaged: Bool {
        guard let superview else { return false }
        return !(superview is NSScrollView)
    }

    /// The user's own answer to the same question. "Always show scroll bars" asks for a
    /// scrollbar that does not leave, and for a standalone scroller this is the only place that
    /// preference is read.
    private var neverHides: Bool {
        scrollerAppearance.usesLegacyPresentation
            || NSScroller.preferredScrollerStyle == .legacy
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        settleVisibility()
        updateTrackingAreas()
    }

    /// The resting state, taken without animation: nothing has moved to animate from.
    private func settleVisibility() {
        hideWork?.cancel()
        hideWork = nil
        alphaValue = isUnmanaged && !neverHides ? 0 : 1
    }

    /// Brings the scrollbar up and starts the clock that takes it away again.
    private func reveal() {
        guard isUnmanaged, isEnabled else { return }
        setRevealed(true)
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        hideWork = nil
        guard isUnmanaged, !neverHides, !isHovered else { return }
        let work = DispatchWorkItem { [weak self] in self?.setRevealed(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Design.Motion.scrollerHold, execute: work)
    }

    /// The animator proxy writes the value through before it animates it, so a caller — or a
    /// test — reads the state it asked for whether or not the fade is running.
    private func setRevealed(_ revealed: Bool) {
        let target: CGFloat = revealed ? 1 : 0
        guard alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealed ? Design.Motion.appear : Design.Motion.vanish
            animator().alphaValue = target
        }
    }

    /// Movement of the *position* is the only thing worth showing a scrollbar for.
    ///
    /// Deliberately not `knobProportion`: a terminal pinned to the bottom of a growing buffer
    /// reports the same position — SwiftTerm's `scrollPosition` saturates at 1 — while its thumb
    /// shrinks on every line an agent prints. Revealing on the thumb would hold the scrollbar up
    /// for the whole of a streaming answer, which is the state this was reported in.
    override var doubleValue: Double {
        get { super.doubleValue }
        set {
            let moved = newValue != super.doubleValue
            super.doubleValue = newValue
            if moved { reveal() }
        }
    }

    /// Nothing to scroll, nothing to show — a terminal that just handed its screen to a
    /// full-screen program takes its scrollbar with it rather than leaving one behind.
    override var isEnabled: Bool {
        get { super.isEnabled }
        set {
            super.isEnabled = newValue
            guard !newValue, isUnmanaged, !neverHides else { return }
            hideWork?.cancel()
            hideWork = nil
            setRevealed(false)
        }
    }

    /// Reaching for the scrollbar keeps it, which is what makes a revealed one grabbable. A
    /// managed scroller is left alone: AppKit already tracks its own hover, and expands on it.
    ///
    /// The terminal's scroller is exactly the view `PointerTracking` describes — it is resized
    /// under a stationary pointer on every window resize and every font change — so the hover
    /// flag is re-derived here rather than waiting for a `mouseExited` that will not come.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverIsStale(isHovered) {
            isHovered = false
            scheduleHide()
        }
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
            self.hoverTracking = nil
        }
        guard isUnmanaged else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        reveal()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        scheduleHide()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if hitPart == .knob {
            onWillScrollWithKnob?()
        }
        return super.sendAction(action, to: target)
    }

    // MARK: - Geometry

    private var isHorizontalScroller: Bool { bounds.width > bounds.height }

    override func rect(for part: NSScroller.Part) -> NSRect {
        let appearance = scrollerAppearance
        guard appearance.usesLegacyPresentation else { return super.rect(for: part) }

        let physicalBounds = bounds.integral
        // WordPad's horizontal control ends with a one-pixel COLOR_BTNFACE junction rail.
        // Its arrows and slot occupy the remaining width; treating the rail as part of the
        // Down/Right button moved that button and shortened the native thumb by one pixel.
        let full: NSRect = if appearance == .windows98,
                              isHorizontalScroller,
                              physicalBounds.width > 1 {
            NSRect(
                x: physicalBounds.minX,
                y: physicalBounds.minY,
                width: physicalBounds.width - 1,
                height: physicalBounds.height
            )
        } else {
            physicalBounds
        }
        let thickness = max(0, min(full.width, full.height))
        guard thickness > 0 else { return .zero }
        // Several period scrollers used a narrow shaft but a slightly longer line-button plate.
        // Treating every arrow as a square was especially visible in the native BeOS and IRIX
        // excerpts: their triangles were squeezed into modern-looking little caps.
        let arrowLength = lineButtonLength(for: appearance, thickness: thickness)

        let decrement: NSRect
        let increment: NSRect
        let slot: NSRect
        if appearance == .beOS {
            // BeOS repeats the up/down (or left/right) pair at both ends of the shaft. NSScroller
            // exposes only one rect per semantic line action, so these are the leading pair;
            // the duplicated trailing pair is drawn and hit-tested separately below.
            if isHorizontalScroller {
                decrement = NSRect(
                    x: full.minX, y: full.minY,
                    width: min(arrowLength, full.width), height: full.height
                )
                increment = NSRect(
                    x: min(full.maxX, full.minX + arrowLength), y: full.minY,
                    width: min(arrowLength, max(0, full.width - arrowLength)),
                    height: full.height
                )
                slot = NSRect(
                    x: min(full.maxX, full.minX + 2 * arrowLength), y: full.minY,
                    width: max(0, full.width - 4 * arrowLength), height: full.height
                )
            } else {
                decrement = NSRect(
                    x: full.minX, y: full.minY,
                    width: full.width, height: min(arrowLength, full.height)
                )
                increment = NSRect(
                    x: full.minX, y: min(full.maxY, full.minY + arrowLength),
                    width: full.width,
                    height: min(arrowLength, max(0, full.height - arrowLength))
                )
                slot = NSRect(
                    x: full.minX, y: min(full.maxY, full.minY + 2 * arrowLength),
                    width: full.width, height: max(0, full.height - 4 * arrowLength)
                )
            }
        } else if isHorizontalScroller {
            if appearance.groupsArrowsAtTrailingEnd {
                decrement = NSRect(
                    x: max(full.minX, full.maxX - 2 * arrowLength),
                    y: full.minY,
                    width: min(arrowLength, full.width),
                    height: full.height
                )
                increment = NSRect(
                    x: max(full.minX, full.maxX - arrowLength),
                    y: full.minY,
                    width: min(arrowLength, full.width),
                    height: full.height
                )
                slot = NSRect(
                    x: full.minX,
                    y: full.minY,
                    width: max(0, full.width - 2 * arrowLength),
                    height: full.height
                )
            } else {
                decrement = NSRect(
                    x: full.minX, y: full.minY,
                    width: min(arrowLength, full.width), height: full.height
                )
                increment = NSRect(
                    x: max(full.minX, full.maxX - arrowLength), y: full.minY,
                    width: min(arrowLength, full.width), height: full.height
                )
                slot = NSRect(
                    x: min(full.maxX, full.minX + arrowLength), y: full.minY,
                    width: max(0, full.width - 2 * arrowLength), height: full.height
                )
            }
        } else if appearance.groupsArrowsAtTrailingEnd {
            // A standalone NSScroller is unflipped, but the scrollers installed by
            // NSScrollView are flipped. In either coordinate system the period pair belongs
            // at the *visual* bottom: Up immediately above Down, with the slot ending above
            // both. Treating minY as physical bottom put every hosted Workbench pair at the
            // top even though the standalone Platinum/OPENSTEP evidence looked correct.
            if isFlipped {
                decrement = NSRect(
                    x: full.minX, y: max(full.minY, full.maxY - 2 * arrowLength),
                    width: full.width, height: min(arrowLength, full.height)
                )
                increment = NSRect(
                    x: full.minX, y: max(full.minY, full.maxY - arrowLength),
                    width: full.width, height: min(arrowLength, full.height)
                )
                slot = NSRect(
                    x: full.minX, y: full.minY,
                    width: full.width, height: max(0, full.height - 2 * arrowLength)
                )
            } else {
                decrement = NSRect(
                    x: full.minX, y: min(full.maxY, full.minY + arrowLength),
                    width: full.width, height: min(arrowLength, full.height)
                )
                increment = NSRect(
                    x: full.minX, y: full.minY,
                    width: full.width, height: min(arrowLength, full.height)
                )
                slot = NSRect(
                    x: full.minX, y: min(full.maxY, full.minY + 2 * arrowLength),
                    width: full.width, height: max(0, full.height - 2 * arrowLength)
                )
            }
        } else {
            decrement = NSRect(
                x: full.minX, y: full.minY,
                width: full.width, height: min(arrowLength, full.height)
            )
            increment = NSRect(
                x: full.minX, y: max(full.minY, full.maxY - arrowLength),
                width: full.width, height: min(arrowLength, full.height)
            )
            slot = NSRect(
                x: full.minX, y: min(full.maxY, full.minY + arrowLength),
                width: full.width, height: max(0, full.height - 2 * arrowLength)
            )
        }

        let slotLength = isHorizontalScroller ? slot.width : slot.height
        let minimumKnob: CGFloat = switch appearance {
        case .aqua, .aquaTiger: thickness * 1.5
        // R5's 12px shaft carries a 15px minimum proportional gadget, the same longitudinal
        // measure as each of its repeated line buttons.
        case .beOS: lineButtonLength(for: .beOS, thickness: thickness)
        // USER32's minimum proportional box is half the 16px scroll metric in the preserved
        // WordPad control. A square minimum invented a second arrow-sized plate and consumed
        // eight real page-region rows at the top of every short Windows scrollbar.
        case .windows98: floor(thickness / 2)
        default: thickness
        }
        let hidesEmptyWindowsThumb = appearance == .windows98 && knobProportion <= 0
        let knobLength = hidesEmptyWindowsThumb ? 0 : min(
            slotLength,
            max(minimumKnob, floor(slotLength * max(0, min(1, knobProportion))))
        )
        let travel = max(0, slotLength - knobLength)
        let value = CGFloat(max(0, min(1, doubleValue)))
        let knob: NSRect
        if hidesEmptyWindowsThumb {
            knob = .zero
        } else if isHorizontalScroller {
            knob = NSRect(
                x: slot.minX + travel * value,
                y: slot.minY,
                width: knobLength,
                height: slot.height
            )
        } else {
            knob = NSRect(
                x: slot.minX,
                // A scroll value of zero is the visual top of the document. Standalone
                // scrollers are unflipped; NSScrollView's hosted scrollers are flipped.
                y: isFlipped
                    ? slot.minY + travel * value
                    : slot.maxY - knobLength - travel * value,
                width: slot.width,
                height: knobLength
            )
        }

        switch part {
        case .decrementLine: return decrement
        case .incrementLine: return increment
        case .knobSlot: return slot
        case .knob: return knob
        case .decrementPage:
            if knob.isEmpty { return .zero }
            if isHorizontalScroller {
                return NSRect(
                    x: slot.minX, y: slot.minY,
                    width: max(0, knob.minX - slot.minX), height: slot.height
                )
            }
            if isFlipped {
                return NSRect(
                    x: slot.minX, y: slot.minY,
                    width: slot.width, height: max(0, knob.minY - slot.minY)
                )
            }
            return NSRect(
                x: slot.minX, y: knob.maxY,
                width: slot.width, height: max(0, slot.maxY - knob.maxY)
            )
        case .incrementPage:
            if knob.isEmpty { return slot }
            if isHorizontalScroller {
                return NSRect(
                    x: knob.maxX, y: slot.minY,
                    width: max(0, slot.maxX - knob.maxX), height: slot.height
                )
            }
            if isFlipped {
                return NSRect(
                    x: slot.minX, y: knob.maxY,
                    width: slot.width, height: max(0, slot.maxY - knob.maxY)
                )
            }
            return NSRect(
                x: slot.minX, y: slot.minY,
                width: slot.width, height: max(0, knob.minY - slot.minY)
            )
        case .noPart: return .zero
        @unknown default: return super.rect(for: part)
        }
    }

    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        guard scrollerAppearance.usesLegacyPresentation else {
            return super.testPart(point)
        }
        if let repeated = beOSRepeatedArrowRects {
            if repeated.decrement.contains(point) { return .decrementLine }
            if repeated.increment.contains(point) { return .incrementLine }
        }
        for part: NSScroller.Part in [
            .decrementLine, .incrementLine, .knob, .decrementPage, .incrementPage
        ] where rect(for: part).contains(point) {
            return part
        }
        return .noPart
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard scrollerAppearance.usesLegacyPresentation else {
            super.draw(dirtyRect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = scrollerAppearance == .aqua
            || scrollerAppearance == .aquaTiger

        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)
    }

    override func drawKnob() {
        guard !delegatesDrawingToAppKit else {
            super.drawKnob()
            return
        }

        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        switch scrollerAppearance {
        case .automatic:
            drawPill(inkSource.ink.secondary, in: knob)
        case .aqua, .aquaTiger:
            drawAquaGel(in: knob, pressed: false)
        case .platinum:
            if !isHorizontalScroller,
               knob.width == 14,
               knob.height == 37 {
                drawPlatinumPixels(Self.platinumVerticalThumb, in: knob)
            } else {
                drawPlatinumThumb(in: knob)
            }
        case .amiga:
            ThemedSurface.draw(
                knob,
                // Workbench's proportional gadget is the same indexed blue as its active
                // title strip (#6688BB). The general accent is intentionally darker for
                // modern actions in this theme, but using it here made the scroller visibly
                // too dark against the source capture's title-colour thumb.
                fill: amigaScrollerFill,
                radius: 0,
                bevel: .automatic
            )
            drawGrip(in: knob, ink: Design.Text.label)
        case .irix:
            if !rendersIRIXReferenceState {
                ThemedSurface.draw(
                    knob,
                    fill: Design.Surface.controlResting,
                    border: Design.Surface.border,
                    radius: 0,
                    bevel: .automatic
                )
                drawGrip(in: knob, ink: Design.Text.secondary)
            }
        case .beOS:
            if !isHorizontalScroller,
               knob.width == 12,
               knob.height == 15 {
                drawBeOSPixels(Self.beOSVerticalThumb, in: knob)
            } else {
                drawBeOSThumb(in: knob)
            }
        case .openStep:
            if !rendersOpenStepReferenceState {
                drawOpenStepThumb(in: knob)
            }
        case .windows98:
            if !isHorizontalScroller,
               knob.width == 16,
               knob.height == 8 {
                drawWindows98Pixels(Self.windows98VerticalThumb, in: knob)
            } else if isHorizontalScroller,
                      knob.height == 16 {
                drawWindows98HorizontalThumb(in: knob)
            } else {
                ThemedSurface.draw(
                    knob,
                    fill: Design.Surface.controlResting,
                    radius: 0,
                    bevel: .automatic
                )
            }
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !delegatesDrawingToAppKit else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }

        let appearance = scrollerAppearance
        if rendersIRIXReferenceState {
            drawIRIXReferenceScroller(in: bounds)
            return
        }
        if rendersOpenStepReferenceState {
            drawOpenStepReferenceScroller(in: bounds)
            return
        }
        let trackRect = appearance.usesLegacyPresentation
            ? rect(for: .knobSlot)
            : slotRect
        guard !trackRect.isEmpty else { return }
        let ink = inkSource.ink
        let ground: NSColor = if appearance.usesLegacyPresentation {
            flag ? Design.Surface.controlHover : Design.Surface.field
        } else {
            flag ? ink.surfaceHover : ink.surface
        }
        if appearance == .platinum,
           !isHorizontalScroller,
           trackRect.width == 14,
           trackRect.height == 154 {
            drawPlatinumVerticalTrack(in: trackRect)
        } else if appearance == .beOS,
                  !isHorizontalScroller,
                  trackRect.width == 12,
                  trackRect.height == 140 {
            drawBeOSVerticalTrack(in: trackRect)
        } else if appearance == .aqua {
            drawCheetahTrack(in: trackRect)
        } else if appearance == .aquaTiger {
            drawTigerTrack(in: trackRect)
        } else if AppThemePalette.current.material(
            for: effectiveAppearance
        ).scrollerTrackStyle == .stippled {
            let patternInk: NSColor = switch appearance {
            case .windows98: Design.Surface.controlResting
            case .openStep: Design.Surface.bevelShadow
            case .amiga: Design.Text.label
            default: ink.secondary
            }
            if appearance == .windows98, !isHorizontalScroller {
                // The vertical USER32 shaft reserves its trailing column for the same #DF
                // frame rail that runs through both arrow buttons and the thumb.
                let pageRegion = NSRect(
                    x: trackRect.minX,
                    y: trackRect.minY,
                    width: max(0, trackRect.width - 1),
                    height: trackRect.height
                )
                drawStippledTrack(ground: ground, ink: patternInk, in: pageRegion)
                windows98InnerHighlightColor.setFill()
                NSRect(
                    x: trackRect.maxX - 1,
                    y: trackRect.minY,
                    width: 1,
                    height: trackRect.height
                ).fill()
            } else if appearance == .windows98, isHorizontalScroller {
                // The horizontal control's page bitmap starts on the opposite checker phase
                // from the vertical shaft at its measured leading edge.
                drawStippledTrack(
                    ground: ground,
                    ink: patternInk,
                    in: trackRect,
                    phaseOffset: 1
                )
                Design.Surface.controlResting.setFill()
                NSRect(
                    x: bounds.maxX - 1,
                    y: bounds.minY,
                    width: 1,
                    height: bounds.height
                ).fill()
            } else {
                drawStippledTrack(ground: ground, ink: patternInk, in: trackRect)
            }
        } else if appearance.usesLegacyPresentation {
            ThemedSurface.draw(
                trackRect,
                fill: ground,
                radius: 0,
                bevel: .sunken
            )
        } else {
            drawPill(ground, in: trackRect)
        }

        // NSScroller still dispatches its old part-drawing hooks on current macOS, but no
        // longer asks a subclass to paint the deprecated line buttons from `draw(_:)`.
        // Period appearances deliberately restore those parts, so the slot hook is the one
        // reliable pass that owns the complete control. Drawing the knob here as well is
        // idempotent: AppKit may call `drawKnob()` afterwards, while a vertical legacy
        // scroller may decide its modern usable-parts policy does not include one at all.
        if appearance.usesLegacyPresentation {
            drawClassicArrowButton(rect(for: .decrementLine), increment: false)
            drawClassicArrowButton(rect(for: .incrementLine), increment: true)
            if let repeated = beOSRepeatedArrowRects {
                drawClassicArrowButton(repeated.decrement, increment: false)
                drawClassicArrowButton(repeated.increment, increment: true)
            }
            drawKnob()
        }
    }

    /// Cheetah's 16px trough is an asymmetric inset well, not the later symmetric silver
    /// gradient. These scanlines are the measured centre-column luminance from TextEdit's Open
    /// panel. They are geometry rather than an image asset: each authored row scales with a
    /// custom thickness while the native 16px control retains its exact one-point bands.
    private func drawCheetahTrack(in rect: NSRect) {
        let rowsTopToBottom: [CGFloat] = [
            255, 221, 192, 200, 211, 219, 228, 235,
            241, 246, 250, 251, 252, 249, 244, 239
        ]
        let rowHeight = rect.height / CGFloat(rowsTopToBottom.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        for (index, value) in rowsTopToBottom.enumerated() {
            let channel = value / 255
            NSColor(srgbRed: channel, green: channel, blue: channel, alpha: 1).setFill()
            let y = isFlipped
                ? rect.minY + CGFloat(index) * rowHeight
                : rect.maxY - CGFloat(index + 1) * rowHeight
            NSRect(x: rect.minX, y: y, width: rect.width, height: rowHeight).fill()
        }
    }

    /// Tiger's trailing-edge trough is brightest at its leading rail, falls through a short
    /// gray well, then blooms nearly white at the window edge. The former symmetric gradient
    /// inverted that construction and made the blue thumb appear to float over a modern pill.
    private func drawTigerTrack(in rect: NSRect) {
        let values: [CGFloat] = [
            255, 255, 184, 192, 200, 211, 219, 228,
            235, 241, 246, 250, 251, 252, 249
        ]
        let crossStep = (isHorizontalScroller ? rect.height : rect.width)
            / CGFloat(values.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        for (index, measured) in values.enumerated() {
            let channel = measured / 255
            NSColor(srgbRed: channel, green: channel, blue: channel, alpha: 1).setFill()
            if isHorizontalScroller {
                let y = isFlipped
                    ? rect.minY + CGFloat(index) * crossStep
                    : rect.maxY - CGFloat(index + 1) * crossStep
                NSRect(x: rect.minX, y: y, width: rect.width, height: crossStep).fill()
            } else {
                NSRect(
                    x: rect.minX + CGFloat(index) * crossStep,
                    y: rect.minY,
                    width: crossStep,
                    height: rect.height
                ).fill()
            }
        }
    }

    /// The second BeOS arrow pair. It invokes the same two semantic line actions as the first,
    /// which is why it is not represented by a new public scroller part.
    private var beOSRepeatedArrowRects: (decrement: NSRect, increment: NSRect)? {
        guard scrollerAppearance == .beOS else { return nil }
        let full = bounds.integral
        let thickness = max(0, min(full.width, full.height))
        let length = lineButtonLength(for: .beOS, thickness: thickness)
        guard length > 0 else { return nil }
        if isHorizontalScroller {
            return (
                NSRect(
                    x: max(full.minX, full.maxX - 2 * length), y: full.minY,
                    width: min(length, full.width), height: full.height
                ),
                NSRect(
                    x: max(full.minX, full.maxX - length), y: full.minY,
                    width: min(length, full.width), height: full.height
                )
            )
        }
        return (
            NSRect(
                x: full.minX, y: max(full.minY, full.maxY - 2 * length),
                width: full.width, height: min(length, full.height)
            ),
            NSRect(
                x: full.minX, y: max(full.minY, full.maxY - length),
                width: full.width, height: min(length, full.height)
            )
        )
    }

    private func lineButtonLength(
        for appearance: AppTheme.Material.ScrollerAppearance,
        thickness: CGFloat
    ) -> CGFloat {
        switch appearance {
        // Platinum's 14px shaft uses two 15px trailing button cells. Each cell owns one
        // closing black seam, so the visible silver plate remains the native 14px square.
        case .platinum: thickness + 1
        case .beOS: thickness + 3
        case .irix: thickness + 1
        case .aqua: thickness + 1
        default: thickness
        }
    }

    private func drawStippledTrack(
        ground: NSColor,
        ink: NSColor,
        in rect: NSRect,
        phaseOffset: Int = 0
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        ground.setFill()
        rect.fill()
        ink.setFill()

        // A one-point checker on a two-point lattice: visible at 1×, still mechanically
        // regular on Retina, and never softened into a contemporary noise texture.
        let minX = floor(rect.minX)
        let maxX = ceil(rect.maxX)
        let minY = floor(rect.minY)
        let maxY = ceil(rect.maxY)
        var y = minY
        var row = 0
        while y < maxY {
            var x = minX + CGFloat((row + phaseOffset) % 2)
            while x < maxX {
                NSRect(x: x, y: y, width: 1, height: 1).fill()
                x += 2
            }
            y += 1
            row += 1
        }
    }

    private func drawClassicArrowButton(_ rect: NSRect, increment: Bool) {
        guard !rect.isEmpty else { return }
        if scrollerAppearance == .beOS,
           !isHorizontalScroller,
           rect.width == 12,
           rect.height == 15,
           hitPart != (increment ? .incrementLine : .decrementLine) {
            // `NSScroller`'s unflipped part naming puts its increment rectangles above their
            // decrement partners in both repeated groups. In source pixels that is the Up
            // plate; the semantic action remains AppKit's, only the visual alphabet differs.
            drawBeOSPixels(
                increment ? Self.beOSVerticalUpButton : Self.beOSVerticalDownButton,
                in: rect
            )
            return
        } else if scrollerAppearance == .platinum,
           !isHorizontalScroller,
           rect.width == 14,
           rect.height == 15,
           hitPart != (increment ? .incrementLine : .decrementLine) {
            drawPlatinumPixels(
                increment
                    ? Self.platinumVerticalIncrementButton
                    : Self.platinumVerticalDecrementButton,
                in: rect
            )
            return
        } else if scrollerAppearance == .windows98,
           !isHorizontalScroller,
           rect.width == 16,
           rect.height == 16,
           hitPart != (increment ? .incrementLine : .decrementLine) {
            drawWindows98Pixels(
                increment
                    ? Self.windows98VerticalDecrementButton
                    : Self.windows98VerticalIncrementButton,
                in: rect
            )
            return
        } else if scrollerAppearance == .windows98,
                  isHorizontalScroller,
                  rect.width == 16,
                  rect.height == 16,
                  hitPart != (increment ? .incrementLine : .decrementLine) {
            drawWindows98Pixels(
                increment
                    ? Self.windows98HorizontalIncrementButton
                    : Self.windows98HorizontalDecrementButton,
                in: rect
            )
            return
        } else if scrollerAppearance == .aqua, isHorizontalScroller {
            drawCheetahHorizontalArrowButton(
                in: rect,
                increment: increment,
                pressed: hitPart == (increment ? .incrementLine : .decrementLine)
            )
            return
        } else if scrollerAppearance == .aquaTiger, !isHorizontalScroller {
            drawTigerVerticalArrowButton(
                in: rect,
                increment: increment,
                pressed: hitPart == (increment ? .incrementLine : .decrementLine)
            )
            return
        } else if scrollerAppearance == .aqua || scrollerAppearance == .aquaTiger {
            // Both preserved Cheetah and Tiger controls use neutral silver line buttons. The
            // blue gel belongs to the proportional thumb; painting the arrows blue made the
            // whole family read like an approximation of Aqua rather than either real release.
            drawTigerArrowButton(
                in: rect,
                pressed: hitPart == (increment ? .incrementLine : .decrementLine)
            )
        } else {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.controlResting,
                radius: 0,
                bevel: hitPart == (increment ? .incrementLine : .decrementLine)
                    ? .sunken
                    : .automatic
            )
        }
        drawArrowGlyph(in: rect, increment: increment)
    }

    /// USER32's 1x vertical plates are fifteen pixels of button artwork plus the right frame
    /// rail. Reusing the generic sixteen-pixel bevel shifted both the rail and the Marlett
    /// triangle, then rounded the inner #DF highlight to #E0. These symbolic samples retain
    /// the exact native geometry while still resolving their five tones from theme roles.
    private func drawWindows98Pixels(_ rowsTopToBottom: [String], in rect: NSRect) {
        guard let columnCount = rowsTopToBottom.first?.count,
              columnCount > 0,
              !rowsTopToBottom.isEmpty else { return }
        let rowCount = rowsTopToBottom.count
        let pixelWidth = rect.width / CGFloat(columnCount)
        let pixelHeight = rect.height / CGFloat(rowCount)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let highlight = Design.Surface.bevelHighlight
        let face = Design.Surface.controlResting
        let shadow = Design.Surface.bevelShadow
        let ink = Design.Text.label
        let innerHighlight = windows98InnerHighlightColor

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rowsTopToBottom.enumerated() {
            let y = isFlipped
                ? rect.minY + CGFloat(rowIndex) * pixelHeight
                : rect.maxY - CGFloat(rowIndex + 1) * pixelHeight
            for (column, sample) in row.enumerated() {
                let color: NSColor = switch sample {
                case "W": highlight
                case "H": innerHighlight
                case "C": face
                case "S": shadow
                default: ink
                }
                color.setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    /// Platinum's native scroller is a strict indexed-palette bitmap. The seven neutral
    /// steps and four lavender steps are not derivable from a generic two-ring bevel without
    /// losing the period's hard seams, so the measured 1x samples are retained symbolically.
    private func drawPlatinumPixels(_ rowsTopToBottom: [String], in rect: NSRect) {
        guard let columnCount = rowsTopToBottom.first?.count,
              columnCount > 0,
              !rowsTopToBottom.isEmpty else { return }
        let pixelWidth = rect.width / CGFloat(columnCount)
        let pixelHeight = rect.height / CGFloat(rowsTopToBottom.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let palette: [Character: NSColor] = [
            "A": NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 170 / 255, alpha: 1),
            "B": NSColor(srgbRed: 153 / 255, green: 153 / 255, blue: 1, alpha: 1),
            "C": NSColor(srgbRed: 221 / 255, green: 221 / 255, blue: 221 / 255, alpha: 1),
            "D": NSColor(srgbRed: 187 / 255, green: 187 / 255, blue: 187 / 255, alpha: 1),
            "E": NSColor(srgbRed: 204 / 255, green: 204 / 255, blue: 204 / 255, alpha: 1),
            "F": NSColor(srgbRed: 119 / 255, green: 119 / 255, blue: 119 / 255, alpha: 1),
            "G": NSColor(srgbRed: 136 / 255, green: 136 / 255, blue: 136 / 255, alpha: 1),
            "H": .black,
            "I": .white,
            "J": NSColor(srgbRed: 204 / 255, green: 204 / 255, blue: 1, alpha: 1),
            "K": NSColor(srgbRed: 102 / 255, green: 102 / 255, blue: 204 / 255, alpha: 1),
            "L": NSColor(srgbRed: 51 / 255, green: 51 / 255, blue: 153 / 255, alpha: 1),
            "M": NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1)
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rowsTopToBottom.enumerated() {
            let y = isFlipped
                ? rect.minY + CGFloat(rowIndex) * pixelHeight
                : rect.maxY - CGFloat(rowIndex + 1) * pixelHeight
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    private func drawPlatinumVerticalTrack(in rect: NSRect) {
        let hiddenByLeadingThumb = Array(repeating: "AAAAAAAAAAAAAA", count: 37)
        let page = [
            "FFFFFFFFFFFFFE",
            "FGGGGGGGGGGGDE"
        ] + Array(repeating: "FGAAAAAAAAAADE", count: 114) + [
            "HHHHHHHHHHHHHH"
        ]
        drawPlatinumPixels(hiddenByLeadingThumb + page, in: rect)
    }

    /// R5 uses six neutral indexed steps and no black outline. The leading white rail runs
    /// uninterrupted through the page region; its last row is a #989898 divider before the
    /// trailing Up/Down pair. The first fifteen rows sit beneath the value-zero thumb.
    private func drawBeOSVerticalTrack(in rect: NSRect) {
        drawBeOSPixels(
            Array(repeating: "WFFFFFFFFFFF", count: 139) + ["KKKKKKKKKKKK"],
            in: rect
        )
    }

    private func drawBeOSPixels(_ rowsTopToBottom: [String], in rect: NSRect) {
        guard let columnCount = rowsTopToBottom.first?.count,
              columnCount > 0,
              !rowsTopToBottom.isEmpty else { return }
        let pixelWidth = rect.width / CGFloat(columnCount)
        let pixelHeight = rect.height / CGFloat(rowsTopToBottom.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let palette: [Character: NSColor] = [
            "W": .white,
            "F": NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1),
            "S": NSColor(srgbRed: 200 / 255, green: 200 / 255, blue: 200 / 255, alpha: 1),
            "D": NSColor(srgbRed: 168 / 255, green: 168 / 255, blue: 168 / 255, alpha: 1),
            "K": NSColor(srgbRed: 152 / 255, green: 152 / 255, blue: 152 / 255, alpha: 1),
            "M": NSColor(srgbRed: 184 / 255, green: 184 / 255, blue: 184 / 255, alpha: 1)
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rowsTopToBottom.enumerated() {
            let y = isFlipped
                ? rect.minY + CGFloat(rowIndex) * pixelHeight
                : rect.maxY - CGFloat(rowIndex + 1) * pixelHeight
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    private static let beOSVerticalUpButton = [
        "WWWWWWWWWWWW",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFSWFFFF",
        "WFFFFFSWFFFF",
        "WFFFFSFSFFFF",
        "WFFFFSFSFFFF",
        "WFFFSFFFSFFF",
        "WFFFSFFFSFFF",
        "WFFSFFFFFSFF",
        "WFFSSSSSSSFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "DKKKKKKKKKKK"
    ]

    private static let beOSVerticalDownButton = [
        "WWWWWWWWWWWW",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFSSSSSSSFF",
        "WFFSFFFFFSFF",
        "WFFFSFFFSFFF",
        "WFFFSFFFSFFF",
        "WFFFFSFSFFFF",
        "WFFFFSFSFFFF",
        "WFFFFFSFFFFF",
        "WFFFFFSFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "KKKKKKKKKKKK"
    ]

    private static let beOSVerticalThumb = [
        "WWWWWWWWWWWF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFWWWWSFFF",
        "WFFFWFFFSFFF",
        "WFFFWFFFSFFF",
        "WFFFWFFFSFFF",
        "WFFFSSSSSFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "WFFFFFFFFFFF",
        "FFFFFFFFFFFF",
        "MMMMMMMMMMMM"
    ]

    private static let platinumVerticalThumb = [
        "HHHHHHHHHHHHHH",
        "MJJJJJJJJJJJJB"
    ] + Array(repeating: "JBBBBBBBBBBBBK", count: 12) + [
        "JBBMJJJJJJBBBK",
        "JBBBLLLLLLLBBK",
        "JBBMJJJJJJBBBK",
        "JBBBLLLLLLLBBK",
        "JBBMJJJJJJBBBK",
        "JBBBLLLLLLLBBK",
        "JBBMJJJJJJBBBK",
        "JBBBLLLLLLLBBK"
    ] + Array(repeating: "JBBBBBBBBBBBBK", count: 13) + [
        "BKKKKKKKKKKKKK",
        "HHHHHHHHHHHHHH"
    ]

    private static let platinumVerticalDecrementButton = [
        "IIIIIIIIIIIIIC"
    ] + Array(repeating: "ICCCCCCCCCCCCD", count: 4) + [
        "ICCCCCHHCCCCCD",
        "ICCCCHHHHCCCCD",
        "ICCCHHHHHHCCCD",
        "ICCHHHHHHHHCCD"
    ] + Array(repeating: "ICCCCCCCCCCCCD", count: 4) + [
        "CDDDDDDDDDDDDD",
        "HHHHHHHHHHHHHH"
    ]

    private static let platinumVerticalIncrementButton = [
        "IIIIIIIIIIIIIC"
    ] + Array(repeating: "ICCCCCCCCCCCCD", count: 4) + [
        "ICCHHHHHHHHCCD",
        "ICCCHHHHHHCCCD",
        "ICCCCHHHHCCCCD",
        "ICCCCCHHCCCCCD"
    ] + Array(repeating: "ICCCCCCCCCCCCD", count: 4) + [
        "CDDDDDDDDDDDDD",
        "HHHHHHHHHHHHHH"
    ]

    private var windows98InnerHighlightColor: NSColor {
        let highlight = Design.Surface.bevelHighlight.usingColorSpace(.sRGB)
            ?? Design.Surface.bevelHighlight
        let face = Design.Surface.controlResting.usingColorSpace(.sRGB)
            ?? Design.Surface.controlResting
        let midpoint: (CGFloat, CGFloat) -> CGFloat = { lhs, rhs in
            floor(((lhs + rhs) / 2) * 255) / 255
        }
        return NSColor(
            srgbRed: midpoint(highlight.redComponent, face.redComponent),
            green: midpoint(highlight.greenComponent, face.greenComponent),
            blue: midpoint(highlight.blueComponent, face.blueComponent),
            alpha: midpoint(highlight.alphaComponent, face.alphaComponent)
        )
    }

    private func drawWindows98HorizontalThumb(in rect: NSRect) {
        let width = Int(rect.width.rounded())
        guard width >= 5 else {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.controlResting,
                radius: 0,
                bevel: .automatic
            )
            return
        }
        let top = String(repeating: "H", count: width - 1) + "K"
        let upper = "H" + String(repeating: "W", count: width - 3) + "SK"
        let middle = "HW" + String(repeating: "C", count: width - 4) + "SK"
        let lower = "H" + String(repeating: "S", count: width - 2) + "K"
        let bottom = String(repeating: "K", count: width)
        drawWindows98Pixels(
            [top, upper] + Array(repeating: middle, count: 12) + [lower, bottom],
            in: rect
        )
    }

    private static let windows98VerticalDecrementButton = [
        "HHHHHHHHHHHHHHKH",
        "WWWWWWWWWWWWWSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCKCCCCCCSKH",
        "WCCCCKKKCCCCCSKH",
        "WCCCKKKKKCCCCSKH",
        "WCCKKKKKKKCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "SSSSSSSSSSSSSSKH",
        "KKKKKKKKKKKKKKKH"
    ]

    private static let windows98VerticalThumb = [
        "HHHHHHHHHHHHHHKH",
        "WWWWWWWWWWWWWSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "SSSSSSSSSSSSSSKH",
        "KKKKKKKKKKKKKKKH"
    ]

    private static let windows98VerticalIncrementButton = [
        "HHHHHHHHHHHHHHKH",
        "WWWWWWWWWWWWWSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCKKKKKKKCCCSKH",
        "WCCCKKKKKCCCCSKH",
        "WCCCCKKKCCCCCSKH",
        "WCCCCCKCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "WCCCCCCCCCCCCSKH",
        "SSSSSSSSSSSSSSKH",
        "KKKKKKKKKKKKKKKH"
    ]

    private static let windows98HorizontalDecrementButton = [
        "HHHHHHHHHHHHHHHK",
        "HWWWWWWWWWWWWWSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCKCCCCCSK",
        "HWCCCCCKKCCCCCSK",
        "HWCCCCKKKCCCCCSK",
        "HWCCCKKKKCCCCCSK",
        "HWCCCCKKKCCCCCSK",
        "HWCCCCCKKCCCCCSK",
        "HWCCCCCCKCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HSSSSSSSSSSSSSSK",
        "KKKKKKKKKKKKKKKK"
    ]

    private static let windows98HorizontalIncrementButton = [
        "HHHHHHHHHHHHHHHK",
        "HWWWWWWWWWWWWWSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCKCCCCCCCSK",
        "HWCCCCKKCCCCCCSK",
        "HWCCCCKKKCCCCCSK",
        "HWCCCCKKKKCCCCSK",
        "HWCCCCKKKCCCCCSK",
        "HWCCCCKKCCCCCCSK",
        "HWCCCCKCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HWCCCCCCCCCCCCSK",
        "HSSSSSSSSSSSSSSK",
        "KKKKKKKKKKKKKKKK"
    ]

    private func drawArrowGlyph(in rect: NSRect, increment: Bool) {
        if scrollerAppearance != .aqua && scrollerAppearance != .aquaTiger {
            drawPixelArrowGlyph(in: rect, increment: increment)
            return
        }

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let size = scrollerAppearance == .aqua
            ? 3
            : max(3, floor(min(rect.width, rect.height) * 0.28))
        let path = NSBezierPath()
        if isHorizontalScroller {
            let direction: CGFloat = increment ? 1 : -1
            path.move(to: NSPoint(x: center.x + direction * size, y: center.y))
            path.line(to: NSPoint(x: center.x - direction * size, y: center.y + size))
            path.line(to: NSPoint(x: center.x - direction * size, y: center.y - size))
        } else {
            let direction: CGFloat = increment ? -1 : 1
            path.move(to: NSPoint(x: center.x, y: center.y + direction * size))
            path.line(to: NSPoint(x: center.x - size, y: center.y - direction * size))
            path.line(to: NSPoint(x: center.x + size, y: center.y - direction * size))
        }
        path.close()
        (scrollerAppearance == .aqua || scrollerAppearance == .aquaTiger
            ? NSColor(calibratedWhite: 0.08, alpha: 0.78)
            : Design.Text.label).setFill()
        path.fill()
    }

    /// The bitmap-era arrows were one-bit stair steps, not antialiased vector triangles.
    /// A disabled graphics-context antialias flag is not sufficient here: a path whose points
    /// fall between device pixels still produces gray coverage pixels. Building the figure out
    /// of whole-pixel rows keeps its silhouette stable at the native 1× sizes in the evidence
    /// archive and on Retina screens alike.
    private func drawPixelArrowGlyph(in rect: NSRect, increment: Bool) {
        let halfSpan: Int = scrollerAppearance == .beOS ? 2 : 3
        let centerX = floor(rect.midX)
        let centerY = floor(rect.midY)
        let ink: NSColor = switch scrollerAppearance {
        case .beOS, .irix: Design.Text.secondary
        default: Design.Text.label
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect.integral).addClip()
        ink.setFill()

        for step in 0...halfSpan {
            let spread = CGFloat(step)
            let advance = CGFloat(halfSpan - step)
            if isHorizontalScroller {
                let x = centerX + (increment ? advance : -advance)
                NSRect(
                    x: x,
                    y: centerY - spread,
                    width: 1,
                    height: 2 * spread + 1
                ).fill()
            } else {
                let y = centerY + (increment ? advance : -advance)
                NSRect(
                    x: centerX - spread,
                    y: y,
                    width: 2 * spread + 1,
                    height: 1
                ).fill()
            }
        }
    }

    /// Tiger kept the saturated Aqua thumb but quieted the line buttons back to silver.
    /// Both buttons live at the trailing end, and each is a small square glass plate with a
    /// single dark figure — visibly different from Cheetah's all-blue candy controls.
    private func drawTigerArrowButton(in rect: NSRect, pressed: Bool) {
        let body = rect.insetBy(dx: 0.5, dy: 0.5)
        let top = NSColor(calibratedWhite: pressed ? 0.72 : 0.98, alpha: 1)
        let bottom = NSColor(calibratedWhite: pressed ? 0.91 : 0.78, alpha: 1)
        NSGradient(colors: [top, bottom])?.draw(
            in: body,
            angle: isHorizontalScroller ? 90 : -90
        )
        NSColor(calibratedWhite: 0.48, alpha: 0.82).setStroke()
        let edge = NSBezierPath(rect: body)
        edge.lineWidth = 1
        edge.stroke()
        NSColor.white.withAlphaComponent(0.76).setFill()
        if isHorizontalScroller {
            NSRect(x: body.minX + 1, y: body.maxY - 2, width: max(0, body.width - 2), height: 1).fill()
        } else {
            NSRect(x: body.minX + 1, y: body.maxY - 2, width: max(0, body.width - 2), height: 1).fill()
        }
    }

    /// TextEdit's horizontal Cheetah scroller used two distinct 17×16 silver bookends. They
    /// are not mirrored generic bevels: each edge, highlight, seam, and antialiased arrow was
    /// authored as part of the control. Preserve those measured native scanlines here instead
    /// of stretching a modern square button over the trough. Other axes and interaction states
    /// keep the scalable vector fallback until the archive contains evidence for them.
    private func drawCheetahHorizontalArrowButton(
        in rect: NSRect,
        increment: Bool,
        pressed: Bool
    ) {
        let samples = increment
            ? Self.cheetahIncrementArrowSamples
            : Self.cheetahDecrementArrowSamples
        let columns = 17
        let rows = 16
        let pixelWidth = rect.width / CGFloat(columns)
        let pixelHeight = rect.height / CGFloat(rows)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()

        for row in 0..<rows {
            let y = isFlipped
                ? rect.minY + CGFloat(row) * pixelHeight
                : rect.maxY - CGFloat(row + 1) * pixelHeight
            for column in 0..<columns {
                let measured = CGFloat(samples[row * columns + column])
                let value = max(0, measured - (pressed ? 24 : 0)) / 255
                NSColor(srgbRed: value, green: value, blue: value, alpha: 1).setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    private static let cheetahDecrementArrowSamples: [UInt8] = [
        194, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        185, 207, 218, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221,
        170, 206, 208, 208, 209, 209, 209, 208, 210, 209, 210, 210, 212, 211, 210, 209, 211,
        188, 239, 241, 241, 242, 242, 242, 242, 242, 242, 242, 243, 243, 242, 242, 242, 238,
        179, 241, 247, 247, 248, 247, 248, 248, 248, 248, 248, 248, 248, 248, 247, 242, 210,
        174, 235, 248, 249, 249, 249, 249, 249, 249, 239, 160, 249, 249, 249, 246, 222, 169,
        175, 223, 247, 250, 250, 250, 250, 250, 183, 94, 75, 250, 250, 248, 234, 211, 155,
        183, 213, 232, 245, 250, 251, 213, 113, 75, 74, 74, 246, 244, 235, 220, 217, 146,
        189, 215, 220, 221, 223, 172, 67, 67, 67, 67, 67, 225, 225, 225, 225, 225, 137,
        194, 221, 226, 228, 230, 231, 193, 101, 69, 69, 69, 232, 231, 232, 232, 231, 147,
        200, 228, 230, 234, 235, 237, 236, 233, 171, 83, 71, 237, 237, 239, 238, 237, 165,
        206, 234, 238, 241, 242, 244, 246, 245, 244, 232, 145, 244, 245, 246, 245, 245, 196,
        211, 240, 244, 248, 249, 250, 251, 251, 251, 252, 251, 252, 251, 251, 251, 251, 243,
        214, 243, 247, 250, 252, 253, 254, 253, 254, 254, 254, 254, 254, 253, 254, 254, 254,
        211, 240, 244, 246, 248, 249, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 250,
        202, 229, 232, 235, 237, 239, 239, 239, 239, 239, 239, 239, 239, 239, 239, 239, 239
    ]

    private static let cheetahIncrementArrowSamples: [UInt8] = [
        255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 212,
        221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221, 221,
        209, 210, 211, 212, 210, 210, 209, 210, 208, 209, 209, 209, 208, 208, 206, 172, 205,
        242, 242, 242, 243, 243, 242, 242, 242, 242, 242, 242, 242, 241, 241, 239, 188, 220,
        240, 247, 248, 248, 248, 248, 248, 248, 248, 248, 247, 248, 247, 247, 241, 179, 225,
        217, 246, 249, 249, 249, 160, 239, 249, 249, 249, 249, 249, 249, 248, 235, 174, 225,
        204, 233, 248, 250, 250, 75, 94, 183, 250, 250, 250, 250, 250, 247, 223, 175, 225,
        205, 219, 235, 244, 246, 74, 74, 75, 113, 213, 251, 250, 245, 232, 213, 183, 225,
        212, 223, 225, 225, 225, 67, 67, 67, 67, 67, 172, 223, 221, 220, 215, 189, 225,
        218, 230, 232, 231, 232, 69, 69, 69, 101, 193, 231, 230, 228, 226, 221, 194, 225,
        224, 237, 239, 237, 237, 71, 83, 171, 233, 236, 237, 235, 234, 230, 228, 200, 225,
        237, 244, 246, 245, 244, 145, 232, 244, 245, 246, 244, 242, 241, 238, 234, 206, 225,
        246, 251, 251, 251, 252, 251, 252, 251, 251, 251, 250, 249, 248, 244, 240, 211, 225,
        252, 254, 253, 254, 254, 254, 254, 254, 253, 254, 253, 252, 250, 247, 243, 214, 225,
        250, 250, 250, 250, 250, 250, 250, 250, 250, 250, 249, 248, 246, 244, 240, 211, 225,
        239, 239, 239, 239, 239, 239, 239, 239, 239, 239, 239, 237, 235, 232, 229, 202, 220
    ]

    /// Tiger's paired trailing arrows share the trough's asymmetric cross-axis lighting but
    /// do not share a vertically mirrored button plate: the lower button carries the frame's
    /// closing shadow. Preserve both native 15×15 states independently instead of rotating a
    /// generic square button and losing those boundary pixels.
    private func drawTigerVerticalArrowButton(
        in rect: NSRect,
        increment: Bool,
        pressed: Bool
    ) {
        let samples = increment
            ? Self.tigerIncrementArrowSamples
            : Self.tigerDecrementArrowSamples
        let columns = 15
        let rows = 15
        let pixelWidth = rect.width / CGFloat(columns)
        let pixelHeight = rect.height / CGFloat(rows)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()

        for row in 0..<rows {
            let y = isFlipped
                ? rect.minY + CGFloat(row) * pixelHeight
                : rect.maxY - CGFloat(row + 1) * pixelHeight
            for column in 0..<columns {
                let measured = CGFloat(samples[row * columns + column])
                let value = max(0, measured - (pressed ? 24 : 0)) / 255
                NSColor(srgbRed: value, green: value, blue: value, alpha: 1).setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    private static let tigerDecrementArrowSamples: [UInt8] = [
        255, 255, 187, 211, 242, 248, 249, 248, 235, 225, 232, 239, 246, 251, 253,
        255, 255, 187, 212, 243, 248, 249, 250, 244, 225, 231, 237, 245, 251, 254,
        255, 255, 186, 209, 242, 247, 249, 250, 251, 172, 231, 237, 244, 250, 253,
        255, 255, 186, 209, 242, 248, 249, 250, 213, 67, 193, 236, 246, 251, 254,
        255, 255, 186, 208, 242, 248, 249, 250, 113, 67, 101, 233, 245, 251, 253,
        255, 255, 188, 210, 242, 248, 249, 183, 75, 67, 69, 171, 244, 251, 254,
        255, 255, 187, 209, 242, 248, 239, 94, 74, 67, 69, 83, 232, 252, 254,
        255, 255, 187, 210, 242, 248, 160, 75, 74, 67, 69, 71, 145, 251, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 165, 176, 191, 183, 178, 175, 173, 158, 164, 170, 181, 196, 207,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254
    ]

    private static let tigerIncrementArrowSamples: [UInt8] = [
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 243, 248, 249, 250, 246, 225, 232, 237, 244, 252, 254,
        255, 255, 187, 210, 242, 248, 160, 75, 74, 67, 69, 71, 145, 251, 254,
        255, 255, 187, 209, 242, 248, 239, 94, 74, 67, 69, 83, 232, 252, 254,
        255, 255, 188, 210, 242, 248, 249, 183, 75, 67, 69, 171, 244, 251, 254,
        255, 255, 186, 208, 242, 248, 249, 250, 113, 67, 101, 233, 245, 251, 253,
        255, 255, 186, 209, 242, 248, 249, 250, 213, 67, 193, 236, 246, 251, 254,
        255, 255, 186, 209, 242, 247, 249, 250, 251, 172, 231, 237, 244, 250, 253,
        255, 255, 186, 209, 242, 248, 249, 250, 250, 223, 230, 235, 242, 249, 252,
        255, 255, 183, 208, 241, 247, 249, 250, 245, 221, 228, 234, 241, 248, 250,
        255, 255, 182, 208, 241, 247, 248, 247, 232, 220, 226, 230, 238, 244, 247,
        255, 255, 179, 206, 239, 241, 235, 223, 213, 215, 221, 228, 234, 240, 243,
        255, 255, 175, 170, 188, 179, 174, 175, 183, 189, 194, 200, 206, 211, 214
    ]

    private func drawGrip(in rect: NSRect, ink: NSColor) {
        let length = min(8, (isHorizontalScroller ? rect.height : rect.width) - 6)
        guard length >= 2 else { return }
        ink.setFill()
        for offset in [-2, 0, 2] as [CGFloat] {
            if isHorizontalScroller {
                NSRect(x: rect.midX + offset, y: rect.midY - length / 2,
                       width: 1, height: length).fill()
            } else {
                NSRect(x: rect.midX - length / 2, y: rect.midY + offset,
                       width: length, height: 1).fill()
            }
        }
    }

    /// The Workbench proportional gadget shares the active title strip's authored blue. Keep
    /// this derived from the chrome data instead of hard-coding a second palette literal, so a
    /// contributed theme that selects the Amiga anatomy still gets its own stated title colour.
    private var amigaScrollerFill: NSColor {
        guard let chrome = AppThemePalette.current.windowChrome(for: effectiveAppearance),
              let stop = chrome.titleBar.activeGradient.stops.min(by: {
                  $0.position < $1.position
              }) else {
            return Design.Surface.accent
        }
        return stop.color
    }

    /// BeOS's proportional gadget is a compact raised block with a small recessed square.
    /// Three generic grip bars made it indistinguishable from the IRIX and Amiga gadgets,
    /// while the preserved Browser scroller uses this quiet square even at its 12px width.
    private func drawBeOSThumb(in rect: NSRect) {
        ThemedSurface.draw(
            rect,
            fill: Design.Surface.controlResting,
            radius: 0,
            bevel: .automatic
        )
        let size: CGFloat = min(4, max(2, floor(min(rect.width, rect.height) - 6)))
        let mark = NSRect(
            x: floor(rect.midX - size / 2),
            y: floor(rect.midY - size / 2),
            width: size,
            height: size
        )
        Design.Surface.bevelShadow.withAlphaComponent(0.46).setFill()
        mark.fill()
        Design.Surface.bevelHighlight.withAlphaComponent(0.82).setFill()
        mark.insetBy(dx: 1, dy: 1).fill()
    }

    /// OPENSTEP's large proportional gadget carries the small black/white scroll dimple from
    /// AppKit's ancestor, not a modern three-line grip. The evidence resolves it as six hard
    /// pixels across; keeping it as one-bit artwork preserves the asymmetric highlight.
    private func drawOpenStepThumb(in rect: NSRect) {
        ThemedSurface.draw(
            rect,
            fill: Design.Surface.controlResting,
            radius: 0,
            bevel: .automatic
        )
        let rows = [
            "..###.",
            ".####.",
            "###oo.",
            "##ooo.",
            ".#ooo."
        ]
        let originX = floor(rect.midX - 3)
        let originY = floor(rect.midY - 2)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        for (rowIndex, row) in rows.reversed().enumerated() {
            for (column, pixel) in row.enumerated() {
                let color: NSColor?
                switch pixel {
                case "#": color = Design.Text.label
                case "o": color = Design.Surface.bevelHighlight
                default: color = nil
                }
                color?.setFill()
                if color != nil {
                    NSRect(
                        x: originX + CGFloat(column),
                        y: originY + CGFloat(rowIndex),
                        width: 1,
                        height: 1
                    ).fill()
                }
            }
        }
    }

    /// The tight Workspace Manager extraction is a complete 18×244 control: a 163px leading
    /// thumb, 47px stippled page region, and two 17px trailing arrow cells. Only that exact
    /// geometry and state use the native indexed reconstruction; arbitrary sizes and scroll
    /// positions continue through the scalable OPENSTEP recipe above.
    private var rendersOpenStepReferenceState: Bool {
        scrollerAppearance == .openStep
            && !isHorizontalScroller
            && bounds.width == 18
            && bounds.height == 244
            && abs(doubleValue) < 0.000_001
            && abs(knobProportion - (163.0 / 210.0)) < 0.000_001
    }

    private func drawOpenStepReferenceScroller(in rect: NSRect) {
        let thumb = [
            "KKKKKKKKKKKKKKKKKK",
            "KGGGGGGGGGGGGGGGGG",
            "KGWWWWWWWWWWWWWWWK"
        ] + Array(repeating: "KGWGGGGGGGGGGGGGDK", count: 75) + [
            "KGWGGGGDKKKGGGGGDK",
            "KGWGGGDKDDDDGGGGDK",
            "KGWGGGKDDGGGGGGGDK",
            "KGWGGGKDGGWWGGGGDK",
            "KGWGGGKDGWWWGGGGDK",
            "KGWGGGGDGWWGGGGGDK"
        ] + Array(repeating: "KGWGGGGGGGGGGGGGDK", count: 77) + [
            "KGWDDDDDDDDDDDDDDK",
            "KGKKKKKKKKKKKKKKKK"
        ]
        let page = (0..<47).map { row in
            row.isMultiple(of: 2)
                ? "KGGDGDGDGDGDGDGDGD"
                : "KGDGDGDGDGDGDGDGDG"
        }
        let up = [
            "KGGGGGGGGGGGGGGGGG",
            "KGWWWWWWWWWWWWWWWK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGGGGGDGGGGGGDK",
            "KGWGGGGGGKGGGGGGDK",
            "KGWGGGGGDKDGGGGGDK",
            "KGWGGGGGKKKGGGGGDK",
            "KGWGGGGDKKKDGGGGDK",
            "KGWGGGGKKKKKGGGGDK",
            "KGWGGGDKKKKKDGGGDK",
            "KGWGGGKKKKKKKGGGDK",
            "KGWGGDKKKKKKKDGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWDDDDDDDDDDDDDDK",
            "KGKKKKKKKKKKKKKKKK"
        ]
        let down = [
            "KGGGGGGGGGGGGGGGGG",
            "KGWWWWWWWWWWWWWWWK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGDKKKKKKKDGGDK",
            "KGWGGGKKKKKKKGGGDK",
            "KGWGGGDKKKKKDGGGDK",
            "KGWGGGGKKKKKGGGGDK",
            "KGWGGGGDKKKDGGGGDK",
            "KGWGGGGGKKKGGGGGDK",
            "KGWGGGGGDKDGGGGGDK",
            "KGWGGGGGGKGGGGGGDK",
            "KGWGGGGGGDGGGGGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWGGGGGGGGGGGGGDK",
            "KGWDDDDDDDDDDDDDDK",
            "KGKKKKKKKKKKKKKKKK"
        ]
        drawOpenStepPixels(thumb + page + up + down, in: rect)
    }

    private func drawOpenStepPixels(_ rowsTopToBottom: [String], in rect: NSRect) {
        guard let columnCount = rowsTopToBottom.first?.count,
              columnCount > 0,
              !rowsTopToBottom.isEmpty else { return }
        let pixelWidth = rect.width / CGFloat(columnCount)
        let pixelHeight = rect.height / CGFloat(rowsTopToBottom.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let palette: [Character: NSColor] = [
            "K": .black,
            "D": NSColor(srgbRed: 85 / 255, green: 85 / 255, blue: 85 / 255, alpha: 1),
            "G": NSColor(srgbRed: 170 / 255, green: 170 / 255, blue: 170 / 255, alpha: 1),
            "W": .white
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rowsTopToBottom.enumerated() {
            let y = isFlipped
                ? rect.minY + CGFloat(rowIndex) * pixelHeight
                : rect.maxY - CGFloat(rowIndex + 1) * pixelHeight
            for (column, sample) in row.enumerated() {
                (palette[sample] ?? .black).setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    /// Background Setting preserves one complete 16×172 4Dwm scroller at native scale. Its
    /// arrows are 20/18px asymmetric cells around a 90px page region and a 44px thumb; the
    /// generic legacy NSScroller part rectangles cannot express those joins, so this exact
    /// source state receives the indexed construction while arbitrary states remain scalable.
    private var rendersIRIXReferenceState: Bool {
        scrollerAppearance == .irix
            && !isHorizontalScroller
            && bounds.width == 16
            && bounds.height == 172
            && abs(doubleValue - 0.95) < 0.000_001
            && abs(knobProportion - 0.31) < 0.000_001
    }

    private func drawIRIXReferenceScroller(in rect: NSRect) {
        let top = [
            "KKKKKKKKKKKKKKKK",
            "LLLLLLLLLLLLLLLL",
            "LCCCCCCCCCCCCCCC",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGDGGGGGGG",
            "LCGGGGGGDDGGGGGG",
            "LCGGGGGGDDGGGGGG",
            "LCGGGGGDDDDGGGGG",
            "LCGGGGGDDDDGGGGG",
            "LCGGGGDDDDDDGGGG",
            "LCGGGGDDDDDDGGGG",
            "LCGGGDDDDDDDDGGG",
            "LCGGGDDDDDDDDGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCSSSSSSSSSSSSSS",
            "LDDDDDDDDDDDDDDD",
            "DDDDDDDDDDDDDDDD"
        ]
        let page = ["CCCCCCCCCCCCCCCC"]
            + Array(repeating: "CGGGGGGGGGGGGGGG", count: 89)
        let thumb = [
            "BBBBBBBBBBBBBBBB",
            "LLLLLLLLLLLLLLLL",
            "LCCCCCCCCCCCCCCC"
        ] + Array(repeating: "LCGGGGGGGGGGGGGG", count: 13) + [
            "LLLLLLLLLLLLLLLL",
            "LBBBBBBBBBBBBBBB",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LLLLLLLLLLLLLLLL",
            "LBBBBBBBBBBBBBBB",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LLLLLLLLLLLLLLLL",
            "LBBBBBBBBBBBBBBB"
        ] + Array(repeating: "LCGGGGGGGGGGGGGG", count: 14) + [
            "LCSSSSSSSSSSSSSS",
            "LSSSSSSSSSSSSSSS",
            "BBBBBBBBBBBBBBBB",
            "DDDDDDDDDDDDDDDD"
        ]
        let bottom = [
            "LLLLLLLLLLLLLLLL",
            "LCCCCCCCCCCCCCCC",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGDDDDDDDDDGGG",
            "LCGGGDDDDDDDDGGG",
            "LCGGGDDDDDDDDGGG",
            "LCGGGGDDDDDDGGGG",
            "LCGGGGDDDDDDGGGG",
            "LCGGGGGDDDDGGGGG",
            "LCGGGGGDDDDGGGGG",
            "LCGGGGGGDDGGGGGG",
            "LCGGGGGGDDGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCGGGGGGGGGGGGGG",
            "LCSSSSSSSSSSSSSS",
            "LDDDDDDDDDDDDDDD"
        ]
        drawIRIXPixels(top + page + thumb + bottom, in: rect)
    }

    private func drawIRIXPixels(_ rowsTopToBottom: [String], in rect: NSRect) {
        guard let columnCount = rowsTopToBottom.first?.count,
              columnCount > 0,
              !rowsTopToBottom.isEmpty else { return }
        let pixelWidth = rect.width / CGFloat(columnCount)
        let pixelHeight = rect.height / CGFloat(rowsTopToBottom.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let palette: [Character: NSColor] = [
            "B": .black,
            "K": NSColor(srgbRed: 47 / 255, green: 47 / 255, blue: 47 / 255, alpha: 1),
            "D": NSColor(srgbRed: 76 / 255, green: 76 / 255, blue: 76 / 255, alpha: 1),
            "S": NSColor(srgbRed: 115 / 255, green: 115 / 255, blue: 115 / 255, alpha: 1),
            "G": NSColor(srgbRed: 153 / 255, green: 153 / 255, blue: 153 / 255, alpha: 1),
            "C": NSColor(srgbRed: 204 / 255, green: 204 / 255, blue: 204 / 255, alpha: 1),
            "L": NSColor(srgbRed: 225 / 255, green: 225 / 255, blue: 225 / 255, alpha: 1)
        ]

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false
        NSBezierPath(rect: rect).addClip()
        for (rowIndex, row) in rowsTopToBottom.enumerated() {
            let y = isFlipped
                ? rect.minY + CGFloat(rowIndex) * pixelHeight
                : rect.maxY - CGFloat(rowIndex + 1) * pixelHeight
            for (column, sample) in row.enumerated() {
                guard let color = palette[sample] else { continue }
                color.setFill()
                NSRect(
                    x: rect.minX + CGFloat(column) * pixelWidth,
                    y: y,
                    width: pixelWidth,
                    height: pixelHeight
                ).fill()
            }
        }
    }

    /// Platinum's lavender proportional gadget is not the desktop selection blue. The source
    /// preserves a four-colour pixel construction: black outside rule, pale lilac light edge,
    /// #9999FF face, and #6666CC shade, plus four dark grip bars. Keeping those measured colours
    /// here avoids changing the theme's selection role merely to colour one piece of hardware.
    private func drawPlatinumThumb(in rect: NSRect) {
        let body = rect.integral
        guard body.width >= 4, body.height >= 4 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.shouldAntialias = false

        NSColor.black.setFill()
        body.fill()
        let edge = body.insetBy(dx: 1, dy: 1)
        let face = edge.insetBy(dx: 1, dy: 1)
        NSColor(
            calibratedRed: 204.0 / 255.0,
            green: 204.0 / 255.0,
            blue: 1,
            alpha: 1
        ).setFill()
        edge.fill()
        NSColor(
            calibratedRed: 153.0 / 255.0,
            green: 153.0 / 255.0,
            blue: 1,
            alpha: 1
        ).setFill()
        face.fill()

        let shade = NSColor(
            calibratedRed: 102.0 / 255.0,
            green: 102.0 / 255.0,
            blue: 204.0 / 255.0,
            alpha: 1
        )
        shade.setFill()
        NSRect(x: edge.maxX - 1, y: edge.minY, width: 1, height: edge.height).fill()
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        let visualBottom = isFlipped ? edge.maxY - 1 : edge.minY
        NSRect(x: edge.minX, y: visualBottom, width: edge.width, height: 1).fill()

        let grip = NSColor(
            calibratedRed: 51.0 / 255.0,
            green: 51.0 / 255.0,
            blue: 153.0 / 255.0,
            alpha: 1
        )
        grip.setFill()
        let length = min(8, (isHorizontalScroller ? body.height : body.width) - 6)
        guard length >= 2 else { return }
        for offset in [-3, -1, 1, 3] as [CGFloat] {
            if isHorizontalScroller {
                NSRect(
                    x: body.midX + offset, y: body.midY - length / 2,
                    width: 1, height: length
                ).fill()
            } else {
                NSRect(
                    x: body.midX - length / 2, y: body.midY + offset,
                    width: length, height: 1
                ).fill()
            }
        }
    }

    /// Aqua's blue gel: a dark leading rim opening into a pale glass face. Cheetah adds the
    /// fine transverse ribs visible in its first-release control; Tiger keeps the directional
    /// glass but drops that emphatic texture. It is intentionally geometry rather than a
    /// bitmap so a custom theme can recolour the family through its semantic accent.
    private func drawAquaGel(in rect: NSRect, pressed: Bool) {
        if scrollerAppearance == .aqua {
            drawCheetahGel(in: rect, pressed: pressed)
            return
        }
        if scrollerAppearance == .aquaTiger {
            drawTigerGel(in: rect, pressed: pressed)
            return
        }
        // Aqua's shaft is not a centred modern overlay pill. At native scale the horizontal
        // glass leaves a 2px rail on each side; the vertical glass is seated against the
        // trailing edge with a 3px white rail at leading. These asymmetric period pixels are
        // visible in both the Cheetah Open panel and Tiger System Profiler references.
        let body: NSRect = if isHorizontalScroller {
            NSRect(
                x: rect.minX,
                y: rect.minY + 2,
                width: rect.width,
                height: max(0, rect.height - 4)
            )
        } else {
            NSRect(
                x: rect.minX + 3,
                y: rect.minY,
                width: max(0, rect.width - 3),
                height: rect.height
            )
        }
        let radius = min(6, min(body.width, body.height) / 2)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()

        let accent = Design.Surface.accent
        let bright = accent.blended(withFraction: pressed ? 0.30 : 0.40, of: .white) ?? accent
        let glass = accent.blended(withFraction: pressed ? 0.18 : 0.28, of: .white) ?? accent
        let waist = accent.blended(withFraction: pressed ? 0.05 : 0.08, of: .white) ?? accent
        let deep = accent.blended(withFraction: pressed ? 0.48 : 0.34, of: .black) ?? accent
        // The dark rim occupies roughly one native pixel; the rest is pale gel. A regular
        // three-stop gradient spread the shadow over half the shaft and was dramatically
        // darker than both Apple references. Raw screenshot Y is the inverse of AppKit Y.
        let gradient: NSGradient? = if isHorizontalScroller {
            NSGradient(colorsAndLocations:
                (bright, 0.00),
                (glass, 0.42),
                (waist, 0.52),
                (glass, 0.64),
                (glass, 0.90),
                (deep, 1.00)
            )
        } else {
            NSGradient(colorsAndLocations:
                (deep, 0.00),
                (glass, 0.10),
                (glass, 0.36),
                (waist, 0.48),
                (glass, 0.58),
                (bright, 1.00)
            )
        }
        gradient?.draw(in: body, angle: isHorizontalScroller ? 90 : 0)

        NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.34).setFill()
        if isHorizontalScroller {
            NSRect(x: body.minX + 2, y: body.minY + 1,
                   width: max(0, body.width - 4), height: 1).fill()
        } else {
            NSRect(x: body.maxX - 2, y: body.minY + 2,
                   width: 1, height: max(0, body.height - 4)).fill()
        }

        deep.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Tiger removes Cheetah's longitudinal ribbing but keeps the same asymmetric Aqua gel:
    /// a one-pixel navy leading rim, pale glass shoulders, a blue waist, and a bright trailing
    /// bloom. These twelve samples are the flat centre of System Profiler's vertical thumb.
    /// The sample profile remains recolorable through the theme accent and the rounded path
    /// supplies the independently scalable end caps.
    private func drawTigerGel(in rect: NSRect, pressed: Bool) {
        let body: NSRect = if isHorizontalScroller {
            NSRect(
                x: rect.minX,
                y: rect.minY + 3,
                width: rect.width,
                height: max(0, rect.height - 3)
            )
        } else {
            NSRect(
                x: rect.minX + 3,
                y: rect.minY,
                width: max(0, rect.width - 3),
                height: rect.height
            )
        }
        guard body.width > 0, body.height > 0 else { return }
        let radius = min(6, min(body.width, body.height) / 2)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(pressed ? 0.24 : 0.16)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = isHorizontalScroller
            ? NSSize(width: 0, height: -1)
            : NSSize(width: -1, height: 0)
        shadow.set()
        NSColor(srgbRed: 171 / 255, green: 171 / 255, blue: 171 / 255, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()
        let crossStep = (isHorizontalScroller ? body.height : body.width)
            / CGFloat(Self.tigerGelSamples.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        for (index, sample) in Self.tigerGelSamples.enumerated() {
            tigerGelColor(sample, pressed: pressed).setFill()
            if isHorizontalScroller {
                let y = isFlipped
                    ? body.minY + CGFloat(index) * crossStep
                    : body.maxY - CGFloat(index + 1) * crossStep
                NSRect(x: body.minX, y: y, width: body.width, height: crossStep).fill()
            } else {
                NSRect(
                    x: body.minX + CGFloat(index) * crossStep,
                    y: body.minY,
                    width: crossStep,
                    height: body.height
                ).fill()
            }
        }

        if isHorizontalScroller {
            NSGraphicsContext.saveGraphicsState()
            let capClip = NSBezierPath()
            capClip.appendRect(NSRect(
                x: body.minX,
                y: body.minY,
                width: min(6, body.width / 2),
                height: body.height
            ))
            capClip.appendRect(NSRect(
                x: max(body.minX, body.maxX - 6),
                y: body.minY,
                width: min(6, body.width / 2),
                height: body.height
            ))
            capClip.addClip()
            tigerGelColor(Self.tigerGelSamples[0], pressed: pressed)
                .withAlphaComponent(pressed ? 0.96 : 0.88)
                .setStroke()
            path.lineWidth = 1.35
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let pixelRows = max(0, Int(body.height.rounded()))
            let capRows = min(
                Self.tigerTopCapScales.count,
                Self.tigerBottomCapScales.count,
                pixelRows / 2
            )
            func drawCrossSection(
                visualRow: Int,
                scale: TigerGelScale
            ) {
                let y = isFlipped
                    ? body.minY + CGFloat(visualRow)
                    : body.maxY - CGFloat(visualRow + 1)
                for (column, sample) in Self.tigerGelSamples.enumerated() {
                    tigerGelColor(sample, scale: scale, pressed: pressed).setFill()
                    NSRect(
                        x: body.minX + CGFloat(column) * crossStep,
                        y: y,
                        width: crossStep,
                        height: 1
                    ).fill()
                }
            }
            for index in 0..<capRows {
                drawCrossSection(
                    visualRow: index,
                    scale: Self.tigerTopCapScales[index]
                )
                drawCrossSection(
                    visualRow: pixelRows - capRows + index,
                    scale: Self.tigerBottomCapScales[index]
                )
            }
        }
    }

    private typealias TigerGelSample = (red: CGFloat, green: CGFloat, blue: CGFloat)
    private typealias TigerGelScale = (red: CGFloat, green: CGFloat, blue: CGFloat)

    private static let tigerGelSamples: [TigerGelSample] = [
        (0, 57, 179), (118, 158, 220), (144, 185, 230), (136, 180, 230),
        (128, 177, 230), (66, 138, 223), (85, 155, 235), (105, 173, 251),
        (122, 191, 255), (135, 204, 255), (147, 218, 255), (137, 205, 255)
    ]

    /// Longitudinal cap modulation measured at the centre column. Values are channel ratios
    /// against the flat `(128, 177, 230)` Tiger face, so a custom accent keeps the same glass
    /// depth instead of inheriting Apple's literal blue.
    private static let tigerTopCapScales: [TigerGelScale] = [
        (27 / 128, 73 / 177, 159 / 230),
        (2 / 128, 79 / 177, 189 / 230),
        (15 / 128, 96 / 177, 199 / 230),
        (30 / 128, 108 / 177, 204 / 230),
        (65 / 128, 136 / 177, 217 / 230),
        (115 / 128, 168 / 177, 228 / 230),
        (125 / 128, 175 / 177, 231 / 230)
    ]

    private static let tigerBottomCapScales: [TigerGelScale] = [
        (127 / 128, 175 / 177, 229 / 230),
        (123 / 128, 172 / 177, 228 / 230),
        (76 / 128, 142 / 177, 218 / 230),
        (31 / 128, 108 / 177, 202 / 230),
        (15 / 128, 95 / 177, 198 / 230),
        (2 / 128, 79 / 177, 189 / 230),
        (38 / 128, 84 / 177, 170 / 230)
    ]

    private func tigerGelColor(_ sample: TigerGelSample, pressed: Bool) -> NSColor {
        let source = NSColor(
            srgbRed: sample.red / 255,
            green: sample.green / 255,
            blue: sample.blue / 255,
            alpha: 1
        )
        let referenceAccent = NSColor(
            srgbRed: 22 / 255,
            green: 134 / 255,
            blue: 217 / 255,
            alpha: 1
        )
        guard let accent = Design.Surface.accent.usingColorSpace(.sRGB) else { return source }
        let recolored = NSColor(
            hue: positiveUnit(
                source.hueComponent + accent.hueComponent - referenceAccent.hueComponent
            ),
            saturation: min(
                1,
                source.saturationComponent
                    * accent.saturationComponent / referenceAccent.saturationComponent
            ),
            brightness: min(
                1,
                source.brightnessComponent
                    * accent.brightnessComponent / referenceAccent.brightnessComponent
            ),
            alpha: 1
        )
        return pressed
            ? (recolored.blended(withFraction: 0.16, of: .black) ?? recolored)
            : recolored
    }

    private func tigerGelColor(
        _ sample: TigerGelSample,
        scale: TigerGelScale,
        pressed: Bool
    ) -> NSColor {
        let base = tigerGelColor(sample, pressed: pressed).usingColorSpace(.sRGB)
            ?? tigerGelColor(sample, pressed: pressed)
        return NSColor(
            srgbRed: min(1, base.redComponent * scale.red),
            green: min(1, base.greenComponent * scale.green),
            blue: min(1, base.blueComponent * scale.blue),
            alpha: base.alphaComponent
        )
    }

    /// Cheetah's proportional thumb is a 12-row gel seated over a neutral lower rim. Its
    /// apparent ribs are a soft 16-column optical wave, not the later three-pixel pinstripe
    /// approximation. The matrix below is measured at the flat centre of TextEdit's long
    /// thumb; rounded clipping and the authored shadow reconstruct the caps at either end.
    /// Samples are hue-shifted and scaled from the stock Aqua accent, so a custom theme that
    /// selects this anatomy still owns the gel colour.
    private func drawCheetahGel(in rect: NSRect, pressed: Bool) {
        let body: NSRect = if isHorizontalScroller {
            NSRect(
                x: rect.minX,
                y: rect.minY + 1,
                width: rect.width,
                height: max(0, rect.height - 3)
            )
        } else {
            NSRect(
                x: rect.minX + 2,
                y: rect.minY,
                width: max(0, rect.width - 3),
                height: rect.height
            )
        }
        guard body.width > 0, body.height > 0 else { return }
        let radius = min(6.5, min(body.width, body.height) / 2)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(pressed ? 0.42 : 0.32)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor(srgbRed: 92 / 255, green: 92 / 255, blue: 92 / 255, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()

        let matrixRect: NSRect = if isHorizontalScroller {
            NSRect(
                x: body.minX,
                y: body.minY + 1,
                width: body.width,
                height: max(0, body.height - 1)
            )
        } else {
            NSRect(
                x: body.minX,
                y: body.minY,
                width: max(0, body.width - 1),
                height: body.height
            )
        }
        let crossStep = (isHorizontalScroller ? matrixRect.height : matrixRect.width)
            / CGFloat(Self.cheetahGelSamples.count)
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false

        if isHorizontalScroller {
            var x = floor(matrixRect.minX)
            while x < ceil(matrixRect.maxX) {
                let cycle = positiveModulo(Int(floor(x - body.minX)), 16)
                for row in Self.cheetahGelSamples.indices {
                    cheetahGelColor(Self.cheetahGelSamples[row][cycle], pressed: pressed).setFill()
                    let y = isFlipped
                        ? matrixRect.minY + CGFloat(row) * crossStep
                        : matrixRect.maxY - CGFloat(row + 1) * crossStep
                    NSRect(x: x, y: y, width: 1, height: crossStep).fill()
                }
                x += 1
            }
        } else {
            var y = floor(matrixRect.minY)
            while y < ceil(matrixRect.maxY) {
                let cycle = positiveModulo(Int(floor(y - body.minY)), 16)
                for column in Self.cheetahGelSamples.indices {
                    cheetahGelColor(
                        Self.cheetahGelSamples[column][cycle],
                        pressed: pressed
                    ).setFill()
                    let x = matrixRect.minX + CGFloat(column) * crossStep
                    NSRect(x: x, y: y, width: crossStep, height: 1).fill()
                }
                y += 1
            }
        }
    }

    private typealias CheetahGelSample = (red: CGFloat, green: CGFloat, blue: CGFloat)

    private static let cheetahGelSamples: [[CheetahGelSample]] = [
        Array(repeating: (0, 57, 179), count: 16),
        [(117,167,224),(122,170,224),(122,167,223),(118,163,223),(117,162,220),(118,160,220),(118,158,220),(121,158,220),(119,155,218),(118,157,220),(118,158,220),(119,162,222),(119,163,222),(119,164,223),(118,165,222),(118,167,224)],
        [(150,191,233),(149,189,233),(150,189,231),(150,189,233),(148,188,231),(145,187,231),(144,185,230),(138,182,229),(140,182,229),(140,184,230),(144,185,230),(145,187,231),(146,187,230),(149,188,231),(151,191,233),(152,192,233)],
        [(149,189,233),(148,189,234),(145,186,231),(145,187,233),(142,186,230),(141,185,231),(136,180,230),(136,181,230),(131,179,229),(137,182,230),(138,181,230),(140,185,231),(142,186,231),(145,187,234),(147,188,234),(150,191,234)],
        [(142,187,235),(139,185,234),(138,184,234),(137,184,234),(137,182,231),(130,179,233),(128,177,230),(124,174,230),(123,173,229),(127,177,231),(130,179,231),(130,179,231),(132,180,233),(136,182,234),(139,184,234),(141,186,235)],
        [(87,155,231),(83,151,229),(80,147,227),(78,148,229),(74,144,225),(71,142,225),(66,138,223),(63,138,224),(59,135,224),(64,138,224),(66,139,223),(71,145,228),(74,145,227),(77,146,227),(80,147,227),(84,151,230)],
        [(108,171,243),(104,170,243),(100,166,240),(96,164,239),(94,162,238),(91,160,238),(85,155,235),(83,155,238),(78,151,235),(82,154,236),(88,157,236),(91,162,239),(94,162,238),(97,165,240),(99,165,239),(103,168,240)],
        [(124,187,255),(122,186,255),(118,182,255),(114,180,255),(113,180,255),(109,179,255),(105,173,251),(100,172,253),(96,168,249),(101,172,251),(106,174,253),(109,178,254),(111,178,253),(115,180,255),(117,181,254),(121,185,255)],
        [(141,204,255),(139,204,255),(135,199,255),(132,199,255),(128,194,255),(125,192,255),(122,191,255),(116,188,255),(113,187,255),(118,188,255),(123,189,255),(125,193,255),(129,196,255),(132,199,255),(136,200,255),(139,205,255)],
        [(155,218,255),(154,218,255),(148,214,255),(147,214,255),(142,211,255),(139,208,255),(135,204,255),(130,200,255),(127,200,255),(131,205,255),(136,205,255),(138,207,255),(144,212,255),(145,212,255),(150,217,255),(152,217,255)],
        [(167,235,255),(163,231,255),(162,230,255),(157,225,255),(152,223,255),(151,223,255),(147,218,255),(141,216,255),(137,213,255),(144,219,255),(147,218,255),(151,223,255),(154,224,255),(158,227,255),(162,228,255),(163,231,255)],
        [(159,224,255),(154,218,255),(154,217,255),(147,213,255),(147,214,255),(144,211,255),(137,205,255),(134,204,255),(128,200,255),(135,208,255),(141,210,255),(144,212,255),(147,213,255),(149,216,255),(154,218,255),(155,219,255)]
    ]

    private func cheetahGelColor(_ sample: CheetahGelSample, pressed: Bool) -> NSColor {
        let source = NSColor(
            srgbRed: sample.red / 255,
            green: sample.green / 255,
            blue: sample.blue / 255,
            alpha: 1
        )
        let referenceAccent = NSColor(
            srgbRed: 8 / 255,
            green: 120 / 255,
            blue: 213 / 255,
            alpha: 1
        )
        guard let accent = Design.Surface.accent.usingColorSpace(.sRGB) else { return source }
        let hue = positiveUnit(
            source.hueComponent + accent.hueComponent - referenceAccent.hueComponent
        )
        let saturation = min(
            1,
            source.saturationComponent
                * accent.saturationComponent / referenceAccent.saturationComponent
        )
        let brightness = min(
            1,
            source.brightnessComponent
                * accent.brightnessComponent / referenceAccent.brightnessComponent
        )
        let recolored = NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1
        )
        return pressed
            ? (recolored.blended(withFraction: 0.16, of: .black) ?? recolored)
            : recolored
    }

    private func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private func positiveUnit(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private func drawPill(_ color: NSColor, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setFill()
        let shortSide = min(rect.width, rect.height)
        let radius = Design.Radius.pill(height: shortSide)
        NSBezierPath(
            roundedRect: rect,
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

/// A clip view whose default is the only background a themed scroll surface wants: none.
///
/// Kept separate because conversations replace the ordinary clip view with a flipped subclass.
/// Subclassing this preserves the invariant without every call site remembering to turn the
/// AppKit background off after construction.
class ThemedClipView: NSClipView, ThemedComponent {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A scroll view that starts transparent, replacing `NSScrollView`.
///
/// The stock default is the erosion: `drawsBackground` is true, so a scroll view someone
/// forgot to configure paints `controlBackgroundColor` — a *system* surface — behind
/// whatever the themed pane put there. Ten of the app's twelve scroll views were switching
/// it off by hand and two had forgotten, which is exactly the argument for a type: the
/// correct state becomes the starting state, and the two forgotten ones were fixed by the
/// rename alone.
///
/// Modern scrollers retain AppKit's presentation policy while `ThemedScroller` replaces their
/// two drawing parts under an authored theme. A material can explicitly request period
/// scrollbar anatomy; that is a persistent legacy-width control because overlay pills cannot
/// contain end arrows. System delegates everything straight back to AppKit, so the identity
/// theme remains genuinely native rather than an imitation.
struct NestedScrollGestureRouter {
    private enum Axis {
        case horizontal
        case vertical
    }

    private var axis: Axis?

    /// Locks one trackpad gesture to the axis it began on, including its momentum tail.
    ///
    /// During momentum, content moves underneath a stationary pointer. AppKit can therefore
    /// retarget later events from the conversation to a nested Markdown table or code block.
    /// Re-deciding from every tiny tail delta lets horizontal noise consume the rest of a
    /// vertical flick, which feels like the conversation hit an invisible stop.
    mutating func forwardsToAncestor(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase
    ) -> Bool {
        let phased = !phase.isEmpty || !momentumPhase.isEmpty
        let beginsDirectGesture = phase.contains(.began)
        if beginsDirectGesture || !phased || axis == nil {
            if deltaX != 0 || deltaY != 0 {
                axis = abs(deltaY) >= abs(deltaX) ? .vertical : .horizontal
            }
        }

        let forwards = axis == .vertical
        // A direct `.ended` commonly arrives before a separate momentum `.began`. Keep the
        // axis across that seam; the next direct `.began` always replaces it when no momentum
        // follows, while an unphased mouse-wheel event makes its own one-event decision above.
        let ends = phase.contains(.cancelled)
            || momentumPhase.contains(.ended)
            || momentumPhase.contains(.cancelled)
        if ends || !phased { axis = nil }
        return forwards
    }

    mutating func reset() {
        axis = nil
    }
}

class ThemedScrollView: NSScrollView, ThemedComponent, SystemChromeBoundary {

    enum SurfaceRole {
        /// The long-standing default: the document is visually part of its containing pane.
        case transparent
        /// A theme-authored project-tree work area, if the active theme states one.
        case sidebarNavigator
    }

    var surfaceRole: SurfaceRole = .transparent {
        didSet { applySurfaceRole() }
    }

    /// Hands vertical-dominant gestures to the nearest enclosing scroll view.
    ///
    /// Opt this in for a nested, horizontal-only viewport such as a Markdown code block. AppKit
    /// otherwise sends the whole trackpad gesture to the view beneath the pointer, even when
    /// that view has no vertical range, which makes the surrounding conversation appear stuck.
    /// Horizontal-dominant gestures remain local.
    var forwardsVerticalScrollToAncestor = false

    /// Reports a wheel or trackpad event before it scrolls, momentum included.
    ///
    /// This is how a caller tells the user's hand from its own `setBoundsOrigin`: AppKit
    /// routes only real gestures through here, so no generation counter is needed to keep
    /// programmatic scrolls from being mistaken for the user leaving. Scroller-thumb drags
    /// never pass through `scrollWheel` — watch the live-scroll notifications for those.
    var onUserScroll: (() -> Void)?
    private var nestedGestureRouter = NestedScrollGestureRouter()
    private let appEvents = AppEventObservations()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView = ThemedClipView(frame: contentView.frame)
        verticalScroller = ThemedScroller(frame: .zero)
        horizontalScroller = ThemedScroller(frame: .zero)
        applyScrollerPresentation()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyScrollerPresentation()
            self?.applySurfaceRole()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if surfaceRole == .sidebarNavigator,
           let well = SidebarAppearance.navigatorWell(for: effectiveAppearance) {
            ThemedSurface.draw(
                bounds,
                fill: well.fill,
                radius: 0,
                bevel: well.bevel
            )
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyScrollerPresentation()
        applySurfaceRole()
    }

    /// The style this scroll view had before a period appearance forced `.legacy` on it.
    ///
    /// Leaving such a theme has to give the *caller's* choice back, not the system preference:
    /// a legacy scroller owns layout space and an overlay one floats, so restoring the wrong one
    /// hands the document the full width and leaves the scroller sitting on top of the text it
    /// was reserving room beside. Nil while no override is in force.
    private var scrollerStyleBeforePeriodAppearance: NSScroller.Style?

    private func applyScrollerPresentation() {
        let appearance = AppThemePalette.current.material(
            for: effectiveAppearance
        ).scrollerAppearance
        let desired: NSScroller.Style
        if appearance.usesLegacyPresentation {
            if scrollerStyleBeforePeriodAppearance == nil {
                scrollerStyleBeforePeriodAppearance = scrollerStyle
            }
            desired = .legacy
        } else {
            desired = scrollerStyleBeforePeriodAppearance ?? NSScroller.preferredScrollerStyle
            scrollerStyleBeforePeriodAppearance = nil
        }
        guard scrollerStyle != desired else { return }
        scrollerStyle = desired
    }

    private func applySurfaceRole() {
        let well = surfaceRole == .sidebarNavigator
            ? SidebarAppearance.navigatorWell(for: effectiveAppearance)
            : nil
        let inset = well?.edgeWidth ?? 0
        let edges = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        contentInsets = edges
        scrollerInsets = edges
        needsLayout = true
        tile()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsVerticalScrollToAncestor,
           nestedGestureRouter.forwardsToAncestor(
               deltaX: event.scrollingDeltaX,
               deltaY: event.scrollingDeltaY,
               phase: event.phase,
               momentumPhase: event.momentumPhase
           ), let ancestorScrollView {
            ancestorScrollView.scrollWheel(with: event)
            return
        }
        if !forwardsVerticalScrollToAncestor { nestedGestureRouter.reset() }

        onUserScroll?()
        super.scrollWheel(with: event)
    }

    private var ancestorScrollView: NSScrollView? {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            ancestor = current.superview
        }
        return nil
    }

    /// A table with a header makes AppKit insert a second clip view beside `contentView`.
    /// It is framework-owned and cannot be replaced through the public API, but its stock
    /// background is still ours to neutralise.
    override func tile() {
        super.tile()
        if AppThemePalette.current.material(
            for: effectiveAppearance
        ).scrollerPlacement == .leading,
           hasVerticalScroller,
           let verticalScroller,
           verticalScroller.frame.width > 0 {
            let trailingFrame = verticalScroller.frame
            verticalScroller.frame.origin.x = bounds.minX + scrollerInsets.left

            // Overlay scrollers float above content, so only the scroller changes edges.
            // A legacy scroller owns layout space; mirror AppKit's trailing reservation by
            // translating the already-sized content, header, and horizontal scroller.
            if scrollerStyle == .legacy {
                let leadingContentX = verticalScroller.frame.maxX
                for case let clip as NSClipView in subviews {
                    var frame = clip.frame
                    frame.origin.x = leadingContentX
                    clip.frame = frame
                }
                if let horizontalScroller, horizontalScroller.frame.width > 0 {
                    var frame = horizontalScroller.frame
                    frame.origin.x = leadingContentX
                    horizontalScroller.frame = frame
                }

                assert(
                    verticalScroller.frame.width == trailingFrame.width,
                    "moving a vertical scroller must not resize it"
                )
            }
        }
        for case let clip as NSClipView in subviews where clip !== contentView {
            clip.drawsBackground = false
        }
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        // macOS 26 inserts visual-effect views into overlay-scrolling chrome. Depending on
        // the scroll view's state, the effect is either direct or nested under private
        // NSScrollPocket/NSHardPocketView wrappers. Permit that AppKit-owned side of the tree
        // while refusing effects in contentView/documentView, where application content lives.
        if view is NSVisualEffectView {
            var ancestor = view.superview
            while let current = ancestor, current !== self {
                if current === contentView || current === documentView {
                    return false
                }
                ancestor = current.superview
            }
            return ancestor === self
        }

        // The only raw clip AppKit may add is the direct, transparent header clip described
        // above. This does not grant permission to a raw clip in the document subtree.
        guard let clip = view as? NSClipView else { return false }
        return clip.superview === self && !clip.drawsBackground
    }
}
