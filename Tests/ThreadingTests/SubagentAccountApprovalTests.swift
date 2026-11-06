import AppKit
import XCTest
@testable import Threading

@MainActor
final class SubagentAccountApprovalTests: HostedStoreTestCase {
    static let now = Date(timeIntervalSince1970: 1_799_000_000)
    static let account = AgentAccount(provider: .claude, handle: AccountHandle(storedName: "work"),
                                      configPath: "/tmp/subagent-account-fixture", displayName: "Work")

    static func plan(kind: AgentKind = .claude, account: AccountHandle = SubagentAccountApprovalTests.account.handle) -> ScheduledSessionPlan {
        ScheduledSessionPlan(projectID: ProjectID(), kind: kind, accountHandle: account,
                             model: nil, reasoningEffort: nil, branch: nil, usesNativeUI: true,
                             permissionMode: .manual, managedWorkspacePlan: nil)
    }

    static func usage(fraction: Double = 0.72, at: Date = now) -> AccountUsage {
        AccountUsage(windows: [
            .init(id: "5h", label: "Five hours", fraction: fraction,
                  resetsAt: now.addingTimeInterval(3_600), windowDuration: 18_000),
            .init(id: "7d", label: "Weekly", fraction: 0.38,
                  resetsAt: now.addingTimeInterval(86_400), windowDuration: 604_800)
        ], planLabel: nil, observedAt: at, source: .api)
    }

    static func request(
        parentID: SessionID = SessionID(), reading: AccountUsageReading = .current(usage()),
        completion: @escaping (Bool) -> Void = { _ in }
    ) -> SubagentAccountApproval {
        SubagentAccountApproval(parentID: parentID, plan: plan(), brief: "Review the login API",
            accountName: "Work", account: account, read: { reading }, refresh: { $0() },
            limits: { [] }, now: { now }, completion: completion)
    }

    func testOnlyTheSameProviderAndAccountCanStartWithoutApproval() {
        let parent = AgentSession(kind: .claude, title: "Parent", accountHandle: Self.account.handle)
        XCTAssertFalse(SubagentAccountApproval.requiresApproval(plan: Self.plan(), parent: parent))
        XCTAssertTrue(SubagentAccountApproval.requiresApproval(plan: Self.plan(account: .standard), parent: parent))
        XCTAssertTrue(SubagentAccountApproval.requiresApproval(plan: Self.plan(kind: .codex), parent: parent))
    }

    func testAccountConsentCannotBeSuppressedAndStopsDuringAccountResolution() {
        guard case .alwaysAsks(.securityGrant) = ConfirmationPrompt.approveSubagentAccount.policy else {
            return XCTFail("Account consent must always ask the owner")
        }
        let parentID = SessionID()
        let lifetime = SubagentLaunchLifetime(parentID: parentID)
        var cancellations = 0
        lifetime.onCancel = { cancellations += 1 }
        NotificationCenter.default.post(SessionWorkDidChange(sessionID: SessionID(), kind: .turnEnded))
        XCTAssertFalse(lifetime.isCancelled)
        NotificationCenter.default.post(SessionWorkDidChange(sessionID: parentID, kind: .turnEnded))
        XCTAssertTrue(lifetime.isCancelled)
        NotificationCenter.default.post(TerminalSessionDidEnd(sessionID: parentID))
        XCTAssertEqual(cancellations, 1)
    }

