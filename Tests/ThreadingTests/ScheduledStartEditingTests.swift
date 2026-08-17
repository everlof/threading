import AppKit
import XCTest
@testable import Threading

/// Editing a scheduled start borrows the composer; it never spends the record.
///
/// The first Edit gesture detached the pictures, removed the record and its reserved
/// conversation, and poured the text into the box — so tapping a row silently unscheduled it,
/// and tapping a second row destroyed both while the box could only hold one. These tests pin
/// the replacement contract: the record stays in the store, still armed, until Save rewrites it
/// in place; Cancel hands the box back untouched; and opening a second row saves the first.
@MainActor
final class ScheduledStartEditingTests: HostedStoreTestCase {

    private var projectFolder: URL!

    override func setUp() {
        super.setUp()
        projectFolder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheduled-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: projectFolder,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        if let projectFolder { try? FileManager.default.removeItem(at: projectFolder) }
        projectFolder = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeComposer() throws -> (SessionComposerViewController, ProjectID) {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: projectFolder))
        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: project.id)
        return (composer, project.id)
    }

    @discardableResult
    private func schedule(
        _ brief: String,
        on composer: SessionComposerViewController,
        in projectID: ProjectID
    ) throws -> ScheduledMessage {
        composer.promptView.stringValue = brief
        composer.scheduleStart(at: Date().addingTimeInterval(3_600), anchor: .wallClock)
        return try XCTUnwrap(
            ScheduledMessageStore.shared.sessionStarts(in: projectID)
                .first { $0.text == brief },
            "scheduling '\(brief)' left no record"
        )
    }

    // MARK: - Opening

    func testOpeningARowForEditingLeavesTheRecordArmedInTheStore() throws {
        let (composer, projectID) = try makeComposer()
        let message = try schedule("Run the release audit", on: composer, in: projectID)
        let reservedID = try XCTUnwrap(message.target.sessionID)

        composer.beginEditingScheduledStart(message.id)

        let record = try XCTUnwrap(ScheduledMessageStore.shared[message.id])
        XCTAssertEqual(record.state, .armed, "opening an edit must not disturb the schedule")
        XCTAssertEqual(record.text, "Run the release audit")
        XCTAssertNotNil(
            ProjectStore.shared.session(withID: reservedID),
            "the reserved conversation must survive the edit being opened"
        )
        XCTAssertEqual(composer.editingScheduledStartID, message.id)
        XCTAssertEqual(composer.promptView.stringValue, "Run the release audit")
    }

    func testOpeningASecondRowSavesTheFirstInsteadOfDestroyingEither() throws {
        let (composer, projectID) = try makeComposer()
        let first = try schedule("Fix the importer", on: composer, in: projectID)
        let second = try schedule("Write the changelog", on: composer, in: projectID)

        composer.beginEditingScheduledStart(first.id)
        composer.promptView.stringValue = "Fix the importer and its tests"
        composer.beginEditingScheduledStart(second.id)

        XCTAssertEqual(
            ScheduledMessageStore.shared[first.id]?.text,
            "Fix the importer and its tests",
            "opening the second row should have saved the first's edits"
        )
        XCTAssertNotNil(
            ScheduledMessageStore.shared[second.id],
            "the second record must survive being opened"
        )
        XCTAssertEqual(composer.editingScheduledStartID, second.id)
        XCTAssertEqual(composer.promptView.stringValue, "Write the changelog")
    }

    // MARK: - Cancelling

    func testCancelRestoresTheDraftAndLeavesTheRecordUntouched() throws {
        let (composer, projectID) = try makeComposer()
        let message = try schedule("Run the tests", on: composer, in: projectID)

        composer.promptView.stringValue = "a half-typed draft"
        DraftStore.shared.setDraft("a half-typed draft", for: projectID)

        composer.beginEditingScheduledStart(message.id)
        composer.promptView.stringValue = "changes the user thought better of"
        composer.cancelScheduledStartEdit()

        XCTAssertEqual(ScheduledMessageStore.shared[message.id]?.text, "Run the tests")
        XCTAssertNil(composer.editingScheduledStartID)
        XCTAssertEqual(composer.promptView.stringValue, "a half-typed draft")
        XCTAssertEqual(DraftStore.shared.draft(for: projectID), "a half-typed draft")
    }

    // MARK: - Saving

    func testCommitRewritesTheRecordInPlaceAndKeepsTheReservation() throws {
        let (composer, projectID) = try makeComposer()
        let message = try schedule("Run the tests", on: composer, in: projectID)
        let reservedID = try XCTUnwrap(message.target.sessionID)
        let dueAt = try XCTUnwrap(message.dueAt)

        composer.beginEditingScheduledStart(message.id)
        composer.promptView.stringValue = "Run the whole audit instead"
        XCTAssertTrue(composer.commitScheduledStartEdit())

        let record = try XCTUnwrap(ScheduledMessageStore.shared[message.id])
        XCTAssertEqual(record.text, "Run the whole audit instead")
        XCTAssertEqual(record.dueAt, dueAt, "Save keeps the moment; only the menu changes it")
        XCTAssertEqual(
            record.target.sessionID,
            reservedID,
            "an edit that changed only the words keeps the reserved conversation"
        )
        let session = try XCTUnwrap(ProjectStore.shared.session(withID: reservedID))
        XCTAssertEqual(
            session.title,
            SessionNaming.promptTitle(from: "Run the whole audit instead"),
            "the kept row follows the rewritten brief"
        )
        XCTAssertNil(composer.editingScheduledStartID)
        XCTAssertEqual(composer.promptView.stringValue, "", "the box returns to the draft")
    }

    func testCommitWithAChangedConfigurationReReservesWithoutLosingTheRecord() throws {
        let (composer, projectID) = try makeComposer()
        let message = try schedule("Run the tests", on: composer, in: projectID)
        let oldReservedID = try XCTUnwrap(message.target.sessionID)

        composer.beginEditingScheduledStart(message.id)
        composer.selectedModel = "some-other-model"
        XCTAssertTrue(composer.commitScheduledStartEdit())

        let record = try XCTUnwrap(
            ScheduledMessageStore.shared[message.id],
            "a configuration change must rewrite the record, never drop it"
        )
        guard case .newSession(let plan) = record.target else {
            return XCTFail("the record stopped being a session start")
        }
        XCTAssertEqual(plan.model, "some-other-model")
        let newReservedID = try XCTUnwrap(plan.reservedSessionID)
        XCTAssertNotEqual(newReservedID, oldReservedID)
        XCTAssertNotNil(ProjectStore.shared.session(withID: newReservedID))
        XCTAssertNil(
            ProjectStore.shared.session(withID: oldReservedID),
            "the superseded reservation should leave with its plan"
        )
    }

    // MARK: - The Record Leaving Mid-Edit

    func testARecordRemovedMidEditEndsTheEditKeepingTheWords() throws {
        let (composer, projectID) = try makeComposer()
        let message = try schedule("Run the tests", on: composer, in: projectID)

        composer.beginEditingScheduledStart(message.id)
        composer.promptView.stringValue = "words typed into the borrowed box"
        XCTAssertTrue(ScheduledMessageStore.shared.remove(message.id))

        XCTAssertNil(
            composer.editingScheduledStartID,
            "the edit cannot outlive the record it was editing"
        )
        XCTAssertEqual(
            composer.promptView.stringValue,
            "words typed into the borrowed box",
            "the box held the only copy, so it keeps it"
        )
        XCTAssertEqual(
            DraftStore.shared.draft(for: projectID),
            "words typed into the borrowed box"
        )
    }
}
