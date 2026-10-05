import XCTest
@testable import Threading

final class ProjectAutomationFilesTests: XCTestCase {
    private func required<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-automation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func configuration(projectID: ProjectID = ProjectID()) -> AutomationConfiguration {
        var config = AutomationConfiguration(projectID: projectID)
        config.name = "Morning report"
        config.instructions = "Read {{project}} and write reports in {{workspace}}."
        config.executionMode = .taskLocalEdits
        config.checkoutPolicy = .automationWorkspace
        return config
    }

    private func save(in root: URL, id: String = "report") throws -> ProjectAutomationFiles.Snapshot {
        let config = configuration()
        return try ProjectAutomationFiles.save(ProjectAutomation(id: id, configuration: config, source: nil),
            instructions: config.instructions, checkout: root.path, expectedFingerprint: nil)
    }

    func testPortableSaveDiscoveryAndConflict() throws {
        let root = try scratch()
        let saved = try save(in: root)
        let loaded = try XCTUnwrap(ProjectAutomationFiles.discover(checkout: root.path).first?.snapshot)
        XCTAssertEqual(saved.fingerprint, loaded.fingerprint)
        let manifest = try XCTUnwrap(String(data: loaded.files["automation.json"]!, encoding: .utf8))
        for forbidden in ["projectID", "account", "sourceInstallationID", "enabled", root.path] {
            XCTAssertFalse(manifest.contains(forbidden), forbidden)
        }
        let ignore = try String(contentsOf: root.appendingPathComponent(".threading/.gitignore"))
        XCTAssertEqual(ignore, "/local/\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".threading/automations/.write-lock").path))
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: "report")
        try Data("Outside edit".utf8).write(to: folder.appendingPathComponent("instructions.md"))
        XCTAssertThrowsError(try ProjectAutomationFiles.save(saved.definition, instructions: "Overwrite",
            checkout: root.path, expectedFingerprint: saved.fingerprint))
        XCTAssertEqual(try ProjectAutomationFiles.read(checkout: root.path, id: "report").instructions, "Outside edit")
    }

