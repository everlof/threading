import AppKit
import XCTest
@testable import Threading

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
@MainActor
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
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
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

    func testCollapsedToolCallsDeferTheirBodiesUntilFirstExpansion() {
        let edit = ToolCallView(
            tool: .edit,
            summary: "Sources/Feature.swift",
            diff: [
                DiffLine(kind: .removed, text: "let oldValue = true"),
                DiffLine(kind: .added, text: "let newValue = true")
            ]
        )

        XCTAssertFalse(Self.descendants(in: edit).contains { $0 is DiffView })
        edit.setExpanded(true)
        XCTAssertEqual(Self.descendants(in: edit).filter { $0 is DiffView }.count, 1)
        edit.setExpanded(false)
        edit.setExpanded(true)
        XCTAssertEqual(
            Self.descendants(in: edit).filter { $0 is DiffView }.count,
            1,
            "reopening a materialized tool should reuse its body"
        )

        let output = "deferred tool output\nwith a second line"
        let read = ToolCallView(tool: .read, summary: "Sources/Feature.swift")
        read.setResult(output, outcome: .succeeded)
        XCTAssertFalse(
            Self.descendants(in: read)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == output }
        )
        read.setExpanded(true)
        XCTAssertTrue(
            Self.descendants(in: read)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == output },
            "a deferred result must appear when its row first opens"
        )
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
        // `guard let … else { continue }` on a failed render used to stand here, so a pane that
        // stopped drawing entirely still passed — silently, having written nothing for anyone to
        // review. These renders exist to be looked at; producing none of them is the one outcome
        // that must fail rather than pass quietly.
        for width in [Design.Size.readableWidth, 720, 1000, 1800] as [CGFloat] {
            let host = pane(rows: rows, turns: turns, width: width)
            let data = try XCTUnwrap(png(of: host), "the pane drew nothing at \(Int(width))pt")
            try data.write(to: directory.appendingPathComponent("pane-\(Int(width)).png"))
        }

        print("Rendered pane widths to \(directory.path)")
    }

    /// The sticky step header, over a live pane scrolled into the middle of a turn.
    ///
    /// Two claims here are only checkable by looking. It must read as **opaque** over the text it
    /// covers, because a translucent strip over a moving transcript reads as a rendering fault
    /// rather than as chrome; and it must stand on the **column**, since a name that starts
    /// somewhere other than where the row starts is a name for something else. 720 is rendered
    /// as well as 1000 because 720 has no gutter and therefore no rail — the case the header
    /// exists for, and the ordinary one in a three-pane window.
    func testRendersTheStickyStepHeaderInsideALongTurn() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [720, 1000] as [CGFloat] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var landed = false
                var data: Data?

                // Everything inside one drawing appearance: the table materializes cells lazily,
                // so construction, layout and the scroll below all have to happen while it is
                // current or the render comes out in two palettes at once.
                appearance.performAsCurrentDrawingAppearance {
                    let (controller, host) = livePane(
                        turns: 6, width: width, appearance: appearance
                    )
                    host.appearance = appearance

                    // Scrolled the way a reader gets there rather than positioned: walk down the
                    // document until the header resolves a step, which is the state being drawn.
                    let clip = controller.scrollView.contentView
                    let overflow = max(
                        0,
                        (clip.documentView?.bounds.height ?? 0)
                            - controller.scrollView.contentSize.height
                    )
                    for step in stride(from: 0.05, through: 0.95, by: 0.05) {
                        clip.setBoundsOrigin(NSPoint(x: 0, y: overflow * CGFloat(step)))
                        controller.scrollView.reflectScrolledClipView(clip)
                        host.layoutSubtreeIfNeeded()
                        controller.updateStickyStep()
                        if controller.stickyStepRowIndex != nil { landed = true; break }
                    }

                    host.layoutSubtreeIfNeeded()
                    data = png(
                        of: host,
                        ground: appearanceName == .darkAqua
                            ? NSColor(white: 0.11, alpha: 1)
                            : NSColor(white: 1, alpha: 1)
                    )
                }

                XCTAssertTrue(
                    landed,
                    "No scroll position inside six stress turns put the reader under a tool call"
                )
                try XCTUnwrap(data, "the pane drew nothing at \(Int(width))pt").write(
                    to: directory.appendingPathComponent("sticky-step-\(Int(width))-\(name).png")
                )
            }
        }

        print("Rendered sticky step header to \(directory.path)")
    }

    /// The live pane, held at a stated width the way a split item holds it.
    ///
    /// A frame alone constrains nothing: laid out detached, the pane settles at the width it
    /// would *prefer*, which for this subtree is its own content's — and every measurement taken
    /// off it is then a measurement of the fixture rather than of the app. See CLAUDE.md.
    private func livePane(
        turns: Int,
        width: CGFloat,
        height: CGFloat = Render.viewportHeight,
        appearance: NSAppearance? = nil
    ) -> (controller: ConversationViewController, host: NSView) {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Column", usesNativeUI: true),
            project: Project(
                name: "Column",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        // The appearance has to be current **while** the subtree is built, not assigned after.
        // `applySurface` bakes resolved colours into layers as each view is constructed, so an
        // appearance handed to the host afterwards repaints nothing: the first pass of the
        // sticky-header render came out entirely in the dark palette, and the second converted
        // the header alone, because the table builds its cells lazily and did so once the
        // drawing appearance had already been put back. Callers that want a stated appearance
        // therefore run *everything* — construction, event application, layout, and any scrolling
        // that materializes further cells — inside one `performAsCurrentDrawingAppearance` block.
        if let appearance { controller.view.appearance = appearance }
        _ = controller.view

        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        Self.apply(Self.stressEvents(shape: .mixed, turns: turns), to: controller)
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    func testTerminatingAConversationEndsItsWorkingStatusClock() {
        let (controller, _) = livePane(turns: 0, width: Render.width)
        controller.apply(.status(.working(word: "Reviewing")))

        let timer = controller.workingStatusTimer
        XCTAssertEqual(timer?.isValid, true)

        controller.terminate()

        XCTAssertNil(controller.workingStatusTimer)
        XCTAssertEqual(timer?.isValid, false)
    }

    /// Everything in the pane stands on one column, and the column is in the middle of the pane.
    ///
    /// Asserted against the **table**, because that is where it was wrong: the row fixture above
    /// centres a stack in a host by hand and so agrees with itself whatever the cell does. In the
    /// app a cell is not given its column's width, and the transcript was flush against the
    /// sidebar in every window wider than the column — with the turn rail, placed for a centred
    /// column, sitting on the first character of every paragraph.
    func testTranscriptComposerAndRailStandOnOneCentredColumn() throws {
        for width in [Design.Size.readableWidth, 720, 1000, 1418, 1800] as [CGFloat] {
            let (controller, _) = livePane(turns: 4, width: width)
            let pane = controller.view
            let expectedColumn = min(
                Design.Size.readableWidth,
                width - Design.Spacing.inset * 2
            )

            var contentFrames: [NSRect] = []
            for row in 0..<controller.tableView.numberOfRows {
                guard let cell = controller.tableView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: true
                ), let content = cell.subviews.first else { continue }
                contentFrames.append(content.convert(content.bounds, to: pane))
            }
            XCTAssertFalse(contentFrames.isEmpty, "no rows materialized at \(Int(width))pt")

            for frame in contentFrames {
                XCTAssertEqual(
                    frame.midX,
                    pane.bounds.midX,
                    accuracy: 1,
                    "a transcript row is off the pane's centre at \(Int(width))pt"
                )
                XCTAssertLessThanOrEqual(
                    frame.width,
                    expectedColumn + 1,
                    "a transcript row is wider than its column at \(Int(width))pt"
                )
                XCTAssertGreaterThanOrEqual(
                    frame.minX,
                    Design.Spacing.inset - 1,
                    "a transcript row reaches the pane's edge at \(Int(width))pt"
                )
            }

            // The box's own padding is the difference, so the line being typed lands on exactly
            // the column the conversation above it is read on.
            let composer = try XCTUnwrap(Self.firstDescendant(PromptView.self, in: pane))
            let box = composer.convert(composer.bounds, to: pane)
            XCTAssertEqual(
                box.midX,
                pane.bounds.midX,
                accuracy: 1,
                "the reply box is off the pane's centre at \(Int(width))pt"
            )
            XCTAssertEqual(
                box.width,
                min(ConversationDefaults.composerWidth, width - Design.Spacing.inset * 2),
                accuracy: 1,
                "the reply box does not hold its column at \(Int(width))pt"
            )
            // Only where both hold their columns. Under that the box keeps the *pane's* inset
            // and the row keeps the table's, which differ by the few points the table insets
            // its own column by — a pane narrower than the reading measure has no column for
            // them to share in the first place.
            if let column = contentFrames.first,
               box.width >= ConversationDefaults.composerWidth - 1 {
                XCTAssertEqual(
                    box.minX + Design.Spacing.inset,
                    column.minX,
                    accuracy: 1,
                    "the reply text is off the transcript's column at \(Int(width))pt"
                )
            }

            // Whatever else moves, the rail keeps its clearance from the words.
            let railTrailing = ConversationMinimap.railLeading(
                paneWidth: width,
                columnWidth: Design.Size.readableWidth
            ) + ConversationMinimap.railWidth(
                paneWidth: width,
                columnWidth: Design.Size.readableWidth
            )
            if let column = contentFrames.first {
                XCTAssertLessThanOrEqual(
                    railTrailing,
                    column.minX,
                    "the turn rail overlaps the column at \(Int(width))pt"
                )
            }
        }
    }

    /// The pane's width belongs to the split view, and the divider must outrank anything the
    /// composer says about it. Every fixture above states its width as `required`, which is
    /// right for measuring the box and blind to the one failure that shipped: the reply box
    /// reached for the pane's width at `.defaultHigh` under its required column cap, and in any
    /// pane wider than the cap the solver satisfied that pull the cheap way — by shrinking the
    /// *pane* through the split view's weaker holding constraints. The conversation clamped
    /// itself to the box's width and the divider would not drag it wider. A detached view held
    /// at holding priority cannot stand in for that machinery (summed content hugging outweighs
    /// a lone optional width and shrinks it for a different reason entirely — measured), so the
    /// fixture is the machinery: a real `NSSplitViewController` in an unshown window, holding
    /// its panes the way the main window holds them, with the divider driven through the same
    /// Auto Layout path a drag resolves into.
    func testTheSplitViewDividerOutranksTheComposer() throws {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Column", usesNativeUI: true),
            project: Project(
                name: "Column",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        Self.apply(Self.stressEvents(shape: .mixed, turns: 2), to: controller)

        let sidebar = NSViewController()
        sidebar.view = NSView()
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.holdingPriority = SidebarDefaults.holdingPriority
        let contentItem = NSSplitViewItem(viewController: controller)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)

        // Built, never shown — see the testing notes in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1900, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1900, height: 800))
        window.layoutIfNeeded()

        let composer = try XCTUnwrap(Self.firstDescendant(PromptView.self, in: split.view))

        // The divider placed where the conversation is far wider than the box's cap — where
        // the shipped bug snapped the pane back to the cap and held it there.
        split.splitView.setPosition(700, ofDividerAt: 0)
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(
            controller.view.frame.width,
            1100,
            "the composer holds the conversation pane against the divider"
        )
        XCTAssertEqual(
            composer.frame.width,
            ConversationDefaults.composerWidth,
            accuracy: 1,
            "the reply box left its column in a wide pane"
        )

        // And back the other way, narrower than the cap: the box yields to the pane rather
        // than pushing the divider out.
        split.splitView.setPosition(1400, ofDividerAt: 0)
        window.layoutIfNeeded()
        let narrow = controller.view.frame.width
        XCTAssertLessThanOrEqual(
            narrow,
            560,
            "the composer pushed the divider back out of a narrow pane"
        )
        XCTAssertEqual(
            composer.frame.width,
            min(ConversationDefaults.composerWidth, narrow - Design.Spacing.inset * 2),
            accuracy: 1,
            "the reply box does not hold its column in a narrow pane"
        )
    }

    /// The images of the real pane, which is the only place the column and the rail can be seen
    /// standing beside each other — `pane(rows:turns:width:)` above draws a fixture that centres
    /// itself by construction and therefore cannot show this going wrong.
    func testRendersTheLivePaneAtSeveralWidths() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for width in [720, 1000, 1418] as [CGFloat] {
            let (_, host) = livePane(turns: 5, width: width)
            let data = try XCTUnwrap(png(of: host), "the live pane drew nothing at \(Int(width))pt")
            try data.write(to: directory.appendingPathComponent("live-pane-\(Int(width)).png"))
        }

        print("Rendered live pane widths to \(directory.path)")
    }

    // MARK: - Stress Profiling

    /// Opt-in because this deliberately reduces several hundred production transcript rows and
    /// exercises replay, measurement, exact jumps, folding, appends and streaming in AppKit.
    /// It is the repeatable counterpart to sampling a large conversation by hand: the event
    /// shapes are deterministic, but every row, fold, constraint and scroll is the production
    /// native-conversation implementation.
    func testStressNativeConversationWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_CONVERSATION_STRESS"] == "1",
            "Set THREADING_CONVERSATION_STRESS=1 to run the native conversation sweep."
        )

        var workloads: [(shape: StressShape, turns: Int)] = [
            (.mixed, 10),
            (.mixed, 25),
            (.mixed, 50),
            (.mixed, 100),
            (.prose, 125),
            (.toolHeavy, 100)
        ]
        if let override = ProcessInfo.processInfo.environment["THREADING_CONVERSATION_STRESS_TURNS"],
           let turns = Int(override), turns > 0 {
            let shape = ProcessInfo.processInfo.environment["THREADING_CONVERSATION_STRESS_SHAPE"]
                .flatMap(StressShape.init(rawValue:))
                ?? .mixed
            workloads = [(shape, turns)]
        }

        for workload in workloads {
            autoreleasepool {
                runConversationStress(shape: workload.shape, turns: workload.turns)
            }
        }
    }

    /// A large history is cheap once settled because its work is folded. This separate gate
    /// measures the opposite state: one current turn accumulating hundreds of addressable tool
    /// rows, results and streaming text before it is allowed to fold.
    func testStressActiveConversationTurnWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_CONVERSATION_ACTIVE_STRESS"] == "1",
            "Set THREADING_CONVERSATION_ACTIVE_STRESS=1 to run the active-turn sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let baseTurns = environment["THREADING_CONVERSATION_ACTIVE_BASE_TURNS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 100
        let toolCount = environment["THREADING_CONVERSATION_ACTIVE_TOOLS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 100
        runActiveTurnStress(baseTurns: baseTurns, toolCount: toolCount)
    }

    /// Opt-in retained-controller workload. Production keeps every live native conversation in
    /// `AgentRuntime` and reparents its view when the sidebar selection changes; one isolated
    /// controller cannot reveal the cumulative layout and memory cost of that lifecycle.
    func testStressConversationResidencyWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_CONVERSATION_RESIDENCY_STRESS"] == "1",
            "Set THREADING_CONVERSATION_RESIDENCY_STRESS=1 to run the residency sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let sessionCount = environment["THREADING_CONVERSATION_RESIDENCY_SESSIONS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 8
        let turns = environment["THREADING_CONVERSATION_RESIDENCY_TURNS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 50
        let shape = environment["THREADING_CONVERSATION_RESIDENCY_SHAPE"]
            .flatMap(StressShape.init(rawValue:))
            ?? .mixed
        runConversationResidencyStress(
            shape: shape,
            sessionCount: sessionCount,
            turns: turns
        )
    }

    /// Opt-in child-transcript workload. Unlike the parent renderer, the Subagents pane has its
    /// own host and update lifecycle, so the ordinary conversation sweep cannot catch it
    /// eagerly constructing every Markdown and tool row or rebuilding them on selection.
    func testStressSubagentTranscriptWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_SUBAGENT_STRESS"] == "1",
            "Set THREADING_SUBAGENT_STRESS=1 to run the child-transcript sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let readStarted = DispatchTime.now().uptimeNanoseconds
        let events: [StreamEvent]
        let source: String
        if let path = environment["THREADING_SUBAGENT_STRESS_TRANSCRIPT"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: url.path),
                "The requested child transcript does not exist."
            )
            events = ClaudeSubagentTranscriptReplay.readConversation(at: url).events
            source = "transcript"
        } else {
            let turns = environment["THREADING_SUBAGENT_STRESS_TURNS"]
                .flatMap(Int.init)
                .flatMap { $0 > 0 ? $0 : nil }
                ?? 100
            events = Self.stressEvents(shape: .mixed, turns: turns)
            source = "generated"
        }
        let readEnded = DispatchTime.now().uptimeNanoseconds

        let sessionID = SessionID()
        let threadID = "profile-child"
        let state = SubagentSessionState(sessionID: sessionID)
        state.apply(.discovered(SubagentDescriptor(
            threadID: threadID,
            nickname: "Profile child",
            role: "Explore"
        )))
        state.apply(.state(threadID: threadID, status: .completed, message: nil))
        let reduced = expectation(description: "child transcript reduced off the main queue")
        let modelStarted = DispatchTime.now().uptimeNanoseconds
        state.replaceTranscriptConversation(threadID: threadID, events: events) {
            reduced.fulfill()
        }
        wait(for: [reduced], timeout: 10)
        let modelEnded = DispatchTime.now().uptimeNanoseconds
        let timeline = state.timeline

        let baselineMemory = Self.physicalFootprintBytes()
        let controller = SubagentTranscriptViewController()
        let frame = NSRect(
            x: 0,
            y: 0,
            width: 540,
            height: Render.viewportHeight
        )
        _ = controller.view
        controller.view.frame = frame
        controller.view.layoutSubtreeIfNeeded()

        let renderStarted = DispatchTime.now().uptimeNanoseconds
        controller.update(timeline, selectedThreadID: threadID)
        let renderEnded = DispatchTime.now().uptimeNanoseconds
        let styledMarkdownBlocksDuringRender = controller.cachedMarkdownBlockCount
        controller.view.layoutSubtreeIfNeeded()
        let initialLayoutEnded = DispatchTime.now().uptimeNanoseconds
        let appKitMaterializedAfterLayout = controller.materializedPresentationCount
        let cachedMarkdownBlocksAfterInitialLayout = controller.cachedMarkdownBlockCount
