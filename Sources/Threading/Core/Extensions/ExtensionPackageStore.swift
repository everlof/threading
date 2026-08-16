import Foundation
import ThreadingExtensionKit

/// One package found in Threading's app-owned extension directory.
///
/// Invalid packages remain in the inventory so Settings can explain what is wrong instead of
/// making a damaged installation disappear. Only a package with a validated `bundle` may run.
struct InstalledExtensionPackage {
    let packageURL: URL
    let bundle: ThreadingExtensionBundle?
    let provenance: ExtensionInstallProvenance?
    let problem: String?

    var identifier: String {
        bundle?.manifest.identifier
            ?? packageURL.deletingPathExtension().lastPathComponent
    }
}

enum ExtensionPackageStoreError: LocalizedError {
    case packageContainsSymbolicLink(String)
    case packageHasTooManyEntries(maximum: Int)
    case packageIsTooLarge(maximum: Int64)
    case alreadyInstalled(String)
    case notInstalled(String)
    case installedCopyInvalid(String)
    case updateChangedUnderneath(String)
    case packageCouldNotBeDigested(String)
    case dataVersionRollback(identifier: String, installed: Int, candidate: Int)
    case invalidFirstPartySource
    case enablementStateCouldNotBeSaved
    case provenanceCouldNotBeSaved(String)

    var errorDescription: String? {
        switch self {
        case .packageContainsSymbolicLink(let path):
            return L10n.format("The extension package contains a symbolic link at %@.", path)
        case .packageHasTooManyEntries(let maximum):
            return L10n.format(
                "The extension package contains more than %lld files and directories.",
                Int64(maximum)
            )
        case .packageIsTooLarge(let maximum):
            let size = ByteCountFormatter.string(
                fromByteCount: maximum,
                countStyle: .file
            )
            return L10n.format("The extension package is larger than %@.", size)
        case .alreadyInstalled(let identifier):
            return L10n.format("An extension with identifier %@ is already installed.", identifier)
        case .notInstalled(let identifier):
            return L10n.format("No extension with identifier %@ is installed.", identifier)
        case .installedCopyInvalid(let message):
            return L10n.format("The installed extension copy did not validate: %@", message)
        case .updateChangedUnderneath(let identifier):
            return L10n.format(
                "The update for %@ changed after it was reviewed. Check what it now asks for and try again.",
                identifier
            )
        case .packageCouldNotBeDigested(let identifier):
            return L10n.format(
                "The extension package for %@ could not be read completely.",
                identifier
            )
        case .dataVersionRollback(let identifier, let installed, let candidate):
            return L10n.format(
                "The update for %@ declares data version %lld, but the installed package already "
                    + "uses %lld. Data versions cannot decrease.",
                identifier,
                Int64(candidate),
                Int64(installed)
            )
        case .invalidFirstPartySource:
            return L10n.string("The included extension has an invalid source URL.")
        case .enablementStateCouldNotBeSaved:
            return L10n.string(
                "Extension enablement could not be saved without risking its recovery copy."
            )
        case .provenanceCouldNotBeSaved(let identifier):
            return L10n.format("Extension provenance could not be saved for %@.", identifier)
        }
    }
}

/// Filesystem and persisted enablement state for installed extension packages.
///
/// This type is synchronous and deliberately has no AppKit dependency. Production wraps it in
/// `ExtensionManager` and performs imports off the main thread; tests can point it at a temporary
/// root without touching the user's Application Support directory.
final class ExtensionPackageStore: @unchecked Sendable {
    static let packageExtension = "threadingextension"
    static let maximumEntries = 20_000
    static let maximumPackageBytes: Int64 = 256 * 1024 * 1024
    static let maximumInstalledPackages = 256
    static let maximumPackageDirectoryEntries = 1_024

    private struct State: Codable {
        static let currentFormatVersion = 1

        var formatVersion = currentFormatVersion
        var enabledIdentifiers: Set<String> = []
    }

    let rootURL: URL
    let packagesURL: URL
    let removedURL: URL
    let provenanceURL: URL
    let storageStore: ExtensionStorageStore

    private let fileManager: FileManager
    private let statePersistence: RecoverableFileStore<State>
    private let lock = NSLock()
    private var provenancePersistence: [
        String: RecoverableFileStore<ExtensionInstallProvenance?>
    ] = [:]

