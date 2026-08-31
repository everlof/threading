import ThreadingRemoteKit
import SwiftUI
import UIKit
import XCTest
@testable import ThreadingMobile

final class SessionDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testTypeDirectionNamesAndOrdersBothKinds() {
        XCTAssertEqual(SessionTypeDirection.chatsFirst.contentTypes, [.chats, .terminals])
        XCTAssertEqual(SessionTypeDirection.terminalsFirst.contentTypes, [.terminals, .chats])
        XCTAssertEqual(SessionTypeDirection.chatsFirst.title, "Chats first")
        XCTAssertEqual(SessionTypeDirection.terminalsFirst.title, "Terminals first")
    }

    func testDashboardOrganizationIncludesProjectRecentAndType() {
        XCTAssertEqual(SessionOrganization.allCases, [.project, .recent, .type])
        XCTAssertEqual(SessionOrganization.type.title, "By type")
    }

    /// An over-height UIKit menu has no dependable scroll gesture: the drag can dismiss it and
    /// continue into a session row underneath. Every capability must therefore add content to a
    /// short submenu, never another unbounded run of root rows.
    func testDashboardMenuHasSixRootDestinationsWithEveryCapability() {
        XCTAssertEqual(
            MobileDashboardMenuDestination.available(
                canManageSessions: true,
                canManageThemes: true,
                canReadUsage: true
            ),
            [.organize, .sessions, .appearance, .usage, .settings, .macs]
        )
    }

    func testDashboardMenuOmitsOnlyCapabilityOwnedDestinations() {
        XCTAssertEqual(
            MobileDashboardMenuDestination.available(
                canManageSessions: false,
                canManageThemes: false,
                canReadUsage: false
            ),
            [.organize, .settings, .macs]
        )
    }

    func testArchivedRowsUseArchiveChronologyAndIgnoreActiveListPinning() {
        let archivedFirst = RemoteSessionSummaryDTO(
            id: "first",
            title: "Archived first",
            agentKind: "codex",
            surface: .terminal,
            state: .idle,
            projectName: "Project",
            lastActiveAt: 9_000,
            isPinned: true,
            isArchived: true,
            archivedAt: 10_000
        )
        let archivedLast = RemoteSessionSummaryDTO(
            id: "last",
            title: "Archived last",
            agentKind: "codex",
            surface: .terminal,
            state: .idle,
            projectName: "Project",
            lastActiveAt: 1_000,
            isArchived: true,
            archivedAt: 11_000
        )

        XCTAssertEqual(
            MobileSessionOrdering.sorted(
                [archivedFirst, archivedLast],
                archived: true
            ).map(\.id),
            ["last", "first"]
        )
    }

    /// The age is one narrow unit, and never a signed quantity: `RelativeDateTimeFormatter`'s
    /// abbreviated Swedish wrote yesterday as `−1 d`, which is what a duration can never do.
    func testSwedishAgeIsOneNarrowUnitWithoutAMinusSign() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "sv_SE")
        )

        // Swedish sets the unit off with a narrow no-break space; the digits and the unit are
        // the assertion, not which space stands between them.
        XCTAssertEqual(age.filter { !$0.isWhitespace }, "1d")
        XCTAssertFalse(age.contains("−"), age)
        XCTAssertFalse(age.contains("-"), age)
    }

    func testEnglishAgeIsOneNarrowUnitWithoutADirectionWord() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-6 * 60), relativeTo: now, locale: english
            ),
            "6m"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-3 * 60 * 60), relativeTo: now, locale: english
            ),
            "3h"
        )
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(-24 * 60 * 60), relativeTo: now, locale: english
            ),
            "1d"
        )
    }

    /// Past a week the age stops counting and names the day, in the reader's own calendar order.
    func testAWeekOldSessionShowsItsDate() {
        let age = MobileSessionAgeFormat.string(
            since: now.addingTimeInterval(-8 * 24 * 60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertFalse(age.contains("d"), age)
        XCTAssertTrue(age.contains("Jan"), age)
    }

    func testFutureClockSkewDoesNotProduceANegativeAge() {
        XCTAssertEqual(
            MobileSessionAgeFormat.string(
                since: now.addingTimeInterval(60 * 60),
                relativeTo: now,
                locale: Locale(identifier: "sv_SE")
            ),
            MobileL10n.string("now")
        )
    }

    func testRootNavigationTitleNamesTheConnectedMac() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: nil,
                activeHostName: "David’s MacBook Pro"
            ),
            "David’s MacBook Pro"
        )
    }

    func testProjectNavigationTitleNamesTheProject() {
        XCTAssertEqual(
            MobileDashboardChrome.title(
                projectName: "AnotherTerminal",
                activeHostName: "David’s MacBook Pro"
            ),
            "AnotherTerminal"
        )
    }

    func testConnectedNavigationStatusIncludesTheActiveRoute() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .online,
                connectionLabel: "Tailscale"
            ),
            MobileL10n.string("Connected · %@", "Tailscale")
        )
    }

    func testOfflineNavigationStatusDoesNotPutATransportErrorInTheTitleBar() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .offline(.transport("The operation timed out after 60 seconds")),
                connectionLabel: "Relay"
            ),
            MobileL10n.string("Not connected")
        )
    }

    func testAnAutomaticallyRetriedFailureSaysWhatWillHappenNext() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .offline(.transport("temporary route miss")),
                connectionLabel: "LAN",
                progress: .waitingToRetry(attempt: 1)
            ),
            MobileL10n.string("Trying again…")
        )

        let presentation = MobileConnectionProgressPresentation.resolve(
            progress: .waitingToRetry(attempt: 1)
        )
        XCTAssertEqual(presentation.currentStep.id, .connection)
        XCTAssertEqual(
            presentation.currentStep.title,
            MobileL10n.string("Connection interrupted. Trying again…")
        )
    }

    /// A single recoverable miss is network movement, not a page-sized failure. Three complete
    /// attempts are enough to say the Mac is unavailable for now and expose recovery actions.
    func testRecoverableFailureNeedsRepeatedAttemptsBeforeFullRecovery() {
        let failure = RemoteConnectionFailure.transport("temporary route miss")

        XCTAssertFalse(MobileConnectionRecoveryPolicy.presentsFullRecovery(
            for: failure,
            attempt: MobileConnectionRecoveryPolicy.settledFailureAttempt - 1
        ))
        XCTAssertTrue(MobileConnectionRecoveryPolicy.presentsFullRecovery(
            for: failure,
            attempt: MobileConnectionRecoveryPolicy.settledFailureAttempt
        ))
    }

    func testAnActionableFailureDoesNotWaitBehindAutomaticRetryChrome() {
        XCTAssertTrue(MobileConnectionRecoveryPolicy.presentsFullRecovery(
            for: .pinnedIdentityMismatch(),
            attempt: 0
        ))
    }

    func testADisclosedFailureStaysStableThroughTheNextAttemptUntilSuccess() {
        let failure = RemoteConnectionFailure.transport("repeated route miss")
        let disclosed = MobileConnectionRecoveryDisplay.updatedFailure(
            current: nil,
            phase: .offline(failure),
            attempt: MobileConnectionRecoveryPolicy.settledFailureAttempt
        )
        XCTAssertEqual(disclosed, failure)

        let whileRetrying = MobileConnectionRecoveryDisplay.updatedFailure(
            current: disclosed,
            phase: .connecting,
            attempt: MobileConnectionRecoveryPolicy.settledFailureAttempt
        )
        XCTAssertEqual(
            whileRetrying,
            failure,
            "the recovery card disappeared for the duration of one automatic retry"
        )

        XCTAssertNil(MobileConnectionRecoveryDisplay.updatedFailure(
            current: whileRetrying,
            phase: .online,
            attempt: 0
        ))
    }

    func testConnectingNavigationStatusNamesTheRouteBeingTried() {
        XCTAssertEqual(
            MobileDashboardChrome.connectionStatus(
                phase: .connecting,
                connectionLabel: nil,
                progress: .tryingRoute(
                    kind: RemoteHostEndpointKind.lan,
                    previousKind: RemoteHostEndpointKind.hosted,
                    number: 2,
                    total: 3
                )
            ),
            MobileL10n.string(
                "Trying %@",
                MobileL10n.string("LAN")
            )
        )
    }

    /// The connection card shows only the operation happening now. Route history, future work and
    /// failover instructions would turn a transient status back into a checklist.
    func testConnectionProgressShowsOnlyTheActiveNamedRoute() {
        let presentation = MobileConnectionProgressPresentation.resolve(
            progress: .tryingRoute(
                kind: RemoteHostEndpointKind.lan,
                previousKind: RemoteHostEndpointKind.hosted,
                number: 2,
                total: 3
            )
        )

        XCTAssertEqual(presentation.currentStep.id, .connection)
        XCTAssertEqual(
            presentation.currentStep.title,
            MobileL10n.string(
                "Trying %@",
                MobileL10n.string("LAN")
            )
        )
    }

    func testConnectionProgressMovesToSessionLoadingAfterTheMacAnswers() {
        let presentation = MobileConnectionProgressPresentation.resolve(
            progress: .loadingSessions(routeKind: RemoteHostEndpointKind.lan)
        )

        XCTAssertEqual(presentation.currentStep.id, .sessions)
        XCTAssertEqual(
            presentation.currentStep.title,
            MobileL10n.string("Loading sessions")
        )
    }

