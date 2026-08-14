import AppKit
import ThreadingExtensionKit

/// The bounded surface a media document is drawn on.
///
/// Two ways in, deliberately, because two kinds of engine exist: `contentLayer` is where an engine
/// with a native animation layer installs itself, and `present(frame:)` is where a decoder that
/// produces bitmaps hands over one bounded frame. Neither is reachable from an extension.
///
/// **The backing store is capped before anything is drawn.** A canvas larger than the ceiling
/// renders at a reduced internal scale rather than allocating an unbounded frame — the alternative
/// is a full-screen player quietly asking for a 33-megapixel buffer on a Retina display.
@MainActor
final class MediaDocumentCanvasView: NSView, ThemedComponent, MediaDocumentRenderHost {

    enum Layout {
        /// The checkerboard's square, in points. Small enough to read as "transparent" and large
        /// enough not to shimmer while a document plays over it.
        static let checkerSquare: CGFloat = 8
    }

    var background: ExtensionMediaBackground = .surface {
        didSet {
            guard background != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether the host offers Copy Frame in this canvas's context menu.
    var allowsFrameCopy = false
    var onCopyFrame: (() -> Void)?

    private let documentLayer = CALayer()
    private var themeRedraw: ThemeRedraw?
    private var limits = MediaDocumentLimits.default
    private var menuSession: AnyObject?

    var presentedFrameForTesting: CGImage? {
        guard let contents = documentLayer.contents else { return nil }
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        // swiftlint:disable:next force_cast - guarded by the type check above.
        return (contents as! CGImage)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        documentLayer.masksToBounds = true
        documentLayer.contentsGravity = .resizeAspect
        // A frozen `CGColor` is the staleness `ThemedControl` exists to prevent; the ground is
        // drawn in `draw(_:)` instead and the layer stays clear.
        documentLayer.backgroundColor = nil
        layer?.addSublayer(documentLayer)
        themeRedraw = ThemeRedraw(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("media.canvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { false }

    override func layout() {
        super.layout()
        // No implicit animation: the document layer follows the pane's live resize, and an
        // animated bounds change would make every drag look like a rubber band.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentLayer.frame = bounds
        documentLayer.contentsScale = backingScale
        CATransaction.commit()
    }

    // MARK: - MediaDocumentRenderHost

    var contentLayer: CALayer { documentLayer }

    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The bounded pixel size a bitmap session should render into.
    ///
    /// Capped on both axes and on the product. A canvas past the ceiling is drawn at a reduced
    /// internal scale, which costs sharpness on an enormous surface and nothing anywhere else.
    var renderPixelSize: CGSize {
        let scale = backingScale
        var width = max(1, bounds.width * scale)
        var height = max(1, bounds.height * scale)

        let axisCap = CGFloat(limits.maximumPixelDimension)
        if width > axisCap || height > axisCap {
            let factor = min(axisCap / width, axisCap / height)
            width *= factor
            height *= factor
        }
        let pixelCap = CGFloat(limits.maximumBackingPixels)
        let total = width * height
        if total > pixelCap {
            let factor = (pixelCap / total).squareRoot()
            width *= factor
            height *= factor
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    func present(frame: CGImage) {
        // Replaces rather than queues: a frame that missed its deadline is superseded, never
        // shown late behind the one after it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        documentLayer.contents = frame
        CATransaction.commit()
    }

    func clear() {
        documentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        documentLayer.contents = nil
        needsDisplay = true
    }

    func applyLimits(_ limits: MediaDocumentLimits) {
        self.limits = limits
    }

    // MARK: - Menu

    /// The secondary click, drawn by the app rather than by AppKit.
    ///
    /// `menu(for:)` would have to build an `NSMenu`, which is the one system surface the theme
    /// boundary keeps out of feature code — and a system menu over a themed canvas is exactly the
    /// mismatch the rule exists for.
    override func rightMouseDown(with event: NSEvent) {
        guard allowsFrameCopy, presentContextMenu(at: .pointer(event.locationInWindow)) else {
            super.rightMouseDown(with: event)
            return
        }
    }

    /// Answers whether a menu opened, which is what the accessibility route reports.
    @discardableResult
    func presentContextMenu(at anchor: ThemedMenuAnchor) -> Bool {
        guard allowsFrameCopy else { return false }
        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: [
                    .item(ThemedMenuItem(
                        title: L10n.string("Copy Frame"),
                        onChoose: { [weak self] in self?.onCopyFrame?() }
                    ))
                ],
                minimumWidth: 0
            ),
            from: self,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
        return menuSession != nil
    }

    override func accessibilityPerformShowMenu() -> Bool {
        presentContextMenu(at: .control)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch background {
        case .transparent:
            return
        case .surface:
            Design.Surface.field.setFill()
            bounds.fill()
        case .checkerboard:
            drawCheckerboard(in: dirtyRect)
        }
    }

    /// The convention that says *this document has transparency*, drawn from theme roles rather
    /// than the usual two greys — a checkerboard in system grey is the one thing a fully themed
    /// page cannot have.
    private func drawCheckerboard(in dirtyRect: NSRect) {
        Design.Surface.field.setFill()
        bounds.fill()

        Design.Surface.controlResting.setFill()
        let square = Layout.checkerSquare
        let firstColumn = Int((dirtyRect.minX / square).rounded(.down))
        let lastColumn = Int((dirtyRect.maxX / square).rounded(.up))
        let firstRow = Int((dirtyRect.minY / square).rounded(.down))
        let lastRow = Int((dirtyRect.maxY / square).rounded(.up))
        guard lastColumn >= firstColumn, lastRow >= firstRow else { return }

        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn where (row + column) % 2 == 0 {
                NSRect(
                    x: CGFloat(column) * square,
                    y: CGFloat(row) * square,
                    width: square,
                    height: square
                ).fill()
            }
        }
    }
}
