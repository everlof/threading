import Foundation
import CoreGraphics

enum SimulatorWorkspaceLayout: String, Codable, CaseIterable, Sendable {
    case automatic, row, column, grid, focus
}

/// The retained membership is deliberately bounded independently of the app-wide helper budget.
/// Layout/frame callbacks operate on at most four visible members, never the device catalogue.
struct SimulatorWorkspaceState: Codable, Equatable, Sendable {
    static let maximumMembers = 4

    struct Member: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        var deviceID: SimulatorDeviceID?
    }

    var members: [Member]
    var selectedID: UUID
    var layout: SimulatorWorkspaceLayout

    init(deviceID: SimulatorDeviceID? = nil, memberID: UUID = UUID()) {
        members = [Member(id: memberID, deviceID: deviceID)]
        selectedID = memberID
        layout = .automatic
    }

    private enum CodingKeys: String, CodingKey { case members, selectedID, layout }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        members = try values.decode([Member].self, forKey: .members)
        selectedID = try values.decode(UUID.self, forKey: .selectedID)
        layout = try values.decode(SimulatorWorkspaceLayout.self, forKey: .layout)
        let ids = members.map(\.id)
        let devices = members.compactMap(\.deviceID)
        guard !members.isEmpty, members.count <= Self.maximumMembers,
              Set(ids).count == ids.count, ids.contains(selectedID),
              Set(devices).count == devices.count,
              members.count == 1 || devices.count == members.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .members, in: values, debugDescription: "Invalid Simulator workspace membership."
            )
        }
    }
}

/// Where a request that names a platform but no device lands: a booted device of that platform
/// (a running emulator or a connected phone count as booted), else the first available one, and
/// never a device the workspace already holds. The pane's own automatic choice, the panel
/// commands and `simulator_prepare` all ask this one rule.
enum SimulatorAutomaticChoice {
    static func deviceID(
        in devices: [SimulatorDevice], android: Bool, excluding taken: Set<SimulatorDeviceID> = []
    ) -> SimulatorDeviceID? {
        let candidates = devices.filter { $0.platform.isAndroid == android && $0.isAdoptable && !taken.contains($0.id) }
        return (candidates.first(where: { $0.state.isBooted }) ?? candidates.first)?.id
    }
}

enum SimulatorWorkspaceGeometry {
    private static let nearTieRatio: CGFloat = 0.96
    /// Width over height of a modern iPhone held upright, until a member's first frame says.
    static let defaultPortraitAspect: CGFloat = 0.46

    struct Plan: Equatable {
        let layout: SimulatorWorkspaceLayout
        let frames: [CGRect]
        let visibleIndices: [Int]
    }

    static func plan(
        size: CGSize, aspects: [CGFloat], layout: SimulatorWorkspaceLayout,
        selectedIndex: Int, gap: CGFloat, titleHeight: CGFloat,
        previousLayout: SimulatorWorkspaceLayout? = nil
    ) -> Plan {
        let count = aspects.count
        guard count > 0, count <= SimulatorWorkspaceState.maximumMembers else {
            return Plan(layout: .focus, frames: [], visibleIndices: [])
        }
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        if count == 1 || layout == .focus {
            return Plan(layout: .focus, frames: Array(repeating: bounds, count: count),
                        visibleIndices: [min(max(0, selectedIndex), count - 1)])
        }
        let candidates: [SimulatorWorkspaceLayout] = layout == .automatic ? [.row, .column, .grid] : [layout]
        let plans = candidates.map { arrangement($0, bounds: bounds, count: count, gap: gap) }
        func score(_ plan: Plan) -> CGFloat {
            zip(plan.frames, aspects).map { frame, aspect in
                let ratio = aspect.isFinite && aspect > 0 ? aspect : 1
                return min(frame.width / max(1, ratio), max(0, frame.height - titleHeight) / max(1, 1 / ratio))
            }.min() ?? 0
        }
        let best = plans.max { score($0) < score($1) }!
        // A near tie keeps the arrangement stable during a divider drag.
        if let previous = plans.first(where: { $0.layout == previousLayout }),
           score(previous) >= score(best) * nearTieRatio { return previous }
        return best
    }

    private static func arrangement(
        _ layout: SimulatorWorkspaceLayout, bounds: CGRect, count: Int, gap: CGFloat
    ) -> Plan {
        let columns: Int
        switch layout {
        case .row: columns = count
        case .column: columns = 1
        default: columns = Int(ceil(sqrt(Double(count))))
        }
        let rows = (count + columns - 1) / columns
        let width = max(0, (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let height = max(0, (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        let frames = (0..<count).map { index in
            CGRect(x: CGFloat(index % columns) * (width + gap),
                   y: CGFloat(index / columns) * (height + gap), width: width, height: height)
        }
        return Plan(layout: layout, frames: frames, visibleIndices: Array(0..<count))
    }
}
