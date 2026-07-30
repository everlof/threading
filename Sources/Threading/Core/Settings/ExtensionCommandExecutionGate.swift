import Foundation
import ThreadingExtensionKit

/// Host-authored confirmation content for an extension command.
///
/// Only trusted host code creates this value. Extension metadata supplies the already-visible
/// extension and command names, but no sentence, button label, severity, or default action.
struct ExtensionCommandConfirmationPresentation: Equatable {
    let title: String
    let message: String
    let acceptTitle: String
    let cancelTitle: String

    init(command: AppCommand) {
        let extensionName = command.origin.extensionName ?? "This extension"
        title = "Run “\(command.title)”?"
        message = "“\(extensionName)” marked this command as destructive. "
            + "It may make changes that cannot be undone."
        acceptTitle = "Run Destructive Command"
        cancelTitle = "Cancel"
    }
}

/// Applies command risk before the request can reach an extension process.
///
/// Menu clicks and keyboard shortcuts share the same AppDelegate selector and therefore this
/// one gate. The presenter is asynchronous so a sheet does not block the app. Cancellation is
/// represented by simply never invoking the command.
@MainActor
enum ExtensionCommandExecutionGate {
    typealias Presenter = @MainActor (
        ExtensionCommandConfirmationPresentation,
        @escaping @MainActor (Bool) -> Void
    ) -> Void

    static func execute(
        _ command: AppCommand,
        present: Presenter,
        invoke: @escaping @MainActor () -> Void
    ) {
        guard command.risk == .destructive else {
            invoke()
            return
        }

        present(.init(command: command)) { approved in
            guard approved else { return }
            invoke()
        }
    }
}
