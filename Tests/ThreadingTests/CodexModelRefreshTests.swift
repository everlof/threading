import XCTest
@testable import Threading

final class CodexModelRefreshTests: XCTestCase {
    func testFetchPagesPreservesCapabilitiesAndNeverStartsATurn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try await Task.detached {
            try CodexModelCatalogClient.fetch(plan: fixture.plan())
        }.value
        XCTAssertEqual(catalog.version, "0.153.4")
        XCTAssertEqual(catalog.options.map(\.identifier), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(catalog.options[0].fastServiceTier, "priority")
        XCTAssertEqual(catalog.options[0].defaultServiceTier, "priority")
        XCTAssertEqual(catalog.options[0].defaultReasoningLevel, "ultra")
        XCTAssertEqual(catalog.options[0].reasoningLevels.map(\.effort), ["low", "ultra"])
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["initialize", "initialized", "model/list", "model/list"])
    }

    func testTimeoutMalformedPaginationAndOutputCeilingReapTheHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (mode, expected) in [
            ("hang", CodexModelRefreshError.timedOut),
            ("malformed", .malformed),
            ("cursor-loop", .malformed),
            ("flood", .tooLarge),
            ("rpc-error", .unavailable)
        ] {
            do {
                _ = try await Task.detached {
                    try CodexModelCatalogClient.fetch(plan: fixture.plan(mode), timeout: mode == "hang" ? 0.5 : 3)
                }.value
                XCTFail("\(mode) should fail")
            } catch {
                XCTAssertEqual(error as? CodexModelRefreshError, expected, mode)
            }
        }
    }

    func testWrongAccountHomeIsRefusedBeforeRequestingModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            _ = try await Task.detached {
                try CodexModelCatalogClient.fetch(plan: fixture.plan("wrong-home"), expectedHome: fixture.root.path)
            }.value
            XCTFail("A different account home must not populate this account's catalog")
        } catch {
            XCTAssertEqual(error as? CodexModelRefreshError, .accountMismatch)
        }
        XCTAssertEqual(try String(contentsOf: fixture.log, encoding: .utf8), "initialize\n")
    }

    func testStressCatalogStaysWithinEightPagesAnd512Models() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = Date()
        let catalog = try await Task.detached {
            try CodexModelCatalogClient.fetch(plan: fixture.plan("stress"))
        }.value
        XCTAssertEqual(catalog.options.count, 512)
        XCTAssertEqual(Set(catalog.options.map(\.identifier)).count, 512)
        print("Codex model refresh: 512 models / 8 pages in \(Date().timeIntervalSince(started)) s (including helper startup)")
    }

    func testSavedDirectCatalogSurvivesOlderWriterAndRestartButAcceptsANewerCLI() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = fixture.account
        let storeURL = fixture.root.appendingPathComponent("catalog.json")
        let store = CodexModelCatalogStore { storeURL }
        let catalog = try await Task.detached {
            try CodexModelCatalogClient.fetch(plan: fixture.plan())
        }.value
        let entry = CodexModelCatalogStore.Entry(
            catalog: catalog, refreshedAt: Date(timeIntervalSince1970: 100),
            authentication: CodexModelCatalogStore.authenticationIdentity(for: account)
        )
        let saved = await store.record(entry, for: account)
        XCTAssertTrue(saved)
        let reloaded = CodexModelCatalogStore { storeURL }
        await reloaded.finishLoading()
        XCTAssertEqual(reloaded.entry(for: account), entry)

        try fixture.writeCache(version: "0.150.0", model: "gpt-old")
        XCTAssertEqual(AgentModels.codexCatalog(account: account, store: reloaded), catalog.options)
        // The remembered-file fast path must make the same precedence decision.
        XCTAssertEqual(AgentModels.codexCatalog(account: account, store: reloaded), catalog.options)
        try fixture.writeCache(version: "0.153.10", model: "gpt-next")
        XCTAssertEqual(AgentModels.codexCatalog(account: account, store: reloaded).map(\.identifier), ["gpt-next"])
        try fixture.writeCache(version: "0.153.4", model: "gpt-current")
        XCTAssertEqual(AgentModels.codexCatalog(account: account, store: reloaded).map(\.identifier), ["gpt-current"])

        try fixture.writeCache(version: "0.150.0", model: "gpt-other-login")
        try Data("new login at same path".utf8).write(to: fixture.root.appendingPathComponent("auth.json"))
        XCTAssertEqual(AgentModels.codexCatalog(account: account, store: reloaded).map(\.identifier), ["gpt-other-login"])
    }

    @MainActor
    func testOneRefreshAtATimeAndPartialFailuresDoNotStopOtherAccounts() async throws {
        let account = AgentAccount(provider: .codex, handle: .named("test"), configPath: "/tmp/test")
        let calls = Calls()
        let service = CodexModelRefreshService(
            accountsProvider: { [account, account, account] },
            refresh: { _, _ in
                let count = await calls.next()
                if count == 2 { throw CodexModelRefreshError.timedOut }
                return 8
            }
        )
        let completed = expectation(description: "Finished")
        XCTAssertTrue(service.start { _ in completed.fulfill() })
        XCTAssertFalse(service.start())
        await fulfillment(of: [completed], timeout: 3)
        guard case .finished(let outcomes) = service.state else { return XCTFail("No outcomes") }
        XCTAssertEqual(outcomes.map(\.modelCount), [8, 0, 8])
        XCTAssertEqual(outcomes.map(\.failure), [nil, .timedOut, nil])
        XCTAssertFalse(service.state.isRunning)
    }

    @MainActor
    func testNoAccountsAndAccountCeilingRunNoHelper() async {
        let account = AgentAccount(provider: .codex, handle: .standard, configPath: "/tmp/test")
        for count in [0, CodexModelCatalogStore.maximumAccounts + 1] {
            let service = CodexModelRefreshService(
                accountsProvider: { Array(repeating: account, count: count) },
                refresh: { _, _ in XCTFail("Must not launch"); return 0 }
            )
            let done = expectation(description: "Refusal")
            service.start { _ in done.fulfill() }
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(service.state, count == 0 ? .unavailable : .tooManyAccounts)
        }
    }

    @MainActor
    func testLaunchRoutesDefaultAndAlternateAccountsExplicitly() {
        let standard = AgentAccount(provider: .codex, handle: .standard, configPath: "/tmp/default")
        let alternate = AgentAccount(provider: .codex, handle: .named("work"), configPath: "/tmp/a ' work")
        let defaultPlan = AgentLauncher.codexAccountAppServerPlan(for: standard)
        let alternatePlan = AgentLauncher.codexAccountAppServerPlan(for: alternate)
        XCTAssertTrue(defaultPlan.arguments.last?.contains("'env' '-u' 'CODEX_HOME'") == true)
        XCTAssertTrue(alternatePlan.arguments.last?.contains("CODEX_HOME=") == true)
        XCTAssertFalse(alternatePlan.arguments.last?.contains("'env' '-u' 'CODEX_HOME'") == true)
    }

    @MainActor
    func testInstalledCLIModelDiscoveryWhenExplicitlyRequested() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_STRESS"] == "codex-model-refresh-live")
        let account = AgentAccount(
            provider: .codex, handle: .standard,
            configPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        )
        let plan = AgentLauncher.codexAccountAppServerPlan(for: account)
        let catalog = try await Task.detached {
            try CodexModelCatalogClient.fetch(plan: plan, expectedHome: account.configPath)
        }.value
        XCTAssertFalse(catalog.options.isEmpty)
        XCTAssertTrue(catalog.options.contains { !$0.reasoningLevels.isEmpty })
        print("Live installed Codex \(catalog.version): \(catalog.options.map(\.identifier).joined(separator: ", "))")
    }

    private actor Calls {
        var count = 0
        func next() -> Int { count += 1; return count }
    }

    private struct Fixture: Sendable {
        let root: URL
        let script: URL
        let log: URL
        var account: AgentAccount {
            AgentAccount(provider: .codex, handle: .named("test"), configPath: root.path)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            script = root.appendingPathComponent("server.py")
            log = root.appendingPathComponent("calls.txt")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("fixture login".utf8).write(to: root.appendingPathComponent("auth.json"))
            try Self.source.write(to: script, atomically: true, encoding: .utf8)
        }

        func plan(_ mode: String = "normal") -> AgentLaunchPlan {
            AgentLaunchPlan(executable: "/usr/bin/python3", arguments: [script.path, log.path, mode], resumeState: .unavailable)
        }

        func writeCache(version: String, model: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "client_version": version,
                "models": [["slug": model, "display_name": model, "visibility": "list"]]
            ])
            try data.write(to: root.appendingPathComponent(AgentDefaults.codexModelsCacheFile), options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        static let source = #"""
        import json, sys, time
        mode = sys.argv[2]
        def emit(value):
            print(json.dumps(value), flush=True)
        def model(name):
            return {'model': name, 'displayName': name, 'hidden': False,
                    'serviceTiers': [{'id':'priority', 'name':'Fast'}],
                    'defaultServiceTier':'priority', 'defaultReasoningEffort':'ultra',
                    'supportedReasoningEfforts':[{'reasoningEffort':e, 'description':e} for e in ['low','ultra']]}
        for line in sys.stdin:
            req = json.loads(line)
            method = req.get('method')
            with open(sys.argv[1], 'a') as f: f.write(method + '\n')
            if method == 'initialize':
                result = {'userAgent':'threading/0.153.4 (test)'}
                if mode == 'wrong-home': result['codexHome'] = '/tmp/different-account'
                emit({'id':req['id'], 'result':result})
            elif method == 'model/list':
                assert req['params']['includeHidden'] == False
                assert req['params']['limit'] == 64
                if mode == 'hang': time.sleep(60)
                elif mode == 'malformed': emit({'id':req['id'], 'result':{'data':'bad'}})
                elif mode == 'flood': print('x' * (3 * 1024 * 1024), flush=True)
                elif mode == 'rpc-error': emit({'id':req['id'], 'error':{'code':-1, 'message':'private diagnostic'}})
                elif mode == 'stress':
                    page = int(req['params'].get('cursor', '0'))
                    emit({'id':req['id'], 'result':{'data':[model('m-'+str(page*64+i)) for i in range(64)],
                          'nextCursor':str(page+1) if page<7 else None}})
                else:
                    next_page = req['params'].get('cursor')
                    emit({'id':req['id'], 'result':{'data':[model('gpt-5.6-sol')] if next_page else [model('gpt-6-astra'), None],
                          'nextCursor':'next' if mode=='cursor-loop' or not next_page else None}})
        """#
    }
}
