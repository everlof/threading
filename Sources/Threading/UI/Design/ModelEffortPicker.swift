import AppKit

/// The provider-neutral data a model-by-effort chooser draws.
///
/// `representedValue` is deliberately separate from `id`: the row naming the account's
/// resolved default model has a stable identity of its own while still answering `nil` so the
/// launch continues to inherit that account setting. The first effort does the same thing for
/// reasoning. A picker can therefore make inheritance visible without changing persistence.
struct ModelEffortPickerPresentation: Equatable {
    struct Model: Equatable {
        let id: String
        let name: String
        let representedValue: String?
        let supportedEffortIDs: Set<String>
    }

    struct Effort: Equatable {
        let id: String
        let name: String
        let representedValue: String?

        var isUltra: Bool { representedValue?.lowercased() == "ultra" }
    }

    let models: [Model]
    let efforts: [Effort]
    let selectedModelID: String
    let selectedEffortID: String

    static let automaticEffortID = "threading.model-effort.automatic"
}

/// A bounded viewport over a provider-sized model catalogue.
///
/// The document is one drawing control rather than one retained view per combination. Its
/// storage is O(models + efforts), AppKit asks it to draw only the visible dirty region, and the
/// enclosing themed scroll view bounds both axes. That is the scaling contract for catalogues
/// received from provider-owned files rather than a fixed application enum.
@MainActor
final class ModelEffortPickerViewController: NSViewController {
    private enum Layout {
        static let inset = Design.Spacing.medium
        static let titleHeight: CGFloat = 22
        static let titleGap = Design.Spacing.small
        static let maximumWidth: CGFloat = 680
        static let maximumMatrixHeight: CGFloat = 336
    }

    let matrixView: ModelEffortMatrixControl

    init(
        presentation: ModelEffortPickerPresentation,
        onChoose: @escaping (_ model: String?, _ effort: String?) -> Void
    ) {
        matrixView = ModelEffortMatrixControl(presentation: presentation, onChoose: onChoose)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: L10n.string("Model × effort"))
        title.applyFont(.caption)
        title.textColor = Design.Text.secondary
        title.setAccessibilityElement(false)

        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = matrixView

        let natural = matrixView.intrinsicContentSize
        matrixView.frame = NSRect(origin: .zero, size: natural)
        let viewport = NSSize(
            width: min(Layout.maximumWidth, natural.width),
            height: min(Layout.maximumMatrixHeight, natural.height)
        )

        for child in [title, scroll] { child.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(title)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Layout.inset),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: Layout.inset),
            title.heightAnchor.constraint(equalToConstant: Layout.titleHeight),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.inset),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.inset),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Layout.titleGap),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Layout.inset),
            scroll.widthAnchor.constraint(equalToConstant: viewport.width),
            scroll.heightAnchor.constraint(equalToConstant: viewport.height)
        ])

        let contentSize = NSSize(
            width: viewport.width + Layout.inset * 2,
            height: Layout.inset * 2 + Layout.titleHeight + Layout.titleGap + viewport.height
        )
        // Give AppKit a non-zero owner before the popover installs the controller. Otherwise
        // the root's temporary autoresizing-mask height of zero fights the complete vertical
        // constraint chain during the first sizing pass, even though the popover corrects it a
        // moment later. A shipping popover should not need constraint recovery to reach its
        // preferred size.
        root.frame = NSRect(origin: .zero, size: contentSize)
        preferredContentSize = contentSize
        view = root
    }
}

/// One themed, keyboard-operable radio grid. Drawing the complete selected cell gives selection
/// enough weight to survive every theme; a tiny checkmark is neither the state nor the target.
@MainActor
final class ModelEffortMatrixControl: ThemedControl {
    private struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    private enum Layout {
        static let modelWidth: CGFloat = 156
        static let effortWidth: CGFloat = 74
        static let headerHeight: CGFloat = 34
        static let rowHeight: CGFloat = 48
        static let horizontalCellInset: CGFloat = 4
        static let verticalCellInset: CGFloat = 6
        static let beacon: CGFloat = 7
        static let selectedBeacon: CGFloat = 11
    }

    private let presentation: ModelEffortPickerPresentation
    private let onChoose: (_ model: String?, _ effort: String?) -> Void
    private var hoveredCell: Cell? {
        didSet {
            guard hoveredCell != oldValue else { return }
            updateUltraAnimation()
            needsDisplay = true
        }
    }
    private var focusedCell: Cell? {
        didSet {
            guard focusedCell != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValue()
        }
    }
    private var trackingAreaReference: NSTrackingArea?
    private var ultraTimer: Timer?
    private var ultraPhase: CGFloat = 0

