import AppKit
import XCTest
@testable import Skalman

/// Draws a real conversation under each stock theme and writes it out.
///
/// This is the only way the chrome refactor can be reviewed at all. A theme's job is to change
/// how the whole surface reads, and no assertion about a token catches "the panels went neon
/// and every label stayed system grey" — which is exactly the state the app is in while the
/// call sites are still being routed. The contact sheet *is* the remaining work list.
@MainActor
final class AppThemeRenderTests: XCTestCase {

    private enum Render {
        static let width: CGFloat = 720
        static let rowLimit = 22

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }

        /// A fixture with the widest colour surface: user bubbles, tool rows, a diff, and code.
        static var fixture: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Transcripts/claude-edit-heavy.jsonl")
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testRendersAConversationUnderEveryStockTheme() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Render.fixture.path),
            "Missing fixture. Regenerate with scripts/scrub_transcript.py."
        )

        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)

            let data = try XCTUnwrap(
                image(for: theme),
                "Failed to render \(theme.name)"
            )
            let url = directory.appendingPathComponent("chrome-\(theme.id.rawValue).png")
            try data.write(to: url)
            written.append(url.lastPathComponent)
        }

        print("Rendered \(written.count) themed conversations to \(directory.path)")
        XCTAssertEqual(written.count, AppThemeLibrary.stock.count)
    }

    // MARK: - Building

    private func rows() -> [ConversationTimeline.Row] {
        let (events, _) = TranscriptReplay.read(at: Render.fixture, kind: .claude)
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return Array(timeline.rows.prefix(Render.rowLimit))
    }

    private func image(for theme: AppTheme) -> Data? {
        // A themed app pins its appearance, or the system draws its own scrollers and selection
        // over it — so the render uses the theme's own mode rather than the process's.
        let appearance = theme.isSystem
            ? NSAppearance(named: .darkAqua)
            : theme.mode.appearance

        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let host = laidOut(rows())
            host.appearance = appearance
            data = png(of: host, ground: theme.resolved(.ground))
        }
        return data
    }

    private func laidOut(_ rows: [ConversationTimeline.Row]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        for row in rows {
            let (view, startsTurn) = ConversationRowView.make(for: row)
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
            ])
            if startsTurn, let previous {
                stack.setCustomSpacing(Design.Chat.turnSpacing, after: previous)
            }
            previous = view
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.inset),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Render.width)
        ])

        host.layoutSubtreeIfNeeded()
        host.frame.size.height = stack.fittingSize.height + Design.Spacing.pane
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func png(of host: NSView, ground: NSColor) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The pane paints no ground of its own — it sits on the window — so the theme's own
        // ground is painted here, which is also what the app does.
        host.wantsLayer = true
        host.layer?.backgroundColor = ground.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
