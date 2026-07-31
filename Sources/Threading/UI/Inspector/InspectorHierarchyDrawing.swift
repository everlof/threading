import AppKit

// MARK: - Shared Primitives

/// The pieces both the plain outline and the hierarchy overlay draw with, in one place so the
/// two surfaces the inspector renders on — the live overlay and the captured bitmap — cannot
/// drift apart.
@MainActor
enum InspectorDrawing {

    /// Resolved before any alpha is applied: `withAlphaComponent` *replaces* alpha, and a
    /// theme's accent is free to be translucent already — the ThemedButton lesson.
    static func resolvedAccent() -> NSColor {
        Design.Surface.accent.usingColorSpace(.sRGB) ?? Design.Surface.accent
    }

    /// The label badge, preferring the space above the rect and falling inside it when the
    /// rect already touches the top — a highlight on the toolbar would otherwise push its
    /// own name off the window.
    static func badge(_ label: String, above rect: NSRect, within bounds: NSRect) {
        drawBadge(label, in: badgeRect(label, above: rect, within: bounds))
    }

    /// Where the badge lands, separately from drawing it, so the layered overlay can *reserve*
    /// that space before placing anything else. The badge is the largest label on screen and
    /// the one whose position is not negotiable; everything else has somewhere else to go.
    static func badgeRect(_ label: String, above rect: NSRect, within bounds: NSRect) -> NSRect {
        let size = badgeSize(label)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + Design.Spacing.tight)
        if origin.y + size.height > bounds.maxY {
            origin.y = rect.maxY - size.height - Design.Spacing.tight
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))

        return NSRect(origin: origin, size: size)
    }

    static func drawBadge(_ label: String, in rect: NSRect, border: NSColor? = nil) {
        let attributes = textAttributes(font: Design.Typography.caption(), color: Design.Text.label)

        panel(rect, radius: Design.Radius.control, border: border ?? Design.Surface.border)

        (label as NSString).draw(
            at: NSPoint(
                x: rect.minX + Design.Spacing.medium,
                y: rect.minY + Design.Spacing.tight
            ),
            withAttributes: attributes
        )
    }

    private static func badgeSize(_ label: String) -> NSSize {
        let attributes = textAttributes(font: Design.Typography.caption(), color: Design.Text.label)
        let textSize = (label as NSString).size(withAttributes: attributes)
        return NSSize(
            width: ceil(textSize.width) + Design.Spacing.medium * 2,
            height: ceil(textSize.height) + Design.Spacing.tight * 2
        )
    }

    /// A filled, bordered surface — every panel the inspector floats over the window.
    static func panel(_ rect: NSRect, radius: CGFloat, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        Design.Surface.elevated.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = Design.Radius.border
        path.stroke()
    }

    /// Measured and drawn with one set of attributes, always: a title measured a hair too
    /// narrow for its own rect wraps and loses its second word below the box.
    static func textAttributes(
        font: NSFont,
        color: NSColor,
        truncating: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        if truncating {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }

        return attributes
    }

    /// White or black, whichever the hue can be read against.
    ///
    /// A deliberate exception to the system-colours rule, and the same one
    /// `ProjectIconStore`'s backplate takes: this ink exists to *oppose* the fill under it, and
    /// every semantic colour follows the appearance instead of the swatch it lands on.
    static func ink(on color: NSColor) -> NSColor {
        let brightness = color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        return brightness > InspectorDefaults.inkFlipBrightness ? .black : .white
    }
}

// MARK: - Hierarchy Drawing

/// The layered element overlay: every level outlined in its own hue, the gaps between them
/// measured, and a legend saying which hue is which class.
///
/// Three rules keep a ten-deep chain readable rather than making it a smear:
///
/// - **Only the target is filled.** Ten translucent washes stacked over one another is a
///   gradient, not a hierarchy; the ancestors are outlines and nothing else.
/// - **Hue means depth, and the ramp cycles**, so a deep enough chain repeats a colour. The
///   numbered chip on each rectangle is what resolves that, and it is the same number the
///   legend row carries.
/// - **A measure is drawn in the *parent's* hue**, because it starts at the parent's edge and
///   the layout that chose it almost always lives there.
@MainActor
enum InspectorHierarchyDrawing {

