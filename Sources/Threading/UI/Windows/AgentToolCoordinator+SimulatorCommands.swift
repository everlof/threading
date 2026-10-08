import ThreadingSimulatorKit

@MainActor
extension AgentToolCoordinator {
    func simulatorPrepare(
        _ arguments: SimulatorPrepareArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let requestedID: SimulatorDeviceID?
        switch SimulatorAgentCommandService.requestedDeviceID(from: arguments) {
        case .accepted(let deviceID): requestedID = deviceID
        case .rejected(let result):
            completion(result)
            return
        }
        if requestedID == nil, let workspace = displayPaneController.simulatorWorkspace(for: sessionID),
           workspace.state.members.count > 1 {
            completion(.failure("Provide device_id when the workspace contains multiple Simulators."))
            return
        }
        let simulator: SimulatorPaneViewController
        do { simulator = try displayPaneController.activateSimulator(for: sessionID, deviceID: requestedID) }
        catch { completion(.failure(error.localizedDescription)); return }
        revealDisplayPane(for: sessionID)
        simulator.prepareForAgent(deviceID: requestedID) { result in
            switch result {
            case .success(let lease):
                completion(SimulatorAgentCommandService.preparationResult(for: lease))
            case .failure(let message):
                completion(.failure(message))
            }
        }
    }

    func simulatorInstallLaunch(
        _ arguments: SimulatorInstallLaunchArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let request = SimulatorAgentCommandService.launchRequest(from: arguments) {
            self.resolve(path: $0, for: sessionID)
        }
        guard case .accepted(let launch) = request else {
            if case .rejected(let result) = request { completion(result) }
            return
        }
        guard let simulator = resolveSimulatorTarget(arguments.deviceID, for: sessionID,
            missingMessage: "Call simulator_prepare before installing an app.", completion: completion) else { return }

        _ = try? displayPaneController.activateSimulator(for: sessionID)
        revealDisplayPane(for: sessionID)
        simulator.installAndLaunchForAgent(
            applicationURL: launch.applicationURL,
            bundleIdentifier: launch.bundleIdentifier,
            arguments: launch.arguments
        ) { result in
            switch result {
            case .success(let receipt):
                completion(SimulatorAgentCommandService.launchResult(for: receipt))
            case .failure(let message):
                completion(.failure(message))
            }
        }
    }

    func simulatorScreenshot(
        _ arguments: SimulatorScreenshotArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let simulator = resolveSimulatorTarget(arguments.deviceID, for: sessionID, completion: completion) else { return }

        _ = try? displayPaneController.activateSimulator(for: sessionID)
        revealDisplayPane(for: sessionID)
        let includeImage = arguments.includeImage ?? true
        let deliver: @MainActor @Sendable (SimulatorPaneAgentResult<SimulatorPaneScreenshot>) -> Void = {
            result in
            switch result {
            case .success(let capture):
                completion(SimulatorAgentCommandService.screenshotResult(
                    data: capture.data, device: capture.device, includeImage: includeImage
                ))
            case .failure(let message):
                completion(.failure(message))
            }
        }
        if let locator = SimulatorAgentCommandService.screenshotLocator(from: arguments) {
            simulator.elementScreenshotForAgent(locator: locator, completion: deliver)
        } else {
            simulator.screenshotForAgent(completion: deliver)
        }
    }

    func simulatorSnapshot(
        _ arguments: SimulatorSnapshotArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let simulator = resolveSimulatorTarget(arguments.deviceID, for: sessionID, completion: completion) else { return }

        _ = try? displayPaneController.activateSimulator(for: sessionID)
        revealDisplayPane(for: sessionID)
        simulator.snapshotForAgent { result in
            switch result {
            case .success(let snapshot):
                completion(SimulatorSnapshotRenderer.result(
                    root: snapshot.root,
                    device: snapshot.device,
                    interactiveOnly: arguments.interactiveOnly ?? true
                ))
            case .failure(let message):
                completion(.failure(message))
            }
        }
    }

    func simulatorWait(
        _ arguments: SimulatorWaitArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        switch SimulatorAgentCommandService.waitRequest(from: arguments) {
        case .rejected(let result):
            completion(result)
        case .accepted(let request):
            guard let simulator = resolveSimulatorTarget(arguments.deviceID, for: sessionID, completion: completion) else { return }
            guard let device = simulator.adoptedDevice else {
                completion(.failure("Call simulator_prepare before waiting for an element."))
                return
            }
            _ = try? displayPaneController.activateSimulator(for: sessionID)
            revealDisplayPane(for: sessionID)
            SimulatorWaitPoller.run(
                request, simulator: simulator, device: device, completion: completion
            )
        }
    }

    func simulatorAnnotations(
        _ arguments: SimulatorTargetArguments, for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let simulator = resolveSimulatorTarget(arguments.deviceID, for: sessionID, completion: completion) else { return }
        guard let device = simulator.adoptedDevice else {
            completion(.failure("Call simulator_prepare before reading the Simulator's notes."))
            return
        }
        let notes = SimulatorAnnotationStore.shared.annotations(for: device.id)
        completion(SimulatorAnnotationRenderer.result(annotations: notes, device: device))
    }

    func resolveSimulatorTarget(
        _ rawDeviceID: String?, for sessionID: SessionID,
        missingMessage: String = "Call simulator_prepare before addressing a Simulator.",
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) -> SimulatorPaneViewController? {
        guard let workspace = displayPaneController.simulatorWorkspace(for: sessionID) else {
            completion(.failure(missingMessage))
            return nil
        }
        if let rawDeviceID {
            guard let id = SimulatorDeviceID(rawDeviceID) else {
                completion(.failure("device_id must be an exact Simulator UDID."))
                return nil
            }
            guard let controller = workspace.simulators.first(where: { $0.selectedDeviceID == id }) else {
                completion(.failure("That device is not adopted in this session. Call simulator_prepare with its device_id."))
                return nil
            }
            return controller
        }
        guard workspace.simulators.count == 1 else {
            let devices = workspace.state.members.compactMap { $0.deviceID?.rawValue }.joined(separator: ", ")
            completion(.failure("Provide device_id: this workspace has multiple Simulators (\(devices))."))
            return nil
        }
        return workspace.selectedSimulator
    }
}
