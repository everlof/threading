import Foundation

// MARK: - AI Provider Type

enum AIProviderType: String, Codable, CaseIterable {
    case claude
    case openai
    case ollama

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .claude, .openai: return true
        case .ollama: return false
        }
    }
}

// MARK: - AI Settings

struct AISettings: Codable, Equatable {

    // MARK: - Properties

    var providerType: AIProviderType
    var ollamaURL: String
    var ollamaModel: String
    var claudeModel: String
    var openaiModel: String
    var autoRunShellIntegration: Bool

    // MARK: - Default Settings

    static let `default` = AISettings(
        providerType: .claude,
        ollamaURL: AIDefaults.ollamaDefaultURL,
        ollamaModel: AIDefaults.ollamaDefaultModel,
        claudeModel: AIDefaults.claudeDefaultModel,
        openaiModel: AIDefaults.openaiDefaultModel,
        autoRunShellIntegration: false
    )

    // MARK: - Codable (with defaults for missing keys)

    enum CodingKeys: String, CodingKey {
        case providerType, ollamaURL, ollamaModel, claudeModel, openaiModel, autoRunShellIntegration
    }

    init(providerType: AIProviderType, ollamaURL: String, ollamaModel: String, claudeModel: String, openaiModel: String, autoRunShellIntegration: Bool) {
        self.providerType = providerType
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
        self.claudeModel = claudeModel
        self.openaiModel = openaiModel
        self.autoRunShellIntegration = autoRunShellIntegration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerType = try container.decodeIfPresent(AIProviderType.self, forKey: .providerType) ?? .claude
        ollamaURL = try container.decodeIfPresent(String.self, forKey: .ollamaURL) ?? AIDefaults.ollamaDefaultURL
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? AIDefaults.ollamaDefaultModel
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? AIDefaults.claudeDefaultModel
        openaiModel = try container.decodeIfPresent(String.self, forKey: .openaiModel) ?? AIDefaults.openaiDefaultModel
        autoRunShellIntegration = try container.decodeIfPresent(Bool.self, forKey: .autoRunShellIntegration) ?? false
    }
}

// MARK: - AI Settings Storage

final class AISettingsStorage {

    // MARK: - Keys

    private enum Keys {
        static let settings = "aiSettings"
    }

    // MARK: - Singleton

    static let shared = AISettingsStorage()

    private init() {}

    // MARK: - Storage

    private let defaults = UserDefaults.standard

    var settings: AISettings {
        get {
            guard let data = defaults.data(forKey: Keys.settings),
                  let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
                return .default
            }
            return settings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.settings)
            }
        }
    }
}
