import AppKit
import XCTest
import ThreadingPluginKit
@testable import Threading

/// Proves the first-party plugin still works when built and loaded the way a third party's is.
///
/// Threading ships Device Logs as an Xcode bundle target, trusted because it sits inside the app
/// and is covered by the app's signature. A third party builds with `scripts/build_plugin.sh`,
/// installs into Application Support, and is trusted only by the allowlist. **Two paths, and only
/// one of them runs on every build** — which is exactly how the third-party path stops working
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
        built = nil
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

    /// The same plugin, built by the documented third-party route, loaded through the allowlist
    /// rather than by location, offering the same tools.
    func testThePluginBuiltTheThirdPartyWayLoadsAndOffersTheSameTools() throws {
        let bundle = try buildTheThirdPartyWay()

        // Trusted by the allowlist, not because it sits inside the app: this copy does not.
        XCTAssertFalse(
            bundle.path.hasPrefix(Bundle.main.bundleURL.path),
            "the parity check must exercise the installed path, not the bundled one"
        )

        // The user's decision is what lets an installed plugin run at all, so the parity check
        // records one — that *is* the third-party path, not a way around it.
        let identity = try PluginLoader.acceptingAnyTeam().identity(of: bundle)
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
        let identity = try PluginLoader.acceptingAnyTeam().identity(of: bundle)
        NativePluginApprovalStore.shared.revoke(identifier: identity.bundleIdentifier)
        switch NativePluginCatalog.load(bundle) {
        case .success: XCTFail("an installed plugin loaded with no decision recorded")
        case .failure(let failure):
            XCTAssertEqual(failure.code, "not_approved", "refused for the wrong reason")
        }
    }
}
