import Foundation

/// Filesystem names shared by account discovery and process routing. Login contents remain
/// provider-owned; Threading reads only the marker needed to identify a completed account.
enum AgentAccountDefaults {
    static let defaultDisplayName = "Default"
    static let claudeDirectoryPrefix = ".claude-"
    static let codexDirectoryPrefix = ".codex-"
    static let claudeDefaultDirectory = ".claude"
    static let codexDefaultDirectory = ".codex"
    static let claudeConfigMarkers = [".claude.json", "settings.json"]
    static let codexAuthMarker = "auth.json"
    static let claudeScienceDirectory = ".claude-science"
    static let claudeScienceFileMarker = "install-id"
    static let claudeScienceDirectoryMarkers = ["runtime", "orgs"]
    static let sessionsSubdirectory = "sessions"
}
