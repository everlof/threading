import AppKit

// MARK: - Annotated Image View

/// A picture you can point at: the image fitted to whatever room it is given, with numbered pins
/// where the user clicked and a live tie to the field that names each one.
///
/// `ThemedImagePreview`'s sibling rather than a mode on it. That control's whole gesture is *one
/// press opens the inspector* — click, Space, force click and VoiceOver's press all land on the
/// same action — and a click that sometimes drops a pin instead would make the most-used image
/// affordance in the app conditional on a flag its call sites cannot see. Here the click is the
/// mark and the **keyboard** opens the picture full size, which is the inverse contract stated
/// once rather than a branch inside the shared one.
///
/// The fitting maths is `ThemedImagePreview.fittedRect` itself, not a copy: a pin lands where it
/// was put only if this view and that one agree, to the point, about where the picture is.
final class AnnotatedImageView: ThemedControl {

    // MARK: - Properties

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            needsDisplay = true
        }
    }

    /// The file behind the picture. Supplies the fullscreen inspector its item, and names the
    /// flattened copy an annotated image is written to.
    var fileURL: URL?

    /// The marks, in the order they were made — which is the order they are numbered.
    var annotations: [ImageAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            if let selectedAnnotationID,
               !annotations.contains(where: { $0.id == selectedAnnotationID }) {
                self.selectedAnnotationID = nil
            }
            needsDisplay = true
        }
    }

    /// The mark drawn lit. Set by this view on a click, and by the rail when a note field takes
    /// focus — which is the whole of "the field lights up its own pin".
    var selectedAnnotationID: ImageAnnotation.ID? {
        didSet {
            guard selectedAnnotationID != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether a click marks the picture. False leaves an ordinary, still-inspectable image.
    var isAnnotating = true {
        didSet {
            guard isAnnotating != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// A click on bare picture. The host owns the list, because the same list is being edited by
    /// a rail of fields and, when the picture is opened full size, by a second view.
    var onAddAnnotation: ((CGPoint) -> Void)?

    /// A click on an existing pin, or on nothing.
    var onSelectAnnotation: ((ImageAnnotation.ID?) -> Void)?

    /// Space, Return, or VoiceOver's press: open the picture at full size.
    var onOpenFullSize: (() -> Void)?

    /// Where the picture is drawn: scaled to fit, never up, and **centred in both directions**.
    ///
    /// `ThemedImagePreview` pins to the top instead, and is right to: it fills a pane that is
    /// taller than most pictures, and a picture floating in the middle leaves dead space between
    /// it and the header the eye is already at. Here the view *is* the column — it stretches to
    /// the sheet's full height — so top-pinning left a band of ground under the capture as tall
    /// as a third of it, with the caption stranded at the bottom of the empty part.
    ///
    /// The scale is `ThemedImagePreview`'s own, so the two views disagree about placement and
    /// never about size.
    var imageRect: NSRect {
        guard let image else { return .zero }
        let fitted = ThemedImagePreview.fittedRect(for: image.size, in: bounds)
        return NSRect(
            x: fitted.minX,
            y: bounds.minY + ((bounds.height - fitted.height) / 2).rounded(.down),
            width: fitted.width,
            height: fitted.height
        )
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(L10n.string("Screenshot"))
        setAccessibilityHelp(ImageAnnotationStrings.imageAccessibilityHelp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    /// States no size, for `ThemedImagePreview`'s reason: a picture's own dimensions are not an
    /// opinion the column holding it should inherit.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Drawing

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

        // Deliberately outside the clip: a pin on the very edge of the picture is exactly the
        // one somebody is complaining about, and half a disc shaved off by the silhouette is the
        // mark disagreeing with the click that made it.
        ImageAnnotationMarks.draw(
            annotations,
            in: target,
            isFlipped: isFlipped,
            selected: selectedAnnotationID
        )

        drawKeyboardFocus(around: shape, keepingEdge: 0)
    }

    // MARK: - Pointing

    override var acceptsFirstResponder: Bool { isEnabled && image != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, image != nil else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let target = imageRect

        // A click on an existing pin selects it rather than stacking a second mark under the
        // pointer. Found by marking the same control twice: two discs at one place, one number
        // readable, and a rail with a field nobody could tell apart from the one above it.
        if let hit = ImageAnnotationGeometry.annotationID(
            at: point,
            among: annotations,
            in: target,
            isFlipped: isFlipped
        ) {
            selectedAnnotationID = hit
            onSelectAnnotation?(hit)
            return
        }

        guard isAnnotating,
              let normalized = ImageAnnotationGeometry.normalizedPoint(
                  for: point,
                  in: target,
                  isFlipped: isFlipped
              ) else {
            onSelectAnnotation?(nil)
            return
        }
        onAddAnnotation?(normalized)
    }

    override func performPrimaryAction() -> Bool {
        guard isEnabled, image != nil, let onOpenFullSize else { return false }
        onOpenFullSize()
        return true
    }

    /// The trackpad's preview gesture follows the keyboard rather than the click, because it is
    /// the *look at this properly* gesture on every other image in the app.
    override func quickLook(with event: NSEvent) {
        guard performPrimaryAction() else {
            super.quickLook(with: event)
            return
        }
    }

    /// The crosshair while a mark can be placed, the arrow otherwise. See `PointerClaiming`.
    override var restingPointer: NSCursor? {
        isEnabled && image != nil && isAnnotating ? .crosshair : .arrow
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}
