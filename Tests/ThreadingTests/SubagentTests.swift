import XCTest
@testable import Threading

/// Subagents: a chat starting a chat of its own, on any provider, without the Manager role.
///
/// Admission and reach are the control plane's, so they are driven through the real plane with
/// fakes. Report-back and lifecycle are driven through their owners with injected dependencies,
/// posting the same events the app posts.
@MainActor
final class SubagentAdmissionTests: XCTestCase {

    // MARK: - Admission

    func testAnyChatMayStartASubagentWithoutAGrant() {
        let fixture = Fixture()

        XCTAssertNil(fixture.plane().admitSubagent(fixture.plan(), from: fixture.actor))
    }

    func testASubagentCannotStartSubagentsOfItsOwn() {
        var fixture = Fixture()
        let child = fixture.addSubagent()

        XCTAssertEqual(
            fixture.plane().admitSubagent(fixture.plan(), from: .agentSession(child.id)),
            .subagentCannotDelegate
        )
    }

    func testLiveSubagentsAreCappedAndArchivedOnesDoNotCount() {
        var fixture = Fixture()
        for _ in 0..<SubagentChatDefaults.maximumLiveSubagents { fixture.addSubagent() }

        XCTAssertEqual(
            fixture.plane().admitSubagent(fixture.plan(), from: fixture.actor),
            .subagentsAtCapacity(limit: SubagentChatDefaults.maximumLiveSubagents)
        )

        fixture.project.sessions[fixture.project.sessions.count - 1].isArchived = true
        XCTAssertNil(fixture.plane().admitSubagent(fixture.plan(), from: fixture.actor))
    }

    func testTheParentsOwnPermissionModeIsTheCeiling() {
        var fixture = Fixture()
        fixture.project.sessions[0].permissionMode = .acceptEdits
        let plane = fixture.plane()

        XCTAssertNil(plane.admitSubagent(fixture.plan(permission: .acceptEdits), from: fixture.actor))
        XCTAssertEqual(
            plane.admitSubagent(fixture.plan(permission: .bypassPermissions), from: fixture.actor),
            .planExceedsParent(field: "permission_mode")
        )
    }

    func testASubagentNeverMergesItsWorkspaceOnItsOwn() {
        let fixture = Fixture()

        XCTAssertEqual(
            fixture.plane().admitSubagent(
                fixture.plan(delivery: .mergeAndCleanUp),
                from: fixture.actor
            ),
            .planExceedsParent(field: "managed_workspace_plan.delivery")
        )
        XCTAssertNil(
            fixture.plane().admitSubagent(fixture.plan(delivery: .keepForReview), from: fixture.actor)
        )
    }

    func testARuntimeThatCannotReportBackIsRefusedInItsOwnWords() {
        let fixture = Fixture()
        let refusal = fixture.plane().admitSubagent(
            fixture.plan(kind: .openCode, native: false),
            from: fixture.actor
        )

        XCTAssertEqual(refusal, .subagentNeedsNativeChat(.openCode))
        XCTAssertTrue(refusal?.toolWords.contains("OpenCode") == true)
    }

    func testStartsAreRateLimitedAndARefusalSpendsNothing() {
        let fixture = Fixture()
        let plane = fixture.plane()
        let now = Date(timeIntervalSince1970: 1_000_000)

        // A refused start must not count against the window.
        XCTAssertNotNil(plane.admitSubagent(fixture.plan(delivery: .mergeAndCleanUp), from: fixture.actor, at: now))
        for _ in 0..<SubagentChatDefaults.maximumStartsPerWindow {
            XCTAssertNil(plane.admitSubagent(fixture.plan(), from: fixture.actor, at: now))
        }
        XCTAssertEqual(
            plane.admitSubagent(fixture.plan(), from: fixture.actor, at: now),
            .subagentStartRateReached(
                limit: SubagentChatDefaults.maximumStartsPerWindow,
                minutes: Int(SubagentChatDefaults.startWindow / 60)
            )
        )
        let later = now.addingTimeInterval(SubagentChatDefaults.startWindow + 1)
        XCTAssertNil(plane.admitSubagent(fixture.plan(), from: fixture.actor, at: later))
    }

