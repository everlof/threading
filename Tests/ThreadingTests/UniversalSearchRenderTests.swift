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
            .group(id: "files", title: "Files"),
            .result(UniversalSearchResultRow(
                id: SearchHitID(rawValue: "file"),
                title: "CallbackHandler.swift:84",
                detail: "Threading › Sources/Auth/CallbackHandler.swift › guard authState == expected"
            )),
            .message(id: "cap", text: "More matches are available — refine the query."),
        ],
        selectedHitID: SearchHitID(rawValue: "session"),
        status: "Some conversation history is still indexing.",
        queryError: nil
    )
}
