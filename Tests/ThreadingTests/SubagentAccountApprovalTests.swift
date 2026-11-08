import AppKit
import XCTest
@testable import Threading

@MainActor
final class SubagentAccountApprovalTests: HostedStoreTestCase {
    static let now = Date(timeIntervalSince1970: 1_799_000_000)
    static let account = AgentAccount(provider: .claude, handle: AccountHandle(storedName: "work"),
                                      configPath: "/tmp/subagent-account-fixture", displayName: "Work")
    static let otherAccount = AgentAccount(provider: .claude, handle: AccountHandle(storedName: "personal"),
        configPath: "/tmp/subagent-personal-fixture", displayName: "Personal")

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
            accountName: "Work", account: account, accounts: [account, otherAccount],
            read: { _ in reading }, refresh: { _, done in done() },
            limits: { _ in [] }, now: { now }, completion: { completion($0 != nil) })
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
            accountName: "Work", account: Self.account, read: { _ in reading },
            refresh: { _, done in finishRefresh = done }, limits: { _ in [] }, now: { Self.now },
            completion: { decisions.append($0 != nil) })
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
            accountName: "Work", account: Self.account, read: { _ in .current(Self.usage()) },
            refresh: { _, done in done() }, limits: { _ in [] }, now: { now }, completion: { decisions.append($0 != nil) })
        XCTAssertTrue(request.canApprove)
        now = now.addingTimeInterval(121)
        request.approve()
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertFalse(request.canApprove)
    }

    func testYourLimitStillBlocksApprovalWhenProviderHasCapacity() {
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, read: { _ in .current(Self.usage()) },
            refresh: { _, done in done() }, limits: { _ in [CustomLimit(windowID: "5h", bound: 0.6, tier: .hold)] },
            now: { Self.now }, completion: { _ in XCTFail("No start may pass the user's limit") })
        XCTAssertFalse(request.canApprove)
        request.approve()
        XCTAssertFalse(request.isResolved)
    }

    func testCreditsRequireTheirOwnExplicitApprovalAndNeverConsumeResetCredits() throws {
        XCTAssertEqual(Self.request(reading: .current(Self.usage(fraction: 0.99))).funding, .includedUsage,
                       "A human start can use the remaining allowance; automatic ranking keeps its reserve")
        var usage = Self.usage(fraction: 1)
        usage.creditBalance = "25.50"
        let request = Self.request(reading: .current(usage))
        XCTAssertEqual(request.funding, .credits)
        request.approve()
        XCTAssertFalse(request.isResolved, "Ordinary approval cannot authorize purchased credits")
        request.approve(funding: .credits)
        XCTAssertTrue(request.isResolved)

        for balance in [nil, "0", "-1", "NaN", "inf", "unknown"] as [String?] {
            usage.creditBalance = balance
            usage.resetCredits = 3
            XCTAssertFalse(Self.request(reading: .current(usage)).canApprove)
        }
        usage.creditBalance = "25.50"
        XCTAssertFalse(Self.request(reading: .stale(usage, error: .decoding)).canApprove)
        let expired = Self.usage(fraction: 1, at: Self.now.addingTimeInterval(-121))
        var oldCredits = expired
        oldCredits.creditBalance = "25.50"
        XCTAssertFalse(Self.request(reading: .current(oldCredits)).canApprove)
        XCTAssertNil(SubagentAccountApproval.funding(for: Self.account, reading: .current(usage),
            rules: [CustomLimit(windowID: "5h", bound: 0.6, tier: .hold)], model: nil, at: Self.now))
    }

    func testSelectingAccountDiscardsOldRefreshAndRequiresAnotherExplicitApproval() throws {
        var callbacks: [() -> Void] = []
        var fetched: [AccountID] = []
        var decisions: [SubagentAccountApproval.Approval] = []
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, accounts: [Self.account, Self.otherAccount],
            read: { account in .current(Self.usage(fraction: account == Self.account ? 1 : 0.2)) },
            refresh: { account, done in fetched.append(account.id); callbacks.append(done) },
            limits: { _ in [] }, now: { Self.now }, completion: { if let answer = $0 { decisions.append(answer) } })
        let card = SubagentAccountApprovalCard(request: request)
        let picker = try XCTUnwrap(descendants(card).compactMap { $0 as? ThemedPopUp }.first)
        request.refresh()
        picker.chooseItem(at: 1)
        XCTAssertEqual(request.plan.accountHandle, Self.otherAccount.handle)
        XCTAssertEqual(request.accountName, "Personal")
        XCTAssertEqual(fetched, [Self.account.id, Self.otherAccount.id])
        callbacks[0]()
        XCTAssertTrue(request.isRefreshing, "Previous account cannot finish the selected account's refresh")
        XCTAssertFalse(request.canApprove)
        callbacks[1]()
        XCTAssertTrue(request.canApprove)
        XCTAssertTrue(decisions.isEmpty)
        request.approve()
        XCTAssertEqual(decisions.map(\.plan.accountHandle), [Self.otherAccount.handle])
        request.selectAccount(Self.account.id)
        XCTAssertEqual(request.plan.accountHandle, Self.otherAccount.handle, "An answered proposal is immutable")
    }

    func testCreditsCannotBypassUnknownWindowsModelLimitsOrYourOwnLimits() {
        let readings = [
            AccountUsage(windows: [], planLabel: nil, observedAt: Self.now, source: .api),
            AccountUsage(windows: [.init(id: "7d", label: "Weekly", fraction: nil,
                resetsAt: Self.now.addingTimeInterval(60), windowDuration: 604_800)],
                planLabel: nil, observedAt: Self.now, source: .api),
            AccountUsage(windows: [.init(id: "7d", label: "Weekly", fraction: 1,
                resetsAt: Self.now.addingTimeInterval(-1), windowDuration: 604_800)],
                planLabel: nil, observedAt: Self.now, source: .api)
        ]
        for var usage in readings {
            usage.creditBalance = "20"
            XCTAssertFalse(Self.request(reading: .current(usage)).canApprove)
        }
        var usage = Self.usage(fraction: 1)
        usage.creditBalance = "20"
        for tier: CustomLimitTier in [.show, .notify, .hold, .park] {
            XCTAssertNil(SubagentAccountApproval.funding(for: Self.account, reading: .current(usage),
                rules: [CustomLimit(windowID: "5h", bound: 0.6, tier: tier)], model: nil, at: Self.now))
        }
        var scopedUsage = Self.usage(fraction: 0.2)
        scopedUsage.modelWindows = [.init(id: "Fable", label: "Weekly · Fable", fraction: 1,
            resetsAt: Self.now.addingTimeInterval(3_600), windowDuration: 604_800, scopeName: "Fable")]
        XCTAssertNil(SubagentAccountApproval.funding(for: Self.account, reading: .current(scopedUsage),
            rules: [], model: "claude-fable-5[1m]", at: Self.now))
        scopedUsage.creditBalance = "20"
        XCTAssertEqual(SubagentAccountApproval.funding(for: Self.account, reading: .current(scopedUsage),
            rules: [], model: "claude-fable-5[1m]", at: Self.now), .credits)
    }

    func testOnlyEnabledAccountsOfTheProposedProviderCanBeSelected() {
        let disabled = AgentAccount(provider: .claude, handle: .standard,
            configPath: "/tmp/subagent-disabled", isEnabled: false)
        let otherProvider = AgentAccount(provider: .codex, handle: .standard,
            configPath: "/tmp/subagent-codex")
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(), brief: "Review",
            accountName: "Work", account: Self.account, accounts: [Self.account, disabled, otherProvider],
            read: { _ in .current(Self.usage()) }, refresh: { _, done in done() }, limits: { _ in [] },
            now: { Self.now }, completion: { _ in })
        XCTAssertEqual(request.accounts, [Self.account])
        request.selectAccount(disabled.id)
        request.selectAccount(otherProvider.id)
        XCTAssertEqual(request.plan.accountHandle, Self.account.handle)
    }

    func testAccountChooserKeepsAThousandAccountsAsValuesWithoutFetchingThem() throws {
        let accounts = (0..<1_000).map { index in
            AgentAccount(provider: .claude, handle: AccountHandle(storedName: "account-\(index)"),
                         configPath: "/tmp/subagent-\(index)", displayName: "Account \(index)")
        }
        var refreshes = 0
        let request = SubagentAccountApproval(parentID: SessionID(), plan: Self.plan(account: accounts[0].handle),
            brief: "Review", accountName: accounts[0].displayName, account: accounts[0], accounts: accounts,
            read: { _ in .notFetched }, refresh: { _, done in refreshes += 1; done() },
            limits: { _ in [] }, completion: { _ in })
        let card = SubagentAccountApprovalCard(request: request)
        let picker = try XCTUnwrap(descendants(card).compactMap { $0 as? ThemedPopUp }.first)
        XCTAssertEqual(picker.numberOfItems, 1_000)
        XCTAssertLessThan(descendants(card).count, 40)
        XCTAssertEqual(refreshes, 0)
        picker.chooseItem(at: 999)
        XCTAssertEqual(request.plan.accountHandle, accounts[999].handle)
        XCTAssertEqual(refreshes, 1)
    }

    func testRendersTerminalApprovalWithCreditsAndAccountSwitching() throws {
        let oldTheme = AppThemePalette.current
        let oldAppearance = NSApp.appearance
        defer { AppThemePalette.set(oldTheme); NSApp.appearance = oldAppearance }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
                         ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("light", .system, .aqua), ("dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        for (name, theme, appearanceName) in themes {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            NSApp.appearance = appearance
            var result: Result<Void, Error>?
            appearance.performAsCurrentDrawingAppearance {
                result = Result {
                    var usage = Self.usage(fraction: 1)
                    usage.creditBalance = "25.50"
                    let request = Self.request(reading: .current(usage))
                    let choice = SubagentAccountApprovalPresenter.choiceRequest(request, parentTitle: "Review")
                    let content = ConfirmationAlert.makeAlert(choice).makeContentView()
                    let host = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
                    host.appearance = appearance
                    host.contentView = content
                    host.setContentSize(content.fittingSize)
                    AppThemeRefresh.repaint(content)
                    content.layoutSubtreeIfNeeded()
                    let picker = try XCTUnwrap(descendants(content).compactMap { $0 as? ThemedPopUp }.first)
                    XCTAssertTrue(picker.isEnabled)
                    picker.chooseItem(at: 1)
                    XCTAssertEqual(request.plan.accountHandle, Self.otherAccount.handle)
                    let approve = try XCTUnwrap(descendants(content).first {
                        $0.accessibilityIdentifier() == "conversation.subagent-account-approval.approve"
                    } as? ThemedButton)
                    XCTAssertEqual(approve.title, L10n.string("Approve with Credits"))
                    XCTAssertTrue(approve.isEnabled)
                    content.layoutSubtreeIfNeeded()
                    let buttonRect = approve.convert(approve.bounds, to: content)
                    XCTAssertTrue(content.bounds.contains(buttonRect), "Approval must fit the terminal dialog")
                    let point = NSPoint(x: buttonRect.midX, y: buttonRect.midY)
                    let hit = content.hitTest(point)
                    XCTAssertTrue(hit === approve || hit?.isDescendant(of: approve) == true)
                    let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: image)
                    try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("subagent-approval-terminal-\(name).png"))
                    _ = approve.performPrimaryAction()
                    XCTAssertTrue(request.isResolved)
                }
            }
            try XCTUnwrap(result).get()
        }
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

        let switched = expectation(description: "The owner's chosen account reaches the actual launch")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertFalse(result.isError)
            switched.fulfill()
        }
        let switchRequest = try XCTUnwrap(proposed)
        let selectionReady = expectation(description: "Selected login refreshed")
        switchRequest.onChange = { if !switchRequest.isRefreshing { selectionReady.fulfill() } }
        switchRequest.selectAccount(standard.id)
        await fulfillment(of: [selectionReady], timeout: 3)
        switchRequest.approve()
        await fulfillment(of: [switched], timeout: 2)
        XCTAssertEqual(launched.last?.accountHandle, .standard)

        var paidUsage = Self.usage(fraction: 1, at: now)
        paidUsage.creditBalance = "12.50"
        usage.acceptAuthoritative(paidUsage, for: Self.account)
        let paidStart = expectation(description: "Explicit credit consent survives final admission")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertFalse(result.isError)
            paidStart.fulfill()
        }
        let paidRequest = try XCTUnwrap(proposed)
        XCTAssertEqual(paidRequest.funding, .credits)
        paidRequest.approve(funding: .credits)
        await fulfillment(of: [paidStart], timeout: 2)
        XCTAssertEqual(launched.last?.accountHandle, Self.account.handle)

        let countBeforeSpentCredits = launched.count
        let creditsSpent = expectation(description: "Credits are checked again at admission")
        service.startSubagent(arguments, for: parent.id) { result in
            XCTAssertTrue(result.isError)
            creditsSpent.fulfill()
        }
        let creditsSpentRequest = try XCTUnwrap(proposed)
        paidUsage.creditBalance = "0"
        usage.acceptAuthoritative(paidUsage, for: Self.account)
        creditsSpentRequest.approve(funding: .credits)
        await fulfillment(of: [creditsSpent], timeout: 2)
        XCTAssertEqual(launched.count, countBeforeSpentCredits)
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
        let themes: [(String, AppTheme, NSAppearance.Name)] = [
            ("light", .system, .aqua), ("dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        for (name, theme, appearanceName) in themes {
            AppThemePalette.set(theme)
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
        var paidUsage = Self.usage(fraction: 1)
        paidUsage.creditBalance = "25.50"
        chat.cancelSubagentAccountApprovals()
        let paidRequest = Self.request(parentID: parent.id, reading: .current(paidUsage))
        chat.presentSubagentAccountApproval(paidRequest)
        try capture("\(name)-credits")
        let paidCard = try XCTUnwrap(chat.activeSubagentAccountCard)
        let paidButton = try XCTUnwrap(descendants(paidCard).first {
            $0.accessibilityIdentifier() == "conversation.subagent-account-approval.approve"
        } as? ThemedButton)
        XCTAssertEqual(paidButton.title, L10n.string("Approve with Credits"))
        XCTAssertTrue(paidButton.isEnabled)

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
