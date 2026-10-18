import ThreadingSimulatorKit

/// `simulator_prepare`: puts the devices an agent asked for in the session's workspace and
/// prepares them. Routing lives in `SimulatorAgentCommandService`; this carries a route out on
/// the workspace and reports, beside the device, what the call added and removed, so repeating
/// a call visibly changes nothing and an unexpected new device is visible at once.
@MainActor
enum SimulatorAgentPreparation {
    typealias Completion = @MainActor @Sendable (MCPToolResult) -> Void

    static func run(
        _ arguments: SimulatorPrepareArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        let request: SimulatorAgentCommandService.PreparationRequest
        switch SimulatorAgentCommandService.preparationRequest(from: arguments) {
        case .accepted(let value): request = value
        case .rejected(let result): completion(result); return
        }
        let panes = coordinator.displayPaneController
        let android = request.preferAndroid ?? false
        let existing = panes.simulatorWorkspace(for: sessionID)
        if let creation = request.creation {
            if let existing, existing.simulators.count >= SimulatorWorkspaceState.maximumMembers,
               request.beside || existing.heldDevices.allSatisfy({ $0.platform.isAndroid }) {
                completion(.failure("The Simulator workspace is full. Remove a member before creating another beside it."))
                return
            }
            Task { @MainActor in
                do {
                    let created = try await panes.createSimulatorForAgent(creation)
                    let adoption = SimulatorPrepareArguments(
                        deviceID: created.id.rawValue, beside: arguments.beside, layout: arguments.layout
                    )
                    run(adoption, sessionID, through: coordinator) { result in
                        // Even a failed boot must return the new identity so an agent can recover
                        // that device instead of creating another empty one on every attempt.
                        guard result.isError else { completion(result); return }
                        completion(.failure("Created \(created.name) (\(created.id.rawValue)) with control enabled, "
                            + "but preparation failed: \(result.text) Retry simulator_prepare with device_id "
                            + "\(created.id.rawValue) and leave out create_name."))
                    }
                } catch { completion(.failure(error.localizedDescription)) }
            }
            return
        }
        let before = existing?.heldDevices ?? []
        let reveal = { [weak coordinator] (workspace: SimulatorWorkspaceViewController?) in
            if let layout = request.layout { workspace?.setLayout(layout) }
            coordinator?.revealDisplayPane(for: sessionID)
        }
        let targetID: SimulatorDeviceID?
        switch SimulatorAgentCommandService.preparationRoute(for: request, in: existing?.agentShape(android: android)) {
        case .rejected(let result): completion(result); return
        case .accepted(.prepare(let id)): targetID = id
        case .accepted(.add(let id)): targetID = id
        case .accepted(.replace(let current, with: let id)):
            guard let existing, let simulator = existing.replace(current, with: id) else {
                completion(.failure(changedWhilePreparing))
                return
            }
            _ = try? panes.activateSimulator(for: sessionID)
            reveal(existing)
            finish(simulator, deviceID: id, preferAndroid: nil, workspace: existing, before: before, completion)
            return
        case .accepted(.set(let devices, selecting: let selected)):
            let workspace: SimulatorWorkspaceViewController
            do {
                _ = try panes.activateSimulator(for: sessionID, deviceID: existing == nil ? selected : nil)
                guard let opened = panes.simulatorWorkspace(for: sessionID) else {
                    completion(.failure(changedWhilePreparing))
                    return
                }
                workspace = opened
                try workspace.setDevices(devices, selecting: selected)
            } catch { completion(.failure(error.localizedDescription)); return }
            reveal(workspace)
            prepareAll(workspace, selecting: selected, before: before, completion)
            return
        case .accepted(.addBeside):
            guard let existing else { return }
            _ = try? panes.activateSimulator(for: sessionID)
            reveal(existing)
            Task { @MainActor in
                do {
                    let simulator = try await existing.addAutomaticMember(android: android)
                    finish(simulator, deviceID: simulator.selectedDeviceID, preferAndroid: nil,
                           workspace: existing, before: before, completion)
                } catch { completion(.failure(error.localizedDescription)) }
            }
            return
        }
        let simulator: SimulatorPaneViewController
        do {
            simulator = try panes.activateSimulator(
                for: sessionID, deviceID: targetID, automaticChoiceIsAndroid: android)
        } catch { completion(.failure(error.localizedDescription)); return }
        let workspace = panes.simulatorWorkspace(for: sessionID)
        reveal(workspace)
        finish(simulator, deviceID: targetID, preferAndroid: targetID == nil ? request.preferAndroid : nil,
               workspace: workspace, before: before, completion)
    }

