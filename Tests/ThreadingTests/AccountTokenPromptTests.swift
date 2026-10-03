import AppKit
import XCTest
@testable import Threading

/// Exercises the production token action and native editor in an offscreen attached panel.
/// Keyboard routing requires the on-screen AccountTokenJourneyUITests scenario.
@MainActor
final class AccountTokenPromptTests: XCTestCase {
    func testPromptIdentityLookupUsesOnlyPreparedEmails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AgentAccount(
            provider: .claude, handle: .named(directory.lastPathComponent), configPath: directory.path
        )
        try Data("{\"oauthAccount\":{\"emailAddress\":\"fixture@example.test\"}}".utf8)
            .write(to: directory.appendingPathComponent(".claude.json"))
        XCTAssertNil(AccountAvatarStore.preparedEmail(for: account))
        await AccountAvatarStore.primeEmails(for: [account])
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".claude.json"))
        XCTAssertEqual(AccountAvatarStore.preparedEmail(for: account), "fixture@example.test")
    }

    func testConfirmSavesTheActiveSecureEditorAndRestoresTheParent() async throws {
        let account = AgentAccount(
            provider: .claude, handle: .named("token-save-fixture"),
            configPath: "/tmp/claude-token-save-fixture", displayName: "Work"
        )
        let store = AgentAccountTokenStore(
            keychain: InMemoryKeychainItemAccess(), dataProtection: { false }
        )
        let vault = AgentAccountTokenVault(store: store)
        let section = AccountTokenSectionController(vault: vault)
        _ = section.eligibleIndices(in: [account])
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let row = section.rowContent(forAccountAt: 0)
        window.contentView = row
        let use = try XCTUnwrap(descendants(row).compactMap { $0 as? ThemedButton }
            .first { $0.title == "Use Token…" })
        XCTAssertTrue(use.performPrimaryAction())
        let panel = try XCTUnwrap(window.childWindows?.first)
        let content = try XCTUnwrap(panel.contentView)
        let field = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedSecureField }.first)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let token = "sk-ant-oat01-" + String(repeating: "Ab1-_", count: 20)
        editor.insertText(token, replacementRange: NSRange(location: 0, length: 0))

        let saved = expectation(description: "saved token restamps its row")
        section.onRowsChange = { saved.fulfill() }
        let confirm = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedButton }
            .first { $0.title == "Use Token" })
        XCTAssertTrue(confirm.performPrimaryAction())
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(vault.cachedToken(for: account.id)?.value, token)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testTokenPromptOpeningAndEditing() throws {
        let savedTheme = AppThemePalette.current
        defer { AppThemePalette.set(savedTheme) }
        let account = AgentAccount(
            provider: .claude,
            handle: .named("token-prompt-fixture"),
            configPath: "/tmp/claude-token-prompt-fixture",
            displayName: "Work"
        )
        let section = AccountTokenSectionController()
        _ = section.eligibleIndices(in: [account])
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }

        var themes: [(AppTheme, NSAppearance.Name)] = [
            (.system, .aqua), (.system, .darkAqua),
            (AppThemeStyles.cyberpunk, .darkAqua), (AppThemeStyles.win98, .aqua)
        ]
        if let path = ProcessInfo.processInfo.environment["THREADING_TOKEN_PROMPT_THEME"] {
            let theme = try JSONDecoder().decode(AppTheme.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            themes.append((theme, .aqua))
            themes.append((theme, .darkAqua))
        }
        for (theme, appearanceName) in themes {
            AppThemePalette.set(theme)
            window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let row = section.rowContent(forAccountAt: 0)
            window.contentView = row
            let use = try XCTUnwrap(descendants(row).compactMap { $0 as? ThemedButton }
                .first { $0.title == "Use Token…" })
            for iteration in 0..<3 {
                let start = ContinuousClock.now
                _ = (use.target as AnyObject?)?.perform(use.action, with: use)
                let panel = try XCTUnwrap(window.childWindows?.first)
                let content = try XCTUnwrap(panel.contentView)
                content.layoutSubtreeIfNeeded()
                print("THREADING_PERF token-prompt \(theme.name) iteration=\(iteration) opening=\(start.duration(to: .now))")
                let field = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedSecureField }.first)
                let editStart = ContinuousClock.now
                XCTAssertTrue(panel.makeFirstResponder(field))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                let token = "sk-ant-oat01-" + String(repeating: "Ab1-_", count: 20)
                editor.insertText(token, replacementRange: NSRange(location: 0, length: 0))
                XCTAssertEqual(editor.string, token)
                content.layoutSubtreeIfNeeded()
                print("THREADING_PERF token-prompt \(theme.name) editing=\(editStart.duration(to: .now))")
                XCTAssertGreaterThan(field.frame.height, 0)
                if iteration == 0 { try render(content, theme: theme, appearance: appearanceName) }
                panel.cancelOperation(nil)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
                XCTAssertFalse(window.ignoresMouseEvents)
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func render(_ content: NSView, theme: AppTheme, appearance: NSAppearance.Name) throws {
        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let suffix = appearance == .aqua ? "light" : "dark"
        try png.write(to: directory.appendingPathComponent("account-token-prompt-\(theme.id.rawValue)-\(suffix).png"))
    }
}
