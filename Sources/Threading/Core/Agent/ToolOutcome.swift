import Foundation

// MARK: - Tool Outcome

/// What actually became of a tool call, settled when its result lands.
///
/// The provider's error flag is necessary but not sufficient: Codex folds exit codes into it
/// and Claude forwards `is_error`, yet a shell command can print `command not found` and still
/// be reported as a success. t3code's answer — sniff the output text for the marks of failure —
/// is adopted here, narrowed to shell output only: a `Read` or `Grep` result is arbitrary file
/// content, where the same strings prove nothing about the call that fetched them.
///
/// A false positive paints a successful row as failed, which is worse than the quiet miss, so
/// the sniff is deliberately biased toward precision: the generic phrases are only trusted in
/// the opening lines, where a failed command reports itself.
enum ToolOutcome: Equatable {
    case succeeded
    case failed

    /// The turn ended before this call reported back — stopped, not failed and not still
    /// running. Without a terminal state such a row reads "running…" forever.
    case interrupted

    // MARK: - Classification

    /// The opening lines a failure phrase is trusted in. Deeper down, "No such file or
    /// directory" is as likely quoted output as a report about the command itself.
    private static let sniffedLineCount = 3

    /// Substrings that mark a failed shell command when they appear in its opening lines.
    private static let failurePhrases = [
        "command not found",
        ": No such file or directory",
        "ENOENT"
    ]

    /// An explicit exit-code report is specific enough to trust anywhere in the output.
    /// Matches "exit code 1", "exited with code 2", "exited with exit code 3" — but never
    /// code 0, which is the shell saying it worked.
    private static let exitCodeReport =
        "exit(ed)?(\\s+with)?(\\s+exit)?\\s+code:?\\s+[1-9]"

    static func classify(text: String, isError: Bool, tool: ToolIdentity) -> ToolOutcome {
        if isError { return .failed }
        guard tool == .bash else { return .succeeded }

        let head = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(sniffedLineCount)
            .joined(separator: "\n")
        if failurePhrases.contains(where: head.contains) { return .failed }

        let reportsExitCode = text.range(
            of: exitCodeReport,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if reportsExitCode { return .failed }

        return .succeeded
    }
}
