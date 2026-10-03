import XCTest
@testable import Threading

@MainActor
final class ProjectAutoHideTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_750_000_000)
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("auto-hide-\(UUID())")
        suiteName = "ProjectAutoHideTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        settings = nil
        defaults = nil
    }

    func testDefaultsOffAndValidDayCountPersistsWhileInvalidValuesAreRefused() {
        XCTAssertFalse(settings.autoHidesInactiveProjects)
        XCTAssertEqual(settings.projectAutoHideDays, 30)
        settings.projectAutoHideDays = 7
        settings.autoHidesInactiveProjects = true
        let reopened = AppSettings(defaults: defaults)
        XCTAssertEqual(reopened.projectAutoHideDays, 7)
        XCTAssertTrue(reopened.autoHidesInactiveProjects)
        for invalid in [0, -1, 366, Int.max] {
            settings.projectAutoHideDays = invalid
            XCTAssertEqual(settings.projectAutoHideDays, 7)
        }
    }

    func testCutoffIncludesEmptyProjectsAndLegacyChatsButNotRecentWork() async throws {
        let old = try project("Old", age: 31)
        let boundary = try project("Boundary", age: 30)
        let recent = try project("Recent", age: 29)
        var restored = try project("Restored", age: 40, chatCount: 1)
        restored.sessions[0].lastActiveAt = clock
        restored.sessions[0].lastWorkAt = daysAgo(40)
        var working = try project("Recent chat", age: 40, chatCount: 1)
        working.sessions[0].lastWorkAt = daysAgo(1)
        let legacy = try project("Legacy chat", age: 40, chatCount: 1)
        let store = try store([old, boundary, recent, restored, working, legacy])
        let coordinator = coordinator(store)
        let disabledCount = await coordinator.reconcile()
        XCTAssertEqual(disabledCount, 0)
        settings.autoHidesInactiveProjects = true
        let count = await coordinator.reconcile()
        XCTAssertEqual(count, 4)
        XCTAssertEqual(Set(store.projects.filter(\.isHidden).map(\.id)),
                       Set([old.id, boundary.id, restored.id, legacy.id]))
        XCTAssertNotNil(store.session(withID: legacy.sessions[0].id))
        let reopened = ProjectStore(stateManager: StateManager(appSupportDirectory: directory), refusesWrites: false)
        XCTAssertEqual(reopened.projects.filter(\.isHidden).count, 4)
    }

    func testOpenScratchpadBusyAndAttentionProjectsStayVisible() async throws {
        let open = try project("Open", age: 40)
        var scratchpad = try project("Scratchpad", age: 40)
        scratchpad.isScratchpad = true
        let attention = try project("Waiting", age: 40, chatCount: 1)
        var terminalProject = try project("Busy terminal", age: 40)
        terminalProject.terminals = [try aged(ProjectTerminal(currentDirectory: "/tmp"), age: 40)]
        let store = try store([open, scratchpad, attention, terminalProject])
        settings.autoHidesInactiveProjects = true
        let coordinator = ProjectAutoHideCoordinator(
            store: store, settings: settings, currentProjectID: { open.id },
            sessionIsProtected: { $0 == attention.sessions[0].id },
            terminalIsBusy: { $0 == terminalProject.terminals[0].id }, now: { self.clock }
        )
        let count = await coordinator.reconcile()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(store.projects.contains(where: \.isHidden))
    }

    func testWritingAndExplicitShowPersistANewInactivityWindow() async throws {
        var old = try project("Old", age: 40, chatCount: 1)
        old.terminals = [try aged(ProjectTerminal(currentDirectory: "/tmp"), age: 40)]
        let store = try store([old])
        let terminal = try XCTUnwrap(old.terminals.first)
        store.noteUserWriting(inTerminal: terminal.id)
        store.flushPendingSave()
        let reopened = ProjectStore(stateManager: StateManager(appSupportDirectory: directory), refusesWrites: false)
        XCTAssertNotNil(reopened.project(withID: old.id)?.lastInteractionAt)
        settings.autoHidesInactiveProjects = true
        let count = await coordinator(reopened).reconcile()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(reopened.setProjectHidden(true, projectID: old.id), .applied)
        XCTAssertEqual(reopened.setProjectHidden(false, projectID: old.id), .applied)
        XCTAssertGreaterThan(try XCTUnwrap(reopened.project(withID: old.id)?.lastInteractionAt), daysAgo(30))
    }

    func testActivityArrivingDuringTraversalCannotHideTheProject() async throws {
        let old = try project("Old", age: 40, chatCount: 300)
        let store = try store([old])
        settings.autoHidesInactiveProjects = true
        let coordinator = ProjectAutoHideCoordinator(
            store: store, settings: settings, currentProjectID: { nil },
            sessionIsProtected: { sessionID in
                if sessionID == old.sessions.last?.id {
                    store.noteTurnStarted(sessionID: sessionID, at: self.clock)
                }
                return false
            },
            terminalIsBusy: { _ in false }, now: { self.clock }
        )
        let count = await coordinator.reconcile()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(try XCTUnwrap(store.project(withID: old.id)).isHidden)
        store.flushPendingSave()
    }

    func testRecoveryRefusesAutoHideWithoutDiscardingTheProject() async throws {
        let old = try project("Old", age: 40)
        let manager = StateManager(appSupportDirectory: directory)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [old])))
        let store = ProjectStore(stateManager: manager, refusesWrites: true)
        settings.autoHidesInactiveProjects = true
        let count = await coordinator(store).reconcile()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(try XCTUnwrap(store.project(withID: old.id)).isHidden)
    }

    func testEnablingTheSettingStartsMaintenanceAndPublishesOnceForThePass() async throws {
        let projects = try [project("First", age: 40), project("Second", age: 40)]
        let store = try store(projects)
        let coordinator = coordinator(store)
        let published = expectation(description: "One navigation update after both durable hides")
        published.assertForOverFulfill = true
        let events = AppEventObservations()
        events.observe(ProjectsDidChange.self) { _ in
            if store.projects.allSatisfy(\.isHidden) { published.fulfill() }
        }
        defer { coordinator.stop(); events.removeAll() }
        coordinator.start()
        XCTAssertFalse(store.projects.contains(where: \.isHidden))
        settings.autoHidesInactiveProjects = true
        await fulfillment(of: [published], timeout: 5)
        XCTAssertTrue(store.projects.allSatisfy(\.isHidden))
    }

    func testStressTraversalYieldsToMainActor() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_AUTO_HIDE_STRESS"] == "1" else {
            throw XCTSkip("Opt-in 25,000-project maintenance fixture")
        }
        let projects = try (0..<25_000).map { try project("Project \($0)", age: 40, chatCount: 4) }
        let store = try store(projects)
        settings.autoHidesInactiveProjects = true
        let protectedSessions = Set(projects.compactMap { $0.sessions.last?.id })
        let coordinator = ProjectAutoHideCoordinator(
            store: store, settings: settings, currentProjectID: { nil },
            sessionIsProtected: { protectedSessions.contains($0) }, terminalIsBusy: { _ in false }, now: { self.clock }
        )
        var heartbeat = 0
        var maximumHeartbeatGap: UInt64 = 0
        let probe = Task { @MainActor in
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                let current = DispatchTime.now().uptimeNanoseconds
                maximumHeartbeatGap = max(maximumHeartbeatGap, current - previous)
                previous = current
                heartbeat += 1
                await Task.yield()
            }
        }
        var timings: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let count = await coordinator.reconcile()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(count, 0)
        }
        probe.cancel()
        await probe.value
        XCTAssertGreaterThan(heartbeat, 1)
        print("Auto-hide: 25,000 projects / 100,000 chats; median \(timings.sorted()[1]) ms; "
            + "maximum \(timings.max() ?? 0) ms; main heartbeat \(heartbeat); "
            + "maximum heartbeat gap \(Double(maximumHeartbeatGap) / 1_000_000) ms")
    }

    private func coordinator(_ store: ProjectStore) -> ProjectAutoHideCoordinator {
        ProjectAutoHideCoordinator(store: store, settings: settings, currentProjectID: { nil },
                                  sessionIsProtected: { _ in false }, terminalIsBusy: { _ in false }, now: { self.clock })
    }

    private func store(_ projects: [Project]) throws -> ProjectStore {
        let manager = StateManager(appSupportDirectory: directory)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: projects)))
        return ProjectStore(stateManager: manager, refusesWrites: false)
    }

    private func project(_ name: String, age: Int, chatCount: Int = 0) throws -> Project {
        var project = try aged(Project(name: name, folderURL: directory.appendingPathComponent(name)), age: age)
        project.sessions = try (0..<chatCount).map { index in
            var session = try aged(AgentSession(kind: .claude, title: "Chat \(index)"), age: age)
            session.lastActiveAt = daysAgo(age)
            return session
        }
        return project
    }

    private func aged<T: Codable>(_ value: T, age: Int) throws -> T {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        json["createdAt"] = daysAgo(age).timeIntervalSinceReferenceDate
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func daysAgo(_ days: Int) -> Date {
        clock.addingTimeInterval(-Double(days) * ProjectAutoHideDefaults.secondsPerDay)
    }
}
