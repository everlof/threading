import AppKit
import XCTest
@testable import Threading

/// The Storage page is fed by project and checkout discovery, neither of which has a product
/// cap. These tests keep that provider boundary explicit: the complete inventory is cheap value
/// state and only the rows intersecting the AppKit viewport own controls.
final class StoragePreferencesVirtualizationTests: XCTestCase {

    private enum Render {
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 1400

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    @MainActor
    func testUnboundedCheckoutGroupsMaterializeOnlyTheViewport() throws {
        let groups = fixtureGroups(count: 120)
        let controller = fixtureController(groups: groups)
        let host = laidOut(controller.view, width: 440, height: 700)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(firstScrollView(in: controller.view))
        controller.scrollGroupToVisibleForTesting(groups[93].identity)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.virtualRowCountForTesting, groups.count + 2)
        XCTAssertGreaterThan(controller.materializedRowCountForTesting, 0)
        XCTAssertLessThan(
            controller.materializedRowCountForTesting,
            controller.virtualRowCountForTesting / 2,
            "the collapsed Storage page retained every checkout card"
        )

        let originBeforeRefresh = scroll.contentView.bounds.origin
        NotificationCenter.default.post(ArtifactScanDidChange())
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.x, originBeforeRefresh.x, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, originBeforeRefresh.y, accuracy: 0.5)

        let rowsBeforeExpansion = controller.virtualRowCountForTesting
        controller.setGroupExpandedForTesting(groups[93].identity, expanded: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.virtualRowCountForTesting, rowsBeforeExpansion)
        XCTAssertLessThan(
            controller.materializedRowCountForTesting,
            controller.virtualRowCountForTesting / 2,
            "opening one checkout materialized offscreen neighbours"
        )
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    /// The old control tag packed `(group, artifact)` with a stride of 10,000. Artifact 10,000
    /// in one checkout therefore meant artifact zero in the next checkout when clicked. A
    /// materialized row now retains the exact values it offers to remove, independent of any
    /// provider-sized coordinate.
    @MainActor
    func testRemovalActionCarriesExactArtifactBeyondFormerTagStride() throws {
        let project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/Users/dev/repo/Threading")
        )
        let checkout = "/Users/dev/worktrees/large-checkout"
        let artifacts = (0...10_000).map { index in
            artifact(
                checkout,
                name: "artifact-\(index)",
                kind: .rust,
                bytes: 1_100_000_000
            )
        }
        let group = ReclaimableFindings.Group(
            attribution: .checkout(project),
            title: "Threading · large-checkout",
            subtitle: "~/worktrees/large-checkout",
            identity: checkout,
            artifacts: artifacts
        )
        let controller = fixtureController(groups: [group])
        let host = laidOut(controller.view, width: 440, height: 320)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        controller.setGroupExpandedForTesting(group.identity, expanded: true)
        let expected = try XCTUnwrap(artifacts.last)
        controller.scrollArtifactToVisibleForTesting(expected.id)
        host.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(
            descendants(of: controller.view, type: ThemedButton.self)
                .compactMap { $0.target as? StorageRemovalActionTarget }
                .first { $0.artifactIDs == [expected.id] }
        )
        XCTAssertEqual(target.artifactIDs, [expected.id])
        XCTAssertEqual(target.groupIdentities, [group.identity])
    }

    /// The complete production controller, not a transcription of its cards. Regular and
    /// constrained widths cover the fixed header, virtual card painting, artifact controls and
    /// the smaller-directory fold under both system appearances.
    @MainActor
    func testRendersStorageSettingsToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        var written: [String] = []
        for width in Render.widths {
            for (name, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    let groups = fixtureGroups(count: 4)
                    let controller = fixtureController(groups: groups)
                    _ = controller.view
                    controller.setGroupExpandedForTesting(groups[0].identity, expanded: true)
                    controller.setGroupExpandedForTesting(groups[1].identity, expanded: true)

                    let host = laidOut(
                        controller.view,
                        width: width,
                        height: Render.height
                    )
                    host.appearance = appearance
                    controller.view.appearance = appearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    data = png(of: host)
                    XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
                }
                let filename = "storage-settings-\(Int(width))-\(name).png"
                try XCTUnwrap(data, "Failed to render \(filename)").write(
                    to: directory.appendingPathComponent(filename)
                )
                written.append(filename)
            }
        }

        print("Rendered \(written.count) Storage settings pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    @MainActor
    private func fixtureController(
        groups: [StoragePreferencesViewController.FindingsGroup]
    ) -> StoragePreferencesViewController {
        StoragePreferencesViewController(
            groupsProvider: { groups },
            scanningProvider: { false },
            refreshStaleProjects: {},
            extensionSectionsProvider: { [] },
            summaryProvider: {
                "38.1 GB reclaimable in 12 directories · measured 12 min ago · only 31 GB free"
            }
        )
    }

    @MainActor
    private func fixtureGroups(
        count: Int
    ) -> [StoragePreferencesViewController.FindingsGroup] {
        let project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: "/Users/dev/repo/Threading")
        )
        return (0..<count).map { index in
            let checkout = "/Users/dev/worktrees/threading-checkout-\(index)"
            return ReclaimableFindings.Group(
                attribution: .checkout(project),
                title: "Threading · checkout-\(index)",
                subtitle: "~/worktrees/threading-checkout-\(index)",
                identity: checkout,
                artifacts: [
                    artifact(checkout, name: "target", kind: .rust, bytes: 3_140_000_000),
                    artifact(checkout, name: "node_modules", kind: .node, bytes: 1_820_000_000),
                    artifact(checkout, name: "__pycache__", kind: .pythonCache, bytes: 84_000_000)
                ]
            )
        }
    }

    private func artifact(
        _ checkout: String,
        name: String,
        kind: ArtifactKind,
        bytes: Int64
    ) -> ReclaimableArtifact {
        ReclaimableArtifact(
            url: URL(fileURLWithPath: checkout).appendingPathComponent(name),
            kind: kind,
            byteCount: bytes,
            modifiedAt: nil,
            checkoutPath: checkout
        )
    }

    @MainActor
    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        // Settings pages are intentionally transparent: the shipping pane paints the chrome
        // ground behind them. Give the isolated capture that same owner, otherwise every
        // translucent panel role is recorded against alpha zero and the evidence cannot prove
        // its text or contrast.
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func firstScrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView { return scroll }
        return root.subviews.lazy.compactMap(firstScrollView).first
    }

    @MainActor
    private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: child, type: type))
        }
        return matches
    }

    @MainActor
    private func png(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
