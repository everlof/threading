import XCTest
@testable import Threading

/// What the model menu's "leave it to the CLI" row is allowed to name.
///
/// The chip and that row answered the same question from different sources: the chip fell
/// through `session.model → reported → configured`, the row consulted only the account's config
/// file. On a login whose `settings.json` names no model — the common case, since leaving the
/// choice to the CLI is the default — a running session showed `Opus · 1M` on the chip above a
/// row still reading "Default model". These hold the rule that closed that gap and the reason it
/// is not simply "prefer whatever is newest".
final class ResolvedDefaultModelTests: XCTestCase {

    // MARK: - The runtime outranks the config file

    /// The whole point: an account that configures nothing still names the model, because the
    /// runtime already said which one it picked.
    func testAnUnconfiguredAccountNamesTheModelItsRuntimeReported() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "claude-opus-5[1m]",
            configuredModel: nil
        )

        XCTAssertEqual(resolved.identifier, "claude-opus-5[1m]")
        XCTAssertEqual(resolved.source, .reportedByRuntime)
    }

    /// Our reading of what the CLI would do loses to what it did. The config file is consulted
    /// before launch and can be edited after it, so a session outliving that edit must report the
    /// model it is actually running rather than the one it would start on today.
    func testTheReportedModelWinsOverADisagreeingConfiguredOne() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "claude-sonnet-5",
            configuredModel: "opus[1m]"
        )

        XCTAssertEqual(resolved.identifier, "claude-sonnet-5")
        XCTAssertEqual(resolved.source, .reportedByRuntime)
    }

    /// Agreement is reported as configuration, not as observation: the suffix the caller picks
    /// from this is the difference between "a setting you can change" and "what this session
    /// happens to run", and the setting is the more useful of the two when both are true.
    func testAgreementIsAttributedToTheAccountSoTheRowStaysActionable() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "opus[1m]",
            configuredModel: "opus[1m]"
        )

        XCTAssertEqual(resolved.identifier, "opus[1m]")
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    // MARK: - The runtime speaks for the default only while nothing is pinned

    /// The regression this rule exists to prevent. After an explicit switch the runtime reports
    /// the *user's choice*, so letting it answer here would print "Sonnet (in use)" on the row
    /// that means "leave it to the CLI" — an actively wrong label, where the generic string was
    /// merely unhelpful.
    func testAPinnedSessionLeavesTheDefaultRowSpeakingForTheAccount() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: "claude-sonnet-5",
            reportedModel: "claude-sonnet-5",
            configuredModel: "opus[1m]"
        )

        XCTAssertEqual(resolved.identifier, "opus[1m]")
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    /// And with nothing configured either, a pinned session's default row has nothing to name —
    /// it must not borrow the pinned model's name.
    func testAPinnedSessionOnAnUnconfiguredAccountNamesNothing() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: "claude-sonnet-5",
            reportedModel: "claude-sonnet-5",
            configuredModel: nil
        )

        XCTAssertNil(resolved.identifier)
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    // MARK: - Nothing to say stays nothing to say

    /// A dormant conversation on an unconfigured login: no source can answer, and the CLI's own
    /// fallback is negotiated per subscription rather than recorded on disk. The caller renders
    /// the generic string here, which is why nil must survive rather than becoming a guess.
    func testNoSourceLeavesTheIdentifierNil() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: nil
        )

        XCTAssertNil(resolved.identifier)
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    /// An empty string is a runtime that answered without saying anything. Treating it as an
    /// answer would blank the row, so it is not one.
    func testAnEmptyReportedModelIsNotAnAnswer() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "",
            configuredModel: "opus[1m]"
        )

        XCTAssertEqual(resolved.identifier, "opus[1m]")
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    /// The account still answers when the runtime has not reported yet — the composer's case,
    /// and a conversation's until its first event lands.
    func testAConfiguredAccountAnswersBeforeTheRuntimeReports() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: "opus[1m]"
        )

        XCTAssertEqual(resolved.identifier, "opus[1m]")
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    // MARK: - What the login ran last time

    /// The composer's case, and the reason this source exists: nothing is running, the account
    /// configures nothing, and the only local evidence is where this login landed before.
    func testAnEarlierRunAnswersWhenNothingElseCan() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: nil,
            rememberedModel: "claude-opus-5[1m]"
        )

        XCTAssertEqual(resolved.identifier, "claude-opus-5[1m]")
        XCTAssertEqual(resolved.source, .rememberedFromEarlierRun)
    }

    /// Evidence loses to configuration. A login that has since been pointed at a model runs that
    /// model next, whatever it ran last week, so the stale observation must not win.
    func testConfigurationOutranksWhatTheLoginRanLastTime() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: "sonnet",
            rememberedModel: "claude-opus-5[1m]"
        )

        XCTAssertEqual(resolved.identifier, "sonnet")
        XCTAssertEqual(resolved.source, .accountConfiguration)
    }

    // MARK: - Named more widely than it is metered

    /// A recollection is good enough to print and not good enough to charge a window against:
    /// applying a scoped Fable limit because this login ran Fable last week would put a session
    /// in the red over a model it may not be running.
    func testARememberedModelNamesTheRowButMetersNothing() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: nil,
            rememberedModel: "claude-fable-5[1m]"
        )

        XCTAssertEqual(resolved.identifier, "claude-fable-5[1m]")
        XCTAssertNil(resolved.meteredIdentifier)
    }

    /// The two sources that do speak for this session meter by what they name.
    func testConfiguredAndReportedModelsAreBothMetered() {
        let configured = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: nil,
            configuredModel: "opus[1m]"
        )
        let reported = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "claude-sonnet-5",
            configuredModel: nil
        )

        XCTAssertEqual(configured.meteredIdentifier, "opus[1m]")
        XCTAssertEqual(reported.meteredIdentifier, "claude-sonnet-5")
    }

    /// And this session's own runtime outranks both: it is the live answer, not a recollection.
    func testTheLiveRuntimeOutranksTheRememberedRun() {
        let resolved = AgentModels.resolvedDefault(
            sessionModel: nil,
            reportedModel: "claude-sonnet-5",
            configuredModel: nil,
            rememberedModel: "claude-opus-5[1m]"
        )

        XCTAssertEqual(resolved.identifier, "claude-sonnet-5")
        XCTAssertEqual(resolved.source, .reportedByRuntime)
    }
}

