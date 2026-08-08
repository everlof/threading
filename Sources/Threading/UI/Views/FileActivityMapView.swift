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

    fileprivate enum Metrics {
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

        static let railReadHeight: CGFloat = 1
        static let detailGap: CGFloat = 1
    }

    // MARK: - Properties

    private(set) var map = FileActivityMap(files: [])
    private(set) var workPresentation: AgentWorkPresentation?
    private var workTarget: AgentWorkTarget?
    /// Whether this instance is a store-backed projection rather than a standalone detail map.
    /// A nil target is still a valid bound state for a sidebar row with no project yet, and that
    /// three-point rail must remain decorative while the row is being configured.
    private var isStoreBound = false

    /// The clock heat is measured against, injectable so a render harness can draw the same
    /// moment twice.
    var clock: () -> Date = Date.init

    private var hoverIndex: Int? {
        didSet {
            guard hoverIndex != oldValue else { return }
            needsDisplay = true
        }
    }

    nonisolated(unsafe) private var glowTimer: Timer?
    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeRedraw = ThemeRedraw(self)
        appEvents.observe(AgentWorkDidChange.self) { [weak self] event in
            guard let self, let target = self.workTarget,
                  target.projectID == event.projectID,
                  target.sessionID == nil || target.sessionID == event.sessionID else { return }
            self.refreshBoundPresentation()
        }
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
        isStoreBound = false
        workTarget = nil
        workPresentation = nil
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

    /// Binds a sidebar rail or detail atlas to the store. The first read is an O(1) cache
    /// lookup; repository enumeration and projection happen asynchronously on a utility queue.
    func bind(to target: AgentWorkTarget?) {
        isStoreBound = true
        guard target != workTarget else {
            refreshBoundPresentation()
            return
        }
        workTarget = target
        workPresentation = nil
        hoverIndex = nil
        refreshBoundPresentation()
    }

    /// Direct injection for render tests and the Component Gallery.
    func setWorkPresentation(_ presentation: AgentWorkPresentation?) {
        isStoreBound = false
        workTarget = nil
        workPresentation = presentation
        hoverIndex = nil
        needsDisplay = true
        scheduleGlowRefreshIfNeeded()
    }

    private func refreshBoundPresentation() {
        guard let target = workTarget else { return }
        if let presentation = AgentWorkTraceStore.shared.presentation(for: target) {
            workPresentation = presentation
            hoverIndex = hoverIndex.flatMap {
                presentation.bins.indices.contains($0) ? $0 : nil
            }
            needsDisplay = true
            scheduleGlowRefreshIfNeeded()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let workPresentation {
            draw(workPresentation, dirtyRect: dirtyRect)
            return
        }
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

    private func draw(_ presentation: AgentWorkPresentation, dirtyRect: NSRect) {
        guard !presentation.bins.isEmpty else { return }
        let now = clock()
        let accent = Design.Surface.accent
        // Reads and edits belong to one semantic family. Sharing the accent makes a read-only
        // session visible under System too; thickness, rather than a fragile second hue, tells
        // the two facts apart.
        let read = accent.withAlphaComponent(accent.alphaComponent * 0.7)
        let tertiary = Design.Text.tertiary
        let quaternary = Design.Text.quaternary
        let restingEven = tertiary.withAlphaComponent(
            tertiary.alphaComponent * Metrics.evenRunDimming
        )
        let restingOdd = quaternary.withAlphaComponent(
            quaternary.alphaComponent * Metrics.oddRunDimming
        )
        let layout = WorkProjectionLayout(
            count: presentation.bins.count,
            bounds: bounds,
            detailed: presentation.isDetailed
        )

        for index in presentation.bins.indices {
            let rect = layout.rect(at: index)
            guard rect.intersects(dirtyRect), rect.width > 0, rect.height > 0 else { continue }
            let bin = presentation.bins[index]

            let resting = bin.seed.runOrdinal.isMultiple(of: 2) ? restingEven : restingOdd
            resting.setFill()
            rect.fill()

            let readHeat = FileActivityMap.heat(since: bin.lastRead, now: now)
            let editHeat = FileActivityMap.heat(since: bin.lastEdit, now: now)
            if editHeat > 0 {
                accent.withAlphaComponent(accent.alphaComponent * glowAlpha(editHeat)).setFill()
                rect.fill()
            }
            if readHeat > 0 {
                read.withAlphaComponent(read.alphaComponent * glowAlpha(readHeat)).setFill()
                let height = presentation.isDetailed
                    ? max(1, floor(rect.height * 0.32))
                    : min(rect.height, Metrics.railReadHeight)
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height).fill()
            }

            // In the project aggregate, a light cap says the same region has more than one
            // agent behind it. The exact recent agents remain textual in the detail card.
            if presentation.scope.isProject, bin.contributorCount > 1 {
                Design.Text.label.withAlphaComponent(0.55).setFill()
                let cap = min(rect.height, max(1, CGFloat(min(bin.contributorCount, 3))))
                NSRect(x: rect.minX, y: rect.maxY - cap, width: rect.width, height: cap).fill()
            }

            if index == hoverIndex {
                Design.Text.label.setStroke()
                let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.stroke()
            }
        }

        if presentation.isDetailed {
            drawWorkHoverLabel(presentation, layout: layout)
        }
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
        guard window != nil, glowTimer == nil, hasActiveGlow(now: clock()) else { return }

        glowTimer = Timer.scheduledTimer(
            timeInterval: Metrics.glowRefreshInterval,
            target: self,
            selector: #selector(refreshGlow),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func refreshGlow() {
        needsDisplay = true
        if !hasActiveGlow(now: clock()) {
            glowTimer?.invalidate()
            glowTimer = nil
        }
    }

    private func hasActiveGlow(now: Date) -> Bool {
        if let workPresentation {
            return workPresentation.bins.contains { bin in
                [bin.lastRead, bin.lastEdit].contains { touch in
                    guard let touch else { return false }
                    return now.timeIntervalSince(touch) < FileActivityMap.Metrics.glowDuration
                }
            }
        }
        return map.hasActiveGlow(now: now)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            glowTimer?.invalidate()
            glowTimer = nil
        } else {
            scheduleGlowRefreshIfNeeded()
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
        if let presentation = workPresentation {
            guard presentation.isDetailed else {
                hoverIndex = nil
                return
            }
            let layout = WorkProjectionLayout(
                count: presentation.bins.count,
                bounds: bounds,
                detailed: true
            )
            hoverIndex = layout.index(at: convert(event.locationInWindow, from: nil))
            return
        }
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
    override func isAccessibilityElement() -> Bool {
        workPresentation?.isDetailed != false
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        if let workPresentation {
            let scope = workPresentation.scope.isProject
                ? L10n.string("Project work map")
                : L10n.string("Agent work map")
            return L10n.format(
                "%@, %d of %d files touched",
                scope,
                workPresentation.touchedFileCount,
                max(
                    workPresentation.repositoryFileCount,
                    workPresentation.touchedFileCount
                )
            )
        }
        let touched = map.touchedCount
        let total = map.entries.count
        guard total > 0 else { return "File activity map, empty" }
        return "File activity map, \(touched) of \(total) files touched"
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A sidebar rail is decorative from the moment it is bound, including while its
        // asynchronous atlas projection is still loading. Keying this only off the completed
        // presentation left a short (and, in a hosted row, deterministic) interval where the
        // three-point strip stole clicks from the row and its trailing buttons.
        if isStoreBound && workTarget?.isDetailed != true { return nil }
        if workPresentation?.isDetailed == false { return nil }
        return super.hitTest(point)
    }

    private func drawWorkHoverLabel(
        _ presentation: AgentWorkPresentation,
        layout: WorkProjectionLayout
    ) {
        guard let hoverIndex, presentation.bins.indices.contains(hoverIndex) else { return }
        let bin = presentation.bins[hoverIndex]
        var text = bin.seed.isOverflow ? L10n.string("New files") : bin.seed.directory
        if text.isEmpty { text = bin.seed.firstPath }
        if bin.seed.fileCount > 1 {
            text += L10n.format(
                " · %d/%d files", bin.touchedFileCount, bin.seed.fileCount
            )
        }
        if bin.contributorCount > 1 {
            text += L10n.format(" · %d agents", bin.contributorCount)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.detail(),
            .foregroundColor: Design.Text.label
        ]
        let padding = Design.Spacing.tight
        let label = truncatedFromTheHead(
            text, toFit: bounds.width - padding * 2, attributes: attributes
        )
        let size = label.size(withAttributes: attributes)
        let mark = layout.rect(at: hoverIndex)
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
        label.draw(
            at: NSPoint(x: frame.minX + padding, y: frame.minY + padding),
            withAttributes: attributes
        )
    }
}

private extension AgentWorkPresentation.Scope {
    var isProject: Bool {
        if case .project = self { return true }
        return false
    }
}

private struct WorkProjectionLayout {
    let count: Int
    let bounds: NSRect
    let detailed: Bool
    let columns: Int
    let rows: Int

    init(count: Int, bounds: NSRect, detailed: Bool) {
        self.count = count
        self.bounds = bounds
        self.detailed = detailed
        if detailed, count > 0, bounds.width > 0, bounds.height > 0 {
            columns = max(1, Int(ceil(sqrt(
                Double(count) * Double(bounds.width / max(bounds.height, 1))
            ))))
            rows = max(1, Int(ceil(Double(count) / Double(columns))))
        } else {
            columns = max(1, count)
            rows = 1
        }
    }

    func rect(at index: Int) -> NSRect {
        guard count > 0 else { return .zero }
        if !detailed {
            let lower = bounds.minX + floor(CGFloat(index) * bounds.width / CGFloat(count))
            let upper = bounds.minX + floor(CGFloat(index + 1) * bounds.width / CGFloat(count))
            return NSRect(x: lower, y: bounds.minY, width: max(0.5, upper - lower), height: bounds.height)
        }

        // Path order runs top-to-bottom, then into the next column, matching the original
        // FileActivityMap and keeping contiguous directories spatially contiguous.
        let column = index / rows
        let row = index % rows
        let gap = FileActivityMapView.Metrics.detailGap
        let width = max(0, (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let height = max(0, (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        return NSRect(
            x: bounds.minX + CGFloat(column) * (width + gap),
            y: bounds.minY + CGFloat(row) * (height + gap),
            width: width,
            height: height
        )
    }

    func index(at point: NSPoint) -> Int? {
        guard bounds.contains(point), count > 0 else { return nil }
        if !detailed {
            return min(count - 1, max(0, Int((point.x - bounds.minX) / bounds.width * CGFloat(count))))
        }
        // At most 512 bounded cells; this runs only on a pointer move over the detail card.
        return (0..<count).first { rect(at: $0).contains(point) }
    }
}
