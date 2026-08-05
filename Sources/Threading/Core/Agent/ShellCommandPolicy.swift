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
/// - The allowlist is short and explicit, and **naming a command is not enough**. A reader turns
///   into a writer through an argument — `sort -o`, `tree -o`, `git diff --output=`,
///   `uniq IN OUT` — or into an executor of something never vetted — `fd -x`, `rg --pre=`. Each
///   allowlisted command carries the flags that do that, verified against the binary. `awk` is
///   absent altogether: it can open files for writing from inside its program, so there is no
///   flag to name.
/// - Anything that could reach a command this policy never sees is refused outright:
///   redirection, command substitution, backgrounding, process substitution, a leading variable
///   assignment, or an absolute path in place of a bare command name.
/// - Splitting on operators is deliberately naive, and that is safe *because* it is naive: a
///   `;` inside a quoted argument splits into a segment whose first word is not on the
///   allowlist, so the whole command is refused rather than admitted.
/// - **Arguments are read unquoted**, because the shell will run `find . "-delete"` and
///   `find . -delete` identically and every rule here is a prefix test. Quoting a flag was
///   enough to walk past all of them. The command *name* keeps its quotes, so unquoting can
///   only ever refuse more, never admit more.
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

        // Read as the shell will read it, not as it was typed. `find . "-delete"` and
        // `find . -delete` are one call spelled two ways, and every rule below is a prefix test
        // that only the unquoted spelling failed — so quoting a flag was enough to walk past
        // the whole policy and have the deletion auto-approved.
        let arguments = tokens.dropFirst().map(unquoted)

        // A flag that names a file to write, or a command to run, turns a reader into a writer.
        // Named per command rather than banned outright, because the same spelling means
        // opposite things: `-o` is "only print the match" to `grep` and "write the result here"
        // to `sort`. Found by asking what each allowlisted command can be made to do, rather
        // than trusting the claim that all but three had no write mode.
        if let dangerous = Rule.writeFlagsByCommand[name],
           arguments.contains(where: { argument in dangerous.contains { names(argument, $0) } }) {
            return false
        }

        switch name {
        case "find":
            // `find` is the one allowlisted command that can run other commands and delete.
            return !arguments.contains { argument in
                Rule.findWriteFlags.contains { names(argument, $0) }
            }

        case "fd":
            // `fd` spells the same capability differently, and its short forms share no prefix
            // with `find`'s: `-x`, `-X`, `--exec` and `--exec-batch` all run an arbitrary
            // command per match. Matched exactly, because `find . -xdev` is an ordinary read
            // and a `-x` *prefix* would refuse it.
            return !arguments.contains { Rule.fdExecFlags.contains($0) }

        case "git":
            return isReadOnlyGit(arguments)

        case "sed":
            return isPrintingSed(arguments)

        case "uniq":
            // `uniq [INPUT [OUTPUT]]` writes its *second* operand — a write with no flag on it
            // at all. Counting bare operands is naive in the same way the splitting is: a
            // value-taking flag like `-f 1` makes its number look like an operand, so
            // `uniq -f 1 file` prompts. That is the direction to be wrong in.
            return arguments.filter { !$0.hasPrefix("-") }.count < 2

        default:
            return true
        }
    }

    /// Whether `argument` is `flag`, in either spelling that flag accepts a value in.
    ///
    /// The two forms cannot share one test. A **long** flag takes its value after `=`, so it must
    /// match exactly or up to that `=` — matching it by bare prefix refuses `rg --pretty` for
    /// starting with `--pre`, and a common read that prompts is the failure this policy was
    /// measured to avoid. A **short** flag attaches its value directly (`sort -o/tmp/x`), so
    /// there it is the prefix that is correct.
    private static func names(_ argument: String, _ flag: String) -> Bool {
        guard flag.hasPrefix("--") else { return argument.hasPrefix(flag) }
        return argument == flag || argument.hasPrefix(flag + "=")
    }

    /// One shell token with a single layer of matching quotes removed.
    ///
    /// Only ever applied to *arguments*. The command name keeps its quotes and so keeps failing
    /// the allowlist, which is the safe direction: unquoting it would admit `"ls"` — and the
    /// point of this policy is never to widen what passes.
    private static func unquoted(_ token: String) -> String {
        guard token.count >= 2,
              let first = token.first, let last = token.last,
              first == last, first == "\"" || first == "'" else { return token }
        return String(token.dropFirst().dropLast())
    }

    /// Whether a `sed` call is the print-a-line-range form and nothing else.
    ///
    /// `sed` is here reluctantly and admitted narrowly, because it is how Codex *reads*:
    /// measured across real rollouts, `sed -n '1,220p' file` accounts for 42% of its shell
    /// calls, and refusing it made the classifier nearly pointless. It is also the allowlisted
    /// command whose writes a flag list cannot describe: `-i` edits in place and `-f` runs a
    /// script this policy never sees, but a `w` inside the script writes a file with no flag on
    /// the line at all.
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
            Rule.sedWriteFlags.contains { names(argument, $0) }
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

        /// Commands admitted here. Being on this list only clears the *name*; the argument rules
        /// above still have to pass, because several of these write or execute when asked to.
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

        /// `fd`'s equivalents, matched exactly rather than by prefix — see the `fd` case above.
        static let fdExecFlags: Set<String> = ["-x", "-X", "--exec", "--exec-batch"]

        /// Per command, the flags that make it write a file or run another command.
        ///
        /// Every one of these was verified against the binary rather than inferred: each writes
        /// an arbitrary path, or executes an arbitrary command, while the command's *name* is on
        /// the allowlist. Prefix-matched so the attached spellings (`--output=x`, `-ox`) are
        /// caught with the detached ones.
        ///
        /// Deliberately over-broad where a prefix is shared with something harmless —
        /// `git diff -O<orderfile>` only reads, and prompts anyway, because `git grep -O` runs a
        /// pager and telling them apart means knowing the subcommand's flag grammar.
        static let writeFlagsByCommand: [String: [String]] = [
            // `sort -o FILE` / `--output=FILE` writes the sorted result over FILE.
            "sort": ["-o", "--output"],
            // `tree -o FILE` sends the listing to FILE.
            "tree": ["-o"],
            // `yq -i` edits the document in place.
            "yq": ["-i", "--inplace", "--in-place"],
            // `git diff --output=FILE` writes the patch to FILE; `git grep -O` runs a pager.
            "git": ["--output", "-O", "--open-files-in-pager"],
            // `rg --pre=CMD` and `--hostname-bin=CMD` each execute CMD.
            "rg": ["--pre", "--hostname-bin"]
        ]

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
