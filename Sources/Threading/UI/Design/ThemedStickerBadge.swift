import AppKit

// MARK: - Themed Sticker Badge

/// A count or short label set as a price sticker — what a material stating
/// `BadgeStyle.sticker` shows where the app would otherwise set a quiet count or pill.
///
/// The plate leans, so it cannot be a styled label: AppKit owns a layer-backed view's geometry,
/// and a label's own layer would carry the plate in front of its text rather than behind it.
/// The badge draws plate and text together in one rotated pass instead, and reports the rotated
/// plate's bounding box as its intrinsic size, so a host lays it out like any other trailing
/// mark. The colours are a sticker's, not the chrome's: the negative status hue with white
/// type and a white die-cut rim, which is what makes it read as a deal on any ground.
final class ThemedStickerBadge: NSView, ThemedComponent {

    // MARK: - Properties

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private var themeRedraw: ThemeRedraw?

    private enum Layout {
        /// Degrees the plate leans, counter-clockwise, the way a sticker lands when it is
        /// slapped on rather than placed.
        static let tilt: CGFloat = 7
        static let horizontalPadding: CGFloat = Design.Spacing.tight
        static let verticalPadding: CGFloat = Design.Spacing.hairline
        static let cornerRadius: CGFloat = Design.Spacing.tight
        /// The die-cut edge. Wide enough to separate the plate from a red or orange ground.
        static let rimWidth: CGFloat = 1.5
    }

    // MARK: - Initialization

    init(text: String = "") {
        self.text = text
        super.init(frame: .zero)
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Whether the current material sets badges as stickers. Hosts ask this to choose between
    /// their quiet mark and this badge.
    static func isWorn(in appearance: NSAppearance) -> Bool {
        AppThemePalette.current.material(for: appearance).badgeStyle == .sticker
    }

    override var intrinsicContentSize: NSSize {
        let plate = plateSize
        let angle = Layout.tilt * .pi / 180
        return NSSize(
            width: ceil(plate.width * cos(angle) + plate.height * sin(angle) + Layout.rimWidth),
            height: ceil(plate.width * sin(angle) + plate.height * cos(angle) + Layout.rimWidth)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: Layout.tilt)
        transform.concat()

        let size = plateSize
        let plate = NSBezierPath(
            roundedRect: NSRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ),
            xRadius: Layout.cornerRadius,
            yRadius: Layout.cornerRadius
        )
        Design.Status.negative.setFill()
        plate.fill()
        NSColor.white.setStroke()
        plate.lineWidth = Layout.rimWidth
        plate.stroke()

        let attributes = textAttributes
        let ink = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: -ink.width / 2, y: -ink.height / 2),
            withAttributes: attributes
        )
    }

    override func accessibilityValue() -> Any? { text }

    // MARK: - Private Methods

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Design.Typography.numericDetail(weight: .bold),
            .foregroundColor: NSColor.white
        ]
    }

    private var plateSize: NSSize {
        let ink = (text as NSString).size(withAttributes: textAttributes)
        return NSSize(
            width: ceil(ink.width) + Layout.horizontalPadding * 2,
            height: ceil(ink.height) + Layout.verticalPadding * 2
        )
    }
}
