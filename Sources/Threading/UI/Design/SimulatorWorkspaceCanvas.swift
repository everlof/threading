import AppKit

/// Geometry only: each device controller draws its own name, screen and status inside the cell it
/// is given, and retains its own themed screen and input authority. Membership is capped before
/// any views are constructed; ordinary frames never rebuild tiles.
final class SimulatorWorkspaceCanvas: NSView, PointerClaiming {
    var restingPointer: NSCursor? { .arrow }
    override func resetCursorRects() { registerPointerClaims() }
    struct Tile {
        let id: UUID
        let content: NSView
        var aspect: CGFloat
    }

    private(set) var tiles: [Tile] = []
    var selectedID: UUID? { didSet { if selectedID != oldValue { needsLayout = true } } }
    var arrangement: SimulatorWorkspaceLayout = .automatic { didSet { if arrangement != oldValue { needsLayout = true } } }
    /// What a tile spends beside its screen (its name and status line), so arrangements are
    /// compared by the screen each would actually leave.
    var tileChromeHeight: CGFloat = 0 { didSet { if tileChromeHeight != oldValue { needsLayout = true } } }
    var holdsGesture: () -> Bool = { false }
    var onVisibleMembers: ((Set<UUID>) -> Void)?
    private(set) var plan: SimulatorWorkspaceGeometry.Plan?

    override var isFlipped: Bool { true }

    func setTiles(_ values: [Tile]) {
        precondition(values.count <= SimulatorWorkspaceState.maximumMembers)
        let retained = Set(values.map(\.id))
        for tile in tiles where !retained.contains(tile.id) {
            tile.content.removeFromSuperview()
        }
        tiles = values
        needsLayout = true
    }

    func updateAspect(_ aspect: CGFloat, for id: UUID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }), tiles[index].aspect != aspect else { return }
        tiles[index].aspect = aspect
        needsLayout = true
    }

    override func viewDidHide() { super.viewDidHide(); onVisibleMembers?([]) }
    override func viewDidUnhide() { super.viewDidUnhide(); needsLayout = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onVisibleMembers?([]) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !holdsGesture() else { return }
        let selected = tiles.firstIndex { $0.id == selectedID } ?? 0
        let next = SimulatorWorkspaceGeometry.plan(
            size: bounds.size, aspects: tiles.map(\.aspect), layout: arrangement,
            selectedIndex: selected, gap: Design.Spacing.large, titleHeight: tileChromeHeight,
            previousLayout: plan?.layout
        )
        plan = next
        let canPresent = window != nil && !isHiddenOrHasHiddenAncestor
        let visible = Set(next.visibleIndices.filter { canPresent && next.frames[$0].width > 0 && next.frames[$0].height > 0 })
        for (index, tile) in tiles.enumerated() {
            let shows = visible.contains(index)
            tile.content.isHidden = !shows
            guard shows else { continue }
            // Give a child its actual viewport before mounting it. A zero-height autoresizing
            // mask would otherwise conflict with the screen's status and annotation insets.
            tile.content.translatesAutoresizingMaskIntoConstraints = true
            let frame = next.frames[index].integral
            if tile.content.frame != frame { tile.content.frame = frame }
            if tile.content.superview !== self { addSubview(tile.content) }
        }
        onVisibleMembers?(Set(visible.map { tiles[$0].id }))
    }
}

@MainActor
extension SimulatorWorkspaceLayout {
    var displayTitle: String {
        switch self {
        case .automatic: L10n.string("Auto")
        case .row: L10n.string("Row")
        case .column: L10n.string("Column")
        case .grid: L10n.string("Grid")
        case .focus: L10n.string("Focus")
        }
    }

    /// Each arrangement's own picture, so the chooser shows what it will do.
    var symbolName: String {
        switch self {
        case .automatic: "rectangle.3.group"
        case .row: "rectangle.split.3x1"
        case .column: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        case .focus: "rectangle.inset.filled"
        }
    }
}
