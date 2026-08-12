import Foundation
import os

// MARK: - Claude Account Last Run Model

/// The model a **login** last ran, read back from the transcripts it has already written.
///
/// `ClaudeTranscriptModel` answers the same question for one conversation Threading is showing.
/// This answers it for an account with no conversation on screen — the composer's case, and a
/// brand-new install's — which is the last gap where the model row had nothing to say.
///
/// The other sources are all configuration, and configuration is exactly what a login that leaves
/// the choice to the CLI does not have: `settings.json` names no model, the organisation names
/// none, and Threading has never watched a session on it start. Measured on a real account with
/// 167 transcripts and no `model` key anywhere, the newest one records `claude-opus-5` — the
/// answer the user wanted, sitting on disk the whole time.
///
/// **This reports what ran, not what was configured**, so callers must label it that way. A
/// session launched with an explicit `--model` writes a transcript like any other, and nothing in
/// the file says whether the model was chosen or inherited. "Last used" is true either way;
/// "account default" would not be.
///
/// Three costs this deliberately avoids, two of them `ClaudeAccountTranscripts`':
///
/// - **Bounded breadth.** Only the few most recently touched project directories are considered.
/// - **Bounded depth.** The chosen transcript is read backwards through
///   `ClaudeTranscriptModel.newestModel(at:)`, which caps how far it looks before giving up.
/// - **Asked once.** The result is memoised for the lifetime of the process. This is a fallback
///   for an account Threading has not yet watched run; the moment it does watch one,
///   `AccountPreference.lastReportedModel` answers first and this is never consulted again.
enum ClaudeAccountLastRunModel {

    // MARK: - Properties

    private static let memo = ClaudeAccountFactMemo<String>()

    // MARK: - Public Methods

    /// The model this login's newest transcript recorded, or nil when it has never run.
    static func lastRunModel(account: AgentAccount) -> String? {
        guard account.provider.supports(.transcriptModelRecord) else { return nil }

        return memo.value(forConfigPath: account.configPath) {
            ClaudeAccountTranscripts.newest(inProjectsOf: account.configPath)
                .flatMap { ClaudeTranscriptModel.newestModel(at: $0) }
        }
    }

    /// Drops the memo, so a test can watch the same account answer differently.
    static func forgetAll() {
        memo.forgetAll()
    }
}
