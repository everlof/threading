import AppKit

// MARK: - Generated App Icon

/// The Dock icon drawn from the current `AppTheme`, so the tile in the Dock carries the same
/// ground and accent the window does.
///
/// Generated rather than shipped, for the same reason `GeneratedProjectIcon` is: the alternative
/// is twelve themes times two appearances of authored artwork that has to be re-exported every
/// time a role moves, and a custom theme — which a user or an agent can invent at any moment —
/// could never have artwork at all. A pure function of the theme covers all three cases with one
/// piece of code.
///
/// **The silhouette never changes.** Only the ground, the ink and the shadow treatment follow
/// the theme; the Threading mark's geometry is fixed. An app icon's first job is to be found in ⌘-Tab
/// by its shape, and a mark that redrew itself per theme would trade the whole point of an icon
/// for a colour match. This is the shipped `AppIcon.icon` document's own mark, restated
/// as geometry.
///
/// **The System theme gets no generated icon** — `image(for:appearance:)` answers nil, and
/// `AppIconPresenter` puts the bundle's own icon back. System means "follow the platform", and
/// what the platform ships for this app is the authored Icon Composer document, with a depth and
/// a glass treatment forty lines of Core Graphics has no business imitating. So the default
/// install looks exactly as it did; only a user who has deliberately chosen a style sees this.
///
/// Drawing the plate and its shadow is not optional. `NSApplication.applicationIconImage` hands
/// the Dock a bitmap and the Dock draws it unmasked — none of the rounding, and on macOS 26 none
/// of the squircle, that a bundle icon gets for free.
@MainActor
enum GeneratedAppIcon {

    // MARK: - Properties

    /// The canvas every macOS app icon is authored on.
    nonisolated static let canvasSide: CGFloat = 1024

    /// Keyed by the *inputs* rather than by the theme's id: a custom theme keeps its identity
    /// across an edit, so an id-keyed cache serves the colours the user just changed away from.
    private static let cache = NSCache<NSString, NSImage>()

    // MARK: - Public Methods

    /// The icon for a theme under one appearance, or nil where the bundle's own icon is the
    /// right answer.
    /// Main-actor isolated because the mark comes from the extension registry, which is. The
    /// stated-mark form below stays free of that, so drawing can be exercised without standing
    /// one up.
    @MainActor
    static func image(for theme: AppTheme, appearance: NSAppearance) -> NSImage? {
        image(
            for: theme,
            appearance: appearance,
            mark: ExtensionAppearanceRegistry.shared.iconMark(forThemeID: theme.id)
        )
    }

