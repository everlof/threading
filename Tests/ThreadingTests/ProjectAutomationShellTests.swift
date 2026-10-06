import AppKit
import Darwin
import XCTest
@testable import Threading

@MainActor
final class ProjectAutomationShellTests: HostedStoreTestCase {
    func testProjectWorkspaceStartsWithDirtyProductCheckoutAndPersistsOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automation-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try GitProcess.run(["init", "-b", "main"], in: root)
        try Data("uncommitted product work".utf8).write(to: root.appendingPathComponent("dirty.txt"))
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let workspace = AutomationWorkspace(automationID: "report", checkoutPath: root.path)
        try FileManager.default.createDirectory(atPath: workspace.executionPath, withIntermediateDirectories: true)
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let plan = ScheduledSessionPlan(projectID: project.id, kind: .codex, accountHandle: .standard,
            model: nil, reasoningEffort: nil, branch: nil, usesNativeUI: true, permissionMode: .acceptEdits,
            automationWorkspace: workspace)
        let session = try XCTUnwrap(shell.sessionCoordinator.startSessionUnattended(plan: plan, title: "Project report"))
        XCTAssertEqual(ProjectStore.shared.project(forSessionID: session.id)?.id, project.id)
        XCTAssertEqual(ProjectStore.shared.workingDirectory(forSessionID: session.id), workspace.executionPath)
        XCTAssertEqual(ProjectStore.shared.executionProject(forSessionID: session.id)?.folderPath, workspace.executionPath)
        XCTAssertNil(session.managedWorkspace)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("dirty.txt")), "uncommitted product work")
        let recovered = ProjectStore(stateManager: StateManager.shared)
        XCTAssertEqual(recovered.project(forSessionID: session.id)?.id, project.id)
        XCTAssertEqual(recovered.workingDirectory(forSessionID: session.id), workspace.executionPath)
    }

    func testRendersProjectAutomationsInShippingShell() async throws {
        // Fixed paths and IDs make the reviewed fingerprint and resolved-path facts repeatable.
        let lock = open("/tmp/threading-project-automation-evidence.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        addTeardownBlock { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteFileExists) }
        let root = URL(fileURLWithPath: "/tmp/ThreadingProjectAutomationEvidence")
        let marker = root.appendingPathComponent(".fixture-owner")
        if FileManager.default.fileExists(atPath: root.path) {
            guard (try? Data(contentsOf: marker)) == Data("project-automation-evidence".utf8) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("project-automation-evidence".utf8).write(to: marker)
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: root) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        _ = ProjectStore.shared.renameProject(id: project.id, to: "Evidence project")
        for name in ["Empty checkout A", "Empty checkout B"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let empty = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
            _ = ProjectStore.shared.renameProject(id: empty.id, to: name)
        }
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame, triggerStore: store)
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1400, height: 900))
        let oldPalette = AppThemePalette.current
        defer { AppThemeLibrary.installResolved(oldPalette) }
        shell.containerViewController.showTriggers(store: store, projectID: project.id)
        let center = try XCTUnwrap(shell.containerViewController.children.compactMap { $0 as? TriggerCenterViewController }.first)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? "/tmp/ThreadingRenders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let themes: [(String, AppTheme)] = [("system", .system), ("pure", AppThemeStyles.pure), ("neo", AppThemeStyles.neoBrutalism)]
        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Project morning report"
        config.model = "gpt-6.1-sol"
        config.reasoningEffort = "high"
        config.instructions = "Read {{project}} and write only inside {{workspace}}."
        config.checkoutPolicy = .automationWorkspace
        config.executionMode = .taskLocalEdits
        let automationID = try XCTUnwrap(TriggerID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001"))
        for (name, theme) in themes {
            AppThemeLibrary.installResolved(theme)
            // The empty page is reachable without adding an empty destination to the tree.
            try await center.prepareEvidencePage(index: 0)
            try await shell.sidebarViewController.refreshAutomationProjects()
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .project(project.id))
            XCTAssertFalse(shell.sidebarViewController.presentedRowKeys.contains(.automations(project.id)))
            try capture(window, in: output, named: "trigger-center-project-empty-\(name)")
        }
        let saved = try await store.saveProjectAutomation(config, id: automationID, expectedRevision: nil, checkout: root.path)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(saved)) as? [String: Any])
        fields["id"] = "AAAAAAAA-BBBB-CCCC-DDDD-000000000002"
        fields["sequence"] = 2
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let revision = try decoder.decode(TriggerRevision.self, from: JSONSerialization.data(withJSONObject: fields))
        let savedPair = try await store.trigger(id: automationID)
        var definition = try XCTUnwrap(savedPair?.definition)
        definition.draftRevisionID = revision.id
        try await store.saveDraft(definition, revision: revision)
        for (name, theme) in themes {
            AppThemeLibrary.installResolved(theme)
            try await center.prepareEvidenceDetail(automationID)
            try await shell.sidebarViewController.refreshAutomationProjects()
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .automations(project.id))
            try capture(window, in: output, named: "trigger-center-project-detail-\(name)")
            var editorConfig = config
            editorConfig.model = nil
            let editor = AutomationEditorViewController(configuration: editorConfig, projects: [project], choices: AutomationEditorChoicesTests.fixture)
            editor.lockedProjectID = project.id
            editor.availableHeight = window.contentLayoutRect.height - Design.Spacing.pane * 2
            await editor.prepareAgentChoices()
            let submitted = try editor.submissionAfterLoadingForProjectEvidence()
            XCTAssertEqual(submitted.projectID, project.id)
            center.presentAsSheet(editor)
            let sheet = try XCTUnwrap(editor.view.window)
            XCTAssertTrue(window.attachedSheet === sheet, "Evidence must use the shipping attached editor")
            try capture(sheet, in: output, named: "trigger-center-project-editor-\(name)")
            let login = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? ThemedPopUp }
                .first { $0.accessibilityIdentifier() == "automation.account" })
            XCTAssertTrue(login.performPrimaryAction())
            try capture(sheet, in: output, named: "trigger-center-project-editor-accounts-\(name)")
            login.dismissMenu()
            center.dismiss(editor)
        }
        let folder = try await store.projectAutomationBinding(automationID)?.checkoutPath
        let instructions = URL(fileURLWithPath: try XCTUnwrap(folder)).appendingPathComponent(".threading/automations/\(automationID.uuidString.lowercased())/instructions.md")
        try FileManager.default.removeItem(at: instructions)
        for (name, theme) in themes {
            AppThemeLibrary.installResolved(theme)
            try await center.prepareEvidencePage(index: 0)
            try await shell.sidebarViewController.refreshAutomationProjects()
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .automations(project.id))
            XCTAssertEqual(center.drawnRowCount, 3, "An invalid imported definition must appear once, with its diagnostic on the automation row")
            try capture(window, in: output, named: "trigger-center-project-error-\(name)")
        }
    }

    func testSidebarCountsSavedAutomationsAndMenuOpensAnEmptyProject() async throws {
        let oldPalette = AppThemePalette.current
        AppThemeLibrary.installResolved(.system)
        defer { AppThemeLibrary.installResolved(oldPalette) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automation-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: root) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let otherFolder = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let unrelated = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: otherFolder))
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame, triggerStore: store)
        let sidebar = shell.sidebarViewController
        try await sidebar.refreshAutomationProjects()
        XCTAssertFalse(sidebar.presentedRowKeys.contains(.automations(project.id)))
        let projectRow = try XCTUnwrap(sidebar.presentedRowKeys.firstIndex(of: .project(project.id)))
        let menuItem = try XCTUnwrap(sidebar.projectMenuEntries(row: projectRow).compactMap { entry -> ThemedMenuItem? in
            guard case .item(let item) = entry,
                  item.representedValue as? String == AppCommands.ID.projectAutomations else { return nil }
            return item
        }.first)
        menuItem.onChoose?()
        XCTAssertTrue(shell.containerViewController.isShowingTriggers)
        XCTAssertEqual(shell.containerViewController.automationProjectID, project.id)
        XCTAssertEqual(sidebar.selectedRowKey, .project(project.id))

        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Morning report"; config.instructions = "Summarize the project."
        let firstID = TriggerID()
        let first = try await store.saveProjectAutomation(config, id: firstID, expectedRevision: nil, checkout: root.path)
        try await sidebar.refreshAutomationProjects()
        sidebar.selectAutomations(projectID: project.id)
        XCTAssertEqual(sidebar.selectedRowKey, .automations(project.id))
        XCTAssertFalse(sidebar.presentedRowKeys.contains(.automations(unrelated.id)))
        func displayedCount() throws -> String? {
            shell.window?.contentView?.layoutSubtreeIfNeeded()
            shell.window?.contentView?.displayIfNeeded()
            let cell = try XCTUnwrap(sidebar.presentedRowView(of: .automations(project.id)))
            return descendants(cell).compactMap { ($0 as? NSTextField)?.stringValue }.first { Int($0) != nil }
        }
        XCTAssertEqual(try displayedCount(), "1")

        let secondID = TriggerID()
        let second = try await store.saveProjectAutomation(config, id: secondID, expectedRevision: nil, checkout: root.path)
        try await sidebar.refreshAutomationProjects()
        XCTAssertEqual(try displayedCount(), "2")
        XCTAssertEqual(sidebar.selectedRowKey, .automations(project.id))
        let counts = try await store.projectAutomationCounts()
        XCTAssertEqual(counts, [project.id: 2], "Paused drafts count; empty projects do not")
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex))
        ProjectStore.shared.update(sessionID: session.id) { $0.branch = "automation-result" }
        XCTAssertEqual(sidebar.selectedRowKey, .automations(project.id))
        sidebar.reload()
        XCTAssertEqual(sidebar.selectedRowKey, .automations(project.id))

        try await store.removeAutomation(firstID, expectedRevision: first.id)
        try await sidebar.refreshAutomationProjects()
        XCTAssertEqual(try displayedCount(), "1")
        try await store.removeAutomation(secondID, expectedRevision: second.id)
        try await sidebar.refreshAutomationProjects()
        XCTAssertFalse(sidebar.presentedRowKeys.contains(.automations(project.id)))
        XCTAssertEqual(sidebar.selectedRowKey, .project(project.id))
        XCTAssertEqual(shell.containerViewController.automationProjectID, project.id)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func capture(_ window: NSWindow, in output: URL, named name: String) throws {
        let content = try XCTUnwrap(window.contentView)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private extension AutomationEditorViewController {
    func submissionAfterLoadingForProjectEvidence() throws -> AutomationConfiguration {
        _ = view
        return try XCTUnwrap(submission().0)
    }
}
