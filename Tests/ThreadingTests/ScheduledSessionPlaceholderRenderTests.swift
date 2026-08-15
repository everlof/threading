import AppKit
import XCTest
@testable import Threading

/// Visual evidence for the actual-conversation empty state a scheduled start reserves.
@MainActor
final class ScheduledSessionPlaceholderRenderTests: XCTestCase {

    private struct Fixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
        let model: ScheduledSessionPlaceholderView.Model
    }

    private var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "ThreadingRenders",
            isDirectory: true
        )
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testRendersTimeResetAndConversationTriggers() throws {
        let fixtures = [
            Fixture(
                name: "time-light",
                theme: .system,
                appearance: .aqua,
                model: .init(
                    title: "Audit the release checklist",
                    trigger: "Starts automatically Today at 17:30 · in 2 hours",
                    problem: nil,
                    brief: "Review the release checklist, verify every migration, and summarize anything that still blocks shipping.",
                    configuration: "Codex · gpt-5.6 · High · Fast · main · Native chat"
                )
            ),
            Fixture(
                name: "usage-reset-dark",
                theme: .system,
                appearance: .darkAqua,
                model: .init(
                    title: "Continue after the usage reset",
                    trigger: "Starts automatically after the usage window resets · expected Tomorrow at 09:05 · in 16 hours",
                    problem: nil,
                    brief: "Pick up the accessibility pass with a fresh usage window and finish the keyboard review.",
                    configuration: "Claude Code · Opus · Extra High · master · Terminal"
                )
            ),
            Fixture(
                name: "conversation-cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua,
                model: .init(
                    title: "Review the implementation",
                    trigger: "Starts automatically when “Implement scheduling” finishes",
                    problem: "Waiting for that conversation to finish its current turn",
                    brief: "Inspect the completed implementation, run the focused checks, and report any lifecycle gaps.",
                    configuration: "Codex · gpt-5.6 · High · feature/scheduled-chat · Native chat"
                )
            )
        ]

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            var png: Data?

            appearance.performAsCurrentDrawingAppearance {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 590))
                host.appearance = appearance
                let scheduled = ScheduledSessionPlaceholderView()
                scheduled.configure(fixture.model)
                host.addSubview(scheduled)
                NSLayoutConstraint.activate([
                    scheduled.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    scheduled.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    scheduled.topAnchor.constraint(equalTo: host.topAnchor),
                    scheduled.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.ground.cgColor

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }

            let data = try XCTUnwrap(png)
            XCTAssertGreaterThan(data.count, 1_000)
            try data.write(
                to: outputDirectory.appendingPathComponent(
                    "scheduled-session-\(fixture.name).png"
                )
            )
        }
    }
}
