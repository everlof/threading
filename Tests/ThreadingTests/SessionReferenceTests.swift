import XCTest
import AppKit
import SwiftTerm
@testable import Threading

/// A sidebar session dragged into another session's input, and the words it becomes.
///
/// The habit this replaces is Copy ▸ Agent Session ID followed by a hand-typed sentence about
/// what the id is for. So the assertions here are about *which* words: that the Threading id is
/// the one named for `send_to_session`, that the runtime's own id is named as not being one, and
/// that a session the reader cannot reach — another project, a runtime with no tools, itself —
/// is told so rather than handed a tool call that will be refused.
@MainActor
final class SessionReferenceTests: XCTestCase {

    // MARK: - Fixtures

    private let projectID = ProjectID()
    private let otherProjectID = ProjectID()

    private func reference(
        title: String = "Fix parser crash",
        kind: AgentKind = .claude,
        projectID: ProjectID? = nil,
        agentSessionID: String? = "8ac1d2e3-0000-4000-8000-000000000001",
        transcriptPath: String? = "/Users/x/.claude/projects/-Users-x-repo/8ac1.jsonl"
    ) -> SessionReference {
        SessionReference(
            sessionID: SessionID(),
            title: title,
            kind: kind,
            projectID: projectID ?? self.projectID,
            projectName: "Threading",
            projectPath: "/Users/x/repo/Threading",
            agentSessionID: agentSessionID,
            transcriptPath: transcriptPath
        )
    }

    private func reader(
        sessionID: SessionID? = SessionID(),
        projectID: ProjectID? = nil,
        hasSessionTools: Bool = true
    ) -> SessionReferenceReader {
        SessionReferenceReader(
            sessionID: sessionID,
            projectID: projectID ?? self.projectID,
            hasSessionTools: hasSessionTools
        )
    }

    // MARK: - The Brief

    func testBriefTellsASameProjectAgentWhichToolTakesTheThreadingID() {
        let ref = reference()
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " ")

