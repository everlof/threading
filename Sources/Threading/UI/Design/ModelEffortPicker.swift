import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

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
        /// Where the name came from, on the row that leaves the choice to the agent — "Account
        /// default", "Last used". Drawn under the name rather than appended to it: appended,
        /// it was truncated to "(account d…" at the column's width, and took the tail of the
        /// name it qualified with it.
        let detail: String?
        let representedValue: String?
        let supportedEffortIDs: Set<String>

        init(
            id: String,
            name: String,
            detail: String? = nil,
            representedValue: String?,
            supportedEffortIDs: Set<String>
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.representedValue = representedValue
            self.supportedEffortIDs = supportedEffortIDs
        }
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

extension ModelEffortPickerPresentation {
    /// Both hosts use the same inheritance row and effort-column semantics.
    static func make(options: [AgentModelOption], defaultModelID: String?,
                     defaultModelName: String, defaultModelDetail: String,
                     defaultOption: AgentModelOption?, selectedModel: String?,
                     selectedEffort: String?) -> Self? {
        guard !options.isEmpty else { return nil }
        let markedInList = options.contains { $0.identifier == defaultModelID }
        let defaultID = defaultModelID ?? "threading.model-effort.default-model"
        var models: [Model] = []
        if !markedInList {
            models.append(Model(id: defaultID, name: defaultModelName,
                detail: defaultModelID == nil ? nil : defaultModelDetail, representedValue: nil,
                supportedEffortIDs: Set(defaultOption?.reasoningLevels.map(\.effort) ?? [])))
        }
        models += options.map { option in
            let isDefault = markedInList && option.identifier == defaultModelID
            return Model(id: option.identifier, name: option.displayName,
                detail: isDefault ? defaultModelDetail : nil,
                representedValue: isDefault ? nil : option.identifier,
                supportedEffortIDs: Set(option.reasoningLevels.map(\.effort)))
        }
        var seen: Set<String> = []
        var efforts = [Effort(id: automaticEffortID, name: L10n.string("Auto"), representedValue: nil)]
        for option in options {
            for level in option.reasoningLevels where seen.insert(level.effort).inserted {
                efforts.append(Effort(id: level.effort, name: level.displayName, representedValue: level.effort))
            }
        }
        return Self(models: models, efforts: efforts,
            selectedModelID: selectedModel ?? defaultID,
            selectedEffortID: selectedEffort ?? automaticEffortID)
    }
}

/// Shared popover contents. Hosts own anchoring, dismissal and the chosen launch values.
@MainActor
final class ModelEffortPickerContentView: NSView {
    private enum Layout {
        static var inset: CGFloat { Design.Spacing.medium }
        static var titleHeight: CGFloat { 22 }
        static var gap: CGFloat { Design.Spacing.small }
        static var maximumWidth: CGFloat { 680 }
        static var maximumMatrixHeight: CGFloat { 336 }
    }

    let matrixView: ModelEffortMatrixControl
    let scrollView = ThemedScrollView(frame: .zero)
    private let title = NSTextField(labelWithString: L10n.string("Model × effort"))
    private let footer: NSView?

    init(matrixView: ModelEffortMatrixControl, footer: NSView? = nil) {
        self.matrixView = matrixView
        self.footer = footer
        super.init(frame: .zero)
        title.applyFont(.caption)
        title.textColor = Design.Text.secondary
        title.setAccessibilityElement(false)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        matrixView.frame = NSRect(origin: .zero, size: matrixView.intrinsicContentSize)
        scrollView.documentView = matrixView
        addSubview(title)
        addSubview(scrollView)
        if let footer { addSubview(footer) }
        #if !os(Linux)
        // AppKit constraints use text alignment rectangles and pixel-align legacy theme
        // controls. Keep that native sizing contract; the Linux host lays out these same
        // children explicitly until its constraint engine supports those semantics.
        for child in [title, scrollView] + (footer.map { [$0] } ?? []) {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let natural = matrixView.intrinsicContentSize
        var constraints = [
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Layout.inset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: Layout.inset),
            title.heightAnchor.constraint(equalToConstant: Layout.titleHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.inset),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Layout.gap),
            scrollView.widthAnchor.constraint(equalToConstant: min(Layout.maximumWidth, natural.width)),
            scrollView.heightAnchor.constraint(equalToConstant: min(Layout.maximumMatrixHeight, natural.height))
        ]
        if let footer {
            constraints += [
                footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.inset),
                footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Layout.gap),
                footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.inset)
            ]
        } else {
            constraints.append(scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.inset))
        }
        NSLayoutConstraint.activate(constraints)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let natural = matrixView.intrinsicContentSize
        return NSSize(width: min(Layout.maximumWidth, natural.width) + Layout.inset * 2,
            height: Layout.inset * 2 + Layout.titleHeight + Layout.gap
                + min(Layout.maximumMatrixHeight, natural.height)
                + (footer.map { Layout.gap + $0.intrinsicContentSize.height } ?? 0))
    }

    override func layout() {
        super.layout()
        #if os(Linux)
        let width = max(1, bounds.width - Layout.inset * 2)
        let footerHeight = footer?.intrinsicContentSize.height ?? 0
        let footerAllowance = footer == nil ? 0 : footerHeight + Layout.gap
        let matrixHeight = max(1, bounds.height - Layout.inset * 2
            - Layout.titleHeight - Layout.gap - footerAllowance)
        title.frame = NSRect(x: Layout.inset, y: bounds.height - Layout.inset - Layout.titleHeight,
                            width: width, height: Layout.titleHeight)
        scrollView.frame = NSRect(x: Layout.inset, y: Layout.inset + footerAllowance,
                                 width: width, height: matrixHeight)
        matrixView.frame = NSRect(origin: .zero, size: matrixView.intrinsicContentSize)
        footer?.frame = NSRect(x: Layout.inset, y: Layout.inset, width: width, height: footerHeight)
        #endif
    }
}

