import AppKit
import ThreadingExtensionKit

/// One shared path from a chosen extension command to its process: the destructive gate, the
/// host-owned confirmation and result alerts, and the dispatch. The menu bar and the sidebar's
/// row menus both route here, so the two invocations can never drift — a row menu that skipped
/// the destructive confirmation would be exactly the kind of gap that grows silently.
@MainActor
enum ExtensionCommandInvoker {

    static func perform(
        _ command: AppCommand,
        context: ExtensionCommandContext,
        input: ExtensionCommandInputValue? = nil,
        window: NSWindow?
    ) {
        guard case .extensionCommand(let identifier, _, let localID) = command.origin else {
            return
        }
        ExtensionCommandExecutionGate.execute(
            command,
            present: { presentation, completion in
                presentConfirmation(presentation, in: window, completion: completion)
            },
            invoke: {
                invoke(
                    command,
                    extensionIdentifier: identifier,
                    localID: localID,
                    context: context,
                    input: input,
                    window: window
                )
            }
        )
    }

    // MARK: - Private Methods

    private static func invoke(
        _ command: AppCommand,
        extensionIdentifier: String,
        localID: String,
        context: ExtensionCommandContext,
        input: ExtensionCommandInputValue?,
        window: NSWindow?
    ) {
        ExtensionManager.shared.invokeCommand(
            extensionIdentifier: extensionIdentifier,
            commandID: localID,
            context: context,
            input: input
        ) { result in
            switch result {
            case .failure(let error):
                NoticeAlert.show(
                    resultNotice(
                        for: command,
                        message: error.localizedDescription,
                        isError: true
                    ),
                    in: window
                )
            case .success(let response):
                if let error = response.error {
                    NoticeAlert.show(
                        resultNotice(for: command, message: error, isError: true),
                        in: window
                    )
                } else if let message = response.message {
                    NoticeAlert.show(
                        resultNotice(for: command, message: message, isError: false),
                        in: window
                    )
                }
            }
        }
    }

    /// The receipt or the failure, as one request. A success carries the command's own notice
    /// key, so its "done" message can be declined per command; an error carries none, so it
    /// can never be hidden — a command whose failures stopped showing would read as working.
    /// Internal rather than private for exactly that assertion (`NoticeAlertTests`).
    static func resultNotice(
        for command: AppCommand,
        message: String,
        isError: Bool
    ) -> NoticeRequest {
        NoticeRequest(
            notice: isError ? nil : .extensionCommandReceipt(commandID: command.id),
            title: command.title,
            message: message,
            style: isError ? .warning : .informational
        )
    }

    private static func presentConfirmation(
        _ presentation: ExtensionCommandConfirmationPresentation,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        // Destructive execution is deliberately not the Return-key default. That used to be
        // three lines here and nowhere else; the register states it once, for every prompt
        // whose policy is `.irreversible`.
        let request = ConfirmationRequest(
            prompt: .runDestructiveExtensionCommand,
            title: presentation.title,
            message: presentation.message,
            confirmTitle: presentation.acceptTitle,
            cancelTitle: presentation.cancelTitle
        )
        ConfirmationAlert.ask(request, in: window, completion: completion)
    }

}
