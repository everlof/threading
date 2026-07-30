import AppKit

// MARK: - Usage Bar View

/// A flat horizontal gauge: quiet full-width track, tinted fill for the spent fraction.
final class UsageBarView: NSView {

    // MARK: - Properties

    var fraction: Double = 0 { didSet { needsLayout = true } }
    var tint: NSColor = Design.Surface.accent { didSet { needsLayout = true } }

    /// The linear time position within the window, 0…1, drawn as a thin vertical mark so the
    /// spent fill can be read against the clock. Nil hides it.
    var timeMark: Double? { didSet { needsLayout = true } }

    private let fillView = NSView()
    private let markView = NSView()

    /// The colours are resolved in `layout()`, which a theme change does not otherwise trigger —
    /// so the bar would keep the previous theme's accent until something else moved it.
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        fillView.wantsLayer = true
        markView.wantsLayer = true
        addSubview(fillView)
        // Above the fill, so the pace line stays visible even where usage has passed it.
        addSubview(markView)
        themeRedraw = ThemeRedraw(self)
    }

    /// `ThemeRedraw` asks for a redraw; this one needs a re-*layout*, because that is where its
    /// layer colours are set.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let radius = bounds.height / 2
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        applyLayerBackground(Design.Surface.controlResting)

        let width = bounds.width * min(max(fraction, 0), 1)
        fillView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        fillView.layer?.cornerCurve = .continuous
        fillView.layer?.cornerRadius = radius
        fillView.applyLayerBackground(tint)
        fillView.isHidden = width <= 0

        if let timeMark {
            let markWidth = UsageBarDefaults.timeMarkWidth
            let markCentre = bounds.width * min(max(timeMark, 0), 1)
            markView.frame = NSRect(
                x: min(max(markCentre - markWidth / 2, 0), bounds.width - markWidth),
                y: 0, width: markWidth, height: bounds.height
            )
            markView.layer?.cornerCurve = .continuous
            markView.layer?.cornerRadius = markWidth / 2
            // labelColor adapts to light/dark, so the mark reads against both the track and any
            // tint fill it overlaps.
            markView.applyLayerBackground(
                Design.Text.label.withAlphaComponent(UsageBarDefaults.timeMarkAlpha)
            )
            markView.isHidden = false
        } else {
            markView.isHidden = true
        }
    }
}

// MARK: - Usage Bar Defaults

enum UsageBarDefaults {
    static let height: CGFloat = 6
    static let timeMarkWidth: CGFloat = 2
    static let timeMarkAlpha: CGFloat = 0.85
}
