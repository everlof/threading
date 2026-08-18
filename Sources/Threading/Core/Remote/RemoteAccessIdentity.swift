import Foundation
import os
import Security
import ThreadingRemoteKit

/// The certificate the routable listeners present, and the fingerprint a paired phone checks it
/// against.
///
/// `SecIdentity` is an immutable Core Foundation object that Network.framework reads from its own
/// queue, which is why this is `@unchecked Sendable`: nothing here is written after construction.
struct RemoteAccessIdentity: @unchecked Sendable {
    let secIdentity: SecIdentity
    let certificateDER: Data
    let fingerprint: RemoteHostFingerprint
}

/// What the identity looks like from the main actor, without touching the disk to find out.
struct RemoteAccessIdentitySnapshot: Equatable, Sendable {
    /// The identity the listeners present, once one has been loaded or minted this launch.
    let fingerprint: RemoteHostFingerprint?
    /// A successor that has been minted and not yet activated. This is what `/api/me` announces
    /// so a paired device can pin it before it goes live.
    let nextFingerprint: RemoteHostFingerprint?
    /// Why there is no identity, when one was asked for and there is none. A failure and a
    /// fingerprint are never both present.
    let failure: RemoteIdentityFailure?

    /// Nothing has asked for an identity yet, which is the shipped state: no routable door is
    /// bound, so no certificate has been minted or read.
    static let unloaded = RemoteAccessIdentitySnapshot(
        fingerprint: nil,
        nextFingerprint: nil,
        failure: nil
    )
}

/// Who the certificate says it is. Read once, at mint time.
struct RemoteIdentitySubject: Sendable {
    /// This Mac's stable id, written into the subject so two Macs are told apart by a person
    /// reading the certificate.
    let hostIdentifier: String
    /// Addresses and names this Mac held when the certificate was minted, for tidiness only.
    let subjectAlternativeNames: [RemoteSubjectAlternativeName]
}

/// What a listener asks for when it needs something to present.
protocol RemoteAccessIdentityProviding: Sendable {
    func currentIdentity() -> Result<RemoteAccessIdentity, RemoteIdentityFailure>
}

/// Where this Mac's remote-access identity lives, and the only thing that mints one.
///
/// **The private key and its certificate are `0600` files in this app's own Application Support
/// directory, and the `SecIdentity` is rebuilt from them every launch.** Not the login keychain:
/// an agent's shell can delete a login-keychain item with `security delete-generic-password` and
/// no prompt, and this app launches agents with an unrestricted shell, so a stray deletion would
/// invalidate every pairing on the machine. The data-protection keychain would answer that and is
/// unavailable to an ad-hoc-signed Debug build. A file is readable by anything running as this
/// user, which is the trade: for a trust root, silent deletion is the failure that matters, and
/// rotation over the pinned channel makes a lost key the only reason anyone re-pairs everything.
///
/// **A missing or unreadable identity is a named state, never a silent regenerate.** Minting
/// happens on first enable and on an explicit reset, and nowhere else: a certificate that
/// quietly changed would unpair every device without anybody asking it to.
///
/// Mutable state belongs to `queue`; the published snapshot is behind a lock so the main actor
/// can read a fingerprint without waiting for a mint.
final class RemoteAccessIdentityStore: RemoteAccessIdentityProviding, @unchecked Sendable {

    // MARK: - Types

    /// The record on disk. Versioned because a build that cannot read one must say so rather
    /// than treat it as absent and mint over it.
    private struct StoredIdentity: Codable {
        let version: Int
        let createdAt: Date
        /// ANSI X9.63 `04 || X || Y || K`, which is what Security.framework hands out and takes
        /// back for a P-256 private key.
        let privateKey: Data
        let certificate: Data
    }

    private enum Slot: String {
        case current
        case next

        var fileName: String { "\(rawValue).json" }
    }

    // MARK: - Properties

    static let shared = RemoteAccessIdentityStore()

    /// Where an identity event is written. Injectable for the same reason the listener set's
    /// journal is: a hosted test runs inside the shipping app, so an unredirected call would
    /// append to the developer's own support journal.
    var journal: (@Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void) {
        get { journalStorage.withLock { $0 } }
        set { journalStorage.withLock { $0 = newValue } }
    }

