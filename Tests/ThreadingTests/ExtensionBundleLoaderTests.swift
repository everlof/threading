import AppKit
import Foundation
import ThreadingExtensionKit
import XCTest
@testable import Threading

final class ExtensionBundleLoaderTests: XCTestCase {

    func testManifestIsInspectedBeforeTheProcessRegistersContributions() throws {
        let registration = ExtensionRegistration(
            commands: [.init(id: "refresh", title: "Refresh")],
            panels: [
                .init(
                    id: "status",
                    title: "Status",
                    root: .status("Ready", role: .positive)
                )
            ]
        )
        let json = String(
            decoding: try JSONEncoder().encode(registration),
            as: UTF8.self
        )
        let directory = try makeBundle(
            capabilities: [.commands, .panels],
            script: """
            #!/bin/sh
            [ "$1" = "--threading-register" ] || exit 64
            printf '%s' \(shellQuoted(json))
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        XCTAssertEqual(bundle.manifest.identifier, "com.example.loader-test")
        XCTAssertEqual(bundle.executableURL.lastPathComponent, "extension")

        let loaded = try ExtensionRegistrationLoader.load(from: bundle)
        XCTAssertEqual(loaded, registration)
    }

    func testLocalizationCataloguesAreInspectedNegotiatedAndAppliedToHostUI() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let localizationDirectory = directory.appendingPathComponent(
            "Localizations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localizationDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode([
            "Status": "Status på svenska",
            "Ready": "Klar",
            "Refresh": "Uppdatera"
        ]).write(to: localizationDirectory.appendingPathComponent("sv.json"))

        let manifest = ExtensionManifest(
            identifier: "com.example.loader-test",
            name: "Loader Test",
            version: "0.1.0",
            executable: "bin/extension",
            localizations: [
                .init(locale: "sv", resource: "Localizations/sv.json")
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        XCTAssertEqual(bundle.localizations.map(\.language), ["sv"])

        let resolver = ExtensionLocalizationResolver(
            catalogs: bundle.localizations,
            preferredLanguages: ["sv-SE", "en"]
        )
        XCTAssertEqual(resolver.language, "sv")
        XCTAssertEqual(
            resolver.panel(
                .init(
                    id: "status",
                    title: "Status",
                    root: .stack(
                        axis: .vertical,
                        spacing: .small,
                        children: [
                            .status("Ready", role: .positive),
                            .button(
                                id: "refresh",
                                title: "Refresh",
                                role: .standard,
                                isEnabled: true
                            )
                        ]
                    )
                )
            ),
            .init(
                id: "status",
                title: "Status på svenska",
                root: .stack(
                    axis: .vertical,
                    spacing: .small,
                    children: [
                        .status("Klar", role: .positive),
                        .button(
                            id: "refresh",
                            title: "Uppdatera",
                            role: .standard,
                            isEnabled: true
                        )
                    ]
                )
            )
        )

        let environment = resolver.environment(
            preferredLanguages: ["sv-SE", "en"],
            localeIdentifier: "sv_SE"
        )
        XCTAssertEqual(
            environment[ExtensionLocalizationEnvironment.selectedLanguage],
            "sv"
        )
        XCTAssertNotNil(environment[ExtensionLocalizationEnvironment.stringsJSON])
    }

    func testInspectorRejectsLocalizationFilesThatAreNotFlatStringCatalogues() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let localizationDirectory = directory.appendingPathComponent(
            "Localizations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localizationDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"Ready":{"translation":"Klar"}}"#.utf8).write(
            to: localizationDirectory.appendingPathComponent("sv.json")
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.loader-test",
            name: "Loader Test",
            version: "0.1.0",
            executable: "bin/extension",
            localizations: [
                .init(locale: "sv", resource: "Localizations/sv.json")
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .localizationResourceInvalid(
                path: "Localizations/sv.json",
                message: let message
            ) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("flat JSON object"))
        }
    }

    func testInspectorRejectsLocalizationThatChangesFormatPlaceholders() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let localizationDirectory = directory.appendingPathComponent(
            "Localizations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localizationDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"Opened build %@":"Öppnade bygge %lld"}"#.utf8).write(
            to: localizationDirectory.appendingPathComponent("sv.json")
        )
        let manifest = ExtensionManifest(
            identifier: "com.example.loader-test",
            name: "Loader Test",
            version: "0.1.0",
            executable: "bin/extension",
            localizations: [
                .init(locale: "sv", resource: "Localizations/sv.json")
            ]
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .localizationResourceInvalid(
                path: "Localizations/sv.json",
                message: let message
            ) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("printf placeholders"))
        }
    }

    func testInspectorSaysWhichSideIsOutOfDateForAnUnknownManifestFormat() throws {
        func inspect(_ manifest: String) -> ExtensionBundleError? {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingFormat-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("bin", isDirectory: true),
                    withIntermediateDirectories: true
                )
                let executable = root.appendingPathComponent("bin/extension")
                try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path
                )
                try Data(manifest.utf8).write(
                    to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
                )
                _ = try ExtensionBundleInspector.inspect(at: root)
                return nil
            } catch {
                return error as? ExtensionBundleError
            }
        }

        // A package from a future Threading. It may carry fields today's decoder cannot read at
        // all, so the format is checked before the document it describes.
        let future = inspect("""
        {"formatVersion": 2, "identifier": "com.example.f", "name": "F", "version": "1.0.0",
         "executable": "bin/extension", "capabilities": [], "somethingNew": {"a": 1}}
        """)
        guard case .manifestFormatUnsupported(2, 1) = future else {
            return XCTFail("unexpected: \(String(describing: future))")
        }
        XCTAssertTrue(
            future?.errorDescription?.contains("needs a newer version of Threading") == true,
            "the message has to say which side is out of date — \(future?.errorDescription ?? "")"
        )

        let ancient = inspect("""
        {"formatVersion": 0, "identifier": "com.example.a", "name": "A", "version": "1.0.0",
         "executable": "bin/extension", "capabilities": []}
        """)
        XCTAssertTrue(
            ancient?.errorDescription?.contains("no longer supports") == true,
            "an old format is the opposite problem — \(ancient?.errorDescription ?? "")"
        )

        // A manifest with no format version at all is malformed, not incompatible, and must
        // still report the missing field rather than being blamed on a version.
        guard case .manifestUnreadable = inspect("""
        {"identifier": "com.example.m", "name": "M", "version": "1.0.0",
         "executable": "bin/extension", "capabilities": []}
        """) else {
            return XCTFail("a missing formatVersion is a malformed manifest")
        }
    }

    func testInspectorRejectsAnUnknownCapabilityBeforeExecution() throws {
        let directory = try makeBundle(
            capabilities: [.init(rawValue: "network")],
            script: "#!/bin/sh\nexit 99"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .unsupportedCapabilities(let capabilities) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(capabilities, ["network"])
        }
    }

    func testInspectorRejectsAnExecutableSymlinkThatEscapesTheBundle() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("bin/extension")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(
            at: executable,
            withDestinationURL: URL(fileURLWithPath: "/bin/echo")
        )

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .executableEscapesBundle = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInspectorAcceptsANonExecutableWebAssemblyModuleAndChecksItsMagic() throws {
        let directory = try makeWebAssemblyBundle(module: Data([
            0x00, 0x61, 0x73, 0x6D,
            0x01, 0x00, 0x00, 0x00
        ]))
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        XCTAssertEqual(bundle.manifest.runtime, .webAssembly)
        XCTAssertFalse(FileManager.default.isExecutableFile(
            atPath: bundle.executableURL.path
        ))

        try Data("not wasm".utf8).write(to: bundle.executableURL)
        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .webAssemblyModuleInvalid("bin/extension.wasm") =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInspectorRejectsLegacyNetworkAuthorityForSafeWebAssembly() throws {
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            capabilities: [.networkClient]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .unsupportedCapabilities(let capabilities) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(capabilities, ["network.client"])
        }
    }

    func testInspectorResolvesACompanionAppWithoutExecutingIt() throws {
        let companion = ExtensionCompanion(
            id: "simulator",
            bundlePath: "Companions/Simulator.app",
            capabilities: [.processSpawn, .screenCapture, .remoteSurfaces]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [companion]
        )
        try addCompanionApp(
            to: directory,
            declaration: companion,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let inspected = try ExtensionBundleInspector.inspect(at: directory)
        let worker = try XCTUnwrap(inspected.companions.first)
        XCTAssertEqual(worker.declaration, companion)
        XCTAssertEqual(
            worker.bundleIdentifier,
            "com.example.wasm-loader-test.companion.simulator"
        )
        XCTAssertEqual(worker.executableURL.lastPathComponent, "SimulatorWorker")
        XCTAssertTrue(
            worker.signedEntitlements.contains("com.apple.security.app-sandbox")
        )
    }

    func testPackagerRequiresAndPlacesEveryDeclaredCompanionApp() throws {
        let companion = ExtensionCompanion(
            id: "simulator",
            bundlePath: "Companions/Simulator.app",
            capabilities: [.processSpawn, .screenCapture, .remoteSurfaces],
            surfaces: [
                .init(
                    id: "device",
                    title: "Device",
                    accessibilityLabel: "Simulator device display",
                    maximumWidth: 1_920,
                    maximumHeight: 1_200
                )
            ]
        )
        let project = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [companion]
        )
        try addCompanionApp(
            to: project,
            declaration: companion,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: project) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ThreadingPackagedCompanion-\(UUID().uuidString).threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: destination) }
        let manifestURL = project.appendingPathComponent(
            ExtensionBundleInspector.manifestName
        )
        let moduleURL = project.appendingPathComponent("bin/extension.wasm")
        let companionURL = project.appendingPathComponent(
            companion.bundlePath,
            isDirectory: true
        )

        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: moduleURL,
            sourceDirectoryURL: project,
            into: destination
        )) { error in
            guard case .companionBundleRequired("simulator") =
                    error as? ExtensionPackagerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let packaged = try ExtensionPackager.assemble(
            manifestURL: manifestURL,
            executableURL: moduleURL,
            sourceDirectoryURL: project,
            companionBundleURLs: ["simulator": companionURL],
            into: destination
        )
        let worker = try XCTUnwrap(packaged.companions.first)
        XCTAssertEqual(worker.declaration.id, "simulator")
        XCTAssertTrue(worker.bundleURL.path.hasSuffix("Companions/Simulator.app"))
        XCTAssertTrue(
            worker.signedEntitlements.contains("com.apple.security.app-sandbox")
        )
    }

    func testPackagerRejectsAnAppForAnUndeclaredCompanion() throws {
        let project = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        )
        defer { try? FileManager.default.removeItem(at: project) }
        let app = project.appendingPathComponent("Unexpected.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ThreadingUnexpectedCompanion-\(UUID().uuidString).threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertThrowsError(try ExtensionPackager.assemble(
            manifestURL: project.appendingPathComponent(
                ExtensionBundleInspector.manifestName
            ),
            executableURL: project.appendingPathComponent("bin/extension.wasm"),
            sourceDirectoryURL: project,
            companionBundleURLs: ["unexpected": app],
            into: destination
        )) { error in
            guard case .companionNotDeclared("unexpected") =
                    error as? ExtensionPackagerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInspectorRejectsACompanionClaimingAnotherProcessIdentity() throws {
        let companion = ExtensionCompanion(
            id: "simulator",
            bundlePath: "Companions/Simulator.app",
            capabilities: [.screenCapture]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [companion]
        )
        try addCompanionApp(
            to: directory,
            declaration: companion,
            extensionIdentifier: "com.example.wasm-loader-test",
            bundleIdentifier: "com.apple.Simulator"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .companionInvalid(let id, let message) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(id, "simulator")
            XCTAssertTrue(message.contains("CFBundleIdentifier"), message)
        }
    }

    func testInspectorRejectsAnUnknownCompanionCapabilityBeforeLookingForItsApp() throws {
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [
                .init(
                    id: "future",
                    bundlePath: "Companions/Future.app",
                    capabilities: [.init(rawValue: "device.quantum")]
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: directory)) { error in
            guard case .unsupportedCompanionCapabilities(let capabilities) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(capabilities, ["future:device.quantum"])
        }
    }

    func testInspectorRejectsUnsignedOrUndeclaredCompanionAuthority() throws {
        let companion = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.screenCapture]
        )

        let unsigned = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [companion]
        )
        try addCompanionApp(
            to: unsigned,
            declaration: companion,
            extensionIdentifier: "com.example.wasm-loader-test",
            sign: false
        )
        defer { try? FileManager.default.removeItem(at: unsigned) }
        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: unsigned)) { error in
            guard case .companionInvalid("worker", let message) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("signature"), message)
        }

        let overprivileged = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [companion]
        )
        try addCompanionApp(
            to: overprivileged,
            declaration: companion,
            extensionIdentifier: "com.example.wasm-loader-test",
            signedCapabilities: [.networkClient]
        )
        defer { try? FileManager.default.removeItem(at: overprivileged) }
        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: overprivileged)) { error in
            guard case .companionInvalid("worker", let message) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("not declared"), message)
        }
    }

    func testCompanionSupervisorUsesOnlyItsOwnGenerationBoundControlChannel() throws {
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.processSpawn, .screenCapture]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let companion = try XCTUnwrap(bundle.companions.first)
        let policy = RecordingCompanionLaunchPolicy()

        let supervisor = try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "generation-1",
            policy: policy,
            validator: { pinned, _ in pinned }
        )
        let request = try XCTUnwrap(policy.requests.first)
        XCTAssertEqual(request.arguments, ["--threading-companion-serve"])
        XCTAssertEqual(
            Set(request.environment.keys),
            Set([
                ExtensionCompanionEnvironment.extensionIdentifier,
                ExtensionCompanionEnvironment.companionIdentifier,
                ExtensionCompanionEnvironment.generation,
                ExtensionCompanionEnvironment.capabilitiesJSON
            ]),
            "a companion launch request has no field for the Wasm broker token or host data"
        )
        XCTAssertNil(request.environment[ExtensionHostConnection.tokenEnvironmentKey])
        XCTAssertNil(request.environment[ExtensionHostConnection.urlEnvironmentKey])
        XCTAssertEqual(
            request.environment[ExtensionCompanionEnvironment.generation],
            "generation-1"
        )
        XCTAssertEqual(
            request.environment[ExtensionCompanionEnvironment.capabilitiesJSON],
            "[\"process.spawn\",\"screen.capture\"]"
        )
        XCTAssertTrue(supervisor.isRunning)

        guard case .pipe(let input) = request.standardInput else {
            return XCTFail("the companion needs a private control input")
        }
        supervisor.stop()
        let shutdownLine = input.fileHandleForReading.readDataToEndOfFile()
            .split(separator: 0x0A)
            .first
        let shutdown = try JSONDecoder().decode(
            ExtensionCompanionHostMessage.self,
            from: Data(try XCTUnwrap(shutdownLine))
        )
        XCTAssertEqual(
            shutdown,
            .init(type: .shutdown, generation: "generation-1")
        )
    }

    func testRemoteSurfaceCompanionInheritsOnlyItsDedicatedDataDescriptor() throws {
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.remoteSurfaces],
            surfaces: [
                .init(
                    id: "device",
                    title: "Device",
                    accessibilityLabel: "Live device display",
                    maximumWidth: 640,
                    maximumHeight: 480
                )
            ]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let companion = try XCTUnwrap(bundle.companions.first)
        let policy = RecordingCompanionLaunchPolicy()

        let supervisor = try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "generation-1",
            policy: policy,
            validator: { pinned, _ in pinned }
        )
        defer { supervisor.stop() }
        let request = try XCTUnwrap(policy.requests.first)

        XCTAssertNotNil(request.remoteSurfaceDescriptor)
        XCTAssertEqual(
            request.environment[ExtensionCompanionEnvironment.remoteSurfaceDescriptor],
            String(ExtensionRemoteSurfaceConnection.childDescriptorNumber)
        )
        XCTAssertNil(request.environment[ExtensionHostConnection.tokenEnvironmentKey])
        XCTAssertNil(request.environment[ExtensionHostConnection.urlEnvironmentKey])
        XCTAssertEqual(
            Set(request.environment.keys),
            Set([
                ExtensionCompanionEnvironment.extensionIdentifier,
                ExtensionCompanionEnvironment.companionIdentifier,
                ExtensionCompanionEnvironment.generation,
                ExtensionCompanionEnvironment.capabilitiesJSON,
                ExtensionCompanionEnvironment.remoteSurfaceDescriptor
            ])
        )
    }

    func testCompanionSupervisorRelaysOnlyDeclaredCorrelatedOperations() throws {
        let operation = ExtensionCompanionOperation(
            id: "device-status",
            title: "Device Status",
            description: "Returns the current simulator device status."
        )
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            operations: [operation]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            capabilities: [.companionOperations],
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let companion = try XCTUnwrap(bundle.companions.first)
        let policy = RecordingCompanionLaunchPolicy { request in
            let device: ExtensionJSONValue
            if case .object(let arguments) = request.arguments {
                device = arguments["device"] ?? .null
            } else {
                device = .null
            }
            return ExtensionCompanionOperationResponse(
                requestID: request.requestID,
                generation: request.generation,
                operationID: request.operationID,
                value: .object([
                    "state": .string("booted"),
                    "device": device
                ])
            )
        }
        let supervisor = try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "generation-1",
            policy: policy,
            validator: { pinned, _ in pinned }
        )
        defer { supervisor.stop() }

        let relayed = expectation(description: "declared operation relayed")
        supervisor.invokeOperation(
            id: operation.id,
            arguments: .object(["device": .string("iPhone 18")]),
            requestID: "request-1"
        ) { result in
            do {
                let response = try result.get()
                XCTAssertEqual(response.requestID, "request-1")
                XCTAssertEqual(response.generation, "generation-1")
                XCTAssertEqual(response.operationID, operation.id)
                XCTAssertEqual(response.value, .object([
                    "state": .string("booted"),
                    "device": .string("iPhone 18")
                ]))
            } catch {
                XCTFail("declared operation failed: \(error)")
            }
            relayed.fulfill()
        }

        let refused = expectation(description: "undeclared operation refused")
        supervisor.invokeOperation(
            id: "arbitrary-command",
            arguments: .emptyObject
        ) { result in
            defer { refused.fulfill() }
            switch result {
            case .success:
                XCTFail("an undeclared operation was accepted")
            case .failure(let error):
                guard case .operationNotDeclared("arbitrary-command") =
                        error as? ExtensionCompanionSupervisorError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        wait(for: [relayed, refused], timeout: 2)
    }

    func testCompanionExitReportsItsFinalDiagnosticInsteadOfStdoutEOF() throws {
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app"
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let companion = try XCTUnwrap(bundle.companions.first)

        let supervisor = try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "diagnostic-generation",
            policy: ExitingCompanionLaunchPolicy(
                status: 73,
                diagnostic: "screen capture requires user approval"
            ),
            validator: { pinned, _ in pinned }
        )
        let exited = expectation(description: "companion exit")
        supervisor.observeTermination { error in
            guard case .processEnded(let status, let message) =
                    error as? ExtensionCompanionSupervisorError else {
                return XCTFail("unexpected terminal error: \(error)")
            }
            XCTAssertEqual(status, 73)
            XCTAssertEqual(message, "screen capture requires user approval")
            exited.fulfill()
        }
        wait(for: [exited], timeout: 2)
    }

    @MainActor
    func testCompanionSystemPermissionBrokerRequestsOnlyDeclaredInteractiveGrants() throws {
        var screenPreflights = 0
        var screenRequests = 0
        var accessibilityRequests = 0
        let authorizer = SystemExtensionCompanionPermissionAuthorizer(
            screenCapturePreflight: {
                screenPreflights += 1
                return false
            },
            screenCaptureRequest: {
                screenRequests += 1
                return true
            },
            accessibilityRequest: {
                accessibilityRequests += 1
                return true
            }
        )

        try authorizer.authorize(capabilities: [
            .processSpawn,
            .networkClient,
            .remoteSurfaces
        ])
        XCTAssertEqual(screenPreflights, 0)
        XCTAssertEqual(screenRequests, 0)
        XCTAssertEqual(accessibilityRequests, 0)

        try authorizer.authorize(capabilities: [
            .screenCapture,
            .inputControl
        ])
        XCTAssertEqual(screenPreflights, 1)
        XCTAssertEqual(screenRequests, 1)
        XCTAssertEqual(accessibilityRequests, 1)
    }

    func testRemoteSurfaceDataPlaneRoundTripsFrameAndExplicitAcknowledgement() throws {
        let pair = try ExtensionRemoteSurfaceConnection.makePair()
        let child = FileHandle(
            fileDescriptor: pair.childDescriptor,
            closeOnDealloc: true
        )
        defer {
            pair.connection.close()
            try? child.close()
        }

        let received = expectation(description: "host received bounded frame")
        pair.connection.start(
            onPacket: { packet in
                guard case .frame(let frame) = packet.message else {
                    return XCTFail("expected a frame")
                }
                XCTAssertEqual(frame.presentationID, "presentation-1")
                XCTAssertEqual(frame.sequence, 1)
                XCTAssertEqual(packet.payload, Data(repeating: 0x7F, count: 16))
                pair.connection.acknowledge(
                    presentationID: frame.presentationID,
                    sequence: frame.sequence,
                    disposition: .displayed
                )
                received.fulfill()
            },
            onFailure: { error in
                XCTFail("remote-surface channel failed: \(error)")
            }
        )

        try ExtensionRemoteSurfaceWire.write(.init(
            message: .frame(.init(
                presentationID: "presentation-1",
                sequence: 1,
                width: 2,
                height: 2,
                bytesPerRow: 8,
                payloadLength: 16
            )),
            payload: Data(repeating: 0x7F, count: 16)
        ), to: child)

        let response = try XCTUnwrap(
            ExtensionRemoteSurfaceWire.read(from: child)
        )
        guard case .acknowledgement(let acknowledgement) = response.message else {
            return XCTFail("expected an acknowledgement")
        }
        XCTAssertEqual(acknowledgement.presentationID, "presentation-1")
        XCTAssertEqual(acknowledgement.sequence, 1)
        XCTAssertEqual(acknowledgement.disposition, .displayed)
        wait(for: [received], timeout: 2)
    }

    func testRemoteSurfaceDataPlaneRejectsASecondUnacknowledgedFrame() throws {
        let pair = try ExtensionRemoteSurfaceConnection.makePair()
        let child = FileHandle(
            fileDescriptor: pair.childDescriptor,
            closeOnDealloc: true
        )
        defer {
            pair.connection.close()
            try? child.close()
        }

        let first = expectation(description: "first frame received")
        let failed = expectation(description: "second unacknowledged frame rejected")
        pair.connection.start(
            onPacket: { _ in first.fulfill() },
            onFailure: { error in
                guard case .frameBeforeAcknowledgement("presentation-1") =
                        error as? ExtensionRemoteSurfaceConnectionError else {
                    return XCTFail("unexpected failure: \(error)")
                }
                failed.fulfill()
            }
        )
        for sequence: UInt64 in [1, 2] {
            try ExtensionRemoteSurfaceWire.write(.init(
                message: .frame(.init(
                    presentationID: "presentation-1",
                    sequence: sequence,
                    width: 1,
                    height: 1,
                    bytesPerRow: 4,
                    payloadLength: 4
                )),
                payload: Data(repeating: UInt8(sequence), count: 4)
            ), to: child)
        }

        wait(for: [first, failed], timeout: 2)
    }

    /// Opt-in end-to-end dogfood for an advanced extension built by
    /// `Examples/SimulatorRelayExtension/Scripts/package.sh`.
    ///
    /// It is intentionally not a fixture: the test launches the package's real signed
    /// companion through the production supervisor and requires a real Simulator window.
    /// Set `THREADING_SIMULATOR_RELAY_PACKAGE` to the assembled `.threadingextension` path.
    @MainActor
    func testSimulatorRelayDogfoodProducesARealFrameAndAcceptsInput() throws {
        guard let configuredPath = ProcessInfo.processInfo.environment[
            "THREADING_SIMULATOR_RELAY_PACKAGE"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !configuredPath.isEmpty else {
            throw XCTSkip(
                "Set THREADING_SIMULATOR_RELAY_PACKAGE to run Simulator dogfood."
            )
        }
        let packageURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            XCTFail("Simulator relay package does not exist at \(packageURL.path).")
            return
        }
        let bundle = try ExtensionBundleInspector.inspect(
            at: packageURL
        )
        XCTAssertEqual(bundle.manifest.identifier, "codes.threading.simulator-relay")
        let companion = try XCTUnwrap(bundle.companions.first {
            $0.declaration.id == "simulator"
        })
        try SystemExtensionCompanionPermissionAuthorizer().authorize(
            capabilities: companion.declaration.capabilities
        )
        let supervisor = try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "simulator-dogfood",
            policy: LocalExtensionCompanionLaunchPolicy(),
            validator: { pinned, _ in pinned }
        )
        defer { supervisor.stop() }

        let frameReceived = expectation(description: "real Simulator frame received")
        frameReceived.assertForOverFulfill = false
        let outcomeLock = NSLock()
        var terminationMessage: String?
        supervisor.observeTermination { error in
            outcomeLock.lock()
            terminationMessage = error.localizedDescription
            outcomeLock.unlock()
            frameReceived.fulfill()
        }
        supervisor.startRemoteSurfaces { packet in
            guard case .frame(let frame) = packet.message else {
                return XCTFail("expected companion-owned frame")
            }
            XCTAssertEqual(frame.presentationID, "dogfood-presentation")
            XCTAssertEqual(packet.payload.count, frame.payloadLength)
            XCTAssertGreaterThan(frame.width, 100)
            XCTAssertGreaterThan(frame.height, 100)
            XCTAssertGreaterThan(
                Set(packet.payload.prefix(64 * 1024)).count,
                1,
                "the capture was one solid colour rather than a Simulator window"
            )
            if frame.sequence == 1 {
                let outputPath = ProcessInfo.processInfo.environment[
                    "THREADING_SIMULATOR_RELAY_FRAME_PATH"
                ] ?? "/tmp/threading-simulator-relay-frame.png"
                do {
                    try Self.writePNG(
                        bgra: packet.payload,
                        width: frame.width,
                        height: frame.height,
                        bytesPerRow: frame.bytesPerRow,
                        to: URL(fileURLWithPath: outputPath)
                    )
                } catch {
                    XCTFail("could not write dogfood frame: \(error)")
                }
            }
            supervisor.acknowledgeRemoteSurfaceFrame(
                presentationID: frame.presentationID,
                sequence: frame.sequence,
                disposition: .displayed
            )
            frameReceived.fulfill()
        }
        supervisor.sendRemoteSurface(.open(.init(
            presentationID: "dogfood-presentation",
            surfaceID: "simulator-window",
            viewport: .init(
                presentationID: "dogfood-presentation",
                width: 430,
                height: 700,
                scale: 1,
                isVisible: true
            )
        )))
        wait(for: [frameReceived], timeout: 20)
        outcomeLock.lock()
        let earlyTermination = terminationMessage
        outcomeLock.unlock()
        XCTAssertNil(earlyTermination, earlyTermination ?? "")

        supervisor.sendRemoteSurface(.input(.init(
            presentationID: "dogfood-presentation",
            kind: .pointerMoved,
            x: 0.5,
            y: 0.5
        )))
        XCTAssertTrue(supervisor.isRunning)
    }

    func testCompanionSupervisorRejectsAStaleGenerationHandshake() throws {
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app"
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let companion = try XCTUnwrap(bundle.companions.first)
        let policy = RecordingCompanionLaunchPolicy(helloGeneration: "old-generation")

        XCTAssertThrowsError(try ExtensionCompanionSupervisor.start(
            extensionBundle: bundle,
            companion: companion,
            generation: "new-generation",
            policy: policy,
            validator: { pinned, _ in pinned }
        )) { error in
            guard case .invalidHandshake(let message) =
                    error as? ExtensionCompanionSupervisorError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("stale generation"), message)
        }
    }

    func testCompanionRequirementIsRecheckedAgainstCurrentBytesBeforeLaunch() throws {
        let declaration = ExtensionCompanion(
            id: "worker",
            bundlePath: "Companions/Worker.app",
            capabilities: [.screenCapture]
        )
        let directory = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            companions: [declaration]
        )
        try addCompanionApp(
            to: directory,
            declaration: declaration,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinnedBundle = try ExtensionBundleInspector.inspect(at: directory)
        let pinned = try XCTUnwrap(pinnedBundle.companions.first)

        XCTAssertFalse(pinned.designatedRequirementData.isEmpty)
        XCTAssertNoThrow(try ExtensionBundleInspector.revalidateCompanionForLaunch(
            pinned,
            in: pinnedBundle
        ))

        // The package path and manifest remain unchanged, but the executable no longer matches
        // the signature which was inspected for this manager generation.
        try FileManager.default.removeItem(at: pinned.executableURL)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/false"),
            to: pinned.executableURL
        )
        XCTAssertThrowsError(
            try ExtensionBundleInspector.revalidateCompanionForLaunch(
                pinned,
                in: pinnedBundle
            )
        ) { error in
            guard case .companionInvalid("worker", let message) =
                    error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("signature"), message)
        }
    }

    @MainActor
    func testManagerStartsBackgroundCompanionsAndLeavesOnDemandWorkersDormant() async throws {
        let deviceStatus = ExtensionCompanionOperation(
            id: "device-status",
            title: "Device Status",
            description: "Returns the current simulator device status."
        )
        let background = ExtensionCompanion(
            id: "background",
            bundlePath: "Companions/Background.app",
            activation: .whileExtensionEnabled,
            capabilities: [.backgroundService]
        )
        let onDemand = ExtensionCompanion(
            id: "device",
            bundlePath: "Companions/Device.app",
            activation: .onDemand,
            capabilities: [.screenCapture],
            operations: [deviceStatus]
        )
        let source = try makeWebAssemblyBundle(
            module: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]),
            capabilities: [.companionOperations],
            companions: [background, onDemand]
        )
        try addCompanionApp(
            to: source,
            declaration: background,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        try addCompanionApp(
            to: source,
            declaration: onDemand,
            extensionIdentifier: "com.example.wasm-loader-test"
        )
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ThreadingCompanionManager-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        let store = ExtensionPackageStore(rootURL: storeRoot)
        _ = try store.install(from: source)
        let corePolicy = RecordingCoreLaunchPolicy()
        let companionPolicy = RecordingCompanionLaunchPolicy { request in
            ExtensionCompanionOperationResponse(
                requestID: request.requestID,
                generation: request.generation,
                operationID: request.operationID,
                value: .object(["state": .string("booted")])
            )
        }
        let permissionAuthorizer = RecordingCompanionPermissionAuthorizer()
        let manager = ExtensionManager(
            store: store,
            launchPolicy: corePolicy,
            companionLaunchPolicy: companionPolicy,
            companionPermissionAuthorizer: permissionAuthorizer
        )
        defer { manager.terminateAll() }

        try manager.setEnabled(true, identifier: "com.example.wasm-loader-test")
        let becameRunning = await waitUntil {
            let snapshot = manager.installedExtensions.first
            return snapshot?.status == .running(commands: 0, panels: 0, tools: 0)
                && snapshot?.companionStatuses["background"] == .running
        }
        XCTAssertTrue(becameRunning)
        XCTAssertEqual(companionPolicy.requests.count, 1)
        XCTAssertEqual(
            companionPolicy.requests.first?.companion.declaration.id,
            "background"
        )
        XCTAssertEqual(
            manager.installedExtensions.first?.companionStatuses["device"],
            .onDemand
        )
        XCTAssertEqual(permissionAuthorizer.requests, [[.backgroundService]])

        let activated = expectation(description: "on-demand companion operation")
        manager.invokeCompanionOperation(
            extensionIdentifier: "com.example.wasm-loader-test",
            companionID: "device",
            operationID: deviceStatus.id,
            arguments: .emptyObject
        ) { result in
            switch result {
            case .success(let response):
                XCTAssertEqual(
                    response.value,
                    .object(["state": .string("booted")])
                )
            case .failure(let error):
                XCTFail("on-demand operation failed: \(error)")
            }
            activated.fulfill()
        }
        await fulfillment(of: [activated], timeout: 2)
        XCTAssertEqual(companionPolicy.requests.count, 2)
        XCTAssertEqual(
            manager.installedExtensions.first?.companionStatuses["device"],
            .running
        )
        XCTAssertEqual(
            permissionAuthorizer.requests,
            [[.backgroundService], [.screenCapture]]
        )

        try manager.setEnabled(false, identifier: "com.example.wasm-loader-test")
        XCTAssertEqual(
            manager.installedExtensions.first?.companionStatuses,
            ["background": .disabled, "device": .disabled]
        )
    }

    func testWebAssemblyLaunchPolicyPassesTheValidatedModuleAsDescriptorFour() throws {
        let directory = try makeWebAssemblyBundle(module: Data([
            0x00, 0x61, 0x73, 0x6D,
            0x01, 0x00, 0x00, 0x00
        ]))
        let runnerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingFakeWasmRunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: runnerDirectory,
            withIntermediateDirectories: true
        )
        let runner = runnerDirectory.appendingPathComponent("runner")
        try Data("""
        #!/bin/bash
        [ "$1" = "--threading-register" ] || exit 64
        magic="$(od -An -tx1 -N4 <&4 | tr -d ' \\n')"
        [ "$magic" = "0061736d" ] || exit 65
        printf '{}'
        """.utf8).write(to: runner)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runner.path
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: runnerDirectory)
        }

        let registration = try ExtensionRegistrationLoader.load(
            from: ExtensionBundleInspector.inspect(at: directory),
            policy: WasmLaunchPolicy(runnerURL: runner)
        )
        XCTAssertEqual(registration, .init())
    }

    func testEmbeddedSandboxedRunnerExecutesARealWASIRegistrationModule() throws {
        let policy = WasmLaunchPolicy()
        try XCTSkipUnless(
            policy.runnerURL() != nil,
            "no built WebAssembly runner in this app bundle"
        )
        let fixture = try XCTUnwrap(Self.repositoryRoot)
            .appendingPathComponent("Tests/Fixtures/Extensions/registration.wasm")
        let directory = try makeWebAssemblyBundle(module: Data(contentsOf: fixture))
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            try ExtensionRegistrationLoader.load(
                from: ExtensionBundleInspector.inspect(at: directory),
                policy: policy
            ),
            .init()
        )
    }

    func testBuiltAppShipsACompleteVersionedExtensionSDKSnapshot() throws {
        let extensionSDK = try XCTUnwrap(Bundle.main.resourceURL?
            .appendingPathComponent("ExtensionSDK", isDirectory: true))
        let sdk = extensionSDK.appendingPathComponent(
            "ThreadingExtensionKit",
            isDirectory: true
        )
        let documentation = extensionSDK.appendingPathComponent(
            "docs/extensions",
            isDirectory: true
        )
        XCTAssertEqual(
            try String(
                contentsOf: sdk.appendingPathComponent("SDK_VERSION"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sdk.appendingPathComponent("Package.swift").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sdk.appendingPathComponent(
                "Sources/ThreadingExtensionKit/ExtensionManifest.swift"
            ).path
        ))
        for requiredPath in [
            "AGENT_AUTHORING.md",
            "API_V1.md",
            "schema/extension-manifest.schema.json",
            "generated/component-catalog.json"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: documentation.appendingPathComponent(requiredPath).path
                ),
                "missing embedded extension authoring contract: \(requiredPath)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sdk.appendingPathComponent(".build").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sdk.appendingPathComponent(
                "Examples/SimulatorRelayExtension/Build"
            ).path
        ))
    }

    func testRegistrationProcessIsTerminatedWhenItTimesOut() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nwhile :; do :; done"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        XCTAssertThrowsError(
            try ExtensionRegistrationLoader.load(from: bundle, timeout: 0.05)
        ) { error in
            guard case .timedOut = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRegistrationOutputIsCapped() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nwhile :; do printf 'xxxxxxxxxxxxxxxx'; done"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        XCTAssertThrowsError(
            try ExtensionRegistrationLoader.load(
                from: bundle,
                timeout: 1,
                maximumOutput: 128
            )
        ) { error in
            guard case .outputTooLarge(let maximum) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(maximum, 128)
        }
    }

    func testRegistrationIsValidatedAgainstTheInspectedManifest() throws {
        let registration = ExtensionRegistration(
            commands: [.init(id: "undeclared", title: "Not allowed")]
        )
        let json = String(
            decoding: try JSONEncoder().encode(registration),
            as: UTF8.self
        )
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nprintf '%s' \(shellQuoted(json))"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        XCTAssertThrowsError(
            try ExtensionRegistrationLoader.load(from: bundle)
        ) { error in
            guard case .invalidRegistration(let message) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("commands"))
        }
    }

    func testSandboxPolicyMapsStorageAndTheExactHostPort() throws {
        let directory = try makeBundle(
            capabilities: [.hostProjectsRead, .keyValueStorage],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        let storage = directory.appendingPathComponent("state", isDirectory: true)

        let profile = try ExtensionSandboxPolicy.profile(
            bundle: bundle,
            environment: [
                ExtensionStorageEnvironment.keyValueDirectory: storage.path,
                ExtensionStorageEnvironment.cacheDirectory: "/private/tmp/not-granted",
                ExtensionHostConnection.urlEnvironmentKey: "http://127.0.0.1:43127"
            ]
        )

        XCTAssertTrue(profile.contains("(subpath \"\(storage.path)\")"))
        XCTAssertFalse(profile.contains("/private/tmp/not-granted"))
        XCTAssertTrue(profile.contains("(remote tcp \"localhost:43127\")"))
        XCTAssertFalse(profile.contains("(remote udp)"))
        XCTAssertFalse(profile.contains("(allow process-fork"))
        XCTAssertFalse(profile.contains("/usr/bin/touch"))
        XCTAssertTrue(profile.contains("(deny mach-lookup"))
        XCTAssertTrue(profile.contains("com.apple.securityd.xpc"))
        XCTAssertFalse(profile.contains("(allow mach-lookup\n"
            + "                (global-name \"com.apple.securityd.xpc\")"))
    }

    func testNetworkClientCapabilityAllowsOutboundButNotInboundNetwork() throws {
        let directory = try makeBundle(
            capabilities: [.networkClient],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let profile = try ExtensionSandboxPolicy.profile(
            bundle: bundle,
            environment: [:]
        )

        XCTAssertTrue(profile.contains("(remote tcp)"))
        XCTAssertTrue(profile.contains("(remote udp)"))
        XCTAssertFalse(profile.contains("network-inbound"))
    }

    func testBrokerOnlyCapabilitiesReceiveOnlyTheExactHostPort() throws {
        let directory = try makeBundle(
            capabilities: [.servicesConsume, .secrets],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let profile = try ExtensionSandboxPolicy.profile(
            bundle: bundle,
            environment: [
                ExtensionHostConnection.urlEnvironmentKey:
                    "http://127.0.0.1:43128/v1"
            ]
        )

        XCTAssertTrue(profile.contains("(remote tcp \"localhost:43128\")"))
        XCTAssertFalse(profile.contains("(remote tcp)"))
        XCTAssertFalse(profile.contains("(remote udp)"))
        XCTAssertFalse(profile.contains("file-write"))
    }

    func testSandboxLaunchFailsClosedWhenTheWrapperIsUnavailable() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)
        XCTAssertThrowsError(try ExtensionSandboxPolicy.launch(
            bundle: bundle,
            commandArguments: ["--threading-serve"],
            environment: [:],
            sandboxExecutableURL: URL(fileURLWithPath: "/does/not/exist")
        )) { error in
            guard case .unavailable = error as? ExtensionSandboxError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testSandboxRejectsAnExtensionControlledInterpreterOutsideTheAllowlist() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/usr/bin/env bash\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        XCTAssertThrowsError(try ExtensionSandboxPolicy.launch(
            bundle: bundle,
            commandArguments: ["--threading-serve"],
            environment: [:]
        )) { error in
            guard case .unsupportedInterpreter("/usr/bin/env") =
                    error as? ExtensionSandboxError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Launch abstraction

    func testRegistrationAndServeShareOneLaunchAbstraction() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let probe = RecordingLaunchPolicy()
        _ = try? ExtensionRegistrationLoader.load(from: bundle, policy: probe)
        XCTAssertEqual(probe.requests.first?.arguments, ["--threading-register"])
        XCTAssertEqual(probe.requests.first?.additionalEnvironment, [:])
        guard case .nullDevice = probe.requests.first?.standardInput else {
            return XCTFail("a registration probe must not be given a writable stdin")
        }

        let serve = RecordingLaunchPolicy()
        XCTAssertThrowsError(try ExtensionProcessSession.start(
            bundle: bundle,
            policy: serve,
            additionalEnvironment: ["THREADING_EXTENSION_HOST_TOKEN": "abc"]
        ))
        XCTAssertEqual(serve.requests.first?.arguments, ["--threading-serve"])
        XCTAssertEqual(
            serve.requests.first?.additionalEnvironment["THREADING_EXTENSION_HOST_TOKEN"],
            "abc"
        )
        guard case .pipe = serve.requests.first?.standardInput else {
            return XCTFail("a persistent session needs a writable stdin")
        }
        XCTAssertEqual(serve.requests.first?.bundle.rootURL, bundle.rootURL)
    }

    func testTheChildEnvironmentIsTheHostBasePlusHostAdditions() {
        let composed = ExtensionLaunchEnvironment.composed(
            with: ["THREADING_EXTENSION_HOST_URL": "http://127.0.0.1:1"]
        )
        XCTAssertEqual(composed["THREADING_EXTENSION_PROTOCOL"], "1")
        XCTAssertEqual(composed["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(composed["THREADING_EXTENSION_HOST_URL"], "http://127.0.0.1:1")
        XCTAssertNil(composed["HOME"])
        XCTAssertNil(composed["THREADING_MCP_PORT"])
    }

    func testAnExitObserverInstalledAfterTheChildDiedStillReceivesTheStatus() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 7"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try SandboxExecLaunchPolicy().spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-register"],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr)
            )
        )
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationStatus, 7)

        // The runner policy learns of an exit from a message rather than from `waitpid`, so the
        // supervisor installs its observer after the spawn returns. A child which raced ahead of
        // that must still report, or a fast crash would leave the session waiting on its timeout.
        let observed = expectation(description: "exit status")
        var status: Int32?
        child.observeExit { value in
            status = value
            observed.fulfill()
        }
        wait(for: [observed], timeout: 1)
        XCTAssertEqual(status, 7)

        // Terminating an already-dead child is a supervisor's normal teardown path.
        child.terminate()
        child.kill()
    }

    // MARK: - Containment

    /// Measures the containment rather than asserting the profile's text.
    ///
    /// Every other sandbox test here reads the generated profile, which proves what we *wrote*
    /// and not what the kernel *enforced*. This one runs a probe inside the sandbox and reads
    /// back what it managed to do. It is deliberately built from shell builtins: a probe that
    /// shelled out to `curl` would be measuring `process-exec` denial in every case and calling
    /// it a network result.
    ///
    /// `readsOwnPackage` is the positive control and is load-bearing. A suite that only ever
    /// asserts denial cannot tell containment from a probe that silently does nothing.
    func testTheSandboxDeniesEverythingAnExtensionDidNotDeclare() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingProbeOutside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let escape = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingProbeEscape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: escape) }

        // A real listener, so a refused connection is the sandbox refusing it. Aiming the probe
        // at a closed port would report "denied" on a machine with no sandbox at all.
        let listener = try makeListener()
        defer { close(listener.descriptor) }

        let directory = try makeBundle(
            capabilities: [],
            script: """
            #!/bin/bash
            # `/bin/bash`, not `/bin/sh`. The launcher runs a `#!/bin/sh` package as
            # `bash --posix`, and posix mode exits the shell on *any* redirection error — so a
            # probe written that way dies at its first denial and reports the rest as silence.
            #
            # Each probe is also written out rather than routed through a helper: a redirection
            # passed as an argument applies to the helper, so `> file` would have captured the
            # report itself.

            # The positive control: an extension may always read its own package.
            if read -r _ < "$0" 2>/dev/null
            then printf 'readsOwnPackage=allowed\\n'
            else printf 'readsOwnPackage=denied\\n'
            fi

            if read -r _ < \(shellQuoted(outside.path)) 2>/dev/null
            then printf 'readsOutsidePackage=allowed\\n'
            else printf 'readsOutsidePackage=denied\\n'
            fi

            if printf x > \(shellQuoted(escape.path)) 2>/dev/null
            then printf 'writesOutsidePackage=allowed\\n'
            else printf 'writesOutsidePackage=denied\\n'
            fi

            if printf x > "$0.written" 2>/dev/null
            then printf 'writesOwnPackage=allowed\\n'
            else printf 'writesOwnPackage=denied\\n'
            fi

            if printf '' > /dev/tcp/127.0.0.1/\(listener.port) 2>/dev/null
            then printf 'opensOutboundTCP=allowed\\n'
            else printf 'opensOutboundTCP=denied\\n'
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try SandboxExecLaunchPolicy().spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-probe"],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr)
            )
        )
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()

