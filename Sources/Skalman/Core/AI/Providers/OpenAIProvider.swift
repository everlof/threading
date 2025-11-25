import Foundation

/// AI provider implementation for OpenAI's API.
final class OpenAIProvider: AIProvider {

    // MARK: - Constants

    private enum API {
        static let baseURL = "https://api.openai.com/v1/chat/completions"
    }

    // MARK: - Properties

    private let apiKey: String
    private let model: String
    private let session: URLSession

    var name: String { "OpenAI" }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Initialization

    init(apiKey: String, model: String = AIDefaults.openaiDefaultModel) {
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AIDefaults.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - AIProvider

    func generateCommand(prompt: String, context: AIContext) async throws -> String {
        let systemPrompt = AISystemPrompts.commandGeneration(context: context)
        let response = try await sendMessage(userMessage: prompt, systemPrompt: systemPrompt)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func explainOutput(command: String, output: String, exitCode: Int32, columns: Int) async throws -> String {
        let userMessage = """
        Command: \(command)
        Exit code: \(exitCode)

        Output:
        \(output.prefix(AIDefaults.maxOutputLength))
        """

        return try await sendMessage(userMessage: userMessage, systemPrompt: AISystemPrompts.outputExplanation(columns: columns))
    }

    // MARK: - Private Methods

    private func sendMessage(userMessage: String, systemPrompt: String) async throws -> String {
        guard isConfigured else {
            throw AIError.missingAPIKey
        }

        guard let url = URL(string: API.baseURL) else {
            throw AIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data)
        case 429:
            throw AIError.rateLimited
        case 401:
            throw AIError.missingAPIKey
        default:
            let message = try? parseErrorMessage(data)
            throw AIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }
        return content
    }

    private func parseErrorMessage(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
