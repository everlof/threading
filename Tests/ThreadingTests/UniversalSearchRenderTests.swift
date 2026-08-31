import AppKit
import XCTest

@testable import Threading

/// Universal Search in the same native window shell and overlay installer used at runtime. The
/// fixture keeps scope, grouping, literal emphasis, provenance, selection and incomplete coverage
/// visible together so a screenshot cannot approve only an isolated row.
@MainActor
final class UniversalSearchRenderTests: XCTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty
            {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let size = NSSize(width: 900, height: 650)
    }

    private struct Variant {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersGroupedScopedResultsInTheShippingOverlay() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        defer { AppThemePalette.set(.system) }

        let variants = [
            Variant(name: "system-light", theme: .system, appearance: .aqua),
            Variant(name: "system-dark", theme: .system, appearance: .darkAqua),
            Variant(name: "cyberpunk", theme: AppThemeStyles.cyberpunk, appearance: .darkAqua),
            Variant(name: "swiss", theme: AppThemeStyles.swissMinimalist, appearance: .aqua),
        ]
        for variant in variants {
            AppThemePalette.set(variant.theme)
            let data = try XCTUnwrap(image(appearance: variant.appearance))
            try data.write(to: Render.directory.appendingPathComponent(
                "universal-search-results-\(variant.name).png"
            ))
        }
    }

    private func image(appearance name: NSAppearance.Name) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let window = TitlebarActionWindow(
                contentRect: NSRect(origin: .zero, size: Render.size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = appearance
            installShell(in: window)

            let controller = UniversalSearchOverlayViewController()
            let presentation = InWindowOverlay.install(controller.view, in: window, onDismiss: {})
            controller.apply(Self.presentation)
            guard let root = window.contentView else { return }
            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            // Hold the pointer state on the result immediately below the selected one. This is
            // the adjacency that regressed: selection belonged to the table row while hover was
            // a full-height cell fill, so the two plates met and read as overlapping.
            if let table = firstTable(in: controller.view),
               let hovered = table.view(atColumn: 0, row: 4, makeIfNecessary: true)
                    as? SearchResultRowView
            {
                hovered.mouseEntered(with: NSEvent())
            }
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
            root.cacheDisplay(in: root.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
            presentation?.remove()
        }
        return data
    }

    private func installShell(in window: NSWindow) {
        guard let bounds = window.contentView?.bounds else { return }
        let root = NSView(frame: bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let sidebar = SidebarBackdropView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let workspace = ThemedSurfaceView()
        workspace.translatesAutoresizingMaskIntoConstraints = false
        workspace.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        root.addSubview(sidebar)
        root.addSubview(workspace)

        let sidebarHeader = PaneHeaderView(leading: [SidebarBrandView()])
        sidebar.addSubview(sidebarHeader)
        let title = NSTextField(labelWithString: "Fix auth callback")
        title.applyFont(.heading)
        title.textColor = Design.Text.label
        let paneHeader = PaneHeaderView(leading: [title])
        workspace.addSubview(paneHeader)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspace.topAnchor.constraint(equalTo: root.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarHeader.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            paneHeader.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            paneHeader.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            paneHeader.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// Height and interaction chrome each have one owner. The table asks the result component
    /// for its live two-line measure, and a result hosted in a table asks the row for the same
    /// plate selection already uses. This fixture keeps two results adjacent because a group
    /// header between them would hide the collision this contract prevents.
    func testAdjacentResultsUseOneRhythmAndDisjointRowOwnedPlates() throws {
        defer { AppThemePalette.set(.system) }
        AppThemePalette.set(AppThemeStyles.cyberpunk)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Render.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(origin: .zero, size: Render.size))
        window.contentView = root

        let controller = UniversalSearchOverlayViewController()
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.addSubview(controller.view)
        controller.apply(Self.presentation)
        root.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(firstTable(in: controller.view))
        let resultRows = [1, 3, 4, 6]
        for row in resultRows {
            XCTAssertEqual(
                table.rect(ofRow: row).height,
                SearchResultRowView.preferredTableRowHeight,
                accuracy: 0.01,
                "result row \(row) restated the component's height"
            )
        }

        let selectedRow = try XCTUnwrap(
            table.rowView(atRow: 3, makeIfNecessary: true) as? ThemedTableRowView
        )
        let hoveredRow = try XCTUnwrap(
            table.rowView(atRow: 4, makeIfNecessary: true) as? ThemedTableRowView
        )
        let hoveredCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 4, makeIfNecessary: true) as? SearchResultRowView
        )
        hoveredCell.mouseEntered(with: NSEvent())

        XCTAssertTrue(selectedRow.isSelected)
        XCTAssertTrue(hoveredRow.interactionHighlightIsActiveForTesting)
        XCTAssertFalse(
            hoveredCell.drawsOwnInteractionPlateForTesting,
            "a table cell rebuilt the row's interaction plate inside itself"
        )

        let selection = selectedRow.convert(selectedRow.plateRectForTesting, to: table)
        let hover = hoveredRow.convert(hoveredRow.plateRectForTesting, to: table)
        XCTAssertEqual(selection.minX, hover.minX, accuracy: 0.01)
        XCTAssertEqual(selection.maxX, hover.maxX, accuracy: 0.01)
        XCTAssertFalse(
            selection.intersects(hover),
            "adjacent selection and hover plates overlap: \(selection), \(hover)"
        )
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }

    private static let presentation = UniversalSearchOverlayState(
        query: "auth",
        scopes: [
            UniversalSearchScopeOption(id: "view", title: "View"),
            UniversalSearchScopeOption(id: "project", title: "Project"),
            UniversalSearchScopeOption(id: "everywhere", title: "Everywhere"),
        ],
        selectedScopeID: "project",
        rows: [
            .group(id: "destinations", title: "Destinations"),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "session"),
                title: "Fix auth callback",
                detail: "Threading › Codex › auth"
            )),
            .group(id: "conversations", title: "Conversations"),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "conversation"),
                title: "OAuth redirect investigation",
                detail: "Threading › Claude › The auth callback now rejects mismatched state."
            )),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "conversation-related"),
                title: "Refresh token follow-up",
                detail: "Threading › Codex › Verify auth callback state after refresh."
            )),
            .group(id: "files", title: "Files"),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "file"),
                title: "CallbackHandler.swift:84",
                detail: "Threading › Sources/Auth/CallbackHandler.swift › guard authState == expected"
            )),
            .message(id: "cap", text: "More matches are available — refine the query."),
        ],
        selectedHitID: SearchHitID(rawValue: "conversation"),
        status: "Some conversation history is still indexing.",
        queryError: nil
    )
}
