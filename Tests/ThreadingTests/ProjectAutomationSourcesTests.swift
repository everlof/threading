import AppKit
import ThreadingController
import XCTest
@testable import Threading

/// A project's Automations page has to say when an event automation's source keeps it from ever
/// running, and offer the fix there. On 2026-10-05 an automation on the project page read Active
/// while its probe source had never been approved; approval lived on a Sources tab only the
/// app-wide page had, and the two pages had the same title.
@MainActor
final class ProjectAutomationSourcesTests: HostedStoreTestCase {
    private var root: URL!
    private var store: TriggerStore!
    private var project: Project!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-sources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        _ = ProjectStore.shared.renameProject(id: project.id, to: "Ordus")
        self.project = try XCTUnwrap(ProjectStore.shared.project(withID: project.id))
        let store = store!, root = root!
        addTeardownBlock {
            await store.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    /// A probe as `TriggerProbeSourceCommands.configure` leaves it: paused and unapproved.
    private func probe(named name: String) async throws -> TriggerSourceInstallation {
        let script = root.appendingPathComponent("\(name).sh")
        try "#!/bin/sh\necho '{\"cursor\":\"c\"}'\n".write(to: script, atomically: true, encoding: .utf8)
        let spec = ControllerSourceSpec(name: name, executable: "/bin/sh", script: script.path,
                                        arguments: [script.path], environment: [:], secrets: [:],
                                        intervalSeconds: 300, timeoutSeconds: 30, limit: 20)
        return try await TriggerProbeSourceCommands.configure(id: nil, expectedRevision: 0, spec: spec, store: store)
    }

    @discardableResult
    private func eventAutomation(named name: String, waitingOn source: TriggerSourceInstallation) async throws -> TriggerID {
        var config = AutomationConfiguration(projectID: project.id)
        config.name = name
        config.instructions = "Assess the new issue."
        config.options.schedule = nil
        config.sourceID = source.id
        config.eventKind = TriggerProbeDefaults.eventKind
        let id = TriggerID()
        let revision = try await store.configureAutomation(config, id: id, expectedRevision: nil, proposedBy: nil)
        try await store.activate(triggerID: id, revisionID: revision.id)
        return id
    }

    private func center(listener: TriggerListenerState = .running) -> TriggerCenterViewController {
        let receipts = TriggerSourceReceipts(statuses: [:], listener: listener)
        let center = TriggerCenterViewController(store: store, readReceipts: { receipts })
        _ = center.view
        center.showProject(project.id)
        return center
    }

    private static func identifiers(_ view: NSView) -> [String] {
        [view.accessibilityIdentifier()].filter { !$0.isEmpty } + view.subviews.flatMap(identifiers)
    }

    private static func texts(_ view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts)
    }

    private static func buttons(_ view: NSView) -> [String] {
        ((view as? ThemedButton).map { [$0.title] } ?? []) + view.subviews.flatMap(buttons)
    }

    private func row(_ center: TriggerCenterViewController, _ identifier: String) -> NSView? {
        center.drawnRows.first { Self.identifiers($0).contains(identifier) }
    }

    // MARK: - Tests

    func testTheTwoPagesAreTitledApartAndBothHaveSources() {
        let global = TriggerCenterViewController(store: store, readReceipts: { .init(statuses: [:], listener: .running) })
        _ = global.view
        XCTAssertEqual(global.drawnTitle, L10n.string("All automations"))
        XCTAssertEqual(global.drawnPageTitles, ["Automations", "Activity", "Sources", "Remote"].map { L10n.string($0) })

        let projectPage = center()
        XCTAssertEqual(projectPage.drawnTitle, L10n.format("%@ · Automations", "Ordus"))
        XCTAssertEqual(projectPage.drawnPageTitles, ["Automations", "Activity", "Sources"].map { L10n.string($0) },
                       "a project has no remote controllers")
    }

