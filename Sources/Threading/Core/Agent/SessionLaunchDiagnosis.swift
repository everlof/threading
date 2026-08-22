import Foundation

// MARK: - Session Launch Diagnosis

/// Reads what an agent printed on its way out and, where it recognises the words, says what
/// happened in the user's terms instead of the runtime's.
///
/// Every rule here is a *bonus*. A launch failure is already fully handled without one — the
/// captured lines are kept, shown and copyable either way — so a rule that stops matching
/// because a CLI reworded itself costs a better sentence and nothing else. That is the only
/// reason matching English output is acceptable at all, and it is why nothing downstream is
/// allowed to require a match.
///
/// The rules are deliberately narrow. A pattern broad enough to catch a family of errors will
/// eventually catch a different one and explain it wrongly, which is worse than not explaining
/// it: a user who is told the wrong cause stops reading the lines that say the right one.
enum SessionLaunchDiagnosis {

    // MARK: - Types

    struct Match: Equatable {
        /// One sentence for the band.
        let summary: String
        /// A stable slug, so a later reader can recognise this cause without re-matching prose.
        let knownCause: String
        /// Whether a recovery attempt has anything to work on. A missing executable is a real
        /// diagnosis with nothing for an agent to repair.
        let isRecoverable: Bool
    }

    /// Slugs, named once so a rule and its reader cannot drift apart.
    enum Cause {
        static let transcriptUnreadable = "transcript-unreadable"
        static let executableMissing = "executable-missing"
        static let identifierInUse = "identifier-in-use"
        static let notSignedIn = "not-signed-in"
    }

    // MARK: - Public Methods

    /// The first rule that matches the captured output, or nil.
    static func classify(lines: [String], kind: AgentKind) -> Match? {
        let haystack = lines.joined(separator: "\n").lowercased()
        guard !haystack.isEmpty else { return nil }

        for rule in rules {
            guard rule.matches(haystack) else { continue }
            return Match(
                summary: rule.summary(kind),
                knownCause: rule.cause,
                isRecoverable: rule.isRecoverable
            )
        }
        return nil
    }

    // MARK: - Private Methods

    private struct Rule: Sendable {
        /// Every phrase must appear. Two weak signals together beat one broad one — "resume"
        /// alone is in half the CLI's help text.
        let phrases: [String]
        let cause: String
        let isRecoverable: Bool
        let summary: @Sendable (AgentKind) -> String

        func matches(_ haystack: String) -> Bool {
            phrases.allSatisfy { haystack.contains($0) }
        }
    }

    /// Ordered most specific first: the transcript rules name a file, and the generic
    /// "cannot start" rules would otherwise answer for them.
    private static let rules: [Rule] = [
        Rule(
            phrases: ["resume", "ordinal"],
            cause: Cause.transcriptUnreadable,
            isRecoverable: true,
            summary: { kind in
                L10n.format(
                    "%@ could not read this conversation's saved file, so it stopped instead of resuming.",
                    kind.displayName
                )
            }
        ),
        Rule(
            phrases: ["failed to resume"],
            cause: Cause.transcriptUnreadable,
            isRecoverable: true,
            summary: { kind in
                L10n.format(
                    "%@ refused to resume this conversation.",
                    kind.displayName
                )
            }
        ),
        Rule(
            phrases: ["command not found"],
            cause: Cause.executableMissing,
            isRecoverable: false,
            summary: { kind in
                L10n.format(
                    "The %@ command was not found on this Mac.",
                    kind.displayName
                )
            }
        ),
        Rule(
            phrases: ["session id", "already in use"],
            cause: Cause.identifierInUse,
            isRecoverable: false,
            summary: { kind in
                L10n.format(
                    "%@ is already using this conversation's identifier somewhere else.",
                    kind.displayName
                )
            }
        ),
        Rule(
            phrases: ["not logged in"],
            cause: Cause.notSignedIn,
            isRecoverable: false,
            summary: { kind in
                L10n.format("This %@ login needs signing in again.", kind.displayName)
            }
        )
    ]
}
