import AppKit
import XCTest
@testable import Threading

/// Settings ▸ Workrooms, drawn light and dark at the pane's two widths, plus the rows its search
/// entries promise. The page is the only owner surface for people outside this Mac, so what it
/// must never lose is the switch, the public address and the way to close everything.
final class WorkroomsSettingsRenderTests: XCTestCase {

    private static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
    private static let height: CGFloat = 1400

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    @MainActor
    func testThePageCarriesTheSwitchTheAddressAndCloseAll() {
        let controller = WorkroomsPreferencesViewController()
        let host = laidOut(controller.view, width: SettingsUIDefaults.pageWidth)
        let labels = Self.labels(in: host)
        for title in ["Ask people outside this Mac", "Tunnel", "Reserved domain", "Add a person"] {
            XCTAssertTrue(labels.contains(L10n.string(title)), title)
        }
        XCTAssertTrue(Self.buttons(in: host).contains(L10n.string("Close All Workrooms")))
    }

    @MainActor
    func testRendersWorkroomsSettingsToImages() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var written = 0
        for width in Self.widths {
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = NSAppearance(named: appearanceName)
                var data: Data?
                appearance?.performAsCurrentDrawingAppearance {
                    let controller = WorkroomsPreferencesViewController()
                    let host = self.laidOut(controller.view, width: width)
                    host.appearance = appearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    data = Self.png(of: host)
                }
                let url = Self.directory.appendingPathComponent("workrooms-\(Int(width))-\(name).png")
                try XCTUnwrap(data, "the Workrooms page rendered nothing at \(width)pt \(name)").write(to: url)
                written += 1
            }
        }
        XCTAssertEqual(written, Self.widths.count * 2)
    }

    // MARK: - Helpers

    @MainActor
    private func laidOut(_ view: NSView, width: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: Self.height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "the page widened its pane")
        return host
    }

    @MainActor
    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews { found.formUnion(labels(in: subview)) }
        return found
    }

    @MainActor
    private static func buttons(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let button = view as? ThemedButton { found.insert(button.title) }
        for subview in view.subviews { found.formUnion(buttons(in: subview)) }
        return found
    }

    @MainActor
    private static func png(of host: NSView) -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
