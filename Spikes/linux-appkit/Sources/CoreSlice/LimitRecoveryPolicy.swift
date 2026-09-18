import Foundation

// MARK: - Limit Recovery Policy

/// What Threading does when a live terminal session is refused over its account's usage limit —
/// the moment `ObservedUsageLimit` reports, decided by the user in advance.
///
/// The default is the quiet one. Recovery types into the user's session and spends their quota
/// with nobody watching, so it is opted into, never discovered: `flagOnly` still reads the
/// refusal (that is what un-strands the spinner — see `limit-recovery.md`) and then leaves the
/// decision where it is today, in front of the user.
///
/// Chosen at three scopes rather than one — a chat, its checkout, the app — because the opt-in
/// is the narrow statement. See `LimitRecoveryResolution`.
///
/// `Codable` because a chat and a project each store their own answer; the raw values are
/// therefore persisted names and cannot be renamed without leaving old records unreadable.
enum LimitRecoveryPolicy: RawRepresentable, Codable, Hashable, Sendable {

    /// Detect and mark, touch nothing. The session flags as stopped on the user; the CLI's own
    /// chooser stays exactly as the CLI drew it.
    case flagOnly

    /// Answer the CLI's chooser with its stop-and-wait option, then schedule "continue" for the
    /// binding window's reset through the scheduled-messages machinery — the routine the user
    /// described doing by hand, automated whole and journaled at every step.
    case waitForReset

    /// Move the conversation to whichever of this session's other logins has the most room, and
    /// carry on there now rather than waiting for the window.
    ///
    /// "Most room" is `LimitEscapeRanking`'s answer, unchanged and unduplicated: the ranking was
    /// written for the interactive strip and is the same arithmetic either way. What the policy
    /// adds is the press — and, because nobody is watching it, the budget under
    /// `LimitRecoveryBudget`.
    case resumeOnBestAccount

    /// The same move, to one login the user named rather than to whichever ranks best.
    ///
    /// **A chat-scope answer only.** A login belongs to exactly one runtime and a chat runs
    /// exactly one, so this is well defined there; a checkout hosts chats of several runtimes and
    /// Settings answers for all of them, which is why those two scopes offer `resumeOnBestAccount`
    /// instead — runtime-neutral by construction. A record that names a login the session cannot
    /// reach degrades to `flagOnly` and says why, the way every other failed precondition here
    /// does.
    case resumeVia(AccountID)

    static let `default` = LimitRecoveryPolicy.flagOnly

    /// What the user has chosen, read where the decision is made.
    @MainActor
    static var current: LimitRecoveryPolicy { LimitRecoverySettings.policy }

    /// The answers a scope that cannot name a runtime may offer — Settings and a checkout.
    ///
    /// This is what `CaseIterable` used to be, and it is a list rather than a derivation because
    /// `resumeVia` carries a login: there is no set of "all cases" to enumerate, and the one that
    /// is missing here is missing for a stated reason rather than by oversight.
    static let runtimeNeutralChoices: [LimitRecoveryPolicy] = [
        .flagOnly,
        .waitForReset,
        .resumeOnBestAccount
    ]

    // MARK: - Storage Names

    /// The persisted names. `resumeVia` spells its login into the same string rather than
    /// earning a second column, so a record written by a build that has never heard of it reads
    /// as "chose nothing" — which is what every reader here already does with a name it does not
    /// recognise.
    private enum Name {
        static let flagOnly = "flagOnly"
        static let waitForReset = "waitForReset"
        static let resumeOnBestAccount = "resumeOnBestAccount"
        static let resumeViaPrefix = "resumeVia:"
    }

    init?(rawValue: String) {
        switch rawValue {
        case Name.flagOnly:
            self = .flagOnly
        case Name.waitForReset:
            self = .waitForReset
        case Name.resumeOnBestAccount:
            self = .resumeOnBestAccount
        default:
            // `AccountID`'s own raw value carries a colon, so the split is bounded to the first
            // one and the rest is handed to the identifier to parse or refuse.
            guard rawValue.hasPrefix(Name.resumeViaPrefix),
                  let accountID = AccountID(
                    rawValue: String(rawValue.dropFirst(Name.resumeViaPrefix.count))
                  )
            else { return nil }
            self = .resumeVia(accountID)
        }
    }

