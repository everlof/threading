import Foundation
import SkalmanExtensionKit

/// One package found in Skalman's app-owned extension directory.
///
/// Invalid packages remain in the inventory so Settings can explain what is wrong instead of
/// making a damaged installation disappear. Only a package with a validated `bundle` may run.
struct InstalledExtensionPackage {
    let packageURL: URL
    let bundle: SkalmanExtensionBundle?
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

    var errorDescription: String? {
        switch self {
        case .packageContainsSymbolicLink(let path):
            return "The extension package contains a symbolic link at \(path)."
        case .packageHasTooManyEntries(let maximum):
            return "The extension package contains more than \(maximum) files and directories."
        case .packageIsTooLarge(let maximum):
            let size = ByteCountFormatter.string(
                fromByteCount: maximum,
                countStyle: .file
            )
            return "The extension package is larger than \(size)."
        case .alreadyInstalled(let identifier):
            return "An extension with identifier \(identifier) is already installed."
        case .notInstalled(let identifier):
            return "No extension with identifier \(identifier) is installed."
        case .installedCopyInvalid(let message):
            return "The installed extension copy did not validate: \(message)"
        case .updateChangedUnderneath(let identifier):
            return "The update for \(identifier) changed after it was reviewed. "
                + "Check what it now asks for and try again."
        case .packageCouldNotBeDigested(let identifier):
            return "The extension package for \(identifier) could not be read completely."
        case .dataVersionRollback(let identifier, let installed, let candidate):
            return "The update for \(identifier) declares data version \(candidate), but the "
                + "installed package already uses \(installed). Data versions cannot decrease."
        }
    }
}

/// Filesystem and persisted enablement state for installed extension packages.
///
/// This type is synchronous and deliberately has no AppKit dependency. Production wraps it in
/// `ExtensionManager` and performs imports off the main thread; tests can point it at a temporary
/// root without touching the user's Application Support directory.
final class ExtensionPackageStore: @unchecked Sendable {
    static let packageExtension = "skalmanextension"
    static let maximumEntries = 20_000
    static let maximumPackageBytes: Int64 = 256 * 1024 * 1024

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

    private let stateURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        rootURL: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skalman", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.packagesURL = rootURL.appendingPathComponent("Packages", isDirectory: true)
        self.removedURL = rootURL.appendingPathComponent("Removed", isDirectory: true)
        self.provenanceURL = rootURL.appendingPathComponent("Provenance", isDirectory: true)
        self.storageStore = ExtensionStorageStore(rootURL: rootURL, fileManager: fileManager)
        self.stateURL = rootURL.appendingPathComponent("state.json", isDirectory: false)
        self.fileManager = fileManager
    }

    func inventory() -> [InstalledExtensionPackage] {
        lock.lock()
        defer { lock.unlock() }

        do {
            try ensureDirectories()
            return try fileManager.contentsOfDirectory(
                at: packagesURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == Self.packageExtension }
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
        } catch {
            return []
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
    func install(from sourceURL: URL) throws -> SkalmanExtensionBundle {
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

        let staged: SkalmanExtensionBundle
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

        var state = loadState()
        state.enabledIdentifiers.remove(identifier)
        try saveState(state)

        try fileManager.moveItem(at: staging, to: target)
        let installed = try ExtensionBundleInspector.inspect(at: target)
        recordProvenance(
            for: installed,
            sourceName: sourceURL.lastPathComponent,
            preserving: nil
        )
        return installed
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
        approving plan: ExtensionUpdatePlan
    ) throws -> SkalmanExtensionBundle {
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
            try? fileManager.removeItem(at: outgoing)
        }

        // The staged copy is the security boundary: it is the exact tree inspected, digested,
        // approved and eventually moved into place. The source may be a mutable development
        // directory, so nothing read directly from it is trusted after this copy begins.
        try fileManager.copyItem(at: sourceURL, to: staging)
        try validatePackageShape(at: staging)
        let staged: SkalmanExtensionBundle
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

        // Move the old copy aside before moving the new one in, and put it back if that fails.
        // A window in which no package exists is survivable; one in which a half-copied package
        // exists is not, which is why the new copy is validated in staging first.
        try fileManager.moveItem(at: target, to: outgoing)
        do {
            try fileManager.moveItem(at: staging, to: target)
        } catch {
            try? fileManager.moveItem(at: outgoing, to: target)
            throw error
        }
        let installed = try ExtensionBundleInspector.inspect(at: target)
        recordProvenance(
            for: installed,
            sourceName: sourceURL.lastPathComponent,
            preserving: loadProvenance(identifier: identifier)
        )
        return installed
    }

    private func installedManifest(for identifier: String) throws -> ExtensionManifest {
        let installed = packageURL(for: identifier)
        guard fileManager.fileExists(atPath: installed.path) else {
            throw ExtensionPackageStoreError.notInstalled(identifier)
        }
        return try ExtensionBundleInspector.inspect(at: installed).manifest
    }

    /// Moves an extension into Skalman's recoverable Removed directory.
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
        try? storageStore.recover(identifier: identifier, alongside: destination)
        let provenance = provenanceFileURL(identifier: identifier)
        if fileManager.fileExists(atPath: provenance.path) {
            try? fileManager.moveItem(
                at: provenance,
                to: destination
                    .deletingPathExtension()
                    .appendingPathExtension("provenance.json")
            )
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
        for bundle: SkalmanExtensionBundle,
        sourceName: String,
        preserving existing: ExtensionInstallProvenance?
    ) {
        guard let digest = ExtensionPackageDigest.compute(
            at: bundle.rootURL,
            fileManager: fileManager
        ) else {
            return
        }
        let now = Date()
        let sdkVersion = bundle.sourceURL.flatMap { source in
            [
                source.appendingPathComponent(
                    "Vendor/SkalmanExtensionKit/SDK_VERSION",
                    isDirectory: false
                ),
                source.appendingPathComponent("SDK_VERSION", isDirectory: false)
            ].lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        let record = ExtensionInstallProvenance(
            sourceName: sourceName,
            contentDigest: digest,
            sdkVersion: sdkVersion,
            firstInstalledAt: existing?.firstInstalledAt ?? now,
            lastUpdatedAt: now
        )
        try? JSONEncoder().encode(record).write(
            to: provenanceFileURL(identifier: bundle.manifest.identifier),
            options: .atomic
        )
    }

    private func loadProvenance(identifier: String) -> ExtensionInstallProvenance? {
        try? JSONDecoder().decode(
            ExtensionInstallProvenance.self,
            from: Data(contentsOf: provenanceFileURL(identifier: identifier))
        )
    }

    private func provenanceFileURL(identifier: String) -> URL {
        provenanceURL.appendingPathComponent("\(identifier).json", isDirectory: false)
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
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.formatVersion == State.currentFormatVersion else {
            return State()
        }
        return state
    }

    private func saveState(_ state: State) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
