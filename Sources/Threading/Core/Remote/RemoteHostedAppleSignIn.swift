import AppKit
import AuthenticationServices
import CryptoKit
import Security

enum RemoteHostedAppleSignInError: Error {
    case alreadyInProgress
    case entropy
    case invalidCredential
}

struct RemoteHostedAppleAuthorization {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
}

/// Bridges Apple's delegate authorization flow into one bounded async operation. The raw nonce
/// exists only until the identity token reaches Threading's service; Apple receives its SHA-256
/// digest and the service verifies that claim before accepting the token.
@MainActor
final class RemoteHostedAppleSignIn: NSObject {
    private var continuation: CheckedContinuation<RemoteHostedAppleAuthorization, Error>?
    private var authorizationController: ASAuthorizationController?
    private var anchor: ASPresentationAnchor?
    private var rawNonce: String?

    func authorize(from anchor: ASPresentationAnchor) async throws
        -> RemoteHostedAppleAuthorization {
        guard continuation == nil else { throw RemoteHostedAppleSignInError.alreadyInProgress }
        let rawNonce = try Self.makeNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.nonce = Self.sha256(rawNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.authorizationController = controller
        self.anchor = anchor
        self.rawNonce = rawNonce
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<RemoteHostedAppleAuthorization, Error>) {
        let continuation = continuation
        self.continuation = nil
        authorizationController = nil
        anchor = nil
        rawNonce = nil
        continuation?.resume(with: result)
    }

    private static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteHostedAppleSignInError.entropy
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension RemoteHostedAppleSignIn: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              tokenData.count <= 16 * 1024,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty,
              let codeData = credential.authorizationCode,
              codeData.count <= 4 * 1024,
              let authorizationCode = String(data: codeData, encoding: .utf8),
              !authorizationCode.isEmpty,
              let rawNonce else {
            finish(.failure(RemoteHostedAppleSignInError.invalidCredential))
            return
        }
        finish(.success(RemoteHostedAppleAuthorization(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce
        )))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }
}

extension RemoteHostedAppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        precondition(anchor != nil, "The authorization request must retain its presentation anchor.")
        return anchor!
    }
}
