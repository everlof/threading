import XCTest

@testable import Threading

final class SessionNameHistoryTests: XCTestCase {
    func testReusingANameRefreshesItsDateWithoutKeepingTheCurrentNameAsAnAlias() throws {
        var history = SessionNameHistory()
        history.recordChange(from: "MIRRORING", to: "IPHONE", at: Date(timeIntervalSince1970: 10))
        history.recordChange(from: "IPHONE", to: "MIRRORING", at: Date(timeIntervalSince1970: 20))
        history.recordChange(from: "MIRRORING", to: "CAMERA", at: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(history.entries.map(\.name), ["MIRRORING", "IPHONE"])
        XCTAssertEqual(history.entries.map(\.lastSeenAt), [
            Date(timeIntervalSince1970: 30), Date(timeIntervalSince1970: 20),
        ])
        let roundTrip = try JSONDecoder().decode(
            SessionNameHistory.self, from: JSONEncoder().encode(history)
        )
        XCTAssertEqual(roundTrip, history)
    }

    func testUnchangedNamesAndEmptyPlaceholdersDoNotCreateHistory() {
        var history = SessionNameHistory()
        history.recordChange(from: "", to: "PHONE", at: Date())
        history.recordChange(from: "ÅNGSTRÖM", to: "angstrom", at: Date())
        history.recordChange(from: " PHONE ", to: "PHONE", at: Date())

        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRetentionKeepsTheLatestNamesAndWholeUnicodeCharacters() {
        var history = SessionNameHistory()
        for index in 0 ... SessionNameHistory.maximumEntries {
            history.recordChange(
                from: "Name \(index)", to: "Name \(index + 1)",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        XCTAssertEqual(history.entries.count, SessionNameHistory.maximumEntries)
        XCTAssertEqual(history.entries.first?.name, "Name \(SessionNameHistory.maximumEntries)")
        XCTAssertEqual(history.entries.last?.name, "Name 1")

        let longName = String(repeating: "👩🏽‍💻", count: SessionNameHistory.maximumNameUTF8Bytes)
        history.recordChange(from: longName, to: "NEXT", at: Date())
        let retained = history.entries.first?.name ?? ""
        XCTAssertLessThanOrEqual(retained.utf8.count, SessionNameHistory.maximumNameUTF8Bytes)
        XCTAssertFalse(retained.isEmpty)
        XCTAssertTrue(longName.hasPrefix(retained))
        XCTAssertTrue(retained.allSatisfy { $0 == "👩🏽‍💻" })
    }

    func testOlderSessionPayloadsStartWithEmptyHistory() throws {
        let session = AgentSession(kind: .codex, title: "Existing chat")
        let data = try JSONEncoder().encode(session)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(payload["nameHistory"])

        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertTrue(decoded.nameHistory.entries.isEmpty)
        XCTAssertEqual(decoded.title, session.title)
    }

    func testInvalidStoredHistoryIsRefusedInsteadOfSilentlyLosingNames() throws {
        let duplicate = SessionNameHistory.Entry(name: "OLD", lastSeenAt: Date())
        let data = try JSONSerialization.data(withJSONObject: [
            "entries": JSONSerialization.jsonObject(with: JSONEncoder().encode([duplicate, duplicate])),
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(SessionNameHistory.self, from: data))
    }
}

@MainActor
final class SessionNameHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var previousAgentTitlePreference = true

    override func setUp() async throws {
        try await MainActor.run {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("session-name-history-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            previousAgentTitlePreference = AppSettings.shared.usesAgentTitleInSidebar
            AppSettings.shared.usesAgentTitleInSidebar = true
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppSettings.shared.usesAgentTitleInSidebar = previousAgentTitlePreference
            try? FileManager.default.removeItem(at: directory)
            directory = nil
        }
    }

    func testVisibleNameChangesSurviveReopeningArchiveAndRestore() throws {
        let (manager, store, project, session) = try fixture()
        XCTAssertEqual(store.updateAgentTitle("MIRRORING", for: session.id, source: .chosen), .accepted)
        XCTAssertEqual(store.updateAgentTitle("IPHONE", for: session.id, source: .chosen), .accepted)
        let renamed = try XCTUnwrap(store.session(withID: session.id))
        XCTAssertEqual(renamed.nameHistory.entries.map(\.name), ["MIRRORING", session.title])

        // Re-asserting a name and a refused weaker title cannot refresh old-name recency.
        XCTAssertEqual(store.updateAgentTitle("IPHONE", for: session.id, source: .chosen), .accepted)
        XCTAssertEqual(store.updateAgentTitle("Other automatic name", for: session.id), .protectedByStrongerSource)
        XCTAssertEqual(store.session(withID: session.id)?.nameHistory, renamed.nameHistory)

        XCTAssertEqual(store.setArchived(true, for: session.id), .applied)
        let reopened = ProjectStore(stateManager: manager, refusesWrites: false)
        let archived = try XCTUnwrap(reopened.session(withID: session.id))
        XCTAssertEqual(archived.nameHistory, renamed.nameHistory)
        XCTAssertEqual(NavigationSearchProjection.record(session: archived, in: project).nameHistory,
                       renamed.nameHistory.entries)
        XCTAssertEqual(reopened.setArchived(false, for: session.id), .applied)
        XCTAssertEqual(reopened.session(withID: session.id)?.nameHistory, renamed.nameHistory)
    }

    func testManualRenameAndClearRecordOnlyNamesThatWereVisible() throws {
        let (_, store, _, session) = try fixture()
        store.updateAgentTitle("IPHONE", for: session.id, source: .chosen)
        XCTAssertEqual(store.renameSession(id: session.id, to: "MY PHONE"), .applied)
        let pinnedHistory = try XCTUnwrap(store.session(withID: session.id)).nameHistory

        store.updateAgentTitle("CAMERA", for: session.id, source: .chosen)
        XCTAssertEqual(store.session(withID: session.id)?.nameHistory, pinnedHistory)
        XCTAssertEqual(store.renameSession(id: session.id, to: nil), .applied)
        let standing = try XCTUnwrap(store.session(withID: session.id))
        XCTAssertEqual(standing.displayTitle, "CAMERA")
        XCTAssertEqual(standing.nameHistory.entries.map(\.name), ["MY PHONE", "IPHONE", session.title])
    }

    func testGenericAndCoalescedTitleChangesKeepIntermediateNames() throws {
        let (manager, store, _, session) = try fixture()
        store.updateAgentTitle("FIRST", for: session.id)
        store.updateAgentTitle("SECOND", for: session.id)
        XCTAssertEqual(store.update(sessionID: session.id) { $0.agentTitle = "THIRD" }, .applied)

        let reopened = ProjectStore(stateManager: manager, refusesWrites: false)
        XCTAssertEqual(reopened.session(withID: session.id)?.nameHistory.entries.map(\.name),
                       ["SECOND", "FIRST", session.title])
    }

    func testRefusedRenameRollsBackHistoryTogetherWithTheName() throws {
        let (manager, store, _, session) = try fixture()
        store.updateAgentTitle("MIRRORING", for: session.id, source: .chosen)
        store.updateAgentTitle("IPHONE", for: session.id, source: .chosen)
        let before = try XCTUnwrap(store.session(withID: session.id))
        let recovery = ProjectStore(stateManager: manager, refusesWrites: true)

        XCTAssertEqual(recovery.renameSession(id: session.id, to: "GHOST"), .persistenceRefused)
        XCTAssertEqual(recovery.session(withID: session.id)?.nameHistory, before.nameHistory)
        XCTAssertEqual(recovery.session(withID: session.id)?.displayTitle, before.displayTitle)
        XCTAssertEqual(recovery.updateAgentTitle("GHOST", for: session.id, source: .chosen), .persistenceRefused)
        XCTAssertEqual(recovery.session(withID: session.id)?.nameHistory, before.nameHistory)
    }

    private func fixture() throws -> (StateManager, ProjectStore, Project, AgentSession) {
        let manager = StateManager(appSupportDirectory: directory)
        let store = ProjectStore(stateManager: manager, refusesWrites: false)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .codex))
        XCTAssertEqual(store.update(sessionID: session.id) { $0.title = "Investigate phone display" }, .applied)
        return (manager, store, project, try XCTUnwrap(store.session(withID: session.id)))
    }
}