    // MARK: - Public Methods

    static func draw(levels: [InspectorLevel], layers: InspectorLayers, within bounds: NSRect) {
        guard let target = levels.first else { return }

        let layered = !layers.isEmpty
        let shown = InspectorHierarchy.shown(levels, for: layers)

        // Outermost first, so an inner outline is never drawn under the one containing it.
        for level in shown.reversed() {
            outline(level, isTarget: level.depth == target.depth, layered: layered)
        }

        // Everything below is a small box wanting a spot near what it names, and around a
        // small component they all want the same one. Placement order is priority order, so
        // the badge goes down first and the target's own gaps before its ancestors'.
        var packer = InspectorLabelPacker()

        let badgeText = badgeLabel(for: target)
        let badgeRect = InspectorDrawing.badgeRect(badgeText, above: target.rect, within: bounds)
        packer.reserve(badgeRect)

        // Depth 1 outward only: the target is the filled one, it carries the badge, and its
        // badge is drawn in its own hue — a chip on top of it would say what three other
        // things already say, on the element least able to spare the pixels.
        if layered {
            for level in shown where level.depth > target.depth {
                chip(level, packer: &packer, within: bounds)
            }
        }

        // **The canvas measures one thing: the element you picked, inside the level holding
        // it.** Measuring every pair was the first version and it does not survive a real
        // window — a 14pt sidebar icon sits eight levels deep, which is twenty-eight numbers
        // fighting for the same corner, and the four that were asked for are lost among them.
        // Every other pair is measured in the key, where text costs a line and nothing is
        // covered by it.
        if layers.contains(.spacing), let pair = InspectorSpacing.gaps(across: shown).first {
            for gap in pair.gaps {
                measure(gap, hue: pair.parent.hue.color, packer: &packer, within: bounds)
            }
        }

        InspectorDrawing.drawBadge(
            badgeText,
            in: badgeRect,
            border: layered ? target.hue.color : Design.Surface.border
        )

        legend(shown, layers: layers, within: bounds)
    }

    /// The target's own badge text, which is what the plain unlayered outline shows too.
    static func badgeLabel(for level: InspectorLevel) -> String {
        "\(level.title) — \(level.size)"
    }

    // MARK: - Private Methods

    private static func outline(_ level: InspectorLevel, isTarget: Bool, layered: Bool) {
        // Unlayered, the target keeps the accent it has always had. Layered, colour stops
        // meaning "this is the pick" and starts meaning "this is depth N", for every level
        // including the target — a target left accent-coloured collides with whichever ramp
        // hue the accent happens to be.
        let color = layered ? level.hue.color : InspectorDrawing.resolvedAccent()

        if isTarget {
            color.withAlphaComponent(color.alphaComponent * InspectorDefaults.fillAlpha).setFill()
            level.rect.fill(using: .sourceOver)
        }

        let width = isTarget
            ? InspectorDefaults.strokeWidth
            : InspectorDefaults.ancestorStrokeWidth
        let inset = width / 2

        color.setStroke()
        let path = NSBezierPath(rect: level.rect.insetBy(dx: inset, dy: inset))
        path.lineWidth = width
        path.stroke()
    }

