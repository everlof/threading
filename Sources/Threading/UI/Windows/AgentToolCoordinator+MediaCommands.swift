import AppKit
import Foundation

@MainActor
extension AgentToolCoordinator {

    /// Reads a recording into a still the calling agent can look at, and shows the user the
    /// same picture.
    ///
    /// A transport adapter: it resolves the path against this session's project, hands the work
    /// to `VideoFrameSheet`, and takes custody of the bytes. Every refusal, number and sentence
    /// in the reply belongs to the request and the result, not to this hub.
    ///
    /// The result carries an image block, which almost nothing else here does — the rule is
    /// `browser_screenshot`'s. A display tool has already put its picture where the *user* can
    /// see it, so returning it again would cost the transcript an image for nothing. Here the
    /// agent's own visual inspection is the entire purpose, and a sentence in place of the
    /// image would be the agent describing a picture it never saw.
    func videoFrames(
        _ arguments: VideoFramesArguments,
        for sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        if let refusal = VideoFrameSheetRequest.refusal(for: arguments) {
            completion(.failure(refusal))
            return
        }
        guard let path = arguments.path, let url = resolve(path: path, for: sessionID) else {
            completion(.failure("No such file: \(arguments.path ?? "")"))
            return
        }

        let request = VideoFrameSheetRequest(url: url, arguments: arguments)
        Task { [weak self] in
            do {
                let sheet = try await VideoFrameSheet.make(request)
                await MainActor.run {
                    guard let self else {
                        completion(.failure("Threading closed the window this call arrived on."))
                        return
                    }
                    completion(self.present(sheet, from: url, for: sessionID))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(
                        "\(url.lastPathComponent) could not be read: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    /// Records the sheet as an attachment and shows it beside the conversation.
    private func present(
        _ sheet: VideoFrameSheetResult,
        from url: URL,
        for sessionID: SessionID
    ) -> MCPToolResult {
        var recorded: SessionAttachment?
        if dependencies.projects.executionProject(forSessionID: sessionID) != nil {
            recorded = dependencies.attachments.recordSnapshot(
                sheet.pngData,
                of: url.deletingPathExtension().appendingPathExtension("frames.png"),
                sessionID: sessionID,
                origin: .agent
            )
        }

        var destination =
            "Shown to you only; this session has no project to record an attachment against."
        if let recorded, let attachments = displayPaneController.activateAttachments(for: sessionID)
        {
            attachments.showAttachment(at: recorded.url)
            destination = "Also shown to the user "
                + (revealDisplayPane(for: sessionID)
                    ? "in the display panel's Attachments list."
                    : "in this session's display panel, which opens when they select it.")
        }

        return .screenshot(
            sheet.report(fileName: url.lastPathComponent, destination: destination),
            pngData: sheet.pngData,
            includeImage: true
        )
    }
}