    func testTheParentsCurfewHoldsItsSubagentsToo() {
        let fixture = Fixture()
        let plane = fixture.plane(heldByCurfew: { $0 == fixture.parent.id ? "Curfew" : nil })

        XCTAssertEqual(
            plane.admitSubagent(fixture.plan(), from: fixture.actor),
            .targetHeldByCurfew(reason: "Curfew")
        )
    }

    // MARK: - Reach

    func testAParentMayArchiveItsOwnSubagentButNotASibling() {
        var fixture = Fixture()
        let child = fixture.addSubagent()
        let plane = fixture.plane()

        XCTAssertNil(plane.authorize(fixture.actor, operation: .archiveSession, target: child.id))
        XCTAssertEqual(
            plane.authorize(fixture.actor, operation: .archiveSession, target: fixture.sibling.id),
            .notPermitted(.archiveSession)
        )
    }

    func testAManagerGrantNeverPersistsAnImplicitOnlyOperation() throws {
        let grant = ControlGrant.manager(
            sessionID: SessionID(),
            projectID: ProjectID(),
            maximumPermissionMode: .manual,
            origin: .newManagerTemplate
        )

        XCTAssertTrue(grant.operations.isDisjoint(with: ControlOperation.implicitOnlyOperations))
        XCTAssertEqual(
            ControlOperation.managerOperations.subtracting([.respondToPermission]),
            ControlOperation.prePermissionResponseManagerOperations,
            "a new manager operation needs its own historical upgrade step"
        )
    }

    // MARK: - Fixture

    private struct Fixture {
        var project: Project
        var parent: AgentSession { project.sessions[0] }
        var sibling: AgentSession { project.sessions[1] }
        var actor: ControlActor { .agentSession(parent.id) }

        init() {
            let parent = AgentSession(kind: .claude, title: "Parent", usesNativeUI: true)
            let sibling = AgentSession(kind: .codex, title: "Sibling", usesNativeUI: true)
            project = Project(name: "Alpha", folderURL: URL(fileURLWithPath: "/tmp/alpha"))
            project.sessions = [parent, sibling]
        }

        @discardableResult
        mutating func addSubagent() -> AgentSession {
            var child = AgentSession(kind: .codex, title: "Subagent", usesNativeUI: true)
            child.lineage = .subagent(of: parent.id)
            project.sessions.append(child)
            return child
        }

        func plan(
            kind: AgentKind = .codex,
            native: Bool = true,
            permission: AgentPermissionMode? = nil,
            delivery: ManagedWorkspaceDelivery? = nil
        ) -> ScheduledSessionPlan {
            ScheduledSessionPlan(
                projectID: project.id,
                kind: kind,
                accountHandle: .standard,
                model: nil,
                reasoningEffort: nil,
                branch: nil,
                usesNativeUI: native,
                permissionMode: permission,
                managedWorkspacePlan: delivery.map { ManagedWorkspacePlan(delivery: $0) }
            )
        }

        @MainActor
        func plane(heldByCurfew: @escaping (SessionID) -> String? = { _ in nil }) -> WorkspaceControlPlane {
            let project = project
            return WorkspaceControlPlane(dependencies: WorkspaceControlPlane.Dependencies(
                session: { id in project.sessions.first { $0.id == id } },
                projectForSession: { id in project.sessions.contains { $0.id == id } ? project : nil },
                activity: { _ in .idle },
                surface: { _ in .chat },
                deliver: { _, _, done in done(.sentNow) },
                steer: { _, _ in .steered },
                armWatch: { _, _, timeout in .armed(awaiting: .turnSettled, expiresAfter: timeout) },
                heldByCurfew: heldByCurfew
            ))
        }
    }
}

// MARK: - Lineage

final class SessionLineageTests: XCTestCase {

    func testLineageRoundTripsAndNestsTheRowUnderItsParent() throws {
        let parentID = SessionID()
        var session = AgentSession(kind: .codex, title: "Subagent")
        session.lineage = .subagent(of: parentID)

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertEqual(decoded.lineage, .subagent(of: parentID))
        XCTAssertEqual(decoded.subagentParentID, parentID)
        XCTAssertEqual(decoded.nestingParentID, parentID)
        XCTAssertFalse(decoded.isSideChat, "a subagent is not a fork; its row keeps its agent mark")
    }

