import Foundation

/// Manages AI provider configuration and requests.
@MainActor
final class AIService {

    // MARK: - Singleton

    static let shared = AIService()

    // MARK: - Properties

    private(set) var provider: AIProvider?

    /// Returns true if an AI provider is configured and ready.
    var isConfigured: Bool {
        provider?.isConfigured ?? false
    }

    /// Returns the name of the current provider, if any.
    var providerName: String? {
        provider?.name
    }

    // MARK: - Initialization

    private init() {
        configure(with: AISettingsStorage.shared.settings)
    }

    // MARK: - Configuration

    /// Configures the AI service with the given settings.
    func configure(with settings: AISettings) {
        switch settings.providerType {
        case .claude:
            if let apiKey = KeychainManager.getKey(for: .claude) {
                provider = ClaudeProvider(apiKey: apiKey, model: settings.claudeModel)
            } else {
                provider = nil
            }

        case .openai:
            if let apiKey = KeychainManager.getKey(for: .openai) {
                provider = OpenAIProvider(apiKey: apiKey, model: settings.openaiModel)
            } else {
                provider = nil
            }

        case .ollama:
            provider = OllamaProvider(baseURL: settings.ollamaURL, model: settings.ollamaModel)
        }
    }

    /// Reconfigures the service by reloading from stored settings.
    func reconfigure() {
        configure(with: AISettingsStorage.shared.settings)
    }

    // MARK: - AI Operations

    /// Generates a shell command from a natural language prompt.
    func generateCommand(prompt: String, context: AIContext) async throws -> String {
        guard let provider = provider else {
            throw AIError.notConfigured
        }
        return try await provider.generateCommand(prompt: prompt, context: context)
    }

    /// Explains command output and errors.
    func explainOutput(command: String, output: String, exitCode: Int32, columns: Int) async throws -> String {
        guard let provider = provider else {
            throw AIError.notConfigured
        }
        return try await provider.explainOutput(command: command, output: output, exitCode: exitCode, columns: columns)
    }
}
