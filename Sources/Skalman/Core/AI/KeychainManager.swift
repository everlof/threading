import Foundation
import Security

/// Manages secure storage of API keys in the macOS Keychain.
final class KeychainManager {

    // MARK: - Service Identifiers

    enum Service: String {
        case claude = "com.skalman.api.claude"
        case openai = "com.skalman.api.openai"

        init?(providerType: AIProviderType) {
            switch providerType {
            case .claude: self = .claude
            case .openai: self = .openai
            case .ollama: return nil
            }
        }
    }

    // MARK: - Errors

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)
        case unexpectedData

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Failed to save to Keychain: \(status)"
            case .deleteFailed(let status):
                return "Failed to delete from Keychain: \(status)"
            case .unexpectedData:
                return "Unexpected data format in Keychain"
            }
        }
    }

    // MARK: - Public Methods

    /// Saves an API key to the Keychain.
    static func saveKey(_ key: String, for service: Service) throws {
        guard let data = key.data(using: .utf8) else { return }

        // Delete existing key first
        try? deleteKey(for: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api_key",
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves an API key from the Keychain.
    static func getKey(for service: Service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api_key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Deletes an API key from the Keychain.
    static func deleteKey(for service: Service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.rawValue,
            kSecAttrAccount as String: "api_key"
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Checks if an API key exists for the given service.
    static func hasKey(for service: Service) -> Bool {
        return getKey(for: service) != nil
    }
}