    func testALineageThisBuildCannotReadLeavesTheRowStanding() throws {
        let session = AgentSession(kind: .codex, title: "From a later build")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        object["lineage"] = ["laterCase": ["of": UUID().uuidString]]

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.lineage)
    }

    func testALineageNamingTheRowItselfIsDropped() throws {
        var session = AgentSession(kind: .codex, title: "Its own parent")
        session.lineage = .subagent(of: session.id)

        let decoded = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONEncoder().encode(session)
        )

        XCTAssertNil(decoded.lineage)
    }
}

// MARK: - Report-Back

@MainActor
final class SubagentReportBackTests: XCTestCase {

    func testACompletedBriefTurnIsMailedFromTheSubagentToItsParent() {
        let fixture = ReportFixture()

        fixture.completeTurn()

        XCTAssertEqual(fixture.mailed.map(\.text), ["Found it: the cache key omits the locale."])
        XCTAssertEqual(fixture.mailed.first?.parent, fixture.parentID)
        XCTAssertEqual(fixture.mailed.first?.child, fixture.child.id)
        XCTAssertEqual(fixture.reports, 1)
    }

    func testATurnTheUserTypedIsNotMailed() {
        let fixture = ReportFixture()

        fixture.reporter.turnStarted(sessionID: fixture.child.id, prompt: "What did you change?")
        fixture.completeTurn()

        XCTAssertTrue(fixture.mailed.isEmpty)
    }

    func testATurnOpenedByMailOrTheBriefIsMailed() {
        let fixture = ReportFixture()

        fixture.reporter.turnStarted(sessionID: fixture.child.id, prompt: "What did you change?")
        fixture.reporter.turnStarted(
            sessionID: fixture.child.id,
            prompt: "[Cross-session message from “Parent” — Threading session x in this project.]\n\nGo on."
        )
        fixture.completeTurn()

        XCTAssertEqual(fixture.mailed.count, 1, "the later, agent-opened turn is the one that ran")
    }

    func testNothingIsMailedOnceTheParentsTenureHasEnded() {
        let fixture = ReportFixture()
        fixture.supervision = nil

        fixture.completeTurn()

        XCTAssertTrue(fixture.mailed.isEmpty)
    }

    func testATurnWithoutACapturedReplyMailsNothing() {
        let fixture = ReportFixture()
        fixture.reply = nil

        fixture.completeTurn()

        XCTAssertTrue(fixture.mailed.isEmpty, "a limit or an exit is watch_session's to report")
    }

    func testATurnThatCapturesNothingDoesNotMailTheLastReplyAgain() {
        let fixture = ReportFixture()

        fixture.completeTurn()
        fixture.completeTurn(captures: false)

        XCTAssertEqual(fixture.mailed.count, 1)
    }

    func testAReplyOverMailsBoundIsCutOnACharacterWithAMarkedNote() throws {
        let reply = String(repeating: "å", count: SubagentReportBack.maximumMailUTF8Bytes)

        let body = try XCTUnwrap(SubagentReportBack.mailBody(for: reply))

        XCTAssertLessThanOrEqual(body.utf8.count, SubagentReportBack.maximumMailUTF8Bytes)
        XCTAssertTrue(body.hasSuffix(SubagentReportBack.cutNotice))
        XCTAssertNil(SubagentReportBack.mailBody(for: "  \n"))
    }

    // MARK: - Fixture

    @MainActor
    private final class ReportFixture {
        let center = NotificationCenter()
        let parentID = SessionID()
        let child: AgentSession
        var supervision: Supervision?
        var reply: String? = "Found it: the cache key omits the locale."
        /// The capture store's value: a turn that captures nothing leaves the previous one.
        var capture: CompletedTurnSnapshot?
        private var generation: UInt64 = 0
        var mailed: [(text: String, parent: SessionID, child: SessionID)] = []
        var reports = 0
        private(set) var reporter: SubagentReportBack!

