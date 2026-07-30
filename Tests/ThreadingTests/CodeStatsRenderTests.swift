import AppKit
import XCTest
@testable import Threading

/// Draws the project-stats popover through the real views and writes each story out as an
/// image, both appearances — the same fixture-to-PNG idea as the conversation and git-review
/// renders, for the same reason: whether six segments read as a composition or a smear, and
/// whether the "Other" fold reads as muted rather than missing, are visible only in a picture.
@MainActor
final class CodeStatsRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// A fixed reading age, so the footer is a stable string rather than the test's runtime.
    private let measuredAt = Date().addingTimeInterval(-7 * 60)

    // MARK: - Stories

    func testRendersTheStorybook() throws {
        var written = 0

        // This repository's own shape: one dominant language, a modest tail, no fold.
        written += try write(story: "01-swift-dominant", info: info(name: "Threading", codes: [
            ("Swift", 60_965, 374), ("Markdown", 4_762, 23), ("JSON", 821, 15),
            ("Python", 322, 2), ("YAML", 81, 2)
        ]))

        // A polyglot monorepo: more languages than the cap, so the fold earns its keep.
        written += try write(story: "02-polyglot", info: info(name: "sonda", codes: [
            ("TypeScript", 48_200, 610), ("Rust", 31_450, 120), ("Python", 12_800, 95),
            ("Go", 8_400, 40), ("Swift", 5_100, 33), ("Shell", 2_200, 51),
            ("YAML", 1_900, 24), ("Dockerfile", 300, 6)
        ]))

        // One language only: the bar is a single run and the legend one row.
        written += try write(story: "03-single-language", info: info(name: "scripts", codes: [
            ("Python", 1_842, 12)
        ]))

        // No scc on the machine: the popover is the install hint instead of silence.
        written += try write(story: "04-missing-tool") {
            ProjectStatsPopoverViewController(missingToolFor: "Threading")
        }

        XCTAssertEqual(written, 8, "Every story should render in both appearances")
        print("Rendered code-stats storybook to \(Render.directory.path)")
    }

    // MARK: - Harness

    private func info(
        name: String,
        codes: [(String, Int, Int)]
    ) -> ProjectStatsPopoverViewController.Info {
        let stats = CodeStats(languages: codes.map {
            CodeStats.Language(
                name: $0.0, files: $0.2, code: $0.1,
                comments: $0.1 / 10, blanks: $0.1 / 12, complexity: 0, bytes: 0
            )
        })
        return ProjectStatsPopoverViewController.Info(
            projectName: name, stats: stats, measuredAt: measuredAt
        )
    }

    private func write(
        story: String,
        info: ProjectStatsPopoverViewController.Info
    ) throws -> Int {
        try write(story: story) { ProjectStatsPopoverViewController(info: info) }
    }

    private func write(
        story: String,
        make: @escaping () -> ProjectStatsPopoverViewController
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)

            var data: Data?
            let render = {
                let controller = make()
                let view = controller.view
                view.appearance = appearance
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                AppThemeRefresh.repaint(view)
                view.layoutSubtreeIfNeeded()

                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(to: directory.appendingPathComponent("code-stats-\(story)-\(name).png"))
            written += 1
        }
        return written
    }
}
