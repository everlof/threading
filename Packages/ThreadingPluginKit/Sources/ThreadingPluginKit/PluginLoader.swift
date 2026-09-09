import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

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
    /// The bundle loaded correctly but does not vend the presentation the host asked for.
    case capabilityUnavailable(name: String)
    /// Static metadata was selected from one signed build but another now occupies its path.
    case buildChanged(identifier: String)
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
        case .capabilityUnavailable(let name):
            return "plugin does not provide its declared \(name) presentation"
        case .buildChanged(let identifier):
            return "\(identifier) changed after its presentation was discovered"
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
        case .capabilityUnavailable: return "capability_unavailable"
        case .buildChanged: return "build_changed"
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
public struct PluginLoader: Sendable {

    /// What a bundle has to satisfy before its code is mapped.
    ///
    /// There is no `init`, so a loader cannot be built without saying which of these it is. That
    /// is deliberate, and it is the inverse of the bug this replaced: trust used to be a
    /// `Set<String>` of teams whose *empty* value silently meant "run anything", so leaving an
    /// argument out produced the dangerous loader. Leaving something out here does not compile.
    fileprivate enum Trust: Sendable {
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

    /// A readable bundle whose installed signature, when required, was checked without mapping
    /// its executable.
    ///
    /// Installed bundles are first copied into a process-private staging directory and the copy is
    /// verified at that final load path. The same `Bundle` instance then crosses into the
    /// main-actor mapping phase. Its initializer reads metadata but does not touch `principalClass`,
    /// so app-mediated replacement of the install path cannot change the build being mapped.
    ///
    /// This is not a sandbox boundary against another already-running process under the same Unix
    /// user; the in-process native tier cannot provide one. Its trust boundary is the explicit
    /// signature/build decision. Untrusted code belongs in the isolated extension tier.
    public final class VerifiedBundle: @unchecked Sendable {
        private let bundle: Bundle
        private let trust: Trust
        private let stagingParent: URL?
        private var mappedFromStaging = false
        public let identity: PluginIdentity?
        /// Presentation metadata read from the same immutable copy whose identity was verified.
        /// A mutable install path is never consulted again when the host names an approval.
        public let displayName: String

        fileprivate init(
            bundle: Bundle,
            trust: Trust,
            identity: PluginIdentity?,
            displayName: String,
            stagingParent: URL?
        ) {
            self.bundle = bundle
            self.trust = trust
            self.identity = identity
            self.displayName = displayName
            self.stagingParent = stagingParent
        }

        deinit {
            guard !mappedFromStaging, let stagingParent else { return }
            PluginLoader.discardStagedCopy(in: stagingParent)
        }

        /// Maps and constructs a bundle whose policy does not require a user decision.
        /// A verified installed candidate still fails closed when the decision is omitted.
        @MainActor
        public func load() throws -> ThreadingNativePlugin {
            try load { identity in
                throw PluginLoadFailure.notApproved(identifier: identity.bundleIdentifier)
            }
        }

        /// Applies the decision to the already verified identity, then and only then maps code.
        /// No filesystem or Security-framework validation occurs in this phase.
        @MainActor
        public func load(
            approving decide: (PluginIdentity) throws -> Bool
        ) throws -> ThreadingNativePlugin {
            if case .signatureAndDecision = trust {
                guard let identity else {
                    throw PluginLoadFailure.signatureInvalid(status: errSecInvalidData)
                }
                guard try decide(identity) else {
                    throw PluginLoadFailure.notApproved(identifier: identity.bundleIdentifier)
                }
            }
            // Everything past this line has mapped and run the bundle's code.
            guard let principal = bundle.principalClass else {
                throw PluginLoadFailure.noPrincipalClass
            }
            mappedFromStaging = stagingParent != nil
            guard let type = principal as? ThreadingNativePlugin.Type else {
                throw PluginLoadFailure.wrongProtocol
            }
            guard ThreadingPluginAPI.supports(type.pluginAPIVersion) else {
                throw PluginLoadFailure.apiVersionMismatch(
                    found: type.pluginAPIVersion,
                    expected: ThreadingPluginAPI.version
                )
            }
            return type.init()
        }
    }

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

    /// Reads bundle metadata and validates the installed signature without mapping executable
    /// code. Callers presenting UI should run this phase on a bounded worker, then call
    /// `VerifiedBundle.load` on the main actor for plugin construction.
    public func verify(bundleAt url: URL) throws -> VerifiedBundle {
        let verifiedURL: URL
        if case .signatureAndDecision = trust {
            // The install directory is user-writable. Copy first, then verify the exact path that
            // will be mapped; otherwise replacing the original after verification can make a
            // path-based `Bundle` execute bytes the user never approved.
            verifiedURL = try Self.stageReadOnlyCopy(of: url)
        } else {
            verifiedURL = url
        }
        let stagingParent = verifiedURL == url ? nil : verifiedURL.deletingLastPathComponent()
        guard let bundle = Bundle(url: verifiedURL) else {
            if let stagingParent { Self.discardStagedCopy(in: stagingParent) }
            throw PluginLoadFailure.unreadableBundle(path: url.path)
        }
        let identity: PluginIdentity?
        if case .signatureAndDecision = trust {
            do {
                identity = try Self.identity(of: verifiedURL)
            } catch {
                if let stagingParent { Self.discardStagedCopy(in: stagingParent) }
                throw error
            }
        } else {
            identity = nil
        }
        let displayName = Self.displayName(of: bundle, identity: identity)
        return VerifiedBundle(
            bundle: bundle,
            trust: trust,
            identity: identity,
            displayName: displayName,
            stagingParent: stagingParent
        )
    }

    /// Selects and bounds plugin-controlled prompt text. Every candidate, including identifiers
    /// used as fallbacks, crosses the same policy; the final literal cannot carry hostile text.
    /// This runs while the verified bundle is still on the worker with the rest of inspection.
    private static func displayName(
        of bundle: Bundle,
        identity: PluginIdentity?
    ) -> String {
        let candidates: [String?] = [
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            identity?.bundleIdentifier,
            bundle.bundleIdentifier,
        ]
        for candidate in candidates {
            if let bounded = boundedPresentationName(candidate) { return bounded }
        }
        return "Plugin"
    }

    private static func boundedPresentationName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bounded = String(raw.unicodeScalars.prefix(256))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty, bounded.unicodeScalars.allSatisfy({ scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }) else { return nil }
        return bounded
    }

