import Foundation

// MARK: - Custom Limit Park Policy

/// Whether one session is parked by a limit of the user's, resolved from the stores.
///
/// The decision itself is `CustomLimitBounds.park`, which is pure. This is the thin layer that
/// finds a session's account and asks — kept apart so the seams that need the answer (the outbox's
/// turn boundary, the row's mark, the composer's strip) all ask it the same way, and so the pure
/// half stays testable without a preferences suite.
@MainActor
enum CustomLimitParkPolicy {

    /// The rule parking this session, or nil.
    static func hold(sessionID: SessionID, at now: Date = Date()) -> CustomLimitHold {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ) else { return .clear }
        return hold(account: account, at: now)
    }

    static func hold(account: AgentAccount, at now: Date = Date()) -> CustomLimitHold {
        let rules = CustomLimitSettings.shared.rules(for: account.id)
        return CustomLimitBounds.park(
            on: AccountUsageService.shared.usage(for: account),
            in: rules,
            overrides: CustomLimitOverrideStore.shared.granted(for: account.id, at: now),
            history: UsageAlertCenter.history(for: account, rules: rules),
            at: now
        )
    }

    static func isParked(sessionID: SessionID, at now: Date = Date()) -> Bool {
        hold(sessionID: sessionID, at: now).isHolding
    }

    /// Records the user's Continue Anyway for whichever rule is parking this session, and tells
    /// the surfaces to re-read.
    ///
    /// Scoped to the rule that is actually holding rather than to the account: an account with two
    /// parked rules is answered one line at a time, which is what "the override applies to the
    /// current window instance" means when there is more than one instance in play.
    static func continueAnyway(sessionID: SessionID, at now: Date = Date()) {
        guard let session = ProjectStore.shared.session(withID: sessionID),
              let account = AgentAccountDiscovery.account(
                  for: session.kind,
                  handle: session.accountHandle
              ),
              let rule = hold(account: account, at: now).rule else { return }

        let window = AccountUsageService.shared.usage(for: account)?
            .allWindows.first { $0.id == rule.windowID }
        CustomLimitOverrideStore.shared.grant(
            rule: rule,
            window: window,
            for: account.id,
            at: now
        )
        NotificationCenter.default.post(CustomLimitsDidChange())
    }
}
