import AppKit

// MARK: - Theme Words

/// The few places a theme may change what the app *says*, not only how it looks: the words a
/// native conversation's status line draws while a turn is in flight ("Herding…", "Fetching…"),
/// the invitation in an empty new-session composer, and the name a fresh session wears until
/// something names it ("New Session").
///
/// **Three slots, deliberately.** All are already placeholder copy chosen from a list or written
/// once — the status line's word is dealt from `WorkingWords.all` for variety, the composer's
/// prompt is a suggestion rather than a label, and the untitled name is a stand-in that the first
/// prompt, the agent or the person replaces. Nothing a person reads to understand state is
/// themable: "Waiting for your answer", "Stopped · usage limit reached", every accessibility
/// label and every control's title stay the app's own and stay localized, because a theme
/// that renamed a state would be a theme that hid it. Theme words are the author's text and
/// are shown as written in every language.
public struct ThemeWords: Equatable {

    /// Dealt one per turn, every word used before any repeats (`WorkingWordCycle`). Empty
    /// means the app's own list.
    public var working: [String]
    /// The empty new-session composer's invitation. Absent means the app's own.
    public var composerPlaceholder: String?
    /// What a session nothing has named yet is called on screen, in place of "New Session".
    /// Presentation only: it is never stored as a title, never sent where a name is a fact
    /// (notifications, search, migration), and naming detection keeps comparing stored titles
    /// with the app's own placeholder. Absent means the app's own.
    public var untitledSession: String?

    public init(
        working: [String] = [],
        composerPlaceholder: String? = nil,
        untitledSession: String? = nil
    ) {
        self.working = working
        self.composerPlaceholder = composerPlaceholder
        self.untitledSession = untitledSession
    }

    public var isEmpty: Bool {
        working.isEmpty && composerPlaceholder == nil && untitledSession == nil
    }
}

extension ThemeWords: Codable {
    private enum CodingKeys: String, CodingKey {
        case working, composerPlaceholder, untitledSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        working = try container.decodeIfPresent([String].self, forKey: .working) ?? []
        composerPlaceholder = try container.decodeIfPresent(String.self, forKey: .composerPlaceholder)
        untitledSession = try container.decodeIfPresent(String.self, forKey: .untitledSession)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !working.isEmpty { try container.encode(working, forKey: .working) }
        try container.encodeIfPresent(composerPlaceholder, forKey: .composerPlaceholder)
        try container.encodeIfPresent(untitledSession, forKey: .untitledSession)
    }
}

// MARK: - Limits

public enum ThemeWordsLimits {
    /// Enough for variety across a sitting, the app's own list's size.
    public static let maximumWorkingWords = 20
    /// The status line also carries the elapsed time and effort; a word longer than this
    /// pushes them out of a narrow conversation.
    public static let maximumWorkingWordLength = 28
    public static let maximumPlaceholderLength = 80
    /// A sidebar row's width: a longer stand-in name truncates before it says anything.
    public static let maximumUntitledSessionLength = 32
}
