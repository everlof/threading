import Foundation

/// Names the directory a managed workspace checks out into.
///
/// That basename is not an implementation detail. It is the agent's working directory, so it is
/// what its own status line, its shell prompt, `pwd`, and every path it prints for the rest of
/// the session are made of. Named by the session UUID, all of those read
/// `63baa514-da0f-4789-9756-221dc0df3d89@HEAD`: thirty-six characters that say nothing about the
/// task and, with nine parallel workspaces of one repository on disk, do not even say which one
/// this is.
///
/// So the name is the session's own title — the words the sidebar row shows — followed by the
/// first group of its UUID. The group keeps two sessions started from the same sentence apart,
/// stays matchable against the full id in the stored record and in the worktree's lock reason,
/// and is short enough that the whole name never exceeds the UUID it replaces.
///
/// The name is chosen once, at provisioning, and never recomputed. Renaming the session later
/// must not move the checkout: the agent is running with this path as its working directory, and
/// provider transcript lookup can derive a conversation's identity from it.
enum ManagedWorkspaceNaming {

    // MARK: - Public Methods

    /// The directory name for one session's managed checkout.
    ///
    /// Falls back to the plain UUID when the title yields no letters or digits at all — no title,
    /// or one written entirely in punctuation or emoji — because a name is worth having only
    /// while it is still a name.
    static func directoryName(for sessionID: SessionID, title: String?) -> String {
        let identifier = sessionID.uuidString.lowercased()
        let stem = title.map(slug(from:)) ?? ""
        guard !stem.isEmpty else { return identifier }

        let unique = String(identifier.prefix(ManagedWorkspaceNamingDefaults.uniqueLength))
        return stem + ManagedWorkspaceNamingDefaults.separator + unique
    }

    /// The title as lower-case ASCII words joined by hyphens, cut at a word boundary.
    ///
    /// Transliterated before it is filtered, never after: a Swedish or Japanese title filtered
    /// straight to ASCII loses every character it was made of and comes back empty, which would
    /// quietly put exactly those titles back on the UUID.
    static func slug(from title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false) ?? title
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let spelled = plain.filter { !ManagedWorkspaceNamingDefaults.apostrophes.contains($0) }
        let words = spelled.lowercased().split { character in
            !(character.isASCII && (character.isLetter || character.isNumber))
        }

        var stem = ""
        for word in words {
            guard !stem.isEmpty else {
                stem = String(word.prefix(ManagedWorkspaceNamingDefaults.slugLimit))
                continue
            }
            // Stops at the first word that does not fit rather than skipping ahead to a shorter
            // one: the name then reads as the opening of the title instead of as words picked
            // out of the middle of it.
            let joined = stem.count + ManagedWorkspaceNamingDefaults.separator.count + word.count
            guard joined <= ManagedWorkspaceNamingDefaults.slugLimit else { break }
            stem += ManagedWorkspaceNamingDefaults.separator + word
        }
        return stem
    }
}

enum ManagedWorkspaceNamingDefaults {
    /// Longest the words part may be. With the separator and the unique group this keeps the
    /// whole name inside the thirty-six characters a UUID took, so nothing that fitted on screen
    /// before this stops fitting now.
    static let slugLimit = 24

    /// The UUID's first group: enough to keep two sessions of the same task apart, and the
    /// prefix a person reads to match a directory against the id in the session record.
    static let uniqueLength = 8

    static let separator = "-"

    /// Dropped rather than split on, so a possessive stays one word: "a running child's output"
    /// becomes `running-childs`, not `running-child-s`.
    static let apostrophes: Set<Character> = ["'", "\u{2019}"]
}
