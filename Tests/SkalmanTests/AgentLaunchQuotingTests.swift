import XCTest
@testable import Skalman

/// What a launch line is allowed to contain when the strings inside it are hostile.
///
/// Every launch is `sh -lc <one string>`, and that string is built from values the user and the
/// agents supply: a project folder chosen from a file panel, a session title an agent wrote, a
/// model identifier, a prompt, an account's config path. `ShellCommand` exists so none of those
/// can be syntax — but "it quotes" is a claim, and the roadmap has carried "plan snapshots,
/// including hostile strings" as the thing that would make it a fact.
///
/// Two ways of checking, because they fail differently:
///
/// - Against a **real shell**, which is the only authority on what its own quoting means. A
///   rule re-derived in a test is a second implementation of the bug.
/// - Against the **plan's own text**, which catches a word that reached the line without going
///   through the quoter at all — something a round-trip of `ShellCommand` cannot see.
@MainActor
final class AgentLaunchQuotingTests: XCTestCase {

    /// Strings that end a quoted word, start a command, or expand to one.
    private static let hostile = [
        "'; rm -rf ~; echo '",
        "$(touch /tmp/skalman-quoting-escape)",
        "`touch /tmp/skalman-quoting-escape`",
        "a\"b",
        "a'b",
        "a\\b",
        "; shutdown -h now",
        "&& echo pwned",
        "| tee /tmp/x",
        "> /tmp/x",
        "\n echo newline",
        "$HOME",
        "${IFS}",
        "*",
        "~root",
        "--flag=value with spaces",
        "- Make sure all tests are green\n- Then build the latest version"
    ]

    // MARK: - Against a real shell

    /// The quoter's output, tokenized by `/bin/sh` itself, gives back exactly the words that
    /// went in. `printf` is the whole command: it reports its arguments and does nothing else,
    /// so a quoting failure shows up as a wrong *answer* rather than as a side effect nobody
    /// was watching for.
    func testQuotedWordsSurviveARealShellUnchanged() throws {
        var command = ShellCommand(word: "/usr/bin/printf")
        command.append(word: "%s\u{1}")
        for word in Self.hostile {
            command.append(word: word)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.source]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let received = String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)

