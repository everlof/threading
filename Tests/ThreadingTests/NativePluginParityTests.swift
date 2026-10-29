import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

/// Proves the first-party plugin still works when built with the public SDK recipe.
///
/// Threading ships Device Logs as an Xcode bundle target, trusted because it sits inside the app
/// and is covered by the app's signature. The manually built copy exercises the exported SDK's
/// public recipe and loader. The host reserves its identifier for the managed release path, so it cannot
/// load through `NativePluginCatalog` without a matching release receipt. The independent example
/// below exercises the ordinary third-party host policy.
///
/// Opt in with `TEST_RUNNER_THREADING_PLUGIN_PARITY=1` — `xcodebuild` forwards an environment
/// variable to the test process only under that prefix, and setting the bare name looks like it
/// worked while every case quietly skips. It extracts an SDK archive and invokes SwiftPM and
/// `codesign`, so it takes several minutes and needs a signing identity. It opts in rather than
/// running in `fast`.
/// `TEST_RUNNER_THREADING_PLUGIN_SDK_ARCHIVE` uses a downloaded release asset in place of the
/// locally generated archive, so the release can be verified with the same host assertions.
@MainActor
final class NativePluginParityTests: XCTestCase {

    /// Built once for the class, not once per test.
    ///
    /// The first test `dlopen`s the installed bundle into this process, so a second build would be
    /// rewriting a binary that is mapped — which is how the second test came to fail with a script
    /// error rather than a verdict. Build the exported SDK only once for both assertions.
    private static var built: Result<URL, Error>?

    override class func tearDown() {
        if case .success(let url)? = built { try? FileManager.default.removeItem(at: url) }
        if case .success(let url)? = builtExample { try? FileManager.default.removeItem(at: url) }
        built = nil
        builtExample = nil
        super.tearDown()
    }

    private func buildTheThirdPartyWay() throws -> URL {
        if let built = Self.built { return try built.get() }
        do {
            let url = try runTheBuildScript()
            Self.built = .success(url)
            return url
        } catch {
            Self.built = .failure(error)
            throw error
        }
    }

    private func runTheBuildScript() throws -> URL {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_PLUGIN_PARITY"] == "1",
            "set THREADING_PLUGIN_PARITY=1 to build the plugin the way a third party does"
        )
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ThreadingTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-plugin-sdk-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archive: URL
        if let supplied = ProcessInfo.processInfo.environment["THREADING_PLUGIN_SDK_ARCHIVE"],
           !supplied.isEmpty {
            archive = URL(fileURLWithPath: supplied)
        } else {
            let archiver = Process()
            archiver.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            archiver.arguments = [
                "python3", root.appendingPathComponent("scripts/archive_plugin_sdk.py").path,
                "0.0.0", scratch.path,
            ]
            let archiveOutput = Pipe()
            archiver.standardOutput = archiveOutput
            archiver.standardError = archiveOutput
            try archiver.run()
            let detail = String(decoding: archiveOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            archiver.waitUntilExit()
            guard archiver.terminationStatus == 0 else {
                XCTFail("the SDK could not be archived: \(detail)")
                throw NSError(domain: "NativePluginParityTests", code: Int(archiver.terminationStatus))
            }
            archive = scratch.appendingPathComponent("ThreadingPluginSDK-0.0.0.zip")
        }
        let sdkName = archive.deletingPathExtension().lastPathComponent
        guard archive.pathExtension == "zip",
              sdkName.range(of: #"^ThreadingPluginSDK-[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil,
              FileManager.default.fileExists(atPath: archive.path)
        else {
            XCTFail("expected an existing ThreadingPluginSDK-<version>.zip archive")
            throw NSError(domain: "NativePluginParityTests", code: 2)
        }

        let extracted = scratch.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let extractor = Process()
        extractor.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extractor.arguments = [
            "-x", "-k", archive.path, extracted.path,
        ]
        try extractor.run()
        extractor.waitUntilExit()
        guard extractor.terminationStatus == 0 else {
            XCTFail("the SDK archive could not be extracted")
            throw NSError(domain: "NativePluginParityTests", code: Int(extractor.terminationStatus))
        }
        let sdk = extracted.appendingPathComponent(sdkName)
        let manifest = try Data(contentsOf: sdk.appendingPathComponent("SDK_VERSION.json"))
        let sdkVersion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        )
        XCTAssertEqual(sdkVersion["pluginAPIVersion"] as? Int, ThreadingPluginAPI.version)
        let package = sdk.appendingPathComponent("Plugins/DeviceLogsPlugin")
        let script = sdk.appendingPathComponent("Packages/ThreadingPluginKit/Tools/build-plugin.sh")
        let installedBundle = NativePluginCatalog.directory.appendingPathComponent("DeviceLogsPlugin.bundle")
        try XCTSkipIf(FileManager.default.fileExists(atPath: installedBundle.path),
                      "an existing Device Logs installation must not be overwritten by the parity test")
        let identity = ProcessInfo.processInfo.environment["THREADING_PLUGIN_IDENTITY"]
            ?? "Developer ID Application: MJUKIS AB (SMQ3E8Y57T)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Xcode's test runner omits Homebrew from PATH even when the developer's shell has it.
        // SwiftPM invokes git during resolution; preserve locally configured Git LFS hooks.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        process.environment = environment
        process.arguments = [
            script.path,
            package.path,
            "--identifier", NativePluginCatalog.deviceLogsIdentifier,
            "--identity", identity,
            "--metadata", package.appendingPathComponent("Info.plist").path,
            "--install",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("the exported SDK could not produce a signed bundle:\n\(text)")
            throw NSError(domain: "NativePluginParityTests", code: Int(process.terminationStatus))
        }
        return installedBundle
    }

