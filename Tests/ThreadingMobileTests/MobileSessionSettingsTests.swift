import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

final class MobileSessionSettingsTests: XCTestCase {
    func testMoveDestinationsExcludeTheAccountAlreadyRunningTheChat() {
        let session = makeSession(accountID: "personal")

        XCTAssertEqual(
            MobileSessionSettingsPresentation.moveDestinations(
                for: session,
                in: makeAgent(accounts: [
                    makeAccount(id: "personal", name: "David"),
                    makeAccount(id: "work", name: "Work"),
                ])
            ).map(\.id),
            ["work"]
        )
    }

    func testAccountRuntimeOffersBestLoginEvenWithOneConfiguredAccount() {
        let choices = MobileSessionSettingsPresentation.limitRecoveryChoices(
            for: makeSession(accountID: "personal"),
            in: makeAgent(accounts: [makeAccount(id: "personal", name: "David")])
        )

        XCTAssertTrue(choices.contains { $0.policy == .resumeOnBestAccount })
    }

    func testPinnedRecoveryOffersOnlyOtherAccounts() {
        let choices = MobileSessionSettingsPresentation.limitRecoveryChoices(
            for: makeSession(accountID: "personal"),
            in: makeAgent(accounts: [
                makeAccount(id: "personal", name: "David"),
                makeAccount(id: "work", name: "Work"),
            ])
        )

        XCTAssertEqual(
            choices.compactMap {
                guard case .resumeVia(let accountID) = $0.policy else { return nil }
                return accountID
            },
            ["work"]
        )
    }

    func testOlderHostWithoutRecoveryFieldShowsNoRecoveryChoices() {
        let session = makeSession(accountID: nil, limitRecovery: nil)

        XCTAssertTrue(MobileSessionSettingsPresentation.limitRecoveryChoices(
            for: session,
            in: makeAgent(accounts: nil)
        ).isEmpty)
        XCTAssertNil(MobileSessionSettingsPresentation.limitRecoveryTitle(
            for: session,
            in: makeAgent(accounts: nil)
        ))
    }

    func testPinnedRecoveryUsesTheAccountsDisplayName() {
        let session = makeSession(
            accountID: "personal",
            limitRecovery: .resumeVia(accountID: "work")
        )

        XCTAssertEqual(
            MobileSessionSettingsPresentation.limitRecoveryTitle(
                for: session,
                in: makeAgent(accounts: [makeAccount(id: "work", name: "Work SSO")])
            ),
            MobileL10n.string("Continue as %@", "Work SSO")
        )
    }

