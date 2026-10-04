import AppKit
import XCTest
@testable import Threading

/// The words an automation's row and page share, and the two component modes the page needed:
/// a fact sheet that takes its row's width, and a run of tabs that measures its own titles.
@MainActor
final class AutomationDetailTests: XCTestCase {

    // MARK: - Summary

    func testADraftSaysSoAndOffersReviewRatherThanPause() {
        let (definition, revision) = Self.automation(draft: true, enabled: false)
        let summary = AutomationSummary.make(
            definition: definition, revision: revision, nextRun: Date(), lastRun: nil)
        XCTAssertEqual(summary.state, .draft)
        XCTAssertEqual(summary.stateTone, .attention)
        XCTAssertEqual(summary.stateActionTitle, L10n.string("Review & Activate"))
        XCTAssertNil(summary.nextRun, "A draft runs on no schedule, whatever the store projects.")
        XCTAssertEqual(summary.lastRun, L10n.string("Not run yet"))
    }

    func testAnActiveAutomationNamesItsNextAndLastRun() {
        let (definition, revision) = Self.automation(draft: false, enabled: true)
        let now = Date(timeIntervalSince1970: 1_791_100_000)
        let run = Self.run(revision, state: .failed, at: now.addingTimeInterval(-3_600))
        let summary = AutomationSummary.make(
            definition: definition, revision: revision, nextRun: now.addingTimeInterval(3_600),
            lastRun: run, now: now)
        XCTAssertEqual(summary.state, .active)
        XCTAssertEqual(summary.stateActionTitle, L10n.string("Pause"))
        XCTAssertNotNil(summary.nextRun)
        XCTAssertTrue(summary.lastRun.contains(L10n.string("Failed")), summary.lastRun)
        XCTAssertEqual(summary.lastRunTone, .failure)
        XCTAssertTrue(summary.timing.contains("09:30"), summary.timing)
    }

    func testAPausedAutomationHasNoNextRun() {
        let (definition, revision) = Self.automation(draft: false, enabled: false)
        let summary = AutomationSummary.make(
            definition: definition, revision: revision, nextRun: Date(), lastRun: nil)
        XCTAssertEqual(summary.state, .paused)
        XCTAssertEqual(summary.stateActionTitle, L10n.string("Resume"))
        XCTAssertNil(summary.nextRun)
    }

    func testARunReceiptStatesItsResultAndWhatChanged() {
        let (_, revision) = Self.automation(draft: false, enabled: true)
        var run = Self.run(revision, state: .completed, at: Date())
        run.result = TriggerRunResult(disposition: .fixed, summary: "Report written.",
                                      changedPaths: ["reports/today.md"], tests: ["unit"])
        let review = AutomationRunReview.make(run, automationName: nil)
        XCTAssertEqual(review.instructions, "Report written.")
        XCTAssertEqual(review.facts.map(\.identifier), ["result", "started", "finished", "changed", "tests"])
    }

    // MARK: - Fact sheet

    func testAFactSheetWithoutAMeasureTakesItsRowsWidthAndRewraps() {
        let facts = [FactSheetView.Fact(
            label: "Instructions",
            value: String(repeating: "Read the collected report and write a summary. ", count: 8),
            identifier: "long"
        )]
        var heights: [CGFloat] = []
        for width in [360.0, 900.0] as [CGFloat] {
            let sheet = FactSheetView(facts: facts)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
            host.addSubview(sheet)
            NSLayoutConstraint.activate([
                sheet.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                sheet.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                sheet.topAnchor.constraint(equalTo: host.topAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(sheet.frame.width, width, accuracy: 0.5)
            let reading = Self.descendants(of: sheet).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "fact.long" }
            XCTAssertLessThanOrEqual(reading?.frame.maxX ?? .infinity, width + 0.5,
                                     "A reading ran past the row it was placed in.")
            heights.append(sheet.frame.height)
        }
        XCTAssertGreaterThan(heights[0], heights[1], "A narrower row should wrap the reading onto more lines.")
    }

    // MARK: - Segmented control

    func testARunSizedToItsTitlesNeitherTruncatesNorStretches() {
        let run = ThemedSegmentedControl()
        run.configure(titles: ["Automations", "Activity", "Sources", "Remote"])
        XCTAssertEqual(run.intrinsicContentSize.width, NSView.noIntrinsicMetric,
                       "By default a run takes the measure its row gives it.")
        run.sizesToTitles = true
        let fitted = run.intrinsicContentSize.width
        XCTAssertGreaterThan(fitted, 0)

        let spacer = NSView()
        let row = NSStackView(views: [run, spacer])
        row.orientation = .horizontal
        run.setContentHuggingPriority(.required, for: .horizontal)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 60))
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(run.frame.width, fitted, accuracy: 0.5, "The run stretched across a wide host.")

        for index in 0..<4 {
            let segment = run.segment(at: index)
            let title = segment.flatMap { Self.descendants(of: $0).compactMap { $0 as? NSTextField }.first }
            XCTAssertNotNil(title)
            if let title {
                XCTAssertGreaterThanOrEqual(title.frame.width + 0.5, ceil(title.intrinsicContentSize.width),
                                            "“\(title.stringValue)” was truncated.")
            }
        }
    }

    // MARK: - Fixtures

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func automation(draft: Bool, enabled: Bool) -> (TriggerDefinition, TriggerRevision) {
        let triggerID = TriggerID()
        let revisionID = TriggerRevisionID()
        var revision = TriggerRevision(
            id: revisionID, triggerID: triggerID, sequence: 1,
            sourceInstallationID: TriggerSourceInstallationID(), eventKind: "schedule", conditions: [],
            projectID: ProjectID(), instructions: "Summarize.", agentKind: .claude, accountHandleName: nil,
            model: nil, reasoningEffort: nil, executionMode: .taskLocalEdits, checkoutPolicy: .projectCheckout,
            limits: .conservative, quietHours: nil, notifications: .standard, allowSourceResources: false,
            proposedBySessionID: nil, createdAt: Date())
        revision.automation = .init(
            schedule: .init(kind: .daily, timeZone: "Europe/Stockholm", hour: 9, minute: 30),
            missedRunPolicy: .skip, archiveOnSuccess: true)
        let definition = TriggerDefinition(
            id: triggerID, name: "Bevakning daglig genomgång", enabled: enabled,
            activeRevisionID: draft ? nil : revisionID, draftRevisionID: draft ? revisionID : nil,
            createdAt: Date(), updatedAt: Date())
        return (definition, revision)
    }

    private static func run(_ revision: TriggerRevision, state: TriggerRunState, at date: Date) -> TriggerRun {
        TriggerRun(id: TriggerRunID(), triggerID: revision.triggerID, triggerRevisionID: revision.id,
                   eventKey: "schedule", state: state, queuedAt: date, startedAt: date,
                   settledAt: date.addingTimeInterval(60), sessionID: nil, managedWorkspaceID: nil,
                   holdReason: nil, result: nil, boundedDiagnostic: nil)
    }
}
