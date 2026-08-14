import Foundation

/// The field names that mean "this value is a secret", shared by every surface that redacts:
/// the execution audit's JSON sanitizer and the info panel's command-line redactor. One list,
/// so the vocabularies cannot drift — a key the audit hides must not be one the panel draws.
enum CredentialVocabulary {

    /// Normalized spellings (lowercase, `-` folded to `_`) of keys whose value is a credential.
    static let credentialKeys: Set<String> = [
        "password", "passwd", "passcode", "secret", "token", "access_token", "refresh_token",
        "accesstoken", "refreshtoken", "id_token", "session_token", "sessiontoken",
        "api_key", "apikey", "x_api_key", "client_secret", "private_key", "secret_key",
        "authorization", "proxy_authorization", "cookie", "set_cookie", "credential",
        "credentials", "cvv", "cvc", "security_code", "card_security_code", "pin"
    ]

    /// Whether a raw key names a credential, under the normalization both consumers share:
    /// `X-Api-Key`, `x_api_key` and `API_KEY` are one spelling here.
    static func isCredentialKey(_ raw: String) -> Bool {
        credentialKeys.contains(raw.lowercased().replacingOccurrences(of: "-", with: "_"))
    }
}
