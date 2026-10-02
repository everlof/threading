import XCTest
@testable import Threading

/// A login's long-lived token: what it must look like, where it is kept, and the one way it may
/// reach a child process — its environment, never its command line.
final class AgentAccountTokenTests: XCTestCase {

    private let spec = AgentKind.claude.longLivedToken!
    private let body = String(repeating: "Ab1-_", count: 20)
    private var token: String { spec.prefix + body }

    private let alternate = AgentAccount(
        provider: .claude,
        handle: .named("claude-work"),
        configPath: "/Users/example/.claude-work"
    )
    private let standard = AgentAccount(
        provider: .claude,
        handle: .standard,
        configPath: "/Users/example/.claude"
    )

    // MARK: - Capability

    func testOnlyARuntimeClaimingTheCapabilityDescribesAToken() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                kind.longLivedToken != nil,
                kind.supports(.longLivedAccountToken),
                "\(kind) must describe its token exactly when it claims the capability"
            )
        }
        XCTAssertEqual(spec.environmentKey, "CLAUDE_CODE_OAUTH_TOKEN")
        XCTAssertEqual(spec.mintCommand, "claude setup-token")
        XCTAssertTrue(
            AgentKind.claude.supports(.accounts),
            "A token belongs to a login, so the runtime must route logins"
        )
    }

    // MARK: - Format

    func testATokenCopiedFromAWrappedTerminalIsRejoined() {
        let wrapped = "  " + spec.prefix + String(body.prefix(30)) + "\n  "
            + String(body.dropFirst(30)) + " \n"
        XCTAssertEqual(AgentAccountTokenFormat.normalized(wrapped, for: spec), .success(token))
    }

    func testRejectsWhatIsNotThisRuntimesToken() {
        XCTAssertEqual(AgentAccountTokenFormat.normalized("   \n", for: spec), .failure(.empty))
        XCTAssertEqual(
            AgentAccountTokenFormat.normalized("sk-ant-api03-" + body, for: spec),
            .failure(.notThisRuntimesToken),
            "An API key bills differently and is not a sign-in"
        )
        XCTAssertEqual(
            AgentAccountTokenFormat.normalized("https://claude.ai/oauth/authorize?x=1", for: spec),
            .failure(.notThisRuntimesToken)
        )
        XCTAssertEqual(
            AgentAccountTokenFormat.normalized(spec.prefix + "short", for: spec),
            .failure(.malformed)
        )
        XCTAssertEqual(
            AgentAccountTokenFormat.normalized(spec.prefix + body + "'; rm -rf ~", for: spec),
            .failure(.malformed),
            "Shell syntax is not a token character"
        )
        XCTAssertEqual(
            AgentAccountTokenFormat.normalized(
                spec.prefix + String(repeating: "a", count: AgentAccountTokenFormat.maximumLength),
                for: spec
            ),
            .failure(.malformed)
        )
    }

    // MARK: - Redaction

    func testATokenNeverPrintsItsValue() {
        let saved = AgentAccountToken(value: token, savedAt: Date(timeIntervalSince1970: 0))
        let credentials = AgentCredentialEnvironment([spec.environmentKey: token])

        for rendering in [
            "\(saved)", String(reflecting: saved), String(describing: Mirror(reflecting: saved).children.map(\.value)),
            "\(credentials)", String(reflecting: credentials),
            String(describing: Mirror(reflecting: credentials).children.map(\.value))
        ] {
            XCTAssertFalse(rendering.contains(body), "Leaked a token: \(rendering)")
        }
        XCTAssertTrue("\(credentials)".contains(spec.environmentKey), "The key is not secret")
    }

    // MARK: - Expiry

    func testExpiryIsAYearFromSavingAndWarnsThreeWeeksAhead() {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let entry = AgentAccountToken(value: token, savedAt: saved)

        XCTAssertEqual(entry.expiresAt.timeIntervalSince(saved), 365 * 24 * 60 * 60)
        XCTAssertFalse(entry.isNearExpiry(at: saved.addingTimeInterval(300 * 24 * 60 * 60)))
        XCTAssertTrue(entry.isNearExpiry(at: saved.addingTimeInterval(345 * 24 * 60 * 60)))
        XCTAssertTrue(entry.isNearExpiry(at: entry.expiresAt.addingTimeInterval(1)))
    }

    // MARK: - Store

    func testTheStoreKeepsOneEntryPerLoginWithItsDate() throws {
        let keychain = InMemoryKeychainItemAccess()
        let store = AgentAccountTokenStore(keychain: keychain, service: "test", dataProtection: { false })
        let first = AgentAccountToken(value: token, savedAt: Date(timeIntervalSince1970: 100))

        XCTAssertNil(store.token(for: alternate.id))
        XCTAssertTrue(store.save(first, for: alternate.id))
        XCTAssertEqual(store.token(for: alternate.id), first)
        XCTAssertNil(store.token(for: standard.id), "One login's token is not another's")

        let replacement = AgentAccountToken(value: token + "x", savedAt: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(store.save(replacement, for: alternate.id))
        XCTAssertEqual(store.token(for: alternate.id), replacement)
        XCTAssertEqual(keychain.itemCount, 1, "Saving again replaces the entry")

        XCTAssertTrue(store.save(first, for: standard.id))
        XCTAssertTrue(store.remove(for: alternate.id))
        XCTAssertNil(store.token(for: alternate.id))
        XCTAssertTrue(store.remove(for: alternate.id), "Removing nothing is not a failure")

        try store.removeAll()
        XCTAssertEqual(keychain.itemCount, 0)
    }

    // MARK: - Vault

    func testTheVaultSavesValidatedTokensAndAnnouncesThem() {
        let vault = makeVault()
        let announced = expectation(forNotification: AgentAccountTokensDidChange.name, object: nil)
        let saved = expectation(description: "saved")

        vault.save("  \(token)\n", for: alternate.id) { result in
            XCTAssertEqual(try? result.get().value, self.token)
            saved.fulfill()
        }
        wait(for: [saved, announced], timeout: 5)

        XCTAssertEqual(vault.token(for: alternate.id)?.value, token)
        XCTAssertEqual(vault.cachedToken(for: alternate.id)?.value, token)
        XCTAssertNil(vault.token(for: standard.id))
    }

    func testTheVaultRefusesAMalformedTokenWithoutTouchingTheKeychain() {
        let keychain = InMemoryKeychainItemAccess()
        let vault = makeVault(keychain: keychain)
        let refused = expectation(description: "refused")

        vault.save("sk-ant-api03-\(body)", for: alternate.id) { result in
            XCTAssertEqual(result.failureValue, .format(.notThisRuntimesToken))
            refused.fulfill()
        }
        wait(for: [refused], timeout: 5)
        XCTAssertEqual(keychain.itemCount, 0)
    }

    func testTheVaultRefusesARuntimeWithoutTokens() {
        let vault = makeVault()
        let codex = AgentAccount(provider: .codex, handle: .standard, configPath: "/tmp/codex")
        let refused = expectation(description: "refused")

        vault.save(token, for: codex.id) { result in
            XCTAssertEqual(result.failureValue, .unsupported)
            refused.fulfill()
        }
        wait(for: [refused], timeout: 5)
        XCTAssertNil(vault.token(for: codex.id))
    }

    func testPrepareReadsAheadSoLaunchesAnswerFromMemory() {
        let keychain = InMemoryKeychainItemAccess()
        let store = AgentAccountTokenStore(keychain: keychain, service: "test", dataProtection: { false })
        XCTAssertTrue(store.save(AgentAccountToken(value: token, savedAt: Date()), for: alternate.id))
        let vault = AgentAccountTokenVault(store: store)

        XCTAssertNil(vault.cachedToken(for: alternate.id), "Nothing is read before it is asked for")
        let prepared = expectation(description: "prepared")
        vault.prepare([alternate.id, standard.id]) { prepared.fulfill() }
        wait(for: [prepared], timeout: 5)

        XCTAssertEqual(vault.cachedToken(for: alternate.id)?.value, token)
    }

    func testRemovingReturnsTheLoginToTheBrowserSignIn() {
        let vault = makeVault()
        let saved = expectation(description: "saved")
        vault.save(token, for: alternate.id) { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)

        let removed = expectation(description: "removed")
        vault.remove(for: alternate.id) { succeeded in
            XCTAssertTrue(succeeded)
            removed.fulfill()
        }
        wait(for: [removed], timeout: 5)
        XCTAssertNil(vault.token(for: alternate.id))
    }

    // MARK: - Routing

    func testATokenLoginGetsItsTokenInTheEnvironmentAndNeverInTheCommand() {
        let entry = AgentAccountToken(value: token, savedAt: Date())
        let route = AgentAccountRouting.route(for: .claude, account: alternate, token: entry)

        XCTAssertEqual(route.credentials.entries, [spec.environmentKey: token])
        XCTAssertFalse(route.command.source.contains(body))
        XCTAssertFalse(
            route.command.source.contains(spec.environmentKey),
            "The token variable must not be unset for the login it signs in"
        )
        XCTAssertTrue(route.command.source.contains("CLAUDE_CONFIG_DIR=/Users/example/.claude-work"))
    }

    func testEveryOtherLoginUnsetsAnyTokenItsShellProfileExports() {
        for account in [alternate, standard] {
            let route = AgentAccountRouting.route(for: .claude, account: account, token: nil)
            XCTAssertTrue(route.credentials.isEmpty)
            XCTAssertTrue(
                route.command.source.contains("'-u' '\(spec.environmentKey)'"),
                "A profile-exported token would sign \(account.handle.name) in as someone else: "
                    + route.command.source
            )
        }
    }

    /// macOS env stops parsing options at the first assignment. Execute the route rather than
    /// just checking for -u: an option after CLAUDE_CONFIG_DIR becomes the executable and exits 127.
    func testClaudeAccountRoutesExecuteWithTheSelectedHomeAndToken() throws {
        let accountKey = try XCTUnwrap(AgentKind.claude.accountEnvironmentKey)
        let savedToken = AgentAccountToken(value: token, savedAt: Date())

        for account in [alternate, standard] {
            for entry in [nil, savedToken] {
                let route = AgentAccountRouting.route(for: .claude, account: account, token: entry)
                var command = route.command
                command.append(word: "/usr/bin/env")

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command.source]
                process.environment = route.credentials.applied(to: [
                    accountKey: "/tmp/inherited-account",
                    spec.environmentKey: "profile-exported-token",
                    "PATH": "/usr/bin:/bin"
                ])
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                XCTAssertEqual(process.terminationStatus, 0, command.source)
                let environment: [String: String] = Dictionary(uniqueKeysWithValues:
                    String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { return nil }
                        return (String(parts[0]), String(parts[1]))
                    }
                )
                XCTAssertEqual(environment[accountKey], account.isDefault ? nil : account.configPath)
                XCTAssertEqual(environment[spec.environmentKey], entry?.value)
            }
        }
    }

    func testARuntimeWithoutTokensIsRoutedExactlyAsBefore() {
        let codex = AgentAccount(provider: .codex, handle: .named("codex-work"), configPath: "/tmp/codex-work")
        let route = AgentAccountRouting.route(for: .codex, account: codex, token: nil)

        XCTAssertEqual(route.command.source, "'env' 'CODEX_HOME=/tmp/codex-work'")
        XCTAssertTrue(route.credentials.isEmpty)
    }

    // MARK: - Launch Plans

    func testAPlanCarriesCredentialsToTheChildEnvironmentOnly() {
        let credentials = AgentCredentialEnvironment([spec.environmentKey: token])
        var command = ShellCommand(word: "env")
        command.append(word: "claude")
        let plan = AgentLaunchPlan.inLoginShell(
            command: command,
            in: "/tmp",
            shellPath: "/bin/zsh",
            resumeState: .unavailable,
            credentialEnvironment: credentials
        )

        XCTAssertFalse(plan.arguments.joined(separator: " ").contains(body))
        XCTAssertFalse(plan.executable.contains(body))
        XCTAssertEqual(plan.launchEnvironment()[spec.environmentKey], token)
    }

    func testAPTYEnvironmentListHasExactlyOneEntryPerCredential() {
        let credentials = AgentCredentialEnvironment([spec.environmentKey: token])
        let applied = credentials.applied(toEntries: [
            "PATH=/usr/bin",
            "\(spec.environmentKey)=exported-by-something-else",
            "NOEQUALS"
        ])

        XCTAssertEqual(applied.filter { $0.hasPrefix("\(spec.environmentKey)=") }, [
            "\(spec.environmentKey)=\(token)"
        ])
        XCTAssertTrue(applied.contains("PATH=/usr/bin"))
        XCTAssertTrue(applied.contains("NOEQUALS"))
        XCTAssertEqual(AgentCredentialEnvironment.none.applied(toEntries: ["A=1"]), ["A=1"])
    }

    // MARK: - Helpers

    private func makeVault(keychain: InMemoryKeychainItemAccess = InMemoryKeychainItemAccess()) -> AgentAccountTokenVault {
        AgentAccountTokenVault(
            store: AgentAccountTokenStore(keychain: keychain, service: "test", dataProtection: { false })
        )
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
