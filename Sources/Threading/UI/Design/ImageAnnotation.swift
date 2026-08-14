import AppKit

// MARK: - Image Annotation

/// One numbered mark a person put on a picture, and the sentence it stands for.
///
/// **The point is normalized into the image's own space** (0…1, origin top-left), never a view
/// coordinate. A mark is made on a preview scaled to fit a column, read again in the fullscreen
/// inspector at 400% with a pan offset, drawn into a flattened copy at the file's real pixel
/// size, and quoted as a coordinate in prose. Those are four different rectangles for the same
/// mark; storing any one of them makes the other three a conversion nobody remembers to do, and
/// a resized sheet would move the pins off the thing they were pointing at.
struct ImageAnnotation: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 0…1 in the image's own space, origin top-left.
    var point: CGPoint
    var note: String

    init(id: UUID = UUID(), point: CGPoint, note: String = "") {
        self.id = id
        self.point = point
        self.note = note
    }
}

/// The pin's geometry, which is **`BrowserAnnotationOverlay`'s geometry**.
///
/// That surface already drops numbered accent pins on live content, and a second numbered mark
/// with its own diameter, ring and number face would be two annotation vocabularies in one app —
/// the thing the design system exists to prevent. Same chip height, same border weight, same
/// accent fill with the ground stroked around it, same top-most-wins hit test.
@MainActor
enum ImageAnnotationDefaults {
    /// The cap, and it is a real one. Every annotation is a text field in a rail and a pin drawn
    /// over the picture, so the list is externally sized in the [Scaling Gate](../../../CLAUDE.md)
    /// sense — a click makes one. Twenty is far past any report anyone has written and far short
    /// of a rail that has to virtualize; the affordance simply stops offering to add.
    static let maximumCount = 20

    static let pinDiameter: CGFloat = Design.Size.chipHeight

    /// Computed, not stored, for the reason the browser overlay records: a `static let` resolves
    /// once and keeps the border weight of whichever theme happened to be current at first draw,
    /// for the life of the process.
    static var pinBorderWidth: CGFloat { Design.Radius.border }

    /// How near a pin's centre counts as hitting it, over and above its own radius.
    static let pinHitSlop: CGFloat = Design.Spacing.tight

    /// The pin drawn into a flattened copy, as a fraction of the smaller image dimension: a mark
    /// on a 4K capture must not be a dot, and a mark on a 200-point icon must not be the icon.
    /// Applied as a *scale on the drawing context* rather than as a second set of measurements,
    /// so the flattened pin is the same pin — ring weight, number face and all — enlarged.
    static let flattenedPinFraction: CGFloat = 0.045
    static let flattenedPinMinimumScale: CGFloat = 1
    static let flattenedPinMaximumScale: CGFloat = 4
}

// MARK: - Geometry

/// Where a mark is, in whichever rectangle the caller is drawing the picture into.
///
/// Every conversion in the feature goes through here, so a pin drawn on the report sheet, a pin
/// drawn in the zoomed inspector and a pin burned into a flattened PNG cannot disagree about
/// where the user clicked.
@MainActor
enum ImageAnnotationGeometry {

    /// The view point a normalized mark sits at, given the rectangle the image occupies.
    ///
    /// `isFlipped` is the caller's own answer about its coordinate space, not a guess: the
    /// inspector's canvas is flipped and `ThemedImagePreview`'s host is not, and a mark placed
    /// with the wrong assumption lands mirrored across the horizontal — which reads as "the pins
    /// are roughly right" until somebody marks a corner.
    static func viewPoint(
        for annotation: ImageAnnotation,
        in imageRect: NSRect,
        isFlipped: Bool
    ) -> NSPoint {
        let x = imageRect.minX + imageRect.width * annotation.point.x
        let fromTop = imageRect.height * annotation.point.y
        return NSPoint(
            x: x,
            y: isFlipped ? imageRect.minY + fromTop : imageRect.maxY - fromTop
        )
    }

    /// The normalized mark a click lands on, or nil when the click missed the picture.
    ///
    /// Clamped rather than merely rejected at the edges: a click one point outside a rectangle
    /// whose size was floored by the fitting maths is a click on the picture as far as the user
    /// is concerned, and refusing it makes the last row of pixels unmarkable.
    static func normalizedPoint(
        for viewPoint: NSPoint,
        in imageRect: NSRect,
        isFlipped: Bool
    ) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        guard imageRect.insetBy(dx: -1, dy: -1).contains(viewPoint) else { return nil }

