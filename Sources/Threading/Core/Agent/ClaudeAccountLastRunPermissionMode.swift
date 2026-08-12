import Foundation

// MARK: - Claude Account Last Run Permission Mode

/// The permission mode a **login** last ran in, read back from the transcripts it has written.
///
/// The sibling of `ClaudeAccountLastRunModel`, for the same reason and with the same limits: the
/// composer has no conversation to ask, and the account may have configured nothing.
///
/// **This is the only source for the case the CLI decides for itself.** With no
/// `permissions.defaultMode` in any settings layer, Claude picks between `default` and `auto` on
/// a server-side gate — see `ClaudeSettings` — so there is no file to read and no fallback to
/// hard-code. Measured on the machine this was written against: forty recent transcripts across
/// four logins, thirty-eight of them recording `auto`, while every settings file on disk was
/// silent and Claude's own settings screen would have answered `default`.
///
/// **This reports what ran, not what was configured**, so callers must label it that way — the
/// rule `ClaudeAccountLastRunModel` already states. Nothing in a transcript says whether the mode
/// was chosen, inherited or reached with Shift+Tab halfway through, so "last used" is true either
/// way and "agent's setting" would not be. `PermissionModePresentation` marks it `(last used)`
/// for exactly that reason.
///
/// The newest record wins rather than the first, which is the opposite of what it looks like it
/// should be: a session's first record is written before the CLI has finished resolving its
/// posture — on the measured transcripts it commonly reads `default` in a session that then spends
/// its whole life in `auto` — so the head of the file is a snapshot of an unfinished decision.
enum ClaudeAccountLastRunPermissionMode {

    // MARK: - Properties

    private static let memo = ClaudeAccountFactMemo<AgentPermissionMode>()

    // MARK: - Public Methods

    /// The posture this login's newest transcript recorded, or nil when it has never run — and
    /// nil for a runtime that records none, which is every runtime but Claude today.
    static func lastRunMode(account: AgentAccount) -> AgentPermissionMode? {
        guard account.provider.supports(.transcriptPermissionModeRecord) else { return nil }

        return memo.value(forConfigPath: account.configPath) {
            ClaudeAccountTranscripts.newest(inProjectsOf: account.configPath)
                .flatMap { ClaudeTranscriptPermissionMode.newestMode(at: $0) }
        }
    }

    /// Drops the memo, so a test can watch the same account answer differently.
    static func forgetAll() {
        memo.forgetAll()
    }
}
