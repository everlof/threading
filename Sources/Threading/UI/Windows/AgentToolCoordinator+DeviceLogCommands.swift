import Foundation

@MainActor
extension AgentToolCoordinator {

    /// Reveal the live log pane and return how to make the app under development say anything.
    /// The build stays the agent's own command, for the reason `simulator-pane.md` gives about
    /// `xcodebuild`. The *linked* tap additionally needs the user's own decision: it changes what
    /// their product publishes rather than what Threading shows.
    func deviceLogPrepare(
        _ arguments: DeviceLogPrepareArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let platform: DeviceLogTap.Platform
        switch DeviceLogAgentCommandService.platform(from: arguments) {
        case .accepted(let accepted): platform = accepted
        case .rejected(let result):
            completion(result)
            return
        }
        displayPaneController.activateDeviceLog(for: sessionID)
        revealDisplayPane(for: sessionID)
        guard platform.isLinked else {
            completion(DeviceLogAgentCommandService.result(building: platform))
            return
        }
        DeviceLogTapConsentController.shared.authorize(for: sessionID, in: windowProvider()) { approved in
            completion(approved
                ? DeviceLogAgentCommandService.result(building: platform)
                : DeviceLogAgentCommandService.refusedResult())
        }
    }
}