    init(
        rootURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.packagesURL = rootURL.appendingPathComponent("Packages", isDirectory: true)
        self.removedURL = rootURL.appendingPathComponent("Removed", isDirectory: true)
        self.provenanceURL = rootURL.appendingPathComponent("Provenance", isDirectory: true)
        self.storageStore = ExtensionStorageStore(rootURL: rootURL, fileManager: fileManager)
        self.fileManager = fileManager
        self.statePersistence = RecoverableFileStore(
            url: rootURL.appendingPathComponent("state.json", isDirectory: false),
            fileManager: fileManager,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
    }

    /// Reads the complete installed-package directory.
    ///
    /// Individual invalid packages remain as inventory entries with a `problem`. Failure to
    /// read the directory itself is different: returning `[]` would falsely tell the product
    /// that every extension had been removed, so the caller must surface or retain that error.
    func inventory() throws -> [InstalledExtensionPackage] {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let entries = try BoundedDirectoryReader.shallowContents(
            of: packagesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            maximumEntries: Self.maximumPackageDirectoryEntries,
            fileManager: fileManager
        )
        let packageURLs = entries.filter { $0.pathExtension == Self.packageExtension }
        guard packageURLs.count <= Self.maximumInstalledPackages else {
            throw BoundedDirectoryReadError.exceedsLimit(
                maximumEntries: Self.maximumInstalledPackages
            )
        }
        return packageURLs
        .map { url in
            do {
                return InstalledExtensionPackage(
                    packageURL: url,
                    bundle: try ExtensionBundleInspector.inspect(at: url),
                    provenance: loadProvenance(
                        identifier: url.deletingPathExtension().lastPathComponent
                    ),
                    problem: nil
                )
            } catch {
                return InstalledExtensionPackage(
                    packageURL: url,
                    bundle: nil,
                    provenance: loadProvenance(
                        identifier: url.deletingPathExtension().lastPathComponent
                    ),
                    problem: error.localizedDescription
                )
            }
        }
        .sorted {
            $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
        }
    }

    func enabledIdentifiers() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return loadState().enabledIdentifiers
    }

    func setEnabled(_ enabled: Bool, identifier: String) throws {
        lock.lock()
        defer { lock.unlock() }

        guard ExtensionIdentifierRules.isReverseDNSIdentifier(identifier) else {
            throw ExtensionValidationError(issues: [
                .init(path: "identifier", message: "must be a lowercase reverse-DNS identifier")
            ])
        }
        var state = loadState()
        if enabled {
            state.enabledIdentifiers.insert(identifier)
        } else {
            state.enabledIdentifiers.remove(identifier)
        }
        try saveState(state)
    }

    /// Copies a validated source directory into app-owned storage and leaves it disabled.
    ///
    /// Copying into a staging sibling and moving only after the copy validates means discovery
    /// sees either the old complete inventory or the new complete package, never a half-copy.
    func install(
        from sourceURL: URL,
        source installSource: ExtensionInstallSource = .localImport
    ) throws -> ThreadingExtensionBundle {
        let sourceBundle = try ExtensionBundleInspector.inspect(at: sourceURL)
        try validatePackageShape(at: sourceBundle.rootURL)

        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let identifier = sourceBundle.manifest.identifier
        let target = packageURL(for: identifier)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw ExtensionPackageStoreError.alreadyInstalled(identifier)
        }

