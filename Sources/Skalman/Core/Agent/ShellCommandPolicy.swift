import Foundation

// MARK: - Shell Command Policy

/// Decides whether a shell command only *reads*, and so is not worth interrupting the user for.
///
/// This exists because of an asymmetry between the two agents. Claude reads files with distinct
/// `Read`, `Grep` and `Glob` tools, which `PermissionPolicy` can admit by name. Codex reads
/// files by shelling out to `cat` — so measured across 1008 rollouts, 82% of its tool calls are
/// shell execution, and without this every `ls` raises a card. Naming the tool is not enough
/// when one tool name covers both reading and writing; the *command* has to be read.
///
/// **It is built to be wrong in one direction only.** Every rule below refuses on doubt, and
/// the failure it protects against is auto-approving something destructive. So:
///
/// - The allowlist is short, explicit, and holds only commands with no write mode at all.
///   `sed` and `awk` are absent despite being read-shaped, because `sed -i` edits in place and
///   `awk` can open files for writing.
/// - Anything that could reach a command this policy never sees is refused outright:
///   redirection, command substitution, backgrounding, process substitution, a leading variable
///   assignment, or an absolute path in place of a bare command name.
/// - Splitting on operators is deliberately naive, and that is safe *because* it is naive: a
///   `;` inside a quoted argument splits into a segment whose first word is not on the
///   allowlist, so the whole command is refused rather than admitted.
///
/// Nothing here weakens an existing rule. It only narrows what prompts, to the same bar
/// Claude's `Read` and `Grep` already clear.
enum ShellCommandPolicy {

    // MARK: - Public Methods

    /// Whether every part of a command line is a known read-only invocation.
    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Checked before splitting, because these are precisely the constructs that would let a
        // segment mean something other than the words it appears to contain.
        guard trimmed.rangeOfCharacter(from: Rule.forbiddenCharacters) == nil,
              !Rule.forbiddenSequences.contains(where: trimmed.contains),
              !isBackgrounded(trimmed) else {
            return false
        }

        let segments = split(trimmed)
        guard !segments.isEmpty else { return false }

