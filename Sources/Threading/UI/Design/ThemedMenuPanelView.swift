import AppKit

/// The shared themed panel for menus on Mac and Linux. Hosts place the panel; its surface
/// and historical frames belong to the design component.
@MainActor
class ThemedMenuPanelView: NSView, ThemedComponent {
    private var mountedDocument: ThemedMenuDocumentView?
    private var mountedRows: [NSView] = []
    private var mountedHeights: [CGFloat] = []
    private var mountedPadding: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        applyMenuSurface()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMenuSurface()
        needsDisplay = true
    }

    private func applyMenuSurface() {
        let paintsIndexedFrame = [
            AppTheme.Material.MenuAppearance.windows98,
            .platinum,
        ].contains(ThemedMenuMetrics.appearance)
        applySurface(
            fill: ThemedMenuMetrics.panelFill,
            radius: .panel,
            // The two indexed classic frames are painted below. Leaving the generic layer
            // border/bevel in place antialiases Windows' square four-tone edge and repaints
            // Platinum's measured black/#222 containment rule with the theme border. A coupon's
            // border is drawn along its scalloped outline instead, which a layer border cannot
            // follow.
            border: paintsIndexedFrame || wearsCoupon ? nil : Design.Surface.border,
            glow: ThemedMenuMetrics.panelHasGlow,
            bevel: paintsIndexedFrame ? .none : .automatic
        )
    }

    /// Mount a bounded page of rows in the same document the Mac menu uses. Preserve rows
    /// through repaint and scrolling so a held press stays attached to its original view.
    func setRows(_ rows: [NSView], heights: [CGFloat], padding: CGFloat = 6) {
        precondition(rows.count == heights.count)
        if rows.count == mountedRows.count,
           zip(rows, mountedRows).allSatisfy({ $0 === $1 }),
           heights == mountedHeights, padding == mountedPadding { return }
        mountedDocument?.removeFromSuperview()
        mountedDocument = nil
        mountedRows = rows
        mountedHeights = heights
        mountedPadding = padding
        guard !rows.isEmpty else { return }

        let document = ThemedMenuDocumentView(views: rows, heights: heights)
        document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(document)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            document.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            document.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            document.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
        mountedDocument = document
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch ThemedMenuMetrics.appearance {
        case .windows98:
            ThemedMenuPanelArtwork.drawWindows98Frame(in: bounds)
        case .platinum:
            ThemedMenuPanelArtwork.drawPlatinumFrame(in: bounds)
        default:
            #if !os(Linux)
            if wearsCoupon {
                // Stroked on the mask's own path at twice the border width: the mask keeps the
                // inner half, which is exactly one border's width inside the scalloped edge.
                let outline = couponOutline
                outline.lineWidth = Design.Radius.border * 2
                Design.Surface.border.setStroke()
                outline.stroke()
            }
            #endif
        }
    }

    /// A coupon theme's menu is a ticket like its popovers. Only the modern family wears it: the
    /// historical families keep the measured frames they reproduce.
    private var wearsCoupon: Bool {
        #if os(Linux)
        false
        #else
        ThemedMenuMetrics.appearance == .automatic
            && CouponOutline.isWorn(by: AppThemePalette.current.material(for: effectiveAppearance))
        #endif
    }

    #if !os(Linux)
    private var couponOutline: NSBezierPath {
        CouponOutline.path(in: bounds, cornerRadius: Design.Radius.panel)
    }

    /// Masks the panel to the coupon. The menu's shadow lives on the chassis around this view
    /// and follows its alpha, so the scallops cast their own shadow without a second path.
    private func shapeCouponMask() {
        guard wearsCoupon else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = couponOutline.threadingCGPath
        layer?.mask = mask
    }
    #else
    private func shapeCouponMask() {}
    #endif

    override func layout() {
        super.layout()
        shapeCouponMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Indexed panel edges retained from the official Platinum Help-menu figure. The same reason
/// the native scrollbars keep measured symbolic rows applies here: a generic raised bevel puts
/// white on the outside top/left, while a Platinum menu has a black containment rule, one inner
/// highlight/shadow pair, and a one-pixel hard drop shadow at the bottom/right.
@MainActor
private enum ThemedMenuPanelArtwork {
    /// The Win32 popup frame is four indexed one-pixel rails, not the app's ordinary two-line
    /// raised control bevel. In visual order it is BUTTONLIGHT, BTN HIGHLIGHT, BTN SHADOW,
    /// black; the final black bottom/right rail is also the menu's hard one-pixel shadow.
    ///
    /// `outerLight` remains palette-derived so a custom theme that deliberately reuses the
    /// Windows menu anatomy can recolour the face without inheriting a stray literal gray.
    static func drawWindows98Frame(in rect: NSRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        func visualRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(
                x: rect.minX + x,
                y: isFlipped
                    ? rect.minY + y
                    : rect.maxY - y - height,
                width: width,
                height: height
            )
        }
        func fill(_ color: NSColor, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            color.setFill()
            visualRect(x: x, y: y, width: width, height: height).fill()
        }

        let width = floor(rect.width)
        let height = floor(rect.height)
        let face = ThemedMenuMetrics.panelFill
        let highlight = Design.Surface.bevelHighlight
        let shadow = Design.Surface.bevelShadow
        // BUTTONLIGHT is the quantized #DF step over the stock #C0 face. A half-channel bias
        // keeps CoreGraphics' round-to-nearest conversion on that indexed value at 1x.
        let outerLight = face.blended(withFraction: 30.5 / 63, of: highlight) ?? highlight

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        fill(face, 0, 0, width, height)
        fill(outerLight, 0, 0, width, 1)
        fill(outerLight, 0, 1, 1, height - 2)
        fill(highlight, 1, 1, width - 2, 1)
        fill(highlight, 1, 2, 1, height - 4)
        fill(shadow, width - 2, 2, 1, height - 3)
        fill(shadow, 1, height - 2, width - 2, 1)
        fill(.black, width - 1, 1, 1, height - 1)
        fill(.black, 0, height - 1, width, 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawPlatinumFrame(in rect: NSRect) {
        guard rect.width >= 4, rect.height >= 4 else { return }
        let isFlipped = NSGraphicsContext.current?.isFlipped ?? false
        func visualRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
            NSRect(
                x: rect.minX + x,
                y: isFlipped
                    ? rect.minY + y
                    : rect.maxY - y - height,
                width: width,
                height: height
            )
        }
        func fill(_ color: NSColor, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            color.setFill()
            visualRect(x: x, y: y, width: width, height: height).fill()
        }

        let width = floor(rect.width)
        let height = floor(rect.height)
        // The source pixel is literal black. `label` is semantic elsewhere, but a user-edited
        // role must not recolour historical menu hardware after `.platinum` has selected it.
        let ink = NSColor.black
        let face = ThemedMenuMetrics.panelFill
        let innerShadow = NSColor(
            srgbRed: 153 / 255, green: 153 / 255, blue: 153 / 255, alpha: 1
        )
        let hardShadow = NSColor(
            srgbRed: 34 / 255, green: 34 / 255, blue: 34 / 255, alpha: 1
        )

        fill(.white, 0, 0, width, height)
        fill(hardShadow, 2, height - 1, width - 2, 1)
        fill(hardShadow, width - 1, 2, 1, height - 2)
        fill(ink, 0, 0, width, 1)
        fill(ink, 0, 0, 1, height - 1)
        fill(ink, width - 2, 0, 1, height - 1)
        fill(ink, 0, height - 2, width - 1, 1)
        fill(face, 1, 1, width - 3, height - 3)
        fill(Design.Surface.bevelHighlight, 1, 1, width - 4, 1)
        fill(Design.Surface.bevelHighlight, 1, 1, 1, height - 3)
        fill(innerShadow, width - 3, 2, 1, height - 4)
        fill(innerShadow, 2, height - 3, width - 4, 1)
    }
}
