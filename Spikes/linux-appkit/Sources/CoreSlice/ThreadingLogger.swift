import OSLog

/// Centralized logging infrastructure using Apple's OSLog framework.
/// View logs with: `log stream --predicate 'subsystem == "codes.threading"'`
/// Or filter by category: `log stream --predicate 'subsystem == "codes.threading" AND category BEGINSWITH "ai"'`
///
/// Every interpolation chooses `privacy:` explicitly. Public fields are structural machine facts:
/// enum tokens, counts, durations, status codes and opaque session identifiers. User content,
/// paths, filenames, URLs, account labels, command arguments, provider/client text and arbitrary
/// error descriptions are private; use `.private(mask: .hash)` when correlation is useful and
/// `.private` for prompts or response bodies. Credentials and bearer tokens are never logged,
/// even privately. `scripts/check_logging_boundaries.py` enforces the source-level part.
public enum ThreadingLogger {

    // MARK: - Subsystem

    private static let subsystem = "codes.threading"

    // MARK: - AI Loggers

    /// General AI operations (provider selection, configuration)
    public static let ai = Logger(subsystem: subsystem, category: "ai")

    /// AI request details (prompts, models, parameters)
    public static let aiRequest = Logger(subsystem: subsystem, category: "ai.request")

    /// AI response details (content, token usage)
    public static let aiResponse = Logger(subsystem: subsystem, category: "ai.response")

    // MARK: - Terminal Loggers

    /// Application launch, shutdown, and process-wide safety boundaries.
    public static let app = Logger(subsystem: subsystem, category: "app")

    /// Terminal operations (buffer, rendering)
    public static let terminal = Logger(subsystem: subsystem, category: "terminal")

    /// Embedded browser tabs, baseline persistence, and Playwright automation.
    public static let browser = Logger(subsystem: subsystem, category: "browser")

    /// Adopted CoreSimulator lifecycle, live-helper sessions, codecs, and aggregate frame health.
    public static let simulator = Logger(subsystem: subsystem, category: "simulator")

    /// Session management (lifecycle, state)
    public static let session = Logger(subsystem: subsystem, category: "session")

    // MARK: - Agent Loggers

    /// Agent session lifecycle (launch, resume, exit, identifier discovery)
    public static let agent = Logger(subsystem: subsystem, category: "agent")

    /// Read-only git queries behind the review pane (command, duration, failures)
    public static let git = Logger(subsystem: subsystem, category: "git")

    /// Coarse performance spans, main-thread stalls, and trace export failures.
    public static let performance = Logger(subsystem: subsystem, category: "performance")

    /// The local, hash-linked execution ledger (storage, rotation, integrity, deletion).
    public static let audit = Logger(subsystem: subsystem, category: "audit")

    /// Usage metering, durable limit history, and dashboard source coverage.
    public static let usage = Logger(subsystem: subsystem, category: "usage")

    /// App chrome themes, terminal palettes, theme imports, and local image assets.
    public static let theme = Logger(subsystem: subsystem, category: "theme")

    /// Persistence recovery/migration, SQLite, reclaimable-artifact scans, and disk cleanup.
    public static let storage = Logger(subsystem: subsystem, category: "storage")

    // MARK: - MCP Loggers

    /// The MCP server Threading exposes to agents (listener lifecycle, tool calls)
    public static let mcp = Logger(subsystem: subsystem, category: "mcp")

    /// Installed extension processes and their private loopback host service.
    public static let extensions = Logger(subsystem: subsystem, category: "extensions")

    /// Remote access — the tunnel, its loopback server, connections and auth decisions.
    public static let remote = Logger(subsystem: subsystem, category: "remote")

    /// The `threading-ptyd` background PTY host — availability, the hello gate, the frame pump.
    /// Its own category because the link is invisible by construction: when it degrades, every
    /// session goes on working with an in-process PTY and nothing on screen says why.
    public static let ptyHost = Logger(subsystem: subsystem, category: "ptyHost")

    /// GitHub connectivity — credential resolution, the app connection, brokered reads.
    public static let github = Logger(subsystem: subsystem, category: "github")

    /// Sparkle software updates — updater start, check outcomes, driver-stage failures.
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}