        let staging = packagesURL.appendingPathComponent(
            ".import-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: sourceBundle.rootURL, to: staging)
        try validatePackageShape(at: staging)

        let staged: ThreadingExtensionBundle
        do {
            staged = try ExtensionBundleInspector.inspect(at: staging)
            guard staged.manifest.identifier == identifier else {
                throw ExtensionPackageStoreError.installedCopyInvalid(
                    "the identifier changed while the package was copied"
                )
            }
        } catch let error as ExtensionPackageStoreError {
            throw error
        } catch {
            throw ExtensionPackageStoreError.installedCopyInvalid(error.localizedDescription)
        }

        let previousState = loadState()
        var state = previousState
        state.enabledIdentifiers.remove(identifier)
        try saveState(state)

        do {
            try fileManager.moveItem(at: staging, to: target)
            let installed = try ExtensionBundleInspector.inspect(at: target)
            try recordProvenance(
                for: installed,
                sourceName: sourceURL.lastPathComponent,
                installSource: installSource,
                preserving: nil
            )
            return installed
        } catch {
            let installError = error
            var rollbackProblems: [String] = []
            do {
                try restoreProvenance(nil, identifier: identifier)
            } catch {
                rollbackProblems.append("provenance: \(error.localizedDescription)")
            }
            if fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.moveItem(at: target, to: staging)
                } catch {
                    rollbackProblems.append("package: \(error.localizedDescription)")
                }
            }
            if state.enabledIdentifiers != previousState.enabledIdentifiers {
                do {
                    try saveState(previousState)
                } catch {
                    rollbackProblems.append("enablement: \(error.localizedDescription)")
                }
            }
            guard rollbackProblems.isEmpty else {
                throw ExtensionPackageStoreError.installedCopyInvalid(
                    "the import failed and its partial state could not be restored completely. "
                        + "Import error: \(installError.localizedDescription). "
                        + "Rollback errors: \(rollbackProblems.joined(separator: "; "))"
                )
            }
            throw installError
        }
    }

    /// What replacing the installed copy of `sourceURL`'s extension would change.
    ///
    /// Computed without touching the installation, so a caller can show it and let the user
    /// decide. Nothing here mutates anything.
    func updatePlan(from sourceURL: URL) throws -> ExtensionUpdatePlan {
        let candidate = try ExtensionBundleInspector.inspect(at: sourceURL)
        let installed = try installedManifest(for: candidate.manifest.identifier)
        guard candidate.manifest.dataVersion >= installed.dataVersion else {
            throw ExtensionPackageStoreError.dataVersionRollback(
                identifier: candidate.manifest.identifier,
                installed: installed.dataVersion,
                candidate: candidate.manifest.dataVersion
            )
        }
        guard let digest = ExtensionPackageDigest.compute(
            at: candidate.rootURL,
            fileManager: fileManager
        ) else {
            throw ExtensionPackageStoreError.packageCouldNotBeDigested(
                candidate.manifest.identifier
            )
        }
        return ExtensionUpdatePlan(
            installed: installed,
            candidate: candidate.manifest,
            sourceDigest: digest
        )
    }

    /// Replaces an installed extension with a newer copy of itself.
    ///
    /// `approving` is the plan the caller showed the user, and it is **re-computed and compared
    /// here** rather than trusted. Between showing a capability delta and acting on it the
    /// source directory can change — the same reason `ArtifactScanner` re-checks its two gates
    /// immediately before deleting — and an update that silently granted a capability the user
    /// never saw is the exact failure this plan exists to prevent.
    ///
    /// Private storage is untouched: it lives in a separate tree keyed by identifier, so an
    /// extension keeps its settings, key-value state, cache and secrets across an update. That
    /// is the behaviour an update *should* have, and it is worth stating because the opposite —
    /// uninstall then install — silently discards all four.
    @discardableResult
    func update(
        from sourceURL: URL,
        approving plan: ExtensionUpdatePlan,
        source installSource: ExtensionInstallSource = .localImport
    ) throws -> ThreadingExtensionBundle {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let identifier = plan.identifier
        let target = packageURL(for: identifier)
        guard fileManager.fileExists(atPath: target.path) else {
            throw ExtensionPackageStoreError.notInstalled(identifier)
        }
        let staging = packagesURL.appendingPathComponent(
            ".update-\(UUID().uuidString)",
            isDirectory: true
        )
        let outgoing = packagesURL.appendingPathComponent(
            ".replaced-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: staging)
        }

        // The staged copy is the security boundary: it is the exact tree inspected, digested,
        // approved and eventually moved into place. The source may be a mutable development
        // directory, so nothing read directly from it is trusted after this copy begins.
        try fileManager.copyItem(at: sourceURL, to: staging)
        try validatePackageShape(at: staging)
        let staged: ThreadingExtensionBundle
        do {
            staged = try ExtensionBundleInspector.inspect(at: staging)
            guard staged.manifest.identifier == identifier else {
                throw ExtensionPackageStoreError.installedCopyInvalid(
                    "the identifier changed while the package was copied"
                )
            }
        } catch let error as ExtensionPackageStoreError {
            throw error
        } catch {
            throw ExtensionPackageStoreError.installedCopyInvalid(error.localizedDescription)
        }

        guard let stagedDigest = ExtensionPackageDigest.compute(
            at: staging,
            fileManager: fileManager
        ) else {
            throw ExtensionPackageStoreError.packageCouldNotBeDigested(identifier)
        }
        let current = try ExtensionBundleInspector.inspect(at: target).manifest
        let observed = ExtensionUpdatePlan(
            installed: current,
            candidate: staged.manifest,
            sourceDigest: stagedDigest
        )
        guard observed == plan, plan.sourceDigest != nil else {
            throw ExtensionPackageStoreError.updateChangedUnderneath(identifier)
        }

        let existingProvenance = loadProvenance(identifier: identifier)

        // Move the old copy aside before moving the new one in, and put it back if that fails.
        // A window in which no package exists is survivable; one in which a half-copied package
        // exists is not, which is why the new copy is validated in staging first.
        try fileManager.moveItem(at: target, to: outgoing)
        do {
            try fileManager.moveItem(at: staging, to: target)
            let installed = try ExtensionBundleInspector.inspect(at: target)
            try recordProvenance(
                for: installed,
                sourceName: sourceURL.lastPathComponent,
                installSource: installSource,
                preserving: existingProvenance
            )
            do {
                try fileManager.removeItem(at: outgoing)
            } catch {
                ThreadingLogger.extensions.error(
                    "Updated \(identifier, privacy: .public), but its replaced package could not be removed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            return installed
        } catch {
            let updateError = error
            var rollbackProblems: [String] = []
            do {
                // If the new tree reached its destination but post-move validation failed, move
                // it back to staging first. The deferred staging cleanup may discard that
                // rejected candidate; it must never discard the known-good outgoing package.
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.moveItem(at: target, to: staging)
                }
                try fileManager.moveItem(at: outgoing, to: target)
            } catch {
                rollbackProblems.append(
                    "package (recoverable at \(outgoing.path)): \(error.localizedDescription)"
                )
            }
            do {
                try restoreProvenance(existingProvenance, identifier: identifier)
            } catch {
                rollbackProblems.append("provenance: \(error.localizedDescription)")
            }
            guard rollbackProblems.isEmpty else {
                throw ExtensionPackageStoreError.installedCopyInvalid(
                    "the update failed and the previous installation could not be restored "
                        + "completely. Update error: \(updateError.localizedDescription). "
                        + "Rollback errors: \(rollbackProblems.joined(separator: "; "))"
                )
            }
            throw updateError
        }
    }

    private func installedManifest(for identifier: String) throws -> ExtensionManifest {
        let installed = packageURL(for: identifier)
        guard fileManager.fileExists(atPath: installed.path) else {
            throw ExtensionPackageStoreError.notInstalled(identifier)
        }
        return try ExtensionBundleInspector.inspect(at: installed).manifest
    }

    /// Moves an extension into Threading's recoverable Removed directory.
    ///
    /// The package is not destroyed. Its enablement record is cleared and the returned URL is
    /// where the user can recover it from until they empty that directory themselves.
    @discardableResult
    func uninstall(identifier: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectories()
        let source = packageURL(for: identifier)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ExtensionPackageStoreError.notInstalled(identifier)
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        var destination = removedURL.appendingPathComponent(
            "\(identifier)-\(timestamp).\(Self.packageExtension)",
            isDirectory: true
        )
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            counter += 1
            destination = removedURL.appendingPathComponent(
                "\(identifier)-\(timestamp)-\(counter).\(Self.packageExtension)",
                isDirectory: true
            )
        }

        var state = loadState()
        state.enabledIdentifiers.remove(identifier)
        try saveState(state)

        try fileManager.moveItem(at: source, to: destination)
        // The package has already moved at this point. A storage recovery failure must not make
        // callers believe the uninstall failed and keep stale UI state; private data remains in
        // its original host-owned directory and is therefore still recoverable.
        do {
            try storageStore.recover(identifier: identifier, alongside: destination)
        } catch {
            ThreadingLogger.extensions.warning(
                "Extension uninstall could not move private storage identifier=\(identifier, privacy: .public) recovery=\(destination.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        let provenance = provenanceFileURL(identifier: identifier)
        if fileManager.fileExists(atPath: provenance.path) {
            do {
                try fileManager.moveItem(
                    at: provenance,
                    to: destination
                        .deletingPathExtension()
                        .appendingPathExtension("provenance.json")
                )
            } catch {
                ThreadingLogger.extensions.warning(
                    "Extension uninstall could not move provenance identifier=\(identifier, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        return destination
    }

    func packageURL(for identifier: String) -> URL {
        packagesURL.appendingPathComponent(
            "\(identifier).\(Self.packageExtension)",
            isDirectory: true
        )
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(
            at: packagesURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: removedURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: provenanceURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func recordProvenance(
        for bundle: ThreadingExtensionBundle,
        sourceName: String,
        installSource: ExtensionInstallSource,
        preserving existing: ExtensionInstallProvenance?
    ) throws {
        if case .firstPartyCatalog(let repositoryURL) = installSource,
           !ExtensionInstallSource.isSafeRepositoryURL(repositoryURL) {
            throw ExtensionPackageStoreError.invalidFirstPartySource
        }
        guard let digest = ExtensionPackageDigest.compute(
            at: bundle.rootURL,
            fileManager: fileManager
        ) else {
            throw ExtensionPackageStoreError.packageCouldNotBeDigested(
                bundle.manifest.identifier
            )
        }
        let now = Date()
        let sdkVersion = bundle.sourceURL.flatMap { source in
            [
                source.appendingPathComponent(
                    "Vendor/ThreadingExtensionKit/SDK_VERSION",
                    isDirectory: false
                ),
                source.appendingPathComponent("SDK_VERSION", isDirectory: false)
            ].lazy.compactMap {
                try? BoundedFileReader.read($0, maximumBytes: 4_096)
            }
                .compactMap { String(data: $0, encoding: .utf8) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let record = ExtensionInstallProvenance(
            installSource: installSource,
            sourceName: sourceName,
            contentDigest: digest,
            sdkVersion: sdkVersion,
            firstInstalledAt: existing?.firstInstalledAt ?? now,
            lastUpdatedAt: now
        )
        guard provenanceStore(identifier: bundle.manifest.identifier).save(record) else {
            throw ExtensionPackageStoreError.provenanceCouldNotBeSaved(
                bundle.manifest.identifier
            )
        }
    }

    /// Restores the provenance half of an import/update transaction with a fresh persistence
    /// latch. A failed verified write deliberately disables its store instance; reusing that
    /// instance would make rollback impossible even when the filesystem failure was transient.
    private func restoreProvenance(
        _ record: ExtensionInstallProvenance?,
        identifier: String
    ) throws {
        provenancePersistence.removeValue(forKey: identifier)
        let url = provenanceFileURL(identifier: identifier)
        guard let record else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        guard provenanceStore(identifier: identifier).save(record) else {
            throw ExtensionPackageStoreError.provenanceCouldNotBeSaved(identifier)
        }
    }

    private func loadProvenance(identifier: String) -> ExtensionInstallProvenance? {
        provenanceStore(identifier: identifier).load(defaultValue: nil).value
    }

    private func provenanceFileURL(identifier: String) -> URL {
        provenanceURL.appendingPathComponent("\(identifier).json", isDirectory: false)
    }

    /// Must be called while `lock` is held. Keeping one instance per identifier preserves the
    /// store's write-disable latch if a recovery copy or a later write cannot be verified.
    private func provenanceStore(
        identifier: String
    ) -> RecoverableFileStore<ExtensionInstallProvenance?> {
        if let existing = provenancePersistence[identifier] {
            return existing
        }
        let store = RecoverableFileStore<ExtensionInstallProvenance?>(
            url: provenanceFileURL(identifier: identifier),
            fileManager: fileManager,
            criticality: .primary,
            sizePolicy: .compactMetadata
        )
        provenancePersistence[identifier] = store
        return store
    }

    private func validatePackageShape(at root: URL) throws {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .fileSizeKey
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return
        }

        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= Self.maximumEntries else {
                throw ExtensionPackageStoreError.packageHasTooManyEntries(
                    maximum: Self.maximumEntries
                )
            }

            let values = try url.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .fileSizeKey
            ])
            let relative = url.pathComponents
                .suffix(enumerator.level)
                .joined(separator: "/")
            guard values.isSymbolicLink != true else {
                throw ExtensionPackageStoreError.packageContainsSymbolicLink(relative)
            }
            if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                guard bytes <= Self.maximumPackageBytes else {
                    throw ExtensionPackageStoreError.packageIsTooLarge(
                        maximum: Self.maximumPackageBytes
                    )
                }
            }
        }
        if let enumerationError {
            throw enumerationError
        }
    }

    private func loadState() -> State {
        statePersistence.load(defaultValue: State()) { state in
            guard state.formatVersion == State.currentFormatVersion else {
                throw ExtensionSettingsValueStoreError.incompatibleFormat(
                    state.formatVersion
                )
            }
            guard state.enabledIdentifiers.allSatisfy(
                ExtensionIdentifierRules.isReverseDNSIdentifier
            ) else {
                throw ExtensionValidationError(issues: [
                    .init(
                        path: "enabledIdentifiers",
                        message: "contains an invalid extension identifier"
                    )
                ])
            }
        }.value
    }

    private func saveState(_ state: State) throws {
        try ensureDirectories()
        guard statePersistence.save(state) else {
            throw ExtensionPackageStoreError.enablementStateCouldNotBeSaved
        }
    }
}
