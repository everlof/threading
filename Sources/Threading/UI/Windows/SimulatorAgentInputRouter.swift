import ThreadingSimulatorKit

/// Thin UI routing for the four typed input declarations.
///
/// Validation and stable results remain in the application service; this adapter only converges
/// the calls on the visible session-owned pane and translates the app vocabulary to the helper's
/// closed wire vocabulary.
@MainActor
enum SimulatorAgentInputRouter {
    typealias Completion = @MainActor @Sendable (MCPToolResult) -> Void

    static func tap(
        _ arguments: SimulatorTapArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        send(
            SimulatorAgentCommandService.tapInput(from: arguments),
            action: "tap",
            sessionID: sessionID,
            through: coordinator,
            completion
        )
    }

    static func swipe(
        _ arguments: SimulatorSwipeArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        send(
            SimulatorAgentCommandService.swipeInput(from: arguments),
            action: "swipe",
            sessionID: sessionID,
            through: coordinator,
            completion
        )
    }

    static func typeText(
        _ arguments: SimulatorTypeTextArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        send(
            SimulatorAgentCommandService.textInput(from: arguments),
            action: "type_text",
            sessionID: sessionID,
            through: coordinator,
            completion
        )
    }

    static func pressButton(
        _ arguments: SimulatorPressButtonArguments,
        _ sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        send(
            SimulatorAgentCommandService.buttonInput(from: arguments),
            action: "press_button",
            sessionID: sessionID,
            through: coordinator,
            completion
        )
    }

    private static func send(
        _ request: SimulatorAgentCommandService.Request<SimulatorAgentCommandService.Input>,
        action: String,
        sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) {
        guard case .accepted(let input) = request else {
            if case .rejected(let result) = request { completion(result) }
            return
        }
        guard let simulator = coordinator.displayPaneController.tabs(for: sessionID)
            .compactMap(\.simulator).first,
              let device = simulator.adoptedDevice else {
            completion(.failure("Call simulator_prepare before controlling the Simulator."))
            return
        }
        _ = coordinator.displayPaneController.activateSimulator(for: sessionID)
        coordinator.revealDisplayPane(for: sessionID)
        simulator.sendInputForAgent(bridgeInput(input)) { result in
            switch result {
            case .success:
                completion(SimulatorAgentCommandService.inputResult(action: action, device: device))
            case .failure(let message):
                completion(.failure(message))
            }
        }
    }

    private static func bridgeInput(
        _ input: SimulatorAgentCommandService.Input
    ) -> SimulatorBridgeInput {
        switch input {
        case .tap(let x, let y):
            return .tap(x: x, y: y)
        case .swipe(let fromX, let fromY, let toX, let toY, let duration):
            return .drag(
                fromX: fromX,
                fromY: fromY,
                toX: toX,
                toY: toY,
                durationMilliseconds: duration
            )
        case .text(let text):
            return .text(text)
        case .button(let button):
            switch button {
            case .home: return .button(.home)
            case .lock: return .button(.lock)
            case .side: return .button(.side)
            case .volumeUp: return .button(.volumeUp)
            case .volumeDown: return .button(.volumeDown)
            }
        }
    }
}

/// The tool hub already conforms through its existing Simulator adapter. Input policy is large
/// enough to stay outside that authority-ratcheted type, so these protocol defaults only perform
/// the checked downcast to the app's sole executor and hand off to the router above.
@MainActor
extension MCPBuiltInToolExecuting {
    func simulatorTap(
        _ arguments: SimulatorTapArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Simulator input is unavailable in this host."))
            return
        }
        SimulatorAgentInputRouter.tap(arguments, sessionID, through: coordinator, completion)
    }

    func simulatorSwipe(
        _ arguments: SimulatorSwipeArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Simulator input is unavailable in this host."))
            return
        }
        SimulatorAgentInputRouter.swipe(arguments, sessionID, through: coordinator, completion)
    }

    func simulatorTypeText(
        _ arguments: SimulatorTypeTextArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Simulator input is unavailable in this host."))
            return
        }
        SimulatorAgentInputRouter.typeText(arguments, sessionID, through: coordinator, completion)
    }

    func simulatorPressButton(
        _ arguments: SimulatorPressButtonArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let coordinator = self as? AgentToolCoordinator else {
            completion(.failure("Simulator input is unavailable in this host."))
            return
        }
        SimulatorAgentInputRouter.pressButton(arguments, sessionID, through: coordinator, completion)
    }
}
