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
        // Keep the numeric picker measurements as computed accessors so InjectionNext can
        // replace them after launch; a stored static constant is already initialized by then.
        static var modelsPerPage: Int { 6 }
        static var providerEffortsPerPage: Int { 6 }
        static var modelWidth: CGFloat { 94 }
        static var headerHeight: CGFloat { 30 }
        static var rowHeight: CGFloat { MobileDesign.Size.minimumTapTarget }
        static var cellGap: CGFloat { 4 }
        static var beacon: CGFloat { 7 }
        static var selectedBeacon: CGFloat { 11 }
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
            Text("Model × effort")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)

            matrix
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.floatingSurface)
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
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }

            if modelPageCount > 1 || effortPageCount > 1 {
                pageControls
            }
        }
        .onAppear {
            scrubFeedback.prepare()
            commitFeedback.prepare()
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
        let onScrubbedAxis = scrubbedCell.map {
            $0 != cell && ($0.row == cell.row || $0.column == cell.column)
        } ?? false

        if available {
            ZStack {
                RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                    .fill(
                        selected
                            ? theme.accent
                            : (onScrubbedAxis ? theme.controlHover.opacity(0.58) : theme.controlResting)
                    )
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
                    RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    theme.accent.opacity(selected ? 0.62 : 0.20),
                                    theme.accentMuted.opacity(selected ? 0.54 : 0.16),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 1,
                                endRadius: max(18, width * 0.62)
                            )
                        )
                    MobileUltraOrbit(
                        active: selected,
                        reduceMotion: reduceMotion,
                        freezesForEvidence: freezesForEvidence,
                        width: min(36, max(20, width - Metrics.cellGap * 2))
                    )
                }

                beacon(isUltra: effort.isUltra, selected: selected)
            }
            .frame(width: max(1, width - Metrics.cellGap), height: Metrics.rowHeight - 8)
            .scaleEffect(isScrubTarget && !reduceMotion ? 1.07 : 1)
            .zIndex(isScrubTarget ? 1 : 0)
            .remoteThemeGlow(selected && effort.isUltra ? theme : RemoteThemePalette(nil))
            .mobileUltraBeam(
                active: selected && effort.isUltra,
                radius: theme.controlRadius,
                reducesMotion: reduceMotion,
                freezesForEvidence: freezesForEvidence
            )
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
                commitFeedback.impactOccurred(intensity: effort.isUltra ? 1 : 0.68)
                commitFeedback.prepare()
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
                let isUltra = visibleEfforts[releaseCell.column].isUltra
                commitFeedback.impactOccurred(intensity: isUltra ? 1 : 0.68)
                commitFeedback.prepare()
                choose(releaseCell)
            }
    }

    @ViewBuilder
    private func beacon(isUltra: Bool, selected: Bool) -> some View {
        let diameter = selected ? Metrics.selectedBeacon : Metrics.beacon
        let ink = selected
            ? theme.accentForeground
            : (isUltra ? theme.accent : theme.tertiaryLabel)
        if isUltra {
            RoundedRectangle(cornerRadius: selected ? 2 : 1, style: .continuous)
                .fill(ink)
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
            Circle()
                .fill(ink)
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

/// A tiny orbit around Ultra's beacon. Reduce Motion freezes it at a deliberate static pose.
private struct MobileUltraOrbit: View {
    @Environment(\.remoteTheme) private var theme
    let active: Bool
    let reduceMotion: Bool
    let freezesForEvidence: Bool
    let width: CGFloat

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
                Circle()
                    .fill(theme.accent.opacity(active ? 0.18 : 0.06))
                    .frame(width: width * (active ? 1.04 : 0.82))
                    .scaleEffect(active ? 0.94 + 0.08 * sin(phase * .pi / 180) : 1)

                ForEach([-18.0, 18.0], id: \.self) { tilt in
                    Capsule()
                        .stroke(
                            AngularGradient(
                                colors: [theme.accentMuted, theme.accent, theme.accentMuted],
                                center: .center,
                                angle: .degrees(phase)
                            ),
                            lineWidth: active ? 1.45 : 0.8
                        )
                        .rotationEffect(.degrees(tilt))
                }
                    .frame(width: width, height: min(22, width * 0.62))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, theme.accent.opacity(active ? 0.72 : 0.20), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.88, height: 1)
                    .rotationEffect(.degrees(phase))

                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? theme.accent : theme.accentMuted)
                        .frame(width: index == 0 ? 5 : 3, height: index == 0 ? 5 : 3)
                        .shadow(color: theme.accent.opacity(active ? 0.72 : 0), radius: 3)
                        .offset(x: width * 0.46)
                        .rotationEffect(.degrees(phase + Double(index * 120)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