#if DEBUG
        let initialRowMaterialization = controller.rowMaterializationDurations
#endif

        // An unshown NSTableView deliberately asks for no cells. Materialize the production
        // presentation rows into a width-constrained document to measure first-paint view work
        // without ordering a test window on screen or constructing rows the collapsed model
        // does not contain.
        let materializedDocument = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: frame.width,
            height: 1
        ))
        let materializedStack = NSStackView()
        materializedStack.orientation = .vertical
        materializedStack.alignment = .leading
        materializedStack.spacing = 0
        materializedStack.translatesAutoresizingMaskIntoConstraints = false
        materializedDocument.addSubview(materializedStack)
        NSLayoutConstraint.activate([
            materializedStack.topAnchor.constraint(equalTo: materializedDocument.topAnchor),
            materializedStack.leadingAnchor.constraint(equalTo: materializedDocument.leadingAnchor),
            materializedStack.trailingAnchor.constraint(equalTo: materializedDocument.trailingAnchor)
        ])

        let table = controller.transcriptTableView
        let viewportStart = max(0, table.numberOfRows - 18)
        let viewportRows = viewportStart..<table.numberOfRows
        let materializeStarted = DispatchTime.now().uptimeNanoseconds
        for row in viewportRows {
            guard let rowView = controller.tableView(
                table,
                viewFor: table.tableColumns.first,
                row: row
            ) else { continue }
            materializedStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: materializedStack.widthAnchor).isActive = true
        }
        let materializeEnded = DispatchTime.now().uptimeNanoseconds
        materializedDocument.layoutSubtreeIfNeeded()
        materializedDocument.frame.size.height = max(
            Render.viewportHeight,
            materializedStack.fittingSize.height
        )
        materializedDocument.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds
        let cachedMarkdownBlocksAfterViewport = controller.cachedMarkdownBlockCount
        let viewportMarkdownCacheGrowth = max(
            0,
            cachedMarkdownBlocksAfterViewport - cachedMarkdownBlocksAfterInitialLayout
        )
        let renderedMemory = Self.physicalFootprintBytes()

        let scrollView = ThemedScrollView(frame: frame)
        scrollView.documentView = materializedDocument
        let overflow = max(0, materializedDocument.bounds.height - scrollView.contentSize.height)
        var scrollDurations: [UInt64] = []
        if overflow > 0 {
            for tick in 0..<120 {
                let progress = CGFloat(tick) / 119
                let started = DispatchTime.now().uptimeNanoseconds
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: overflow * progress))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                materializedDocument.layoutSubtreeIfNeeded()
                scrollDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            }
        }

        // Exercise every logical row only after measuring the cold viewport. Running this
        // diagnostic first would populate the bounded Markdown cache and make first-paint
        // materialization look cheaper than the production path.
        var rowMountDurations: [UInt64] = []
        for row in 0..<table.numberOfRows {
            autoreleasepool {
                let started = DispatchTime.now().uptimeNanoseconds
                guard let rowView = controller.tableView(
                    table,
                    viewFor: table.tableColumns.first,
                    row: row
                ) else { return }
                rowView.frame = NSRect(x: 0, y: 0, width: frame.width, height: 1)
                rowView.frame.size.height = max(1, rowView.fittingSize.height)
                rowView.layoutSubtreeIfNeeded()
                rowMountDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            }
        }
        let diagnosticEnded = DispatchTime.now().uptimeNanoseconds

        let descendants = Self.descendantCount(in: materializedDocument)
#if DEBUG
        let renderPhases = controller.lastRenderPhaseDurations
        let renderPhaseMetrics = "summary_ms="
            + Self.milliseconds(renderPhases.summaryNanoseconds)
            + " presentation_ms="
            + Self.milliseconds(renderPhases.presentationNanoseconds)
            + " reload_ms="
            + Self.milliseconds(renderPhases.reloadNanoseconds)
            + " summary_rebuilds=\(renderPhases.summaryRebuilds)"
            + " appkit_mounts=\(initialRowMaterialization.count)"
            + " appkit_markdown_mounts=\(initialRowMaterialization.markdownCount)"
            + " appkit_mount_ms="
            + Self.milliseconds(initialRowMaterialization.totalNanoseconds)
            + " appkit_host_ms="
            + Self.milliseconds(initialRowMaterialization.hostNanoseconds)
            + " appkit_content_ms="
            + Self.milliseconds(initialRowMaterialization.contentNanoseconds)
            + " appkit_markdown_content_ms="
            + Self.milliseconds(initialRowMaterialization.markdownContentNanoseconds)
            + " appkit_install_ms="
            + Self.milliseconds(initialRowMaterialization.installNanoseconds)
            + " "
#else
        let renderPhaseMetrics = ""
#endif
        print(
            "THREADING_PERF subagent-transcript "
                + "source=\(source) events=\(events.count) rows=\(controller.renderedRowCount) "
                + "presented=\(controller.renderedPresentationCount) "
                + "materialized=\(viewportRows.count) "
                + "descendants=\(descendants) "
                + "read_ms=\(Self.milliseconds(readEnded - readStarted)) "
                + "model_ms=\(Self.milliseconds(modelEnded - modelStarted)) "
                + "model_thread=worker "
                + "render_ms=\(Self.milliseconds(renderEnded - renderStarted)) "
                + renderPhaseMetrics
                + "styled_markdown_during_render=\(styledMarkdownBlocksDuringRender) "
                + "appkit_materialized_after_layout=\(appKitMaterializedAfterLayout) "
                + "cached_markdown_after_layout=\(cachedMarkdownBlocksAfterInitialLayout) "
                + "cached_markdown_after_viewport=\(cachedMarkdownBlocksAfterViewport) "
                + "viewport_markdown_cache_growth=\(viewportMarkdownCacheGrowth) "
                + "initial_layout_ms=\(Self.milliseconds(initialLayoutEnded - renderEnded)) "
                + "initial_paint_ms=\(Self.milliseconds(initialLayoutEnded - renderStarted)) "
                + "materialize_ms=\(Self.milliseconds(materializeEnded - materializeStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - materializeEnded)) "
                + "fixture_first_paint_ms=\(Self.milliseconds(layoutEnded - renderStarted)) "
                + "elapsed_ms=\(Self.milliseconds(diagnosticEnded - renderStarted)) "
                + "row_mount_p50_ms="
                + Self.milliseconds(Self.percentile(rowMountDurations, 0.50)) + " "
                + "row_mount_p95_ms="
                + Self.milliseconds(Self.percentile(rowMountDurations, 0.95)) + " "
                + "scroll_p50_ms=\(Self.milliseconds(Self.percentile(scrollDurations, 0.50))) "
                + "scroll_p95_ms=\(Self.milliseconds(Self.percentile(scrollDurations, 0.95))) "
                + "renderer_delta_mb="
                + Self.megabytes(Self.positiveDifference(renderedMemory, baselineMemory))
        )

        XCTAssertLessThan(
            viewportRows.count,
            max(40, controller.renderedPresentationCount + 1),
            "the child transcript materialized an unexpectedly large working set"
        )
        XCTAssertEqual(
            styledMarkdownBlocksDuringRender,
            0,
            "presentation construction eagerly styled offscreen Markdown"
        )
        XCTAssertLessThanOrEqual(
            viewportMarkdownCacheGrowth,
            viewportRows.count,
            "the representative viewport styled more Markdown blocks than it requested"
        )
        XCTAssertLessThanOrEqual(
            cachedMarkdownBlocksAfterInitialLayout,
            appKitMaterializedAfterLayout,
            "initial layout styled Markdown blocks that AppKit had not materialized"
        )
