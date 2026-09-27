#if DEBUG
import Foundation
import Security
import XCTest
import ThreadingRemoteKit
@testable import Threading

final class SecretApprovalGitHubTests: XCTestCase {
    private let token = "github_pat_disposableTestValue"

    private final class Keychain: KeychainItemAccessing {
        var queries: [[String: Any]] = []
        var data: Data?
        var addStatus = errSecSuccess
        func data(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
            queries.append(query)
            return (data == nil ? errSecItemNotFound : errSecSuccess, data)
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            XCTFail("Trial credentials must never fall back or update another store")
            return errSecUnimplemented
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            queries.append(attributes)
            if addStatus == errSecSuccess { data = attributes[kSecValueData as String] as? Data }
            return addStatus
        }
        func delete(_ query: [String: Any]) -> OSStatus {
            queries.append(query)
            data = nil
            return errSecSuccess
        }
    }

    func testRealTokenIsRefusedBeforeAnyKeychainAccessWhenProtectionIsUnavailable() {
        let keychain = Keychain()
        let store = SecretApprovalGitHubStore(keychain: keychain, available: false)
        XCTAssertThrowsError(try store.save(token))
        XCTAssertThrowsError(try store.read())
        XCTAssertTrue(keychain.queries.isEmpty)
    }

    func testTokenUsesOnlyTheDedicatedDeviceLocalProtectedItemAndStopDeletesIt() throws {
        let keychain = Keychain()
        let store = SecretApprovalGitHubStore(keychain: keychain, available: true)
        try store.save(token)
        XCTAssertEqual(try store.read(), token)
        try store.remove()
        XCTAssertNil(keychain.data)
        for query in keychain.queries {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "trial-token")
        }
        let saved = try XCTUnwrap(keychain.queries.first { $0[kSecValueData as String] != nil })
        XCTAssertEqual(saved[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testMissingEntitlementNeverFallsBackToLoginKeychain() {
        let keychain = Keychain()
        keychain.addStatus = errSecMissingEntitlement
        let store = SecretApprovalGitHubStore(keychain: keychain, available: true)
        XCTAssertThrowsError(try store.save(token))
        XCTAssertEqual(keychain.queries.count, 2)
        XCTAssertTrue(keychain.queries.allSatisfy { $0[kSecUseDataProtectionKeychain as String] as? Bool == true })
    }

    func testRequestHasOneDestinationAndRejectsHeaderInjectionAndWrongTokenKinds() throws {
        let request = try SecretApprovalGitHub.request(token: token)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        for invalid in ["", "ghp_legacy", "github_pat_", "github_pat_x\r\nHost: other.test", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try SecretApprovalGitHub.request(token: invalid))
        }
    }

    func testProfileResponseExposesOnlyABoundedUsername() throws {
        XCTAssertEqual(try SecretApprovalGitHub.login(from: Data(#"{"login":"octocat","email":"private@example.test","bio":"untrusted content"}"#.utf8)), "octocat")
        for body in [#"{"login":"bad\nname"}"#, #"{"login":"https://other.test"}"#, #"{"login":""}"#, #"{"message":"server error"}"#] {
            XCTAssertThrowsError(try SecretApprovalGitHub.login(from: Data(body.utf8)))
        }
        XCTAssertThrowsError(try SecretApprovalGitHub.login(from: Data(repeating: 32, count: SecretApprovalGitHub.maximumResponseBytes + 1)))
    }

    func testEveryRedirectIsRefusedIncludingTheSameHost() throws {
        let delegate = SecretApprovalGitHubRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = try SecretApprovalGitHub.request(token: token)
        let task = session.dataTask(with: request)
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
        for destination in ["https://api.github.com/user", "https://api.github.com/repos", "https://other.test/user", "http://api.github.com/user"] {
            let answered = expectation(description: "Redirect refused")
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: destination)!)) { forwarded in
                XCTAssertNil(forwarded)
                answered.fulfill()
            }
            wait(for: [answered], timeout: 1)
        }
    }

    func testLiveResponsePathRejectsStatusAndOversizedBodies() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileProtocol.self]
        let request = try SecretApprovalGitHub.request(token: token)
        ProfileProtocol.set(status: 200, body: Data(#"{"login":"octocat","email":"not-returned"}"#.utf8))
        let login = try await SecretApprovalGitHub.fetch(request, configuration: configuration)
        XCTAssertEqual(login, "octocat")
        for status in [301, 302, 401, 403, 500] {
            ProfileProtocol.set(status: status, body: Data(#"{"login":"must-not-succeed"}"#.utf8))
            do {
                _ = try await SecretApprovalGitHub.fetch(request, configuration: configuration)
                XCTFail("An unsuccessful response cannot produce a receipt")
            } catch is SecretApprovalGitHubFailure { }
        }
        ProfileProtocol.set(status: 200, body: Data(repeating: 32, count: SecretApprovalGitHub.maximumResponseBytes + 1))
        do {
            _ = try await SecretApprovalGitHub.fetch(request, configuration: configuration)
            XCTFail("Streaming must enforce its byte cap")
        } catch is SecretApprovalGitHubFailure { }
    }
}

private final class ProfileProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = (200, Data())
    static func set(status: Int, body: Data) { lock.withLock { fixture = (status, body) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock { Self.fixture }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
#endif
