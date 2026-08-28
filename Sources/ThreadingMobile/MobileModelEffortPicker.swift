import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
import UIKit

/// The phone rendering of the same model-by-effort decision as the Mac composer.
///
/// It receives only the catalogue already sent by the Mac and returns wire values. Presentation
/// is theme-owned here; provider validity and inheritance remain owned by the host/catalogue.
struct MobileModelEffortPicker: View {
    private struct ModelRow: Identifiable {
        let id: String
        let name: String
        let representedValue: String?
        let supportedEffortIDs: Set<String>
        /// The highest level this model offers. Ultra for one provider, Max for another: the
        /// ceiling is a property of the row, not of one named column.
        let topEffortID: String?
    }

    private struct EffortColumn: Identifiable {
        let id: String
        let name: String
        let representedValue: String?

        /// Providers do not all send their shared levels in the same order. The matrix must
        /// preserve the familiar left-to-right increase in effort instead of reflecting which
        /// model happened to introduce a level first.
        var canonicalRank: Int {
            switch representedValue?.lowercased() {
            case "low": return 0
            case "medium": return 1
            case "high": return 2
            case "xhigh": return 3
            case "max": return 4
            case "ultra": return 5
            default: return 100
            }
        }

        var compactName: String {
            switch representedValue?.lowercased() {
            case nil: return MobileL10n.string("Auto")
            case "low": return "L"
            case "medium": return "M"
            case "high": return "H"
            case "xhigh": return "XH"
            case "max": return MobileL10n.string("Max")
            case "ultra": return MobileL10n.string("Ultra")
            default: return name
            }
        }
    }

    private struct MatrixCell: Hashable {
        let row: Int
        let column: Int
    }

    private enum Metrics {
        /// Six model rows and Auto plus six provider efforts are the bounded page. Provider
        /// catalogues can be larger, so overflow advances by pages before any cell views exist.
        /// The matrix itself never becomes a two-axis scroll surface.
        // Keep the numeric picker measurements as computed accessors so InjectionNext can
        // replace them after launch; a stored static constant is already initialized by then.
        static var modelsPerPage: Int { 5 }
        static var providerEffortsPerPage: Int { 6 }
        static var modelWidth: CGFloat { 94 }
        static var headerHeight: CGFloat { 30 }
        static var rowHeight: CGFloat { MobileDesign.Size.minimumTapTarget }
        static var cellGap: CGFloat { 4 }
        /// Every level sits on one ramp from the lowest to the model's ceiling: the beacon grows
        /// from `beaconMinimum` to `beaconMaximum`, its ink crosses from tertiary to accent, and
        /// the column's wash deepens to `washMaximum`. Selection adds `selectionGrowth`.
        static var beaconMinimum: CGFloat { 5 }
        static var beaconMaximum: CGFloat { 10 }
        static var selectionGrowth: CGFloat { 3 }
        static var washMaximum: Double { 0.14 }
        static var automaticRingWidth: CGFloat { 1.5 }
        static let automaticEffortID = "threading.mobile.model-effort.automatic"
    }

    #if DEBUG
    private static let injectionNotification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
    #endif

    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modelPage: Int
    @State private var effortPage: Int
    @State private var scrubbedCell: MatrixCell?
    @State private var scrubFeedback = UISelectionFeedbackGenerator()
    @State private var commitFeedback = UIImpactFeedbackGenerator(style: .medium)
    #if DEBUG
    @State private var injectionRevision = 0
    #endif

    private let rows: [ModelRow]
    private let effortCatalog: [EffortColumn]
    private let defaultModelID: String?
    let selectedModelID: String
    let selectedEffortID: String
    let onChoose: (_ model: String?, _ effort: String?) -> Void

