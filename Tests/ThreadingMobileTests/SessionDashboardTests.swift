import ThreadingRemoteKit
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
