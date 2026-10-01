import AppKit

// MARK: - Theme Words

/// The few places a theme may change what the app *says*, not only how it looks: the words a
/// native conversation's status line draws while a turn is in flight ("Herding…", "Fetching…"),
/// and the invitation in an empty new-session composer.
///
/// **Two slots, deliberately.** Both are already playful copy chosen from a list or written once
/// — the status line's word is dealt from `WorkingWords.all` for variety, and the composer's
/// prompt is a suggestion rather than a label. Nothing a person reads to understand state is
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

    public init(working: [String] = [], composerPlaceholder: String? = nil) {
        self.working = working
        self.composerPlaceholder = composerPlaceholder
    }

    public var isEmpty: Bool { working.isEmpty && composerPlaceholder == nil }
}

extension ThemeWords: Codable {
    private enum CodingKeys: String, CodingKey {
        case working, composerPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        working = try container.decodeIfPresent([String].self, forKey: .working) ?? []
        composerPlaceholder = try container.decodeIfPresent(String.self, forKey: .composerPlaceholder)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !working.isEmpty { try container.encode(working, forKey: .working) }
        try container.encodeIfPresent(composerPlaceholder, forKey: .composerPlaceholder)
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
}
