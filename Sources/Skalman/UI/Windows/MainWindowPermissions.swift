import AppKit

// MARK: - Permission Presentation

/// Presents tool approval requests from the disabled Claude headless transport.
///
/// Claude's native mode has no terminal to prompt in, so the request arrives here instead —
/// held open by the `PreToolUse` hook until it is answered. Codex Chat uses the CLI's sandbox
/// and does not route approvals through this broker.
///
/// The request is shown as a card inside the conversation that raised it, so the decision sits
/// with the session it belongs to and an off-screen session announces itself through the
/// sidebar rather than seizing the window. The modal sheet remains only as a fallback for the
/// case that should not happen — a request with no live conversation to show it in.
extension MainWindowController {

    /// Installs the presenter. Called once, at startup.
    func installPermissionPresenter() {
        PermissionBroker.present = { [weak self] request, decide in
            guard let self else {
                decide(.deny(reason: "Skalman's window has gone away."))
                return
            }

            if let conversation = AgentRuntime.shared.conversation(for: request.sessionID) {
                conversation.presentPermission(request, decide: decide)
            } else {
                self.presentPermissionSheet(request, decide: decide)
            }
        }
    }

    private func presentPermissionSheet(
        _ request: PermissionRequest,
        decide: @escaping (PermissionDecision) -> Void
    ) {
        guard let window else {
            decide(.deny(reason: "Skalman has no window to ask in."))
            return
        }

        // The request may be for a session the user is not looking at, so the sheet names
        // which one is asking rather than assuming it is the visible one.
        let sessionName = ProjectStore.shared.session(withID: request.sessionID)?.displayTitle
        let project = ProjectStore.shared.project(forSessionID: request.sessionID)?.name

        let alert = NSAlert()
        alert.messageText = L10n.format("Allow %@?", request.toolName)
        alert.informativeText = [
            request.summary,
            [sessionName, project].compactMap { $0 }.joined(separator: " · ")
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.string("Allow"))
        alert.addButton(withTitle: L10n.string("Allow for This Session"))
        alert.addButton(withTitle: L10n.string("Deny"))

        // An edit is approved on what it changes, not merely which file — so the sheet shows
        // the diff, the same one the conversation will. Other tools keep to the path or
        // command in the text above.
        if let diff = EditDiff.lines(forTool: request.toolName, input: request.input) {
            alert.accessoryView = permissionDiffAccessory(diff, path: request.filePath)
        }

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                decide(.allow(reason: "Approved in Skalman."))

            case .alertSecondButtonReturn:
                PermissionBroker.allowAlways(toolName: request.toolName, for: request.sessionID)
                decide(.allow(reason: "Approved in Skalman for the rest of this session."))

            default:
                decide(.deny(reason: "The user declined in Skalman."))
            }
        }

        // A sheet on a background window is easy to miss, and the CLI is blocked until it is
        // answered — so the app asks for attention rather than waiting silently.
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// A scrollable, size-bounded diff for the approval sheet's accessory slot.
    ///
    /// `NSAlert` sizes an accessory view to its frame, so the diff is capped in both directions
    /// and allowed to scroll — a large edit must not push the buttons off the screen.
    private func permissionDiffAccessory(_ diff: [DiffLine], path: String?) -> NSView {
        let scroll = ThemedScrollView(frame: NSRect(
            x: 0, y: 0,
            width: PermissionDiffDefaults.width,
            height: PermissionDiffDefaults.maxHeight
        ))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder

        let diffView = DiffView(lines: diff, path: path)
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = diffView

        diffView.leadingAnchor.constraint(equalTo: clip.leadingAnchor).isActive = true
        diffView.trailingAnchor.constraint(equalTo: clip.trailingAnchor).isActive = true
        diffView.topAnchor.constraint(equalTo: clip.topAnchor).isActive = true
        diffView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        return scroll
    }
}

// MARK: - Permission Diff Defaults

enum PermissionDiffDefaults {
    static let width: CGFloat = 460
    static let maxHeight: CGFloat = 280
}
