import Foundation
import XCTest
@testable import Threading

/// What an agent may start, where its remote requests go, and which choices the editor refuses
/// to make by default.
@MainActor
final class AutomationAuthorityTests: XCTestCase {
    @MainActor private final class ApprovalLog {
        var requests: [AutomationApprovalRequest] = []
    }

    private func scratchStore() throws -> TriggerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-authority-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }
        return store
    }

    private func pausedAutomation(in store: TriggerStore) async throws -> (TriggerID, TriggerRevision) {
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        return (id, revision)
    }

    func testAgentEnableWaitsForTheApprovalOfThatRevision() async throws {
        let store = try scratchStore()
        let (id, revision) = try await pausedAutomation(in: store)
        let log = ApprovalLog()
        let arguments = AutomationToolArguments(operation: "enable", id: id.uuidString,
                                                expectedRevision: revision.id.uuidString)
        do {
            _ = try await AutomationCommands.execute(arguments, store: store, approve: { request in
                log.requests.append(request); return false
            })
            XCTFail("an unapproved enable went ahead")
        } catch AutomationCommandError.notApproved {}
        let declined = try await store.trigger(id: id)
        XCTAssertEqual(declined?.definition.enabled, false)
        guard case .local(.enable, _, let shown)? = log.requests.first else { return XCTFail("no approval asked") }
        XCTAssertEqual(shown.id, revision.id)

        _ = try await AutomationCommands.execute(arguments, store: store, approve: { _ in true })
        let approved = try await store.trigger(id: id)
        XCTAssertEqual(approved?.definition.enabled, true)
    }

    func testDeclinedAgentRunStartsNothing() async throws {
        let store = try scratchStore()
        let (id, revision) = try await pausedAutomation(in: store)
        let arguments = AutomationToolArguments(operation: "run", id: id.uuidString,
                                                expectedRevision: revision.id.uuidString, requestKey: "agent-request")
        do {
            _ = try await AutomationCommands.execute(arguments, store: store, approve: { _ in false })
            XCTFail("an unapproved run went ahead")
        } catch AutomationCommandError.notApproved {}
        let runs = try await store.runs(triggerID: id)
        XCTAssertTrue(runs.isEmpty)
    }

    func testConfigureAndPauseNeedNoApproval() async throws {
        let store = try scratchStore()
        let (id, revision) = try await pausedAutomation(in: store)
        let log = ApprovalLog()
        _ = try await AutomationCommands.execute(.init(operation: "pause", id: id.uuidString,
            expectedRevision: revision.id.uuidString), store: store, approve: { request in
                log.requests.append(request); return false
            })
        XCTAssertTrue(log.requests.isEmpty)
    }

    func testRemoteRequestsUseTheSavedControllerConnection() throws {
        var host = RemoteHostRecord(destination: "fixture")
        let bare = RemoteAutomationEndpoint(hostID: host.id, executable: "", database: "")
        XCTAssertThrowsError(try AutomationToolActions.endpoint(for: host, requested: bare))

        host.controllerExecutable = "/opt/threading/controller"
        host.controllerDatabase = "/var/lib/threading/controller.db"
        let resolved = try AutomationToolActions.endpoint(for: host, requested: bare)
        XCTAssertEqual(resolved.executable, "/opt/threading/controller")
        XCTAssertEqual(resolved.database, "/var/lib/threading/controller.db")

        let chosen = RemoteAutomationEndpoint(hostID: host.id, executable: "/bin/sh", database: "")
        XCTAssertThrowsError(try AutomationToolActions.endpoint(for: host, requested: chosen))

        let decoded = try JSONDecoder().decode(RemoteAutomationEndpoint.self,
            from: Data("{\"hostID\":\"\(host.id.rawValue.uuidString)\"}".utf8))
        XCTAssertEqual(try AutomationToolActions.endpoint(for: host, requested: decoded), resolved)
    }

    func testOnlySourceEventsMayWaitForALaterRelease() {
        let event = revision(schedule: nil)
        let scheduled = revision(schedule: .init(kind: .daily, timeZone: "UTC"))
        var run = TriggerRun(id: TriggerRunID(), triggerID: event.triggerID, triggerRevisionID: event.id,
            eventKey: "event", state: .received, queuedAt: Date(), startedAt: nil, settledAt: nil, sessionID: nil,
            managedWorkspaceID: nil, holdReason: nil, result: nil, boundedDiagnostic: nil)
        XCTAssertTrue(run.canWaitForRelease(under: event))
        XCTAssertFalse(run.canWaitForRelease(under: scheduled))
        run.initiatedManually = true
        XCTAssertFalse(run.canWaitForRelease(under: event))
    }

    func testEditorRefusesToMoveAnAutomationToAnotherProject() throws {
        let remaining = Project(name: "Other", folderURL: URL(fileURLWithPath: "/tmp/other"))
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Report"; config.instructions = "Summarize"
        let orphaned = AutomationEditorViewController(configuration: config, projects: [remaining], choices: AutomationEditorChoicesTests.fixture)
        _ = orphaned.view
        XCTAssertThrowsError(try orphaned.submission()) { error in
            XCTAssertEqual(error as? AutomationEditorError, .projectUnavailable)
        }

        config.projectID = remaining.id
        let current = AutomationEditorViewController(configuration: config, projects: [remaining], choices: AutomationEditorChoicesTests.fixture)
        _ = current.view
        XCTAssertEqual(try current.submission().0?.projectID, remaining.id)
    }

    func testEditorRefusesToMoveAnEventRuleToAnotherSource() throws {
        let project = Project(name: "App", folderURL: URL(fileURLWithPath: "/tmp/app"))
        let other = TriggerSourceInstallation(id: TriggerSourceInstallationID(), sourceType: "test", displayName: "Other",
            configuration: [:], credentialReference: nil, enabled: true, health: .healthy, lastCheckedAt: nil,
            lastEventAt: nil, boundedDiagnostic: nil, createdAt: Date(), updatedAt: Date())
        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Review"; config.instructions = "Assess"
        config.executionMode = .assessOnly
        config.options.schedule = nil
        config.sourceID = TriggerSourceInstallationID()
        config.eventKind = "review.required"
        let editor = AutomationEditorViewController(configuration: config, sources: [other], projects: [project], choices: AutomationEditorChoicesTests.fixture)
        _ = editor.view
        XCTAssertThrowsError(try editor.submission()) { error in
            XCTAssertEqual(error as? AutomationEditorError, .sourceUnavailable)
        }
    }

    private func revision(schedule: AutomationSchedule?) -> TriggerRevision {
        var revision = TriggerRevision(id: TriggerRevisionID(), triggerID: TriggerID(), sequence: 1,
            sourceInstallationID: TriggerSourceInstallationID(), eventKind: "test", conditions: [],
            projectID: ProjectID(), instructions: "Assess", agentKind: .codex, accountHandleName: nil,
            model: nil, reasoningEffort: nil, executionMode: .assessOnly, checkoutPolicy: .projectCheckout,
            limits: .conservative, quietHours: nil, notifications: .standard, allowSourceResources: false,
            proposedBySessionID: nil, createdAt: Date())
        revision.automation = .init(schedule: schedule, missedRunPolicy: .skip, archiveOnSuccess: false)
        return revision
    }
}
