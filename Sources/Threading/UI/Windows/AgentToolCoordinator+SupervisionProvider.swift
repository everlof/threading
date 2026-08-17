@MainActor
extension AgentToolCoordinator: SupervisionToolProviding {
    var supervisionCommands: SupervisionCommandService { .shared }
}
