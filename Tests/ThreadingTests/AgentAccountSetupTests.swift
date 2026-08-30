import XCTest
@testable import Threading

@MainActor
final class AgentAccountSetupTests: XCTestCase {

    func testContextNormalizesAReadableNameIntoAnIsolatedProviderHome() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let claude = try XCTUnwrap(AgentAccountSetupCoordinator.newContext(
            provider: .claude,
            displayName: "  Åcme Work / Europe  ",
            homeDirectory: home
        ))
        XCTAssertEqual(claude.displayName, "  Åcme Work / Europe  ")
        XCTAssertEqual(claude.handle, .named("claude-acme-work-europe"))
        XCTAssertEqual(claude.configPath, "/Users/example/.claude-acme-work-europe")
        XCTAssertFalse(claude.isReconnect)

        let codex = try XCTUnwrap(AgentAccountSetupCoordinator.newContext(
            provider: .codex,
            displayName: "Personal #2",
            homeDirectory: home
        ))
        XCTAssertEqual(codex.handle, .named("codex-personal-2"))
        XCTAssertEqual(codex.configPath, "/Users/example/.codex-personal-2")
    }

    func testContextRejectsANameWithoutLettersOrNumbersAndBoundsLongNames() throws {
        XCTAssertNil(AgentAccountSetupCoordinator.newContext(
            provider: .claude,
            displayName: " — / … ",
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        ))

        let context = try XCTUnwrap(AgentAccountSetupCoordinator.newContext(
            provider: .codex,
            displayName: String(repeating: "a", count: 100),
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        ))
        XCTAssertEqual(
            context.handle.name.count,
            ".codex-".dropFirst().count + AgentAccountSetupDefaults.maximumSlugLength
        )
    }

    func testProviderAdaptersUseOfficialLoginAndStatusCommandsUnderDistinctHomes() {
        XCTAssertEqual(AgentAccountSetupProvider.claude.environmentKey, "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(AgentAccountSetupProvider.claude.loginArguments, ["auth", "login"])
        XCTAssertEqual(
            AgentAccountSetupProvider.claude.statusArguments,
            ["auth", "status", "--json"]
        )

        XCTAssertEqual(AgentAccountSetupProvider.codex.environmentKey, "CODEX_HOME")
        XCTAssertEqual(
            AgentAccountSetupProvider.codex.loginArguments,
            ["login", "-c", "cli_auth_credentials_store=\"file\""]
        )
        XCTAssertEqual(
            AgentAccountSetupProvider.codex.statusArguments,
            ["login", "status", "-c", "cli_auth_credentials_store=\"file\""]
        )
        XCTAssertTrue(AgentAccountSetupProvider.allCases.allSatisfy {
            $0.installationGuide.scheme == "https"
        })

        XCTAssertEqual(
            AgentKind.allCases.compactMap(AgentAccountSetupProvider.init(kind:)),
            [.claude, .codex],
            "Only measured isolated-home adapters may grow an Add Login action"
        )
    }

    func testEverySupportedAgentStatesItsSignInBoundary() {
        XCTAssertEqual(AgentKind.allCases.count, 5)
        for kind in AgentKind.allCases {
            XCTAssertFalse(kind.accountAccessDetail.isEmpty, kind.displayName)
            XCTAssertFalse(kind.accountAccessOwner.isEmpty, kind.displayName)
        }
        XCTAssertTrue(AgentKind.grok.accountAccessDetail.contains("one Grok login"))
        XCTAssertTrue(AgentKind.cursor.accountAccessDetail.contains("agent login"))
        XCTAssertTrue(AgentKind.openCode.accountAccessDetail.contains("/connect"))
    }

    func testRegistryPersistsOnlyValidatedLocationsAndDeduplicatesAProviderPath() throws {
        let suite = "AgentAccountSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let registry = AgentAccountLocationRegistry(defaults: defaults)
        XCTAssertTrue(registry.register(
            provider: .claude,
            handle: .named("claude-work"),
            configPath: "/Users/example/.claude-work"
        ))
        XCTAssertTrue(registry.register(
            provider: .claude,
            handle: .named("claude-renamed"),
            configPath: "/Users/example/.claude-work/../.claude-work"
        ))
        XCTAssertFalse(registry.register(
            provider: .codex,
            handle: .standard,
            configPath: "/Users/example/.codex"
        ))

        XCTAssertEqual(registry.records.count, 1)
        XCTAssertEqual(registry.records.first?.handle, .named("claude-renamed"))
        XCTAssertEqual(registry.records.first?.configPath, "/Users/example/.claude-work")

        let reloaded = AgentAccountLocationRegistry(defaults: defaults)
        XCTAssertEqual(reloaded.records, registry.records)
        XCTAssertTrue(reloaded.contains(
            provider: .claude,
            configPath: "/Users/example/.claude-work"
        ))
        XCTAssertTrue(reloaded.records.allSatisfy { !$0.handle.isStandard })
    }
}