    /// The stated-mark form, for tests and previews that must not depend on what is installed.
    static func image(
        for theme: AppTheme,
        appearance: NSAppearance,
        mark: NSImage?
    ) -> NSImage? {
        guard var recipe = Recipe(theme: theme, appearance: appearance) else { return nil }
        recipe.mark = mark

        let key = recipe.cacheKey as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image = draw(recipe)
        // The app's name, not the theme's. This is the application icon whichever theme drew it,
        // and a screen reader announcing "Cyberpunk" for the Dock tile would be describing the
        // paint rather than the thing.
        image.accessibilityDescription =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Recipe

    /// Everything the drawing needs, resolved out of the theme once.
    ///
    /// Resolving here rather than while drawing is what lets the cache key be honest: two themes
    /// that state the same ground, ink and shadow produce the same picture and should share it,
    /// and a theme edited to new colours cannot collide with its own previous value.
    struct Recipe {
        let ground: NSColor
        let ink: NSColor
        let shadow: Shadow?
        let corner: Corner

        /// A contributed theme's own mark, drawn in place of the default Threading mark.
        ///
        /// The **plate is never the extension's** — it is the theme's `ground`, drawn here — so
        /// a package supplies a glyph rather than an icon. That is what keeps every contributed
        /// theme's Dock tile recognisably this app's, and what makes shipping a copy of some
        /// other application's icon useless rather than merely discouraged.
        /// `ExtensionBundleLoader` refuses a mark that fills its own bounds, so by the time one
        /// arrives here it has transparency to composite against.
        var mark: NSImage?

        /// How the theme finishes the Threading mark's strokes.
        enum Corner {
            case round
            case mitred

            var lineCap: NSBezierPath.LineCapStyle { self == .round ? .round : .butt }
            var lineJoin: NSBezierPath.LineJoinStyle { self == .round ? .round : .miter }
        }

        struct Shadow {
            let color: NSColor
            let blur: CGFloat
            let offset: CGSize
        }

        /// Nil for the System theme, whose answer is the bundle icon.
        init?(theme: AppTheme, appearance: NSAppearance) {
            guard theme.id != .system else { return nil }

            var resolvedGround = NSColor.black
            var resolvedInk = NSColor.white
            var resolvedShadow: Shadow?

            // Stated, not ambient. Material is variant-owned — a pale style may want a hard ink
            // shadow where its night counterpart wants a restrained glow — so `theme.material`
            // answers for whatever appearance AppKit last had in hand, which here is whatever
            // happened to draw last rather than the icon being asked for.
            let material = theme.material(for: appearance)

            // Resolving inside the appearance is what bakes a concrete colour out of the dynamic
            // ones an unthemed role still answers with. A role read outside this block resolves
            // against whatever appearance AppKit last had in hand — the same trap
            // `AppTheme.terminalPalette` documents, and here it would render a light theme's
            // icon with dark-mode ink.
            appearance.performAsCurrentDrawingAppearance {
                let ground = theme.resolved(.ground, appearance: appearance)
                    .usingColorSpace(.sRGB) ?? .black
                // A theme whose accent sits too close to its own ground would draw an invisible
                // mark. `legible(on:)` moves it along its own lightness axis and leaves a
                // palette that already passes completely alone, so this is a floor rather than a
                // correction — no theme in the stock library is touched by it.
                let ink = (theme.resolved(.accent, appearance: appearance)
                    .usingColorSpace(.sRGB) ?? .white)
                    .legible(on: ground)

                resolvedGround = ground
                resolvedInk = ink

                if let glow = material.glow {
                    let color = theme.resolved(glow.role, appearance: appearance)
                        .usingColorSpace(.sRGB) ?? .black
                    resolvedShadow = Shadow(
                        color: color.withAlphaComponent(CGFloat(glow.opacity)),
                        blur: glow.radius * Layout.shadowScale,
                        // **The vertical offset is negated.** A theme states its shadow for
                        // `CALayer.shadowOffset`, which `Design.applyThemeGlow` passes straight
                        // through in the layer's y-up space — so Bauhaus's `offsetY: -4` is a
                        // lift cast *downward*, which is what a printed style means. `NSShadow`
                        // in this drawing context resolves the other way: measured against the
                        // rendered pixels, the same value put the lift up and to the right,
                        // where the chrome puts it down and to the right. One negation is the
                        // whole difference between the icon and the window agreeing.
                        offset: CGSize(
                            width: glow.offsetX * Layout.shadowScale,
                            height: -glow.offsetY * Layout.shadowScale
                        )
                    )
                }
            }

            ground = resolvedGround
            ink = resolvedInk
            shadow = resolvedShadow
            // The mark is a small element, so it follows the radius the theme gives its small
            // elements. Without this Bauhaus and Newsprint are two beige plates carrying the same
            // rounded mark; with it one is printed with hard corners and the other is not.
            corner = material.controlRadius >= Layout.roundedControlThreshold
                ? .round
                : .mitred
        }

        /// Two themes drawing the same picture share a cache entry; one edited to new colours
        /// cannot hit its own stale one.
        var cacheKey: String {
            let shadowKey = shadow.map {
                "\($0.color.hexString)-\($0.color.alphaComponent)-\($0.blur)"
                    + "-\($0.offset.width)-\($0.offset.height)"
            } ?? "none"
            // `ObjectIdentifier` rather than the bytes: the registry hands back one memoized
            // image per theme and replaces it when the package changes, so identity is exactly
            // the right grain — and hashing a megabyte of PNG on every redraw is not.
            let markKey = mark.map { "\(ObjectIdentifier($0))" } ?? "threading"
            return "\(ground.hexString)-\(ink.hexString)-\(corner)-\(shadowKey)-\(markKey)"
        }
    }

    // MARK: - Private Methods

    private static func draw(_ recipe: Recipe) -> NSImage {
        let side = canvasSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let body = NSRect(
                x: (side - side * Layout.bodyRatio) / 2,
                y: (side - side * Layout.bodyRatio) / 2,
                width: side * Layout.bodyRatio,
                height: side * Layout.bodyRatio
            )
            let radius = body.width * Layout.cornerRatio
            let plate = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

            drawPlate(plate, fill: recipe.ground, body: body)

            // Clipped to the plate so a hard printed shadow — Bauhaus, Neo Brutalism — lands on
            // the tile rather than hanging off its corner into the Dock.
            NSGraphicsContext.saveGraphicsState()
            plate.setClip()
            if let mark = recipe.mark {
                drawMark(mark, recipe, in: body)
            } else {
                drawThreadingMark(recipe, in: body)
            }
            NSGraphicsContext.restoreGraphicsState()

            return true
        }
    }

