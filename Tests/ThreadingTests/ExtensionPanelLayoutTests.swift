import AppKit
import XCTest
@testable import Threading
import ThreadingExtensionKit

/// Pins the panel host's readable inset. The content stack always *declared*
/// `Design.Spacing.pane` on every edge — and the GitHub Checks panel still rendered flush
/// against the pane's edge, because each row was pinned to the stack's full width, the
/// trailing inset became unsatisfiable, and the solver broke the leading pin. Frames, not
/// constraints, are what this asserts, since the constraints were "right" the whole time.
@MainActor
final class ExtensionPanelLayoutTests: XCTestCase {

    private final class FakeRouter: ExtensionPanelRouting {
        var item: ExtensionPanelInventoryItem?

        var extensionPanelInventory: [ExtensionPanelInventoryItem] {
            item.map { [$0] } ?? []
        }

        func registeredPanel(
            extensionIdentifier: String,
            panelID: String
        ) -> ExtensionPanelInventoryItem? {
            item
        }

        func extensionImageResourceURL(
            extensionIdentifier: String,
            relativePath: String
        ) -> URL? {
            nil
        }

        func invokePanelAction(
            extensionIdentifier: String,
            panelID: String,
            actionID: String,
            context: ExtensionCommandContext,
            completion: @escaping (Result<ExtensionActionResponse, Error>) -> Void
        ) -> Bool {
            // Deliberately never completes: the test reads the panel's *registered* value.
            true
        }
    }

    private func laidOutPanel(
        _ panel: ExtensionPanel,
        width: CGFloat = 360
    ) -> (host: NSView, controller: ExtensionPanelViewController) {
        let router = FakeRouter()
        router.item = ExtensionPanelInventoryItem(
            extensionIdentifier: "com.example.checks",
            extensionName: "Checks",
            processGeneration: "generation-one",
            panel: panel
        )
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.checks",
            panelID: panel.id,
            title: panel.title,
            context: ExtensionCommandContext(),
            router: router
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return (host, controller)
    }

    func testPanelContentKeepsThePaneInsetOnBothSides() throws {
        let panel = ExtensionPanel(
            id: "checks",
            title: "Checks",
            root: .stack(
                axis: .vertical,
                spacing: .medium,
                children: [
                    .text("everlof/threading", role: .heading),
                    .status("Couldn't read checks", role: .warning),
                    .text(
                        "GitHub doesn't have this commit — it hasn't been pushed.",
                        role: .detail
                    )
                ]
            )
        )
        let (host, controller) = laidOutPanel(panel)

        let rendered = try XCTUnwrap(
            view(
                withIdentifierPrefix: "extension.panel.com.example.checks",
                under: controller.view
            ),
            "the rendered panel root went missing"
        )
        let frame = rendered.superview!.convert(rendered.frame, to: host)
        XCTAssertEqual(
            frame.minX, Design.Spacing.pane, accuracy: 0.5,
            "content lost its leading pane inset"
        )
        XCTAssertEqual(
            frame.maxX, host.bounds.width - Design.Spacing.pane, accuracy: 0.5,
            "content overflows the trailing pane inset"
        )
    }

    func testTheUnavailableStateKeepsTheSameInset() throws {
        let router = FakeRouter()
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.checks",
            panelID: "checks",
            title: "Checks",
            context: ExtensionCommandContext(),
            router: router
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let unavailable = try XCTUnwrap(
            view(withIdentifierPrefix: "extension.panel.unavailable", under: controller.view)
        )
        // A text field's frame carries AppKit's 2pt halo outside its alignment rect, and the
        // stack aligns by the rect — so measure the rect, which is where the ink is.
        let frame = unavailable.alignmentRect(
            forFrame: unavailable.superview!.convert(unavailable.frame, to: host)
        )
        XCTAssertEqual(frame.minX, Design.Spacing.pane, accuracy: 0.5)
        XCTAssertEqual(
            frame.maxX, host.bounds.width - Design.Spacing.pane, accuracy: 0.5
        )
    }

