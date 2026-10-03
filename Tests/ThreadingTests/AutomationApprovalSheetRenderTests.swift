import AppKit
import ThreadingController
import XCTest
@testable import Threading

/// The automation approval sheets, built through the presenters the shipping flows use.
///
/// The sheet is the receipt for starting unattended work, so the behavioural half pins *which*
/// facts it states for each purpose — above all the login a run falls back to when none was
/// chosen, which a sheet of identifiers once hid while that login's session had expired. The
/// render half writes each story light and dark under deliberately different themes.
@MainActor
final class AutomationApprovalSheetRenderTests: XCTestCase {

    // MARK: - Facts

    func testARunNamesWhereWhenWhoAndTheExactRevision() {
        let revision = Self.scheduleRevision(account: "claude-sonda-02")
        let review = AutomationReview.make(revision, purpose: .runNow, context: Self.context())

        XCTAssertEqual(review.facts.map(\.identifier),
                       ["project", "when", "agent", "account", "permissions", "allowed", "limits", "afterSuccess", "revision"])
        XCTAssertEqual(fact("project", in: review)?.value, "sonda-automations")
        XCTAssertEqual(fact("project", in: review)?.detail, "~/repo/sonda-automations")
        XCTAssertEqual(fact("when", in: review)?.value, L10n.string("Once, now"))
        XCTAssertEqual(fact("when", in: review)?.detail,
                       L10n.format("Saved schedule: %@", revision.automation!.schedule!.summary))
        XCTAssertEqual(fact("agent", in: review)?.value, "Claude Code · Opus 5.5 · High effort")
        XCTAssertEqual(fact("account", in: review)?.tone, .normal)
        XCTAssertEqual(fact("account", in: review)?.detail, "~/.claude-sonda-02")
        XCTAssertEqual(fact("revision", in: review)?.detail, revision.id.uuidString)
        XCTAssertEqual(review.instructions, revision.instructions)
        XCTAssertFalse(review.facts.contains { $0.value.contains(revision.projectID.uuidString) })
    }

    func testARunWithNoAccountSaysWhichLoginItFallsBackTo() {
        let review = AutomationReview.make(
            Self.scheduleRevision(account: nil), purpose: .enable, context: Self.context())

        let account = fact("account", in: review)
        XCTAssertEqual(account?.tone, .caution)
        XCTAssertEqual(account?.value, L10n.format("Default login, %@", "~/.claude"))
        XCTAssertEqual(account?.detail, L10n.string("No account chosen for this automation"))
        XCTAssertEqual(fact("when", in: review)?.value, Self.scheduleRevision(account: nil).automation!.schedule!.summary)
        XCTAssertEqual(fact("when", in: review)?.detail, L10n.string("A missed time runs once when the Mac is back"))
    }

    func testAnAccountThatWasNotFoundIsNotPassedOffAsTheChosenOne() {
        var context = Self.context()
        context.account = { _, _ in .init(handle: .standard, name: "Claude", directory: "~/.claude") }
        let review = AutomationReview.make(
            Self.scheduleRevision(account: "claude-gone"), purpose: .runNow, context: context)

        XCTAssertEqual(fact("account", in: review)?.tone, .caution)
        XCTAssertEqual(fact("account", in: review)?.detail,
                       L10n.format("“%@” was not found, so this login: %@", "claude-gone", "~/.claude"))
    }

    func testOnlyAnEventRuleStatesItsEventSourceAndConditions() {
        let review = AutomationReview.make(Self.eventRevision(), purpose: .activate, context: Self.context())

        XCTAssertEqual(review.facts.map(\.identifier),
                       ["project", "when", "conditions", "agent", "account", "permissions", "allowed", "limits", "revision"])
        XCTAssertEqual(fact("when", in: review)?.value, L10n.format("“%@” arrives", "case.review-required"))
        XCTAssertEqual(fact("when", in: review)?.detail, L10n.format("From %@", "Sonda review feed"))
        XCTAssertEqual(fact("conditions", in: review)?.value, "lab  equals  \"ALS\"")
        XCTAssertEqual(fact("limits", in: review)?.detail, L10n.string("One run at a time"))
        XCTAssertEqual(fact("account", in: review)?.value, L10n.format("Default login, %@", "~/.codex"))
        XCTAssertEqual(fact("account", in: review)?.detail, L10n.string("No account chosen for this automation"))
    }