        init() {
            var child = AgentSession(kind: .codex, title: "Subagent", usesNativeUI: true)
            child.lineage = .subagent(of: parentID)
            self.child = child
            supervision = Supervision(managerID: parentID, childID: child.id, brief: "Find the bug")
            reporter = SubagentReportBack(center: center, dependencies: .init(
                session: { [unowned self] id in id == self.child.id ? self.child : nil },
                supervision: { [unowned self] _ in self.supervision },
                snapshot: { [unowned self] _ in self.capture },
                mail: { [unowned self] text, parent, child in self.mailed.append((text, parent, child)) },
                recordReport: { [unowned self] _ in self.reports += 1 }
            ))
            reporter.start()
        }

        /// A whole turn: it starts, the provider captures `reply` (or nothing), and it settles.
        func completeTurn(captures: Bool = true) {
            post(from: .idle, to: .working)
            if captures {
                generation += 1
                capture = CompletedTurnSnapshot(
                    sessionID: child.id,
                    generation: generation,
                    finalAssistantText: reply
                )
            }
            post(from: .working, to: .idle)
        }

        private func post(from previous: SessionActivity, to current: SessionActivity) {
            center.post(SessionRuntimeDidChange(
                sessionID: child.id,
                transition: SessionRuntimeTransition(
                    previous: .test(activity: previous),
                    current: .test(activity: current)
                ),
                cause: nil
            ))
        }
    }
}

// MARK: - Lifecycle

@MainActor
final class SubagentLifecycleTests: XCTestCase {

    func testArchivingAParentArchivesItsSubagentsAndUndoBringsThemBack() {
        let center = NotificationCenter()
        let parentID = SessionID()
        let first = SessionID()
        let second = SessionID()
        var live: [SessionID] = [first, second]
        var archived: [SessionID: Bool] = [:]
        var readopted: [SessionID] = []
        let lifecycle = SubagentLifecycle(center: center, dependencies: .init(
            liveSubagents: { $0 == parentID ? live : [] },
            setArchived: { archived[$1] = $0 },
            readopt: { child, parent in
                XCTAssertEqual(parent, parentID)
                readopted.append(child)
            }
        ))
        lifecycle.start()

        center.post(SessionArchivedStateDidChange(sessionID: parentID, isArchived: true))
        XCTAssertEqual(archived, [first: true, second: true])

        // Something archived the subagents with it; nothing else is touched on restore.
        live = []
        center.post(SessionArchivedStateDidChange(sessionID: parentID, isArchived: false))
        XCTAssertEqual(archived, [first: false, second: false])
        XCTAssertEqual(readopted, [first, second])
    }

    func testRestoringAParentRestoresOnlyWhatItsArchiveTook() {
        let center = NotificationCenter()
        let parentID = SessionID()
        var calls = 0
        let lifecycle = SubagentLifecycle(center: center, dependencies: .init(
            liveSubagents: { _ in [] },
            setArchived: { _, _ in calls += 1 },
            readopt: { _, _ in calls += 1 }
        ))
        lifecycle.start()

        center.post(SessionArchivedStateDidChange(sessionID: parentID, isArchived: true))
        center.post(SessionArchivedStateDidChange(sessionID: parentID, isArchived: false))

        XCTAssertEqual(calls, 0, "a subagent the user archived earlier stays archived")
    }
}

// MARK: - Catalogue

final class SubagentCatalogTests: XCTestCase {

    func testStartSubagentIsAloneInItsOwnSwitchableGroup() {
        XCTAssertEqual(MCPToolCatalog.subagents.tools.map(\.name), ["start_subagent"])
        XCTAssertFalse(
            MCPTools.supervisionTools.contains("start_subagent"),
            "delegating is every chat's; it must not hide behind a manager grant"
        )
    }

    func testThePrefixNamesTheToolWithinItsBudget() {
        let everything = MCPToolCatalog.decisionPrefix(for: MCPToolCatalog.groups)
        XCTAssertTrue(everything.contains("start_subagent"))
        XCTAssertLessThanOrEqual(everything.count, MCPInstructionDefaults.decisionPrefixCharacterLimit)

        let delegationOnly = MCPToolCatalog.decisionPrefix(for: [MCPToolCatalog.subagents])
        XCTAssertTrue(delegationOnly.contains("start_subagent"))
        XCTAssertFalse(delegationOnly.contains("mail_send"))
    }

    func testARemoteSessionIsNotOfferedIt() {
        XCTAssertFalse(MCPRemoteSessionToolScope.reaches(toolNamed: "start_subagent"))
    }
}
