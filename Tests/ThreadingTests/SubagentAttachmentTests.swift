import AppKit
import XCTest
@testable import Threading

@MainActor
final class SubagentAttachmentTests: HostedStoreTestCase {
    private var root: URL!
    private var payloads: [SessionID: String] = [:]
    private var allowsOutside = false

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func store() -> SessionAttachmentStore {
        SessionAttachmentStore(
            loadPayload: { [weak self] in self?.payloads[$0] },
            savePayload: { [weak self] in self?.payloads[$1] = $0 },
            copiesDirectory: { [root] in root!.appendingPathComponent("custody") },
            referenceRoot: { [root] _ in root },
            allowsFilesOutsideProject: { [weak self] in self?.allowsOutside ?? false }
        )
    }

    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func record(_ texts: [String], source: AttachmentAgentSource = .main,
                        session: SessionID, store: SessionAttachmentStore, turn: String? = nil) async {
        await AttachmentDetection.record(
            texts: texts, sessionID: session, projectRoot: root,
            context: .init(sources: [source], turnID: turn), store: store,
            shouldAdmit: { true }
        )
    }

    func testParentAndChildShareDetectionDeduplicationAndPersistedAttribution() async throws {
        let session = SessionID()
        let store = store()
        let image = try file("render with spaces.png")
        let child = AttachmentAgentSource(threadID: "child-1", name: "Review match screen")
        let prose = "See [result](\(image.path))"
        await record([prose], source: child, session: session, store: store, turn: "parent-turn")
        let first = try XCTUnwrap(store.attachments(for: session).first)
        XCTAssertFalse(AttachmentFilter.agent.admits(first))
        XCTAssertTrue(AttachmentFilter.subagents.admits(first))
        await record([prose], session: session, store: store)
        await record([prose], source: child, session: session, store: store, turn: "parent-turn")
        let rows = store.attachments(for: session)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, first.id)
        XCTAssertEqual(rows.first?.turnID, "parent-turn")
        XCTAssertEqual(rows.first?.agentSources, [.main, child])
        XCTAssertTrue(AttachmentFilter.agent.admits(rows[0]))
        XCTAssertTrue(AttachmentFilter.subagents.admits(rows[0]))
        XCTAssertEqual(self.store().attachments(for: session), rows)
    }

    func testUserHandoffKeepsItsOriginAndTurnWhenAChildReferencesIt() async throws {
        let session = SessionID()
        let store = store()
        let image = try file("sent.png")
        let handed = try XCTUnwrap(store.record(declared: image, sessionID: session,
                                               projectRoot: root, origin: .user,
                                               turnID: "user-turn", turnPlacement: .next))
        await record([image.path], source: .init(threadID: "child", name: "Review"),
                     session: session, store: store, turn: "child-turn")
        let row = try XCTUnwrap(store.attachments(for: session).first)
        XCTAssertEqual(row.id, handed.id)
        XCTAssertEqual(row.origin, .user)
        XCTAssertEqual(row.turnID, "user-turn")
        XCTAssertTrue(AttachmentFilter.user.admits(row))
        XCTAssertTrue(AttachmentFilter.subagents.admits(row))
        XCTAssertFalse(AttachmentFilter.agent.admits(row))
    }

    func testWithheldChildReferencesKeepAttributionWhenScopeWidens() async throws {
        let session = SessionID()
        let store = store()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("child-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        let child = AttachmentAgentSource(threadID: "child", name: "Screenshot review")
        await record([outside.path], source: child, session: session, store: store, turn: "delegated-turn")
        await record([outside.path], source: child, session: session, store: store, turn: "delegated-turn")
        XCTAssertTrue(store.attachments(for: session).isEmpty)
        XCTAssertEqual(store.withheldReferences(for: session).count, 1)
        allowsOutside = true
        _ = await store.admitWithheldFilesOutsideProjectAsync(for: session)
        let row = try XCTUnwrap(store.attachments(for: session).first)
        XCTAssertEqual(row.agentSources, [child])
        XCTAssertEqual(row.turnID, "delegated-turn")
        XCTAssertTrue(row.isOutsideProject)
        XCTAssertNotEqual(row.url, outside)
        allowsOutside = false
        XCTAssertTrue(store.attachments(for: session).isEmpty)
    }

    func testSharedContentPolicyExcludesThinkingAndToolPathsForMainAndChild() async throws {
        let delivered = try file("delivered.png")
        let incidental = try file("incidental.png")
        let record: [String: Any] = ["type": "assistant", "isSidechain": true,
            "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": incidental.path],
                ["type": "tool_use", "id": "read", "name": "Read", "input": ["file_path": incidental.path]],
                ["type": "text", "text": delivered.path]
            ]]]
        XCTAssertNil(TranscriptReplay.claudeEvent(from: record))
        let event = try XCTUnwrap(TranscriptReplay.claudeEvent(from: record, scope: .child))
        XCTAssertEqual(AttachmentDetection.assistantTexts(in: event), [delivered.path])
        for source in [AttachmentAgentSource.main, .init(threadID: "child", name: "Review")] {
            let session = SessionID()
            let store = store()
            await self.record(AttachmentDetection.assistantTexts(in: event), source: source,
                              session: session, store: store)
            XCTAssertEqual(store.attachments(for: session).map(\.name), ["delivered.png"])
        }
    }

    func testLiveAndTerminalChildrenUseTheSharedDetectorWithoutOpeningTheirPane() async throws {
        for kind in [AgentKind.claude, .codex] {
            let image = try file("\(kind.rawValue).png")
            let session = SessionID()
            let store = store()
            let state = SubagentSessionState(sessionID: session)
            let observation = SubagentAttachmentObserver(sessionID: session, store: store,
                configuration: { .init(kind: kind, projectRoot: self.root) },
                currentTurnID: { "parent-turn" }, isEnabled: { true })
            state.attachmentObserver = observation
            defer { state.invalidate() }
            state.apply(.discovered(.init(threadID: "child", nickname: "Render result")))
            state.apply(.conversation(threadID: "child", event: .assistantMessage(blocks: [.text(image.path)])))
            try await eventually { !store.attachments(for: session).isEmpty }
            XCTAssertEqual(store.attachments(for: session).first?.agentSources.first?.threadID, "child")
            XCTAssertEqual(store.attachments(for: session).first?.turnID, "parent-turn")

            let transcript = root.appendingPathComponent("\(kind.rawValue).jsonl")
            let terminalSession = SessionID()
            let observer = TerminalTranscriptAttachmentObserver(
                sessionID: terminalSession, kind: kind, projectRoot: { self.root },
                currentDirectory: { nil }, transcriptURL: { transcript },
                context: { .init(sources: [.init(threadID: "terminal-child", name: "Capture")]) },
                isChild: true, store: store
            )
            defer { observer.invalidate() }
            observer.noteTurnFinished()
            // The hook may precede the writer. The ordinary stability retries must cover children.
            try await Task.sleep(nanoseconds: 100_000_000)
            let row: [String: Any] = kind == .claude
                ? ["type": "assistant", "isSidechain": true,
                   "message": ["role": "assistant", "content": [["type": "text", "text": image.path]]]]
                : ["type": "event_msg", "payload": ["type": "agent_message", "message": image.path]]
            var bytes = try JSONSerialization.data(withJSONObject: row)
            bytes.append(10)
            try bytes.write(to: transcript)
            try await eventually { !store.attachments(for: terminalSession).isEmpty }
            XCTAssertEqual(store.attachments(for: terminalSession).first?.agentSources.first?.threadID, "terminal-child")
        }
    }

    func testSubagentFilterAppearsOnFirstChildAndSurvivesCompletionWithoutFiles() throws {
        let session = SessionID()
        let state = SubagentSessionState(sessionID: session)
        let pane = SessionAttachmentsViewController(sessionID: session, hasSubagents: { state.timeline.hasAgents })
        _ = pane.view
        pane.refresh()
        XCTAssertFalse(pane.attachmentFilterControl.titles.contains("Subagents"))
        state.apply(.discovered(.init(threadID: "child", nickname: "Review")))
        XCTAssertTrue(pane.attachmentFilterControl.titles.contains("Subagents"))
        XCTAssertFalse(pane.attachmentFilterControl.isHidden)
        state.apply(.state(threadID: "child", status: .completed, message: nil))
        pane.refresh()
        XCTAssertTrue(pane.attachmentFilterControl.titles.contains("Subagents"))
        pane.attachmentFilterControl.onSelect?(2)
        XCTAssertEqual(pane.attachmentFilterControl.selectedIndex, 2)
        XCTAssertTrue(labels(pane.view).contains { $0.stringValue == "Nothing here from Subagents." })
        state.invalidate()
    }

    func testCodexChildStopsBeforeInheritedParentOutputAndUnchangedPollSkipsParsing() async throws {
        let image = try file("parent.png")
        let transcript = root.appendingPathComponent("child.jsonl")
        let inherited: [[String: Any]] = [
            ["type": "event_msg", "payload": ["type": "agent_message", "message": image.path]],
            ["type": "inter_agent_communication_metadata", "payload": [:]]
        ]
        try inherited.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n").appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptReplay.latestAssistantTexts(at: transcript, kind: .codex,
                       scanLimit: TranscriptAttachmentDefaults.transcriptScanBytes, isChild: true), [])
        let worker = AttachmentDetectionWorker()
        let first = await worker.transcriptReferences(at: transcript, lookup: nil, kind: .codex,
            isChild: true, lastAssistantMessage: nil, projectRoot: root, currentDirectory: nil)
        let second = await worker.transcriptReferences(at: transcript, lookup: nil, kind: .codex,
            isChild: true, lastAssistantMessage: nil, projectRoot: root, currentDirectory: nil,
            previousSignature: first.signature)
        XCTAssertTrue(first.didReadTranscript)
        XCTAssertFalse(second.didReadTranscript)
    }

    func testDisabledAndInvalidatedChildWorkCannotAdmitFiles() async throws {
        let image = try file("child.png")
        let session = SessionID()
        let store = store()
        let state = SubagentSessionState(sessionID: session)
        var enabled = false
        state.attachmentObserver = SubagentAttachmentObserver(sessionID: session, store: store,
            configuration: { .init(kind: .claude, projectRoot: self.root) },
            currentTurnID: { nil }, isEnabled: { enabled })
        state.apply(.discovered(.init(threadID: "child")))
        state.apply(.conversation(threadID: "child", event: .assistantMessage(blocks: [.text(image.path)])))
        enabled = true
        state.apply(.conversation(threadID: "child", event: .assistantMessage(blocks: [.text(image.path)])))
        state.invalidate()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(store.attachments(for: session).isEmpty)
    }

    func testStressSixtyFourChildrenShareOneBoundedFileHistoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_SUBAGENT_ATTACHMENT_STRESS"] == "1" else {
            throw XCTSkip("Opt-in attachment cardinality fixture")
        }
        let session = SessionID()
        let store = store()
        let image = try file("shared.png")
        let state = SubagentSessionState(sessionID: session)
        state.attachmentObserver = SubagentAttachmentObserver(sessionID: session, store: store,
            configuration: { .init(kind: .codex, projectRoot: self.root) },
            currentTurnID: { "parent-turn" }, isEnabled: { true })
        defer { state.invalidate() }
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<64 {
            let id = "child-\(index)"
            state.apply(.discovered(.init(threadID: id, nickname: "Review \(index)")))
            state.apply(.conversation(threadID: id, event: .assistantMessage(blocks: [.text(image.path)])))
        }
        let enqueueEnded = DispatchTime.now().uptimeNanoseconds
        try await eventually { store.attachments(for: session).first?.agentSources.count == 64 }
        let finished = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(store.attachments(for: session).count, 1)
        print("SUBAGENT_ATTACHMENTS children=64 rows=1 enqueue_ms=\(Double(enqueueEnded - started) / 1_000_000) settle_ms=\(Double(finished - started) / 1_000_000)")
    }

    func testRendersSubagentAttachmentsInShippingShell() async throws {
        let previousStore = SessionAttachmentStore.shared
        SessionAttachmentStore.shared = SessionAttachmentStore(
            now: { Date(timeIntervalSince1970: 1_791_540_000) },
            copiesDirectory: { self.root.appendingPathComponent("render-custody") },
            referenceRoot: { _ in self.root }
        )
        defer { SessionAttachmentStore.shared = previousStore }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        _ = ProjectStore.shared.renameProject(id: project.id, to: "Attachment review")
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex,
                                     usesNativeUI: true, title: "Subagent attachments"))
        let store = SessionAttachmentStore.shared
        let child = AttachmentAgentSource(threadID: "child-review", name: "Review match screen")
        let names = ["Main comparison.png", "Child screenshots.png", "Shared result.png", "Your reference.png"]
        let files = try names.map { name -> URL in
            let url = root.appendingPathComponent(name)
            let image = NSImage(size: NSSize(width: 320, height: 200))
            image.lockFocus()
            NSColor.systemPurple.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 200)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 240, height: 120), xRadius: 12, yRadius: 12).fill()
            image.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let shell = makeMainWindowController()
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1400, height: 900))
        shell.displayPaneController.showSession(session.id)
        shell.setDisplayPaneVisible(true, animated: false, remembersSessionChoice: false)
        let pane = try XCTUnwrap(shell.displayPaneController.activateAttachments(for: session.id))
        let content = try XCTUnwrap(window.contentView)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(.system)
        window.appearance = NSAppearance(named: .aqua)
        AppThemeRefresh.repaint(content)
        pane.refresh()
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.attachmentFilterControl.titles.contains("Subagents"))
        try capture(shell.displayPaneController.view, to: output.appendingPathComponent("attachment-subagents-before-delegation.png"))
        let state = AgentRuntime.shared.subagentState(for: session.id)
        state.apply(.discovered(.init(threadID: "child-review", nickname: "Review match screen")))
        state.apply(.state(threadID: "child-review", status: .completed, message: nil))
        pane.attachmentFilterControl.onSelect?(2)
        content.layoutSubtreeIfNeeded()
        try capture(shell.displayPaneController.view, to: output.appendingPathComponent("attachment-subagents-empty-completed.png"))
        pane.attachmentFilterControl.onSelect?(0)
        await record([files[0].absoluteString], session: session.id, store: store)
        await record([files[1].absoluteString, files[2].absoluteString], source: child, session: session.id, store: store)
        await record([files[2].absoluteString], session: session.id, store: store)
        _ = store.record(declared: files[3], sessionID: session.id, projectRoot: root, origin: .user)
        for (name, theme, appearance) in [
            ("system-light", AppTheme.system, NSAppearance.Name.aqua),
            ("system-dark", AppTheme.system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("win98", AppThemeStyles.win98, .aqua)
        ] {
            AppThemePalette.set(theme)
            window.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            pane.refresh()
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(pane.attachmentFilterControl.titles, ["All", "Main agent", "Subagents", "You"])
            for label in labels(pane.attachmentFilterControl) {
                XCTAssertGreaterThanOrEqual(label.bounds.width + 1, label.intrinsicContentSize.width,
                                           "Clipped filter: \(label.stringValue), \(name)")
            }
            try capture(shell.displayPaneController.view, to: output.appendingPathComponent("attachment-subagents-\(name).png"))
        }
        pane.attachmentFilterControl.onSelect?(2)
        content.layoutSubtreeIfNeeded()
        try capture(content, to: output.appendingPathComponent("attachment-subagents-shell.png"))
        XCTAssertFalse(window.isVisible)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate())
    }

    private func labels(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels)
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
