import AppKit
import XCTest
@testable import Skalman

/// Draws whole fixture conversations through the real row views and writes them out as images.
///
/// Two jobs, and the second is the point. The assertions catch the layout faults that are
/// invisible to the timeline tests — a row that measures zero high, one that overflows the pane
/// — because those are properties of Auto Layout, not of the model. The images are how the
/// conversation's *appearance* becomes reviewable at all: until this existed, the only way to
/// see a rendering change was to build the app, start a session and get an agent to say
/// something with the right shape in it.
///
/// Both appearances are rendered, because the design derives every surface from a system colour
/// specifically so light and dark both work, and a change that breaks one is easy to miss while
/// working in the other.
final class ConversationRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        /// The display pane's real working width. Narrow enough that wrapping, diff gutters and
        /// the tool row's fixed glyph column are all under pressure, which is where they break.
        static let width: CGFloat = 720

        /// Rows per image. A fixture runs to hundreds of rows and a single tall strip is not
        /// reviewable; this is about a screenful of conversation.
        static let rowLimit = 40

        /// A plausible window height, for the pane renders — the rail centres in the viewport,
        /// so an image of it has to have one.
        static let viewportHeight: CGFloat = 800

        /// Where images land. Overridable so a review pass can drop them somewhere convenient.
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }
    }

    private enum Fixture: String, CaseIterable {
        case claudeEditHeavy = "claude-edit-heavy"
        case claudeToolsAndThinking = "claude-tools-and-thinking"
        case codexExecAndPatch = "codex-exec-and-patch"
        case codexReasoning = "codex-reasoning"

        var kind: AgentKind { rawValue.hasPrefix("claude") ? .claude : .codex }

        var url: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Transcripts/\(rawValue).jsonl")
        }
    }

    // MARK: - Building

    private func rows(for fixture: Fixture) throws -> [ConversationTimeline.Row] {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: fixture.url.path),
            "Missing fixture \(fixture.rawValue). Regenerate with scripts/scrub_transcript.py."
        )

        let (events, _) = TranscriptReplay.read(at: fixture.url, kind: fixture.kind)
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return timeline.rows
    }

    /// Lays the rows out in a stack shaped like the conversation pane's, at a fixed width.
    private func laidOut(_ rows: [ConversationTimeline.Row], width: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        var previous: NSView?

        func add(_ view: NSView, startsTurn: Bool) {
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

        // Mirrors `ConversationRendering.apply(_:)`. Divergence here would make the images
        // pictures of something the app never draws, so any change to placement belongs in
        // both — the row views themselves are already shared.
        for row in rows {
            let (view, startsTurn) = ConversationRowView.make(for: row)
            if startsTurn, previous != nil {
                add(ConversationRowView.turnDivider(), startsTurn: true)
            }
            add(view, startsTurn: startsTurn)
        }

        // Width is pinned and height left free, which is the pane's own arrangement: a
        // conversation is as tall as it needs to be inside a scroll view of fixed width.
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: width)
        ])

        host.layoutSubtreeIfNeeded()
        host.frame.size.height = stack.fittingSize.height
        host.layoutSubtreeIfNeeded()

        return stack
    }

    // MARK: - Layout

    func testNoRowCollapsesToNothing() throws {
        // A zero-height row is invisible but still takes the stack's spacing, so it reads as an
        // unexplained gap. Empty content is the usual cause and the timeline drops that, but a
        // view that fails to size itself is not something the model can see.
        for fixture in Fixture.allCases {
            let rows = Array(try self.rows(for: fixture).prefix(Render.rowLimit))
            let stack = laidOut(rows, width: Render.width)

            // Indexed by subview, not by row: dividers are inserted between turns, so the
            // two lists are no longer parallel.
            for (index, view) in stack.arrangedSubviews.enumerated() {
                XCTAssertGreaterThan(
                    view.frame.height, 0,
                    "\(fixture.rawValue) subview \(index) (\(type(of: view))) laid out zero high"
                )
            }
        }
    }

    func testNoRowOverflowsThePane() throws {
        // The pane is narrow and horizontal scrolling is not offered, so anything wider than it
        // is simply lost. Long single-token lines in tool output are the usual culprit.
        for fixture in Fixture.allCases {
            let rows = Array(try self.rows(for: fixture).prefix(Render.rowLimit))
            let stack = laidOut(rows, width: Render.width)

            for (index, view) in stack.arrangedSubviews.enumerated() {
                XCTAssertLessThanOrEqual(
                    view.frame.maxX, Render.width + 1,
                    "\(fixture.rawValue) subview \(index) (\(type(of: view))) overflowed the pane"
                )
            }
        }
    }

    func testUserBubblesStayOnTheRightAndDoNotSpanThePane() throws {
        // The bubble's whole job is to read as the user's side of an exchange, which it stops
        // doing the moment it is full width.
        let rows = try self.rows(for: .claudeEditHeavy)
        let userRows = rows.filter { if case .userMessage = $0 { return true } else { return false } }
        XCTAssertFalse(userRows.isEmpty)

        let stack = laidOut(Array(userRows.prefix(10)), width: Render.width)

        // Skipping the turn dividers between them, which have no bubble inside.
        let bubbles = stack.arrangedSubviews.compactMap { $0.subviews.first }
        XCTAssertGreaterThanOrEqual(bubbles.count, userRows.prefix(10).count)

        for bubble in bubbles {
            XCTAssertLessThanOrEqual(
                bubble.frame.width,
                Render.width * Design.Chat.bubbleMaxWidthFraction + 1,
                "A user bubble spanned the pane"
            )
        }
    }

    func testToolCallsRenderCollapsed() throws {
        // Collapsed by default is what keeps a directory listing from being longer than
        // everything said around it. A tool row that opens itself defeats the whole treatment.
        let rows = try self.rows(for: .codexExecAndPatch)
        let toolRows = rows.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertFalse(toolRows.isEmpty)

        let stack = laidOut(Array(toolRows.prefix(20)), width: Render.width)
        let heights = stack.arrangedSubviews.map(\.frame.height)

        let tallest = try XCTUnwrap(heights.max())
        XCTAssertLessThan(tallest, 120, "A collapsed tool row was \(tallest)pt tall")
    }

    // MARK: - Pane

    /// The whole pane: the column capped and centred, with the turn rail in the gutter that
    /// leaves. The row-level harness above cannot show either — both are properties of the
    /// pane, and the rail in particular exists or not depending on how wide it is.
    private func pane(
        rows: [ConversationTimeline.Row],
        turns: [ConversationTimeline.Turn],
        width: CGFloat
    ) -> NSView {
        let stack = laidOut(rows, width: Design.Size.readableWidth)
        stack.removeFromSuperview()
        stack.translatesAutoresizingMaskIntoConstraints = false

        let minimap = ConversationMinimapView()
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.setTurns(turns)
        minimap.setAvailableWidth(
            ConversationMinimap.railWidth(paneWidth: width, columnWidth: Design.Size.readableWidth),
            paneWidth: width
        )
        // The rail fades in rather than appearing, and a still image has no run loop to
        // animate over.
        minimap.alphaValue = 1

        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        host.addSubview(stack)
        host.addSubview(minimap)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: min(width, Design.Size.readableWidth)),

            minimap.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: ConversationMinimap.railLeading(
                    paneWidth: width, columnWidth: Design.Size.readableWidth
                )
            ),
            minimap.topAnchor.constraint(equalTo: host.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            minimap.widthAnchor.constraint(
                equalToConstant: ConversationMinimap.railWidth(
                    paneWidth: width, columnWidth: Design.Size.readableWidth
                )
            )
        ])

        // A *viewport*, not the document. The rail is pinned to the scroll view in the app and
        // centres in what is on screen; sizing the host to the whole conversation would centre
        // it in a page two thousand points tall and show something the app never draws.
        host.frame.size.height = Render.viewportHeight
        host.layoutSubtreeIfNeeded()

        return host
    }

    func testRendersThePaneAtSeveralWidths() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (events, _) = TranscriptReplay.read(at: Fixture.claudeEditHeavy.url, kind: .claude)
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }

        let rows = Array(timeline.rows.prefix(Render.rowLimit))
        let turns = timeline.turns.filter { $0.rowIndex < rows.count }

        // Chosen to straddle the thresholds: no gutter, a rail that fades in, a rail shown at
        // rest, and a window wide enough that the rail's placement stops being obvious — which
        // is the width at which it was found to be wrong.
        for width in [Design.Size.readableWidth, 720, 1000, 1800] as [CGFloat] {
            let host = pane(rows: rows, turns: turns, width: width)
            guard let data = png(of: host) else { continue }
            try data.write(to: directory.appendingPathComponent("pane-\(Int(width)).png"))
        }

        print("Rendered pane widths to \(directory.path)")
    }

    // MARK: - Images

    func testRendersEveryFixtureInBothAppearances() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for fixture in Fixture.allCases {
            let rows = Array(try self.rows(for: fixture).prefix(Render.rowLimit))

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("\(fixture.rawValue)-\(name).png")
                let data = try XCTUnwrap(
                    image(of: rows, appearance: appearance),
                    "Failed to render \(fixture.rawValue) in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        // Printed rather than asserted: the value is in opening them. A failure here means the
        // renderer could not draw at all, which the layout tests above would have caught first.
        print("Rendered \(written.count) conversations to \(directory.path)")
        XCTAssertEqual(written.count, Fixture.allCases.count * 2)
    }

    // MARK: - Theme Matrix

    /// Every stock theme × its appearances × every fixture, as a reviewable gallery.
    ///
    /// This is the render pass the individual bug reports kept asking for one cell of: a light
    /// variant carrying dark syntax, a diff wash frozen in the wrong appearance, a palette that
    /// reads in one agent's output shape and not the other's. The assertions elsewhere pin what
    /// can be measured; this writes the whole combination space out as images, with an
    /// `matrix.html` beside them so a human can sweep every cell in one scroll.
    func testRendersTheThemeMatrix() throws {
        let directory = Render.directory.appendingPathComponent("theme-matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let original = AppThemePalette.current
        defer { AppThemePalette.set(original) }

        var rowsByFixture: [Fixture: [ConversationTimeline.Row]] = [:]
        for fixture in Fixture.allCases {
            rowsByFixture[fixture] = Array(try self.rows(for: fixture).prefix(Render.rowLimit))
        }

        var cells: [(themeName: String, variant: String, fixture: String, file: String)] = []

        for theme in [AppTheme.system] + AppThemeStyles.all {
            AppThemePalette.set(theme)

            // An adaptive theme (System included) is two appearances; a fixed theme is the one
            // it pins. Rendering a fixed theme in the other appearance would show something the
            // app never draws.
            let variants: [(String, NSAppearance.Name)] = theme.isAdaptive
                ? [("light", .aqua), ("dark", .darkAqua)]
                : [theme.mode == .dark ? ("dark", .darkAqua) : ("light", .aqua)]

            for (variantName, appearanceName) in variants {
                for fixture in Fixture.allCases {
                    guard let rows = rowsByFixture[fixture] else { continue }
                    let file = "\(theme.id.rawValue)-\(variantName)-\(fixture.rawValue).png"
                    let data = try XCTUnwrap(
                        image(of: rows, appearance: appearanceName, ground: Design.Surface.ground),
                        "Failed to render \(theme.name) (\(variantName)) × \(fixture.rawValue)"
                    )
                    try data.write(to: directory.appendingPathComponent(file))
                    cells.append((
                        themeName: theme.name,
                        variant: variantName,
                        fixture: fixture.rawValue,
                        file: file
                    ))
                }
            }
        }

        try matrixHTML(cells: cells, fixtures: Fixture.allCases.map(\.rawValue))
            .write(
                to: directory.appendingPathComponent("matrix.html"),
                atomically: true,
                encoding: .utf8
            )

        print("Rendered \(cells.count) matrix cells to \(directory.path)/matrix.html")
        XCTAssertFalse(cells.isEmpty)
    }

    /// One row per theme-variant, one column per fixture; images lazy-load and click through
    /// to the full-size file.
    private func matrixHTML(
        cells: [(themeName: String, variant: String, fixture: String, file: String)],
        fixtures: [String]
    ) -> String {
        var byRow: [String: [String: String]] = [:]
        var rowOrder: [String] = []
        for cell in cells {
            let key = "\(cell.themeName) · \(cell.variant)"
            if byRow[key] == nil { rowOrder.append(key) }
            byRow[key, default: [:]][cell.fixture] = cell.file
        }

        var html = """
        <!doctype html><meta charset="utf-8"><title>Skalman theme matrix</title>
        <style>
        body { font: 13px -apple-system, sans-serif; margin: 16px; background: #1a1a1a; color: #ddd; }
        table { border-collapse: collapse; }
        th, td { padding: 6px 8px; text-align: left; vertical-align: top; }
        thead th { position: sticky; top: 0; background: #1a1a1a; z-index: 1; }
        th.theme { position: sticky; left: 0; background: #1a1a1a; white-space: nowrap; }
        img { width: 340px; display: block; border-radius: 6px; border: 1px solid #333; }
        </style>
        <h1>Theme × agent matrix</h1>
        <table><thead><tr><th class="theme">Theme</th>
        """
        for fixture in fixtures { html += "<th>\(fixture)</th>" }
        html += "</tr></thead><tbody>"
        for key in rowOrder {
            html += "<tr><th class=\"theme\">\(key)</th>"
            for fixture in fixtures {
                if let file = byRow[key]?[fixture] {
                    html += "<td><a href=\"\(file)\"><img loading=\"lazy\" src=\"\(file)\"></a></td>"
                } else {
                    html += "<td>—</td>"
                }
            }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    /// Snapshots a laid-out view.
    private func png(of host: NSView, ground: NSColor = .textBackgroundColor) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The pane has no background of its own — it sits on the window's material — so one is
        // painted here, or every label draws onto transparency and the image is unreadable.
        host.wantsLayer = true
        host.layer?.backgroundColor = ground.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func image(
        of rows: [ConversationTimeline.Row],
        appearance name: NSAppearance.Name,
        ground: NSColor = .textBackgroundColor
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let stack = self.laidOut(rows, width: Render.width)
            stack.appearance = appearance

            guard let host = stack.superview else { return }
            host.appearance = appearance
            data = self.png(of: host, ground: ground)
        }

        // `performAsCurrentDrawingAppearance` is the only thing that makes a dynamic system
        // colour resolve to the appearance being rendered rather than the process's own.
        if #available(macOS 11.0, *) {
            appearance?.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        return data
    }
}
