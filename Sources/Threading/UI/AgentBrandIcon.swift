import AppKit

// MARK: - Agent Brand Icons

/// The agents' own marks — Claude's coral starburst, OpenAI's knot — used wherever a session,
/// chip, or list row identifies its agent.
///
/// Loaded as loose PNGs from the app bundle's `Icons/` folder rather than the asset catalogue.
/// Claude's mark keeps its brand colour; OpenAI's is monochrome by design, so it ships as a
/// template image and tints with its context exactly like the SF Symbols it sits beside — which
/// is also what keeps it visible in dark mode.
enum AgentBrandIcons {

    static let claude = load(
        AgentIconDefaults.claudeResource,
        isTemplate: false,
        accessibility: AgentKind.claude.displayName
    )
    static let codex = load(
        AgentIconDefaults.codexResource,
        isTemplate: true,
        accessibility: AgentKind.codex.displayName
    )

    /// Bundled at 2× the nominal point size, so the mark stays crisp on Retina displays.
    private static func load(_ name: String, isTemplate: Bool, accessibility: String) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: AgentIconDefaults.resourceExtension,
            subdirectory: AgentIconDefaults.resourceSubdirectory
        ), let image = NSImage(contentsOf: url) else { return nil }

        image.size = NSSize(
            width: AgentIconDefaults.pointSize,
            height: AgentIconDefaults.pointSize
        )
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibility
        return image
    }
}

extension AgentKind {

    /// The agent's brand mark, or nil for kinds identified by an SF Symbol (`symbolName`).
    var brandIcon: NSImage? {
        switch self {
        case .claude: return AgentBrandIcons.claude
        case .codex: return AgentBrandIcons.codex
        case .grok, .openCode: return nil
        }
    }

    /// The mark shown beside the agent's name: its brand icon, else its SF Symbol.
    var icon: NSImage? {
        brandIcon ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: displayName)
    }
}

// MARK: - Agent Icon Defaults

enum AgentIconDefaults {
    static let claudeResource = "AgentIconClaude"
    static let codexResource = "AgentIconCodex"
    static let resourceExtension = "png"
    static let resourceSubdirectory = "Icons"

    /// Nominal size; views with a smaller slot scale the mark down proportionally.
    static let pointSize: CGFloat = 15

    /// Dims a non-template brand mark for a dormant row, standing in for the tertiary
    /// tint that dims the SF Symbols beside it.
    static let dormantAlpha: CGFloat = 0.5
}
