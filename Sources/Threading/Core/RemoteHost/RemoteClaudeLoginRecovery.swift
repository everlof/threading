import CryptoKit
import Foundation

/// A copied browser login can expire while its host is off. Claude can then clear both tokens
/// after refresh fails, leaving a nonempty JSON file that is no longer a login. Only launch
/// preparation with the host's standing copy consent reaches this worker-side recovery.
enum RemoteClaudeLoginRecovery {
    private static let credentialFile = ".credentials.json"
    private static let missingCredentialStatus: Int32 = 3

    static func prepare(
        directory: String,
        context: RemoteHostLaunchContext,
        runner: any RemoteHostCommandRunning,
        credentials: () throws -> Data
    ) throws {
        let result = try runner.run(on: context.destination, command: "sh -s",
            input: .data(Data(readScript(directory: directory).utf8)),
            extraOptions: [], timeout: RemoteHostDefaults.commandTimeout)
        let existing: Data?
        switch result.termination {
        case .exited(0): existing = Data(result.output.utf8)
        case .exited(let status) where status == missingCredentialStatus: existing = nil
        default: throw RemoteConversationFailure.credentialTransfer
        }
        guard let replacement = try replacement(for: existing, credentials: credentials) else { return }
        let digest = existing.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let script = RemoteConversationAccount.installScript(directory: directory, file: credentialFile,
            credentials: replacement, replacingDigest: digest)
        let installed = try runner.run(on: context.destination, command: "sh -s",
            input: .data(Data(script.utf8)), extraOptions: [], timeout: RemoteHostDefaults.commandTimeout)
        guard installed.succeeded else { throw RemoteConversationFailure.credentialTransfer }
    }

    /// A healthy remote login needs no Keychain access. An expired login with a refresh token
    /// may still recover through the CLI when the Mac cannot supply a currently usable token.
    static func replacement(for existing: Data?, now: Date = Date(),
                            credentials: () throws -> Data) throws -> Data? {
        let remote = existing.flatMap(Login.init)
        guard remote?.isUsable(at: now) != true else { return nil }
        do {
            let bytes = try credentials()
            guard Login(bytes)?.isUsable(at: now) == true else {
                throw RemoteConversationFailure.credentialsUnavailable(.claude)
            }
            return bytes
        } catch {
            guard remote?.canRefresh == true else { throw error }
            return nil
        }
    }

    static func readScript(directory: String) -> String {
        RemoteConversationAccount.privateDirectoryScript(directory) + """

        target="$directory"/\(ShellCommand(word: credentialFile).source)
        test ! -L "$target" || exit 2
        test -e "$target" || exit \(missingCredentialStatus)
        test -f "$target" || exit 2
        test "$(stat -c %u "$target")" = "$(id -u)" || exit 2
        test "$(stat -c %s "$target")" -le \(KeychainCredentialsDefaults.maxItemBytes) || exit 2
        chmod 600 "$target" || exit 2
        head -c \(KeychainCredentialsDefaults.maxItemBytes) "$target"
        """
    }

    private struct Login {
        let hasAccessToken: Bool
        let canRefresh: Bool
        let expiresAt: Date?

        init?(_ bytes: Data) {
            guard bytes.count <= KeychainCredentialsDefaults.maxItemBytes,
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
            hasAccessToken = (oauth[KeychainCredentialsDefaults.accessTokenKey] as? String)?.isEmpty == false
            canRefresh = (oauth["refreshToken"] as? String)?.isEmpty == false
            expiresAt = (oauth[KeychainCredentialsDefaults.expiresAtKey] as? Double)
                .map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        func isUsable(at now: Date) -> Bool {
            hasAccessToken && (expiresAt.map {
                $0 > now.addingTimeInterval(KeychainCredentialsDefaults.expirySkew)
            } ?? true)
        }
    }
}