    func testRefreshNeverApprovesAndAnswerIsSpentExactlyOnce() {
        var reading: AccountUsageReading = .notFetched
        var finishRefresh: (() -> Void)?
        var decisions: [Bool] = []
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, read: { reading },
            refresh: { finishRefresh = $0 }, limits: { [] }, now: { Self.now },
            completion: { decisions.append($0) })
        request.refresh()
        request.approve()
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertFalse(request.canApprove)
        reading = .current(Self.usage())
        finishRefresh?()
        XCTAssertTrue(request.canApprove)
        XCTAssertTrue(decisions.isEmpty)
        request.approve()
        request.approve()
        request.deny()
        XCTAssertEqual(decisions, [true])
    }

    func testUnknownStaleExpiredAndSpentUsageCannotBeApproved() {
        for reading: AccountUsageReading in [
            .notFetched, .failed(.tokenExpired), .stale(Self.usage(), error: .decoding),
            .current(Self.usage(at: Self.now.addingTimeInterval(-121))),
            .current(Self.usage(fraction: 1))
        ] {
            var decisions: [Bool] = []
            let request = Self.request(reading: reading) { decisions.append($0) }
            XCTAssertFalse(request.canApprove)
            request.approve()
            XCTAssertTrue(decisions.isEmpty)
            request.deny()
            XCTAssertEqual(decisions, [false])
        }
    }

    func testAgeIsCheckedAgainAtTheApprovalPress() {
        var now = Self.now
        var decisions: [Bool] = []
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, read: { .current(Self.usage()) },
            refresh: { $0() }, limits: { [] }, now: { now }, completion: { decisions.append($0) })
        XCTAssertTrue(request.canApprove)
        now = now.addingTimeInterval(121)
        request.approve()
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertFalse(request.canApprove)
    }

    func testYourLimitStillBlocksApprovalWhenProviderHasCapacity() {
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, read: { .current(Self.usage()) },
            refresh: { $0() }, limits: { [CustomLimit(windowID: "5h", bound: 0.6, tier: .hold)] },
            now: { Self.now }, completion: { _ in XCTFail("No start may pass the user's limit") })
        XCTAssertFalse(request.canApprove)
        request.approve()
        XCTAssertFalse(request.isResolved)
    }

    func testToolDoesNotSpawnBeforeApprovalOrAfterDenialAndUsesTheExactApprovedAccount() async throws {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: URL(fileURLWithPath: NSTemporaryDirectory())))
        let parent = try XCTUnwrap(store.addSession(to: project.id, kind: .claude,
                                                   usesNativeUI: true, title: "Parent"))
        let now = Date()
        let reading = AccountUsage(windows: [.init(id: "5h", label: "Five hours", fraction: 0.25,
            resetsAt: now.addingTimeInterval(3_600), windowDuration: 18_000)],
            planLabel: nil, observedAt: now, source: .api)
        let usage = AccountUsageService(observesActivity: false, fetcher: { _ in reading })
        let standard = AgentAccount(provider: .claude, handle: .standard,
            configPath: "/tmp/subagent-standard-fixture", displayName: "Standard")
        var availableAccounts = [Self.account, standard]
        let actions = SupervisionActionRegistry()
        var proposed: SubagentAccountApproval?
        var launched: [ScheduledSessionPlan] = []
        actions.register(.init(
            spawn: { _, _, _, _ in .failure(.init("Not used")) },
            spawnSubagent: { plan, _, _ in
                launched.append(plan)
                return .success(AgentSession(kind: plan.kind, title: "Child", accountHandle: plan.accountHandle))
            },
            resume: { _ in false }, move: { _, _, _ in .failure(.init("Not used")) },
            finish: { _, _ in false }, approveSubagentAccount: { proposed = $0 }
        ))
        let control = WorkspaceControlPlane(dependencies: .init(
            session: { store.session(withID: $0) },
            projectForSession: { store.project(forSessionID: $0) },
            activity: { _ in .working }, surface: { _ in .chat },
            deliver: { _, _, done in done(.sentNow) }, steer: { _, _ in .steered },
            armWatch: { _, _, timeout in .armed(awaiting: .turnSettled, expiresAfter: timeout) }
        ))
        let service = SupervisionCommandService(projects: store, control: control,
            grants: .shared, subscriptions: .shared, usage: usage, transcriptUsage: .shared,
            actions: actions, accounts: { _ in availableAccounts })
        let arguments = try JSONDecoder().decode(StartSubagentArguments.self, from: Data(
            #"{"brief":"Review API","plan":{"kind":"claude","account":"work"}}"#.utf8))
        let denied = expectation(description: "Denied without starting")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertTrue(result.isError)
            denied.fulfill()
        }
        let first = try XCTUnwrap(proposed)
        XCTAssertTrue(launched.isEmpty)
        first.deny()
        await fulfillment(of: [denied], timeout: 2)
        XCTAssertTrue(launched.isEmpty)

        let started = expectation(description: "Started after owner approval")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertFalse(result.isError)
            started.fulfill()
        }
        let second = try XCTUnwrap(proposed)
        XCTAssertNotEqual(second.id, first.id)
        let refreshed = expectation(description: "Usage fetched for review")
        second.onChange = { if !second.isRefreshing { refreshed.fulfill() } }
        second.refresh()
        await fulfillment(of: [refreshed], timeout: 3)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(second.canApprove)
        second.approve()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(launched.map(\.accountHandle), [Self.account.handle])

        let stopped = expectation(description: "Stop retires the proposed start")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertTrue(result.isError)
            stopped.fulfill()
        }
        let stoppedRequest = try XCTUnwrap(proposed)
        NotificationCenter.default.post(SessionWorkDidChange(sessionID: parent.id, kind: .turnEnded))
        stoppedRequest.approve()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(launched.count, 1)

        let removed = expectation(description: "Removed accounts cannot launch from an old card")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertTrue(result.isError)
            removed.fulfill()
        }
        let removedRequest = try XCTUnwrap(proposed)
        availableAccounts = [standard]
        removedRequest.approve()
        await fulfillment(of: [removed], timeout: 2)
        XCTAssertEqual(launched.count, 1)

        proposed = nil
        usage.acceptAuthoritative(reading, for: standard)
        let inherited = try JSONDecoder().decode(StartSubagentArguments.self,
            from: Data(#"{"brief":"Use the parent's account"}"#.utf8))
        let inheritedStart = expectation(description: "The parent's account needs no extra approval")
        service.startSubagent(inherited, for: parent.id) { result in
            XCTAssertFalse(result.isError)
            inheritedStart.fulfill()
        }
        await fulfillment(of: [inheritedStart], timeout: 2)
        XCTAssertNil(proposed)
        XCTAssertEqual(launched.map(\.accountHandle), [Self.account.handle, .standard])

        availableAccounts = [Self.account, standard]
        usage.acceptAuthoritative(Self.usage(fraction: 0.1, at: now), for: Self.account)
        usage.acceptAuthoritative(Self.usage(fraction: 0.95, at: now), for: standard)
        let best = try JSONDecoder().decode(StartSubagentArguments.self,
            from: Data(#"{"brief":"Choose an account","plan":{"account":"best"}}"#.utf8))
        let bestStart = expectation(description: "Best is frozen before approval")
        service.startSubagent(best, for: parent.id) { result in
            XCTAssertFalse(result.isError)
            bestStart.fulfill()
        }
        let bestRequest = try XCTUnwrap(proposed)
        XCTAssertEqual(bestRequest.plan.accountHandle, Self.account.handle)
        usage.acceptAuthoritative(Self.usage(fraction: 0.72, at: now), for: Self.account)
        usage.acceptAuthoritative(Self.usage(fraction: 0.01, at: now), for: standard)
        bestRequest.approve()
        await fulfillment(of: [bestStart], timeout: 2)
        XCTAssertEqual(launched.last?.accountHandle, Self.account.handle)
    }

    func testQueueIsBoundedAndTerminationDeniesEveryPendingStart() throws {
        let (controller, _) = NativeChatShowcaseTests.fixture(.working)
        controller.isTurnInFlight = true
        var decisions: [Bool] = []
        let requests = (0..<5).map { _ in Self.request { decisions.append($0) } }
        for request in requests { controller.presentSubagentAccountApproval(request) }
        XCTAssertEqual(controller.subagentAccountApprovals.count, 4)
        XCTAssertEqual(controller.runtimeSnapshot.blocker, .awaitingUser)
        XCTAssertEqual(decisions, [false])
        XCTAssertEqual(controller.activeSubagentAccountCard?.request.id, requests[0].id)
        requests[0].deny()
        XCTAssertEqual(controller.activeSubagentAccountCard?.request.id, requests[1].id)
        XCTAssertFalse(controller.resolveManagerPermission(id: requests[1].id.uuidString, decision: .allow))
        controller.terminate()
        requests[1].approve()
        XCTAssertEqual(decisions, Array(repeating: false, count: 5))
        XCTAssertTrue(controller.subagentAccountApprovals.isEmpty)
        XCTAssertNil(controller.activeSubagentAccountCard)
    }

    func testRendersApprovalAndSubagentHierarchyInShippingShell() throws {
        let oldTheme = AppThemePalette.current
        let oldAppearance = NSApp.appearance
        let oldDensity = AppSettings.shared.compactsSidebarTree
        defer {
            NSApp.appearance = oldAppearance
            AppThemePalette.set(oldTheme)
            AppSettings.shared.compactsSidebarTree = oldDensity
        }
        AppThemePalette.set(.system)
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: URL(fileURLWithPath: NSTemporaryDirectory())))
        let parent = try XCTUnwrap(store.addSession(to: project.id, kind: .codex,
            usesNativeUI: true, title: "Login flow"))
        for title in ["Review API", "Test errors"] {
            _ = store.addSession(to: project.id, kind: .claude, usesNativeUI: true,
                                 title: title, lineage: .subagent(of: parent.id))
        }
        _ = store.addSession(to: project.id, kind: .codex, usesNativeUI: true, title: "Release notes")
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            NSApp.appearance = appearance
            var result: Result<Void, Error>?
            // Layer-backed hosts must be constructed and captured in the same drawing
            // appearance, as in NativeChatShowcaseTests; changing only inherited appearance
            // on an offscreen fixture does not run the application's theme transition.
            appearance.performAsCurrentDrawingAppearance {
                result = Result {
                    try renderApprovalShell(parent: parent, project: project, appearance: appearance,
                                            name: name, directory: directory)
                }
            }
            try XCTUnwrap(result).get()
        }
    }

    private func renderApprovalShell(
        parent: AgentSession, project: Project, appearance: NSAppearance, name: String, directory: URL
    ) throws {
        let main = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(main.window)
        window.appearance = appearance
        window.setContentSize(NSSize(width: 1_120, height: 760))
        let content = try XCTUnwrap(window.contentView)
        content.appearance = appearance
        let chat = requireConversationViewController(agentSession: parent, project: project,
                                                     customizationLookup: { _ in .empty })
        defer { chat.terminate() }
        main.containerViewController.setCurrentSessionForTesting(parent.id)
        main.containerViewController.attachConversation(chat)
        main.sidebarViewController.mountInitialTreeIfNeeded()
        main.sidebarViewController.select(sessionID: parent.id, notifyDelegate: false)
        chat.isTurnInFlight = true
        chat.presentSubagentAccountApproval(Self.request(parentID: parent.id))
        func capture(_ name: String) throws {
            var png: Data?
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: image)
                png = image.representation(using: .png, properties: [:])
            }
            try XCTUnwrap(png).write(
                to: directory.appendingPathComponent("subagent-approval-\(name).png"))
        }
        for compact in [false, true] {
            AppSettings.shared.compactsSidebarTree = compact
            main.sidebarViewController.applyTreeDensity()
            try capture("\(name)-\(compact ? "compact" : "tree")")
            XCTAssertEqual(descendants(content).compactMap { $0 as? SidebarSubagentConnectorView }.count, 2)
            let card = try XCTUnwrap(chat.activeSubagentAccountCard)
            let approve = try XCTUnwrap(descendants(card).first {
                $0.accessibilityIdentifier() == "conversation.subagent-account-approval.approve"
            } as? ThemedButton)
            XCTAssertTrue(approve.isEnabled)
            let point = approve.convert(NSPoint(x: approve.bounds.midX, y: approve.bounds.midY), to: content)
            let hit = content.hitTest(point)
            XCTAssertTrue(hit === approve || hit?.isDescendant(of: approve) == true)
        }
        guard name == "dark" else { return }
        let outline = try XCTUnwrap(descendants(main.sidebarViewController.view)
            .first { $0 is NSOutlineView } as? NSOutlineView)
        let parentNode = try XCTUnwrap((0..<outline.numberOfRows)
            .compactMap { outline.item(atRow: $0) as? SessionNode }
            .first { $0.sessionID == parent.id })
        outline.collapseItem(parentNode)
        window.setContentSize(NSSize(width: 900, height: 700))
        for (name, reading) in [("unavailable", AccountUsageReading.failed(.tokenExpired)),
                                ("spent", .current(Self.usage(fraction: 1)))] {
            chat.cancelSubagentAccountApprovals()
            chat.presentSubagentAccountApproval(Self.request(parentID: parent.id, reading: reading))
            try capture("dark-compact-collapsed-\(name)")
            XCTAssertFalse(try XCTUnwrap(chat.activeSubagentAccountCard).request.canApprove)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
