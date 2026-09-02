import AppKit

/// A non-menu chooser presented from a chip. The chip owns the held/pressed state and dismissal
/// bookkeeping; the session owns only its presentation surface.
@MainActor
public protocol ChipChoicePresentationSession: AnyObject {
    func dismissChipChoicePresentation()
}

/// Geometry and period indicator ink shared by both chooser implementations.
///
/// `ChipView` serves the composer while `ThemedPopUp` serves forms and extension UI; a retro
/// material cannot acquire two different arrow wells merely because the caller used the other
/// semantic wrapper.
@MainActor
public enum ClassicChoiceDrawing {
    public static let edge: CGFloat = 2
    public static let arrowWidth: CGFloat = 18
    public static let textInset: CGFloat = 5

    /// The Aqua chooser's own corner. Tiger draws its small pop-up a step tighter than the push
    /// button beside it, so this is the chooser's measure rather than the material's control
    /// radius — and it is one measure for both chooser implementations, which is the point of
    /// this type.
    public static let aquaCornerRadius: CGFloat = 5

    public static func arrowRect(
        in bounds: NSRect,
        style: AppTheme.Material.ChoiceStyle
    ) -> NSRect {
        if style == .dropdown {
            return NSRect(
                x: bounds.maxX - edge - arrowWidth,
                y: edge,
                width: arrowWidth,
                height: max(0, bounds.height - edge * 2)
            )
        }
        return NSRect(
            x: bounds.maxX - arrowWidth,
            y: 0,
            width: arrowWidth,
            height: bounds.height
        )
    }

    public static func drawIntegratedSeparator(at x: CGFloat, in bounds: NSRect) {
        Design.Surface.bevelShadow.setFill()
        NSRect(x: x, y: 2, width: 1, height: max(0, bounds.height - 4)).fill()
        Design.Surface.bevelHighlight.setFill()
        NSRect(x: x + 1, y: 2, width: 1, height: max(0, bounds.height - 4)).fill()
    }

    /// The face inside an Aqua chooser's border — everything a well drawn to the trailing edge
    /// is allowed to cover.
    ///
    /// Both implementations put a one-point border on the control: `ThemedPopUp` strokes it,
    /// `ChipView` hands it to the layer, and either way it occupies the outermost point of the
    /// silhouette. The well belongs *inside* that, with the button's own corner.
    public static func aquaFace(in bounds: NSRect) -> ThemedSurface.Shape {
        let border = Design.Radius.controlBorder
        return ThemedSurface.Shape(
            rect: bounds.insetBy(dx: border, dy: border),
            radius: max(0, aquaCornerRadius - border)
        )
    }

    /// The Aqua chooser's plate: a silver capsule with a hairline border.
    ///
    /// Stroked here rather than applied to either implementation's layer, so the corner is one
    /// circular arc for both of them. See `ChipView.updateBackground` for what a layer border
    /// does to this radius instead.
    @discardableResult
    public static func drawAquaSurface(in bounds: NSRect) -> ThemedSurface.Shape {
        ThemedSurface.draw(
            bounds,
            fill: Design.Surface.controlResting,
            border: Design.Surface.border,
            radius: aquaCornerRadius
        )
    }

    /// The blue gel plate an Aqua pop-up wears at its trailing end.
    ///
    /// Clipped to the button's own face rather than filled square. A pop-up's well reaches the
    /// trailing edge, and the curve there belongs to the *button*: drawn as a rectangle it
    /// painted over both right corners and the border joining them, so the control ended in a
    /// hard blue block and read as cut off at the right. The clip is also what leaves the three
    /// outer edges to the border already around them; only the seam against the value is the
    /// well's own to draw.
    public static func drawAquaArrowWell(in rect: NSRect, face: ThemedSurface.Shape, pressed: Bool) {
        let leading = max(rect.minX, face.rect.minX)
        let well = NSRect(
            x: leading,
            y: face.rect.minY,
            width: max(0, face.rect.maxX - leading),
            height: face.rect.height
        )
        guard well.width > 0, well.height > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        face.path.addClip()
        let accent = Design.Surface.accent
        let bright = accent.blended(withFraction: pressed ? 0.36 : 0.63, of: .white) ?? accent
        let deep = accent.blended(withFraction: pressed ? 0.36 : 0.18, of: .black) ?? accent
        NSGradient(colors: [bright, accent, deep])?.draw(in: well, angle: -90)
        NSColor.white.withAlphaComponent(pressed ? 0.24 : 0.58).setFill()
        NSRect(
            x: well.minX + 1,
            y: well.maxY - 2,
            width: max(0, well.width - 2),
            height: 1
        ).fill()
        Design.Surface.border.withAlphaComponent(0.70).setFill()
        NSRect(x: well.minX, y: well.minY, width: 1, height: well.height).fill()
    }

