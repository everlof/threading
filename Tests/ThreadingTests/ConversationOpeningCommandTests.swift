import XCTest
@testable import Threading

/// The start composer crosses from a process-free draft into a live native transport. A slash
/// command at that seam must take the same semantic route as one typed after the chat appears.
@MainActor
final class ConversationOpeningCommandTests: HostedStoreTestCase {
    func testCodexOpeningReviewWaitsForTheCatalogAndUsesReviewStart() throws {
        try verifyAdmission(queued: false)
    }

    func testQueuedPromptRecordsWorkOnlyWhenTheTransportAcceptsIt() throws {
        try verifyAdmission(queued: true)
    }

    private func verifyAdmission(queued: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-opening-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try GitProcess.run(["init", "--quiet"], in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let capture = directory.appendingPathComponent("requests.jsonl")
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true,
            title: "Opening review"
        ))
        XCTAssertTrue(store.update(sessionID: session.id) {
            // This fixture owns the shell process it records. Do not inherit the developer's
            // background-host choice and silently turn the fixture into a daemon integration.
            $0.backgroundHost = false
        }.succeeded)
        let workingDirectory = session.workingDirectory(in: project)
        let script =
            "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                + "read -r initialized; read -r open_thread; "
                + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{"
                + "\"id\":\"thread-opening\",\"model\":\"gpt-test\"}}}'; "
                + "read -r skills; printf '%s\\n' \"$skills\" >> '\(capture.path)'; "
                + "printf '%s\\n' '{\"id\":3,\"result\":{\"data\":[{"
                + "\"cwd\":\"\(workingDirectory)\",\"errors\":[],\"skills\":[]}]}}'; "
                + "read -r review; "
                + "printf '%s\\n' \"$review\" >> '\(capture.path)'; "
                + "printf '%s\\n' '{\"id\":4,\"result\":{\"turn\":{"
                + "\"id\":\"review-turn\"}}}'; "
                + "printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{"
                + "\"threadId\":\"thread-opening\",\"turn\":{\"id\":\"review-turn\","
                + "\"items\":[],\"status\":\"completed\"}}}'; cat >/dev/null"

        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session,
            project: project,
            currentSessionProjection: CurrentSessionProjection { sessionID in
                store.project(withID: project.id)?.sessions.first { $0.id == sessionID }
            },
            launchPlanProvider: { _, _, _ in
                AgentLaunchPlan(
                    executable: "/bin/sh",
                    arguments: ["-c", script],
                    resumeState: .unavailable
                )
            },
            customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        defer { controller.terminate(preservingViewport: false) }

        var workEdges: [SessionWorkDidChange.Kind] = []
        let events = AppEventObservations()
        events.observe(SessionWorkDidChange.self) { event in
            if event.sessionID == session.id { workEdges.append(event.kind) }
        }
        if queued {
            XCTAssertTrue(controller.enqueue(ConversationPrompt(text: "Queued work")))
            XCTAssertNil(store.session(withID: session.id)?.lastTurnAt)
        }
        controller.launch()
        if !queued { controller.sendInitialPrompt("/review focus on authentication") }

        let expectedMethod = queued ? "turn/start" : "review/start"
        let didStartReview = waitUntil {
            self.recordedMethods(in: capture).contains(expectedMethod)
        }
        let capturedRequests = try String(contentsOf: capture, encoding: .utf8)
        XCTAssertTrue(
            didStartReview,
            "the opening command never reached Codex's semantic review endpoint; received \(capturedRequests)"
        )

        let lines = capturedRequests
            .split(separator: "\n")
            .map(String.init)
        let requests = try lines.map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
        let review = try XCTUnwrap(requests.first {
            $0["method"] as? String == expectedMethod
        })
        let parameters = try XCTUnwrap(review["params"] as? [String: Any])
        if !queued {
            let target = try XCTUnwrap(parameters["target"] as? [String: Any])
            XCTAssertEqual(target["type"] as? String, "custom")
            XCTAssertEqual(target["instructions"] as? String, "focus on authentication")
            XCTAssertFalse(requests.contains { $0["method"] as? String == "turn/start" })
        }
        XCTAssertTrue(waitUntil { controller.stream.canSend })
        XCTAssertTrue(waitUntil {
            GitTurnBaselineStore.shared.latestCheckpoint(forSessionID: session.id)?.status
                == .complete
        })

        let finished = try XCTUnwrap(store.session(withID: session.id))
        let startedAt = try XCTUnwrap(finished.lastTurnAt)
        XCTAssertGreaterThan(try XCTUnwrap(finished.lastWorkAt), startedAt)
        XCTAssertEqual(workEdges, [.turnStarted, .turnEnded])
        withExtendedLifetime(events) {}
        controller.terminate(preservingViewport: false)
        XCTAssertEqual(store.removeSession(id: session.id), .applied)
        XCTAssertTrue(waitUntil {
            GitTurnBaselineStore.shared.checkpoints(forSessionID: session.id).isEmpty
        })
    }

    func testOpeningCommandReturnsToTheDraftIfTheAgentExitsBeforeItsCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-opening-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true,
            title: "Failed opening command"
        ))
        XCTAssertTrue(store.update(sessionID: session.id) {
            // The expected exit belongs to the local fixture process, not to threading-ptyd.
            $0.backgroundHost = false
        }.succeeded)
        let controller = try XCTUnwrap(ConversationViewController(
            agentSession: session,
            project: project,
            currentSessionProjection: CurrentSessionProjection { sessionID in
                store.project(withID: project.id)?.sessions.first { $0.id == sessionID }
            },
            launchPlanProvider: { _, _, _ in
                AgentLaunchPlan(
                    executable: "/bin/sh",
                    arguments: ["-c", "/bin/sleep 0.2; exit 9"],
                    resumeState: .unavailable
                )
            },
            customizationLookup: { _ in .empty }
        ))
        _ = controller.view
        defer {
            controller.terminate(preservingViewport: false)
            SessionContinuityStore.shared.setConversationDraft("", for: session.id)
            _ = store.removeSession(id: session.id)
        }

        controller.launch()
        XCTAssertTrue(waitUntil { controller.stream.isRunning })
        controller.sendInitialPrompt("/review focus on authentication")
        controller.promptView.stringValue = "Keep the draft I started while this was booting."

        XCTAssertTrue(waitUntil { !controller.stream.isRunning }, "the fixture process did not exit")
        let restored = "/review focus on authentication\n\n"
            + "Keep the draft I started while this was booting."
        XCTAssertEqual(controller.promptView.stringValue, restored)
        XCTAssertNil(store.session(withID: session.id)?.lastTurnAt)
        XCTAssertNil(store.session(withID: session.id)?.lastWorkAt)
        XCTAssertEqual(
            SessionContinuityStore.shared.state(for: session.id).conversationDraft,
            restored,
            "the recovered opening message would be lost when the failed surface is discarded"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func recordedMethods(in file: URL) -> [String] {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let request = object as? [String: Any] else { return nil }
            return request["method"] as? String
        }
    }
}
