import AppKit

extension Design {
    /// Content beneath annotations is authored by the website, independently of the app theme.
    /// Both polarities must remain present: an accent and its text ink alone can both disappear
    /// into a midtone page. Fixed opaque extremes give the boundary its own 21:1 contrast.
    @MainActor
    enum Annotation {
        static var darkEdge: NSColor { .black }
        static var lightEdge: NSColor { .white }
        static var edgeWidth: CGFloat { Accessibility.focusRingWidth / 2 }
        static var fill: NSColor { Surface.accent.withAlphaComponent(1) }
        static var editorFill: NSColor { Surface.floating.withAlphaComponent(1) }
    }
}

/// One paint contract for pins, target outlines, badges and the note editor. No page sampling,
/// image reads or extra per-pin views are needed; work remains proportional to drawn paths.
@MainActor
enum BrowserAnnotationChrome {
    static func outerWidth(for width: CGFloat) -> CGFloat {
        width + 4 * Design.Annotation.edgeWidth
    }

    static func stroke(_ path: NSBezierPath, width: CGFloat) {
        Design.Annotation.darkEdge.setStroke()
        path.lineWidth = outerWidth(for: width)
        path.stroke()
        Design.Annotation.lightEdge.setStroke()
        path.lineWidth = width + 2 * Design.Annotation.edgeWidth
        path.stroke()
        Design.Annotation.fill.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    static func fill(_ path: NSBezierPath, color: NSColor? = nil) {
        Design.Annotation.darkEdge.setStroke()
        path.lineWidth = 4 * Design.Annotation.edgeWidth
        path.stroke()
        Design.Annotation.lightEdge.setStroke()
        path.lineWidth = 2 * Design.Annotation.edgeWidth
        path.stroke()
        (color ?? Design.Annotation.fill).setFill()
        path.fill()
    }
}

final class BrowserAnnotationSurfaceView: NSView, ThemedComponent, ThemeDerivedContent {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func rederiveThemedContent() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = ThemedSurface.Shape(rect: bounds, radius: Design.Radius.panel)
            .inset(by: 2 * Design.Annotation.edgeWidth)
        BrowserAnnotationChrome.fill(shape.path, color: Design.Annotation.editorFill)
    }
}