    /// The ink a chooser's indicator is cut from.
    ///
    /// Every classic style but one draws its arrow on the control face, where the label colour is
    /// the answer. The Aqua pop-up draws it on the blue gel well, so the ink has to be measured
    /// against the accent instead — `Text.selected`, the tone this app already puts on a selected
    /// row. On Tiger's blue that measures to the same dark mark it was using; on a theme whose
    /// authored accent is dark it is the difference between an arrow and a smudge.
    public static func indicatorInk(for style: AppTheme.Material.ChoiceStyle) -> NSColor {
        style == .aquaPopup ? Design.Text.selected : Design.Text.label
    }

    public static func drawIndicator(
        _ style: AppTheme.Material.ChoiceStyle,
        in rect: NSRect,
        color: NSColor
    ) {
        color.setFill()
        switch style {
        case .chip:
            return
        case .dropdown, .popup:
            triangle(
                center: NSPoint(x: rect.midX, y: rect.midY - 1),
                width: 7,
                height: 4,
                pointsUp: false
            ).fill()
        case .doubleArrowPopup, .aquaPopup:
            triangle(
                center: NSPoint(x: rect.midX, y: rect.midY + 3),
                width: 5,
                height: 3,
                pointsUp: true
            ).fill()
            triangle(
                center: NSPoint(x: rect.midX, y: rect.midY - 3),
                width: 5,
                height: 3,
                pointsUp: false
            ).fill()
        case .cycle:
            horizontalTriangle(
                center: NSPoint(x: rect.midX + 1, y: rect.midY + 3),
                pointsRight: true
            ).fill()
            horizontalTriangle(
                center: NSPoint(x: rect.midX - 1, y: rect.midY - 3),
                pointsRight: false
            ).fill()
        }
    }

    private static func triangle(
        center: NSPoint,
        width: CGFloat,
        height: CGFloat,
        pointsUp: Bool
    ) -> NSBezierPath {
        let direction: CGFloat = pointsUp ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y + direction * height / 2))
        path.line(to: NSPoint(x: center.x - width / 2, y: center.y - direction * height / 2))
        path.line(to: NSPoint(x: center.x + width / 2, y: center.y - direction * height / 2))
        path.close()
        return path
    }

    private static func horizontalTriangle(
        center: NSPoint,
        pointsRight: Bool
    ) -> NSBezierPath {
        let direction: CGFloat = pointsRight ? 1 : -1
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + direction * 3, y: center.y))
        path.line(to: NSPoint(x: center.x - direction * 2, y: center.y + 2))
        path.line(to: NSPoint(x: center.x - direction * 2, y: center.y - 2))
        path.close()
        return path
    }
}

/// A flat pill that opens a menu.
///
/// The app's standard way to offer a choice. `NSPopUpButton` was the obvious control and
/// looks wrong beside this design: its bezel and full-size chevron read as a form field,
/// where a chip is meant to sit quietly next to the content it modifies.
///
/// **The pill is the hover, not the chip.** At rest a chip draws no plate at all: the answer it
/// is showing is content, and content on this surface is set in text — the rule `PageTitleView`
/// and every plain `ThemedButton` already keep, and the one a row of chips broke. Six filled
/// pills along the composer's footer read as six objects competing with the words above them,
/// and each one spent the contrast of a *surface* saying something a chevron already says. Under
/// the pointer — or while its menu is open, or while it holds the keyboard focus — the plate
/// rises, which is the moment "this is pressable" is the thing worth saying.
///
/// The frame keeps the padding the plate needs either way, so nothing moves when it appears and
/// a run of chips does not reflow under the pointer. That padding is what
/// `OpticalInsetProviding` reports: a row aligning by ink puts the chip's *text* on the margin
/// rather than the edge of a plate that is not drawn.
///
/// See `Design` for the vocabulary this belongs to.
public final class ChipView: ThemedControl, OpticalInsetProviding, ThemedMenuPresentationObserving {

    public enum HeightStyle {
        /// A compact chooser among other compact controls.
        case compact
        /// A chooser sharing a row with a single-line text field.
        case field

        fileprivate var value: CGFloat {
            switch self {
            case .compact: return Design.Size.choiceHeight
            case .field: return Design.Size.fieldHeight
            }
        }
    }

    // MARK: - Properties

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private let contentStack = NSStackView()
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var titleWidthConstraint: NSLayoutConstraint?
    private var configuredIcon: NSImage?
    private var appliedChoiceStyle: AppTheme.Material.ChoiceStyle?
    private var appliedChoiceHeight: CGFloat?

    /// The room between the chip's edge and its content, at rest and under the plate alike.
    ///
    /// A step tighter than the `Spacing.medium` a filled pill was built with. Ten points is what
    /// a *drawn* pill needs to hold its text clear of the curve at each end — and at rest there
    /// is no curve any more, so on a run of six chips it was eighty points of invisible air in
    /// the one row that had none to spare: the composer's footer overflowed a 720-point column
    /// and crushed the usage reading beside the send. The plate still reads at six, because it
    /// only ever appears under one chip at a time and the eye is already on it.
    public static let horizontalPadding = Design.Spacing.small

