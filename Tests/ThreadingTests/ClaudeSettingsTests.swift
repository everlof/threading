import XCTest
@testable import Threading

/// Covers the settings files a Claude session inherits its posture and its speed from.
///
/// These were the two facts the composer used to answer with "Agent's Setting" — a chip naming
/// the place the answer lives rather than the answer. They live in files this app can read, and
/// what is worth pinning is the CLI's own resolution of them: the layer order, and the one value
/// whose *source* decides whether it counts at all.
final class ClaudeSettingsTests: XCTestCase {

    // MARK: - Fixtures

    private var account: URL!
    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // A managed policy replaces every writable layer outright, so on a machine that has one
        // these tests would truthfully resolve the managed value and prove nothing.
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: ClaudeSettingsDefaults.managedSettingsPath),
            "managed settings replace the layers under test"
        )

        account = try makeDirectory(named: "claude-settings-account")
        project = try makeDirectory(named: "claude-settings-project")
        ClaudeSettings.forgetAll()
    }

    override func tearDown() {
        for url in [account, project].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        ClaudeSettings.forgetAll()
        super.tearDown()
    }

    private var fixture: AgentAccount {
        AgentAccount(provider: .claude, handle: .named("settings"), configPath: account.path)
    }

    private func mode() -> AgentPermissionMode? {
        ClaudeSettings.permissionMode(account: fixture, projectDirectory: project.path)
    }

    // MARK: - Layers

    /// Most-specific-first, the CLI's own order: the project's `settings.local.json` beats its
    /// `settings.json`, which beats the account's own.
    func testThePermissionModeFollowsTheSettingsLayers() throws {
        XCTAssertNil(mode(), "an account that states nothing states nothing")

        try write(#"{"permissions": {"defaultMode": "plan"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .plan)

        try write(#"{"permissions": {"defaultMode": "acceptEdits"}}"#, to: projectSettings)
        XCTAssertEqual(mode(), .acceptEdits)

        try write(#"{"permissions": {"defaultMode": "bypassPermissions"}}"#, to: localSettings)
        XCTAssertEqual(mode(), .bypassPermissions)
    }

    /// A layer that says nothing about the mode is not a layer that says "nothing": it is skipped,
    /// and the layer below still answers. A `statusLine`-only project file used to be the shape
    /// most likely to get this wrong.
    func testALayerThatStatesNoModeIsSkippedRatherThanAnswering() throws {
        try write(#"{"permissions": {"defaultMode": "plan"}}"#, to: accountSettings)
        try write(#"{"statusLine": {"type": "command", "command": "line"}}"#, to: projectSettings)

        XCTAssertEqual(mode(), .plan)
    }

    // MARK: - The one source-restricted value

    /// `auto` hands the agent a classifier instead of a prompt, so a `.claude` directory that
    /// travels with a checkout may not grant it. Measured against CLI 2.1.228, which drops the
    /// key outright rather than falling through — the user's own mode underneath it does not
    /// apply either, and this app must not report a mode the session will not run in.
    func testAutoIsOnlyGrantedByALayerARepositoryCannotWrite() throws {
        try write(#"{"permissions": {"defaultMode": "plan"}}"#, to: accountSettings)
        try write(#"{"permissions": {"defaultMode": "auto"}}"#, to: projectSettings)
        XCTAssertNil(mode(), "a repository granted itself auto mode")

        try FileManager.default.removeItem(at: projectSettings)
        ClaudeSettings.forgetAll()
        try write(#"{"permissions": {"defaultMode": "auto"}}"#, to: localSettings)
        XCTAssertNil(mode(), "settings.local.json is repo-controllable too")

        try FileManager.default.removeItem(at: localSettings)
        // Explicitly, because this phase rewrites the account file to a value of exactly the
        // same length: what is under test here is the source rule, not the memo's invalidation,
        // which `testAnEditedSettingsFileIsReadAgain` covers on its own terms.
        ClaudeSettings.forgetAll()
        try write(#"{"permissions": {"defaultMode": "auto"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .auto, "the user's own settings may grant it")
    }

    // MARK: - Vocabulary

    /// Both spellings read as Manual: `manual` is the one the CLI's `--help` documents and this
    /// app persists, `default` is the one it writes down. A reader taking only the external one
    /// would report "unknown" for the most common posture there is.
    func testManualAndDefaultBothReadAsManual() throws {
        try write(#"{"permissions": {"defaultMode": "manual"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .manual)

        try write(#"{"permissions": {"defaultMode": "default"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .manual)
    }

    /// A mode this app has never heard of reads as nothing rather than as the nearest one it
    /// knows. A newer CLI's seventh posture must leave the chip saying where the decision lives.
    func testAnUnknownModeReadsAsNothing() throws {
        try write(#"{"permissions": {"defaultMode": "telepathy"}}"#, to: accountSettings)
        XCTAssertNil(mode())
    }

    /// A file that will not parse states nothing, which is what the CLI does with it in
    /// `--print` mode as well.
    func testAMalformedFileStatesNothing() throws {
        try write("{ not json", to: accountSettings)
        XCTAssertNil(mode())
    }

    // MARK: - Speed

    /// Fast mode is a settings key like any other, and unset is not the same as Standard *here*:
    /// this reports what the file says, and `AgentModels.defaultFastMode` is where unset becomes
    /// the Standard a live control-channel flag actually starts in.
    func testFastModeIsReadFromTheLayersAndUnsetIsDecidedElsewhere() throws {
        XCTAssertNil(ClaudeSettings.fastMode(account: fixture, projectDirectory: project.path))
        XCTAssertEqual(
            AgentModels.defaultFastMode(
                for: .claude,
                model: "opus",
                account: fixture,
                projectDirectory: project.path
            ),
            false,
            "a flag that starts off is a known Standard, not an unknown"
        )

        try write(#"{"fastMode": true}"#, to: accountSettings)
        XCTAssertEqual(
            ClaudeSettings.fastMode(account: fixture, projectDirectory: project.path),
            true
        )
        XCTAssertEqual(
            AgentModels.defaultFastMode(
                for: .claude,
                model: "opus",
                account: fixture,
                projectDirectory: project.path
            ),
            true,
            "a login that turned fast mode on for itself was reported as Standard"
        )
    }

    // MARK: - Caching

    /// The memo is keyed on the file, not on the process: `refreshConversationControls()` runs on
    /// every streamed event, so these reads are cached — and a cache that outlived an edit would
    /// leave the chip naming a mode the user had just changed.
    ///
    /// The reading is stamped with modification date *and* size. The rewrites here change both,
    /// which is the assertion that survives on a filesystem with a coarse timestamp; the size is
    /// carried precisely because a settings file is small enough to be rewritten inside one tick
    /// of the other.
    func testAnEditedSettingsFileIsReadAgain() throws {
        try write(#"{"permissions": {"defaultMode": "plan"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .plan)

        try write(#"{"permissions": {"defaultMode": "acceptEdits"}}"#, to: accountSettings)
        XCTAssertEqual(mode(), .acceptEdits)

        try FileManager.default.removeItem(at: accountSettings)
        XCTAssertNil(mode(), "a deleted file still answered from the memo")
    }

    // MARK: - Helpers

    private var accountSettings: URL {
        account.appendingPathComponent(ClaudeSettingsDefaults.settingsFile)
    }

    private var projectSettings: URL {
        project
            .appendingPathComponent(ClaudeSettingsDefaults.projectSettingsDirectory)
            .appendingPathComponent(ClaudeSettingsDefaults.settingsFile)
    }

    private var localSettings: URL {
        project
            .appendingPathComponent(ClaudeSettingsDefaults.projectSettingsDirectory)
            .appendingPathComponent(ClaudeSettingsDefaults.localSettingsFile)
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: url)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
