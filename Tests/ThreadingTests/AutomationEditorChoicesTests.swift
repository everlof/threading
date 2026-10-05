import AppKit
import XCTest
@testable import Threading

@MainActor
final class AutomationEditorChoicesTests: XCTestCase {
    nonisolated static let codexModels = [
        option("catalog-sol", name: "Sol", efforts: ["high", "ultra"]),
        option("catalog-luna", name: "Luna", efforts: ["low", "medium"])
    ]

    static var fixture: AutomationAgentChoiceProvider {
        AutomationAgentChoiceProvider(
            accounts: { kind in
                [AgentAccount(provider: kind, handle: .standard, configPath: "/tmp/fixture-default", displayName: "Personal"),
                 AgentAccount(provider: kind, handle: .named("work"), configPath: "/tmp/fixture-work", displayName: "Work"),
                 AgentAccount(provider: kind, handle: .named("expired"), configPath: "/tmp/fixture-expired", displayName: "Old login"),
                 AgentAccount(provider: kind, handle: .named("hidden"), configPath: "/tmp/fixture-hidden", displayName: "Hidden", isEnabled: false)]
            },
            catalog: { kind, account in
                if kind == .claude {
                    return .init(models: [option("catalog-opus", name: "Opus", efforts: ["high", "max"])], defaultModel: "catalog-opus")
                }
                let models = account?.handle == .named("work") ? [codexModels[1]] : codexModels
                return .init(models: models, defaultModel: models.first?.identifier)
            },
            signInStatus: { account, _ in account.handle == .named("expired") ? .signedOut : .signedIn },
            authenticationRefused: { _ in false })
    }

    nonisolated private static func option(_ id: String, name: String, efforts: [String]) -> AgentModelOption {
        .init(identifier: id, displayName: name, fastServiceTier: nil, defaultServiceTier: nil,
              reasoningLevels: efforts.map { .init(effort: $0, description: "") })
    }

    private func editor(model: String? = nil, effort: String? = nil, account: String? = nil, choices: AutomationAgentChoiceProvider? = nil) -> AutomationEditorViewController {
        let project = Project(name: "Report project", folderURL: URL(fileURLWithPath: "/tmp/automation-choices"))
        var config = AutomationConfiguration(projectID: project.id)
        config.name = "Morning report"; config.instructions = "Summarize yesterday."
        config.model = model; config.reasoningEffort = effort; config.account = account
        return AutomationEditorViewController(configuration: config, projects: [project], choices: choices ?? Self.fixture)
    }

    func testLateCatalogCannotReplaceTheNewAgentsChoices() async throws {
        let gate = SuspendedCatalog()
        var provider = Self.fixture
        let ordinary = provider.catalog
        provider.catalog = { kind, account in
            if kind == .codex { return await gate.read() }
            return await ordinary(kind, account)
        }
        let form = editor(choices: provider)
        let originalPreparation = Task { await form.prepareAgentChoices() }
        await gate.waitUntilStarted()
        let agent = try popUp("automation.agent", in: form)
        agent.chooseItem(at: try XCTUnwrap(agent.indexOfItem { $0.title == AgentKind.claude.displayName }))
        await form.prepareAgentChoices()
        XCTAssertEqual(titles(try popUp("automation.model", in: form)), ["Default", "Opus"])
        await gate.finish()
        await originalPreparation.value
        XCTAssertEqual(titles(try popUp("automation.model", in: form)), ["Default", "Opus"])
        XCTAssertEqual(try form.submission().0?.agent, .claude)
    }

    func testChoicesUseCatalogIdentifiersAndModelSpecificEfforts() async throws {
        let form = editor()
        await form.prepareAgentChoices()
        let model = try popUp("automation.model", in: form)
        let effort = try popUp("automation.effort", in: form)
        XCTAssertEqual(titles(model), ["Default", "Sol", "Luna"])
        XCTAssertEqual(titles(effort), ["Default", "High", "Ultra"])
        XCTAssertNil(try form.submission().0?.model)
        XCTAssertNil(try form.submission().0?.reasoningEffort)
        model.chooseItem(at: 1); effort.chooseItem(at: 2)
        XCTAssertEqual(try form.submission().0?.model, "catalog-sol")
        XCTAssertEqual(try form.submission().0?.reasoningEffort, "ultra")
        model.chooseItem(at: 2)
        XCTAssertEqual(titles(effort), ["Default", "Light", "Medium"])
        XCTAssertNil(try form.submission().0?.reasoningEffort, "Changing models cannot carry an unsupported effort")
        effort.chooseItem(at: 1)
        XCTAssertEqual(try form.submission().0?.reasoningEffort, "low")
    }

