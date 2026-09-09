import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

/// Proves the first-party plugin still works when built and loaded the way a third party's is.
///
/// Threading ships Device Logs as an Xcode bundle target, trusted because it sits inside the app
/// and is covered by the app's signature. A third party builds with `scripts/build_plugin.sh`,
/// installs into Application Support, and runs only once the user has approved it. **Two paths,
/// and only one of them runs on every build** — which is exactly how the third-party path stops working
/// without anyone noticing. This runs the other one.
///
/// Opt in with `TEST_RUNNER_THREADING_PLUGIN_PARITY=1` — `xcodebuild` forwards an environment
/// variable to the test process only under that prefix, and setting the bare name looks like it
/// worked while every case quietly skips. It invokes SwiftPM and `codesign`, so it is tens of
/// seconds and needs a signing identity, which is why it opts in rather than running in `fast`.
@MainActor
final class NativePluginParityTests: XCTestCase {

    /// Built once for the class, not once per test.
    ///
    /// The first test `dlopen`s the installed bundle into this process, so a second build would be
    /// rewriting a binary that is mapped — which is how the second test came to fail with a script
    /// error rather than a verdict. Once is also 40 seconds instead of 140.
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
        let script = root.appendingPathComponent("scripts/build_plugin.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            script.path,
            root.appendingPathComponent("Plugins/DeviceLogsPlugin").path,
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
            "build_plugin.sh could not produce a signed bundle here:\n\(text)"
        )
        return NativePluginCatalog.directory.appendingPathComponent("DeviceLogsPlugin.bundle")
    }

    /// The same plugin, built by the documented third-party route, loaded by decision rather than
    /// by location, offering the same tools.
    func testThePluginBuiltTheThirdPartyWayLoadsAndOffersTheSameTools() throws {
        let bundle = try buildTheThirdPartyWay()

        // Trusted by the user's decision, not because it sits inside the app: this copy does not.
        XCTAssertFalse(
            bundle.path.hasPrefix(Bundle.main.bundleURL.path),
            "the parity check must exercise the installed path, not the bundled one"
        )

        // The user's decision is what lets an installed plugin run at all, so the parity check
        // records one — that *is* the third-party path, not a way around it.
        let identity = try PluginLoader.identity(of: bundle)
        NativePluginApprovalStore.shared.remember(true, for: identity)
        defer { NativePluginApprovalStore.shared.revoke(identifier: identity.bundleIdentifier) }

        let plugin: ThreadingNativePlugin
        switch NativePluginCatalog.load(bundle) {
        case .success(let loaded): plugin = loaded
        case .failure(let failure):
            return XCTFail("a plugin built the third-party way was refused: \(failure)")
        }

        XCTAssertEqual(plugin.pluginIdentifier, NativePluginCatalog.deviceLogsIdentifier)
        XCTAssertEqual(type(of: plugin).pluginAPIVersion, ThreadingPluginAPI.version)

        let thirdParty = Set((plugin.pluginTools ?? []).map(\.name))
        XCTAssertEqual(thirdParty.count, 5, "found \(thirdParty.sorted())")

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

    /// The decision is what stands between the plugins folder and arbitrary code in this process,
    /// so an installed plugin must be refused without one — including ours, signed by our own team.
    func testTheInstalledCopyIsRefusedWithoutTheUsersDecision() throws {
        let bundle = try buildTheThirdPartyWay()
        let identity = try PluginLoader.identity(of: bundle)
        NativePluginApprovalStore.shared.revoke(identifier: identity.bundleIdentifier)
        switch NativePluginCatalog.load(bundle) {
        case .success: XCTFail("an installed plugin loaded with no decision recorded")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "not_approved", "refused for the wrong reason")
        }
    }

    /// The claim this tier is sold on: **`ThreadingPluginKit` is all a third party needs.**
    ///
    /// Device Logs cannot prove it. It links `ThreadingDesignKit` too, which is not published and
    /// cannot be — so the case above shows that *our* plugin survives the third-party build, not
    /// that a plugin built with only the published package works at all. This runs the example in
    /// `Packages/ThreadingPluginKit/Examples`, whose manifest names one dependency, through the
    /// recipe in `Tools/` and ad-hoc signing, which is what someone with no Developer ID has.
    ///
    /// If this passes and the others fail, the SDK is fine and Threading broke. If this fails
    /// alone, we have grown a dependency on something we do not hand out.
    func testAPluginBuiltWithNothingButTheSDKLoadsAndOffersItsTool() throws {
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

        // It draws, in the host's colours, through the same path the shipped plugin uses.
        let pane = try XCTUnwrap(plugin.makePaneView?(
            context: PluginContext(theme: NativePluginCatalog.theme(), arguments: [:])
        ))
        pane.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        pane.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.subviews.isEmpty, "the example pane drew nothing")
    }

    /// Installed plugins resolve ThreadingPluginKit to the host's dynamic framework. If the
    /// generated getter called `ThreadingPluginAPI.version`, a v4 navigator-only bundle loaded by
    /// a v3 host would report 3 and pass the old host's exact check before its missing required
    /// pane selector was dispatched. The separately compiled binary must carry no reference to
    /// that runtime getter: its own `pluginAPIVersion` remains 4 regardless of the host framework.
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
