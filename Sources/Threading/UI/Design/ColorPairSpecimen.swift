import AppKit

// MARK: - Color Pair Specimen

/// Two colours shown touching, with a type specimen drawn in the first over the second.
///
/// It answers the one question a pair of hex values cannot answer at a glance: *are these
/// actually the same colour?* `#505050` against `#464646` reads as two different values in a
/// sentence and as one flat field on screen, which is exactly the complaint — and the complaint
/// is much easier to believe when the two fields are next to each other.
///
/// **Nothing is drawn between the halves, deliberately.** A divider would be a seam the eye finds
/// whether or not the colours differ, and the seam is the whole measurement here: two adjacent
/// fields with no rule between them is the most sensitive comparison the eye makes, so a pair
/// that still looks like one block *is* one block as far as any reader is concerned. The outline
/// around the pill is what keeps the shape legible when that happens.
///
/// The glyphs say which half is which without a caption: they are drawn in the ink colour over
/// the ground colour, so a specimen of a working pair is readable and a specimen of the pair this
/// component exists for is blank. Their letterforms are chrome typography rather than the
/// terminal's own font — this is a swatch showing colour, not a screenshot claiming to reproduce
/// a program's output.
///
/// The colours are **program colours**, passed in as resolved values rather than read from a
/// `Design` role. That is the one case where a component may hold a literal colour: it is
/// reporting one, not choosing one. Everything the component chooses — its outline, its ink when
/// it has no pair to show, its typography — still comes from the theme, and follows a live
/// switch.
@MainActor
final class ColorPairSpecimenView: NSView, ThemedComponent {

    // MARK: - Properties

    private(set) var inkColor: NSColor
    private(set) var groundColor: NSColor
    private let caption: String?
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    /// `accessibilityLabel` is required rather than derived: the component sees two colours, and
    /// only the caller knows what they *are* — which of them is text, which is background, and
    /// under what circumstances the reader is being shown them.
    ///
    /// `caption` is not decoration. The case this component exists for draws *nothing* — the
    /// specimen goes as blank as the run it is reporting — and an unlabelled empty rounded box in
    /// a row of controls does not read as a colour sample, it reads as a text field. Two words
    /// above it say what the reader is looking at, including when what they are looking at is the
    /// absence. A swatch already sitting under its own heading passes `nil`.
    init(ink: NSColor, ground: NSColor, caption: String? = nil, accessibilityLabel: String) {
        inkColor = ink
        groundColor = ground
        self.caption = caption
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
        // A specimen is evidence, not a control: it never stretches to fill the room a row has
        // left over, and never gives up its own size to a sentence beside it.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier(ColorPairSpecimenDefaults.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Replaces the pair without replacing the view, so a host holding a stable identity can
    /// re-point a specimen at a new finding.
    func setPair(ink: NSColor, ground: NSColor, accessibilityLabel: String) {
        inkColor = ink
        groundColor = ground
        setAccessibilityLabel(accessibilityLabel)
        needsDisplay = true
    }

    /// Where the pair itself is drawn: the whole view when there is no caption, and the row under
    /// it when there is. Readable so a test measures the colours where they actually are rather
    /// than assuming the component is all swatch.
    var pairRect: NSRect {
        let size = NSSize(
            width: ColorPairSpecimenDefaults.inkWidth + ColorPairSpecimenDefaults.groundWidth,
            height: ColorPairSpecimenDefaults.height
        )
        return NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: 0,
            width: size.width,
            height: min(size.height, bounds.height)
        )
    }

    // MARK: - Drawing

    override var intrinsicContentSize: NSSize {
        let pair = NSSize(
            width: ColorPairSpecimenDefaults.inkWidth + ColorPairSpecimenDefaults.groundWidth,
            height: ColorPairSpecimenDefaults.height
        )
        guard let captionText else { return pair }
        let size = captionText.size()
        return NSSize(
            width: max(pair.width, size.width.rounded(.up)),
            height: pair.height + ColorPairSpecimenDefaults.captionGap + size.height.rounded(.up)
        )
    }