    /// What the main actor may read: fingerprints and a failure, never a key and never the disk.
    var snapshot: RemoteAccessIdentitySnapshot { snapshotStorage.withLock { $0 } }

    private let directory: URL
    private let strategy: RemoteIdentityImportStrategy
    private let subject: @Sendable () -> RemoteIdentitySubject
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: RemoteIdentityDefaults.queueLabel)
    private let snapshotStorage =
        OSAllocatedUnfairLock<RemoteAccessIdentitySnapshot>(initialState: .unloaded)
    private let journalStorage = OSAllocatedUnfairLock<
        @Sendable (RemoteDiagnosticEvent, RemoteDiagnosticLevel, [RemoteDiagnosticField: String]) -> Void
    >(initialState: { event, level, fields in
        MacRemoteDiagnostics.record(event, level: level, fields: fields)
    })

    /// Queue-owned. The identity is rebuilt once per launch and then kept: a PKCS#12 import is
    /// the expensive half of this file, and the listener asks for it on every rebuild.
    private var cached: RemoteAccessIdentity?
    /// Queue-owned. Why the current slot could not be read, so a failure survives into the
    /// snapshot the settings screen will show.
    private var currentFailure: RemoteIdentityFailure?

    // MARK: - Initialization

    init(
        directory: URL = RemoteIdentityLocations.directory(),
        strategy: RemoteIdentityImportStrategy? = nil,
        subject: @escaping @Sendable () -> RemoteIdentitySubject = RemoteIdentityLocations.currentSubject,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.strategy = strategy ?? .preferred(directory: directory)
        self.subject = subject
        self.fileManager = fileManager
    }

    // MARK: - Reading

    /// The identity the listeners present, minting one the first time this Mac needs it.
    ///
    /// Called from the listener's queue, never from the main actor: it reads files, derives a key
    /// and imports a container.
    func currentIdentity() -> Result<RemoteAccessIdentity, RemoteIdentityFailure> {
        queue.sync {
            if let cached { return .success(cached) }
            let outcome = loadOrMint()
            publish()
            return outcome
        }
    }

    // MARK: - Explicit operations

    /// Throws the identity away and mints a new one.
    ///
    /// Every device paired to the old certificate has to scan a new code, which is why nothing
    /// calls this except a person asking for it.
    func reset() -> Result<RemoteAccessIdentity, RemoteIdentityFailure> {
        queue.sync {
            cached = nil
            remove(.current)
            remove(.next)
            let outcome = mint(into: .current)
            switch outcome {
            case .success(let identity):
                currentFailure = nil
                record(.hostIdentityReset, fingerprint: identity.fingerprint)
            case .failure(let failure):
                currentFailure = failure
            }
            publish()
            return outcome
        }
    }

    /// Mints the successor and keeps both, so `/api/me` can announce it over the channel the
    /// current identity already authenticates.
    ///
    /// Preparing twice replaces the unannounced successor rather than accumulating them: until
    /// activation nothing has presented it, so there is nothing to be compatible with.
    func prepareRotation() -> Result<RemoteHostFingerprint, RemoteIdentityFailure> {
        queue.sync {
            let outcome = mint(into: .next)
            publish()
            return outcome.map(\.fingerprint)
        }
    }

    /// Promotes the prepared successor. The listeners have to be rebuilt to present it; that is
    /// the caller's job, and the port does not move.
    func activateRotation() -> Result<RemoteAccessIdentity, RemoteIdentityFailure> {
        queue.sync {
            guard case .success(let stored) = read(.next) else {
                publish()
                return .failure(.noRotationPrepared)
            }
            guard let identity = makeIdentity(from: stored) else {
                publish()
                return .failure(.corrupt)
            }
            guard write(stored, to: .current) else {
                publish()
                return .failure(.unreadable)
            }
            remove(.next)
            cached = identity
            currentFailure = nil
            record(.hostIdentityRotated, fingerprint: identity.fingerprint)
            publish()
            return .success(identity)
        }
    }

    // MARK: - Loading

    private func loadOrMint() -> Result<RemoteAccessIdentity, RemoteIdentityFailure> {
        guard ensureDirectory() else {
            currentFailure = .directoryUnavailable
            return .failure(.directoryUnavailable)
        }
        switch read(.current) {
        case .success(let stored):
            guard let identity = makeIdentity(from: stored) else {
                currentFailure = .corrupt
                return .failure(.corrupt)
            }
            cached = identity
            currentFailure = nil
            return .success(identity)
        case .failure(.absent):
            let outcome = mint(into: .current)
            switch outcome {
            case .success(let identity):
                currentFailure = nil
                record(.hostIdentityCreated, fingerprint: identity.fingerprint)
            case .failure(let failure):
                currentFailure = failure
            }
            return outcome
        case .failure(let failure):
            // Deliberately not a mint. A file that is there and cannot be read is a state a
            // person has to see; replacing it would unpair every device to hide a bug.
            currentFailure = failure
            return .failure(failure)
        }
    }

    /// Rebuilds the `SecIdentity` from the two halves of a record, refusing a record whose
    /// halves do not belong together.
    ///
    /// The certificate's public key is compared against the stored private key's before anything
    /// is presented, so a file that was half-written or half-restored fails here with a name on
    /// it rather than at somebody's first TLS handshake.
    private func makeIdentity(from stored: StoredIdentity) -> RemoteAccessIdentity? {
        guard let key = try? RemoteIdentityCertificateBuilder.makeKey(
                privateKeyData: stored.privateKey
              ),
              let publicKey = SecKeyCopyPublicKey(key),
              let certificate = SecCertificateCreateWithData(nil, stored.certificate as CFData),
              let certificateKey = SecCertificateCopyKey(certificate),
              let expected = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let found = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              expected == found,
              let pkcs8 = RemotePKCS12Writer.pkcs8PrivateKey(x963: stored.privateKey),
              let container = RemotePKCS12Writer.makeContainer(
                  privateKeyPKCS8: pkcs8,
                  certificateDER: stored.certificate
              ),
              let identity = try? RemoteIdentityImporter.makeIdentity(
                  container: container,
                  strategy: strategy
              ) else { return nil }
        return RemoteAccessIdentity(
            secIdentity: identity,
            certificateDER: stored.certificate,
            fingerprint: RemoteHostFingerprint(certificateDER: stored.certificate)
        )
    }

    private func mint(into slot: Slot) -> Result<RemoteAccessIdentity, RemoteIdentityFailure> {
        guard ensureDirectory() else { return .failure(.directoryUnavailable) }
        let subject = self.subject()
        do {
            let key = try RemoteIdentityCertificateBuilder.makeKey()
            let certificate = try RemoteIdentityCertificateBuilder.makeCertificate(
                key: key,
                hostIdentifier: subject.hostIdentifier,
                subjectAlternativeNames: subject.subjectAlternativeNames
            )
            let stored = StoredIdentity(
                version: RemoteIdentityDefaults.recordVersion,
                createdAt: Date(),
                privateKey: try RemoteIdentityCertificateBuilder.privateKeyData(key),
                certificate: certificate
            )
            guard write(stored, to: slot) else { return .failure(.unreadable) }
            guard let identity = makeIdentity(from: stored) else {
                return .failure(.identityImportFailed)
            }
            if slot == .current { cached = identity }
            return .success(identity)
        } catch let failure as RemoteIdentityFailure {
            return .failure(failure)
        } catch {
            return .failure(.certificateGenerationFailed)
        }
    }

    // MARK: - Files

    private func url(for slot: Slot) -> URL {
        directory.appendingPathComponent(slot.fileName)
    }

    private func ensureDirectory() -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: RemoteIdentityDefaults.directoryPermissions]
            )
            return true
        } catch {
            ThreadingLogger.remote.error(
                "Remote access identity directory unavailable: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    /// Four answers, not two: absent, unreadable, a shape from another build, and a record.
    private func read(_ slot: Slot) -> Result<StoredIdentity, RemoteIdentityFailure> {
        let url = self.url(for: slot)
        guard fileManager.fileExists(atPath: url.path) else { return .failure(.absent) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        guard let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data) else {
            return .failure(.corrupt)
        }
        guard stored.version == RemoteIdentityDefaults.recordVersion else {
            // A record from a newer build is left exactly as it is. Overwriting it would mean a
            // downgrade confiscated the trust root it merely could not read.
            return .failure(.unsupportedVersion)
        }
        return .success(stored)
    }

    /// Writes the record and then proves what it wrote.
    ///
    /// The permission bits are set after the write rather than passed to it: an atomic write
    /// replaces the file with a new inode, so anything set beforehand belongs to the file that
    /// was replaced. Re-reading them is the same rule the rest of persistence follows — a short
    /// write and a wrong mode both look like success at the call site.
    private func write(_ stored: StoredIdentity, to slot: Slot) -> Bool {
        let url = self.url(for: slot)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: RemoteIdentityDefaults.filePermissions],
                ofItemAtPath: url.path
            )
            let written = try fileManager.attributesOfItem(atPath: url.path)
            guard (written[.posixPermissions] as? NSNumber)?.intValue
                    == RemoteIdentityDefaults.filePermissions else { return false }
            return true
        } catch {
            ThreadingLogger.remote.error(
                "Remote access identity could not be written: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    private func remove(_ slot: Slot) {
        try? fileManager.removeItem(at: url(for: slot))
    }

    // MARK: - Publishing

    private func publish() {
        let current = cached?.fingerprint
        let next = try? read(.next).map { RemoteHostFingerprint(certificateDER: $0.certificate) }.get()
        snapshotStorage.withLock {
            $0 = RemoteAccessIdentitySnapshot(
                fingerprint: current,
                nextFingerprint: next,
                failure: current == nil ? (currentFailure ?? .absent) : nil
            )
        }
    }

    /// A fingerprint is a public value, and it is still not what goes in the journal: a report
    /// carries a short hash of it, so two events about the same identity join without the report
    /// naming the certificate any device is pinned to.
    private func record(_ event: RemoteDiagnosticEvent, fingerprint: RemoteHostFingerprint) {
        journal(event, .info, [.detail: MacRemoteDiagnostics.pseudonym(fingerprint.hex, prefix: "fp")])
    }
}

