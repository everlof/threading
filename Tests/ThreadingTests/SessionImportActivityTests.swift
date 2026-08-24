import Foundation
import XCTest
@testable import Threading

/// What the import sheet says about a conversation, and what it does with more than one of them.
///
/// Two of these were shipped wrong and both were visible in the sheet: seven conversations
/// stacked at the top reading "4 min ago" when one of them was live and the rest had been idle
/// for eight hours, and the same conversation offered twice because two accounts hold a copy.
@MainActor
final class SessionImportActivityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-import-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Last Activity

    func testActivityIsTheLastTurnRatherThanTheLastWrite() throws {
        // A conversation that ended at 10:35, then the bookkeeping Claude re-appends whenever a
        // CLI starts — none of it timestamped, all of it written hours later.
        let transcript = try write(
            lines: [
                #"{"type":"user","timestamp":"2026-08-06T06:20:00.000Z","message":{"content":"hi"}}"#,
                #"{"type":"assistant","timestamp":"2026-08-06T08:35:15.527Z","message":{}}"#,
                #"{"type":"file-history-snapshot","messageId":"abc"}"#,
                #"{"type":"bridge-session","bridgeId":"xyz"}"#,
                #"{"type":"last-prompt","lastPrompt":"so is there anything that needs fixing?"}"#
            ],
            modified: Date()
        )

        let activity = SessionImporter.lastActivity(at: transcript)

        XCTAssertEqual(
            activity.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-06T08:35:15Z")!.timeIntervalSince1970,
            accuracy: 1,
            "The newest turn is the answer, not the newest write"
        )
        XCTAssertLessThan(
            activity,
            SessionImporter.modificationDate(of: transcript),
            "A file touched long after its conversation ended must not read as recent"
        )
    }

    func testActivityFallsBackToTheFileWhenNothingIsStamped() throws {
        // A transcript holding only a title record: 3 of this project's 276 look like this.
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        let transcript = try write(
            lines: [#"{"type":"ai-title","aiTitle":"Implement the diff plan"}"#],
            modified: written
        )

        XCTAssertEqual(
            SessionImporter.lastActivity(at: transcript).timeIntervalSince1970,
            written.timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testActivityReadsCodexRolloutStamps() throws {
        let transcript = try write(
            lines: [
                #"{"timestamp":"2026-08-05T09:00:00.000Z","type":"session_meta","payload":{}}"#,
                #"{"timestamp":"2026-08-05T11:11:45.000Z","type":"event_msg","payload":{}}"#
            ],
            modified: Date()
        )

        XCTAssertEqual(
            SessionImporter.lastActivity(at: transcript).timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-05T11:11:45Z")!.timeIntervalSince1970,
            accuracy: 1
        )
    }

    // MARK: - Duplicates

    func testAConversationHeldByTwoAccountsIsOfferedOnce() {
        let older = session(id: shared, account: "nhartley", activeAt: 3_000)
        let newer = session(id: shared, account: "ikeller", activeAt: 9_000)
        let other = session(id: toolbarID, account: nil, activeAt: 5_000)

        let offered = SessionImporter.deduplicated(
            [newer, other, older].sorted { $0.lastActiveAt > $1.lastActiveAt }
        )

        XCTAssertEqual(
            offered.map(\.agentSessionID.rawValue),
            [shared, toolbarID],
            "Both rows resume the same transcript, so only one is worth offering"
        )
        XCTAssertEqual(
            offered.first?.accountHandle,
            newer.accountHandle,
            "The surviving copy is the account that ran it most recently"
        )
    }

    func testTwoAgentsMayShareAnIdentifierWithoutCollapsing() {
        let claude = session(id: shared, account: nil, activeAt: 9_000)
        var codex = session(id: shared, account: nil, activeAt: 5_000)
        codex = ImportableSession(
            agentSessionID: codex.agentSessionID,
            kind: .codex,
            accountHandle: codex.accountHandle,
            title: codex.title,
            lastActiveAt: codex.lastActiveAt
        )

        XCTAssertEqual(SessionImporter.deduplicated([claude, codex]).count, 2)
    }

    // MARK: - Multiple Selection

    func testASelectionSurvivesTheSearchThatHidesIt() throws {
        let sheet = makeSheet()

        sheet.selectSessions(withIDs: [sidebarID, toolbarID])
        XCTAssertEqual(sheet.importButtonTitleForTesting, "Import 2 conversations")

        // Narrowing to something neither of them matches must not quietly drop them: the count
        // on the button is the only thing saying so, which is why it is asserted here.
        sheet.updateSearchQuery("composer")
        XCTAssertEqual(sheet.visibleSessionIDs, [composerID])
        XCTAssertEqual(
            sheet.selectedSessions.map(\.agentSessionID.rawValue),
            [sidebarID, toolbarID]
        )
        XCTAssertEqual(sheet.importButtonTitleForTesting, "Import 2 conversations")
    }

    func testASearchThatKeepsAChosenRowKeepsTheChoice() throws {
        let sheet = makeSheet()
        sheet.selectSessions(withIDs: [sidebarID, toolbarID])

        // The dangerous case, and the one a filter hits every keystroke: the query still shows
        // one of the chosen rows. Reloading the table clears its selection and reports that
        // like any other change, so a controller reading it back drops exactly the row the
        // user was searching for.
        sheet.updateSearchQuery("sidebar")

        XCTAssertEqual(sheet.visibleSessionIDs, [sidebarID])
        XCTAssertEqual(
            sheet.selectedSessions.map(\.agentSessionID.rawValue),
            [sidebarID, toolbarID]
        )
        XCTAssertEqual(Array(sheet.drawnSelectionForTesting().rows), [0])
    }

    func testSearchingTwiceAccumulatesWhatEachSearchFound() throws {
        let sheet = makeSheet()

        sheet.updateSearchQuery("sidebar")
        sheet.selectSessions(withIDs: [sidebarID])
        sheet.updateSearchQuery("composer")

        // Adding to the selection is what the second search is for, so the ids arrive together.
        sheet.selectSessions(withIDs: [sidebarID, composerID])
        sheet.updateSearchQuery("")

        var imported: [ImportableSession] = []
        sheet.onPick = { imported = $0 }
        sheet.confirm()

        XCTAssertEqual(
            imported.map(\.agentSessionID.rawValue),
            [sidebarID, composerID],
            "Adopted newest first, in the order the sheet lists them"
        )
    }

    func testEveryChosenRowIsMarkedByTheListItself() throws {
        let sheet = makeSheet()
        sheet.selectSessions(withIDs: [sidebarID, composerID])

        let drawn = sheet.drawnSelectionForTesting()

        XCTAssertEqual(
            Array(drawn.rows),
            [0, 2],
            "The list has to agree with the count on the button, or the sheet is lying"
        )
        XCTAssertEqual(drawn.marked, [true, true], "Both rows draw as chosen, not just the last")
    }

    func testRowsHiddenByASearchAreNotMarkedButAreStillChosen() throws {
        let sheet = makeSheet()
        sheet.selectSessions(withIDs: [sidebarID, toolbarID])
        sheet.updateSearchQuery("composer")

        XCTAssertTrue(
            sheet.drawnSelectionForTesting().rows.isEmpty,
            "Nothing on screen is chosen, so nothing on screen may be marked"
        )
        XCTAssertEqual(sheet.selectedSessions.count, 2)
        XCTAssertEqual(sheet.importButtonTitleForTesting, "Import 2 conversations")
    }

    func testCancellingAdoptsNothing() {
        let sheet = makeSheet()
        sheet.selectSessions(withIDs: [sidebarID, toolbarID])

        var imported: [ImportableSession]?
        sheet.onPick = { imported = $0 }
        sheet.cancel()

        XCTAssertEqual(imported?.count, 0, "Dismissal is an empty list, never a silent import")
    }

    func testTheFirstRowIsChosenSoReturnAlwaysHasATarget() {
        let sheet = makeSheet()

        XCTAssertEqual(
            sheet.selectedSessions.map(\.agentSessionID.rawValue),
            [sidebarID],
            "One row is chosen up front, as it was before the sheet took several"
        )
        XCTAssertEqual(sheet.importButtonTitleForTesting, "Import 1 conversation")
    }

    // MARK: - Fixture

    private let sidebarID = "11111111-1111-1111-1111-111111111111"
    private let toolbarID = "22222222-2222-2222-2222-222222222222"
    private let composerID = "33333333-3333-3333-3333-333333333333"
    private let shared = "44444444-4444-4444-4444-444444444444"

    private func makeSheet() -> SessionImportViewController {
        let sheet = SessionImportViewController(sessions: [
            session(id: sidebarID, account: nil, activeAt: 9_000, title: "Refactor the sidebar"),
            session(id: toolbarID, account: nil, activeAt: 8_000, title: "Refactor the toolbar"),
            session(id: composerID, account: nil, activeAt: 7_000, title: "Fix the composer")
        ])
        sheet.loadView()
        return sheet
    }

    private func session(
        id: String,
        account: String?,
        activeAt: TimeInterval,
        title: String = "A conversation"
    ) -> ImportableSession {
        ImportableSession(
            agentSessionID: TranscriptID(id),
            kind: .claude,
            accountHandle: AccountHandle(storedName: account),
            title: title,
            lastActiveAt: Date(timeIntervalSince1970: activeAt)
        )
    }

    private func write(lines: [String], modified: Date) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }
}
