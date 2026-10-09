import Foundation

/// The field names that mean "this value is a secret", shared by every surface that redacts:
/// the execution audit's JSON sanitizer, the info panel's command line and browser URLs. One
/// list keeps a value hidden when it crosses from one of those surfaces to another.
enum CredentialVocabulary {

    /// Normalized spellings of keys whose value is a credential. Multi-segment entries preserve
    /// the meaning of pairs such as `api_key`; single-segment entries can also appear after a
    /// vendor namespace (`github_token`, `aws_secret_access_key`).
    static let credentialKeys: Set<String> = [
        "password", "passwd", "passcode", "secret", "token", "access_token", "refresh_token",
        "accesstoken", "refreshtoken", "id_token", "session_token", "sessiontoken",
        "api_key", "apikey", "x_api_key", "client_secret", "private_key", "secret_key",
        "authorization", "proxy_authorization", "cookie", "set_cookie", "credential",
        "credentials", "auth", "bearer", "key", "signature", "cvv", "cvc", "security_code",
        "card_security_code", "pin"
    ]

    /// Query parameters with these names are sensitive in an authentication URL, but the same
    /// generic names must not erase ordinary source-code or session-identity fields in an audit.
    private static let urlOnlySegments: Set<String> = ["code", "session"]

    /// Whether a raw key names a credential, under the normalization every consumer shares.
    /// Camel case is folded before punctuation is segmented, so `apiToken`, `X-Api-Key` and
    /// `AWS_SECRET_ACCESS_KEY` all expose their credential-bearing segment or pair.
    static func isCredentialKey(_ raw: String) -> Bool {
        let segments = normalizedSegments(raw)
        guard !segments.isEmpty else { return false }

        let normalized = segments.joined(separator: "_")
        if credentialKeys.contains(normalized) { return true }
        if segments.contains(where: credentialKeys.contains) { return true }

        return zip(segments, segments.dropFirst()).contains { pair in
            credentialKeys.contains("\(pair.0)_\(pair.1)")
        }
    }

    /// Browser query names additionally treat OAuth authorization codes and session identifiers
    /// as sensitive. All ordinary credential spellings still come from `isCredentialKey`.
    static func isSensitiveURLQueryKey(_ raw: String) -> Bool {
        isCredentialKey(raw) || !urlOnlySegments.isDisjoint(with: normalizedSegments(raw))
    }

    private static func normalizedSegments(_ raw: String) -> [String] {
        let characters = Array(raw)
        var normalized = ""
        normalized.reserveCapacity(raw.count)

        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else {
                if !normalized.isEmpty, normalized.last != "_" { normalized.append("_") }
                continue
            }

            if character.isUppercase, !normalized.isEmpty, normalized.last != "_" {
                let previous = characters[characters.index(before: index)]
                let nextIsLowercase: Bool
                let next = characters.index(after: index)
                if next < characters.endIndex {
                    nextIsLowercase = characters[next].isLowercase
                } else {
                    nextIsLowercase = false
                }
                if previous.isLowercase || previous.isNumber
                    || (previous.isUppercase && nextIsLowercase) {
                    normalized.append("_")
                }
            }
            normalized.append(contentsOf: character.lowercased())
        }

        return normalized.split(separator: "_").map(String.init)
    }
}

/// Credential-bearing URL components shared by browser traces and command-line display.
enum CredentialURLRedactor {
    struct Redacted: Equatable, Sendable {
        let value: String
        let redactedCount: Int
    }

    static func redact(
        _ value: String,
        placeholder: String,
        removingFragment: Bool
    ) -> Redacted? {
        guard var components = URLComponents(string: value),
              components.scheme != nil,
              components.host != nil else { return nil }

        var count = 0
        if components.user != nil || components.password != nil {
            // Clear the dependent password first. Foundation refuses a nil user while a password
            // is still present, which would otherwise leave both credentials in the rendered URL.
            components.password = nil
            components.user = nil
            count += 1
        }
        components.queryItems = components.queryItems?.map { item in
            guard CredentialVocabulary.isSensitiveURLQueryKey(item.name) else { return item }
            count += 1
            return URLQueryItem(name: item.name, value: placeholder)
        }
        if removingFragment, components.fragment != nil {
            components.fragment = nil
            count += 1
        }

        guard count > 0, let rendered = components.string else { return nil }
        return Redacted(value: rendered, redactedCount: count)
    }
}
