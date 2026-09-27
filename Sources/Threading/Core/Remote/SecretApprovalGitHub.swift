#if DEBUG
import Foundation
import LocalAuthentication
import Security
import ThreadingRemoteKit

enum SecretApprovalGitHubFailure: Error {
    case protectedStorageRequired, invalidToken, keychain(OSStatus), refused, invalidResponse
}

/// One dedicated trial item. No credential discovery, login-Keychain fallback or CLI access.
struct SecretApprovalGitHubStore {
    private let keychain: any KeychainItemAccessing
    private let available: Bool
    static let maximumTokenBytes = 255

    init(keychain: any KeychainItemAccessing = SystemKeychainItemAccess(), available: Bool? = nil) {
        self.keychain = keychain
        self.available = available ?? Self.isAvailable
    }

    static var isAvailable: Bool {
        // A debuggable app or one permitting foreign libraries is not a real-token trial host.
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoTeamIdentifier as String] is String,
              let flags = info[kSecCodeInfoFlags as String] as? UInt32,
              flags & SecCodeSignatureFlags.runtime.rawValue != 0 else { return false }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard entitlements["com.apple.security.get-task-allow"] as? Bool != true,
              entitlements["com.apple.security.cs.disable-library-validation"] as? Bool != true,
              entitlements["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool != true else { return false }
        return KeychainStoragePolicy.usesDataProtectionKeychain
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: KeychainStoragePolicy.remoteService("codes.threading.faceid.github-profile"),
         kSecAttrAccount as String: "trial-token",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }

    static func accepts(_ token: String) -> Bool {
        token.hasPrefix("github_pat_") && token.utf8.count > "github_pat_".utf8.count
            && token.utf8.count <= maximumTokenBytes && token.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }
    }

    func save(_ token: String) throws {
        guard available else { throw SecretApprovalGitHubFailure.protectedStorageRequired }
        guard Self.accepts(token) else { throw SecretApprovalGitHubFailure.invalidToken }
        try remove()
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        let status = keychain.add(item)
        guard status == errSecSuccess else { throw SecretApprovalGitHubFailure.keychain(status) }
    }

    func read() throws -> String {
        guard available else { throw SecretApprovalGitHubFailure.protectedStorageRequired }
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        item[kSecUseAuthenticationContext as String] = context
        let result = keychain.data(matching: item)
        guard result.status == errSecSuccess else { throw SecretApprovalGitHubFailure.keychain(result.status) }
        guard let data = result.data, data.count <= Self.maximumTokenBytes,
              let token = String(data: data, encoding: .utf8), Self.accepts(token) else {
            throw SecretApprovalGitHubFailure.invalidToken
        }
        return token
    }

    func remove() throws {
        guard available else { return }
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretApprovalGitHubFailure.keychain(status)
        }
    }
}

/// The only outbound operation. Neither the phone nor a response can choose its destination.
enum SecretApprovalGitHub {
    static let timeout: TimeInterval = 7
    static let maximumResponseBytes = 32 * 1024

    static func request(token: String) throws -> URLRequest {
        guard SecretApprovalGitHubStore.accepts(token), let url = URL(string: RemoteSecretApprovalLab.githubURL) else {
            throw SecretApprovalGitHubFailure.invalidToken
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = RemoteSecretApprovalLab.githubMethod
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Threading-FaceID-Trial", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func login(from data: Data) throws -> String {
        struct Profile: Decodable { let login: String }
        guard data.count <= maximumResponseBytes,
              let profile = try? JSONDecoder().decode(Profile.self, from: data),
              RemoteSecretApprovalLab.isValidGitHubLogin(profile.login) else {
            throw SecretApprovalGitHubFailure.invalidResponse
        }
        return profile.login
    }

    static func fetchProfile() async throws -> String {
        // Called only after consumption of a valid approval. The token never enters diagnostics.
        let request = try request(token: SecretApprovalGitHubStore().read())
        return try await fetch(request)
    }

    static func fetch(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        guard request.url?.absoluteString == RemoteSecretApprovalLab.githubURL,
              request.httpMethod == RemoteSecretApprovalLab.githubMethod else {
            throw SecretApprovalGitHubFailure.refused
        }
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Even same-host redirects are refused: only the approved path may receive this token.
        let (stream, response) = try await session.bytes(for: request, delegate: SecretApprovalGitHubRedirectPolicy())
        defer { stream.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.absoluteString == RemoteSecretApprovalLab.githubURL else {
            throw SecretApprovalGitHubFailure.refused
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < maximumResponseBytes else { throw SecretApprovalGitHubFailure.invalidResponse }
            data.append(byte)
        }
        return try login(from: data)
    }
}

final class SecretApprovalGitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