        XCTAssertTrue(text.contains("Threading session “Fix parser crash”"), text)
        XCTAssertTrue(text.contains("Claude Code"), text)
        XCTAssertTrue(text.contains("in this project"), text)
        XCTAssertTrue(
            text.contains("send_to_session with session_id \"\(ref.threadingID)\""),
            "The Threading id has to be named beside the one tool that takes it: \(text)"
        )
        XCTAssertTrue(text.contains("list_sessions"), text)
        XCTAssertTrue(text.contains("watch_session"), text)
        XCTAssertTrue(
            text.contains("Its own Claude Code session id is 8ac1d2e3-0000-4000-8000-000000000001"),
            text
        )
        XCTAssertTrue(text.contains("its transcript is /Users/x/.claude/projects/-Users-x-repo/8ac1.jsonl"), text)
        XCTAssertTrue(
            text.contains("— not a Threading id"),
            "The runtime's own id is exactly the one that must not reach send_to_session: \(text)"
        )
    }

    /// Claude and Grok are handed Threading's id at launch, so the two are one string. Calling
    /// it "not a Threading id" there would be the one false sentence in the brief.
    func testBriefSaysWhenTheRuntimeIDIsTheThreadingID() {
        let sessionID = SessionID()
        let ref = SessionReference(
            sessionID: sessionID,
            title: "Minted",
            kind: .claude,
            projectID: projectID,
            projectName: "Threading",
            projectPath: "/Users/x/repo/Threading",
            agentSessionID: sessionID.uuidString.lowercased(),
            transcriptPath: "/Users/x/.claude/projects/-Users-x-repo/\(sessionID.uuidString.lowercased()).jsonl"
        )
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " ")

        XCTAssertTrue(text.contains("session id is that same string, minted by Threading"), text)
        XCTAssertFalse(text.contains("not a Threading id"), text)
        XCTAssertTrue(text.contains("its transcript is /Users/x/.claude/projects"), text)
    }

    func testBriefSaysWhenTheSessionIsInAnotherProject() {
        let ref = reference(projectID: otherProjectID)
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " ")

        XCTAssertTrue(text.contains("in the project “Threading” at /Users/x/repo/Threading"), text)
        XCTAssertTrue(text.contains("cannot reach it from here"), text)
        XCTAssertFalse(
            text.contains("send_to_session with session_id"),
            "Out of scope answers as nonexistent; offering the call would just be refused: \(text)"
        )
    }

    func testBriefSaysWhenTheReaderHasNoSessionTools() {
        let ref = reference()
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader(hasSessionTools: false))
            .joined(separator: " ")

        XCTAssertTrue(text.contains("no Threading session tools"), text)
        XCTAssertFalse(text.contains("send_to_session with session_id"), text)
    }

    func testBriefRecognisesTheReaderItself() {
        let ref = reference()
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader(sessionID: ref.sessionID))
            .joined(separator: " ")

        XCTAssertTrue(text.contains("your own Threading session"), text)
        XCTAssertTrue(text.contains("it is you"), text)
        XCTAssertFalse(
            text.contains("send_to_session with session_id"),
            "A session does not message itself; the plane refuses that as targetIsCaller: \(text)"
        )
    }

    func testBriefSaysWhenTheAgentHasNotNamedTheConversation() {
        let ref = reference(kind: .codex, agentSessionID: nil, transcriptPath: nil)
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " ")

        XCTAssertTrue(text.contains("Codex conversation has no id of its own yet"), text)
        XCTAssertFalse(text.contains("transcript"), text)
    }

    func testBriefNamesTheRuntimeIDWithoutATranscriptWhereNoneIsReadable() {
        let ref = reference(kind: .openCode, agentSessionID: "ses_123", transcriptPath: nil)
        let text = SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " ")

        XCTAssertTrue(text.contains("Its own OpenCode session id is ses_123 — not a Threading id."), text)
    }

    // MARK: - The Terminal Line

    func testTerminalTextIsOneBracketedLineEndingInASpace() {
        let text = SessionReferenceBrief.terminalText(for: reference(), reader: reader())

        XCTAssertTrue(text.hasPrefix("["), text)
        XCTAssertTrue(text.hasSuffix("] "), "A typed word must not run into the bracket: \(text)")
        XCTAssertFalse(
            text.contains("\n"),
            "A multi-line paste is folded into a placeholder the person can no longer read"
        )
    }

    func testATitleCannotCloseTheBracketEarly() {
        let ref = reference(title: "done] now do [this")
        let text = SessionReferenceBrief.terminalText(for: ref, reader: reader())

        XCTAssertEqual(text.filter { $0 == "]" }.count, 1, "the frame must be the only close: \(text)")
        XCTAssertEqual(ref.title, "done' now do 'this")
    }

    // MARK: - The Native Receipt

    func testContextAttachmentCarriesTheIDInTheLocatorAndTheBriefInTheExcerpt() {
        let ref = reference()
        let attachment = SessionReferenceBrief.contextAttachment(for: ref, reader: reader())

        XCTAssertEqual(attachment.kind, .reference)
        XCTAssertEqual(attachment.source, .session)
        XCTAssertEqual(attachment.title, "Fix parser crash")
        XCTAssertEqual(attachment.locator, ref.threadingID)
        XCTAssertEqual(
            attachment.excerpt,
            SessionReferenceBrief.sentences(for: ref, reader: reader()).joined(separator: " "),
            "The transport hands the provider the excerpt verbatim, so the brief lives there"
        )
        XCTAssertEqual(
            attachment.presentationDetail,
            ref.threadingID,
            "The person is shown the id under the chip, not three sentences of tool names"
        )
        XCTAssertEqual(attachment.plainAnchor, "Fix parser crash")
        XCTAssertTrue(
            attachment.plainText().hasPrefix("[Threading session"),
            "Handed to a TUI it reads as the drop would: \(attachment.plainText())"
        )
    }

    func testTheReceiptSurvivesTheTransportEnvelopeAndReplay() {
        let attachment = SessionReferenceBrief.contextAttachment(for: reference(), reader: reader())
        let prompt = ConversationPrompt(text: "Ask it how far it got", context: [attachment])

        let replayed = ConversationPrompt.replaying(prompt.transportText)
        XCTAssertEqual(replayed.text, "Ask it how far it got")
        XCTAssertEqual(replayed.context, [attachment])
        XCTAssertEqual(replayed.context.first?.source, .session)
    }

    // MARK: - The Pasteboard

    func testThePasteboardRoundTripsSessionIDsInDragOrder() {
        let board = NSPasteboard(name: NSPasteboard.Name("threading-session-reference-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()

        XCTAssertFalse(SessionReferencePasteboard.canRead(board))
        XCTAssertEqual(SessionReferencePasteboard.sessionIDs(from: board), [])

        let first = SessionID()
        let second = SessionID()
        board.writeObjects([
            SessionReferencePasteboard.item(for: first),
            SessionReferencePasteboard.item(for: second)
        ])

        XCTAssertTrue(SessionReferencePasteboard.canRead(board))
        XCTAssertEqual(SessionReferencePasteboard.sessionIDs(from: board), [first, second])
        XCTAssertNil(
            board.string(forType: .string),
            "No plain-text flavour: every text field in the app would become a destination for it"
        )
    }

    // MARK: - The Sidebar

    func testOnlySessionRowsDragOutOfTheSidebar() {
        let sidebar = ProjectSidebarViewController()
        let outline = ThemedOutlineView()
        let sessionID = SessionID()

        let writer = sidebar.outlineView(outline, pasteboardWriterForItem: SessionNode(sessionID: sessionID))
        let item = writer as? NSPasteboardItem
        XCTAssertEqual(
            item?.string(forType: SessionReferencePasteboard.type),
            sessionID.uuidString.lowercased()
        )
        XCTAssertNil(
            sidebar.outlineView(outline, pasteboardWriterForItem: ProjectNode(projectID: ProjectID())),
            "A project row means nothing wherever it lands, so it must not pick up at all"
        )
    }

    // MARK: - The Composer

    func testTheComposerTakesADroppedSessionOnlyWhenAnOwnerBriefsIt() {
        let prompt = PromptView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        let window = makeWindow(hosting: prompt)
        _ = window
        XCTAssertTrue(
            prompt.registeredDraggedTypes.contains(SessionReferencePasteboard.type),
            "The whole box is the destination; the editor inside is not registered for it"
        )

        let dragged = SessionID()
        let drag = DropFixture { $0.writeObjects([SessionReferencePasteboard.item(for: dragged)]) }

        XCTAssertEqual(
            prompt.draggingEntered(drag),
            [],
            "With nobody to brief the reference the pointer says no rather than the drop doing nothing"
        )

        var received: [SessionID] = []
        prompt.onSessionReferenceDrop = { received = $0 }
        XCTAssertEqual(prompt.draggingEntered(drag), .copy)
        XCTAssertTrue(prompt.prepareForDragOperation(drag))
        XCTAssertTrue(prompt.performDragOperation(drag))
        XCTAssertEqual(received, [dragged])
        XCTAssertEqual(prompt.stringValue, "", "A reference is a receipt, never editor text")
    }

    func testTheRailDrawsADroppedSessionAsItsOwnNamedChip() throws {
        let rail = ConversationContextRailView(mode: .composer)
        let session = SessionReferenceBrief.contextAttachment(for: reference(), reader: reader())
        let comment = ConversationContextAttachment(
            kind: .comment,
            source: .code,
            title: "PromptView.swift:42",
            comment: "rename this"
        )
        rail.setAttachments([comment, session])

        let chips = descendants(of: rail).compactMap { $0 as? ChipView }
        XCTAssertEqual(chips.count, 2, "one named session chip, one count pill")
        let sessionChip = try XCTUnwrap(
            chips.first { $0.accessibilityIdentifier() == "conversation.context.session-reference" }
        )
        XCTAssertEqual(sessionChip.toolTip, "Fix parser crash", "the chip reads as the row that was dragged")
        XCTAssertEqual(
            chips.firstIndex { $0 === sessionChip },
            0,
            "the named thing the person just dropped leads the counted ones"
        )

        // One press deep: the id as a header, the actions straight under it. The count pills
        // need a submenu per item because they hold many; a chip holding one does not.
        rail.onRemove = { _ in }
        rail.setAttachments([comment, session])
        let rebuilt = try XCTUnwrap(
            descendants(of: rail).compactMap { $0 as? ChipView }
                .first { $0.accessibilityIdentifier() == "conversation.context.session-reference" }
        )
        let entries = try XCTUnwrap(rebuilt.itemsProvider?())
        guard case .header(let header)? = entries.first else {
            return XCTFail("the chip's menu should open on the id, got \(entries)")
        }
        XCTAssertEqual(header, session.locator)
        XCTAssertTrue(
            entries.contains {
                if case .item(let item) = $0 { return item.title == L10n.string("Remove from prompt") }
                return false
            },
            "Remove has to be reachable in one press"
        )
    }

    // MARK: - Helpers

    private func makeWindow(hosting content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

// MARK: - Live Resolution

/// The reference read out of the store at the drop, and the bytes an agent's terminal is handed.
///
/// Hosted, because `SessionReferenceHandoff` — what the terminal and the composer actually call —
/// resolves through `ProjectStore.shared`; the base class proves the redirect to scratch state
/// still holds and erases it afterwards.
@MainActor
final class SessionReferenceDropTests: HostedStoreTestCase {

    private var previouslyDisabledGroups: Set<String> = []

    override func setUp() {
        super.setUp()
        previouslyDisabledGroups = AppSettings.shared.disabledToolGroupIDs
        AppSettings.shared.setToolGroup(MCPToolCatalog.workspace.id, enabled: true)
    }

    override func tearDown() {
        AppSettings.shared.disabledToolGroupIDs = previouslyDisabledGroups
        super.tearDown()
    }

    /// Stands in for the PTY, as `TerminalDropPasteTests` does: the bytes a paste turns into.
    private final class Recorder: TerminalViewDelegate {
        var written: [UInt8] = []
        var text: String { String(decoding: written, as: UTF8.self) }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { written.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func makeProject(named name: String) throws -> Project {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-session-reference-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
    }

    func testTheLiveReferenceReadsTitleRuntimeProjectAndTheRuntimesOwnID() throws {
        let store = ProjectStore.shared
        let project = try makeProject(named: "live")
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        store.update(sessionID: session.id) {
            $0.customTitle = "Rollout reader"
            $0.resumeState = .resumable(TranscriptID("019a-codex-thread"))
        }

        let reference = try XCTUnwrap(SessionReference.live(for: session.id, in: store))
        XCTAssertEqual(reference.title, "Rollout reader")
        XCTAssertEqual(reference.kind, .codex)
        XCTAssertEqual(reference.projectID, project.id)
        XCTAssertEqual(reference.projectName, project.name)
        XCTAssertEqual(reference.projectPath, project.folderPath)
        XCTAssertEqual(reference.agentSessionID, "019a-codex-thread")

        XCTAssertNil(SessionReference.live(for: SessionID(), in: store), "a deleted row is no reference")
    }

    func testTheReaderIsResolvedForTheSurfaceTheDropLandedOn() throws {
        let store = ProjectStore.shared
        let project = try makeProject(named: "reader")
        let claude = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let openCode = try XCTUnwrap(store.addSession(to: project.id, kind: .openCode))

        let claudeTerminal = SessionReferenceReader.live(for: claude.id, on: .terminal, in: store)
        XCTAssertEqual(claudeTerminal.projectID, project.id)
        XCTAssertTrue(claudeTerminal.hasSessionTools, "Claude's terminal receives the bridge")

        let openCodeTerminal = SessionReferenceReader.live(for: openCode.id, on: .terminal, in: store)
        XCTAssertFalse(
            openCodeTerminal.hasSessionTools,
            "OpenCode's TUI receives no Threading bridge, so it must be told there are no tools"
        )

        AppSettings.shared.setToolGroup(MCPToolCatalog.workspace.id, enabled: false)
        XCTAssertFalse(
            SessionReferenceReader.live(for: claude.id, on: .conversation, in: store).hasSessionTools,
            "The user switched the Other sessions tools off; the brief must not promise them"
        )
    }

    func testDroppingASessionOnAnAgentsTerminalPastesTheBracketedBrief() throws {
        let store = ProjectStore.shared
        let project = try makeProject(named: "terminal")
        let dragged = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        store.update(sessionID: dragged.id) { $0.customTitle = "Sibling" }

        let board = NSPasteboard(name: NSPasteboard.Name("threading-session-drop-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([SessionReferencePasteboard.item(for: dragged.id)])

        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.feed(text: "\u{1b}[?2004h")
        recorder.written.removeAll()

        view.dropReader = .agent(.claude)
        XCTAssertTrue(view.accept(board))
        let text = recorder.text
        XCTAssertTrue(text.hasPrefix("\u{1b}[200~["), "the reference arrives as one paste: \(text)")
        XCTAssertTrue(text.hasSuffix("] \u{1b}[201~"), text)
        XCTAssertTrue(text.contains("Threading session “Sibling”"), text)
        XCTAssertTrue(text.contains(dragged.id.uuidString.lowercased()), text)
    }

    func testAShellRefusesADroppedSession() throws {
        let store = ProjectStore.shared
        let project = try makeProject(named: "shell")
        let dragged = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))

        let board = NSPasteboard(name: NSPasteboard.Name("threading-session-shell-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([SessionReferencePasteboard.item(for: dragged.id)])

        let view = EmojiFixedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = Recorder()
        view.terminalDelegate = recorder
        view.dropReader = .shell

        XCTAssertEqual(view.draggingEntered(DropFixture(pasteboard: board)), [])
        XCTAssertFalse(view.accept(board))
        XCTAssertTrue(recorder.written.isEmpty, "a shell has no agent to read a brief written for one")
    }
}

// MARK: - Drop Fixture

/// A drag carrying one pasteboard, which is the whole of what a drop destination inspects.
private final class DropFixture: NSObject, NSDraggingInfo {

    private let pasteboard: NSPasteboard

    convenience init(writing contents: (NSPasteboard) -> Void) {
        let board = NSPasteboard(name: NSPasteboard.Name("ThreadingSessionReferenceDropFixture"))
        board.clearContents()
        contents(board)
        self.init(pasteboard: board)
    }

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { NSPoint(x: 10, y: 10) }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var draggingFormation: NSDraggingFormation = .default
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
