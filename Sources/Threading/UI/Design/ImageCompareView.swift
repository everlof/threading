import AppKit

/// Measurements the compare surface owns. Everything else reads `Design` tokens directly.
enum ImageCompareDefaults {
    /// The draggable seam handle — sized as a control target, like a chip.
    static var handleDiameter: CGFloat { Design.Size.chipHeight }
    /// The seam's stroke.
    static let seamWidth: CGFloat = 2
    /// One checker square, in points.
    static let checkerSquare: CGFloat = 8
    /// The arrow-key nudge, as a fraction of the canvas.
    static let keyboardStep: CGFloat = 0.05
    /// Between a caption and the pixels it names. The band reserved for it is this plus the
    /// caption's own measured line.
    static let captionGap: CGFloat = Design.Spacing.small
    /// Past this many points per pixel the images are icons being inspected, and interpolation
    /// smears exactly the pixels the comparison is looking for.
    static let crispScaleThreshold: CGFloat = 4
    /// The cap `preferredHeight(forWidth:)` applies, so one tall screenshot does not turn a
    /// review row into a full-window scroll.
    static let maximumPreferredCanvasHeight: CGFloat = 420
}

/// An interactive comparison of two images: a draggable wipe seam (either axis), a crossfade,
/// a pixel difference, and side-by-side — one scrubbed fraction shared across modes, so the
/// seam stays where the user left it when they switch.
///
/// The component is the whole surface: the drawing canvas, the per-side captions, the
/// dimension note when the two sides disagree, and the mode chip. Hosts size it and hand it
/// content; nothing about its appearance is theirs to choose.
final class ImageCompareView: NSView {

    // MARK: - Properties

    /// One side of the comparison. The title is what the caption beside the image says — a
    /// filename, or a revision like "HEAD".
    struct Side {
        let image: NSImage
        let title: String
    }

    private let canvas = ImageCompareCanvas()
    private let modeChip = ChipView()

    /// Answered when the user picks a different mode, so a host can persist it.
    var onModeChange: ((ImageCompareMode) -> Void)?

    var mode: ImageCompareMode {
        get { canvas.mode }
        set {
            canvas.mode = newValue
            updateModeChip()
        }
    }

    /// The scrub position — exposed for tests and for hosts restoring a saved comparison.
    var fraction: CGFloat {
        get { canvas.fraction }
        set { canvas.fraction = newValue }
    }

    override var isFlipped: Bool { true }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Hands the surface its two sides. A nil side is an added or deleted file: the one image
    /// shows plainly and the modes hide, because a comparison needs two things to compare.
    func configure(old: Side?, new: Side?) {
        canvas.old = old
        canvas.new = new
        modeChip.isHidden = old == nil || new == nil
        updateModeChip()
        canvas.needsDisplay = true
    }

    /// The height the surface wants at `width`: the fitted canvas (capped), the controls row,
    /// and the spacing between them. What a review row uses to size an expanded body.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let controls = modeChip.isHidden ? 0 : Design.Size.chipHeight + Design.Spacing.small
        return canvas.preferredCanvasHeight(forWidth: width) + controls
    }

    // MARK: - Private Methods

    private func setupViews() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        modeChip.translatesAutoresizingMaskIntoConstraints = false

        modeChip.itemsProvider = { [weak self] in self?.modeMenuEntries() ?? [] }
        modeChip.onSelect = { [weak self] item in
            guard let self, let mode = item.representedValue as? ImageCompareMode else { return }
            self.mode = mode
            self.onModeChange?(mode)
        }

        addSubview(canvas)
        addSubview(modeChip)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            modeChip.topAnchor.constraint(
                equalTo: canvas.bottomAnchor, constant: Design.Spacing.small
            ),
            modeChip.leadingAnchor.constraint(equalTo: leadingAnchor),
            modeChip.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateModeChip()
    }

    private func modeMenuEntries() -> [ThemedMenuEntry] {
        ImageCompareMode.allCases.map { candidate in
            .item(ThemedMenuItem(
                title: Self.name(for: candidate),
                representedValue: candidate,
                isSelected: candidate == mode
            ))
        }
    }

    private func updateModeChip() {
        modeChip.configure(symbolName: Self.symbol(for: mode), title: Self.name(for: mode))
    }

    /// The chip names the answer — which comparison is on — not the setting.
    static func name(for mode: ImageCompareMode) -> String {
        switch mode {
        case .wipeHorizontal: return L10n.string("Wipe ↔")
        case .wipeVertical: return L10n.string("Wipe ↕")
        case .fade: return L10n.string("Fade")
        case .difference: return L10n.string("Difference")
        case .sideBySide: return L10n.string("Side by Side")
        }
    }

    private static func symbol(for mode: ImageCompareMode) -> String {
        switch mode {
        case .wipeHorizontal: return "rectangle.split.2x1"
        case .wipeVertical: return "rectangle.split.1x2"
        case .fade: return "circle.lefthalf.filled.inverse"
        case .difference: return "circle.circle"
        case .sideBySide: return "rectangle.on.rectangle"
        }
    }
}

