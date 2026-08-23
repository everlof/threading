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

        XCTAssertTrue(choices.contains {
            $0.policy.action == RemoteLimitRecoveryPolicyDTO.resumeOnBestAccount
        })
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
            choices.filter {
                $0.policy.action == RemoteLimitRecoveryPolicyDTO.resumeVia
            }.map(\.policy.accountID),
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
            limitRecovery: .init(
                action: RemoteLimitRecoveryPolicyDTO.resumeVia,
                accountID: "work"
            )
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
        limitRecovery: RemoteLimitRecoveryPolicyDTO? = .init(
            action: RemoteLimitRecoveryPolicyDTO.waitForReset
        )
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
