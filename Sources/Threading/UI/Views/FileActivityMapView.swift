import AppKit

// MARK: - File Activity Map View

/// The repo strip: every tracked file as a mark, reads glowing quietly and edits in the
/// accent, fading to a residual that remembers where the session has been.
///
/// The marks carry no labels — at a point or two per file there is no room for any, and the
/// strip is read the way an editor minimap is read: by shape and by where the light is.
/// Hovering names the file under the pointer. Untouched files rest at the quietest label
/// tier, alternating shade per top-level directory so the runs read as regions rather than
/// as one undifferentiated column.
final class FileActivityMapView: NSView {

    // MARK: - Metrics

    private enum Metrics {
        /// The dimmest a glowing mark draws; the residual floor must stay visible.
        static let minimumGlowAlpha: CGFloat = 0.25

        /// The two resting shades, multiplied onto their tiers' own alpha —
        /// `withAlphaComponent` replaces rather than scales, so the resolved alpha is read
        /// first. Alternating directory runs take one each; the gap between the tiers is
        /// what makes the runs read as regions rather than as one undifferentiated column.
        static let evenRunDimming: CGFloat = 0.55
        static let oddRunDimming: CGFloat = 0.8

        /// How often the fade is repainted while anything still glows. Heat eases over
        /// tens of seconds, so a film-rate timer would burn the battery repainting
        /// differences no eye can see.
        static let glowRefreshInterval: TimeInterval = 0.25
    }

    // MARK: - Properties

    private(set) var map = FileActivityMap(files: [])

    /// The clock heat is measured against, injectable so a render harness can draw the same
    /// moment twice.
    var clock: () -> Date = Date.init

