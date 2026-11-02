import AppKit
import XCTest
@testable import Threading

/// A working turn drawn the way a long agent run actually arrives: a sentence of narration, a run
/// of calls, a thought, another sentence, at every pane width the three-pane window can give it.
///
/// `ConversationRenderTests` draws recorded fixtures, and their turns have settled, so they fold
/// into one line and never show this shape. It is the shape a reader spends a run looking at.
@MainActor
final class ConversationWorkingTurnRenderTests: XCTestCase {

    // MARK: - Fixture

    private static let widths: [CGFloat] = [480, 720, 1000, 1418, 1800, 2300]
    private static let viewportHeight: CGFloat = 1000

    private static func call(_ id: String, _ tool: ToolIdentity, _ subject: String) -> ContentBlock {
        let key: String
        switch tool {
        case .bash: key = "command"
        case .grep, .glob: key = "pattern"
        default: key = "file_path"
        }
        return .toolUse(id: id, tool: tool, input: [key: .string(subject)])
    }

    private static func results(_ ids: [String]) -> StreamEvent {
        .toolResults(ids.map { ToolResult(toolUseID: $0, text: "line one\nline two\nline three", isError: false) })
    }

    private static var events: [StreamEvent] {
        var events: [StreamEvent] = [
            .userMessage("Kan du kolla hur HCH-summan hanteras när labbet saknar en kongener?"),
            .assistantMessage(blocks: [
                call("s1", .read, "crates/sonda-core/src/xylene_sum.rs"),
                call("s2", .grep, "hch_sum"),
                .text(
                    "Summan räknas som ofullständig när en kongener saknas, och kontrollen hamnar "
                        + "i granskning snarare än klarering.\n\n"
                        + "- Bevisen ligger i `aggregate_synthesis_rejections`\n"
                        + "- Kundtexten finns redan i `i18n.rs`"
                )
            ]),
            .toolResults([
                ToolResult(toolUseID: "s1", text: "48 lines", isError: false),
                ToolResult(toolUseID: "s2", text: "12 matches", isError: false)
            ]),
            .turnFinished(text: nil, outcome: .completed, metrics: TurnMetrics(duration: 42)),
            .userMessage(
                "Implementera SONDA-746: en ofullständig HCH-summa ska ge granskning med varning, "
                    + "inte klarering. Läs ärendet och skriv den källbaserade granskningen först."
            )
        ]
        let narration: [(String?, [(ToolIdentity, String)], String?)] = [
            (
                "Nu spårar jag hur `aggregate_synthesis_rejections` och intervallbevisen används i "
                    + "screeningexekveringen.",
                [
                    (.bash, "cd /Users/david/repo/sonda-746 && wc -l crates/sonda-core/src/xylene_sum.rs"),
                    (.read, "crates/sonda-core/src/screening.rs"),
                    (.read, "crates/sonda-core/src/pop_hch_sum.rs"),
                    (.grep, "aggregate_synthesis_rejections")
                ],
                nil
            ),
            (
                "Infrastrukturen finns: avvisningar i `aggregate_synthesis_rejections` blir redan "
                    + "granskningskontroller i POP-screeningen. Nu kollar jag var HCH förekommer i "
                    + "regler och register.",
                [
                    (.grep, "hch_sum"),
                    (.read, "docs/regulatory-playbooks/pop-annex-iv.md"),
                    (.bash, "sed -n 30,160p docs/regulatory-playbooks/pop-annex-iv.md")
                ],
                "Snapshot-kontraktet validerar redan `Derived`-bevis generiskt, så HCH kräver ingen "
                    + "formändring om det använder befintliga varianter. Nu kollar jag korpusverktygen "
                    + "och vad labben faktiskt redovisar för HCH."
            ),
            (
                nil,
                [
                    (.bash, "cargo run -p corpus-tools -- labs --analyte hch"),
                    (.read, "crates/corpus-tools/src/labs.rs")
                ],
                "5 jordrapporter har full HCH-uppsättning utan labbsumma, och 56 har både PCB-7 och "
                    + "alla sju kongener, så SONDA-745 berör många prov. Nu läser jag "
                    + "`screening_result` för att se hur osäkra och enhetslösa kontroller slutbehandlas."
            ),
            (
                "Jag kontrollerar vilka regelfamiljer som riktar sig mot `hch_sum` (utöver POP), "
                    + "eftersom bevis och avvisningar också läses av tröskelvägen.",
                [
                    (.read, "crates/sonda-core/src/screening_result.rs"),
                    (.edit, "docs/reviews/SONDA-746.md")
                ],
                nil
            ),
            (
                "Nu skriver jag den källbaserade granskningen för SONDA-746 innan implementationen, "
                    + "enligt `_CHANGE-REVIEW.md`.",
                [(.bash, "cargo test -p sonda-core hch")],
                nil
            ),
            (
                "SONDA-745 berör HP-motorn (`clp/component_sum_proxy.rs`, troligen `clp/speciation.rs`, "
                    + "där SONDA-644 arbetar). Jag läser hur PCB-7-proxyn tillämpas idag.",
                [
                    (.read, "clp/component_sum_proxy.rs"),
                    (.read, "clp/speciation.rs"),
                    (.grep, "pcb_7_proxy")
                ],
                nil
            )
        ]
        for (step, (say, tools, thought)) in narration.enumerated() {
            let ids = tools.indices.map { "w\(step)-\($0)" }
            var blocks: [ContentBlock] = []
            if let say { blocks.append(.text(say)) }
            for (id, tool) in zip(ids, tools) { blocks.append(call(id, tool.0, tool.1)) }
            events.append(.assistantMessage(blocks: blocks))
            events.append(results(ids))
            if let thought { events.append(.assistantMessage(blocks: [.thinking(thought)])) }
        }
        return events
    }

