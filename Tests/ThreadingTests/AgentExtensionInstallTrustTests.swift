import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class AgentExtensionInstallTrustTests: HostedStoreTestCase {
    func testTrustPersistsForOnlyOneChatAndCanBeRevoked() throws {
        let suite = "\(PreferenceStore.hostedTestSuitePrefix).install-trust.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SessionID()
        let other = SessionID()
        let store = AgentExtensionInstallTrustStore(defaults: defaults)
        XCTAssertFalse(store.allows(first))
        store.allow(first, name: "Extension development")
        let restarted = AgentExtensionInstallTrustStore(defaults: defaults)
        XCTAssertTrue(restarted.allows(first))
        XCTAssertFalse(restarted.allows(other))
        restarted.revoke(first)
        XCTAssertFalse(AgentExtensionInstallTrustStore(defaults: defaults).allows(first))
    }

    func testCallingChatTrustCoversInstallsAndCapabilityUpdatesUntilRevoked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "\(PreferenceStore.hostedTestSuitePrefix).install-flow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let first = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex))
        let other = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex))
        let packageStore = ExtensionPackageStore(rootURL: root.appendingPathComponent("Host"))
        let manager = ExtensionManager(store: packageStore)
        defer { manager.terminateAll() }
        let trust = AgentExtensionInstallTrustStore(defaults: defaults)
        let live = AgentToolDependencies.live
        let dependencies = AgentToolDependencies(
            projects: live.projects, attachments: live.attachments, displayStore: live.displayStore,
            extensions: manager, externalTools: live.externalTools, remoteMirror: live.remoteMirror,
            settings: live.settings, notifications: live.notifications,
            notificationTargets: live.notificationTargets, archiveScheduler: live.archiveScheduler,
            sessionCommands: live.sessionCommands,
            extensionInstallation: AgentExtensionInstallService(
                projects: live.projects, extensions: manager, trust: trust
            ),
            extensionAuthoring: live.extensionAuthoring,
            browserStorage: live.browserStorage, settingsCatalogue: live.settingsCatalogue,
            control: live.control, mobileDiagnosticsInspection: live.mobileDiagnosticsInspection,
            baselines: live.baselines
        )
        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { other.id }, setPaneVisible: { _ in }, windowProvider: { nil },
            browserAccessDecisionProvider: nil, browserSiteDataDecisionProvider: nil,
            playwrightRunner: PlaywrightAutomationRunner(), dependencies: dependencies
        )
        var answers: [Int?] = [nil, 0, 1, nil, nil]
        var prompts = 0
        coordinator.extensionInstallDecision = { request, decide in
            prompts += 1
            XCTAssertEqual(request.options.count, 2)
            XCTAssertTrue(request.message.contains("including future capability changes"))
            guard !answers.isEmpty else {
                XCTFail("Unexpected install prompt")
                decide(nil)
                return
            }
            decide(answers.removeFirst())
        }
        let package = root.appendingPathComponent("Test.threadingextension")
        try writePackage(at: package, version: "1.0.0")
        let cancelled = await propose(coordinator, package: package, session: first.id)
        XCTAssertFalse(cancelled.isError)
        XCTAssertTrue(manager.installedExtensions.isEmpty)
        XCTAssertFalse(trust.allows(first.id))

        let once = await propose(coordinator, package: package, session: first.id)
        XCTAssertFalse(once.isError, once.text)
        XCTAssertFalse(trust.allows(first.id))
        XCTAssertFalse(try XCTUnwrap(manager.installedExtensions.first).isEnabled)

        try writePackage(at: package, version: "1.1.0")
        let granted = await propose(coordinator, package: package, session: first.id)
        XCTAssertFalse(granted.isError, granted.text)
        XCTAssertTrue(trust.allows(first.id))
        XCTAssertFalse(trust.allows(other.id))

        try writePackage(at: package, version: "2.0.0", capabilities: [.commands])
        let updated = await propose(coordinator, package: package, session: first.id)
        XCTAssertFalse(updated.isError, updated.text)
        XCTAssertEqual(prompts, 3)
        XCTAssertEqual(manager.installedExtensions.first?.version, "2.0.0")
        XCTAssertFalse(try XCTUnwrap(manager.installedExtensions.first).isEnabled)

        let secondPackage = root.appendingPathComponent("Second.threadingextension")
        try writePackage(at: secondPackage, version: "1.0.0", identifier: "com.example.second")
        let fresh = await propose(coordinator, package: secondPackage, session: first.id)
        XCTAssertFalse(fresh.isError, fresh.text)
        XCTAssertEqual(prompts, 3)
        XCTAssertEqual(manager.installedExtensions.count, 2)
        XCTAssertTrue(manager.installedExtensions.allSatisfy { !$0.isEnabled })

        _ = await propose(coordinator, package: package, session: other.id)
        XCTAssertEqual(prompts, 4)
        trust.revoke(first.id)
        _ = await propose(coordinator, package: package, session: first.id)
        XCTAssertEqual(prompts, 5)
        XCTAssertTrue(answers.isEmpty)

        trust.allow(first.id, name: "Development")
        try Data("invalid manifest".utf8).write(
            to: package.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        let invalid = await propose(coordinator, package: package, session: first.id)
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(prompts, 5)
        XCTAssertEqual(manager.installedExtensions.first { $0.identifier == "com.example.trust" }?.version, "2.0.0")
        let missing = await propose(coordinator, package: secondPackage, session: SessionID())
        XCTAssertTrue(missing.isError)
    }

    func testSettingsRevokesOnlyTheSelectedChat() throws {
        try verifySettingsGrantRows(count: 2)
    }

    func testStressTrustListKeepsOnlyViewportControls() throws {
        guard ProcessInfo.processInfo.environment["THREADING_STRESS"] == "1" else {
            throw XCTSkip("Set THREADING_STRESS=1 for 1,000 trusted chats.")
        }
        try verifySettingsGrantRows(count: 1_000)
    }

    private func verifySettingsGrantRows(count: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "\(PreferenceStore.hostedTestSuitePrefix).trust-settings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let ids = (0..<count).map { _ in SessionID() }.sorted { $0.uuidString < $1.uuidString }
        // Seed once; the stress action is mounting and revoking, not manufacturing grants.
        defaults.set(Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element.uuidString, "Development chat \($0.offset)")
        }), forKey: "agentExtensionInstallTrust.v1")
        let trust = AgentExtensionInstallTrustStore(defaults: defaults)
        let manager = ExtensionManager(store: ExtensionPackageStore(rootURL: root))
        defer { manager.terminateAll() }
        let mountStarted = Date.timeIntervalSinceReferenceDate
        let controller = ExtensionsPreferencesViewController(manager: manager, installTrust: trust)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let mountDuration = Date.timeIntervalSinceReferenceDate - mountStarted
        func buttons(_ view: NSView) -> [ThemedButton] {
            (view as? ThemedButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let prefix = "settings.extensions.revoke-trust."
        let visible = buttons(controller.view).filter { $0.accessibilityIdentifier().hasPrefix(prefix) }
        XCTAssertGreaterThan(visible.count, 0)
        XCTAssertLessThan(visible.count, 30)
        let first = try XCTUnwrap(visible.first {
            $0.accessibilityIdentifier() == prefix + ids[0].uuidString
        })
        let revokeStarted = Date.timeIntervalSinceReferenceDate
        first.performClick()
        controller.view.layoutSubtreeIfNeeded()
        let revokeDuration = Date.timeIntervalSinceReferenceDate - revokeStarted
        XCTAssertFalse(trust.allows(ids[0]))
        XCTAssertTrue(trust.allows(ids[1]))
        let second = try XCTUnwrap(buttons(controller.view).first {
            $0.accessibilityIdentifier() == prefix + ids[1].uuidString
        })
        second.performClick()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(trust.allows(ids[1]))
        XCTAssertEqual(trust.grants.count, count - 2)
        print("Install trust settings: grants=\(count) visible=\(visible.count) mount=\(mountDuration)s revoke=\(revokeDuration)s")
        if count == 2 {
            XCTAssertFalse(buttons(controller.view).contains {
                $0.accessibilityIdentifier().hasPrefix(prefix)
            })
        }
    }

    private func propose(
        _ coordinator: AgentToolCoordinator, package: URL, session: SessionID
    ) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            // Exercise the real typed MCP dispatch, including authenticated caller forwarding.
            coordinator.handle(
                .extensionProposeInstall(.init(directory: package.path)), for: session
            ) { continuation.resume(returning: $0) }
        }
    }

    private func writePackage(
        at root: URL, version: String, identifier: String = "com.example.trust",
        capabilities: Set<ExtensionCapability> = []
    ) throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("test")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try JSONEncoder().encode(ExtensionManifest(
            identifier: identifier, name: "Trust Test", version: version,
            runtime: .native, executable: "bin/test", capabilities: capabilities
        )).write(to: root.appendingPathComponent(ExtensionBundleInspector.manifestName))
    }
}