    /// Built at read time rather than stored, so a live theme switch takes its face and its ink
    /// with it — the reason `SearchMatchLabel` rebuilds rather than holding an attributed string.
    private var captionText: NSAttributedString? {
        caption.map {
            NSAttributedString(
                string: $0,
                attributes: [
                    .font: Design.Typography.caption(),
                    .foregroundColor: Design.Text.tertiary
                ]
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        drawCaption()

        let edge = Design.Radius.controlBorder
        let body = pairRect.insetBy(dx: edge / 2, dy: edge / 2)
        let radius = Design.Radius.control(fitting: body.size)
        let outline = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()

        // Proportional rather than fixed, so the two halves keep their relationship if a theme's
        // border weight or a host's constraint gives the specimen a different size than it asked
        // for. The ink half is the narrower one: it is a colour, while the ground half is a
        // colour *and* the surface the glyphs have to sit on.
        let inkFraction = ColorPairSpecimenDefaults.inkWidth
            / (ColorPairSpecimenDefaults.inkWidth + ColorPairSpecimenDefaults.groundWidth)
        let split = (body.width * inkFraction).rounded()

        inkColor.setFill()
        NSRect(x: body.minX, y: body.minY, width: split, height: body.height).fill()
        groundColor.setFill()
        NSRect(
            x: body.minX + split,
            y: body.minY,
            width: max(0, body.width - split),
            height: body.height
        ).fill()

        drawSpecimenGlyphs(
            in: NSRect(
                x: body.minX + split,
                y: body.minY,
                width: max(0, body.width - split),
                height: body.height
            )
        )

        NSGraphicsContext.restoreGraphicsState()

        // Stroked last and outside the clip, so it survives both fills — including the case the
        // component exists for, where the two of them are the same colour and the outline is the
        // only thing saying anything is there at all.
        Design.Surface.border.setStroke()
        outline.lineWidth = edge
        outline.stroke()
    }

    // MARK: - Private Methods

    /// Centred over the swatch, in the band's quietest ink. It sits above rather than beside so
    /// the unit stays narrow: the sentence it is evidence for is the half of the band that has to
    /// give way, and it should give way as little as possible.
    private func drawCaption() {
        guard let captionText else { return }
        let size = captionText.size()
        captionText.draw(
            at: NSPoint(
                x: ((bounds.width - size.width) / 2).rounded(),
                y: (bounds.maxY - size.height).rounded()
            )
        )
    }

    private func drawSpecimenGlyphs(in rect: NSRect) {
        let font = Design.Typography.code()
        let text = NSAttributedString(
            string: ColorPairSpecimenDefaults.specimen,
            attributes: [.font: font, .foregroundColor: inkColor]
        )
        let size = text.size()
        guard size.width <= rect.width else { return }
        text.draw(
            at: NSPoint(
                x: (rect.midX - size.width / 2).rounded(),
                y: (rect.midY - size.height / 2).rounded()
            )
        )
    }
}

// MARK: - Color Pair Specimen Defaults

@MainActor
enum ColorPairSpecimenDefaults {

    /// **Clearly smaller than the controls beside it, not nearly the same.** The first size drawn
    /// here was 60×22 against a ~30pt button, and it read as a mistake — close enough to the
    /// button's proportions to look like it was trying to be one, and on a collapsed pair it drew
    /// as a wide, bordered, empty rounded rectangle in a row of controls, which is a text field.
    /// A swatch is furniture of a different order from a button, so it is sized like a mark: a
    /// tab icon tall, and rounded enough at that height that nothing about it invites a click.
    static let height: CGFloat = Design.Size.tabIconSlot

    /// Wide enough to be a colour rather than a line.
    static let inkWidth: CGFloat = Design.Size.tabIconSlot

    /// Wide enough for the specimen glyphs with air on both sides.
    static let groundWidth: CGFloat = Design.Size.tabIconSlot + Design.Spacing.small

    /// Between the caption and the swatch it names. One step: any more and the two stop reading
    /// as one thing.
    static let captionGap: CGFloat = Design.Spacing.hairline

    /// The type specimen: two letterforms with and without an ascender, which is enough shape to
    /// tell "text I cannot read" from "an empty swatch". Not copy — no locale changes what a
    /// specimen of a typeface's ink looks like.
    static let specimen = "Aa"

    static let identifier = "color.pair.specimen"
}
