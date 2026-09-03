import AppKit
import XCTest
@testable import Threading

/// The info row's contracts: secrets hidden until deliberately revealed, readings written in
/// place, parentage drawn as indent, and a pointer action that VoiceOver can take without a
/// pointer.
@MainActor
final class SessionInfoRowTests: XCTestCase {

    func testDirectoryPathLendsThePanelNoWidthOfItsOwn() {
        func makePanel(path: String) -> SessionInfoViewController {
            let controller = SessionInfoViewController(sessionID: SessionID(), folderPath: path)
            controller.readSource = { completion in completion(.empty) }
            controller.usageSource = { nil }
            controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
            controller.view.layoutSubtreeIfNeeded()
            return controller
        }

        let short = makePanel(path: "/tmp/project")
        let long = makePanel(path: "/tmp/" + String(repeating: "very-long-project-name/", count: 20))

        XCTAssertEqual(
            short.view.fittingSize.width,
            long.view.fittingSize.width,
            accuracy: 0.5,
            "an unbounded session path asked the panel, and therefore the window, to grow"
        )
    }

    /// Usage totals move while the Info pane is being read. A new total with the same rows must
    /// update those rows in place; clearing the list here sends its scroll view straight back to
    /// the top on every indexing event.
    func testUsageReadingUpdateKeepsTheInfoPaneScrollPosition() throws {
        let sessionID = SessionID()
        var usage = usageSnapshot(sessionID: sessionID, scale: 1)
        let controller = SessionInfoViewController(
            sessionID: sessionID,
            folderPath: NSTemporaryDirectory()
        )
        controller.readSource = { completion in completion(.empty) }
        controller.usageSource = { usage }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()

        let scroll = try XCTUnwrap(
            descendants(of: ThemedScrollView.self, in: controller.view).first
        )
        let document = try XCTUnwrap(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        let furthest = max(document.frame.height - scroll.contentView.bounds.height, 0)
        XCTAssertGreaterThan(furthest, 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: furthest))
        scroll.reflectScrolledClipView(scroll.contentView)
        let origin = scroll.contentView.bounds.origin
        XCTAssertGreaterThan(origin.y, 0)
        let valuesBefore = descendants(of: CompoundValueLabel.self, in: controller.view)
            .map(\.plainValue)

        usage = usageSnapshot(sessionID: sessionID, scale: 2)
        controller.applyUsage(usage)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 0.5)
        XCTAssertNotEqual(
            descendants(of: CompoundValueLabel.self, in: controller.view).map(\.plainValue),
            valuesBefore,
            "the fixed rows kept their stale usage reading"
        )
    }

    // MARK: - Fixtures

    private func makeProcessRow(
        commandLine: SessionInfoRowView.CommandLine?,
        indentLevel: Int = 0,
        isExpandable: Bool = false
    ) -> SessionInfoRowView {
        SessionInfoRowView(
            symbolName: "circle.fill",
            symbolColor: Design.Status.positive,
            primary: "node",
            secondary: "50301",
            valueSegments: ["3%", "96 MB"],
            indentLevel: indentLevel,
            commandLine: commandLine,
            isExpandable: isExpandable,
            accessibilityLabel: "node · process 50301"
        )
    }

    /// A home nobody on this machine has, so a fixture path is never folded to `~` by accident.
    private static let elsewhere = "/Users/someone-else"

    private var secretCommandLine: SessionInfoRowView.CommandLine {
        SessionInfoRowView.CommandLine(
            redactedArguments: ["node", "server.js", "--token", "<redacted>"],
            fullArguments: ["node", "server.js", "--token", "abc123"],
            redactedCount: 1,
            home: Self.elsewhere
        )
    }

    /// A startup prompt is one argv element even when it contains paragraphs. The Info panel is
    /// not a transcript: those line breaks must not become row geometry or escape above the
    /// Processes heading, which is the production failure this fixture represents.
    func testMultilineProcessArgumentsBecomeOneDisplayLine() throws {
        let command = try XCTUnwrap(SessionInfoRowView.CommandLine(
            processArguments: [
                "/Users/me/.npm-global/bin/codex",
                "--config",
                "check_for_update_on_startup=false",
                "First prompt line\n\nSecond\tprompt line"
            ],
            home: Self.elsewhere
        ))

        XCTAssertEqual(
            command.fullDisplay,
            "--config check_for_update_on_startup=false First prompt line Second prompt line"
        )
        XCTAssertEqual(
            command.fullLine,
            "/Users/me/.npm-global/bin/codex --config check_for_update_on_startup=false First prompt line Second prompt line"
        )
        XCTAssertFalse(command.fullDisplay.contains(where: { $0.isNewline }))
    }

    // MARK: - Paths & Copy

    /// The home directory folds to `~` wherever it starts a path in what is drawn — at the head
    /// of an argument or after an `=` — and never inside a longer name that merely begins the
    /// same way. The copied line keeps the real paths, quoted so it runs again.
    func testHomeDirectoryFoldsToTildeInWhatIsDrawnButNotInWhatIsCopied() throws {
        let command = try XCTUnwrap(SessionInfoRowView.CommandLine(
            processArguments: [
                "/Users/me/.local/bin/claude",
                "--settings",
                "/Users/me/Library/Application Support/x.json",
                "--socket=/Users/me/run/mcp.sock",
                "/Users/meredith/other"
            ],
            home: "/Users/me"
        ))

        XCTAssertEqual(
            command.redactedDisplay,
            "--settings ~/Library/Application Support/x.json --socket=~/run/mcp.sock /Users/meredith/other"
        )
        XCTAssertTrue(command.redactedLine.hasPrefix("~/.local/bin/claude "))
        XCTAssertEqual(
            command.copyText(revealed: false),
            "/Users/me/.local/bin/claude --settings '/Users/me/Library/Application Support/x.json' "
                + "--socket=/Users/me/run/mcp.sock /Users/meredith/other"
        )
    }

    /// The unfolded block is the command as a person writes it: the program, then a flag with
    /// the value after it on one line, an inline `--key=value` and a positional on their own.
    func testTheBlockPairsAFlagWithItsValueAndCountsWhatItCannotShow() throws {
        let command = try XCTUnwrap(SessionInfoRowView.CommandLine(
            processArguments: [
                "claude", "--model", "opus", "--effort", "xhigh", "--settings=/x",
                "Investigate the panel", "--verbose"
            ],
            home: Self.elsewhere
        ))

        XCTAssertEqual(
            command.block(revealed: false),
            .init(
                lines: [
                    "claude", "--model opus", "--effort xhigh", "--settings=/x",
                    "Investigate the panel", "--verbose"
                ],
                omittedArgumentCount: 0
            )
        )

        let paths = (0..<60).map { "file-\($0).swift" }
        let long = try XCTUnwrap(SessionInfoRowView.CommandLine(
            processArguments: ["swiftlint"] + paths,
            home: Self.elsewhere
        ))
        let block = long.block(revealed: false)
        XCTAssertEqual(block.lines.count, ProcessDetailDefaults.maximumLines)
        XCTAssertEqual(block.omittedArgumentCount, 61 - ProcessDetailDefaults.maximumLines)
    }

    // MARK: - Unfolding

    /// A press on a process row unfolds its command and facts beneath the compact band, and a
    /// second press folds them away again — the same height it started at.
    func testAProcessRowUnfoldsItsCommandAndFoldsBack() throws {
        let row = makeProcessRow(commandLine: secretCommandLine, isExpandable: true)
        row.update(reading(facts: ["Started 8 min ago", "Working directory: ~/repo"]))
        let host = pin(row, width: 320)

        let folded = row.fittingSize.height
        XCTAssertEqual(folded, SessionInfoLayout.rowHeight)
        XCTAssertFalse(row.isExpanded)

        XCTAssertTrue(row.accessibilityPerformPress())
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.isExpanded)
        XCTAssertGreaterThan(row.fittingSize.height, folded)

        let lines = descendants(of: NSTextField.self, in: row).map(\.stringValue)
        XCTAssertTrue(lines.contains("--token <redacted>"), "\(lines)")
        XCTAssertTrue(lines.contains("Started 8 min ago"))
        XCTAssertTrue(lines.contains("Working directory: ~/repo"))
        XCTAssertFalse(lines.contains(where: { $0.contains("abc123") }))

        XCTAssertTrue(row.accessibilityPerformPress())
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.isExpanded)
        XCTAssertEqual(row.fittingSize.height, folded)
    }

    /// A poll writes into an open row without folding it, and the reveal reaches the block.
    func testAReadingAndARevealReachTheOpenBlockWithoutFoldingIt() {
        let row = makeProcessRow(commandLine: secretCommandLine, isExpandable: true)
        row.update(reading(facts: ["Started 8 min ago"]))
        _ = pin(row, width: 320)
        row.setExpanded(true)

        row.update(reading(facts: ["Started 9 min ago"]))
        XCTAssertTrue(row.isExpanded)
        var lines = descendants(of: NSTextField.self, in: row).map(\.stringValue)
        XCTAssertTrue(lines.contains("Started 9 min ago"))
        XCTAssertFalse(lines.contains("Started 8 min ago"))

        row.toggleReveal()
        lines = descendants(of: NSTextField.self, in: row).map(\.stringValue)
        XCTAssertTrue(lines.contains("--token abc123"))
        XCTAssertFalse(lines.contains("--token <redacted>"))
    }

    /// A row that cannot unfold does not pretend to: no help, no press, no hover.
    func testARowWithoutAFoldStaysInert() {
        let row = makeProcessRow(commandLine: secretCommandLine, isExpandable: false)
        XCTAssertFalse(row.accessibilityPerformPress())
        XCTAssertNil(row.accessibilityHelp())
        XCTAssertEqual(row.restingPointer, .arrow)

        let unfoldable = makeProcessRow(commandLine: secretCommandLine, isExpandable: true)
        XCTAssertNotNil(unfoldable.accessibilityHelp())
        XCTAssertEqual(unfoldable.restingPointer, .pointingHand)
    }

    /// The panel remembers which processes were open across a rebuild — a sibling process
    /// exiting must not fold the command a person is reading.
    func testThePanelKeepsOpenRowsOpenAcrossARebuild() throws {
        let controller = makePanel(applying: treeSnapshot)
        let node = try XCTUnwrap(processRow(in: controller, pid: 200))
        XCTAssertTrue(node.accessibilityPerformPress())
        XCTAssertTrue(node.isExpanded)

        var processes = treeSnapshot.processGroups[0].processes
        processes.append(SessionProcess(
            pid: 400, command: "esbuild", memoryBytes: 0, cpuPercent: nil, depth: 2
        ))
        let grown = SessionInfoSnapshot(
            processGroups: [SessionProcessGroup(origin: .agent, processes: processes)],
            portGroups: []
        )
        controller.apply(grown, isRunning: true)

        let rebuilt = try XCTUnwrap(processRow(in: controller, pid: 200))
        XCTAssertFalse(rebuilt === node)
        XCTAssertTrue(rebuilt.isExpanded)
        XCTAssertFalse(try XCTUnwrap(processRow(in: controller, pid: 100)).isExpanded)
    }

    /// The fold inside the panel's own list, hosted the way the render harness hosts it: the
    /// open row grows in the scroll document, and the row under it moves down by as much.
    func testAnUnfoldedRowGrowsInsideThePanelsList() throws {
        let controller = SessionInfoViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory()
        )
        controller.readSource = { completion in completion(self.treeSnapshot) }
        controller.usageSource = { nil }

        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let view = controller.view
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        controller.apply(treeSnapshot, isRunning: true)
        host.layoutSubtreeIfNeeded()

        let claude = try XCTUnwrap(processRow(in: controller, pid: 100))
        let node = try XCTUnwrap(processRow(in: controller, pid: 200))
        let foldedHeight = claude.frame.height
        let nodeBefore = node.convert(node.bounds, to: host).minY

        claude.setExpanded(true)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(claude.isExpanded)
        XCTAssertGreaterThan(claude.frame.height, foldedHeight)
        XCTAssertNotEqual(node.convert(node.bounds, to: host).minY, nodeBefore)
    }

    private func pin(_ row: SessionInfoRowView, width: CGFloat) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func processRow(
        in controller: SessionInfoViewController,
        pid: pid_t
    ) -> SessionInfoRowView? {
        let identifier = SessionInfoDefaults.processRowIdentifier(pid)
        return descendants(of: SessionInfoRowView.self, in: controller.view)
            .first { $0.accessibilityIdentifier() == identifier }
    }

    // MARK: - Receipt

    /// The receipt says each thing once: without delegated work the main agent is the total,
    /// and one model is named beside the total rather than restated under a heading of its own.
    func testTheReceiptSaysEachThingOnce() {
        let sessionID = SessionID()
        let single = usageSnapshot(
            sessionID: sessionID,
            scale: 1,
            models: [
                .init(
                    name: "claude-opus-4-6",
                    tokens: .init(uncachedInput: 1_000, output: 100),
                    cost: .init(catalogPricedUSD: 0.5),
                    records: 3
                )
            ]
        )
        let controller = SessionInfoViewController(sessionID: sessionID, folderPath: NSTemporaryDirectory())
        controller.readSource = { completion in completion(.empty) }
        controller.usageSource = { single }
        _ = controller.view

        var labels = descendants(of: NSTextField.self, in: controller.view).map(\.stringValue)
        XCTAssertFalse(labels.contains("Main agent"))
        XCTAssertFalse(labels.contains("Subagents"))
        XCTAssertFalse(labels.contains("Models"))
        // The count is the total's, not the model's: the model is named, not restated.
        XCTAssertTrue(labels.contains("10 requests · Opus 4.6"), "\(labels)")

        let delegated = SessionUsageSnapshot(
            sessionID: sessionID,
            total: single.total,
            main: single.main,
            subagents: .init(tokens: .init(output: 40), records: 1),
            children: ["child": .init(tokens: .init(output: 40))],
            indexedRange: .lifetime,
            builtAt: single.builtAt,
            pricingCatalogVersion: single.pricingCatalogVersion,
            coverage: nil
        )
        controller.usageSource = { delegated }
        labels = descendants(of: NSTextField.self, in: controller.view).map(\.stringValue)
        XCTAssertTrue(labels.contains("Main agent"))
        XCTAssertTrue(labels.contains("Subagents"))
        XCTAssertFalse(labels.contains("Models"))

        controller.usageSource = { self.usageSnapshot(sessionID: sessionID, scale: 1) }
        labels = descendants(of: NSTextField.self, in: controller.view).map(\.stringValue)
        XCTAssertTrue(labels.contains("Models"))
        XCTAssertFalse(labels.contains("Main agent"))
    }

    private func reading(facts: [String]) -> SessionInfoRowView.Reading {
        SessionInfoRowView.Reading(
            valueSegments: ["3%", "96 MB"],
            dotSymbolName: "circle.fill",
            dotColor: Design.Status.positive,
            factLines: facts,
            accessibilityValue: "3% · 96 MB"
        )
    }

    private func secondaryText(of row: SessionInfoRowView) -> String? {
        descendants(of: NSTextField.self, in: row)
            .first { $0.stringValue.contains("50301") }?
            .stringValue
    }

    private func descendants<T>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            let match = (subview as? T).map { [$0] } ?? []
            return match + descendants(of: type, in: subview)
        }
    }

    private func usageSnapshot(
        sessionID: SessionID,
        scale: Int64,
        models: [SessionUsageSnapshot.Model]? = nil
    ) -> SessionUsageSnapshot {
        let models = models ?? Self.defaultModels(scale: scale)
        let reading = SessionUsageSnapshot.Reading(
            tokens: .init(
                uncachedInput: scale * 12_000,
                cachedInput: scale * 24_000,
                cacheWrite: scale * 2_000,
                output: scale * 4_000,
                reasoning: scale * 1_000
            ),
            cost: .init(catalogPricedUSD: Double(scale)),
            records: Int(scale * 10),
            models: models
        )
        return SessionUsageSnapshot(
            sessionID: sessionID,
            total: reading,
            main: reading,
            subagents: .init(),
            children: [:],
            indexedRange: .lifetime,
            builtAt: Date(timeIntervalSince1970: 1_800_000_000),
            pricingCatalogVersion: UsagePricingCatalog.version,
            coverage: nil
        )
    }

    private static func defaultModels(scale: Int64) -> [SessionUsageSnapshot.Model] {
        (0..<SessionUsageDefaults.maximumModelRows).map { index -> SessionUsageSnapshot.Model in
            let tokens = UsageTokenCounts(
                uncachedInput: scale * Int64(1_000 + index),
                cachedInput: scale * Int64(2_000 + index),
                output: scale * Int64(100 + index)
            )
            let cost = UsageReportSelection.CostQuality(
                catalogPricedUSD: Double(scale * Int64(index + 1)) / 10
            )
            return SessionUsageSnapshot.Model(
                name: "model-\(index)",
                tokens: tokens,
                cost: cost,
                records: Int(scale) + index
            )
        }
    }

    // MARK: - Redaction & Reveal

    /// The row draws the redacted line by default — nowhere on screen or in the tooltip does
    /// the raw value appear until the reveal is chosen.
    func testSecretsAreHiddenUntilRevealed() {
        let row = makeProcessRow(commandLine: secretCommandLine)
        row.update(reading(facts: ["Started 8 min ago"]))

        XCTAssertEqual(secondaryText(of: row), "50301 · server.js --token <redacted>")
        XCTAssertFalse(row.revealsFullCommand)

        let toolTip = row.toolTip ?? ""
        XCTAssertTrue(toolTip.contains("node server.js --token <redacted>"))
        XCTAssertTrue(toolTip.contains("Started 8 min ago"))
        XCTAssertFalse(toolTip.contains("abc123"))
    }

    func testRevealSwapsTheSecondaryAndTheToolTipAndBack() {
        let row = makeProcessRow(commandLine: secretCommandLine)
        row.update(reading(facts: []))

        row.toggleReveal()
        XCTAssertTrue(row.revealsFullCommand)
        XCTAssertEqual(secondaryText(of: row), "50301 · server.js --token abc123")
        XCTAssertTrue(row.toolTip?.contains("abc123") == true)

        row.toggleReveal()
        XCTAssertEqual(secondaryText(of: row), "50301 · server.js --token <redacted>")
        XCTAssertFalse(row.toolTip?.contains("abc123") == true)
    }

    /// Any command line can be copied; a reveal is offered only when something was hidden. A
    /// row without a command line has no menu, and the pointerless route answers the same way.
    func testTheMenuOffersACopyAlwaysAndARevealOnlyWhenSomethingWasHidden() {
        let innocent = SessionInfoRowView.CommandLine(
            redactedArguments: ["node", "server.js", "--port", "3000"],
            fullArguments: ["node", "server.js", "--port", "3000"],
            redactedCount: 0,
            home: Self.elsewhere
        )

        XCTAssertEqual(titles(of: makeProcessRow(commandLine: innocent).menuEntries()), ["Copy Command Line"])
        XCTAssertEqual(
            titles(of: makeProcessRow(commandLine: secretCommandLine).menuEntries()),
            ["Copy Command Line", "Show Full Command"]
        )
        XCTAssertTrue(makeProcessRow(commandLine: nil).menuEntries().isEmpty)
        XCTAssertFalse(makeProcessRow(commandLine: nil).accessibilityPerformShowMenu())
    }

    private func titles(of entries: [ThemedMenuEntry]) -> [String] {
        entries.compactMap { entry in
            if case .item(let item) = entry { return item.title }
            return nil
        }
    }

    // MARK: - Readings In Place

    /// A poll writes into the row that is already there: the value, the dot, the tooltip and
    /// the spoken value all move without the row being replaced.
    func testAReadingIsWrittenInPlace() {
        let row = makeProcessRow(commandLine: nil)

        row.update(SessionInfoRowView.Reading(
            valueSegments: ["0%", "12 MB"],
            dotSymbolName: "circle",
            dotColor: Design.Status.warning,
            factLines: ["Stopped"],
            accessibilityValue: "Stopped · 0% · 12 MB"
        ))

        XCTAssertEqual(row.accessibilityValue() as? String, "Stopped · 0% · 12 MB")
        XCTAssertTrue(row.toolTip?.contains("Stopped") == true)

        let value = descendants(of: CompoundValueLabel.self, in: row).first
        XCTAssertEqual(value?.plainValue, "0% · 12 MB")
    }

    // MARK: - Indentation

    /// Parentage is drawn by the dot column: one step per level, measured against a sibling at
    /// the root.
    func testIndentGrowsByOneStepPerLevel() {
        let root = makeProcessRow(commandLine: nil, indentLevel: 0)
        let grandchild = makeProcessRow(commandLine: nil, indentLevel: 2)

        for row in [root, grandchild] {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(row)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: 320),
                row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                row.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            host.layoutSubtreeIfNeeded()
        }

        let rootGlyph = descendants(of: GlyphView.self, in: root).first
        let deepGlyph = descendants(of: GlyphView.self, in: grandchild).first
        XCTAssertEqual(
            (deepGlyph?.frame.origin.x ?? 0) - (rootGlyph?.frame.origin.x ?? 0),
            2 * Design.Spacing.medium
        )
    }

    /// The cap: a runaway chain flattens rather than pushing the name into the value.
    func testIndentIsCapped() {
        let capped = makeProcessRow(commandLine: nil, indentLevel: 40)
        let atCap = makeProcessRow(commandLine: nil, indentLevel: SessionInfoLayout.maxIndentDepth)

        for row in [capped, atCap] {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(row)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: 320),
                row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                row.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            host.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(
            descendants(of: GlyphView.self, in: capped).first?.frame.origin.x,
            descendants(of: GlyphView.self, in: atCap).first?.frame.origin.x
        )
    }

    /// A real agent command can carry an opening prompt or configuration paths long enough to
    /// wrap many times. Each description owns one line in the compact row and must truncate
    /// horizontally instead of painting through its sibling or the reading on the right.
    func testLongCommandLineKeepsTwoTextLinesSeparateFromTheReading() throws {
        let arguments = ["claude"] + Array(
            repeating: ["--settings", "/Users/me/Library/Application Support/Threading"],
            count: 8
        ).flatMap { $0 }
        let longCommand = SessionInfoRowView.CommandLine(
            redactedArguments: arguments,
            fullArguments: arguments,
            redactedCount: 0,
            home: Self.elsewhere
        )
        let row = makeProcessRow(commandLine: longCommand)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 312),
            host.heightAnchor.constraint(equalToConstant: SessionInfoLayout.rowHeight),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor)
        ])

        host.layoutSubtreeIfNeeded()

        let labels = descendants(of: NSTextField.self, in: row)
        let primary = try XCTUnwrap(labels.first { $0.stringValue == "node" })
        let secondary = try XCTUnwrap(labels.first { $0.stringValue.contains("50301") })
        let value = try XCTUnwrap(descendants(of: CompoundValueLabel.self, in: row).first)

        let primaryFrame = primary.convert(primary.bounds, to: row)
        let secondaryFrame = secondary.convert(secondary.bounds, to: row)
        let valueFrame = value.convert(value.bounds, to: row)

        XCTAssertFalse(primaryFrame.intersects(secondaryFrame))
        XCTAssertLessThanOrEqual(primaryFrame.maxX + Design.Spacing.tight, valueFrame.minX)
        XCTAssertLessThanOrEqual(secondaryFrame.maxX + Design.Spacing.tight, valueFrame.minX)

        for label in labels {
            let frame = label.convert(label.bounds, to: row)
            XCTAssertTrue(label.usesSingleLineMode)
            XCTAssertGreaterThanOrEqual(frame.minY, row.bounds.minY)
            XCTAssertLessThanOrEqual(frame.maxY, row.bounds.maxY)
        }
    }

    // MARK: - Accessibility

    /// The port row is a link VoiceOver can press; the process row is a quiet group. Both speak
    /// as one element so nothing inside is announced twice.
    func testTheActionRowIsAPressableLink() {
        var opened = false
        let row = SessionInfoRowView(
            symbolName: "globe",
            symbolColor: Design.Text.secondary,
            primary: "3000",
            secondary: "node",
            valueSegments: ["localhost"],
            accessibilityLabel: "Port 3000 · node",
            action: { opened = true }
        )

        XCTAssertEqual(row.accessibilityRole(), .link)
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertTrue(opened)
    }

    func testTheInertRowIsAGroupAndDoesNotPretendToPress() {
        let row = makeProcessRow(commandLine: nil)

        XCTAssertEqual(row.accessibilityRole(), .group)
        XCTAssertFalse(row.accessibilityPerformPress())
        XCTAssertEqual(row.accessibilityLabel(), "node · process 50301")
    }

    // MARK: - Stop Affordance

    private func makePanel(applying snapshot: SessionInfoSnapshot) -> SessionInfoViewController {
        let controller = SessionInfoViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory()
        )
        controller.readSource = { completion in completion(snapshot) }
        _ = controller.view
        controller.apply(snapshot, isRunning: !snapshot.processes.isEmpty)
        return controller
    }

    private func stopButton(in view: NSView, titled title: String) -> ThemedIconButton? {
        if let button = view as? ThemedIconButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let found = stopButton(in: subview, titled: title) { return found }
        }
        return nil
    }

    private var treeSnapshot: SessionInfoSnapshot {
        SessionInfoSnapshot(
            processGroups: [SessionProcessGroup(origin: .agent, processes: [
                SessionProcess(
                    pid: 100, command: "claude", memoryBytes: 0, cpuPercent: nil,
                    depth: 0, startTime: ProcessStartTime(seconds: 10, microseconds: 1)
                ),
                SessionProcess(
                    pid: 200, command: "node", memoryBytes: 0, cpuPercent: nil,
                    depth: 1, startTime: ProcessStartTime(seconds: 20, microseconds: 2)
                ),
                SessionProcess(
                    pid: 300, command: "orphanish", memoryBytes: 0, cpuPercent: nil,
                    depth: 1, startTime: nil
                )
            ])],
            portGroups: []
        )
    }

    /// The root row never offers a stop — session teardown owns it — and neither does a row
    /// whose start identity could not be read: no identity, no kill.
    func testOnlyANonRootProcessWithAnIdentityOffersStop() {
        let controller = makePanel(applying: treeSnapshot)

        XCTAssertNil(stopButton(in: controller.view, titled: "Stop claude"))
        XCTAssertNil(stopButton(in: controller.view, titled: "Stop orphanish"))
        XCTAssertNotNil(stopButton(in: controller.view, titled: "Stop node"))
    }

    /// The press asks first, and the captured identity travels with the answer.
    func testAConfirmedStopSendsThePidAndItsCapturedIdentity() throws {
        let controller = makePanel(applying: treeSnapshot)

        var asked: ConfirmationRequest?
        controller.confirmStop = { request in
            asked = request
            return true
        }
        var stopped: (pid: pid_t, start: ProcessStartTime)?
        controller.onStopProcess = { pid, start in stopped = (pid, start) }

        let button = try XCTUnwrap(stopButton(in: controller.view, titled: "Stop node"))
        button.onPress?()

        XCTAssertEqual(asked?.prompt, .stopSessionProcess)
        XCTAssertEqual(asked?.title, "Stop node?")
        XCTAssertEqual(stopped?.pid, 200)
        XCTAssertEqual(stopped?.start, ProcessStartTime(seconds: 20, microseconds: 2))
    }

    func testADeclinedStopSignalsNothing() throws {
        let controller = makePanel(applying: treeSnapshot)

        controller.confirmStop = { _ in false }
        var stopped = false
        controller.onStopProcess = { _, _ in stopped = true }

        let button = try XCTUnwrap(stopButton(in: controller.view, titled: "Stop node"))
        button.onPress?()

        XCTAssertFalse(stopped)
    }

    // MARK: - Compound Value

    /// The value gives up whole segments, never characters: at full width both parts fit, at a
    /// squeezed width the memory half drops complete, and cramped to nothing it says nothing.
    func testTheValueDropsWholeSegmentsWhenSqueezed() {
        let label = CompoundValueLabel()
        label.segments = ["3%", "96 MB"]

        let full = label.intrinsicContentSize.width
        XCTAssertEqual(label.drawableSegmentCount(in: full), 2)

        let firstOnly = CompoundValueLabel()
        firstOnly.segments = ["3%"]
        XCTAssertEqual(label.drawableSegmentCount(in: firstOnly.intrinsicContentSize.width + 1), 1)

        XCTAssertEqual(label.drawableSegmentCount(in: 2), 0)
        XCTAssertEqual(label.plainValue, "3% · 96 MB")
    }
}