#if DEBUG
    func testConnectionProgressLabCoversEveryAuthoredTransportCheckpoint() {
        XCTAssertEqual(
            MobileConnectionProgressLabStory.allCases.map(\.progress),
            [
                .preparingRoutes,
                .tryingRoute(
                    kind: RemoteHostEndpointKind.hosted,
                    previousKind: nil,
                    number: 1,
                    total: 3
                ),
                .tryingRoute(
                    kind: RemoteHostEndpointKind.lan,
                    previousKind: RemoteHostEndpointKind.hosted,
                    number: 2,
                    total: 3
                ),
                .tryingRoute(
                    kind: RemoteHostEndpointKind.tailscale,
                    previousKind: RemoteHostEndpointKind.lan,
                    number: 3,
                    total: 3
                ),
                .loadingSessions(routeKind: RemoteHostEndpointKind.lan),
                .waitingToRetry(attempt: 1),
            ]
        )
        for story in MobileConnectionProgressLabStory.allCases {
            XCTAssertEqual(
                story.navigationStatus,
                MobileDashboardChrome.connectionStatus(
                    phase: .connecting,
                    connectionLabel: nil,
                    progress: story.progress
                )
            )
        }
    }
#endif

    /// A route failure must replace the indeterminate loading card with an actionable state. The
    /// useful network facts are semantic route names; the address, port and raw timeout stay in
    /// diagnostics where they cannot turn the dashboard into a network inspector.
    func testOfflineRecoveryNamesRoutesAndIdentityWithoutAnAddressOrPort() throws {
        let host = try pairedHost()
        let presentation = MobileConnectionRecoveryPresentation.resolve(
            failure: .transport(
                URLError(.timedOut),
                host: "david-mac.tailnet.example"
            ),
            host: host
        )

        XCTAssertEqual(presentation.title, MobileL10n.string("Can’t reach this Mac"))
        XCTAssertEqual(presentation.primaryRecovery, .reconnect)
        XCTAssertTrue(presentation.offersPairAgain)
        XCTAssertEqual(presentation.lastConnection, MobileL10n.string("Tailscale"))
        XCTAssertEqual(
            Set(presentation.routesTried),
            Set([MobileL10n.string("Tailscale"), MobileL10n.string("LAN")])
        )
        XCTAssertEqual(
            presentation.identityCode?.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount
        )
        let visibleNetworkText = ([presentation.lastConnection].compactMap { $0 }
            + presentation.routesTried).joined(separator: " ")
        XCTAssertFalse(visibleNetworkText.contains("8760"))
        XCTAssertFalse(visibleNetworkText.contains("192.168"))
        XCTAssertFalse(
            presentation.message.contains("timed out"),
            "Foundation's transport prose leaked into the recovery card"
        )
    }

    /// An identity refusal never becomes a one-tap trust override. The action opens the scanner,
    /// where the code is learned from the Mac's screen again, and the saved code remains visible
    /// for the comparison that should happen first.
    func testIdentityMismatchKeepsTheScanAsTheOnlyTrustRecovery() throws {
        let host = try pairedHost()
        let presentation = MobileConnectionRecoveryPresentation.resolve(
            failure: .pinnedIdentityMismatch(),
            host: host
        )

        XCTAssertEqual(
            presentation.title,
            MobileL10n.string("Check this Mac’s identity")
        )
        XCTAssertEqual(presentation.primaryRecovery, .pairAgain)
        XCTAssertFalse(presentation.offersPairAgain)
        XCTAssertEqual(presentation.identityCode, host.pinnedFingerprintCode)
    }

    // MARK: - One list, one row

    /// Chats and terminals stand on one plate in the order the arrangement asks for, each kind in
    /// its own run — the Mac sidebar's reading, where a project's terminals follow its chats and
    /// "Terminals first" turns that around. A row identity names its kind, so a chat and a
    /// terminal the Mac happened to give the same UUID would still be two rows.
    func testDashboardRowsFollowTheArrangementOrderAndKeepTheirKinds() {
        let chat = session(id: "same", title: "Licensing strategy")
        let shell = terminal(id: "same", title: "Development server", state: .idle)

        let chatsFirst = DashboardRowItem.rows(
            sessions: [chat], terminals: [shell], order: SessionTypeDirection.chatsFirst.contentTypes
        )
        XCTAssertEqual(chatsFirst, [.chat(chat), .terminal(shell)])

        let terminalsFirst = DashboardRowItem.rows(
            sessions: [chat], terminals: [shell],
            order: SessionTypeDirection.terminalsFirst.contentTypes
        )
        XCTAssertEqual(terminalsFirst, [.terminal(shell), .chat(chat)])

        XCTAssertEqual(Set(chatsFirst.map(\.id)).count, 2, "a chat and a terminal never share a row")
        XCTAssertEqual(DashboardRowItem.rows(sessions: [chat], terminals: [shell], order: [.chats]),
                       [.chat(chat)])
    }

    /// The hairline between rows starts where the text starts, for a chat and a terminal alike:
    /// the inset, the tile and the gap after it — not a literal that only matched one of them.
    func testTheRowDividerStartsWhereTheTextStarts() {
        XCTAssertEqual(
            DashboardRowMetrics.textLeadingEdge,
            MobileDesign.Spacing.medium + MobileDesign.Size.rowMark + MobileDesign.Spacing.medium
        )
    }

    /// A terminal's state is shown the way a chat's is — the laptop, the dimmed tile, the working
    /// mark — and spelled only for VoiceOver. "Ready" and "Stopped" used to sit in the trailing
    /// column where a chat shows its age.
    func testTerminalRowShowsItsStateAndSpellsItOnlyForVoiceOver() {
        let working = MobileTerminalRowPresentation.resolve(state: .working, isAvailable: true)
        XCTAssertTrue(working.isWorking)
        XCTAssertFalse(working.isDimmed)
        XCTAssertEqual(working.availabilityLabel, MobileL10n.string("Working"))

        let ready = MobileTerminalRowPresentation.resolve(state: .idle, isAvailable: true)
        XCTAssertFalse(ready.isWorking)
        XCTAssertFalse(ready.isDimmed)
        XCTAssertEqual(ready.availabilityLabel, MobileL10n.string("Ready"))

        let stopped = MobileTerminalRowPresentation.resolve(state: .dormant, isAvailable: false)
        XCTAssertFalse(stopped.isWorking)
        XCTAssertTrue(stopped.isDimmed)
        XCTAssertEqual(stopped.availabilityLabel, MobileL10n.string("Stopped"))

        // The Mac reports "working" only for a shell it is running; a stale word over a shell
        // that is not available must not animate a mark that claims "moving right now".
        let staleWorking = MobileTerminalRowPresentation.resolve(state: .working, isAvailable: false)
        XCTAssertFalse(staleWorking.isWorking)
        XCTAssertTrue(staleWorking.isDimmed)
    }

    /// The by-type headings name each kind with the symbol its direction picker uses, so the
    /// heading over a plate and the choice that put it there read as the same thing.
    func testTypeHeadingsMatchTheDirectionPickerSymbols() {
        XCTAssertEqual(DashboardContentType.chats.symbol, SessionTypeDirection.chatsFirst.symbol)
        XCTAssertEqual(
            DashboardContentType.terminals.symbol,
            SessionTypeDirection.terminalsFirst.symbol
        )
        XCTAssertEqual(DashboardContentType.terminals.symbol, MobileTerminalMark.symbolName)
        XCTAssertEqual(DashboardContentType.chats.title, MobileL10n.string("Chats"))
        XCTAssertEqual(DashboardContentType.terminals.title, MobileL10n.string("Terminals"))
    }

    private func session(id: String, title: String) -> RemoteSessionSummaryDTO {
        RemoteSessionSummaryDTO(
            id: id,
            title: title,
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            projectName: "AnotherTerminal"
        )
    }

    private func terminal(
        id: String,
        title: String,
        state: RemoteTerminalActivity
    ) -> RemoteProjectTerminalSummaryDTO {
        RemoteProjectTerminalSummaryDTO(
            id: id,
            title: title,
            projectName: "AnotherTerminal",
            state: state,
            isAvailable: state != .dormant
        )
    }

    private func pairedHost() throws -> PairedRemoteHost {
        let fingerprint = RemoteHostFingerprint(
            certificateDER: Data("dashboard recovery certificate".utf8)
        )
        let tailnet = try XCTUnwrap(URL(string: "https://david-mac.tailnet.example:8760/"))
        let local = try XCTUnwrap(URL(string: "https://192.168.1.42:8760/"))
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: tailnet,
            token: String(repeating: "a", count: 43),
            pinnedFingerprintCode: fingerprint.pairingCode
        ))
        return PairedRemoteHost(
            id: "mac-1",
            hostID: "mac-1",
            shareID: "my-devices",
            scope: "all",
            name: "David’s MacBook Pro",
            link: link,
            lastConnectedAt: Date(),
            endpoints: [
                RemoteHostEndpointDTO(kind: .tailscale, baseURL: tailnet, isStable: true),
                RemoteHostEndpointDTO(kind: .lan, baseURL: local, isStable: true),
            ],
            connectionPolicy: .privateOnly,
            activeEndpointKind: .tailscale,
            pinnedFingerprint: fingerprint.hex
        )
    }
}