    private var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            needsDisplay = true
        }
    }

    private var glowTimer: Timer?
    private var themeRedraw: ThemeRedraw?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        glowTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    // MARK: - Public Methods

    /// Replaces the file universe, dropping any recorded activity with it.
    func setFiles(_ paths: [String], root: String? = nil) {
        setMap(FileActivityMap(files: paths, root: root))
    }

    /// Replaces the whole map — how a harness hands over a pre-built state.
    func setMap(_ map: FileActivityMap) {
        self.map = map
        hoverIndex = nil
        needsDisplay = true
        scheduleGlowRefreshIfNeeded()
    }

    /// Sets the hovered mark directly — how the render harness draws the hover state, since
    /// a still image has no pointer to track.
    func hover(at index: Int?) {
        hoverIndex = index.flatMap { map.entries.indices.contains($0) ? $0 : nil }
    }

    /// Records what a tool call touched, if anything.
    func recordTouches(tool: ToolIdentity, input: [String: Any], at date: Date? = nil) {
        let date = date ?? clock()
        for touch in FileActivityMap.touches(tool: tool, input: input) {
            map.record(touch.kind, path: touch.path, at: date)
        }
        needsDisplay = true
        scheduleGlowRefreshIfNeeded()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = FileActivityMap.Layout.compute(count: map.entries.count, size: bounds.size)
        else { return }

        let now = clock()
        let origin = contentOrigin(for: layout)

        // Resolved once per pass rather than per mark: five thousand `NSColor` resolutions
        // per frame is the kind of cost that only shows up on the largest repo.
        let accent = Design.Surface.accent
        let read = Design.Text.secondary
        let tertiary = Design.Text.tertiary
        let quaternary = Design.Text.quaternary
        let restingEven = tertiary.withAlphaComponent(
            tertiary.alphaComponent * Metrics.evenRunDimming
        )
        let restingOdd = quaternary.withAlphaComponent(
            quaternary.alphaComponent * Metrics.oddRunDimming
        )

        for index in map.entries.indices {
            let entry = map.entries[index]
            var rect = layout.rect(at: index)
            rect.origin.x += origin.x
            rect.origin.y += origin.y

            guard rect.intersects(dirtyRect) else { continue }

            let editHeat = FileActivityMap.heat(since: entry.lastEdit, now: now)
            let readHeat = FileActivityMap.heat(since: entry.lastRead, now: now)

            let colour: NSColor
            if editHeat > 0, editHeat >= readHeat {
                colour = accent.withAlphaComponent(accent.alphaComponent * glowAlpha(editHeat))
            } else if readHeat > 0 {
                colour = read.withAlphaComponent(read.alphaComponent * glowAlpha(readHeat))
            } else {
                colour = entry.runOrdinal.isMultiple(of: 2) ? restingEven : restingOdd
            }

            (index == hoverIndex ? Design.Text.label : colour).setFill()
            rect.fill()
        }

        drawHoverLabel(layout: layout, origin: origin)
    }

    private func glowAlpha(_ heat: Double) -> CGFloat {
        Metrics.minimumGlowAlpha + (1 - Metrics.minimumGlowAlpha) * CGFloat(heat)
    }

    /// The strip is centred in the pane on both axes: it is an index of the repo, not a
    /// scale of the view, and pinning it to a corner reads as a layout accident.
    private func contentOrigin(for layout: FileActivityMap.Layout) -> CGPoint {
        let contentHeight = CGFloat(layout.rowsPerColumn) * layout.rowPitch
        return CGPoint(
            x: max(0, (bounds.width - layout.contentWidth) / 2),
            y: max(0, (bounds.height - contentHeight) / 2)
        )
    }

    private func drawHoverLabel(layout: FileActivityMap.Layout, origin: CGPoint) {
        guard let hoverIndex, map.entries.indices.contains(hoverIndex) else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(),
            .foregroundColor: Design.Text.label
        ]
        let padding = Design.Spacing.tight
        let text = truncatedFromTheHead(
            map.entries[hoverIndex].path,
            toFit: bounds.width - padding * 2,
            attributes: attributes
        )
        let size = text.size(withAttributes: attributes)

        var mark = layout.rect(at: hoverIndex)
        mark.origin.x += origin.x
        mark.origin.y += origin.y

        // Beside the mark's row, pulled back inside the pane when the path runs long. The
        // wash behind it is what keeps the label legible over the marks it crosses.
        var frame = NSRect(
            x: mark.minX,
            y: min(max(0, mark.midY - size.height / 2), bounds.height - size.height - padding * 2),
            width: size.width + padding * 2,
            height: size.height + padding * 2
        )
        frame.origin.x = min(frame.origin.x, max(0, bounds.width - frame.width))

        let wash = NSBezierPath(
            roundedRect: frame,
            xRadius: Design.Spacing.tight,
            yRadius: Design.Spacing.tight
        )
        Design.Surface.elevated.setFill()
        wash.fill()
        Design.Surface.border.setStroke()
        wash.stroke()

        text.draw(
            at: NSPoint(x: frame.minX + padding, y: frame.minY + padding),
            withAttributes: attributes
        )
    }

    /// Drops leading path components until the label fits — the tail is the identifying
    /// part of a path, and a name clipped at the *end* hides exactly it.
    private func truncatedFromTheHead(
        _ path: String,
        toFit width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSString {
        var text = path as NSString
        var components = path.split(separator: "/").map(String.init)

        while text.size(withAttributes: attributes).width > width, components.count > 1 {
            components.removeFirst()
            text = ("…/" + components.joined(separator: "/")) as NSString
        }
        return text
    }

    // MARK: - Glow Refresh

    /// Repaints while anything is still fading, and stops itself the moment nothing is —
    /// a strip nobody has touched costs nothing.
    private func scheduleGlowRefreshIfNeeded() {
        guard glowTimer == nil, map.hasActiveGlow(now: clock()) else { return }

        glowTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.glowRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            needsDisplay = true
            if !map.hasActiveGlow(now: clock()) {
                glowTimer?.invalidate()
                glowTimer = nil
            }
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverIndex(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverIndex(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
    }

    private func updateHoverIndex(with event: NSEvent) {
        guard let layout = FileActivityMap.Layout.compute(count: map.entries.count, size: bounds.size)
        else {
            hoverIndex = nil
            return
        }

        let origin = contentOrigin(for: layout)
        let point = convert(event.locationInWindow, from: nil)
        let column = Int((point.x - origin.x) / layout.columnPitch)
        let row = Int((point.y - origin.y) / layout.rowPitch)

        guard column >= 0, column < layout.columnCount, row >= 0, row < layout.rowsPerColumn
        else {
            hoverIndex = nil
            return
        }

        let index = column * layout.rowsPerColumn + row
        hoverIndex = map.entries.indices.contains(index) ? index : nil
    }

    // MARK: - Accessibility

    /// A drawn view is invisible to VoiceOver unless it says otherwise — the trap
    /// `ThemedControl` documents, walked into by every view that renders itself.
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        let touched = map.touchedCount
        let total = map.entries.count
        guard total > 0 else { return "File activity map, empty" }
        return "File activity map, \(touched) of \(total) files touched"
    }
}