        let x = (viewPoint.x - imageRect.minX) / imageRect.width
        let fromTop = isFlipped
            ? (viewPoint.y - imageRect.minY)
            : (imageRect.maxY - viewPoint.y)
        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(fromTop / imageRect.height, 0), 1)
        )
    }

    /// Which pin a point is on, searched from the last drawn to the first so the mark on top is
    /// the mark you hit — two pins overlapping is common on a dense screenshot.
    static func annotationID(
        at viewPoint: NSPoint,
        among annotations: [ImageAnnotation],
        in imageRect: NSRect,
        isFlipped: Bool
    ) -> ImageAnnotation.ID? {
        let reach = ImageAnnotationDefaults.pinDiameter / 2 + ImageAnnotationDefaults.pinHitSlop
        return annotations.reversed().first { annotation in
            let centre = Self.viewPoint(for: annotation, in: imageRect, isFlipped: isFlipped)
            return hypot(centre.x - viewPoint.x, centre.y - viewPoint.y) <= reach
        }?.id
    }

    /// The mark in the image's own pixels, which is what a report quotes and what a person
    /// measuring the PNG can check.
    static func imagePoint(for annotation: ImageAnnotation, imageSize: NSSize) -> CGPoint {
        CGPoint(
            x: (annotation.point.x * imageSize.width).rounded(),
            y: (annotation.point.y * imageSize.height).rounded()
        )
    }
}

// MARK: - Drawing

/// Draws the numbered pins, in the one place both the preview and the zoomed canvas call.
@MainActor
enum ImageAnnotationMarks {

    /// One-based, because the rail counts from one and a report that says "annotation 0" reads
    /// as a bug in the report.
    static func label(forIndex index: Int) -> String { String(index + 1) }

    /// A filled accent disc with the ground stroked around it, so the mark survives being
    /// dropped on a screenshot of this very app — where the colour under it may be the accent
    /// itself. The selected pin doubles its ring rather than changing colour: Differentiate
    /// Without Colour takes a tint away and leaves a shape.
    static func draw(
        _ annotations: [ImageAnnotation],
        in imageRect: NSRect,
        isFlipped: Bool,
        selected: ImageAnnotation.ID?,
        scale: CGFloat = 1
    ) {
        guard !imageRect.isEmpty else { return }
        for (index, annotation) in annotations.enumerated() {
            let centre = ImageAnnotationGeometry.viewPoint(
                for: annotation,
                in: imageRect,
                isFlipped: isFlipped
            )
            draw(
                label: label(forIndex: index),
                at: centre,
                isSelected: annotation.id == selected,
                scale: scale
            )
        }
    }

    /// One pin, centred on a point in the current context.
    ///
    /// `scale` enlarges the whole mark through the graphics context rather than through a second
    /// set of measurements — the flattened copy of a 4K screenshot needs a bigger pin, not a
    /// differently proportioned one, and typography here comes from a semantic role that has no
    /// size to pass anyway.
    static func draw(
        label: String,
        at centre: NSPoint,
        isSelected: Bool,
        scale: CGFloat = 1
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if scale != 1 {
            let transform = NSAffineTransform()
            transform.translateX(by: centre.x, yBy: centre.y)
            transform.scale(by: scale)
            transform.translateX(by: -centre.x, yBy: -centre.y)
            transform.concat()
        }

        let diameter = ImageAnnotationDefaults.pinDiameter
        let rect = NSRect(
            x: centre.x - diameter / 2,
            y: centre.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        let disc = NSBezierPath(ovalIn: rect)
        Design.Surface.accent.setFill()
        disc.fill()
        Design.Surface.ground.setStroke()
        disc.lineWidth = ImageAnnotationDefaults.pinBorderWidth * (isSelected ? 2 : 1)
        disc.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.numericDetail(weight: .semibold),
            .foregroundColor: Design.Text.selected
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: (rect.midX - size.width / 2).rounded(.down),
                y: (rect.midY - size.height / 2).rounded(.down)
            ),
            withAttributes: attributes
        )
    }
}

// MARK: - Flattening

/// The annotated copy that goes to an agent.
///
/// A picture with the marks drawn into it is the one form of "I mean *this* bit" that survives
/// every transport: an attachment path, a pasted image, a transcript, a person reading over a
/// shoulder. The coordinates go in the prose beside it, because a flattened pin says where and
/// only the sentence says what.
@MainActor
enum ImageAnnotationFlattening {