    // MARK: - Render

    private func livePane(width: CGFloat) -> (ConversationViewController, NSView) {
        let controller = requireConversationViewController(
            agentSession: AgentSession(kind: .claude, title: "Look", usesNativeUI: true),
            project: Project(
                name: "Look",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.viewportHeight))
        host.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: Self.viewportHeight),
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        for event in Self.events {
            for change in controller.timeline.apply(event) { controller.apply(change) }
        }
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    func testRendersAWorkingTurnAtEveryPaneWidth() throws {
        let environment = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
        let directory = URL(fileURLWithPath: environment ?? NSTemporaryDirectory())
            .appendingPathComponent("working-turn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousTheme = AppThemePalette.current
        let previousTerminalTheme = ThemeAssignments.defaultTheme
        let previousAppearance = NSApp.appearance
        let previousBackdrop = WindowBackdrop.ground
        defer {
            AppThemePalette.set(previousTheme)
            ThemeAssignments.setDefaultTheme(previousTerminalTheme)
            NSApp.appearance = previousAppearance
            WindowBackdrop.set(previousBackdrop)
        }

        for (name, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            NSApp.appearance = appearance
            AppThemePalette.set(AppThemeStyles.threading)
            let terminal = AppThemeStyles.threading.terminalPalette(for: appearance)
            ThemeAssignments.setDefaultTheme(terminal)
            WindowBackdrop.set(.terminal(terminal.background))

            for width in Self.widths {
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    let (controller, host) = livePane(width: width)
                    host.appearance = appearance
                    AppThemeRefresh.repaint(host)
                    let clip = controller.scrollView.contentView
                    let overflow = max(
                        0,
                        (clip.documentView?.bounds.height ?? 0) - controller.scrollView.contentSize.height
                    )
                    clip.setBoundsOrigin(NSPoint(x: 0, y: overflow))
                    controller.scrollView.reflectScrolledClipView(clip)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.wantsLayer = true
                    host.layer?.backgroundColor = terminal.background.cgColor
                    host.cacheDisplay(in: host.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }
                try XCTUnwrap(data, "the pane drew nothing at \(Int(width))pt").write(
                    to: directory.appendingPathComponent("turn-\(Int(width))-\(name).png")
                )
            }
        }
        print("Rendered working turns to \(directory.path)")
    }

    /// The same pane with its disclosures opened and a failure in a run, which are the states a
    /// resting image cannot show: nested rows on their rule, the open chevron, the failure count.
    func testRendersOpenedWork() throws {
        let environment = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
        let directory = URL(fileURLWithPath: environment ?? NSTemporaryDirectory())
            .appendingPathComponent("working-turn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for width in [CGFloat(480), 1000] {
            let (controller, host) = livePane(width: width)
            let runs = controller.presentationItems.compactMap { item -> [Int]? in
                guard case .toolFold(let indices) = item.content else { return nil }
                return indices
            }
            let run = try XCTUnwrap(runs.dropFirst().first)
            controller.scrollToTimelineRow(run[0], animated: false)
            let row = try XCTUnwrap(controller.presentationRow(forTimelineIndex: run[0]))
            let cell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
            let tool = try XCTUnwrap(Self.toolView(in: cell))
            tool.setExpanded(true)
            host.layoutSubtreeIfNeeded()

            // The pointer over one reply and one bubble, so their floating actions are drawn too.
            let event = try XCTUnwrap(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
            for row in 0..<controller.tableView.numberOfRows {
                guard let cell = controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
                      let message = cell.subviews.first as? ConversationMessageContextView else { continue }
                message.mouseEntered(with: event)
            }
            host.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("opened-\(Int(width)).png")
            )
        }
    }

    // MARK: - Assertions

    func testAColumnGrowsWithARoomyPaneAndStopsAtItsCeiling() {
        let base = Design.Chat.columnWidth
        let ceiling = (base * Design.Chat.columnGrowth).rounded()

        XCTAssertEqual(Design.Chat.columnWidth(inPane: 480), base, "a narrow pane keeps the base cap")
        XCTAssertEqual(Design.Chat.columnWidth(inPane: 1000), base)
        XCTAssertGreaterThan(Design.Chat.columnWidth(inPane: 1400), base)
        XCTAssertLessThan(Design.Chat.columnWidth(inPane: 1400), ceiling)
        XCTAssertEqual(Design.Chat.columnWidth(inPane: 2300), ceiling, "prose has a longest line")
        XCTAssertEqual(Design.Chat.columnWidth(inPane: 6000), ceiling)

        var previous: CGFloat = 0
        for pane in stride(from: CGFloat(300), through: 3000, by: 7) {
            let column = Design.Chat.columnWidth(inPane: pane)
            XCTAssertGreaterThanOrEqual(column, previous, "the column shrank as \(pane)pt grew")
            previous = column
        }
    }

    func testRowsAndReplyBoxTakeTheColumnThePaneGives() throws {
        for width in [CGFloat(480), 1000, 1418, 2300] {
            let (controller, _) = livePane(width: width)
            let measure = Design.Chat.columnWidth(inPane: width)
            let column = min(measure, width - Design.Chat.columnMargin * 2)

            var prose: NSRect?
            for row in 0..<controller.tableView.numberOfRows {
                guard case .timeline(let index) = controller.presentationItems[row].content,
                      case .assistant = controller.timeline.rows[index],
                      let cell = controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true),
                      let content = cell.subviews.first else { continue }
                prose = content.convert(content.bounds, to: controller.view)
                break
            }
            XCTAssertEqual(try XCTUnwrap(prose).width, column, accuracy: 1, "at \(Int(width))pt")
            XCTAssertEqual(
                ConversationPaneLayout.measuredComposerWidth(in: width),
                min(measure + Design.Spacing.inset * 2, width - Design.Spacing.inset * 2),
                accuracy: 0.5
            )
        }
    }

