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
/// of the squircle, that a bundle icon gets for free. The phone is the opposite case, and gets
/// its own `Grid`.
@MainActor
enum GeneratedAppIcon {

    // MARK: - Properties

    /// The canvas every macOS app icon is authored on.
    nonisolated static let canvasSide: CGFloat = 1024

    /// Keyed by the *inputs* rather than by the theme's id: a custom theme keeps its identity
    /// across an edit, so an id-keyed cache serves the colours the user just changed away from.
    private static let cache = NSCache<NSString, NSImage>()

    // MARK: - Grid

    /// Which platform's tile the icon is drawn for.
    ///
    /// The two platforms disagree about who draws the plate. The Dock hands a runtime bitmap to
    /// the screen unmasked, so the Mac form draws the rounded plate itself and the drop shadow
    /// the platform adds under a bundle icon. The iPhone does the opposite: `setAlternateIconName`
    /// selects a compiled full-bleed square, the Home Screen masks it into its squircle and draws
    /// nothing under it. Carrying the Mac form onto the phone put the Dock's shadow *inside* the
    /// squircle, which on a white ground read as a grey border around a smaller plate — and left
    /// the mark a quarter smaller than the primary icon's, because the margin the Dock reserves
    /// for its shadow had become part of the tile.
    enum Grid {
        /// A rounded plate with its drop shadow, inside the margin macOS reserves for one.
        case dock
        /// The ground to every edge, no rounding and no shadow; the mark on the iOS safe zone.
        case phone
    }

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