    func testResourceChangesAndImmutableSnapshot() throws {
        let root = try scratch()
        var saved = try save(in: root)
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: "report")
        try Data("print('v1')".utf8).write(to: folder.appendingPathComponent("collect.py"))
        var definition = saved.definition
        definition.resources = ["collect.py"]
        // Resource declaration is an outside edit, then discovery freezes those exact bytes.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(definition).write(to: folder.appendingPathComponent("automation.json"))
        saved = try ProjectAutomationFiles.read(checkout: root.path, id: "report")
        let revision = try ProjectAutomationFiles.revision(snapshot: saved, checkout: root.path)
        try Data("print('v2')".utf8).write(to: folder.appendingPathComponent("collect.py"))
        XCTAssertNotEqual(try ProjectAutomationFiles.read(checkout: root.path, id: "report").fingerprint, saved.fingerprint)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: revision.resourcesPath).appendingPathComponent("collect.py")), "print('v1')")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("collect.py"))
        XCTAssertNotNil(try ProjectAutomationFiles.discover(checkout: root.path).first?.diagnostic)
    }

    func testInvalidVersionTraversalAndSymlinkAreRefused() throws {
        let root = try scratch()
        let saved = try save(in: root)
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: "report")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for path in ["../outside.md", "/tmp/outside.md", "a/../../outside.md"] {
            var definition = saved.definition; definition.instructions = path
            try encoder.encode(definition).write(to: folder.appendingPathComponent("automation.json"))
            XCTAssertThrowsError(try ProjectAutomationFiles.read(checkout: root.path, id: "report"))
        }
        var future = saved.definition; future.formatVersion = 2
        try encoder.encode(future).write(to: folder.appendingPathComponent("automation.json"))
        XCTAssertThrowsError(try ProjectAutomationFiles.read(checkout: root.path, id: "report"))
        try encoder.encode(saved.definition).write(to: folder.appendingPathComponent("automation.json"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("instructions.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("instructions.md"), withDestinationURL: root.appendingPathComponent("outside.md"))
        XCTAssertThrowsError(try ProjectAutomationFiles.read(checkout: root.path, id: "report"))
        XCTAssertThrowsError(try ProjectAutomationFiles.folder(checkout: root.path, id: "../escape"))
    }

    func testMissingInvalidAndOversizedDirectoriesHaveVisibleDiagnostics() throws {
        let root = try scratch()
        let folder = root.appendingPathComponent(".threading/automations/broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNotNil(try ProjectAutomationFiles.discover(checkout: root.path).first?.diagnostic)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("automation.json"))
        XCTAssertNotNil(try ProjectAutomationFiles.discover(checkout: root.path).first?.diagnostic)
        for i in 0..<500 {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent().appendingPathComponent("a\(i)"), withIntermediateDirectories: true)
        }
        XCTAssertThrowsError(try ProjectAutomationFiles.discover(checkout: root.path))
    }

    func testDiscoveryPausesAndRestartKeepsBinding() async throws {
        let root = try scratch()
        let projectID = ProjectID()
        _ = try save(in: root)
        let databaseURL = root.appendingPathComponent("triggers.db")
        let store = TriggerStore(url: databaseURL)
        _ = try await store.discoverProjectAutomations(projectID: projectID, checkout: root.path)
        let pair = try required(try await store.triggers().first)
        XCTAssertFalse(pair.definition.enabled)
        try await store.activate(triggerID: pair.definition.id, revisionID: pair.revision.id)
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: "report")
        try Data("Changed instructions".utf8).write(to: folder.appendingPathComponent("instructions.md"))
        _ = try await store.discoverProjectAutomations(projectID: projectID, checkout: root.path)
        let changed = try required(try await store.trigger(id: pair.definition.id))
        XCTAssertFalse(changed.definition.enabled)
        XCTAssertNotEqual(changed.revision.id, pair.revision.id)
        await store.close()
        let reopened = TriggerStore(url: databaseURL)
        addTeardownBlock { await reopened.close() }
        _ = try await reopened.discoverProjectAutomations(projectID: projectID, checkout: root.path)
        let restored = try await reopened.triggers()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.definition.id, pair.definition.id)
        XCTAssertEqual(restored.first?.revision.id, changed.revision.id)
    }

    func testDispatchDetectsOutsideEditWithoutDiscovery() async throws {
        let root = try scratch()
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        _ = try save(in: root)
        _ = try await store.discoverProjectAutomations(projectID: ProjectID(), checkout: root.path)
        let pair = try required(try await store.triggers().first)
        try await store.activate(triggerID: pair.definition.id, revisionID: pair.revision.id)
        let dispatch = try await store.runAutomationNow(pair.definition.id, expectedRevision: pair.revision.id, requestKey: "one")
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: "report")
        try Data("Changed after reservation".utf8).write(to: folder.appendingPathComponent("instructions.md"))
        let claimed = try await store.claimDispatch(dispatch.run.id)
        XCTAssertNil(claimed)
        let blocked = try await store.run(id: dispatch.run.id)
        XCTAssertEqual(blocked?.state, .needsAttention)
        let paused = try await store.trigger(id: pair.definition.id)
        XCTAssertFalse(paused?.definition.enabled ?? true)
        let binding = try await store.projectAutomationBinding(pair.definition.id)
        XCTAssertNotNil(binding?.diagnostic)
    }

    func testWorktreesHaveOneScheduleOwner() async throws {
        let root = try scratch()
        _ = try GitProcess.run(["init", "-b", "main"], in: root)
        try Data("seed".utf8).write(to: root.appendingPathComponent("seed"))
        _ = try GitProcess.run(["add", "seed"], in: root)
        _ = try GitProcess.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "seed"], in: root)
        let second = root.appendingPathComponent("sibling")
        _ = try GitProcess.run(["worktree", "add", "-b", "second", second.path], in: root)
        _ = try save(in: root); _ = try save(in: second)
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        _ = try await store.discoverProjectAutomations(projectID: ProjectID(), checkout: root.path)
        let first = try required(try await store.triggers().first)
        try await store.activate(triggerID: first.definition.id, revisionID: first.revision.id)
        _ = try await store.discoverProjectAutomations(projectID: ProjectID(), checkout: second.path)
        let other = try required(try await store.triggers().first { $0.definition.id != first.definition.id })
        let owner = try await store.projectAutomationOwner(other.definition.id)
        XCTAssertEqual(owner, root.path)
        try await store.activate(triggerID: other.definition.id, revisionID: other.revision.id)
        let active = try await store.activeTriggers()
        XCTAssertEqual(active.map(\.definition.id), [other.definition.id])
        let dates = try await (store.nextAutomationDate(first.definition.id), store.nextAutomationDate(other.definition.id))
        XCTAssertNil(dates.0); XCTAssertNotNil(dates.1)
    }

    func testAdoptionKeepsTriggerIdentityHistoryAndLeavesSchedulePaused() async throws {
        let root = try scratch()
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let id = TriggerID()
        var config = configuration()
        config.checkoutPolicy = .projectCheckout
        config.account = "chosen-login"
        let original = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        let oldRun = try await store.runAutomationNow(id, expectedRevision: original.id, requestKey: "retained-history")
        var settled = oldRun.run; settled.state = .completed; settled.settledAt = Date()
        try await store.updateRun(settled)
        _ = try save(in: root)
        let ownerProject = ProjectID()
        let revision = try await store.adoptProjectAutomation(id, expectedRevision: original.id,
            projectID: ownerProject, checkout: root.path, automationID: "report")
        XCTAssertEqual(revision.triggerID, id)
        XCTAssertEqual(revision.projectID, ownerProject)
        XCTAssertEqual(revision.accountHandleName, "chosen-login")
        let pairs = try await store.triggers()
        XCTAssertEqual(pairs.count, 1)
        XCTAssertFalse(pairs.first?.definition.enabled ?? true)
        let history = try await store.runPage(triggerID: id)
        XCTAssertEqual(history.items.map(\.id), [settled.id])
        let projectHistory = try await store.runPage(projectID: ownerProject)
        XCTAssertEqual(projectHistory.items.map(\.id), [settled.id])
        let due = try await store.nextAutomationDate(id)
        XCTAssertNil(due)
    }

    func testToolSaveUsesProjectFilesAndRejectsStaleRevision() async throws {
        let root = try scratch()
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let id = TriggerID()
        var config = configuration()
        config.account = "automation-fixture"
        config.instructions = "Read \(root.path)."
        config.permissions = try .allowList(parsing: ["Write(\(root.path)/.threading/local/automations/\(id.uuidString.lowercased())/**)"])
        let text = try await AutomationCommands.execute(.init(operation: "configure", id: id.uuidString,
            configuration: config, folder: root.path), store: store)
        let saved = try JSONDecoder().decode(AutomationSnapshot.self, from: Data(text.utf8))
        let binding = try await store.projectAutomationBinding(id)
        XCTAssertEqual(binding?.automationID, id.uuidString.lowercased())
        let portable = try ProjectAutomationFiles.read(checkout: root.path, id: id.uuidString.lowercased())
        XCTAssertEqual(portable.instructions, "Read {{project}}.")
        XCTAssertEqual(portable.definition.permissions.rules, ["Write({{workspace}}/**)"])
        let folder = try ProjectAutomationFiles.folder(checkout: root.path, id: id.uuidString.lowercased())
        let notes = folder.appendingPathComponent("README.md")
        try Data("Keep the project's authored notes.".utf8).write(to: notes)
        config.account = nil
        config.instructions = "Second version"
        _ = try await AutomationCommands.execute(.init(operation: "configure", id: id.uuidString,
            expectedRevision: saved.revision.uuidString, configuration: config), store: store)
        XCTAssertEqual(try ProjectAutomationFiles.read(checkout: root.path, id: id.uuidString.lowercased()).instructions, "Second version")
        XCTAssertEqual(try String(contentsOf: notes), "Keep the project's authored notes.")
        let resaved = try await store.trigger(id: id)
        XCTAssertNil(resaved?.revision.accountHandleName, "Choosing the default login must clear the previous local account")
        do {
            _ = try await AutomationCommands.execute(.init(operation: "configure", id: id.uuidString,
                expectedRevision: saved.revision.uuidString, configuration: config), store: store)
            XCTFail("stale revision was accepted")
        } catch ProjectAutomationFiles.Failure.conflict {}
    }

    func testStressDiscoveryBudget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_AUTOMATION_STRESS"] == "1")
        let root = try scratch()
        let config = configuration()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let setupStart = Date()
        for index in 0..<500 {
            let folder = root.appendingPathComponent(".threading/automations/task-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(ProjectAutomation(id: "task-\(index)", configuration: config, source: nil)).write(to: folder.appendingPathComponent("automation.json"))
            try Data(config.instructions.utf8).write(to: folder.appendingPathComponent("instructions.md"))
        }
        let setup = Date().timeIntervalSince(setupStart)
        let heartbeat = Task { @MainActor in
            var count = 0
            var maximumGap: TimeInterval = 0
            var previous = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = Date()
                maximumGap = max(maximumGap, now.timeIntervalSince(previous))
                previous = now
                count += 1
            }
            return (count, maximumGap)
        }
        defer { heartbeat.cancel() }
        let start = Date()
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let projectID = ProjectID()
        let discovered = try await store.discoverProjectAutomations(projectID: projectID, checkout: root.path)
        let discovery = Date().timeIntervalSince(start)
        XCTAssertEqual(discovered.count, 500)
        let secondStart = Date()
        _ = try await store.discoverProjectAutomations(projectID: projectID, checkout: root.path)
        let unchanged = Date().timeIntervalSince(secondStart)
        let pairs = try await store.triggers()
        XCTAssertEqual(pairs.count, 500)
        heartbeat.cancel()
        let responsiveness = await heartbeat.value
        XCTAssertGreaterThan(responsiveness.0, 1, "Background discovery must let the main actor continue")
        print("Project automation stress: manufacture \(setup)s, initial discovery \(discovery)s, unchanged discovery \(unchanged)s; 500 definitions, \(responsiveness.0) main-actor heartbeats, maximum gap \(responsiveness.1)s")
    }

    func testDeletionTombstonesDoNotFillTheLiveCatalogueOrRediscoverFiles() async throws {
        let root = try scratch()
        let store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await store.close() }
        let config = configuration()
        let id = TriggerID()
        let revision = try await store.saveProjectAutomation(config, id: id, expectedRevision: nil, checkout: root.path)
        try await store.removeAutomation(id, expectedRevision: revision.id)
        let liveBindings = try await store.projectAutomationBindings()
        XCTAssertTrue(liveBindings.isEmpty)
        _ = try await store.discoverProjectAutomations(projectID: config.projectID, checkout: root.path)
        let live = try await store.triggers()
        XCTAssertTrue(live.isEmpty)
        let tombstone = try await store.projectAutomationBinding(id)
        XCTAssertNotNil(tombstone)
    }

    func testSessionWorkspacePersistsAndRoutesResumeUnderItsOwner() throws {
        let root = try scratch()
        let project = Project(name: "Sonda", folderURL: root)
        let workspace = AutomationWorkspace(automationID: "report", checkoutPath: root.path)
        let session = try XCTUnwrap(AgentSessionCreation.makeRecord(kind: .codex, usesNativeUI: true,
            permissionMode: .acceptEdits, automationWorkspace: workspace))
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.workingDirectory(in: project), workspace.executionPath)
        XCTAssertNil(restored.managedWorkspace)
    }
}
