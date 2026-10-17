import AppKit
import XCTest
@testable import Threading

/// Where an unattended run is drawn, and the one rule behind it: a run may use a terminal only
/// where nothing in that terminal can stop and wait for a person.
///
/// The surface belongs to the approved revision because it decides how the run's permission
/// questions are answered. So the cases pin who may choose a terminal for which mode, that a
/// revision saved before the choice existed still reads as chat, that the store and the editor
/// hand back exactly what was chosen, that the approval sheet names it, and that a terminal is
/// brokered for exactly as long as a run owns it.
@MainActor
final class AutomationSurfaceTests: XCTestCase {

    private var sessions: [SessionID] = []
    private var reportedLifecycle = false

    override func setUp() {
        super.setUp()
        reportedLifecycle = AppSettings.shared.reportsClaudeLifecycleEvents
    }

    override func tearDown() {
        AppSettings.shared.reportsClaudeLifecycleEvents = reportedLifecycle
        for session in sessions {
            UnattendedRunPermissions.unregister(session)
            MCPSessionRegistry.remove(sessionID: session)
        }
        super.tearDown()
    }

    // MARK: - Who may run where

    func testChatAdmitsEveryAgentAndMode() {
        for agent in AgentKind.allCases {
            for mode in TriggerExecutionMode.allCases {
                XCTAssertTrue(AutomationSurface.chat.admits(agent, mode: mode), "\(agent) \(mode)")
            }
        }
    }

    /// Claude's hook answers every question its terminal would ask, so every single-stage mode
    /// may run there.
    func testClaudeRunsEverySingleStageModeInItsTerminal() {
        for mode in [TriggerExecutionMode.taskReadOnly, .taskLocalEdits, .assessOnly] {
            XCTAssertNoThrow(try AutomationSurface.terminal.validate(agent: .claude, mode: mode), "\(mode)")
        }
    }

    /// Codex asks for edit approvals in its terminal, and nothing there can answer them.
    func testCodexRunsOnlyReadOnlyModesInItsTerminal() {
        XCTAssertNoThrow(try AutomationSurface.terminal.validate(agent: .codex, mode: .taskReadOnly))
        XCTAssertNoThrow(try AutomationSurface.terminal.validate(agent: .codex, mode: .assessOnly))
        XCTAssertThrowsError(try AutomationSurface.terminal.validate(agent: .codex, mode: .taskLocalEdits)) {
            XCTAssertEqual($0 as? AutomationSurfaceError,
                           .terminalNeedsReadOnlyMode(agent: AgentKind.codex.displayName))
        }
    }

    /// The fix stage is a second prompt into the same conversation, which a terminal launch
    /// never delivers — whichever agent it is.
    func testAssessThenFixStaysInChatForEveryAgent() {
        for agent in [AgentKind.claude, .codex] {
            XCTAssertThrowsError(try AutomationSurface.terminal.validate(agent: agent, mode: .assessThenFix)) {
                XCTAssertEqual($0 as? AutomationSurfaceError, .terminalHasOneStage, "\(agent)")
            }
        }
    }

    func testAnAgentWithoutAnAnswerableTerminalIsRefused() {
        XCTAssertThrowsError(try AutomationSurface.terminal.validate(agent: .grok, mode: .taskReadOnly)) {
            XCTAssertEqual($0 as? AutomationSurfaceError,
                           .terminalUnavailable(agent: AgentKind.grok.displayName))
        }
    }

    // MARK: - Persistence

    /// Chat is written as no key at all, so a revision that never chose the terminal is the same
    /// JSON it was before the choice existed, and one saved then still reads as chat.
    func testARevisionWithoutASurfaceReadsAsChat() throws {
        let revision = AutomationApprovalSheetRenderTests.scheduleRevision(account: nil)
        let data = try JSONEncoder().encode(revision)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["surface"])
        XCTAssertEqual(try JSONDecoder().decode(TriggerRevision.self, from: data).effectiveSurface, .chat)

