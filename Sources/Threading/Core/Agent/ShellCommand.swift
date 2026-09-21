import Foundation

// MARK: - Shell Command

/// A shell command assembled from arguments rather than source-code fragments.
///
/// Every caller-provided word is single-quoted as it enters the command. The only syntax that
/// can be emitted raw is one of the fixed operators below, so interpolating a title, branch,
/// model, prompt, environment value, or path into `sh -c` is not an available operation.
struct ShellCommand: Equatable, Sendable {
    enum Operator {
        case and
        case endOfOptions

        fileprivate var source: String {
            switch self {
            case .and: return "&&"
            case .endOfOptions: return "--"
            }
        }
    }

    private var components: [String] = []

    /// The command's trailing operand — for an agent launch, the opening prompt.
    ///
    /// Kept apart from the flags because the operand-taking CLIs reject a positional argument that begins
    /// with `-`, and both reject it *before* the session exists: Claude's parser answers
    /// `error: unknown option '- Make sure all tests are green'` and exits 1, Codex answers
    /// `unexpected argument '- ' found`. A bulleted opening — a list of things to do, one per
    /// line — is an ordinary thing to type into the composer, and it killed the launch a
    /// third of a second after it started.
    ///
    /// Two rules together make it safe, and each is needed: the operand is emitted **last**,
    /// after the MCP flags `routed` appends around the command, and it is separated by `--`,
    /// the terminator both parsers honour. Appending `--` where the prompt used to sit would
    /// have handed `--mcp-config` to the CLI as prompt text instead.
    private var operand: String?

    init() {}

    init(word: String) {
        append(word: word)
    }

    mutating func append(word: String) {
        components.append(Self.quote(word))
    }

    mutating func append(words: [String]) {
        for word in words {
            append(word: word)
        }
    }

    mutating func append(flag: String) {
        precondition(flag.hasPrefix("-"), "A shell flag must start with '-'")
        append(word: flag)
    }

    mutating func append(flag: String, value: String) {
        append(flag: flag)
        append(word: value)
    }

    mutating func append(operator shellOperator: Operator) {
        components.append(shellOperator.source)
    }

    /// Sets the trailing operand. A command has at most one — the opening prompt.
    mutating func append(operand value: String) {
        precondition(operand == nil, "A command carries one trailing operand")
        operand = value
    }

    /// Composing commands carries the operand along, so it stays last however the outer
    /// command is built up afterwards.
    mutating func append(contentsOf command: ShellCommand) {
        components.append(contentsOf: command.components)
        if let inner = command.operand {
            append(operand: inner)
        }
    }

    var source: String {
        guard let operand else { return components.joined(separator: " ") }
        return (components + [Operator.endOfOptions.source, Self.quote(operand)])
            .joined(separator: " ")
    }

    /// Produces the fixed `cd <directory> && exec <command>` wrapper used by login-shell and
    /// interactive-shell launches. Only `&&` is syntax; both commands and the directory remain
    /// ordinary quoted words.
    static func executing(_ command: ShellCommand, in directory: String) -> ShellCommand {
        var source = ShellCommand(word: "cd")
        source.append(word: directory)
        source.append(operator: .and)
        source.append(word: "exec")
        source.append(contentsOf: command)
        return source
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
