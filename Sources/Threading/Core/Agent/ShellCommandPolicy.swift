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
///   redirection, command substitution, backgrounding, process substitution, brace expansion,
///   a subshell, a leading variable assignment, or an absolute path in place of a bare command
///   name.
/// - **The line is read the way the shell reads it** (`ShellWords`): operators split only where
///   they are unquoted, and arguments arrive with their quotes and escapes removed, because the
///   shell runs `find . "-delete"` and `find . -de'l'ete` exactly as `find . -delete` and every
///   rule here is a prefix test. Splitting at every `|` used to be called safe because a quoted
///   one only refused more; for an unattended automation run a refusal is final, and it refused
///   `rg 'a|b'` and every `jq` filter while the run's allow-list named both. The command *name*
///   keeps its quotes, so `"ls"` still fails the allowlist.
///
/// Nothing here weakens an existing rule. It only narrows what prompts, to the same bar
/// Claude's `Read` and `Grep` already clear.
enum ShellCommandPolicy {

    // MARK: - Public Methods

    /// Whether every part of a command line is a known read-only invocation.
    static func isReadOnly(_ command: String) -> Bool {
        guard let segments = segments(ofVettable: command) else { return false }
        return segments.allSatisfy(isReadOnlySegment)
    }

    /// The simple commands a line consists of, or nil when the line holds a construct that could
    /// run something none of its segments shows — redirection, substitution, backgrounding, a
    /// newline — or holds nothing at all.
    ///
    /// Shared with automation allow-lists (`AutomationPermissionRule`), which vet each segment the
    /// same way: a segment is admitted only if it is read-only here or matches a rule the person
    /// approved, so a chain cannot smuggle a second command past a rule naming the first.
    static func segments(ofVettable command: String) -> [ShellWords.Segment]? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let segments = ShellWords.segments(of: trimmed), !segments.isEmpty else { return nil }
        return segments
    }

    static func isReadOnlySegment(_ segment: ShellWords.Segment) -> Bool {
        guard let name = segment.words.first else { return false }

        // `FOO=bar cmd` runs `cmd` with an environment this policy never inspected, and
        // `/usr/bin/whatever` names a binary rather than the command the allowlist vetted.
        guard !name.contains("="), !name.contains("/") else { return false }
        guard Rule.readOnlyCommands.contains(name) else { return false }

        // Read as the shell will read it, not as it was typed: `find . "-delete"` and
        // `find . -delete` are one call spelled two ways, and every rule below is a prefix test.
        let arguments = Array(segment.words.dropFirst())

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
            // at all. Counting bare operands is deliberately naive: a value-taking flag like `-f 1` makes its number look like an operand, so
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
            "pgrep",
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

        /// A bare line-range print: `5p`, `1,220p`, `10,$p`, matched after the shell's quotes
        /// are gone. Anything richer — a substitution, a `w`, a regex address — is refused.
        static let sedPrintScript = #"^\d+(,(\d+|\$))?p$"#

        /// Git subcommands that only inspect. `config`, `stash`, `tag`, `branch` and `remote`
        /// are absent because each writes under some arguments.
        static let readOnlyGitSubcommands: Set<String> = [
            "status", "log", "diff", "show", "rev-parse", "describe", "ls-files", "ls-tree",
            "blame", "shortlog", "cat-file", "merge-base", "for-each-ref", "symbolic-ref",
            "name-rev", "whatchanged", "reflog", "grep", "count-objects", "check-ignore"
        ]
    }
}
