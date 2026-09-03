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
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
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

        static let size = NSSize(width: 420, height: 820)
        static let narrowSize = NSSize(width: 312, height: 760)
        static let multilineCommandSize = NSSize(width: 477, height: 559)
        static let unfoldedSize = NSSize(width: 420, height: 940)
    }

    /// The fixture paths live under the real home so the picture shows them folded to `~`,
    /// which is how every path on a person's own machine will actually read.
    private static let home = NSHomeDirectory()

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

        AppThemePalette.set(.system)
        let narrow = try XCTUnwrap(
            panelImage(
                appearance: .darkAqua,
                snapshot: Self.runningFixture,
                isRunning: true,
                size: Render.narrowSize
            ),
            "Failed to render the info panel at its narrow shipping width"
        )
        try narrow.write(
            to: directory.appendingPathComponent("info-panel-system-dark-narrow.png")
        )
        written += 1

        let multilineCommand = try XCTUnwrap(
            panelImage(
                appearance: .darkAqua,
                snapshot: Self.multilineCommandFixture,
                isRunning: true,
                size: Render.multilineCommandSize,
                usageSnapshot: Self.multilineCommandUsageFixture
            ),
            "Failed to render the live multiline-command regression"
        )
        try multilineCommand.write(
            to: directory.appendingPathComponent("info-panel-system-dark-multiline-command.png")
        )
        written += 1

        // The agent's row unfolded: the launch command one flag per line, with when it started
        // and where it runs, under the compact band that still carries the reading.
        for (appearanceName, appearanceID) in Render.appearances {
            let unfolded = try XCTUnwrap(
                panelImage(
                    appearance: appearanceID,
                    snapshot: Self.runningFixture,
                    isRunning: true,
                    size: Render.unfoldedSize,
                    unfoldedProcessIDs: [50283, 60244]
                ),
                "Failed to render the unfolded process rows in \(appearanceName)"
            )
            try unfolded.write(
                to: directory.appendingPathComponent("info-panel-system-\(appearanceName)-unfolded.png")
            )
            written += 1
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count + 4)
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

    /// Both origins, nested depths, a paragraph-long agent command, a stopped process, a
    /// reachable port and an unreachable one — every visual voice the panel has, in one picture.
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
                        startTime: ProcessStartTime(
                            seconds: UInt64(Date().timeIntervalSince1970) - 11 * 60,
                            microseconds: 0
                        ),
                        executablePath: "\(home)/.local/share/claude/versions/2.1.218/claude",
                        arguments: [
                            "claude",
                            "--model", "opus",
                            "--effort", "xhigh",
                            "--settings",
                            "\(home)/Library/Application Support/Threading/settings/2AC51650-8C1E-4F0B-9E2B-7A1D3C5E9F00.json",
                            "We can still have terminals too, so keep the full launch context available."
                        ],
                        workingDirectory: "\(home)/repo/example"
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
                        startTime: ProcessStartTime(
                            seconds: UInt64(Date().timeIntervalSince1970) - 3 * 60,
                            microseconds: 0
                        ),
                        arguments: ["python", "manage.py", "runserver", "--settings=app.settings.dev"],
                        workingDirectory: "\(home)/repo/example/backend"
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

    /// Mirrors the live failure report: the first two processes are Codex launchers whose argv
    /// includes a paragraph-bearing startup prompt. The embedded line breaks — not merely a
    /// long command — are what made AppKit paint their detail lines above "Processes".
    private static var multilineCommandFixture: SessionInfoSnapshot {
        SessionInfoSnapshot(
            processGroups: [
                SessionProcessGroup(origin: .agent, processes: [
                    SessionProcess(
                        pid: 57_385,
                        command: "node",
                        memoryBytes: 16_400_000,
                        cpuPercent: 0,
                        depth: 0,
                        arguments: [
                            "\(home)/.npm-global/bin/codex",
                            "--config",
                            "check_for_update_on_startup=false",
                            "Investigate the session info panel.\n\nKeep the process tree readable."
                        ]
                    ),
                    SessionProcess(
                        pid: 57_366,
                        command: "codex",
                        memoryBytes: 279_800_000,
                        cpuPercent: 4,
                        depth: 1,
                        arguments: [
                            "\(home)/.npm-global/bin/codex",
                            "--config",
                            "check_for_update_on_startup=false",
                            "First paragraph of the opening request.\nSecond paragraph of the opening request."
                        ]
                    ),
                    SessionProcess(
                        pid: 15_182,
                        command: "bash",
                        memoryBytes: 2_000_000,
                        cpuPercent: 0,
                        depth: 1,
                        arguments: ["bash", "scripts/test.sh", "all"]
                    ),
                    SessionProcess(
                        pid: 15_197,
                        command: "xcodebuild",
                        memoryBytes: 166_200_000,
                        cpuPercent: 9,
                        depth: 2,
                        arguments: ["xcodebuild", "-project", "/Users/me/repo/AnotherTerminal/Threading.xcodeproj"]
                    )
                ])
            ],
            portGroups: []
        )
    }

    private static var usageFixture: SessionUsageSnapshot {
        let total = SessionUsageSnapshot.Reading(
            tokens: .init(
                uncachedInput: 72_000,
                cachedInput: 96_000,
                cacheWrite: 4_000,
                output: 12_000,
                reasoning: 5_000
            ),
            unindexedTokens: 2_000,
            cost: .init(catalogPricedUSD: 1.42, cacheSavingsUSD: 0.86),
            records: 8,
            models: [
                .init(
                    name: "claude-opus-4-6",
                    tokens: .init(uncachedInput: 72_000, cachedInput: 51_000, output: 9_000),
                    cost: .init(catalogPricedUSD: 1.12),
                    records: 5
                ),
                .init(
                    name: "claude-sonnet-4-6",
                    tokens: .init(cachedInput: 45_000, cacheWrite: 4_000, output: 3_000),
                    cost: .init(catalogPricedUSD: 0.30),
                    records: 3
                )
            ]
        )
        return SessionUsageSnapshot(
            sessionID: SessionID(),
            total: total,
            main: .init(
                tokens: .init(uncachedInput: 55_000, cachedInput: 54_000, output: 8_000),
                cost: .init(catalogPricedUSD: 1.04),
                records: 5
            ),
            subagents: .init(
                tokens: .init(uncachedInput: 17_000, cachedInput: 42_000, cacheWrite: 4_000, output: 4_000),
                unindexedTokens: 2_000,
                cost: .init(catalogPricedUSD: 0.38),
                records: 3
            ),
            children: ["child": .init(tokens: .init(output: 4_000), unindexedTokens: 2_000)],
            indexedRange: .lifetime,
            builtAt: Date(),
            pricingCatalogVersion: UsagePricingCatalog.version,
            coverage: .init(
                runtimeID: AgentKind.claude.rawValue,
                runtimeName: AgentKind.claude.displayName,
                state: .complete,
                sourceCount: 2,
                recordCount: 8
            )
        )
    }

    private static var multilineCommandUsageFixture: SessionUsageSnapshot {
        let total = SessionUsageSnapshot.Reading(
            tokens: .init(
                uncachedInput: 4_000_000,
                cachedInput: 141_700_000,
                output: 272_000,
                reasoning: 113_000
            ),
            cost: .init(providerReportedUSD: 78),
            records: 1_072,
            models: [
                .init(
                    name: "gpt-5.6-sol",
                    tokens: .init(
                        uncachedInput: 4_000_000,
                        cachedInput: 141_700_000,
                        output: 272_000,
                        reasoning: 113_000
                    ),
                    cost: .init(providerReportedUSD: 78),
                    records: 1_072
                )
            ]
        )
        return SessionUsageSnapshot(
            sessionID: SessionID(),
            total: total,
            main: total,
            subagents: .init(),
            children: [:],
            indexedRange: .lifetime,
            builtAt: Date(),
            pricingCatalogVersion: UsagePricingCatalog.version,
            coverage: .init(
                runtimeID: AgentKind.codex.rawValue,
                runtimeName: AgentKind.codex.displayName,
                state: .complete,
                sourceCount: 1,
                recordCount: 1_072
            )
        )
    }

    // MARK: - Helpers

    private func panelImage(
        appearance name: NSAppearance.Name,
        snapshot: SessionInfoSnapshot,
        isRunning: Bool,
        size: NSSize = Render.size,
        usageSnapshot: SessionUsageSnapshot? = nil,
        unfoldedProcessIDs: Set<pid_t> = []
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let controller = SessionInfoViewController(
                sessionID: SessionID(),
                folderPath: "\(Self.home)/repo/example"
            )
            // Installed before the view exists, so even `viewDidLoad`'s own refresh reads the
            // fixture rather than walking the machine.
            controller.readSource = { completion in completion(snapshot) }
            let resolvedUsage = usageSnapshot ?? Self.usageFixture
            controller.usageSource = { resolvedUsage }

            let host = ThemedSurfaceView()
            host.frame = NSRect(origin: .zero, size: size)
            host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            host.appearance = appearance

            let view = controller.view
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)

            controller.apply(snapshot, isRunning: isRunning)
            var unfolded = 0
            for process in snapshot.processes where unfoldedProcessIDs.contains(process.pid) {
                let identifier = SessionInfoDefaults.processRowIdentifier(process.pid)
                guard let row = Self.descendants(of: SessionInfoRowView.self, in: controller.view)
                    .first(where: { $0.accessibilityIdentifier() == identifier }) else { continue }
                row.setExpanded(true)
                if row.isExpanded { unfolded += 1 }
            }
            XCTAssertEqual(unfolded, unfoldedProcessIDs.count, "a row asked to unfold did not")

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

    private static func descendants<T>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            let match = (subview as? T).map { [$0] } ?? []
            return match + descendants(of: type, in: subview)
        }
    }
}
