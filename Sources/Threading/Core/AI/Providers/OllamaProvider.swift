import Foundation
import OSLog

/// AI provider implementation for Ollama (local LLM).
final class OllamaProvider: AIProvider {

    // MARK: - Properties

    private let baseURL: URL
    private let model: String
    private let session: URLSession

    var name: String { "Ollama" }

    var isConfigured: Bool { true }

    // MARK: - Initialization

    init(baseURL: String = AIDefaults.ollamaDefaultURL, model: String = AIDefaults.ollamaDefaultModel) {
        self.baseURL = URL(string: baseURL) ?? URL(string: AIDefaults.ollamaDefaultURL)!
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AIDefaults.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - AIProvider

    func generateCommand(prompt: String, context: AIContext) async throws -> String {
        let systemPrompt = AISystemPrompts.commandGeneration(context: context)
        let fullPrompt = "\(systemPrompt)\n\nUser request: \(prompt)"
        let response = try await sendMessage(prompt: fullPrompt)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func explainOutput(command: String, output: String, exitCode: Int32, columns: Int) async throws -> String {
        let userMessage = """
        Command: \(command)
        Exit code: \(exitCode)

        Output:
        \(output.prefix(AIDefaults.maxOutputLength))
        """

        let fullPrompt = "\(AISystemPrompts.outputExplanation(columns: columns))\n\n\(userMessage)"
        return try await sendMessage(prompt: fullPrompt)
    }

    // MARK: - Private Methods

    private func sendMessage(prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Log request
        let startTime = Date()
        ThreadingLogger.aiRequest.debug("Ollama request - model: \(self.model), url: \(url.absoluteString)")
        ThreadingLogger.aiRequest.debug("Prompt: \(prompt)")

        let (data, response) = try await session.data(for: request)
        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            ThreadingLogger.aiResponse.error("Ollama response: invalid HTTP response")
            throw AIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResponse(data, duration: duration)
        case 404:
            ThreadingLogger.aiResponse.error("Ollama response: model '\(self.model)' not found")
            throw AIError.serverError(statusCode: 404, message: "Model '\(model)' not found. Run 'ollama pull \(model)' first.")
        default:
            let message = try? parseErrorMessage(data)
            ThreadingLogger.aiResponse.error("Ollama response: server error \(httpResponse.statusCode) - \(message ?? "unknown")")
            throw AIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResponse(_ data: Data, duration: TimeInterval) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String else {
            ThreadingLogger.aiResponse.error("Ollama response: failed to parse JSON")
            throw AIError.invalidResponse
        }

        // Extract and log token usage (Ollama provides eval counts)
        let promptEvalCount = json["prompt_eval_count"] as? Int ?? 0
        let evalCount = json["eval_count"] as? Int ?? 0
        ThreadingLogger.aiResponse.info("Ollama response - duration: \(String(format: "%.2f", duration))s, prompt_eval_count: \(promptEvalCount), eval_count: \(evalCount)")

        // Record token usage
        TokenUsageManager.shared.record(model: model, inputTokens: promptEvalCount, outputTokens: evalCount)

        ThreadingLogger.aiResponse.debug("Ollama response text: \(response)")
        return response
    }

    private func parseErrorMessage(_ data: Data) throws -> String? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? String else {
            return nil
        }
        return error
    }

    // MARK: - Connection Test

    /// Tests if Ollama is running and accessible.
    func testConnection() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}