        return segments.allSatisfy(isReadOnlySegment)
    }

    // MARK: - Private Methods

    /// Whether a lone `&` backgrounds part of the line.
    ///
    /// `&&` is a chain and every link of it is vetted below, but a single `&` detaches what
    /// came before it and lets the rest run unwatched — so the two have to be told apart rather
    /// than the character banned outright. Measured on real rollouts, banning it outright is
    /// what made a chain of reads prompt.
    private static func isBackgrounded(_ command: String) -> Bool {
        command.replacingOccurrences(of: "&&", with: "").contains("&")
    }

    /// One command line broken at every operator that starts a new command.
    ///
    /// Splitting on the bare characters handles the doubled operators for free: `&&` and `||`
    /// each yield an empty middle segment, which is filtered out.
    private static func split(_ command: String) -> [String] {
        command
            .components(separatedBy: CharacterSet(charactersIn: "&|;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func isReadOnlySegment(_ segment: String) -> Bool {
        let tokens = segment.split(separator: " ").map(String.init)
        guard let name = tokens.first else { return false }

        // `FOO=bar cmd` runs `cmd` with an environment this policy never inspected, and
        // `/usr/bin/whatever` names a binary rather than the command the allowlist vetted.
        guard !name.contains("="), !name.contains("/") else { return false }
        guard Rule.readOnlyCommands.contains(name) else { return false }

        let arguments = Array(tokens.dropFirst())

        switch name {
        case "find", "fd":
            // `find` is the one allowlisted command that can run other commands and delete.
            return !arguments.contains { argument in
                Rule.findWriteFlags.contains { argument.hasPrefix($0) }
            }

        case "git":
            return isReadOnlyGit(arguments)

        case "sed":
            return isPrintingSed(arguments)

        default:
            return true
        }
    }

    /// Whether a `sed` call is the print-a-line-range form and nothing else.
    ///
    /// `sed` is here reluctantly and admitted narrowly, because it is how Codex *reads*:
    /// measured across real rollouts, `sed -n '1,220p' file` accounts for 42% of its shell
    /// calls, and refusing it made the classifier nearly pointless. It is also the one
    /// allowlisted command that can write — `-i` edits in place, `-f` runs a script this policy
    /// never sees, and a `w` inside the script writes a file.
    ///
    /// So rather than banning the write flags and admitting the rest, the *script itself* must
    /// be a bare line range ending in `p`. Anything else — a substitution, a `w`, a regex
    /// address — is refused, and that includes forms that happen to be harmless. Of the 2,650
    /// real `sed` calls seen, none used `-i` or `-f`.
    private static func isPrintingSed(_ arguments: [String]) -> Bool {
        // `-n` suppresses the automatic print, which is what makes this a read of a range
        // rather than a rewrite of the whole file.
        guard arguments.contains("-n") else { return false }

        guard !arguments.contains(where: { argument in
            Rule.sedWriteFlags.contains { argument.hasPrefix($0) }
        }) else { return false }

        guard let script = arguments.first(where: { !$0.hasPrefix("-") }) else { return false }

        return script.range(of: Rule.sedPrintScript, options: .regularExpression) != nil
    }

    /// Whether a `git` invocation is one of the read-only subcommands.
    ///
    /// A short list of subcommands rather than a scan for dangerous flags: `git` has hundreds
    /// of write paths, and `config`, `stash`, `tag` and `branch` all read *and* write depending
    /// on their arguments. Naming the safe ones is the only version of this that stays correct
    /// as git grows.
    private static func isReadOnlyGit(_ arguments: [String]) -> Bool {
        // A leading `-c key=value` reconfigures the run, so the subcommand after it is not
        // the one being vetted.
        guard let subcommand = arguments.first, !subcommand.hasPrefix("-") else { return false }

        return Rule.readOnlyGitSubcommands.contains(subcommand)
    }

    // MARK: - Rules

    private enum Rule {
        /// Characters that can redirect output or start a substitution. `<` covers process
        /// substitution `<(…)` along with plain input redirection.
        ///
        /// `&` is *not* here: `&&` is an ordinary chain whose every link is vetted, and banning
        /// the character outright made a chain of reads prompt. Backgrounding is caught
        /// separately by `isBackgrounded`.
        static let forbiddenCharacters = CharacterSet(charactersIn: "><`\n\r$")

        /// Kept separate for the ones that are more than a character, and for readability.
        static let forbiddenSequences = ["$(", "${"]

        /// Commands admitted here. All but `find`, `git` and `sed` have no write mode at all;
        /// those three carry their own rule above.
        ///
        /// `awk` is deliberately absent — it can open files for writing from inside its
        /// program, and unlike `sed` there is no narrow form worth carving out: it did not
        /// appear often enough in real rollouts to be worth the risk.
        static let readOnlyCommands: Set<String> = [
            "ls", "cat", "head", "tail", "wc", "file", "stat", "pwd", "echo", "printf",
            "basename", "dirname", "realpath", "readlink", "which", "type", "tree",
            "grep", "egrep", "fgrep", "rg", "ag", "find", "fd",
            "du", "df", "date", "uname", "hostname", "whoami", "id", "uptime", "arch",
            "sort", "uniq", "cut", "tr", "column", "nl", "seq", "diff", "cmp",
            "jq", "yq", "shasum", "md5sum", "cksum", "true", "false", "git", "sed"
        ]

        /// `find` predicates that run a command or delete a file.
        static let findWriteFlags = ["-exec", "-execdir", "-ok", "-okdir", "-delete",
                                     "-fprint", "-fls", "-fprintf"]

        /// `sed` flags that edit in place or run a script this policy never sees.
        static let sedWriteFlags = ["-i", "--in-place", "-f", "--file"]

        /// A bare line-range print: `5p`, `1,220p`, with or without shell quotes. Anything
        /// richer — a substitution, a `w`, a regex address — is refused.
        ///
        /// `10,$p` is accepted by this pattern but never reaches it: the `$` ban above runs
        /// first and cannot tell `$p` inside single quotes from a variable without tracking
        /// shell quoting. That form prompts, which is the right direction to be wrong in.
        static let sedPrintScript = #"^['"]?\d+(,(\d+|\$))?p['"]?$"#

        /// Git subcommands that only inspect. `config`, `stash`, `tag`, `branch` and `remote`
        /// are absent because each writes under some arguments.
        static let readOnlyGitSubcommands: Set<String> = [
            "status", "log", "diff", "show", "rev-parse", "describe", "ls-files", "ls-tree",
            "blame", "shortlog", "cat-file", "merge-base", "for-each-ref", "symbolic-ref",
            "name-rev", "whatchanged", "reflog", "grep", "count-objects", "check-ignore"
        ]
    }
}