    private static let changedWhilePreparing =
        "The Simulator workspace changed while preparing; call simulator_prepare again."

    private static func finish(
        _ simulator: SimulatorPaneViewController,
        deviceID: SimulatorDeviceID?,
        preferAndroid: Bool?,
        workspace: SimulatorWorkspaceViewController?,
        before: [SimulatorDeviceID],
        _ completion: @escaping Completion
    ) {
        simulator.prepareForAgent(deviceID: deviceID, preferAndroid: preferAndroid) { [weak workspace] result in
            deliver(result, workspace: workspace, before: before, problems: [], completion)
        }
    }

    /// Every member of a requested workspace prepares at once, and the result waits for all of
    /// them: it describes `selected`, and lists the others that could not be prepared.
    private static func prepareAll(
        _ workspace: SimulatorWorkspaceViewController,
        selecting selected: SimulatorDeviceID,
        before: [SimulatorDeviceID],
        _ completion: @escaping Completion
    ) {
        let members = workspace.simulators
        guard let primary = members.first(where: { $0.selectedDeviceID == selected }) else {
            completion(.failure(changedWhilePreparing))
            return
        }
        let tally = Tally(remaining: members.count)
        let settle: @MainActor @Sendable () -> Void = { [weak workspace] in
            guard tally.remaining == 0, let result = tally.primary else { return }
            deliver(result, workspace: workspace, before: before, problems: tally.problems, completion)
        }
        for member in members where member !== primary {
            guard let id = member.selectedDeviceID else { tally.remaining -= 1; continue }
            member.prepareForAgent(deviceID: id) { result in
                if case .failure(let message) = result { tally.problems.append("\(id.rawValue): \(message)") }
                tally.remaining -= 1
                settle()
            }
        }
        primary.prepareForAgent(deviceID: selected) { result in
            tally.primary = result
            tally.remaining -= 1
            settle()
        }
    }

    private static func deliver(
        _ result: SimulatorPaneAgentResult<SimulatorDeviceLease>,
        workspace: SimulatorWorkspaceViewController?,
        before: [SimulatorDeviceID],
        problems: [String],
        _ completion: @escaping Completion
    ) {
        let summary = workspace?.agentSummary.changes(since: before)
        switch result {
        case .success(let lease) where lease.device.platform.isAndroid:
            // The adb serial changes with every emulator boot, so it is read now, not stored.
            Task { @MainActor in
                let serial = try? await AndroidDeviceControl.shared?.target(for: lease.device.id).serial
                completion(SimulatorAgentCommandService.preparationResult(
                    for: lease, adbSerial: serial, workspace: summary, problems: problems))
            }
        case .success(let lease):
            completion(SimulatorAgentCommandService.preparationResult(
                for: lease, workspace: summary, problems: problems))
        case .failure(let message):
            completion(.failure(message))
        }
    }

    /// The members of a requested workspace still preparing, and what they answered.
    @MainActor
    private final class Tally {
        var remaining: Int
        var primary: SimulatorPaneAgentResult<SimulatorDeviceLease>?
        var problems: [String] = []

        init(remaining: Int) { self.remaining = remaining }
    }
}
