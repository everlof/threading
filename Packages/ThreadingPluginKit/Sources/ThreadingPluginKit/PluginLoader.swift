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
    case noPrincipalClass
    case wrongProtocol
    case apiVersionMismatch(found: Int, expected: Int)
    /// Validly signed, but the user has not agreed to run this particular build of it.
    case notApproved(identifier: String)

    public var description: String {
        switch self {
        case .unreadableBundle(let path):
            return "bundle could not be opened at \(path)"
        case .signatureInvalid(let status):
            return "signature invalid or absent (OSStatus \(status))"
        case .noPrincipalClass:
            return "bundle declares no NSPrincipalClass"
        case .wrongProtocol:
            return "principal class does not conform to ThreadingNativePlugin"
        case .notApproved(let identifier):
            return "\(identifier) has not been approved to run inside Threading"
        case .apiVersionMismatch(let found, let expected):
            return "plugin speaks API \(found), host speaks \(expected)"
        }
    }

    /// A stable token for a journal or a failure record, carrying no path or identity.
    public var code: String {
        switch self {
        case .unreadableBundle: return "unreadable_bundle"
        case .signatureInvalid: return "signature_invalid"
        case .noPrincipalClass: return "no_principal_class"
        case .wrongProtocol: return "wrong_protocol"
        case .apiVersionMismatch: return "api_version_mismatch"
        case .notApproved: return "not_approved"
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
/// The policy is a valid signature plus the user's decision about the identity it carries, and
/// `NativePluginApprovals` in the host holds the second half. A team allowlist stood here first
/// and was removed: it closed the tier to everyone but us, which is not a platform.
public struct PluginLoader {

    /// What a bundle has to satisfy before its code is mapped.
    ///
    /// There is no `init`, so a loader cannot be built without saying which of these it is. That
    /// is deliberate, and it is the inverse of the bug this replaced: trust used to be a
    /// `Set<String>` of teams whose *empty* value silently meant "run anything", so leaving an
    /// argument out produced the dangerous loader. Leaving something out here does not compile.
    private enum Trust {
        /// A valid signature — from anyone, ad-hoc included — plus a decision about the identity
        /// it carries. The policy for anything a user installed.
        case signatureAndDecision
        /// Already covered by a signature the operating system checked: the bundle sits inside the
        /// host's own app bundle, so altering it invalidates the app itself.
        case sealedByHostBundle
        /// Nothing is checked at all.
        case unchecked
    }

    private let trust: Trust

    private init(trust: Trust) {
        self.trust = trust
    }

    /// The ordinary policy for an installed plugin: the signature must validate, and then the
    /// decision handed to `load(bundleAt:approving:)` must say yes to the identity read from it.
    ///
    /// The signature is not evidence of who to trust — anyone can sign, and ad-hoc counts. It is
    /// what makes the identity a decision is recorded against *mean the bytes the user was shown*.
    public static func signatureAndDecision() -> PluginLoader {
        PluginLoader(trust: .signatureAndDecision)
    }

    /// For a bundle inside the host's own app bundle, whose integrity the operating system already
    /// enforced. Nothing a decision could add: altering it breaks the app's own signature.
    ///
    /// **Not a first-party privilege.** Anyone shipping an app that loads plugins has this for the
    /// plugins inside their own bundle; a plugin of ours installed the ordinary way is refused
    /// until approved, and `NativePluginParityTests` asserts exactly that.
    public static func sealedByHostBundle() -> PluginLoader {
        PluginLoader(trust: .sealedByHostBundle)
    }

    /// Runs whatever it is pointed at, signed or not, approved or not.
    ///
    /// **Probes and tests only.** Named at length because the danger has to be typed out rather
    /// than reached by omission.
    public static func uncheckedForProbesAndTests() -> PluginLoader {
        PluginLoader(trust: .unchecked)
    }

    /// Load under a policy that needs no decision. Refuses a `signatureAndDecision()` loader,
    /// which has to be asked through `load(bundleAt:approving:)`.
    @MainActor
    public func load(bundleAt url: URL) throws -> ThreadingNativePlugin {
        try load(bundleAt: url) { identity in
            // Reaching here means the caller used the decision-free overload on a loader whose
            // whole policy is the decision. Refusing beats defaulting to yes: a bypass would be
            // silent, and this is the boundary between a plugins folder and arbitrary code in
            // this process.
            throw PluginLoadFailure.notApproved(identifier: identity.bundleIdentifier)
        }
    }

    /// Load one bundle, asking `decide` about its verified identity before any code is mapped.
    ///
    /// The order is the whole point and it is a property of this method rather than of the
    /// caller: readability, then signature, then the decision, and only then `principalClass` —
    /// which is the call that maps and runs the bundle's code. An earlier shape left the first
    /// three to whoever happened to call `identity(of:)` first.
    ///
    /// `decide` is non-escaping and called synchronously, so a host may consult main-actor state
    /// (a stored approval, a modal prompt) inside it.
    ///
    /// Main-actor because `ThreadingNativePlugin` is: the thing being constructed vends `NSView`s
    /// and is called back on every theme change, so the isolation belongs in the type rather than
    /// in a sentence a plugin author has to find. Reading a bundle's `identity(of:)` stays
    /// nonisolated — that part is only file and signature reading.
    @MainActor
    public func load(
        bundleAt url: URL,
        approving decide: (PluginIdentity) throws -> Bool
    ) throws -> ThreadingNativePlugin {
        // Forming a Bundle validates the path and metadata but does not map its executable. Do
        // this before the signature check so an absent path is reported as absent rather than as
        // a corrupt signature; principalClass stays below verification because it loads code.
        guard let bundle = Bundle(url: url) else {
            throw PluginLoadFailure.unreadableBundle(path: url.path)
        }
        if case .signatureAndDecision = trust {
            let identity = try Self.identity(of: url)
            guard try decide(identity) else {
                throw PluginLoadFailure.notApproved(identifier: identity.bundleIdentifier)
            }
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

    /// Who a bundle says it is, and exactly which build of it this is.
    ///
    /// The team alone is not an identity to record a decision against: approving "this plugin"
    /// has to mean the bytes the user was shown, or an update — or a replacement dropped into the
    /// same folder under the same name — inherits an approval nobody gave it. `cdHash` is the code
    /// directory hash, so a changed binary is a different identity and asks again.
    public struct PluginIdentity: Equatable, Sendable {
        public let bundleIdentifier: String
        public let team: String?
        public let cdHash: String

        public init(bundleIdentifier: String, team: String?, cdHash: String) {
            self.bundleIdentifier = bundleIdentifier
            self.team = team
            self.cdHash = cdHash
        }
    }

    /// Reads the identity, validating the signature on the way.
    ///
    /// Static because trust plays no part in reading one: a host showing an approval prompt needs
    /// the identity *before* it has a policy to apply to it, and making the caller construct a
    /// loader to ask would imply the answer depended on which one.
    public static func identity(of url: URL) throws -> PluginIdentity {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else {
            throw PluginLoadFailure.signatureInvalid(status: created)
        }
        let valid = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard valid == errSecSuccess else {
            throw PluginLoadFailure.signatureInvalid(status: valid)
        }
        // `kSecCSSigningInformation` is what puts the identifier, team and cdhash into the
        // dictionary. Asked with no flags — as this was — the call still succeeds and simply
        // omits them, so every correctly signed bundle read back as "team none, hash empty". A
        // check that cannot see an identity refuses everything, which looks exactly like a plugin
        // that will not load.
        var information: CFDictionary?
        let read = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard read == errSecSuccess, let dictionary = information as? [String: Any] else {
            throw PluginLoadFailure.signatureInvalid(status: read)
        }
        let hash = (dictionary[kSecCodeInfoUnique as String] as? Data)
            .map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
        let identifier = (dictionary[kSecCodeInfoIdentifier as String] as? String)
            ?? Bundle(url: url)?.bundleIdentifier ?? url.lastPathComponent
        return PluginIdentity(
            bundleIdentifier: identifier,
            team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: hash
        )
    }
}
