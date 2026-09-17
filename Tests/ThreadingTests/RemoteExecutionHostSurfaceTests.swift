import AppKit
import XCTest
@testable import Threading

/// Everywhere a project's remote host shows, because the point of storing it on the project is
/// that nobody can forget it is set: the row marks, the hover card line, the project menu item and
/// the editor that keeps an unusable host from being saved.
@MainActor
final class RemoteExecutionHostSurfaceTests: HostedStoreTestCase {

    private enum Render {
        static let rowWidth: CGFloat = 260
        static let rowHeight: CGFloat = 28

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private let host = ProjectExecutionHost(destination: "lima-ptyd-spike", remoteDirectory: "/home/me/app")

    // MARK: - Row marks

    func testASessionRowSaysWhereItRunsAndForgetsItOnReuse() throws {
        let (container, row) = hostedSessionRow()
        row.configure(with: AgentSession(kind: .claude, title: "Remote"), activity: .idle, executionHost: "pi")
        container.layoutSubtreeIfNeeded()

        let mark = try view(named: RemoteExecutionHostMark.sessionMarkIdentifier, in: row)
        XCTAssertFalse(mark.isHidden)
        XCTAssertGreaterThan(mark.frame.width, 0, "the mark was given no room in the row")
        XCTAssertEqual(mark.accessibilityLabel(), RemoteExecutionHostMark.runsOn("pi"))
        XCTAssertEqual(mark.accessibilityRole(), .image)

        row.configure(with: AgentSession(kind: .claude, title: "Local"), activity: .idle)
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(try view(named: RemoteExecutionHostMark.sessionMarkIdentifier, in: row).isHidden,
                      "a recycled row claimed another session's host")
    }

    func testAProjectRowSaysWhereItsSessionsRun() throws {
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        var project = Project(name: "App", folderURL: URL(fileURLWithPath: "/tmp/app"))
        project.executionHost = host
        row.configure(with: project, executionHost: host.destination)
        row.frame = NSRect(x: 0, y: 0, width: Render.rowWidth, height: Render.rowHeight)
        row.layoutSubtreeIfNeeded()

        let mark = try view(named: RemoteExecutionHostMark.projectMarkIdentifier, in: row)
        XCTAssertFalse(mark.isHidden)
        XCTAssertEqual(mark.accessibilityLabel(), RemoteExecutionHostMark.runsOn(host.destination))

        row.configure(with: Project(name: "Local", folderURL: URL(fileURLWithPath: "/tmp/local")))
        XCTAssertTrue(try view(named: RemoteExecutionHostMark.projectMarkIdentifier, in: row).isHidden)
    }

    // MARK: - Hover card

