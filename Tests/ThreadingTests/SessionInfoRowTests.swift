import AppKit
import XCTest
@testable import Threading

/// The info row's contracts: secrets hidden until deliberately revealed, readings written in
/// place, parentage drawn as indent, and a pointer action that VoiceOver can take without a
/// pointer.
@MainActor
final class SessionInfoRowTests: XCTestCase {

    // MARK: - Fixtures

    private func makeProcessRow(
        commandLine: SessionInfoRowView.CommandLine?,
        indentLevel: Int = 0
    ) -> SessionInfoRowView {
        SessionInfoRowView(
            symbolName: "circle.fill",
            symbolColor: Design.Status.positive,
            primary: "node",
            secondary: "50301",
            valueSegments: ["3%", "96 MB"],
            indentLevel: indentLevel,
            commandLine: commandLine,
            accessibilityLabel: "node · process 50301"
        )
    }

    private var secretCommandLine: SessionInfoRowView.CommandLine {
        SessionInfoRowView.CommandLine(
            redactedDisplay: "server.js --token <redacted>",
            fullDisplay: "server.js --token abc123",
            redactedLine: "node server.js --token <redacted>",
            fullLine: "node server.js --token abc123",
            redactedCount: 1
        )
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
        row.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("50301") }?
            .stringValue
    }

    // MARK: - Redaction & Reveal

    /// The row draws the redacted line by default — nowhere on screen or in the tooltip does
    /// the raw value appear until the reveal is chosen.
    func testSecretsAreHiddenUntilRevealed() {
        let row = makeProcessRow(commandLine: secretCommandLine)
        row.update(reading(facts: ["Started 8 min ago"]))

        XCTAssertEqual(secondaryText(of: row), "50301  server.js --token <redacted>")
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
        XCTAssertEqual(secondaryText(of: row), "50301  server.js --token abc123")
        XCTAssertTrue(row.toolTip?.contains("abc123") == true)

        row.toggleReveal()
        XCTAssertEqual(secondaryText(of: row), "50301  server.js --token <redacted>")
        XCTAssertFalse(row.toolTip?.contains("abc123") == true)
    }

    /// A command line that hid nothing has nothing to reveal, so the menu is not offered — and
    /// the pointerless route answers the same way.
    func testTheRevealMenuIsOnlyOfferedWhenSomethingWasHidden() {
        let innocent = SessionInfoRowView.CommandLine(
            redactedDisplay: "server.js --port 3000",
            fullDisplay: "server.js --port 3000",
            redactedLine: "node server.js --port 3000",
            fullLine: "node server.js --port 3000",
            redactedCount: 0
        )

        XCTAssertFalse(makeProcessRow(commandLine: innocent).accessibilityPerformShowMenu())
        XCTAssertFalse(makeProcessRow(commandLine: nil).accessibilityPerformShowMenu())
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

        let value = row.subviews.compactMap { $0 as? CompoundValueLabel }.first
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

        let rootGlyph = root.subviews.compactMap { $0 as? GlyphView }.first
        let deepGlyph = grandchild.subviews.compactMap { $0 as? GlyphView }.first
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
            capped.subviews.compactMap { $0 as? GlyphView }.first?.frame.origin.x,
            atCap.subviews.compactMap { $0 as? GlyphView }.first?.frame.origin.x
        )
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