    func testAToolRunSaysWhatItDidInTheOrderItDidIt() {
        func call(_ id: String, _ tool: ToolIdentity, _ summary: String, failed: Bool = false)
            -> ConversationTimeline.ToolCall {
            var timeline = ConversationTimeline(sessionID: SessionID())
            let key = tool == .bash ? "command" : "file_path"
            _ = timeline.apply(.assistantMessage(blocks: [
                .toolUse(id: id, tool: tool, input: [key: .string(summary)])
            ]))
            if failed {
                _ = timeline.apply(.toolResults([ToolResult(toolUseID: id, text: "no", isError: true)]))
            }
            guard case .toolCall(let result) = timeline.rows[0] else {
                XCTFail("no call")
                fatalError("unreachable")
            }
            return result
        }

        let summary = ToolRunSummary(calls: [
            call("1", .bash, "swift build"),
            call("2", .read, "a.swift"),
            call("3", .read, "b.swift"),
            call("4", .read, "a.swift"),
            call("5", .grep, "needle")
        ])
        XCTAssertEqual(
            summary.text,
            "Ran 1 command, read 2 files, searched once",
            "ordered by first appearance, and a file read twice is one file"
        )
        XCTAssertNil(summary.attention)

        let failing = ToolRunSummary(calls: [
            call("1", .bash, "swift build", failed: true),
            call("2", .bash, "swift test")
        ])
        XCTAssertEqual(failing.text, "Ran 2 commands")
        XCTAssertEqual(failing.attention, "1 failed", "a fold is the only place a failure can show")
    }