#if DEBUG
/// The demo router that decides which screen `THREADING_MOBILE_DEMO` opens.
///
/// This is the surface iOS appearance is reviewed from: `scripts/ui-evidence-ios.sh` launches the
/// shipping app once per capture with one id in the environment. An id nothing matches renders
/// the real app, which photographs cleanly and passes review while showing the wrong screen — so
/// the mapping is worth spelling out rather than reading back from the code that performs it.
final class MobileDemoSceneTests: XCTestCase {
    func testMarketingProviderFixturesAreBundledPrivatePTYRecordings() throws {
        for provider in MobileMarketingTerminalFixture.Provider.allCases {
            let fixture = try MobileMarketingTerminalFixture.load(provider)
            XCTAssertEqual(fixture.provider, provider.rawValue)
            XCTAssertEqual(fixture.columns, 62)
            XCTAssertEqual(fixture.rows, provider == .claude ? 49 : 55)
            XCTAssertGreaterThan(fixture.payload.count, 1_500)
            XCTAssertFalse(fixture.payload.isEmpty)
            XCTAssertTrue(fixture.payload.contains(0x1B))
            let transcriptMarker = provider == .claude ? "Completed:" : "Validation"
            XCTAssertTrue(fixture.payload.contains(Data(transcriptMarker.utf8)))
            if provider == .claude {
                XCTAssertTrue(fixture.payload.contains(Data("capture-plan.md".utf8)))
                XCTAssertTrue(fixture.payload.contains(Data("Added".utf8)))
                XCTAssertTrue(fixture.payload.contains(Data("removed".utf8)))
                XCTAssertTrue(fixture.payload.contains(Data("\u{1B}[31m".utf8)))
                XCTAssertTrue(fixture.payload.contains(Data("\u{1B}[32m".utf8)))
            } else {
                XCTAssertTrue(fixture.payload.contains(Data("Edited".utf8)))
                XCTAssertTrue(fixture.payload.contains(Data("capture-notes.md".utf8)))
                XCTAssertTrue(
                    fixture.payload.contains(Data("\u{1B}[38;2;".utf8)),
                    "the installed Codex renderer must contribute its real syntax palette"
                )
            }
            XCTAssertFalse(fixture.payload.contains(Data("authentication rejected".utf8)))
            XCTAssertFalse(fixture.payload.contains(Data("MCP client".utf8)))
            XCTAssertFalse(fixture.payload.contains(Data("/Users/".utf8)))
            XCTAssertFalse(fixture.payload.contains(Data("/home/".utf8)))
        }
        XCTAssertEqual(
            MobileMarketingTerminalFixture.provider(
                marketingSessionID: "marketing-claude-session"
            ),
            .claude
        )
        XCTAssertEqual(
            MobileMarketingTerminalFixture.provider(
                marketingSessionID: "marketing-codex-session"
            ),
            .codex
        )
        XCTAssertNil(
            MobileMarketingTerminalFixture.provider(marketingSessionID: "ordinary-session")
        )
    }

