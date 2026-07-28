import AppKit
import XCTest
@testable import Skalman

/// Draws a sidebar session row in each of its trailing-slot states and writes them out, both
/// appearances — the same fixture-to-PNG idea as the other render tests.
///
/// The trailing slot is the one part of the row that cannot be reviewed any other way. Its
/// contents swap under the pointer, so a screenshot of the running app would need the pointer
/// driven onto a row; and whether the `⋯` and the archive button read as a *pair* at the row's
/// edge — rather than as two icons that happen to be adjacent, or as a cluster crowding the
/// title — is exactly the kind of question no assertion answers.
@MainActor
final class SidebarRowRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }
    }

    private enum Fixture {
        static let width: CGFloat = 240
        static let height: CGFloat = 28
    }

    // MARK: - Stories

    func testRendersTheStorybook() throws {
        var written = 0

        // At rest: the status dot alone, at the row's trailing edge. The dot's position here
        // is the one to compare against the hovered stories — it must not have moved.
        written += try write(story: "01-idle-at-rest", activity: .idle, hovered: false)

        // Working, at rest: the spinner occupies the same place the dot does.
        written += try write(story: "02-working-at-rest", activity: .working, hovered: false)

        // Hovered: the `⋯` and the archive button, the archive outboard at the row's edge.
        written += try write(story: "03-hovered", activity: .idle, hovered: true)

        // Hovered while working — the state a user is most often in when reaching for either
        // button, and the one where the pair replaces a spinner rather than a static dot.
        written += try write(story: "04-hovered-while-working", activity: .working, hovered: true)

        // A title long enough to be truncated, so the gap the widened slot takes from the
        // text is visible rather than inferred.
        written += try write(
            story: "05-hovered-long-title",
            activity: .idle,
            hovered: true,
            title: "Refactor the sidebar trailing slot and its hover controls"
        )

        XCTAssertEqual(written, 10, "Every story should render in both appearances")
        print("Rendered sidebar-row storybook to \(Render.directory.path)")
    }

    // MARK: - Harness

    /// The row reads nothing off the event — `mouseEntered` only records the hover and starts
    /// the crossfade — so a synthesized one is enough to reach the hovered state without a
    /// pointer, and without test-only API on the row itself.
    private static func enterEvent() -> NSEvent? {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }

    private func write(
        story: String,
        activity: SessionActivity,
        hovered: Bool,
        title: String = "Fix the hover state"
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)

            var data: Data?
            let render = {
                let row = SessionRowView(customizationLookup: { _ in .empty })
                row.translatesAutoresizingMaskIntoConstraints = false

                let host = NSView(
                    frame: NSRect(x: 0, y: 0, width: Fixture.width, height: Fixture.height)
                )
                host.appearance = appearance
                host.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    row.topAnchor.constraint(equalTo: host.topAnchor),
                    row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])

                // Configured before the hover is asserted, then again after: `configure`
                // reapplies the hover state without animating, which is what makes the
                // hovered stories deterministic rather than a race with the crossfade.
                let session = AgentSession(kind: .claude, title: title)
                row.configure(with: session, activity: activity)
                if hovered, let entered = Self.enterEvent() {
                    row.mouseEntered(with: entered)
                    row.configure(with: session, activity: activity)
                }

                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.background.cgColor

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(
                to: directory.appendingPathComponent("sidebar-row-\(story)-\(name).png")
            )
            written += 1
        }
        return written
    }
}