    func testARevisionSavedBeforePoliciesReadsAsReadOnly() {
        let review = AutomationReview.make(
            Self.scheduleRevision(account: "claude-sonda-02"), purpose: .runNow, context: Self.context())

        XCTAssertEqual(fact("allowed", in: review)?.value, L10n.string("Read-only commands only"))
        XCTAssertEqual(fact("allowed", in: review)?.detail, L10n.string("Anything else is refused"))
        XCTAssertEqual(fact("allowed", in: review)?.tone, .normal)
    }

    func testTheSheetStatesTheAllowListRuleByRule() throws {
        let policy = try AutomationPermissionPolicy.allowList(parsing: Self.bevakningRules)
        let review = AutomationReview.make(
            Self.scheduleRevision(account: "claude-sonda-02", permissions: policy),
            purpose: .enable, context: Self.context())

        XCTAssertEqual(fact("allowed", in: review)?.value, policy.rules.map(\.text).joined(separator: "\n"))
        XCTAssertEqual(fact("allowed", in: review)?.detail,
                       L10n.string("Plus read-only commands; anything else is refused"))
        XCTAssertEqual(fact("allowed", in: review)?.tone, .normal)
    }

    func testFullPermissionIsStatedAsACaution() {
        let review = AutomationReview.make(
            Self.scheduleRevision(account: "claude-sonda-02", permissions: .full),
            purpose: .enable, context: Self.context())

        XCTAssertEqual(fact("allowed", in: review)?.value, L10n.string("Full permission"))
        XCTAssertEqual(fact("allowed", in: review)?.detail, L10n.string("Every command runs without asking"))
        XCTAssertEqual(fact("allowed", in: review)?.tone, .caution)
    }

    func testAMissingProjectIsAnnouncedRatherThanShownAsAnIdentifier() {
        var context = Self.context()
        context.project = { _ in nil }
        let revision = Self.scheduleRevision(account: "claude-sonda-02")
        let review = AutomationReview.make(revision, purpose: .runNow, context: context)

        XCTAssertEqual(fact("project", in: review)?.value, L10n.string("Unknown project"))
        XCTAssertEqual(fact("project", in: review)?.detail, revision.projectID.uuidString)
        XCTAssertEqual(fact("project", in: review)?.tone, .caution)
    }

    func testTheReviewScrollsAsOneColumnOnlyWhenTheBriefIsLong() {
        let long = AutomationReviewView(review: .make(
            Self.scheduleRevision(account: "claude-sonda-02"), purpose: .runNow, context: Self.context()))
        long.layoutSubtreeIfNeeded()
        XCTAssertEqual(long.fittingSize.height, AutomationReviewView.Layout.maximumHeight, accuracy: 0.5)
        XCTAssertTrue(long.scrollView.hasVerticalScroller)

        var short = Self.eventRevision()
        short.instructions = "Assess the case."
        let brief = AutomationReviewView(review: .make(short, purpose: .activate, context: Self.context()))
        brief.layoutSubtreeIfNeeded()
        XCTAssertLessThan(brief.fittingSize.height, AutomationReviewView.Layout.maximumHeight)
        XCTAssertFalse(brief.scrollView.hasVerticalScroller)
    }

    func testTheAgentSheetCarriesTheReviewForTheRequestedPurpose() throws {
        let revision = Self.scheduleRevision(account: "claude-sonda-02")
        let run = AutomationApprovalPresenter.confirmationRequest(
            for: .local(.run, name: "Bevakning", revision: revision), context: Self.context())
        let enable = AutomationApprovalPresenter.confirmationRequest(
            for: .local(.enable, name: "Bevakning", revision: revision), context: Self.context())

        let runReview = try XCTUnwrap(run.accessory as? AutomationReviewView).review
        let enableReview = try XCTUnwrap(enable.accessory as? AutomationReviewView).review
        XCTAssertEqual(fact("when", in: runReview)?.value, L10n.string("Once, now"))
        XCTAssertEqual(fact("when", in: enableReview)?.value, revision.automation!.schedule!.summary)
    }

