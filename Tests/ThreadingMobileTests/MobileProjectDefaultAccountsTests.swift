import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The phone's half of a project's ordered default logins: the draft's prediction, when it is
/// decided again, what the create request says, who gets the editor, and what the editor saves.
final class MobileProjectDefaultAccountsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let work = RemoteAccountReferenceDTO(agentID: "claude", accountID: "work")
    private let spare = RemoteAccountReferenceDTO(agentID: "claude", accountID: "spare")
    private let codex = RemoteAccountReferenceDTO(agentID: "codex", accountID: "default")

    // MARK: - Prediction

    func testTheFirstListedLoginWithRoomIsChosen() {
        let prediction = predict([work, spare], agents: [
            claude(work: [window(0.40)], spare: [window(0.10)]),
        ])

        XCTAssertEqual(prediction.chosen, work, "the order outranks which login has more room")
        XCTAssertEqual(prediction.entries.map(\.state), [.usable, .usable])
        XCTAssertFalse(prediction.isEverythingSpent)
    }

    func testASpentLoginIsSkipped() {
        let prediction = predict([work, spare], agents: [
            claude(work: [window(0.95, resetsIn: 3_600)], spare: [window(0.20)]),
        ])

        XCTAssertEqual(prediction.chosen, spare)
        XCTAssertEqual(
            prediction.entries.first?.state,
            .spent(until: now.addingTimeInterval(3_600))
        )
    }

    func testTheLineIsTheOneTheMacUses() {
        let atLine = predict([work, spare], agents: [
            claude(
                work: [window(RemoteProjectDefaultAccounts.spentFraction)],
                spare: [window(0.10)]
            ),
        ])
        let belowLine = predict([work, spare], agents: [
            claude(work: [window(0.919)], spare: [window(0.10)]),
        ])

        XCTAssertEqual(atLine.chosen, spare, "at the line is out")
        XCTAssertEqual(belowLine.chosen, work)
    }

    func testAnUnknownReadingIsPickableButNotShownAsRoom() {
        let prediction = predict([work, spare], agents: [
            claude(work: [window(nil)], spare: [window(0.10)]),
        ])

        XCTAssertEqual(prediction.chosen, work, "unknown is not evidence of exhaustion")
        XCTAssertEqual(prediction.entries.first?.state, .unverified)
        XCTAssertEqual(
            MobileProjectDefaultAccounts.stateLine(.unverified, account: nil, reading: nil),
            MobileL10n.string("Usage unknown")
        )
    }

    func testALoginNothingHasReadIsPickable() {
        let unread = account("work", windows: [])
        let failed = account("work", windows: nil, usageError: "unavailable")

        XCTAssertEqual(MobileProjectDefaultAccounts.state(of: unread, model: nil, now: now), .unverified)
        XCTAssertEqual(MobileProjectDefaultAccounts.state(of: failed, model: nil, now: now), .unverified)
    }

    func testAWindowPastItsResetProvesNothing() {
        let prediction = predict([work, spare], agents: [
            claude(work: [window(0.99, resetsIn: -60)], spare: [window(0.10)]),
        ])

        XCTAssertEqual(prediction.chosen, work)
        XCTAssertEqual(prediction.entries.first?.state, .unverified)
    }

    func testAnOlderHostsBindingFractionCanStillProveExhaustion() {
        let older = account("work", windows: nil, fraction: 0.97)

        XCTAssertEqual(
            MobileProjectDefaultAccounts.state(of: older, model: nil, now: now),
            .spent(until: nil)
        )
    }

    func testWhenEverythingIsSpentTheSoonestResetIsChosen() {
        let prediction = predict([work, spare], agents: [
            claude(
                work: [window(0.99, resetsIn: 3 * 3_600)],
                spare: [window(0.95, resetsIn: 3_600)]
            ),
        ])

        XCTAssertEqual(prediction.chosen, spare)
        XCTAssertTrue(prediction.isEverythingSpent)
    }

    func testEqualResetsGoToTheListsOrder() {
        let prediction = predict([spare, work], agents: [
            claude(
                work: [window(0.99, resetsIn: 3_600)],
                spare: [window(0.99, resetsIn: 3_600)]
            ),
        ])

        XCTAssertEqual(prediction.chosen, spare)
    }

    func testAnUnknownResetComesBackLast() {
        let prediction = predict([work, spare], agents: [
            claude(
                work: [window(0.99, resetsIn: nil)],
                spare: [window(0.99, resetsIn: 7 * 24 * 3_600)]
            ),
        ])

        XCTAssertEqual(prediction.entries.first?.state, .spent(until: nil))
        XCTAssertEqual(prediction.chosen, spare)
    }

    func testALoginOutOnSeveralWindowsComesBackWhenTheLastOneResets() {
        let state = MobileProjectDefaultAccounts.state(
            of: account("work", windows: [
                window(0.95, resetsIn: 3_600, id: "5h"),
                window(0.99, resetsIn: 5 * 3_600, id: "7d"),
            ]),
            model: nil,
            now: now
        )

        XCTAssertEqual(state, .spent(until: now.addingTimeInterval(5 * 3_600)))
    }

    func testAReferenceTheCatalogueDoesNotOfferIsUnavailableAndSkipped() {
        let ghost = RemoteAccountReferenceDTO(agentID: "claude", accountID: "renamed")
        let gone = RemoteAccountReferenceDTO(agentID: "retired-runtime", accountID: "default")
        let agents = [claude(work: [window(0.10)], spare: [window(0.10)])]

        let prediction = predict([ghost, gone, spare], agents: agents)

        XCTAssertEqual(prediction.chosen, spare)
        XCTAssertEqual(prediction.entries.map(\.state).prefix(2), [.unavailable, .unavailable])
        XCTAssertNil(predict([ghost, gone], agents: agents).chosen, "nothing to start on: the app's rule")
        XCTAssertEqual(
            MobileProjectDefaultAccounts.stateLine(.unavailable, account: nil, reading: nil),
            MobileL10n.string("Unavailable login")
        )
    }

    func testAModelScopedWindowMetersOnlyItsModel() {
        let scoped = window(0.97, resetsIn: 3_600, id: "7d-fable", meters: ["fable"])
        let agents = [claude(work: [window(0.30), scoped], spare: [window(0.10)])]

        let onSol = MobileProjectDefaultAccounts.predict(
            list: [work, spare],
            agents: agents,
            model: { _, _ in "sol" },
            now: now
        )
        let onFable = MobileProjectDefaultAccounts.predict(
            list: [work, spare],
            agents: agents,
            model: { _, _ in "fable" },
            now: now
        )

        XCTAssertEqual(onSol.chosen, work, "a Fable window does not stop a Sol chat")
        XCTAssertEqual(onFable.chosen, spare)
    }

    func testTheListCanFallBackToAnotherRuntime() {
        let prediction = predict([work, spare, codex], agents: [
            claude(work: [window(0.99, resetsIn: 600)], spare: [window(0.96, resetsIn: 600)]),
            agent("codex", accounts: [account("default", windows: [window(0.20)])]),
        ])

        XCTAssertEqual(prediction.chosen, codex)
    }

    func testAHandPickedRuntimeTakesTheFirstUsableLoginListedForIt() {
        let agents = [
            claude(work: [window(0.99, resetsIn: 600)], spare: [window(0.10)]),
            agent("codex", accounts: [account("default", windows: [window(0.20)])]),
        ]

        XCTAssertEqual(
            MobileProjectDefaultAccounts.predict(
                list: [codex, work, spare],
                runtime: "claude",
                agents: agents,
                now: now
            ),
            spare
        )
        XCTAssertNil(MobileProjectDefaultAccounts.predict(
            list: [codex],
            runtime: "claude",
            agents: agents,
            now: now
        ), "a runtime the list does not name keeps the app's rule")
    }

    // MARK: - When the Draft Decides

    func testTheListDecidesWhenTheDraftFirstHasAProject() {
        let opened = SessionDraftIdentity(agentID: "", accountID: "", source: .appRule, projectID: nil)

        let resolved = resolve(opened, projectID: "a", pick: work)

        XCTAssertEqual(resolved, SessionDraftIdentity(
            agentID: "claude", accountID: "work", source: .projectDefault, projectID: "a"
        ))
    }

    func testAProjectWithoutAListKeepsTheAppsRule() {
        let opened = SessionDraftIdentity(
            agentID: "codex", accountID: "default", source: .appRule, projectID: nil
        )

        let resolved = resolve(opened, projectID: "a", pick: nil)

        XCTAssertEqual(resolved.agentID, "codex")
        XCTAssertEqual(resolved.accountID, "default")
        XCTAssertEqual(resolved.source, .appRule)
        XCTAssertEqual(resolved.projectID, "a")
    }

    func testAnOpenDraftIsNotSwitchedUnderThePerson() {
        let shown = SessionDraftIdentity(
            agentID: "claude", accountID: "work", source: .projectDefault, projectID: "a"
        )
        let appRule = SessionDraftIdentity(
            agentID: "codex", accountID: "default", source: .appRule, projectID: "a"
        )

        // A reading arrived that would now pick another login, or the list itself changed.
        XCTAssertEqual(resolve(shown, projectID: "a", pick: spare), shown)
        XCTAssertEqual(resolve(appRule, projectID: "a", pick: spare), appRule)
    }

    /// The draft re-resolves on every catalogue refresh; a settled one must not pay for a
    /// prediction it will not use.
    func testASettledDraftDoesNotPredict() {
        let shown = SessionDraftIdentity(
            agentID: "claude", accountID: "work", source: .projectDefault, projectID: "a"
        )
        var predictions = 0
        func predicted() -> RemoteAccountReferenceDTO? {
            predictions += 1
            return spare
        }

        _ = SessionDraftIdentityResolution.resolve(
            current: shown,
            projectID: "a",
            pick: predicted(),
            appRuleAgentID: "codex",
            isCurrentOffered: true
        )
        XCTAssertEqual(predictions, 0)

        _ = SessionDraftIdentityResolution.resolve(
            current: shown,
            projectID: "b",
            pick: predicted(),
            appRuleAgentID: "codex",
            isCurrentOffered: true
        )
        XCTAssertEqual(predictions, 1)
    }

    func testMovingTheDraftToAnotherProjectTakesThatProjectsList() {
        let shown = SessionDraftIdentity(
            agentID: "claude", accountID: "work", source: .projectDefault, projectID: "a"
        )
        let appRule = SessionDraftIdentity(
            agentID: "codex", accountID: "default", source: .appRule, projectID: "a"
        )

        XCTAssertEqual(resolve(shown, projectID: "b", pick: codex), SessionDraftIdentity(
            agentID: "codex", accountID: "default", source: .projectDefault, projectID: "b"
        ))
        XCTAssertEqual(resolve(appRule, projectID: "b", pick: spare).source, .projectDefault)
        XCTAssertEqual(resolve(appRule, projectID: "b", pick: spare).accountID, "spare")
    }

    func testMovingToAProjectWithoutAListReturnsToTheAppsRule() {
        let shown = SessionDraftIdentity(
            agentID: "claude", accountID: "spare", source: .projectDefault, projectID: "a"
        )

        let resolved = resolve(shown, projectID: "b", pick: nil, appRuleAgentID: "codex")

        XCTAssertEqual(resolved, SessionDraftIdentity(
            agentID: "codex", accountID: "", source: .appRule, projectID: "b"
        ), "the last project's choice is not this project's")
    }

    func testAPersonsChoiceIsNeverReplaced() {
        let chosen = SessionDraftIdentity(
            agentID: "claude", accountID: "spare", source: .explicit, projectID: "a"
        )

        XCTAssertEqual(resolve(chosen, projectID: "b", pick: codex), chosen)
        XCTAssertEqual(resolve(chosen, projectID: "a", pick: work, isCurrentOffered: false), chosen)
    }

    func testAListsPickTheMacWithdrewIsDecidedAgain() {
        let shown = SessionDraftIdentity(
            agentID: "claude", accountID: "work", source: .projectDefault, projectID: "a"
        )

        let resolved = resolve(shown, projectID: "a", pick: spare, isCurrentOffered: false)

        XCTAssertEqual(resolved.accountID, "spare")
        XCTAssertEqual(resolved.source, .projectDefault)
    }

    // MARK: - What the Create Request Says

    func testOnlyAListsPickOnAMacThatKeepsListsSaysProjectDefault() {
        let current = [RemoteRESTFeature.projectDefaultAccounts.rawValue]
        let older = [RemoteRESTFeature.projectVisibility.rawValue]

        XCTAssertEqual(
            MobileProjectDefaultAccounts.accountSelection(source: .projectDefault, features: current),
            .projectDefault
        )
        for source in [SessionDraftIdentitySource.explicit, .appRule] {
            XCTAssertNil(MobileProjectDefaultAccounts.accountSelection(source: source, features: current))
        }
        for features in [older, nil] {
            XCTAssertNil(
                MobileProjectDefaultAccounts.accountSelection(
                    source: .projectDefault,
                    features: features
                ),
                "an older Mac is never sent a word it would ignore"
            )
        }
    }

    func testAnOlderMacsCreateRequestCarriesNoSelectionField() throws {
        let request = RemoteCreateSessionRequestDTO(
            projectID: "a",
            agentKind: "claude",
            accountHandle: "work",
            surface: .terminal,
            accountSelection: MobileProjectDefaultAccounts.accountSelection(
                source: .projectDefault,
                features: [RemoteRESTFeature.projectVisibility.rawValue]
            ),
            prompt: "Go"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertNil(object["accountSelection"])
        XCTAssertEqual(object["accountHandle"] as? String, "work")
    }

    // MARK: - Who Gets the Editor

    @MainActor
    func testAnOlderMacShowsNoDefaultAccountsEditor() throws {
        let model = RemoteAppModel()
        model.startDemo()

        XCTAssertTrue(model.canManageProjectVisibility, "the demo is an owner on a Mac")
        XCTAssertFalse(model.offersProjectDefaultAccounts)
        XCTAssertFalse(model.canManageProjectDefaultAccounts)
        XCTAssertFalse(RemoteAppModel.canManageProjectDefaultAccounts(in: nil))
    }

    @MainActor
    func testAnOwnerOnAMacThatKeepsListsGetsTheEditor() {
        let features = [RemoteRESTFeature.projectDefaultAccounts.rawValue]

        XCTAssertTrue(RemoteAppModel.canManageProjectDefaultAccounts(
            in: me(capability: .interact, features: features)
        ))
        XCTAssertFalse(RemoteAppModel.canManageProjectDefaultAccounts(
            in: me(capability: .view, features: features)
        ), "a device that cannot start chats cannot save the list either")
        XCTAssertFalse(RemoteAppModel.canManageProjectDefaultAccounts(
            in: me(capability: .interact, features: features, catalogue: false)
        ))
        XCTAssertFalse(RemoteAppModel.canManageProjectDefaultAccounts(
            in: me(capability: .interact, features: [RemoteRESTFeature.projectVisibility.rawValue])
        ))
    }

    // MARK: - The Editor

    func testReorderingSavesTheListInItsNewOrder() {
        var editor = MobileProjectDefaultAccountsEditor(list: [work, spare, codex])
        XCTAssertFalse(editor.hasChanges)

        editor.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(
            editor.request(projectID: "a"),
            RemoteSetProjectDefaultAccountsRequestDTO(projectID: "a", accounts: [codex, work, spare])
        )
    }

    func testRemovingAndAddingEditTheWholeList() {
        let agents = [
            claude(work: [window(0.10)], spare: [window(0.10)]),
            agent("codex", accounts: [account("default", windows: [])]),
            agent("grok", accounts: nil),
        ]
        var editor = MobileProjectDefaultAccountsEditor(list: [work, spare])

        XCTAssertEqual(editor.available(in: agents), [codex], "every other login, runtimes included")

        editor.remove(atOffsets: IndexSet(integer: 0))
        editor.add(codex)
        editor.add(codex)

        XCTAssertEqual(editor.entries, [spare, codex], "a login is listed once")
        XCTAssertEqual(editor.available(in: agents), [work])
        XCTAssertEqual(editor.request(projectID: "a").accounts, [spare, codex])
    }

    func testClearingTheListSavesAnEmptyList() {
        var editor = MobileProjectDefaultAccountsEditor(list: [work])

        editor.remove(atOffsets: IndexSet(integer: 0))

        XCTAssertTrue(editor.hasChanges)
        XCTAssertEqual(editor.request(projectID: "a").accounts, [])
    }

    func testTheEditorHoldsTheListTheWayTheMacStoresIt() {
        let many = (0..<40).map {
            RemoteAccountReferenceDTO(agentID: "claude", accountID: "login-\($0)")
        }
        var editor = MobileProjectDefaultAccountsEditor(list: [work, work] + many)

        XCTAssertEqual(editor.entries.count, RemoteProjectDefaultAccounts.maximumEntries)
        XCTAssertEqual(editor.entries.first, work)
        XCTAssertFalse(editor.canAdd)
        XCTAssertFalse(editor.hasChanges, "normalizing what the Mac sent is not an edit")

        editor.add(codex)
        XCTAssertFalse(editor.entries.contains(codex))
    }

    // MARK: - The Receipt

    func testTheReceiptNamesBothLoginsAndWhy() {
        let agents = [claude(work: [], spare: [])]
        let out = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .spent
        )
        let ownLimit = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .ownLimit
        )
        let timed = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .spent,
            resetsAt: now.addingTimeInterval(3_600).timeIntervalSince1970
        )

        XCTAssertEqual(
            MobileProjectDefaultAccounts.receipt(for: out, agentID: "claude", agents: agents, now: now),
            MobileL10n.string("Started on %@ — %@ is out of usage", "Spare", "Work")
        )
        XCTAssertEqual(
            MobileProjectDefaultAccounts.receipt(
                for: ownLimit,
                agentID: "claude",
                agents: agents,
                now: now
            ),
            MobileL10n.string("Started on %@ — %@ reached your limit", "Spare", "Work")
        )
        XCTAssertEqual(
            MobileProjectDefaultAccounts.receipt(for: timed, agentID: "claude", agents: agents, now: now),
            MobileL10n.string(
                "Started on %@ — %@ is out until %@",
                "Spare",
                "Work",
                MobileProjectDefaultAccounts.resetTime(now.addingTimeInterval(3_600), now: now)
            )
        )
    }

    @MainActor
    func testTheCreatedChatKeepsTheReceiptForItsScreen() throws {
        let model = RemoteAppModel()
        let draft = MobileSessionDraft(projectName: "Threading")
        let substitution = RemoteAccountSubstitutionDTO(
            requestedAccountID: "work",
            accountID: "spare",
            reason: .spent
        )

        model.noteDraftStarted(draft, creation: MobileCreatedSession(
            session: RemoteSessionSummaryDTO(
                id: "session",
                title: "Review",
                agentKind: "claude",
                surface: .terminal,
                state: .working,
                projectName: "Threading"
            ),
            openingStrategy: .awaitCreatedSession,
            accountSubstitution: substitution
        ))

        let notice = try XCTUnwrap(model.startedDrafts[draft.id]?.accountReceipt)
        XCTAssertEqual(notice.substitution, substitution)
        XCTAssertEqual(
            notice.expiresAt.timeIntervalSince(notice.shownAt),
            MobileAccountSubstitutionNotice.displayDuration
        )
    }

    // MARK: - Rendered State

    /// The shipping editor page, under a light and a dark theme, with a listed login that has a
    /// reading, one the catalogue no longer offers, and the rest of the Mac's logins to add. The
    /// rows stand on the theme's own panel rather than UIKit's grouped grey, which is what
    /// `ThemedSettingsSection` exists for. The pictures land in the test's temporary directory,
    /// or in `THREADING_RENDER_OUT` when it names one.
    @MainActor
    func testTheEditorPageStandsOnTheThemesPlates() throws {
        let model = RemoteAppModel()
        model.startDemo()
        let project = try XCTUnwrap(model.me?.newSessionCatalog?.projects.first)
        let route = MobileProjectDefaultAccountsRoute(projectID: project.id, list: [
            RemoteAccountReferenceDTO(agentID: "claude", accountID: "keller"),
            RemoteAccountReferenceDTO(agentID: "claude", accountID: "renamed-login"),
            RemoteAccountReferenceDTO(agentID: "claude", accountID: "default"),
        ])
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory

        for (name, dto) in [("light", RemoteAppModel.demoLightTheme), ("dark", RemoteAppModel.demoTheme)] {
            let palette = RemoteThemePalette(dto)
            let host = UIHostingController(
                rootView: MobileProjectDefaultAccountsView(route: route)
                    .environmentObject(model)
                    .mobileTheme(palette)
            )
            let window = hostedWindow(rootViewController: host)
            defer { window.isHidden = true }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let file = output.appendingPathComponent("project-default-accounts-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: file)
            print("Rendered \(file.path)")

            // A row's plate, sampled beside its text: the theme's panel, never a system grey.
            let rowPlate = try XCTUnwrap(pixel(in: image, at: CGPoint(x: 30, y: 200)))
            XCTAssertEqual(rowPlate, UIColor(palette.panel).rgba8, accuracy: 3, "\(name) row plate")
        }
    }

    /// The draft as it ships, hosted with the stores it reads: a project that lists a Claude
    /// login starts the draft on Claude, where the app's own rule would have taken Codex. The
    /// bar's disc wears the runtime's own mark, and Claude's keeps its coral, so the bar says
    /// which runtime the draft is on without asking SwiftUI's toolbar for an accessibility
    /// label it does not give a hosted test. The same catalogue from a Mac that does not
    /// advertise the feature leaves the draft on the app's rule.
    @MainActor
    func testADraftInAProjectWithAListStartsOnTheListsPick() throws {
        let listed = try draftBarCoralPixels(advertisingFeature: true)
        let older = try draftBarCoralPixels(advertisingFeature: false)

        XCTAssertGreaterThan(listed, 20, "the draft did not start on the project's Claude login")
        XCTAssertEqual(older, 0, "an older Mac's draft must keep the app's own rule")
    }

    /// The receipt is the started chat's: it appears over the session the draft became, names
    /// both logins in the catalogue's words, and a tap takes it away.
    @MainActor
    func testAStartedChatOpensWithTheReceiptForAMovedLogin() throws {
        let restoreAccessibility = try MobileAccessibilityTestRuntime.enableAutomation()
        defer { restoreAccessibility() }
        let model = RemoteAppModel(
            continuity: MobileSessionContinuityStore(defaults: try XCTUnwrap(UserDefaults(
                suiteName: "MobileProjectDefaultAccountsTests.\(UUID().uuidString)"
            )))
        )
        model.startDemo()
        let draft = MobileSessionDraft(projectName: "Strom")
        let screen = NavigationStack {
            SessionDraftView(draft: draft)
        }
        .environmentObject(model)
        .environmentObject(MobileSessionContinuityStore(defaults: try XCTUnwrap(UserDefaults(
            suiteName: "MobileProjectDefaultAccountsTests.\(UUID().uuidString)"
        ))))
        .environmentObject(MobileTerminalKeyboardStore())
        .environmentObject(RemoteNotificationManager())
        .mobileTheme(RemoteThemePalette(RemoteAppModel.demoLightTheme))
        let window = hostedWindow(rootViewController: UIHostingController(rootView: screen))
        defer { window.isHidden = true }
        let session = try XCTUnwrap(model.me?.sessions.first { $0.agentKind == "claude" })
        let substitution = RemoteAccountSubstitutionDTO(
            requestedAccountID: "default",
            accountID: "keller",
            reason: .spent,
            resetsAt: Date().addingTimeInterval(2 * 3_600).timeIntervalSince1970
        )
        let expected = MobileProjectDefaultAccounts.receipt(
            for: substitution,
            agentID: "claude",
            agents: model.me?.newSessionCatalog?.agents ?? []
        )
        XCTAssertTrue(expected.contains("Vera Keller"), "the receipt names logins as the catalogue does")
        XCTAssertNil(accessibleElement(labelled: expected, in: window), "no receipt before the send")

        model.noteDraftStarted(draft, creation: MobileCreatedSession(
            session: session,
            openingStrategy: .awaitCreatedSession,
            accountSubstitution: substitution
        ))
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-default-accounts-receipt.png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("Rendered \(file.path)")

        let receipt = try XCTUnwrap(
            accessibleElement(labelled: expected, in: window),
            "the opened chat does not show the receipt"
        )
        let frame = window.convert(receipt.accessibilityFrame, from: nil)
        let plate = try XCTUnwrap(pixel(in: image, at: CGPoint(x: frame.minX + 4, y: frame.midY)))
        let palette = RemoteThemePalette(RemoteAppModel.demoLightTheme)
        let wash = UIColor(palette.accentMuted).rgba8
        let ground = palette.uiGround.rgba8
        let alpha = Double(wash[3]) / 255
        let expectedPlate = zip(wash.prefix(3), ground.prefix(3)).map {
            UInt8((Double($0) * alpha + Double($1) * (1 - alpha)).rounded())
        } + [255]
        XCTAssertEqual(plate, expectedPlate, accuracy: 3, "receipt stands on its own theme ground")
    }

    // MARK: - Fixtures

    /// The first accessibility element anywhere under `root` whose label is `label`.
    @MainActor
    private func accessibleElement(labelled label: String, in root: NSObject) -> NSObject? {
        MobileAccessibilityTestRuntime.element(labelled: label, in: root)
    }

    /// Hosts a draft in Strom, whose list names Claude's second login, and counts the pixels of
    /// Claude's coral in the navigation bar's trailing control.
    @MainActor
    private func draftBarCoralPixels(advertisingFeature: Bool) throws -> Int {
        let model = RemoteAppModel(
            continuity: MobileSessionContinuityStore(defaults: try XCTUnwrap(UserDefaults(
                suiteName: "MobileProjectDefaultAccountsTests.\(UUID().uuidString)"
            )))
        )
        model.startDemo()
        let demo = try XCTUnwrap(model.me)
        let catalogue = try XCTUnwrap(demo.newSessionCatalog)
        XCTAssertEqual(
            SessionDraftCatalogReconciliation.agentID(current: "", catalog: catalogue),
            "codex",
            "the app's rule must not already be Claude, or this proves nothing"
        )
        let projects = catalogue.projects.map { project in
            RemoteProjectChoiceDTO(
                id: project.id,
                name: project.name,
                branch: project.branch,
                checkoutLabel: project.checkoutLabel,
                reportLaunch: project.reportLaunch,
                isHidden: project.isHidden,
                repository: project.repository,
                defaultAccounts: project.name == "Strom"
                    ? [RemoteAccountReferenceDTO(agentID: "claude", accountID: "keller")]
                    : nil
            )
        }
        let features = (demo.features ?? []) + (advertisingFeature
            ? [RemoteRESTFeature.projectDefaultAccounts.rawValue]
            : [])
        model.adoptRefreshedCatalogueIfChanged(RemoteMeDTO(
            serverProtocol: demo.serverProtocol,
            share: demo.share,
            sessions: demo.sessions,
            terminals: demo.terminals,
            host: demo.host,
            theme: demo.theme,
            themeCatalog: demo.themeCatalog,
            archivedSessions: demo.archivedSessions,
            newSessionCatalog: RemoteNewSessionCatalogDTO(
                projects: projects,
                agents: catalogue.agents,
                supportsManagerRole: catalogue.supportsManagerRole
            ),
            features: features,
            revision: demo.revision
        ))
        XCTAssertEqual(model.offersProjectDefaultAccounts, advertisingFeature)

        let screen = NavigationStack {
            SessionDraftView(draft: MobileSessionDraft(projectName: "Strom"))
        }
        .environmentObject(model)
        .environmentObject(MobileSessionContinuityStore(defaults: try XCTUnwrap(UserDefaults(
            suiteName: "MobileProjectDefaultAccountsTests.\(UUID().uuidString)"
        ))))
        .environmentObject(MobileTerminalKeyboardStore())
        .environmentObject(RemoteNotificationManager())
        .mobileTheme(RemoteThemePalette(nil))
        let window = hostedWindow(rootViewController: UIHostingController(rootView: screen))
        defer { window.isHidden = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let name = advertisingFeature ? "listed" : "older-host"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-default-accounts-draft-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("Rendered \(file.path)")

        // The trailing control of the bar, wherever the safe area put the bar.
        let bitmap = try XCTUnwrap(rgbaBitmap(of: image))
        var coral = 0
        for y in 0..<min(160, bitmap.height) {
            for x in max(0, bitmap.width - 90)..<bitmap.width {
                let offset = (y * bitmap.width + x) * 4
                let (red, green, blue) = (
                    Int(bitmap.bytes[offset]),
                    Int(bitmap.bytes[offset + 1]),
                    Int(bitmap.bytes[offset + 2])
                )
                if red > 180, (90...150).contains(green), (60...120).contains(blue) { coral += 1 }
            }
        }
        return coral
    }

    private func rgbaBitmap(of image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    @MainActor
    private func hostedWindow(rootViewController: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        return window
    }

    private func pixel(in image: UIImage, at point: CGPoint) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(
            cgImage,
            in: CGRect(
                x: -point.x,
                y: point.y - CGFloat(cgImage.height) + 1,
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        )
        return rgba
    }

    private func predict(
        _ list: [RemoteAccountReferenceDTO],
        agents: [RemoteAgentChoiceDTO]
    ) -> MobileProjectDefaultAccounts.Prediction {
        MobileProjectDefaultAccounts.predict(list: list, agents: agents, now: now)
    }

    private func resolve(
        _ current: SessionDraftIdentity,
        projectID: String,
        pick: RemoteAccountReferenceDTO?,
        appRuleAgentID: String = "codex",
        isCurrentOffered: Bool = true
    ) -> SessionDraftIdentity {
        SessionDraftIdentityResolution.resolve(
            current: current,
            projectID: projectID,
            pick: pick,
            appRuleAgentID: appRuleAgentID,
            isCurrentOffered: isCurrentOffered
        )
    }

    private func window(
        _ fraction: Double?,
        resetsIn: TimeInterval? = 3_600,
        id: String = "5h",
        meters: [String]? = nil
    ) -> RemoteAccountUsageWindowDTO {
        RemoteAccountUsageWindowDTO(
            id: id,
            name: id,
            fraction: fraction,
            resetsAt: resetsIn.map { now.addingTimeInterval($0).timeIntervalSince1970 },
            metersModelIDs: meters
        )
    }

    private func account(
        _ id: String,
        windows: [RemoteAccountUsageWindowDTO]?,
        fraction: Double? = nil,
        usageError: String? = nil
    ) -> RemoteAccountChoiceDTO {
        RemoteAccountChoiceDTO(
            id: id,
            name: id.capitalized,
            usageFraction: fraction,
            usageError: usageError,
            usageWindows: windows,
            models: [],
            defaultModelID: "sol"
        )
    }

    private func agent(_ id: String, accounts: [RemoteAccountChoiceDTO]?) -> RemoteAgentChoiceDTO {
        RemoteAgentChoiceDTO(
            id: id,
            name: id.capitalized,
            accounts: accounts,
            models: [],
            defaultModelID: nil,
            supportsConversation: false
        )
    }

    private func claude(
        work: [RemoteAccountUsageWindowDTO],
        spare: [RemoteAccountUsageWindowDTO]
    ) -> RemoteAgentChoiceDTO {
        agent("claude", accounts: [
            account("work", windows: work),
            account("spare", windows: spare),
        ])
    }

    private func me(
        capability: RemoteAdvertisedCapability,
        features: [String],
        catalogue: Bool = true
    ) -> RemoteMeDTO {
        RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "Phone", scope: .all, capability: capability, expiresAt: nil),
            sessions: [],
            newSessionCatalog: catalogue
                ? RemoteNewSessionCatalogDTO(projects: [], agents: [])
                : nil,
            features: features
        )
    }
}

private extension UIColor {
    /// The colour as 8-bit sRGB components, the way a rendered pixel reads.
    var rgba8: [UInt8] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { UInt8(max(0, min(1, $0)) * 255 + 0.5) }
    }
}

private func XCTAssertEqual(
    _ actual: [UInt8],
    _ expected: [UInt8],
    accuracy: UInt8,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let close = actual.count == expected.count && zip(actual, expected).allSatisfy {
        abs(Int($0) - Int($1)) <= Int(accuracy)
    }
    XCTAssertTrue(close, "\(message): \(actual) is not \(expected)", file: file, line: line)
}