    init(
        presentation: ModelEffortPickerPresentation,
        onChoose: @escaping (_ model: String?, _ effort: String?) -> Void
    ) {
        self.presentation = presentation
        self.onChoose = onChoose
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(L10n.string("Model and effort"))
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Layout.modelWidth + CGFloat(presentation.efforts.count) * Layout.effortWidth,
            height: Layout.headerHeight + CGFloat(presentation.models.count) * Layout.rowHeight
        )
    }

    override var acceptsFirstResponder: Bool { isEnabled && firstAvailableCell() != nil }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled,
              let cell = focusedCell ?? selectedCell() ?? firstAvailableCell() else { return false }
        choose(cell)
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, focusedCell == nil {
            focusedCell = selectedCell() ?? firstAvailableCell()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopUltraAnimation() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateUltraAnimation()
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let point = uncoveredPointerLocation(in: event) else {
            hoveredCell = nil
            return
        }
        hoveredCell = availableCell(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCell = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled,
              let cell = availableCell(at: convert(event.locationInWindow, from: nil)) else {
            return
        }
        window?.makeFirstResponder(self)
        focusedCell = cell
        choose(cell)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: moveFocus(horizontal: -1, vertical: 0) // left
        case 124: moveFocus(horizontal: 1, vertical: 0) // right
        case 125: moveFocus(horizontal: 0, vertical: 1) // down
        case 126: moveFocus(horizontal: 0, vertical: -1) // up
        case 36, 49:
            if let cell = focusedCell ?? selectedCell() ?? firstAvailableCell() { choose(cell) }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHeader(in: dirtyRect)
        for row in presentation.models.indices {
            let rowRect = NSRect(
                x: 0,
                y: Layout.headerHeight + CGFloat(row) * Layout.rowHeight,
                width: bounds.width,
                height: Layout.rowHeight
            )
            guard rowRect.intersects(dirtyRect) else { continue }
            drawModel(row, in: rowRect)
            for column in presentation.efforts.indices {
                drawCell(Cell(row: row, column: column), in: cellRect(row: row, column: column))
            }
            Design.Surface.divider.setFill()
            NSRect(x: 0, y: rowRect.maxY - 1, width: bounds.width, height: 1).fill()
        }
    }

    private func drawHeader(in dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: Layout.headerHeight)
        guard rect.intersects(dirtyRect) else { return }
        drawText(
            L10n.string("Model"),
            in: NSRect(x: Design.Spacing.small, y: 0, width: Layout.modelWidth, height: rect.height),
            font: Design.Typography.caption(),
            color: Design.Text.tertiary,
            alignment: .left
        )
        for column in presentation.efforts.indices {
            let rect = NSRect(
                x: Layout.modelWidth + CGFloat(column) * Layout.effortWidth,
                y: 0,
                width: Layout.effortWidth,
                height: Layout.headerHeight
            )
            drawText(
                presentation.efforts[column].name,
                in: rect,
                font: Design.Typography.caption(),
                color: presentation.efforts[column].isUltra
                    ? Design.Surface.accent
                    : Design.Text.tertiary,
                alignment: .center
            )
        }
        Design.Surface.divider.setFill()
        NSRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private func drawModel(_ row: Int, in rect: NSRect) {
        let selected = presentation.models[row].id == presentation.selectedModelID
        drawText(
            presentation.models[row].name,
            in: NSRect(
                x: Design.Spacing.small,
                y: rect.minY,
                width: Layout.modelWidth - Design.Spacing.medium,
                height: rect.height
            ),
            font: selected ? Design.Typography.control() : Design.Typography.controlRegular(),
            color: selected ? Design.Text.label : Design.Text.secondary,
            alignment: .left
        )
    }

    private func drawCell(_ cell: Cell, in rect: NSRect) {
        let available = isAvailable(cell)
        let selected = isSelected(cell)
        let hovered = hoveredCell == cell
        let focused = focusedCell == cell && window?.firstResponder === self
        let effort = presentation.efforts[cell.column]

        if selected {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.selectionFill,
                border: Design.Surface.accent,
                radius: Design.Radius.control
            )
        } else if hovered || focused {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.controlHover,
                border: focused ? Design.Surface.accent : Design.Surface.border,
                radius: Design.Radius.control
            )
        } else if available {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.controlResting,
                border: effort.isUltra ? Design.Surface.accentMuted : nil,
                radius: Design.Radius.control
            )
        }

        if effort.isUltra, available { drawUltraOrbit(in: rect, selected: selected, active: hovered) }

        let diameter = selected ? Layout.selectedBeacon : Layout.beacon
        let beacon = NSRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let ink: NSColor
        if !available {
            ink = Design.Text.quaternary
        } else if selected {
            ink = Design.Ink.selection.label
        } else if effort.isUltra || hovered || focused {
            ink = Design.Surface.accent
        } else {
            ink = Design.Text.tertiary
        }
        ink.setFill()
        NSBezierPath(ovalIn: beacon).fill()
        if selected {
            Design.Ink.selection.label.withAlphaComponent(0.42).setStroke()
            let ring = NSBezierPath(ovalIn: beacon.insetBy(dx: -4, dy: -4))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    /// Ultra is the one provider level that earns a spectacle, but the spectacle still belongs
    /// to the active theme: accent for the orbit, accent-muted for its field, no fixed violet.
    private func drawUltraOrbit(in rect: NSRect, selected: Bool, active: Bool) {
        let strength: CGFloat = selected ? 0.82 : (active ? 0.62 : 0.28)
        Design.Surface.accent.withAlphaComponent(strength).setStroke()
        let orbitRect = rect.insetBy(dx: 8, dy: 7)
        let orbit = NSBezierPath(ovalIn: orbitRect)
        orbit.lineWidth = selected ? 1.5 : 1
        orbit.stroke()

        guard selected || active else { return }
        for index in 0..<3 {
            let angle = ultraPhase + CGFloat(index) * (.pi * 2 / 3)
            let radiusX = orbitRect.width / 2
            let radiusY = orbitRect.height / 2
            let point = NSPoint(
                x: orbitRect.midX + cos(angle) * radiusX,
                y: orbitRect.midY + sin(angle) * radiusY
            )
            let size: CGFloat = index == 0 ? 4 : 3
            Design.Surface.accent.withAlphaComponent(strength).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )).fill()
        }
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        let height = attributed.size().height
        attributed.draw(in: NSRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        ))
    }

    private func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(
            x: Layout.modelWidth + CGFloat(column) * Layout.effortWidth
                + Layout.horizontalCellInset,
            y: Layout.headerHeight + CGFloat(row) * Layout.rowHeight
                + Layout.verticalCellInset,
            width: Layout.effortWidth - Layout.horizontalCellInset * 2,
            height: Layout.rowHeight - Layout.verticalCellInset * 2
        )
    }

    private func availableCell(at point: NSPoint) -> Cell? {
        guard point.x >= Layout.modelWidth,
              point.y >= Layout.headerHeight else { return nil }
        let row = Int((point.y - Layout.headerHeight) / Layout.rowHeight)
        let column = Int((point.x - Layout.modelWidth) / Layout.effortWidth)
        let cell = Cell(row: row, column: column)
        guard presentation.models.indices.contains(row),
              presentation.efforts.indices.contains(column),
              isAvailable(cell) else { return nil }
        return cell
    }

    private func isAvailable(_ cell: Cell) -> Bool {
        guard presentation.models.indices.contains(cell.row),
              presentation.efforts.indices.contains(cell.column) else { return false }
        guard let effort = presentation.efforts[cell.column].representedValue else { return true }
        return presentation.models[cell.row].supportedEffortIDs.contains(effort)
    }

    private func isSelected(_ cell: Cell) -> Bool {
        presentation.models[cell.row].id == presentation.selectedModelID
            && presentation.efforts[cell.column].id == presentation.selectedEffortID
    }

    private func selectedCell() -> Cell? {
        guard let row = presentation.models.firstIndex(where: {
            $0.id == presentation.selectedModelID
        }), let column = presentation.efforts.firstIndex(where: {
            $0.id == presentation.selectedEffortID
        }) else { return nil }
        let cell = Cell(row: row, column: column)
        return isAvailable(cell) ? cell : nil
    }

    private func firstAvailableCell() -> Cell? {
        for row in presentation.models.indices {
            for column in presentation.efforts.indices {
                let cell = Cell(row: row, column: column)
                if isAvailable(cell) { return cell }
            }
        }
        return nil
    }

    private func moveFocus(horizontal: Int, vertical: Int) {
        guard var candidate = focusedCell ?? selectedCell() ?? firstAvailableCell() else { return }
        let attempts = max(1, presentation.models.count * presentation.efforts.count)
        for _ in 0..<attempts {
            candidate = Cell(
                row: min(max(0, candidate.row + vertical), presentation.models.count - 1),
                column: min(max(0, candidate.column + horizontal), presentation.efforts.count - 1)
            )
            if isAvailable(candidate) {
                focusedCell = candidate
                scrollToVisible(cellRect(row: candidate.row, column: candidate.column))
                return
            }
            if (vertical < 0 && candidate.row == 0)
                || (vertical > 0 && candidate.row == presentation.models.count - 1)
                || (horizontal < 0 && candidate.column == 0)
                || (horizontal > 0 && candidate.column == presentation.efforts.count - 1) {
                return
            }
        }
    }

    private func choose(_ cell: Cell) {
        guard isAvailable(cell) else { return }
        let model = presentation.models[cell.row]
        let effort = presentation.efforts[cell.column]
        onChoose(model.representedValue, effort.representedValue)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func updateAccessibilityValue() {
        let cell = focusedCell ?? selectedCell()
        guard let cell,
              presentation.models.indices.contains(cell.row),
              presentation.efforts.indices.contains(cell.column) else {
            setAccessibilityValue(nil)
            return
        }
        setAccessibilityValue(
            "\(presentation.models[cell.row].name), \(presentation.efforts[cell.column].name)"
        )
    }

    private func updateUltraAnimation() {
        let active = [hoveredCell, selectedCell()].compactMap { $0 }.contains { cell in
            presentation.efforts[cell.column].isUltra
        }
        guard active, !Design.Motion.reducesMotion, window != nil else {
            stopUltraAnimation()
            return
        }
        guard ultraTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ultraPhase += .pi / 36
                self.ultraPhase.formTruncatingRemainder(dividingBy: .pi * 2)
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ultraTimer = timer
    }

    private func stopUltraAnimation() {
        ultraTimer?.invalidate()
        ultraTimer = nil
    }
}