        let report = String(decoding: output, as: UTF8.self)
        var outcomes: [String: String] = [:]
        for line in report.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            outcomes[String(parts[0])] = String(parts[1])
        }

        // A probe that says nothing is the failure this message has to explain: silence looks
        // identical to total denial, and is usually the probe itself being broken.
        let transcript = """
            status \(child.terminationStatus)
            stdout: \(report.isEmpty ? "<empty>" : report)
            stderr: \(String(decoding: diagnostics, as: UTF8.self))
            """
        XCTAssertEqual(
            outcomes["readsOwnPackage"],
            "allowed",
            "the probe read nothing at all, so its denials prove nothing —\n\(transcript)"
        )
        for denied in [
            "readsOutsidePackage",
            "writesOutsidePackage",
            "writesOwnPackage",
            "opensOutboundTCP"
        ] {
            XCTAssertEqual(outcomes[denied], "denied", "\(denied) —\n\(transcript)")
        }

        // Denial is not merely a non-zero status inside the sandbox: nothing may reach disk.
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundle.executableURL.path + ".written"
            )
        )
    }

    /// The other half of the network measurement, and the reason the denial half means
    /// anything.
    ///
    /// The same probe against the same listener, differing only in the manifest's declared
    /// `network.client`. Without this, "denied" could equally be a broken probe, a closed port,
    /// or a machine where nothing is contained at all.
    func testDeclaringNetworkClientIsWhatOpensTheOutboundPath() throws {
        let listener = try makeListener()
        defer { close(listener.descriptor) }

        func probeNetwork(capabilities: Set<ExtensionCapability>) throws -> String {
            let directory = try makeBundle(
                capabilities: capabilities,
                script: """
                #!/bin/bash
                if printf '' > /dev/tcp/127.0.0.1/\(listener.port) 2>/dev/null
                then printf 'opensOutboundTCP=allowed\\n'
                else printf 'opensOutboundTCP=denied\\n'
                fi
                """
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let stdout = Pipe()
            let stderr = Pipe()
            let child = try SandboxExecLaunchPolicy().spawn(
                ExtensionLaunchRequest(
                    bundle: try ExtensionBundleInspector.inspect(at: directory),
                    arguments: ["--threading-probe"],
                    standardOutput: .pipe(stdout),
                    standardError: .pipe(stderr)
                )
            )
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        XCTAssertEqual(try probeNetwork(capabilities: []), "opensOutboundTCP=denied")
        XCTAssertEqual(
            try probeNetwork(capabilities: [.networkClient]),
            "opensOutboundTCP=allowed"
        )
    }

    /// Spawning another program is measured on its own, because it is denied differently.
    ///
    /// The other refusals hand the extension an error it can see and carry on from. This one
    /// **ends the process**: the attempt does not return, so a probe that ran it alongside the
    /// others would report every later case as silence — which is exactly what it did before
    /// this was split out. A launcher expecting a graceful error here would be wrong.
    func testTheSandboxEndsAnExtensionThatTriesToRunAnotherProgram() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingProbeSpawned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        let directory = try makeBundle(
            capabilities: [],
            script: """
            #!/bin/bash
            printf 'started=yes\\n'
            /bin/ls / >/dev/null 2>&1
            printf 'executesAnotherProgram=allowed\\n'
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try SandboxExecLaunchPolicy().spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-probe"],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr)
            )
        )
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()

        let report = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(
            report.contains("started=yes"),
            "the probe never ran, so its silence proves nothing — \(report)"
        )
        XCTAssertFalse(
            report.contains("executesAnotherProgram=allowed"),
            "an extension reached another program — \(report)"
        )
        XCTAssertNotEqual(
            child.terminationStatus,
            0,
            "the attempt neither ran nor ended the process, which is a third behaviour worth "
                + "understanding before the signed runner relies on either"
        )
    }

    func testTheDescriptorConnectionAnswersRequestsInOrderOverOneSocket() throws {
        let queue = DispatchQueue(label: "test.extension-host-descriptor")
        var seen: [String] = []
        let answered = expectation(description: "two answers")
        answered.expectedFulfillmentCount = 2

        let pair = try XCTUnwrap(ExtensionHostDescriptorConnection.makePair(
            queue: queue,
            handler: { request, respond in
                seen.append(request.path)
                respond(.json(Data("{\"ok\":true}".utf8)))
                answered.fulfill()
            },
            onClose: { _ in }
        ))
        defer {
            pair.connection.cancel()
            close(pair.childDescriptor)
        }

        let child = FileHandle(fileDescriptor: pair.childDescriptor, closeOnDealloc: false)
        for path in ["/v1/sessions", "/v1/projects"] {
            let request = "GET \(path) HTTP/1.1\r\n"
                + "Authorization: Bearer token\r\n"
                + "Content-Length: 0\r\n\r\n"
            try child.write(contentsOf: Data(request.utf8))
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(seen, ["/v1/sessions", "/v1/projects"])

        var replies = ""
        while replies.components(separatedBy: "HTTP/1.1 200 OK").count - 1 < 2 {
            let chunk = child.availableData
            XCTAssertFalse(chunk.isEmpty, "the host closed before answering")
            replies += String(decoding: chunk, as: UTF8.self)
        }
        XCTAssertEqual(
            replies.components(separatedBy: "{\"ok\":true}").count - 1,
            2,
            "each request must be answered exactly once on the shared socket"
        )
    }

    func testTheExperimentalLauncherRefusesToPassABrokerDescriptor() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        // Refusing is the honest answer: `Process` cannot install a descriptor past the three
        // standard streams, and a child launched without its broker would report every host
        // call as a configuration failure rather than as a launch that could not be contained.
        XCTAssertThrowsError(try SandboxExecLaunchPolicy().spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-serve"],
                standardInput: .pipe(Pipe()),
                standardOutput: .pipe(Pipe()),
                standardError: .pipe(Pipe()),
                extraDescriptors: [ExtensionHostDescriptorConnection.childDescriptorNumber: 9]
            )
        )) { error in
            guard case .descriptorPassingUnsupported = error as? ExtensionLaunchPolicyError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testALaunchPolicyFailureIsReportedAsALaunchFailure() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/sh\nexit 0"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        XCTAssertThrowsError(try ExtensionRegistrationLoader.load(
            from: bundle,
            policy: RecordingLaunchPolicy(underlying: RefusingLaunchPolicy())
        )) { error in
            guard case .launchFailed(let message) = error as? ExtensionBundleError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("containment"))
        }

        XCTAssertThrowsError(try ExtensionProcessSession.start(
            bundle: bundle,
            policy: RefusingLaunchPolicy()
        )) { error in
            guard case .launchFailed = error as? ExtensionProcessError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Descriptor-passing spawn

    func testTheSpawnerInstallsABrokerDescriptorPastTheStandardStreams() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: """
            #!/bin/bash
            printf 'argument=%s\\n' "$1"
            printf 'environment=%s\\n' "$THREADING_PROBE"
            read -r line <&3
            printf 'broker=%s\\n' "$line"
            if read -r _ <&4 2>/dev/null
            then printf 'unmappedDescriptor=inherited\\n'
            else printf 'unmappedDescriptor=closed\\n'
            fi
            """
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let stdout = Pipe()
        let broker = Pipe()
        // Deliberately left out of the descriptor map. `POSIX_SPAWN_CLOEXEC_DEFAULT` means the
        // child inherits exactly what it was given, and this proves that rather than assuming
        // it — an extension inheriting a stray descriptor would be a hole no profile can close.
        let unmapped = Pipe()
        defer { try? unmapped.fileHandleForWriting.close() }

        let child = try ExtensionChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [bundle.executableURL.path, "--threading-serve"],
            environment: ["THREADING_PROBE": "present"],
            workingDirectory: bundle.rootURL,
            descriptors: [
                0: FileHandle.nullDevice.fileDescriptor,
                1: stdout.fileHandleForWriting.fileDescriptor,
                2: FileHandle.nullDevice.fileDescriptor,
                3: broker.fileHandleForReading.fileDescriptor
            ]
        )
        try stdout.fileHandleForWriting.close()
        try broker.fileHandleForWriting.write(contentsOf: Data("hello-from-host\n".utf8))
        try broker.fileHandleForWriting.close()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        child.waitUntilExit()

        XCTAssertTrue(output.contains("argument=--threading-serve"), output)
        XCTAssertTrue(output.contains("environment=present"), output)
        XCTAssertTrue(output.contains("broker=hello-from-host"), output)
        XCTAssertTrue(output.contains("unmappedDescriptor=closed"), output)
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testTheSpawnerReportsAnExitStatusToALateObserver() throws {
        let directory = try makeBundle(
            capabilities: [],
            script: "#!/bin/bash\nexit 9"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ExtensionBundleInspector.inspect(at: directory)

        let child = try ExtensionChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [bundle.executableURL.path],
            environment: [:],
            workingDirectory: nil,
            descriptors: [
                0: FileHandle.nullDevice.fileDescriptor,
                1: FileHandle.nullDevice.fileDescriptor,
                2: FileHandle.nullDevice.fileDescriptor
            ]
        )
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationStatus, 9)

        let observed = expectation(description: "late exit observer")
        var status: Int32?
        child.observeExit {
            status = $0
            observed.fulfill()
        }
        wait(for: [observed], timeout: 2)
        XCTAssertEqual(status, 9)

        // Reaping already happened; these must be safe no-ops rather than signalling a pid the
        // kernel may since have reused.
        child.terminate()
        child.kill()
    }

    func testTheSpawnerFailsRatherThanRunningTheWrongThing() {
        XCTAssertThrowsError(try ExtensionChildSpawner.spawn(
            executableURL: URL(fileURLWithPath: "/does/not/exist"),
            arguments: [],
            environment: [:],
            workingDirectory: nil,
            descriptors: [:]
        )) { error in
            guard case .spawnFailed = error as? ExtensionSpawnError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - The contained helper

    /// The whole containment, end to end, through the helper that actually ships.
    ///
    /// The package has to live in the real install root, because the helper's read-only
    /// entitlement names that exact path — which is the point of the entitlement. It is created
    /// under a test-only identifier and removed again; the app's own packages are untouched.
    func testTheSignedHelperRunsAnExtensionAndContainsIt() throws {
        let policy = HelperLaunchPolicy()
        try XCTSkipUnless(
            policy.helperURL(for: []) != nil,
            "no built helper in this bundle — run through the app-hosted test target"
        )

        let installRoot = try XCTUnwrap(ExtensionRunnerValidator.installRootPath())
        let package = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent(
                "codes.threading.tests.\(UUID().uuidString).threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: package) }

        let escape = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingHelperEscape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: escape) }

        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifest = ExtensionManifest(
            identifier: "codes.threading.tests.helper",
            name: "Helper Probe",
            version: "0.1.0",
            executable: "bin/extension",
            capabilities: []
        )
        try JSONEncoder().encode(manifest).write(
            to: package.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        let executable = package.appendingPathComponent("bin/extension")
        try Data("""
        #!/bin/bash
        if read -r _ < "$0"
        then printf 'readsOwnPackage=allowed\\n'
        else printf 'readsOwnPackage=denied\\n'
        fi
        if printf x > \(shellQuoted(escape.path)) 2>/dev/null
        then printf 'writesOutsidePackage=allowed\\n'
        else printf 'writesOutsidePackage=denied\\n'
        fi
        if printf x > "$0.written" 2>/dev/null
        then printf 'writesOwnPackage=allowed\\n'
        else printf 'writesOwnPackage=denied\\n'
        fi
        read -r broker <&3
        printf 'broker=%s\\n' "$broker"
        printf 'entryMode=%s\\n' "$1"

        """.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let bundle = try ExtensionBundleInspector.inspect(at: package)
        let stdout = Pipe()
        let stderr = Pipe()
        let broker = Pipe()

        let child = try policy.spawn(
            ExtensionLaunchRequest(
                bundle: bundle,
                arguments: ["--threading-serve"],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr),
                extraDescriptors: [
                    ExtensionHostDescriptorConnection.childDescriptorNumber:
                        broker.fileHandleForReading.fileDescriptor
                ]
            )
        )
        try broker.fileHandleForWriting.write(contentsOf: Data("hello-broker\n".utf8))
        try broker.fileHandleForWriting.close()

        let report = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let diagnostics = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        child.waitUntilExit()
        let transcript = "status \(child.terminationStatus)\nout: \(report)\nerr: \(diagnostics)"

        XCTAssertTrue(report.contains("entryMode=--threading-serve"), transcript)
        // The positive controls: the extension ran, read its package, and was handed the broker
        // on a descriptor that survived the helper's exec.
        XCTAssertTrue(report.contains("readsOwnPackage=allowed"), transcript)
        XCTAssertTrue(report.contains("broker=hello-broker"), transcript)
        // And it is contained without a single line of profile written by us.
        XCTAssertTrue(report.contains("writesOutsidePackage=denied"), transcript)
        XCTAssertTrue(report.contains("writesOwnPackage=denied"), transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path), transcript)
    }

    /// Runs the compiled `DenialProbeExtension` inside the containment and reads back what it
    /// managed to do.
    ///
    /// This is the only test that measures the sandbox rather than the profile or the
    /// entitlements file, and it exists because that distinction was not academic: Xcode's
    /// injected debug entitlements once granted the helper read access to all of `/`, so the
    /// containment was off in Debug builds while every other test stayed green.
    ///
    /// It needs the probe built, which the verification baseline already does. When it is
    /// absent the test skips and names the command, rather than passing quietly.
    ///
    /// **The helper is re-signed before it is used, and that is not incidental.** The
    /// `xcodebuild test` action injects its own entitlements into every target it builds —
    /// including the `/` exception and the `testmanagerd` lookups — overriding
    /// `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`. The copy in `Contents/Helpers` after a test
    /// build is therefore *not* the copy that ships, and probing it would measure Xcode's
    /// debugging affordances rather than the containment. So this signs the built binary with
    /// the entitlements file the product actually uses, and probes that.
    func testTheCompiledProbeIsContainedByTheSignedHelper() throws {
        let policy = HelperLaunchPolicy()
        let builtHelper = try XCTUnwrap(
            policy.helperURL(for: []),
            "no built helper in this bundle — run through the app-hosted test target"
        )
        let repository = try XCTUnwrap(Self.repositoryRoot)
        let helper = try Self.resigned(
            builtHelper,
            entitlements: repository
                .appendingPathComponent("Helper/threading-extension-helper.entitlements")
        )
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let probe = repository.appendingPathComponent(
            "ThreadingExtensionKit/.build/\(Self.hostTriple)/debug/DenialProbeExtension"
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: probe.path),
            "build it first: swift build --package-path ThreadingExtensionKit "
                + "--product DenialProbeExtension"
        )

        // The package must live in the real install root: the helper's entitlement names that
        // exact path, which is the whole point of the entitlement.
        let installRoot = try XCTUnwrap(ExtensionRunnerValidator.installRootPath())
        let package = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent(
                "codes.threading.tests.probe.\(UUID().uuidString).threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "codes.threading.tests.probe",
            name: "Denial Probe",
            version: "1.0.0",
            executable: "bin/extension",
            capabilities: [.panels]
        )).write(to: package.appendingPathComponent(ExtensionBundleInspector.manifestName))
        try FileManager.default.copyItem(
            at: probe,
            to: package.appendingPathComponent("bin/extension")
        )

        // Seed the exact production namespace with real bytes. The child asks for this precise
        // service/account and requests kSecReturnData, so "denied" proves isolation rather than
        // merely proving that a fictional item was absent.
        let secretKey = "containment-probe"
        try KeychainExtensionSecretStore.shared.setData(
            Data("host-only-secret".utf8),
            extensionIdentifier: "codes.threading.tests.probe",
            key: secretKey
        )
        defer {
            try? KeychainExtensionSecretStore.shared.remove(
                extensionIdentifier: "codes.threading.tests.probe",
                key: secretKey
            )
        }

        let bundle = try ExtensionBundleInspector.inspect(at: package)
        let stdout = Pipe()
        let stderr = Pipe()
        let child = try ExtensionChildSpawner.spawn(
            executableURL: helper,
            arguments: [
                bundle.rootURL.path,
                bundle.executableURL.path,
                "--threading-register"
            ],
            environment: ExtensionLaunchEnvironment.base,
            workingDirectory: bundle.rootURL,
            descriptors: [
                0: FileHandle.nullDevice.fileDescriptor,
                1: stdout.fileHandleForWriting.fileDescriptor,
                2: stderr.fileHandleForWriting.fileDescriptor
            ]
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        let report = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        child.waitUntilExit()

        var outcomes: [String: String] = [:]
        for line in report.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            outcomes[String(parts[0])] = String(parts[1])
        }

        XCTAssertEqual(
            outcomes["readsOwnPackage"],
            "allowed",
            "the probe read nothing at all, so its denials prove nothing —\n\(report)"
        )
        for denied in [
            "readsHomeDirectory",
            "readsProjectDatabase",
            "readsExtensionsRoot",
            "writesOwnPackage",
            "writesTemporaryDirectory",
            "listensOnATCPPort",
            "readsExtensionSecrets",
            // Spawning is *permitted* under App Sandbox where the Seatbelt profile denied it.
            // What has to hold is that the child is contained too — a child that escaped would
            // make the whole boundary a formality.
            "spawnedChildEscapes"
        ] {
            XCTAssertEqual(outcomes[denied], "denied", "\(denied) —\n\(report)")
        }

        XCTAssertEqual(
            outcomes["spawnsAnotherProgram"],
            "denied",
            "an unsupervised descendant can outlive disable or uninstall —\n\(report)"
        )

        // `readsAnyKeychainItem` remains observational: Keychain may expose metadata belonging
        // to the helper's own access group. The exact seeded secret above is the security gate.
    }

    /// The cooperative probe above disables Keychain UI itself. This one deliberately does
    /// not: it asks for real bytes using Security.framework's default interactive behaviour.
    /// The generated Seatbelt policy must deny the securityd connection before an ACL can ask
    /// the user anything. A timeout kills the process so a regression cannot leave CI — or a
    /// developer — blocked behind a dialog.
    func testTheSandboxPreventsAnAdversarialExtensionFromRaisingAKeychainPrompt() throws {
        let repository = try XCTUnwrap(Self.repositoryRoot)
        let probe = repository.appendingPathComponent(
            "ThreadingExtensionKit/.build/\(Self.hostTriple)/debug/DenialProbeExtension"
        )
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: probe.path),
            "build it first: swift build --package-path ThreadingExtensionKit "
                + "--product DenialProbeExtension"
        )

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codes.threading.tests.adversarial-keychain.\(UUID().uuidString)"
                    + ".threadingextension",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: package) }
        try FileManager.default.createDirectory(
            at: package.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ExtensionManifest(
            identifier: "codes.threading.tests.probe",
            name: "Adversarial Keychain Probe",
            version: "1.0.0",
            executable: "bin/extension",
            capabilities: [.panels]
        )).write(to: package.appendingPathComponent(ExtensionBundleInspector.manifestName))
        try FileManager.default.copyItem(
            at: probe,
            to: package.appendingPathComponent("bin/extension")
        )

        let secretKey = "containment-probe"
        try KeychainExtensionSecretStore.shared.setData(
            Data("host-only-secret".utf8),
            extensionIdentifier: "codes.threading.tests.probe",
            key: secretKey
        )
        defer {
            try? KeychainExtensionSecretStore.shared.remove(
                extensionIdentifier: "codes.threading.tests.probe",
                key: secretKey
            )
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try SandboxExecLaunchPolicy().spawn(
            ExtensionLaunchRequest(
                bundle: try ExtensionBundleInspector.inspect(at: package),
                arguments: ["--threading-register"],
                additionalEnvironment: [
                    "THREADING_EXTENSION_ADVERSARIAL_KEYCHAIN_PROBE": "1"
                ],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr)
            )
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        let exited = expectation(description: "the denied Keychain query returns without UI")
        var status: Int32?
        child.observeExit { value in
            status = value
            exited.fulfill()
        }
        let waitResult = XCTWaiter.wait(for: [exited], timeout: 2)
        if waitResult != .completed {
            child.kill()
            child.waitUntilExit()
            return XCTFail(
                "the extension did not return promptly; a Keychain authorization UI may "
                    + "have escaped the sandbox"
            )
        }

        let report = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(status, 0, report)
        XCTAssertTrue(report.contains("readsOwnPackage=allowed"), report)
        XCTAssertTrue(report.contains("readsExtensionSecrets=denied"), report)
    }

    /// Copies a built helper and signs it with the entitlements the product ships, returning
    /// the copy.
    ///
    /// Ad-hoc signing is enough to carry entitlements — App Sandbox does not require a real
    /// identity, only a signature — which is what makes this measurable without one.
    private static func resigned(
        _ helper: URL,
        entitlements: URL
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingHelperResign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(helper.lastPathComponent)
        try FileManager.default.copyItem(at: helper, to: copy)

        try run("/usr/bin/codesign", [
            "--force", "--sign", "-",
            "--entitlements", entitlements.path,
            copy.path
        ])

        // The re-sign has to have actually replaced them. If Xcode's `/` exception survived,
        // every read assertion below would pass for the wrong reason — which is precisely the
        // failure this test exists to catch.
        let applied = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", copy.path])
        XCTAssertFalse(
            applied.contains("absolute-path.read-only"),
            "the shipping entitlements still grant a broad filesystem read:\n\(applied)"
        )
        return copy
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static let hostTriple: String = {
        #if arch(arm64)
        return "arm64-apple-macosx"
        #else
        return "x86_64-apple-macosx"
        #endif
    }()

    /// Located from `#filePath` rather than the test bundle, so the probe needs no copy into
    /// app resources to be found.
    private static let repositoryRoot: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testTheHelperRefusesAPackageOutsideTheInstallRoot() throws {
        let policy = HelperLaunchPolicy()
        try XCTSkipUnless(
            policy.helperURL(for: []) != nil,
            "no built helper in this bundle"
        )

        // A perfectly valid package — in the wrong place. The app would never ask for this;
        // the helper refuses it anyway, because a broker that trusts its caller is not a
        // boundary.
        let directory = try makeBundle(capabilities: [], script: "#!/bin/bash\nexit 0")
        defer { try? FileManager.default.removeItem(at: directory) }

        let stdout = Pipe()
        let stderr = Pipe()
        let child = try policy.spawn(
            ExtensionLaunchRequest(
                bundle: try ExtensionBundleInspector.inspect(at: directory),
                arguments: ["--threading-serve"],
                standardOutput: .pipe(stdout),
                standardError: .pipe(stderr)
            )
        )
        _ = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        child.waitUntilExit()

        XCTAssertTrue(
            diagnostics.contains("not an installed extension"),
            "expected a refusal, got: \(diagnostics)"
        )
        XCTAssertNotEqual(child.terminationStatus, 0)
    }

    @MainActor
    func testTheAppSelectsTheRuntimeBoundaryWithoutRestoringThePromptCapableHelper() throws {
        let policy = ExtensionManager.defaultLaunchPolicy(
            usesContainedLauncher: false
        )
        XCTAssertTrue(
            policy is RuntimeSelectingLaunchPolicy
        )
        XCTAssertTrue(
            ExtensionManager.defaultLaunchPolicy(
                usesContainedLauncher: true,
                bundle: Bundle(for: type(of: self))
            ) is RuntimeSelectingLaunchPolicy,
            "a stale developer default must not restore the Keychain prompt surface"
        )

        let nativeDirectory = try makeBundle(
            capabilities: [],
            script: "#!/bin/bash\nexit 0"
        )
        let wasmDirectory = try makeWebAssemblyBundle(module: Data([
            0x00, 0x61, 0x73, 0x6D,
            0x01, 0x00, 0x00, 0x00
        ]))
        defer {
            try? FileManager.default.removeItem(at: nativeDirectory)
            try? FileManager.default.removeItem(at: wasmDirectory)
        }
        XCTAssertEqual(
            policy.hostTransport(
                for: try ExtensionBundleInspector.inspect(at: nativeDirectory)
            ),
            .loopback
        )
        XCTAssertEqual(
            policy.hostTransport(
                for: try ExtensionBundleInspector.inspect(at: wasmDirectory)
            ),
            .descriptor
        )
    }

    func testTheHelperPolicyPicksItsVariantFromTheNetworkCapability() {
        XCTAssertEqual(
            HelperLaunchPolicy.helperName(for: []),
            HelperLaunchPolicy.helperName
        )
        XCTAssertEqual(
            HelperLaunchPolicy.helperName(for: [.keyValueStorage, .panels]),
            HelperLaunchPolicy.helperName
        )
        XCTAssertEqual(
            HelperLaunchPolicy.helperName(for: [.networkClient]),
            HelperLaunchPolicy.networkHelperName
        )
        XCTAssertEqual(HelperLaunchPolicy().hostTransport, .descriptor)
    }

    // MARK: - Runner validation

    func testTheRunnerRefusesAnythingItWasNotAskedToLaunch() throws {
        let installRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRunnerPackages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: installRoot) }

        let package = installRoot
            .appendingPathComponent("com.example.runner.threadingextension", isDirectory: true)
        let bin = package.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("extension")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        func request(
            package packagePath: String = package.path,
            executable executablePath: String = executable.path,
            arguments: [String] = ["--threading-serve"],
            environment: [String: String] = [:]
        ) -> ExtensionRunnerRequest {
            ExtensionRunnerRequest(
                packagePath: packagePath,
                executablePath: executablePath,
                arguments: arguments,
                environment: environment
            )
        }

        func refusal(_ value: ExtensionRunnerRequest) -> ExtensionRunnerRefusal? {
            do {
                try ExtensionRunnerValidator.validate(
                    value,
                    installRootPath: installRoot.path
                )
                return nil
            } catch {
                return error as? ExtensionRunnerRefusal
            }
        }

        // The positive control. Without it the refusals below could all be one broken check.
        XCTAssertNil(refusal(request()))
        XCTAssertNil(refusal(request(arguments: ["--threading-register"])))
        XCTAssertNil(refusal(
            request(environment: [ExtensionHostConnection.tokenEnvironmentKey: "token"])
        ))

        // An entry mode the runner does not know turns it into a general-purpose exec service.
        XCTAssertEqual(
            refusal(request(arguments: ["--wat"])),
            .unknownEntryMode(["--wat"])
        )
        XCTAssertEqual(refusal(request(arguments: [])), .unknownEntryMode([]))
        XCTAssertEqual(
            refusal(request(arguments: ["--threading-serve", "--and-this"])),
            .unknownEntryMode(["--threading-serve", "--and-this"])
        )

        // An injected library runs with the child's authority, which would make the sandbox
        // profile irrelevant to what actually executes.
        XCTAssertEqual(
            refusal(request(environment: ["DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"])),
            .forbiddenEnvironmentKey("DYLD_INSERT_LIBRARIES")
        )

        // Traversal, both textual and through the install root's own parent.
        XCTAssertEqual(
            refusal(request(package: installRoot.appendingPathComponent("..").path)),
            .packageOutsideInstallRoot(installRoot.appendingPathComponent("..").path)
        )
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingElsewhere-\(UUID().uuidString).threadingextension")
        try FileManager.default.createDirectory(
            at: elsewhere,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        XCTAssertEqual(
            refusal(request(package: elsewhere.path)),
            .packageOutsideInstallRoot(elsewhere.path)
        )

        // A directory in the right place that is not a package.
        let notAPackage = installRoot.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(
            at: notAPackage,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            refusal(request(package: notAPackage.path)),
            .packageNotAPackage(notAPackage.path)
        )

        // An executable that leaves its package, including via a symlink that points out.
        XCTAssertEqual(
            refusal(request(executable: "/bin/ls")),
            .executableEscapesPackage("/bin/ls")
        )
        let escapingLink = bin.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: escapingLink,
            withDestinationURL: URL(fileURLWithPath: "/bin/ls")
        )
        XCTAssertEqual(
            refusal(request(executable: escapingLink.path)),
            .executableEscapesPackage(escapingLink.path),
            "a symlink inside the package must not launder a path outside it"
        )

        // A real path inside the package that is not runnable.
        let readme = package.appendingPathComponent("README", isDirectory: false)
        try Data("hello".utf8).write(to: readme)
        XCTAssertEqual(
            refusal(request(executable: readme.path)),
            .executableNotRunnable(readme.path)
        )
        XCTAssertEqual(
            refusal(request(executable: bin.path)),
            .executableNotRunnable(bin.path)
        )
    }

    // MARK: - Helpers

    private final class RecordingCoreLaunchPolicy:
        ExtensionLaunchPolicy,
        @unchecked Sendable
    {
        let hostTransport: ExtensionHostTransport = .descriptor
        private(set) var requests: [ExtensionLaunchRequest] = []

        func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
            requests.append(request)
            guard case .pipe(let output) = request.standardOutput else {
                throw ExtensionProcessError.invalidMessage("test launch has no output pipe")
            }
            try output.fileHandleForWriting.write(contentsOf: Data("{}\n".utf8))
            return RecordingCompanionChild()
        }
    }

    private final class RecordingCompanionLaunchPolicy:
        ExtensionCompanionLaunchPolicy,
        @unchecked Sendable
    {
        private let helloGeneration: String?
        private let operationHandler: ((
            ExtensionCompanionOperationRequest
        ) -> ExtensionCompanionOperationResponse)?
        private(set) var requests: [ExtensionCompanionLaunchRequest] = []

        init(
            helloGeneration: String? = nil,
            operationHandler: ((
                ExtensionCompanionOperationRequest
            ) -> ExtensionCompanionOperationResponse)? = nil
        ) {
            self.helloGeneration = helloGeneration
            self.operationHandler = operationHandler
        }

        func spawn(
            _ request: ExtensionCompanionLaunchRequest
        ) throws -> ExtensionChildProcess {
            requests.append(request)
            guard case .pipe(let output) = request.standardOutput else {
                throw ExtensionCompanionSupervisorError.invalidHandshake(
                    "test launch has no output pipe"
                )
            }
            let hello = ExtensionCompanionHello(
                companionID: request.environment[
                    ExtensionCompanionEnvironment.companionIdentifier
                ] ?? "",
                generation: helloGeneration ?? request.environment[
                    ExtensionCompanionEnvironment.generation
                ] ?? ""
            )
            var data = try JSONEncoder().encode(hello)
            data.append(0x0A)
            try output.fileHandleForWriting.write(contentsOf: data)
            if let operationHandler,
               case .pipe(let input) = request.standardInput {
                let outputHandle = output.fileHandleForWriting
                DispatchQueue.global(qos: .userInitiated).async {
                    var buffer = Data()
                    while true {
                        let chunk = input.fileHandleForReading.availableData
                        guard !chunk.isEmpty else { return }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let line = Data(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                            guard let operation = try? JSONDecoder().decode(
                                ExtensionCompanionOperationRequest.self,
                                from: line
                            ) else {
                                continue
                            }
                            var response = try? JSONEncoder().encode(
                                operationHandler(operation)
                            )
                            response?.append(0x0A)
                            if let response {
                                try? outputHandle.write(contentsOf: response)
                            }
                        }
                    }
                }
            }
            return RecordingCompanionChild()
        }
    }

    private struct ExitingCompanionLaunchPolicy: ExtensionCompanionLaunchPolicy {
        let status: Int32
        let diagnostic: String

        func spawn(
            _ request: ExtensionCompanionLaunchRequest
        ) throws -> ExtensionChildProcess {
            let companionID = request.environment[
                ExtensionCompanionEnvironment.companionIdentifier
            ] ?? ""
            let generation = request.environment[
                ExtensionCompanionEnvironment.generation
            ] ?? ""
            let hello = ExtensionCompanionHello(
                companionID: companionID,
                generation: generation
            )
            let helloData = try JSONEncoder().encode(hello)
            let helloBase64 = helloData.base64EncodedString()
            let diagnosticBase64 = Data(diagnostic.utf8).base64EncodedString()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "printf '%s' '\(helloBase64)' | base64 -D; printf '\\n'; "
                    + "sleep 0.05; printf '%s' '\(diagnosticBase64)' | base64 -D >&2; "
                    + "printf '\\n' >&2; exit \(status)"
            ]
            process.standardInput = request.standardInput.processValue
            process.standardOutput = request.standardOutput.processValue
            process.standardError = request.standardError.processValue
            process.environment = ExtensionLaunchEnvironment.composed(
                with: request.environment
            )
            let child = LocalChildProcess(process: process)
            try child.run()
            return child
        }
    }

    @MainActor
    private final class RecordingCompanionPermissionAuthorizer:
        ExtensionCompanionSystemPermissionAuthorizing
    {
        private(set) var requests: [Set<ExtensionCompanionCapability>] = []

        func authorize(
            capabilities: Set<ExtensionCompanionCapability>
        ) throws {
            requests.append(capabilities)
        }
    }

    private final class RecordingCompanionChild:
        ExtensionChildProcess,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var running = true
        private var status: Int32 = 0
        private var observer: ((Int32) -> Void)?

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return running
        }

        var terminationStatus: Int32 {
            lock.lock()
            defer { lock.unlock() }
            return status
        }

        func waitUntilExit() {}

        func terminate() {
            finish(status: 0)
        }

        func kill() {
            finish(status: SIGKILL)
        }

        func observeExit(_ handler: ((Int32) -> Void)?) {
            let completed: Int32?
            lock.lock()
            if running {
                observer = handler
                completed = nil
            } else {
                completed = status
            }
            lock.unlock()
            if let handler, let completed {
                handler(completed)
            }
        }

        private func finish(status: Int32) {
            let observer: ((Int32) -> Void)?
            lock.lock()
            guard running else {
                lock.unlock()
                return
            }
            running = false
            self.status = status
            observer = self.observer
            self.observer = nil
            lock.unlock()
            observer?(status)
        }
    }

    private final class RecordingLaunchPolicy:
        ExtensionLaunchPolicy,
        @unchecked Sendable
    {
        private let underlying: ExtensionLaunchPolicy
        private(set) var requests: [ExtensionLaunchRequest] = []

        var hostTransport: ExtensionHostTransport { underlying.hostTransport }

        init(underlying: ExtensionLaunchPolicy = SandboxExecLaunchPolicy()) {
            self.underlying = underlying
        }

        func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
            requests.append(request)
            return try underlying.spawn(request)
        }
    }

    private struct RefusingLaunchPolicy: ExtensionLaunchPolicy {
        let hostTransport: ExtensionHostTransport = .loopback

        struct Refusal: LocalizedError {
            var errorDescription: String? { "containment is unavailable" }
        }

        func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
            throw Refusal()
        }
    }

    /// A listening TCP socket on an ephemeral loopback port.
    ///
    /// It is never accepted from: a connect succeeds off the backlog, which is all a probe
    /// needs to tell "the sandbox let me out" from "nothing was listening".
    private func makeListener() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(descriptor < 0, "no socket available")

        var reuse: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw XCTSkip("could not open a loopback listener")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(descriptor)
            throw XCTSkip("could not read the listener's port")
        }
        return (descriptor, UInt16(bigEndian: assigned.sin_port))
    }

    private func makeBundle(
        capabilities: Set<ExtensionCapability>,
        script: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingExtensionLoaderTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        let manifest = ExtensionManifest(
            identifier: "com.example.loader-test",
            name: "Loader Test",
            version: "0.1.0",
            executable: "bin/extension",
            capabilities: capabilities
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )

        let executable = bin.appendingPathComponent("extension")
        try Data((script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return root
    }

    private func makeWebAssemblyBundle(
        module: Data,
        capabilities: Set<ExtensionCapability> = [],
        companions: [ExtensionCompanion] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingWasmLoaderTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )

        let manifest = ExtensionManifest(
            identifier: "com.example.wasm-loader-test",
            name: "Wasm Loader Test",
            version: "0.1.0",
            runtime: .webAssembly,
            executable: "bin/extension.wasm",
            capabilities: capabilities,
            companions: companions
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        try module.write(to: bin.appendingPathComponent("extension.wasm"))
        try Data("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "WasmLoaderTest",
            targets: [.executableTarget(name: "WasmLoaderTest")]
        )
        """.utf8).write(to: root.appendingPathComponent("Package.swift"))
        let sources = root.appendingPathComponent(
            "Sources/WasmLoaderTest",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        try Data("print(\"test\")\n".utf8).write(
            to: sources.appendingPathComponent("main.swift")
        )
        return root
    }

    private func addCompanionApp(
        to root: URL,
        declaration: ExtensionCompanion,
        extensionIdentifier: String,
        bundleIdentifier: String? = nil,
        signedCapabilities: Set<ExtensionCompanionCapability>? = nil,
        sign: Bool = true
    ) throws {
        let app = root.appendingPathComponent(
            declaration.bundlePath,
            isDirectory: true
        )
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": bundleIdentifier
                ?? declaration.expectedBundleIdentifier(
                    extensionIdentifier: extensionIdentifier
                ),
            "CFBundleExecutable": "SimulatorWorker"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .binary,
            options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("SimulatorWorker")
        // Entitlements are embedded in a Mach-O code signature. A shell script can make the
        // enclosing app look signed while carrying no executable entitlements at all, which
        // would make this fixture test a different object than a real companion app.
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        guard sign else { return }

        let capabilities = signedCapabilities ?? declaration.capabilities
        var entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true
        ]
        if capabilities.contains(.networkClient) {
            entitlements["com.apple.security.network.client"] = true
        }
        if capabilities.contains(.networkListen) {
            entitlements["com.apple.security.network.server"] = true
        }
        if capabilities.contains(.appleEvents) {
            entitlements["com.apple.security.automation.apple-events"] = true
        }
        if capabilities.contains(.userSelectedFilesWrite) {
            entitlements["com.apple.security.files.user-selected.read-write"] = true
        } else if capabilities.contains(.userSelectedFilesRead) {
            entitlements["com.apple.security.files.user-selected.read-only"] = true
        }
        let entitlementsURL = root.appendingPathComponent(
            ".companion-test-entitlements-\(declaration.id).plist"
        )
        try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        ).write(to: entitlementsURL)
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }
        _ = try Self.run("/usr/bin/codesign", [
            "--force",
            "--sign", "-",
            "--options", "runtime",
            "--entitlements", entitlementsURL.path,
            app.path
        ])
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writePNG(
        bgra: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        to url: URL
    ) throws {
        guard let provider = CGDataProvider(data: bgra as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                ).union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let png = NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
    }

    @MainActor
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
}