    func testARunThatFailsAfterItsFoldWasDrawnSaysSo() throws {
        let (controller, _) = livePane(width: 1000)
        let events: [StreamEvent] = [
            .assistantMessage(blocks: [
                Self.call("late-1", .bash, "swift build"),
                Self.call("late-2", .bash, "swift test")
            ])
        ]
        for event in events {
            for change in controller.timeline.apply(event) { controller.apply(change) }
        }
        let foldRow = try XCTUnwrap(controller.presentationItems.lastIndex {
            if case .toolFold = $0.content { return true }
            return false
        })
        controller.view.layoutSubtreeIfNeeded()
        _ = controller.tableView.view(atColumn: 0, row: foldRow, makeIfNecessary: true)
        for change in controller.timeline.apply(.toolResults([
            ToolResult(toolUseID: "late-2", text: "boom", isError: true)
        ])) { controller.apply(change) }

        let cell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: foldRow, makeIfNecessary: true))
        XCTAssertTrue(
            Self.labels(in: cell).contains("1 failed"),
            "the fold still reads as clean: \(Self.labels(in: cell))"
        )
    }

    func testARunThatFailsWhileOpenStillSaysSoOnItsDisclosure() throws {
        let (controller, _) = livePane(width: 1000)
        for change in controller.timeline.apply(.assistantMessage(blocks: [
            Self.call("open-1", .bash, "swift build"),
            Self.call("open-2", .bash, "swift test"),
            Self.call("open-3", .bash, "swift run")
        ])) { controller.apply(change) }
        let run = try XCTUnwrap(controller.presentationItems.compactMap { item -> [Int]? in
            guard case .toolFold(let indices) = item.content else { return nil }
            return indices
        }.last)
        controller.scrollToTimelineRow(run[2], animated: false)
        controller.view.layoutSubtreeIfNeeded()

        for change in controller.timeline.apply(.toolResults([
            ToolResult(toolUseID: "open-3", text: "boom", isError: true)
        ])) { controller.apply(change) }

        let foldRow = try XCTUnwrap(controller.presentationItems.firstIndex {
            $0.id == .toolFold(firstIndex: run[0])
        })
        let cell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: foldRow, makeIfNecessary: true))
        XCTAssertTrue(
            Self.labels(in: cell).contains("1 failed"),
            "the open run's own rows stopped the walk short of its disclosure"
        )
    }

    func testOpenedCallsHangFromARuleOneStepIn() throws {
        let (controller, host) = livePane(width: 1000)
        let run = try XCTUnwrap(controller.presentationItems.compactMap { item -> [Int]? in
            guard case .toolFold(let indices) = item.content else { return nil }
            return indices
        }.first)
        controller.scrollToTimelineRow(run[1], animated: false)
        host.layoutSubtreeIfNeeded()

        let foldRow = try XCTUnwrap(controller.presentationItems.firstIndex {
            $0.id == .toolFold(firstIndex: run[0])
        })
        let foldCell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: foldRow, makeIfNecessary: true))
        let fold = try XCTUnwrap(foldCell.subviews.first)
        let childRow = try XCTUnwrap(controller.presentationRow(forTimelineIndex: run[1]))
        let childCell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: childRow, makeIfNecessary: true))
        let child = try XCTUnwrap(childCell.subviews.first)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            child.convert(child.bounds, to: host).minX - fold.convert(fold.bounds, to: host).minX,
            Design.Chat.nestedRowIndent,
            accuracy: 0.5,
            "a call under an open run does not stand one step in from the run's own words"
        )
        XCTAssertEqual(childCell.subviews.count, 2, "the nested row has no rule")
        XCTAssertEqual(foldCell.subviews.count, 1, "the disclosure itself is not nested")
    }

    /// A label's run of a fold is the fold's business; the assertions read what it ended up saying.
    private static func labels(in root: NSView) -> [String] {
        var found: [String] = []
        if let label = root as? NSTextField { found.append(label.stringValue) }
        for child in root.subviews { found += labels(in: child) }
        return found
    }

    private static func toolView(in root: NSView) -> ToolCallView? {
        if let tool = root as? ToolCallView { return tool }
        return root.subviews.lazy.compactMap { toolView(in: $0) }.first
    }
}
