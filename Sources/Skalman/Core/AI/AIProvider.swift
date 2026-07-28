import Foundation

// MARK: - AI Context

/// Context information about the terminal session for AI requests.
struct AIContext {
    let workingDirectory: String?
    let shell: String
    let operatingSystem: String

    static func current(workingDirectory: String?, shell: String = TerminalDefaults.defaultShell) -> AIContext {
        return AIContext(
            workingDirectory: workingDirectory,
            shell: shell,
            operatingSystem: "macOS"
        )
    }
}

// MARK: - AI Response

/// Response from an AI provider.
struct AIResponse {
    let content: String
    let suggestedCommand: String?
}

// MARK: - AI Error

enum AIError: LocalizedError {
    case notConfigured
    case missingAPIKey
    case networkError(Error)
    case invalidResponse
    case rateLimited
    case serverError(statusCode: Int, message: String?)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.string("AI provider is not configured")
        case .missingAPIKey:
            return L10n.string("API key is missing. Please add your API key in Settings.")
        case .networkError(let error):
            return L10n.format("Network error: %@", error.localizedDescription)
        case .invalidResponse:
            return L10n.string("Invalid response from AI provider")
        case .rateLimited:
            return L10n.string("Rate limited. Please try again later.")
        case .serverError(let code, let message):
            if let message = message {
                return L10n.format("Server error (%lld): %@", Int64(code), message)
            }
            return L10n.format("Server error (%lld)", Int64(code))
        case .timeout:
            return L10n.string("Request timed out")
        }
    }
}

// MARK: - AI Provider Protocol

/// Protocol for AI service providers.
protocol AIProvider {
    /// Display name of the provider.
    var name: String { get }

    /// Whether the provider is properly configured and ready to use.
    var isConfigured: Bool { get }

    /// Generates a shell command from a natural language prompt.
    func generateCommand(prompt: String, context: AIContext) async throws -> String

    /// Explains command output, typically for error analysis.
    func explainOutput(command: String, output: String, exitCode: Int32, columns: Int) async throws -> String
}

// MARK: - System Prompts

enum AISystemPrompts {

    static func commandGeneration(context: AIContext) -> String {
        var prompt = """
        You are a helpful assistant that generates shell commands for \(context.operatingSystem).
        The user's shell is \(context.shell).
        """

        if let directory = context.workingDirectory {
            prompt += "\nCurrent working directory: \(directory)"
        }

        prompt += """

        Generate ONLY the shell command, nothing else. Do not include explanations, markdown formatting, or code blocks.
        If multiple commands are needed, combine them with && or ;.
        The command should be safe and not destructive unless explicitly requested.
        """

        return prompt
    }

    static func outputExplanation(columns: Int) -> String {
        """
        You are a helpful assistant that explains terminal command output.
        Analyze the command, its output, and exit code to help the user understand what happened.
        If there's an error, explain what went wrong and suggest how to fix it.
        Keep your explanation concise but informative.

        CRITICAL FORMATTING RULES:
        - The terminal is \(columns) columns wide
        - You MUST manually wrap lines so no line exceeds \(columns - 5) characters
        - Break lines at word boundaries (spaces), never in the middle of words
        - Use short sentences and paragraphs
        - Add blank lines between paragraphs for readability

        You may use ANSI escape codes for color (these don't count toward line length):
        - \\x1b[1m = bold, \\x1b[32m = green, \\x1b[31m = red, \\x1b[33m = yellow, \\x1b[36m = cyan, \\x1b[0m = reset

        Example of proper formatting for a ~60 column terminal:
        \\x1b[1mError:\\x1b[0m The \\x1b[36m-m\\x1b[0m flag is not valid for sleep.

        The \\x1b[36msleep\\x1b[0m command expects a number of seconds.
        Try: \\x1b[36msleep 10\\x1b[0m
        """
    }
}
