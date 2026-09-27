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

    // MARK: - A folder reached through a symlink

    /// The trap the obvious call walks into. Foundation hands `/private/tmp` back as `/tmp`,
    /// the one spelling Claude never files under, so a project normalised that way was looked
    /// for in `-tmp-…` while its conversation sat in `-private-tmp-…`.
    func testThePhysicalPathKeepsPrivateWhereFoundationStripsIt() {
        XCTAssertEqual(URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path, "/tmp")

        XCTAssertEqual(ClaudeTranscript.physicalPath(of: "/tmp"), "/private/tmp")
        XCTAssertEqual(ClaudeTranscript.projectSlugs(forPath: "/tmp"), ["-private-tmp", "-tmp"])
    }

    func testAFolderWithNoLinkOnItsPathHasOneSpelling() throws {
        let physical = try Self.workingDirectory(of: temporaryDirectory())

        XCTAssertEqual(
            ClaudeTranscript.projectSlugs(forPath: physical),
            [ClaudeTranscript.projectSlug(forPath: physical)]
        )
    }

    /// The case that stopped a conversation resuming, reduced: its folder was stored as
    /// `/tmp/takto-pr60`, Claude filed it under `-private-tmp-takto-pr60`, the lookup missed,
    /// and the launch fell through to `--session-id`, which Claude refused with exit 1.
    ///
    /// The physical path is asked of the kernel the way Claude asks it (`pwd -P`, i.e.
    /// `getcwd`), rather than computed by the code under test.
    @MainActor
    func testAConversationFiledUnderThePhysicalPathIsFoundThroughALink() throws {
        let folder = try linkedFolder()
        let configPath = try temporaryDirectory()
        let transcriptID = TranscriptID("f4f885ad-69c4-4848-9d9b-8166328a59ac")
        let planted = try plantTranscript(
            transcriptID: transcriptID,
            configPath: configPath,
            slug: ClaudeTranscript.projectSlug(forPath: folder.physical)
        )

        let located = try locate(transcriptID, configPath: configPath, folder: folder.link)

        XCTAssertEqual(located.path, planted.path)
        XCTAssertEqual(
            ClaudeTranscript.storageURL(
                sessionID: transcriptID,
                account: Self.account(configPath: configPath),
                in: Self.project(at: folder.link)
            )?.path,
            planted.path
        )
    }

    /// A copy Threading filed under the stated spelling before this was known is the file Claude
    /// goes on writing, because its `--resume` opens a copy wherever it is. It is still found,
    /// while a copy made now goes where Claude files a conversation it starts.
    @MainActor
    func testACopyFiledUnderTheStatedSpellingIsStillFound() throws {
        let folder = try linkedFolder()
        let configPath = try temporaryDirectory()
        let transcriptID = TranscriptID("3c44806a-5f53-45fd-9060-839db64a9cf5")
        let legacy = try plantTranscript(
            transcriptID: transcriptID,
            configPath: configPath,
            slug: ClaudeTranscript.projectSlug(forPath: folder.link)
        )

        let located = try locate(transcriptID, configPath: configPath, folder: folder.link)
        let destination = try XCTUnwrap(
            ClaudeTranscript.storageURL(
                sessionID: transcriptID,
                account: Self.account(configPath: configPath),
                in: Self.project(at: folder.link)
            )
        )

        XCTAssertEqual(located.path, legacy.path)
        XCTAssertEqual(
            destination.deletingLastPathComponent().lastPathComponent,
            ClaudeTranscript.projectSlug(forPath: folder.physical)
        )
    }

    /// Both present means a stale copy beside a live one; Claude resumes the physical one.
    @MainActor
    func testThePhysicalCopyWinsWhenBothSpellingsHoldOne() throws {
        let folder = try linkedFolder()
        let configPath = try temporaryDirectory()
        let transcriptID = TranscriptID("8cae8876-fd26-47a7-b71a-2246316c6d20")
        _ = try plantTranscript(
            transcriptID: transcriptID,
            configPath: configPath,
            slug: ClaudeTranscript.projectSlug(forPath: folder.link)
        )
        let physical = try plantTranscript(
            transcriptID: transcriptID,
            configPath: configPath,
            slug: ClaudeTranscript.projectSlug(forPath: folder.physical)
        )

        XCTAssertEqual(
            try locate(transcriptID, configPath: configPath, folder: folder.link).path,
            physical.path
        )
    }

    /// A catalogue projection asks `.known` once per session on the main actor, so it must not
    /// resolve a link or probe for a file: a folder nothing has resolved keeps its stated
    /// spelling, and one that has been resolved answers the physical one from memory.
    func testTheKnownEffortAnswersFromMemoryAlone() throws {
        let folder = try linkedFolder()
        let stated = ClaudeTranscript.projectSlug(forPath: folder.link)
        let physical = ClaudeTranscript.projectSlug(forPath: folder.physical)

        XCTAssertEqual(ClaudeTranscript.projectSlugs(forPath: folder.link, effort: .known), [stated])
        XCTAssertEqual(ClaudeTranscript.projectSlugs(forPath: folder.link), [physical, stated])
        XCTAssertEqual(
            ClaudeTranscript.projectSlugs(forPath: folder.link, effort: .known),
            [physical, stated]
        )
    }

    // MARK: - Fixtures

    private static func account(configPath: String) -> AgentAccount {
        AgentAccount(provider: .claude, handle: .standard, configPath: configPath)
    }

    private static func project(at folder: String) -> Project {
        var project = Project(name: "linked", folderURL: URL(fileURLWithPath: folder))
        project.folderPath = folder
        return project
    }

    /// The file the reader, and so the launcher's resume check, settles on.
    @MainActor
    private func locate(_ transcriptID: TranscriptID, configPath: String, folder: String) throws -> URL {
        var session = AgentSession(kind: .claude, title: "linked")
        session.resumeState = .resumable(transcriptID)
        let request = try XCTUnwrap(
            SessionTranscript.readRequest(
                sessionID: transcriptID,
                for: session,
                in: Self.project(at: folder),
                account: Self.account(configPath: configPath)
            )
        )
        return try XCTUnwrap(request.resolve())
    }

    /// A real folder and a link to it, with the physical path as the kernel reports it. Under
    /// the temporary directory, which is itself under `/var` — a link into `/private` — so the
    /// fixture has both kinds of link on its path.
    private func linkedFolder() throws -> (link: String, physical: String) {
        let root = try temporaryDirectory()
        let real = (root as NSString).appendingPathComponent("real")
        let link = (root as NSString).appendingPathComponent("link")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let physical = try Self.workingDirectory(of: link)
        XCTAssertNotEqual(physical, link)
        return (link, physical)
    }

    private static func workingDirectory(of path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/pwd")
        process.arguments = ["-P"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
