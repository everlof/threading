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

    private static func subview(of root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = subview(of: child, identifier: identifier) { return found }
        }
        return nil
    }

    func testRendersTimeResetAndConversationTriggers() throws {
        let fixtures = [
            Fixture(
                name: "time-light",
                theme: .system,
                appearance: .aqua,
                model: .init(
                    trigger: "Starts automatically Today at 17:30 · in 2 hours",
                    problem: nil,
                    brief: "Review the release checklist, verify every migration, and summarize anything that still blocks shipping.",
                    configuration: "Codex · gpt-5.6 · High · Fast · main · Native chat"
                )
            ),
            // The brief that used to draw as two clipped lines: hard newlines between long
            // paragraphs, each of which must wrap the column rather than truncate at it.
            Fixture(
                name: "usage-reset-dark",
                theme: .system,
                appearance: .darkAqua,
                model: .init(
                    trigger: "Starts automatically after the 7-day usage window on this account resets · expected Tomorrow at 09:05 (Europe/Stockholm) · in 16 hours",
                    problem: nil,
                    brief: "- Pick up the accessibility pass with a fresh usage window and finish the keyboard review across every settings pane.\n"
                        + "- Also revisit the sidebar shortcut question: cmd + s is a pretty well established chord for toggling the sidebar, so it should probably be our default.",
                    configuration: "Claude Code · Opus · Extra High · master · Terminal"
                )
            ),
            Fixture(
                name: "conversation-cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua,
                model: .init(
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
                    // The pane's width, stated the way a split view would (CLAUDE.md: "a
                    // detached fixture with a frame constrains nothing"). Without these the
                    // placeholder solved to its content's preferred 808 points inside the
                    // 760-point host, and every width conclusion below was about a pane that
                    // did not exist.
                    host.widthAnchor.constraint(equalToConstant: 760),
                    host.heightAnchor.constraint(equalToConstant: 590),
                    scheduled.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    scheduled.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    scheduled.topAnchor.constraint(equalTo: host.topAnchor),
                    scheduled.bottomAnchor.constraint(equalTo: host.bottomAnchor)
                ])
                AppThemeRefresh.repaint(host)
                // Twice, as the window's layout engine would: the first pass decides the
                // column's width, and the wrapping labels re-measure their heights against it.
                host.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()

                // The multi-paragraph brief *wraps* the column instead of clipping each
                // paragraph to one truncated line — the defect this surface shipped with:
                // `byTruncatingTail` on a wrapping field truncates per paragraph, so a
                // two-bullet brief drew as two "…" lines with the pane standing empty.
                if fixture.name == "usage-reset-dark",
                   let brief = Self.subview(of: host, identifier: "scheduled-session.brief"),
                   let font = (brief as? NSTextField)?.font {
                    let lineHeight = ceil(font.boundingRectForFont.height)
                    XCTAssertGreaterThan(
                        brief.frame.height,
                        lineHeight * 3.5,
                        "a two-paragraph brief should wrap into four or more lines, not clip to two"
                    )
                }

                // The seam between the announcement and the brief survives the warning line
                // hiding. It was recorded as custom spacing *after* the sometimes-hidden
                // warning label, and NSStackView drops a hidden member's custom spacing — so
                // this fixture, the ordinary no-warning case, collapsed the section break to
                // the 4pt base and "Brief" read as a stray word glued to the headline.
                if fixture.name == "usage-reset-dark",
                   let trigger = Self.subview(of: host, identifier: "scheduled-session.trigger"),
                   let caption = Self.subview(
                       of: host,
                       identifier: "scheduled-session.brief-caption"
                   ),
                   let triggerFrame = trigger.superview.map({ $0.convert(trigger.frame, to: host) }),
                   let captionFrame = caption.superview.map({ $0.convert(caption.frame, to: host) }) {
                    XCTAssertGreaterThanOrEqual(
                        triggerFrame.minY - captionFrame.maxY,
                        Design.Spacing.pane - 4,
                        "the announcement→brief section break collapsed; the seam must not hang on the hideable warning line"
                    )
                }

                // The headline wraps too: a trigger sentence longer than the column drew as one
                // truncated line because the field kept its cached one-line intrinsic size after
                // its preferred width moved.
                if fixture.name == "usage-reset-dark",
                   let trigger = Self.subview(of: host, identifier: "scheduled-session.trigger"),
                   let font = (trigger as? NSTextField)?.font {
                    XCTAssertGreaterThan(
                        trigger.frame.height,
                        ceil(font.boundingRectForFont.height) * 1.5,
                        "a long trigger sentence should wrap to a second line, not truncate"
                    )
                }

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
