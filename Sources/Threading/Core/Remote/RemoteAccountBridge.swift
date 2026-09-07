import AppKit
import ThreadingRemoteKit

// MARK: - Remote Account Bridge

/// Turns a session's login into the identity a remote client's row draws, the way
/// `RemoteThemeBridge` turns the current app theme into a palette a client can paint.
///
/// The resolution lives here rather than on the phone because every input is on this Mac: the
/// account directories `AgentAccountDiscovery` scans, the login address `AccountName` reads, the
/// emoji the user chose, and the hash `AccountBadge` hues its disc with. A client that tried to
/// derive any of that would be guessing from an agent kind and a handle name.
@MainActor
enum RemoteAccountBridge {

    // MARK: - Public Methods

    /// The account identity for a session row, or nil when the row has nothing extra to say.
    ///
    /// Nil in exactly the cases the Mac sidebar draws no chip: a runtime without account routing,
    /// and the CLI's **default** login, whose agent mark already says everything the row knows.
    /// That is also what keeps this cheap on the projection path — the standard handle, which is
    /// most rows, answers before any directory is scanned. `SessionRowView` takes the same
    /// shortcut for the same reason.
    static func identity(for session: AgentSession) -> RemoteSessionAccountDTO? {
        guard session.kind.supportsAccounts else { return nil }
        guard session.accountHandle != .standard || AccountPresentation.showsStandardBadge(provider: session.kind) else { return nil }
        guard let account = AgentAccountDiscovery.account(
            for: session.kind,
            handle: session.accountHandle
        ) else { return nil }
        let p = account.presentation(in: .sidebar)
        guard !account.isDefault || p.style.showDefaultBadge == true else { return nil }

        return identity(for: account)
    }

    /// The wire form of one account's chip and name.
    ///
    /// Separate from the session lookup so a test can state an account and read the chip without a
    /// home directory to discover it in.
    static func identity(
        for account: AgentAccount, surface: AccountAppearanceSurface = .sidebar
    ) -> RemoteSessionAccountDTO {
        let value = account.presentation(in: surface)
        return RemoteSessionAccountDTO(
            name: value.name, glyph: value.glyph, isEmoji: value.isEmoji,
            hue: value.isEmoji ? nil : Double(AccountBadge.hue(for: account)),
            backgroundHex: value.isEmoji && AccountAppearance.normalizedHex(value.style.backgroundHex) == nil ? nil : value.background.hexString,
            foregroundHex: value.foreground.hexString, imageID: value.imageID,
            badgeHidden: !value.showsBadge(isDefault: account.isDefault, surface: surface),
            displayLabel: value.visibleName, email: value.email
        )
    }

    /// The login's own address, for a client that names the person and the account separately.
    ///
    /// Both stores, in the order `AccountName` reads them: what the CLI wrote down, then what it
    /// answered when asked. Nil is ordinary — the standard Claude login records only a hashed id
    /// until the probe has run — and a client is expected to show the name alone in that case.
    ///
    /// Free on the catalogue path, which is the only caller: `AccountName.names(for:)` resolves
    /// the same two caches for the same accounts a couple of lines earlier, to derive the names.
    /// This adds a dictionary read, not a directory scan.
    static func email(for account: AgentAccount) -> String? {
        account.presentation().email
    }

    static func appearances(for account: AgentAccount) -> [String: RemoteSessionAccountDTO] {
        Dictionary(uniqueKeysWithValues: AccountAppearanceSurface.allCases.map {
            ($0.rawValue, identity(for: account, surface: $0))
        })
    }

    static func images(for account: AgentAccount) -> [String: Data] {
        var images: [String: Data] = [:]
        for surface in AccountAppearanceSurface.allCases {
            if let id = account.presentation(in: surface).imageID,
               let png = AccountImageStore.png(id) { images[id] = png }
        }
        return images
    }

    // MARK: - Usage

    /// The account's limit windows as the phone's disc rings them: the account's own first, then
    /// the ones scoped to a model, each scoped one naming the ids among `modelChoices` it meters.
    ///
    /// The scope is resolved here because `ModelName.scope` is the rule and it reads a families
    /// table this Mac owns; a phone deciding from two strings whether `Fable` meters
    /// `claude-fable-5[1m]` would be a second copy of that table, one release behind. What
    /// crosses the wire is the answer per model choice, which the phone matches against the
    /// chat's model with a lookup. A scoped window that meters none of the choices still travels,
    /// with an empty list: the phone never rings it, and the wire stays a faithful copy of the
    /// reading rather than a curated one.
    static func usageWindows(
        for usage: AccountUsage,
        modelChoices: [String]
    ) -> [RemoteAccountUsageWindowDTO] {
        let accountWide = usage.windows.map { dto(for: $0, metersModelIDs: nil) }
        let scoped = usage.modelWindows.map { window in
            dto(
                for: window,
                metersModelIDs: modelChoices.filter { ModelName.scope(window.id, meters: $0) }
            )
        }
        return accountWide + scoped
    }

    private static func dto(
        for window: AccountUsage.Window,
        metersModelIDs: [String]?
    ) -> RemoteAccountUsageWindowDTO {
        RemoteAccountUsageWindowDTO(
            id: window.id,
            name: window.compactName,
            fraction: window.fraction,
            resetsAt: window.resetsAt?.timeIntervalSince1970,
            windowDuration: window.windowDuration,
            metersModelIDs: metersModelIDs
        )
    }
}
