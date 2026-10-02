import XCTest
@testable import Threading

/// The popover that orders a project's default logins.
///
/// Driven through the buttons a person presses, with the logins stated rather than discovered, so
/// the order the store ends up holding is the order the presses made. Every control names its
/// login, which is what VoiceOver reads and what keeps three identical arrows apart.
@MainActor
final class ProjectDefaultAccountsEditorTests: HostedStoreTestCase {

    // MARK: - Fixture

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private static func account(_ provider: AgentKind, _ handle: AccountHandle) -> AgentAccount {
        AgentAccount(
            provider: provider,
            handle: handle,
            configPath: "/nonexistent/\(handle.name)",
            displayName: handle.isStandard ? "Personal" : handle.name,
            presentationNameIsResolved: true
        )
    }

    private let accounts = [
        account(.claude, .standard),
        account(.claude, .named("claude-work")),
        account(.codex, .named("codex-spare"))
    ]

    private func makeEditor() throws -> (ProjectDefaultAccountsViewController, ProjectID) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-accounts-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        addTeardownBlock { ProjectStore.shared.removeProject(id: project.id) }
        let editor = ProjectDefaultAccountsViewController(
            projectID: project.id,
            store: .shared,
            accountsProvider: { [accounts] in accounts }
        )
        _ = editor.view
        return (editor, project.id)
    }

    private func button(_ identifier: String, in view: NSView) throws -> ThemedIconButton {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityIdentifier() == identifier },
            "no control \(identifier)"
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func press(_ identifier: String, in view: NSView) throws {
        try button(identifier, in: view).onPress?()
    }

    // MARK: - Behavior

    func testAddingReorderingAndRemovingWritesTheOrderThePressesMade() throws {
        let (editor, projectID) = try makeEditor()
        let work = AccountID(provider: .claude, handle: .named("claude-work"))
        let spare = AccountID(provider: .codex, handle: .named("codex-spare"))

        try press("project-default-accounts.add.\(work.rawValue)", in: editor.view)
        try press("project-default-accounts.add.\(spare.rawValue)", in: editor.view)
        XCTAssertEqual(ProjectStore.shared.project(withID: projectID)?.defaultAccounts, [work, spare])

        try press("project-default-accounts.up.1", in: editor.view)
        XCTAssertEqual(ProjectStore.shared.project(withID: projectID)?.defaultAccounts, [spare, work])

        try press("project-default-accounts.remove.0", in: editor.view)
        XCTAssertEqual(ProjectStore.shared.project(withID: projectID)?.defaultAccounts, [work])

        try press("project-default-accounts.remove.0", in: editor.view)
        XCTAssertNil(
            ProjectStore.shared.project(withID: projectID)?.defaultAccounts,
            "an emptied order is no order, so the app-wide rule applies again"
        )
    }

    func testTheEndsOfTheOrderCannotMoveFurtherAndEveryControlNamesItsLogin() throws {
        let (editor, _) = try makeEditor()
        let work = AccountID(provider: .claude, handle: .named("claude-work"))
        let personal = AccountID(provider: .claude, handle: .standard)
        editor.add(work)
        editor.add(personal)

        XCTAssertFalse(try button("project-default-accounts.up.0", in: editor.view).isEnabled)
        XCTAssertTrue(try button("project-default-accounts.down.0", in: editor.view).isEnabled)
        XCTAssertTrue(try button("project-default-accounts.up.1", in: editor.view).isEnabled)
        XCTAssertFalse(try button("project-default-accounts.down.1", in: editor.view).isEnabled)

        let labels = descendants(of: editor.view)
            .compactMap { $0 as? ThemedIconButton }
            .compactMap { $0.accessibilityTitle() }
        XCTAssertEqual(labels.count, 7, "two listed rows of three controls, and one add")
        XCTAssertEqual(Set(labels).count, labels.count, "two controls read the same to VoiceOver")
        XCTAssertTrue(labels.contains { $0.contains("claude-work") })
    }

    func testAThemeChangeRestatesTheRowsInPlace() throws {
        let (editor, _) = try makeEditor()
        editor.add(AccountID(provider: .claude, handle: .named("claude-work")))
        let before = descendants(of: editor.view).count

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        defer { AppThemePalette.set(.system) }
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertEqual(descendants(of: editor.view).count, before)
        XCTAssertEqual(editor.list, [AccountID(provider: .claude, handle: .named("claude-work"))])
    }

    // MARK: - Rendered State

    func testRendersTheEditorToImages() throws {
        let (editor, _) = try makeEditor()
        editor.add(AccountID(provider: .claude, handle: .named("claude-work")))
        editor.add(AccountID(provider: .codex, handle: .named("codex-spare")))
        editor.add(AccountID(provider: .claude, handle: .named("claude-gone")))

        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            editor.view.appearance = appearance
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                editor.rebuild()
                editor.view.layoutSubtreeIfNeeded()
                editor.view.setFrameSize(editor.view.fittingSize)
                editor.view.layoutSubtreeIfNeeded()
                guard let rep = editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds) else {
                    return
                }
                editor.view.wantsLayer = true
                editor.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                editor.view.cacheDisplay(in: editor.view.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            let url = Render.directory.appendingPathComponent("project-default-accounts-\(name).png")
            try XCTUnwrap(data, "the editor did not render in \(name)").write(to: url)
        }
        XCTAssertGreaterThan(editor.view.fittingSize.height, 0)
    }
}
