import XCTest
@testable import Threading

/// Finding the file a Claude conversation was written to, for folders that are not
/// `/Users/me/repo/thing`.
///
/// The encoding had replaced `/` and nothing else, which is right for the ordinary case and
/// silently wrong for every other one. Nothing failed loudly: a directory that does not exist
/// reads as "this session never recorded a conversation", so `AgentLauncher` took its
/// fresh-launch branch and relaunched with `--session-id` naming an id Claude had already
/// used. Claude exits 1 on that within a second, which on screen is a Resume button that does
/// nothing at all. Every managed workspace was in this state — they live under
/// `Application Support` — and so was any project folder with a dot in its name.
///
/// The expectations here were measured against the CLI rather than reasoned about: a folder
/// named `slug probe_v1.2 åäö-🎉` is filed under `slug-probe-v1-2-------`.
final class ClaudeTranscriptPathTests: XCTestCase {

    // MARK: - Encoding

    func testAnOrdinaryCheckoutPathStillSlugsToItsSeparatorsAlone() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "/Users/david/repo/AnotherTerminal"),
            "-Users-david-repo-AnotherTerminal"
        )
    }

    /// The case that stranded four conversations: a managed workspace lives under
    /// `Application Support`, and the space is not a separator.
    func testASpaceBecomesASeparatorLikeEverythingElse() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(
                forPath: "/Users/david/Library/Application Support/Threading/ManagedWorkspaces/a1"
            ),
            "-Users-david-Library-Application-Support-Threading-ManagedWorkspaces-a1"
        )
    }

    /// Two dots, two dashes: a leading-dot directory and a dotted folder name are both ordinary
    /// on disk, and both used to be unreachable.
    func testADotBecomesASeparator() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "/Users/david/repo/sonda/.claude/worktrees/w"),
            "-Users-david-repo-sonda--claude-worktrees-w"
        )
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "/Users/david/mjukis/projects/mjukis.dev"),
            "-Users-david-mjukis-projects-mjukis-dev"
        )
    }

    func testAnUnderscoreBecomesASeparator() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "/tmp/my_project"),
            "-tmp-my-project"
        )
    }

    /// An existing dash survives as itself, so a slug is lossy in the direction that matters:
    /// two different paths can encode alike. That is why `SessionImporter` checks each
    /// transcript's recorded `cwd` rather than trusting the directory it found the file in.
    func testAnExistingDashIsKeptRatherThanDoubled() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "/tmp/a-b"),
            "-tmp-a-b"
        )
    }

    /// Per UTF-16 code unit, which is the whole reason this is not `map` over `Character`:
    /// each Latin-1 letter contributes one dash and the astral scalar contributes two.
    func testNonASCIIIsCountedInCodeUnitsSoAnAstralScalarIsTwoSeparators() {
        XCTAssertEqual(
            ClaudeTranscript.projectSlug(forPath: "slug probe_v1.2 åäö-🎉"),
            "slug-probe-v1-2-------"
        )
    }

    func testAnEmptyPathEncodesToNothingRatherThanTrapping() {
        XCTAssertEqual(ClaudeTranscript.projectSlug(forPath: ""), "")
    }

    // MARK: - Locating the transcript

    /// The end the encoding exists for: the URL Threading composes is the file Claude wrote.
    ///
    /// `AgentLauncher.plan` and `ProjectStore.executionProject` both hand this type a project
    /// whose folder has been substituted for the session's own checkout, so a managed workspace
    /// is addressed by the worktree it ran in — not by the repository it will merge back into.
    func testAManagedWorkspaceTranscriptIsFoundWhereClaudeWroteIt() throws {
        let configPath = try temporaryDirectory()
        let worktree = "/Users/david/Library/Application Support/Threading/ManagedWorkspaces/a1"
        let transcriptID = TranscriptID("acb696ff-3bed-42b4-bf73-ab4c4bb2ba3c")

        let planted = try plantTranscript(
            transcriptID: transcriptID,
            configPath: configPath,
            slug: "-Users-david-Library-Application-Support-Threading-ManagedWorkspaces-a1"
        )

        var project = Project(
            name: "AnotherTerminal",
            folderURL: URL(fileURLWithPath: "/Users/david/repo/AnotherTerminal")
        )
        project.folderPath = worktree

        let url = try XCTUnwrap(
            ClaudeTranscript.storageURL(
                sessionID: transcriptID,
                account: Self.account(configPath: configPath),
                in: project
            )
        )

        XCTAssertEqual(url.path, planted.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// Children hang off the root transcript's own name, so they inherit the same directory and
    /// were unreachable for exactly the same sessions.
    func testTheSubagentsDirectoryHangsOffTheSameEncodedFolder() throws {
        let configPath = try temporaryDirectory()
        var project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        project.folderPath = "/Users/david/mjukis/projects/mjukis.dev"

        let root = try XCTUnwrap(
            ClaudeTranscript.storageURL(
                sessionID: TranscriptID("00000000-0000-0000-0000-0000000000ab"),
                account: Self.account(configPath: configPath),
                in: project
            )
        )

        XCTAssertEqual(
            ClaudeTranscript.subagentsDirectory(forRoot: root).path,
            configPath + "/projects/-Users-david-mjukis-projects-mjukis-dev"
                + "/00000000-0000-0000-0000-0000000000ab/subagents"
        )
    }

    // MARK: - Fixtures

    private static func account(configPath: String) -> AgentAccount {
        AgentAccount(provider: .claude, handle: .standard, configPath: configPath)
    }

    private func temporaryDirectory() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeTranscriptPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    /// Writes a transcript exactly where the CLI would, so the assertion is against a real file
    /// rather than against the same string twice.
    private func plantTranscript(
        transcriptID: TranscriptID,
        configPath: String,
        slug: String
    ) throws -> URL {
        let directory = URL(fileURLWithPath: configPath)
            .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory)
            .appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory
            .appendingPathComponent(transcriptID.rawValue)
            .appendingPathExtension(AgentDefaults.transcriptExtension)
        try Data().write(to: file)
        return file
    }
}
