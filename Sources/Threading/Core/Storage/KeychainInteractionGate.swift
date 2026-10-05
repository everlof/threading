import Foundation
import Security

/// The one owner of Security's keychain user-interaction switch inside the app.
///
/// `SecKeychainSetUserInteractionAllowed` is the mechanism verified to hold a login-Keychain
/// prompt back (`kSecUseAuthenticationUI` promises the same but was not provable without risking
/// a live prompt), and it is process-global. Two callers toggling it independently can leave it
/// off for the whole app, or turn it back on under a read that must not prompt. Every read that
/// toggles it, and every read that may prompt, therefore runs through this one serial gate.
/// A body may block while a person answers a prompt; call it off the main actor.
enum KeychainInteractionGate {
    private static let queue = DispatchQueue(label: "codes.threading.keychain-interaction")

    /// Whether a login-Keychain read made now could show a prompt. Tests use it to prove a caller
    /// read with the switch off.
    static var interactionAllowed: Bool {
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        return allowed.boolValue
    }

    static func run<T>(allowingPrompt: Bool, _ body: () -> T) -> T {
        queue.sync {
            guard !allowingPrompt else { return body() }
            var restore: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&restore)
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(restore.boolValue) }
            return body()
        }
    }
}
