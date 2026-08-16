import AppKit
import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class ExtensionPackageStoreTests: XCTestCase {
    private var cleanupURLs: [URL] = []

    override func tearDown() {
        cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    func testImportCopiesIntoAppOwnedStorageAndLeavesTheExtensionDisabled() throws {
        let source = try makePackage()
        let root = temporaryDirectory("store")
        let store = ExtensionPackageStore(rootURL: root)

        let installed = try store.install(from: source)

        XCTAssertEqual(installed.manifest.identifier, "com.example.installed-test")
        XCTAssertEqual(
            installed.rootURL,
            store.packageURL(for: "com.example.installed-test")
                .resolvingSymlinksInPath()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try store.inventory().map(\.identifier), ["com.example.installed-test"])
        XCTAssertEqual(store.enabledIdentifiers(), [])
        let provenance = try XCTUnwrap(try store.inventory().first?.provenance)
        XCTAssertEqual(provenance.origin, .localImport)
        XCTAssertEqual(provenance.sourceName, source.lastPathComponent)
        XCTAssertEqual(provenance.contentDigest.count, 64)
        XCTAssertTrue(provenance.presentation.contains("unsigned"))
    }

    func testFirstPartyInstallRecordsItsAppOwnedOriginAndStillStaysDisabled() throws {
        let source = try makePackage()
        let repositoryURL = try XCTUnwrap(URL(
            string: "https://github.com/everlof/threading/tree/master/Packages/Example"
        ))
        let entry = try FirstPartyExtensionCatalog.Entry(
            identifier: "com.example.installed-test",
            name: "Installed Test",
            version: "1.0.0",
            summary: "A package included with Threading.",
            repositoryURL: repositoryURL,
            packageURL: source.appendingPathExtension(
                ExtensionPackageStore.packageExtension
            )
        )
        try entry.validate(ExtensionBundleInspector.inspect(at: source))
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("first-party-store"))

        _ = try store.install(from: source, source: entry.installSource)

        XCTAssertEqual(store.enabledIdentifiers(), [])
        let provenance = try XCTUnwrap(try store.inventory().first?.provenance)
        XCTAssertEqual(provenance.formatVersion, 2)
        XCTAssertEqual(provenance.origin, .firstPartyCatalog)
        XCTAssertEqual(provenance.repositoryURL, repositoryURL)
        XCTAssertTrue(provenance.presentation.contains("From Threading"))
        XCTAssertTrue(provenance.presentation.contains("included copy"))
        XCTAssertFalse(provenance.presentation.contains("unsigned"))
    }

    func testFirstPartyCatalogRejectsUnsafeSourcesMismatchesAndUnboundedInventory() throws {
        let source = try makePackage()
        let packageURL = source.appendingPathExtension(
            ExtensionPackageStore.packageExtension
        )
        XCTAssertThrowsError(try FirstPartyExtensionCatalog.Entry(
            identifier: "com.example.installed-test",
            name: "Installed Test",
            version: "1.0.0",
            summary: "A package included with Threading.",
            repositoryURL: try XCTUnwrap(URL(string: "http://example.com/source")),
            packageURL: packageURL
        )) { error in
            XCTAssertEqual(
                error as? FirstPartyExtensionCatalog.CatalogError,
                .invalidRepositoryURL("http://example.com/source")
            )
        }

        let entry = try FirstPartyExtensionCatalog.Entry(
            identifier: "com.example.installed-test",
            name: "Different name",
            version: "1.0.0",
            summary: "A package included with Threading.",
            repositoryURL: try XCTUnwrap(URL(string: "https://example.com/source")),
            packageURL: packageURL
        )
        let inspected = try ExtensionBundleInspector.inspect(at: source)
        XCTAssertThrowsError(
            try entry.validate(inspected)
        ) { error in
            XCTAssertEqual(
                error as? FirstPartyExtensionCatalog.CatalogError,
                .packageDoesNotMatch("com.example.installed-test")
            )
        }
        XCTAssertThrowsError(try entry.validate(ExtensionUpdatePlan(
            installed: inspected.manifest,
            candidate: inspected.manifest
        ))) { error in
            XCTAssertEqual(
                error as? FirstPartyExtensionCatalog.CatalogError,
                .packageDoesNotMatch("com.example.installed-test")
            )
        }
        XCTAssertThrowsError(try FirstPartyExtensionCatalog(
            entries: Array(
                repeating: entry,
                count: FirstPartyExtensionCatalog.maximumEntries + 1
            )
        )) { error in
            XCTAssertEqual(
                error as? FirstPartyExtensionCatalog.CatalogError,
                .tooManyEntries(maximum: FirstPartyExtensionCatalog.maximumEntries)
            )
        }

        let store = ExtensionPackageStore(rootURL: temporaryDirectory("unsafe-first-party"))
        XCTAssertThrowsError(try store.install(
            from: source,
            source: .firstPartyCatalog(
                repositoryURL: try XCTUnwrap(URL(string: "http://example.com/source"))
            )
        )) { error in
            guard case .invalidFirstPartySource = error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.inventory().count, 0)
    }

    func testImportRollsBackWhenItsProvenanceCannotBeSaved() throws {
        let source = try makePackage()
        let root = temporaryDirectory("provenance-write-failure")
        let store = ExtensionPackageStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.provenanceURL.appendingPathComponent(
                "com.example.installed-test.json",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try store.install(from: source)) { error in
            guard case .provenanceCouldNotBeSaved(let identifier) =
                error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "com.example.installed-test")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.packageURL(for: "com.example.installed-test").path
            ),
            "an import without its audit provenance was reported as failed but left installed"
        )
        XCTAssertEqual(try store.inventory().count, 0)
    }

    func testEnablementPersistsSeparatelyFromThePackage() throws {
        let source = try makePackage()
        let root = temporaryDirectory("state")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(from: source)

        try store.setEnabled(true, identifier: "com.example.installed-test")

        let reopened = ExtensionPackageStore(rootURL: root)
        XCTAssertEqual(reopened.enabledIdentifiers(), ["com.example.installed-test"])
        XCTAssertEqual(try reopened.inventory().count, 1)
    }

    func testInventoryReportsTopLevelStorageFailureInsteadOfPretendingItIsEmpty() throws {
        let root = temporaryDirectory("inventory-root-is-file")
        let sentinel = Data("not a directory".utf8)
        try sentinel.write(to: root)
        let store = ExtensionPackageStore(rootURL: root)

        XCTAssertThrowsError(try store.inventory())
        XCTAssertEqual(
            try Data(contentsOf: root),
            sentinel,
            "inventory must not replace unreadable storage to manufacture an empty result"
        )
    }

    func testInventoryRefusesAnUnboundedPackageDirectoryBeforeFilteringNames() throws {
        let root = temporaryDirectory("inventory-directory-budget")
        let store = ExtensionPackageStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.packagesURL,
            withIntermediateDirectories: true
        )
        for index in 0...ExtensionPackageStore.maximumPackageDirectoryEntries {
            try Data().write(to: store.packagesURL.appendingPathComponent("unrelated-\(index)"))
        }

        XCTAssertThrowsError(try store.inventory()) { error in
            XCTAssertEqual(
                error as? BoundedDirectoryReadError,
                .exceedsLimit(
                    maximumEntries: ExtensionPackageStore.maximumPackageDirectoryEntries
                )
            )
        }
    }

    func testInventoryRefusesMorePackagesThanTheProductCanRender() throws {
        let root = temporaryDirectory("inventory-package-budget")
        let store = ExtensionPackageStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.packagesURL,
            withIntermediateDirectories: true
        )
        for index in 0...ExtensionPackageStore.maximumInstalledPackages {
            try FileManager.default.createDirectory(
                at: store.packagesURL.appendingPathComponent(
                    "com.example.package-\(index).threadingextension",
                    isDirectory: true
                ),
                withIntermediateDirectories: false
            )
        }

        XCTAssertThrowsError(try store.inventory()) { error in
            XCTAssertEqual(
                error as? BoundedDirectoryReadError,
                .exceedsLimit(maximumEntries: ExtensionPackageStore.maximumInstalledPackages)
            )
        }
    }

    func testUnreadableEnablementIsRecoveredBeforeAReplacementIsWritten() throws {
        let root = temporaryDirectory("corrupt-state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        let corrupt = Data("{".utf8)
        try corrupt.write(to: stateURL)
        let store = ExtensionPackageStore(rootURL: root)

        XCTAssertEqual(store.enabledIdentifiers(), [])
        try store.setEnabled(true, identifier: "com.example.recovered")

        let recovery = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("state.json.unreadable-") }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recovery)), corrupt)
        XCTAssertEqual(
            ExtensionPackageStore(rootURL: root).enabledIdentifiers(),
            ["com.example.recovered"]
        )
    }

    func testLegacySelfVersionedEnablementMigratesWithoutBeingMistakenForAnEnvelope() throws {
        let root = temporaryDirectory("legacy-state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(
            #"{"formatVersion":1,"enabledIdentifiers":["com.example.legacy"]}"#.utf8
        ).write(to: root.appendingPathComponent("state.json"))

        XCTAssertEqual(
            ExtensionPackageStore(rootURL: root).enabledIdentifiers(),
            ["com.example.legacy"]
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).contains { $0.lastPathComponent.hasPrefix("state.json.unreadable-") }
        )
    }

    func testInvalidIdentifierInEnablementStateIsQuarantined() throws {
        let root = temporaryDirectory("invalid-state-identifier")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        let invalid = Data(
            #"{"formatVersion":1,"enabledIdentifiers":["../../outside"]}"#.utf8
        )
        try invalid.write(to: stateURL)

        XCTAssertEqual(ExtensionPackageStore(rootURL: root).enabledIdentifiers(), [])
        let recovery = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("state.json.unreadable-") }
        )
        XCTAssertEqual(try Data(contentsOf: recovery), invalid)
    }

    func testSetEnabledRejectsAnIdentifierThatCannotBeAStorageKey() {
        let root = temporaryDirectory("invalid-set-identifier")
        let store = ExtensionPackageStore(rootURL: root)

        XCTAssertThrowsError(try store.setEnabled(true, identifier: "../../outside"))
        XCTAssertEqual(store.enabledIdentifiers(), [])
    }

    func testUnreadableProvenanceIsQuarantinedAndNeverPresentedAsTrustedFact() throws {
        let source = try makePackage()
        let root = temporaryDirectory("corrupt-provenance")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(from: source)
        let provenanceURL = store.provenanceURL.appendingPathComponent(
            "com.example.installed-test.json"
        )
        let future = Data(#"{"formatVersion":99,"value":{}}"#.utf8)
        try future.write(to: provenanceURL)

        let package = try XCTUnwrap(try store.inventory().first)
        XCTAssertNotNil(package.bundle, "audit metadata must not make a valid package disappear")
        XCTAssertNil(package.provenance, "future metadata must never be interpreted as valid")
        let recovery = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: store.provenanceURL,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(
                "com.example.installed-test.json.unreadable-"
            ) }
        )
        XCTAssertEqual(try Data(contentsOf: recovery), future)
    }

    func testFormatOneLocalProvenanceStillDecodesWithoutInventingCatalogTrust() throws {
        let digest = String(repeating: "a", count: 64)
        let data = Data("""
        {
          "formatVersion": 1,
          "origin": "localImport",
          "sourceName": "Legacy.threadingextension",
          "contentDigest": "\(digest)",
          "firstInstalledAt": 0,
          "lastUpdatedAt": 1
        }
        """.utf8)

        let provenance = try JSONDecoder().decode(
            ExtensionInstallProvenance.self,
            from: data
        )

        XCTAssertEqual(provenance.formatVersion, 1)
        XCTAssertEqual(provenance.origin, .localImport)
        XCTAssertNil(provenance.repositoryURL)
        XCTAssertTrue(provenance.presentation.contains("unsigned"))
    }

    func testDuplicateIdentifierNeverOverwritesTheInstalledPackage() throws {
        let source = try makePackage()
        let root = temporaryDirectory("duplicate")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(from: source)

        XCTAssertThrowsError(try store.install(from: source)) { error in
            guard case .alreadyInstalled(let identifier) = error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "com.example.installed-test")
        }
    }

    func testImportRejectsSymbolicLinksAnywhereInThePackage() throws {
        let source = try makePackage()
        let resources = source.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("outside"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        let store = ExtensionPackageStore(rootURL: temporaryDirectory("links"))
        XCTAssertThrowsError(try store.install(from: source)) { error in
            guard case .packageContainsSymbolicLink(let path) = error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "Resources/outside")
        }
    }

    func testUninstallMovesThePackageToRecoverableStorageAndClearsEnablement() throws {
        let source = try makePackage()
        let root = temporaryDirectory("remove")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(from: source)
        try store.setEnabled(true, identifier: "com.example.installed-test")

        let recoveredAt = try store.uninstall(identifier: "com.example.installed-test")

        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredAt.path))
        XCTAssertTrue(recoveredAt.path.hasPrefix(store.removedURL.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveredAt
                .deletingPathExtension()
                .appendingPathExtension("provenance.json")
                .path
        ))
        XCTAssertEqual(try store.inventory().count, 0)
        XCTAssertEqual(store.enabledIdentifiers(), [])
    }

    func testPrivateStoragePersistsOutsideThePackageAndIsRecoveredOnRemoval() throws {
        let source = try makePackage(capabilities: [.keyValueStorage, .cacheStorage])
        let root = temporaryDirectory("private-storage")
        let store = ExtensionPackageStore(rootURL: root)
        let installed = try store.install(from: source)
        let environment = try store.storageStore.environment(for: installed.manifest)

        let values = try ExtensionKeyValueStore(environment: environment)
        try values.set("cached answer", forKey: "answer")
        let cache = try ExtensionCache.directoryURL(environment: environment)
        try Data("disposable".utf8).write(
            to: cache.appendingPathComponent("index.txt", isDirectory: false)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installed.rootURL
                    .appendingPathComponent(ExtensionKeyValueStore.stateFileName)
                    .path
            )
        )

        let recoveredPackage = try store.uninstall(identifier: installed.manifest.identifier)
        let recoveredStorage = ExtensionStorageStore.recoveryURL(
            alongside: recoveredPackage
        )
        let recoveredValues = try ExtensionKeyValueStore(
            directoryURL: recoveredStorage.appendingPathComponent("Data", isDirectory: true)
        )
        XCTAssertEqual(
            try recoveredValues.value(forKey: "answer", as: String.self),
            "cached answer"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveredStorage
                    .appendingPathComponent("Cache/index.txt", isDirectory: false)
                    .path
            )
        )
    }

    func testStorageEnvironmentIsCapabilityGatedAndNamespaced() throws {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("storage-capabilities"))
        let plain = ExtensionManifest(
            identifier: "com.example.plain",
            name: "Plain",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/plain"
        )
        let persistent = ExtensionManifest(
            identifier: "com.example.persistent",
            name: "Persistent",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/persistent",
            capabilities: [.keyValueStorage]
        )

        XCTAssertEqual(try store.storageStore.environment(for: plain), [:])
        let environment = try store.storageStore.environment(for: persistent)
        XCTAssertNotNil(environment[ExtensionStorageEnvironment.keyValueDirectory])
        XCTAssertNil(environment[ExtensionStorageEnvironment.cacheDirectory])
        XCTAssertTrue(
            environment[ExtensionStorageEnvironment.keyValueDirectory]?
                .hasSuffix("/Data/com.example.persistent") == true
        )
    }

    func testDataVersionCommitsMonotonicallyAndIsRecoveredOnRemoval() throws {
        let root = temporaryDirectory("data-version")
        let store = ExtensionPackageStore(rootURL: root)
        let identifier = "com.example.installed-test"
        XCTAssertEqual(
            try store.storageStore.committedDataVersion(identifier: identifier),
            0
        )

        try store.storageStore.commitDataVersion(2, identifier: identifier)
        XCTAssertEqual(
            try store.storageStore.committedDataVersion(identifier: identifier),
            2
        )
        XCTAssertThrowsError(
            try store.storageStore.commitDataVersion(1, identifier: identifier)
        ) { error in
            guard case .dataVersionRollback(_, 2, 1) =
                    error as? ExtensionStorageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        _ = try store.install(from: makePackage())
        let recoveredPackage = try store.uninstall(identifier: identifier)
        let recoveredMetadata = ExtensionStorageStore.recoveryURL(
            alongside: recoveredPackage
        ).appendingPathComponent("Data/data-version.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredMetadata.path))
    }

    func testFutureDataVersionMetadataIsRefusedWithoutBeingOverwritten() throws {
        let root = temporaryDirectory("future-data-version")
        let storage = ExtensionStorageStore(rootURL: root)
        let identifier = "com.example.future-data"
        let directory = storage.dataDirectory(for: identifier)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stateURL = directory.appendingPathComponent("data-version.json")
        let future = Data(#"{"formatVersion":99,"dataVersion":7}"#.utf8)
        try future.write(to: stateURL)

        XCTAssertThrowsError(try storage.committedDataVersion(identifier: identifier))
        XCTAssertThrowsError(try storage.commitDataVersion(8, identifier: identifier))
        XCTAssertEqual(try Data(contentsOf: stateURL), future)
    }

    func testDataVersionStorageRejectsInvalidIdentifiersAndVersions() {
        let storage = ExtensionStorageStore(rootURL: temporaryDirectory("invalid-data-version"))

        XCTAssertThrowsError(
            try storage.committedDataVersion(identifier: "../../outside")
        )
        XCTAssertThrowsError(
            try storage.commitDataVersion(0, identifier: "com.example.invalid-version")
        )
        XCTAssertThrowsError(try storage.keyValues(extensionIdentifier: "../../outside"))
        XCTAssertThrowsError(
            try storage.cacheData(extensionIdentifier: "../../outside", name: "value.json")
        )
        XCTAssertThrowsError(try storage.recover(
            identifier: "../../outside",
            alongside: temporaryDirectory("outside.threadingextension")
        ))
    }

    func testOversizedCacheIsRecreatedBeforeTheExtensionStarts() throws {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("cache-quota"))
        let manifest = ExtensionManifest(
            identifier: "com.example.cache-quota",
            name: "Cache Quota",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/cache-quota",
            capabilities: [.cacheStorage]
        )
        let cache = store.storageStore.cacheDirectory(for: manifest.identifier)
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let oversized = cache.appendingPathComponent(".hidden-index", isDirectory: false)
        _ = FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ExtensionStorageStore.maximumCacheBytes + 1))
        try handle.close()

        let environment = try store.storageStore.environment(for: manifest)

        XCTAssertEqual(
            environment[ExtensionStorageEnvironment.cacheDirectory],
            cache.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testManagerSuppliesDeclaredStorageDirectoriesToTheProcess() async throws {
        let source = try makePackage(
            capabilities: [.keyValueStorage, .cacheStorage],
            requiresStorageEnvironment: true
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-storage"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let becameRunning = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }
        XCTAssertTrue(becameRunning)
    }

    func testManagerStartsAndStopsAnEnabledInstalledExtension() async throws {
        let source = try makePackage()
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let becameRunning = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }
        XCTAssertTrue(becameRunning)
        XCTAssertNotNil(manager.registration(for: "com.example.installed-test"))

        try manager.setEnabled(false, identifier: "com.example.installed-test")
        XCTAssertEqual(manager.installedExtensions.first?.status, .disabled)
        XCTAssertNil(manager.registration(for: "com.example.installed-test"))
        manager.terminateAll()
    }

    func testExtensionsSettingsUsesTheThemeBoundaryAndExposesImportAndEnableControls() throws {
        let source = try makePackage(tool: ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up one value."
        ))
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("settings"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let controller = ExtensionsPreferencesViewController(manager: manager)
        _ = controller.view
        let window = settingsWindow(controller.view)
        window.contentView?.layoutSubtreeIfNeeded()

        var identifiers = Set(
            descendants(in: controller.view).compactMap { $0.accessibilityIdentifier() }
        )
        XCTAssertTrue(identifiers.contains("settings.extensions.import"))
        XCTAssertTrue(identifiers.contains(
            "settings.extensions.enabled.com.example.installed-test"
        ))
        let card = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier()
                    == "settings.extensions.card.com.example.installed-test"
            }
        )
        XCTAssertTrue(card.accessibilityPerformPress())
        window.contentView?.layoutSubtreeIfNeeded()
        identifiers = Set(
            descendants(in: controller.view).compactMap { $0.accessibilityIdentifier() }
        )
        // Updating is reachable from the page. Without it the capability delta is computed and
        // never shown, which is the same as not computing it.
        XCTAssertTrue(identifiers.contains(
            "settings.extensions.update.com.example.installed-test"
        ))
        let labels = descendants(in: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Agent-tool extension"))
        XCTAssertTrue(labels.contains("Agent tools"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testExtensionsSettingsListsAnAppOwnedExtensionWithSourceAndInstallControls() throws {
        let source = try makePackage()
        let container = temporaryDirectory("first-party-settings")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let package = container.appendingPathComponent(
            "com.example.installed-test.threadingextension",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: source, to: package)
        let entry = try FirstPartyExtensionCatalog.Entry(
            identifier: "com.example.installed-test",
            name: "Installed Test",
            version: "1.0.0",
            summary: "A package included with Threading.",
            repositoryURL: try XCTUnwrap(URL(string: "https://example.com/source")),
            packageURL: package
        )
        let catalog = try FirstPartyExtensionCatalog(entries: [entry])
        let manager = ExtensionManager(
            store: ExtensionPackageStore(rootURL: temporaryDirectory("catalog-settings-store"))
        )
        let controller = ExtensionsPreferencesViewController(
            manager: manager,
            firstPartyCatalog: catalog
        )
        _ = controller.view
        let window = settingsWindow(controller.view)
        window.contentView?.layoutSubtreeIfNeeded()

        let identifiers = Set(descendants(in: controller.view).compactMap {
            $0.accessibilityIdentifier()
        })
        XCTAssertTrue(identifiers.contains(
            "settings.extensions.first-party.source.com.example.installed-test"
        ))
        XCTAssertTrue(identifiers.contains(
            "settings.extensions.first-party.install.com.example.installed-test"
        ))
        let labels = descendants(in: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Installed Test"))
        XCTAssertTrue(labels.contains {
            $0.contains("Version 1.0.0 · Available from Threading")
        })
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testExtensionsSettingsShowsProvidedAndConsumedServiceAvailability() throws {
        let source = try makePackage(
            service: .init(
                id: "status",
                version: 2,
                title: "Status",
                description: "Returns status."
            ),
            serviceDependencies: [
                .init(
                    providerIdentifier: "com.example.other",
                    serviceID: "status",
                    required: true
                )
            ]
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("settings-services"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let controller = ExtensionsPreferencesViewController(manager: manager)
        _ = controller.view
        let window = settingsWindow(controller.view)
        window.contentView?.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier()
                    == "settings.extensions.card.com.example.installed-test"
            }
        )
        XCTAssertTrue(card.accessibilityPerformPress())
        window.contentView?.layoutSubtreeIfNeeded()
        let labels = descendants(in: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains("Provides services"))
        XCTAssertTrue(labels.contains("Status v2"))
        XCTAssertTrue(labels.contains("Uses services"))
        XCTAssertTrue(labels.contains(
            "com.example.other / status v1 · required · unavailable"
        ))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testExtensionsSettingsPreservesContributedHostFieldsInVirtualPage() throws {
        let source = try makePackage()
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("settings-host-fields"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let field = ExtensionSettingField(
            id: "host-label",
            title: "Host label",
            control: .text(
                defaultValue: "Build",
                placeholder: "Build",
                maximumLength: 40
            )
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.settings-host",
            name: "Settings Host",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/settings-host",
            capabilities: [.settings],
            settings: .init(sections: [
                .init(
                    id: "extensions-host",
                    page: .extensions,
                    title: "Host additions",
                    fields: [field]
                )
            ])
        )
        _ = ExtensionManager.shared
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer { ExtensionSettingsRegistry.shared.replace(enabledManifests: []) }

        let controller = ExtensionsPreferencesViewController(manager: manager)
        _ = controller.view
        let window = settingsWindow(controller.view)
        window.contentView?.layoutSubtreeIfNeeded()
        let identifiers = Set(descendants(in: controller.view).compactMap {
            $0.accessibilityIdentifier()
        })

        XCTAssertTrue(identifiers.contains(
            "settings.extension.com.example.settings-host.host-label"
        ))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testStressExtensionsPreferencesWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["THREADING_EXTENSIONS_PREFERENCES_STRESS"] == "1" else {
            throw XCTSkip(
                "Set THREADING_EXTENSIONS_PREFERENCES_STRESS=1 to run the installed-package sweep."
            )
        }
        let packageCount = min(
            Int(environment["THREADING_EXTENSIONS_PREFERENCES_STRESS_PACKAGES"] ?? "")
                ?? ExtensionPackageStore.maximumInstalledPackages,
            ExtensionPackageStore.maximumInstalledPackages
        )
        let themeID = AppThemeID(
            environment["THREADING_EXTENSIONS_PREFERENCES_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(AppThemeLibrary.theme(withID: themeID))
        _ = NSApplication.shared
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(theme)
        defer { AppThemeLibrary.apply(previousTheme) }

        let store = ExtensionPackageStore(
            rootURL: temporaryDirectory("settings-stress")
        )
        try makeStressPackages(count: packageCount, in: store)
        let managerStarted = DispatchTime.now().uptimeNanoseconds
        let manager = ExtensionManager(store: store)
        let managerReady = DispatchTime.now().uptimeNanoseconds
        defer { manager.terminateAll() }

        let memoryBefore = physicalFootprintBytes()
        let loadStarted = DispatchTime.now().uptimeNanoseconds
        let controller = ExtensionsPreferencesViewController(manager: manager)
        _ = controller.view
        let loadReady = DispatchTime.now().uptimeNanoseconds
        let window = settingsWindow(controller.view)
        window.appearance = theme.mode.appearance ?? NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded()
        let layoutReady = DispatchTime.now().uptimeNanoseconds

        let initialViews = descendants(in: controller.view).count
        let initialRows = controller.virtualRowCountForTesting
        let initialMaterialized = controller.materializedRowCountForTesting
        let card = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier().hasPrefix("settings.extensions.card.")
            }
        )
        let disclosureStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(card.accessibilityPerformPress())
        window.contentView?.layoutSubtreeIfNeeded()
        let disclosureReady = DispatchTime.now().uptimeNanoseconds

        let scroll = try XCTUnwrap(
            descendants(in: controller.view).compactMap { $0 as? NSScrollView }.first
        )
        let scrollStarted = DispatchTime.now().uptimeNanoseconds
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        scroll.contentView.scroll(
            to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentView.bounds.height))
        )
        scroll.reflectScrolledClipView(scroll.contentView)
        window.contentView?.layoutSubtreeIfNeeded()
        let scrollReady = DispatchTime.now().uptimeNanoseconds
        let originBeforeRefresh = scroll.contentView.bounds.origin
        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(ExtensionsDidChange())
        let refreshRendered = DispatchTime.now().uptimeNanoseconds
        window.contentView?.layoutSubtreeIfNeeded()
        let refreshReady = DispatchTime.now().uptimeNanoseconds
        let originAfterRefresh = scroll.contentView.bounds.origin
        let finalViews = descendants(in: controller.view).count
        let memoryAfter = physicalFootprintBytes()
        let memoryDelta = memoryAfter >= memoryBefore ? memoryAfter - memoryBefore : 0

        XCTAssertEqual(manager.installedExtensions.count, packageCount)
        XCTAssertGreaterThan(initialRows, 0)
        XCTAssertGreaterThan(initialMaterialized, 0)
        XCTAssertLessThanOrEqual(initialMaterialized, initialRows)
        XCTAssertEqual(originAfterRefresh.x, originBeforeRefresh.x, accuracy: 0.5)
        XCTAssertEqual(originAfterRefresh.y, originBeforeRefresh.y, accuracy: 0.5)
        print(
            "THREADING_PERF extensions-preferences "
                + "theme=\(theme.id.rawValue) packages=\(packageCount) "
                + "manager_ms=\(milliseconds(managerReady - managerStarted)) "
                + "load_ms=\(milliseconds(loadReady - loadStarted)) "
                + "layout_ms=\(milliseconds(layoutReady - loadReady)) "
                + "disclosure_ms=\(milliseconds(disclosureReady - disclosureStarted)) "
                + "scroll_to_end_ms=\(milliseconds(scrollReady - scrollStarted)) "
                + "hot_refresh_render_ms=\(milliseconds(refreshRendered - refreshStarted)) "
                + "hot_refresh_layout_ms=\(milliseconds(refreshReady - refreshRendered)) "
                + "virtual_rows=\(initialRows) materialized_rows=\(initialMaterialized) "
                + "initial_views=\(initialViews) final_views=\(finalViews) "
                + "footprint_delta_mb=\(megabytes(memoryDelta))"
        )
    }

    func testExtensionImageResourcesStayInsideTheInstalledPackage() throws {
        let source = try makePackage()
        let resources = source.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: resources.appendingPathComponent("icon.png")
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("image-resources"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)

        XCTAssertNotNil(manager.imageResourceURL(
            relativePath: "Resources/icon.png",
            extensionIdentifier: "com.example.installed-test"
        ))
        XCTAssertNil(manager.imageResourceURL(
            relativePath: "../outside.png",
            extensionIdentifier: "com.example.installed-test"
        ))
        XCTAssertNil(manager.imageResourceURL(
            relativePath: "/tmp/outside.png",
            extensionIdentifier: "com.example.installed-test"
        ))
    }

    func testExtensionImageDecodeRechecksBytesAndDecodedDimensions() throws {
        let source = try makePackage()
        let resources = source.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        try pngData(width: 16, height: 16).write(
            to: resources.appendingPathComponent("accepted.png")
        )
        try pngData(
            width: ExtensionImageResourceLoader.maximumPixelDimension + 1,
            height: 1
        ).write(to: resources.appendingPathComponent("too-wide.png"))

        let store = ExtensionPackageStore(rootURL: temporaryDirectory("image-decode-policy"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let acceptedURL = try XCTUnwrap(manager.imageResourceURL(
            relativePath: "Resources/accepted.png",
            extensionIdentifier: "com.example.installed-test"
        ))
        let oversizedDimensionsURL = try XCTUnwrap(manager.imageResourceURL(
            relativePath: "Resources/too-wide.png",
            extensionIdentifier: "com.example.installed-test"
        ))

        XCTAssertNotNil(ExtensionImageResourceLoader.image(at: acceptedURL))
        XCTAssertNil(ExtensionImageResourceLoader.image(at: oversizedDimensionsURL))

        // The URL lookup is only a cheap refusal. The authoritative read must still notice if
        // the package changes between resolution and decode.
        let handle = try FileHandle(forWritingTo: acceptedURL)
        try handle.truncate(atOffset: UInt64(ExtensionImageResourceLoader.maximumBytes + 1))
        try handle.close()
        XCTAssertNil(ExtensionImageResourceLoader.image(at: acceptedURL))
    }

    func testExtensionsSettingsLetsTheUserResolveIdentityResolverConflicts() throws {
        let source = try makePackage()
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("identity-settings"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let suite = "ExtensionIdentitySettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ExtensionIdentityResolverRegistry(defaults: defaults)
        let componentRegistry = ComponentCustomizationRegistry(
            selectionDefaults: defaults
        )
        try componentRegistry.register(HostComponentContracts.sidebarSessionIdentity)

        for (index, identifier) in [
            "com.example.installed-test",
            "com.example.other"
        ].enumerated() {
            try registry.replace(
                .init(providerIcons: [
                    .init(providerID: "codex", image: .systemSymbol("terminal"))
                ]),
                from: .init(
                    extensionIdentifier: identifier,
                    processGeneration: "one",
                    order: index
                )
            )
            try componentRegistry.replacePatches(
                [
                    .init(
                        id: "identity-\(index)",
                        target: .sessionIdentity(),
                        replacement: .stack(
                            axis: .horizontal,
                            spacing: .tight,
                            children: [
                                .image(
                                    ExtensionSessionIdentityAsset.providerImage,
                                    role: .identity,
                                    accessibilityLabel: "Provider"
                                )
                            ]
                        )
                    )
                ],
                from: .init(
                    extensionIdentifier: identifier,
                    processGeneration: "one",
                    order: index
                )
            )
        }

        let controller = ExtensionsPreferencesViewController(
            manager: manager,
            identityRegistry: registry,
            componentRegistry: componentRegistry
        )
        _ = controller.view
        let window = settingsWindow(controller.view)
        window.contentView?.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == "settings.extensions.identity.provider"
            } as? ThemedPopUp
        )
        let otherIndex = try XCTUnwrap((0..<menu.numberOfItems).first {
            menu.item(at: $0)?.representedValue as? String == "com.example.other"
        })
        menu.chooseItem(at: otherIndex)

        XCTAssertEqual(
            registry.selectedProviderExtensionIdentifier,
            "com.example.other"
        )
        XCTAssertEqual(
            registry.providerIcon(providerID: "codex")?.extensionIdentifier,
            "com.example.other"
        )

        window.contentView?.layoutSubtreeIfNeeded()
        let sessionMenu = try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == "settings.extensions.identity.session"
            } as? ThemedPopUp
        )
        let sessionIndex = try XCTUnwrap((0..<sessionMenu.numberOfItems).first {
            sessionMenu.item(at: $0)?.representedValue as? String
                == "com.example.other"
        })
        sessionMenu.chooseItem(at: sessionIndex)
        XCTAssertEqual(
            componentRegistry.selectedReplacementExtensionIdentifier(
                for: .sidebarSessionIdentity
            ),
            "com.example.other"
        )

        let restoredRegistry = ComponentCustomizationRegistry(
            selectionDefaults: defaults
        )
        XCTAssertEqual(
            restoredRegistry.selectedReplacementExtensionIdentifier(
                for: .sidebarSessionIdentity
            ),
            "com.example.other"
        )
    }

    func testManagerPublishesDeclaredToolsThenRoutesTheRuntimeRegistration() async throws {
        let tool = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up one value."
        )
        let response = ExtensionMCPToolResponse(
            requestID: "manager-tool-request",
            text: "extension answer"
        )
        let source = try makePackage(tool: tool, toolResponse: response)
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-tools"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        let provider = ExtensionMCPToolProvider(manager: manager)
        let groupID = "extension.com.example.installed-test"
        let wasEnabled = AppSettings.shared.isToolGroupEnabled(groupID)
        AppSettings.shared.setToolGroup(groupID, enabled: true)
        defer {
            AppSettings.shared.setToolGroup(groupID, enabled: wasEnabled)
            manager.terminateAll()
        }

        XCTAssertEqual(manager.mcpToolInventory.first?.declaredTools, [tool])
        XCTAssertEqual(manager.mcpToolInventory.first?.registeredTools, [])
        XCTAssertEqual(provider.groups.first?.tools.map(\.name), [
            "ext__com__example__installed-test__lookup"
        ])
        XCTAssertEqual(provider.groups.first?.tools.first?.inputSchema, .object([
            "type": .string("object"),
            "properties": .object([:])
        ]))
        XCTAssertFalse(try XCTUnwrap(provider.groups.first).isAvailable)

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let registered = await waitUntil {
            manager.mcpToolInventory.first?.registeredTools == [tool]
        }
        XCTAssertTrue(registered)
        XCTAssertTrue(try XCTUnwrap(provider.groups.first).isAvailable)

        let result = await withCheckedContinuation { continuation in
            let routed = manager.invokeMCPTool(
                named: tool.qualifiedName(
                    extensionIdentifier: "com.example.installed-test"
                ),
                arguments: ExtensionJSONValue.object(["key": .string("answer")]),
                for: SessionID(),
                requestID: response.requestID
            ) {
                continuation.resume(returning: $0)
            }
            XCTAssertTrue(routed)
        }
        XCTAssertEqual(try result.get(), response)
    }

    func testManagerRegistersRoutesAndRemovesExtensionCommands() async throws {
        let command = ExtensionCommand(
            id: "open-build",
            title: "Open Build",
            scope: .project,
            defaultShortcut: .init(
                key: "b",
                modifiers: [.option, .command]
            )
        )
        let response = ExtensionCommandResponse(
            requestID: "manager-command-request",
            commandID: command.id,
            message: "Opened build."
        )
        let source = try makePackage(
            command: command,
            commandResponse: response
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-commands"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let qualifiedID = CommandRegistry.qualifiedID(
            extensionIdentifier: "com.example.installed-test",
            commandID: command.id
        )
        let registered = await waitUntil {
            CommandRegistry.shared.command(id: qualifiedID) != nil
        }
        XCTAssertTrue(registered)

        let result = await withCheckedContinuation { continuation in
            let routed = manager.invokeCommand(
                extensionIdentifier: "com.example.installed-test",
                commandID: command.id,
                context: .init(projectID: "project-1"),
                requestID: response.requestID,
                completion: { continuation.resume(returning: $0) }
            )
            XCTAssertTrue(routed)
        }
        XCTAssertEqual(try result.get(), response)

        try manager.setEnabled(false, identifier: "com.example.installed-test")
        XCTAssertNil(CommandRegistry.shared.command(id: qualifiedID))
    }

    func testManagerPublishesRoutesAndRemovesExtensionPanels() async throws {
        let panel = ExtensionPanel(
            id: "build-status",
            title: "Build Status",
            root: .status("Ready", role: .neutral)
        )
        let updated = ExtensionPanel(
            id: panel.id,
            title: panel.title,
            root: .status("Passed", role: .positive)
        )
        let source = try makePackage(
            panel: panel,
            panelResponse: .init(
                requestID: "replaced-at-runtime",
                panel: updated,
                message: "Build refreshed."
            )
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-panels"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let registered = await waitUntil {
            manager.extensionPanelInventory.map(\.panel) == [panel]
        }
        XCTAssertTrue(registered)
        let inventory = try XCTUnwrap(manager.extensionPanelInventory.first)
        XCTAssertEqual(inventory.extensionName, "Installed Test")
        XCTAssertFalse(inventory.processGeneration.isEmpty)

        let result = await withCheckedContinuation { continuation in
            let routed = manager.invokePanelAction(
                extensionIdentifier: inventory.extensionIdentifier,
                panelID: panel.id,
                actionID: "refresh",
                context: .init(projectID: "project-1", sessionID: "session-1"),
                completion: { continuation.resume(returning: $0) }
            )
            XCTAssertTrue(routed)
        }
        let response = try result.get()
        XCTAssertEqual(response.panel, updated)
        XCTAssertEqual(response.message, "Build refreshed.")

        try manager.setEnabled(false, identifier: inventory.extensionIdentifier)
        XCTAssertEqual(manager.extensionPanelInventory, [])
        XCTAssertNil(manager.registeredPanel(
            extensionIdentifier: inventory.extensionIdentifier,
            panelID: panel.id
        ))
    }

    func testManagerSuppliesPersistsAndStreamsHostRenderedSettings() async throws {
        let field = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "status",
                    title: "Status",
                    sections: [
                        .init(id: "display", fields: [field])
                    ]
                )
            ]
        )
        let source = try makePackage(
            capabilities: [.keyValueStorage],
            settings: settings,
            settingsResponseIDs: [field.id]
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-settings"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let dataDirectory = store.storageStore.dataDirectory(
            for: "com.example.installed-test"
        )
        let initialSyncArrived = await waitUntil {
            FileManager.default.fileExists(
                atPath: dataDirectory.appendingPathComponent("settings-requests.jsonl").path
            )
        }
        XCTAssertTrue(initialSyncArrived)
        XCTAssertEqual(
            manager.settingValue(
                extensionIdentifier: "com.example.installed-test",
                field: field
            ),
            .bool(true)
        )

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            manager.setSetting(
                extensionIdentifier: "com.example.installed-test",
                settingID: field.id,
                value: .bool(false)
            ) {
                continuation.resume(returning: $0)
            }
        }
        try result.get()
        XCTAssertEqual(
            manager.settingValue(
                extensionIdentifier: "com.example.installed-test",
                field: field
            ),
            .bool(false)
        )

        let requests = try String(
            contentsOf: dataDirectory.appendingPathComponent("settings-requests.jsonl"),
            encoding: .utf8
        )
        XCTAssertTrue(requests.contains(#""show-status":true"#))
        XCTAssertTrue(requests.contains(#""show-status":false"#))
        let launchValues = try String(
            contentsOf: dataDirectory.appendingPathComponent("launch-settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(launchValues.contains(#""show-status":true"#))

        try manager.setEnabled(false, identifier: "com.example.installed-test")
        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let relaunchedWithPersistedValue = await waitUntil {
            (try? String(
                contentsOf: dataDirectory.appendingPathComponent("launch-settings.json"),
                encoding: .utf8
            ))?.contains(#""show-status":false"#) == true
        }
        XCTAssertTrue(relaunchedWithPersistedValue)
    }

    func testManagerRollsBackASettingRejectedByTheRunningExtension() async throws {
        let field = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "status",
                    title: "Status",
                    sections: [.init(id: "display", fields: [field])]
                )
            ]
        )
        let source = try makePackage(
            capabilities: [.keyValueStorage],
            settings: settings,
            settingsResponseIDs: [field.id],
            settingsResponseError: "Rejected by the test extension."
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-settings-reject"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let running = await waitUntil {
            let item = manager.installedExtensions.first {
                $0.identifier == "com.example.installed-test"
            }
            if case .running = item?.status {
                return true
            }
            return false
        }
        XCTAssertTrue(running)

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            manager.setSetting(
                extensionIdentifier: "com.example.installed-test",
                settingID: field.id,
                value: .bool(false)
            ) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(
            manager.settingValue(
                extensionIdentifier: "com.example.installed-test",
                field: field
            ),
            .bool(true)
        )
    }

    func testManagerRoutesABrokeredServiceToTheRegisteredProviderProcess() async throws {
        let service = ExtensionServiceDefinition(
            id: "status",
            version: 2,
            title: "Status",
            description: "Returns current status."
        )
        let response = ExtensionServiceResponse(
            requestID: "service-request",
            serviceID: service.id,
            serviceVersion: service.version,
            value: .object(["state": .string("passed")])
        )
        let source = try makePackage(
            service: service,
            serviceResponse: response
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-service"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let running = await waitUntil {
            manager.registration(for: "com.example.installed-test")?.services == [service]
        }
        XCTAssertTrue(running)

        let result = await withCheckedContinuation { continuation in
            manager.invokeService(
                providerIdentifier: "com.example.installed-test",
                serviceID: service.id,
                serviceVersion: service.version,
                callerExtensionIdentifier: "com.example.consumer",
                arguments: .object(["projectID": .string("project-1")]),
                completion: { continuation.resume(returning: $0) }
            )
        }
        let received = try result.get()
        XCTAssertEqual(received.serviceID, response.serviceID)
        XCTAssertEqual(received.serviceVersion, response.serviceVersion)
        XCTAssertEqual(received.value, response.value)
        XCTAssertNil(received.error)

        let dependency = ExtensionServiceDependency(
            providerIdentifier: "com.example.installed-test",
            serviceID: service.id,
            version: service.version
        )
        XCTAssertTrue(manager.isServiceAvailable(dependency))
        try manager.setEnabled(false, identifier: "com.example.installed-test")
        XCTAssertFalse(manager.isServiceAvailable(dependency))
        let unavailable = await withCheckedContinuation { continuation in
            manager.invokeService(
                providerIdentifier: dependency.providerIdentifier,
                serviceID: dependency.serviceID,
                serviceVersion: dependency.version,
                callerExtensionIdentifier: "com.example.consumer",
                arguments: .emptyObject,
                completion: { continuation.resume(returning: $0) }
            )
        }
        XCTAssertThrowsError(try unavailable.get())
    }

    func testHostClientCallsAProviderThroughTheRealLoopbackBroker() async throws {
        let definition = ExtensionServiceDefinition(
            id: "status",
            title: "Status",
            description: "Returns current status."
        )
        let response = ExtensionServiceResponse(
            requestID: "fixture-replaced-at-runtime",
            serviceID: definition.id,
            serviceVersion: definition.version,
            value: .object(["state": .string("passed")])
        )
        let source = try makePackage(
            service: definition,
            serviceResponse: response
        )
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("loopback-service"))
        _ = try store.install(from: source)
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        let registry = ComponentCustomizationRegistry()
        let host = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            serviceRouter: manager
        )
        await withCheckedContinuation { continuation in
            host.start(registry: registry) {
                continuation.resume()
            }
        }
        defer { host.stop() }

        try manager.setEnabled(true, identifier: "com.example.installed-test")
        let providerRegistered = await waitUntil {
            manager.registration(for: "com.example.installed-test")?.services == [definition]
        }
        XCTAssertTrue(providerRegistered)

        let dependency = ExtensionServiceDependency(
            providerIdentifier: "com.example.installed-test",
            serviceID: definition.id
        )
        let authorization = try XCTUnwrap(try host.authorize(
            extensionIdentifier: "com.example.consumer",
            processGeneration: "consumer-one",
            order: 0,
            capabilities: [.servicesConsume],
            serviceDependencies: [dependency]
        ))
        let value = try await ExtensionHostClient(
            connection: authorization.connection
        ).callService(
            providerIdentifier: dependency.providerIdentifier,
            serviceID: dependency.serviceID,
            version: dependency.version,
            arguments: .object(["projectID": .string("project-1")])
        )
        XCTAssertEqual(value, .object(["state": .string("passed")]))
    }

    func testHostClientCanOnlyCallItsOwnCompanionThroughTheCapabilityBroker() async throws {
        let registry = ComponentCustomizationRegistry()
        let router = RecordingCompanionRouter()
        let host = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1")),
            companionRouter: router
        )
        await withCheckedContinuation { continuation in
            host.start(registry: registry) {
                continuation.resume()
            }
        }
        defer { host.stop() }

        let authorization = try XCTUnwrap(try host.authorize(
            extensionIdentifier: "com.example.consumer",
            processGeneration: "consumer-one",
            order: 0,
            capabilities: [.companionOperations]
        ))
        let value = try await ExtensionHostClient(
            connection: authorization.connection
        ).callCompanion(
            "simulator",
            operation: "device-status",
            arguments: .object(["device": .string("iPhone 18")])
        )

        XCTAssertEqual(value, .object(["state": .string("booted")]))
        XCTAssertEqual(router.extensionIdentifier, "com.example.consumer")
        XCTAssertEqual(router.companionID, "simulator")
        XCTAssertEqual(router.operationID, "device-status")
        XCTAssertEqual(
            router.arguments,
            .object(["device": .string("iPhone 18")])
        )

        let underprivileged = try XCTUnwrap(try host.authorize(
            extensionIdentifier: "com.example.underprivileged",
            processGeneration: "consumer-two",
            order: 1,
            capabilities: [.hostProjectsRead]
        ))
        do {
            _ = try await ExtensionHostClient(
                connection: underprivileged.connection
            ).callCompanion("simulator", operation: "device-status")
            XCTFail("the route accepted a generation without companions.invoke")
        } catch let error as ExtensionHostClientError {
            guard case .rejected(let status, _) = error else {
                return XCTFail("unexpected client error: \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    func testDeclaredExtensionToolsBecomeASettingsGroupWithQualifiedNames() {
        let tool = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up one value."
        )
        let inventory = ExtensionMCPToolInventory(
            extensionIdentifier: "com.example.cache",
            extensionName: "Cache Helper",
            isExtensionEnabled: true,
            declaredTools: [tool],
            registeredTools: [tool]
        )

        let group = MCPToolCatalog.externalGroup(externalGroup(for: inventory))

        XCTAssertEqual(group.id, "extension.com.example.cache")
        XCTAssertEqual(group.title, "Cache Helper")
        XCTAssertEqual(group.tools.map(\.name), [
            "ext__com__example__cache__lookup"
        ])
        XCTAssertEqual(group.tools.map(\.title), ["Lookup"])
    }

    func testExtensionToolGroupRendersBesideBuiltInToolsWithinThemeBoundary() {
        let tool = ExtensionMCPTool(
            id: "lookup",
            title: "Lookup",
            description: "Look up one value."
        )
        let inventory = ExtensionMCPToolInventory(
            extensionIdentifier: "com.example.cache",
            extensionName: "Cache Helper",
            isExtensionEnabled: true,
            declaredTools: [tool],
            registeredTools: [tool]
        )
        let group = MCPToolCatalog.externalGroup(externalGroup(for: inventory))
        let controller = ToolsPreferencesViewController(
            groups: [MCPToolCatalog.display, group]
        )
        let window = settingsWindow(controller.view, width: 760, height: 2_400)
        window.contentView?.layoutSubtreeIfNeeded()

        for identifier in [
            "settings.tools.group.\(MCPToolCatalog.display.id)",
            "settings.tools.group.\(group.id)"
        ] {
            let disclosure = descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == identifier
            }
            XCTAssertTrue(try XCTUnwrap(disclosure).accessibilityPerformPress())
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let labels = descendants(in: controller.view)
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(MCPToolCatalog.display.title))
        XCTAssertTrue(labels.contains(group.title))
        XCTAssertTrue(labels.contains("Lookup"))
        XCTAssertTrue(labels.contains("ext__com__example__cache__lookup"))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
        withExtendedLifetime(window) {}
    }

    func testExtensionSettingsAddStablePagesAndSectionsAndPersistHostOwnedValues() throws {
        let ownField = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        let hostField = ExtensionSettingField(
            id: "refresh-label",
            title: "Refresh label",
            control: .text(
                defaultValue: "Build",
                placeholder: "Build",
                maximumLength: 40
            )
        )
        let settings = ExtensionSettingsContribution(
            pages: [
                .init(
                    id: "ci",
                    title: "CI",
                    sections: [
                        .init(id: "display", fields: [ownField])
                    ]
                )
            ],
            sections: [
                .init(
                    id: "general",
                    page: .general,
                    title: "CI",
                    fields: [hostField]
                )
            ]
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.settings-test",
            name: "Settings Test",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/settings",
            capabilities: [.settings],
            settings: settings
        )
        try manifest.validate()

        // Initialise the production singleton before replacing the isolated registry. Its
        // manifest inventory sync is otherwise triggered lazily by the first rendered control.
        _ = ExtensionManager.shared
        let builtInIDs = SettingsPages.builtIn.map(\.id)
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer {
            ExtensionSettingsRegistry.shared.replace(enabledManifests: [])
        }

        XCTAssertEqual(SettingsPages.builtIn.map(\.id), builtInIDs)
        let pageID = ExtensionSettingsRegistry.qualifiedPageID(
            extensionIdentifier: manifest.identifier,
            localPageID: "ci"
        )
        XCTAssertNotNil(SettingsPages.page(id: pageID))
        XCTAssertEqual(SettingsPages.page(id: SettingsPages.generalID)?.title, "General")

        let general = SettingsUI.page([], hostPage: .general)
        let generalWindow = settingsWindow(general)
        generalWindow.contentView?.layoutSubtreeIfNeeded()
        let generalIDs = Set(descendants(in: general).compactMap {
            $0.accessibilityIdentifier()
        })
        XCTAssertTrue(generalIDs.contains(
            "settings.extension.com.example.settings-test.refresh-label"
        ))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: general), [])

        let extensionPage = try XCTUnwrap(SettingsPages.page(id: pageID)).make()
        _ = extensionPage.view
        let extensionWindow = settingsWindow(extensionPage.view)
        extensionWindow.contentView?.layoutSubtreeIfNeeded()
        let extensionIDs = Set(descendants(in: extensionPage.view).compactMap {
            $0.accessibilityIdentifier()
        })
        XCTAssertTrue(extensionIDs.contains(
            "settings.extension.com.example.settings-test.show-status"
        ))
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: extensionPage.view), [])

        let root = temporaryDirectory("host-settings-values")
        let values = ExtensionSettingsValueStore(rootURL: root)
        try values.set(
            .bool(false),
            field: ownField,
            extensionIdentifier: manifest.identifier
        )
        let reopened = ExtensionSettingsValueStore(rootURL: root)
        XCTAssertEqual(
            try reopened.value(
                extensionIdentifier: manifest.identifier,
                field: ownField
            ),
            .bool(false)
        )
        XCTAssertNil(
            try ExtensionStorageStore(
                rootURL: temporaryDirectory("settings-capability-boundary")
            ).environment(for: manifest)[ExtensionSettingsEnvironment.valuesJSON]
        )
        withExtendedLifetime((generalWindow, extensionWindow)) {}
    }

    func testUnreadableExtensionSettingsAreRecoveredBeforeAnEdit() throws {
        let root = temporaryDirectory("corrupt-extension-settings")
        let identifier = "com.example.settings-recovery"
        let directory = root.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let valuesURL = directory.appendingPathComponent("values.json")
        let corrupt = Data("{".utf8)
        try corrupt.write(to: valuesURL)
        let field = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        let store = ExtensionSettingsValueStore(rootURL: root)

        XCTAssertEqual(
            try store.value(extensionIdentifier: identifier, field: field),
            .bool(true)
        )
        try store.set(.bool(false), field: field, extensionIdentifier: identifier)

        let recovery = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("values.json.unreadable-") }
        )
        XCTAssertEqual(try Data(contentsOf: recovery), corrupt)
        XCTAssertEqual(
            try ExtensionSettingsValueStore(rootURL: root).value(
                extensionIdentifier: identifier,
                field: field
            ),
            .bool(false)
        )
    }

    func testExtensionSettingsRejectPathLikeIdentifiers() throws {
        let root = temporaryDirectory("invalid-settings-identifier")
        let field = ExtensionSettingField(
            id: "show-status",
            title: "Show status",
            control: .toggle(defaultValue: true)
        )
        let store = ExtensionSettingsValueStore(rootURL: root)

        XCTAssertThrowsError(
            try store.set(
                .bool(false),
                field: field,
                extensionIdentifier: "../../outside"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMCPCoreDependsOnlyOnTheExternalProviderBoundary() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Threading/Core/MCP", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0) }.joined(separator: "\n")

        XCTAssertFalse(source.contains("import ThreadingExtensionKit"))
        XCTAssertFalse(source.contains("ExtensionManager"))
        XCTAssertFalse(source.contains("ExtensionJSONValue"))
    }

    private func externalGroup(
        for inventory: ExtensionMCPToolInventory
    ) -> MCPExternalToolGroup {
        let tool = inventory.declaredTools[0]
        return MCPExternalToolGroup(
            id: inventory.groupID,
            title: inventory.extensionName,
            summary: "Tools contributed by the \(inventory.extensionName) extension.",
            symbol: "puzzlepiece.extension",
            tools: [
                MCPExternalTool(
                    name: tool.qualifiedName(
                        extensionIdentifier: inventory.extensionIdentifier
                    ),
                    title: tool.title,
                    detail: tool.description,
                    symbol: "wrench.and.screwdriver",
                    description: tool.description,
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                )
            ],
            instruction: "Use the contributed tools as described.",
            isAvailable: inventory.isExtensionEnabled
        )
    }

    // MARK: - Updates

    // MARK: - Packaging

    func testThePackagerAssemblesAnInstallablePackageFromAManifestAndABinary() throws {
        let workspace = temporaryDirectory("packager")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let manifestURL = workspace.appendingPathComponent("threading-extension.json")
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "com.example.packaged",
            name: "Packaged",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/packaged",
            capabilities: [.panels]
        )).write(to: manifestURL)

        let built = workspace.appendingPathComponent("built-binary")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: built)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: built.path
        )

        let destination = workspace.appendingPathComponent(
            ExtensionPackager.packageName(for: "com.example.packaged")
        )
        let bundle = try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: built,
            into: destination
        )

        // The executable lands where the *manifest* says, not where the caller happened to
        // build it — renaming is the packager's job precisely so authors need not do it.
        XCTAssertEqual(bundle.executableURL.lastPathComponent, "packaged")
        XCTAssertTrue(bundle.executableURL.path.hasSuffix("bin/packaged"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundle.executableURL.path))

        // The proof it worked is that the store will take it.
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("packager-store"))
        let installed = try store.install(from: destination)
        XCTAssertEqual(installed.manifest.identifier, "com.example.packaged")
    }

    func testThePackagerRetainsEditableSourceForAWebAssemblyPackage() throws {
        let workspace = temporaryDirectory("wasm-packager")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let manifestURL = workspace.appendingPathComponent("threading-extension.json")
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "com.example.wasm-packaged",
            name: "Wasm Packaged",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/packaged.wasm",
            capabilities: [.panels]
        )).write(to: manifestURL)

        let module = workspace.appendingPathComponent("packaged.wasm")
        try Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]).write(to: module)
        let source = workspace.appendingPathComponent("project", isDirectory: true)
        let sourceTarget = source.appendingPathComponent(
            "Sources/WasmPackaged",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceTarget,
            withIntermediateDirectories: true
        )
        try Data("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "WasmPackaged",
            targets: [.executableTarget(name: "WasmPackaged")]
        )
        """.utf8).write(to: source.appendingPathComponent("Package.swift"))
        try Data("print(\"hello\")\n".utf8).write(
            to: sourceTarget.appendingPathComponent("main.swift")
        )
        let sourceResources = source.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceResources,
            withIntermediateDirectories: true
        )
        try Data("// shader source".utf8).write(
            to: sourceResources.appendingPathComponent("surface.metal")
        )
        let localBuild = source.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(
            at: localBuild,
            withIntermediateDirectories: true
        )
        try Data("local artifact".utf8).write(
            to: localBuild.appendingPathComponent("not-source")
        )

        let destination = workspace.appendingPathComponent(
            ExtensionPackager.packageName(for: "com.example.wasm-packaged")
        )
        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: module,
            into: destination
        )) { error in
            guard case .editableSourceRequired = error as? ExtensionPackagerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let bundle = try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: module,
            sourceDirectoryURL: source,
            into: destination
        )
        XCTAssertEqual(
            bundle.sourceURL,
            destination.appendingPathComponent("Source", isDirectory: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "Source/Sources/WasmPackaged/main.swift"
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Source/.build").path
        ))
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("Resources/surface.metal"),
                encoding: .utf8
            ),
            "// shader source"
        )

        let store = ExtensionPackageStore(rootURL: temporaryDirectory("wasm-packager-store"))
        let installed = try store.install(from: destination)
        XCTAssertEqual(installed.manifest.runtime, .webAssembly)
        XCTAssertNotNil(installed.sourceURL)
    }

    func testScaffolderCreatesAnAtomicSelfContainedExtensionProject() throws {
        let sdk = try XCTUnwrap(Bundle.main.resourceURL?
            .appendingPathComponent("ExtensionSDK/ThreadingExtensionKit", isDirectory: true))
        let destination = temporaryDirectory("scaffold")

        let project = try ExtensionProjectScaffolder.scaffold(
            name: "Build Watch",
            identifier: "com.example.build-watch",
            at: destination,
            sdkSnapshotURL: sdk
        )

        XCTAssertEqual(project.manifest.runtime, .webAssembly)
        XCTAssertEqual(project.sdkVersion, "1")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "Vendor/ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionManifest.swift"
            ).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "Sources/ExtensionMain/main.swift"
            ).path
        ))
        for requiredPath in [
            "Vendor/docs/extensions/AGENT_AUTHORING.md",
            "Vendor/docs/extensions/API_V1.md",
            "Vendor/docs/extensions/schema/extension-manifest.schema.json",
            "Vendor/docs/extensions/generated/component-catalog.json"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent(requiredPath).path
                ),
                "missing scaffolded extension authoring contract: \(requiredPath)"
            )
        }
        let scaffoldREADME = try String(
            contentsOf: destination.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(scaffoldREADME.contains(
            "Start by reading `Vendor/docs/extensions/AGENT_AUTHORING.md` completely"
        ))
        let packageScript = destination.appendingPathComponent("Scripts/package.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: packageScript.path))
        let packageScriptSource = try String(
            contentsOf: packageScript,
            encoding: .utf8
        )
        XCTAssertTrue(packageScriptSource.contains("--swift-sdk \"$SDK_ID\""))
        XCTAssertTrue(packageScriptSource.contains("--exclude Build"))
        XCTAssertTrue(packageScriptSource.contains(
            "rsync -a \"$PROJECT_DIR/Resources/\" \"$STAGING/Resources/\""
        ))
        XCTAssertTrue(packageScriptSource.contains("com.example.build-watch.threadingextension"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "Vendor/ThreadingExtensionKit/.build"
            ).path
        ))

        XCTAssertThrowsError(try ExtensionProjectScaffolder.scaffold(
            name: "Build Watch",
            identifier: "com.example.build-watch",
            at: destination,
            sdkSnapshotURL: sdk
        )) { error in
            guard case .destinationExists = error as? ExtensionProjectScaffolderError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInstallProposalNamesTrustRuntimeCapabilitiesAndDisabledState() {
        let root = temporaryDirectory("install-proposal")
        let manifest = ExtensionManifest(
            identifier: "com.example.proposal",
            name: "Proposal",
            version: "2.3.0",
            dataVersion: 4,
            runtime: .webAssembly,
            executable: "bin/proposal.wasm",
            capabilities: [.panels, .secrets]
        )
        let proposal = ExtensionInstallProposal(bundle: ThreadingExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/proposal.wasm"),
            sourceURL: root.appendingPathComponent("Source", isDirectory: true),
            manifest: manifest
        ))

        XCTAssertEqual(proposal.title, "Install “Proposal”?")
        XCTAssertEqual(proposal.acceptTitle, "Install Disabled")
        XCTAssertTrue(proposal.message.contains("unsigned local import"))
        XCTAssertTrue(proposal.message.contains("WebAssembly"))
        XCTAssertTrue(proposal.message.contains("  • panels"))
        XCTAssertTrue(proposal.message.contains("  • storage.secrets"))
        XCTAssertTrue(proposal.message.contains("Rebuildable Swift source is included"))
        XCTAssertTrue(proposal.message.contains("left disabled"))
    }

    func testFirstPartyInstallProposalExplainsTheAppCopyAndNeverPromisesGitExecution() throws {
        let root = temporaryDirectory("first-party-install-proposal")
        let manifest = ExtensionManifest(
            identifier: "com.example.first-party",
            name: "First Party",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/first-party.wasm"
        )
        let repositoryURL = try XCTUnwrap(URL(string: "https://example.com/source"))
        let proposal = ExtensionInstallProposal(
            bundle: ThreadingExtensionBundle(
                rootURL: root,
                executableURL: root.appendingPathComponent("bin/first-party.wasm"),
                sourceURL: root.appendingPathComponent("Source", isDirectory: true),
                manifest: manifest
            ),
            source: .firstPartyCatalog(repositoryURL: repositoryURL)
        )

        XCTAssertTrue(proposal.message.contains("included with Threading"))
        XCTAssertTrue(proposal.message.contains(repositoryURL.absoluteString))
        XCTAssertTrue(proposal.message.contains("not cloned or built"))
        XCTAssertTrue(proposal.message.contains("left disabled"))
        XCTAssertFalse(proposal.message.contains("unsigned local import"))
    }

    func testInstallProposalCallsOutExtensionSuppliedMetalSource() {
        let root = temporaryDirectory("metal-install-proposal")
        let manifest = ExtensionManifest(
            identifier: "com.example.metal",
            name: "Metal Surface",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/metal.wasm",
            capabilities: [.componentCustomization, .customMetalSurfaces]
        )
        let proposal = ExtensionInstallProposal(bundle: ThreadingExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/metal.wasm"),
            sourceURL: root.appendingPathComponent("Source", isDirectory: true),
            manifest: manifest
        ))

        XCTAssertTrue(proposal.message.contains("  • ui.rendering.metal"))
        XCTAssertTrue(proposal.message.contains("compile and run"))
        XCTAssertTrue(proposal.message.contains("consume GPU resources"))
        XCTAssertTrue(proposal.message.contains("review the included source"))
    }

    func testInstallProposalSeparatesCompanionOSAuthorityFromHostCapabilities() {
        let root = temporaryDirectory("advanced-install-proposal")
        let manifest = ExtensionManifest(
            identifier: "com.example.simulator",
            name: "Simulator",
            version: "1.0.0",
            runtime: .webAssembly,
            executable: "bin/simulator.wasm",
            capabilities: [.panels, .hostSessionsRead],
            companions: [
                .init(
                    id: "device",
                    bundlePath: "Companions/Device.app",
                    activation: .whileExtensionEnabled,
                    capabilities: [.processSpawn, .screenCapture, .remoteSurfaces]
                )
            ]
        )
        let proposal = ExtensionInstallProposal(bundle: ThreadingExtensionBundle(
            rootURL: root,
            executableURL: root.appendingPathComponent("bin/simulator.wasm"),
            sourceURL: root.appendingPathComponent("Source", isDirectory: true),
            manifest: manifest
        ))

        XCTAssertEqual(proposal.capabilities, ["host.sessions.read", "panels"])
        XCTAssertEqual(proposal.companions.map(\.id), ["device"])
        XCTAssertTrue(proposal.message.contains("advanced extension"), proposal.message)
        XCTAssertTrue(proposal.message.contains("separate macOS companion"), proposal.message)
        XCTAssertTrue(proposal.message.contains("runs while the extension is enabled"), proposal.message)
        XCTAssertTrue(proposal.message.contains("screen.capture"), proposal.message)
        XCTAssertTrue(proposal.message.contains("ui.remote-surfaces"), proposal.message)
        XCTAssertTrue(proposal.message.contains("does not inherit additional Threading host data"), proposal.message)
    }

    func testDogfoodScaffoldBuildsPackagesInstallsAndRunsAsWebAssembly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let swiftPath = environment["THREADING_SWIFT_WASM"],
              let sdkID = environment["THREADING_SWIFT_WASM_SDK"] else {
            throw XCTSkip(
                "Set THREADING_SWIFT_WASM and THREADING_SWIFT_WASM_SDK to run the real "
                    + "scaffold → compile → package → install → runner dogfood pass."
            )
        }
        let sdk = try XCTUnwrap(Bundle.main.resourceURL?
            .appendingPathComponent("ExtensionSDK/ThreadingExtensionKit", isDirectory: true))
        let workspace = temporaryDirectory("dogfood-authoring-flow")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let projectURL = workspace.appendingPathComponent("BuildWatch", isDirectory: true)
        let scaffold = try ExtensionProjectScaffolder.scaffold(
            name: "Build Watch",
            identifier: "com.example.build-watch",
            at: projectURL,
            sdkSnapshotURL: sdk
        )

        let package = Process()
        package.executableURL = URL(fileURLWithPath: "/bin/sh")
        package.arguments = [
            projectURL.appendingPathComponent("Scripts/package.sh").path,
            sdkID
        ]
        // A hosted XCTest process carries DYLD/XCTest injection meant for the app under test.
        // Passing it into SwiftPM makes its freshly compiled Package.swift helper fail to spawn.
        // Keep the user's ordinary toolchain environment and remove only test-runner injection.
        var packageEnvironment = environment.filter { key, _ in
            !key.hasPrefix("DYLD_")
                && !key.hasPrefix("XCTest")
                && key != "LLVM_PROFILE_FILE"
        }
        packageEnvironment["THREADING_SWIFT_EXEC"] = swiftPath
        packageEnvironment["CLANG_MODULE_CACHE_PATH"] = workspace
            .appendingPathComponent("clang-cache", isDirectory: true).path
        packageEnvironment["SWIFTPM_MODULECACHE_OVERRIDE"] = workspace
            .appendingPathComponent("swift-module-cache", isDirectory: true).path
        package.environment = packageEnvironment
        let packageOutput = Pipe()
        package.standardOutput = packageOutput
        package.standardError = packageOutput
        try package.run()
        let diagnostics = String(
            decoding: packageOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        package.waitUntilExit()
        guard package.terminationStatus == 0 else {
            return XCTFail(diagnostics)
        }

        let packageURL = projectURL.appendingPathComponent(
            "Build",
            isDirectory: true
        ).appendingPathComponent(
            ExtensionPackager.packageName(for: scaffold.manifest.identifier),
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return XCTFail(diagnostics)
        }

        let store = ExtensionPackageStore(
            rootURL: workspace.appendingPathComponent("Host", isDirectory: true)
        )
        let installed = try store.install(from: packageURL)
        XCTAssertEqual(installed.manifest.identifier, scaffold.manifest.identifier)
        XCTAssertEqual(installed.manifest.runtime, .webAssembly)
        XCTAssertEqual(store.enabledIdentifiers(), [])
        XCTAssertEqual(try store.inventory().first?.provenance?.sdkVersion, "1")

        let registration = try ExtensionRegistrationLoader.load(from: installed)
        XCTAssertEqual(registration.panels.map(\.id), ["welcome"])
        XCTAssertEqual(registration.panels.first?.title, "Build Watch")
    }

    func testThePackagerLeavesNothingBehindWhenAssemblyFails() throws {
        let workspace = temporaryDirectory("packager-fail")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let manifestURL = workspace.appendingPathComponent("threading-extension.json")
        // A manifest naming a capability the host does not implement: valid JSON, refused by
        // the inspector. The packager must not leave a half-built package for someone to find.
        try Data("""
        {"formatVersion": 1, "identifier": "com.example.bad", "name": "Bad",
         "version": "1.0.0", "executable": "bin/bad", "capabilities": ["not.a.capability"]}
        """.utf8).write(to: manifestURL)

        let built = workspace.appendingPathComponent("built-binary")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: built)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: built.path
        )

        let destination = workspace.appendingPathComponent("bad.threadingextension")
        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: built,
            into: destination
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: workspace.path)
                .filter { $0.hasPrefix(".assemble-") },
            [],
            "a failed assembly must not leave its staging directory behind"
        )
    }

    func testThePackagerRefusesToOverwriteOrToEscapeThePackage() throws {
        let workspace = temporaryDirectory("packager-refusals")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let built = workspace.appendingPathComponent("built-binary")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: built)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: built.path
        )

        func manifest(executable: String) throws -> URL {
            let url = workspace.appendingPathComponent("\(UUID().uuidString).json")
            try JSONEncoder().encode(ExtensionManifest(
                identifier: "com.example.refusals",
                name: "Refusals",
                version: "1.0.0",
                runtime: .native,
                executable: executable,
                capabilities: []
            )).write(to: url)
            return url
        }

        // A manifest that points out of its own package is refused before anything is written,
        // rather than producing a package the inspector rejects later with a vaguer message.
        for escaping in ["../outside", "/etc/passwd", "bin/../../outside"] {
            let destination = workspace.appendingPathComponent("\(UUID().uuidString).threadingextension")
            XCTAssertThrowsError(try ExtensionPackager.assemble(
                manifestURL: try manifest(executable: escaping),
                executableURL: built,
                into: destination
            ), escaping)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), escaping)
        }

        // Overwriting is refused: assembling over a real package would destroy it on a typo.
        let occupied = workspace.appendingPathComponent("taken.threadingextension")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: try manifest(executable: "bin/x"),
            executableURL: built,
            into: occupied
        )) { error in
            guard case .destinationExists = error as? ExtensionPackagerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // And a source that is not runnable is caught before a package is started.
        let notExecutable = workspace.appendingPathComponent("plain.txt")
        try Data("hello".utf8).write(to: notExecutable)
        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: try manifest(executable: "bin/x"),
            executableURL: notExecutable,
            into: workspace.appendingPathComponent("plain.threadingextension")
        )) { error in
            guard case .executableNotRunnable = error as? ExtensionPackagerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUpdateRefusesWhenOnlyTheExecutableChangedAfterThePlanWasSeen() throws {
        let root = temporaryDirectory("store")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(
            from: try makeVersionedPackage(version: "1.0.0", capabilities: [])
        )

        let source = try makeVersionedPackage(version: "1.1.0", capabilities: [])
        let plan = try store.updatePlan(from: source)
        XCTAssertNotNil(plan.sourceDigest, "the plan has to record what it saw")

        // The manifest is untouched — same identifier, version and capabilities — so a
        // manifest-only re-check would call this the same package and install code the user
        // never reviewed. Capabilities still bound what that code could do; the point is that
        // the re-check should mean "the same thing I showed you".
        try Data("#!/bin/sh\necho substituted\n".utf8)
            .write(to: source.appendingPathComponent("bin/extension"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: source.appendingPathComponent("bin/extension").path
        )

        XCTAssertThrowsError(try store.update(from: source, approving: plan)) { error in
            guard case .updateChangedUnderneath = error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.inventory().first?.bundle?.manifest.version, "1.0.0")
    }

    func testUpdateRefusesADataSchemaRollbackBeforeReplacingAnything() throws {
        let root = temporaryDirectory("data-version-update")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(from: makeVersionedPackage(
            version: "2.0.0",
            capabilities: [],
            dataVersion: 3
        ))
        let candidate = try makeVersionedPackage(
            version: "1.0.0",
            capabilities: [],
            dataVersion: 2
        )

        XCTAssertThrowsError(try store.updatePlan(from: candidate)) { error in
            guard case .dataVersionRollback(_, 3, 2) =
                    error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try store.inventory().first?.bundle?.manifest.dataVersion,
            3
        )
    }

    func testThePackageDigestNoticesContentAndLayoutChanges() throws {
        let root = temporaryDirectory("digest")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = root.appendingPathComponent("bin/extension")
        try Data("one".utf8).write(to: file)

        let first = try XCTUnwrap(ExtensionPackageDigest.compute(at: root))
        XCTAssertEqual(
            ExtensionPackageDigest.compute(at: root),
            first,
            "the digest has to be stable, or every re-check is a false alarm"
        )

        try Data("two".utf8).write(to: file)
        let afterEdit = try XCTUnwrap(ExtensionPackageDigest.compute(at: root))
        XCTAssertNotEqual(afterEdit, first)

        // Moving a file without changing any bytes must change the digest too: paths are
        // hashed alongside contents precisely so a rename is not invisible.
        try FileManager.default.moveItem(
            at: file,
            to: root.appendingPathComponent("bin/renamed")
        )
        XCTAssertNotEqual(ExtensionPackageDigest.compute(at: root), afterEdit)
    }

    func testTheUpdateConfirmationNamesTheNewPermissionsAndTheVersionDirection() {
        func manifest(
            _ version: String,
            _ capabilities: Set<ExtensionCapability>
        ) -> ExtensionManifest {
            ExtensionManifest(
                identifier: "com.example.confirm",
                name: "Confirm",
                version: version,
                runtime: .native,
                executable: "bin/extension",
                capabilities: capabilities
            )
        }

        let widening = ExtensionUpdatePlan(
            installed: manifest("1.0.0", [.panels]),
            candidate: manifest("2.0.0", [.panels, .networkClient, .secrets])
        ).confirmation(name: "CI Status")

        // The title has to carry the risk, because a title people skim is the last thing read
        // before a button is pressed.
        XCTAssertEqual(widening.title, "Update “CI Status” and grant new permissions?")
        XCTAssertEqual(widening.acceptTitle, "Grant and Update")
        XCTAssertTrue(widening.message.contains("1.0.0 → 2.0.0"), widening.message)
        XCTAssertTrue(widening.message.contains("network.client"), widening.message)
        XCTAssertTrue(widening.message.contains("storage.secrets"), widening.message)
        // Said plainly, because the alternative people assume is that updating resets things.
        XCTAssertTrue(widening.message.contains("secrets are kept"), widening.message)

        // An ordinary update must not borrow the alarming wording, or the alarming wording
        // stops meaning anything.
        let ordinary = ExtensionUpdatePlan(
            installed: manifest("1.0.0", [.panels]),
            candidate: manifest("1.1.0", [.panels])
        ).confirmation(name: "CI Status")
        XCTAssertEqual(ordinary.title, "Update “CI Status”?")
        XCTAssertEqual(ordinary.acceptTitle, "Update")
        XCTAssertFalse(ordinary.message.contains("permissions"), ordinary.message)

        let migration = ExtensionUpdatePlan(
            installed: ExtensionManifest(
                identifier: "com.example.confirm",
                name: "Confirm",
                version: "1.0.0",
                dataVersion: 1,
                runtime: .native,
                executable: "bin/extension"
            ),
            candidate: ExtensionManifest(
                identifier: "com.example.confirm",
                name: "Confirm",
                version: "1.1.0",
                dataVersion: 2,
                runtime: .native,
                executable: "bin/extension"
            )
        ).confirmation(name: "CI Status")
        XCTAssertTrue(migration.message.contains("schema 1 → 2"), migration.message)

        let downgrade = ExtensionUpdatePlan(
            installed: manifest("2.0.0", [.panels]),
            candidate: manifest("1.0.0", [.panels])
        ).confirmation(name: "CI Status")
        XCTAssertTrue(downgrade.message.contains("downgrade"), downgrade.message)

        let sideways = ExtensionUpdatePlan(
            installed: manifest("1.0-beta", [.panels]),
            candidate: manifest("1.0.0", [.panels])
        ).confirmation(name: "CI Status")
        XCTAssertTrue(sideways.message.contains("cannot"), sideways.message)
    }

    func testAddingOrBackgroundingACompanionRequiresUpdateApproval() {
        func manifest(
            version: String,
            companions: [ExtensionCompanion]
        ) -> ExtensionManifest {
            ExtensionManifest(
                identifier: "com.example.advanced-update",
                name: "Advanced Update",
                version: version,
                runtime: .webAssembly,
                executable: "bin/extension.wasm",
                companions: companions
            )
        }

        let companion = ExtensionCompanion(
            id: "proxy",
            bundlePath: "Companions/Proxy.app",
            capabilities: [.networkClient, .networkListen]
        )
        let adding = ExtensionUpdatePlan(
            installed: manifest(version: "1.0.0", companions: []),
            candidate: manifest(version: "1.1.0", companions: [companion])
        )
        XCTAssertTrue(adding.requiresApproval)
        XCTAssertEqual(adding.addedCapabilities, [])
        XCTAssertTrue(
            adding.addedCompanionAuthorities.contains("proxy: native companion app")
        )
        XCTAssertTrue(
            adding.addedCompanionAuthorities.contains("proxy: network.listen")
        )
        let addingConfirmation = adding.confirmation(name: "Proxy")
        XCTAssertEqual(
            addingConfirmation.title,
            "Update “Proxy” and grant new permissions?"
        )
        XCTAssertTrue(
            addingConfirmation.message.contains("advanced companion"),
            addingConfirmation.message
        )

        let backgrounding = ExtensionUpdatePlan(
            installed: manifest(version: "1.1.0", companions: [companion]),
            candidate: manifest(
                version: "1.2.0",
                companions: [
                    .init(
                        id: companion.id,
                        bundlePath: companion.bundlePath,
                        activation: .whileExtensionEnabled,
                        capabilities: companion.capabilities
                    )
                ]
            )
        )
        XCTAssertEqual(
            backgrounding.addedCompanionAuthorities,
            ["proxy: run while enabled"]
        )
        XCTAssertTrue(backgrounding.requiresApproval)
    }

    func testUpdatingARunningExtensionStopsItFirstAndPutsItBack() async throws {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-update"))
        _ = try store.install(
            from: try makeVersionedPackage(version: "1.0.0", capabilities: [])
        )
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.versioned")
        let started = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }
        XCTAssertTrue(started, "the extension has to be running for the update to be a swap")

        let source = try makeVersionedPackage(version: "2.0.0", capabilities: [])
        let plan = try store.updatePlan(from: source)
        XCTAssertEqual(plan.versionChange, .newer)

        let updated = expectation(description: "update")
        var outcome: Result<InstalledExtensionSnapshot, Error>?
        manager.update(from: source, approving: plan) {
            outcome = $0
            updated.fulfill()
        }
        await fulfillment(of: [updated], timeout: 10)

        switch try XCTUnwrap(outcome) {
        case .failure(let error):
            XCTFail("update failed: \(error)")
        case .success(let snapshot):
            XCTAssertEqual(snapshot.identifier, "com.example.versioned")
        }
        XCTAssertEqual(
            try store.inventory().first?.bundle?.manifest.version,
            "2.0.0"
        )

        // Enablement is preserved: an extension that was running is running again, on the new
        // code. Silently disabling it would be a worse outcome than refusing the update.
        let restarted = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }
        XCTAssertTrue(restarted, "an extension that was enabled must come back enabled")
        XCTAssertTrue(store.enabledIdentifiers().contains("com.example.versioned"))
    }

    func testAFailedUpdateLeavesTheExtensionInstalledAndRunning() async throws {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-update-fail"))
        _ = try store.install(
            from: try makeVersionedPackage(version: "1.0.0", capabilities: [])
        )
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.versioned")
        _ = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }

        let source = try makeVersionedPackage(version: "2.0.0", capabilities: [])
        let plan = try store.updatePlan(from: source)
        // The source grows two capabilities after the plan was approved, which the store
        // refuses. The extension must survive that refusal untouched.
        try writeManifest(
            at: source,
            version: "2.0.0",
            capabilities: [.networkClient, .secrets]
        )

        let finished = expectation(description: "refused update")
        var failure: Error?
        manager.update(from: source, approving: plan) {
            if case .failure(let error) = $0 { failure = error }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertNotNil(failure)
        XCTAssertEqual(try store.inventory().first?.bundle?.manifest.version, "1.0.0")
        let stillRunning = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }
        XCTAssertTrue(stillRunning, "a refused update must not leave the extension stopped")
    }

    func testAnUpdateExcludesConflictingLifecycleActionsUntilItCompletes() async throws {
        let store = ExtensionPackageStore(rootURL: temporaryDirectory("manager-update-lock"))
        _ = try store.install(
            from: try makeVersionedPackage(version: "1.0.0", capabilities: [])
        )
        let manager = ExtensionManager(store: store)
        defer { manager.terminateAll() }
        try manager.setEnabled(true, identifier: "com.example.versioned")
        _ = await waitUntil {
            manager.installedExtensions.first?.status
                == .running(commands: 0, panels: 0, tools: 0)
        }

        let source = try makeVersionedPackage(version: "2.0.0", capabilities: [])
        let plan = try store.updatePlan(from: source)
        let finished = expectation(description: "first update")
        var firstOutcome: Result<InstalledExtensionSnapshot, Error>?
        manager.update(from: source, approving: plan) {
            firstOutcome = $0
            finished.fulfill()
        }

        XCTAssertEqual(manager.installedExtensions.first?.status, .updating)
        XCTAssertThrowsError(
            try manager.setEnabled(false, identifier: "com.example.versioned")
        ) {
            guard case .operationInProgress = $0 as? ExtensionManagerError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        XCTAssertThrowsError(try manager.uninstall(identifier: "com.example.versioned")) {
            guard case .operationInProgress = $0 as? ExtensionManagerError else {
                return XCTFail("unexpected error: \($0)")
            }
        }
        // Simulate an administrative desired-state change outside the manager while its main
        // actor is still in the transition. Completion must re-read this, not restart from a
        // Boolean captured before the copy.
        try store.setEnabled(false, identifier: "com.example.versioned")

        let refused = expectation(description: "overlapping update refused")
        manager.update(from: source, approving: plan) { result in
            guard case .failure(let error) = result,
                  case .operationInProgress = error as? ExtensionManagerError else {
                XCTFail("a second update should be refused immediately")
                refused.fulfill()
                return
            }
            refused.fulfill()
        }
        await fulfillment(of: [refused, finished], timeout: 10)
        guard case .success = try XCTUnwrap(firstOutcome) else {
            return XCTFail("the first update should still complete")
        }
        XCTAssertFalse(store.enabledIdentifiers().contains("com.example.versioned"))
        XCTAssertEqual(manager.installedExtensions.first?.status, .disabled)
    }

    func testExtensionVersionsCompareByComponentAndAdmitIncomparableOnes() {
        func compare(_ candidate: String, _ installed: String) -> ExtensionVersion.Comparison {
            ExtensionVersion(candidate).compared(to: ExtensionVersion(installed))
        }

        XCTAssertEqual(compare("1.2.0", "1.1.9"), .newer)
        XCTAssertEqual(compare("1.1.9", "1.2.0"), .older)
        XCTAssertEqual(compare("2.0.0", "1.999.999"), .newer)
        // Numeric, not lexicographic: "10" beats "9" even though "1" sorts before "9".
        XCTAssertEqual(compare("0.10.0", "0.9.0"), .newer)
        XCTAssertEqual(compare("1.0.0", "1.0.0"), .same)
        // A trailing zero is not a release.
        XCTAssertEqual(compare("1.2", "1.2.0"), .same)

        // A version this cannot order says so rather than guessing. Ordering "1.0-beta"
        // against "1.0" wrongly is worse than declining to.
        XCTAssertEqual(compare("1.0-beta", "1.0"), .incomparable)
        XCTAssertEqual(compare("", "1.0"), .incomparable)
        XCTAssertEqual(compare("1.0-beta", "1.0-beta"), .same)
    }

    func testAnUpdatePlanNamesTheAuthorityAnUpdateWouldAdd() {
        func manifest(
            version: String,
            capabilities: Set<ExtensionCapability>
        ) -> ExtensionManifest {
            ExtensionManifest(
                identifier: "com.example.updates",
                name: "Updates",
                version: version,
                runtime: .native,
                executable: "bin/extension",
                capabilities: capabilities
            )
        }

        let widening = ExtensionUpdatePlan(
            installed: manifest(version: "1.0.0", capabilities: [.panels]),
            candidate: manifest(
                version: "1.1.0",
                capabilities: [.panels, .networkClient, .secrets]
            )
        )
        XCTAssertEqual(widening.versionChange, .newer)
        XCTAssertEqual(widening.addedCapabilities, [.networkClient, .secrets])
        XCTAssertEqual(widening.removedCapabilities, [])
        XCTAssertTrue(
            widening.requiresApproval,
            "an update that asks for more authority must be approved again"
        )
        XCTAssertFalse(widening.isReinstallOrRollback)

        // Giving authority up needs nobody's consent.
        let narrowing = ExtensionUpdatePlan(
            installed: manifest(version: "1.0.0", capabilities: [.panels, .networkClient]),
            candidate: manifest(version: "1.1.0", capabilities: [.panels])
        )
        XCTAssertEqual(narrowing.removedCapabilities, [.networkClient])
        XCTAssertFalse(narrowing.requiresApproval)

        // A rollback is legitimate and is surfaced rather than refused — a silent one is how an
        // old vulnerable build comes back.
        let rollback = ExtensionUpdatePlan(
            installed: manifest(version: "2.0.0", capabilities: [.panels]),
            candidate: manifest(version: "1.0.0", capabilities: [.panels])
        )
        XCTAssertEqual(rollback.versionChange, .older)
        XCTAssertTrue(rollback.isReinstallOrRollback)
        XCTAssertFalse(rollback.requiresApproval)
    }

    func testUpdateReplacesThePackageAndKeepsPrivateStorage() throws {
        let root = temporaryDirectory("store")
        let store = ExtensionPackageStore(rootURL: root)

        let first = try makeVersionedPackage(version: "1.0.0", capabilities: [.panels])
        let installed = try store.install(from: first)
        XCTAssertEqual(installed.manifest.version, "1.0.0")

        // State the extension owns, which an update must not discard. Uninstall-then-install
        // would lose all of it, which is exactly why update exists as its own operation.
        try store.storageStore.setKeyValue(
            .string("kept"),
            extensionIdentifier: "com.example.versioned",
            key: "state"
        )

        let second = try makeVersionedPackage(
            version: "1.1.0",
            capabilities: [.panels, .keyValueStorage]
        )
        let plan = try store.updatePlan(from: second)
        XCTAssertEqual(plan.versionChange, .newer)
        XCTAssertEqual(plan.addedCapabilities, [.keyValueStorage])

        let repositoryURL = try XCTUnwrap(URL(string: "https://example.com/versioned"))
        let updated = try store.update(
            from: second,
            approving: plan,
            source: .firstPartyCatalog(repositoryURL: repositoryURL)
        )
        XCTAssertEqual(updated.manifest.version, "1.1.0")
        XCTAssertEqual(try store.inventory().count, 1, "an update replaces rather than accumulates")
        XCTAssertEqual(
            try store.storageStore.keyValues(
                extensionIdentifier: "com.example.versioned"
            )["state"],
            ExtensionJSONValue.string("kept")
        )
        let provenance = try XCTUnwrap(try store.inventory().first?.provenance)
        XCTAssertEqual(provenance.origin, .firstPartyCatalog)
        XCTAssertEqual(provenance.repositoryURL, repositoryURL)
    }

    func testUpdateRefusesWhenTheSourceChangedAfterThePlanWasSeen() throws {
        let root = temporaryDirectory("store")
        let store = ExtensionPackageStore(rootURL: root)
        _ = try store.install(
            from: try makeVersionedPackage(version: "1.0.0", capabilities: [.panels])
        )

        let source = try makeVersionedPackage(version: "1.1.0", capabilities: [.panels])
        let plan = try store.updatePlan(from: source)
        XCTAssertFalse(plan.requiresApproval)

        // The user approved a plan that asked for nothing new. Between then and now the source
        // grew two capabilities — which is precisely the substitution the re-check exists for.
        try writeManifest(
            at: source,
            version: "1.1.0",
            capabilities: [.panels, .networkClient, .secrets]
        )
        XCTAssertThrowsError(try store.update(from: source, approving: plan)) { error in
            guard case .updateChangedUnderneath = error as? ExtensionPackageStoreError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try store.inventory().first?.bundle?.manifest.version,
            "1.0.0",
            "a refused update must leave the installed copy untouched"
        )
    }

    @MainActor
    private final class RecordingCompanionRouter: ExtensionCompanionRouting {
        private(set) var extensionIdentifier: String?
        private(set) var companionID: String?
        private(set) var operationID: String?
        private(set) var arguments: ExtensionJSONValue?

        func invokeCompanionOperation(
            extensionIdentifier: String,
            companionID: String,
            operationID: String,
            arguments: ExtensionJSONValue,
            completion: @escaping @MainActor @Sendable (
                Result<ExtensionCompanionOperationResponse, Error>
            ) -> Void
        ) {
            self.extensionIdentifier = extensionIdentifier
            self.companionID = companionID
            self.operationID = operationID
            self.arguments = arguments
            completion(.success(ExtensionCompanionOperationResponse(
                requestID: "host-owned-request",
                generation: "host-owned-generation",
                operationID: operationID,
                value: .object(["state": .string("booted")])
            )))
        }
    }

    private func makeVersionedPackage(
        version: String,
        capabilities: Set<ExtensionCapability>,
        dataVersion: Int = 1
    ) throws -> URL {
        let root = temporaryDirectory("versioned-source")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A real serve loop, not `exit 0`: the update tests are about swapping a *running*
        // extension, and a package that exits immediately never reaches `.running` at all.
        let registration = String(
            decoding: try JSONEncoder().encode(ExtensionRegistration()),
            as: UTF8.self
        )
        let executable = root.appendingPathComponent("bin/extension")
        try Data("""
        #!/bin/sh
        case "$1" in
          --threading-register)
            printf '%s' \(shellQuoted(registration))
            ;;
          --threading-serve)
            printf '%s\\n' \(shellQuoted(registration))
            while read -r _; do :; done
            ;;
          *)
            exit 64
            ;;
        esac

        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try writeManifest(
            at: root,
            version: version,
            capabilities: capabilities,
            dataVersion: dataVersion
        )
        return root
    }

    private func writeManifest(
        at root: URL,
        version: String,
        capabilities: Set<ExtensionCapability>,
        dataVersion: Int = 1
    ) throws {
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "com.example.versioned",
            name: "Versioned",
            version: version,
            dataVersion: dataVersion,
            runtime: .native,
            executable: "bin/extension",
            capabilities: capabilities
        )).write(to: root.appendingPathComponent(ExtensionBundleInspector.manifestName))
    }

    private func makePackage(
        tool: ExtensionMCPTool? = nil,
        toolResponse: ExtensionMCPToolResponse? = nil,
        service: ExtensionServiceDefinition? = nil,
        serviceResponse: ExtensionServiceResponse? = nil,
        serviceDependencies: [ExtensionServiceDependency] = [],
        command: ExtensionCommand? = nil,
        commandResponse: ExtensionCommandResponse? = nil,
        panel: ExtensionPanel? = nil,
        panelResponse: ExtensionActionResponse? = nil,
        capabilities requestedCapabilities: Set<ExtensionCapability> = [],
        requiresStorageEnvironment: Bool = false,
        settings: ExtensionSettingsContribution = .init(),
        settingsResponseIDs: [String] = [],
        settingsResponseError: String? = nil
    ) throws -> URL {
        let root = temporaryDirectory("source")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        let tools = tool.map { [$0] } ?? []
        var capabilities = requestedCapabilities
        if !tools.isEmpty {
            capabilities.insert(.mcpTools)
        }
        let services = service.map { [$0] } ?? []
        if !services.isEmpty {
            capabilities.insert(.servicesProvide)
        }
        if !serviceDependencies.isEmpty {
            capabilities.insert(.servicesConsume)
        }
        let commands = command.map { [$0] } ?? []
        if !commands.isEmpty {
            capabilities.insert(.commands)
        }
        let panels = panel.map { [$0] } ?? []
        if !panels.isEmpty {
            capabilities.insert(.panels)
        }
        if !settings.isEmpty {
            capabilities.insert(.settings)
        }
        let manifest = ExtensionManifest(
            identifier: "com.example.installed-test",
            name: "Installed Test",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/extension",
            capabilities: capabilities,
            mcpTools: tools,
            settings: settings,
            services: services,
            serviceDependencies: serviceDependencies
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        let registration = String(
            decoding: try JSONEncoder().encode(ExtensionRegistration(
                commands: commands,
                panels: panels,
                mcpTools: tools,
                services: services
            )),
            as: UTF8.self
        )
        let serveBody: String
        if !settingsResponseIDs.isEmpty {
            let ids = String(
                decoding: try JSONEncoder().encode(settingsResponseIDs),
                as: UTF8.self
            )
            let errorMember: String
            if let settingsResponseError {
                let encoded = String(
                    decoding: try JSONEncoder().encode(settingsResponseError),
                    as: UTF8.self
                )
                errorMember = ",\"error\":\(encoded)"
            } else {
                errorMember = ""
            }
            serveBody = """
                [ -n "$THREADING_EXTENSION_SETTINGS_JSON" ] || exit 68
                printf '%s\\n' "$THREADING_EXTENSION_SETTINGS_JSON" > "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/launch-settings.json"
                while IFS= read -r line; do
                  printf '%s\\n' "$line" >> "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY/settings-requests.jsonl"
                  request_id=${line#*\\"requestID\\":\\"}
                  request_id=${request_id%%\\"*}
                  printf '{"protocolVersion":1,"requestID":"%s","settingIDs":%s\(errorMember)}\\n' "$request_id" \(shellQuoted(ids))
                done
                """
        } else if let serviceResponse {
            let serviceID = String(
                decoding: try JSONEncoder().encode(serviceResponse.serviceID),
                as: UTF8.self
            )
            let member: String
            if let value = serviceResponse.value {
                let encoded = String(
                    decoding: try JSONEncoder().encode(value),
                    as: UTF8.self
                )
                member = ",\"value\":\(encoded)"
            } else if let error = serviceResponse.error {
                let encoded = String(
                    decoding: try JSONEncoder().encode(error),
                    as: UTF8.self
                )
                member = ",\"error\":\(encoded)"
            } else {
                member = ""
            }
            serveBody = """
                IFS= read -r line || exit 65
                request_id=${line#*\\"requestID\\":\\"}
                request_id=${request_id%%\\"*}
                printf '{"protocolVersion":1,"requestID":"%s","serviceID":%s,"serviceVersion":%s%s}\\n' "$request_id" \(shellQuoted(serviceID)) \(shellQuoted(String(serviceResponse.serviceVersion))) \(shellQuoted(member))
                while IFS= read -r line; do :; done
                """
        } else if let panelResponse {
            let panelMember: String
            if let panel = panelResponse.panel {
                panelMember = ",\"panel\":" + String(
                    decoding: try JSONEncoder().encode(panel),
                    as: UTF8.self
                )
            } else {
                panelMember = ""
            }
            let messageMember: String
            if let message = panelResponse.message {
                messageMember = ",\"message\":" + String(
                    decoding: try JSONEncoder().encode(message),
                    as: UTF8.self
                )
            } else {
                messageMember = ""
            }
            let errorMember: String
            if let error = panelResponse.error {
                errorMember = ",\"error\":" + String(
                    decoding: try JSONEncoder().encode(error),
                    as: UTF8.self
                )
            } else {
                errorMember = ""
            }
            let members = panelMember + messageMember + errorMember
            serveBody = """
                IFS= read -r line || exit 65
                request_id=${line#*\\"requestID\\":\\"}
                request_id=${request_id%%\\"*}
                printf '{"protocolVersion":1,"requestID":"%s"%s}\\n' "$request_id" \(shellQuoted(members))
                while IFS= read -r line; do :; done
                """
        } else if let commandResponse {
            let response = String(
                decoding: try JSONEncoder().encode(commandResponse),
                as: UTF8.self
            )
            serveBody = """
                IFS= read -r line || exit 65
                printf '%s\\n' \(shellQuoted(response))
                while IFS= read -r line; do :; done
                """
        } else if let toolResponse {
            let response = String(
                decoding: try JSONEncoder().encode(toolResponse),
                as: UTF8.self
            )
            serveBody = """
                IFS= read -r line || exit 65
                printf '%s\\n' \(shellQuoted(response))
                while IFS= read -r line; do :; done
                """
        } else {
            serveBody = "while IFS= read -r line; do :; done"
        }
        let storageGuard = requiresStorageEnvironment
            ? """
                [ -n "$THREADING_EXTENSION_KEY_VALUE_DIRECTORY" ] || exit 66
                [ -n "$THREADING_EXTENSION_CACHE_DIRECTORY" ] || exit 67
                """
            : ""
        let script = """
            #!/bin/sh
            case "$1" in
              --threading-register)
                printf '%s' \(shellQuoted(registration))
                ;;
              --threading-serve)
                \(storageGuard)
                printf '%s\\n' \(shellQuoted(registration))
                \(serveBody)
                ;;
              *)
                exit 64
                ;;
            esac
            """
        let executable = bin.appendingPathComponent("extension")
        try Data((script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return root
    }

    private func makeStressPackages(
        count: Int,
        in store: ExtensionPackageStore
    ) throws {
        try FileManager.default.createDirectory(
            at: store.packagesURL,
            withIntermediateDirectories: true
        )
        for index in 0..<count {
            let identifier = String(format: "com.example.stress%03d", index)
            let root = store.packagesURL.appendingPathComponent(
                "\(identifier).threadingextension",
                isDirectory: true
            )
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let manifest = ExtensionManifest(
                identifier: identifier,
                name: String(format: "Stress Extension %03d", index),
                version: "1.0.\(index)",
                runtime: .native,
                executable: "bin/extension",
                capabilities: [.commands, .mcpTools],
                mcpTools: [
                    .init(
                        id: "lookup",
                        title: "Lookup",
                        description: "Look up one value."
                    )
                ]
            )
            try JSONEncoder().encode(manifest).write(
                to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
            )
            let executable = bin.appendingPathComponent("extension")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
    }

    private func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingExtensionPackageTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        cleanupURLs.append(url)
        return url
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func physicalFootprintBytes() -> UInt64 {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    /// Table-backed settings intentionally materialize nothing for a detached zero-size view.
    /// Host them at the same useful size as the real window before making visible-row assertions.
    private func settingsWindow(
        _ page: NSView,
        width: CGFloat = 720,
        height: CGFloat = 700
    ) -> NSWindow {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }
}
