@testable import ThreadingMobile
import ThreadingRemoteKit
import XCTest

@MainActor
final class MobileNewSessionDefaultsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MobileNewSessionDefaultsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSuccessfulChoiceReloadsAndIsIsolatedByHostAgentAndAccount() {
        let store = MobileNewSessionDefaultsStore(defaults: defaults)
        let primary = identity(host: "mac-a", agent: "codex", account: "default")
        let otherHost = identity(host: "mac-b", agent: "codex", account: "default")
        let otherAgent = identity(host: "mac-a", agent: "claude", account: "default")
        let otherAccount = identity(host: "mac-a", agent: "codex", account: "work")
        let choice = MobileNewSessionRunChoice(modelID: "gpt-sol", reasoningID: "xhigh")

        XCTAssertTrue(store.remember(choice, for: primary))
        XCTAssertNil(store.choice(for: otherHost))
        XCTAssertNil(store.choice(for: otherAgent))
        XCTAssertNil(store.choice(for: otherAccount))

        let reloaded = MobileNewSessionDefaultsStore(defaults: defaults)
        XCTAssertEqual(reloaded.choice(for: primary), choice)
    }

    func testRecordsAreBoundedToTheMostRecentIdentities() {
        let store = MobileNewSessionDefaultsStore(defaults: defaults)
        for index in 0 ... MobileNewSessionDefaultsStore.maximumRecordCount {
            XCTAssertTrue(store.remember(
                MobileNewSessionRunChoice(modelID: "model-\(index)", reasoningID: "high"),
                for: identity(host: "mac", agent: "codex", account: "account-\(index)")
            ))
        }

        XCTAssertNil(store.choice(for: identity(host: "mac", agent: "codex", account: "account-0")))
        XCTAssertEqual(
            store.choice(for: identity(
                host: "mac",
                agent: "codex",
                account: "account-\(MobileNewSessionDefaultsStore.maximumRecordCount)"
            ))?.modelID,
            "model-\(MobileNewSessionDefaultsStore.maximumRecordCount)"
        )
        let reloaded = MobileNewSessionDefaultsStore(defaults: defaults)
        XCTAssertNil(reloaded.choice(for: identity(host: "mac", agent: "codex", account: "account-0")))
    }

    func testRejectedOversizedCandidateLeavesLastGoodArchiveUntouched() {
        let store = MobileNewSessionDefaultsStore(defaults: defaults)
        let primary = identity(host: "mac", agent: "codex", account: "default")
        let good = MobileNewSessionRunChoice(modelID: "sol", reasoningID: "xhigh")
        XCTAssertTrue(store.remember(good, for: primary))
        let persisted = defaults.data(forKey: MobileNewSessionDefaultsStore.archiveKey)

        XCTAssertFalse(store.remember(
            MobileNewSessionRunChoice(
                modelID: String(
                    repeating: "m",
                    count: MobileNewSessionDefaultsStore.maximumIdentifierBytes + 1
                ),
                reasoningID: "high"
            ),
            for: primary
        ))

        XCTAssertEqual(store.choice(for: primary), good)
        XCTAssertEqual(defaults.data(forKey: MobileNewSessionDefaultsStore.archiveKey), persisted)
        XCTAssertEqual(
            MobileNewSessionDefaultsStore(defaults: defaults).choice(for: primary),
            good
        )
    }

    func testCorruptArchiveIsQuarantinedAndLiveDefaultsCanTakeOver() {
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: MobileNewSessionDefaultsStore.archiveKey)

        let store = MobileNewSessionDefaultsStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: MobileNewSessionDefaultsStore.archiveKey))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(MobileNewSessionDefaultsStore.unreadableKeyPrefix)
                && (value as? Data) == original
        })
        XCTAssertNil(store.choice(for: identity(host: "mac", agent: "codex", account: "default")))
        XCTAssertTrue(store.remember(
            MobileNewSessionRunChoice(modelID: "gpt-sol", reasoningID: "xhigh"),
            for: identity(host: "mac", agent: "codex", account: "default")
        ))
    }

    func testOversizedArchiveIsRejectedBeforeDecodeAndQuarantined() {
        let original = Data(
            repeating: 0x41,
            count: MobileNewSessionDefaultsStore.maximumArchiveBytes + 1
        )
        defaults.set(original, forKey: MobileNewSessionDefaultsStore.archiveKey)

        _ = MobileNewSessionDefaultsStore(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: MobileNewSessionDefaultsStore.archiveKey))
        XCTAssertTrue(defaults.dictionaryRepresentation().contains { key, value in
            key.hasPrefix(MobileNewSessionDefaultsStore.unreadableKeyPrefix)
                && (value as? Data) == original
        })
    }

    func testNewerArchiveRemainsUntouchedAndDisablesOlderWriter() {
        let newer = Data(#"{"version":2,"records":[]}"#.utf8)
        defaults.set(newer, forKey: MobileNewSessionDefaultsStore.archiveKey)
        let store = MobileNewSessionDefaultsStore(defaults: defaults)

        XCTAssertFalse(store.remember(
            MobileNewSessionRunChoice(modelID: "gpt-sol", reasoningID: "xhigh"),
            for: identity(host: "mac", agent: "codex", account: "default")
        ))
        XCTAssertEqual(defaults.data(forKey: MobileNewSessionDefaultsStore.archiveKey), newer)
    }

    func testRememberedConcreteChoiceWinsOverLaterProviderDefaults() {
        let resolved = SessionDraftRunChoiceResolution.initial(
            remembered: MobileNewSessionRunChoice(modelID: "sol", reasoningID: "xhigh"),
            defaultModelID: "terra",
            models: models
        )

        XCTAssertEqual(resolved, MobileNewSessionRunChoice(modelID: "sol", reasoningID: "xhigh"))
    }

    func testWithdrawnRememberedValuesRepairToLiveEffectiveDefaults() {
        XCTAssertEqual(
            SessionDraftRunChoiceResolution.initial(
                remembered: MobileNewSessionRunChoice(modelID: "retired", reasoningID: "max"),
                defaultModelID: "terra",
                models: models
            ),
            MobileNewSessionRunChoice(modelID: "terra", reasoningID: "medium")
        )
        XCTAssertEqual(
            SessionDraftRunChoiceResolution.initial(
                remembered: MobileNewSessionRunChoice(modelID: "sol", reasoningID: "retired"),
                defaultModelID: "terra",
                models: models
            ),
            MobileNewSessionRunChoice(modelID: "sol", reasoningID: "low")
        )
    }

    func testOpenDraftPreservesAutoAndLaunchMaterializesIt() {
        let automatic = MobileNewSessionRunChoice(modelID: nil, reasoningID: nil)
        XCTAssertEqual(
            SessionDraftRunChoiceResolution.repair(
                current: automatic,
                defaultModelID: "terra",
                models: models
            ),
            automatic
        )
        XCTAssertEqual(
            SessionDraftRunChoiceResolution.launch(
                current: automatic,
                defaultModelID: "terra",
                models: models
            ),
            MobileNewSessionRunChoice(modelID: "terra", reasoningID: "medium")
        )
    }

    func testMissingCatalogFailsOpenToUnnamedRuntimeDefaults() {
        XCTAssertEqual(
            SessionDraftRunChoiceResolution.launch(
                current: MobileNewSessionRunChoice(modelID: nil, reasoningID: nil),
                defaultModelID: nil,
                models: []
            ),
            MobileNewSessionRunChoice(modelID: nil, reasoningID: nil)
        )
    }

    private var models: [RemoteModelChoiceDTO] {
        [
            .init(
                id: "sol",
                name: "Sol",
                reasoning: [
                    .init(id: "low", name: "Light"),
                    .init(id: "xhigh", name: "Extra High"),
                ],
                defaultReasoningID: "low"
            ),
            .init(
                id: "terra",
                name: "Terra",
                reasoning: [
                    .init(id: "medium", name: "Medium"),
                    .init(id: "high", name: "High"),
                ],
                defaultReasoningID: "medium"
            ),
        ]
    }

    private func identity(
        host: String,
        agent: String,
        account: String
    ) -> MobileNewSessionChoiceIdentity {
        MobileNewSessionChoiceIdentity(hostID: host, agentID: agent, accountID: account)
    }
}