    /// One point, for the fraction AppKit's text cell needs and Auto Layout rounds away. See
    /// `intrinsicContentSize`.
    private static let titleRoundingAllowance: CGFloat = 1

    private var isPresentingMenu = false {
        didSet {
            updateBackground()
            needsDisplay = true
        }
    }
    private var menuSession: AnyObject?
    private var choicePresentationSession: (any ChipChoicePresentationSession)?
    private var heightConstraint: NSLayoutConstraint?

    public var heightStyle: HeightStyle = .compact {
        didSet {
            guard heightStyle != oldValue else { return }
            applyHeight()
        }
    }

    /// The height a `ControlRowView` this chip stands in has stated, which wins over the style's
    /// own. Nil everywhere else, which is every chip that is not in a row.
    ///
    /// Under `.compact` the two agree by construction — a row's compact height *is*
    /// `choiceHeight`, because the chooser is what a theme authors. It is `.field` rows that
    /// need this: there the chip stands beside a text field and takes the field's height, and
    /// that used to be a `heightStyle` each host had to remember to set.
    private var rowHeight: CGFloat?

    /// What this chip is actually drawn at.
    private var controlHeight: CGFloat { rowHeight ?? heightStyle.value }

    /// `NSTextField` lays out its alignment rectangle inside a slightly wider cell frame. The
    /// classic chooser draws its arrow outside Auto Layout, so reserving only the nominal text
    /// inset lets that private frame overhang enter the arrow well by a few points. Keep the
    /// overhang in the chooser's geometry contract instead of relying on a particular AppKit
    /// font or cell implementation to happen to fit. `NSStackView` places the integral cell
    /// frame one point beyond that reported inset, so the frame edge belongs here too.
    private var classicTitleTrailingOverhang: CGFloat {
        max(0, titleLabel.alignmentRectInsets.right) + 1
    }

    /// The integral frame width AppKit needs to draw the complete title. Text cells report
    /// fractional natural widths (`27.49` for “Auto” in OpenStep, for example), while stack
    /// layout may round the arranged frame down. The control's outer intrinsic width cannot
    /// repair that inner rounding after the fact, so a chooser states this minimum on the label
    /// itself. Its high (rather than required) priority still permits genuine row compression in
    /// a narrow window — the chip's own edge pins are required, so a real squeeze still wins.
    private var naturalTitleCellWidth: CGFloat {
        let font = titleLabel.font ?? Design.Typography.controlRegular()
        let stringWidth = titleLabel.stringValue.size(withAttributes: [.font: font]).width
        let probeBounds = NSRect(
            x: 0,
            y: 0,
            width: 10_000,
            height: max(controlHeight, titleLabel.intrinsicContentSize.height)
        )
        let cellDrawingInset: CGFloat
        let unboundedCellWidth: CGFloat
        if let cell = titleLabel.cell {
            cellDrawingInset = max(
                0,
                probeBounds.width - cell.titleRect(forBounds: probeBounds).width
            )
            unboundedCellWidth = cell.cellSize(forBounds: probeBounds).width
        } else {
            cellDrawingInset = 0
            unboundedCellWidth = 0
        }
        let intrinsicWidth = titleLabel.intrinsicContentSize.width
        let cellWidth = titleLabel.cell?.cellSize.width ?? 0
        return ceil(max(
            stringWidth + cellDrawingInset,
            intrinsicWidth > 0 && intrinsicWidth < 10_000 ? intrinsicWidth : 0,
            cellWidth > 0 && cellWidth < 10_000 ? cellWidth : 0,
            unboundedCellWidth > 0 && unboundedCellWidth < 10_000 ? unboundedCellWidth : 0
        ))
    }