    init(
        models: [RemoteModelChoiceDTO],
        defaultModelID: String?,
        selectedModelID: String,
        selectedEffortID: String,
        onChoose: @escaping (_ model: String?, _ effort: String?) -> Void
    ) {
        var seen: Set<String> = []
        var efforts = [EffortColumn(
            id: Metrics.automaticEffortID,
            name: MobileL10n.string("Auto"),
            representedValue: nil
        )]
        for model in models {
            for effort in model.reasoning where seen.insert(effort.id).inserted {
                efforts.append(EffortColumn(
                    id: effort.id,
                    name: effort.name,
                    representedValue: effort.id
                ))
            }
        }
        if let automatic = efforts.first {
            let orderedProviderEfforts = efforts.dropFirst().enumerated().sorted { lhs, rhs in
                lhs.element.canonicalRank == rhs.element.canonicalRank
                    ? lhs.offset < rhs.offset
                    : lhs.element.canonicalRank < rhs.element.canonicalRank
            }.map(\.element)
            efforts = [automatic] + orderedProviderEfforts
        }
        let rankByEffortID = Dictionary(
            efforts.map { ($0.id, $0.canonicalRank) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = models.map { model in
            let isDefault = model.id == defaultModelID
            let supported = model.reasoning.map(\.id)
            return ModelRow(
                id: model.id,
                name: model.name,
                representedValue: isDefault ? nil : model.id,
                supportedEffortIDs: Set(supported),
                topEffortID: supported.max { lhs, rhs in
                    (rankByEffortID[lhs] ?? -1) < (rankByEffortID[rhs] ?? -1)
                }
            )
        }

        self.rows = rows
        effortCatalog = efforts
        self.defaultModelID = defaultModelID
        self.selectedModelID = selectedModelID
        self.selectedEffortID = selectedEffortID
        self.onChoose = onChoose

        let effectiveModelID = selectedModelID.isEmpty
            ? (defaultModelID ?? rows.first?.id ?? "")
            : selectedModelID
        let selectedModelIndex = rows.firstIndex { $0.id == effectiveModelID } ?? 0
        _modelPage = State(initialValue: selectedModelIndex / Metrics.modelsPerPage)

        let effectiveEffortID = selectedEffortID.isEmpty
            ? Metrics.automaticEffortID
            : selectedEffortID
        let providerEffortIndex = efforts.dropFirst().firstIndex {
            $0.id == effectiveEffortID
        }.map { efforts.distance(from: efforts.startIndex, to: $0) - 1 } ?? 0
        _effortPage = State(
            initialValue: providerEffortIndex / Metrics.providerEffortsPerPage
        )
    }

    private var effectiveSelectedModelID: String {
        selectedModelID.isEmpty ? (defaultModelID ?? rows.first?.id ?? "") : selectedModelID
    }

    private var effectiveSelectedEffortID: String {
        selectedEffortID.isEmpty ? Metrics.automaticEffortID : selectedEffortID
    }

    private var freezesForEvidence: Bool {
        ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_RUN"] != nil
    }

    private var modelPageCount: Int {
        max(1, Int(ceil(Double(rows.count) / Double(Metrics.modelsPerPage))))
    }

    private var effortPageCount: Int {
        let providerCount = max(0, effortCatalog.count - 1)
        return max(
            1,
            Int(ceil(Double(providerCount) / Double(Metrics.providerEffortsPerPage)))
        )
    }

    private var visibleRows: [ModelRow] {
        let start = min(modelPage * Metrics.modelsPerPage, rows.count)
        let end = min(start + Metrics.modelsPerPage, rows.count)
        return Array(rows[start..<end])
    }

    /// Auto remains the first column on every effort page. A provider can add more than the
    /// six levels a phone width can carry; paging keeps construction and gesture hit testing
    /// bounded without turning the matrix into a scroll view.
    private var visibleEfforts: [EffortColumn] {
        guard let automatic = effortCatalog.first else { return [] }
        let providerEfforts = Array(effortCatalog.dropFirst())
        let start = min(
            effortPage * Metrics.providerEffortsPerPage,
            providerEfforts.count
        )
        let end = min(start + Metrics.providerEffortsPerPage, providerEfforts.count)
        return [automatic] + Array(providerEfforts[start..<end])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(titleText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(scrubbedCell == nil ? theme.secondaryLabel : theme.label)
                .lineLimit(1)
                .contentTransition(.identity)

            matrix
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.floatingSurface)
        // The popover is tone-on-tone with the composer bar it opens over; the themed dialog's
        // border gives the edge back without a second surface colour.
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                .strokeBorder(theme.border, lineWidth: max(theme.borderWidth, 1))
        }
        .frame(minWidth: 350, idealWidth: 380, maxWidth: 420)
        .accessibilityElement(children: .contain)
        #if DEBUG
        // The injected body is available immediately, and changing this state makes an already
        // presented SwiftUI picker evaluate it again without closing the sheet.
        .onReceive(NotificationCenter.default.publisher(for: Self.injectionNotification)) { _ in
            injectionRevision &+= 1
        }
        .id(injectionRevision)
        #endif
    }

    /// A finger hides the cell it is on, so the title reads the scrubbed combination and the
    /// axis labels light up; the summary is only shown once the choice is committed otherwise.
    private var titleText: String {
        guard let cell = scrubbedCell, isAvailable(cell) else {
            return MobileL10n.string("Model × effort")
        }
        return "\(visibleRows[cell.row].name) · \(visibleEfforts[cell.column].name)"
    }

    private func isScrubbedRow(_ model: ModelRow) -> Bool {
        scrubbedCell.map { visibleRows.indices.contains($0.row) && visibleRows[$0.row].id == model.id }
            ?? false
    }

    private func isScrubbedColumn(_ effort: EffortColumn) -> Bool {
        scrubbedCell.map {
            visibleEfforts.indices.contains($0.column) && visibleEfforts[$0.column].id == effort.id
        } ?? false
    }

    private var matrix: some View {
        VStack(spacing: MobileDesign.Spacing.tight) {
            GeometryReader { geometry in
                let modelWidth = min(Metrics.modelWidth, geometry.size.width * 0.28)
                let effortWidth = max(
                    1,
                    (geometry.size.width - modelWidth)
                        / CGFloat(max(visibleEfforts.count, 1))
                )

                matrixContent(modelWidth: modelWidth, effortWidth: effortWidth)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(modelWidth: modelWidth, effortWidth: effortWidth))
            }
            .frame(height: matrixHeight)
            .background {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .fill(theme.panel)
                    .overlay {
                        // The ceiling's wash fills the whole panel rather than one cell, so
                        // reaching a model's top level is felt on the surface being held.
                        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                            .fill(
                                RadialGradient(
                                    colors: [
                                        theme.accent.opacity(activeCellIsCeiling ? 0.22 : 0),
                                        theme.accentMuted.opacity(activeCellIsCeiling ? 0.10 : 0),
                                        .clear,
                                    ],
                                    center: .center,
                                    startRadius: 8,
                                    endRadius: 260
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }
            .mobileUltraBeam(
                active: activeCellIsCeiling,
                radius: theme.controlRadius,
                reducesMotion: reduceMotion,
                freezesForEvidence: freezesForEvidence
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: MobileDesign.Motion.controlResponse),
                value: activeCellIsCeiling
            )

            if modelPageCount > 1 || effortPageCount > 1 {
                pageControls
            }
        }
        .onAppear {
            scrubFeedback.prepare()
            commitFeedback.prepare()
        }
    }

    /// Every page is the same height. A short last page leaves blank rows rather than pulling
    /// the page controls up under the finger that just tapped them.
    private var matrixHeight: CGFloat {
        let rowsOnAPage = rows.count > Metrics.modelsPerPage
            ? Metrics.modelsPerPage
            : visibleRows.count
        return Metrics.headerHeight + CGFloat(rowsOnAPage) * Metrics.rowHeight
    }

    /// The cell a finger is on, else the committed one; the beam and the wash follow it.
    private var activeCell: MatrixCell? {
        if let scrubbedCell { return scrubbedCell }
        guard let row = visibleRows.firstIndex(where: { $0.id == effectiveSelectedModelID }),
              let column = visibleEfforts.firstIndex(where: { $0.id == effectiveSelectedEffortID })
        else { return nil }
        return MatrixCell(row: row, column: column)
    }

    private var activeCellIsCeiling: Bool {
        guard let cell = activeCell, isAvailable(cell) else { return false }
        return isCeiling(model: visibleRows[cell.row], effort: visibleEfforts[cell.column])
    }

    private func isCeiling(model: ModelRow, effort: EffortColumn) -> Bool {
        effort.representedValue != nil && effort.id == model.topEffortID
    }

    /// Where a level sits between the catalogue's lowest and highest provider level, 0…1.
    /// Auto has no place on the ramp; unknown levels count as the top.
    private func rampFraction(_ effort: EffortColumn) -> Double {
        let ranks = effortCatalog.compactMap { column -> Int? in
            column.representedValue == nil ? nil : column.canonicalRank
        }
        guard effort.representedValue != nil,
              let lowest = ranks.min(), let highest = ranks.max(), highest > lowest
        else { return effort.representedValue == nil ? 0 : 1 }
        let rank = min(effort.canonicalRank, highest)
        return Double(rank - lowest) / Double(highest - lowest)
    }

    private func matrixContent(modelWidth: CGFloat, effortWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            matrixHeader(modelWidth: modelWidth, effortWidth: effortWidth)
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { row, model in
                HStack(spacing: 0) {
                    modelLabel(model, width: modelWidth)
                    ForEach(Array(visibleEfforts.enumerated()), id: \.element.id) {
                        column, effort in
                        effortCell(
                            model: model,
                            effort: effort,
                            cell: MatrixCell(row: row, column: column),
                            width: effortWidth
                        )
                    }
                }
                .frame(height: Metrics.rowHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(height: max(theme.borderWidth, 1))
                }
            }
            if rows.count > Metrics.modelsPerPage, visibleRows.count < Metrics.modelsPerPage {
                Color.clear
                    .frame(
                        height: CGFloat(Metrics.modelsPerPage - visibleRows.count)
                            * Metrics.rowHeight
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private func matrixHeader(modelWidth: CGFloat, effortWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Model")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.tertiaryLabel)
                .padding(.leading, MobileDesign.Spacing.small)
                .frame(width: modelWidth, alignment: .leading)
            ForEach(visibleEfforts) { effort in
                Text(effort.compactName)
                    .foregroundStyle(
                        isScrubbedColumn(effort)
                            ? theme.accent
                            : theme.tertiaryLabel
                    )
                    .overlay {
                        Text(effort.compactName)
                            .foregroundStyle(theme.accent)
                            .opacity(isScrubbedColumn(effort) ? 0 : rampFraction(effort) * 0.85)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(width: effortWidth)
                    .accessibilityLabel(effort.name)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(theme.tertiaryLabel)
        .frame(height: Metrics.headerHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: max(theme.borderWidth, 1))
        }
    }

    private func modelLabel(_ model: ModelRow, width: CGFloat) -> some View {
        let selected = effectiveSelectedModelID == model.id
        let scrubbed = isScrubbedRow(model)
        return VStack(alignment: .leading, spacing: 1) {
            Text(model.name)
                .font(selected ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(
                    scrubbed ? theme.accent : (selected ? theme.label : theme.secondaryLabel)
                )
                .lineLimit(1)
                .truncationMode(.tail)
            if model.representedValue == nil {
                Text(MobileL10n.string("Default"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
            }
        }
            .padding(.leading, MobileDesign.Spacing.small)
            .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func effortCell(
        model: ModelRow,
        effort: EffortColumn,
        cell: MatrixCell,
        width: CGFloat
    ) -> some View {
        let available = effort.representedValue == nil
            || model.supportedEffortIDs.contains(effort.id)
        let committed = effectiveSelectedModelID == model.id
            && effectiveSelectedEffortID == effort.id
        let selected = scrubbedCell.map { $0 == cell } ?? committed
        let isScrubTarget = scrubbedCell == cell
        let onScrubbedAxis = scrubbedCell.map {
            $0 != cell && ($0.row == cell.row || $0.column == cell.column)
        } ?? false
        let fraction = rampFraction(effort)
        let ceiling = isCeiling(model: model, effort: effort)

        if available {
            ZStack {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .fill(
                        selected
                            ? theme.accent
                            : (onScrubbedAxis ? theme.controlHover.opacity(0.58) : theme.controlResting)
                    )
                if !selected {
                    // The ramp's wash: each column one step deeper than the one before it, so
                    // the matrix reads as a gradient of effort before any cell is chosen.
                    RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                        .fill(theme.accent.opacity(fraction * Metrics.washMaximum))
                }
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .stroke(
                        selected ? theme.accent : (ceiling ? theme.accentMuted : theme.border),
                        lineWidth: selected ? max(theme.borderWidth, 2) : theme.borderWidth
                    )
                beacon(effort: effort, fraction: fraction, ceiling: ceiling, selected: selected)
            }
            .frame(width: max(1, width - Metrics.cellGap), height: Metrics.rowHeight - 8)
            .scaleEffect(isScrubTarget && !reduceMotion ? 1.07 : 1)
            .zIndex(isScrubTarget ? 1 : 0)
            .animation(
                reduceMotion ? nil : .snappy(
                    duration: MobileDesign.Motion.controlResponse,
                    extraBounce: 0.08
                ),
                value: isScrubTarget
            )
            .frame(width: width, height: Metrics.rowHeight)
            .accessibilityLabel("\(model.name), \(effort.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction {
                commit(cell, fraction: fraction)
            }
        } else {
            Circle()
                .fill(theme.tertiaryLabel.opacity(0.22))
                .frame(width: Metrics.beaconMinimum, height: Metrics.beaconMinimum)
                .frame(width: width, height: Metrics.rowHeight)
                .accessibilityHidden(true)
        }
    }

    /// The commit's haptic climbs the same ramp the beacons do.
    private func commit(_ cell: MatrixCell, fraction: Double) {
        commitFeedback.impactOccurred(intensity: 0.5 + 0.5 * fraction)
        commitFeedback.prepare()
        choose(cell)
    }

    private func scrubGesture(modelWidth: CGFloat, effortWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard let cell = availableCell(
                    at: value.location,
                    modelWidth: modelWidth,
                    effortWidth: effortWidth
                ), cell != scrubbedCell else { return }
                scrubbedCell = cell
                scrubFeedback.selectionChanged()
                scrubFeedback.prepare()
            }
            .onEnded { value in
                let releaseCell = availableCell(
                    at: value.location,
                    modelWidth: modelWidth,
                    effortWidth: effortWidth
                ) ?? scrubbedCell
                scrubbedCell = nil
                guard let releaseCell else { return }
                commit(releaseCell, fraction: rampFraction(visibleEfforts[releaseCell.column]))
            }
    }

    @ViewBuilder
    private func beacon(
        effort: EffortColumn,
        fraction: Double,
        ceiling: Bool,
        selected: Bool
    ) -> some View {
        let growth = selected ? Metrics.selectionGrowth : 0
        let diameter = Metrics.beaconMinimum
            + (Metrics.beaconMaximum - Metrics.beaconMinimum) * fraction
            + growth
        if effort.representedValue == nil {
            // Auto chooses nothing itself, so its beacon is a ring the account's setting
            // shows through.
            Circle()
                .strokeBorder(
                    selected ? theme.accentForeground : theme.tertiaryLabel,
                    lineWidth: Metrics.automaticRingWidth
                )
                .frame(
                    width: Metrics.beaconMinimum + 2 + growth,
                    height: Metrics.beaconMinimum + 2 + growth
                )
        } else if ceiling {
            RoundedRectangle(cornerRadius: selected ? 2 : 1, style: .continuous)
                .fill(selected ? theme.accentForeground : theme.accent)
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(45))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(theme.accentForeground.opacity(0.54), lineWidth: 1)
                            .padding(-4)
                            .rotationEffect(.degrees(45))
                    }
                }
        } else {
            ZStack {
                Circle().fill(selected ? theme.accentForeground : theme.tertiaryLabel)
                if !selected {
                    Circle().fill(theme.accent.opacity(fraction))
                }
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                if selected {
                    Circle()
                        .stroke(theme.accentForeground.opacity(0.44), lineWidth: 1)
                        .padding(-4)
                }
            }
        }
    }

    private func availableCell(
        at point: CGPoint,
        modelWidth: CGFloat,
        effortWidth: CGFloat
    ) -> MatrixCell? {
        guard point.x >= modelWidth,
              point.y >= Metrics.headerHeight,
              effortWidth > 0 else { return nil }
        let row = Int((point.y - Metrics.headerHeight) / Metrics.rowHeight)
        let column = Int((point.x - modelWidth) / effortWidth)
        let cell = MatrixCell(row: row, column: column)
        guard visibleRows.indices.contains(row),
              visibleEfforts.indices.contains(column),
              isAvailable(cell) else { return nil }
        return cell
    }

    private func isAvailable(_ cell: MatrixCell) -> Bool {
        guard visibleRows.indices.contains(cell.row),
              visibleEfforts.indices.contains(cell.column) else { return false }
        let effort = visibleEfforts[cell.column]
        return effort.representedValue == nil
            || visibleRows[cell.row].supportedEffortIDs.contains(effort.id)
    }

    private func choose(_ cell: MatrixCell) {
        guard isAvailable(cell) else { return }
        let model = visibleRows[cell.row]
        let effort = visibleEfforts[cell.column]
        onChoose(model.representedValue, effort.representedValue)
    }

    private var pageControls: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            if modelPageCount > 1 {
                pageControl(
                    title: MobileL10n.string("Model"),
                    page: modelPage,
                    count: modelPageCount,
                    previousAccessibilityLabel: MobileL10n.string("Previous model page"),
                    nextAccessibilityLabel: MobileL10n.string("Next model page"),
                    move: { modelPage = min(max(0, modelPage + $0), modelPageCount - 1) }
                )
            }
            if modelPageCount > 1 && effortPageCount > 1 {
                Spacer(minLength: MobileDesign.Spacing.small)
            }
            if effortPageCount > 1 {
                pageControl(
                    title: MobileL10n.string("Effort"),
                    page: effortPage,
                    count: effortPageCount,
                    previousAccessibilityLabel: MobileL10n.string("Previous effort page"),
                    nextAccessibilityLabel: MobileL10n.string("Next effort page"),
                    move: { effortPage = min(max(0, effortPage + $0), effortPageCount - 1) }
                )
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(theme.secondaryLabel)
    }

    private func pageControl(
        title: String,
        page: Int,
        count: Int,
        previousAccessibilityLabel: String,
        nextAccessibilityLabel: String,
        move: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: MobileDesign.Spacing.tight) {
            Button {
                scrubFeedback.selectionChanged()
                scrubFeedback.prepare()
                move(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: MobileDesign.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page == 0)
            .accessibilityLabel(previousAccessibilityLabel)

            Text("\(title) \(page + 1)/\(count)")
                .monospacedDigit()
                .contentTransition(.numericText())

            Button {
                scrubFeedback.selectionChanged()
                scrubFeedback.prepare()
                move(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: MobileDesign.Size.minimumTapTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(page == count - 1)
            .accessibilityLabel(nextAccessibilityLabel)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: MobileDesign.Motion.controlResponse),
            value: page
        )
    }
}

#endif
