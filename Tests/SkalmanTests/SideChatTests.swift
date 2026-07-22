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
        parent.agentSessionID = TranscriptID(parent.id.uuidString.lowercased())
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
        parent.agentSessionID = nil
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
        parent.agentSessionID = TranscriptID("01930000-0000-7000-8000-000000000000")
        parent.hasLaunched = true

        let child = AgentSession(kind: .codex, title: "Side Chat", forkedFrom: parent.id)
        project.sessions = [parent, child]

        XCTAssertNil(AgentLauncher.forkParent(for: child, in: project))
        XCTAssertFalse(AgentKind.codex.supportsForking)
        XCTAssertFalse(AgentKind.shell.supportsForking)
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
        let parentID = try XCTUnwrap(parent.agentSessionID)

        XCTAssertTrue(command.contains("--resume '\(parentID)'"), command)
        XCTAssertTrue(command.contains("--fork-session"), command)
        XCTAssertTrue(
            command.contains("--session-id '\(child.id.uuidString.lowercased())'"),
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
            command.contains("--session-id '\(child.id.uuidString.lowercased())'"),
            command
        )
    }

    // MARK: - Helpers

    /// Writes an empty transcript where the CLI would keep the parent's conversation, so the
    /// launcher's existence gate sees what it expects. Skips the test when no Claude account
    /// is installed, since the path is derived from the account's own config directory.
    private func writeTranscript(for session: AgentSession, in project: Project) throws -> URL {
        let agentID = try XCTUnwrap(session.agentSessionID)
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
