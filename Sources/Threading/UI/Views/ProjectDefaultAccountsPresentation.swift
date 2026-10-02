import Foundation

/// How a project's ordered logins are put into words: the editor's state lines, the composer's
/// provenance, and the receipt a send that moved logins leaves behind.
@MainActor
enum ProjectDefaultAccountsPresentation {

    // MARK: - Public Methods

    /// One short line for a listed login's row: whether a new chat could start on it now.
    static func stateLine(_ state: ProjectAccountOrder.State, at now: Date = Date()) -> String {
        switch state {
        case .usable:
            return L10n.string("Has room")
        case .unverified:
            return L10n.string("Usage unknown")
        case .spent(let until, .provider):
            guard let until else { return L10n.string("Out of usage") }
            return L10n.format("Out until %@", UsageFormat.absolute(until, from: now))
        case .spent(let until, .ownLimit):
            guard let until else { return L10n.string("At your limit") }
            return L10n.format("At your limit until %@", UsageFormat.absolute(until, from: now))
        case .unavailable(.disabled):
            return L10n.string("Switched off")
        case .unavailable(.missing), .unavailable(.enabled):
            return L10n.string("Login not found")
        }
    }

    /// The visible name of a listed login, or its handle when it is no longer discovered.
    static func name(of accountID: AccountID) -> String {
        guard let account = AgentAccountDiscovery.allAccounts(for: accountID.provider)
            .first(where: { $0.handle == accountID.handle }) else {
            return accountID.handle.name
        }
        return account.presentation(in: .chooser).visibleName
    }

    /// The receipt a send leaves when it started on the next listed login: which one, and why
    /// the one the draft showed was passed over.
    static func receipt(
        for substitution: ProjectDefaultAccounts.Substitution,
        at now: Date = Date()
    ) -> ToastRequest {
        let from = name(of: substitution.from)
        let reason: String
        switch (substitution.wasOwnLimit, substitution.fromResetsAt) {
        case (false, let until?):
            reason = L10n.format("%@ is out until %@.", from, UsageFormat.absolute(until, from: now))
        case (false, nil):
            reason = L10n.format("%@ is out of usage.", from)
        case (true, let until?):
            reason = L10n.format(
                "%@ is at your limit until %@.",
                from,
                UsageFormat.absolute(until, from: now)
            )
        case (true, nil):
            reason = L10n.format("%@ is at your limit.", from)
        }
        return ToastRequest(
            message: L10n.format("Started on %@", name(of: substitution.to)),
            detail: reason + " " + L10n.string("It is next in this project's default accounts."),
            identifier: "composer.toast.project-default-account"
        )
    }

    /// The composer's provenance for a login the list chose, for its tooltip: "Project default",
    /// plus the logins passed over to reach it.
    static func provenance(
        _ resolution: ProjectAccountOrder.Resolution?,
        at now: Date = Date()
    ) -> String? {
        guard let resolution, resolution.chosen != nil else { return nil }
        let skipped = resolution.skipped.map { entry in
            "\(name(of: entry.accountID)): \(stateLine(entry.state, at: now))"
        }
        if resolution.isEverythingSpent {
            return L10n.string("Project default · every listed account is out; this one returns first")
        }
        guard !skipped.isEmpty else { return L10n.string("Project default") }
        return L10n.format("Project default · skipped %@", skipped.joined(separator: ", "))
    }
}