    /// **Classic anatomies only**, and that restriction is load-bearing.
    ///
    /// A minimum on the label is a minimum the label keeps whatever the row wants: it is stated
    /// at `defaultHigh`, and every compression priority the composer hands its chips is in the
    /// 239–263 band, so on a modern chip it silently outranks all of them. Tried there once and
    /// the composer's column came out 626 points wide in a 496-point pane — the exact shape of
    /// the bug the label's own `defaultLow` resistance exists to prevent, arriving from the
    /// inside. The modern anatomy answers its rounding in `intrinsicContentSize` instead, where
    /// a row may still compress what it asked for.
    private func updateTitleWidthConstraint(for style: AppTheme.Material.ChoiceStyle) {
        titleWidthConstraint?.isActive = false
        titleWidthConstraint = nil
        // Which child absorbs the slack is the same question, answered the other way round per
        // anatomy. Past a modern chip's title there is nothing but padding, so the title should
        // take the fraction `titleRoundingAllowance` reserved — at the default 250 it merely ties
        // with `NSStackView`'s own hugging, a tie is settled by leaving the space unspent, and the
        // label kept the width Auto Layout had floored out of its fractional intrinsic: an
        // ellipsis a third of a point short of its own glyphs, inside a chip at full width.
        // A classic chooser must not, because the slack past *its* title is the arrow well, drawn
        // outside Auto Layout — a title willing to grow runs straight under the arrow.
        titleLabel.setContentHuggingPriority(
            style.isClassic ? .defaultLow : .defaultLow - 1,
            for: .horizontal
        )
        guard style.isClassic else { return }

        let constraint = titleLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: naturalTitleCellWidth
        )
        constraint.priority = .defaultHigh
        constraint.isActive = true
        titleWidthConstraint = constraint
    }

    /// Restates the height wherever it is held: the constraint, the intrinsic size, and the
    /// pill radius the background is drawn from — which is a function of the height, so a chip
    /// that resized without this kept the silhouette of the size it used to be.
    private func applyHeight() {
        heightConstraint?.constant = controlHeight
        invalidateIntrinsicContentSize()
        updateBackground()
    }

    /// Widens the chip to its full contents while hovered, so a label truncated to fit the row
    /// (`Default m…`) becomes readable. Held so it can be removed on exit.
    private var hoverWidthConstraint: NSLayoutConstraint?

    /// Choices to offer, rebuilt each time so the menu always reflects current state.
    public var itemsProvider: (() -> [ThemedMenuEntry])?

    /// Replaces only the choice surface while leaving this chip's appearance and layout intact.
    ///
    /// The callback receives the chip to anchor from and a dismissal callback that must be
    /// invoked exactly once when its transient surface closes. Returning nil falls back to the
    /// ordinary menu provider. Kept at the design boundary so a feature never intercepts AppKit
    /// mouse events or subclasses this control just to present different themed content.
    public var choicePresentationProvider: ((
        _ chip: ChipView,
        _ didDismiss: @escaping () -> Void
    ) -> (any ChipChoicePresentationSession)?)?

    /// The item currently represented, so callers can read the selection back.
    private(set) var selectedItem: ThemedMenuItem?

    /// Called after a menu item is chosen.
    public var onSelect: ((ThemedMenuItem) -> Void)?

    /// Replaces AppKit presentation in behavior tests. Returning a choice simulates selecting it.
    /// Production leaves this nil.
    public var menuPresentationOverride: ((ThemedMenuPresentation) -> ThemedMenuItem?)?

    public override var intrinsicContentSize: NSSize {
        // The row may compress a chooser, but it first needs an honest natural width to
        // compress *from*. Returning no width made `NSStackView` treat the classic chooser as
        // if its value cost no space: the row's spring absorbed hundreds of spare points while
        // the title stopped at the independently drawn arrow well. Every period popup then
        // clipped its last glyph beside an otherwise empty footer.
        //
        // Do not ask the pinned stack for `fittingSize` here. At initialization the chip has no
        // width, so the stack has already compressed its label to satisfy the chip's leading and
        // trailing constraints; using that compressed answer as the chip's intrinsic width is a
        // circular measurement. Sum the visible children's own natural widths instead.
        let visibleContent = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let contentWidth = visibleContent.enumerated().reduce(CGFloat.zero) { result, entry in
            let (index, view) = entry
            // The source string is the floor, while the text field's intrinsic width also
            // carries the cell's private drawing inset. A classic field needs that last couple
            // of points even when the glyphs themselves fit; omitting them makes AppKit choose
            // an ellipsis before the independently drawn arrow well.
            let alignmentWidth: CGFloat
            if view === iconView {
                alignmentWidth = Design.Symbol.control
            } else if view === chevronView {
                alignmentWidth = Design.Symbol.chevron
            } else if let field = view as? NSTextField {
                if field === titleLabel {
                    alignmentWidth = naturalTitleCellWidth
                } else {
                    let candidate = field.intrinsicContentSize.width
                    alignmentWidth = candidate > 0 && candidate < 10_000 ? candidate : 0
                }
            } else {
                let candidate = view.intrinsicContentSize.width
                // AppKit uses very large fitting values as an unconstrained sentinel. Never
                // turn one into window geometry if another arranged child is added later.
                alignmentWidth = candidate > 0 && candidate < 10_000 ? candidate : 0
            }
            // Auto Layout places a text field's alignment rectangle, while AppKit draws the
            // cell in its wider frame. Include both frame overhangs in the natural size; the
            // trailing one is otherwise free to reach into a classic arrow well.
            let width = alignmentWidth
                + max(0, view.alignmentRectInsets.left)
                + max(0, view.alignmentRectInsets.right)
            guard index > 0 else { return result + width }
            let previous = visibleContent[index - 1]
            let customSpacing = contentStack.customSpacing(after: previous)
            // `customSpacing(after:)` returns a very large sentinel when the arranged view has
            // no override. It is an instruction to use `spacing`, not a distance to add.
            let spacing = customSpacing == NSStackView.useDefaultSpacing
                ? contentStack.spacing
                : customSpacing
            return result + spacing + width
        }
        let outerWidth: CGFloat = if choiceStyle == .chip {
            // The `+1` is the same allowance the classic anatomy makes through
            // `classicTitleTrailingOverhang`, for the same reason: a text cell's natural width is
            // fractional and stack layout rounds the arranged frame down, so a title measured to
            // the point can still be handed a frame a fraction short of drawing it. At the
            // control face's medium weight the measurement happened to carry that point already;
            // dropping to regular took it away and `Claude Code · Everlof` started drawing as
            // `Claude Code · Everl…` inside a chip at its own full intrinsic width. Stated here
            // rather than as a minimum on the label, because an intrinsic width is something a
            // row may still compress and a `defaultHigh` minimum is not — see
            // `updateTitleWidthConstraint`.
            Self.horizontalPadding * 2 + Self.titleRoundingAllowance
        } else {
            ClassicChoiceDrawing.textInset * 2
                + ClassicChoiceDrawing.arrowWidth
                + classicTitleTrailingOverhang
        }
        return NSSize(width: ceil(contentWidth + outerWidth), height: controlHeight)
    }

    /// A neighbouring reading can align to the title's ink rather than the pill's geometric
    /// centre. The icon and chevron do not define a text baseline.
    public var contentFirstBaselineAnchor: NSLayoutYAxisAnchor { titleLabel.firstBaselineAnchor }

    public override var isEnabled: Bool {
        didSet { updateBackground() }
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    /// ThemeRedraw invalidates drawing, while a chooser style also changes which children take
    /// part and how much trailing room the independent arrow button owns.
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        let anatomyChanged = choiceStyle != appliedChoiceStyle
            || controlHeight != appliedChoiceHeight
        super.setNeedsDisplay(invalidRect)
        needsLayout = true
        // `AppThemeLibrary.apply` first re-resolves every recorded layer surface and then posts
        // the redraw event. When the new theme changes this control from a chip into a classic
        // chooser, that first pass necessarily re-applies the *old* chip recipe. Restate the
        // surface after resolving the new anatomy so a live switch gets the field/raised face
        // immediately rather than only after the next hover.
        if anatomyChanged {
            updateBackground()
        }
    }

    public override func layout() {
        updateChoiceStyleIfNeeded()
        super.layout()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            ThemedMenuPresenter.dismiss(menuSession)
            choicePresentationSession?.dismissChipChoicePresentation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // The resting tiers. `updateChipInk` owns them from here — stated once there so the
        // hover step and the starting state cannot drift apart.
        titleLabel.applyFont(.controlRegular)
        titleLabel.textColor = Design.Text.secondary
        titleLabel.lineBreakMode = .byTruncatingTail
        // A chip's own compression resistance decides whether the row may make it narrower.
        // Once it may, the label has to be the part that yields; leaving NSTextField's default
        // 750 here let the hidden inner label push through an already-compressible ChipView and
        // ultimately widen a split pane. The full value remains in the tooltip and the chip
        // expands to its fitting width while hovered.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevronView.image = NSImage(
            systemSymbolName: DesignSymbols.chevron,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.chevron, weight: .semibold))
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        // A mark is the size it is; the title is the part that varies. With the stack's default
        // hugging both were equally willing to grow, so a point of width meant for the label —
        // the `titleRoundingAllowance` above all — could land in the chevron instead and the
        // title went on drawing an ellipsis inside a chip at its own full intrinsic width.
        chevronView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // The chip is the accessibility element; exposing its decorative children too would
        // make VoiceOver announce one control as three unrelated objects.
        iconView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        chevronView.setAccessibilityElement(false)

        for view in [iconView, titleLabel, chevronView] {
            contentStack.addArrangedSubview(view)
        }
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = Design.Spacing.tight + 1
        contentStack.setCustomSpacing(Design.Spacing.tight, after: titleLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        let heightConstraint = heightAnchor.constraint(equalToConstant: controlHeight)
        self.heightConstraint = heightConstraint
        let leading = contentStack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.horizontalPadding
        )
        let trailing = contentStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.horizontalPadding
        )
        contentLeadingConstraint = leading
        contentTrailingConstraint = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightConstraint,
            iconView.widthAnchor.constraint(equalToConstant: Design.Symbol.control),
            iconView.heightAnchor.constraint(equalToConstant: Design.Symbol.control)
        ])

        updateChoiceStyleIfNeeded()
        updateBackground()
    }

    // MARK: - Public Methods

    /// Sets what the chip currently shows.
    public func configure(symbolName: String?, title: String) {
        configure(
            icon: symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            },
            title: title
        )
    }

    /// The image variant, for marks that are not SF Symbols — an agent's brand icon.
    public func configure(icon: NSImage?, title: String) {
        configuredIcon = icon
        iconView.image = icon
        iconView.isHidden = icon == nil || choiceStyle.isClassic
        titleLabel.stringValue = title
        toolTip = title
        updateTitleWidthConstraint(for: choiceStyle)
        invalidateIntrinsicContentSize()
    }

    /// Selects an item by its represented value, so a rebuilt menu keeps its choice.
    public func select(_ item: ThemedMenuItem?) {
        selectedItem = item
    }

    // MARK: - Interaction

    /// The chip's hover is a fill *and* a width, so it answers the base's hook rather than
    /// redrawing: see `updateHoverWidth`.
    public override func hoverDidChange() {
        super.hoverDidChange()
        updateHoverState()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        _ = presentMenu()
    }

    // The press that opened the menu may still be held; the menu tracks it from there, so
    // nothing about press-drag-release is this chip's business.

    public override var acceptsFirstResponder: Bool { isEnabled }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { updateBackground(focused: true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateBackground(focused: false) }
        return resigned
    }

    public override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            _ = presentMenu()
        default:
            super.keyDown(with: event)
        }
    }

    /// Builds the semantic presentation separately from showing it. Kept internal for behavior
    /// tests without exposing the contained AppKit menu.
    public func preparedPresentation() -> ThemedMenuPresentation? {
        guard let entries = itemsProvider?(),
              entries.contains(where: {
                  if case .item = $0 { return true }
                  return false
              })
        else { return nil }

        return ThemedMenuPresentation(entries: entries, minimumWidth: bounds.width)
    }

    @discardableResult
    private func presentMenu() -> Bool {
        guard isEnabled, menuSession == nil, choicePresentationSession == nil else {
            return false
        }

        if let choicePresentationProvider {
            themedMenuPresentationDidChange(isPresented: true)
            let session = choicePresentationProvider(self) { [weak self] in
                guard let self else { return }
                self.choicePresentationSession = nil
                self.themedMenuPresentationDidChange(isPresented: false)
            }
            if let session {
                choicePresentationSession = session
                return true
            }
            themedMenuPresentationDidChange(isPresented: false)
        }

        guard let presentation = preparedPresentation() else { return false }

        if let menuPresentationOverride {
            themedMenuPresentationDidChange(isPresented: true)
            defer { themedMenuPresentationDidChange(isPresented: false) }
            if let selected = menuPresentationOverride(presentation) {
                choose(selected)
            }
        } else {
            let selectedIndex = presentation.entries.firstIndex { entry in
                guard case .item(let item) = entry else { return false }
                return item.isSelected
            }
            menuSession = ThemedMenuPresenter.present(
                presentation,
                from: self,
                selectedEntryIndex: selectedIndex,
                onChoose: { [weak self] _, item in self?.choose(item) },
                onDismiss: { [weak self] in
                    self?.menuSession = nil
                }
            )
            if menuSession == nil {
                return false
            }
        }
        return true
    }

    public func themedMenuPresentationDidChange(isPresented: Bool) {
        isPresentingMenu = isPresented
    }

    private func choose(_ item: ThemedMenuItem) {
        selectedItem = item
        item.onChoose?()
        onSelect?(item)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: - Private Methods

    private func updateHoverState() {
        updateBackground()
        updateHoverWidth()
    }

    /// Goes through `applySurface` rather than setting the layer's colour directly, so the fill
    /// the chip is *currently* wearing is the one recorded for `AppThemeRefresh`'s sweep. Setting
    /// it directly left the resting fill recorded forever, and a chip hovered while the theme
    /// changed was swept back to resting under the pointer until the mouse moved again.
    private func updateBackground(focused explicitFocus: Bool? = nil) {
        updateChoiceStyleIfNeeded()
        let focused = explicitFocus ?? (window?.firstResponder === self)
        switch choiceStyle {
        case .chip:
            // The plate is the hover. Raised for the three states that mean "you are on this
            // one" — the pointer, an open menu, the keyboard focus — and absent otherwise, so a
            // row of chips reads as the answers it is showing rather than as a run of objects.
            //
            // The glow goes with it: a theme that haloes its controls would otherwise ring a
            // plate nobody drew, which is a lit outline around bare text.
            let raised = isHovered || isPresentingMenu || focused
            applySurface(
                fill: raised ? Design.Surface.controlHover : .clear,
                radius: .pill(height: controlHeight),
                border: focused ? Design.Surface.accent : nil,
                controlGlow: raised
            )
            updateChipInk(raised: raised)
        case .dropdown:
            // The editable/value half of a Win32 combo is a white sunken well. The arrow is a
            // separate raised button drawn below, not a modern glyph floating in a gray pill.
            applySurface(
                fill: Design.Surface.field,
                radius: .fixed(0),
                bevel: .sunken
            )
        case .popup, .doubleArrowPopup, .cycle:
            applySurface(
                fill: Design.Surface.controlResting,
                radius: .fixed(0),
                bevel: isPresentingMenu ? .sunken : .automatic
            )
        case .aquaPopup:
            // Drawn in `draw(_:)` rather than applied here, and the layer left carrying nothing
            // but the silhouette. A `CALayer` border follows the *continuous* corner this app
            // rounds everything with, whose inner offset is not concentric: at a five-point
            // radius under a one-point border the stroke thickens through the arc and leaves a
            // visible ledge where it meets the straight run — an extra edge in the corner, on a
            // chooser sitting a row above a `ThemedPopUp` that strokes a clean circular one. Two
            // Aqua choosers in one window cannot have two different corners, and the way to
            // guarantee that is one drawing path, which is what this type exists for.
            applySurface(
                fill: .clear,
                radius: .fixed(ClassicChoiceDrawing.aquaCornerRadius)
            )
        }
        alphaValue = isEnabled ? 1 : 0.5
        needsDisplay = true
    }

    /// One ramp, moved a tier by the pointer: the title from `secondary` to `label`, the mark and
    /// the chevron from `tertiary` to `secondary`, under a plate that was not there before.
    ///
    /// **A settings row is not the content of the screen it sits on.** At full strength a run of
    /// chips was the brightest thing in the composer — brighter than the brief being written
    /// above it — which is the wrong answer to "what is this screen for": the words are, and the
    /// row underneath says what they will be sent with. Every composer that has grown a row like
    /// this settles in the same place; the reference shots that prompted the change (Cursor,
    /// ChatGPT) both draw it as muted regular-weight text with a small chevron.
    ///
    /// The step is ink only. Weight is fixed at `controlRegular` for the same reason the padding
    /// is fixed: a bolder face on hover is a *wider* face, and a row that reflowed under the
    /// pointer would be a worse distraction than the one this quiets.
    private func updateChipInk(raised: Bool) {
        titleLabel.textColor = raised ? Design.Text.label : Design.Text.secondary
        iconView.contentTintColor = raised ? Design.Text.secondary : Design.Text.tertiary
        chevronView.contentTintColor = raised ? Design.Text.secondary : Design.Text.tertiary
    }

    /// The padding the hover plate needs, which the frame carries at rest as well so nothing
    /// moves when the plate appears. A row aligning by ink subtracts it — see `ControlRowView`.
    public var opticalHorizontalInset: CGFloat {
        choiceStyle == .chip ? Self.horizontalPadding : ClassicChoiceDrawing.textInset
    }

    /// A classic chooser draws its well to the frame and therefore has no invisible vertical
    /// padding. A modern chip rests as content inside a hover target, so section layout measures
    /// to the tallest visible child instead of to that target.
    public func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat {
        guard !choiceStyle.isClassic else { return 0 }
        let contentHeight = contentStack.arrangedSubviews.reduce(CGFloat.zero) { height, view in
            guard !view.isHidden else { return height }
            let intrinsic = view.intrinsicContentSize.height
            guard intrinsic > 0, intrinsic < 10_000 else { return height }
            return max(height, intrinsic)
        }
        guard contentHeight > 0 else { return 0 }
        return max(0, (frameHeight - contentHeight) / 2)
    }

    private var choiceStyle: AppTheme.Material.ChoiceStyle {
        AppThemePalette.current.material(for: effectiveAppearance).choiceStyle
    }

    private func updateChoiceStyleIfNeeded() {
        let style = choiceStyle
        let height = controlHeight
        guard style != appliedChoiceStyle || height != appliedChoiceHeight else { return }
        appliedChoiceStyle = style
        appliedChoiceHeight = height
        heightConstraint?.constant = height

        switch style {
        case .chip:
            // Regular, not the control face's medium. A chip states a setting, and `control` is
            // the weight this app gives an *action*; at medium in a run of six the row read as
            // six buttons under the box rather than as a line about the message in it.
            titleLabel.applyFont(.controlRegular)
            iconView.isHidden = configuredIcon == nil
            chevronView.isHidden = false
            contentLeadingConstraint?.constant = Self.horizontalPadding
            contentTrailingConstraint?.constant = -Self.horizontalPadding
        case .dropdown, .popup, .doubleArrowPopup, .aquaPopup, .cycle:
            titleLabel.applyFont(.controlRegular)
            // A period chooser's value sits in a *drawn well* — white under Windows 98, the face
            // colour under Platinum — and a well is a container for a value at full strength.
            // The modern chip's resting tier is a statement about a flat row, not about a
            // material that draws a box around every choice.
            titleLabel.textColor = Design.Text.label
            // SF Symbols are a modern platform vocabulary. The native combo carries only its
            // value and the small filled arrow; the menu rows remain free to carry their marks.
            iconView.isHidden = true
            chevronView.isHidden = true
            contentLeadingConstraint?.constant = ClassicChoiceDrawing.textInset
            contentTrailingConstraint?.constant = -(
                ClassicChoiceDrawing.arrowWidth
                    + ClassicChoiceDrawing.textInset
                    + classicTitleTrailingOverhang
            )
        }
        updateTitleWidthConstraint(for: style)
        invalidateIntrinsicContentSize()
    }

    public override func draw(_ dirtyRect: NSRect) {
        let style = choiceStyle
        guard style.isClassic else { return }

        let arrowRect = ClassicChoiceDrawing.arrowRect(in: bounds, style: style)
        if style == .dropdown {
            _ = ThemedSurface.draw(
                arrowRect,
                fill: Design.Surface.controlResting,
                radius: 0,
                bevel: isPresentingMenu ? .sunken : .automatic
            )
        } else if style == .aquaPopup {
            ClassicChoiceDrawing.drawAquaSurface(in: bounds)
            ClassicChoiceDrawing.drawAquaArrowWell(
                in: arrowRect,
                face: ClassicChoiceDrawing.aquaFace(in: bounds),
                pressed: isPresentingMenu
            )
        } else {
            ClassicChoiceDrawing.drawIntegratedSeparator(at: arrowRect.minX, in: bounds)
        }
        ClassicChoiceDrawing.drawIndicator(
            style,
            in: arrowRect,
            color: ClassicChoiceDrawing.indicatorInk(for: style)
        )

        guard window?.firstResponder === self else { return }
        let valueRect = NSRect(
            x: ClassicChoiceDrawing.textInset - 1,
            y: ClassicChoiceDrawing.edge + 2,
            width: max(
                0,
                arrowRect.minX - ClassicChoiceDrawing.textInset * 2
            ),
            height: max(0, bounds.height - ClassicChoiceDrawing.edge * 2 - 4)
        )
        let focus = NSBezierPath(rect: valueRect)
        focus.lineWidth = 1
        focus.setLineDash([1, 1], count: 2, phase: 0)
        Design.Text.label.setStroke()
        focus.stroke()
    }

    /// Pins the chip to its full contents while hovered, so a label the row squeezed into an
    /// ellipsis becomes readable. Priority sits just below required so the neighbouring chips
    /// yield their shared space to it rather than the layout breaking.
    private func updateHoverWidth() {
        hoverWidthConstraint?.isActive = false
        hoverWidthConstraint = nil

        if isHovered {
            // `fittingSize` measures the chip at its label's full, untruncated width, because
            // truncation is a drawing behaviour and does not shrink the intrinsic size.
            let fullWidth = fittingSize.width
            let constraint = widthAnchor.constraint(equalToConstant: fullWidth)
            constraint.priority = .required - 1
            constraint.isActive = true
            hoverWidthConstraint = constraint
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.quick
            context.allowsImplicitAnimation = true
            superview?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    public override func accessibilityTitle() -> String? { titleLabel.stringValue }
    public override func accessibilityValue() -> Any? { selectedItem?.title ?? titleLabel.stringValue }
    public override func isAccessibilityEnabled() -> Bool { isEnabled }
    public override func accessibilityPerformPress() -> Bool { presentMenu() }
    public override func accessibilityPerformShowMenu() -> Bool { presentMenu() }
}

// MARK: - ControlRowMember

extension ChipView: ControlRowMember {

    /// Under a compact row this confirms the height the chip already had — the row takes its
    /// compact measure *from* the chooser. It is the taller rows that move it, and the live
    /// theme switch: `choiceHeight` is the material's, so a style change resizes every chip in
    /// a row along with the row itself.
    public func adopt(_ metrics: ControlRowMetrics) {
        guard rowHeight != metrics.height else { return }
        rowHeight = metrics.height
        applyHeight()
    }
}

// MARK: - Design Symbols

/// Symbols the design system uses itself, as opposed to ones a feature chooses.
public enum DesignSymbols {
    public static let chevron = "chevron.down"
    public static let submit = "return"

    /// The send glyph's other face, while a turn is running. A filled square rather than an
    /// outlined one: Stop is the only control in the box that acts on something already
    /// happening, and it has to read as the more definite of the two at 18pt.
    public static let stop = "stop.fill"

    /// Adding to the turn already running, as opposed to starting another one.
    public static let steer = "arrow.turn.down.right"
    public static let search = "magnifyingglass"
    public static let attachment = "paperclip"
    public static let removeAttachment = "xmark"
    /// Entering annotation mode on a browser page, and being in it.
    public static let annotate = "plus.bubble"
    public static let annotating = "checkmark.bubble.fill"
    /// How a report ended: filed, or refused. Beside wording that already says which, so the
    /// pair carries the outcome without relying on the colour they are tinted.
    public static let reportFiled = "checkmark.circle"
    public static let reportRefused = "exclamationmark.triangle"

    /// A `PaneNoticeView` stating a fact rather than a problem. Its shape differs from the
    /// warning triangle beside it so the two are told apart without their tints.
    public static let noticeInformational = "info.circle"
}