        var terminal = revision
        terminal.surface = .terminal
        let restored = try JSONDecoder().decode(TriggerRevision.self, from: JSONEncoder().encode(terminal))
        XCTAssertEqual(restored.effectiveSurface, .terminal)
    }

    func testAProjectFileWithoutASurfaceReadsAsChat() throws {
        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Readiness"
        let file = ProjectAutomation(id: "readiness", configuration: config, source: nil)
        let data = try JSONEncoder().encode(file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["surface"], "an automation.json that never chose the terminal changed")

        config.surface = .terminal
        let chosen = ProjectAutomation(id: "readiness", configuration: config, source: nil)
        let restored = try JSONDecoder().decode(ProjectAutomation.self, from: JSONEncoder().encode(chosen))
        XCTAssertEqual(restored.surface, .terminal)
    }

    func testTheStoreKeepsTheSurfaceAndRefusesOneTheAgentCannotHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-surface-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TriggerStore(url: directory.appendingPathComponent("db"))
        addTeardownBlock { await store.close(); try? FileManager.default.removeItem(at: directory) }

        var config = AutomationConfiguration(projectID: ProjectID())
        config.name = "Ordus rollout readiness"; config.instructions = "Report rollout readiness."
        config.agent = .codex; config.executionMode = .taskReadOnly; config.surface = .terminal
        let id = TriggerID()
        let saved = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        XCTAssertEqual(saved.effectiveSurface, .terminal)
        let pair = try await store.trigger(id: id)
        let stored = try XCTUnwrap(pair)
        XCTAssertEqual(AutomationConfiguration(definition: stored.definition, revision: stored.revision).surface,
                       .terminal, "editing the automation would lose its surface")

        config.executionMode = .assessThenFix
        do {
            _ = try await store.configureAutomation(config, id: id, expectedRevision: saved.id, proposedBy: nil)
            XCTFail("a terminal that cannot take the fix stage was saved")
        } catch {
            XCTAssertEqual(error as? AutomationSurfaceError, .terminalHasOneStage)
        }
        let unchanged = try await store.trigger(id: id)
        XCTAssertEqual(unchanged?.revision.id, saved.id)
    }

    // MARK: - Editor and approval

    func testTheEditorSubmitsTheSurfaceItShows() throws {
        let form = editor(surface: nil)
        XCTAssertNil(try form.submission().0?.surface, "chat must be saved as no choice at all")

        let choice = try popUp("automation.surface", in: form)
        XCTAssertEqual((0..<choice.numberOfItems).compactMap { choice.item(at: $0)?.title },
                       [L10n.string("Chat"), L10n.string("Terminal")])
        choice.selectItem(at: 1)
        XCTAssertEqual(try form.submission().0?.surface, .terminal)

        XCTAssertEqual(try popUp("automation.surface", in: editor(surface: .terminal)).indexOfSelectedItem, 1)
    }

    func testTheApprovalSheetNamesWhereARunIsDrawn() {
        let context = AutomationApprovalSheetRenderTests.context()
        var revision = AutomationApprovalSheetRenderTests.scheduleRevision(account: "claude-sonda-02")
        let chat = AutomationReview.make(revision, purpose: .enable, context: context)
            .facts.first { $0.identifier == "surface" }
        XCTAssertEqual(chat?.value, L10n.string("Chat"))
        XCTAssertNil(chat?.detail)

        revision.surface = .terminal
        let terminal = AutomationReview.make(revision, purpose: .enable, context: context)
            .facts.first { $0.identifier == "surface" }
        XCTAssertEqual(terminal?.value, L10n.string("Terminal"))
        XCTAssertEqual(terminal?.detail, L10n.string(
            "The agent’s own terminal. Its permission questions are answered from this revision, as in Chat."))
    }

    // MARK: - Launch

    /// A Claude terminal owned by a run carries the broker and the turn reports the run settles
    /// on, even with lifecycle reporting switched off; the same session without a run carries
    /// neither, so the person keeps Claude's own prompt.
    func testAClaudeTerminalIsBrokeredOnlyWhileARunOwnsIt() throws {
        AppSettings.shared.reportsClaudeLifecycleEvents = false
        let session = AgentSession(kind: .claude, title: "run")
        sessions.append(session.id)
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        XCTAssertFalse(try brokerHooks(in: AgentLauncher.plan(for: session, in: project)).brokered)

        UnattendedRunPermissions.register(.init(policy: .readOnly, revisionSequence: 4), for: session.id)
        let plan = try AgentLauncher.plan(for: session, in: project)
        let hooks = try brokerHooks(in: plan)
        XCTAssertTrue(hooks.brokered, "an unattended terminal would wait at Claude's own prompt")
        XCTAssertTrue(hooks.reportsTurns, "the run could not see its turn end")
        XCTAssertTrue(try XCTUnwrap(plan.arguments.last).contains("\(MCPDefaults.brokerEnvironmentKey)=1"))
    }

    /// Codex's shared `hooks.json` reaches the broker only for a launch that exports the variable.
    func testACodexTerminalExportsTheBrokerOnlyWhileARunOwnsIt() throws {
        let session = AgentSession(kind: .codex, title: "run")
        sessions.append(session.id)
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let variable = "\(MCPDefaults.brokerEnvironmentKey)=1"

        XCTAssertFalse(try XCTUnwrap(AgentLauncher.plan(for: session, in: project).arguments.last).contains(variable))
        UnattendedRunPermissions.register(.init(policy: .readOnly, revisionSequence: 4), for: session.id)
        XCTAssertTrue(try XCTUnwrap(AgentLauncher.plan(for: session, in: project).arguments.last).contains(variable))
    }

    // MARK: - Helpers

    private func editor(surface: AutomationSurface?) -> AutomationEditorViewController {
        let project = Project(name: "wordy-live-rules-sim", folderURL: URL(fileURLWithPath: "/tmp/wordy-live-rules-sim"))
        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Ordus rollout readiness"; config.instructions = "Report rollout readiness."
        config.agent = .codex; config.executionMode = .taskReadOnly; config.surface = surface
        let editor = AutomationEditorViewController(
            configuration: config, projects: [project], choices: AutomationEditorChoicesTests.fixture)
        _ = editor.view
        return editor
    }

    private func popUp(_ identifier: String, in form: AutomationEditorViewController) throws -> ThemedPopUp {
        func find(_ view: NSView) -> ThemedPopUp? {
            if let control = view as? ThemedPopUp, control.accessibilityIdentifier() == identifier { return control }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try XCTUnwrap(find(form.view))
    }

    /// Reads the settings file a Claude launch names: whether its `PreToolUse` reaches the
    /// broker, and whether it reports the turn ending.
    private func brokerHooks(in plan: AgentLaunchPlan) throws -> (brokered: Bool, reportsTurns: Bool) {
        let command = try XCTUnwrap(plan.arguments.last)
        let pattern = #"'?--settings'? (?:'([^']+)'|(\S+))"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = [1, 2].lazy.compactMap({ Range(match.range(at: $0), in: command) }).first else {
            return (false, false)
        }
        let path = String(command[range])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let preToolUse = (hooks["PreToolUse"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        return (preToolUse.contains { $0.contains(MCPDefaults.permissionPathPrefix) }, hooks["Stop"] != nil)
    }
}