#if DEBUG
        XCTAssertEqual(
            renderPhases.summaryRebuilds,
            1,
            "the child navigator rebuilt its rows more than once for one model update"
        )
#endif
    }

    func testDetachedConversationTreeRepaintsOnlyAfterMissingAGlobalSweep() {
        let detachedTree = NSView()
        detachedTree.addSubview(NSView())

        XCTAssertTrue(AppThemeRefresh.repaintIfNeeded(detachedTree))
        XCTAssertFalse(AppThemeRefresh.repaintIfNeeded(detachedTree))

        _ = NSApplication.shared
        AppThemeRefresh.repaintEverything()

        XCTAssertTrue(AppThemeRefresh.repaintIfNeeded(detachedTree))
        XCTAssertFalse(AppThemeRefresh.repaintIfNeeded(detachedTree))
    }

    func testSettledTurnVirtualizesFoldedWorkAndRestoresPresentation() throws {
        let session = AgentSession(kind: .codex, title: "Fold restoration", usesNativeUI: true)
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(
                name: "Fold restoration",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.viewportHeight
        )
        controller.isReplaying = true
        let events = Self.stressEvents(shape: .mixed, turns: 1)
        Self.apply(Array(events.prefix(2)), to: controller)

        XCTAssertEqual(controller.presentationItems.count, 6)
        XCTAssertTrue(controller.rowViews.isEmpty)

        Self.apply(Array(events.dropFirst(2)), to: controller)
        controller.finishReplayRendering()
        controller.view.layoutSubtreeIfNeeded()

        let foldRow = try XCTUnwrap(
            controller.presentationItems.firstIndex { $0.id == .fold(turnStart: 0) }
        )
        let foldHost = try XCTUnwrap(
            controller.tableView.view(atColumn: 0, row: foldRow, makeIfNecessary: true)
        )
        let fold = try XCTUnwrap(
            Self.firstDescendant(TurnFoldView.self, in: foldHost)
        )

        XCTAssertEqual(controller.presentationItems.count, 3)
        XCTAssertTrue((1...4).allSatisfy {
            controller.presentationRow(forTimelineIndex: $0) == nil
        })

        fold.setExpanded(true)
        XCTAssertEqual(controller.presentationItems.count, 7)
        XCTAssertTrue((1...4).allSatisfy {
            controller.presentationRow(forTimelineIndex: $0) != nil
        })
        XCTAssertTrue(controller.expandedTurnStarts.contains(0))

        fold.setExpanded(false)
        XCTAssertEqual(controller.presentationItems.count, 3)
        XCTAssertTrue((1...4).allSatisfy {
            controller.presentationRow(forTimelineIndex: $0) == nil
        })
        XCTAssertFalse(controller.expandedTurnStarts.contains(0))

        fold.setExpanded(true)
        XCTAssertEqual(controller.presentationItems.count, 7)
        XCTAssertTrue(controller.expandedTurnStarts.contains(0))
    }

    func testReplayFinishAttachesAnUnfinishedTail() {
        let session = AgentSession(kind: .codex, title: "Replay tail", usesNativeUI: true)
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(
                name: "Replay tail",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.isReplaying = true

        Self.apply(
            Array(Self.stressEvents(shape: .mixed, turns: 1).prefix(2)),
            to: controller
        )
        XCTAssertEqual(controller.presentationItems.count, 6)
        XCTAssertTrue(controller.rowViews.isEmpty)

        controller.finishReplayRendering()

        XCTAssertEqual(controller.tableView.numberOfRows, 6)
        XCTAssertTrue((0...5).allSatisfy {
            controller.presentationRow(forTimelineIndex: $0) != nil
        })
    }

    func testLargeReplayMaterializesOnlyViewportRowsAndCanJumpExactly() throws {
        let controller = requireConversationViewController(
            agentSession: AgentSession(
                kind: .codex,
                title: "Virtual conversation",
                usesNativeUI: true
            ),
            project: Project(
                name: "Virtual conversation",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.viewportHeight
        )
        controller.isReplaying = true
        Self.apply(Self.stressEvents(shape: .mixed, turns: 100), to: controller)
        controller.finishReplayRendering()
        controller.isReplaying = false
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(controller.presentationItems.count, 300)
        XCTAssertLessThan(
            controller.rowViews.count,
            40,
            "The virtual table materialized more than a viewport-sized working set"
        )

        let lastTurn = try XCTUnwrap(controller.timeline.turns.last)
        let targetRow = try XCTUnwrap(
            controller.presentationRow(forTimelineIndex: lastTurn.rowIndex)
        )
        controller.scrollToTimelineRow(lastTurn.rowIndex, animated: false)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            controller.tableView.rect(ofRow: targetRow)
                .intersects(controller.scrollView.contentView.documentVisibleRect)
        )
        XCTAssertNotNil(
            controller.rowViews[lastTurn.rowIndex],
            "The exact target row was not materialized after the deep jump"
        )
        XCTAssertLessThan(controller.rowViews.count, 40)
    }

    func testLiveMinimapAppendsAndSettlesOnlyTheTrailingTurn() {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .codex, title: "Live rail", usesNativeUI: true),
            project: Project(
                name: "Live rail",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view

        Self.apply([
            .userMessage("First question"),
            .assistantMessage(blocks: [.text("First answer")]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(duration: 1)
            )
        ], to: controller)

        XCTAssertEqual(controller.minimapTurnCount, 1)
        XCTAssertEqual(controller.lastMinimapTurn?.userText, "First question")
        XCTAssertEqual(controller.lastMinimapTurn?.assistantText, "First answer")
        XCTAssertEqual(controller.lastMinimapTurn?.duration, 1)

        Self.apply([.userMessage("Second question")], to: controller)

        XCTAssertEqual(controller.minimapTurnCount, 2)
        XCTAssertEqual(controller.lastMinimapTurn?.userText, "Second question")
        XCTAssertNil(controller.lastMinimapTurn?.assistantText)

        Self.apply([
            .assistantMessage(blocks: [.text("Second answer")]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(duration: 2)
            )
        ], to: controller)

        XCTAssertEqual(controller.minimapTurnCount, 2)
        XCTAssertEqual(controller.lastMinimapTurn?.assistantText, "Second answer")
        XCTAssertEqual(controller.lastMinimapTurn?.duration, 2)
    }

    private enum StressShape: String {
        case prose
        case mixed
        case toolHeavy = "tool-heavy"
    }

    private func runConversationResidencyStress(
        shape: StressShape,
        sessionCount: Int,
        turns: Int
    ) {
        let events = Self.stressEvents(shape: shape, turns: turns)
        let baselineMemory = Self.physicalFootprintBytes()
        var peakMemory = baselineMemory
        var buildDurations: [UInt64] = []
        var controllers: [ConversationViewController] = []
        controllers.reserveCapacity(sessionCount)

        for sessionIndex in 0..<sessionCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let session = AgentSession(
                kind: .codex,
                title: "Resident conversation \(sessionIndex)",
                usesNativeUI: true
            )
            let controller = requireConversationViewController(
                agentSession: session,
                project: Project(
                    name: "Resident project \(sessionIndex)",
                    folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                ),
                customizationLookup: { _ in .empty }
            )
            _ = controller.view
            controller.view.frame = NSRect(
                x: 0,
                y: 0,
                width: Render.width,
                height: Render.viewportHeight
            )
            controller.isReplaying = true
            Self.apply(events, to: controller)
            controller.finishReplayRendering()
            controller.isReplaying = false
            controller.refreshMinimap()
            controller.view.layoutSubtreeIfNeeded()
            buildDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            controllers.append(controller)
            peakMemory = max(peakMemory, Self.physicalFootprintBytes())
        }

        let memoryAfterBuild = Self.physicalFootprintBytes()
        let host = NSViewController()
        host.view = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.viewportHeight
        ))
        var current: ConversationViewController?
        var detachDurations: [UInt64] = []
        var reparentDurations: [UInt64] = []
        var repaintDurations: [UInt64] = []
        var layoutDurations: [UInt64] = []

        func install(_ controller: ConversationViewController) {
            host.addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: host.view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor)
            ])
        }

        func detachCurrent() {
            current?.view.removeFromSuperview()
            current?.removeFromParent()
            current = nil
        }

        func attach(
            _ controller: ConversationViewController,
            recordPhases: Bool = false
        ) -> UInt64 {
            let started = DispatchTime.now().uptimeNanoseconds
            detachCurrent()
            let detached = DispatchTime.now().uptimeNanoseconds
            install(controller)
            let reparented = DispatchTime.now().uptimeNanoseconds
            AppThemeRefresh.repaintIfNeeded(controller.view)
            let repainted = DispatchTime.now().uptimeNanoseconds
            host.view.layoutSubtreeIfNeeded()
            let laidOut = DispatchTime.now().uptimeNanoseconds
            current = controller
            if recordPhases {
                detachDurations.append(detached - started)
                reparentDurations.append(reparented - detached)
                repaintDurations.append(repainted - reparented)
                layoutDurations.append(laidOut - repainted)
            }
            return laidOut - started
        }

        // One unmeasured pass pays any process-global AppKit and theme-cache setup. Later passes
        // are the ordinary hot sidebar switch between already-resident conversations.
        for controller in controllers { _ = attach(controller) }

        var switchDurations: [UInt64] = []
        for _ in 0..<3 {
            for controller in controllers {
                switchDurations.append(attach(controller, recordPhases: true))
            }
        }
        peakMemory = max(peakMemory, Self.physicalFootprintBytes())

        var deepJumpDurations: [UInt64] = []
        for controller in controllers {
            _ = attach(controller)
            guard let lastTurn = controller.timeline.turns.last else { continue }
            let started = DispatchTime.now().uptimeNanoseconds
            controller.scrollToTimelineRow(lastTurn.rowIndex, animated: false)
            host.view.layoutSubtreeIfNeeded()
            deepJumpDurations.append(DispatchTime.now().uptimeNanoseconds - started)
        }

        // Every update is deliberately off-screen. Production still mutates its retained model
        // and views, but does not lay the detached hierarchy out until the session is selected.
        detachCurrent()
        var backgroundUpdateDurations: [UInt64] = []
        for (sessionIndex, controller) in controllers.enumerated() {
            let started = DispatchTime.now().uptimeNanoseconds
            Self.apply(Self.residencyAppendEvents(sessionIndex: sessionIndex), to: controller)
            backgroundUpdateDurations.append(DispatchTime.now().uptimeNanoseconds - started)
        }

        var postUpdateSwitchDurations: [UInt64] = []
        for controller in controllers {
            postUpdateSwitchDurations.append(attach(controller))
        }
        let memoryAfterUpdates = Self.physicalFootprintBytes()
        peakMemory = max(peakMemory, memoryAfterUpdates)

        let totalRows = controllers.reduce(0) { $0 + $1.timeline.rows.count }
        let materializedRows = controllers.reduce(0) { $0 + $1.rowViews.count }
        let presentedRows = controllers.reduce(0) { $0 + $1.presentationItems.count }
        let cachedHeights = controllers.reduce(0) { $0 + $1.rowHeightCache.count }
        let descendants = controllers.reduce(0) { $0 + Self.descendantCount(in: $1.view) }
        detachCurrent()
        XCTAssertEqual(host.children.count, 0)
        XCTAssertFalse(buildDurations.isEmpty)
        XCTAssertFalse(switchDurations.isEmpty)

        print(
            "THREADING_PERF conversation-residency "
                + "shape=\(shape.rawValue) sessions=\(sessionCount) turns=\(turns) "
                + "rows=\(totalRows) materialized=\(materializedRows) "
                + "presented=\(presentedRows) cached_heights=\(cachedHeights) "
                + "descendants=\(descendants) "
                + "build_total_ms=\(Self.milliseconds(buildDurations.reduce(0, +))) "
                + "build_p95_ms=\(Self.milliseconds(Self.percentile(buildDurations, 0.95))) "
                + "switches=\(switchDurations.count) "
                + "switch_p50_ms=\(Self.milliseconds(Self.percentile(switchDurations, 0.50))) "
                + "switch_p95_ms=\(Self.milliseconds(Self.percentile(switchDurations, 0.95))) "
                + "switch_max_ms=\(Self.milliseconds(switchDurations.max() ?? 0)) "
                + "detach_p95_ms=\(Self.milliseconds(Self.percentile(detachDurations, 0.95))) "
                + "reparent_p95_ms="
                + Self.milliseconds(Self.percentile(reparentDurations, 0.95)) + " "
                + "repaint_p95_ms="
                + Self.milliseconds(Self.percentile(repaintDurations, 0.95)) + " "
                + "layout_p95_ms="
                + Self.milliseconds(Self.percentile(layoutDurations, 0.95)) + " "
                + "background_update_p95_ms="
                + Self.milliseconds(Self.percentile(backgroundUpdateDurations, 0.95)) + " "
                + "post_update_switch_p95_ms="
                + Self.milliseconds(Self.percentile(postUpdateSwitchDurations, 0.95)) + " "
                + "deep_jump_p95_ms="
                + Self.milliseconds(Self.percentile(deepJumpDurations, 0.95)) + " "
                + "baseline_mb=\(Self.megabytes(baselineMemory)) "
                + "after_build_mb=\(Self.megabytes(memoryAfterBuild)) "
                + "peak_mb=\(Self.megabytes(peakMemory)) "
                + "resident_delta_mb="
                + Self.megabytes(Self.positiveDifference(peakMemory, baselineMemory))
        )
    }

    private func runConversationStress(shape: StressShape, turns: Int) {
        let baselineMemory = Self.physicalFootprintBytes()
        let events = Self.stressEvents(shape: shape, turns: turns)
        let fixtureMemory = Self.physicalFootprintBytes()

        var modelTimeline = ConversationTimeline(sessionID: SessionID())
        let modelStarted = DispatchTime.now().uptimeNanoseconds
        for event in events { _ = modelTimeline.apply(event) }
        let modelElapsed = DispatchTime.now().uptimeNanoseconds - modelStarted
        let modelMemory = Self.physicalFootprintBytes()

        let session = AgentSession(kind: .codex, title: "Conversation stress", usesNativeUI: true)
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(
                name: "Conversation stress",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.viewportHeight
        )
        controller.view.layoutSubtreeIfNeeded()
        controller.isReplaying = true
        let rendererBaselineMemory = Self.physicalFootprintBytes()

        let replayStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply(events, to: controller)
        let presentationEnded = DispatchTime.now().uptimeNanoseconds
        controller.finishReplayRendering()
        let reloadEnded = DispatchTime.now().uptimeNanoseconds
        controller.refreshMinimap()
        let replayEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds
        let renderedMemory = Self.physicalFootprintBytes()

        let rowCount = controller.timeline.rows.count
        let materializedRowCount = controller.rowViews.count
        let presentedCount = controller.presentationItems.count
        let cachedHeightCount = controller.rowHeightCache.count
        let descendantCount = Self.descendantCount(in: controller.view)
        XCTAssertEqual(controller.minimapTurnCount, turns)
        print(
            "THREADING_PERF conversation-replay "
                + "shape=\(shape.rawValue) turns=\(turns) events=\(events.count) "
                + "rows=\(rowCount) materialized=\(materializedRowCount) "
                + "presented=\(presentedCount) minimap_turns=\(controller.minimapTurnCount) "
                + "cached_heights=\(cachedHeightCount) "
                + "descendants=\(descendantCount) "
                + "model_ms=\(Self.milliseconds(modelElapsed)) "
                + "presentation_ms="
                + Self.milliseconds(presentationEnded - replayStarted) + " "
                + "reload_ms=\(Self.milliseconds(reloadEnded - presentationEnded)) "
                + "minimap_ms=\(Self.milliseconds(replayEnded - reloadEnded)) "
                + "render_ms=\(Self.milliseconds(replayEnded - replayStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - replayEnded)) "
                + "elapsed_ms=\(Self.milliseconds(layoutEnded - replayStarted)) "
                + "baseline_mb=\(Self.megabytes(baselineMemory)) "
                + "fixture_mb=\(Self.megabytes(fixtureMemory)) "
                + "model_mb=\(Self.megabytes(modelMemory)) "
                + "rendered_mb=\(Self.megabytes(renderedMemory)) "
                + "renderer_delta_mb="
                + Self.megabytes(Self.positiveDifference(
                    renderedMemory,
                    rendererBaselineMemory
                ))
        )

        if let lastTurn = controller.timeline.turns.last {
            let targetRow = controller.presentationRow(forTimelineIndex: lastTurn.rowIndex)
            let jumpStarted = DispatchTime.now().uptimeNanoseconds
            controller.scrollToTimelineRow(lastTurn.rowIndex, animated: false)
            controller.view.layoutSubtreeIfNeeded()
            let jumpElapsed = DispatchTime.now().uptimeNanoseconds - jumpStarted
            print(
                "THREADING_PERF conversation-deep-jump "
                    + "shape=\(shape.rawValue) turns=\(turns) target_row=\(lastTurn.rowIndex) "
                    + "elapsed_ms=\(Self.milliseconds(jumpElapsed))"
            )
            if let targetRow {
                XCTAssertTrue(
                    controller.tableView.rect(ofRow: targetRow)
                        .intersects(controller.scrollView.contentView.documentVisibleRect),
                    "the exact deepest turn did not land in the viewport"
                )
                XCTAssertNotNil(
                    controller.rowViews[lastTurn.rowIndex],
                    "the exact deepest turn was not materialized after its jump"
                )
            } else {
                XCTFail("the deepest turn had no presentation row")
            }
        }

        XCTAssertLessThan(
            controller.rowViews.count,
            40,
            "a massive conversation materialized more than a viewport-sized working set"
        )

        controller.isReplaying = false
        let liveTurn = turns
        let liveIDs = (0..<8).map { "live-\(shape.rawValue)-\(liveTurn)-\($0)" }
        var liveBlocks: [ContentBlock] = [
            .thinking("Checking the last incremental path before replying.")
        ]
        liveBlocks.append(contentsOf: liveIDs.enumerated().map { index, id in
            .toolUse(
                id: id,
                tool: index.isMultiple(of: 2) ? .read : .bash,
                input: index.isMultiple(of: 2)
                    ? ["file_path": .string("Sources/Generated/Live\(index).swift")]
                    : ["command": .string("swift test --filter LiveCase\(index)")]
            )
        })
        liveBlocks.append(.text("The incremental update completed and the pane stayed responsive."))

        let appendStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply([
            .userMessage("Run one more deep incremental check."),
            .assistantMessage(blocks: liveBlocks)
        ], to: controller)
        controller.view.layoutSubtreeIfNeeded()
        let appendElapsed = DispatchTime.now().uptimeNanoseconds - appendStarted
        XCTAssertEqual(controller.minimapTurnCount, turns + 1)
        XCTAssertEqual(controller.lastMinimapTurn?.userText, "Run one more deep incremental check.")
        print(
            "THREADING_PERF conversation-incremental-append "
                + "shape=\(shape.rawValue) base_turns=\(turns) added_rows=11 "
                + "elapsed_ms=\(Self.milliseconds(appendElapsed))"
        )

        let foldStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply([
            .toolResults(liveIDs.enumerated().map { index, id in
                ToolResult(
                    toolUseID: id,
                    text: index.isMultiple(of: 2)
                        ? "struct LiveCase\(index) {}"
                        : "Test Suite 'LiveCase\(index)' passed",
                    isError: false
                )
            }),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 1.25,
                    outputTokens: 128,
                    effort: "high",
                    contextTokens: 24_000,
                    contextWindow: 200_000
                )
            )
        ], to: controller)
        controller.view.layoutSubtreeIfNeeded()
        let foldElapsed = DispatchTime.now().uptimeNanoseconds - foldStarted
        XCTAssertEqual(
            controller.lastMinimapTurn?.assistantText,
            "The incremental update completed and the pane stayed responsive."
        )
        print(
            "THREADING_PERF conversation-result-and-fold "
                + "shape=\(shape.rawValue) base_turns=\(turns) folded_rows=9 "
                + "elapsed_ms=\(Self.milliseconds(foldElapsed))"
        )

        Self.apply([.userMessage("Stream a deterministic long response.")], to: controller)
        let streamStarted = DispatchTime.now().uptimeNanoseconds
        for index in 0..<250 {
            Self.apply([
                .textDelta(" chunk-\(index) with stable text for native label measurement")
            ], to: controller)
        }
        controller.view.layoutSubtreeIfNeeded()
        let streamElapsed = DispatchTime.now().uptimeNanoseconds - streamStarted
        print(
            "THREADING_PERF conversation-stream-update "
                + "shape=\(shape.rawValue) base_turns=\(turns) deltas=250 "
                + "characters=\(controller.timeline.streamingText.count) "
                + "elapsed_ms=\(Self.milliseconds(streamElapsed))"
        )

        XCTAssertEqual(controller.timeline.rows.count, modelTimeline.rows.count + 12)
    }

    private func runActiveTurnStress(baseTurns: Int, toolCount: Int) {
        let controller = requireConversationViewController(
            agentSession: AgentSession(
                kind: .codex,
                title: "Active turn stress",
                usesNativeUI: true
            ),
            project: Project(
                name: "Active turn stress",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: Render.width,
            height: Render.viewportHeight
        )
        controller.view.layoutSubtreeIfNeeded()
        controller.isReplaying = true
        Self.apply(Self.stressEvents(shape: .mixed, turns: baseTurns), to: controller)
        controller.finishReplayRendering()
        controller.isReplaying = false
        controller.refreshMinimap()
        controller.view.layoutSubtreeIfNeeded()

        let baseRows = controller.timeline.rows.count
        let basePresented = controller.presentationItems.count
        let baselineMemory = Self.physicalFootprintBytes()
        var peakMemory = baselineMemory
        let activeStartIndex = baseRows

        let userStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply([
            .userMessage("Run a deliberately broad active-turn workload without folding it early.")
        ], to: controller)
        controller.view.layoutSubtreeIfNeeded()
        let userElapsed = DispatchTime.now().uptimeNanoseconds - userStarted

        let toolIDs = (0..<toolCount).map { "active-stress-\($0)" }
        let batchSize = 10
        var appendDurations: [UInt64] = []
        for start in stride(from: 0, to: toolCount, by: batchSize) {
            let end = min(start + batchSize, toolCount)
            let blocks = (start..<end).map { index in
                Self.activeToolBlock(index: index, id: toolIDs[index])
            }
            let started = DispatchTime.now().uptimeNanoseconds
            Self.apply([.assistantMessage(blocks: blocks)], to: controller)
            controller.view.layoutSubtreeIfNeeded()
            appendDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            peakMemory = max(peakMemory, Self.physicalFootprintBytes())
        }

        let activeRows = controller.timeline.rows.count
        let activePresented = controller.presentationItems.count
        XCTAssertEqual(activeRows, baseRows + toolCount + 1)
        XCTAssertEqual(activePresented, basePresented + toolCount + 2)
        XCTAssertEqual(controller.minimapTurnCount, baseTurns + 1)
        XCTAssertLessThan(
            controller.rowViews.count,
            40,
            "an unfolded active turn materialized more than a viewport"
        )

        let targetTimelineRow = activeStartIndex + 1 + toolCount / 2
        guard let targetPresentationRow = controller.presentationRow(
            forTimelineIndex: targetTimelineRow
        ) else {
            XCTFail("the middle active tool had no presentation identity")
            return
        }
        let jumpStarted = DispatchTime.now().uptimeNanoseconds
        let jumpMeasurements = controller.scrollToTimelineRow(
            targetTimelineRow,
            animated: false
        )
        controller.view.layoutSubtreeIfNeeded()
        let jumpElapsed = DispatchTime.now().uptimeNanoseconds - jumpStarted
        XCTAssertNotNil(jumpMeasurements)
        XCTAssertTrue(
            controller.tableView.rect(ofRow: targetPresentationRow)
                .intersects(controller.scrollView.contentView.documentVisibleRect),
            "the exact middle active tool did not land in the viewport"
        )
        XCTAssertNotNil(
            controller.rowViews[targetTimelineRow],
            "the exact middle active tool was not materialized"
        )
        let targetRowHeight = controller.tableView.rect(ofRow: targetPresentationRow).height
        let activeMaterialized = controller.rowViews.count

        let streamStarted = DispatchTime.now().uptimeNanoseconds
        for index in 0..<250 {
            Self.apply([
                .textDelta(" active-chunk-\(index) with deterministic streaming content")
            ], to: controller)
        }
        controller.view.layoutSubtreeIfNeeded()
        let streamElapsed = DispatchTime.now().uptimeNanoseconds - streamStarted
        XCTAssertEqual(controller.presentationItems.count, activePresented + 1)
        peakMemory = max(peakMemory, Self.physicalFootprintBytes())

        var resultDurations: [UInt64] = []
        let reversedIDs = Array(toolIDs.reversed())
        for start in stride(from: 0, to: toolCount, by: batchSize) {
            let end = min(start + batchSize, toolCount)
            let results = reversedIDs[start..<end].map { id in
                ToolResult(
                    toolUseID: id,
                    text: "Completed deterministic active-turn work for \(id).",
                    isError: false
                )
            }
            let started = DispatchTime.now().uptimeNanoseconds
            Self.apply([.toolResults(Array(results))], to: controller)
            controller.view.layoutSubtreeIfNeeded()
            resultDurations.append(DispatchTime.now().uptimeNanoseconds - started)
            peakMemory = max(peakMemory, Self.physicalFootprintBytes())
        }
        for index in (activeStartIndex + 1)..<(activeStartIndex + 1 + toolCount) {
            guard case .toolCall(let call) = controller.timeline.rows[index] else {
                XCTFail("active row \(index) was not a tool call")
                return
            }
            XCTAssertNotNil(call.result, "active tool \(index) lost its result")
        }
        let activePeakMemory = peakMemory

        let finalAnswer = "The broad active-turn workload completed without losing a tool row."
        let finalAssistantIndex = controller.timeline.rows.count
        let settleStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply([
            .assistantMessage(blocks: [.text(finalAnswer)]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 12.5,
                    outputTokens: 512,
                    effort: "high",
                    contextTokens: 48_000,
                    contextWindow: 200_000
                )
            )
        ], to: controller)
        controller.view.layoutSubtreeIfNeeded()
        let settleElapsed = DispatchTime.now().uptimeNanoseconds - settleStarted
        let settledMemory = Self.physicalFootprintBytes()

        XCTAssertTrue(controller.foldedTurnStarts.contains(activeStartIndex))
        XCTAssertNil(
            controller.presentationRow(forTimelineIndex: targetTimelineRow),
            "settlement left a folded tool addressable in the presentation"
        )
        XCTAssertEqual(controller.presentationItems.count, basePresented + 4)
        XCTAssertEqual(controller.lastMinimapTurn?.assistantText, finalAnswer)
        XCTAssertLessThan(controller.rowViews.count, 40)

        guard let finalPresentationRow = controller.presentationRow(
            forTimelineIndex: finalAssistantIndex
        ) else {
            XCTFail("the final active-turn answer had no presentation identity")
            return
        }
        let finalJumpStarted = DispatchTime.now().uptimeNanoseconds
        controller.scrollToTimelineRow(finalAssistantIndex, animated: false)
        controller.view.layoutSubtreeIfNeeded()
        let finalJumpElapsed = DispatchTime.now().uptimeNanoseconds - finalJumpStarted
        XCTAssertTrue(
            controller.tableView.rect(ofRow: finalPresentationRow)
                .intersects(controller.scrollView.contentView.documentVisibleRect),
            "the final active-turn answer did not land in the viewport"
        )
        XCTAssertNotNil(controller.rowViews[finalAssistantIndex])

        print(
            "THREADING_PERF conversation-active-build "
                + "base_turns=\(baseTurns) tools=\(toolCount) batch_size=\(batchSize) "
                + "base_rows=\(baseRows) active_rows=\(activeRows) "
                + "presented=\(activePresented) materialized=\(activeMaterialized) "
                + "batches=\(appendDurations.count) "
                + "user_ms=\(Self.milliseconds(userElapsed)) "
                + "append_total_ms=\(Self.milliseconds(appendDurations.reduce(0, +))) "
                + "append_p50_ms="
                + Self.milliseconds(Self.percentile(appendDurations, 0.50)) + " "
                + "append_p95_ms="
                + Self.milliseconds(Self.percentile(appendDurations, 0.95)) + " "
                + "append_max_ms=\(Self.milliseconds(appendDurations.max() ?? 0)) "
                + "middle_jump_ms=\(Self.milliseconds(jumpElapsed)) "
                + "jump_target_height=\(String(format: "%.1f", targetRowHeight)) "
                + "jump_geometry_ms="
                + Self.milliseconds(jumpMeasurements?.geometryNanoseconds ?? 0) + " "
                + "jump_layout_ms="
                + Self.milliseconds(jumpMeasurements?.landingLayoutNanoseconds ?? 0) + " "
                + "jump_correction_ms="
                + Self.milliseconds(jumpMeasurements?.correctionNanoseconds ?? 0) + " "
                + "jump_visible_turns_ms="
                + Self.milliseconds(jumpMeasurements?.visibleTurnsNanoseconds ?? 0) + " "
                + "jump_measured_total_ms="
                + Self.milliseconds(jumpMeasurements?.totalNanoseconds ?? 0) + " "
                + "stream_deltas=250 stream_ms=\(Self.milliseconds(streamElapsed)) "
                + "baseline_mb=\(Self.megabytes(baselineMemory)) "
                + "peak_mb=\(Self.megabytes(activePeakMemory)) "
                + "active_delta_mb="
                + Self.megabytes(Self.positiveDifference(activePeakMemory, baselineMemory))
        )
        print(
            "THREADING_PERF conversation-active-results "
                + "base_turns=\(baseTurns) tools=\(toolCount) batches=\(resultDurations.count) "
                + "result_total_ms=\(Self.milliseconds(resultDurations.reduce(0, +))) "
                + "result_p50_ms="
                + Self.milliseconds(Self.percentile(resultDurations, 0.50)) + " "
                + "result_p95_ms="
                + Self.milliseconds(Self.percentile(resultDurations, 0.95)) + " "
                + "result_max_ms=\(Self.milliseconds(resultDurations.max() ?? 0))"
        )
        print(
            "THREADING_PERF conversation-active-settle "
                + "base_turns=\(baseTurns) tools=\(toolCount) "
                + "settle_ms=\(Self.milliseconds(settleElapsed)) "
                + "rows=\(controller.timeline.rows.count) "
                + "presented=\(controller.presentationItems.count) "
                + "materialized=\(controller.rowViews.count) "
                + "final_jump_ms=\(Self.milliseconds(finalJumpElapsed)) "
                + "settled_delta_mb="
                + Self.megabytes(Self.positiveDifference(settledMemory, baselineMemory))
        )
    }

    private static func activeToolBlock(index: Int, id: String) -> ContentBlock {
        switch index % 3 {
        case 0:
            return .toolUse(
                id: id,
                tool: .read,
                input: [
                    "file_path": .string("Sources/Active/Feature\(index)/Case.swift")
                ]
            )
        case 1:
            return .toolUse(
                id: id,
                tool: .bash,
                input: ["command": .string("swift test --filter ActiveCase\(index)")]
            )
        default:
            return .toolUse(
                id: id,
                tool: .edit,
                input: [
                    "file_path": .string("Sources/Active/Feature\(index)/Case.swift"),
                    "old_string": .string("let value = \(index)"),
                    "new_string": .string("let value = \(index + 1)")
                ]
            )
        }
    }

    private static func stressEvents(shape: StressShape, turns: Int) -> [StreamEvent] {
        var events: [StreamEvent] = []
        events.reserveCapacity(turns * 4)

        for turn in 0..<turns {
            events.append(.userMessage(
                "Turn \(turn): inspect the deterministic renderer workload and summarize the result."
            ))

            let toolCount: Int
            switch shape {
            case .prose: toolCount = 0
            case .mixed: toolCount = 3
            case .toolHeavy: toolCount = 8
            }

            var blocks: [ContentBlock] = []
            if shape != .prose {
                blocks.append(.thinking(
                    "Reasoning through turn \(turn), its inputs, constraints, and expected output."
                ))
            }

            let toolIDs = (0..<toolCount).map { "stress-\(shape.rawValue)-\(turn)-\($0)" }
            for (index, id) in toolIDs.enumerated() {
                switch index % 3 {
                case 0:
                    blocks.append(.toolUse(
                        id: id,
                        tool: .read,
                        input: [
                            "file_path": .string("Sources/Generated/Feature\(turn)/Case\(index).swift")
                        ]
                    ))
                case 1:
                    blocks.append(.toolUse(
                        id: id,
                        tool: .bash,
                        input: ["command": .string("swift test --filter Stress\(turn)_\(index)")]
                    ))
                default:
                    blocks.append(.toolUse(
                        id: id,
                        tool: .edit,
                        input: [
                            "file_path": .string("Sources/Generated/Feature\(turn)/Case\(index).swift"),
                            "old_string": .string("let value = \(turn)"),
                            "new_string": .string("let value = \(turn + index + 1)")
                        ]
                    ))
                }
            }

            let paragraphCount = shape == .prose ? 6 : 2
            let markdown = (0..<paragraphCount).map { paragraph in
                "### Turn \(turn), section \(paragraph)\n\n"
                    + "The deterministic native-renderer workload keeps wrapping, Markdown "
                    + "layout, selection, and retained row constraints representative. "
                    + "It is generated locally and performs no provider or network work."
            }.joined(separator: "\n\n")
            blocks.append(.text(markdown))
            events.append(.assistantMessage(blocks: blocks))

            if !toolIDs.isEmpty {
                events.append(.toolResults(toolIDs.enumerated().map { index, id in
                    ToolResult(
                        toolUseID: id,
                        text: index.isMultiple(of: 2)
                            ? "Read 48 lines from deterministic fixture \(turn)-\(index)."
                            : "Test Suite 'Stress\(turn)_\(index)' passed.",
                        isError: false
                    )
                }))
            }
            events.append(.turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: Double(turn + 1) / 10,
                    outputTokens: 96 + turn,
                    effort: "high",
                    contextTokens: 8_000 + turn * 320,
                    contextWindow: 200_000
                )
            ))
        }

        return events
    }

    private static func residencyAppendEvents(sessionIndex: Int) -> [StreamEvent] {
        let toolIDs = (0..<4).map { "resident-\(sessionIndex)-\($0)" }
        var blocks: [ContentBlock] = [
            .thinking("Checking the retained conversation before presenting its next result.")
        ]
        blocks.append(contentsOf: toolIDs.enumerated().map { index, id in
            .toolUse(
                id: id,
                tool: index.isMultiple(of: 2) ? .read : .bash,
                input: index.isMultiple(of: 2)
                    ? ["file_path": .string("Sources/Resident/Case\(sessionIndex)-\(index).swift")]
                    : ["command": .string("swift test --filter Resident\(sessionIndex)_\(index)")]
            )
        })
        blocks.append(.text("The background update completed and is ready when this chat returns."))

        return [
            .userMessage("Run one retained-session background check."),
            .assistantMessage(blocks: blocks),
            .toolResults(toolIDs.map { id in
                ToolResult(toolUseID: id, text: "Completed deterministic resident work.", isError: false)
            }),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 0.75,
                    outputTokens: 96,
                    effort: "high",
                    contextTokens: 32_000,
                    contextWindow: 200_000
                )
            )
        ]
    }

    private static func apply(
        _ events: [StreamEvent],
        to controller: ConversationViewController
    ) {
        for event in events {
            for change in controller.timeline.apply(event) {
                controller.apply(change)
            }
        }
    }

    private static func descendantCount(in root: NSView) -> Int {
        var count = 0
        var pending = root.subviews
        while let view = pending.popLast() {
            count += 1
            pending.append(contentsOf: view.subviews)
        }
        return count
    }

    private static func descendants(in root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = root.subviews
        while let view = pending.popLast() {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstDescendant(type, in: child) { return match }
        }
        return nil
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func positiveDifference(_ larger: UInt64, _ smaller: UInt64) -> UInt64 {
        larger >= smaller ? larger - smaller : 0
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
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

    func testHandoffDividerRendersWithinTheConversationColumn() throws {
        let kinds: [AgentKind] = [.claude, .codex, .grok, .openCode]
        let endpoints = kinds.enumerated().map { index, kind in
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: kind,
                model: "provider/model-with-a-deliberately-long-name-\(index)",
                title: "Hop \(index)"
            )
        }
        let handoff = try XCTUnwrap(ConversationHandoff(endpoints: endpoints))
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var payload: Data?
            let render = {
                let divider = ConversationHandoffView(
                    handoff: handoff,
                    canOpenSource: true,
                    onOpenSource: { _ in }
                )
                let host = NSView(frame: NSRect(
                    x: 0,
                    y: 0,
                    width: Design.Size.readableWidth,
                    height: 1
                ))
                host.appearance = appearance
                divider.appearance = appearance
                host.addSubview(divider)
                NSLayoutConstraint.activate([
                    divider.topAnchor.constraint(equalTo: host.topAnchor),
                    divider.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                host.layoutSubtreeIfNeeded()
                host.frame.size.height = divider.fittingSize.height
                host.layoutSubtreeIfNeeded()

                XCTAssertGreaterThan(host.frame.height, 0)
                XCTAssertLessThanOrEqual(divider.frame.maxX, Design.Size.readableWidth + 1)
                XCTAssertTrue(divider.accessibilityLabel()?.contains("Context handoff") == true)
                payload = self.png(of: host)
            }
            appearance?.performAsCurrentDrawingAppearance(render)
            let data = try XCTUnwrap(payload, "Failed to render handoff divider in \(name)")
            try data.write(to: directory.appendingPathComponent("handoff-divider-\(name).png"))
        }
    }

    // MARK: - Long User Messages

    func testTheCollapseThresholdCountsCharactersAndHardLines() {
        XCTAssertFalse(ConversationDefaults.collapsesUserMessage("Fix the bug"))
        XCTAssertTrue(ConversationDefaults.collapsesUserMessage(
            String(repeating: "a", count: ConversationDefaults.longMessageCharacterCap + 1)
        ))
        XCTAssertTrue(ConversationDefaults.collapsesUserMessage(
            Array(repeating: "line", count: ConversationDefaults.longMessageLineCap + 1)
                .joined(separator: "\n")
        ))
        XCTAssertFalse(ConversationDefaults.collapsesUserMessage(
            Array(repeating: "line", count: ConversationDefaults.longMessageLineCap)
                .joined(separator: "\n")
        ))
    }

    func testALongUserMessageRendersCollapsedAndBounded() throws {
        // Twenty pasted lines must not become a twenty-line banner: the collapsed bubble caps
        // at eight rendered lines plus its footer, whatever the message holds.
        let long = (1...20).map { "Pasted log line \($0): something happened here" }
            .joined(separator: "\n")
        let short = "Fix the flaky test"

        let stack = laidOut([.userMessage(long), .userMessage(short)], width: Render.width)
        let rows = stack.arrangedSubviews.filter { !($0 is NSBox) }

        let collapsed = try XCTUnwrap(rows.first?.subviews.first, "The long bubble went missing")
        XCTAssertTrue(collapsed is UserMessageBubbleView, "A long message drew the plain bubble")

        // Generous cap: eight body lines, the footer, and padding — but nowhere near twenty
        // lines, which would be ~380pt.
        XCTAssertLessThan(collapsed.frame.height, 230, "The long bubble did not collapse")

        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = png(of: stack.superview ?? stack) {
            try data.write(to: directory.appendingPathComponent("long-user-message.png"))
        }
    }

    // MARK: - Changed Files Card

    /// The per-turn changed-files card, drawn from a synthetic tree: indentation, folder
    /// rows, per-node ±counts and the header actions are all appearance work no assertion
    /// would catch.
    func testRendersTheChangedFilesCard() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Five files on purpose: at the auto-expand cap, so the card draws its whole tree —
        // a sixth would (correctly) start it collapsed and the picture would show five rows.
        let tree = ChangedFilesTree.build(from: [
            ChangedFilesTree.File(path: "public/robots.txt", added: 4, removed: 0),
            ChangedFilesTree.File(path: "src/layouts/BaseLayout.astro", added: 1, removed: 8),
            ChangedFilesTree.File(path: "src/lib/constants.ts", added: 9, removed: 0),
            ChangedFilesTree.File(path: "src/pages/index.astro", added: 2, removed: 8),
            ChangedFilesTree.File(path: "astro.config.mjs", added: 3, removed: 1)
        ])

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let card = ChangedFilesCardView(tree: tree, onViewDiff: {})
                let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
                host.addSubview(card)
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: host.topAnchor),
                    card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    card.widthAnchor.constraint(equalToConstant: Render.width)
                ])
                host.appearance = appearance
                card.appearance = appearance
                host.layoutSubtreeIfNeeded()
                host.frame.size.height = card.fittingSize.height
                host.layoutSubtreeIfNeeded()

                // Every row of a seven-file tree is on screen: the fixture is small enough to
                // auto-expand, so a short card means rows collapsed that should not have.
                XCTAssertGreaterThan(host.frame.height, 150, "The card rendered collapsed")
                data = self.png(of: host)
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let payload = try XCTUnwrap(data, "Failed to render the changed-files card in \(name)")
            try payload.write(to: directory.appendingPathComponent("changed-files-card-\(name).png"))
        }
    }

    /// The preview a file row raises under the pointer: the path, its ±counts, and the change
    /// itself. Washes, gutters and the code face against the popover's own surface are all
    /// appearance work, and this is the only place they are reviewed.
    func testRendersTheChangedFileDiffPreview() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = GitFileDiff(
            path: "Sources/Threading/Core/Remote/RemoteAccessTypes.swift",
            change: .modified,
            hunks: [GitHunk(
                header: "@@ -210,6 +210,11 @@",
                lines: [
                    .init(kind: .context, text: "    func authorization(forToken token: String) -> RemoteAuthorization?", oldNumber: 210, newNumber: 210),
                    .init(kind: .context, text: "", oldNumber: 211, newNumber: 211),
                    .init(kind: .added, text: "    /// Revalidates an authorization captured by an already-authenticated connection.", newNumber: 212),
                    .init(kind: .added, text: "    /// Socket closure is asynchronous, so every operation that crosses to another", newNumber: 213),
                    .init(kind: .added, text: "    /// session checks this immediately before reading or mutating session state.", newNumber: 214),
                    .init(kind: .added, text: "    func isCurrent(_ authorization: RemoteAuthorization) -> Bool", newNumber: 215),
                    .init(kind: .removed, text: "    func stale(_ authorization: RemoteAuthorization) -> Bool", oldNumber: 212),
                    .init(kind: .context, text: "}", oldNumber: 213, newNumber: 216)
                ]
            )],
            added: 4,
            removed: 1
        )
        let card = ChangedFilesCardView(
            tree: ChangedFilesTree.build(from: [
                ChangedFilesTree.File(path: file.path, added: file.added, removed: file.removed)
            ]),
            previews: ChangedFileDiffPreview.previews(from: [file]),
            onViewDiff: {}
        )

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let surface = card.makePreviewSurface(
                    for: ChangedFileDiffPreview.preview(of: file)
                )
                let host = NSView()
                host.addSubview(surface.view)
                NSLayoutConstraint.activate([
                    surface.view.topAnchor.constraint(equalTo: host.topAnchor),
                    surface.view.leadingAnchor.constraint(equalTo: host.leadingAnchor)
                ])
                // The popover paints a surface behind this content; the fixture stands in for
                // it, or the diff draws onto transparency. It has to be a colour that follows
                // the *drawing* appearance — a palette role resolves against the running app's
                // instead, which painted a light ground under dark-resolved text and rendered
                // every unwashed line invisible.
                host.appearance = appearance
                surface.view.appearance = appearance
                host.frame = NSRect(origin: .zero, size: surface.view.fittingSize)
                host.layoutSubtreeIfNeeded()

                XCTAssertGreaterThan(host.frame.height, 60, "The preview rendered empty")
                data = self.png(of: host)
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let payload = try XCTUnwrap(data, "Failed to render the diff preview in \(name)")
            try payload.write(
                to: directory.appendingPathComponent("changed-file-diff-preview-\(name).png")
            )
        }
    }

    // MARK: - Reply Composer

    /// The composer at the foot of the pane, with the narration line above it.
    ///
    /// The picture is the point. This surface was reviewed for a long time only by using the
    /// app, and what it had become — a strip of chips floating between the conversation and the
    /// input, clustered at the leading edge with the pane's whole width empty beside them, and
    /// an empty preview card parked underneath the box — was plain in a screenshot and in no
    /// assertion anyone had written. Both appearances, because every surface here is derived
    /// from a system colour and a change that breaks one is easy to miss from inside the other.
    func testRendersTheReplyComposer() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?

            let render = {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))

                // Both states in one picture: the box as it rests, waiting for a reply, and the
                // box with something in it. The resting one is what the pane shows nearly all
                // the time and is the height the whole redesign turns on.
                let column = NSStackView(views: [
                    self.replyComposerColumn(typing: ""),
                    self.replyComposerColumn(typing: "Have another look at the diff")
                ])
                column.orientation = .vertical
                column.alignment = .leading
                column.spacing = Design.Spacing.large
                column.translatesAutoresizingMaskIntoConstraints = false
                for band in column.arrangedSubviews {
                    band.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                }
                host.addSubview(column)
                NSLayoutConstraint.activate([
                    column.topAnchor.constraint(
                        equalTo: host.topAnchor,
                        constant: Design.Spacing.inset
                    ),
                    column.leadingAnchor.constraint(
                        equalTo: host.leadingAnchor,
                        constant: Design.Spacing.inset
                    ),
                    column.trailingAnchor.constraint(
                        equalTo: host.trailingAnchor,
                        constant: -Design.Spacing.inset
                    )
                ])
                host.appearance = appearance
                column.appearance = appearance
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                host.frame.size.height = column.fittingSize.height + Design.Spacing.inset * 2
                host.layoutSubtreeIfNeeded()
                data = self.png(of: host)
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let payload = try XCTUnwrap(data, "Failed to render the reply composer in \(name)")
            try payload.write(to: directory.appendingPathComponent("reply-composer-\(name).png"))
        }
    }

    /// The composer's controls reach the pane's trailing edge rather than trailing the chips.
    ///
    /// The strip this replaced sized itself to its content and was pinned by one edge, so the
    /// meter and the send sat wherever the last chip happened to end — which on a wide pane is
    /// the middle of an otherwise empty row.
    func testTheReplyComposerSpansThePaneAndFinishesAtItsTrailingEdge() throws {
        let column = replyComposerColumn(typing: "")
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
        host.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: host.topAnchor),
            column.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        host.frame.size.height = column.fittingSize.height
        host.layoutSubtreeIfNeeded()

        let prompt = try XCTUnwrap(
            Self.descendants(in: column).compactMap { $0 as? PromptView }.first
        )
        XCTAssertEqual(prompt.frame.width, Render.width, accuracy: 1, "The box left the pane's width behind")

        let send = try XCTUnwrap(
            Self.descendants(in: prompt).compactMap { $0 as? ThemedButton }.first,
            "The composer drew no send control"
        )
        XCTAssertLessThan(
            prompt.bounds.maxX - send.convert(send.bounds, to: prompt).maxX,
            Design.Spacing.large,
            "The send did not reach the box's trailing edge"
        )
    }

    /// Builds the pane's whole bottom band — the narration line and the composer under it —
    /// with the controls a live Codex session would have put on the row.
    private func replyComposerColumn(typing text: String) -> NSStackView {
        let orb = WorkingOrbView()
        orb.isHidden = true
        let status = NSTextField(labelWithString: "Ready · last turn 47s · ↓ 1.2k tokens")
        status.applyFont(.subheading)
        status.textColor = Design.Text.tertiary
        status.lineBreakMode = .byTruncatingTail

        let narration = NSStackView(views: [orb, status])
        narration.orientation = .horizontal
        narration.alignment = .centerY
        narration.spacing = Design.Spacing.tight
        narration.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.inset,
            bottom: 0,
            right: 0
        )

        let model = ChipView()
        model.configure(symbolName: "cpu", title: "Opus · 1M")
        // Model then mode, the pair the opening composer leads with.
        let mode = ChipView()
        mode.configure(
            symbolName: PermissionModePresentation.symbol,
            title: AgentPermissionMode.acceptEdits.displayName
        )
        let effort = ChipView()
        effort.configure(symbolName: "brain", title: "High")
        let speed = ChipView()
        speed.configure(symbolName: "bolt.fill", title: "Standard")

        let context = NSTextField(labelWithString: TurnStatusText.context(
            tokens: 74_000,
            window: 200_000
        ))
        context.applyFont(.subheading)
        context.textColor = Design.Text.tertiary

        let prompt = PromptView()
        prompt.fontSurface = .conversation
        prompt.showsImageAttachments = true
        prompt.submitPlacement = .footer
        prompt.placeholder = "Reply to Codex"
        prompt.setFooterControls(leading: [model, mode, effort, speed], trailing: [context])
        prompt.stringValue = text

        let column = NSStackView(views: [narration, prompt])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            narration.widthAnchor.constraint(equalTo: column.widthAnchor),
            prompt.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        return column
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
        <!doctype html><meta charset="utf-8"><title>Threading theme matrix</title>
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
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
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

