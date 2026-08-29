import AppKit
import XCTest
@testable import Threading

/// The complete visible manager-role story, in both system appearances.
///
/// These images are intentionally feature-shaped rather than component-shaped: a reviewer sees
/// the role at creation, in navigation, while supervising, in the command plane, and where its
/// global controls and audit trail live. That keeps a change from being "covered" by a glyph in
/// isolation while its actual sentence, neighbouring controls, or full-page hierarchy is wrong.
@MainActor
final class ManagerRoleRenderTests: HostedStoreTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua),
        ]
    }

    private final class ControllerHostView: NSView {
        var retainedControllers: [NSViewController] = []
    }

    func testRendersEveryManagerRoleSurface() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            AppThemePalette.set(.system)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        // The composer mark stitches itself in when motion is enabled. An offscreen evidence
        // capture otherwise records whichever animation frame happens to be presented when the
        // bitmap is cached, so two complete-suite runs can disagree only inside the logo.
        Design.Motion.reduceMotionOverrideForTesting = true
        AppThemePalette.set(.system)

        let fixture = try makeFixture()
        var written = 0

        written += try writeStory(
            named: "manager-role-composer",
            size: NSSize(width: 900, height: 640)
        ) { [self] in managerComposer(projectID: fixture.project.id) }

        written += try writeStory(
            named: "manager-role-fleet",
            size: NSSize(width: 940, height: 720)
        ) { [self] in fleetSurface(fixture) }

        written += try writeStory(
            named: "manager-role-tools-settings",
            size: NSSize(width: 680, height: 820)
        ) { [self] in toolsSettings() }

        written += try writeStory(
            named: "manager-role-advanced-settings",
            size: NSSize(width: 680, height: 860)
        ) { [self] in controllerHost(AdvancedPreferencesViewController()) }

        written += try writeStory(
            named: "manager-role-archived-settings",
            size: NSSize(width: 680, height: 460)
        ) { [self] in archivedSettings(fixture) }

        written += try writeStory(
            named: "manager-role-command-palette",
            size: NSSize(width: 760, height: 500)
        ) { [self] in commandPalette() }

        written += try writeMenu(
            named: "manager-role-project-create-menu",
            size: NSSize(width: 420, height: 300)
        ) {
            [
                .item(ThemedMenuItem(
                    title: L10n.string("New Chat…"),
                    shortcut: ShortcutOverrideStore.shared.shortcut(
                        forID: AppCommands.ID.newSession
                    ),
                    image: ThemedMenuIcon.symbol("bubble.left"),
                    onChoose: {}
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("New Manager…"),
                    shortcut: ShortcutOverrideStore.shared.shortcut(
                        forID: AppCommands.ID.newManager
                    ),
                    image: ThemedMenuIcon.symbol("person.3"),
                    onChoose: {}
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("New Terminal"),
                    image: ThemedMenuIcon.symbol("terminal"),
                    onChoose: {}
                )),
            ]
        }

        written += try writeMenu(
            named: "manager-role-make-menu",
            size: NSSize(width: 460, height: 820)
        ) { [self] in sessionMenuEntries(for: fixture.regular) }

        written += try writeMenu(
            named: "manager-role-revoke-menu",
            size: NSSize(width: 460, height: 820)
        ) { [self] in sessionMenuEntries(for: fixture.manager) }

        XCTAssertEqual(written, 18, "Every manager-role surface should exist in light and dark")
        print("Rendered manager-role evidence to \(directory.path)")
    }

    // MARK: - Fixture

    private struct Fixture {
        let project: Project
        let manager: AgentSession
        let regular: AgentSession
        let children: [AgentSession]
        let supervisions: [Supervision]
        let archived: AgentSession
    }

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-manager-role-evidence/Release Control", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        _ = store.renameProject(id: project.id, to: "Release Control")

        let manager = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true,
            title: "Release coordinator"
        ))
        let regular = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Review launch checklist"
        ))
        let titles: [(String, AgentKind)] = [
            ("Fix account routing", .codex),
            ("Verify UI evidence", .claude),
            ("Prepare release notes", .codex),
        ]
        let children = try titles.map { title, kind in
            try XCTUnwrap(store.addSession(to: project.id, kind: kind, title: title))
        }
        let archived = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Retire obsolete migration"
        ))

        _ = try XCTUnwrap(ControlGrantStore.shared.conferManager(
            sessionID: manager.id,
            origin: .newManagerTemplate
        ))
        let briefs = [
            "Move the saturated account safely, then report the result.",
            "Capture and inspect the complete light and dark evidence set.",
            "Summarize the user-visible authority and supervision changes.",
        ]
        var supervisions: [Supervision] = []
        for (child, brief) in zip(children, briefs) {
            guard case .adopted(let supervision) = ControlGrantStore.shared.adopt(
                childID: child.id,
                by: manager.id,
                brief: brief
            ) else {
                return try XCTUnwrap(nil, "Could not build supervised child fixture")
            }
            supervisions.append(supervision)
        }

        guard case .adopted = ControlGrantStore.shared.adopt(
            childID: archived.id,
            by: manager.id,
            brief: "Remove the obsolete path and archive when complete."
        ) else {
            return try XCTUnwrap(nil, "Could not build archived supervision fixture")
        }
        XCTAssertTrue(ControlGrantStore.shared.archive(childID: archived.id, by: manager.id))
        XCTAssertEqual(store.setArchived(true, for: archived.id), .applied)

        return Fixture(
            project: try XCTUnwrap(store.project(withID: project.id)),
            manager: try XCTUnwrap(store.session(withID: manager.id)),
            regular: try XCTUnwrap(store.session(withID: regular.id)),
            children: children.compactMap { store.session(withID: $0.id) },
            supervisions: supervisions,
            archived: try XCTUnwrap(store.session(withID: archived.id))
        )
    }

    // MARK: - Surfaces

    private func managerComposer(projectID: ProjectID) -> NSView {
        let controller = SessionComposerViewController()
        _ = controller.view
        controller.show(projectID: projectID)
        controller.presetManagerRole()
        descendants(of: controller.view).compactMap { $0 as? PromptView }.first?.stringValue =
            "Coordinate the release, delegate verification, and stop when every check is green."
        return controllerHost(controller)
    }

    private func fleetSurface(_ fixture: Fixture) -> NSView {
        let root = ControllerHostView()

        let title = PageTitleView(symbolName: fixture.manager.kind.symbolName, inkSource: .chrome)
        title.update(
            title: fixture.manager.displayTitle,
            symbolName: fixture.manager.kind.symbolName,
            identity: fixture.manager.id
        )
        title.setRoleSymbol("person.3", accessibility: L10n.string("Manager"))
        let header = PaneHeaderView(leading: [title], margin: .paneEdge)

        let managerRow = SessionRowView(customizationLookup: { _ in .empty })
        managerRow.configure(with: fixture.manager, activity: .working)
        let childRow = SessionRowView(customizationLookup: { _ in .empty })
        childRow.configure(with: fixture.children[1], activity: .awaitingUser)
        let managerInfo = SessionInfoPopoverViewController(
            info: .init(session: fixture.manager, activity: .working),
            isEmbedded: true
        )
        let childInfo = SessionInfoPopoverViewController(
            info: .init(session: fixture.children[1], activity: .awaitingUser),
            isEmbedded: true
        )
        root.retainedControllers = [managerInfo, childInfo]

        let rows = NSStackView(views: [managerRow, childRow])
        rows.orientation = .vertical
        rows.spacing = 0
        rows.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.small,
            right: Design.Spacing.medium
        )
        managerRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
        childRow.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let inspectorStack = NSStackView(views: [rows, managerInfo.view, childInfo.view])
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = Design.Spacing.large
        inspectorStack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.large,
            left: Design.Spacing.large,
            bottom: Design.Spacing.large,
            right: Design.Spacing.large
        )
        inspectorStack.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let activities: [SessionActivity] = [.working, .awaitingUser, .idle]
        let eventKinds: [SupervisionEventKind] = [.reportReceived, .needsAttention, .settled]
        let listRows = zip(zip(fixture.supervisions, fixture.children), zip(activities, eventKinds))
            .map { pair, state in
                SupervisionListViewController.Row(
                    supervision: pair.0,
                    session: pair.1,
                    activity: state.0,
                    lastEvent: SupervisionEvent(
                        supervisionID: pair.0.id,
                        at: fixedNow.addingTimeInterval(-300),
                        kind: state.1,
                        detail: nil
                    )
                )
            }
        let chats = SupervisionListViewController(
            managerID: fixture.manager.id,
            rowsProvider: { listRows },
            now: { fixedNow }
        )
        root.retainedControllers.append(chats)

        let body = NSStackView(views: [inspectorStack, chats.view])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0
        body.distribution = .fill

        let notice = PaneNoticeView(
            tone: .informational,
            message: L10n.format("Moved to %1$@ by %2$@", "Codex · Backup", fixture.manager.displayTitle),
            actions: [PaneNoticeAction(title: L10n.string("Undo")) {}],
            onDismiss: {}
        )

        for item in [header, body, notice] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: notice.topAnchor),
            chats.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            chats.view.heightAnchor.constraint(equalTo: body.heightAnchor),
            notice.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            notice.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func toolsSettings() -> NSView {
        let controller = ToolsPreferencesViewController(groups: [MCPToolCatalog.supervision])
        _ = controller.view
        controller.setGroup(MCPToolCatalog.supervision.id, expanded: true)
        return controllerHost(controller)
    }

    private func archivedSettings(_ fixture: Fixture) -> NSView {
        var archived = fixture.archived
        let archiveDate = Date().addingTimeInterval(-3_600)
        archived.lastActiveAt = archiveDate
        archived.archivedAt = archiveDate
        let controller = ArchivedPreferencesViewController(rowsProvider: {
            [(fixture.project, archived)]
        })
        _ = controller.view
        controller.viewWillAppear()
        return controllerHost(controller)
    }

    private func commandPalette() -> NSView {
        let ids = [
            AppCommands.ID.newManager,
            AppCommands.ID.makeManager,
            AppCommands.ID.revokeManager,
        ]
        let descriptors = ids.compactMap(AppCommands.command).map {
            $0.hostDescriptor(shortcut: nil, availability: .available)
        }
        let controller = CommandPaletteViewController(
            catalog: { descriptors },
            invoke: { .invoked(commandID: $0) }
        )
        _ = controller.view
        controller.setSearchQueryForTesting("manager")
        let deadline = Date().addingTimeInterval(2)
        while controller.visibleCommandIDsForTesting.count != descriptors.count, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(Set(controller.visibleCommandIDsForTesting), Set(ids))
        return controllerHost(controller)
    }

    private func controllerHost(_ controller: NSViewController) -> NSView {
        let host = ControllerHostView()
        host.retainedControllers = [controller]
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        return host
    }

    private func sessionMenuEntries(for session: AgentSession) -> [ThemedMenuEntry] {
        let sidebar = ProjectSidebarViewController()
        sidebar.actionSessionID = session.id
        return sidebar.sessionActionEntries(for: session)
    }

    // MARK: - Rendering

    private func writeStory(
        named name: String,
        size: NSSize,
        build: @escaping () -> NSView
    ) throws -> Int {
        var written = 0
        for (appearanceName, appearanceID) in Render.appearances {
            let data = try XCTUnwrap(
                image(size: size, appearance: appearanceID, build: build),
                "Could not render \(name) in \(appearanceName)"
            )
            try data.write(to: Render.directory.appendingPathComponent(
                "\(name)-\(appearanceName).png"
            ))
            written += 1
        }
        return written
    }

    private func image(
        size: NSSize,
        appearance name: NSAppearance.Name,
        build: @escaping () -> NSView
    ) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render: @MainActor () -> Void = {
            let host = ThemedSurfaceView()
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = appearance
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
            let content = build()
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    private func writeMenu(
        named name: String,
        size: NSSize,
        entries: @escaping () -> [ThemedMenuEntry]
    ) throws -> Int {
        var written = 0
        for (appearanceName, appearanceID) in Render.appearances {
            let data = try XCTUnwrap(
                menuImage(size: size, appearance: appearanceID, entries: entries()),
                "Could not render \(name) in \(appearanceName)"
            )
            try data.write(to: Render.directory.appendingPathComponent(
                "\(name)-\(appearanceName).png"
            ))
            written += 1
        }
        return written
    }

    private func menuImage(
        size: NSSize,
        appearance name: NSAppearance.Name,
        entries: [ThemedMenuEntry]
    ) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        let render: @MainActor () -> Void = {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            let root = ThemedSurfaceView()
            root.frame = NSRect(origin: .zero, size: size)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 12, y: size.height - 32, width: 1, height: 1))
            root.addSubview(source)
            window.contentView = root
            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: SidebarDefaults.menuWidth),
                from: source,
                selectedEntryIndex: nil,
                onChoose: { _, _ in },
                onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