    var rawValue: String {
        switch self {
        case .flagOnly:
            return Name.flagOnly
        case .waitForReset:
            return Name.waitForReset
        case .resumeOnBestAccount:
            return Name.resumeOnBestAccount
        case .resumeVia(let accountID):
            return Name.resumeViaPrefix + accountID.rawValue
        }
    }

    // MARK: - Coding

    /// Written by hand, and the shape is the point: one string, exactly what
    /// `PreferenceStore` and both records already hold. Swift synthesises `Codable` for an enum
    /// with an associated value — a nested object keyed by case name — which would silently
    /// change the stored form the moment `resumeVia` was added and leave every existing
    /// `"waitForReset"` unreadable.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = LimitRecoveryPolicy(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown limit recovery policy"
            ))
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - What It Does

    /// The login this policy names, where it names one.
    var pinnedAccountID: AccountID? {
        guard case .resumeVia(let accountID) = self else { return nil }
        return accountID
    }

    /// Whether carrying this out moves the conversation to another login — the two policies that
    /// stop the agent, spend a second window and need `LimitRecoveryBudget` under them.
    var movesToAnotherAccount: Bool {
        switch self {
        case .flagOnly, .waitForReset:
            return false
        case .resumeOnBestAccount, .resumeVia:
            return true
        }
    }

    var title: String {
        switch self {
        case .flagOnly:
            return L10n.string("Flag the session and wait for you")
        case .waitForReset:
            return L10n.string("Answer the chooser and continue at reset")
        case .resumeOnBestAccount:
            return L10n.string("Move to the login with the most room and carry on")
        case .resumeVia(let accountID):
            // The stored handle rather than the account's display name: this is reached where a
            // login may no longer exist to ask, and the surfaces that *can* ask — the chat menu,
            // the strip — name it through `AccountName.display` beside their own account list.
            return L10n.format("Move to %@ and carry on", accountID.handle.name)
        }
    }

    var explanation: String {
        switch self {
        case .flagOnly:
            return L10n.string(
                "The refusal is read and the session is marked as stopped; nothing is typed and nothing is scheduled."
            )
        case .waitForReset:
            return L10n.string(
                "Threading chooses “Stop and wait”, schedules “continue” for the window's reset, and the session resumes on its own."
            )
        case .resumeOnBestAccount, .resumeVia:
            return L10n.string(
                "Threading stops the agent, moves the conversation to a login with room, and queues “continue” there. A login whose fresh reading has no room is refused rather than used."
            )
        }
    }
}

// MARK: - Storage

/// Stored through `PreferenceStore` for the reason the Usage Windows page's own settings are:
/// a hosted test run must not flip what a background process does with the developer's real
/// sessions and quota.
@MainActor
enum LimitRecoverySettings {

    /// Not private, so a test can seed the app scope by writing here rather than through
    /// `policy` below.
    ///
    /// The setter posts `AppSettingsDidChange` into whatever observers the test host has live —
    /// a sidebar controller from an earlier case among them — which is the hazard
    /// `SidebarTreeBuilderTests` already writes `UserDefaults` directly to avoid. A test that
    /// only needs the *value* seeded should not be broadcasting a settings change to the whole
    /// application to get it.
    static let storageKey = "limitRecoveryPolicy"

    static var policy: LimitRecoveryPolicy {
        get {
            PreferenceStore.shared.string(forKey: storageKey)
                .flatMap(LimitRecoveryPolicy.init(rawValue:))
                ?? .default
        }
        set {
            guard newValue != policy else { return }
            PreferenceStore.shared.set(newValue.rawValue, forKey: storageKey)
            NotificationCenter.default.post(AppSettingsDidChange())
        }
    }
}