    func testExtensionSettingsMaterializeOnlyVisibleFieldsAndRetainTheirTargets() throws {
        let fields = (0..<ExtensionSettingsContribution.maximumFields).map(stressSettingField)
        let section = ExtensionSettingsRenderer.sectionModel(
            extensionIdentifier: "com.example.settings-virtual",
            extensionName: "Virtual Settings",
            sectionID: "virtual",
            title: "Virtual",
            fields: fields,
            prefixesTitleWithExtension: false
        )
        let list = ExtensionSettingsListView(
            baseSections: [],
            extensionSections: [section]
        )
        let window = performanceWindow(list, width: 620, height: 420)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(list.virtualRowCount, fields.count + 1)
        XCTAssertLessThan(list.materializedRowCount, list.virtualRowCount)
        let first = try XCTUnwrap(
            view(
                withIdentifierPrefix: "settings.extension.com.example.settings-virtual.field-0",
                under: list
            ) as? NSControl
        )
        XCTAssertNotNil(first.target, "a recycled control lost the row-owned action target")

        let table = try XCTUnwrap(firstTableView(in: list))
        let scroll = try XCTUnwrap(firstScrollView(in: list))
        let lastRow = table.numberOfRows - 1
        let lastFrame = table.rect(ofRow: lastRow)
        scroll.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(lastFrame.maxY - scroll.contentSize.height, 0)
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            view(
                withIdentifierPrefix: "settings.extension.com.example.settings-virtual.field-127",
                under: list
            ),
            "the final value row did not materialize at the bottom"
        )
        XCTAssertLessThan(list.materializedRowCount, list.virtualRowCount)
        withExtendedLifetime(window) {}
    }

    func testToolsHostKeepsExtensionFieldsAsIndividualVirtualRows() throws {
        let identifier = "com.example.tools-settings-virtual"
        let fields = (0..<ExtensionSettingsContribution.maximumFields).map(stressSettingField)
        let manifest = ExtensionManifest(
            identifier: identifier,
            name: "Tools Settings Virtual",
            version: "1.0.0",
            runtime: .native,
            executable: "bin/settings",
            capabilities: [.settings],
            settings: ExtensionSettingsContribution(sections: [
                .init(
                    id: "tools",
                    page: .tools,
                    title: "Virtual tools settings",
                    fields: fields
                )
            ])
        )
        try manifest.validate()
        _ = ExtensionManager.shared
        ExtensionSettingsRegistry.shared.replace(enabledManifests: [manifest])
        defer { ExtensionSettingsRegistry.shared.replace(enabledManifests: []) }

        let controller = ToolsPreferencesViewController(groups: [])
        let window = performanceWindow(controller.view, width: 620, height: 420)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(firstTableView(in: controller.view))
        let scroll = try XCTUnwrap(firstScrollView(in: controller.view))
        // Note + three fixed browser sections + caption + one row per contributed field.
        XCTAssertEqual(table.numberOfRows, fields.count + 5)
        XCTAssertLessThan(descendantCount(in: controller.view), fields.count * 4)

        let lastFrame = table.rect(ofRow: table.numberOfRows - 1)
        scroll.contentView.scroll(to: NSPoint(
            x: 0,
            y: max(lastFrame.maxY - scroll.contentSize.height, 0)
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()

        let finalControl = try XCTUnwrap(
            view(
                withIdentifierPrefix: "settings.extension.\(identifier).field-127",
                under: controller.view
            ) as? NSControl
        )
        XCTAssertNotNil(finalControl.target)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
        withExtendedLifetime(window) {}
    }

    // MARK: - Performance

    /// Maximum-contract panel trees are uncommon enough to miss in ordinary UI tests and large
    /// enough to turn a whole-tree semantic rebuild into a visible pause. This keeps initial
    /// rendering, Auto Layout, viewport drawing, and a process-generation replacement separate.
    func testStressExtensionPanelWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_EXTENSION_UI_STRESS"] == "1",
            "Set THREADING_EXTENSION_UI_STRESS=1 to run the extension panel sweep."
        )
        let nodeCount = environment["THREADING_EXTENSION_UI_STRESS_NODES"]
            .flatMap(Int.init)
            .map { min(max($0, 2), ExtensionPanel.nodeConstraints.maximumNodes) }
            ?? ExtensionPanel.nodeConstraints.maximumNodes
        let themeID = AppThemeID(
            environment["THREADING_EXTENSION_UI_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(AppThemeLibrary.theme(withID: themeID))
        _ = NSApplication.shared
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(theme)
        defer { AppThemeLibrary.apply(previousTheme) }

        let panel = stressPanel(childCount: nodeCount - 1, generation: 1)
        XCTAssertTrue(panel.validationIssues(path: "panel").isEmpty)
        let router = FakeRouter()
        router.item = stressInventory(panel: panel, generation: 1)
        let baselineMemory = Self.physicalFootprintBytes()

        let controllerStarted = DispatchTime.now().uptimeNanoseconds
        let controller = ExtensionPanelViewController(
            extensionIdentifier: "com.example.stress",
            panelID: panel.id,
            title: panel.title,
            context: ExtensionCommandContext(),
            router: router
        )
        let controllerEnded = DispatchTime.now().uptimeNanoseconds
        let page = controller.view
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page, width: 420, height: 700)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds
        let coldDescendants = descendantCount(in: page)

        router.item = stressInventory(
            panel: stressPanel(childCount: nodeCount - 1, generation: 2),
            generation: 2
        )
        let mutationStarted = DispatchTime.now().uptimeNanoseconds
        NotificationCenter.default.post(ExtensionsDidChange())
        let mutationRendered = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let mutationLaidOut = DispatchTime.now().uptimeNanoseconds

        let scroll = try XCTUnwrap(firstScrollView(in: page))
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        let draw = try scrollAndDraw(scroll, host: host, frames: 48)
        let renderedMemory = Self.physicalFootprintBytes()

        print(
            "THREADING_PERF extension-panel "
                + "theme=\(themeID.rawValue) nodes=\(nodeCount) "
                + "controller_ms=\(Self.milliseconds(controllerEnded - controllerStarted)) "
                + "render_ms=\(Self.milliseconds(renderEnded - controllerEnded)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "mutation_render_ms=\(Self.milliseconds(mutationRendered - mutationStarted)) "
                + "mutation_layout_ms=\(Self.milliseconds(mutationLaidOut - mutationRendered)) "
                + "document_height=\(Int(documentHeight)) descendants=\(coldDescendants) "
                + "scroll_ms=\(Self.milliseconds(draw.scroll / 48)) "
                + "scroll_layout_ms=\(Self.milliseconds(draw.layout / 48)) "
                + "draw_ms=\(Self.milliseconds(draw.draw / 48)) "
                + "footprint_mb=\(Self.megabytes(Self.positiveDifference(renderedMemory, baselineMemory)))"
        )

        XCTAssertGreaterThan(documentHeight, scroll.contentSize.height)
        XCTAssertGreaterThan(coldDescendants, nodeCount)
        withExtendedLifetime((window, router)) {}
    }

    /// A built-in Settings page can aggregate contributions from several extensions, even though
    /// one extension is capped at 128 fields. This reproduces that aggregate with the production
    /// settings renderer and measures the virtual page's cold mount and scrolling cost.
    func testStressExtensionSettingsWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_EXTENSION_SETTINGS_STRESS"] == "1",
            "Set THREADING_EXTENSION_SETTINGS_STRESS=1 to run the extension settings sweep."
        )
        let fieldCount = environment["THREADING_EXTENSION_SETTINGS_STRESS_FIELDS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? ExtensionSettingsContribution.maximumFields
        let themeID = AppThemeID(
            environment["THREADING_EXTENSION_UI_STRESS_THEME"] ?? "system"
        )
        let theme = try XCTUnwrap(AppThemeLibrary.theme(withID: themeID))
        _ = NSApplication.shared
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(theme)
        defer { AppThemeLibrary.apply(previousTheme) }

        let fields = (0..<fieldCount).map(stressSettingField)
        let baselineMemory = Self.physicalFootprintBytes()
        let renderStarted = DispatchTime.now().uptimeNanoseconds
        let sections = stride(
            from: 0,
            to: fieldCount,
            by: ExtensionSettingsContribution.maximumFields
        ).map { start -> ExtensionSettingsSectionModel in
            let end = min(start + ExtensionSettingsContribution.maximumFields, fieldCount)
            let extensionIndex = start / ExtensionSettingsContribution.maximumFields
            return ExtensionSettingsRenderer.sectionModel(
                extensionIdentifier: "com.example.settings\(extensionIndex)",
                extensionName: "Stress \(extensionIndex)",
                sectionID: "stress-\(extensionIndex)",
                title: "Extension \(extensionIndex)",
                fields: Array(fields[start..<end]),
                prefixesTitleWithExtension: true
            )
        }
        let list = ExtensionSettingsListView(
            baseSections: [],
            extensionSections: sections
        )
        let page = SettingsUI.listPage(
            title: "Extension stress",
            body: list,
            localizes: false
        )
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        let window = performanceWindow(page, width: 620, height: 700)
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let scroll = try XCTUnwrap(firstScrollView(in: page))
        let documentHeight = scroll.documentView?.bounds.height ?? 0
        let draw = try scrollAndDraw(scroll, host: host, frames: 48)
        let renderedMemory = Self.physicalFootprintBytes()
        let descendants = descendantCount(in: page)

        print(
            "THREADING_PERF extension-settings "
                + "theme=\(themeID.rawValue) extensions=\(sections.count) fields=\(fieldCount) "
                + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - renderEnded)) "
                + "document_height=\(Int(documentHeight)) descendants=\(descendants) "
                + "virtual_rows=\(list.virtualRowCount) "
                + "materialized_rows=\(list.materializedRowCount) "
                + "scroll_ms=\(Self.milliseconds(draw.scroll / 48)) "
                + "scroll_layout_ms=\(Self.milliseconds(draw.layout / 48)) "
                + "draw_ms=\(Self.milliseconds(draw.draw / 48)) "
                + "footprint_mb=\(Self.megabytes(Self.positiveDifference(renderedMemory, baselineMemory)))"
        )

        XCTAssertGreaterThan(documentHeight, scroll.contentSize.height)
        XCTAssertGreaterThan(list.virtualRowCount, list.materializedRowCount)
        withExtendedLifetime(window) {}
    }

    private func stressPanel(childCount: Int, generation: Int) -> ExtensionPanel {
        let options = (0..<3).map {
            ExtensionPickerOption(value: "option-\($0)", title: "Option \($0)")
        }
        let children = (0..<childCount).map { index -> ExtensionNode in
            switch index % 5 {
            case 0:
                return .text(
                    "Result \(generation)-\(index): a representative extension-provided line",
                    role: .body
                )
            case 1:
                return .status("Status \(generation)-\(index)", role: .neutral)
            case 2:
                return .button(
                    id: "action-\(index)",
                    title: "Run action \(index)",
                    role: .standard,
                    isEnabled: true
                )
            case 3:
                return .textInput(
                    id: "input-\(index)",
                    value: "Value \(generation)-\(index)",
                    placeholder: "Type a value",
                    accessibilityLabel: "Value \(index)",
                    role: .text,
                    isEnabled: true
                )
            default:
                return .picker(
                    id: "picker-\(index)",
                    selection: options.first?.value,
                    options: options,
                    accessibilityLabel: "Choice \(index)",
                    isEnabled: true
                )
            }
        }
        return ExtensionPanel(
            id: "stress",
            title: "Stress panel",
            root: .stack(axis: .vertical, spacing: .small, children: children)
        )
    }

    private func stressInventory(
        panel: ExtensionPanel,
        generation: Int
    ) -> ExtensionPanelInventoryItem {
        ExtensionPanelInventoryItem(
            extensionIdentifier: "com.example.stress",
            extensionName: "Stress",
            processGeneration: "generation-\(generation)",
            panel: panel
        )
    }

    private func stressSettingField(_ index: Int) -> ExtensionSettingField {
        let control: ExtensionSettingControl
        switch index % 4 {
        case 0:
            control = .toggle(defaultValue: index.isMultiple(of: 2))
        case 1:
            control = .text(
                defaultValue: "value-\(index)",
                placeholder: "Extension value",
                maximumLength: 256
            )
        case 2:
            control = .choice(
                defaultValue: "one",
                options: [
                    ExtensionSettingOption(id: "one", title: "One"),
                    ExtensionSettingOption(id: "two", title: "Two"),
                    ExtensionSettingOption(id: "three", title: "Three")
                ]
            )
        default:
            control = .integer(defaultValue: 10, minimum: 0, maximum: 100, step: 1)
        }
        return ExtensionSettingField(
            id: "field-\(index)",
            title: "Extension setting \(index)",
            description: "A representative setting supplied by an installed extension.",
            control: control
        )
    }

    private func performanceWindow(_ page: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    private func firstScrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        for child in root.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func firstTableView(in root: NSView) -> NSTableView? {
        if let table = root as? NSTableView { return table }
        for child in root.subviews {
            if let table = firstTableView(in: child) { return table }
        }
        return nil
    }

    private func descendantCount(in root: NSView) -> Int {
        1 + root.subviews.reduce(0) { $0 + descendantCount(in: $1) }
    }

    private func scrollAndDraw(
        _ scroll: NSScrollView,
        host: NSView,
        frames: UInt64
    ) throws -> (scroll: UInt64, layout: UInt64, draw: UInt64) {
        let document = try XCTUnwrap(scroll.documentView)
        let viewport = scroll.bounds
        let overflow = max(document.bounds.height - scroll.contentSize.height, 0)
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: viewport))
        var scrollNanoseconds: UInt64 = 0
        var layoutNanoseconds: UInt64 = 0
        var drawNanoseconds: UInt64 = 0
        for frame in 0..<frames {
            let fraction = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            let started = DispatchTime.now().uptimeNanoseconds
            scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
            let scrolled = DispatchTime.now().uptimeNanoseconds
            host.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            scroll.cacheDisplay(in: viewport, to: bitmap)
            let drawn = DispatchTime.now().uptimeNanoseconds
            scrollNanoseconds += scrolled - started
            layoutNanoseconds += laidOut - scrolled
            drawNanoseconds += drawn - laidOut
        }
        return (scrollNanoseconds, layoutNanoseconds, drawNanoseconds)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func positiveDifference(_ larger: UInt64, _ smaller: UInt64) -> UInt64 {
        larger >= smaller ? larger - smaller : 0
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private func view(withIdentifierPrefix prefix: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier().hasPrefix(prefix) { return root }
        for child in root.subviews {
            if let found = view(withIdentifierPrefix: prefix, under: child) { return found }
        }
        return nil
    }
}
