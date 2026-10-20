import CryptoKit
import Foundation
import XCTest
@testable import Threading

final class RemoteClaudeLoginRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClearedNonemptyCredentialIsRecoveredFromTheSelectedLogin() throws {
        let cleared = login(access: "", refresh: "", expiry: 0)
        let current = login(expiry: now.timeIntervalSince1970 + 3600)
        XCTAssertEqual(try replacement(cleared, with: current), current)
    }

    func testExpiredRemoteCredentialUsesACurrentMacLogin() throws {
        let expired = login(expiry: now.timeIntervalSince1970 - 3600)
        let current = login(expiry: now.timeIntervalSince1970 + 3600)
        XCTAssertEqual(try replacement(expired, with: current), current)
    }

    func testHealthyRemoteCredentialNeverReadsOrOverwritesFromTheMac() throws {
        for expiry: Double? in [now.timeIntervalSince1970 + 3600, nil] {
            XCTAssertNil(try RemoteClaudeLoginRecovery.replacement(for: login(expiry: expiry), now: now) {
                XCTFail("A healthy remote login should not require local Keychain access")
                throw RemoteConversationFailure.claudeKeychainAccessRequired
            })
        }
    }

    func testRefreshableRemoteLoginSurvivesAnUnavailableOrOlderMacLogin() throws {
        let expired = login(expiry: now.timeIntervalSince1970 - 10)
        XCTAssertNil(try replacement(expired, with: login(expiry: now.timeIntervalSince1970 - 3600)))
        XCTAssertNil(try RemoteClaudeLoginRecovery.replacement(for: expired, now: now) {
            throw RemoteConversationFailure.claudeKeychainAccessRequired
        })
    }

    func testMissingEmptyAndMalformedFilesCanRecover() throws {
        let current = login(expiry: now.timeIntervalSince1970 + 3600)
        for existing: Data? in [nil, Data(), Data("not json".utf8), Data("{}".utf8)] {
            XCTAssertEqual(try replacement(existing, with: current), current)
        }
    }

    func testAnUnrecoverableLoginReportsItsOriginalKeychainFailure() {
        XCTAssertThrowsError(try RemoteClaudeLoginRecovery.replacement(
            for: login(access: "", refresh: "", expiry: 0), now: now
        ) { throw RemoteConversationFailure.claudeKeychainAccessRequired }) { error in
            XCTAssertEqual((error as? RemoteConversationFailure)?.launchFailure.knownCause,
                           RemoteConversationFailure.keychainAccessCause)
        }
    }

    func testUnusableMacCredentialsCannotReplaceAClearedLogin() {
        let cleared = login(access: "", refresh: "", expiry: 0)
        for local in [cleared, login(expiry: now.timeIntervalSince1970 - 1),
                      login(expiry: now.timeIntervalSince1970 + 29),
                      Data(repeating: 32, count: 65537)] {
            XCTAssertThrowsError(try replacement(cleared, with: local))
        }
    }

    /// Exercises the actual SSH scripts on Linux, with synthetic credentials in one unique
    /// scratch account. Never reads a real login, starts a provider or touches a saved chat.
    func testRecoveryAndConcurrentRefreshOnTheRealLinuxHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_REMOTE_LOGIN_RECOVERY_TEST"] == "1",
              let alias = environment["THREADING_REMOTE_HOST_DESTINATION"] else {
            throw XCTSkip("opt in to the Linux login recovery scripts")
        }
        let destination = RemoteHostDestination(alias: alias,
            configFile: environment["THREADING_REMOTE_HOST_SSH_CONFIG"])
        let runner = SystemSSHCommandRunner()
        let homeResult = try runner.run(on: destination, command: #"printf '%s' "$HOME""#, input: .none,
            timeout: RemoteHostDefaults.commandTimeout)
        XCTAssertTrue(homeResult.succeeded)
        let home = homeResult.output
        XCTAssertTrue(home.hasPrefix("/"))
        let directory = home + "/.local/share/threading/login-recovery-test-" + UUID().uuidString
        let q = { (value: String) in ShellCommand(word: value).source }
        defer {
            _ = try? runner.run(on: destination, command: "rm -rf -- \(q(directory))", input: .none,
                timeout: RemoteHostDefaults.commandTimeout)
        }
        let facts = RemoteHostFacts(machine: "x86_64", home: home, user: "fixture",
            loginShell: "/bin/bash", hasSystemd: true, lingerEnabled: true,
            installedBinaries: [], activeInstances: [], claudePath: nil)
        let context = RemoteHostLaunchContext(destination: destination, facts: facts,
            localSocketPath: "/unused")
        func run(_ script: String) throws -> RemoteHostCommandResult {
            try runner.run(on: destination, command: "sh -s", input: .data(Data(script.utf8)),
                timeout: RemoteHostDefaults.commandTimeout)
        }
        func read() throws -> Data {
            let result = try run(RemoteClaudeLoginRecovery.readScript(directory: directory))
            XCTAssertTrue(result.succeeded)
            return Data(result.output.utf8)
        }
        let current = login(expiry: Date().timeIntervalSince1970 + 3600)
        let cleared = login(access: "", refresh: "", expiry: 0)
        let localDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-login-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        try current.write(to: localDirectory.appendingPathComponent(".credentials.json"))
        let local = AgentAccount(provider: .claude, handle: .named("recovery-fixture"),
            configPath: localDirectory.path)
        let remote = RemoteConversationAccount(directory: directory, environmentKey: "CLAUDE_CONFIG_DIR",
            credentialFile: ".credentials.json", usesCopiedLogin: true)
        try remote.prepare(account: local, reuse: true, context: context, runner: runner)
        XCTAssertEqual(try read(), current, "First launch should populate a missing remote login")
        for initial in [cleared, login(expiry: 1), Data()] {
            XCTAssertTrue(try run("rm -f \(q(directory + "/.credentials.json"))").succeeded)
            XCTAssertTrue(try run(RemoteConversationAccount.installScript(directory: directory,
                file: ".credentials.json", credentials: initial)).succeeded)
            try remote.prepare(account: local, reuse: false, context: context, runner: runner)
            XCTAssertEqual(try read(), initial, "Disabled copying must not repair even a cleared login")
            try remote.prepare(account: local, reuse: true, context: context, runner: runner)
            XCTAssertEqual(try read(), current)
            // Relaunch with a healthy copied login must not try to read the Mac again.
            try RemoteClaudeLoginRecovery.prepare(directory: directory, context: context, runner: runner) {
                XCTFail("Healthy login reached the Mac credential reader")
                throw RemoteConversationFailure.claudeKeychainAccessRequired
            }
        }
        let clearedDigest = SHA256.hash(data: cleared).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(try run(RemoteConversationAccount.installScript(directory: directory,
            file: ".credentials.json", credentials: login(access: "stale-copy", expiry: 1),
            replacingDigest: clearedDigest)).succeeded)
        XCTAssertEqual(try read(), current, "A refresh after the snapshot must win over the copy")
        let permissions = try run("stat -c '%a' \(q(directory)) \(q(directory + "/.credentials.json"))")
        XCTAssertEqual(permissions.output, "700\n600\n")

        // Refuse symlinks and oversized input before reading any credential bytes.
        let target = q(directory + "/.credentials.json")
        XCTAssertTrue(try run("mv \(target) \(q(directory + "/saved")); ln -s saved \(target)").succeeded)
        XCTAssertFalse(try run(RemoteClaudeLoginRecovery.readScript(directory: directory)).succeeded)
        XCTAssertFalse(try run(RemoteConversationAccount.installScript(directory: directory,
            file: ".credentials.json", credentials: cleared, replacingDigest: clearedDigest)).succeeded)
        XCTAssertTrue(try run("rm \(target); head -c 65537 /dev/zero > \(target)").succeeded)
        XCTAssertFalse(try run(RemoteClaudeLoginRecovery.readScript(directory: directory)).succeeded)
    }

    private func replacement(_ existing: Data?, with local: Data) throws -> Data? {
        try RemoteClaudeLoginRecovery.replacement(for: existing, now: now) { local }
    }

    private func login(access: String = "fixture-access", refresh: String = "fixture-refresh",
                       expiry: Double?) -> Data {
        var oauth: [String: Any] = ["accessToken": access, "refreshToken": refresh]
        if let expiry { oauth["expiresAt"] = expiry * 1000 }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    }
}
