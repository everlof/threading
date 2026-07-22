import OSLog

/// Centralized logging infrastructure using Apple's OSLog framework.
/// View logs with: `log stream --predicate 'subsystem == "com.skalman"'`
/// Or filter by category: `log stream --predicate 'subsystem == "com.skalman" AND category BEGINSWITH "ai"'`
enum SkalmanLogger {

    // MARK: - Subsystem

    private static let subsystem = "com.skalman"

    // MARK: - AI Loggers

    /// General AI operations (provider selection, configuration)
    static let ai = Logger(subsystem: subsystem, category: "ai")

    /// AI request details (prompts, models, parameters)
    static let aiRequest = Logger(subsystem: subsystem, category: "ai.request")

    /// AI response details (content, token usage)
    static let aiResponse = Logger(subsystem: subsystem, category: "ai.response")

    // MARK: - Terminal Loggers

    /// Terminal operations (buffer, rendering)
    static let terminal = Logger(subsystem: subsystem, category: "terminal")

    /// Session management (lifecycle, state)
    static let session = Logger(subsystem: subsystem, category: "session")

    // MARK: - Agent Loggers

    /// Agent session lifecycle (launch, resume, exit, identifier discovery)
    static let agent = Logger(subsystem: subsystem, category: "agent")

    /// Read-only git queries behind the review pane (command, duration, failures)
    static let git = Logger(subsystem: subsystem, category: "git")

    // MARK: - MCP Loggers

    /// The MCP server Skalman exposes to agents (listener lifecycle, tool calls)
    static let mcp = Logger(subsystem: subsystem, category: "mcp")
}
