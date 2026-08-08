import Foundation

// MARK: - App Data Reset Flow

/// Performing a reset, as opposed to deciding to.
///
/// Two screens offer this now — Settings ▸ Advanced and the recovery surface — and the part that
/// must not differ between them is not the wording but the *order*: the app-owned Keychain items
/// have to be erased before the directories are moved, because keychain items are in neither the
/// preferences domain nor the support directory and nothing else would ever remove them. A second
/// copy of that sequence is how one screen quietly stops clearing a credential.
///
/// The confirmation and the failure alert stay with the caller. Their blast radii read
/// differently on a settings page and on a crash screen, and this owns neither sentence.
@MainActor
enum AppDataResetFlow {

    /// Erases what a reset must erase, moves the rest aside, and restarts.
    ///
    /// **Returns `Never` on success**: the restart is not a convenience. Every store here is a
    /// singleton holding its state in memory, so a running app carries on from what it read at
    /// launch and would write that back over the reset at the first save. See
    /// `AppRelaunch.discardingState`, which is also why nothing is offered to reset *without*
    /// restarting.
    ///
    /// The date is passed in rather than read, so a test names the folder it expects instead of
    /// racing the clock.
    static func perform(
        _ scope: AppDataReset.Scope,
        at date: Date = Date(),
        reason: IntentionalExitReason = .reset
    ) throws -> Never {
        if case .everything = scope {
            // An app-data reset must not leave durable owner credentials behind. Stop the
            // listener first, then erase the one app-owned Keychain item before moving the file
            // state aside. A settings-only reset deliberately keeps pairings.
            try RemoteAccessCoordinator.shared.deleteOwnerDevicesForAppReset()
            // Same reason, second store: the browser's test credentials are Keychain items, so
            // moving the app's directories aside would leave every one of them behind while
            // telling the user their state had been removed.
            try BrowserCredentialStore().deleteAll()
            // The 1Password references deliberately have *no* line here. They live in the
            // preferences domain, which `AppDataReset` snapshots into the backup and then
            // removes — so clearing them first would delete them from the recovery copy and lose
            // them outright if the reset went on to fail. The Keychain calls above are not
            // symmetric with that: keychain items are in neither the domain nor the support
            // directory, so nothing else would ever remove them.
        }

        let outcome = try AppDataReset.perform(scope, at: date)
        ThreadingLogger.agent.info(
            "Reset app data into \(outcome.backup.lastPathComponent, privacy: .public)"
        )
        AppRelaunch.discardingState(reason: reason)
    }
}