    /// The depth number at the level's top-leading corner: inside it when the rectangle has
    /// room, outside when it has not. Small, because it is a key into the legend rather than a
    /// label — the legend is where the names are.
    private static func chip(
        _ level: InspectorLevel,
        packer: inout InspectorLabelPacker,
        within bounds: NSRect
    ) {
        let text = "\(level.depth)"
        let attributes = InspectorDrawing.textAttributes(
            font: Design.Typography.compactCode(),
            color: InspectorDrawing.ink(on: level.hue.color)
        )
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(
            width: max(InspectorDefaults.chipSize, ceil(textSize.width) + Design.Spacing.small),
            height: InspectorDefaults.chipSize
        )

        let rect = packer.place(
            size: size,
            candidates: InspectorChipPlacement.candidates(for: level.rect, size: size),
            within: bounds
        )
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Design.Radius.control(fitting: size),
            yRadius: Design.Radius.control(fitting: size)
        )
        level.hue.color.setFill()
        path.fill()

        (text as NSString).draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// One measured gap: a dashed run between the two edges, a tick at each end so a short
    /// measure still reads as a span, and the number in a chip the packer finds room for.
    private static func measure(
        _ gap: InspectorGap,
        hue: NSColor,
        packer: inout InspectorLabelPacker,
        within bounds: NSRect
    ) {
        hue.setStroke()

        let line = NSBezierPath()
        line.move(to: gap.start)
        line.line(to: gap.end)
        line.lineWidth = InspectorDefaults.measureWidth
        var pattern = InspectorDefaults.measureDash
        line.setLineDash(&pattern, count: pattern.count, phase: 0)
        line.stroke()

        let ticks = NSBezierPath()
        let reach = InspectorDefaults.measureTick / 2
        for point in [gap.start, gap.end] {
            if gap.isHorizontal {
                ticks.move(to: NSPoint(x: point.x, y: point.y - reach))
                ticks.line(to: NSPoint(x: point.x, y: point.y + reach))
            } else {
                ticks.move(to: NSPoint(x: point.x - reach, y: point.y))
                ticks.line(to: NSPoint(x: point.x + reach, y: point.y))
            }
        }
        ticks.lineWidth = InspectorDefaults.measureWidth
        ticks.stroke()

        measureLabel(gap.label, on: gap, hue: hue, packer: &packer, within: bounds)
    }

