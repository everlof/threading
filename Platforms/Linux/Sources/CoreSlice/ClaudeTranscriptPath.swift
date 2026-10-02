import Foundation

/// Claude's on-disk conversation slot, independent of account discovery or a host UI.
enum ClaudeTranscriptPath {
    static func storageURL(sessionID: TranscriptID, configPath: String, projectPath: String) -> URL? {
        guard sessionID.isSafePathComponent else { return nil }
        return URL(fileURLWithPath: configPath, isDirectory: true)
            .appendingPathComponent(AgentDefaults.claudeProjectsSubdirectory, isDirectory: true)
            .appendingPathComponent(projectSlug(forPath: projectPath), isDirectory: true)
            .appendingPathComponent(sessionID.rawValue, isDirectory: false)
            .appendingPathExtension(AgentDefaults.transcriptExtension)
    }

    /// Claude replaces every non-ASCII-alphanumeric UTF-16 code unit with a dash.
    static func projectSlug(forPath path: String) -> String {
        var slug = ""
        slug.reserveCapacity(path.utf16.count)
        for unit in path.utf16 {
            if preservedSlugCodeUnits.contains(unit), let scalar = Unicode.Scalar(unit) {
                slug.unicodeScalars.append(scalar)
            } else {
                slug.append(AgentDefaults.projectSlugSeparator)
            }
        }
        return slug
    }

    private static let preservedSlugCodeUnits: Set<UInt16> = Set(
        AgentDefaults.projectSlugPreservedCharacters.utf16
    )
}