    /// The public recipe produces a plugin with the same tools as the embedded target. The SDK
    /// loader can construct it after validating its signature and an explicit test decision.
    func testDeviceLogsBuiltWithPublicRecipeOffersTheSameTools() throws {
        let bundle = try buildTheThirdPartyWay()

        XCTAssertFalse(
            bundle.path.hasPrefix(Bundle.main.bundleURL.path),
            "the parity check must exercise the installed build, not the bundled one"
        )

        let identity = try PluginLoader.identity(of: bundle)
        let sections = try XCTUnwrap(NativePluginPaneDiscovery.descriptor(
            at: bundle, isBundled: false, verifiedInstalledIdentity: identity
        ))
        XCTAssertEqual(sections.sections.map(\.identifier), ["regular", "bluetooth"])
        let plugin = try PluginLoader.signatureAndDecision().load(bundleAt: bundle) {
            $0 == identity
        }

        XCTAssertEqual(plugin.pluginIdentifier, NativePluginCatalog.deviceLogsIdentifier)
        XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)

        let thirdParty = Set((plugin.pluginTools ?? []).map(\.name))
        XCTAssertFalse(thirdParty.isEmpty)

        // The bundled copy is the comparison, so a capability that only the shipped one has is a
        // failure here rather than a discovery later.
        let shippedURL = try XCTUnwrap(NativePluginCatalog.deviceLogsBundle)
        guard case .success(let shipped) = NativePluginCatalog.load(shippedURL) else {
            return XCTFail("the shipped plugin did not load")
        }
        XCTAssertEqual(
            thirdParty,
            Set((shipped.pluginTools ?? []).map(\.name)),
            "the two build paths do not offer the same tools"
        )
    }

    /// A manual copy using a reserved first-party identity cannot impersonate a managed release,
    /// even when its exact signed build has been approved as an ordinary installed plugin.
    func testManuallyInstalledFirstPartyIdentifierRequiresManagedReceipt() throws {
        let bundle = try buildTheThirdPartyWay()
        let identity = try PluginLoader.identity(of: bundle)
        NativePluginApprovalStore.shared.remember(true, for: identity)
        defer { NativePluginApprovalStore.shared.revoke(identifier: identity.bundleIdentifier) }
        switch NativePluginCatalog.load(bundle) {
        case .success: XCTFail("a manual copy impersonated a managed first-party release")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "build_changed", "refused for the wrong reason")
        }
    }

    /// The claim this tier is sold on: **`ThreadingPluginKit` is all a third party needs.**
    ///
    /// Device Logs exercises the complete SDK snapshot, including DesignKit and the parser. This
    /// separate case proves the narrower promise that a plugin needs only the PluginKit package:
    /// it runs the example in
    /// `Packages/ThreadingPluginKit/Examples`, whose manifest names one dependency, through the
    /// recipe in `Tools/` and ad-hoc signing, which is what someone with no Developer ID has.
    ///
    /// If this passes and the others fail, the SDK is fine and Threading broke. If this fails
    /// alone, we have grown a dependency on something we do not hand out.
    func testAPluginBuiltWithNothingButTheSDKLoadsAndOffersItsTool() async throws {
        let bundle = try buildTheExampleWithOnlyTheSDK()

        let identity = try PluginLoader.identity(of: bundle)
        XCTAssertNil(identity.team, "the example is ad-hoc signed on purpose: no Developer ID")
        NativePluginApprovalStore.shared.remember(true, for: identity)
        defer { NativePluginApprovalStore.shared.revoke(identifier: identity.bundleIdentifier) }

        let plugin: ThreadingNativePlugin
        switch NativePluginCatalog.load(bundle) {
        case .success(let loaded): plugin = loaded
        case .failure(let failure):
            return XCTFail("a plugin needing only the published SDK was refused: \(failure)")
        }

        XCTAssertEqual(plugin.pluginIdentifier, "com.example.hellopane")
        XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)
        XCTAssertEqual((plugin.pluginTools ?? []).map(\.name), ["set_greeting"])

        let paneDeclaration = try XCTUnwrap(NativePluginPaneDiscovery.descriptor(
            at: bundle, isBundled: false, verifiedInstalledIdentity: identity
        ))
        XCTAssertEqual(paneDeclaration.sections.map(\.identifier), ["hello"])
        XCTAssertEqual(paneDeclaration.sections.first?.command?.title, "Open Hello Pane")
        XCTAssertEqual(paneDeclaration.route("from-device")?.section, "hello")
        XCTAssertEqual(paneDeclaration.route("from-device")?.context, .selectedDevice)
        let registry = CommandRegistry()
        registry.replaceNativePluginBundles([bundle], paneDescriptors: [paneDeclaration])
        let commandID = PanelCommands.nativePluginSectionID(
            identifier: identity.bundleIdentifier, section: "hello"
        )
        XCTAssertEqual(registry.command(id: commandID)?.panelTarget,
                       .nativePluginSection(identifier: identity.bundleIdentifier, section: "hello"))

        // Load through the ordinary pane host so the context comes from Threading, not this test.
        let controller = NativePluginPaneViewController(bundleURL: bundle, owningSessionID: nil)
        controller.loadView()
        for _ in 0..<200 where controller.loaded == nil && controller.refusal == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let hosted = try XCTUnwrap(controller.loaded, "the approved example did not reach the pane host")
        XCTAssertEqual(hosted.pluginIdentifier, plugin.pluginIdentifier)
        let label = try XCTUnwrap(descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Hello from a plugin." })
        XCTAssertEqual(label.toolTip,
                       "This host offers device services to approved native plugins.")
        controller.activate(arguments: ["deviceID": "example-phone"])
        XCTAssertEqual(label.stringValue, "Selected device: example-phone")
    }

    /// Installed plugins resolve ThreadingPluginKit to the host's dynamic framework. If the
    /// generated getter called `ThreadingPluginAPI.version`, a v4 navigator-only bundle loaded by
    /// a v3 host would report 3 and pass the old host's exact check before its missing required
    /// pane selector was dispatched. The separately compiled binary must carry no reference to
    /// that runtime getter: its own `pluginAPIVersion` stays the literal it was compiled with
    /// regardless of the host framework.
    func testV4PluginBinaryEmbedsItsGenerationInsteadOfReadingTheHostGeneration() throws {
        let bundle = try buildTheExampleWithOnlyTheSDK()
        let executable = try XCTUnwrap(Bundle(url: bundle)?.executableURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-u", executable.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let symbols = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, symbols)
        XCTAssertFalse(
            symbols.contains("_$s18ThreadingPluginKit0aB3APIO7versionSivgZ"),
            "the plugin's generation still depends on whichever framework the host supplies"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static var builtExample: Result<URL, Error>?

    private func buildTheExampleWithOnlyTheSDK() throws -> URL {
        if let built = Self.builtExample { return try built.get() }
        do {
            let url = try runTheSDKRecipe()
            Self.builtExample = .success(url)
            return url
        } catch {
            Self.builtExample = .failure(error)
            throw error
        }
    }

    /// Deliberately the SDK's own script rather than `scripts/build_plugin.sh`: the wrapper
    /// supplies our identifier and our Developer ID, and neither is available to the person this
    /// test stands in for.
    private func runTheSDKRecipe() throws -> URL {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_PLUGIN_PARITY"] == "1",
            "set THREADING_PLUGIN_PARITY=1 to build the example the way a third party does"
        )
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let kit = root.appendingPathComponent("Packages/ThreadingPluginKit")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            kit.appendingPathComponent("Tools/build-plugin.sh").path,
            kit.appendingPathComponent("Examples/HelloPanePlugin").path,
            "--identifier", "com.example.hellopane",
            "--metadata", kit.appendingPathComponent(
                "Examples/HelloPanePlugin/PaneMetadata.plist"
            ).path,
            "--install",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try XCTSkipUnless(
            process.terminationStatus == 0,
            "the SDK recipe could not produce a signed bundle here:\n\(text)"
        )
        return NativePluginCatalog.directory.appendingPathComponent("HelloPanePlugin.bundle")
    }
}
