import Foundation

// MARK: - Disk Notice Hook

/// The answering hook's endpoint: `/disk-notice/<token>`, posted by Claude's
/// `PostToolUseFailure` hook.
///
/// Like `/mail-notice/` and `/question-guard/`, a deliberate exception to "hooks are silent": its
/// reply is hook JSON or an empty body. `DiskPressureNotice` decides; this parses the route and the
/// payload, and takes the volume reading here — on the listener's queue rather than the main
/// actor, since it is a syscall on the agent's hot path.
extension MCPServer {

    func routeDiskNotice(
        _ request: HTTPRequest,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        let target = request.path.dropFirst(MCPDefaults.diskNoticePathPrefix.count)
        let token = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)

        guard let token, let sessionID = MCPSessionRegistry.session(forToken: token) else {
            respond(MacMailHookOutput.silence)
            return
        }

        let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        let failure = DiskPressureFailure(payload)
        let reading = DiskSpace.immediateHomeReading()

        Task { @MainActor in
            guard let reply = DiskPressureNotice.decide(sessionID, failure: failure, reading: reading),
                  let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else {
                return respond(MacMailHookOutput.silence)
            }
            respond(.json(data))
        }
    }
}
