import AppKit

// MARK: - Permission Presentation

/// Presents tool approval requests from native conversation transports.
///
/// A native mode has no terminal to prompt in. Claude's request is held open by `PreToolUse`;
/// Codex's arrives as an app-server JSON-RPC request. Both use the same policy and inline card.
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
                decide(.deny(reason: "Threading's window has gone away."))
                return
            }

            if let conversation = AgentRuntime.shared.conversation(for: request.sessionID) {
                conversation.presentPermission(request, decide: decide)
            } else {
                self.presentPermissionSheet(request, decide: decide)
            }
        }

        PermissionBroker.explainSystemGrant = { [weak self] permission, request, proceed in
            guard let self else {
                proceed(false)
                return
            }
            self.presentSystemGrantSheet(permission, request, proceed: proceed)
        }
    }

    // MARK: - System Grants

    /// Says what macOS is about to ask for, and on whose behalf, before the command that makes
    /// it ask runs.
    ///
    /// A window sheet rather than a card inside the conversation, which is the opposite of the
    /// choice above and for a reason: this is not a question about one chat's next tool call.
    /// It is about a grant held by the application, given once and then exercised by every
    /// session — and the dialog it is warning about will itself arrive as an application-modal
    /// system alert. A card in a pane the user may not be looking at would be a footnote to an
    /// interruption.
    private func presentSystemGrantSheet(
        _ permission: SystemPrivacyPermission,
        _ request: PermissionRequest,
        proceed: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let session = ProjectStore.shared.session(withID: request.sessionID)

        ConfirmationAlert.ask(
            Self.systemGrantConfirmation(
                permission: permission,
                agent: session?.kind.displayName,
                command: request.summary,
                sessionName: session?.displayTitle,
                projectName: ProjectStore.shared.project(forSessionID: request.sessionID)?.name
            ),
            in: window
        ) { accepted in proceed(accepted) }

        // The agent is blocked until this is answered, and the sheet may be on a window behind
        // whatever the user is doing — the same reason the permission sheet asks for attention.
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// The sheet's wording, built without being run.
    ///
    /// Separated from the presentation for the reason `AppDelegate.quitConfirmation` is: this is
    /// the only place the user is told that the dialog they are about to see names the wrong
    /// program, and a test has to be able to read that sentence without a modal on screen.
    static func systemGrantConfirmation(
        permission: SystemPrivacyPermission,
        agent: String?,
        command: String,
        sessionName: String?,
        projectName: String?
    ) -> ConfirmationRequest {
        // A session Threading cannot name is not a reason to leave the sentence dangling; the
        // grant and the command are the parts that carry it.
        let agent = agent ?? L10n.string("An agent")

        // The command is the whole answer to "why now", so it comes first and in full. The chat
        // and project follow, because the next question after "why" is "which of these six".
        let attribution = [sessionName, projectName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return ConfirmationRequest(
            prompt: .approveSystemPermissionPrompt,
            title: L10n.format("%@ needs macOS %@", agent, permission.title),
            message: [
                command,
                attribution,
                L10n.format(
                    "macOS will ask next, and its prompt will say Threading rather than %@: a "
                        + "program Threading launches is approved against Threading's own grant. "
                        + "Nothing is granted by continuing — the system asks separately, and "
                        + "you can refuse it there too.",
                    agent
                ),
                permission.purpose
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n"),
            confirmTitle: L10n.string("Continue"),
            cancelTitle: L10n.string("Deny"),
            // Not a warning: nothing has gone wrong, and nothing is granted by answering it.
            style: .informational
        )
    }

    private func presentPermissionSheet(
        _ request: PermissionRequest,
        decide: @escaping @MainActor @Sendable (PermissionDecision) -> Void
    ) {
        guard let window else {
            decide(.deny(reason: "Threading has no window to ask in."))
            return
        }

        // The request may be for a session the user is not looking at, so the sheet names
        // which one is asking rather than assuming it is the visible one.
        let sessionName = ProjectStore.shared.session(withID: request.sessionID)?.displayTitle
        let project = ProjectStore.shared.project(forSessionID: request.sessionID)?.name

        // An edit is approved on what it changes, not merely which file — so the sheet shows
        // the diff, the same one the conversation will. Other tools keep to the path or
        // command in the text above.
        let diff = EditDiff.lines(forTool: request.toolName, input: request.foundationInput)

        // "Allow for This Session" is this prompt's remembered answer, and it is scoped to one
        // tool in one session. A "Don't ask again" box would be the same idea with none of the
        // scope, which is why a grant is `.alwaysAsks` in the register.
        let choice = ChoiceRequest(
            prompt: .approveToolPermission,
            title: L10n.format("Allow %@?", request.toolName),
            message: [
                request.summary,
                [sessionName, project].compactMap { $0 }.joined(separator: " · ")
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n"),
            options: [
                ConfirmationOption(title: L10n.string("Allow")),
                ConfirmationOption(title: L10n.string("Allow for This Session"))
            ],
            cancelTitle: L10n.string("Deny"),
            style: .informational,
            accessory: diff.map { permissionDiffAccessory($0, path: request.filePath) }
        )

        ConfirmationAlert.choose(choice, in: window) { chosen in
            switch chosen {
            case 0:
                decide(.allow(reason: "Approved in Threading."))

            case 1:
                PermissionBroker.allowAlways(toolName: request.toolName, for: request.sessionID)
                decide(.allow(reason: "Approved in Threading for the rest of this session."))

            default:
                decide(.deny(reason: "The user declined in Threading."))
            }
        }

        // A sheet on a background window is easy to miss, and the CLI is blocked until it is
        // answered — so the app asks for attention rather than waiting silently.
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// A scrollable, size-bounded diff for the approval sheet's accessory slot.
    ///
    /// The alert sizes an accessory view to its frame, so the diff is capped in both directions
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
