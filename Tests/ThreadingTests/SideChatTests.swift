import XCTest
@testable import Threading

/// Side chats: a session forked from another so a question can be asked without joining the
/// conversation it asks about.
@MainActor
final class SideChatTests: XCTestCase {

    // MARK: - Fixtures

    /// A project rooted in a temporary folder, so a transcript written for it lands under a
    /// path no real session could own.
    private func makeProject() throws -> Project {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-side-chat-\(UUID().uuidString)")
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
        let child = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: .forked(from: parent.id)
            ),
            title: "Side Chat"
        )
        project.sessions = [parent, child]

        XCTAssertEqual(AgentLauncher.forkParent(for: child, in: project)?.id, parent.id)
    }

    /// The fork is a birth, not a mode: once the child has run it owns a transcript of its
    /// own, and forking again would throw away everything said in it.
    func testForkParentIsGoneOnceTheChildHasLaunched() throws {
        var project = try makeProject()
        let parent = makeParent()
        var child = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: .forked(from: parent.id)
            ),
            title: "Side Chat"
        )
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
        let child = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: .forked(from: parent.id)
            ),
            title: "Side Chat"
        )
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

    /// Codex has no `--fork-session`, so its typed configuration cannot carry a parent.
    func testCodexNeverForks() throws {
        var project = try makeProject()
        var parent = AgentSession(kind: .codex, title: "Parent")
        parent.resumeState = .resumable(
            TranscriptID("01930000-0000-7000-8000-000000000000")
        )
        parent.hasLaunched = true

        let child = AgentSession(kind: .codex, title: "Ordinary")
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
        let child = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: .forked(from: parent.id)
            ),
            title: "Side Chat"
        )
        project.sessions = [parent, child]

        let transcript = try writeTranscript(for: parent, in: project)
        addTeardownBlock { try? FileManager.default.removeItem(at: transcript) }

        let command = try XCTUnwrap(try AgentLauncher.plan(for: child, in: project).arguments.last)
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
        let child = AgentSession(
            configuration: .claude(
                remoteControl: nil,
                reasoningEffort: nil,
                origin: .forked(from: parent.id)
            ),
            title: "Side Chat"
        )
        project.sessions = [parent, child]

        let command = try XCTUnwrap(try AgentLauncher.plan(for: child, in: project).arguments.last)

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
            try AgentLauncher.plan(for: claude, in: project).resumeState,
            .resumable(TranscriptID(claude.id.uuidString.lowercased()))
        )
        XCTAssertEqual(
            try AgentLauncher.plan(for: codex, in: project).resumeState,
            .awaitingIdentifier
        )
    }

    func testClaudeNativeLaunchForwardsSubagentText() throws {
        let project = try makeProject()
        let session = AgentSession(kind: .claude, title: "Claude")
        let source = try XCTUnwrap(
            try AgentLauncher.streamPlan(for: session, in: project).arguments.last
        )

        XCTAssertTrue(source.contains("'--forward-subagent-text'"), source)
    }

    func testCodexNativeFastModeConfiguresThePersistentAppServer() throws {
        let project = try makeProject()
        var session = AgentSession(kind: .codex, title: "Codex", model: "future-fast-model")
        session.resumeState = .resumable(TranscriptID("thread-fast"))
        session.fastMode = true

        let source = try XCTUnwrap(
            try AgentLauncher.streamPlan(for: session, in: project).arguments.last
        )

        XCTAssertTrue(source.contains("'--model' 'future-fast-model'"), source)
        XCTAssertTrue(source.contains("'--config' 'service_tier=\"priority\"'"), source)
        XCTAssertTrue(source.contains("'--config' 'features.fast_mode=true'"), source)
        XCTAssertTrue(source.contains("'app-server' '--listen' 'stdio://'"), source)
    }

    func testCodexNativeStandardModeOverridesAnAccountFastDefault() throws {
        let project = try makeProject()
        var session = AgentSession(kind: .codex, title: "Codex")
        session.resumeState = .resumable(TranscriptID("thread-standard"))
        session.fastMode = false

        let source = try XCTUnwrap(
            try AgentLauncher.streamPlan(for: session, in: project).arguments.last
        )

        XCTAssertTrue(source.contains("'--config' 'service_tier=\"default\"'"), source)
        XCTAssertFalse(source.contains("features.fast_mode=true"), source)
        XCTAssertTrue(source.contains("'app-server' '--listen' 'stdio://'"), source)
    }

    func testCodexNativeReasoningEffortConfiguresThePersistentAppServer() throws {
        let project = try makeProject()
        var session = AgentSession(
            configuration: .codex(reasoningEffort: "ultra"),
            title: "Codex",
            model: "gpt-5.6-sol"
        )
        session.resumeState = .resumable(TranscriptID("thread-ultra"))

        let source = try XCTUnwrap(
            try AgentLauncher.streamPlan(for: session, in: project).arguments.last
        )

        XCTAssertTrue(
            source.contains("'--config' 'model_reasoning_effort=\"ultra\"'"),
            source
        )
        XCTAssertTrue(source.contains("'app-server' '--listen' 'stdio://'"), source)
    }

    func testLaunchPlanQuotesHostilePathTitleModelAndPrompt() throws {
        let hostile = "'; rm -rf ~'"
        var project = try makeProject()
        project.folderPath = "/tmp/\(hostile)"
        var session = AgentSession(kind: .claude, title: hostile, model: hostile)

        // Only an explicit rename reaches the launch as `--name`; a creation title stays
        // out of the command line entirely, so the hostile name must be a rename to be
        // quoted at all.
        session.customTitle = hostile

        let source = try XCTUnwrap(
            try AgentLauncher.plan(for: session, in: project, initialPrompt: hostile).arguments.last
        )
        let quotedHostile = ShellCommand(word: hostile).source
        let occurrenceCount = source.components(separatedBy: quotedHostile).count - 1

        XCTAssertGreaterThanOrEqual(occurrenceCount, 3, source)
        XCTAssertTrue(source.contains(ShellCommand(word: project.folderPath).source), source)
    }

    // MARK: - Cross-provider continuation

    func testContinuationLineageRoundTripsWithoutTheSourceRecord() throws {
        let sourceID = SessionID()
        let destinationID = SessionID()
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: sourceID,
                kind: .claude,
                model: "claude-sonnet-4-5",
                title: "Parser fix"
            ),
            ConversationHandoffEndpoint(
                sessionID: destinationID,
                kind: .codex,
                model: "gpt-5.6-sol",
                title: "Continue the parser fix"
            )
        ]))
        let session = AgentSession(
            configuration: .codex(reasoningEffort: nil),
            title: "Continue the parser fix",
            handoff: handoff,
            id: destinationID
        )

        let restored = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(restored.continuedFrom, sourceID)
        XCTAssertEqual(restored.continuationSourceKind, .claude)
        XCTAssertTrue(restored.isCrossProviderContinuation)
    }

    func testContinuationBootstrapExistsOnlyUntilItsFirstLaunch() {
        let sourceID = SessionID()
        let destinationID = SessionID()
        let handoff = ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: sourceID,
                kind: .claude,
                model: nil,
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: destinationID,
                kind: .codex,
                model: nil,
                title: nil
            )
        ])!
        var continuation = AgentSession(
            configuration: .codex(reasoningEffort: nil),
            title: "Continue the parser fix",
            handoff: handoff,
            id: destinationID
        )

        let opening = ConversationContinuation.openingPrompt(for: continuation)
        XCTAssertTrue(opening?.contains("conversation_history") == true)
        XCTAssertTrue(opening?.contains("next_cursor") == true)

        continuation.hasLaunched = true
        XCTAssertNil(ConversationContinuation.openingPrompt(for: continuation))
        XCTAssertNil(ConversationContinuation.openingPrompt(
            for: AgentSession(kind: .codex, title: "Ordinary")
        ))
    }

    func testOpenCodeContinuationAttachesTheDurableSnapshot() throws {
        let project = try makeProject()
        let sourceID = SessionID()
        let destinationID = SessionID()
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: sourceID,
                kind: .grok,
                model: "grok-4",
                title: "Source"
            ),
            ConversationHandoffEndpoint(
                sessionID: destinationID,
                kind: .openCode,
                model: nil,
                title: "Destination"
            )
        ]))
        let session = AgentSession(
            configuration: .openCode,
            title: "Destination",
            handoff: handoff,
            id: destinationID
        )

        let command = try XCTUnwrap(
            try AgentLauncher.plan(
                for: session,
                in: project,
                initialPrompt: ConversationContinuation.openingPrompt(for: session)
            ).arguments.last
        )
        let snapshotPath = ConversationHandoffStore.url(for: destinationID).path

        XCTAssertTrue(command.contains("'--file' '\(snapshotPath)'"), command)
        XCTAssertTrue(command.contains("'--prompt'"), command)
        XCTAssertFalse(command.contains("<conversation_history>"), command)
    }

    func testGrokTerminalContinuationReceivesBoundedInlineHistory() throws {
        let sourceID = SessionID()
        let destinationID = SessionID()
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: sourceID,
                kind: .openCode,
                model: nil,
                title: "Source"
            ),
            ConversationHandoffEndpoint(
                sessionID: destinationID,
                kind: .grok,
                model: "grok-4",
                title: "Destination"
            )
        ]))
        let session = AgentSession(
            configuration: .grok,
            title: "Destination",
            handoff: handoff,
            id: destinationID
        )
        try ConversationHandoffStore.save(
            snapshot: ConversationHandoffSnapshot(
                sourceProvider: "OpenCode",
                sourceTitle: "Source",
                wasTruncated: false,
                segments: ["[USER]\nKeep the parser lossless."]
            ),
            for: destinationID
        )
        addTeardownBlock { ConversationHandoffStore.remove(for: destinationID) }

        let prompt = try XCTUnwrap(ConversationContinuation.openingPrompt(for: session))
        XCTAssertTrue(prompt.contains("<conversation_history>"), prompt)
        XCTAssertTrue(prompt.contains("Keep the parser lossless."), prompt)
        XCTAssertFalse(prompt.contains("conversation_history`"), prompt)
    }

    func testHandoffStoreCopiesAndRemovesTheFrozenTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-handoff-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source.jsonl")
        let sessionID = SessionID()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one frozen record\n".utf8).write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try ConversationHandoffStore.save(
            sourceTranscript: source,
            for: sessionID,
            rootDirectory: root
        )
        let snapshot = ConversationHandoffStore.url(
            for: sessionID,
            rootDirectory: root
        )
        XCTAssertEqual(try Data(contentsOf: snapshot), Data("one frozen record\n".utf8))

        ConversationHandoffStore.remove(for: sessionID, rootDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
    }

    func testHistoryPageIsNormalisedScopedAndPaginated() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/claude-tools-and-thinking.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path))

        let first = try ConversationHistoryPage.render(
            transcriptURL: fixture,
            sourceKind: .claude,
            sourceTitle: "Fixture",
            cursor: nil,
            pageCharacterLimit: 5_000
        ).get()
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        )
        let history = try XCTUnwrap(payload["history"] as? String)
        let next = try XCTUnwrap(payload["next_cursor"] as? String)

        XCTAssertEqual(payload["source_provider"] as? String, AgentKind.claude.displayName)
        XCTAssertTrue(history.contains("<conversation_history>"))
        XCTAssertTrue(history.contains("[ASSISTANT"))
        XCTAssertFalse(
            history.contains("\"signature\""),
            "private thinking envelopes crossed the handoff boundary"
        )

        let second = try ConversationHistoryPage.render(
            transcriptURL: fixture,
            sourceKind: .claude,
            sourceTitle: "Fixture",
            cursor: next,
            pageCharacterLimit: 5_000
        ).get()
        XCTAssertNotEqual(first, second)
    }

    func testNormalisedSnapshotRoundTripsAndPaginatesWithoutProviderFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-normalised-handoff-\(UUID().uuidString)")
        let sessionID = SessionID()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let snapshot = ConversationHandoffSnapshot(
            sourceProvider: "OpenCode",
            sourceTitle: "Portable",
            wasTruncated: true,
            segments: ["[USER]\none", "[ASSISTANT]\ntwo"]
        )
        try ConversationHandoffStore.save(
            snapshot: snapshot,
            for: sessionID,
            rootDirectory: root
        )
        let url = ConversationHandoffStore.url(for: sessionID, rootDirectory: root)
        XCTAssertEqual(
            try ConversationHandoffStore.loadSnapshot(
                at: url,
                legacySourceKind: nil,
                legacySourceTitle: ""
            ),
            snapshot
        )

        let first = try ConversationHistoryPage.render(
            snapshotURL: url,
            legacySourceKind: nil,
            legacySourceTitle: "",
            cursor: nil,
            pageCharacterLimit: 1
        ).get()
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["source_provider"] as? String, "OpenCode")
        XCTAssertEqual(payload["replay_window_truncated"] as? Bool, true)
        XCTAssertEqual(payload["next_cursor"] as? String, "1")
    }

    func testHandoffSnapshotsRefuseOversizedWritesAndReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-bounded-handoff-\(UUID().uuidString)")
        let writeID = SessionID()
        let readID = SessionID()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let oversized = String(
            repeating: "x",
            count: ConversationHandoffStore.maximumSnapshotBytes
        )
        XCTAssertThrowsError(
            try ConversationHandoffStore.save(
                snapshot: ConversationHandoffSnapshot(
                    sourceProvider: "Fixture",
                    sourceTitle: "Oversized",
                    wasTruncated: false,
                    segments: [oversized]
                ),
                for: writeID,
                rootDirectory: root
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ConversationHandoffStore.url(for: writeID, rootDirectory: root).path
        ))

        let readURL = ConversationHandoffStore.url(for: readID, rootDirectory: root)
        try FileManager.default.createDirectory(
            at: readURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: readURL.path, contents: Data())
        let handle = try FileHandle(forWritingTo: readURL)
        try handle.truncate(
            atOffset: UInt64(ConversationHandoffStore.maximumSnapshotBytes + 1)
        )
        try handle.close()

        XCTAssertThrowsError(
            try ConversationHandoffStore.loadSnapshot(
                at: readURL,
                legacySourceKind: nil,
                legacySourceTitle: ""
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large"), "\(error)")
        }
    }

    func testOpenCodeExportKeepsVisibleContextAndDropsReasoning() throws {
        let export: [String: Any] = [
            "info": ["id": "session"],
            "messages": [
                [
                    "info": ["role": "user"],
                    "parts": [["type": "text", "text": "Question"]]
                ],
                [
                    "info": ["role": "assistant"],
                    "parts": [
                        ["type": "reasoning", "text": "private chain"],
                        ["type": "text", "text": "Answer"],
                        [
                            "type": "tool",
                            "tool": "read",
                            "state": ["input": ["path": "README"], "output": "contents"]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: export)
        let history = try ConversationHandoffCapture.openCodeSegments(from: data)
            .joined(separator: "\n")

        XCTAssertTrue(history.contains("[USER]\nQuestion"), history)
        XCTAssertTrue(history.contains("[ASSISTANT]\nAnswer"), history)
        XCTAssertTrue(history.contains("ASSISTANT TOOL CALL: read"), history)
        XCTAssertTrue(history.contains("[TOOL RESULT]\ncontents"), history)
        XCTAssertFalse(history.contains("private chain"), history)
    }

    func testRepeatedHandoffDoesNotDuplicateItsHistoryTransport() {
        let events: [StreamEvent] = [
            .userMessage("Threading cross-provider continuation bootstrap"),
            .assistantMessage(blocks: [
                .toolUse(
                    id: "history",
                    tool: .mcp("mcp__threading__conversation_history"),
                    input: [:]
                )
            ]),
            .toolResults([ToolResult(
                toolUseID: "history",
                text: "<conversation_history>old turn</conversation_history>",
                isError: false
            )]),
            .userMessage("New question"),
            .assistantMessage(blocks: [.text("New answer")])
        ]

        let history = ConversationHistoryPage.continuationSegments(from: events)
            .joined(separator: "\n")
        XCTAssertFalse(history.contains("bootstrap"), history)
        XCTAssertFalse(history.contains("old turn"), history)
        XCTAssertTrue(history.contains("New question"), history)
        XCTAssertTrue(history.contains("New answer"), history)
    }

    func testHandoffPresentationKeepsOriginAndNewestStops() throws {
        let kinds: [AgentKind] = [.claude, .codex, .grok, .openCode, .claude]
        let endpoints = kinds.enumerated().map { index, kind in
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: kind,
                model: "model-\(index)",
                title: nil
            )
        }
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: endpoints))
        let presentation = ConversationHandoffPresentation(handoff: handoff)

        XCTAssertEqual(presentation.endpoints.map(\.sessionID), [
            endpoints[0].sessionID,
            endpoints[3].sessionID,
            endpoints[4].sessionID
        ])
        XCTAssertEqual(presentation.omittedEndpointCount, 2)
        XCTAssertTrue(presentation.compactPath.contains("+2"))
        XCTAssertTrue(presentation.spokenPath.contains("2 earlier stops omitted"))
    }

    func testHandoffTargetModelSettlesOnTheFirstRuntimeReport() throws {
        var handoff = try XCTUnwrap(ConversationHandoff(endpoints: [
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .claude,
                model: "claude-sonnet-4-5",
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .codex,
                model: "account-default",
                title: nil,
                modelIsProvisional: true
            )
        ]))

        handoff.recordTargetModel("gpt-5.6-sol")
        handoff.recordTargetModel("later-resume-model")
        XCTAssertEqual(handoff.target?.model, "gpt-5.6-sol")
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

@MainActor
final class SessionCoordinatorTests: XCTestCase {

    func testRetainsTheApplicationServicesInjectedAtItsOwnershipBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionCoordinatorTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let suite = "SessionCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let projectStore = ProjectStore(
            stateManager: StateManager(appSupportDirectory: directory)
        )
        let agentRuntime = AgentRuntime()
        let settings = AppSettings(defaults: defaults)
        let eventLog = EventLog(directory: directory.appendingPathComponent("Logs"))
        let environment = AppEnvironment(
            projectStore: projectStore,
            agentRuntime: agentRuntime,
            settings: settings,
            eventLog: eventLog
        )
        let sidebar = ProjectSidebarViewController(projectStore: projectStore)
        let coordinator = SessionCoordinator(
            sidebar: sidebar,
            container: TerminalContainerViewController(recovery: false),
            environment: environment,
            onPresentationChanged: {}
        )

        XCTAssertTrue(coordinator.environment.projectStore === projectStore)
        XCTAssertTrue(coordinator.environment.agentRuntime === agentRuntime)
        XCTAssertTrue(coordinator.environment.settings === settings)
        XCTAssertTrue(coordinator.environment.eventLog === eventLog)
        XCTAssertTrue(coordinator.sidebar.projectStore === projectStore)
    }

    func testReusableOpeningMessageFollowsThePerChatTask() {
        XCTAssertEqual(
            NewChatOpeningMessage.compose(
                prompt: "  Fix the flaky test.\n",
                reusableMessage: "\nRename this chat to one uppercase word.  "
            ),
            "Fix the flaky test.\n\nRename this chat to one uppercase word."
        )
    }

    func testReusableOpeningMessageCanOpenAnOtherwiseEmptyChat() {
        XCTAssertEqual(
            NewChatOpeningMessage.compose(
                prompt: " \n ",
                reusableMessage: "Rename this chat."
            ),
            "Rename this chat."
        )
        XCTAssertNil(
            NewChatOpeningMessage.compose(prompt: nil, reusableMessage: " \n ")
        )
    }

    func testNewChatOpeningMessagePersistsVerbatimAndCanBeCleared() {
        let suite = "SessionCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let message = "Use one word.\nKEEP IT UPPERCASE."
        AppSettings(defaults: defaults).newChatOpeningMessage = message
        XCTAssertEqual(AppSettings(defaults: defaults).newChatOpeningMessage, message)

        AppSettings(defaults: defaults).newChatOpeningMessage = ""
        XCTAssertEqual(AppSettings(defaults: defaults).newChatOpeningMessage, "")
    }

    func testBranchTargetsItsExistingCheckout() {
        let original = ProjectID()
        let checkout = ProjectID()

        let resolved = SessionCoordinator.targetProjectID(
            startingAt: original,
            branch: "feature/safe-coordinator"
        ) { branch, repositoryProjectID in
            XCTAssertEqual(branch, "feature/safe-coordinator")
            XCTAssertEqual(repositoryProjectID, original)
            return checkout
        }

        XCTAssertEqual(resolved, checkout)
    }

    func testMissingCheckoutFallsBackToComposerProject() {
        let original = ProjectID()
        let resolved = SessionCoordinator.targetProjectID(
            startingAt: original,
            branch: "deleted-branch"
        ) { _, _ in nil }

        XCTAssertEqual(resolved, original)
    }
}

final class ShellCommandTests: XCTestCase {

    /// Values representative of every dynamic launch field. Running them through a real shell
    /// proves they remain one argument; merely comparing quote characters would test the
    /// implementation rather than the safety property.
    func testHostileWordsRoundTripThroughShell() throws {
        let hostileWords = [
            "'; rm -rf ~'",
            "feature/one && touch /tmp/threading-injection",
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
