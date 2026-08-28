import Foundation
import OSLog

/// AI provider implementation for Anthropic's Claude API.
final class ClaudeProvider: AIProvider {

    // MARK: - Constants

    private enum API {
        static let baseURL = "https://api.anthropic.com/v1/messages"
        static let version = "2023-06-01"
    }

    // MARK: - Properties

    private let apiKey: String
    private let model: String
    private let session: URLSession

    var name: String { "Claude" }

    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Initialization

    init(apiKey: String, model: String = AIDefaults.claudeDefaultModel) {
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
            ThreadingLogger.ai.error("Claude API key not configured")
            throw AIError.missingAPIKey
        }

        guard let url = URL(string: API.baseURL) else {
            throw AIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(API.version, forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Log request
        let startTime = Date()
        ThreadingLogger.aiRequest.debug(
            "Claude request - model: \(self.model, privacy: .private(mask: .hash))"
        )
        ThreadingLogger.aiRequest.debug("System prompt: \(systemPrompt, privacy: .private)")
        ThreadingLogger.aiRequest.debug("User message: \(userMessage, privacy: .private)")

        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            ThreadingLogger.aiResponse.error("Claude response: invalid HTTP response")
            throw AIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let result = try await parseResponse(data, duration: duration)
            return result
        case 429:
            ThreadingLogger.aiResponse.error("Claude response: rate limited")
            throw AIError.rateLimited
        case 401:
            ThreadingLogger.aiResponse.error("Claude response: authentication failed")
            throw AIError.missingAPIKey
        default:
            let message = try? parseErrorMessage(data)
            ThreadingLogger.aiResponse.error(
                "Claude response: server error \(httpResponse.statusCode, privacy: .public) - \(message ?? "unknown", privacy: .private(mask: .hash))"
            )
            throw AIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data, duration: TimeInterval) async throws -> String {
        // `content` is read per element, matching the other content-block readers in this
        // codebase: the blocks stand alone, so one this reader cannot open should cost that
        // block and not the answer. Refusing the container raised `invalidResponse` for a
        // response whose text was sitting in the very next element.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = WireList.objects(
                  json["content"],
                  site: WireListSite.aiClaudeResponseContent,
                  log: ThreadingLogger.aiResponse
              ),
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            ThreadingLogger.aiResponse.error("Claude response: failed to parse JSON")
            throw AIError.invalidResponse
        }

        // Extract and log token usage
        if let usage = json["usage"] as? [String: Any] {
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
        ThreadingLogger.aiResponse.info(
            "Claude response - duration: \(String(format: "%.2f", duration), privacy: .public)s, input_tokens: \(inputTokens, privacy: .public), output_tokens: \(outputTokens, privacy: .public)"
        )

            // Record token usage
            await TokenUsageManager.shared.record(
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
        }

        ThreadingLogger.aiResponse.debug("Claude response text: \(text, privacy: .private)")
        return text
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