    /// The number, in a chip the packer finds room for — and a **leader** back to the measure
    /// when that room was not on the measure itself.
    ///
    /// The leader is what makes a displaced label honest rather than merely tidy. Around a
    /// small component every number is displaced, and four numbers floating near a 13pt icon
    /// belong to nothing in particular; a hairline from the chip to the middle of the gap it
    /// came from says which one each is.
    private static func measureLabel(
        _ text: String,
        on gap: InspectorGap,
        hue: NSColor,
        packer: inout InspectorLabelPacker,
        within bounds: NSRect
    ) {
        let attributes = InspectorDrawing.textAttributes(
            font: Design.Typography.compactCode(),
            color: Design.Text.label
        )
        let textSize = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(
            width: ceil(textSize.width) + Design.Spacing.small,
            height: ceil(textSize.height) + Design.Spacing.hairline
        )

        let rect = packer.place(
            size: size,
            candidates: gap.labelCandidates(size: size),
            within: bounds
        )

        let middle = NSPoint(x: (gap.start.x + gap.end.x) / 2, y: (gap.start.y + gap.end.y) / 2)
        if !rect.insetBy(dx: -InspectorDefaults.labelClearance, dy: -InspectorDefaults.labelClearance)
            .contains(middle) {
            let leader = NSBezierPath()
            leader.move(to: middle)
            leader.line(to: nearestEdgePoint(of: rect, to: middle))
            leader.lineWidth = InspectorDefaults.measureWidth
            hue.withAlphaComponent(
                hue.alphaComponent * InspectorDefaults.leaderAlpha
            ).setStroke()
            leader.stroke()
        }

        InspectorDrawing.panel(rect, radius: Design.Radius.control(fitting: size), border: hue)

        (text as NSString).draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// Where a leader should meet its chip: the point on the chip's edge closest to the
    /// measure, so the line stops at the box rather than running under it.
    private static func nearestEdgePoint(of rect: NSRect, to point: NSPoint) -> NSPoint {
        NSPoint(
            x: max(rect.minX, min(point.x, rect.maxX)),
            y: max(rect.minY, min(point.y, rect.maxY))
        )
    }

    // MARK: - Legend

    /// The colour key, plus the line that says the two modifiers exist at all.
    ///
    /// The hint is drawn whether anything is held or not: a modifier nothing mentions is a
    /// feature nobody finds, and element mode is exactly where the question it answers gets
    /// asked. Under a modifier the legend grows above it.
    private static func legend(
        _ levels: [InspectorLevel],
        layers: InspectorLayers,
        within bounds: NSRect
    ) {
        let rowAttributes = InspectorDrawing.textAttributes(
            font: Design.Typography.code(),
            color: Design.Text.label,
            truncating: true
        )
        // Truncating rather than wrapping, both of them: the panel is sized from these very
        // strings, and a string measured a hair narrower than the box it is drawn in breaks at
        // the space and puts its last word on a line the box has no room for.
        let hintAttributes = InspectorDrawing.textAttributes(
            font: Design.Typography.detail(),
            color: Design.Text.secondary,
            truncating: true
        )

        let rows = layers.isEmpty
            ? []
            : InspectorLegendPlacement.rows(for: levels, layers: layers, within: bounds)
        let titles = rows.map(\.title)
        let hint = InspectorStrings.layerHint

        let titleCap = min(
            InspectorDefaults.legendTitleWidth,
            bounds.width * InspectorDefaults.legendTitleFraction
        )
        let textWidth = titles.reduce(
            (hint as NSString).size(withAttributes: hintAttributes).width
                - InspectorDefaults.legendSwatch - Design.Spacing.small
        ) { widest, title in
            max(widest, min(
                (title as NSString).size(withAttributes: rowAttributes).width,
                titleCap
            ))
        }

        let rowHeight = InspectorDefaults.legendRowHeight
        let width = Design.Spacing.medium * 2
            + InspectorDefaults.legendSwatch
            + Design.Spacing.small
            + ceil(textWidth)
        let height = Design.Spacing.medium * 2
            + rowHeight * CGFloat(titles.count)
            + rowHeight

        let size = NSSize(width: width, height: height)
        let panel = NSRect(
            origin: InspectorLegendPlacement.origin(
                size: size,
                target: levels.first?.rect ?? .zero,
                within: bounds
            ),
            size: size
        )
        InspectorDrawing.panel(panel, radius: Design.Radius.panel, border: Design.Surface.border)

        (hint as NSString).draw(
            in: NSRect(
                x: panel.minX + Design.Spacing.medium,
                y: panel.minY + Design.Spacing.medium,
                width: width - Design.Spacing.medium * 2,
                height: rowHeight
            ),
            withAttributes: hintAttributes
        )

        // Target first, reading outward — the order the report's own legend is written in, so
        // the picture and the pasted text can be followed together.
        for (index, row) in rows.enumerated() {
            let y = panel.maxY - Design.Spacing.medium - rowHeight * CGFloat(index + 1)

            let swatch = NSRect(
                x: panel.minX + Design.Spacing.medium,
                y: y + (rowHeight - InspectorDefaults.legendSwatch) / 2,
                width: InspectorDefaults.legendSwatch,
                height: InspectorDefaults.legendSwatch
            )

            if let hue = row.hue {
                let mark = NSBezierPath(
                    roundedRect: swatch,
                    xRadius: Design.Radius.control(fitting: swatch.size),
                    yRadius: Design.Radius.control(fitting: swatch.size)
                )
                hue.color.setFill()
                mark.fill()
            }

            (row.title as NSString).draw(
                in: NSRect(
                    x: swatch.maxX + Design.Spacing.small,
                    y: y,
                    width: panel.maxX - Design.Spacing.medium - swatch.maxX - Design.Spacing.small,
                    height: rowHeight
                ),
                // The fold names no colour, so it is not drawn as though it did.
                withAttributes: row.hue == nil ? hintAttributes : rowAttributes
            )
        }
    }
}
