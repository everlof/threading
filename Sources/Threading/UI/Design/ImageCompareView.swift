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
    /// Between a caption and the pixels it names.
    static let captionGap: CGFloat = Design.Spacing.small
    /// Between a caption and the surface's outer edge, on every side. The focus ring strokes
    /// the bounds, so text flush against them sits on the ring; the band reserved for a caption
    /// is this margin plus the measured line plus `captionGap`, and sideways the text keeps
    /// this much clear of the bounds wherever the picture itself reaches them.
    ///
    /// A step above `captionGap` on purpose. Equal to it, the title sat as close to the border
    /// as to the picture it names — and with the ring drawn the pair read as one crowded line
    /// rather than as a label belonging to the image under it.
    static let captionMargin: CGFloat = Design.Spacing.medium
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

    /// The scale the surface's own row stands at, and the one a host placing these controls
    /// puts them in — so the comparison reads the same whether its modes sit under the canvas
    /// or up in a tab's header.
    static let controlScale: ControlRowScale = .compact

    private let canvas = ImageCompareCanvas()
    private let modeChip = ChipView()
    private lazy var expandButton = ThemedIconButton(
        symbolName: "arrow.up.left.and.arrow.down.right",
        accessibility: L10n.string("Open comparison"),
        target: .inline,
        inkSource: .chrome
    )
    /// The chip at one edge, the way to open the comparison at the other. The row is what makes
    /// the two stand at one height: the chip is the theme's `choiceHeight` and the button used
    /// to be a fixed 20, which is the six points the pair sat out of level by under the System
    /// theme and four points the *other* way under Platinum.
    private lazy var controlRow = ControlRowView(
        scale: Self.controlScale,
        leading: [modeChip],
        trailing: [expandButton]
    )

    /// Answered when the user picks a different mode, so a host can persist it.
    var onModeChange: ((ImageCompareMode) -> Void)?

    /// Whether the surface offers to open itself in the window's own inspector.
    ///
    /// On by default: wherever a comparison is inline it is inside something else's height — a
    /// review row, a pane the divider decides — and the expanded surface is the same comparison
    /// with the room to actually scrub it. The inspector turns it off in the one place it would
    /// offer to open what is already open.
    var allowsExpansion = true {
        didSet {
            guard allowsExpansion != oldValue else { return }
            updateControls()
        }
    }

    /// The control inside the surface, for a host whose window *is* this comparison and so opens
    /// with the scrub already in hand.
    var preferredFirstResponder: NSView { canvas }

    /// Whether the surface still draws the controls row under its canvas. False once a host has
    /// taken the controls with `hostControls()`.
    private(set) var carriesControls = true

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
        updateControls()
        canvas.needsDisplay = true
    }

    /// The height the surface wants at `width`: the fitted canvas (capped), the controls row,
    /// and the spacing between them. What a review row uses to size an expanded body.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let controls = showsRow
            ? ControlRowView.height(for: Self.controlScale) + Design.Spacing.small
            : 0
        return canvas.preferredCanvasHeight(forWidth: width) + controls
    }

    /// Hands the surface's own controls to a host that will place them itself, and stops the
    /// surface drawing a row for them.
    ///
    /// One call rather than two accessors and a flag, because taking the controls and giving up
    /// the row are the same act: a host that took them and forgot to detach would leave a chip
    /// in two places, and one that detached without placing them would lose the modes entirely.
    ///
    /// The controls stay wired to this surface — the chip still switches *its* mode and the
    /// button still expands *this* comparison. What the host gains is where they sit. The Compare
    /// tab uses it to put them in a header, above the scroll view rather than inside it: below
    /// the canvas they were part of the scrolled content, so the modes scrolled off a tall
    /// screenshot exactly when a reader had got far enough down it to want another one.
    @discardableResult
    func hostControls() -> (mode: NSView, expansion: NSView) {
        guard carriesControls else { return (modeChip, expandButton) }
        carriesControls = false
        // Emptying the row is what gives the two views up: it takes them out of its runs and
        // out of its view tree in one act, so neither can be left half-held by a row that is
        // no longer on screen. The host puts them in a row of its own — see `controlScale`.
        controlRow.configure(leading: [], trailing: [])
        controlRow.removeFromSuperview()
        updateControls()
        return (modeChip, expandButton)
    }

    /// Opens this comparison in the window's inspector, and answers whether it opened. A surface
    /// with no window — a fixture, or a row already on its way out — has nowhere to open into.
    @discardableResult
    func expand() -> Bool {
        CompareInspectorPresenter.present(
            CompareInspectorContent(
                old: canvas.old, new: canvas.new, mode: mode, fraction: fraction
            ),
            // The canvas, not the surface around it: it is what focus comes back to when the
            // inspector closes, and a plain view would decline it.
            from: canvas,
            onClose: { [weak self] result in
                guard let self else { return }
                // The expanded surface is *this* comparison, so what the user settled on there
                // is what stands here — otherwise closing it would throw their scrub away and
                // snap the mode back to whichever one they opened.
                self.fraction = result.fraction
                guard result.mode != self.mode else { return }
                self.mode = result.mode
                self.onModeChange?(result.mode)
            }
        )
    }

    // MARK: - Private Methods

    private func setupViews() {
        canvas.translatesAutoresizingMaskIntoConstraints = false

        modeChip.itemsProvider = { [weak self] in self?.modeMenuEntries() ?? [] }
        modeChip.onSelect = { [weak self] item in
            guard let self, let mode = item.representedValue as? ImageCompareMode else { return }
            self.mode = mode
            self.onModeChange?(mode)
        }
        expandButton.onPress = { [weak self] in
            guard self?.expand() == false else { return }
            NSSound.beep()
        }

        addSubview(canvas)
        addSubview(controlRow)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        updateControls()
    }

    /// The canvas and the row beneath it, which is the surface as it ships.
    private lazy var attachedConstraints: [NSLayoutConstraint] = [
        controlRow.topAnchor.constraint(
            equalTo: canvas.bottomAnchor, constant: Design.Spacing.small
        ),
        controlRow.leadingAnchor.constraint(equalTo: leadingAnchor),
        controlRow.trailingAnchor.constraint(equalTo: trailingAnchor),
        controlRow.bottomAnchor.constraint(equalTo: bottomAnchor)
    ]

    /// The canvas alone: a host has taken the controls, or there is only one image and there
    /// are none to show. Either way nothing is left to reserve a row for, so the surface is
    /// exactly the comparison.
    private lazy var hostedConstraints: [NSLayoutConstraint] = [
        canvas.bottomAnchor.constraint(equalTo: bottomAnchor)
    ]

    /// The controls row: the mode chip, and the way to open the comparison larger.
    ///
    /// Both need two sides. A single image is an added or deleted file — there is no comparison
    /// to switch the mode of, and nothing an inspector would show that the row does not.
    private var showsControls: Bool { canvas.old != nil && canvas.new != nil }

    /// Whether the surface is currently drawing a row of its own, which is the one condition
    /// `preferredHeight(forWidth:)` reserves room for.
    private var showsRow: Bool { carriesControls && showsControls }

    private func updateControls() {
        modeChip.isHidden = !showsControls
        expandButton.isHidden = !showsControls || !allowsExpansion
        updateRowAttachment()
        updateModeChip()
    }

    /// Pins the canvas either above the row or straight to the bottom.
    ///
    /// Stated as one decision because it used to be two: the chip was *hidden* for a single
    /// image while its constraints went on holding a chip's height under the canvas, and
    /// `preferredHeight(forWidth:)` — correctly — reported a height with no row in it. An added
    /// file was therefore fitted into a box a row shorter than the surface asked for, and paid
    /// for it in the picture.
    private func updateRowAttachment() {
        NSLayoutConstraint.deactivate(showsRow ? hostedConstraints : attachedConstraints)
        NSLayoutConstraint.activate(showsRow ? attachedConstraints : hostedConstraints)
        controlRow.isHidden = !showsRow
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

    /// The chip names the answer — which comparison is on — not the setting. The words are the
    /// mode's own (`ImageCompareMode.title`), so an exported comparison labels its buttons with
    /// the same ones.
    static func name(for mode: ImageCompareMode) -> String { mode.title }

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

    private var focusOrigin = KeyboardFocusOrigin()

    /// Whether the ring is being drawn — see `KeyboardFocusOrigin`. The expanded comparison hands
    /// this canvas focus the moment it opens, and the ring follows the canvas's own bounds, so an
    /// unconditional one outlined the whole surface before the user had done anything.
    var showsKeyboardFocusRing: Bool { hasKeyboardFocus && focusOrigin.isFromKeyboard }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel(L10n.string("Image comparison"))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusArrived(from: NSApp.currentEvent) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusOrigin.resigned()
            needsDisplay = true
        }
        return resigned
    }

    /// Internal rather than private so a fixture can state the event that moved focus:
    /// `NSApp.currentEvent` is whatever the run loop last pulled off the queue, and an unshown
    /// test window pulls nothing.
    func focusArrived(from event: NSEvent?) {
        focusOrigin.arrived(from: event)
        needsDisplay = true
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

    /// The narrowest slot still worth writing in. Measured from the font for the same reason the
    /// line height is: a slot narrower than a couple of glyphs and the ellipsis after them holds
    /// no name, only the mark saying a name was truncated — which is what the last points of a
    /// seam travelling to the edge would otherwise leave behind.
    private var minimumCaptionWidth: CGFloat {
        ("Ag…" as NSString).size(withAttributes: [.font: Design.Typography.caption()]).width
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
        let band = ImageCompareDefaults.captionMargin + captionLineHeight
            + ImageCompareDefaults.captionGap
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
    ///
    /// Shown only under keyboard traversal (`KeyboardFocusOrigin`), because the silhouette here is
    /// the whole surface: the expanded comparison focuses this canvas as it opens, and a ring
    /// around everything says nothing about where focus is.
    private func drawCanvasFocusRing() {
        guard showsKeyboardFocusRing else { return }
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
    /// Nothing here draws over the comparison, and neither title is styled as the important
    /// one. Both come off one ramp read by how much of its picture each side is showing, and in
    /// the horizontal wipe the band divides where the seam does — so a caption tracks the pixels
    /// it names as they are revealed and covered, rather than sitting at a fixed edge naming an
    /// image that may have been scrubbed out of view entirely.
    private func drawCaptions(layout: ImageCompareLayout) {
        let placement = layout.placement
        let top = layout.captions.top
        let bottom = layout.captions.bottom
        let shares = visibleShares
        var bottomHoldsATitle = false

        switch effectiveMode {
        case .wipeVertical:
            // The seam sweeps downward, so the sides are named above and below the picture.
            if let old {
                drawCaption(old.title, ink: captionInk(showing: shares.old), in: top, edge: .top)
            }
            if let new {
                drawCaption(
                    new.title, ink: captionInk(showing: shares.new), in: bottom, edge: .bottom
                )
                bottomHoldsATitle = true
            }

        case .sideBySide:
            // Both sides are whole and each caption stands over its own picture, so neither is
            // showing more than the other: they meet at the middle of the ramp.
            if let old {
                drawCaption(
                    old.title, ink: captionInk(showing: shares.old),
                    in: slot(over: placement.canvasRect, in: top), edge: .top, alignment: .center
                )
            }
            if let new, let secondary = placement.secondaryCanvasRect {
                drawCaption(
                    new.title, ink: captionInk(showing: shares.new),
                    in: slot(over: secondary, in: top), edge: .top, alignment: .center
                )
            }

        case .difference:
            // Neither side is anywhere — the difference is one image made of both — so the pair
            // is named the way the text diff names it rather than split across two edges that
            // would imply a position this mode does not have.
            if let old, let new {
                drawCaption(
                    "\(old.title) → \(new.title)", ink: captionInk(showing: Self.balancedShare),
                    in: top, edge: .top, alignment: .center
                )
            }

        default:
            // The wipe's seam and the fade's blend are both scrubbed left to right, so the old
            // side sits at the start of that travel and the new side at its end.
            switch (old, new) {
            case let (.some(old), .some(new)):
                let (leading, trailing) = halves(of: top, splitAt: captionSplit(in: layout))
                drawCaption(
                    old.title, ink: captionInk(showing: shares.old), in: leading, edge: .top
                )
                drawCaption(
                    newSideCaption(new), ink: captionInk(showing: shares.new),
                    in: trailing, edge: .top, alignment: .right
                )
            case let (.some(side), nil), let (nil, .some(side)):
                // One side alone — an added or deleted file. There is nothing to tell it apart
                // from, so it takes the whole band, at the top of the ramp: it is all that is
                // being shown.
                drawCaption(side.title, ink: captionInk(showing: 1), in: top, edge: .top)
            case (nil, nil):
                break
            }
        }

        drawDimensionNote(in: bottom, sharingTheBand: bottomHoldsATitle)
    }

    /// How much of the picture each side is showing at the current scrub, 0 to 1.
    ///
    /// The wipes divide the canvas at the seam — old before it, new after it — so the old
    /// side's share *is* the fraction. The fade divides opacity rather than area and reads the
    /// other way round, since its fraction is the new side's alpha. The number is turned into a
    /// share here so the captions can share one ramp instead of each mode inking its own.
    private var visibleShares: (old: CGFloat, new: CGFloat) {
        guard isScrubbable else { return (Self.balancedShare, Self.balancedShare) }
        switch effectiveMode {
        case .wipeHorizontal, .wipeVertical:
            return (fraction, 1 - fraction)
        case .fade:
            return (1 - fraction, fraction)
        case .difference, .sideBySide:
            return (Self.balancedShare, Self.balancedShare)
        }
    }

    /// The share a caption is inked at when neither side is showing more than the other: the
    /// static modes, and a scrub held at the middle.
    private static let balancedShare: CGFloat = 0.5

    /// One ramp for every caption, so neither side is inked as the one that matters: a title is
    /// as present as its picture is. Held at the middle the two match exactly, and the ramp's
    /// midpoint is the tier the captions used to be written in; scrubbed either way, the side
    /// being revealed comes forward and the side being covered recedes.
    ///
    /// It is what ties a name to the image beside it. Two titles inked by rank say which file
    /// is newer, which is not the question the surface is asking — the pair used to sit at fixed
    /// weights while the seam moved, so a fully covered image kept a caption as solid as the one
    /// filling the canvas.
    ///
    /// Bottoming out at `tertiary` rather than fading to nothing: a name scrubbed out of view is
    /// still the answer to what is *not* being looked at.
    private func captionInk(showing share: CGFloat) -> NSColor {
        let ramp = ImageCompareLayout.clamped(share)
        return Design.Text.tertiary.blended(withFraction: ramp, of: Design.Text.label)
            ?? Design.Text.label
    }

    /// Where the top band divides between the two titles.
    ///
    /// The horizontal wipe divides at its seam, so the two names hinge on the handle and each
    /// keeps to the pixels on its own side of it. Every other mode divides at the middle: the
    /// fade stacks its sides rather than splitting the canvas, so there is nothing on the
    /// picture for a moving divide to point at.
    private func captionSplit(in layout: ImageCompareLayout) -> CGFloat {
        guard effectiveMode == .wipeHorizontal else { return layout.captions.top.midX }
        return ImageCompareLayout.seam(
            in: layout.placement.canvasRect, mode: effectiveMode, fraction: fraction
        )
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

    /// Two captions in one band, divided at `split` with half the gap either side of it, so a
    /// long title truncates rather than running into the one opposite.
    ///
    /// A slot may come out empty, which is the point of dividing at the seam: the side has been
    /// scrubbed off the canvas, and its name goes with it rather than hanging over pixels that
    /// belong to the other image.
    private func halves(
        of band: CGRect,
        splitAt split: CGFloat? = nil
    ) -> (leading: CGRect, trailing: CGRect) {
        let gap = Design.Spacing.medium / 2
        let divide = min(max(split ?? band.midX, band.minX), band.maxX)
        let leadingWidth = max(0, divide - gap - band.minX)
        let trailingWidth = max(0, band.maxX - divide - gap)
        return (
            CGRect(x: band.minX, y: band.minY, width: leadingWidth, height: band.height),
            CGRect(
                x: band.maxX - trailingWidth, y: band.minY,
                width: trailingWidth, height: band.height
            )
        )
    }

    /// The part of a band that lies over one canvas — how a side-by-side caption stays over the
    /// image it names instead of over the pair.
    private func slot(over canvas: CGRect, in band: CGRect) -> CGRect {
        CGRect(x: canvas.minX, y: band.minY, width: canvas.width, height: band.height)
    }

    /// One line of caption, a margin in from the outer edge of its band — flush, it sat on the
    /// canvas's own focus ring — with the rest of the band, the gap, between it and the
    /// picture. Sideways the slot is clamped a margin inside the surface for the same reason:
    /// the band hugs the picture, and where the picture reaches the bounds the ring is there
    /// too. Truncating rather than wrapping: the line is one line high, and
    /// `NSString.draw(in:)` wraps by default, which would draw the second word over the pixels
    /// the band exists to keep clear.
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
        let margin = ImageCompareDefaults.captionMargin
        let leading = max(slot.minX, bounds.minX + margin)
        let trailing = min(slot.maxX, bounds.maxX - margin)
        guard trailing - leading >= minimumCaptionWidth else { return }
        let line = min(captionLineHeight, max(0, slot.height - margin))
        (text as NSString).draw(
            in: CGRect(
                x: leading,
                y: edge == .top ? slot.minY + margin : slot.maxY - line - margin,
                width: trailing - leading,
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
