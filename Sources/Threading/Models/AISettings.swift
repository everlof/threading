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

    // MARK: - Default Settings

    static let `default` = AISettings(
        providerType: .claude,
        ollamaURL: AIDefaults.ollamaDefaultURL,
        ollamaModel: AIDefaults.ollamaDefaultModel,
        claudeModel: AIDefaults.claudeDefaultModel,
        openaiModel: AIDefaults.openaiDefaultModel
    )

    // MARK: - Codable (with defaults for missing keys)

    enum CodingKeys: String, CodingKey {
        case providerType, ollamaURL, ollamaModel, claudeModel, openaiModel
    }

    init(providerType: AIProviderType, ollamaURL: String, ollamaModel: String, claudeModel: String, openaiModel: String) {
        self.providerType = providerType
        self.ollamaURL = ollamaURL
        self.ollamaModel = ollamaModel
        self.claudeModel = claudeModel
        self.openaiModel = openaiModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerType = try container.decodeIfPresent(AIProviderType.self, forKey: .providerType) ?? .claude
        ollamaURL = try container.decodeIfPresent(String.self, forKey: .ollamaURL) ?? AIDefaults.ollamaDefaultURL
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? AIDefaults.ollamaDefaultModel
        claudeModel = try container.decodeIfPresent(String.self, forKey: .claudeModel) ?? AIDefaults.claudeDefaultModel
        openaiModel = try container.decodeIfPresent(String.self, forKey: .openaiModel) ?? AIDefaults.openaiDefaultModel
    }
}

// MARK: - AI Settings Storage

@MainActor
final class AISettingsStorage {

    // MARK: - Keys

    private enum Keys {
        static let settings = "aiSettings"
    }

    // MARK: - Singleton

    static let shared = AISettingsStorage()

    // MARK: - Storage

    private let persistence: RecoverableDefaultsStore<AISettings>
    private var storedSettings: AISettings

    init(defaults: UserDefaults = .standard) {
        self.persistence = RecoverableDefaultsStore(
            defaults: defaults,
            key: Keys.settings,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.storedSettings = persistence.load(defaultValue: .default).value
    }

    var settings: AISettings {
        get { storedSettings }
        set {
            if persistence.save(newValue) {
                storedSettings = newValue
            }
        }
    }
}