        XCTAssertEqual(received, Self.hostile, "a word changed meaning on its way through sh")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// The side effect none of the above may have had. `$(…)` and backticks in the corpus would
    /// create this file if the quoting let them run; the round-trip above would still pass,
    /// because printf would faithfully report the *result* of the expansion.
    func testNoSubstitutionRanWhileQuoting() throws {
        let evidence = "/tmp/skalman-quoting-escape"
        try? FileManager.default.removeItem(atPath: evidence)

        try testQuotedWordsSurviveARealShellUnchanged()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: evidence),
            "a command substitution executed: the quoting is not quoting"
        )
    }

    // MARK: - Against the plan

    /// Every word in a launch line is quoted, and the *only* raw syntax is the fixed `&&`.
    ///
    /// Checked by deleting the quoted spans and looking at what is left: anything other than
    /// whitespace and `&&` is a word that reached the command line without passing through the
    /// quoter, which is the failure this design exists to prevent and the one a `ShellCommand`
    /// unit test cannot see.
    func testAHostileProjectAndSessionProduceNoRawSyntax() {
        for hostile in Self.hostile {
            let project = Project(
                name: hostile,
                folderURL: URL(fileURLWithPath: "/tmp/\(hostile)")
            )
            let session = AgentSession(kind: .claude, title: hostile, model: hostile)

            let plan = AgentLauncher.plan(for: session, in: project, initialPrompt: hostile)
            let source = try? XCTUnwrap(plan.arguments.last)
            let residue = Self.strippingQuotedSpans(source ?? "")
                .replacingOccurrences(of: "&&", with: "")
                .replacingOccurrences(of: "--", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            XCTAssertTrue(
                residue.isEmpty,
                "unquoted text reached the launch line for \(hostile): \(residue)"
            )
        }
    }

    /// The launch is handed to a shell as **one argument**, so nothing after it can be read as
    /// a further command however the words inside it are shaped.
    func testTheLaunchIsASingleShellArgument() {
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(kind: .codex, title: "t")

        let plan = AgentLauncher.plan(for: session, in: project)

        XCTAssertEqual(
            plan.arguments.dropLast(),
            ["-l", "-c"],
            "the launch stopped being a login shell running one command"
        )
        XCTAssertEqual(plan.arguments.count, 3, "the shell was handed more than one command")
    }

    // MARK: - Against the CLI's own parser

    /// A prompt that begins with `-` is a prompt, not a flag.
    ///
    /// The composer's own opening — a bulleted list of things to do — killed a session a third
    /// of a second after it launched: Claude's parser read `- Make sure all tests are green` as
    /// an unknown option and exited 1, and the user was left looking at a chat that had opened
    /// with no prompt in it. Codex fails the same way (`unexpected argument '- ' found`) and
    /// says so in its own error: *to pass `- ` as a value, use `-- - `*.
    ///
    /// Checked by tokenizing the launch line with a real shell, because the property is about
    /// the *words the CLI receives*, and the shell is what decides those.
    func testAPromptBeginningWithADashSurvivesAsAPromptNotAFlag() throws {
        let opening = "- Make sure all tests are green\n- Then build the latest version"

        for kind in [AgentKind.claude, .codex] {
            let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
            let session = AgentSession(kind: kind, title: "t")

            let words = try Self.tokenizing(
                XCTUnwrap(
                    AgentLauncher.plan(
                        for: session,
                        in: project,
                        initialPrompt: opening
                    ).arguments.last
                )
            )

            XCTAssertEqual(
                words.suffix(2),
                ["--", opening],
                "\(kind) launched with the opening prompt exposed to its option parser"
            )
        }
    }

    /// And it is the *last* word, after every flag the launch grows on its way out.
    ///
    /// `routed` wraps the command and appends the MCP flags around it, so the prompt used to
    /// sit in the middle of the line. Terminating the options where it stood would have handed
    /// `--mcp-config` to the CLI as more prompt text — the operand has to move to the end, not
    /// just gain a `--`.
    func testTheOpeningPromptIsTheLastWordOnTheLine() throws {
        let opening = "an ordinary opening"
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        let session = AgentSession(kind: .claude, title: "t")

        let words = try Self.tokenizing(
            XCTUnwrap(
                AgentLauncher.plan(
                    for: session,
                    in: project,
                    initialPrompt: opening
                ).arguments.last
            )
        )

        XCTAssertEqual(words.last, opening)
        XCTAssertEqual(
            words.firstIndex(of: opening),
            words.count - 1,
            "the prompt appears before the end of the line"
        )
    }

    /// The rule holds however the command is assembled afterwards: `ShellCommand` composition
    /// is what carries the operand to the end, so a command appended *into* another keeps it
    /// there rather than leaving it stranded mid-line.
    func testAComposedCommandKeepsItsOperandLast() {
        var inner = ShellCommand(word: "claude")
        inner.append(operand: "- do the thing")

        var outer = ShellCommand(word: "env")
        outer.append(contentsOf: inner)
        outer.append(flag: "--mcp-config", value: "/tmp/c.json")

        XCTAssertEqual(outer.source, "'env' 'claude' '--mcp-config' '/tmp/c.json' -- '- do the thing'")
    }

    /// The residue check, checked.
    ///
    /// This helper was wrong on its first outing — it read the quoter's `'\''` escape as syntax
    /// and failed a launch line that was perfectly quoted. A test whose helper can be wrong in
    /// one direction can be wrong in the other, and a residue parser that finds nothing is a
    /// test that passes for the worst possible reason.
    func testTheResidueCheckSeesUnquotedSyntax() {
        XCTAssertEqual(Self.strippingQuotedSpans("'a' && 'b'").trimmingCharacters(in: .whitespaces), "&&")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'; rm -rf ~"), "; rm -rf ~")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'$(id)"), "$(id)")
        XCTAssertEqual(Self.strippingQuotedSpans("'a'`id`"), "`id`")

        // And is silent on a correctly quoted word containing every one of those.
        var quoted = ShellCommand(word: "echo")
        quoted.append(word: "; $(id) `id` && it's fine")
        XCTAssertEqual(Self.strippingQuotedSpans(quoted.source).trimmingCharacters(in: .whitespaces), "")
    }

    // MARK: - Helpers

    /// The words the CLI would receive, tokenized by a shell rather than re-derived here.
    ///
    /// The launch line *starts an agent*, so it is never run: the fixed `cd … && exec ` prefix
    /// is dropped and what remains is handed to `set --`, which splits and unquotes it exactly
    /// as the shell would have before `printf` reports the words back.
    ///
    /// `exec` is an ordinary quoted word in that prefix, not raw syntax — `ShellCommand` emits
    /// only `&&` and `--` unquoted — so the marker is built from `ShellCommand` rather than
    /// written out here. A shell runs the `exec` builtin either way, but a literal `&& exec `
    /// never appears in the line and looking for one finds nothing.
    private static func tokenizing(_ launchLine: String) throws -> [String] {
        let marker = "&& \(ShellCommand(word: "exec").source) "
        let prefix = try XCTUnwrap(
            launchLine.range(of: marker),
            "the launch line stopped being 'cd … && exec …'"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -- \(launchLine[prefix.upperBound...]); printf '%s\u{1}' \"$@\""
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }

    /// Removes everything a shell would read as part of a *word*, leaving only what it would
    /// read as syntax.
    ///
    /// Two rules, and the second is the one this got wrong first: inside `'…'` nothing is
    /// special, and *outside* it a backslash makes the next character literal. The quoter emits
    /// a literal apostrophe as `'\''` — close, escaped quote, reopen — so a parser that only
    /// toggles on quotes sees the escape as syntax and reports a false positive on any string
    /// containing an apostrophe.
    private static func strippingQuotedSpans(_ source: String) -> String {
        var remainder = ""
        var isQuoted = false
        let characters = Array(source)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if isQuoted {
                isQuoted = character != "'"
                index += 1
                continue
            }

            switch character {
            case "'":
                isQuoted = true
            case "\\":
                // The escaped character belongs to the word, not to the syntax.
                index += 1
            default:
                remainder.append(character)
            }

            index += 1
        }

        return remainder
    }
}
