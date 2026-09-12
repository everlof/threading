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
    /// `AppRelaunch.PreparedRelaunch.commit`, which is also why nothing is offered to reset
    /// *without* restarting.
    ///
    /// The date is passed in rather than read, so a test names the folder it expects instead of
    /// racing the clock.
    static func perform(
        _ scope: AppDataReset.Scope,
        at date: Date = Date(),
        reason: IntentionalExitReason = .reset,
        prepareRelaunch: () throws -> AppRelaunch.PreparedRelaunch = {
            try AppRelaunch.prepare()
        },
        reset: (AppDataReset.Scope, Date) throws -> AppDataReset.Outcome = { scope, date in
            try AppDataReset.perform(scope, at: date)
        }
    ) throws -> Never {
        let scopeCode: String
        switch scope {
        case .settings: scopeCode = "settings"
        case .everything: scopeCode = "everything"
        }
        ThreadingLogger.app.notice(
            "App data reset started scope=\(scopeCode, privacy: .public)"
        )
        // Prove that the helper can start before deleting credentials, closing the database or
        // moving anything. It waits behind a pipe until `commit`; an error below releases this
        // owner and cancels the helper without ever asking it to reopen the app.
        let relaunch = try prepareRelaunch()

        if case .everything = scope {
            // An app-data reset must not leave durable owner credentials behind. Stop the
            // listener first, then erase the one app-owned Keychain item before moving the file
            // state aside. A settings-only reset deliberately keeps pairings.
            try RemoteAccessCoordinator.shared.deleteOwnerDevicesForAppReset()
            // Same reason, second store: the browser's test credentials are Keychain items, so
            // moving the app's directories aside would leave every one of them behind while
            // telling the user their state had been removed.
            try BrowserCredentialStore().deleteAll()
            // Trigger-source bearers are app-owned too. The source records themselves live
            // inside Application Support and are moved aside below; their Keychain secrets do
            // not, so Reset Everything must erase them explicitly.
            try TriggerSourceCredentialStore.deleteAll()
            // The 1Password references deliberately have *no* line here. They live in the
            // preferences domain, which `AppDataReset` snapshots into the backup and then
            // removes — so clearing them first would delete them from the recovery copy and lose
            // them outright if the reset went on to fail. The Keychain calls above are not
            // symmetric with that: keychain items are in neither the domain nor the support
            // directory, so nothing else would ever remove them.

            // The SQLite store and its WAL/SHM files are inside the directory about to move.
            // Close the cached connection first: moving an open vnode works at the filesystem
            // layer but violates SQLite's lifetime contract and can leave its final checkpoint
            // targeting paths that no longer name the database. A failed move may reopen later.
            StateManager.shared.closeDatabase()
        }

        let outcome = try reset(scope, date)
        ThreadingLogger.app.notice(
            "App data reset prepared scope=\(scopeCode, privacy: .public) backup=\(outcome.backup.lastPathComponent, privacy: .private(mask: .hash)) preferences=\(outcome.tookPreferences, privacy: .public) support=\(outcome.tookSupportDirectory, privacy: .public)"
        )
        try relaunch.commit(reason: reason)
    }
}
