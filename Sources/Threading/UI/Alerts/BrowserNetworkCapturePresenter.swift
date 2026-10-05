import AppKit

@MainActor
enum BrowserNetworkCapturePresenter {
    static func request(
        _ request: BrowserNetworkCaptureRequest,
        settings: BrowserNetworkCaptureSettings,
        sessionID: SessionID,
        window: NSWindow?,
        decision: ((BrowserNetworkCaptureOptions, @escaping @MainActor (Bool) -> Void) -> Void)?,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        BrowserNetworkCaptureCommandService.request(request, settings: settings, confirm: { proposed, settle in
            if let decision {
                decision(proposed, settle)
                return
            }
            let enabled = BrowserNetworkCaptureField.allCases
                .filter { proposed[$0] }.map { L10n.string($0.title) }.joined(separator: "\n")
            BrowserPermissionPresenter.confirm(ConfirmationRequest(
                prompt: .approveBrowserNetworkCapture,
                title: L10n.string("Change Browser Network Capture?"),
                message: L10n.format(
                    "This changes capture for all in-app browser tabs. Enabled details:\n%@\n\nText payloads can contain site data and become readable to agents with website access. Changes affect future requests and clear existing captured payloads. You can change this in Settings ▸ Tools ▸ Browser Network Capture.",
                    enabled.isEmpty ? L10n.string("Metadata only") : enabled
                ),
                confirmTitle: L10n.string("Apply Capture Settings")
            ), for: sessionID, in: window, completion: settle)
        }, completion: completion)
    }
}
