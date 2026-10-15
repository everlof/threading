import AppKit
import XCTest
@testable import Threading

@MainActor
final class RemoteNativeConversationTests: XCTestCase {
    func testRemoteCodexReadsTheMirrorWithoutLookingUpALocalRollout() throws {
        var project = Project(name: "Remote", folderURL: URL(fileURLWithPath: "/Users/local/project"))
        project.executionHost = ProjectExecutionHost(destination: "box", remoteDirectory: "/home/remote/project")
        let session = AgentSession(kind: .codex, title: "Remote", usesNativeUI: true)
        let account = AgentAccount(provider: .codex, handle: session.accountHandle, configPath: "/Users/local/.codex")
        let request = SessionTranscript.readRequest(sessionID: TranscriptID(UUID().uuidString), for: session, in: project, account: account)
        guard case .file(let file) = request else { return XCTFail("remote replay attempted local discovery") }
        XCTAssertTrue(RemoteTranscriptMirror.shared.contains(file))
    }

    func testRemoteAccountNamespaceSurvivesPersistence() throws {
        var session = AgentSession(kind: .codex, title: "Remote", usesNativeUI: true)
        session.remoteUsesCopiedAccount = true
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.remoteUsesCopiedAccount, true)
    }

    func testTranscriptAliasRejectsPathsOutsideTheSelectedAccount() {
        let account = RemoteConversationAccount(directory: "/home/remote/account", environmentKey: "CODEX_HOME", credentialFile: "auth.json", usesCopiedLogin: true)
        let id = TranscriptID(UUID().uuidString)
        XCTAssertNil(RemoteNativeConversation.transcriptAliasScript(id: id, path: "/home/remote/other/sessions/a.jsonl", account: account))
        XCTAssertNil(RemoteNativeConversation.transcriptAliasScript(id: id, path: "/home/remote/account/sessions/../../secret", account: account))
        XCTAssertNil(RemoteNativeConversation.transcriptAliasScript(id: TranscriptID("../escape"), path: "/home/remote/account/sessions/a.jsonl", account: account))
    }

    func testRemoteEnvironmentCannotInheritLocalPathsOrCredentials() {
        let plan = AgentLaunchPlan(executable: "/bin/bash", arguments: [], resumeState: .unavailable,
                                   environmentOverrides: ["USER": "remote"], baseEnvironment: ["HOME": "/home/remote"])
        XCTAssertEqual(plan.launchEnvironment(), ["HOME": "/home/remote", "USER": "remote"])
        XCTAssertEqual(plan.environmentEntries(on: ["HOME=/Users/local", "OPENAI_API_KEY=local-secret"]),
                       ["HOME=/home/remote", "USER=remote"])
    }

    func testCredentialReuseRequiresExplicitConsentAndSurvivesEditing() throws {
        let old = Data(#"{"destination":"box"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(RemoteHostRecord.self, from: old).reusesLocalCredentials)
        var record = RemoteHostRecord(destination: "box", reusesLocalCredentials: true)
        record.controllerExecutable = "/custom/controller"
        record.controllerDatabase = "/custom/database"
        let editor = RemoteHostRecordPromptAccessory(current: record)
        editor.labelField.stringValue = "Windows"
        let updated = editor.record(replacing: record)
        XCTAssertTrue(updated.reusesLocalCredentials)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.controllerExecutable, record.controllerExecutable)
        XCTAssertEqual(updated.controllerDatabase, record.controllerDatabase)
        XCTAssertTrue(try JSONDecoder().decode(RemoteHostRecord.self, from: JSONEncoder().encode(updated)).reusesLocalCredentials)
    }

    func testCredentialExportExcludesPreferencesAndRejectsInvalidPayloads() throws {
        let payload = Data(#"{"tokens":{"access_token":"fixture","refresh_token":"refresh"},"auth_mode":"chatgpt","hooks":{"evil":"command"},"mcp_servers":{"evil":{}}}"#.utf8)
        let result = try RemoteConversationAccount.validatedCredentials(payload, provider: .codex)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertNotNil(object["tokens"])
        XCTAssertNil(object["hooks"])
        XCTAssertNil(object["mcp_servers"])
        XCTAssertThrowsError(try RemoteConversationAccount.validatedCredentials(Data("{}".utf8), provider: .codex))
        XCTAssertThrowsError(try RemoteConversationAccount.validatedCredentials(Data(repeating: 32, count: 65537), provider: .claude))
        let claude = try RemoteConversationAccount.validatedCredentials(
            Data(#"{"claudeAiOauth":{"accessToken":"fixture","refreshToken":"refresh"},"preferences":{"x":1}}"#.utf8), provider: .claude)
        XCTAssertEqual(Set((try XCTUnwrap(JSONSerialization.jsonObject(with: claude) as? [String: Any])).keys), ["claudeAiOauth"])
    }

    func testAccountsHaveSeparateRemoteHomesAndNoMacPathIsUsedAsARemotePath() throws {
        let first = AgentAccount(provider: .codex, handle: .standard, configPath: "/Users/me/.codex")
        let second = AgentAccount(provider: .codex, handle: .standard, configPath: "/Users/me/.codex-work")
        let a = try RemoteConversationAccount.make(account: first, home: "/home/me", reuse: true)
        let b = try RemoteConversationAccount.make(account: second, home: "/home/me", reuse: true)
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertFalse(a.directory.contains("/Users/"))
        XCTAssertEqual(try RemoteConversationAccount.make(account: first, home: "/home/me", reuse: false).directory, "/home/me/.codex")
    }

    func testNativeCommandsRunInRemoteFolderWithRemoteToolsAndSessionIdentity() throws {
        let facts = RemoteHostFacts(machine: "x86_64", home: "/home/me", user: "me", loginShell: "/bin/bash",
                                    hasSystemd: true, lingerEnabled: true, installedBinaries: [], activeInstances: [], claudePath: nil)
        let route = RemoteHostToolRoute(socketPath: "/home/me/mcp.sock", bridgePath: "/home/me/bridge", cacheDirectory: "/home/me/cache")
        let context = RemoteHostLaunchContext(destination: .init(alias: "box", configFile: nil), facts: facts,
                                             localSocketPath: "/tmp/test.sock", toolRoute: route)
        let host = ProjectExecutionHost(destination: "box", remoteDirectory: "/home/me/project with spaces")
        for kind in [AgentKind.claude, .codex] {
            let session = AgentSession(kind: kind, title: "Remote", usesNativeUI: true)
            let local = AgentAccount(provider: kind, handle: .standard, configPath: "/Users/me/account")
            let account = try RemoteConversationAccount.make(account: local, home: facts.home, reuse: true)
            let launch = try RemoteNativeConversation.makeLaunch(session: session, host: host, context: context, account: account).encode()
            let script = launch.plan.arguments.joined(separator: " ")
            XCTAssertTrue(script.contains("'/home/me/project with spaces'"))
            XCTAssertFalse(script.contains("/Users/"))
            XCTAssertFalse(script.contains(MCPSessionRegistry.token(for: session.id)))
            XCTAssertTrue(launch.environment.contains("\(account.environmentKey)=\(account.directory)"))
            XCTAssertTrue(launch.environment.contains("HOME=/home/me"))
        }
    }
}
