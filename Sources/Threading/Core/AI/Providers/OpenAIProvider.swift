import Foundation
import OSLog

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
            ThreadingLogger.ai.error("OpenAI API key not configured")
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

        // Log request
        let startTime = Date()
        ThreadingLogger.aiRequest.debug(
            "OpenAI request - model: \(self.model, privacy: .private(mask: .hash))"
        )
        ThreadingLogger.aiRequest.debug("System prompt: \(systemPrompt, privacy: .private)")
        ThreadingLogger.aiRequest.debug("User message: \(userMessage, privacy: .private)")

        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            ThreadingLogger.aiResponse.error("OpenAI response: invalid HTTP response")
            throw AIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try await parseResponse(data, duration: duration)
        case 429:
            ThreadingLogger.aiResponse.error("OpenAI response: rate limited")
            throw AIError.rateLimited
        case 401:
            ThreadingLogger.aiResponse.error("OpenAI response: authentication failed")
            throw AIError.missingAPIKey
        default:
            let message = try? parseErrorMessage(data)
            ThreadingLogger.aiResponse.error(
                "OpenAI response: server error \(httpResponse.statusCode, privacy: .public) - \(message ?? "unknown", privacy: .private(mask: .hash))"
            )
            throw AIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data, duration: TimeInterval) async throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            ThreadingLogger.aiResponse.error("OpenAI response: failed to parse JSON")
            throw AIError.invalidResponse
        }

        // Extract and log token usage
        if let usage = json["usage"] as? [String: Any] {
            let promptTokens = usage["prompt_tokens"] as? Int ?? 0
            let completionTokens = usage["completion_tokens"] as? Int ?? 0
        ThreadingLogger.aiResponse.info(
            "OpenAI response - duration: \(String(format: "%.2f", duration), privacy: .public)s, prompt_tokens: \(promptTokens, privacy: .public), completion_tokens: \(completionTokens, privacy: .public)"
        )

            // Record token usage
            await TokenUsageManager.shared.record(
                model: model,
                inputTokens: promptTokens,
                outputTokens: completionTokens
            )
        }

        ThreadingLogger.aiResponse.debug("OpenAI response text: \(content, privacy: .private)")
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
