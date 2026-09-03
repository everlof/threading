import AppKit

/// A short compound reading — `12% · 248 MB` — that would rather say **fewer** of its parts
/// than say one of them half.
///
/// `UsageReadingLabel` learned the rule first: a tail-truncated reading is not a shorter
/// reading, it is a number whose units went missing. That label is welded to
/// `AccountUsage.Reading` and shares its composition with the toolbar pill, so this is the same
/// policy for plain segments: given room for some it states them complete, from the head; given
/// room for none it draws nothing. The full line stays on the accessibility value and on
/// whatever tooltip the host set.
///
/// The intrinsic width is always the **whole** line, which keeps the choice stable — a dropped
/// segment comes back when the row widens. One ink and one face per reading, because a
/// compound reading is one quiet fact; a host needing per-segment emphasis has outgrown this
/// component.
final class CompoundValueLabel: NSView {

    // MARK: - Types

    /// The face a whole reading is set in.
    ///
    /// A process reading (`12% · 248 MB`) is code-shaped and sits quietly in the compact code
    /// face at the tertiary tier. A receipt (`3.0M tokens · $2.99 est.`) is a number in prose —
    /// on a receipt the number *is* the content, not a fact beside it — so it takes fixed-width
    /// digits at the secondary tier, the same digits the Activity card's counts use.
    enum Face {
        case code
        case numeric
    }

    // MARK: - Properties

    private var themeRedraw: ThemeRedraw?

    /// The parts to state, in print order. Dropped only whole, from the tail.
    var segments: [String] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var face: Face = .code {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Where the drawn line sits when the view is wider than it — a trailing value hangs from
    /// its right edge.
    var alignment: NSTextAlignment = .left {
        didSet { needsDisplay = true }
    }

    /// A host that speaks for its whole row (a row that is itself the accessibility element)
    /// turns this off so the reading is not announced twice.
    var isAccessibilityExposed = true

    /// Every segment, whether or not there was room to draw them all.
    var plainValue: String {
        segments.joined(separator: CompoundValueDefaults.separator)
    }

    override var intrinsicContentSize: NSSize {
        guard !segments.isEmpty else { return .zero }
        let size = line(count: segments.count).size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        themeRedraw = ThemeRedraw(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    /// A width change is a *content* change here: it decides how many segments are stated.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = drawableSegmentCount(in: bounds.width)
        guard count > 0 else { return }

        let text = line(count: count)
        let size = text.size()
        let x = alignment == .right ? bounds.width - size.width : 0
        text.draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()))
    }

    /// How many complete segments fit the width on offer — measured, with half a point of slack
    /// for the integral widths a stack view hands out.
    func drawableSegmentCount(in width: CGFloat) -> Int {
        for count in stride(from: segments.count, through: 1, by: -1)
        where line(count: count).size().width <= width + 0.5 {
            return count
        }
        return 0
    }

    private func line(count: Int) -> NSAttributedString {
        let font: NSFont
        let ink: NSColor
        switch face {
        case .code:
            font = Design.Typography.compactCode()
            ink = Design.Text.tertiary
        case .numeric:
            font = Design.Typography.numericDetail()
            ink = Design.Text.secondary
        }
        return NSAttributedString(
            string: segments.prefix(count).joined(separator: CompoundValueDefaults.separator),
            attributes: [.font: font, .foregroundColor: ink]
        )
    }

    // MARK: - Accessibility

    /// The whole reading, however much of it there was room to draw.
    override func isAccessibilityElement() -> Bool {
        isAccessibilityExposed && !segments.isEmpty
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { plainValue }
}

// MARK: - Defaults

enum CompoundValueDefaults {
    static let separator = " · "
}
