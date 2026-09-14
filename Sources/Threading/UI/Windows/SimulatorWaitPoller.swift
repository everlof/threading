import Foundation
import ThreadingSimulatorKit

/// Polls fresh accessibility snapshots until a locator appears or disappears, or the deadline
/// passes — the `simulator_wait` engine. Kept off the coordinator so the poll loop does not count
/// toward its authority budget.
@MainActor
enum SimulatorWaitPoller {
    /// How often to re-snapshot while waiting. A warm snapshot is milliseconds; this keeps the read
    /// rate modest without making the wait feel laggy.
    private static let pollInterval: TimeInterval = 0.3

    static func run(
        _ request: SimulatorAgentCommandService.WaitRequest,
        simulator: SimulatorPaneViewController,
        device: SimulatorDevice,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let deadline = Date().addingTimeInterval(
            Double(request.timeoutMilliseconds) / 1_000
        )
        step(request, simulator: simulator, device: device, deadline: deadline, completion: completion)
    }

    private static func step(
        _ request: SimulatorAgentCommandService.WaitRequest,
        simulator: SimulatorPaneViewController,
        device: SimulatorDevice,
        deadline: Date,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        simulator.snapshotForAgent { result in
            switch result {
            case .failure(let message):
                completion(.failure(message))
            case .success(let snapshot):
                let matches = SimulatorElementResolver.matchCount(
                    request.locator, in: snapshot.root
                )
                let satisfied = request.condition == .appears ? matches > 0 : matches == 0
                if satisfied {
                    completion(.success(describe(request, satisfied: true, device: device)))
                } else if Date() >= deadline {
                    completion(.failure(describe(request, satisfied: false, device: device)))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                        step(
                            request, simulator: simulator, device: device,
                            deadline: deadline, completion: completion
                        )
                    }
                }
            }
        }
    }

    private static func describe(
        _ request: SimulatorAgentCommandService.WaitRequest,
        satisfied: Bool,
        device: SimulatorDevice
    ) -> String {
        let verb = request.condition == .appears ? "appear" : "disappear"
        let target = locatorDescription(request.locator)
        if satisfied {
            return "\(target) did \(verb) on \(device.name). Read simulator_snapshot for its ref and tap point."
        }
        return "Timed out after \(request.timeoutMilliseconds) ms waiting for \(target) to \(verb)."
    }

    private static func locatorDescription(
        _ locator: SimulatorAgentCommandService.ElementLocator
    ) -> String {
        var parts: [String] = []
        if let role = locator.role, !role.isEmpty { parts.append("role=\(role)") }
        if let label = locator.label, !label.isEmpty { parts.append("label=\"\(label)\"") }
        if let identifier = locator.identifier, !identifier.isEmpty {
            parts.append("identifier=\(identifier)")
        }
        return parts.isEmpty ? "the element" : parts.joined(separator: " ")
    }
}
