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

    // MARK: - Stress Profiling

    /// Opt-in because this deliberately builds several hundred real AppKit/Markdown rows.
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

    func testSettledTurnLazilyMaterializesAndReusesFoldedWork() throws {
        let session = AgentSession(kind: .codex, title: "Fold restoration", usesNativeUI: true)
        let controller = ConversationViewController(
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

        XCTAssertEqual(controller.stack.arrangedSubviews.count, 1)
        XCTAssertEqual(controller.deferredReplayRowIndices, Set(1...5))
        XCTAssertTrue((1...5).allSatisfy { controller.rowViews[$0] == nil })

        Self.apply(Array(events.dropFirst(2)), to: controller)

        let fold = try XCTUnwrap(
            controller.stack.arrangedSubviews.compactMap { $0 as? TurnFoldView }.first
        )

        XCTAssertEqual(controller.stack.arrangedSubviews.count, 3)
        XCTAssertTrue(controller.deferredReplayRowIndices.isEmpty)
        XCTAssertTrue((1...4).allSatisfy { controller.rowViews[$0] == nil })

        fold.setExpanded(true)
        let foldedWork = try (1...4).map { try XCTUnwrap(controller.rowViews[$0]) }
        XCTAssertEqual(controller.stack.arrangedSubviews.count, 7)
        XCTAssertTrue(foldedWork.allSatisfy { $0.superview === controller.stack })
        XCTAssertTrue(foldedWork.allSatisfy { view in
            controller.rowEdgeConstraints[ObjectIdentifier(view)]?.allSatisfy(\.isActive) == true
        })

        fold.setExpanded(false)
        XCTAssertEqual(controller.stack.arrangedSubviews.count, 3)
        XCTAssertTrue(foldedWork.allSatisfy { $0.superview == nil })
        XCTAssertTrue(foldedWork.allSatisfy { view in
            controller.rowEdgeConstraints[ObjectIdentifier(view)]?.allSatisfy { !$0.isActive }
                == true
        })

        fold.setExpanded(true)
        XCTAssertEqual(controller.stack.arrangedSubviews.count, 7)
        XCTAssertTrue(zip(1...4, foldedWork).allSatisfy { pair in
            controller.rowViews[pair.0] === pair.1
        })
    }

    func testReplayFinishAttachesAnUnfinishedTail() {
        let session = AgentSession(kind: .codex, title: "Replay tail", usesNativeUI: true)
        let controller = ConversationViewController(
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
        XCTAssertEqual(controller.stack.arrangedSubviews.count, 1)
        XCTAssertEqual(controller.deferredReplayRowIndices, Set(1...5))

        controller.finishReplayRendering()

        XCTAssertTrue(controller.deferredReplayRowIndices.isEmpty)
        XCTAssertEqual(controller.stack.arrangedSubviews.count, 6)
        XCTAssertTrue((0...5).allSatisfy { controller.rowViews[$0]?.superview === controller.stack })
    }

    private enum StressShape: String {
        case prose
        case mixed
        case toolHeavy = "tool-heavy"
    }

    private func runConversationStress(shape: StressShape, turns: Int) {
        let events = Self.stressEvents(shape: shape, turns: turns)

        var modelTimeline = ConversationTimeline(sessionID: SessionID())
        let modelStarted = DispatchTime.now().uptimeNanoseconds
        for event in events { _ = modelTimeline.apply(event) }
        let modelElapsed = DispatchTime.now().uptimeNanoseconds - modelStarted

        let session = AgentSession(kind: .codex, title: "Conversation stress", usesNativeUI: true)
        let controller = ConversationViewController(
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

        let replayStarted = DispatchTime.now().uptimeNanoseconds
        Self.apply(events, to: controller)
        controller.finishReplayRendering()
        controller.refreshMinimap()
        let replayEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let rowCount = controller.timeline.rows.count
        let materializedRowCount = controller.rowViews.count
        let arrangedCount = controller.stack.arrangedSubviews.count
        let descendantCount = Self.descendantCount(in: controller.view)
        print(
            "THREADING_PERF conversation-replay "
                + "shape=\(shape.rawValue) turns=\(turns) events=\(events.count) "
                + "rows=\(rowCount) materialized=\(materializedRowCount) "
                + "arranged=\(arrangedCount) descendants=\(descendantCount) "
                + "model_ms=\(Self.milliseconds(modelElapsed)) "
                + "render_ms=\(Self.milliseconds(replayEnded - replayStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - replayEnded)) "
                + "elapsed_ms=\(Self.milliseconds(layoutEnded - replayStarted))"
        )

        if let lastTurn = controller.timeline.turns.last,
           let rowView = controller.rowViews[lastTurn.rowIndex],
           let documentView = controller.scrollView.documentView {
            let jumpStarted = DispatchTime.now().uptimeNanoseconds
            controller.autoScroll.noteJumpedToRow()
            let frame = rowView.convert(rowView.bounds, to: documentView)
            controller.scrollView.contentView.setBoundsOrigin(NSPoint(
                x: 0,
                y: max(0, frame.minY - Design.Spacing.large)
            ))
            controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            controller.view.layoutSubtreeIfNeeded()
            let jumpElapsed = DispatchTime.now().uptimeNanoseconds - jumpStarted
            print(
                "THREADING_PERF conversation-deep-jump "
                    + "shape=\(shape.rawValue) turns=\(turns) target_row=\(lastTurn.rowIndex) "
                    + "elapsed_ms=\(Self.milliseconds(jumpElapsed))"
            )
        }

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
                isError: false,
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
                isError: false,
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

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
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
        let controller = ConversationViewController(
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

        XCTAssertEqual(selectedID, "child-two")
        XCTAssertEqual(controller.representedThreadID, "child-two")
        XCTAssertTrue(
            descendants(of: controller.view)
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
                    transcriptURL: transcriptURL
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
            transcriptDescendants.compactMap { $0 as? ToolCallView }.filter(\.isHidden).count,
            3,
            "Tool rows should start hidden behind their run disclosure"
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
        XCTAssertTrue(
            transcriptDescendants.contains { $0 is MarkdownView },
            "The child reply did not use the native Markdown renderer"
        )

        let scrollView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? NSScrollView }.first
        )
        let documentView = try XCTUnwrap(scrollView.documentView)
        let stack = try XCTUnwrap(
            documentView.subviews.compactMap { $0 as? NSStackView }.first
        )
        XCTAssertEqual(
            stack.frame.width,
            documentView.bounds.width,
            accuracy: 1,
            "A narrow detail pane must fill its document width so transcript rows wrap"
        )

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1_000)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-subagent-transcript.png")
        try data.write(to: url)
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
                    transcriptURL: URL(fileURLWithPath: "/tmp/agent-opens.jsonl"),
                    canOpenTranscript: true
                ),
                SubagentSummaryItem(
                    id: "empty",
                    title: "Render check",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: [],
                    canOpenTranscript: false
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
                    transcriptURL: URL(fileURLWithPath: "/tmp/agent-opens.jsonl"),
                    canOpenTranscript: true
                ),
                SubagentSummaryItem(
                    id: "empty",
                    title: "Render check",
                    subtitle: nil,
                    state: .completed,
                    statusDetail: nil,
                    detailLines: [],
                    canOpenTranscript: false
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