    /// The phone's copy: the same ground, ink, corner and themed glow, on the `.phone` grid.
    ///
    /// Uncached and default-mark only, because the running app never asks for it. The phone
    /// cannot generate an icon at runtime, so this exists for the render test that feeds
    /// `scripts/generate_mobile_theme_icons.sh`, and that covers the stock library — whose marks
    /// are all the default one.
    static func phoneImage(for theme: AppTheme, appearance: NSAppearance) -> NSImage? {
        guard let recipe = Recipe(theme: theme, appearance: appearance, grid: .phone) else {
            return nil
        }
        return draw(recipe)
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
        let grid: Grid

        /// A contributed theme's own mark, drawn in place of the default Threading mark.
        ///
        /// The **plate is never the extension's** — it is the theme's `ground`, drawn here — so
        /// a package supplies a glyph rather than an icon. That is what keeps every contributed
        /// theme's Dock tile recognisably this app's, and what makes shipping a copy of some
        /// other application's icon useless rather than merely discouraged.
        /// `ExtensionBundleLoader` refuses a mark that fills its own bounds, so by the time one
        /// arrives here it has transparency to composite against.
        var mark: NSImage?

        /// How the theme finishes the Threading mark's six corners — the outline's joins.
        ///
        /// Joins only, never caps. The strands' outer ends are buried under the outline, and
        /// their inner ends meet in the knot, which is a join and not a corner: a square-cut
        /// strand end is a slanted cut whose corners poke out of the knot on one side and leave
        /// a notch on the other, six times round, on every mitred theme. The brand mark ends
        /// every strand round for that reason, and so does `ThreadingMarkView`.
        enum Corner {
            case round
            case mitred

            var lineJoin: NSBezierPath.LineJoinStyle { self == .round ? .round : .miter }
        }

        struct Shadow {
            let color: NSColor
            let blur: CGFloat
            let offset: CGSize
        }

        /// Nil for the System theme, whose answer is the bundle icon.
        init?(theme: AppTheme, appearance: NSAppearance, grid: Grid = .dock) {
            guard theme.id != .system else { return nil }

            var resolvedGround = NSColor.black
            var resolvedInk = NSColor.white
            var resolvedShadow: Shadow?

            // Stated, not ambient. Material is variant-owned — a pale style may want a hard ink
            // shadow where its night counterpart wants a restrained glow — so `theme.material`
            // answers for whatever appearance AppKit last had in hand, which here is whatever
            // happened to draw last rather than the icon being asked for.
            let material = theme.material(for: appearance)
            // The glow is scaled to the mark's stroke, and the mark's stroke follows the grid.
            let shadowScale = Layout.shadowScale(for: grid)

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
                // correction.
                //
                // Asked for with `inkContrastMargin` on top, because this ink is measured where
                // it lands rather than where it was chosen. `legible(on:)` returns the colour
                // sitting exactly on the ratio, and the trip to a raster — eight bits a channel,
                // through the bitmap's own colour space — costs about a hundredth of a ratio
                // point. IRIX Indigo Magic is the theme thin enough to show it: its accent is
                // floored from 2.46 up to the boundary and rendered back at 2.9929:1, failing a
                // floor of 3 that it had in fact been given.
                let ink = (theme.resolved(.accent, appearance: appearance)
                    .usingColorSpace(.sRGB) ?? .white)
                    .legible(
                        on: ground,
                        ratio: ThemeContrast.minimumRatio + Layout.inkContrastMargin
                    )

                resolvedGround = ground
                resolvedInk = ink

                if let glow = material.glow {
                    let color = theme.resolved(glow.role, appearance: appearance)
                        .usingColorSpace(.sRGB) ?? .black
                    resolvedShadow = Shadow(
                        color: color.withAlphaComponent(CGFloat(glow.opacity)),
                        blur: glow.radius * shadowScale,
                        // The layer's sign, unchanged. A theme states its shadow for
                        // `CALayer.shadowOffset`, which `Design.applyThemeGlow` passes straight
                        // through in the layer's y-up space — so Bauhaus's `offsetY: -4` is a
                        // lift cast *downward*, which is what a printed style means — and
                        // `NSShadow` in the bitmap context `draw` sets up reads y the same way.
                        // It did not while the icon was an `NSImage` drawing handler: that
                        // resolved the same number the other way, the value was negated here to
                        // compensate, and moving into the bitmap context flipped it back.
                        // `testAPrintedStyleCastsItsLiftDownAndRight` holds the sign.
                        offset: CGSize(
                            width: glow.offsetX * shadowScale,
                            height: glow.offsetY * shadowScale
                        )
                    )
                }
            }

            ground = resolvedGround
            ink = resolvedInk
            shadow = resolvedShadow
            // The mark is a small element, so its corners follow the radius the theme gives its
            // small elements. Without this Bauhaus and Newsprint are two beige plates carrying
            // the same rounded mark; with it one is printed with hard corners and the other is
            // not.
            corner = material.controlRadius >= Layout.roundedControlThreshold
                ? .round
                : .mitred
            self.grid = grid
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
            return "\(grid)-\(ground.hexString)-\(ink.hexString)-\(corner)-\(shadowKey)-\(markKey)"
        }
    }

    // MARK: - Private Methods

    /// Rasterized once, at the canvas size, rather than left as a drawing handler.
    ///
    /// A Core Graphics shadow is stated in **device** space: drawn through a handler into a
    /// 256px raster, a 40pt offset is still 40 pixels — four times the lift the same picture
    /// carries at 1024, and the contact sheet the shadow scale was judged on is drawn at 256.
    /// Drawing the plate, the mark and their shadows into one 1024 bitmap makes the picture the
    /// same at every size the Dock, the switcher, a preview or a test asks for, because each of
    /// them then scales pixels rather than re-running the shadow at its own scale.
    private static func draw(_ recipe: Recipe) -> NSImage {
        let side = Int(canvasSide)
        let image = NSImage(size: NSSize(width: canvasSide, height: canvasSide))
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
        ), let context = NSGraphicsContext(bitmapImageRep: raster) else { return image }
        raster.size = image.size
        let canvas = NSRect(origin: .zero, size: image.size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let markBox: NSRect
        switch recipe.grid {
        case .dock:
            let body = canvas.insetBy(
                dx: canvasSide * (1 - Layout.bodyRatio) / 2,
                dy: canvasSide * (1 - Layout.bodyRatio) / 2
            )
            let radius = body.width * Layout.cornerRatio
            let plate = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
            drawPlate(plate, fill: recipe.ground, body: body)
            // Clipped to the plate so a hard printed shadow — Bauhaus, Neo Brutalism — lands
            // on the tile rather than hanging off its corner into the Dock.
            plate.setClip()
            markBox = Layout.markBox(on: .dock, in: body)
        case .phone:
            // No plate and no shadow: the Home Screen masks the tile and lights nothing under
            // it, so the ground runs to every edge and the mark sits on the platform's safe
            // zone, where `scripts/generate_mobile_app_icon.swift` puts the brand mark.
            recipe.ground.setFill()
            canvas.fill()
            markBox = Layout.markBox(on: .phone, in: canvas)
        }

        if let mark = recipe.mark {
            drawMark(mark, recipe, in: markBox)
        } else {
            drawThreadingMark(recipe, in: markBox)
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(raster)
        return image
    }

    /// The plate, under the drop shadow the Dock does not add for a runtime icon.
    private static func drawPlate(_ plate: NSBezierPath, fill: NSColor, body: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let cast = NSShadow()
        cast.shadowColor = NSColor.black.withAlphaComponent(Layout.plateShadowOpacity)
        cast.shadowBlurRadius = body.width * Layout.plateShadowBlurRatio
        // Downward: y is up in the bitmap context `draw` sets up, as it is for a layer. Through
        // the `NSImage` drawing handler the icon used to be, the same value cast the shadow
        // *above* the plate, which nothing on the platform does, and nothing noticed because the
        // Mac's margin is transparent; the phone's copy composited it over the ground and showed
        // a border darker along its top edge than its bottom.
        // `testThePlateShadowFallsBelowTheDockIcon` holds the sign.
        cast.shadowOffset = CGSize(width: 0, height: -body.width * Layout.plateShadowOffsetRatio)
        cast.set()
        fill.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A contributed mark, fitted inside the mark box and wearing the theme's own shadow.
    ///
    /// **Aspect is preserved and the mark is never upscaled past the safe area.** An author
    /// exports whatever shape their glyph is; forcing it into a square would letterbox some
    /// marks and stretch others, and neither is a failure the author can see from their own
    /// asset. The theme's glow applies here for the same reason it applies to the default mark — a
    /// printed style's mark should sit on the page the way its panels do.
    private static func drawMark(_ mark: NSImage, _ recipe: Recipe, in markBox: NSRect) {
        let size = mark.size
        guard size.width > 0, size.height > 0 else { return }

        let safe = markBox.insetBy(
            dx: markBox.width * Layout.contributedMarkInsetRatio,
            dy: markBox.height * Layout.contributedMarkInsetRatio
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

    /// The Threading mark, whose geometry is stated as fractions of `markBox`.
    private static func drawThreadingMark(_ recipe: Recipe, in markBox: NSRect) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(
                x: markBox.minX + markBox.width * x,
                y: markBox.minY + markBox.height * y
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
        outer.lineWidth = markBox.width * Layout.outerStrokeRatio
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
        spoke.lineWidth = markBox.width * Layout.strokeRatio
        // Round whatever the theme's corners are: see `Corner`.
        spoke.lineCapStyle = .round

        let center = NSBezierPath()
        // Slightly larger than the display SVG's junction, so the gaps between adjacent round
        // strand ends are covered and the center reads genuinely solid on every material.
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
        /// The Dock's mark gets more air than the standalone SVG because it sits inside a
        /// rounded app-icon plate and carries the theme's glow or printed lift around it.
        static let defaultMarkScale: CGFloat = 0.76

        /// The iOS icon grid: the whole 1024 canvas is the tile, and the mark box is the
        /// platform's safe zone — 840 of it, the same 92pt inset
        /// `scripts/generate_mobile_app_icon.swift` fits the brand mark into for the primary
        /// icon. A theme's mark is therefore the brand mark's size, and choosing an icon on the
        /// phone changes the paint and nothing else.
        static let phoneSafeZoneRatio: CGFloat = 840.0 / 1024.0

        /// A theme that rounds its controls rounds the mark.
        static let roundedControlThreshold: CGFloat = 6

        /// Asked for on top of `ThemeContrast.minimumRatio` when flooring the mark's ink.
        ///
        /// `legible(on:)` answers with the colour sitting *exactly* on the ratio, and this ink
        /// is then judged where it lands: rounded to eight bits a channel and converted into
        /// whatever colour space the raster keeps. That trip costs a hundredth of a ratio point
        /// or so, which is enough to put a boundary answer under the floor it was given.
        /// A twentieth is far more than the loss and far less than a visible change of colour.
        static let inkContrastMargin: CGFloat = 0.05

        /// The margin a contributed mark keeps inside the mark box, per edge — so it stays a
        /// little smaller than the default mark's extents.
        ///
        /// A contributed mark keeps the same safe-area discipline as the default mark. A mark
        /// drawn to the plate's edge would read as a different *kind* of icon beside every stock
        /// style, which is the one thing the mark-only rule exists to prevent.
        static let contributedMarkInsetRatio: CGFloat = 0.05

        /// The square the mark's geometry is stated in, for one grid.
        ///
        /// On the Dock it is the plate scaled about its centre by `defaultMarkScale`; on the
        /// phone it is the safe zone of the whole canvas.
        static func markBox(on grid: Grid, in body: NSRect) -> NSRect {
            let scale: CGFloat
            switch grid {
            case .dock: scale = defaultMarkScale
            case .phone: scale = phoneSafeZoneRatio
            }
            return body.insetBy(
                dx: body.width * (1 - scale) / 2,
                dy: body.height * (1 - scale) / 2
            )
        }

        /// The mark box's side on the 1024 canvas, per grid.
        static func markBoxSide(on grid: Grid) -> CGFloat {
            switch grid {
            case .dock: return canvasSide * bodyRatio * defaultMarkScale
            case .phone: return canvasSide * phoneSafeZoneRatio
            }
        }

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
        static func shadowScale(for grid: Grid) -> CGFloat {
            (markBoxSide(on: grid) * strokeRatio) / chromeReferenceInk
        }

        /// The shadow the Dock adds for a bundle icon and does not add for a runtime one.
        static let plateShadowOpacity: CGFloat = 0.28
        static let plateShadowBlurRatio: CGFloat = 0.055
        static let plateShadowOffsetRatio: CGFloat = 0.022
    }
}
