import Foundation

/// Removes secret-shaped values from a process's argument vector before the info panel draws it.
///
/// argv is where credentials actually travel — `--api-key sk-…`, `-p hunter2`, `TOKEN=… npm run`
/// — and the panel ends up in screenshots. The rules are **key-driven**: a value is hidden
/// because the flag or assignment naming it is credential-shaped ([`CredentialVocabulary`]),
/// never because of what the value looks like. Guessing at value shapes redacts ports and
/// commit hashes, and missing one shape leaks a key; a wrongly hidden value costs one
/// right-click to reveal, so over-hiding is the recoverable direction.
enum CommandLineRedactor {

    /// An argument vector with its secrets replaced, and how many were.
    ///
    /// `redactedCount` is what gates the reveal affordance: a command line that hid nothing has
    /// nothing to offer a "Show Full Command" item for.
    struct Redacted: Equatable, Sendable {
        let arguments: [String]
        let redactedCount: Int
    }

    /// What a hidden value renders as — the execution audit's angle-bracket vocabulary, so a
    /// redaction reads the same wherever it appears.
    static let placeholder = "<redacted>"

    /// Short flags whose following argument is a secret by convention rather than by name:
    /// `-p` is the password flag of `mysql`, `psql` and `sshpass`.
    private static let shortSecretFlags: Set<String> = ["-p"]

    static func redact(_ arguments: [String]) -> Redacted {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var redactedCount = 0
        var redactNext = false

        for argument in arguments {
            if redactNext {
                // Unconditionally: a secret is allowed to start with a dash, and a flag that
                // names a credential is followed by its value in every CLI worth guessing at.
                result.append(placeholder)
                redactedCount += 1
                redactNext = false
                continue
            }

            if let keyed = keyedCredential(in: argument) {
                result.append("\(keyed.head)=\(placeholder)")
                redactedCount += 1
                continue
            }

            if namesASecretValue(argument) {
                redactNext = true
            }
            result.append(argument)
        }

        return Redacted(arguments: result, redactedCount: redactedCount)
    }

    // MARK: - Private Methods

    /// `--api-key=v`, `-token=v` and `API_KEY=v` in one shape: everything before the first `=`
    /// is the key, dashes stripped for the vocabulary but preserved in what is drawn.
    private static func keyedCredential(in argument: String) -> (head: Substring, value: Substring)? {
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else { return nil }

        let head = argument[..<equals]
        let name = head.drop(while: { $0 == "-" })
        guard !name.isEmpty, CredentialVocabulary.isCredentialKey(String(name)) else { return nil }

        return (head, argument[argument.index(after: equals)...])
    }

    /// A bare flag whose *next* argument is the secret.
    private static func namesASecretValue(_ argument: String) -> Bool {
        guard argument.hasPrefix("-") else { return false }
        if shortSecretFlags.contains(argument) { return true }

        let name = argument.drop(while: { $0 == "-" })
        guard !name.isEmpty else { return false }
        return CredentialVocabulary.isCredentialKey(String(name))
    }
}
