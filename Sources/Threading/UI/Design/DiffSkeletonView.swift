import AppKit

/// The ghost of a diff body: quiet context bars with the file's added/removed weight tinted
/// through them, standing in for a TextKit document that has not been built yet.
///
/// Two review rows wear it. A scroller-thumb seek row keeps its expanded geometry while
/// deliberately building no text, and a progressive comparison's pending row owns its numstat
/// height before its hunks hydrate. Both used to hold that space as one empty card — a reader
/// scrubbing through a 20,000-line diff saw a screen of bare surface, which reads as the pane
/// failing to draw rather than declining to yet.
///
/// The bars are a silhouette, not content: a repeating hunk-shaped block whose changed run is
/// split by the file's own +/− proportion, at a deliberate whisper of the diff hues. Drawing
/// visits only the bar rows intersecting `dirtyRect`, so a document-sized body costs the
/// viewport, not the document.
///
/// The pulse is a layer-opacity animation for `ThemedSpinner`'s reason — a redraw timer would
/// be main-thread work for the length of a drag — and Reduce Motion removes it rather than
/// slowing it: the hint is the ghost content itself, not its breathing.
final class DiffSkeletonView: NSView, ThemedComponent {

    // MARK: - Types

    /// What one bar stands in for. Internal so a test can assert the distribution follows the
    /// file's counts without decoding tinted pixels.
    enum BarKind {
        case context
        case added
        case removed
    }

    // MARK: - Layout

    private enum Layout {
        /// One bar row's pitch — roughly a code line at the default scale.
        static let rowPitch: CGFloat = 14
        static let barHeight: CGFloat = 6
        /// Echoes the diff's number column, so the ghost's left edge sits where code sits.
        static let gutter: CGFloat = 36
        /// Bars per repeating block; each block fakes one hunk's silhouette.
        static let blockLength = 12
        /// Context bars framing each block's changed run, split around it in two pairs.
        static let contextBarsPerBlock = 4
        /// The fraction of the available width each bar takes, cycled by row index. Prime-ish
        /// against `indents` so the two cycles do not beat into a visible diagonal.
        static let widths: [CGFloat] = [0.62, 0.38, 0.74, 0.5, 0.66, 0.3, 0.58, 0.44]
        /// Extra leading indent per row, faking code structure.
        static let indents: [CGFloat] = [0, 12, 24, 12, 0, 24, 12, 0, 12, 36, 24, 0]
    }

    private static let pulseKey = "diff-skeleton-pulse"

    // MARK: - Properties

    /// How the changed run inside each block splits, computed once from the file's counts.
    /// Both zero when the counts are unknown, in which case every bar is context.
    private let addedBarsPerBlock: Int
    private let removedBarsPerBlock: Int

    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()

    // MARK: - Initialization

    init(added: Int, removed: Int) {
        let changed = Layout.blockLength - Layout.contextBarsPerBlock
        let total = added + removed
        if total > 0 {
            var addedShare = Int((Double(changed) * Double(added) / Double(total)).rounded())
            // A file that has any of a kind shows at least one bar of it, and a file that
            // lacks a kind shows none — the silhouette must not invent removals.
            if added > 0 { addedShare = max(addedShare, 1) }
            if removed > 0 { addedShare = min(addedShare, changed - 1) } else { addedShare = changed }
            if added == 0 { addedShare = 0 }
            addedBarsPerBlock = addedShare
            removedBarsPerBlock = changed - addedShare
        } else {
            addedBarsPerBlock = 0
            removedBarsPerBlock = 0
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyPulse()
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Pulse

    /// Whether the breathing animation is currently installed — a seam for tests, which cannot
    /// watch a compositor.
    var isPulsing: Bool {
        layer?.animation(forKey: Self.pulseKey) != nil
    }

    /// An animation belongs to the layer tree, which drops it whenever the view leaves a
    /// window — and a virtual table rehosts these rows constantly.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulse()
    }

    private func applyPulse() {
        guard window != nil, !Design.Motion.reducesMotion else {
            // The bars stay: the ghost content is the status. Only its perpetual movement
            // disappears, the same answer `ThemedSpinner` gives.
            layer?.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard layer?.animation(forKey: Self.pulseKey) == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = Design.Motion.skeletonPulseFloor
        pulse.duration = Design.Motion.skeletonPulsePeriod
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        layer?.add(pulse, forKey: Self.pulseKey)
    }

    // MARK: - Drawing

    /// Bars are counted from the top, like the lines they stand in for.
    override var isFlipped: Bool { true }

    /// What the bar at `index` stands in for: a hunk-shaped block — context, the added run,
    /// context again, the removed run — repeated for the height of the body.
    func barKind(at index: Int) -> BarKind {
        let changed = addedBarsPerBlock + removedBarsPerBlock
        guard changed > 0 else { return .context }
        let position = index % Layout.blockLength
        let leadingContext = Layout.contextBarsPerBlock / 2
        if position < leadingContext { return .context }
        if position < leadingContext + addedBarsPerBlock { return .added }
        if position < Layout.contextBarsPerBlock + addedBarsPerBlock { return .context }
        return .removed
    }

    override func draw(_ dirtyRect: NSRect) {
        let available = bounds.width - Layout.gutter - Design.Spacing.inset
        guard available > 1, Layout.rowPitch > 0 else { return }

        // Clip before deriving row indices. A layer-backed view drawn through `cacheDisplay` —
        // a window snapshot, an inspector report, this file's own render test — is handed the
        // *unclipped* rect first: `CGRectInfinite`, whose origin is
        // -CGFloat.greatestFiniteMagnitude / 2. Dividing that by the row pitch overflows `Int`,
        // and the conversion traps the whole process rather than clamping. Bars exist only
        // inside `bounds`, and intersecting an infinite rect with `bounds` is exactly `bounds`.
        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty else { return }

        let firstRow = max(0, Int(visible.minY / Layout.rowPitch))
        let lastRow = max(firstRow, Int(ceil(visible.maxY / Layout.rowPitch)))
        for row in firstRow...lastRow {
            let y = CGFloat(row) * Layout.rowPitch + (Layout.rowPitch - Layout.barHeight) / 2
            guard y + Layout.barHeight <= bounds.height else { break }

            let indent = Layout.indents[row % Layout.indents.count]
            let width = max(available - indent, 1) * Layout.widths[row % Layout.widths.count]
            let bar = NSRect(
                x: Layout.gutter + indent,
                y: y,
                width: width,
                height: Layout.barHeight
            )
            color(for: barKind(at: row)).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: Layout.barHeight / 2,
                yRadius: Layout.barHeight / 2
            ).fill()
        }
    }

    private func color(for kind: BarKind) -> NSColor {
        switch kind {
        case .context:
            return Design.Text.quaternary
        case .added:
            return Design.Diff.added.withAlphaComponent(Design.Opacity.skeletonDiffTint)
        case .removed:
            return Design.Diff.removed.withAlphaComponent(Design.Opacity.skeletonDiffTint)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