    /// Draws the pins into a copy at the image's own size. Returns nil for an empty image, and
    /// the original for an empty annotation list — there is nothing to burn in, and re-encoding
    /// a screenshot to change nothing costs quality for no reason.
    static func flattened(_ image: NSImage, annotations: [ImageAnnotation]) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        guard !annotations.isEmpty else { return image }

        let size = image.size
        let wanted = min(size.width, size.height) * ImageAnnotationDefaults.flattenedPinFraction
        let scale = min(
            max(
                wanted / ImageAnnotationDefaults.pinDiameter,
                ImageAnnotationDefaults.flattenedPinMinimumScale
            ),
            ImageAnnotationDefaults.flattenedPinMaximumScale
        )

        let copy = NSImage(size: size)
        copy.lockFocus()
        defer { copy.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))

        // `lockFocus` gives an unflipped context, so the marks are placed with the same rule the
        // preview uses for an unflipped host.
        ImageAnnotationMarks.draw(
            annotations,
            in: NSRect(origin: .zero, size: size),
            isFlipped: false,
            selected: nil,
            scale: scale
        )
        return copy
    }

    /// Writes the flattened copy beside the original, named after it.
    ///
    /// A sibling name rather than a UUID: the path is the first thing an agent reads, and
    /// `Screenshot 2026-08-14-annotated.png` says what it is before the picture is even opened.
    static func writeFlattenedPNG(
        _ image: NSImage,
        annotations: [ImageAnnotation],
        basedOn original: URL?,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        guard let flattened = flattened(image, annotations: annotations),
              let tiff = flattened.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let stem = original?.deletingPathExtension().lastPathComponent ?? "annotated-image"
        let name = original == nil ? stem : stem + "-annotated"
        let url = directory.appendingPathComponent(name).appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            ThreadingLogger.storage.error(
                "Annotated image could not be written: \(String(describing: type(of: error)), privacy: .public)"
            )
            return nil
        }
    }
}

// MARK: - Prose

/// What the annotations say, as text, for a report body or a composer.
@MainActor
enum ImageAnnotationSummary {

    /// A numbered list carrying each mark's point in the image's own pixels.
    ///
    /// Both halves are load-bearing and were chosen together: the flattened picture shows
    /// *where*, and a coordinate lets a reader who is measuring the PNG — an agent counting
    /// pixels, a person checking a frame — land on the same spot without eyeballing a disc.
    /// An annotation nobody wrote a note for still counts; the mark itself was the statement.
    static func lines(_ annotations: [ImageAnnotation], imageSize: NSSize) -> [String] {
        annotations.enumerated().map { index, annotation in
            let point = ImageAnnotationGeometry.imagePoint(
                for: annotation,
                imageSize: imageSize
            )
            let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
            // Not localized, and deliberately: this is a coordinate in a report body, read by an
            // agent and by whoever is measuring the PNG. A translated "at" would change the one
            // part of the report that has to be machine-readable in every language.
            let position = "\(ImageAnnotationMarks.label(forIndex: index)) "
                + "at (\(Int(point.x)), \(Int(point.y)))"
            return note.isEmpty ? position : position + " — " + note
        }
    }

    /// The same list under its own heading, or nothing at all when no mark was made. Empty
    /// rather than an empty section: a report that carries "Annotations" and nothing under it
    /// says the user tried and failed to mark something.
    static func section(_ annotations: [ImageAnnotation], imageSize: NSSize) -> String? {
        let rows = lines(annotations, imageSize: imageSize)
        guard !rows.isEmpty else { return nil }
        return ([ImageAnnotationStrings.heading] + rows).joined(separator: "\n")
    }
}

// MARK: - Strings

@MainActor
enum ImageAnnotationStrings {
    /// Markdown structure inside a report body rather than copy on a screen, so it stays put
    /// while the sentences around it translate. The caption below is the on-screen word.
    static let heading = "## Annotations"

    static var caption: String { L10n.string("Annotations") }
    static var addHint: String { L10n.string("Click the image to mark a place") }
    static var fullCount: String {
        L10n.format("That is the most marks one report carries (%lld).",
                    ImageAnnotationDefaults.maximumCount)
    }
    static var removeTitle: String { L10n.string("Remove") }

    static func notePlaceholder(index: Int) -> String {
        L10n.format("What is wrong at mark %@?", ImageAnnotationMarks.label(forIndex: index))
    }

    static func accessibilityLabel(index: Int) -> String {
        L10n.format("Annotation %@", ImageAnnotationMarks.label(forIndex: index))
    }

    static var imageAccessibilityHelp: String {
        L10n.string("Click to add a numbered mark. Press Space to open the image full size.")
    }
}
