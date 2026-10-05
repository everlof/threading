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
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
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
            // Empty state is an ordinary navigable project destination.
            try await center.prepareEvidencePage(index: 0)
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .automations(project.id))
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
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .automations(project.id))
            try capture(window, in: output, named: "trigger-center-project-detail-\(name)")
            let editor = AutomationEditorViewController(configuration: config, projects: [project])
            editor.lockedProjectID = project.id
            let submitted = try editor.submissionAfterLoadingForProjectEvidence()
            XCTAssertEqual(submitted.projectID, project.id)
        }
        let folder = try await store.projectAutomationBinding(automationID)?.checkoutPath
        let instructions = URL(fileURLWithPath: try XCTUnwrap(folder)).appendingPathComponent(".threading/automations/\(automationID.uuidString.lowercased())/instructions.md")
        try FileManager.default.removeItem(at: instructions)
        for (name, theme) in themes {
            AppThemeLibrary.installResolved(theme)
            try await center.prepareEvidencePage(index: 0)
            shell.sidebarViewController.selectAutomations(projectID: project.id)
            XCTAssertEqual(shell.sidebarViewController.selectedRowKey, .automations(project.id))
            XCTAssertEqual(center.drawnRowCount, 3, "An invalid imported definition must appear once, with its diagnostic on the automation row")
            try capture(window, in: output, named: "trigger-center-project-error-\(name)")
        }
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
