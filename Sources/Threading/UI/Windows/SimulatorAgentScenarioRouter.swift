import Foundation

/// `simulator_scenario`: the agent's way into the same scenario controller as the workspace's
/// Scenarios menu and band, so what an agent opens is what the person sees, and the reverse.
@MainActor
enum SimulatorAgentScenarioRouter {
    typealias Completion = @MainActor @Sendable (MCPToolResult) -> Void

    static func run(
        _ arguments: SimulatorScenarioArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        guard let workspace = coordinator.displayPaneController.simulatorWorkspace(for: sessionID) else {
            completion(.failure("Call simulator_prepare before opening a scenario."))
            return
        }
        var deviceID: SimulatorDeviceID?
        if let raw = arguments.deviceID {
            guard let id = SimulatorDeviceID(raw) else {
                completion(.failure(SimulatorAgentCommandService.deviceIDFormatFailure))
                return
            }
            guard workspace.simulators.contains(where: { $0.selectedDeviceID == id }) else {
                completion(.failure("That device is not adopted in this session. Call simulator_prepare with its device_id."))
                return
            }
            deviceID = id
        }
        if let step = arguments.step, step < 0 {
            completion(.failure("step counts from 0."))
            return
        }
        _ = try? coordinator.displayPaneController.activateSimulator(for: sessionID)
        coordinator.revealDisplayPane(for: sessionID)
        let scenarios = workspace.scenarios
        Task { @MainActor in
            do {
                switch (arguments.scenario, arguments.step) {
                case (nil, nil):
                    await scenarios.reload()
                    completion(await listing(scenarios))
                case (let id?, let step):
                    await scenarios.reload()
                    completion(await result(try await scenarios.open(id, step: step, on: deviceID)))
                case (nil, let step?):
                    completion(await result(try await scenarios.go(to: step)))
                }
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    // MARK: - Results

    private struct ListingPayload: Encodable, Sendable {
        let file: String?
        let devicePlatforms: [String]
        let open: OpenPayload?
        let scenarios: [ScenarioPayload]
        let problems: [String]

        private enum CodingKeys: String, CodingKey {
            case file, open, scenarios, problems
            case devicePlatforms = "device_platforms"
        }
    }

    private struct ScenarioPayload: Encodable, Sendable {
        let id: String
        let group: String
        let title: String
        let variant: String?
        let platforms: [String]
        let steps: [String]?
    }

    private struct OpenPayload: Encodable, Sendable {
        let scenario: String
        let step: Int?
        let stepTitle: String?
        let stepCount: Int
        let devices: [String]
        let failures: [String]

        private enum CodingKeys: String, CodingKey {
            case scenario, step, devices, failures
            case stepTitle = "step_title"
            case stepCount = "step_count"
        }
    }

    private static func listing(_ scenarios: SimulatorScenarioController) async -> MCPToolResult {
        guard let catalog = scenarios.catalog else {
            return .failure(SimulatorScenarioError.noCheckout.localizedDescription)
        }
        guard catalog.fileExists else {
            return .failure(SimulatorScenarioError.noFile.localizedDescription
                + " Open Scenario Help from the workspace's Scenarios button to set one up.")
        }
        let open = scenarios.session.map { session in
            OpenPayload(
                scenario: session.scenario.id,
                step: session.scenario.hasSteps ? session.step : nil,
                stepTitle: session.scenario.hasSteps ? session.scenario.steps[session.step].title : nil,
                stepCount: session.scenario.steps.count,
                devices: session.deviceIDs.map(\.rawValue),
                failures: session.failure.map { [$0] } ?? []
            )
        }
        return await encoded(ListingPayload(
            file: catalog.fileURL.path,
            devicePlatforms: scenarios.memberPlatforms.map(\.rawValue).sorted(),
            open: open,
            scenarios: scenarios.offeredScenarios.map { scenario in
                ScenarioPayload(
                    id: scenario.id, group: scenario.group, title: scenario.title, variant: scenario.variant,
                    platforms: scenario.platforms.map(\.rawValue).sorted(),
                    steps: scenario.hasSteps ? scenario.steps.map(\.title) : nil
                )
            },
            problems: catalog.diagnostics.map(\.message)
        ))
    }

    private static func result(_ outcome: SimulatorScenarioController.Outcome) async -> MCPToolResult {
        let payload = OpenPayload(
            scenario: outcome.scenario.id,
            step: outcome.step,
            stepTitle: outcome.step.flatMap { outcome.scenario.steps.indices.contains($0) ? outcome.scenario.steps[$0].title : nil },
            stepCount: outcome.scenario.steps.count,
            devices: outcome.devices.map(\.rawValue),
            failures: outcome.failures
        )
        // Every device refusing is a failure; some refusing is a result that names them.
        guard outcome.failures.count < max(outcome.devices.count, 1) else {
            return .failure(outcome.failures.joined(separator: "\n"))
        }
        return await encoded(payload)
    }

    /// A listing can name 512 scenarios, so it is encoded on a worker.
    private static func encoded<Value: Encodable & Sendable>(_ value: Value) async -> MCPToolResult {
        await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
                return MCPToolResult.failure("Could not encode the scenario result.")
            }
            return MCPToolResult.success(text)
        }.value
    }
}

/// The tool hub conforms through its Simulator adapter; this default hands off to the router,
/// as the input tools do (`SimulatorAgentInputRouter`).
@MainActor
extension MCPBuiltInToolExecuting {
    func simulatorScenario(
        _ arguments: SimulatorScenarioArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Simulator scenarios are unavailable in this host."))
            return
        }
        SimulatorAgentScenarioRouter.run(arguments, sessionID, through: coordinator, completion)
    }
}
