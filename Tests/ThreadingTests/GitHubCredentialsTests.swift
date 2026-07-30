import XCTest
@testable import Threading
import ThreadingExtensionKit

/// Fakes shared by the credential-chain and broker tests.
actor FakeTokenSource: GitHubTokenSourcing {
    private var storedToken: String?
    private(set) var probeCount = 0
    private(set) var invalidations = 0

    init(token: String?) {
        storedToken = token
    }

    func token() async -> String? {
        probeCount += 1
        return storedToken
    }

    func invalidate() {
        invalidations += 1
        storedToken = nil
    }
}

final class FakeAppTokens: GitHubAppTokenProviding, @unchecked Sendable {
    private(set) var rejections = 0
    var token: String?

    init(token: String?) {
        self.token = token
    }

    func freshAccessToken() async -> String? { token }

    func noteRejectedAccessToken() async {
        rejections += 1
        token = nil
    }
}

final class GitHubCredentialsTests: XCTestCase {

    private func resolver(
        app: String?,
        gh: String?,
        git: String?
    ) -> (GitHubCredentialResolver, FakeAppTokens, FakeTokenSource, FakeTokenSource) {
        let appTokens = FakeAppTokens(token: app)
        let ghSource = FakeTokenSource(token: gh)
        let gitSource = FakeTokenSource(token: git)
        return (
            GitHubCredentialResolver(
                appConnection: appTokens,
                ghSource: ghSource,
                gitSource: gitSource
            ),
            appTokens,
            ghSource,
            gitSource
        )
    }

    func testTheChainOrdersAppThenGhThenGitThenAnonymous() async {
        let (subject, _, _, _) = resolver(app: "app-token", gh: "gh-token", git: "git-token")
        let credentials = await subject.orderedCredentials()
        XCTAssertEqual(
            credentials.map(\.tier),
            [.app, .ghCLI, .gitCredential, .anonymous]
        )
        XCTAssertEqual(
            credentials.map(\.token),
            ["app-token", "gh-token", "git-token", nil]
        )
    }

    func testAMissingTierIsSkippedAndAnonymousAlwaysRemains() async {
        let (subject, _, _, _) = resolver(app: nil, gh: nil, git: "git-token")
        let credentials = await subject.orderedCredentials()
        XCTAssertEqual(credentials.map(\.tier), [.gitCredential, .anonymous])

        let (empty, _, _, _) = resolver(app: nil, gh: nil, git: nil)
        let anonymousOnly = await empty.orderedCredentials()
        XCTAssertEqual(anonymousOnly.map(\.tier), [.anonymous])
    }

    func testInvalidationRoutesToTheTierThatFailed() async {
        let (subject, appTokens, ghSource, gitSource) = resolver(
            app: "a", gh: "b", git: "c"
        )
        await subject.invalidate(.ghCLI)
        let ghInvalidations = await ghSource.invalidations
        let gitInvalidations = await gitSource.invalidations
        XCTAssertEqual(ghInvalidations, 1)
        XCTAssertEqual(gitInvalidations, 0)
        XCTAssertEqual(appTokens.rejections, 0)

        await subject.invalidate(.app)
        XCTAssertEqual(appTokens.rejections, 1)

        await subject.invalidate(.anonymous)
        let unchanged = await gitSource.invalidations
        XCTAssertEqual(unchanged, 0, "anonymous has nothing to invalidate")
    }

    // MARK: - Probe caching

    func testASuccessfulProbeIsCachedUntilInvalidated() async {
        let counter = ProbeCounter(results: ["token-1", "token-2"])
        let source = GhCLITokenSource(shellPath: "/bin/true", probe: counter.next)

        let first = await source.token()
        let second = await source.token()
        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(second, "token-1", "a cached success must not re-probe")
        XCTAssertEqual(counter.calls, 1)

        await source.invalidate()
        let third = await source.token()
        XCTAssertEqual(third, "token-2", "invalidation is what re-probes")
        XCTAssertEqual(counter.calls, 2)
    }

    func testAFailedProbeIsNotRetriedImmediately() async {
        let counter = ProbeCounter(results: [nil, "late-token"])
        let source = GitCredentialHelperSource(shellPath: "/bin/true", probe: counter.next)

        let first = await source.token()
        let second = await source.token()
        XCTAssertNil(first)
        XCTAssertNil(second, "a failure is cached for the retry interval")
        XCTAssertEqual(counter.calls, 1)

        await source.invalidate()
        let third = await source.token()
        XCTAssertEqual(third, "late-token")
    }

    // MARK: - git credential fill parsing

