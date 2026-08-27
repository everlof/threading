import Foundation
import Security

/// Where `SecPKCS12Import` is allowed to put what it reads.
///
/// The default keychain is the one outcome that must never happen, and it is what the importer
/// does on macOS when nothing says otherwise. `kSecImportToMemoryOnly` says otherwise, and it is
/// **macOS 15 and later**, not 13, so an older system needs a keychain of this app's own: created
/// fresh each launch with a generated password, never added to the search list, and deleted
/// rather than reused. The login keychain is never touched on either path.
enum RemoteIdentityImportStrategy: Equatable {
    case memoryOnly
    case keychainFile(URL)

    /// What this system supports, unless a caller states otherwise.
    static func preferred(directory: URL) -> RemoteIdentityImportStrategy {
        if #available(macOS 15.0, *) { return .memoryOnly }
        return .keychainFile(directory.appendingPathComponent("identity-import.keychain"))
    }
}

enum RemoteIdentityImporter {

    /// Turns a one-shot container into the `SecIdentity` the listener presents.
    static func makeIdentity(
        container: RemotePKCS12Writer.Container,
        strategy: RemoteIdentityImportStrategy
    ) throws -> SecIdentity {
        var options: [String: Any] = [
            kSecImportExportPassphrase as String: container.passphrase as CFString
        ]
        var keychain: SecKeychain?

        switch strategy {
        case .memoryOnly:
            guard #available(macOS 15.0, *) else { throw RemoteIdentityFailure.identityImportFailed }
            options[kSecImportToMemoryOnly as String] = kCFBooleanTrue as Any
        case .keychainFile(let url):
            keychain = try makeThrowawayKeychain(at: url)
            options[kSecImportExportKeychain as String] = keychain as Any
        }

        var items: CFArray?
        let status = SecPKCS12Import(container.data as CFData, options as CFDictionary, &items)
        defer {
            if case .keychainFile(let url) = strategy {
                if let keychain { SecKeychainDelete(keychain) }
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard status == errSecSuccess else { throw RemoteIdentityFailure.identityImportFailed }

        // Success with nothing in it is the failure this route is most likely to produce, so it
        // is checked rather than assumed: an unencrypted key bag imports "successfully" and
        // yields no identity at all.
        guard let entries = items as? [[String: Any]],
              let first = entries.first,
              let identity = Self.identity(from: first[kSecImportItemIdentity as String]) else {
            throw RemoteIdentityFailure.identityImportFailed
        }
        return identity
    }

    /// The value under `kSecImportItemIdentity`, if it really is one.
    ///
    /// `as?` cannot ask this question. The compiler rejects a conditional downcast to a
    /// CoreFoundation type outright, as one that "will always succeed": a Swift cast does not tell
    /// one CF type from another, so `as? SecIdentity` would have waved through whatever the
    /// framework had put there. The name Security gives its own types is `CFGetTypeID`, so that is
    /// what is compared, and only a match is taken as an identity. Parsing a container is the one
    /// place here that reads bytes somebody else supplied, and a container that decodes to
    /// something other than an identity is a refusal — `identityImportFailed`, the same answer an
    /// empty result gets — never a trap.
    static func identity(from value: Any?) -> SecIdentity? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == SecIdentityGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast - guarded by the CFTypeID comparison above.
        return (object as! SecIdentity)
    }

    /// A keychain this app owns for the length of one import.
    ///
    /// Created with a generated password so nothing prompts, deleted immediately afterwards, and
    /// never added to the search list: a keychain in the search list is one every other Security
    /// call on this machine would consult.
    private static func makeThrowawayKeychain(at url: URL) throws -> SecKeychain {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let password = RemotePKCS12Writer.randomBytes(RemotePKCS12Defaults.passphraseByteCount)
            .base64EncodedString()
        var previousList: CFArray?
        SecKeychainCopySearchList(&previousList)

        var keychain: SecKeychain?
        let status = password.withCString { pointer in
            SecKeychainCreate(url.path, UInt32(strlen(pointer)), pointer, false, nil, &keychain)
        }
        guard status == errSecSuccess, let keychain else {
            throw RemoteIdentityFailure.keychainUnavailable
        }
        // Belt and braces: if creating it put it in the search list, take it back out.
        if let previousList { SecKeychainSetSearchList(previousList) }
        return keychain
    }
}