    private func makeSession(
        accountID: String?,
        limitRecovery: RemoteLimitRecoveryPolicyDTO? = .waitForReset
    ) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: "session",
            title: "Remote controls",
            agentKind: "codex",
            surface: .conversation,
            state: .idle,
            projectName: "Threading",
            accountID: accountID,
            limitRecovery: limitRecovery
        )
    }

    // MARK: - Continuation

    func testContinuationUsageMatchesRuntimeAndAccountInsteadOfDisplayName() {
        let destination = RemoteContinuationDestinationDTO(
            agentID: "claude", agentName: "Claude Code", accountID: "default", accountName: "Work"
        )
        let expected = makeAccount(id: "default", name: "Renamed Work", usage: "5h 84%")
        let agents = [
            makeAgent(accounts: [makeAccount(id: "default", name: "Work", usage: "5h 12%")]),
            RemoteAgentChoiceDTO(
                id: "claude", name: "Claude Code", accounts: [expected], models: [],
                defaultModelID: nil, supportsConversation: true
            )
        ]
        XCTAssertEqual(
            MobileSessionSettingsPresentation.continuationAccounts(for: [destination], in: agents)[destination.id],
            expected
        )
        XCTAssertTrue(MobileSessionSettingsPresentation.continuationAccounts(
            for: [.init(agentID: "opencode", agentName: "OpenCode")], in: agents
        ).isEmpty)
        XCTAssertTrue(MobileSessionSettingsPresentation.continuationAccounts(for: [destination], in: []).isEmpty)
    }

    func testRecoveryChoicesCarryUsageWithoutChangingTheirIdentityOrTitle() {
        let choices = MobileSessionSettingsPresentation.limitRecoveryChoices(
            for: makeSession(accountID: "personal"),
            in: makeAgent(accounts: [makeAccount(id: "work", name: "Work", usage: "5h 84% · 7d 92%")])
        )
        let pinned = choices.first { $0.policy == .resumeVia(accountID: "work") }
        XCTAssertEqual(pinned?.title, MobileL10n.string("Continue as %@", "Work"))
        XCTAssertEqual(pinned?.usage, "5h 84% · 7d 92%")
        XCTAssertTrue(choices.filter { $0.policy != .resumeVia(accountID: "work") }.allSatisfy { $0.usage == nil })
    }

    func testContinuationUsageJoinAtOneThousandAccountsPreservesEveryDestination() {
        let accounts = (0..<1_000).map { index in
            makeAccount(id: "account-\(index)", name: "Work", usage: "5h \(index % 100)%")
        }
        let destinations = accounts.reversed().map {
            RemoteContinuationDestinationDTO(agentID: "codex", agentName: "Codex", accountID: $0.id)
        }
        let joined = MobileSessionSettingsPresentation.continuationAccounts(
            for: destinations, in: [makeAgent(accounts: accounts)]
        )
        XCTAssertEqual(joined.count, accounts.count)
        for destination in destinations {
            XCTAssertEqual(joined[destination.id]?.id, destination.accountID)
        }
    }

    func testUnknownUsageDoesNotBecomeZeroCapacity() {
        XCTAssertEqual(
            MobileSessionSettingsPresentation.accountUsage(makeAccount(id: "work", name: "Work"), model: nil),
            MobileL10n.string("Loading usage…")
        )
    }

    /// The Mac names a login only where there is a choice between them, and the list is what
    /// says so: one row for a runtime reads as just that runtime, however it got there.
    func testContinuationNamesALoginOnlyWhereTheRuntimeOffersMoreThanOne() {
        let destinations = [
            RemoteContinuationDestinationDTO(
                agentID: "claude",
                agentName: "Claude Code",
                accountID: "default",
                accountName: "David"
            ),
            RemoteContinuationDestinationDTO(
                agentID: "codex",
                agentName: "Codex",
                accountID: "personal",
                accountName: "David",
                emoji: "🧑‍💻"
            ),
            RemoteContinuationDestinationDTO(
                agentID: "codex",
                agentName: "Codex",
                accountID: "work",
                accountName: "Work"
            ),
        ]

        XCTAssertEqual(
            destinations.map {
                MobileSessionSettingsPresentation.continuationTitle(for: $0, in: destinations)
            },
            ["Claude Code", "Codex · 🧑‍💻  David", "Codex · Work"]
        )
    }

    /// A runtime that routes no logins sends none, and must not be drawn as though it had one.
    func testContinuationToARuntimeWithoutLoginsNamesOnlyTheRuntime() {
        let destination = RemoteContinuationDestinationDTO(
            agentID: "opencode",
            agentName: "OpenCode"
        )

        XCTAssertEqual(
            MobileSessionSettingsPresentation.continuationTitle(
                for: destination,
                in: [destination]
            ),
            "OpenCode"
        )
    }

    /// Two logins of two runtimes are four distinct rows; a `ForEach` over colliding ids would
    /// draw one of each.
    func testContinuationDestinationsAreDistinctPerRuntimeAndLogin() {
        let destinations = [
            RemoteContinuationDestinationDTO(
                agentID: "claude",
                agentName: "Claude Code",
                accountID: "default",
                accountName: "David"
            ),
            RemoteContinuationDestinationDTO(
                agentID: "claude",
                agentName: "Claude Code",
                accountID: "work",
                accountName: "Work"
            ),
            RemoteContinuationDestinationDTO(
                agentID: "codex",
                agentName: "Codex",
                accountID: "default",
                accountName: "David"
            ),
            RemoteContinuationDestinationDTO(agentID: "opencode", agentName: "OpenCode"),
        ]

        XCTAssertEqual(Set(destinations.map(\.id)).count, destinations.count)
    }

    private func makeAgent(accounts: [RemoteAccountChoiceDTO]?) -> RemoteAgentChoiceDTO {
        RemoteAgentChoiceDTO(
            id: "codex",
            name: "Codex",
            accounts: accounts,
            models: [],
            defaultModelID: nil,
            supportsConversation: true
        )
    }

    private func makeAccount(id: String, name: String, usage: String? = nil) -> RemoteAccountChoiceDTO {
        RemoteAccountChoiceDTO(
            id: id,
            name: name,
            usageSummary: usage,
            models: [],
            defaultModelID: nil
        )
    }
}
