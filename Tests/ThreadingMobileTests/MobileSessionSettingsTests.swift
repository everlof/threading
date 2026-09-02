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

    private func makeAccount(id: String, name: String) -> RemoteAccountChoiceDTO {
        RemoteAccountChoiceDTO(
            id: id,
            name: name,
            models: [],
            defaultModelID: nil
        )
    }
}