    func testTheProjectPageNamesAnUnapprovedSourceAndOffersItsApprovalSheet() async throws {
        let issues = try await probe(named: "Ordus issues")
        try await eventAutomation(named: "Check new Ordus issue", waitingOn: issues)

        let page = center()
        try await page.prepareEvidencePage(index: 0)

        let attention = try XCTUnwrap(row(page, "automation.source-attention.\(issues.id.uuidString)"),
                                      "the Active automation's unapproved source is not on its page")
        let words = Self.texts(attention)
        XCTAssertTrue(words.contains(L10n.format("Event source “%@”", "Ordus issues")), "\(words)")
        XCTAssertTrue(words.contains(L10n.string("Needs approval")), "\(words)")
        XCTAssertTrue(words.contains { $0.contains("Check new Ordus issue") }, "it names who waits on it: \(words)")
        // The host's own approval sheet, not a shortcut around it.
        XCTAssertTrue(Self.buttons(attention).contains(L10n.string("Review & Approve…")), "\(Self.buttons(attention))")
        XCTAssertEqual(page.drawnRows.filter { Self.identifiers($0).contains { $0.hasPrefix("automation.source-attention.") } }.count, 1)
    }

    func testAnAutomationsOwnPageNamesItsSourceProblem() async throws {
        let issues = try await probe(named: "Ordus issues")
        let id = try await eventAutomation(named: "Check new Ordus issue", waitingOn: issues)

        let page = center()
        try await page.prepareEvidenceDetail(id)

        let attention = try XCTUnwrap(row(page, "automation.source-attention.\(issues.id.uuidString)"))
        XCTAssertTrue(Self.texts(attention).contains(L10n.string("Needs approval")))
        let header = try XCTUnwrap(page.drawnRows.compactMap { $0 as? AutomationDetailHeaderView }.first)
        XCTAssertTrue(Self.buttons(header).contains(L10n.format("%@ · Automations", "Ordus")),
                      "the way back names the project's page, not All automations")
    }

    func testAnApprovedSourceWithAStoppedListenerSaysItIsNotCheckedAndAHealthyOneSaysNothing() async throws {
        let issues = try await probe(named: "Ordus issues")
        let approved = try await TriggerProbeSourceCommands.approve(
            issues.id, expectedRevision: try XCTUnwrap(issues.probe?.revision),
            reviewedHash: try XCTUnwrap(issues.probe?.hash), enable: true, store: store)
        try await eventAutomation(named: "Check new Ordus issue", waitingOn: approved)

        let healthy = center()
        try await healthy.prepareEvidencePage(index: 0)
        XCTAssertNil(row(healthy, "automation.source-attention.\(approved.id.uuidString)"))

        let refused = TriggerListenerState.refused(reason: "OS_REASON_CODESIGNING", attempts: 87)
        let blocked = center(listener: refused)
        try await blocked.prepareEvidencePage(index: 0)
        let attention = try XCTUnwrap(row(blocked, "automation.source-attention.\(approved.id.uuidString)"))
        XCTAssertTrue(Self.texts(attention).contains(L10n.string("Not checked")))
        XCTAssertTrue(Self.texts(attention).contains { $0.hasPrefix(refused.sourceConsequence) })
    }

    func testTheProjectSourcesTabListsOnlyTheSourcesItsAutomationsUse() async throws {
        let issues = try await probe(named: "Ordus issues")
        let unrelated = try await probe(named: "Another project's feed")
        try await eventAutomation(named: "Check new Ordus issue", waitingOn: issues)

        let refused = TriggerListenerState.refused(reason: "OS_REASON_CODESIGNING", attempts: 87)
        let page = center(listener: refused)
        try await page.prepareEvidencePage(index: 2)

        let identifiers = Set(page.drawnRows.flatMap(Self.identifiers))
        XCTAssertTrue(identifiers.contains("probe.\(issues.id.uuidString)"))
        XCTAssertFalse(identifiers.contains("probe.\(unrelated.id.uuidString)"))
        XCTAssertFalse(identifiers.contains("probe.new"), "creating sources is the app-wide page's job")
        let probeRow = try XCTUnwrap(row(page, "probe.\(issues.id.uuidString)"))
        XCTAssertTrue(Self.buttons(probeRow).contains(L10n.string("Review & Approve…")), "\(Self.buttons(probeRow))")
        let listener = try XCTUnwrap(row(page, "sources.listener"))
        XCTAssertTrue(Self.texts(listener).contains(L10n.string("Blocked by macOS")))
        XCTAssertTrue(Self.texts(listener).contains { $0.contains("OS_REASON_CODESIGNING") })
    }
}
