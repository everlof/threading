import AppKit

final class ThemedMenuDocumentView: NSView {

    let naturalHeight: CGFloat
    private let views: [NSView]
    private let viewHeights: [CGFloat]

    override var isFlipped: Bool { true }

    /// `heights` comes from `ThemedMenuMetrics.heights(for:)`, the same call that sized the
    /// panel. It used to be re-derived here from each view's class — a row's own
    /// `preferredHeight`, and `separatorHeight` for anything else — which is fine while every
    /// non-row *is* a separator and silently wrong the moment one is not: a section head was
    /// laid out in a 13pt slot while the panel had been sized for its 30, so the head drew
    /// against the row above it and the difference pooled at the panel's bottom edge.
    init(views: [NSView], heights: [CGFloat]) {
        self.views = views
        #if os(Linux)
        viewHeights = heights
        #else
        if ThemedMenuMetrics.appearance == .platinum, views.count > 1 {
            // The official Help-menu crop exposes the actual edge rhythm: the first and last
            // item slots are 18px, interior item slots 20px, and etched separators 2px. The
            // outer slots meet the frame's inner highlight/shadow, so treating every row as a
            // uniform 19px moved the first separator down while coincidentally leaving the
            // second one correct.
            viewHeights = views.enumerated().map { index, view in
                guard view is ThemedMenuRowView else {
                    return ThemedMenuMetrics.separatorHeight
                }
                return index == 0 || index == views.count - 1 ? 18 : 20
            }
        } else {
            viewHeights = heights
        }
        #endif
        naturalHeight = viewHeights.reduce(0, +)
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (view, height) in zip(views, viewHeights) {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}
