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

    // MARK: - Escape

    /// **Escape belongs to the surface, not to whichever child is holding the caret.**
    ///
    /// Search bound the key on the query field's `control(_:textView:doCommandBy:)` seam and
    /// nowhere else, so it closed the palette from the one responder the palette had placed and
    /// from none of the others: click a result and the table has the keyboard, tab to the scope
    /// run and a segment does, and Escape then travelled a responder chain in which nothing had
    /// heard of the surface covering the window. Delivered here the way a window delivers a
    /// plain Escape — `cancelOperation(_:)` from the responder that actually holds focus — which
    /// is the route `CompareInspectorView` shipped without and had to be given.
    @MainActor
    func testEscapeClosesSearchFromEveryPlaceInsideItTheKeyboardCanBe() throws {
        let places: [(String, (NSView) throws -> NSResponder)] = [
            ("the results list", { try XCTUnwrap(self.firstTable(in: $0)) }),
            ("a scope segment", {
                let run = try XCTUnwrap(self.descendants(of: $0, type: ThemedSegmentedControl.self).first)
                return try XCTUnwrap(run.segment(at: 0))
            }),
            ("the close button", {
                try XCTUnwrap(self.descendants(of: $0, type: ThemedButton.self).first {
                    $0.accessibilityLabel() == "Close Search"
                })
            }),
            ("the surface itself", { $0 }),
        ]

        for (place, responder) in places {
            var dismissals = 0
            let controller = UniversalSearchOverlayViewController()
            controller.onDismiss = { dismissals += 1 }
            controller.apply(Self.presentation)
            let host = Self.host(controller)
            host.layoutSubtreeIfNeeded()

            try responder(controller.view)
                .doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertEqual(
                dismissals, 1,
                "Escape from \(place) did not close Search"
            )
        }
    }

    // MARK: - The Header

    /// The reported picture: a 32pt query beside a 26pt scope run and a 26pt ✕, each floating
    /// three points clear of the other two.
    @MainActor
    func testTheQueryTheScopeRunAndTheCloseStandAtOneHeight() throws {
        let controller = UniversalSearchOverlayViewController()
        controller.apply(Self.presentation)
        let host = Self.host(controller)
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(descendants(of: controller.view, type: ThemedSearchField.self).first)
        let scope = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedSegmentedControl.self).first
        )
        let close = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedButton.self).first {
                $0.accessibilityLabel() == "Close Search"
            }
        )

        for member in [field, scope, close] as [NSView] {
            XCTAssertEqual(
                member.frame.height, Design.Size.fieldHeight, accuracy: 0.5,
                "\(type(of: member)) stood at \(member.frame.height) in a "
                    + "\(Design.Size.fieldHeight)pt row"
            )
        }
        for member in [scope, close] as [NSView] {
            XCTAssertEqual(
                member.convert(member.bounds, to: nil).midY,
                field.convert(field.bounds, to: nil).midY,
                accuracy: 0.5,
                "\(type(of: member)) is off the query's centreline"
            )
        }
    }

    /// The query is the row; the controls beside it are what it is narrowed by. Held at its
    /// placeholder's width it left a hole between the words and the scope run.
    @MainActor
    func testTheQueryTakesTheHeadersSpareWidth() throws {
        let controller = UniversalSearchOverlayViewController()
        controller.apply(Self.presentation)
        let host = Self.host(controller)
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(descendants(of: controller.view, type: ThemedSearchField.self).first)
        let scope = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedSegmentedControl.self).first
        )
        let gap = scope.convert(scope.bounds, to: nil).minX - field.convert(field.bounds, to: nil).maxX

        XCTAssertGreaterThan(field.frame.width, scope.frame.width)
        XCTAssertLessThanOrEqual(
            gap, Design.Spacing.large,
            "the header left \(gap)pt of air between the query and the scope run"
        )
    }

    // MARK: - The List

    /// A palette is the size of its answer. The list was a fixed 470 points with a required 160
    /// under it, so three matches drew a hundred and eighty points of empty panel below them —
    /// the largest single thing in the picture this was reported from.
    @MainActor
    func testTheListIsTheSizeOfItsAnswerAndStopsGrowingWhereItScrolls() throws {
        let short = UniversalSearchOverlayViewController()
        short.apply(Self.oneResult)
        let shortHost = Self.host(short)
        shortHost.layoutSubtreeIfNeeded()
        let shortList = try XCTUnwrap(firstTable(in: short.view)?.enclosingScrollView)

        let long = UniversalSearchOverlayViewController()
        long.apply(Self.manyResults)
        let longHost = Self.host(long)
        longHost.layoutSubtreeIfNeeded()
        let longList = try XCTUnwrap(firstTable(in: long.view)?.enclosingScrollView)

        XCTAssertLessThan(
            shortList.frame.height, longList.frame.height / 2,
            "a two-row answer took the same panel as a full one"
        )
        XCTAssertGreaterThanOrEqual(
            shortList.frame.height,
            SearchResultRowView.preferredTableRowHeight,
            "the list is shorter than the single result it is showing"
        )
        XCTAssertLessThanOrEqual(
            longList.frame.height, Render.size.height,
            "a long answer grew the panel past the window instead of scrolling"
        )
        XCTAssertGreaterThan(
            longList.frame.height, shortList.frame.height,
            "the list did not grow with its content at all"
        )
    }

    // MARK: - Helpers

    /// The surface in a window it can lay out in, parked where nothing draws on screen.
    @MainActor
    private static func host(_ controller: UniversalSearchOverlayViewController) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Render.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(origin: .zero, size: Render.size))
        window.contentView = root
        controller.view.frame = root.bounds
        controller.view.autoresizingMask = [.width, .height]
        root.addSubview(controller.view)
        return root
    }

    @MainActor
    private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var found: [T] = []
        for view in root.subviews {
            if let match = view as? T { found.append(match) }
            found += descendants(of: view, type: type)
        }
        return found
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }

    private static let oneResult = UniversalSearchOverlayState(
        query: "auth",
        scopes: presentation.scopes,
        selectedScopeID: "project",
        rows: [
            .group(id: "destinations", title: "Destinations"),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "session"),
                title: "Fix auth callback",
                detail: "Threading › Codex › auth"
            )),
        ],
        selectedHitID: nil,
        status: nil,
        queryError: nil
    )

    private static let manyResults = UniversalSearchOverlayState(
        query: "auth",
        scopes: presentation.scopes,
        selectedScopeID: "project",
        rows: [.group(id: "destinations", title: "Destinations")]
            + (0 ..< 40).map { index in
                .result(UniversalSearchResultRow(
                    id: SearchHitID(rawValue: "session-\(index)"),
                    title: "Fix auth callback \(index)",
                    detail: "Threading › Codex › auth"
                ))
            },
        selectedHitID: nil,
        status: nil,
        queryError: nil
    )

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