@MainActor
final class SubagentSummaryViewTests: XCTestCase {

    func testTerminalSurfaceKeepsTheSubagentNavigatorOutOfTheMainPane() {
        let session = AgentSession(kind: .claude, title: "Terminal children")
        let state = SubagentSessionState(sessionID: session.id)
        let controller = AgentSessionViewController(
            agentSession: session,
            subagentState: state
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        state.apply(.discovered(SubagentDescriptor(
            threadID: "terminal-child",
            nickname: "Terminal researcher",
            path: "/tmp/terminal-child.jsonl"
        )))
        state.apply(.state(
            threadID: "terminal-child",
            status: .working,
            message: nil
        ))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            descendants(of: controller.view).compactMap { $0 as? SubagentSummaryView }.isEmpty,
            "Child navigation belongs in the side pane, not above the terminal"
        )
        XCTAssertEqual(controller.subagents.workingCount, 1)
    }

    func testNativeSurfaceKeepsTheSubagentNavigatorOutOfTheMainPane() {
        let session = AgentSession(kind: .codex, title: "Native children")
        let state = SubagentSessionState(sessionID: session.id)
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(
                name: "Native children",
                folderURL: URL(fileURLWithPath: "/tmp/native-children")
            ),
            subagentState: state,
            customizationLookup: { _ in .empty }
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        controller.view.layoutSubtreeIfNeeded()

        state.apply(.discovered(SubagentDescriptor(
            threadID: "native-child",
            nickname: "Native researcher"
        )))
        state.apply(.state(
            threadID: "native-child",
            status: .working,
            message: nil
        ))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            descendants(of: controller.view).compactMap { $0 as? SubagentSummaryView }.isEmpty,
            "Child navigation belongs in the side pane, not above the native conversation"
        )
        XCTAssertEqual(controller.subagents.workingCount, 1)
    }

    func testSubagentSidePaneOwnsTheCompleteNavigator() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        for index in 0..<12 {
            let threadID = "working-\(index)"
            timeline.apply(.discovered(SubagentDescriptor(threadID: threadID)))
            timeline.apply(.state(
                threadID: threadID,
                status: .working,
                message: nil
            ))
        }

        let controller = SubagentTranscriptViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 720)
        controller.update(timeline, selectedThreadID: "working-11")
        controller.view.layoutSubtreeIfNeeded()

        let summary = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? SubagentSummaryView }.first
        )
        XCTAssertEqual(summary.selectionStyle, .navigation)
        XCTAssertEqual(
            descendants(of: summary).compactMap { $0 as? ThemedButton }.count,
            12,
            "The scrolling side pane should retain every child rather than clipping the list"
        )
    }

    func testSubagentSidePaneSwitchesSelectedTranscriptAndReportsSelection() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        for (id, name, reply) in [
            ("child-one", "First child", "First reply"),
            ("child-two", "Second child", "Second reply")
        ] {
            timeline.apply(.discovered(SubagentDescriptor(threadID: id, nickname: name)))
            timeline.apply(.state(threadID: id, status: .completed, message: nil))
            timeline.apply(.conversation(
                threadID: id,
                event: .assistantMessage(blocks: [.text(reply)])
            ))
        }

        let controller = SubagentTranscriptViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 720)
        var selectedID: String?
        controller.onSelectAgent = { selectedID = $0 }
        controller.update(timeline, selectedThreadID: "child-one")
        controller.view.layoutSubtreeIfNeeded()

        let second = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == "Second child" }
        )
        _ = second.sendAction(second.action, to: second.target)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(selectedID, "child-two")
        XCTAssertEqual(controller.representedThreadID, "child-two")
        let transcriptRow = try XCTUnwrap(
            controller.transcriptTableView.view(
                atColumn: 0,
                row: 1,
                makeIfNecessary: true
            )
        )
        XCTAssertTrue(
            descendants(of: transcriptRow)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "Second reply" }
        )
    }

    func testNavigationSelectionKeepsTheOverviewCompact() throws {
        let view = SubagentSummaryView()
        view.selectionStyle = .navigation
        view.update(
            items: [
                SubagentSummaryItem(
                    id: "child-1",
                    title: "Parser audit",
                    subtitle: "Inspect the app-server event adapter.",
                    state: .working,
                    statusDetail: nil,
                    detailLines: [
                        "Started",
                        "Read CodexAppServerEvent.swift",
                        "Found a missing terminal-state mapping"
                    ]
                )
            ],
            workingCount: 1,
            doneCount: 0
        )

        let collapsed = laidOut(view)
        var selections: [String?] = []
        view.onSelect = { selections.append($0) }
        view.setSelection("child-1")
        let selected = laidOut(view)
        view.setSelection("child-1")

        XCTAssertEqual(collapsed, selected)
        XCTAssertEqual(selections.compactMap { $0 }, ["child-1", "child-1"])
        let selectedButton = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == "Parser audit" }
        )
        XCTAssertEqual(
            selectedButton.accessibilityValue() as? Bool,
            true,
            "VoiceOver should identify the child whose transcript is on screen"
        )
    }

    func testSelectionExpandsChildActivityWithoutChangingTheSummaryWidth() {
        let view = SubagentSummaryView()
        let items = [
            SubagentSummaryItem(
                id: "child-1",
                title: "Parser audit",
                subtitle: "Inspect the app-server event adapter.",
                state: .working,
                statusDetail: "Read · 18s · 4 tools",
                detailLines: [
                    "Started",
                    "Read CodexAppServerEvent.swift",
                    "Found a missing terminal-state mapping"
                ]
            ),
            SubagentSummaryItem(
                id: "child-2",
                title: "Render check",
                subtitle: nil,
                state: .completed,
                statusDetail: nil,
                detailLines: ["Theme boundary passed"]
            )
        ]

        view.update(items: items, workingCount: 1, doneCount: 1)
        let collapsed = laidOut(view)
        view.setSelection("child-1")
        let expanded = laidOut(view)

        XCTAssertEqual(collapsed.width, expanded.width, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.height, collapsed.height + Design.Spacing.large)
    }

    func testLongSubagentTextStaysInsideANarrowSummary() throws {
        let view = SubagentSummaryView()
        let title = "Investigate the native renderer and its deliberately long summary title"
        let detail = "Reasoning: Chronology: 1. The single real user message asked for "
            + "a thorough investigation of the renderer at a deliberately narrow pane width."
        let transcriptURL = URL(fileURLWithPath: "/tmp/agent-af90bc36.jsonl")
        var revealedURL: URL?
        view.onRevealTranscript = { revealedURL = $0 }
        view.update(
            items: [
                SubagentSummaryItem(
                    id: "child-1",
                    title: title,
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: [detail],
                    transcriptAvailability: .onDisk(transcriptURL)
                )
            ],
            workingCount: 0,
            doneCount: 1
        )
        view.setSelection("child-1")
        _ = laidOut(view, width: 360)

        let button = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.title == title }
        )
        XCTAssertLessThan(
            button.frame.width,
            button.intrinsicContentSize.width,
            "The fixture no longer exercises a squeezed title"
        )

        let detailLabel = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == detail }
        )
        XCTAssertEqual(detailLabel.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(detailLabel.maximumNumberOfLines, 3)

        let revealButton = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? ThemedIconButton }
                .first { $0.accessibilityTitle() == L10n.string("Reveal in Finder") }
        )
        revealButton.onPress?()
        XCTAssertEqual(revealedURL, transcriptURL)

        for descendant in descendants(of: view) {
            let frame = descendant.convert(descendant.bounds, to: view)
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                view.bounds.minX - 0.5,
                "\(type(of: descendant)) escaped the summary's leading edge: \(frame)"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                view.bounds.maxX + 0.5,
                "\(type(of: descendant)) escaped the summary's trailing edge: \(frame)"
            )
        }

        let margin = Design.Spacing.large
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: view.frame.width + margin * 2,
            height: view.frame.height + margin * 2
        ))
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame.origin = NSPoint(x: margin, y: margin)
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent("subagent-summary-friendly-transcript.png")
        )
    }

    func testExpandedSubagentSummaryRenders() throws {
        let view = SubagentSummaryView()
        view.update(
            items: [
                SubagentSummaryItem(
                    id: "child-1",
                    title: "Cargo enrollment ffi",
                    subtitle: "Audit the retained-parent capacity regression.",
                    state: .working,
                    statusDetail: "Read · 1m 42s · 14 tools · 24.2K tokens",
                    detailLines: [
                        "Started",
                        "Edited rust_target_pipeline.rs",
                        "The retained-parent capacity regression passes.",
                        "Running the remaining native Cargo fixtures"
                    ]
                ),
                SubagentSummaryItem(
                    id: "child-2",
                    title: "Unicode audit",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: "28s · 6 tools · 8.1K tokens",
                    detailLines: ["Finished"]
                )
            ],
            workingCount: 1,
            doneCount: 1
        )
        view.setSelection("child-1")

        let size = laidOut(view)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.appearance = NSAppearance(named: .darkAqua)
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-subagent-summary.png")
        try data.write(to: url)
    }

    func testSubagentTranscriptReusesNativeRowsAndRendersAtPaneWidth() throws {
        let agent = makeAgent(
            threadID: "child-detail",
            status: .working,
            events: [
                .userMessage("Audit the retained-parent capacity regression."),
                .assistantMessage(blocks: [
                    .thinking("I should inspect the admission path first."),
                    .toolUse(
                        id: "tool-1",
                        tool: .bash,
                        input: ["command": "swift test --filter CapacityRegression"]
                    ),
                    .toolUse(
                        id: "tool-2",
                        tool: .read,
                        input: ["path": "Sources/Threading/Core/Agent/ConversationTimeline.swift"]
                    ),
                    .text("""
                    The focused regression now passes.

                    | Check | Result |
                    | --- | ---: |
                    | Capacity | 44 sites |
                    """),
                    .toolUse(
                        id: "tool-3",
                        tool: .bash,
                        input: ["command": "scripts/test.sh fast"]
                    ),
                    .text("The final validation passes.")
                ])
            ]
        )

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 720))
        host.appearance = NSAppearance(named: .darkAqua)
        host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))

        let controller = SubagentTranscriptViewController()
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]
        host.addSubview(controller.view)
        controller.update(agent)
        host.layoutSubtreeIfNeeded()
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.representedThreadID, "child-detail")
        XCTAssertEqual(controller.renderedRowCount, agent.conversation.rows.count)
        XCTAssertGreaterThan(controller.renderedRowCount, 2)

        let compactItems = ConversationRowPresentation.compact(agent.conversation.rows)
        XCTAssertEqual(
            compactItems.compactMap { item -> Int? in
                guard case .toolCalls(let calls) = item else { return nil }
                return calls.count
            },
            [2, 1],
            "Tool calls moved across assistant prose instead of folding in chronological runs"
        )

        let transcriptDescendants = descendants(of: controller.view)
        XCTAssertEqual(
            transcriptDescendants.compactMap { $0 as? TurnFoldView }.count,
            2,
            "The compact child transcript did not replace tool runs with disclosures"
        )
        XCTAssertEqual(
            transcriptDescendants.compactMap { $0 as? ToolCallView }.count,
            0,
            "Collapsed virtual tool rows should not be materialized behind their disclosure"
        )
        XCTAssertEqual(
            controller.renderedPresentationCount,
            8,
            "Markdown blocks should be separate virtual rows beside the two tool folds"
        )
        let summary = try XCTUnwrap(
            transcriptDescendants.compactMap { $0 as? SubagentSummaryView }.first
        )
        XCTAssertEqual(summary.selectionStyle, .navigation)
        XCTAssertTrue(
            descendants(of: summary)
                .compactMap { $0 as? ThemedButton }
                .contains { $0.title == agent.descriptor.displayName },
            "The side pane no longer exposes the child navigator"
        )
        XCTAssertFalse(
            transcriptDescendants.contains { $0 is MarkdownView },
            "A long reply was rebuilt as one eager Markdown constraint tree"
        )
        XCTAssertTrue(
            transcriptDescendants.compactMap { $0 as? NSTextField }
                .contains { $0.stringValue.contains("The focused regression now passes") },
            "The block-virtualized reply did not retain its rendered Markdown text"
        )

        let firstFold = try XCTUnwrap(
            transcriptDescendants.compactMap { $0 as? TurnFoldView }.first
        )
        firstFold.setExpanded(true)
        XCTAssertEqual(
            controller.renderedPresentationCount,
            10,
            "Opening a two-tool fold should insert exactly its two virtual rows"
        )
        firstFold.setExpanded(false)
        XCTAssertEqual(
            controller.renderedPresentationCount,
            8,
            "Closing a tool fold should release its virtual rows again"
        )

        let scrollView = controller.transcriptScrollView
        let tableView = controller.transcriptTableView
        XCTAssertEqual(
            tableView.frame.width,
            scrollView.contentSize.width,
            accuracy: 1,
            "A narrow virtual transcript must fill its clip width so rows wrap"
        )

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-subagent-transcript.png")
        try data.write(to: url)
    }

    func testDocumentTableReflowsWhenThePaneWidthChanges() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Design.Typography.body(surface: .conversation),
            .foregroundColor: Design.Text.label
        ]
        let table = ThemedDocumentTableView(
            headers: [
                NSAttributedString(string: "Section", attributes: attributes),
                NSAttributedString(string: "Rows", attributes: attributes)
            ],
            rows: [[
                NSAttributedString(string: "Sessions", attributes: attributes),
                NSAttributedString(
                    string: String(
                        repeating: "New sessions keep their own title and branch. ",
                        count: 4
                    ),
                    attributes: attributes
                )
            ]],
            alignments: [.left, .left],
            availableWidth: 360,
            minimumColumnWidth: MarkdownDefaults.tableColumnWidth
        )

        table.frame.size = NSSize(width: 360, height: table.intrinsicContentSize.height)
        let narrowHeight = table.intrinsicContentSize.height
        table.frame.size.width = 720
        let wideHeight = table.intrinsicContentSize.height
        table.frame.size.width = 360
        let restoredHeight = table.intrinsicContentSize.height

        XCTAssertLessThan(
            wideHeight,
            narrowHeight,
            "A wider pane kept the Markdown table's narrow wrapping"
        )
        XCTAssertEqual(
            restoredHeight,
            narrowHeight,
            accuracy: 0.5,
            "Shrinking the pane did not restore the table's measured row height"
        )
    }

    /// A pane narrower than the readable column still has to wrap to *itself*.
    ///
    /// The row host is the only place that decides a row's measure, and a table cell is free to
    /// be wider than its column: nothing pins it. Asking for the readable column at a higher
    /// priority than the pane's own width therefore does not lose gracefully in a narrow pane —
    /// the cell grows past the clip and the sentences are cut mid-word at its edge, with no
    /// wrap and no horizontal scroller to reach them.
    func testChildTranscriptWrapsToANarrowPaneRatherThanLeavingIt() throws {
        let agent = makeAgent(
            threadID: "narrow-pane",
            status: .completed,
            events: [
                .userMessage("Review the browser credential plan."),
                .assistantMessage(blocks: [
                    .text("""
                    Invariant 1 says the origin key is compared again immediately before the \
                    fill, but "immediately before" in Swift is not immediately before. The \
                    bridge executes against whatever main-frame document exists when WebKit \
                    delivers the script, so a click landing on a fresh document crosses the \
                    secret into the wrong origin.
                    """)
                ])
            ]
        )

        // The width a panel opens itself to — narrower than `Design.Size.readableWidth`, which
        // is the case the row host has to survive.
        let paneWidth = DisplayPaneDefaults.defaultWidth
        let host = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 720))
        host.appearance = NSAppearance(named: .darkAqua)

        let controller = SubagentTranscriptViewController()
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]
        host.addSubview(controller.view)
        controller.update(agent)
        host.layoutSubtreeIfNeeded()

        // Drawing is what makes an unshown table ask for its cells.
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        host.layoutSubtreeIfNeeded()

        let rows = descendants(of: controller.view).compactMap { $0 as? ConversationVirtualRowHost }
        XCTAssertFalse(rows.isEmpty, "The transcript materialized no rows to measure")

        for row in rows {
            XCTAssertLessThanOrEqual(
                row.convert(row.bounds, to: host).maxX, paneWidth + 1,
                "A row measured \(row.bounds.width)pt in a \(paneWidth)pt pane"
            )
            for content in row.subviews {
                XCTAssertLessThanOrEqual(
                    content.convert(content.bounds, to: host).maxX, paneWidth + 1,
                    "\(type(of: content)) measured \(content.bounds.width)pt "
                        + "in a \(paneWidth)pt pane"
                )
            }
        }
    }

    /// The other half of the same rule: given the room, prose still stops at the readable
    /// column rather than running the full width of a wide pane.
    func testChildTranscriptStopsAtTheReadableColumnInAWidePane() throws {
        let agent = makeAgent(
            threadID: "wide-pane",
            status: .completed,
            events: [
                .assistantMessage(blocks: [
                    .text(String(repeating: "The measure of a line of prose. ", count: 12))
                ])
            ]
        )

        let paneWidth = Design.Size.readableWidth * 2
        let host = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 720))
        host.appearance = NSAppearance(named: .darkAqua)

        let controller = SubagentTranscriptViewController()
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]
        host.addSubview(controller.view)
        controller.update(agent)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        host.layoutSubtreeIfNeeded()

        let contents = descendants(of: controller.view)
            .compactMap { $0 as? ConversationVirtualRowHost }
            .flatMap(\.subviews)
        XCTAssertFalse(contents.isEmpty, "The transcript materialized no rows to measure")

        let measures = contents.map { $0.alignmentRect(forFrame: $0.frame).width }
        for (content, measure) in zip(contents, measures) {
            XCTAssertLessThanOrEqual(
                measure, Design.Size.readableWidth + 1,
                "\(type(of: content)) ran to \(measure)pt of a \(paneWidth)pt pane"
            )
        }
        // The cap has to be reached, not merely respected: a row that stops short of it in a
        // wide pane is the same fault read from the other side.
        XCTAssertEqual(
            measures.max() ?? 0, Design.Size.readableWidth, accuracy: 1,
            "Prose no longer fills the readable column when the pane can hold it"
        )
    }

    func testDisplayPaneKeepsOneEphemeralSubagentTabAndDoesNotReopenIt() throws {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        var timeline = SubagentTimeline(sessionID: sessionID)
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "child-pane",
            nickname: "Pane child"
        )))
        timeline.apply(.state(
            threadID: "child-pane",
            status: .working,
            message: nil
        ))
        timeline.apply(.conversation(
            threadID: "child-pane",
            event: .assistantMessage(blocks: [.text("First update.")])
        ))

        let controller = pane.activateSubagents(
            timeline,
            selectedThreadID: "child-pane",
            for: sessionID
        )
        let tab = try XCTUnwrap(pane.tabs(for: sessionID).first)
        XCTAssertTrue(tab.subagents === controller)
        XCTAssertEqual(tab.title, "Subagents")
        XCTAssertEqual(tab.symbolName, "person.2")
        XCTAssertEqual(pane.activeTabID(for: sessionID), tab.id)

        timeline.apply(.state(
            threadID: "child-pane",
            status: .completed,
            message: nil
        ))
        timeline.apply(.conversation(
            threadID: "child-pane",
            event: .assistantMessage(blocks: [.text("Finished.")])
        ))
        pane.updateSubagents(
            timeline,
            selectedThreadID: "child-pane",
            for: sessionID
        )
        let updated = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(
            controller.renderedRowCount,
            updated.conversation.rows.count
        )

        XCTAssertTrue(pane.closeTab(id: tab.id, for: sessionID))
        pane.updateSubagents(
            timeline,
            selectedThreadID: "child-pane",
            for: sessionID
        )
        XCTAssertTrue(pane.tabs(for: sessionID).isEmpty)
    }

    // MARK: - Rows That Lead Nowhere

    /// A chevron is a promise. A finished child with no transcript — no rows replayed and no
    /// file on disk — has nothing behind it, and offering the same affordance as a child that
    /// opens leaves the user clicking a control that cannot answer.
    func testAFinishedChildWithNoTranscriptOffersNoWayIn() throws {
        let view = SubagentSummaryView()
        view.selectionStyle = .navigation
        view.update(
            items: [
                SubagentSummaryItem(
                    id: "opens",
                    title: "Parser audit",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: ["Finished"],
                    transcriptAvailability: .onDisk(
                        URL(fileURLWithPath: "/tmp/agent-opens.jsonl")
                    )
                ),
                SubagentSummaryItem(
                    id: "empty",
                    title: "Render check",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: [],
                    transcriptAvailability: .unavailable
                )
            ],
            workingCount: 0,
            doneCount: 2
        )
        _ = laidOut(view)

        let buttonTitles = descendants(of: view)
            .compactMap { $0 as? ThemedButton }
            .map(\.title)
        XCTAssertEqual(
            buttonTitles,
            ["Parser audit"],
            "Only the child with a transcript should be a control"
        )

        let labels = descendants(of: view)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertTrue(
            labels.contains("Render check"),
            "The child is still listed — it just does not pretend to open"
        )
        XCTAssertTrue(
            labels.contains("No transcript recorded."),
            "A row that leads nowhere has to say why, or it reads as a broken control"
        )
    }

    /// A child still running has no transcript *yet*, which is the one case where waiting is the
    /// truth. It keeps its chevron so the user can watch it fill.
    func testARunningChildKeepsItsWayInBeforeAnyTranscriptExists() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(threadID: "live", role: "Explore")))
        timeline.apply(.state(threadID: "live", status: .working, message: nil))

        let controller = SubagentTranscriptViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        controller.update(timeline, selectedThreadID: "live")
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            descendants(of: controller.view).compactMap { $0 as? ThemedButton }.count,
            1
        )
        XCTAssertTrue(
            descendants(of: controller.view)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue.contains("has not arrived yet") }
        )
    }

    /// The same pane, once the child has finished without one: the notice has to stop claiming
    /// a file is on its way, because nothing is going to write it.
    func testAFinishedChildWithNoTranscriptSaysSoRatherThanWaiting() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(threadID: "done", role: "Explore")))
        timeline.apply(.state(threadID: "done", status: .completed, message: nil))

        let controller = SubagentTranscriptViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        controller.update(timeline, selectedThreadID: "done")
        controller.view.layoutSubtreeIfNeeded()

        let labels = descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertTrue(labels.contains("No transcript was recorded for this child."))
        XCTAssertFalse(labels.contains { $0.contains("has not arrived yet") })
    }

    /// Aligned by ink: dropping the chevron must not drag the row's words left, or a list that
    /// mixes openable and empty children reads as ragged.
    func testARowThatLeadsNowhereStillLinesUpWithTheRowsThatOpen() throws {
        let view = SubagentSummaryView()
        view.selectionStyle = .navigation
        view.update(
            items: [
                SubagentSummaryItem(
                    id: "opens",
                    title: "Parser audit",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: ["Finished"],
                    transcriptAvailability: .onDisk(
                        URL(fileURLWithPath: "/tmp/agent-opens.jsonl")
                    )
                ),
                SubagentSummaryItem(
                    id: "empty",
                    title: "Render check",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: [],
                    transcriptAvailability: .unavailable
                )
            ],
            workingCount: 0,
            doneCount: 2
        )
        _ = laidOut(view)

        let button = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? ThemedButton }
                .first { $0.title == "Parser audit" }
        )
        let label = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "Render check" }
        )
        // Measured on alignment rects, not frames — that is what the stack lays out against,
        // and an `NSTextField` carries a 2pt horizontal alignment inset a raw frame would
        // report as a misalignment that is not on screen.
        let buttonInk = alignedLeadingX(of: button, in: view)
            + ThemedButton.plainTitleLeadingInset
        let labelInk = alignedLeadingX(of: label, in: view)

        XCTAssertEqual(labelInk, buttonInk, accuracy: 0.5)
    }

    private func makeAgent(
        sessionID: SessionID = SessionID(),
        threadID: String,
        status: SubagentStatus,
        events: [StreamEvent]
    ) -> SubagentTimeline.Agent {
        var timeline = SubagentTimeline(sessionID: sessionID)
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: threadID,
            nickname: "Cargo enrollment ffi",
            prompt: "Audit the retained-parent capacity regression."
        )))
        timeline.apply(.state(
            threadID: threadID,
            status: status,
            message: status.isDone ? "Finished" : "Working"
        ))
        timeline.apply(.activity(
            threadID: threadID,
            text: "Edited rust_target_pipeline.rs"
        ))
        for event in events {
            timeline.apply(.conversation(threadID: threadID, event: event))
        }
        return timeline.agents[0]
    }

    private func laidOut(_ view: SubagentSummaryView, width: CGFloat = 560) -> CGSize {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: size.height))
        view.layoutSubtreeIfNeeded()
        return view.frame.size
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Where a view's *ink* starts, in another view's coordinates.
    private func alignedLeadingX(of view: NSView, in ancestor: NSView) -> CGFloat {
        guard let parent = view.superview else { return view.frame.minX }
        let aligned = view.alignmentRect(forFrame: view.frame)
        return parent.convert(aligned.origin, to: ancestor).x
    }
}
