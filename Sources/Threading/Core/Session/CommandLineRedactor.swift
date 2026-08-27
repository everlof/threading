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
    private static let headerFlags: Set<String> = ["-H", "--header"]

    private enum PendingValue {
        case credential
        case header
    }

    static func redact(_ arguments: [String]) -> Redacted {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var redactedCount = 0
        var pendingValue: PendingValue?

        for argument in arguments {
            if let pending = pendingValue {
                switch pending {
                case .credential:
                    // Unconditionally: a secret is allowed to start with a dash, and a flag that
                    // names a credential is followed by its value in every CLI worth guessing at.
                    result.append(placeholder)
                    redactedCount += 1
                case .header:
                    if let redacted = redactedHeader(argument) {
                        result.append(redacted)
                        redactedCount += 1
                    } else {
                        result.append(argument)
                    }
                }
                pendingValue = nil
                continue
            }

            if let inlineHeader = redactedInlineHeader(argument) {
                result.append(inlineHeader)
                redactedCount += 1
                continue
            }

            if let redactedURL = CredentialURLRedactor.redact(
                argument,
                placeholder: placeholder,
                removingFragment: false
            ) {
                result.append(redactedURL.value)
                redactedCount += redactedURL.redactedCount
                continue
            }

            if let keyed = keyedCredential(in: argument) {
                result.append("\(keyed.head)=\(placeholder)")
                redactedCount += 1
                continue
            }

            if headerFlags.contains(argument) {
                pendingValue = .header
            } else if namesASecretValue(argument) {
                pendingValue = .credential
            }
            result.append(argument)
        }

        return Redacted(arguments: result, redactedCount: redactedCount)
    }

    // MARK: - Private Methods

    /// Curl-style `-H Authorization: Bearer …` arguments preserve the header name while hiding
    /// its complete value. Innocent headers pass through unchanged.
    private static func redactedHeader(_ argument: String) -> String? {
        guard let colon = argument.firstIndex(of: ":") else { return nil }
        let name = String(argument[..<colon]).trimmingCharacters(in: .whitespaces)
        guard CredentialVocabulary.isCredentialKey(name) else { return nil }

        let valueStart = argument.index(after: colon)
        let remainder = argument[valueStart...]
        guard remainder.contains(where: { !$0.isWhitespace }) else { return nil }
        let whitespace = remainder.prefix(while: \.isWhitespace)
        return "\(argument[...colon])\(whitespace)\(placeholder)"
    }

    private static func redactedInlineHeader(_ argument: String) -> String? {
        guard let equals = argument.firstIndex(of: "=") else { return nil }
        let flag = String(argument[..<equals])
        guard headerFlags.contains(flag),
              let redacted = redactedHeader(String(argument[argument.index(after: equals)...]))
        else { return nil }
        return "\(flag)=\(redacted)"
    }

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
