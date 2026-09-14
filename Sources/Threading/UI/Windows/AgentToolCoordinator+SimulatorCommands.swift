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
        let simulator = displayPaneController.activateSimulator(
            for: sessionID,
            deviceID: requestedID
        )
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
        guard let simulator = adoptedSimulator(for: sessionID) else {
            completion(.failure("Call simulator_prepare before installing an app."))
            return
        }

        _ = displayPaneController.activateSimulator(for: sessionID)
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
        guard let simulator = adoptedSimulator(for: sessionID) else {
            completion(.failure("Call simulator_prepare before capturing the Simulator."))
            return
        }

        _ = displayPaneController.activateSimulator(for: sessionID)
        revealDisplayPane(for: sessionID)
        simulator.screenshotForAgent { result in
            switch result {
            case .success(let capture):
                completion(SimulatorAgentCommandService.screenshotResult(
                    data: capture.data,
                    device: capture.device,
                    includeImage: arguments.includeImage ?? true
                ))
            case .failure(let message):
                completion(.failure(message))
            }
        }
    }

    func simulatorSnapshot(
        _ arguments: SimulatorSnapshotArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let simulator = adoptedSimulator(for: sessionID) else {
            completion(.failure("Call simulator_prepare before reading the Simulator's elements."))
            return
        }

        _ = displayPaneController.activateSimulator(for: sessionID)
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

    func simulatorAnnotations(
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let simulator = adoptedSimulator(for: sessionID),
              let device = simulator.adoptedDevice else {
            completion(.failure("Call simulator_prepare before reading the Simulator's notes."))
            return
        }
        let notes = SimulatorAnnotationStore.shared.annotations(for: device.id)
        completion(SimulatorAnnotationRenderer.result(annotations: notes, device: device))
    }

    private func adoptedSimulator(for sessionID: SessionID) -> SimulatorPaneViewController? {
        displayPaneController.tabs(for: sessionID)
            .compactMap(\.simulator)
            .first
    }
}