    /// The plate, under the drop shadow the Dock does not add for a runtime icon.
    private static func drawPlate(_ plate: NSBezierPath, fill: NSColor, body: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let cast = NSShadow()
        cast.shadowColor = NSColor.black.withAlphaComponent(Layout.plateShadowOpacity)
        cast.shadowBlurRadius = body.width * Layout.plateShadowBlurRatio
        cast.shadowOffset = CGSize(width: 0, height: -body.width * Layout.plateShadowOffsetRatio)
        cast.set()
        fill.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A contributed mark, fitted inside the plate and wearing the theme's own shadow.
    ///
    /// **Aspect is preserved and the mark is never upscaled past the safe area.** An author
    /// exports whatever shape their glyph is; forcing it into a square would letterbox some
    /// marks and stretch others, and neither is a failure the author can see from their own
    /// asset. The theme's glow applies here for the same reason it applies to the default mark — a
    /// printed style's mark should sit on the page the way its panels do.
    private static func drawMark(_ mark: NSImage, _ recipe: Recipe, in body: NSRect) {
        let size = mark.size
        guard size.width > 0, size.height > 0 else { return }

        let safe = body.insetBy(
            dx: body.width * Layout.markInsetRatio,
            dy: body.height * Layout.markInsetRatio
        )
        let scale = min(safe.width / size.width, safe.height / size.height, 1)
        let drawn = NSRect(
            x: safe.midX - size.width * scale / 2,
            y: safe.midY - size.height * scale / 2,
            width: size.width * scale,
            height: size.height * scale
        )

        NSGraphicsContext.saveGraphicsState()
        if let shadow = recipe.shadow {
            let cast = NSShadow()
            cast.shadowColor = shadow.color
            cast.shadowBlurRadius = shadow.blur
            cast.shadowOffset = shadow.offset
            cast.set()
        }
        mark.draw(
            in: drawn,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawThreadingMark(_ recipe: Recipe, in body: NSRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let scaledX = 0.5 + (x - 0.5) * Layout.defaultMarkScale
            let scaledY = 0.5 + (y - 0.5) * Layout.defaultMarkScale
            return NSPoint(
                x: body.minX + body.width * scaledX,
                y: body.minY + body.height * scaledY
            )
        }

        func quadratic(
            _ path: NSBezierPath,
            from start: CGPoint,
            control: CGPoint,
            to end: CGPoint
        ) {
            let first = CGPoint(
                x: start.x + (control.x - start.x) * 2 / 3,
                y: start.y + (control.y - start.y) * 2 / 3
            )
            let second = CGPoint(
                x: end.x + (control.x - end.x) * 2 / 3,
                y: end.y + (control.y - end.y) * 2 / 3
            )
            path.curve(
                to: point(end.x, end.y),
                controlPoint1: point(first.x, first.y),
                controlPoint2: point(second.x, second.y)
            )
        }

        let outerPoints: [(end: CGPoint, control: CGPoint)] = [
            (.init(x: 0.865390625, y: 0.7109375), .init(x: 0.667109375, y: 0.789375)),
            (.init(x: 0.865390625, y: 0.2890625), .init(x: 0.834140625, y: 0.5)),
            (.init(x: 0.5, y: 0.078125), .init(x: 0.667109375, y: 0.210625)),
            (.init(x: 0.134609375, y: 0.2890625), .init(x: 0.332890625, y: 0.210625)),
            (.init(x: 0.134609375, y: 0.7109375), .init(x: 0.165859375, y: 0.5)),
            (.init(x: 0.5, y: 0.921875), .init(x: 0.332890625, y: 0.789375))
        ]
        let outer = NSBezierPath()
        var start = CGPoint(x: 0.5, y: 0.921875)
        outer.move(to: point(start.x, start.y))
        for edge in outerPoints {
            quadratic(outer, from: start, control: edge.control, to: edge.end)
            start = edge.end
        }
        outer.close()
        outer.lineWidth = body.width * Layout.outerStrokeRatio * Layout.defaultMarkScale
        outer.lineCapStyle = recipe.corner.lineCap
        outer.lineJoinStyle = recipe.corner.lineJoin

        func rotated(_ value: CGPoint, turns: Int) -> CGPoint {
            let angle = -CGFloat(turns) * .pi / 3
            let dx = value.x - 0.5
            let dy = value.y - 0.5
            return CGPoint(
                x: 0.5 + dx * cos(angle) - dy * sin(angle),
                y: 0.5 + dx * sin(angle) + dy * cos(angle)
            )
        }

        let spoke = NSBezierPath()
        let spokeStart = CGPoint(x: 0.5, y: 0.90625)
        let control1 = CGPoint(x: 0.515625, y: 0.7734375)
        let control2 = CGPoint(x: 0.5234375, y: 0.6640625)
        let spokeEnd = CGPoint(x: 0.45703125, y: 0.54296875)
        for turns in 0..<6 {
            let segmentStart = rotated(spokeStart, turns: turns)
            let segmentControl1 = rotated(control1, turns: turns)
            let segmentControl2 = rotated(control2, turns: turns)
            let segmentEnd = rotated(spokeEnd, turns: turns)
            spoke.move(to: point(segmentStart.x, segmentStart.y))
            spoke.curve(
                to: point(segmentEnd.x, segmentEnd.y),
                controlPoint1: point(segmentControl1.x, segmentControl1.y),
                controlPoint2: point(segmentControl2.x, segmentControl2.y)
            )
        }
        spoke.lineWidth = body.width * Layout.strokeRatio * Layout.defaultMarkScale
        spoke.lineCapStyle = recipe.corner.lineCap
        spoke.lineJoinStyle = recipe.corner.lineJoin

        let center = NSBezierPath()
        // Slightly larger than the display SVG's junction. A square-ended theme stops each
        // strand before its half-stroke can reach the SVG-sized hexagon; this radius covers
        // those endpoints too, so every material keeps the center genuinely solid.
        [
            CGPoint(x: 0.5, y: 0.575),
            CGPoint(x: 0.5649519, y: 0.5375),
            CGPoint(x: 0.5649519, y: 0.4625),
            CGPoint(x: 0.5, y: 0.425),
            CGPoint(x: 0.4350481, y: 0.4625),
            CGPoint(x: 0.4350481, y: 0.5375)
        ].enumerated().forEach { index, vertex in
            if index == 0 {
                center.move(to: point(vertex.x, vertex.y))
            } else {
                center.line(to: point(vertex.x, vertex.y))
            }
        }
        center.close()

        // Compose the complete silhouette before its themed shadow is applied. Casting from the
        // six strands independently leaves six small shadow wedges at their overlaps, which
        // visually re-opens the center even though its geometry is filled.
        let side = Int(canvasSide)
        guard let raster = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        raster.size = NSSize(width: canvasSide, height: canvasSide)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: raster)
        recipe.ink.setStroke()
        outer.stroke()
        spoke.stroke()
        recipe.ink.setFill()
        center.fill()
        NSGraphicsContext.restoreGraphicsState()

        let mark = NSImage(size: raster.size)
        mark.addRepresentation(raster)

        NSGraphicsContext.saveGraphicsState()
        if let shadow = recipe.shadow {
            let cast = NSShadow()
            cast.shadowColor = shadow.color
            cast.shadowBlurRadius = shadow.blur
            cast.shadowOffset = shadow.offset
            cast.set()
        }
        mark.draw(
            in: NSRect(origin: .zero, size: raster.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Layout

extension GeneratedAppIcon {

    /// Apple's macOS icon grid, and the Threading mark stated as fractions of the plate it sits on.
    ///
    /// Fractions rather than points so the same numbers draw the 1024 canvas and any preview
    /// size a settings page asks for.
    enum Layout {
        /// The macOS app icon template: the body occupies 824 of a 1024 canvas, leaving the
        /// 100pt margin the platform's own icons reserve for their shadow.
        static let bodyRatio: CGFloat = 824.0 / 1024.0
        /// 185.4 of the 824pt body — the template's continuous corner.
        static let cornerRatio: CGFloat = 185.4 / 824.0

        /// The display SVG uses 7pt for its outer hexagon and 7.5pt for the six strands on a
        /// 128pt canvas. Keeping those separate preserves the slightly stronger inner motion.
        static let outerStrokeRatio: CGFloat = 7.0 / 128.0
        static let strokeRatio: CGFloat = 7.5 / 128.0
        /// The runtime mark gets more air than the standalone SVG because it sits inside a
        /// rounded app-icon plate and carries the theme's glow or printed lift around it.
        static let defaultMarkScale: CGFloat = 0.76

        /// A theme that rounds its controls rounds the mark.
        static let roundedControlThreshold: CGFloat = 6

        /// The margin a contributed mark keeps inside the plate, per edge.
        ///
        /// A contributed mark keeps the same safe-area discipline as the default mark. A mark
        /// drawn to the plate's edge would
        /// read as a different *kind* of icon beside every stock style, which is the one thing
        /// the mark-only rule exists to prevent.
        static let markInsetRatio: CGFloat = 0.16

        /// Glow radii and offsets are authored in chrome points, beside controls whose ink is
        /// about this heavy. The mark's stroke is the icon's equivalent ink, so the two are
        /// matched on **weight of mark** rather than on canvas size.
        ///
        /// Measured by looking at it. Scaling by the canvas instead — an 824pt plate against a
        /// ~96pt chrome element, so 8.6× — put Bauhaus's 4pt printed offset at 34pt against the
        /// mark, which stops reading as a lift and starts reading as a second silhouette
        /// in the theme's label colour. Bauhaus, Neo Brutalism, Newsprint and Industrial all
        /// state a zero-radius offset shadow, so all four failed the same way.
        static let chromeReferenceInk: CGFloat = 28
        static var shadowScale: CGFloat {
            (canvasSide * bodyRatio * strokeRatio * defaultMarkScale) / chromeReferenceInk
        }

        /// The shadow the Dock adds for a bundle icon and does not add for a runtime one.
        static let plateShadowOpacity: CGFloat = 0.28
        static let plateShadowBlurRatio: CGFloat = 0.055
        static let plateShadowOffsetRatio: CGFloat = 0.022
    }
}
