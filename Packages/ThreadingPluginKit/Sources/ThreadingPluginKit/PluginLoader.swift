import Foundation
import Security

// MARK: - Refusals

/// Why a bundle was not loaded.
///
/// Every case is a *refusal to map code*, so each one is worth recording by name: "the plugin did
/// not appear" is not a diagnosis, and the host's failure surface should be able to say which of
/// these happened.
public enum PluginLoadFailure: Error, Equatable, CustomStringConvertible {
    case unreadableBundle(path: String)
    case signatureInvalid(status: OSStatus)
    case untrustedTeam(String?)
    case noPrincipalClass
    case wrongProtocol
    case apiVersionMismatch(found: Int, expected: Int)

    public var description: String {
        switch self {
        case .unreadableBundle(let path):
            return "bundle could not be opened at \(path)"
        case .signatureInvalid(let status):
            return "signature invalid or absent (OSStatus \(status))"
        case .untrustedTeam(let team):
            return "signing team \(team ?? "none") is not allowlisted"
        case .noPrincipalClass:
            return "bundle declares no NSPrincipalClass"
        case .wrongProtocol:
            return "principal class does not conform to ThreadingNativePlugin"
        case .apiVersionMismatch(let found, let expected):
            return "plugin speaks API \(found), host speaks \(expected)"
        }
    }

    /// A stable token for a journal or a failure record, carrying no path or identity.
    public var code: String {
        switch self {
        case .unreadableBundle: return "unreadable_bundle"
        case .signatureInvalid: return "signature_invalid"
        case .untrustedTeam: return "untrusted_team"
        case .noPrincipalClass: return "no_principal_class"
        case .wrongProtocol: return "wrong_protocol"
        case .apiVersionMismatch: return "api_version_mismatch"
        }
    }
}

// MARK: - Loader

/// Loads a plugin bundle, refusing before any of its code is mapped.
///
/// **The operating system enforces nothing here.** Threading ships hardened runtime carrying
/// `com.apple.security.cs.disable-library-validation`, so `dlopen` will accept a bundle signed by
/// any team, or ad-hoc. Every check below is ours, and the order matters: the signature is
/// verified before `Bundle.principalClass` is touched, because reading the principal class is what
/// maps and runs the bundle's code.
///
/// The policy this mirrors is `simulator-pane.md`'s helper check: exact location, signing
/// identifier and team, verified before launch.
public struct PluginLoader {
    /// Teams whose bundles may be loaded. An empty set loads nothing: this tier maps unsandboxed
    /// code into the host process, so it opens by refusing rather than by trusting.
    public var allowedTeams: Set<String>

    /// Skips the signature check entirely. **Only a probe or a test may set this**, which is why
    /// it cannot be reached through `init(allowedTeams:)` — see `acceptingAnyTeam()`.
    private let acceptsAnyTeam: Bool

    public init(allowedTeams: Set<String>) {
        self.allowedTeams = allowedTeams
        self.acceptsAnyTeam = false
    }

    /// A loader that runs whatever it is pointed at, signed or not.
    ///
    /// This existed as "an empty allowlist means accept anything", which read as a convenience and
    /// was in fact the shipping default: `NativePluginCatalog.allowedTeams` is empty until the
    /// first-party team is added, and its own documentation said that meant *load nothing*. The
    /// host and the loader stated opposite policies and the loader won. Naming the dangerous
    /// behaviour is what stops it being reached by leaving something out.
    public static func acceptingAnyTeam() -> PluginLoader {
        PluginLoader(allowedTeams: [], acceptsAnyTeam: true)
    }

    private init(allowedTeams: Set<String>, acceptsAnyTeam: Bool) {
        self.allowedTeams = allowedTeams
        self.acceptsAnyTeam = acceptsAnyTeam
    }

    public func load(bundleAt url: URL) throws -> ThreadingNativePlugin {
        if !acceptsAnyTeam {
            try verifySignature(at: url)
        }
        guard let bundle = Bundle(url: url) else {
            throw PluginLoadFailure.unreadableBundle(path: url.path)
        }
        // Everything past this line has mapped and run the bundle's code.
        guard let principal = bundle.principalClass else {
            throw PluginLoadFailure.noPrincipalClass
        }
        guard let type = principal as? ThreadingNativePlugin.Type else {
            throw PluginLoadFailure.wrongProtocol
        }
        guard type.pluginAPIVersion == ThreadingPluginAPI.version else {
            throw PluginLoadFailure.apiVersionMismatch(
                found: type.pluginAPIVersion,
                expected: ThreadingPluginAPI.version
            )
        }
        return type.init()
    }

    /// The signing team of a bundle, or `nil` when it carries none (ad-hoc).
    /// Throws if the signature is absent or does not validate.
    public func signingTeam(of url: URL) throws -> String? {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            throw PluginLoadFailure.signatureInvalid(status: created)
        }
        let valid = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard valid == errSecSuccess else {
            throw PluginLoadFailure.signatureInvalid(status: valid)
        }
        // `kSecCSSigningInformation` is what puts the team into the dictionary. Asked with no
        // flags — as this did — the call succeeds and simply omits it, so every correctly signed
        // bundle read back as "team none" and was refused. An allowlist that cannot see a team
        // rejects everything, which looks exactly like a plugin that will not load.
        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard read == errSecSuccess, let dictionary = information as? [String: Any] else {
            throw PluginLoadFailure.signatureInvalid(status: read)
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func verifySignature(at url: URL) throws {
        let team = try signingTeam(of: url)
        guard let team, allowedTeams.contains(team) else {
            throw PluginLoadFailure.untrustedTeam(team)
        }
    }
}
