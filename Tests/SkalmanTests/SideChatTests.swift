import XCTest
@testable import Skalman

/// Side chats: a session forked from another so a question can be asked without joining the
/// conversation it asks about.
@MainActor
final class SideChatTests: XCTestCase {

    // MARK: - Fixtures

    /// A project rooted in a temporary folder, so a transcript written for it lands under a
    /// path no real session could own.
    private func makeProject() throws -> Project {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("skalman-side-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        var project = Project(name: "fixture", folderURL: folder)
        project.folderPath = folder.path
        return project
    }

    private func makeParent() -> AgentSession {
        var parent = AgentSession(kind: .claude, title: "Parent")
        parent.resumeState = .resumable(TranscriptID(parent.id.uuidString.lowercased()))
        parent.hasLaunched = true
        return parent
    }

    // MARK: - Fork Gate

    func testForkParentResolvesForAFreshSideChat() throws {
        var project = try makeProject()
        let parent = makeParent()
        let child = AgentSession(kind: .claude, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        XCTAssertEqual(AgentLauncher.forkParent(for: child, in: project)?.id, parent.id)
    }

    /// The fork is a birth, not a mode: once the child has run it owns a transcript of its
    /// own, and forking again would throw away everything said in it.
    func testForkParentIsGoneOnceTheChildHasLaunched() throws {
        var project = try makeProject()
        let parent = makeParent()
        var child = AgentSession(kind: .claude, title: "Side Chat", forkedFrom: parent.id)
        child.hasLaunched = true
        project.sessions = [parent, child]

        XCTAssertNil(AgentLauncher.forkParent(for: child, in: project))
    }

    /// A parent that never started has no conversation to copy, so its child is an ordinary
    /// new session rather than a broken fork.
    func testForkParentRefusesAParentWithNoConversation() throws {
        var project = try makeProject()
        var parent = makeParent()
        parent.resumeState = .awaitingIdentifier
        let child = AgentSession(kind: .claude, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        XCTAssertNil(AgentLauncher.forkParent(for: child, in: project))
    }

    func testOrdinarySessionNeverForks() throws {
        var project = try makeProject()
        let parent = makeParent()
        let plain = AgentSession(kind: .claude, title: "Plain")
        project.sessions = [parent, plain]

        XCTAssertNil(AgentLauncher.forkParent(for: plain, in: project))
    }

    /// Codex has no `--fork-session`, so a record carrying a parent must not produce one.
    func testCodexNeverForks() throws {
        var project = try makeProject()
        var parent = AgentSession(kind: .codex, title: "Parent")
        parent.resumeState = .resumable(
            TranscriptID("01930000-0000-7000-8000-000000000000")
        )
        parent.hasLaunched = true

        let child = AgentSession(kind: .codex, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        XCTAssertNil(AgentLauncher.forkParent(for: child, in: project))
        XCTAssertFalse(AgentKind.codex.supportsForking)
    }

    // MARK: - Launch Line

    /// The whole point, in one assertion: resume the *parent's* conversation while writing to
    /// the *child's* identifier. Both flags together are what makes a side chat run beside a
    /// live session instead of fighting it for one transcript.
    func testForkLaunchResumesTheParentUnderTheChildsIdentifier() throws {
        var project = try makeProject()
        let parent = makeParent()
        let child = AgentSession(kind: .claude, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        let transcript = try writeTranscript(for: parent, in: project)
        addTeardownBlock { try? FileManager.default.removeItem(at: transcript) }

        let command = try XCTUnwrap(AgentLauncher.plan(for: child, in: project).arguments.last)
        let parentID = try XCTUnwrap(parent.resumeState.transcriptID)

        XCTAssertTrue(command.contains("'--resume' '\(parentID)'"), command)
        XCTAssertTrue(command.contains("'--fork-session'"), command)
        XCTAssertTrue(
            command.contains("'--session-id' '\(child.id.uuidString.lowercased())'"),
            command
        )
    }

    /// Without the parent's transcript there is nothing to fork, so the launch falls through
    /// to the ordinary fresh-session path rather than resuming a conversation that is not on
    /// disk. Same rule the plain resume already applies to itself.
    func testForkFallsBackToAFreshLaunchWithoutTheParentsTranscript() throws {
        var project = try makeProject()
        let parent = makeParent()
        let child = AgentSession(kind: .claude, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        let command = try XCTUnwrap(AgentLauncher.plan(for: child, in: project).arguments.last)

        XCTAssertFalse(command.contains("--fork-session"), command)
        XCTAssertTrue(
            command.contains("'--session-id' '\(child.id.uuidString.lowercased())'"),
            command
        )
    }

    // MARK: - Resume State Launch Plans

    func testFreshLaunchPlansExposeHowTheirIdentifierIsEstablished() throws {
        let project = try makeProject()
        let claude = AgentSession(kind: .claude, title: "Claude")
        let codex = AgentSession(kind: .codex, title: "Codex")

        XCTAssertEqual(
            AgentLauncher.plan(for: claude, in: project).resumeState,
            .resumable(TranscriptID(claude.id.uuidString.lowercased()))
        )
        XCTAssertEqual(
            AgentLauncher.plan(for: codex, in: project).resumeState,
            .awaitingIdentifier
        )
    }

    func testLaunchPlanQuotesHostilePathTitleModelAndPrompt() throws {
        let hostile = "'; rm -rf ~'"
        var project = try makeProject()
        project.folderPath = "/tmp/\(hostile)"
        let session = AgentSession(kind: .claude, title: hostile, model: hostile)

        let source = try XCTUnwrap(
            AgentLauncher.plan(for: session, in: project, initialPrompt: hostile).arguments.last
        )
        let quotedHostile = ShellCommand(word: hostile).source
        let occurrenceCount = source.components(separatedBy: quotedHostile).count - 1

        XCTAssertGreaterThanOrEqual(occurrenceCount, 3, source)
        XCTAssertTrue(source.contains(ShellCommand(word: project.folderPath).source), source)
    }

    // MARK: - Helpers

    /// Writes an empty transcript where the CLI would keep the parent's conversation, so the
    /// launcher's existence gate sees what it expects. Skips the test when no Claude account
    /// is installed, since the path is derived from the account's own config directory.
    private func writeTranscript(for session: AgentSession, in project: Project) throws -> URL {
        let agentID = try XCTUnwrap(session.resumeState.transcriptID)
        let url = try XCTUnwrap(
            ClaudeTranscript.url(sessionID: agentID, for: session, in: project),
            "no Claude account discovered on this machine"
        )

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)

        // The directory is named after the temporary project folder, so it belongs to this
        // test alone and goes with it.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return url
    }
}

final class ShellCommandTests: XCTestCase {

    /// Values representative of every dynamic launch field. Running them through a real shell
    /// proves they remain one argument; merely comparing quote characters would test the
    /// implementation rather than the safety property.
    func testHostileWordsRoundTripThroughShell() throws {
        let hostileWords = [
            "'; rm -rf ~'",
            "feature/one && touch /tmp/skalman-injection",
            "$(whoami) `id` $HOME",
            "folder with spaces/and\nnewlines",
            "double\" and single' quotes",
            "",
            "🦊 unicode"
        ]

        for word in hostileWords {
            var command = ShellCommand(word: "/usr/bin/printf")
            command.append(word: "%s")
            command.append(word: word)

            XCTAssertEqual(try run(command), word, "Did not preserve \(word.debugDescription)")
        }
    }

    func testFlagValueAndFixedOperatorComposeWithoutRawFragments() throws {
        var first = ShellCommand(word: "/usr/bin/true")
        var second = ShellCommand(word: "/usr/bin/printf")
        second.append(flag: "--", value: "'; echo injected'")
        first.append(operator: .and)
        first.append(contentsOf: second)

        XCTAssertEqual(try run(first), "'; echo injected'")
    }

    func testDirectoryWrapperPreservesAHostilePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder '; echo injected; $(whoami)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pwd = ShellCommand(word: "/bin/pwd")
        let command = ShellCommand.executing(pwd, in: directory.path)

        XCTAssertEqual(
            try run(command).trimmingCharacters(in: .newlines),
            directory.path
        )
    }

    private func run(_ command: ShellCommand) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.source]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command.source)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
