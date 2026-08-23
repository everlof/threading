import SwiftUI
import ThreadingRemoteKit

#if os(iOS)

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
    }

    private struct EffortColumn: Identifiable {
        let id: String
        let name: String
        let representedValue: String?

        var isUltra: Bool { representedValue?.lowercased() == "ultra" }

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
        static let modelsPerPage = 6
        static let providerEffortsPerPage = 6
        static let modelWidth: CGFloat = 94
        static let headerHeight: CGFloat = 30
        static let rowHeight: CGFloat = MobileDesign.Size.minimumTapTarget
        static let cellGap: CGFloat = 4
        static let beacon: CGFloat = 7
        static let selectedBeacon: CGFloat = 11
        static let automaticEffortID = "threading.mobile.model-effort.automatic"
    }

    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modelPage: Int
    @State private var effortPage: Int
    @State private var scrubbedCell: MatrixCell?
    @State private var scrubFeedbackStep = 0
    @State private var commitFeedbackStep = 0

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
        let rows = models.map { model in
            let isDefault = model.id == defaultModelID
            return ModelRow(
                id: model.id,
                name: isDefault
                    ? MobileL10n.string("%@ · Default", model.name)
                    : model.name,
                representedValue: isDefault ? nil : model.id,
                supportedEffortIDs: Set(model.reasoning.map(\.id))
            )
        }
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
            Text("Model × effort")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)

            matrix
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.floatingSurface)
        .frame(minWidth: 350, idealWidth: 380, maxWidth: 420)
        .accessibilityElement(children: .contain)
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
                    .sensoryFeedback(.selection, trigger: scrubFeedbackStep)
                    .sensoryFeedback(.impact(weight: .light), trigger: commitFeedbackStep)
            }
            .frame(height: matrixHeight)
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }

            if modelPageCount > 1 || effortPageCount > 1 {
                pageControls
            }
        }
    }

    private var matrixHeight: CGFloat {
        Metrics.headerHeight + CGFloat(visibleRows.count) * Metrics.rowHeight
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
                    .foregroundStyle(effort.isUltra ? theme.accent : theme.tertiaryLabel)
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
        Text(model.name)
            .font(
                effectiveSelectedModelID == model.id
                    ? .caption.weight(.semibold)
                    : .caption
            )
            .foregroundStyle(
                effectiveSelectedModelID == model.id ? theme.label : theme.secondaryLabel
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, MobileDesign.Spacing.small)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(theme.divider)
                    .frame(width: max(theme.borderWidth, 1))
            }
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

        if available {
            ZStack {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .fill(selected ? theme.accent : theme.controlResting)
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                            .stroke(
                                selected ? theme.accent : (
                                    effort.isUltra ? theme.accentMuted : theme.border
                                ),
                                lineWidth: selected ? max(theme.borderWidth, 2) : theme.borderWidth
                            )
                    }

                if effort.isUltra {
                    MobileUltraOrbit(
                        active: selected,
                        reduceMotion: reduceMotion,
                        width: min(36, max(20, width - Metrics.cellGap * 2))
                    )
                }

                Circle()
                    .fill(selected ? theme.accentForeground : (
                        effort.isUltra ? theme.accent : theme.tertiaryLabel
                    ))
                    .frame(
                        width: selected ? Metrics.selectedBeacon : Metrics.beacon,
                        height: selected ? Metrics.selectedBeacon : Metrics.beacon
                    )
                    .overlay {
                        if selected {
                            Circle()
                                .stroke(theme.accentForeground.opacity(0.44), lineWidth: 1)
                                .padding(-4)
                        }
                    }
            }
            .frame(width: max(1, width - Metrics.cellGap), height: Metrics.rowHeight - 8)
            .scaleEffect(isScrubTarget && !reduceMotion ? 1.07 : 1)
            .zIndex(isScrubTarget ? 1 : 0)
            .remoteThemeGlow(selected && effort.isUltra ? theme : RemoteThemePalette(nil))
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
                choose(cell)
            }
        } else {
            Circle()
                .fill(theme.tertiaryLabel.opacity(0.22))
                .frame(width: Metrics.beacon, height: Metrics.beacon)
                .frame(width: width, height: Metrics.rowHeight)
                .accessibilityHidden(true)
        }
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
                scrubFeedbackStep &+= 1
            }
            .onEnded { value in
                let releaseCell = availableCell(
                    at: value.location,
                    modelWidth: modelWidth,
                    effortWidth: effortWidth
                ) ?? scrubbedCell
                scrubbedCell = nil
                guard let releaseCell else { return }
                commitFeedbackStep &+= 1
                choose(releaseCell)
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
            Button { move(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
            }
            .buttonStyle(.plain)
            .disabled(page == 0)
            .accessibilityLabel(previousAccessibilityLabel)

            Text("\(title) \(page + 1)/\(count)")
                .monospacedDigit()
                .contentTransition(.numericText())

            Button { move(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
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

/// A tiny orbit around Ultra's beacon. Reduce Motion freezes it at a deliberate static pose.
private struct MobileUltraOrbit: View {
    @Environment(\.remoteTheme) private var theme
    let active: Bool
    let reduceMotion: Bool
    let width: CGFloat

    /// Evidence compares complete app-owned frames until they are byte-stable. Freeze at the
    /// same intentional pose as Reduce Motion while that harness is present; ordinary DEBUG and
    /// release launches still animate.
    private var freezesForEvidence: Bool {
        ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_RUN"] != nil
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 24,
            paused: reduceMotion || freezesForEvidence || !active
        )) { context in
            let phase = reduceMotion || freezesForEvidence
                ? 22.0
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3)
                    / 3 * 360
            ZStack {
                Capsule()
                    .stroke(theme.accent.opacity(active ? 0.82 : 0.30), lineWidth: active ? 1.5 : 1)
                    .frame(width: width, height: min(22, width * 0.62))
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(theme.accent.opacity(active ? 0.90 : 0.40))
                        .frame(width: index == 0 ? 4 : 3, height: index == 0 ? 4 : 3)
                        .offset(x: width / 2)
                        .rotationEffect(.degrees(phase + Double(index * 120)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