    func testTheSessionHoverCardNamesTheHost() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))

        let info = SessionInfoPopoverViewController.Info(session: session, activity: .idle)
        XCTAssertEqual(info.executionHost, host.destination)

        let card = SessionInfoPopoverViewController(info: info)
        let labels = descendants(of: card.view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(RemoteExecutionHostMark.runsOn(host.destination)), "\(labels)")
    }

    // MARK: - Project menu

    func testTheProjectMenuNamesTheHostAndOpensTheEditor() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        let sidebar = ProjectSidebarViewController()
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        sidebar.view.layoutSubtreeIfNeeded()
        sidebar.mountInitialTreeIfNeeded()

        XCTAssertNotNil(remoteHostItem(in: sidebar.projectMenuEntries(row: 0)),
                        "a build that can run remote sessions offers the editor")
        XCTAssertEqual(remoteHostItem(in: sidebar.projectMenuEntries(row: 0))?.title,
                       L10n.string("Remote Host…"))

        XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        sidebar.reload()
        XCTAssertEqual(remoteHostItem(in: sidebar.projectMenuEntries(row: 0))?.title,
                       L10n.format("Remote Host: %@…", host.destination),
                       "the menu states the host before anyone opens it")
    }

    // MARK: - Editor

    func testTheEditorOffersRemoveOnlyWhenThereIsAHost() {
        let empty = RemoteHostPromptAlert.makeAlert(projectName: "App", current: nil)
        XCTAssertFalse(buttonTitles(empty.makeContentView()).contains(L10n.string("Remove Host")))

        let set = RemoteHostPromptAlert.makeAlert(projectName: "App", current: host)
        XCTAssertTrue(buttonTitles(set.makeContentView()).contains(L10n.string("Remove Host")))
    }

    /// A folder a launch would refuse keeps the dialog open with the correction in view. The
    /// machine itself is chosen from the list, so it cannot be mistyped here at all.
    func testTheEditorRefusesAFolderALaunchWouldRefuse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteHostStore(directory: directory)
        let record = RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")
        XCTAssertEqual(store.add(record), .applied)

        let accessory = RemoteHostPromptAccessory(current: nil, store: store)
        accessory.remoteDirectoryField.stringValue = "relative/path"

        XCTAssertFalse(accessory.validate(announcing: false))
        XCTAssertEqual(accessory.helperLabel.stringValue,
                       ProjectExecutionHost.Problem.relativeRemoteDirectory.message)

        accessory.remoteDirectoryField.stringValue = "/home/me/app"
        XCTAssertTrue(accessory.validate(announcing: false))
        XCTAssertEqual(accessory.host, .on(record, remoteDirectory: "/home/me/app"))
    }

    // MARK: - Tools

    /// A remote session is offered only the tools that can answer it from this Mac, and a call to
    /// any other is refused even when named directly — a path on the host resolved against this
    /// Mac's disk would read the wrong file or none.
    func testARemoteSessionIsOfferedOnlyToolsThatNeedNoFileOnThisMac() throws {
        let local = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        let remote = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: remote.id), .applied)
        let localSession = try XCTUnwrap(ProjectStore.shared.addSession(to: local.id, kind: .claude))
        let remoteSession = try XCTUnwrap(ProjectStore.shared.addSession(to: remote.id, kind: .claude))

        let offered = Set(MCPToolCatalog.definitions(for: remoteSession.id).map(\.name))
        XCTAssertFalse(offered.isEmpty)
        XCTAssertTrue(offered.allSatisfy(MCPRemoteSessionToolScope.reaches(toolNamed:)), "\(offered)")
        let localOffered = Set(MCPToolCatalog.definitions(for: localSession.id).map(\.name))
        if localOffered.contains("display_image") {
            XCTAssertFalse(offered.contains("display_image"))
        }
        if localOffered.contains("set_session_name") {
            XCTAssertTrue(offered.contains("set_session_name"))
        }

        // Simulator annotations are this Mac's simulator; listing sessions needs nothing local.
        let simulator = AgentCommand.simulatorAnnotations(EmptyToolArguments())
        if MCPToolCatalog.admits(simulator, for: localSession.id) {
            XCTAssertFalse(MCPToolCatalog.admits(simulator, for: remoteSession.id))
        }
        let sessions = AgentCommand.listSessions(EmptyToolArguments())
        if MCPToolCatalog.admits(sessions, for: localSession.id) {
            XCTAssertTrue(MCPToolCatalog.admits(sessions, for: remoteSession.id))
        }
        XCTAssertTrue(MCPToolCatalog.instructions(for: remoteSession.id)
            .contains(MCPRemoteSessionToolScope.instructions))
        XCTAssertFalse(MCPToolCatalog.instructions(for: localSession.id)
            .contains(MCPRemoteSessionToolScope.instructions))
        XCTAssertTrue(MCPToolCatalog.remoteProviderLaunchToolNames.allSatisfy(MCPRemoteSessionToolScope.reaches(toolNamed:)))
        XCTAssertFalse(MCPRemoteSessionToolScope.reaches(toolNamed: "an_extension_tool"),
                       "an extension's arguments are unknown, so none reaches a remote host")
    }

    // MARK: - Hook reports

    /// A remote agent's hooks name paths on its host. Read here they would find nothing, or another
    /// file at the same path, and a host working directory would read as the agent leaving its
    /// checkout — so a remote session's reports arrive with those paths cleared.
    func testARemoteSessionsHookReportKeepsItsEventButNotItsHostPaths() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: scratchFolder()))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        XCTAssertFalse(ProjectStore.shared.sessionRunsOnRemoteHost(session.id))
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        XCTAssertTrue(ProjectStore.shared.sessionRunsOnRemoteHost(session.id))

        let report = try XCTUnwrap(HookLifecycleReport(sessionID: session.id, event: .turnFinished, payload: [
            "session_id": "abc",
            "transcript_path": "/home/me/.claude/projects/-home-me-app/abc.jsonl",
            "agent_transcript_path": "/home/me/.claude/projects/-home-me-app/child.jsonl",
            "cwd": "/home/me/app",
            "last_assistant_message": "done"
        ]))
        let stripped = report.withoutHostPaths()
        XCTAssertNil(stripped.transcriptPath)
        XCTAssertNil(stripped.subagentTranscriptPath)
        XCTAssertNil(stripped.workingDirectory)
        XCTAssertEqual(stripped.event, .turnFinished)
        XCTAssertEqual(stripped.agentSessionID, report.agentSessionID)
        XCTAssertEqual(stripped.lastAssistantMessage, "done")
    }

    // MARK: - Images

    /// The marked rows, plain and selected, and the editor, light and dark.
    func testRendersTheHostMarkAndEditorToImages() throws {
        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))

            for selected in [false, true] {
                let (container, row) = hostedSessionRow()
                container.appearance = appearance
                row.configure(with: AgentSession(kind: .claude, title: "Remote session"),
                              activity: .idle, executionHost: host.destination)
                row.backgroundStyle = selected ? .emphasized : .normal
                AppThemeRefresh.repaint(container)
                container.layoutSubtreeIfNeeded()
                let data = try XCTUnwrap(png(of: container, appearance: appearance, selected: selected))
                try data.write(to: Render.directory.appendingPathComponent(
                    "remote-host-session-row-\(selected ? "selected" : "plain")-\(name).png"
                ))
            }

            let content = RemoteHostPromptAlert.makeAlert(projectName: "App", current: host).makeContentView()
            content.appearance = appearance
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.frame = NSRect(origin: .zero, size: content.fittingSize)
            content.layoutSubtreeIfNeeded()
            let data = try XCTUnwrap(png(of: content, appearance: appearance, selected: false))
            try data.write(to: Render.directory.appendingPathComponent("remote-host-editor-\(name).png"))
        }
    }

    // MARK: - Helpers

    private func hostedSessionRow() -> (host: NSView, row: SessionRowView) {
        let row = SessionRowView(customizationLookup: { _ in .empty })
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Render.rowWidth, height: Render.rowHeight))
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return (container, row)
    }

    private func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-host-surface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func remoteHostItem(in entries: [ThemedMenuEntry]) -> ThemedMenuItem? {
        entries.compactMap(\.item).first {
            ($0.representedValue as? String) == AppCommands.ID.projectRemoteHost
        }
    }

    private func buttonTitles(_ root: NSView) -> [String] {
        descendants(of: root).compactMap { ($0 as? ThemedButton)?.title }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func view(named identifier: String, in root: NSView) throws -> NSView {
        func walk(_ node: NSView) -> NSView? {
            if node.accessibilityIdentifier() == identifier { return node }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return try XCTUnwrap(walk(root), "no view identified as \(identifier)")
    }

    /// The ground is resolved *in* the render's appearance — resolved in the test process's own,
    /// a light render came out on a dark ground — and a selected row is drawn on the selection
    /// fill the sidebar paints behind it, so the emphasized ink is judged where it is used.
    private func png(of host: NSView, appearance: NSAppearance, selected: Bool) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        appearance.performAsCurrentDrawingAppearance {
            host.layer?.backgroundColor = (selected ? Design.Surface.accent : NSColor.windowBackgroundColor).cgColor
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep.representation(using: .png, properties: [:])
    }
}
