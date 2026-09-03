import XCTest
@testable import Threading

/// Remembering what a login's runtime resolved an alias to.
///
/// The catalogue's alias rows read the bare family — "Opus" — until this has watched the login
/// launch that alias, after which the row can say which Opus. Everything here is about recording
/// only what was seen, and only where there is something to learn.
final class ModelAliasResolutionStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: ModelAliasResolutionStore!
    private let login = AccountID(provider: .claude, handle: .named("claude-fixture"))

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ModelAliasResolutionStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = ModelAliasResolutionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Recording

    func testAnAliasIsRememberedAsWhatItResolvedTo() {
        store.record("claude-opus-5", forLaunched: "opus", in: login)

        XCTAssertEqual(store.resolvedModel(forLaunched: "opus", in: login), "claude-opus-5")
        XCTAssertNil(
            store.resolvedModel(forLaunched: "sonnet", in: login),
            "an alias this login has never launched has no answer, and none is guessed"
        )
    }

    /// The label is at most one run stale: the next start on the login is the truth.
    func testTheNewestRunOverwritesTheLast() {
        store.record("claude-opus-4-8", forLaunched: "opus", in: login)
        store.record("claude-opus-5", forLaunched: "opus", in: login)

        XCTAssertEqual(store.resolvedModel(forLaunched: "opus", in: login), "claude-opus-5")
    }

    func testARecordSurvivesARelaunch() {
        store.record("claude-fable-5-1[1m]", forLaunched: "fable[1m]", in: login)

        let reloaded = ModelAliasResolutionStore(defaults: defaults)

        XCTAssertEqual(
            reloaded.resolvedModel(forLaunched: "fable[1m]", in: login),
            "claude-fable-5-1[1m]"
        )
    }

    /// A launch that names its own version has nothing to teach, and an id the runtime echoed
    /// back unchanged says nothing either.
    func testOnlyAliasesAreRecorded() {
        store.record("claude-fable-5-1[1m]", forLaunched: "claude-fable-5-1[1m]", in: login)
        store.record("claude-fable-5-1", forLaunched: "claude-fable-5-1[1m]", in: login)
        store.record("opus", forLaunched: "opus", in: login)

        XCTAssertNil(store.resolvedModel(forLaunched: "claude-fable-5-1[1m]", in: login))
        XCTAssertNil(store.resolvedModel(forLaunched: "opus", in: login))
    }

    /// Only a runtime whose catalogue is aliases has anything to learn, and the capability says
    /// which — `check_architecture_boundaries.sh` fails the build on naming the runtime.
    func testARuntimeWithoutAliasesRecordsNothing() {
        let codex = AccountID(provider: .codex, handle: .named("codex-fixture"))

        store.record("gpt-5.6", forLaunched: "gpt", in: codex)

        XCTAssertNil(store.resolvedModel(forLaunched: "gpt", in: codex))
    }

    /// Two logins can be granted different models, so what one resolved says nothing about
    /// the other — the same reason the hidden-model set is per login.
    func testLoginsDoNotShareAnswers() {
        let other = AccountID(provider: .claude, handle: .named("claude-other"))

        store.record("claude-opus-5", forLaunched: "opus", in: login)

        XCTAssertNil(store.resolvedModel(forLaunched: "opus", in: other))
    }

    // MARK: - Bounds

    /// A compact preference must not grow with whatever a launch was called. An alias already
    /// remembered still updates once the login is full; only a new one is refused.
    func testTheRecordIsBoundedPerLogin() {
        for index in 0..<40 {
            store.record("model-\(index)", forLaunched: "alias-\(index)", in: login)
        }

        XCTAssertEqual(store.resolvedModel(forLaunched: "alias-0", in: login), "model-0")
        XCTAssertNil(store.resolvedModel(forLaunched: "alias-39", in: login))

        store.record("model-changed", forLaunched: "alias-0", in: login)
        XCTAssertEqual(store.resolvedModel(forLaunched: "alias-0", in: login), "model-changed")
    }

    func testABlankIdentifierIsNotAnAnswer() {
        store.record("   ", forLaunched: "opus", in: login)
        store.record("claude-opus-5", forLaunched: "", in: login)

        XCTAssertNil(store.resolvedModel(forLaunched: "opus", in: login))
        XCTAssertNil(store.resolvedModel(forLaunched: "", in: login))
    }

    func testForgettingEmptiesTheStoreAndWhatItPersisted() {
        store.record("claude-opus-5", forLaunched: "opus", in: login)

        store.forgetAll()

        XCTAssertNil(store.resolvedModel(forLaunched: "opus", in: login))
        XCTAssertNil(
            ModelAliasResolutionStore(defaults: defaults).resolvedModel(forLaunched: "opus", in: login),
            "forgetting is persisted, not just dropped from memory"
        )
    }
}