    func testCredentialFillParsingReadsOnlyThePassword() {
        let output = """
        protocol=https
        host=github.com
        username=everlof
        password=gho_secret123
        """
        XCTAssertEqual(
            GitCredentialHelperSource.password(fromCredentialFill: output),
            "gho_secret123"
        )
        XCTAssertNil(GitCredentialHelperSource.password(fromCredentialFill: "username=x"))
        XCTAssertNil(GitCredentialHelperSource.password(fromCredentialFill: "password="))
        XCTAssertEqual(
            GitCredentialHelperSource.password(
                fromCredentialFill: "password=with=equals=kept"
            ),
            "with=equals=kept"
        )
    }

    // MARK: - Device flow

    func testDeviceCodeRequestParsesTheGrantEnvelope() async throws {
        let transport = scriptedTransport([
            (200, [
                "device_code": "dev-1",
                "user_code": "ABCD-1234",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5
            ])
        ])
        let device = try await GitHubAppConnection.requestDeviceCode(
            clientID: "Iv1.example",
            transport: transport
        )
        XCTAssertEqual(device.userCode, "ABCD-1234")
        XCTAssertEqual(device.verificationURL.host, "github.com")
        XCTAssertEqual(device.pollInterval, 5)
    }

    func testPollingSurvivesPendingAndReturnsTheGrant() async throws {
        let transport = scriptedTransport([
            (200, ["error": "authorization_pending"]),
            (200, [
                "access_token": "ghu_token",
                "refresh_token": "ghr_refresh",
                "expires_in": 28_800
            ])
        ])
        let device = GitHubDeviceCode(
            deviceCode: "dev-1",
            userCode: "ABCD-1234",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(30),
            pollInterval: 0.05
        )
        let grant = try await GitHubAppConnection.pollForGrant(
            clientID: "Iv1.example",
            device: device,
            transport: transport
        )
        XCTAssertEqual(grant.accessToken, "ghu_token")
        XCTAssertEqual(grant.refreshToken, "ghr_refresh")
        XCTAssertEqual(grant.expiresIn, 28_800)
    }

    func testADeclinedAuthorizationThrowsDeclined() async {
        let transport = scriptedTransport([
            (200, ["error": "access_denied"])
        ])
        let device = GitHubDeviceCode(
            deviceCode: "dev-1",
            userCode: "ABCD-1234",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(30),
            pollInterval: 0.05
        )
        do {
            _ = try await GitHubAppConnection.pollForGrant(
                clientID: "Iv1.example",
                device: device,
                transport: transport
            )
            XCTFail("a declined grant must throw")
        } catch let error as GitHubDeviceFlowError {
            XCTAssertEqual(error, .declined)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnExpiredDeviceCodeThrowsWithoutPolling() async {
        let transport = scriptedTransport([])
        let device = GitHubDeviceCode(
            deviceCode: "dev-1",
            userCode: "ABCD-1234",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date(timeIntervalSinceNow: -1),
            pollInterval: 0.05
        )
        do {
            _ = try await GitHubAppConnection.pollForGrant(
                clientID: "Iv1.example",
                device: device,
                transport: transport
            )
            XCTFail("an expired code must throw")
        } catch let error as GitHubDeviceFlowError {
            XCTAssertEqual(error, .expired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testARefreshPresentsTheSameClientID() async throws {
        let recorder = RequestRecorder()
        let transport: GitHubAppConnection.Transport = { request in
            recorder.record(request)
            let body = try JSONSerialization.data(withJSONObject: [
                "access_token": "ghu_new",
                "expires_in": 28_800
            ])
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, http)
        }
        let grant = try await GitHubAppConnection.refreshGrant(
            clientID: "Iv1.example",
            refresh: "ghr_old",
            transport: transport
        )
        XCTAssertEqual(grant.accessToken, "ghu_new")
        let sent = recorder.requests.first?.httpBody
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(
            sent.contains("client_id=Iv1.example"),
            "GitHub refuses a refresh that does not name the app: \(sent)"
        )
        XCTAssertTrue(sent.contains("grant_type=refresh_token"))
    }

    // MARK: - Helpers

    private func scriptedTransport(
        _ script: [(Int, [String: Any])]
    ) -> GitHubAppConnection.Transport {
        let responses = ScriptedResponses(script: script)
        return { request in
            let (status, payload) = responses.next()
            let body = try JSONSerialization.data(withJSONObject: payload)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, http)
        }
    }
}

/// Counts probe invocations; the sources take a plain closure, so state lives here.
final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String?]
    private(set) var calls = 0

    init(results: [String?]) {
        self.results = results
    }

    var next: @Sendable (String) -> String? {
        { [self] _ in
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return results.isEmpty ? nil : results.removeFirst()
        }
    }
}

final class ScriptedResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Int, [String: Any])]

    init(script: [(Int, [String: Any])]) {
        self.script = script
    }

    func next() -> (Int, [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else { return (599, [:]) }
        return script.removeFirst()
    }
}

final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }
}