    func testAccountsMarkLogoutAndSelectingAnotherAgentClearsForeignChoices() async throws {
        let form = editor(model: "catalog-sol", effort: "ultra")
        await form.prepareAgentChoices()
        let account = try popUp("automation.account", in: form)
        XCTAssertEqual(titles(account), ["Default — Personal", "Work", "Old login — Signed out"])
        account.chooseItem(at: 1)
        await form.prepareAgentChoices()
        XCTAssertEqual(try form.submission().0?.account, "work")
        XCTAssertTrue(titles(try popUp("automation.model", in: form)).contains("catalog-sol — Custom"))
        let agent = try popUp("automation.agent", in: form)
        agent.chooseItem(at: try XCTUnwrap(agent.indexOfItem { $0.title == AgentKind.claude.displayName }))
        await form.prepareAgentChoices()
        XCTAssertEqual(titles(try popUp("automation.model", in: form)), ["Default", "Opus"])
        XCTAssertEqual(titles(try popUp("automation.effort", in: form)), ["Default", "High", "Max"])
        let result = try XCTUnwrap(form.submission().0)
        XCTAssertEqual(result.agent, .claude)
        XCTAssertNil(result.account); XCTAssertNil(result.model); XCTAssertNil(result.reasoningEffort)
    }

    func testUnavailableSavedValuesSurviveOpeningAndSaving() async throws {
        let form = editor(model: "retired-model", effort: "future-effort", account: "removed-login")
        // A save during preparation preserves exactly the same saved identifiers.
        _ = form.view
        XCTAssertEqual(try form.submission().0?.model, "retired-model")
        await form.prepareAgentChoices()
        XCTAssertEqual(try popUp("automation.account", in: form).selectedItem?.title, "removed-login — Unavailable")
        XCTAssertEqual(titles(try popUp("automation.model", in: form)), ["Default", "retired-model — Custom"])
        XCTAssertEqual(try popUp("automation.effort", in: form).selectedItem?.title, "future-effort — Custom")
        let result = try XCTUnwrap(form.submission().0)
        XCTAssertEqual(result.account, "removed-login")
        XCTAssertEqual(result.model, "retired-model"); XCTAssertEqual(result.reasoningEffort, "future-effort")
    }

    func testASavedCustomEntryStaysSelectableAfterChoosingSomethingElse() async throws {
        let form = editor(model: "retired-model", effort: "future-effort", account: "removed-login")
        await form.prepareAgentChoices()
        let model = try popUp("automation.model", in: form)
        let effort = try popUp("automation.effort", in: form)
        let account = try popUp("automation.account", in: form)

        // The saved login is not on this Mac, so it offers no catalog; choose the standard one.
        account.chooseItem(at: 0)
        await form.prepareAgentChoices()
        // Choose catalog entries, then make each menu rebuild: another login reloads the model
        // catalog (Work lists only Luna), and another model rebuilds the efforts.
        model.chooseItem(at: try XCTUnwrap(model.indexOfItem { $0.title == "Sol" }))
        account.chooseItem(at: try XCTUnwrap(account.indexOfItem { $0.title == "Work" }))
        await form.prepareAgentChoices()
        XCTAssertTrue(titles(account).contains("removed-login — Unavailable"), "\(titles(account))")
        XCTAssertTrue(titles(model).contains("retired-model — Custom"), "\(titles(model))")
        model.chooseItem(at: try XCTUnwrap(model.indexOfItem { $0.title == "Luna" }))
        XCTAssertTrue(titles(effort).contains("future-effort — Custom"), "\(titles(effort))")
        XCTAssertNil(try form.submission().0?.reasoningEffort, "a model change still clears an unsupported effort")

        model.chooseItem(at: try XCTUnwrap(model.indexOfItem { $0.title == "retired-model — Custom" }))
        effort.chooseItem(at: try XCTUnwrap(effort.indexOfItem { $0.title == "future-effort — Custom" }))
        account.chooseItem(at: try XCTUnwrap(account.indexOfItem { $0.title == "removed-login — Unavailable" }))
        await form.prepareAgentChoices()
        let result = try XCTUnwrap(form.submission().0)
        XCTAssertEqual(result.account, "removed-login")
        XCTAssertEqual(result.model, "retired-model")
        XCTAssertEqual(result.reasoningEffort, "future-effort")

        // Another agent's menus never carry these identifiers.
        let agent = try popUp("automation.agent", in: form)
        agent.chooseItem(at: try XCTUnwrap(agent.indexOfItem { $0.title == AgentKind.claude.displayName }))
        await form.prepareAgentChoices()
        XCTAssertFalse(titles(model).contains { $0.hasPrefix("retired-model") })
        XCTAssertFalse(titles(account).contains { $0.hasPrefix("removed-login") })
    }