/// A bounded viewport over a provider-sized model catalogue.
///
/// The document is one drawing control rather than one retained view per combination. Its
/// storage is O(models + efforts), AppKit asks it to draw only the visible dirty region, and the
/// enclosing themed scroll view bounds both axes. That is the scaling contract for catalogues
/// received from provider-owned files rather than a fixed application enum.
#if !os(Linux)
@MainActor
final class ModelEffortPickerViewController: NSViewController {
    let matrixView: ModelEffortMatrixControl
    private let hiddenModelCount: Int
    private let onShowHiddenModels: (() -> Void)?

    init(
        presentation: ModelEffortPickerPresentation,
        hiddenModelCount: Int = 0,
        onHideModel: ((_ modelID: String) -> Void)? = nil,
        onShowHiddenModels: (() -> Void)? = nil,
        onChoose: @escaping (_ model: String?, _ effort: String?) -> Void
    ) {
        self.hiddenModelCount = hiddenModelCount
        self.onShowHiddenModels = onShowHiddenModels
        matrixView = ModelEffortMatrixControl(
            presentation: presentation,
            onHideModel: onHideModel,
            onChoose: onChoose
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let showHidden: ThemedButton? = if hiddenModelCount > 0, onShowHiddenModels != nil {
            ThemedButton(
                title: L10n.format("Show hidden models (%d)", hiddenModelCount),
                target: self,
                action: #selector(showHiddenModelsClicked)
            )
        } else {
            nil
        }
        showHidden?.emphasis = .tertiary
        showHidden?.contentAlignment = .leading
        showHidden?.setAccessibilityIdentifier("model-effort.show-hidden-models")

        let root = ModelEffortPickerContentView(matrixView: matrixView, footer: showHidden)
        let contentSize = root.intrinsicContentSize
        root.frame = NSRect(origin: .zero, size: contentSize)
        preferredContentSize = contentSize
        view = root
    }

    @objc private func showHiddenModelsClicked() {
        onShowHiddenModels?()
    }
}

#endif

/// One themed, keyboard-operable radio grid. Drawing the complete selected cell gives selection
/// enough weight to survive every theme; a tiny checkmark is neither the state nor the target.
@MainActor
final class ModelEffortMatrixControl: ThemedControl {
    private struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    private enum Layout {
        static var modelWidth: CGFloat { 156 }
        static var effortWidth: CGFloat { 74 }
        static var headerHeight: CGFloat { 34 }
        static var rowHeight: CGFloat { 48 }
        static var horizontalCellInset: CGFloat { 4 }
        static var verticalCellInset: CGFloat { 6 }
        static var detailGap: CGFloat { Design.Spacing.hairline }
        static var beacon: CGFloat { 7 }
        static var selectedBeacon: CGFloat { 11 }
        static var axisHoverProgress: CGFloat { 0.46 }
    }

    #if DEBUG && !os(Linux)
    private static let injectionNotification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
    #endif