    @MainActor
    func testMarketingSessionNavigationReplaysTheReviewedPTYFixtureThroughTheDemoWire() throws {
        let session = try XCTUnwrap(RemoteAppModel.marketingResponse.sessions.first {
            $0.id == "marketing-claude-session"
        })
        let expected = try MobileMarketingTerminalFixture.load(.claude)
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: DemoExperience.link)
        )
        var received = Data()
        connection.onTerminalOutput = { received.append($0) }

        connection.connect()
        defer { connection.disconnect(markEnded: false) }

        XCTAssertEqual(connection.phase, .connected)
        XCTAssertEqual(
            Data(received.suffix(expected.payload.count)),
            expected.payload,
            "the connection's ordinary terminal reset may precede the reviewed replay"
        )
        XCTAssertTrue(connection.supportsFocusedInputControl)
        XCTAssertEqual(connection.runPlan?.activeTitle, "Render theme variants")
        XCTAssertEqual(connection.runPlanSteps.map(\.title), [
            "Build deterministic provider fixtures",
            "Capture five marketing checkpoints",
            "Render theme variants",
        ])
    }

    @MainActor
    func testMarketingStoryHasOneProjectFourMixedChatsAndNoStandaloneTerminal() throws {
        let response = RemoteAppModel.marketingResponse
        XCTAssertEqual(response.newSessionCatalog?.projects.map(\.name), ["Threading"])
        XCTAssertEqual(response.sessions.count, 4)
        XCTAssertEqual(response.terminals, [])
        XCTAssertEqual(Set(response.sessions.map(\.agentKind)), ["claude", "codex"])
        XCTAssertEqual(Set(response.sessions.compactMap(\.accountID)), [
            "codex-work", "default", "keller",
        ])
        XCTAssertEqual(Set(response.sessions.map(\.state)), [
            .dormant, .idle, .needsAttention, .working,
        ])

        let codexTerminal = try XCTUnwrap(response.sessions.first {
            $0.id == "marketing-codex-session"
        })
        XCTAssertEqual(codexTerminal.accountID, "default")
        XCTAssertNil(
            codexTerminal.account,
            "the standard Codex login should not add an account chip to its agent mark"
        )
    }

    @MainActor
    func testMarketingTerminalPaletteMatchesEverySelectedAppTheme() {
        for appTheme in RemoteAppModel.demoCatalogThemes {
            let terminal = RemoteAppModel.demoMarketingTerminalTheme(matching: appTheme)

            XCTAssertEqual(terminal.id, "marketing-\(appTheme.id)-terminal")
            XCTAssertEqual(terminal.background, appTheme.colors["ground"])
            XCTAssertEqual(terminal.foreground, appTheme.colors["label"])
            XCTAssertEqual(terminal.cursor, appTheme.colors["accent"])
            XCTAssertEqual(terminal.selection, appTheme.colors["selection"])
            XCTAssertEqual(terminal.ansi.count, 16)
        }
    }

    @MainActor
    func testRunPlanFixtureBuildsTheStructuredPlanItPhotographs() {
        let key = MobileDemoScene.environmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, MobileDemoFixture.conversationRunPlan.rawValue, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }

        let connection = RemoteSessionConnection.demoConversation()

        XCTAssertEqual(connection.runPlan?.activeTitle, "Polish the phone checklist disclosure")
        XCTAssertEqual(connection.runPlanSteps.count, 5)

        let host = UIHostingController(rootView: MobileRunPlanDisclosure(connection: connection))
        let size = host.sizeThatFits(in: CGSize(width: 440, height: 956))
        XCTAssertGreaterThan(size.height, 0)
    }

    /// Every catalogue id, and the scene it names, written as literals.
    ///
    /// The `switch` is exhaustive so a new fixture id cannot be added without a line here, and
    /// the ids are literals so a rename of a case is a failure rather than a silent agreement.
    func testEveryCatalogueIDResolvesToTheSceneItNames() {
        for fixture in MobileDemoFixture.allCases {
            let expected: (id: String, scene: MobileDemoScene)
            switch fixture {
            case .terminalANSI: expected = ("terminal-ansi", .terminal)
            case .terminalAttachments: expected = ("terminal-attachments", .terminal)
            case .terminalBrowserActivity:
                expected = ("terminal-browser-activity", .terminal)
            case .terminalClaudeTUI: expected = ("terminal-claude-tui", .terminal)
            case .terminalCodexTUI: expected = ("terminal-codex-tui", .terminal)
            case .terminalCollaboration: expected = ("terminal-collaboration", .terminal)
            case .terminalCompose: expected = ("terminal-compose", .terminal)
            case .terminalScrollback: expected = ("terminal-scrollback", .terminal)
            case .terminalSelection: expected = ("terminal-selection", .terminal)
            case .marketingSessions: expected = ("marketing-sessions", .shippingRoot)
            case .marketingClaudeTUI: expected = ("marketing-claude-tui", .terminal)
            case .marketingCodexTUI: expected = ("marketing-codex-tui", .terminal)
            case .marketingClaudeUsageMenu:
                expected = ("marketing-claude-usage-menu", .terminal)
            case .marketingSettings: expected = ("marketing-settings", .settings)
            case .conversation: expected = ("conversation", .conversation)
            case .conversationAttachments: expected = ("conversation-attachments", .conversation)
            case .conversationAwayFromLatest:
                expected = ("conversation-away-from-latest", .conversation)
            case .conversationColdStress: expected = ("conversation-cold-stress", .conversation)
            case .conversationCollaboration:
                expected = ("conversation-collaboration", .conversation)
            case .conversationContentTypes: expected = ("conversation-content-types", .conversation)
            case .conversationKeyboard: expected = ("conversation-keyboard", .conversation)
            case .conversationReconnectStress:
                expected = ("conversation-reconnect-stress", .conversation)
            case .conversationRichContent: expected = ("conversation-rich-content", .conversation)
            case .conversationRunPlan: expected = ("conversation-run-plan", .conversation)
            case .conversationRunPlanExpanded:
                expected = ("conversation-run-plan-expanded", .conversation)
            case .conversationScrollStress: expected = ("conversation-scroll-stress", .conversation)
            case .conversationStreaming: expected = ("conversation-streaming", .conversation)
            case .conversationToolExpanded: expected = ("conversation-tool-expanded", .conversation)
            case .attentionRequest: expected = ("attention-request", .attentionRequest)
            case .pairing: expected = ("pairing", .pairing)
            case .welcome: expected = ("welcome", .welcome)
            case .welcomeBrowser: expected = ("welcome-browser", .welcome)
            case .welcomeUsage: expected = ("welcome-usage", .welcome)
            case .settings: expected = ("settings", .settings)
            case .appIconSettings: expected = ("app-icon-settings", .appIconSettings)
            case .collaborationSettings:
                expected = ("collaboration-settings", .collaborationSettings)
            case .advancedConnectionSettings:
                expected = ("advanced-connection-settings", .advancedConnectionSettings)
            case .localDiagnosticsSettings:
                expected = ("local-diagnostics-settings", .localDiagnosticsSettings)
            case .notificationSettings: expected = ("notification-settings", .notificationSettings)
            case .macAppearanceSettings:
                expected = ("mac-appearance-settings", .macAppearanceSettings)
            case .connectionProgressLab:
                expected = ("connection-progress-lab", .connectionProgressLab)
            case .connectionStatus: expected = ("connection-status", .connectionStatus)
            case .diagnostics: expected = ("diagnostics", .diagnostics)
            case .terminalKeySettings: expected = ("terminal-key-settings", .terminalKeySettings)
            case .terminalKeyEditor: expected = ("terminal-key-editor", .terminalKeyEditor)
            case .terminalKeyCatalog: expected = ("terminal-key-catalog", .terminalKeyCatalog)
            case .terminalKeySnippet: expected = ("terminal-key-snippet", .terminalKeySnippet)
            case .terminalKeyEdit: expected = ("terminal-key-edit", .terminalKeyEdit)
            case .sharedLink: expected = ("shared-link", .sharedLink)
            case .shareChatRoles: expected = ("share-chat-roles", .shareChatRoles)
            case .shareChatBlocked: expected = ("share-chat-blocked", .shareChatBlocked)
            case .shareChatLink: expected = ("share-chat-link", .shareChatLink)
            case .sessionSettings: expected = ("session-settings", .sessionSettings)
            case .permission: expected = ("permission", .permission)
            case .permissionLong: expected = ("permission-long", .permission)
            case .newSession: expected = ("new-session", .newSession)
            case .newSessionDraftMatrix:
                expected = ("new-session-draft-matrix", .newSession)
            case .newSessionModelEffortPicker:
                expected = ("new-session-model-effort-picker", .newSession)
            case .newSessionMultiline: expected = ("new-session-multiline", .newSession)
            case .newSessionSingleCharacter:
                expected = ("new-session-single-character", .newSession)
            case .newSessionScrollOverflow:
                expected = ("new-session-scroll-overflow", .newSession)
            case .newSessionStructuredError:
                expected = ("new-session-structured-error", .newSession)
            case .themedDialogAlert: expected = ("themed-dialog-alert", .themedDialogAlert)
            case .themedDialogConfirmation:
                expected = ("themed-dialog-confirmation", .themedDialogConfirmation)
            case .review: expected = ("review", .review(showsAllFiles: false))
            case .reviewFiles: expected = ("review-files", .review(showsAllFiles: true))
            case .reviewFilesMassive:
                expected = ("review-files-massive", .review(showsAllFiles: true))
            case .sessionOpeningConnecting:
                expected = ("session-opening-connecting", .sessionOpening(.connecting))
            case .sessionOpeningResuming:
                expected = ("session-opening-resuming", .sessionOpening(.resuming))
            case .sessionOpeningFailed:
                expected = ("session-opening-failed", .sessionOpening(.failed))
            case .workspace: expected = ("workspace", .workspace)
            case .browserPrivate: expected = ("browser-private", .browserPrivate)
            case .attachments: expected = ("attachments", .attachments)
            case .universalSearch: expected = ("universal-search", .universalSearch)
            case .attachmentDetailHTML:
                expected = ("attachment-detail-html", .attachmentDetail(kind: .html))
            case .attachmentDetailImage:
                expected = ("attachment-detail-image", .attachmentDetail(kind: .image))
            case .attachmentDetailPDF:
                expected = ("attachment-detail-pdf", .attachmentDetail(kind: .pdf))
            case .attachmentDetailText:
                expected = ("attachment-detail-text", .attachmentDetail(kind: .text))
            case .usage: expected = ("usage", .shippingRoot)
            case .usageLimit: expected = ("usage-limit", .shippingRoot)
            case .usageLimitUnavailable: expected = ("usage-limit-unavailable", .shippingRoot)
            case .usageLimitZero: expected = ("usage-limit-zero", .shippingRoot)
            case .usageStale: expected = ("usage-stale", .shippingRoot)
            case .sessions: expected = ("sessions", .shippingRoot)
            case .sessionsConnecting: expected = ("sessions-connecting", .shippingRoot)
            case .sessionsOffline: expected = ("sessions-offline", .shippingRoot)
            case .projectSessions: expected = ("project-sessions", .shippingRoot)
            case .report: expected = ("report", .shippingRoot)
            case .reportScreenshot: expected = ("report-screenshot", .shippingRoot)
            }

            XCTAssertEqual(fixture.rawValue, expected.id)
            XCTAssertEqual(MobileDemoScene.resolve(expected.id), expected.scene, expected.id)
            XCTAssertEqual(fixture.scene, expected.scene, expected.id)
        }
    }

    /// An unset variable and an id nobody named both reach the shipping root, which is exactly
    /// why a mistyped fixture is invisible in a screenshot. The catalogue is what can tell them
    /// apart, so it must refuse what the router accepts.
    func testAnUnknownIDIsIndistinguishableFromNoDemoAtTheRootButNotInTheCatalogue() {
        XCTAssertEqual(MobileDemoScene.resolve(nil), .shippingRoot)
        XCTAssertEqual(MobileDemoScene.resolve(""), .shippingRoot)
        XCTAssertEqual(MobileDemoScene.resolve("pairring"), .shippingRoot)
        XCTAssertEqual(MobileDemoScene.resolve("terminal-key"), .shippingRoot)

        XCTAssertNil(MobileDemoFixture(rawValue: "pairring"))
        XCTAssertNil(MobileDemoFixture(rawValue: "terminal-key"))
        XCTAssertEqual(MobileDemoFixture(rawValue: "pairing"), .pairing)
    }

    /// The prefix families are parameterised ids, not aliases: the router still routes a member
    /// the catalogue has never heard of, and the part after the prefix survives.
    func testPrefixFamiliesStillRouteIDsTheCatalogueDoesNotList() {
        XCTAssertEqual(MobileDemoScene.resolve("conversation-something-new"), .conversation)
        XCTAssertEqual(MobileDemoScene.resolve("welcome-terminal"), .welcome)
        XCTAssertEqual(MobileDemoScene.resolve("permission-short"), .permission)
        XCTAssertEqual(MobileDemoScene.resolve("new-session-anything"), .newSession)
        XCTAssertEqual(
            MobileDemoScene.resolve("review-massive"),
            .review(showsAllFiles: false)
        )
        XCTAssertEqual(
            MobileDemoScene.resolve("attachment-detail-archive"),
            .attachmentDetail(kind: .archive)
        )
        // An unknown suffix is a `RemoteAttachmentKind.unknown`, not a refusal.
        XCTAssertEqual(
            MobileDemoScene.resolve("attachment-detail-sketch"),
            .attachmentDetail(kind: .unknown("sketch"))
        )
    }

    /// Every id that shares the mirrored terminal screen, spelled out.
    func testTheTerminalFamilyContainsOnlyTerminalScreens() {
        XCTAssertEqual(MobileDemoScene.terminalFixtureIDs, [
            "marketing-claude-tui",
            "marketing-claude-usage-menu",
            "marketing-codex-tui",
            "terminal-ansi",
            "terminal-attachments",
            "terminal-browser-activity",
            "terminal-claude-tui",
            "terminal-codex-tui",
            "terminal-collaboration",
            "terminal-compose",
            "terminal-scrollback",
            "terminal-selection",
        ])
        // `terminal-key-*` sits beside them and must not be swallowed by the family.
        XCTAssertEqual(MobileDemoScene.resolve("terminal-key-editor"), .terminalKeyEditor)
    }

    func testRecordedProviderPTYsKeepTheirCapturedGridWhileUsingInteractiveChrome() {
        XCTAssertEqual(MobileDemoScene.recordedPTYFixtureIDs, [
            "marketing-claude-tui",
            "marketing-claude-usage-menu",
            "marketing-codex-tui",
        ])
        XCTAssertFalse(TerminalViewRepresentable.usesLocalViewport(
            capability: .interact,
            replaysRecordedGrid: true
        ))
        XCTAssertTrue(TerminalViewRepresentable.usesLocalViewport(
            capability: .interact,
            replaysRecordedGrid: false
        ))
        XCTAssertFalse(TerminalViewRepresentable.usesLocalViewport(
            capability: .view,
            replaysRecordedGrid: false
        ))
    }

    /// The variable is spelled once, and every reader in the app goes through it.
    func testTheEnvironmentVariableIsSpelledOnce() {
        XCTAssertEqual(MobileDemoScene.environmentKey, "THREADING_MOBILE_DEMO")
    }
}
#endif
