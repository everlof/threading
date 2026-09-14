import CoreGraphics
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
        switch SimulatorAgentCommandService.tapAddressing(from: arguments) {
        case .rejected(let result):
            completion(result)
        case .coordinate(let x, let y):
            send(
                .accepted(.tap(x: x, y: y)),
                action: "tap",
                sessionID: sessionID,
                through: coordinator,
                completion
            )
        case .locator(let locator):
            resolve(locator, sessionID: sessionID, through: coordinator, completion) {
                simulator, device, point in
                simulator.sendInputForAgent(.tap(x: Double(point.x), y: Double(point.y))) { result in
                    finish(result, action: "tap", device: device, completion)
                }
            }
        }
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
        switch SimulatorAgentCommandService.typeAddressing(from: arguments) {
        case .rejected(let result):
            completion(result)
        case .focused(let text):
            send(
                .accepted(.text(text)),
                action: "type_text",
                sessionID: sessionID,
                through: coordinator,
                completion
            )
        case .located(let locator, let text):
            // Focus the located field with a tap, then type into it.
            resolve(locator, sessionID: sessionID, through: coordinator, completion) {
                simulator, device, point in
                simulator.sendInputForAgent(.tap(x: Double(point.x), y: Double(point.y))) { tap in
                    switch tap {
                    case .failure(let message):
                        completion(.failure(message))
                    case .success:
                        simulator.sendInputForAgent(.text(text)) { result in
                            finish(result, action: "type_text", device: device, completion)
                        }
                    }
                }
            }
        }
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
        guard let (simulator, device) = resolvedSimulator(
            for: sessionID, through: coordinator, completion
        ) else { return }
        simulator.sendInputForAgent(bridgeInput(input)) { result in
            finish(result, action: action, device: device, completion)
        }
    }

    /// Resolve the session's visible Simulator pane and adopted device, revealing and activating it,
    /// or complete with the standard "prepare first" failure and return nil.
    private static func resolvedSimulator(
        for sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion
    ) -> (SimulatorPaneViewController, SimulatorDevice)? {
        guard let simulator = coordinator.displayPaneController.tabs(for: sessionID)
            .compactMap(\.simulator).first,
              let device = simulator.adoptedDevice else {
            completion(.failure("Call simulator_prepare before controlling the Simulator."))
            return nil
        }
        _ = coordinator.displayPaneController.activateSimulator(for: sessionID)
        coordinator.revealDisplayPane(for: sessionID)
        return (simulator, device)
    }

    /// Take a fresh snapshot and resolve the locator to a normalized point immediately before acting.
    /// A miss or an ambiguity fails with a helpful message rather than a silent guess.
    private static func resolve(
        _ locator: SimulatorAgentCommandService.ElementLocator,
        sessionID: SessionID,
        through coordinator: AgentToolCoordinator,
        _ completion: @escaping Completion,
        onResolved: @escaping @MainActor @Sendable (
            SimulatorPaneViewController, SimulatorDevice, CGPoint
        ) -> Void
    ) {
        guard let (simulator, device) = resolvedSimulator(
            for: sessionID, through: coordinator, completion
        ) else { return }
        simulator.snapshotForAgent { result in
            switch result {
            case .failure(let message):
                completion(.failure(message))
            case .success(let snapshot):
                switch SimulatorElementResolver.resolve(locator, in: snapshot.root) {
                case .point(let point):
                    onResolved(simulator, device, point)
                case .notFound(let message), .ambiguous(let message):
                    completion(.failure(message))
                }
            }
        }
    }

    private static func finish(
        _ result: SimulatorPaneAgentResult<Void>,
        action: String,
        device: SimulatorDevice,
        _ completion: @escaping Completion
    ) {
        switch result {
        case .success:
            completion(SimulatorAgentCommandService.inputResult(action: action, device: device))
        case .failure(let message):
            completion(.failure(message))
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
