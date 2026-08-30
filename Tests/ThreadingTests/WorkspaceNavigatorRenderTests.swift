import AppKit
import ThreadingExtensionKit
import XCTest

@testable import Threading

/// Captures an extension navigator in the shipping main-window split shell. The header cannot be
/// reviewed honestly as an isolated band: its title truncation, sidebar width, separator, themed
/// ground, collection viewport and menu overlay are relationships owned by the real window.
@MainActor
final class WorkspaceNavigatorRenderTests: HostedStoreTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let windowSize = NSSize(width: 1_120, height: 720)
    }

    private struct AppearanceFixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersFocusedNavigatorAndNativeRouteInTheMainWindow() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        let previousSelection = AppSettings.shared.workspaceNavigatorSelection
        defer {
            AppSettings.shared.workspaceNavigatorSelection = previousSelection
            AppThemePalette.set(previousTheme)
        }

        let router = try WorkspaceNavigatorEvidenceRouter()
        let factRegistry = try makePipelineFactRegistry()
        let controller = makeMainWindowController(
            initialFramePlan: .useDefaultFrame,
            workspaceNavigatorRouting: router
        )
        controller.installWorkspaceNavigatorFactRegistry(factRegistry)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Render.windowSize)
        let content = try XCTUnwrap(window.contentView)
        // The composer deliberately chooses a fresh greeting for every arrival. This catalogue
        // owns the navigator, not that unrelated welcome copy, so pin the one multiline hero in
        // the shipping shell before hashing the pixels. A second evidence run must prove the
        // same navigator rather than fail because the composer rolled another valid sentence.
        let greeting = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? MorphingMultilineTitleLabel }.first
        )
        greeting.setStringValue("What are we building today?", animated: false)
        let selection = WorkspaceNavigatorSelection.extensionNavigator(
            extensionIdentifier: router.inventory.extensionIdentifier,
            navigatorID: router.inventory.navigator.id
        )
        let fixtures = [
            AppearanceFixture(name: "system-light", theme: .system, appearance: .aqua),
            AppearanceFixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            AppearanceFixture(
                name: "cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua
            ),
            AppearanceFixture(
                name: "swiss",
                theme: AppThemeStyles.swissMinimalist,
                appearance: .aqua
            )
        ]

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            content.appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            controller.selectWorkspaceNavigator(selection)
            AppThemeRefresh.repaint(content)
            try suppressComposerUsage(in: content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()

            try write(content, named: "workspace-navigator-\(fixture.name)-focused.png")

            let menuButton = try XCTUnwrap(
                descendants(of: content).compactMap { $0 as? ThemedIconButton }.first {
                    $0.accessibilityIdentifier() == "workspace.navigator.menu"
                }
            )
            XCTAssertTrue(menuButton.accessibilityPerformPress())
            XCTAssertTrue(ThemedMenuPresenter.isMenuOpen(in: window))
            try suppressComposerUsage(in: content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try write(content, named: "workspace-navigator-\(fixture.name)-menu.png")

            // This is the same callback the menu row reaches. Besides preparing the next
            // fixture, it proves the outgoing source cannot leave its self-retained overlay.
            controller.selectWorkspaceNavigator(.native)
            XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: window))
        }

        AppThemePalette.set(.system)
        content.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        controller.selectWorkspaceNavigator(.extensionNavigator(
            extensionIdentifier: router.pipelineInventory.extensionIdentifier,
            navigatorID: router.pipelineInventory.navigator.id
        ))
        _ = try waitForPipelineTable(in: content, rowCount: 8)
        AppThemeRefresh.repaint(content)
        try suppressComposerUsage(in: content)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        try write(content, named: "workspace-navigator-pipeline-system-light-focused.png")

        let pipelineMenuButton = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ThemedIconButton }.first {
                $0.accessibilityIdentifier() == "workspace.navigator.menu"
            }
        )
        XCTAssertTrue(pipelineMenuButton.accessibilityPerformPress())
        XCTAssertTrue(ThemedMenuPresenter.isMenuOpen(in: window))
        try suppressComposerUsage(in: content)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        try write(content, named: "workspace-navigator-pipeline-system-light-menu.png")
        controller.selectWorkspaceNavigator(.native)
        XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: window))

        for fixture in [
            AppearanceFixture(name: "system-light", theme: .system, appearance: .aqua),
            AppearanceFixture(
                name: "cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua
            ),
            AppearanceFixture(
                name: "swiss",
                theme: AppThemeStyles.swissMinimalist,
                appearance: .aqua
            ),
        ] {
            AppThemePalette.set(fixture.theme)
            content.appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            controller.selectWorkspaceNavigator(.extensionNavigator(
                extensionIdentifier: router.pipelineInventory.extensionIdentifier,
                navigatorID: router.pipelineInventory.navigator.id
            ))
            let table = try waitForPipelineTable(in: content, rowCount: 8)
            _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            let template = try XCTUnwrap(
                descendants(of: table).compactMap {
                    $0 as? WorkspaceNavigatorPipelineTemplateView
                }.first
            )
            template.setIntentControlsPresented(true)
            AppThemeRefresh.repaint(content)
            try suppressComposerUsage(in: content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try write(
                content,
                named: "workspace-navigator-pipeline-\(fixture.name)-intents.png"
            )

            if fixture.name == "system-light" {
                template.setIntentControlsPresented(false)
                let pin = try XCTUnwrap(
                    descendants(of: template).compactMap { $0 as? ThemedIconButton }.first {
                        $0.accessibilityIdentifier() == "workspace.navigator.intent.pin"
                    }
                )
                XCTAssertTrue(window.makeFirstResponder(pin))
                content.displayIfNeeded()
                try write(
                    content,
                    named: "workspace-navigator-pipeline-system-light-intent-focus.png"
                )
                XCTAssertTrue(window.makeFirstResponder(nil))
            }
            controller.selectWorkspaceNavigator(.native)
        }

        AppThemePalette.set(.system)
        content.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        controller.selectWorkspaceNavigator(.extensionNavigator(
            extensionIdentifier: router.pipelineInventory.extensionIdentifier,
            navigatorID: router.pipelineInventory.navigator.id
        ))
        _ = try waitForPipelineTable(in: content, rowCount: 8)
        // The preceding intent matrix ends in Swiss. Setting the palette changes the model;
        // repainting is what returns every already-mounted composer control to System chrome.
        AppThemeRefresh.repaint(content)
        let pipelineSearch = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? ThemedSearchField }.first
        )
        pipelineSearch.stringValue = "No matching focused work"
        pipelineSearch.delegate?.controlTextDidChange?(Notification(
            name: NSControl.textDidChangeNotification,
            object: pipelineSearch
        ))
        _ = try waitForPipelineTable(in: content, rowCount: 0)
        try suppressComposerUsage(in: content)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        try write(content, named: "workspace-navigator-pipeline-system-light-empty.png")
        controller.selectWorkspaceNavigator(.native)

        let activitySelection = WorkspaceNavigatorSelection.extensionNavigator(
            extensionIdentifier: router.activityInboxInventory.extensionIdentifier,
            navigatorID: router.activityInboxInventory.navigator.id
        )
        for fixture in [
            AppearanceFixture(name: "system-light", theme: .system, appearance: .aqua),
            AppearanceFixture(name: "system-dark", theme: .system, appearance: .darkAqua),
        ] {
            AppThemePalette.set(fixture.theme)
            content.appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            controller.selectWorkspaceNavigator(activitySelection)
            _ = try waitForPipelineTable(in: content, rowCount: 9)
            freezePipelineSpinners(in: content)
            AppThemeRefresh.repaint(content)
            try suppressComposerUsage(in: content)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            try write(
                content,
                named: "workspace-navigator-activity-inbox-\(fixture.name).png"
            )

            if fixture.name == "system-light" {
                let menuButton = try XCTUnwrap(
                    descendants(of: content).compactMap { $0 as? ThemedIconButton }.first {
                        $0.accessibilityIdentifier() == "workspace.navigator.menu"
                    }
                )
                XCTAssertTrue(menuButton.accessibilityPerformPress())
                XCTAssertTrue(ThemedMenuPresenter.isMenuOpen(in: window))
                freezePipelineSpinners(in: content)
                try suppressComposerUsage(in: content)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                try write(
                    content,
                    named: "workspace-navigator-activity-inbox-system-light-menu.png"
                )
            }
            controller.selectWorkspaceNavigator(.native)
            XCTAssertFalse(ThemedMenuPresenter.isMenuOpen(in: window))
        }

        print("Rendered the focused workspace navigator to \(Render.directory.path)")
    }

    private func makePipelineFactRegistry() throws -> ExtensionFactRegistry {
        let registry = ExtensionFactRegistry(now: { Date(timeIntervalSinceReferenceDate: 100) })
        let keys: Set<ExtensionFactKey> = [
            ExtensionHostFactKey.sessionTitle,
            ExtensionHostFactKey.sessionDetailedActivity,
            ExtensionHostFactKey.sessionBranch,
            ExtensionHostFactKey.sessionLastUsedAt,
            ExtensionHostFactKey.sessionIsArchived,
            ExtensionHostFactKey.sessionIsSnoozed,
        ]
        try registry.replaceHostDefinitions(
            HostFactCatalog.definitions.filter { keys.contains($0.key) }
        )
        let rows: [(String, String, String, String, ExtensionStatusRole)] = [
            ("pipeline-1", "Review navigator permissions", ExtensionSessionDetailedActivity.awaitingUser.rawValue, "Waiting for you", .warning),
            ("pipeline-2", "Prepare the 1.4 release", ExtensionSessionDetailedActivity.working.rawValue, "Working", .positive),
            ("pipeline-3", "Design a focused project sidebar", ExtensionSessionDetailedActivity.idle.rawValue, "Idle", .neutral),
            ("pipeline-4", "Keep lifecycle tests deterministic", ExtensionSessionDetailedActivity.working.rawValue, "Working", .positive),
            ("pipeline-5", "Document host-owned recovery", ExtensionSessionDetailedActivity.idle.rawValue, "Idle", .neutral),
            ("pipeline-6", "Join GitLab merge-request state", ExtensionSessionDetailedActivity.awaitingUser.rawValue, "Waiting", .warning),
            ("pipeline-7", "Move search into the host transform", ExtensionSessionDetailedActivity.working.rawValue, "Working", .positive),
            ("pipeline-8", "Define safe row intents", ExtensionSessionDetailedActivity.idle.rawValue, "Planned", .neutral),
        ]
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let lastUsedByID: [String: Date] = [
            "pipeline-1": calendar.date(byAdding: .day, value: -10, to: today)!,
            "pipeline-2": calendar.date(byAdding: .hour, value: -1, to: now)!,
            "pipeline-3": calendar.date(byAdding: .hour, value: -2, to: now)!,
            "pipeline-4": calendar.date(byAdding: .hour, value: -12, to: today)!,
            "pipeline-5": calendar.date(byAdding: .day, value: -4, to: today)!,
            "pipeline-6": now,
            "pipeline-7": calendar.date(byAdding: .day, value: -10, to: today)!,
            "pipeline-8": now,
        ]
        let observedAt = Date(timeIntervalSinceReferenceDate: 50)
        let facts = rows.flatMap { id, title, activity, activityLabel, status in
            let subject = ExtensionFactSubject.session(id)
            return [
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionTitle,
                    subject: subject,
                    value: .string(title),
                    observedAt: observedAt
                ),
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionDetailedActivity,
                    subject: subject,
                    value: .string(activity),
                    label: activityLabel,
                    status: status,
                    observedAt: observedAt
                ),
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionBranch,
                    subject: subject,
                    value: .string("navigator-pipeline"),
                    observedAt: observedAt
                ),
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionLastUsedAt,
                    subject: subject,
                    value: .date(lastUsedByID[id]!),
                    observedAt: observedAt
                ),
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionIsArchived,
                    subject: subject,
                    value: .boolean(id == "pipeline-6"),
                    observedAt: observedAt
                ),
                ExtensionFact(
                    key: ExtensionHostFactKey.sessionIsSnoozed,
                    subject: subject,
                    value: .boolean(id == "pipeline-8"),
                    observedAt: observedAt
                ),
            ]
        }
        try registry.replaceHostFacts(
            facts,
            replacing: Set(rows.map { .session($0.0) })
        )
        return registry
    }

    private func waitForPipelineTable(
        in root: NSView,
        rowCount: Int,
        timeout: TimeInterval = 2
    ) throws -> ThemedTableView {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let table = descendants(of: root).compactMap({ $0 as? ThemedTableView }).first(
                where: {
                    $0.accessibilityIdentifier().hasPrefix("workspace.navigator.collection.")
                        && $0.numberOfRows == rowCount
                }
            ) {
                return table
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return try XCTUnwrap(
            nil as ThemedTableView?,
            "pipeline evidence table did not reach \(rowCount) rows before timeout"
        )
    }

    /// The surrounding shipping composer may receive a live account-usage edge while this
    /// navigator evidence is being captured. Keep that unrelated reading deterministic so a
    /// later pipeline image cannot differ from an earlier shell image merely because the
    /// provider refreshed between them.
    private func suppressComposerUsage(in root: NSView) throws {
        let subtree = [root] + descendants(of: root)
        let controls = subtree + subtree
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
        let usage = try XCTUnwrap(
            controls.compactMap { $0 as? UsageReadingLabel }.first {
                $0.accessibilityIdentifier() == "composer.session-start.usage"
            }
        )
        usage.readings = []
        usage.toolTip = nil
        usage.isHidden = true
    }

    /// Evidence must show the working indicator without sampling a different animation frame on
    /// the second strict pass. Removing only the presentation animation leaves the semantic arc
    /// visible and keeps its accessibility identity intact.
    private func freezePipelineSpinners(in root: NSView) {
        for spinner in descendants(of: root).compactMap({ $0 as? ThemedSpinner }) {
            spinner.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        }
    }

    private func write(_ view: NSView, named filename: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Render.directory.appendingPathComponent(filename))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class WorkspaceNavigatorEvidenceRouter: ExtensionWorkspaceNavigatorRouting {
    let inventory: ExtensionWorkspaceNavigatorInventoryItem
    let pipelineInventory: ExtensionWorkspaceNavigatorInventoryItem
    let activityInboxInventory: ExtensionWorkspaceNavigatorInventoryItem

    init() throws {
        let sections = [
            ExtensionWorkspaceNavigatorSection(
                id: "priority",
                header: .text("Priority", role: .heading)
            ),
            ExtensionWorkspaceNavigatorSection(
                id: "recent",
                header: .text("Recent", role: .heading)
            )
        ]
        let rows: [(String, String, String, ExtensionStatusRole)] = [
            ("permission", "Review navigator permissions", "Waiting for you", .warning),
            ("release", "Prepare the 1.4 release", "Working · release/1.4", .positive),
            ("sidebar", "Design a focused project sidebar", "Idle · navigator-pipeline", .neutral),
            ("tests", "Keep extension lifecycle tests deterministic", "Done · main", .positive),
            ("docs", "Document host-owned recovery", "Idle · docs", .neutral),
            ("gitlab", "Join GitLab merge-request state", "Waiting · provider", .warning),
            ("search", "Move search into the host transform", "Planned · pipeline", .neutral),
            ("intents", "Define safe row intents", "Planned · pipeline", .neutral)
        ]
        let items = rows.enumerated().map { index, row in
            ExtensionWorkspaceNavigatorItem(
                id: row.0,
                sectionID: index < 2 ? "priority" : "recent",
                content: .stack(
                    axis: .vertical,
                    spacing: .tight,
                    children: [
                        .text(row.1, role: .compactBody),
                        .status(row.2, role: row.3)
                    ]
                ),
                activation: .destination(.session(
                    id: String(format: "00000000-0000-0000-0000-%012d", index + 1),
                    projectID: nil
                )),
                isSelected: index == 2
            )
        }
        let navigator = ExtensionWorkspaceNavigator(
            id: "focused-workspace",
            title: "Priority work across every checkout",
            root: .collection(.init(
                id: "sessions",
                layout: .list,
                sections: sections,
                items: items
            )),
            options: [
                .init(
                    id: "group",
                    title: "Group by project",
                    control: .toggle(defaultValue: true)
                )
            ]
        )
        inventory = .init(
            extensionIdentifier: "com.example.focused-navigator",
            extensionName: "Focused Navigator",
            processGeneration: "evidence-generation",
            navigator: navigator,
            optionValues: ["group": .bool(true)],
            optionPersistenceOutcome: .loaded
        )

        let title = ExtensionWorkspaceNavigatorFactReference(ExtensionHostFactKey.sessionTitle)
        let activity = ExtensionWorkspaceNavigatorFactReference(
            ExtensionHostFactKey.sessionDetailedActivity
        )
        let branch = ExtensionWorkspaceNavigatorFactReference(ExtensionHostFactKey.sessionBranch)
        let workingOnly = ExtensionWorkspaceNavigatorOption(
            id: "working-only",
            title: "Working only",
            control: .toggle(defaultValue: false)
        )
        let pipelineNavigator = ExtensionWorkspaceNavigator(
            id: "pipeline-workspace",
            title: "Focused work from shared session facts",
            root: .content(.text("Pipeline unavailable", role: .body)),
            options: [workingOnly],
            intents: [.pin, .archive],
            pipeline: .init(
                consumes: [
                    .init(key: title.key, requirement: .required),
                    .init(key: activity.key, requirement: .enhances),
                    .init(key: branch.key, requirement: .enhances),
                ],
                search: .init(
                    placeholder: "Find focused work",
                    accessibilityLabel: "Search focused navigator sessions",
                    fields: [title, branch]
                ),
                filters: [.init(
                    when: [.init(optionID: workingOnly.id, equals: .bool(true))],
                    predicate: .comparison(
                        .init(activity),
                        .equal,
                        .string(ExtensionSessionDetailedActivity.working.rawValue)
                    )
                )],
                sort: [.init(
                    operand: .init(title),
                    direction: .ascending
                )],
                output: .init(
                    collectionID: "pipeline-sessions",
                    rowTemplate: .stack(
                        axis: .vertical,
                        spacing: .tight,
                        children: [
                            .text(
                                .fact(title, facet: .value, fallback: "Untitled session"),
                                role: .compactBody
                            ),
                            .stack(
                                axis: .horizontal,
                                spacing: .small,
                                children: [
                                    .status(
                                        .fact(activity, facet: .label, fallback: "Idle"),
                                        role: .factStatus(activity, fallback: .neutral)
                                    ),
                                    .flexibleSpacer,
                                    .text(
                                        .fact(branch, facet: .value, fallback: "No branch"),
                                        role: .compactDetail
                                    ),
                                    .intent(.pin),
                                    .intent(.archive),
                                ]
                            ),
                        ]
                    ),
                    emptyState: .init(title: "No focused work")
                )
            )
        )
        pipelineInventory = .init(
            extensionIdentifier: "com.example.pipeline-navigator",
            extensionName: "Pipeline Navigator",
            processGeneration: "pipeline-evidence-generation",
            navigator: pipelineNavigator,
            optionValues: [workingOnly.id: .bool(false)],
            optionPersistenceOutcome: .loaded
        )

        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Packages/ThreadingExtensionKit/Examples/ActivityInboxExtension/"
                    + "threading-extension.json"
            )
        let manifest = try JSONDecoder().decode(
            ExtensionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try manifest.validate()
        guard let activityInbox = manifest.workspaceNavigators.first(where: {
            $0.id == "activity-inbox"
        }), let sortOption = activityInbox.options.first(where: {
            $0.id == "sort-order"
        }) else {
            throw WorkspaceNavigatorEvidenceError.missingActivityInboxDeclaration
        }
        activityInboxInventory = .init(
            extensionIdentifier: manifest.identifier,
            extensionName: manifest.name,
            processGeneration: "activity-inbox-evidence-generation",
            navigator: activityInbox,
            optionValues: [sortOption.id: .string("recent")],
            optionPersistenceOutcome: .loaded
        )
    }

    var extensionWorkspaceNavigatorInventory: [ExtensionWorkspaceNavigatorInventoryItem] {
        [inventory, pipelineInventory, activityInboxInventory]
    }

    func registeredWorkspaceNavigator(
        extensionIdentifier: String,
        navigatorID: String
    ) -> ExtensionWorkspaceNavigatorInventoryItem? {
        extensionWorkspaceNavigatorInventory.first {
            $0.extensionIdentifier == extensionIdentifier && $0.navigator.id == navigatorID
        }
    }

    func extensionImageResourceURL(
        extensionIdentifier: String,
        relativePath: String
    ) -> URL? {
        nil
    }

    func invokeWorkspaceNavigatorAction(
        extensionIdentifier: String,
        navigatorID: String,
        actionID: String,
        value: ExtensionJSONValue?,
        context: ExtensionCommandContext,
        completion: @escaping (
            Result<ExtensionWorkspaceNavigatorActionResponse, Error>
        ) -> Void
    ) -> Bool {
        false
    }
}

private enum WorkspaceNavigatorEvidenceError: Error {
    case missingActivityInboxDeclaration
}
