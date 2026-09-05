import XCTest

@testable import Threading

@MainActor
final class BankedUsageResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSelectorUsesSoonestExpiringAvailableCodexCredit() {
        let credits = CodexAccountRateLimitsSnapshot.ResetCredits(
            availableCount: 3,
            credits: [
                credit(id: "later", expiresIn: 900),
                credit(id: "spent", expiresIn: 10, status: "consumed"),
                credit(id: "other", expiresIn: 5, resetType: "other"),
                credit(id: "first", expiresIn: 300),
                credit(id: "no-expiry", expiresIn: nil)
            ]
        )

        XCTAssertEqual(BankedUsageResetCreditSelector.select(from: credits)?.id, "first")
    }

    func testSelectorLetsProviderChooseWhenDetailRowsAreMissing() {
        XCTAssertNil(BankedUsageResetCreditSelector.select(from: .init(
            availableCount: 2,
            credits: nil
        )))
    }

    func testSelectorDoesNotTreatAnotherCreditTypeAsACodexReset() {
        XCTAssertNil(BankedUsageResetCreditSelector.select(from: .init(
            availableCount: 1,
            credits: [credit(id: "other", expiresIn: 60, resetType: "other")]
        )))
    }

    func testAccountAppServerEnvelopeParsesTypedReadAndConsumeResults() throws {
        let readData = Data(#"""
        {
            "id": 2,
            "result": {
                "accountId": "backend-account",
                "rateLimits": {
                    "planType": "plus",
                    "primary": {"usedPercent": 42, "windowDurationMins": 300}
                },
                "rateLimitResetCredits": {"availableCount": 1, "credits": []}
            }
        }
        """#.utf8)
        let consumeData = Data(#"{"id":3,"result":{"outcome":"alreadyRedeemed"}}"#.utf8)

        guard case .response(.integer(2), .snapshot(let snapshot), nil) =
                CodexAccountAppServerEnvelope.parse(readData) else {
            return XCTFail("Expected a typed rate-limit snapshot")
        }
        guard case .response(.integer(3), .consumed(let outcome), nil) =
                CodexAccountAppServerEnvelope.parse(consumeData) else {
            return XCTFail("Expected a typed consume outcome")
        }

        XCTAssertEqual(snapshot.accountId, "backend-account")
        XCTAssertEqual(snapshot.rateLimits.primary?.usedPercent, 42)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
        XCTAssertEqual(outcome, .alreadyRedeemed)
    }

    func testPrepareCarriesExistingContinuationCount() async throws {
        let adapter = RecordingBankedResetAdapter(usage: usage(fraction: 0.2))
        let account = codexAccount()
        let sessions: Set<SessionID> = [SessionID(), SessionID()]
        let service = BankedUsageResetService(
            adapterProvider: { _ in adapter },
            owedSessionsProvider: { _ in sessions },
            continuationReleaser: { _, _ in XCTFail("prepare must not release"); return nil },
            authoritativePublisher: { _, _ in XCTFail("prepare must not publish") },
            now: { self.now }
        )

        let offer = try await service.prepare(account: account)

        XCTAssertEqual(offer.owedContinuationCount, 2)
        XCTAssertEqual(offer.accountID, account.id)
        XCTAssertEqual(adapter.preparedOwedCount, 2)
    }

    func testConfirmedResetPublishesBeforeReleasingExistingSessions() async throws {
        let adapter = RecordingBankedResetAdapter(usage: usage(fraction: 0.2))
        let account = codexAccount()
        let sessions: Set<SessionID> = [SessionID(), SessionID()]
        var sequence: [String] = []
        var releasedSessions: Set<SessionID> = []
        var releasedAt: Date?
        let service = BankedUsageResetService(
            adapterProvider: { _ in adapter },
            owedSessionsProvider: { _ in sessions },
            continuationReleaser: { ids, date in
                sequence.append("release")
                releasedSessions = ids
                releasedAt = date
                return ids.count
            },
            authoritativePublisher: { _, _ in sequence.append("publish") },
            now: { self.now }
        )
        let offer = adapter.offer(account: account, owed: sessions.count)

        let result = try await service.redeem(
            account: account,
            offer: offer,
            idempotencyKey: "same-logical-mutation"
        )

        XCTAssertEqual(sequence, ["publish", "release"])
        XCTAssertEqual(releasedSessions, sessions)
        XCTAssertEqual(releasedAt, now.addingTimeInterval(PresetDefaults.resetPadding))
        XCTAssertEqual(result.releasedContinuationCount, 2)
        XCTAssertTrue(result.hasVerifiedHeadroom)
        XCTAssertEqual(adapter.receivedIdempotencyKey, "same-logical-mutation")
    }

    func testNothingToResetNeverReleasesContinuations() async throws {
        let adapter = RecordingBankedResetAdapter(
            outcome: .nothingToReset,
            usage: usage(fraction: 1)
        )
        let account = codexAccount()
        var released = false
        let service = BankedUsageResetService(
            adapterProvider: { _ in adapter },
            owedSessionsProvider: { _ in [SessionID()] },
            continuationReleaser: { _, _ in released = true; return 1 },
            authoritativePublisher: { _, _ in },
            now: { self.now }
        )

        let result = try await service.redeem(
            account: account,
            offer: adapter.offer(account: account, owed: 1)
        )

        XCTAssertFalse(released)
        XCTAssertEqual(result.releasedContinuationCount, 0)
        XCTAssertFalse(result.hasVerifiedHeadroom)
    }

    func testResetDoesNotReleaseWhileAnyCurrentWindowRemainsSpent() async throws {
        var blockedUsage = usage(fraction: 0.2)
        blockedUsage.modelWindows = [.init(
            id: "gpt-5",
            label: "Weekly · gpt-5",
            fraction: 1,
            resetsAt: now.addingTimeInterval(3_600),
            windowDuration: 7 * 86_400,
            scopeName: "gpt-5"
        )]
        let adapter = RecordingBankedResetAdapter(usage: blockedUsage)
        let account = codexAccount()
        var released = false
        let service = BankedUsageResetService(
            adapterProvider: { _ in adapter },
            owedSessionsProvider: { _ in [SessionID()] },
            continuationReleaser: { _, _ in released = true; return 1 },
            authoritativePublisher: { _, _ in },
            now: { self.now }
        )

        let result = try await service.redeem(
            account: account,
            offer: adapter.offer(account: account, owed: 1)
        )

        XCTAssertFalse(released)
        XCTAssertEqual(result.releasedContinuationCount, 0)
        XCTAssertFalse(result.hasVerifiedHeadroom)
    }

    func testAmbiguousConsumeRetriesOnceWithTheSameIdempotencyKey() async throws {
        let client = AmbiguousConsumeClient(snapshot: snapshot(fraction: 0.2))
        let adapter = CodexBankedUsageResetAdapter(
            clientFactory: { client },
            backendIdentityProvider: { _ in "backend-account" }
        )
        let account = codexAccount()
        let offer = BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            providerAccountID: "backend-account",
            availableCount: 1,
            selectedCreditID: "credit-one",
            selectedCreditTitle: "Soonest",
            selectedCreditExpiresAt: nil,
            letsProviderChooseCredit: false,
            eligibleWindowLabels: ["Five-hour"],
            owedContinuationCount: 0
        )

        let result = try await adapter.redeem(
            account: account,
            offer: offer,
            idempotencyKey: "stable-key"
        )

        XCTAssertEqual(result.outcome, .reset)
        XCTAssertEqual(client.idempotencyKeys, ["stable-key", "stable-key"])
        XCTAssertEqual(client.retryFlags, [false, true])
    }

    func testAccountSwitchAfterConfirmationFailsBeforeConsume() async throws {
        let client = AmbiguousConsumeClient(snapshot: snapshot(fraction: 0.2))
        let adapter = CodexBankedUsageResetAdapter(
            clientFactory: { client },
            backendIdentityProvider: { _ in "different-account" }
        )
        let account = codexAccount()
        let offer = BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            providerAccountID: "reviewed-account",
            availableCount: 1,
            selectedCreditID: "credit-one",
            selectedCreditTitle: "Soonest",
            selectedCreditExpiresAt: nil,
            letsProviderChooseCredit: false,
            eligibleWindowLabels: ["Five-hour"],
            owedContinuationCount: 0
        )

        do {
            _ = try await adapter.redeem(
                account: account,
                offer: offer,
                idempotencyKey: "must-not-send"
            )
            XCTFail("A changed provider account must fail before consume")
        } catch let error as BankedUsageResetError {
            XCTAssertEqual(error, .accountMismatch)
        }
        XCTAssertTrue(client.idempotencyKeys.isEmpty)
    }

    func testRemoteOfferFingerprintBindsRawIdentitiesWithoutPublishingThem() throws {
        let account = codexAccount()
        let first = BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            providerAccountID: "provider-account-secret",
            availableCount: 1,
            selectedCreditID: "credit-secret",
            selectedCreditTitle: "Soonest",
            selectedCreditExpiresAt: nil,
            letsProviderChooseCredit: false,
            eligibleWindowLabels: ["Five-hour"],
            owedContinuationCount: 0
        )
        let changed = BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            providerAccountID: "different-provider-account",
            availableCount: first.availableCount,
            selectedCreditID: first.selectedCreditID,
            selectedCreditTitle: first.selectedCreditTitle,
            selectedCreditExpiresAt: first.selectedCreditExpiresAt,
            letsProviderChooseCredit: first.letsProviderChooseCredit,
            eligibleWindowLabels: first.eligibleWindowLabels,
            owedContinuationCount: first.owedContinuationCount
        )

        let wire = RemoteUsageBridge.resetOffer(first, seriesID: "series")
        let changedWire = RemoteUsageBridge.resetOffer(changed, seriesID: "series")
        let encoded = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)

        XCTAssertEqual(wire.offerFingerprint.count, 64)
        XCTAssertNotEqual(wire.offerFingerprint, changedWire.offerFingerprint)
        XCTAssertFalse(encoded.contains("provider-account-secret"))
        XCTAssertFalse(encoded.contains("credit-secret"))
    }

    private func codexAccount() -> AgentAccount {
        AgentAccount(
            provider: .codex,
            handle: AccountHandle(storedName: "reset-test"),
            configPath: "/tmp/reset-test",
            displayName: "Reset Test"
        )
    }

    private func usage(fraction: Double) -> AccountUsage {
        AccountUsage(
            windows: [.init(
                id: "5h",
                label: "Five-hour",
                fraction: fraction,
                resetsAt: now.addingTimeInterval(3_600),
                windowDuration: 5 * 3_600
            )],
            planLabel: "Plus",
            observedAt: now,
            source: .api
        )
    }

    private func snapshot(fraction: Double) -> CodexAccountRateLimitsSnapshot {
        .init(
            accountId: "backend-account",
            rateLimits: .init(
                limitId: "codex",
                limitName: nil,
                planType: "plus",
                primary: .init(
                    usedPercent: fraction * 100,
                    windowDurationMins: 300,
                    resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970
                ),
                secondary: nil,
                credits: nil
            ),
            rateLimitsByLimitId: nil,
            rateLimitResetCredits: .init(availableCount: 0, credits: [])
        )
    }

    private func credit(
        id: String,
        expiresIn: TimeInterval?,
        status: String = "available",
        resetType: String = "codexRateLimits"
    ) -> CodexAccountRateLimitsSnapshot.ResetCredit {
        .init(
            id: id,
            title: id,
            description: nil,
            grantedAt: now.timeIntervalSince1970,
            expiresAt: expiresIn.map { now.addingTimeInterval($0).timeIntervalSince1970 },
            resetType: resetType,
            status: status
        )
    }
}

@MainActor
private final class RecordingBankedResetAdapter: BankedUsageResetAdapter {
    let outcome: BankedUsageResetOutcome
    let usage: AccountUsage
    var preparedOwedCount: Int?
    var receivedIdempotencyKey: String?

    init(outcome: BankedUsageResetOutcome = .reset, usage: AccountUsage) {
        self.outcome = outcome
        self.usage = usage
    }

    func offer(account: AgentAccount, owed: Int) -> BankedUsageResetOffer {
        BankedUsageResetOffer(
            accountID: account.id,
            accountName: account.displayName,
            availableCount: 2,
            selectedCreditID: "credit-one",
            selectedCreditTitle: "Soonest",
            selectedCreditExpiresAt: nil,
            letsProviderChooseCredit: false,
            eligibleWindowLabels: ["Five-hour", "Weekly"],
            owedContinuationCount: owed
        )
    }

    func prepare(account: AgentAccount, owedContinuationCount: Int) async throws
        -> BankedUsageResetOffer {
        preparedOwedCount = owedContinuationCount
        return offer(account: account, owed: owedContinuationCount)
    }

    func redeem(
        account _: AgentAccount,
        offer _: BankedUsageResetOffer,
        idempotencyKey: String
    ) async throws -> BankedUsageResetAdapterResult {
        receivedIdempotencyKey = idempotencyKey
        return BankedUsageResetAdapterResult(
            outcome: outcome,
            authoritativeUsage: usage
        )
    }
}

@MainActor
private final class AmbiguousConsumeClient: CodexAccountAppServerServing {
    let snapshot: CodexAccountRateLimitsSnapshot
    var idempotencyKeys: [String] = []
    var retryFlags: [Bool] = []

    init(snapshot: CodexAccountRateLimitsSnapshot) {
        self.snapshot = snapshot
    }

    func read(
        account _: AgentAccount,
        expectedBackendAccountID _: String
    ) async throws -> CodexAccountRateLimitsSnapshot {
        snapshot
    }

    func consume(
        account _: AgentAccount,
        expectedBackendAccountID _: String,
        offer _: BankedUsageResetOffer,
        idempotencyKey: String,
        isIdempotentRetry: Bool
    ) async throws -> CodexAccountConsumeResult {
        idempotencyKeys.append(idempotencyKey)
        retryFlags.append(isIdempotentRetry)
        if !isIdempotentRetry {
            throw CodexAccountAppServerError.transport(
                "Connection closed after send.",
                consumeMayHaveBeenSent: true
            )
        }
        return CodexAccountConsumeResult(outcome: .reset, snapshot: snapshot)
    }
}
