import AppKit
import XCTest
@testable import Threading

/// Draws the session Info panel from a fixture snapshot and writes each state out as an image —
/// System light and dark plus the two deliberately different stock themes, per the component
/// contract in `docs/THEME_BOUNDARY.md`.
///
/// It exists because the panel's defining fix is a *relationship* no assertion states: whether
/// the section headings, the notes, the row glyphs and the header path all stand on one ink
/// column. The panel once had four different leading edges, every one of them individually
/// "correct"; the misalignment was visible only in a picture.
///
/// The fixture reaches the controller through its `readSource` seam, so the poll re-applies the
/// fixture instead of racing it with the machine's real process table.
@MainActor
final class SessionInfoRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        static let themes: [(name: String, theme: AppTheme)] = [
            ("system", .system),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist)
        ]

        static let size = NSSize(width: 380, height: 420)
    }

    // MARK: - Stories

    func testRendersTheRunningPanelStorybook() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    panelImage(appearance: appearanceID, snapshot: Self.runningFixture, isRunning: true),
                    "Failed to render the info panel under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "info-panel-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered info panel storybook to \(directory.path)")
    }

    /// The two empty voices: a session with nothing running, and a running session listening
    /// on nothing — the note whose indentation once disagreed with everything above it.
    func testRendersTheEmptyStates() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (appearanceName, appearanceID) in Render.appearances {
            AppThemePalette.set(.system)

            let dormant = try XCTUnwrap(
                panelImage(appearance: appearanceID, snapshot: .empty, isRunning: false),
                "Failed to render the dormant panel in \(appearanceName)"
            )
            try dormant.write(
                to: directory.appendingPathComponent("info-dormant-\(appearanceName).png")
            )

            let quiet = try XCTUnwrap(
                panelImage(appearance: appearanceID, snapshot: Self.noPortsFixture, isRunning: true),
                "Failed to render the no-ports panel in \(appearanceName)"
            )
            try quiet.write(
                to: directory.appendingPathComponent("info-no-ports-\(appearanceName).png")
            )
            written += 2
        }

        XCTAssertEqual(written, Render.appearances.count * 2)
        print("Rendered info panel empty states to \(directory.path)")
    }

    // MARK: - Fixtures

    /// Both origins, nested depths, a stopped process, a reachable port and an unreachable one —
    /// every visual voice the panel has, in one picture.
    private static var runningFixture: SessionInfoSnapshot {
        SessionInfoSnapshot(
            processGroups: [
                SessionProcessGroup(origin: .agent, processes: [
                    SessionProcess(
                        pid: 50283,
                        command: "claude",
                        memoryBytes: 248 * 1024 * 1024,
                        cpuPercent: 12,
                        depth: 0,
                        executablePath: "/Users/me/.local/share/claude/versions/2.1.218",
                        arguments: ["claude", "--continue"]
                    ),
                    SessionProcess(
                        pid: 50301,
                        command: "node",
                        memoryBytes: 96 * 1024 * 1024,
                        cpuPercent: 3,
                        depth: 1,
                        arguments: ["node", "server.js", "--port", "3000"]
                    ),
                    SessionProcess(
                        pid: 50425,
                        command: "esbuild",
                        memoryBytes: 6 * 1024 * 1024,
                        cpuPercent: nil,
                        depth: 2,
                        arguments: ["esbuild", "--watch"]
                    )
                ]),
                SessionProcessGroup(origin: .shell, processes: [
                    SessionProcess(
                        pid: 60110,
                        command: "zsh",
                        memoryBytes: 4 * 1024 * 1024,
                        cpuPercent: 0,
                        depth: 0,
                        arguments: ["-zsh"]
                    ),
                    SessionProcess(
                        pid: 60244,
                        command: "python",
                        memoryBytes: 30 * 1024 * 1024,
                        cpuPercent: 0,
                        depth: 1,
                        state: .stopped,
                        arguments: ["python", "manage.py", "runserver"]
                    )
                ])
            ],
            portGroups: [
                SessionPortGroup(origin: .agent, ports: [
                    ListeningPort(port: 3000, pid: 50301, command: "node", address: "0.0.0.0", isIPv6: false),
                    ListeningPort(port: 5000, pid: 50301, command: "node", address: "192.168.1.20", isIPv6: false)
                ])
            ]
        )
    }

    private static var noPortsFixture: SessionInfoSnapshot {
        SessionInfoSnapshot(
            processGroups: [
                SessionProcessGroup(origin: .agent, processes: [
                    SessionProcess(
                        pid: 50283,
                        command: "claude",
                        memoryBytes: 200 * 1024 * 1024,
                        cpuPercent: 1,
                        depth: 0,
                        arguments: ["claude"]
                    )
                ])
            ],
            portGroups: []
        )
    }

    // MARK: - Helpers

    private func panelImage(
        appearance name: NSAppearance.Name,
        snapshot: SessionInfoSnapshot,
        isRunning: Bool
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let controller = SessionInfoViewController(
                sessionID: SessionID(),
                folderPath: "/Users/me/repo/example"
            )
            // Installed before the view exists, so even `viewDidLoad`'s own refresh reads the
            // fixture rather than walking the machine.
            controller.readSource = { completion in completion(snapshot) }

            let host = ThemedSurfaceView()
            host.frame = NSRect(origin: .zero, size: Render.size)
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance

            let view = controller.view
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)

            controller.apply(snapshot, isRunning: isRunning)

            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }
}