    func testTheStoredStandardAliasSelectsDefaultAndADisabledSavedLoginStaysVisible() async throws {
        let standard = editor(account: AccountHandle.standardName)
        await standard.prepareAgentChoices()
        XCTAssertEqual(try popUp("automation.account", in: standard).indexOfSelectedItem, 0)
        XCTAssertNil(try standard.submission().0?.account)
        let disabled = editor(account: "hidden")
        await disabled.prepareAgentChoices()
        XCTAssertEqual(try popUp("automation.account", in: disabled).selectedItem?.title, "Hidden — Disabled")
        XCTAssertEqual(try disabled.submission().0?.account, "hidden")
    }

    func testProviderStatusNeedsExplicitLogoutRatherThanAnArbitraryFailure() {
        func result(_ text: String, exit: Int32, truncated: Bool = false) -> BoundedChildResult {
            .init(output: Data(text.utf8), outputWasTruncated: truncated, termination: .exited(exit))
        }
        XCTAssertEqual(AgentAccountSetupProvider.claude.signInStatus(result("{\"loggedIn\":false}", exit: 1)), .signedOut)
        XCTAssertEqual(AgentAccountSetupProvider.claude.signInStatus(result("{\"loggedIn\":true}", exit: 0)), .signedIn)
        XCTAssertEqual(AgentAccountSetupProvider.claude.signInStatus(result("broken JSON", exit: 1)), .unavailable)
        XCTAssertEqual(AgentAccountSetupProvider.claude.signInStatus(result("{\"loggedIn\":1}", exit: 0)), .unavailable)
        XCTAssertEqual(AgentAccountSetupProvider.claude.signInStatus(result("{\"loggedIn\":false}", exit: 1, truncated: true)), .unavailable)
        XCTAssertEqual(AgentAccountSetupProvider.codex.signInStatus(result("Not logged in\n", exit: 1)), .signedOut)
        XCTAssertEqual(AgentAccountSetupProvider.codex.signInStatus(result("Failed to read configuration", exit: 1)), .unavailable)
        XCTAssertEqual(AgentAccountSetupProvider.codex.signInStatus(result("command not found", exit: 127)), .unavailable)
        XCTAssertEqual(AgentAccountSetupProvider.codex.existingLoginStatusArguments, ["login", "status"])
    }

    func testUsageFailuresDoNotMislabelAnUnreadableLoginAsSignedOut() {
        XCTAssertTrue(AutomationAgentChoiceProvider.authenticationWasRefused(.tokenExpired))
        XCTAssertTrue(AutomationAgentChoiceProvider.authenticationWasRefused(.http(status: 401)))
        XCTAssertFalse(AutomationAgentChoiceProvider.authenticationWasRefused(.noCredential("No readable usage source")))
        XCTAssertFalse(AutomationAgentChoiceProvider.authenticationWasRefused(.network("Offline")))
        XCTAssertFalse(AutomationAgentChoiceProvider.authenticationWasRefused(.http(status: 403)))
        XCTAssertFalse(AutomationAgentChoiceProvider.authenticationWasRefused(nil))
    }

    private func titles(_ control: ThemedPopUp) -> [String] {
        (0..<control.numberOfItems).compactMap { control.item(at: $0)?.title }
    }

    private func popUp(_ identifier: String, in form: AutomationEditorViewController) throws -> ThemedPopUp {
        func find(_ view: NSView) -> ThemedPopUp? {
            if let control = view as? ThemedPopUp, control.accessibilityIdentifier() == identifier { return control }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try XCTUnwrap(find(form.view))
    }
}

private actor SuspendedCatalog {
    private var pending: CheckedContinuation<AutomationAgentCatalog, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func read() async -> AutomationAgentCatalog {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiting?.resume(); waiting = nil
        }
    }

    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func finish() {
        pending?.resume(returning: .init(models: AutomationEditorChoicesTests.codexModels, defaultModel: "catalog-sol"))
        pending = nil
    }
}