    // MARK: - Storybook

    private enum Story: String, CaseIterable {
        case scheduleRun = "schedule-run"
        case scheduleEnableDefaultLogin = "schedule-enable-default-login"
        case eventActivate = "event-activate"
        case remoteRun = "remote-run"
        case scheduleRunAllowList = "schedule-run-allow-list"
        case scheduleEnableFull = "schedule-enable-full"
    }

    func testRendersTheApprovalSheetStorybook() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "ThreadingRenders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let themes: [(String, AppTheme)] = [
            ("system", .system), ("swiss", AppThemeStyles.swissMinimalist), ("neo-brutalism", AppThemeStyles.neoBrutalism),
        ]
        var written = 0
        for (themeName, theme) in themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for story in Story.allCases {
                    let data = try XCTUnwrap(image(of: request(for: story), appearance: appearance),
                                             "\(story.rawValue) \(themeName) \(appearanceName)")
                    try data.write(to: directory.appendingPathComponent(
                        "approval-\(story.rawValue)-\(themeName)-\(appearanceName).png"))
                    written += 1
                }
            }
        }
        XCTAssertEqual(written, themes.count * 2 * Story.allCases.count)
    }

    private func request(for story: Story) -> ConfirmationRequest {
        switch story {
        case .scheduleRun:
            return AutomationApprovalPresenter.confirmationRequest(
                for: .local(.run, name: "Bevakning daglig genomgång",
                            revision: Self.scheduleRevision(account: "claude-sonda-02")),
                context: Self.context())
        case .scheduleEnableDefaultLogin:
            return AutomationApprovalPresenter.confirmationRequest(
                for: .local(.enable, name: "Bevakning daglig genomgång", revision: Self.scheduleRevision(account: nil)),
                context: Self.context())
        case .eventActivate:
            return ConfirmationRequest(
                prompt: .approveTriggerActivation,
                title: L10n.format("Activate “%@”?", "Review-required cases"),
                message: L10n.string(
                    "Review the schedule or event, project, instructions, and permissions below. Enabling permits future runs with these settings."
                ),
                confirmTitle: L10n.string("Activate"),
                accessory: TriggerCenterViewController.reviewAccessory(
                    for: Self.eventRevision(), purpose: .activate, context: Self.context())
            )
        case .remoteRun:
            return AutomationApprovalPresenter.confirmationRequest(
                for: .remote(.run, automation: Self.remoteAutomation(), hostName: "sonda-vps"))
        case .scheduleRunAllowList:
            var revision = Self.scheduleRevision(account: "claude-sonda-02")
            revision.permissions = try! AutomationPermissionPolicy.allowList(parsing: Self.bevakningRules)
            return AutomationApprovalPresenter.confirmationRequest(
                for: .local(.run, name: "Bevakning daglig genomgång", revision: revision), context: Self.context())
        case .scheduleEnableFull:
            return AutomationApprovalPresenter.confirmationRequest(
                for: .local(.enable, name: "Bevakning daglig genomgång",
                            revision: Self.scheduleRevision(account: "claude-sonda-02", permissions: .full)),
                context: Self.context())
        }
    }

    private func image(of request: ConfirmationRequest, appearance name: NSAppearance.Name) -> Data? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            MainActor.assumeIsolated {
                let content = ConfirmationAlert.makeAlert(request).makeContentView()
                content.appearance = appearance
                content.layoutSubtreeIfNeeded()
                content.frame = NSRect(origin: .zero, size: content.fittingSize)
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.cacheDisplay(in: content.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
        }
        return data
    }

    // MARK: - Fixtures

    private func fact(_ identifier: String, in review: AutomationReview) -> FactSheetView.Fact? {
        review.facts.first { $0.identifier == identifier }
    }

    static func context() -> AutomationReview.Context {
        AutomationReview.Context(
            project: { _ in ("sonda-automations", "~/repo/sonda-automations") },
            account: { kind, handle in
                let standard = kind == .codex ? "codex" : "claude"
                switch handle {
                case .standard: return .init(handle: .standard, name: kind.displayName, directory: "~/.\(standard)")
                case .named(let name): return .init(handle: handle, name: name, directory: "~/.\(name)")
                }
            },
            model: { revision in revision.agentKind == .codex ? "GPT-5.5" : "Opus 5.5" },
            effort: { revision in revision.reasoningEffort.map { _ in L10n.format("%@ effort", "High") } },
            sourceName: { _ in "Sonda review feed" }
        )
    }

    static let instructions = String(repeating: """
        Daily triage of Sonda's monitored sources ("bevakningar") in changedetection.io on the Sonda VPS. \
        Decide which changes matter to Sonda and which could become customer news, write one Swedish HTML \
        report, and mail it to Viktor and David only when something is relevant.

        1. Collect. Run the collector and read its JSON.
        2. Triage every changed watch and write the report.

        """, count: 3)

    static let bevakningRules = [
        "Bash(python3 /Users/david/repo/sonda-automations/bevakning/collect.py *)",
        "Bash(python3 /Users/david/repo/sonda-automations/bevakning/send.py *)",
        "Bash(git -C /Users/david/repo/sonda fetch --quiet origin develop)",
        "Write(/Users/david/Downloads/Sonda-bevakning/**)",
        "WebFetch(domain:eur-lex.europa.eu)",
    ]

    static func scheduleRevision(account: String?, permissions: AutomationPermissionPolicy? = nil) -> TriggerRevision {
        TriggerRevision(
            id: TriggerRevisionID(), triggerID: TriggerID(), sequence: 2,
            sourceInstallationID: TriggerSourceInstallationID(), eventKind: "schedule.due", conditions: [],
            projectID: ProjectID(), instructions: instructions, agentKind: .claude,
            accountHandleName: account, model: "claude-opus-5-5", reasoningEffort: "high",
            executionMode: .taskLocalEdits, checkoutPolicy: .projectCheckout,
            limits: TriggerLimits(maximumConcurrentRuns: 1, maximumRuntimeMinutes: 60),
            quietHours: nil, notifications: .standard, allowSourceResources: false,
            proposedBySessionID: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            automation: AutomationOptions(
                schedule: AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 9, minute: 30),
                missedRunPolicy: .latest, archiveOnSuccess: true),
            permissions: permissions
        )
    }

    static func eventRevision() -> TriggerRevision {
        TriggerRevision(
            id: TriggerRevisionID(), triggerID: TriggerID(), sequence: 1,
            sourceInstallationID: TriggerSourceInstallationID(), eventKind: "case.review-required",
            conditions: [TriggerCondition(attribute: "lab", comparison: .equals, value: .string("ALS"))],
            projectID: ProjectID(), instructions: "Assess the case and fix the parser if the cause is obvious.",
            agentKind: .codex, accountHandleName: nil, model: nil, reasoningEffort: nil,
            executionMode: .assessThenFix, checkoutPolicy: .managedWorktree, limits: .conservative,
            quietHours: nil, notifications: .standard, allowSourceResources: false,
            proposedBySessionID: nil, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// The controller's record has no public initializer; it arrives decoded over owner-RPC, so
    /// the fixture is decoded the same way from a spec encoded by the real encoder.
    static func remoteAutomation() -> ControllerAutomation {
        let spec = ControllerAutomationSpec(
            name: "Nightly corpus refresh", workerID: WorkerID(),
            instruction: "Refresh the corpus index and report anything that failed to parse.",
            schedule: AutomationSchedule(kind: .daily, timeZone: "Europe/Stockholm", hour: 3, minute: 15))
        let specJSON = String(decoding: try! JSONEncoder().encode(spec), as: UTF8.self)
        let json = """
            {"id":"\(UUID().uuidString)","revision":4,"enabled":false,"deleted":false,"spec":\(specJSON)}
            """
        return try! JSONDecoder().decode(ControllerAutomation.self, from: Data(json.utf8))
    }
}