/// Where the identity files live, and who the certificate says this Mac is.
enum RemoteIdentityLocations {

    /// `~/Library/Application Support/Threading/RemoteIdentity`, or a per-pid scratch directory
    /// under a hosted test.
    ///
    /// The redirect is the same one `StateManager` makes and for the same reason: the test bundle
    /// runs inside the shipping app, so an unredirected default would mint over — or read — the
    /// identity of the app the developer is running, and every device paired to that Mac would
    /// stop trusting it because a test ran.
    static func directory(fileManager: FileManager = .default) -> URL {
        guard !isHostedTest else {
            return fileManager.temporaryDirectory.appendingPathComponent(
                "Threading-HostedTestIdentity-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName, isDirectory: true)
            .appendingPathComponent(RemoteIdentityDefaults.directoryName, isDirectory: true)
    }

    /// Whether this process is a hosted XCTest bundle rather than the app the user is running.
    static let isHostedTest = NSClassFromString("XCTestCase") != nil

    /// The names this Mac would put in a certificate right now.
    ///
    /// Read at mint time and never again: the addresses a Mac holds change with every network it
    /// joins, and the client checks none of them. One certificate serving every address the Mac
    /// ever has is exactly what makes a VPN address work with no further ceremony.
    static let currentSubject: @Sendable () -> RemoteIdentitySubject = {
        var names: [RemoteSubjectAlternativeName] = []
        if let localHostname = RemoteAccessCoordinator.bonjourLocalHostname() {
            names.append(.dnsName(localHostname))
        }
        for address in RemoteNetworkInterfaces.current()
        where RemoteDoorClassification.isRoutable(address) {
            guard let name = RemoteSubjectAlternativeName.ipAddress(parsing: address.address) else {
                continue
            }
            names.append(name)
        }
        return RemoteIdentitySubject(
            hostIdentifier: RemoteHostIdentity.current.id,
            subjectAlternativeNames: names
        )
    }
}