// MARK: - Canvas

/// The drawing and interaction surface: everything inside the compare view that is not the
/// mode chip. A `ThemedControl` because the seam is dragged, focused and keyed like any other
/// control — and because everything here is drawn at display time from roles, never frozen
/// into a layer.
final class ImageCompareCanvas: ThemedControl {

    // MARK: - Properties

    var old: ImageCompareView.Side? { didSet { needsDisplay = true } }
    var new: ImageCompareView.Side? { didSet { needsDisplay = true } }

    var mode: ImageCompareMode = .wipeHorizontal {
        didSet {
            guard mode != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The scrub position, 0…1 — the seam's place in the wipes, the new side's opacity in fade.
    var fraction: CGFloat = 0.5 {
        didSet {
            let clamped = ImageCompareLayout.clamped(fraction)
            if clamped != fraction {
                fraction = clamped
                return
            }
            guard fraction != oldValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var isFlipped: Bool { true }

    /// There is nothing to operate without two sides, and nothing to scrub in the static modes.
    private var isScrubbable: Bool {
        old != nil && new != nil && mode.usesFraction
    }

    override var acceptsFirstResponder: Bool { isEnabled && isScrubbable }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel(L10n.string("Image comparison"))
    }

    // MARK: - Public Methods

    /// The canvas height that fits the two sides at `width`, capped so a tall screenshot stays
    /// a row rather than a page — plus the caption bands, which are the surface's height too:
    /// asking for the image's height alone would take the captions back out of the image.
    func preferredCanvasHeight(forWidth width: CGFloat) -> CGFloat {
        let bands = captionBands
        let reserved = bands.top + bands.bottom
        let union = unionPixelSize
        guard union.width > 0, union.height > 0, width > 0 else {
            return ImageCompareDefaults.maximumPreferredCanvasHeight / 2 + reserved
        }
        var fittedWidth: CGFloat = width
        if mode == .sideBySide {
            let half: CGFloat = (width - Design.Spacing.medium) / 2
            fittedWidth = max(0, half)
        }
        let height: CGFloat = union.height * (fittedWidth / union.width)
        return min(height, ImageCompareDefaults.maximumPreferredCanvasHeight) + reserved
    }

    // MARK: - Layout

    private var unionPixelSize: CGSize {
        CGSize(
            width: max(oldPixelSize.width, newPixelSize.width),
            height: max(oldPixelSize.height, newPixelSize.height)
        )
    }

    private var oldPixelSize: CGSize { old.map { Self.pixelSize(of: $0.image) } ?? .zero }
    private var newPixelSize: CGSize { new.map { Self.pixelSize(of: $0.image) } ?? .zero }

    /// The image's pixel grid, not its point size: a 2× screenshot reports half its pixels as
    /// its `size`, and a comparison of pixels should say what the pixels say.
    static func pixelSize(of image: NSImage) -> CGSize {
        var best: CGSize = .zero
        for representation in image.representations {
            let candidate = CGSize(
                width: CGFloat(representation.pixelsWide),
                height: CGFloat(representation.pixelsHigh)
            )
            guard candidate.width > 0, candidate.height > 0 else { continue }
            if candidate.width * candidate.height > best.width * best.height {
                best = candidate
            }
        }
        return best == .zero ? image.size : best
    }

    /// The geometry the canvas is drawing at right now: the pure layout, fed this canvas's own
    /// content, mode and caption bands.
    var currentLayout: ImageCompareLayout {
        ImageCompareLayout.layout(
            oldSize: oldPixelSize,
            newSize: newPixelSize,
            in: bounds,
            mode: effectiveMode,
            gap: Design.Spacing.medium,
            captions: captionBands
        )
    }

    /// One side alone has no modes: it draws as a plain fitted image whatever `mode` says.
    private var effectiveMode: ImageCompareMode {
        (old == nil || new == nil) ? .fade : mode
    }

    /// The measured caption line. Read from the font rather than pinned to a token, because the
    /// caption follows the app's text-size setting and a fixed band would clip it.
    private var captionLineHeight: CGFloat {
        ("Ag" as NSString).size(withAttributes: [.font: Design.Typography.caption()]).height
    }

    /// Whether the two sides disagree about their pixel size — what the dimension note says.
    private var hasDimensionNote: Bool {
        guard old != nil, new != nil else { return false }
        return oldPixelSize != newPixelSize
    }

    /// The room this mode's captions need, taken out of the surface before the images are
    /// fitted. A band is only reserved where something is written, so an unnamed single image
    /// still gets the whole surface.
    private var captionBands: ImageCompareLayout.CaptionBands {
        let band = captionLineHeight + ImageCompareDefaults.captionGap
        let isNamed = old != nil || new != nil
        // The vertical wipe's mapping is vertical, so the new side is named under the image.
        let namesNewSideBelow = effectiveMode == .wipeVertical && old != nil && new != nil
        return ImageCompareLayout.CaptionBands(
            top: isNamed ? band : 0,
            bottom: namesNewSideBelow || hasDimensionNote ? band : 0
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let layout = currentLayout
        let placement = layout.placement

        if old != nil || new != nil {
            drawCheckerboard(in: placement.canvasRect)
            if let secondary = placement.secondaryCanvasRect {
                drawCheckerboard(in: secondary)
            }
        }

        switch effectiveMode {
        case .wipeHorizontal, .wipeVertical:
            drawWipe(layout: layout)
        case .fade:
            drawFade(layout: layout)
        case .difference:
            drawDifference(layout: layout)
        case .sideBySide:
            drawSideBySide(layout: layout)
        }

        drawCaptions(layout: layout)
        drawCanvasFocusRing()
    }

    /// Drawn by hand rather than through `drawKeyboardFocus`: the canvas has no applied
    /// surface, so its silhouette is its own bounds — inset by half the ring's width, since a
    /// stroke is centred on its path and the half outside the bounds is clipped to half weight.
    private func drawCanvasFocusRing() {
        guard hasKeyboardFocus else { return }
        let width = Design.Accessibility.focusRingWidth
        let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
        let radius = max(0, Design.Radius.control - width / 2)
        let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        Design.Surface.accent.setStroke()
        ring.lineWidth = width
        ring.stroke()
    }

    private func drawImage(
        _ image: NSImage,
        in rect: CGRect,
        at scale: CGFloat,
        alpha: CGFloat = 1,
        operation: NSCompositingOperation = .sourceOver
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let context = NSGraphicsContext.current
        let previous = context?.imageInterpolation ?? .default
        if scale >= ImageCompareDefaults.crispScaleThreshold {
            context?.imageInterpolation = .none
        }
        image.draw(
            in: rect,
            from: .zero,
            operation: operation,
            fraction: alpha,
            respectFlipped: true,
            hints: nil
        )
        context?.imageInterpolation = previous
    }

    private func drawWipe(layout: ImageCompareLayout) {
        let placement = layout.placement
        let regions = ImageCompareLayout.wipeRegions(
            in: placement.canvasRect, mode: effectiveMode, fraction: fraction
        )

        if let old {
            NSGraphicsContext.saveGraphicsState()
            regions.old.clip()
            drawImage(old.image, in: placement.oldRect, at: layout.scale)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let new {
            NSGraphicsContext.saveGraphicsState()
            regions.new.clip()
            drawImage(new.image, in: placement.newRect, at: layout.scale)
            NSGraphicsContext.restoreGraphicsState()
        }

        drawSeam(in: placement.canvasRect)
    }

    private func drawFade(layout: ImageCompareLayout) {
        let placement = layout.placement
        // One side alone draws plainly, whatever the fraction says: an added file is not a
        // faded one.
        let newAlpha = old == nil || new == nil ? 1 : fraction
        if let old {
            drawImage(old.image, in: placement.oldRect, at: layout.scale)
        }
        if let new {
            drawImage(new.image, in: placement.newRect, at: layout.scale, alpha: newAlpha)
        }
    }

    private func drawDifference(layout: ImageCompareLayout) {
        guard let old, let new, let context = NSGraphicsContext.current?.cgContext else { return }
        let placement = layout.placement

        // Composited in a transparency layer so the difference is between the two images alone
        // — drawn straight onto the view, the checkerboard would join the arithmetic. The
        // operation rides the draw call itself: `NSImage.draw` states its own compositing, so
        // a blend mode set on the context beneath it is silently overridden.
        NSGraphicsContext.saveGraphicsState()
        placement.canvasRect.clip()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawImage(old.image, in: placement.oldRect, at: layout.scale)
        drawImage(new.image, in: placement.newRect, at: layout.scale, operation: .difference)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSideBySide(layout: ImageCompareLayout) {
        let placement = layout.placement
        if let old {
            drawImage(old.image, in: placement.oldRect, at: layout.scale)
        }
        if let new {
            drawImage(new.image, in: placement.newRect, at: layout.scale)
        }
    }

    // MARK: - Seam

    private var handleCentre: CGPoint {
        let canvas = currentLayout.placement.canvasRect
        let seam = ImageCompareLayout.seam(in: canvas, mode: effectiveMode, fraction: fraction)
        switch effectiveMode {
        case .wipeHorizontal: return CGPoint(x: seam, y: canvas.midY)
        case .wipeVertical: return CGPoint(x: canvas.midX, y: seam)
        default: return .zero
        }
    }

    private func drawSeam(in canvas: CGRect) {
        guard isScrubbable, canvas.width > 0 else { return }
        let seam = ImageCompareLayout.seam(in: canvas, mode: effectiveMode, fraction: fraction)
        let accent = Design.Surface.accent

        let line = NSBezierPath()
        switch effectiveMode {
        case .wipeHorizontal:
            line.move(to: CGPoint(x: seam, y: canvas.minY))
            line.line(to: CGPoint(x: seam, y: canvas.maxY))
        case .wipeVertical:
            line.move(to: CGPoint(x: canvas.minX, y: seam))
            line.line(to: CGPoint(x: canvas.maxX, y: seam))
        default:
            return
        }
        accent.setStroke()
        line.lineWidth = ImageCompareDefaults.seamWidth
        line.stroke()

        // The handle floats over image content, so its fill is flattened opaque — the
        // floating-surface rule; a translucent lift would let the pixels underneath run
        // through the one control on the surface.
        let diameter = ImageCompareDefaults.handleDiameter
        let centre = handleCentre
        let handleRect = CGRect(
            x: centre.x - diameter / 2,
            y: centre.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let fill = isHovered || isDragging
            ? WindowBackdrop.opaque(Design.Surface.controlHover)
            : WindowBackdrop.opaque(Design.Surface.elevated)
        ThemedSurface.draw(handleRect, fill: fill, border: accent, radius: diameter / 2)

        drawHandleChevrons(centre: centre)
    }

    private func drawHandleChevrons(centre: CGPoint) {
        let ink = Design.Text.secondary
        let arm: CGFloat = 3
        let offset: CGFloat = 5
        let chevrons = NSBezierPath()
        let vertical = effectiveMode == .wipeVertical

        for direction: CGFloat in [-1, 1] {
            let tipDistance = offset + arm
            let tip = CGPoint(
                x: centre.x + (vertical ? 0 : direction * tipDistance),
                y: centre.y + (vertical ? direction * tipDistance : 0)
            )
            let baseA = CGPoint(
                x: vertical ? centre.x - arm : centre.x + direction * offset,
                y: vertical ? centre.y + direction * offset : centre.y - arm
            )
            let baseB = CGPoint(
                x: vertical ? centre.x + arm : centre.x + direction * offset,
                y: vertical ? centre.y + direction * offset : centre.y + arm
            )
            chevrons.move(to: baseA)
            chevrons.line(to: tip)
            chevrons.line(to: baseB)
        }

        ink.setStroke()
        chevrons.lineWidth = 1.5
        chevrons.lineCapStyle = .round
        chevrons.lineJoinStyle = .round
        chevrons.stroke()
    }

    // MARK: - Checkerboard

    /// Drawn so transparency reads as transparency. Both squares are flattened opaque — the
    /// board is the ground the images sit on, not a wash over one.
    private func drawCheckerboard(in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let base = WindowBackdrop.opaque(Design.Surface.background)
        let alt = Design.Surface.controlResting.composited(over: base)

        base.setFill()
        rect.fill()

        alt.setFill()
        let square = ImageCompareDefaults.checkerSquare
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var column = 0
            var x = rect.minX
            while x < rect.maxX {
                if (row + column) % 2 == 1 {
                    CGRect(x: x, y: y, width: square, height: square)
                        .intersection(rect)
                        .fill()
                }
                x += square
                column += 1
            }
            y += square
            row += 1
        }
    }

    // MARK: - Captions

    /// Which end of its band a caption hugs, so the gap in the band is always the one between
    /// the words and the picture.
    private enum CaptionEdge {
        case top
        case bottom
    }

    /// Names the two sides in the strips reserved beside the images.
    ///
    /// Nothing here draws over the comparison. Position carries the mapping — start of the
    /// travel is the old side, end of it the new — and the new side is inked a step stronger, so
    /// which is which survives a title too long to read to its end.
    private func drawCaptions(layout: ImageCompareLayout) {
        let placement = layout.placement
        let top = layout.captions.top
        let bottom = layout.captions.bottom
        var bottomHoldsATitle = false

        switch effectiveMode {
        case .wipeVertical:
            // The seam sweeps downward, so the sides are named above and below the picture.
            if let old {
                drawCaption(old.title, ink: Design.Text.secondary, in: top, edge: .top)
            }
            if let new {
                drawCaption(new.title, ink: Design.Text.label, in: bottom, edge: .bottom)
                bottomHoldsATitle = true
            }

        case .sideBySide:
            if let old {
                drawCaption(
                    old.title, ink: Design.Text.secondary,
                    in: slot(over: placement.canvasRect, in: top), edge: .top, alignment: .center
                )
            }
            if let new, let secondary = placement.secondaryCanvasRect {
                drawCaption(
                    new.title, ink: Design.Text.label,
                    in: slot(over: secondary, in: top), edge: .top, alignment: .center
                )
            }

        case .difference:
            // Neither side is anywhere — the difference is one image made of both — so the pair
            // is named the way the text diff names it rather than split across two edges that
            // would imply a position this mode does not have.
            if let old, let new {
                drawCaption(
                    "\(old.title) → \(new.title)", ink: Design.Text.secondary,
                    in: top, edge: .top, alignment: .center
                )
            }

        default:
            // The wipe's seam and the fade's blend are both scrubbed left to right, so the old
            // side sits at the start of that travel and the new side at its end.
            switch (old, new) {
            case let (.some(old), .some(new)):
                let (leading, trailing) = halves(of: top)
                drawCaption(old.title, ink: Design.Text.secondary, in: leading, edge: .top)
                drawCaption(
                    newSideCaption(new), ink: Design.Text.label,
                    in: trailing, edge: .top, alignment: .right
                )
            case let (.some(side), nil), let (nil, .some(side)):
                // One side alone — an added or deleted file. There is nothing to tell it apart
                // from, so it takes the whole band.
                drawCaption(side.title, ink: Design.Text.label, in: top, edge: .top)
            case (nil, nil):
                break
            }
        }

        drawDimensionNote(in: bottom, sharingTheBand: bottomHoldsATitle)
    }

    /// The new side's caption. In the crossfade it carries the blend, which is the fraction's
    /// only readout — the wipes show theirs as the seam's own position.
    private func newSideCaption(_ side: ImageCompareView.Side) -> String {
        guard effectiveMode == .fade, isScrubbable else { return side.title }
        return "\(side.title) · \(Int((fraction * 100).rounded()))%"
    }

    /// The note that says the two sides are not the same size. Centred in its band, unless a
    /// title already has the left of it — then it takes the right, rather than stacking on top
    /// of the words or being dropped the way it used to be.
    private func drawDimensionNote(in band: CGRect, sharingTheBand: Bool) {
        guard hasDimensionNote else { return }
        let text = "\(Int(oldPixelSize.width))×\(Int(oldPixelSize.height)) → " +
            "\(Int(newPixelSize.width))×\(Int(newPixelSize.height))"
        let slot = sharingTheBand ? halves(of: band).trailing : band
        drawCaption(
            text, ink: Design.Text.tertiary,
            in: slot, edge: .bottom, alignment: sharingTheBand ? .right : .center
        )
    }

    /// Two captions in one band, each capped at half of it, so a long title truncates rather
    /// than running into the one opposite.
    private func halves(of band: CGRect) -> (leading: CGRect, trailing: CGRect) {
        let width = max(0, (band.width - Design.Spacing.medium) / 2)
        return (
            CGRect(x: band.minX, y: band.minY, width: width, height: band.height),
            CGRect(x: band.maxX - width, y: band.minY, width: width, height: band.height)
        )
    }

    /// The part of a band that lies over one canvas — how a side-by-side caption stays over the
    /// image it names instead of over the pair.
    private func slot(over canvas: CGRect, in band: CGRect) -> CGRect {
        CGRect(x: canvas.minX, y: band.minY, width: canvas.width, height: band.height)
    }

    /// One line of caption, hugging the outer edge of its band. Truncating rather than
    /// wrapping: the line is one line high, and `NSString.draw(in:)` wraps by default, which
    /// would draw the second word over the pixels the band exists to keep clear.
    private func drawCaption(
        _ text: String,
        ink: NSColor,
        in slot: CGRect,
        edge: CaptionEdge,
        alignment: NSTextAlignment = .left
    ) {
        guard slot.width > 0, slot.height > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.caption(),
            .foregroundColor: ink,
            .paragraphStyle: style
        ]
        let line = min(captionLineHeight, slot.height)
        (text as NSString).draw(
            in: CGRect(
                x: slot.minX,
                y: edge == .top ? slot.minY : slot.maxY - line,
                width: slot.width,
                height: line
            ),
            withAttributes: attributes
        )
    }

    // MARK: - Interaction

    private var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, isScrubbable else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        scrub(to: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        scrub(to: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func scrub(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        fraction = ImageCompareLayout.fraction(
            at: point, in: currentLayout.placement.canvasRect, mode: effectiveMode
        )
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, isScrubbable else {
            super.keyDown(with: event)
            return
        }
        let step = ImageCompareDefaults.keyboardStep
        switch event.specialKey {
        case .some(.leftArrow), .some(.upArrow):
            fraction -= step
        case .some(.rightArrow), .some(.downArrow):
            fraction += step
        case .some(.home):
            fraction = 0
        case .some(.end):
            fraction = 1
        default:
            super.keyDown(with: event)
        }
    }

    /// Space and Return recentre the scrub — the one position every mode has a use for.
    override func performPrimaryAction() -> Bool {
        guard isScrubbable else { return false }
        fraction = 0.5
        return true
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? {
        "\(Int((fraction * 100).rounded()))%"
    }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }

    override func accessibilityPerformIncrement() -> Bool {
        guard isScrubbable else { return false }
        fraction += ImageCompareDefaults.keyboardStep
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard isScrubbable else { return false }
        fraction -= ImageCompareDefaults.keyboardStep
        return true
    }
}