// MARK: - Reading an account's own files

/// What Threading may learn about a login from the files the CLI itself writes.
///
/// `settings.json` is the user's; `.claude.json` is the CLI's cache of what the service said.
/// The second is undocumented and was null on two of four real logins when this was measured,
/// so every assertion here is also a statement about degrading quietly when it is absent.
final class ClaudeAccountModelDiscoveryTests: XCTestCase {

    private var configDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("account-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        // Memoised per config path for the life of the process, and every fixture writes a fresh
        // one — cleared anyway so a test never inherits another's answer.
        ClaudeAccountLastRunModel.forgetAll()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configDirectory)
        configDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - The catalog

    /// A login with no cache still gets the documented aliases, which is the whole catalog for
    /// every account that has never run — and for the two idle logins measured.
    func testTheDocumentedAliasesStandAloneWithoutACache() {
        let identifiers = AgentModels.options(for: .claude, account: account()).map(\.identifier)

        XCTAssertEqual(identifiers, AgentDefaults.claudeModels)
    }

    /// The gap this closes: `claude-fable-5[1m]` is selectable on a real login and no alias
    /// names it, so before reading the cache it could not be picked from this menu at all.
    ///
    /// It lands beside `fable` rather than after `haiku`: a cached model is a member of a tier,
    /// not an afterthought appended to the list, and reading the two Fables a menu apart made the
    /// long-context variant look like a different family.
    func testACachedModelNoAliasNamesIsOfferedInsideItsTier() throws {
        try writeState(#"""
        {"additionalModelOptionsCache": [
          {"value": "claude-fable-5[1m]", "label": "Fable",
           "description": "Fable 5 · Most capable"}
        ]}
        """#)

        let options = AgentModels.options(for: .claude, account: account())

        XCTAssertEqual(
            options.map(\.identifier),
            ["fable", "claude-fable-5[1m]", "opus", "sonnet", "haiku"]
        )
        // Ours, not the service's "Fable": two rows reading "Fable" would distinguish nothing,
        // and this name matches what the chip and the usage pill call the same model.
        XCTAssertEqual(options[1].displayName, ModelName.display(for: "claude-fable-5[1m]"))
    }

    /// An id `ModelName` has never seen renders with the service's own word for it rather than
    /// as a raw identifier — the case that arrives when a model ships before Threading does.
    /// It also sorts last, since a tier nothing names is not a tier to rank.
    func testAnUnrecognisedModelBorrowsTheServicesLabel() throws {
        try writeState(#"""
        {"additionalModelOptionsCache": [{"value": "claude-quasar-9", "label": "Quasar"}]}
        """#)

        let options = AgentModels.options(for: .claude, account: account())

        XCTAssertEqual(options.last?.identifier, "claude-quasar-9")
        XCTAssertEqual(options.last?.displayName, "Quasar")
    }

    // MARK: - The order

    /// A model picker is a ladder, and the rung a user reaches for first should be the most
    /// capable model the login can run. The list used to open on whatever order the alias
    /// constant happened to be written in.
    func testTheCatalogDescendsFromTheMostCapableTier() {
        let identifiers = AgentModels.options(for: .claude, account: account()).map(\.identifier)

        XCTAssertEqual(identifiers, ["fable", "opus", "sonnet", "haiku"])
    }

    /// Inside a tier the alias leads the variants it stands for: `Fable` is the ordinary choice
    /// and `Fable 5 · 1M` the deliberate one, whatever order the CLI cached them in.
    func testAnAliasLeadsItsOwnTier() throws {
        try writeState(#"""
        {"additionalModelOptionsCache": [
          {"value": "claude-opus-4-8", "label": "Opus 4.8"},
          {"value": "claude-fable-5[1m]", "label": "Fable 1M"}
        ]}
        """#)

        let identifiers = AgentModels.options(for: .claude, account: account()).map(\.identifier)

        XCTAssertEqual(
            identifiers,
            ["fable", "claude-fable-5[1m]", "opus", "claude-opus-4-8", "sonnet", "haiku"]
        )
    }

    /// Two openings of the same menu list the same models in the same order. Sorting on an
    /// explicit index rather than leaving equal keys to `sort`'s own doing is what guarantees it
    /// — a menu that reshuffled between openings with nothing changed would read as a defect.
    func testTheOrderIsStableAcrossReads() throws {
        try writeState(#"""
        {"additionalModelOptionsCache": [
          {"value": "claude-quasar-9", "label": "Quasar"},
          {"value": "claude-pulsar-2", "label": "Pulsar"}
        ]}
        """#)

        let first = AgentModels.options(for: .claude, account: account()).map(\.identifier)
        let second = AgentModels.options(for: .claude, account: account()).map(\.identifier)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.suffix(2)), ["claude-quasar-9", "claude-pulsar-2"])
    }

    /// A conversation pinned to a model this catalog no longer lists still gets a row — placed
    /// in its tier, not pushed to the front where it would read as the recommendation.
    func testAPinnedModelJoinsTheListInItsOwnTier() {
        let identifiers = AgentModels.options(
            for: .claude,
            account: account(),
            including: "claude-sonnet-4-6"
        ).map(\.identifier)

        XCTAssertEqual(identifiers, ["fable", "opus", "sonnet", "claude-sonnet-4-6", "haiku"])
    }

    /// A pinned model the catalog already carries is not doubled, and nothing moves.
    func testAPinnedModelAlreadyInTheCatalogChangesNothing() {
        let plain = AgentModels.options(for: .claude, account: account()).map(\.identifier)
        let including = AgentModels.options(
            for: .claude,
            account: account(),
            including: "opus"
        ).map(\.identifier)

        XCTAssertEqual(plain, including)
    }

    /// A cache naming a model an alias already covers must not double it.
    func testACachedAliasIsNotListedTwice() throws {
        try writeState(#"{"additionalModelOptionsCache": [{"value": "opus", "label": "Opus"}]}"#)

        let identifiers = AgentModels.options(for: .claude, account: account()).map(\.identifier)

        XCTAssertEqual(identifiers, AgentDefaults.claudeModels)
    }

    /// Malformed or unexpected cache contents leave the aliases standing rather than throwing
    /// away the menu. This file is the CLI's, and its shape is not ours to depend on.
    func testAnUnreadableCacheLeavesTheAliasesIntact() throws {
        try writeState(#"{"additionalModelOptionsCache": "not-a-list"}"#)

        XCTAssertEqual(
            AgentModels.options(for: .claude, account: account()).map(\.identifier),
            AgentDefaults.claudeModels
        )
    }

    // MARK: - The organisation's default

    /// Null on every personal login, so this is the managed-account path: the org names the
    /// model and the user's file names none.
    func testTheOrganisationDefaultAnswersWhenTheUsersFileIsSilent() throws {
        try writeState(#"{"orgModelDefaultCache": "claude-opus-5"}"#)

        XCTAssertEqual(AgentModels.defaultModel(for: .claude, account: account()), "claude-opus-5")
    }

    /// The shape is unverified — it was null everywhere it could be observed — so the object
    /// forms are accepted too rather than silently reporting nothing on a managed login.
    func testTheOrganisationDefaultIsReadWhenItIsNestedInAnObject() throws {
        try writeState(#"{"orgModelDefaultCache": {"model": "claude-opus-5"}}"#)

        XCTAssertEqual(AgentModels.defaultModel(for: .claude, account: account()), "claude-opus-5")
    }

    /// A shape nobody anticipated reads as absent. Being wrong here costs a missing name, never
    /// a wrong one — the failure this whole area exists to avoid.
    func testAnUnrecognisedOrganisationShapeReadsAsAbsent() throws {
        try writeState(#"{"orgModelDefaultCache": {"unexpected": ["claude-opus-5"]}}"#)

        XCTAssertNil(AgentModels.defaultModel(for: .claude, account: account()))
    }

    /// The user's own file wins. A login that states a model has already overridden its
    /// organisation, and naming the org's choice there would name a model it will not run.
    func testTheUsersOwnSettingBeatsTheOrganisationDefault() throws {
        try writeState(#"{"orgModelDefaultCache": "claude-opus-5"}"#)
        try write(#"{"model": "sonnet"}"#, to: AgentDefaults.claudeSettingsFile)

        XCTAssertEqual(AgentModels.defaultModel(for: .claude, account: account()), "sonnet")
    }

    /// An account with neither still answers nothing, which is what keeps "Default model" honest.
    func testNeitherFileLeavesTheDefaultUnnamed() {
        XCTAssertNil(AgentModels.defaultModel(for: .claude, account: account()))
    }

    // MARK: - What the login last ran, from its own transcripts

    /// The gap this closes, and the case measured on a real login: 167 transcripts, no `model`
    /// key anywhere, and the answer sitting on disk the whole time. Before this, such an account
    /// could name nothing until it had run once *inside Threading*.
    func testALoginNamesTheModelItsNewestTranscriptRecorded() throws {
        try transcript("one", in: "project-a", model: "claude-sonnet-5")
        try transcript("two", in: "project-a", model: "claude-opus-5", newest: true)

        XCTAssertEqual(ClaudeAccountLastRunModel.lastRunModel(account: account()), "claude-opus-5")
    }

    /// Newest wins across directories too — a login works in several checkouts and the most
    /// recent conversation is the one that speaks for it.
    func testTheNewestTranscriptWinsAcrossProjectDirectories() throws {
        try transcript("old", in: "project-a", model: "claude-sonnet-5")
        try transcript("new", in: "project-b", model: "claude-opus-5", newest: true)

        XCTAssertEqual(ClaudeAccountLastRunModel.lastRunModel(account: account()), "claude-opus-5")
    }

    /// A login that has genuinely never run answers nothing rather than inventing a name — the
    /// one remaining case the UI must render as "the agent decides".
    func testALoginWithNoTranscriptsAnswersNothing() {
        XCTAssertNil(ClaudeAccountLastRunModel.lastRunModel(account: account()))
    }

    /// Only Claude records the model in its transcripts, and the capability says so rather than
    /// this type naming the runtime — `check_architecture_boundaries.sh` fails the build on the
    /// latter.
    func testARuntimeThatRecordsNoModelIsNotSearched() throws {
        try transcript("one", in: "project-a", model: "claude-opus-5")

        let codex = AgentAccount(
            provider: .codex,
            handle: .named("fixture"),
            configPath: configDirectory.path
        )

        XCTAssertNil(ClaudeAccountLastRunModel.lastRunModel(account: codex))
    }

    // MARK: - Helpers

    /// Writes a transcript under `<config>/projects/<directory>/`. `newest` bumps its
    /// modification date, since a test writes all of them within the same millisecond.
    private func transcript(
        _ name: String,
        in directory: String,
        model: String,
        newest: Bool = false
    ) throws {
        let folder = configDirectory
            .appendingPathComponent(TranscriptModelDefaults.claudeProjectsDirectory)
            .appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent(
            "\(name).\(TranscriptModelDefaults.transcriptExtension)"
        )
        let line = #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)"}}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let date = newest ? Date().addingTimeInterval(60) : Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: folder.path
        )
    }

    private func account() -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: .named("fixture"),
            configPath: configDirectory.path
        )
    }

    private func writeState(_ json: String) throws {
        try write(json, to: AgentDefaults.claudeStateFile)
    }

    private func write(_ json: String, to name: String) throws {
        try Data(json.utf8).write(to: configDirectory.appendingPathComponent(name))
    }
}
