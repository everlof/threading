import AppKit
import XCTest
@testable import Threading

@MainActor
final class RemoteLoginFailureTests: HostedStoreTestCase {
    func testDeniedKeychainAccessHasItsOwnRecoveryWithoutReadingTheRealKeychain() throws {
        let account = AgentAccount(provider: .claude, handle: .standard,
            configPath: NSTemporaryDirectory() + UUID().uuidString)
        XCTAssertThrowsError(try RemoteConversationAccount.credentials(for: account, keychainExport: { _ in
            throw ClaudeKeychainCredentials.RemoteLoginExportError.accessRequired
        })) { error in
            let failure = (error as? RemoteConversationFailure)?.launchFailure
            XCTAssertEqual(failure?.knownCause, RemoteConversationFailure.keychainAccessCause)
            XCTAssertEqual(failure?.detail, [])
            XCTAssertTrue(failure?.summary.contains("Always Allow") == true)
            XCTAssertFalse(failure?.summary.contains("Codex") == true)
        }
        XCTAssertThrowsError(try RemoteConversationAccount.credentials(for: account, keychainExport: { _ in nil })) { error in
            XCTAssertNotEqual((error as? RemoteConversationFailure)?.launchFailure.knownCause,
                              RemoteConversationFailure.keychainAccessCause)
            XCTAssertTrue(error.localizedDescription.contains("Reconnect"))
        }
    }

    func testAFileBackedClaudeLoginStillWorksWhenKeychainAccessIsDenied() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
        try bytes.write(to: directory.appendingPathComponent(".credentials.json"))
        let account = AgentAccount(provider: .claude, handle: .standard, configPath: directory.path)
        XCTAssertEqual(try RemoteConversationAccount.credentials(for: account, keychainExport: { _ in
            throw ClaudeKeychainCredentials.RemoteLoginExportError.accessRequired
        }), bytes)
    }

    func testCodexRecoveryNeverSuggestsGrantingClaudeKeychainAccess() {
        let failure = RemoteConversationFailure.credentialsUnavailable(.codex).launchFailure
        XCTAssertTrue(failure.summary.contains("auth.json"))
        XCTAssertFalse(failure.summary.contains("Claude"))
        XCTAssertFalse(failure.summary.contains("Privacy"))
        XCTAssertTrue(failure.detail.isEmpty)
    }

    func testPermissionRecoveryInTheShippingWindow() throws {
        let previous = AppThemeLibrary.current
        let palette = AppThemePalette.current
        defer { AppThemeLibrary.installResolved(previous); AppThemePalette.set(palette) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let triggers = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock {
            await triggers.close()
            try? FileManager.default.removeItem(at: root)
        }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude, title: "Windows chat"))
        let failure = RemoteConversationFailure.claudeKeychainAccessRequired.launchFailure
        XCTAssertEqual(ProjectStore.shared.update(sessionID: session.id) { $0.lastLaunchFailure = failure }, .applied)
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame, triggerStore: triggers)
        let window = try XCTUnwrap(shell.window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1100, height: 760))
        let container = shell.containerViewController
        container.show(sessionID: session.id)
        let surface = try XCTUnwrap(descendants(container.view).compactMap { $0 as? LaunchFailureView }.first)
        XCTAssertFalse(surface.isHidden)
        XCTAssertTrue(descendants(surface).compactMap { $0 as? ThemedSurfaceView }.allSatisfy(\.isHidden))
        let buttons = descendants(surface).compactMap { $0 as? ThemedButton }
        XCTAssertEqual(buttons.map(\.title), ["Open Privacy Settings", "Try Again", "Copy Details"])
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = try XCTUnwrap(window.contentView)
        for (name, theme, appearance) in [
            ("light", AppTheme.system, NSAppearance.Name.aqua),
            ("dark", AppTheme.system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ] {
            AppThemeLibrary.installResolved(theme)
            window.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            let summary = try XCTUnwrap(descendants(surface).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == failure.summary })
            XCTAssertLessThanOrEqual(summary.bounds.width, surface.bounds.width)
            XCTAssertGreaterThan(summary.bounds.height, summary.font!.pointSize * 3)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("remote-login-permission-\(name).png"))
        }
        buttons[0].performClick()
        XCTAssertTrue(descendants(container.view).contains { $0.accessibilityIdentifier() == "settings.privacy.page" },
                      "The recovery button must open the real Privacy page")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