    private let presentation: ModelEffortPickerPresentation
    private let onHideModel: ((_ modelID: String) -> Void)?
    private let onChoose: (_ model: String?, _ effort: String?) -> Void
    private var hoveredCell: Cell? {
        didSet {
            guard hoveredCell != oldValue else { return }
            updateUltraAnimation()
            needsDisplay = true
        }
    }
    private var hoveredModelRow: Int? {
        didSet {
            guard hoveredModelRow != oldValue else { return }
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
        onHideModel: ((_ modelID: String) -> Void)? = nil,
        onChoose: @escaping (_ model: String?, _ effort: String?) -> Void
    ) {
        self.presentation = presentation
        self.onHideModel = onHideModel
        self.onChoose = onChoose
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(L10n.string("Model and effort"))
        updateAccessibilityValue()
        #if DEBUG && !os(Linux)
        // Injection replaces the drawing methods, but AppKit still needs an invalidation before
        // the already-open picker asks those methods for another frame.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(injectionDidComplete(_:)),
            name: Self.injectionNotification,
            object: nil
        )
        #endif
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

    struct VisibleChoice {
        let index: Int
        let name: String
        let detail: String
        let frame: NSRect
        let selected: Bool
        let focused: Bool
        let enabled: Bool
    }

    func visibleChoices() -> [VisibleChoice] {
        let visible = visibleRect
        guard !visible.isEmpty, !presentation.efforts.isEmpty else { return [] }
        let first = max(0, Int(floor((visible.minY - Layout.headerHeight) / Layout.rowHeight)))
        let end = min(presentation.models.count,
            max(first, Int(ceil((visible.maxY - Layout.headerHeight) / Layout.rowHeight))))
        guard first < end else { return [] }
        var result: [VisibleChoice] = []
        for row in first..<end {
            let model = presentation.models[row]
            for column in presentation.efforts.indices {
                let cell = Cell(row: row, column: column)
                let frame = cellRect(row: cell.row, column: cell.column).intersection(visible)
                guard !frame.isEmpty else { continue }
                let effort = presentation.efforts[column]
                result.append(VisibleChoice(index: row * presentation.efforts.count + column,
                    name: "\(model.name) · \(effort.name)", detail: model.detail ?? "", frame: frame,
                    selected: isSelected(cell), focused: focusedCell == cell, enabled: isAvailable(cell)))
            }
        }
        return result
    }

    @discardableResult
    func chooseVisibleChoice(at index: Int) -> Bool {
        guard index >= 0, !presentation.efforts.isEmpty else { return false }
        let cell = Cell(row: index / presentation.efforts.count, column: index % presentation.efforts.count)
        guard isEnabled, isAvailable(cell), cellRect(row: cell.row, column: cell.column).intersects(visibleRect) else { return false }
        choose(cell)
        return true
    }

    func revealFocusedChoice() {
        guard let cell = focusedCell ?? selectedCell() ?? firstAvailableCell() else { return }
        scrollToVisible(cellRect(row: cell.row, column: cell.column))
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
            hoveredModelRow = nil
            return
        }
        hoveredCell = availableCell(at: point)
        hoveredModelRow = modelRow(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCell = nil
        hoveredModelRow = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let row = modelRow(at: point), canHideModel(at: row), hideRect(for: row).contains(point) {
            #if !os(Linux)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            #endif
            onHideModel?(presentation.models[row].id)
            return
        }
        guard let cell = availableCell(at: point) else { return }
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
        case 115: moveFocus(toRow: 0) // home
        case 119: moveFocus(toRow: presentation.models.count - 1) // end
        case 116: moveFocusByPage(-1)
        case 121: moveFocusByPage(1)
        case 36, 49:
            if let cell = focusedCell ?? selectedCell() ?? firstAvailableCell() { choose(cell) }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHeader(in: dirtyRect)
        let firstRow = max(0, Int(floor((dirtyRect.minY - Layout.headerHeight) / Layout.rowHeight)))
        let endRow = min(presentation.models.count,
            max(firstRow, Int(ceil((dirtyRect.maxY - Layout.headerHeight) / Layout.rowHeight))))
        guard firstRow < endRow else { return }
        for row in firstRow..<endRow {
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
            let onActiveColumn = activeCell?.column == column
            drawText(
                presentation.efforts[column].name,
                in: rect,
                font: onActiveColumn ? Design.Typography.control() : Design.Typography.caption(),
                color: onActiveColumn || presentation.efforts[column].isUltra
                    ? Design.Surface.accent
                    : Design.Text.tertiary,
                alignment: .center
            )
        }
        Design.Surface.divider.setFill()
        NSRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private func drawModel(_ row: Int, in rect: NSRect) {
        let model = presentation.models[row]
        let selected = model.id == presentation.selectedModelID
        let onActiveRow = activeCell?.row == row
        let showsHide = hoveredModelRow == row && canHideModel(at: row)
        let nameFont = selected || onActiveRow
            ? Design.Typography.control()
            : Design.Typography.controlRegular()
        let nameColor = onActiveRow
            ? Design.Surface.accent
            : (selected ? Design.Text.label : Design.Text.secondary)
        let column = NSRect(
            x: Design.Spacing.small,
            y: rect.minY,
            width: Layout.modelWidth - Design.Spacing.medium - (showsHide ? 26 : 0),
            height: rect.height
        )

        if let detail = model.detail {
            // Two lines stacked around the row's middle: the name first, the qualifier under
            // it in the quietest tier, so the row still leads with the model and its
            // provenance reads as a note rather than as part of the name.
            let detailFont = Design.Typography.detail()
            let nameHeight = lineHeight(of: nameFont)
            let detailHeight = lineHeight(of: detailFont)
            let top = column.midY - (nameHeight + Layout.detailGap + detailHeight) / 2
            drawText(
                model.name,
                in: NSRect(x: column.minX, y: top, width: column.width, height: nameHeight),
                font: nameFont,
                color: nameColor,
                alignment: .left
            )
            drawText(
                detail,
                in: NSRect(
                    x: column.minX,
                    y: top + nameHeight + Layout.detailGap,
                    width: column.width,
                    height: detailHeight
                ),
                font: detailFont,
                color: Design.Text.tertiary,
                alignment: .left
            )
        } else {
            drawText(model.name, in: column, font: nameFont, color: nameColor, alignment: .left)
        }
        if showsHide { drawHideModelButton(row: row) }
    }

    private func lineHeight(of font: NSFont) -> CGFloat {
        NSAttributedString(string: " ", attributes: [.font: font]).size().height
    }

    private func drawCell(_ cell: Cell, in rect: NSRect) {
        let available = isAvailable(cell)
        let selected = isSelected(cell)
        let hovered = hoveredCell == cell
        let onHoveredAxis = hoveredCell.map {
            $0 != cell && ($0.row == cell.row || $0.column == cell.column)
        } ?? false
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
                border: Design.Surface.accent,
                radius: Design.Radius.control
            )
        } else if onHoveredAxis && available {
            ThemedSurface.draw(
                rect,
                fill: axisHoverFill,
                border: effort.isUltra ? Design.Surface.accentMuted : nil,
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
        if effort.isUltra {
            diamond(in: beacon).fill()
        } else {
            NSBezierPath(ovalIn: beacon).fill()
        }
        if selected {
            Design.Ink.selection.label.withAlphaComponent(0.42).setStroke()
            let ring = effort.isUltra
                ? diamond(in: beacon.insetBy(dx: -4, dy: -4))
                : NSBezierPath(ovalIn: beacon.insetBy(dx: -4, dy: -4))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    /// Ultra is the one provider level that earns a spectacle, but the spectacle still belongs
    /// to the active theme: accent for the orbit, accent-muted for its field, no fixed violet.
    private func drawUltraOrbit(in rect: NSRect, selected: Bool, active: Bool) {
        let strength: CGFloat = selected ? 0.82 : (active ? 0.62 : 0.28)
        let halo = rect.insetBy(dx: 3, dy: 2)
        NSGradient(
            starting: Design.Surface.accent.withAlphaComponent(strength * 0.32),
            ending: Design.Surface.accentMuted.withAlphaComponent(0)
        )?.draw(in: NSBezierPath(ovalIn: halo), relativeCenterPosition: .zero)

        Design.Surface.accent.withAlphaComponent(strength).setStroke()
        let orbitRect = rect.insetBy(dx: 8, dy: 7)
        for rotation: CGFloat in [-18, 18] {
            let orbit = NSBezierPath(ovalIn: orbitRect)
            var transform = AffineTransform()
            transform.translate(x: orbitRect.midX, y: orbitRect.midY)
            transform.rotate(byDegrees: rotation)
            transform.translate(x: -orbitRect.midX, y: -orbitRect.midY)
            orbit.transform(using: transform)
            orbit.lineWidth = selected ? 1.35 : 0.8
            orbit.stroke()
        }

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

    private func drawHideModelButton(row: Int) {
        let rect = hideRect(for: row)
        if rect.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
            ThemedSurface.draw(
                rect,
                fill: Design.Surface.controlHover,
                border: Design.Surface.border,
                radius: Design.Radius.control
            )
        }
        guard let image = NSImage(
            systemSymbolName: "eye.slash",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(.init(paletteColors: [Design.Text.secondary]))
        ) else { return }
        let size = image.size
        image.draw(in: NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    private func diamond(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.midY))
        path.close()
        return path
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

    /// The cell being considered right now: the pointer's, else the keyboard's while the
    /// control holds focus. Its row label and column header read it back in accent, so a
    /// combination is legible without tracing across the matrix.
    private var activeCell: Cell? {
        if let hoveredCell { return hoveredCell }
        guard window?.firstResponder === self else { return nil }
        return focusedCell
    }

    /// A crosshair is partway from rest to hover, whichever colours and alpha the theme
    /// authored for those two states. Replacing the hover role's alpha with a fixed value made
    /// Pure Black's axes nearly half-white while their intersection stayed at its 10% hover,
    /// visually demoting the cell the pointer was actually considering.
    private var axisHoverFill: NSColor {
        Design.Surface.controlResting.blended(
            withFraction: Layout.axisHoverProgress,
            of: Design.Surface.controlHover
        ) ?? Design.Surface.controlHover
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

    private func modelRow(at point: NSPoint) -> Int? {
        guard point.x >= 0,
              point.x < Layout.modelWidth,
              point.y >= Layout.headerHeight else { return nil }
        let row = Int((point.y - Layout.headerHeight) / Layout.rowHeight)
        return presentation.models.indices.contains(row) ? row : nil
    }

    private func canHideModel(at row: Int) -> Bool {
        guard onHideModel != nil, presentation.models.indices.contains(row) else { return false }
        let model = presentation.models[row]
        return model.representedValue != nil
            && model.id != presentation.selectedModelID
            && presentation.models.count > 1
    }

    private func hideRect(for row: Int) -> NSRect {
        NSRect(
            x: Layout.modelWidth - 30,
            y: Layout.headerHeight + CGFloat(row) * Layout.rowHeight + 9,
            width: 24,
            height: 30
        )
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

    private func moveFocusByPage(_ direction: Int) {
        guard let current = focusedCell ?? selectedCell() ?? firstAvailableCell() else { return }
        let pageRows = max(1, Int(visibleRect.height / Layout.rowHeight))
        moveFocus(toRow: current.row + direction * pageRows)
    }

    private func moveFocus(toRow requestedRow: Int) {
        guard let current = focusedCell ?? selectedCell() ?? firstAvailableCell(),
              !presentation.models.isEmpty else { return }
        let row = min(max(0, requestedRow), presentation.models.count - 1)
        let preferred = Cell(row: row, column: current.column)
        let column = isAvailable(preferred) ? current.column
            : presentation.efforts.indices.first { isAvailable(Cell(row: row, column: $0)) }
        guard let column else { return }
        focusedCell = Cell(row: row, column: column)
        scrollToVisible(cellRect(row: row, column: column))
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
        #if !os(Linux)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let row = (focusedCell ?? selectedCell())?.row,
              canHideModel(at: row) else { return nil }
        let model = presentation.models[row]
        return [
            NSAccessibilityCustomAction(name: L10n.format("Hide %@", model.name)) {
                [weak self] in
                guard let self else { return false }
                self.onHideModel?(model.id)
                return true
            }
        ]
    }

    private func updateAccessibilityValue() {
        let cell = focusedCell ?? selectedCell()
        guard let cell,
              presentation.models.indices.contains(cell.row),
              presentation.efforts.indices.contains(cell.column) else {
            setAccessibilityValue(nil)
            return
        }
        let model = presentation.models[cell.row]
        let name = model.detail.map { "\(model.name), \($0)" } ?? model.name
        setAccessibilityValue("\(name), \(presentation.efforts[cell.column].name)")
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

    #if DEBUG && !os(Linux)
    @objc private nonisolated func injectionDidComplete(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.invalidateIntrinsicContentSize()
            self.setFrameSize(self.intrinsicContentSize)
            self.needsLayout = true
            self.needsDisplay = true
            self.updateUltraAnimation()
        }
    }

    /// Freezes the otherwise pointer-only affordance into deterministic rendered evidence.
    func hoverModelForTesting(at row: Int?) {
        hoveredModelRow = row.flatMap { presentation.models.indices.contains($0) ? $0 : nil }
    }

    func hoverCellForTesting(row: Int?, column: Int?) {
        guard let row, let column else {
            hoveredCell = nil
            return
        }
        let cell = Cell(row: row, column: column)
        hoveredCell = isAvailable(cell) ? cell : nil
    }

    var axisHoverFillForTesting: NSColor { axisHoverFill }
    #endif
}
