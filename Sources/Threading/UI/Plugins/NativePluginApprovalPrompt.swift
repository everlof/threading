import AppKit
import ThreadingPluginKit

/// The question itself.
///
/// Deliberately blunt about what is being agreed to. A plugin is not sandboxed and not a document:
/// approving one means its code runs inside Threading, with Threading's files, Threading's network
/// access and every permission the user has granted Threading. A dialog that said "allow this
/// extension?" would be technically true and practically a lie.
@MainActor
enum NativePluginApprovalPrompt {

    static func ask(
        about identity: PluginLoader.PluginIdentity,
        named name: String,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let signer = identity.team.map { L10n.format("signed by team %@", $0) }
            ?? L10n.string("not signed by any identified developer")

        let request = ConfirmationRequest(
            prompt: .runNativePlugin,
            title: L10n.format("Run “%@” inside Threading?", name),
            message: L10n.format(
                "This plugin is %@. Its code runs inside Threading, with access to your files, "
                    + "your network, and everything you have permitted Threading to do. It is not "
                    + "sandboxed.\n\nOnly allow a plugin you trust as much as you trust Threading "
                    + "itself. This answer applies to this exact build — an update will ask again.",
                signer
            ),
            confirmTitle: L10n.string("Allow"),
            cancelTitle: L10n.string("Don't Allow")
        )
        ConfirmationAlert.ask(request, in: window) { approved in
            // A refusal is remembered too: asking again every launch teaches a user to click
            // through the question that protects them.
            NativePluginApprovalStore.shared.remember(approved, for: identity)
            completion(approved)
        }
    }
}