    /// Makes installed code stable between verification and `Bundle.principalClass`.
    ///
    /// The source may change while it is copied; validating the finished copy catches that. Its
    /// UUID parent is private to this process and made non-writable before the URL escapes this
    /// function, so ordinary replacement through the install path cannot reach the staged bytes.
    /// Successful native code remains mapped for the process lifetime, so its staged resources do
    /// too; the process-specific root lives under the system temporary directory.
    private static func stageReadOnlyCopy(of source: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PluginLoadFailure.unreadableBundle(path: source.path)
        }
        let root = stagingRoot
        do {
            let parent = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let staged = parent.appendingPathComponent(
                source.lastPathComponent,
                isDirectory: true
            )
            do {
                try FileManager.default.copyItem(at: source, to: staged)
                try removeWritePermissionRecursively(from: staged)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: parent.path
                )
                return staged
            } catch {
                try? FileManager.default.removeItem(at: parent)
                throw error
            }
        } catch let failure as PluginLoadFailure {
            throw failure
        } catch {
            throw PluginLoadFailure.unreadableBundle(path: source.path)
        }
    }

    private static func removeWritePermissionRecursively(from root: URL) throws {
        let protectedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard protectedRoot == root.standardizedFileURL.path else {
            throw PluginLoadFailure.unreadableBundle(path: root.path)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) else {
            throw PluginLoadFailure.unreadableBundle(path: root.path)
        }
        var entries = [root]
        while let entry = enumerator.nextObject() as? URL { entries.append(entry) }

        // Children first so directories remain traversable until their contents are protected.
        for entry in entries.reversed() {
            let values = try entry.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isDirectoryKey,
            ])
            if values.isSymbolicLink == true {
                // Framework-version links are ordinary inside bundles, but a link out of the
                // staged tree would put mutable bytes back behind the final verified path.
                let target = entry.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.hasPrefix(protectedRoot + "/") else {
                    throw PluginLoadFailure.unreadableBundle(path: root.path)
                }
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber else {
                throw PluginLoadFailure.unreadableBundle(path: root.path)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions.intValue & ~0o222],
                ofItemAtPath: entry.path
            )
        }
    }

    private static func discardStagedCopy(in parent: URL) {
        guard parent.lastPathComponent.count == UUID().uuidString.count,
              parent.deletingLastPathComponent() == stagingRoot else { return }
        // Releasing the last verified-candidate reference commonly happens on the main actor.
        // Recursively walking and chmod/removing an externally sized bundle must not happen there.
        stagingCleanupQueue.async {
            makeWritableAndRemove(parent)
        }
    }

    /// One owner bounds cleanup concurrency even if a directory refresh rejects many candidates.
    private static let stagingCleanupQueue = DispatchQueue(
        label: "codes.threading.plugin-staging-cleanup",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    private static let stagingRoot: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingPluginStaging-\(ProcessInfo.processInfo.processIdentifier)-"
                + UUID().uuidString,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        atexit { PluginLoader.removeStagingRootAtExit() }
        #endif
        return root
    }()

    private static func removeStagingRootAtExit() {
        makeWritableAndRemove(stagingRoot)
    }

    private static func makeWritableAndRemove(_ root: URL) {
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: []
        ) {
            var entries = [root]
            while let entry = enumerator.nextObject() as? URL { entries.append(entry) }
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [
                    .isSymbolicLinkKey,
                    .isDirectoryKey,
                ]), values.isSymbolicLink != true else { continue }
                try? FileManager.default.setAttributes(
                    [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
                    ofItemAtPath: entry.path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Load under a policy that needs no decision. Refuses a `signatureAndDecision()` loader,
    /// which has to be asked through `load(bundleAt:approving:)`.
    @MainActor
    public func load(bundleAt url: URL) throws -> ThreadingNativePlugin {
        try verify(bundleAt: url).load()
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
        try verify(bundleAt: url).load(approving: decide)
    }

    /// Who a bundle says it is, and exactly which build of it this is.
    ///
    /// The team alone is not an identity to record a decision against: approving "this plugin"
    /// has to mean the bytes the user was shown, or an update — or a replacement dropped into the
    /// same folder under the same name — inherits an approval nobody gave it. `cdHash` is the code
    /// directory hash, so a changed binary is a different identity and asks again.
    public struct PluginIdentity: Equatable, Hashable, Sendable {
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
