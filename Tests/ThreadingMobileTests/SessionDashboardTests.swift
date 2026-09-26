import Combine
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

    @MainActor
    func testDashboardMountsOnlyAViewportOfAThousandRows() {
        let metrics = MobileDashboardCollectionPerformanceProbe.exercise(rowCount: 1_000)

        XCTAssertEqual(metrics.snapshotItemCount, 1_000)
        XCTAssertGreaterThan(metrics.mountedCellCount, 0)
        XCTAssertLessThan(metrics.mountedCellCount, 40)
        XCTAssertEqual(metrics.mountedNativeRowCount, metrics.mountedCellCount)
        XCTAssertEqual(metrics.hostedContentCount, 0)
    }

    @MainActor
    func testDashboardUpdatesWorkingStatusInTheSamePublicationAsRowMoves() {
        // Expected: idle, working beside a move, settled during a move, working without a
        // move, cached (unknown), then live again, followed by prepared cells stopping/starting
        // at display. No timer or second model update intervenes.
        for rowCount in [20, 1_000] {
            XCTAssertEqual(
                MobileDashboardWorkingStatusProbe.exercise(rowCount: rowCount),
                [false, true, false, true, false, true, false, true],
                "Catalogue with \(rowCount) rows"
            )
        }
    }

    /// A catalogue update that drops a whole group used to kill the app: the layout installed
    /// for the shorter list was resolved against the snapshot still holding the longer one, and
    /// a compositional layout treats a nil section as an assertion failure rather than an empty
    /// one. Reaching the assertion is the crash, so this test aborting is the regression.
    @MainActor
    func testADashboardThatLosesSectionsKeepsTheOnesThatRemain() {
        XCTAssertEqual(
            MobileDashboardCollectionPerformanceProbe.exerciseSectionRemoval(
                initialSections: 4,
                remainingSections: 1
            ),
            1
        )
        XCTAssertEqual(
            MobileDashboardCollectionPerformanceProbe.exerciseSectionRemoval(
                initialSections: 3,
                remainingSections: 0
            ),
            0
        )
    }

    /// A dashboard cell keeps its LabelMorph view as it leaves and re-enters the viewport. The
    /// recycled view may carry another chat's title, but that reassignment is not a rename and
    /// must not produce the scrambled transition visible while scrolling the session list.
    @MainActor
    func testDashboardAnimatesOnlyARenameOfTheSameVisibleRecord() {
        let metrics = MobileDashboardTitleReuseProbe.exercise()

        XCTAssertFalse(metrics.initialPresentationAnimated)
        XCTAssertTrue(metrics.sameRecordRenameAnimated)
        XCTAssertFalse(metrics.recycledPresentationAnimated)
        XCTAssertEqual(metrics.recycledTitle, "Second title")
    }

    /// The native-cell migration kept computing the full-swipe threshold and firing its haptic,
    /// but dropped the visual armed state. The action therefore looked frozen while the finger
    /// crossed the exact distance that changed what releasing would do.
    @MainActor
    func testDashboardSwipeVisiblyAnswersEachArmingEdge() {
        let metrics = MobileDashboardSwipeArmProbe.exercise()

        XCTAssertTrue(metrics.restingUsesControlPlate)
        XCTAssertTrue(metrics.armedUsesAccentPlate)
        XCTAssertTrue(metrics.disarmedUsesControlPlate)
        XCTAssertEqual(metrics.firstArmMotionCount, 1)
        XCTAssertEqual(metrics.disarmMotionCount, 1)
        XCTAssertEqual(metrics.secondArmMotionCount, 2)
        XCTAssertTrue(metrics.reducedMotionUsesAccentPlate)
        XCTAssertEqual(metrics.reducedMotionArmMotionCount, 0)
        XCTAssertTrue(metrics.armedShowsReleaseInstruction)
        XCTAssertTrue(metrics.retreatRestoresActionTitle)
        XCTAssertTrue(metrics.reducedMotionShowsReleaseInstruction)
    }

    @MainActor
    func testSwipeSurvivesLayoutAndLiveUpdatesThenCancelsAndReusesCleanly() {
        XCTAssertEqual(
            MobileDashboardSwipeLifecycleProbe.exercise(),
            [-110, -110, -110, -110, 110, -130, 0, 0, 0]
        )
    }

    func testDashboardRowHeightFollowsAccessibilityContentSize() {
        let standard = DashboardRowMetrics.height(
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large),
            dividerWidth: 1
        )
        let accessibility = DashboardRowMetrics.height(
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: .accessibilityLarge
            ),
            dividerWidth: 1
        )

        XCTAssertGreaterThanOrEqual(standard, MobileDesign.Size.minimumTapTarget)
        XCTAssertGreaterThan(accessibility, standard)
    }

    @MainActor
    func testAnIdenticalRefreshCatalogueIsNotPublishedAgain() throws {
        let model = RemoteAppModel()
        model.startDemo()
        let response = try XCTUnwrap(model.me)
        var publications = 0
        let subscription = model.$me.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        XCTAssertFalse(model.adoptRefreshedCatalogueIfChanged(response))
        XCTAssertEqual(publications, 0)

        XCTAssertTrue(model.adoptRefreshedCatalogueIfChanged(
            response.replacing(theme: RemoteAppModel.demoLightTheme)
        ))
        XCTAssertEqual(publications, 1)
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

    func testCachedNavigationStatusNamesItsAgeWhileReconnectContinues() {
        let status = MobileDashboardChrome.connectionStatus(
            phase: .connecting,
            connectionLabel: nil,
            progress: .preparingRoutes,
            cachedAt: now.addingTimeInterval(-7 * 60),
            now: now
        )

        XCTAssertTrue(status.contains(MobileL10n.string("Checking saved connections")), status)
        XCTAssertTrue(status.contains("Updated"), status)
        XCTAssertTrue(status.contains("7"), status)
    }

    func testCachedNavigationAgeClampsFutureClockSkewToNow() {
        let age = MobileDashboardCacheAgeFormat.string(
            capturedAt: now.addingTimeInterval(60 * 60),
            relativeTo: now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(age.localizedCaseInsensitiveContains("now"), age)
        XCTAssertFalse(age.localizedCaseInsensitiveContains("in "), age)
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
        XCTAssertTrue(working.showsAvailability)
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

        let cached = MobileTerminalRowPresentation.resolve(
            state: .working,
            isAvailable: true,
            isCatalogueLive: false
        )
        XCTAssertFalse(cached.isWorking)
        XCTAssertFalse(cached.isDimmed)
        XCTAssertFalse(cached.showsAvailability)
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

    // MARK: - Project section ordering

    private func key(
        _ title: String,
        id: String? = nil,
        repository: RemoteRepositoryDTO? = nil
    ) -> MobileProjectSectionOrdering.Key {
        MobileProjectSectionOrdering.Key(
            id: id ?? "id:\(title)",
            title: title,
            repository: repository
        )
    }

    /// The bug this ordering exists for: a worktree is named after its directory, so once the
    /// project it grew from has been renamed the two sort nowhere near each other. The Mac never
    /// showed it, because its sidebar puts every checkout under the repository's own row.
    func testAWorktreeSectionFollowsTheCheckoutItGrewFrom() {
        let repository = RemoteRepositoryDTO(id: "repo-1", name: "Threading", isMainCheckout: true)
        let worktree = RemoteRepositoryDTO(id: "repo-1", name: "Threading", isMainCheckout: false)
        let sections = [
            key("AnotherTerminal-experiment-jev", repository: worktree),
            key("autokor"),
            key("Threading", repository: repository),
            key("app-mono"),
            key("AnotherTerminal-linux-appkit", repository: worktree),
        ]

        let ordered = MobileProjectSectionOrdering.sorted(sections) { $0 }.map(\.title)

        XCTAssertEqual(ordered, [
            "app-mono",
            "autokor",
            "Threading",
            "AnotherTerminal-experiment-jev",
            "AnotherTerminal-linux-appkit",
        ])
    }

    /// A Mac too old to describe its repositories still sends its projects, and they are still
    /// ordered — by name, exactly as before.
    func testProjectsWithoutARepositoryKeepAlphabeticalOrder() {
        let sections = [key("Threading"), key("app-mono"), key("AnotherTerminal-experiment-jev")]

        let ordered = MobileProjectSectionOrdering.sorted(sections) { $0 }.map(\.title)

        XCTAssertEqual(ordered, ["AnotherTerminal-experiment-jev", "app-mono", "Threading"])
    }

    /// Two repositories can be called the same thing, and a folder outside any repository can be
    /// called what a repository is called. Which group goes first matters less than each group
    /// staying in one piece.
    func testGroupsSharingANameStayContiguous() {
        let left = RemoteRepositoryDTO(id: "repo-a", name: "Tools", isMainCheckout: false)
        let right = RemoteRepositoryDTO(id: "repo-b", name: "Tools", isMainCheckout: false)
        let sections = [
            key("a-one", repository: left),
            key("b-one", repository: right),
            key("a-two", repository: left),
            key("b-two", repository: right),
        ]

        let ordered = MobileProjectSectionOrdering.sorted(sections) { $0 }.map(\.title)

        XCTAssertEqual(ordered, ["a-one", "a-two", "b-one", "b-two"])
    }

    /// Swift's sort is not stable, so two checkouts standing on the same name must still have a
    /// fixed order — otherwise they swap places on every publication.
    func testCheckoutsSharingATitleKeepAFixedOrder() {
        let repository = RemoteRepositoryDTO(id: "repo-1", name: "Threading", isMainCheckout: false)
        let sections = [
            key("master", id: "id:second", repository: repository),
            key("master", id: "id:first", repository: repository),
        ]

        XCTAssertEqual(
            MobileProjectSectionOrdering.sorted(sections) { $0 }.map(\.id),
            ["id:first", "id:second"]
        )
        XCTAssertEqual(
            MobileProjectSectionOrdering.sorted(sections.reversed()) { $0 }.map(\.id),
            ["id:first", "id:second"]
        )
    }

}

/// The row a long press lifts out of the dashboard, hosted the way UIKit hosts a context-menu
/// preview: in a hosting controller of its own, with none of the list's environment.
///
/// Reported from a screenshot on Swiss Minimalist: the lifted row drew its title in a colour a
/// shade off the white panel, and stood as a pill under a theme whose every panel is square with
/// a two-point border. The first was the preview's nested views answering `\.remoteTheme` with
/// the built-in fallback — a dark palette, whose label is #F3F4F6 — because a context-menu
/// preview is a presentation boundary like a sheet and inherits nothing. The second was UIKit's
/// own platter radius, which the preview has to be told about through `contextMenuPreview`.
/// Both are read off pixels here, since both passed every assertion anyone had written.
@MainActor
final class MobileLiftedSessionRowTests: XCTestCase {
    func testNativeHighlightAndDismissalCarryTheBorderForEveryRowPosition() throws {
        for radius in [0.0, 20.0] {
            for index in 0..<3 {
                let images = MobileDashboardHighlightProbe.capture(
                    theme: RemoteThemePalette(theme(radius: radius, borderWidth: 4)), rowIndex: index
                )
                XCTAssertEqual(images.count, 2)
                for image in images {
                    for point in [CGPoint(x: image.size.width / 2, y: 0),
                                  CGPoint(x: 0, y: image.size.height / 2),
                                  CGPoint(x: image.size.width - 1, y: image.size.height / 2),
                                  CGPoint(x: image.size.width / 2, y: image.size.height - 1)] {
                        let ink = try rgb(at: point, in: image)
                        XCTAssertLessThan(ink.red, 0.2, "Missing native preview border: \(point)")
                        XCTAssertLessThan(ink.green, 0.2)
                        XCTAssertLessThan(ink.blue, 0.2)
                        XCTAssertGreaterThan(ink.alpha, 0.8)
                    }
                    let corner = try rgb(at: CGPoint(x: 1, y: 0), in: image)
                    if radius == 0 {
                        XCTAssertLessThan(corner.red, 0.2)
                    } else {
                        XCTAssertLessThan(corner.alpha, 0.2)
                    }
                    // The row's title survives lifting alongside its plate.
                    XCTAssertLessThan(try darkestLuminance(
                        in: CGRect(x: 54, y: 10, width: 130, height: 20), of: image
                    ), 0.4)
                }
            }
        }
    }

    private enum Fixture {
        static let width: CGFloat = 362
        static let label = "#111111"
        static let panel = "#FFFFFF"
        static let border = "#000000"
        static let borderWidth = 2.0
        /// Where the platter shows through if the row does not cover its own corner.
        static let backdrop = UIColor.red
    }

    func testTheLiftedRowDrawsItsTitleInTheThemeLabelWithoutTheListEnvironment() throws {
        let fixture = try hosted(theme: theme(radius: 0))
        let title = try XCTUnwrap(
            first(MobileMorphingTitleLabel.self, in: fixture.window),
            "the lifted row draws its title with the same morphing label as the list"
        )
        let titleFrame = title.convert(title.bounds, to: fixture.window)
        let darkest = try darkestLuminance(in: titleFrame, of: fixture.image)

        XCTAssertLessThan(
            darkest,
            0.4,
            "the title is drawn in the theme's label (\(Fixture.label)), not the fallback " +
                "palette's near-white; darkest ink measured \(darkest)"
        )
    }

    /// Sampled on the top row, one pixel in: the two-point stroke is centred on the edge and
    /// clipped to it, so the border is that one row, and a square theme lifts with the one-point
    /// radius the platter needs to honour a shape at all, whose arc grazes the very corner.
    func testASquareThemeLiftsASquareBorderedRow() throws {
        let fixture = try hosted(theme: theme(radius: 0))
        let corner = try rgb(at: CGPoint(x: 1, y: 0), in: fixture.image)

        XCTAssertLessThan(
            corner.red,
            0.2,
            "a square theme's lifted row reaches its own corner with the border, not the platter"
        )
        XCTAssertLessThan(corner.green, 0.2)
        XCTAssertLessThan(corner.blue, 0.2)
    }

    func testARoundedThemeLiftsARoundedRow() throws {
        let fixture = try hosted(theme: theme(radius: 20))
        let corner = try rgb(at: CGPoint(x: 1, y: 0), in: fixture.image)
        let pastTheArc = try rgb(at: CGPoint(x: 20, y: 0), in: fixture.image)

        XCTAssertGreaterThan(
            corner.red,
            0.8,
            "a rounded theme leaves its corner to the platter"
        )
        XCTAssertLessThan(corner.green, 0.2)
        XCTAssertLessThan(
            pastTheArc.red,
            0.2,
            "past the arc the top edge is the border again"
        )
    }

    // MARK: - Fixture

    private struct Hosted {
        let window: UIWindow
        let image: UIImage
    }

    /// The lifted row in a hosting controller with nothing above it — no `mobileTheme`, no
    /// environment — pinned to the window's top-left corner so a pixel's address is the row's.
    private func hosted(theme: RemoteThemeDTO) throws -> Hosted {
        let session = RemoteSessionSummaryDTO(
            id: "macos",
            title: "MACOS",
            agentKind: "claude",
            surface: .terminal,
            state: .idle,
            projectName: "AnotherTerminal",
            isAvailable: false,
            lastActiveAt: Date().addingTimeInterval(-86_400).timeIntervalSince1970
        )
        let root = UIHostingController(
            rootView: MobileLiftedSessionRow(
                session: session,
                width: Fixture.width,
                theme: RemoteThemePalette(theme)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
        )
        root.view.backgroundColor = .clear
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.backgroundColor = Fixture.backdrop
        window.rootViewController = root
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "lifted-row-radius-\(Int(theme.material.panelRadius))"
        attachment.lifetime = .keepAlways
        add(attachment)
        return Hosted(window: window, image: image)
    }

    private func theme(radius: Double, borderWidth: Double = Fixture.borderWidth) -> RemoteThemeDTO {
        RemoteThemeDTO(
            id: "lifted-row-test-\(Int(radius))",
            name: "Lifted row test",
            mode: .light,
            colors: [
                "ground": Fixture.panel,
                "surface": "#F2F2F2",
                "panel": Fixture.panel,
                "elevated": Fixture.panel,
                "border": Fixture.border,
                "divider": Fixture.border,
                "label": Fixture.label,
                "secondary_label": "#666666",
                "tertiary_label": "#999999",
                "accent": "#FF3000",
            ],
            material: RemoteThemeDTO.Material(
                panelRadius: radius,
                controlRadius: radius / 2,
                borderWidth: borderWidth
            )
        )
    }

    private func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews {
            if let found = first(type, in: child) { return found }
        }
        return nil
    }

    // MARK: - Pixels

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    private func rgb(at point: CGPoint, in image: UIImage) throws -> RGB {
        let pixels = try pixels(of: image)
        return pixels.rgb(x: Int(point.x), y: Int(point.y))
    }

    private func darkestLuminance(in rect: CGRect, of image: UIImage) throws -> CGFloat {
        let pixels = try pixels(of: image)
        var darkest: CGFloat = 1
        for y in Int(rect.minY)..<Int(rect.maxY.rounded(.up)) {
            for x in Int(rect.minX)..<Int(rect.maxX.rounded(.up)) {
                darkest = min(darkest, pixels.rgb(x: x, y: y).luminance)
            }
        }
        return darkest
    }

    private struct Pixels {
        let width: Int
        let bytes: [UInt8]

        func rgb(x: Int, y: Int) -> RGB {
            let offset = (y * width + x) * 4
            return RGB(
                red: CGFloat(bytes[offset]) / 255,
                green: CGFloat(bytes[offset + 1]) / 255,
                blue: CGFloat(bytes[offset + 2]) / 255,
                alpha: CGFloat(bytes[offset + 3]) / 255
            )
        }
    }

    /// The image as one RGBA buffer at one byte per channel, whatever the source encoding.
    private func pixels(of image: UIImage) throws -> Pixels {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, bytes: bytes)
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
    @MainActor
    func testMarketingProviderFixturesAreBundledPrivatePTYRecordings() throws {
        for provider in MobileMarketingTerminalFixture.Provider.allCases {
            for mode in MobileMarketingTerminalFixture.TerminalMode.allCases {
                let fixture = try MobileMarketingTerminalFixture.load(provider, mode: mode)
                XCTAssertEqual(fixture.provider, provider.rawValue)
                // Each mode is its own recording against a terminal reporting that background, so a
                // light app theme replays the providers' light palettes rather than dark blocks.
                XCTAssertEqual(fixture.terminalMode, mode.rawValue)
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
                    XCTAssertTrue(
                        fixture.payload.contains(Data("\u{1B}[91m".utf8)),
                        "the installed Claude renderer must retain removed-line syntax color"
                    )
                    XCTAssertTrue(
                        fixture.payload.contains(Data("\u{1B}[92m".utf8)),
                        "the installed Claude renderer must retain added-line syntax color"
                    )
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
        }
        XCTAssertEqual(
            MobileMarketingTerminalFixture.TerminalMode.matching(RemoteAppModel.demoThreadingTheme),
            .dark
        )
        XCTAssertEqual(
            MobileMarketingTerminalFixture.TerminalMode.matching(RemoteAppModel.demoLightTheme),
            .light
        )
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
    func testMarketingSessionNavigationReplaysTheReviewedPTYFixtureThroughTheDemoWire() async throws {
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

        let replayArrived = await Self.eventually {
            connection.phase == .connected
                && received.count >= expected.payload.count
                && connection.runPlanSteps.count == 3
        }
        XCTAssertTrue(replayArrived)
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
            "Capture six marketing checkpoints",
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
    func testMarketingResponseNamesTheAppThemeTheFrameIsDrawnIn() {
        // The frame is painted in the theme `THREADING_MOBILE_THEME` asks for; the Settings
        // capture's "Mac appearance" row reads `me.theme`, so the response has to carry the same
        // record rather than the demo's own.
        XCTAssertEqual(
            RemoteAppModel.marketingResponse.theme?.id,
            RemoteAppModel.demoRequestedMarketingTheme.id
        )
    }

    @MainActor
    func testMarketingTerminalPaletteMatchesEverySelectedAppTheme() throws {
        for appTheme in RemoteAppModel.demoCatalogThemes {
            let terminal = RemoteAppModel.demoMarketingTerminalTheme(matching: appTheme)

            XCTAssertEqual(terminal.id, "marketing-\(appTheme.id)-terminal")
            XCTAssertEqual(terminal.background, appTheme.colors["ground"])
            XCTAssertEqual(
                terminal.foreground.uppercased(),
                appTheme.colors["label"]?.uppercased()
            )
            XCTAssertEqual(terminal.cursor.uppercased(), appTheme.colors["accent"]?.uppercased())
            XCTAssertEqual(terminal.ansi.count, 16)

            // A terminal cell is opaque: every entry is six-digit hex, so a label tint such as
            // `tertiary_label` reaches SwiftTerm composited over the ground instead of as the
            // label with its alpha dropped (Art Deco's cream prompt bar, Editorial's black one).
            let opaque = try NSRegularExpression(pattern: "^#[0-9A-F]{6}$")
            for value in terminal.ansi + [terminal.selection, terminal.foreground] {
                XCTAssertNotNil(
                    opaque.firstMatch(
                        in: value, range: NSRange(value.startIndex..., in: value)
                    ),
                    "\(appTheme.id) yields a non-opaque terminal colour: \(value)"
                )
            }
            // Bright black is the prompt-bar grey: never the ground and never the label.
            let brightBlack = terminal.ansi[8].uppercased()
            XCTAssertNotEqual(brightBlack, terminal.background.uppercased(), appTheme.id)
            XCTAssertNotEqual(brightBlack, terminal.foreground.uppercased(), appTheme.id)
            // And the greys sit where a TUI recorded for that background expects them.
            if appTheme.mode == .light {
                XCTAssertEqual(terminal.ansi[0], terminal.foreground, appTheme.id)
                XCTAssertEqual(terminal.ansi[15], terminal.background, appTheme.id)
            } else {
                XCTAssertEqual(terminal.ansi[15], terminal.foreground, appTheme.id)
                XCTAssertNotEqual(terminal.ansi[0], terminal.foreground, appTheme.id)
            }
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
            case .terminalAttachmentNotice: expected = ("terminal-attachment-notice", .terminal)
            case .terminalBrowserActivity:
                expected = ("terminal-browser-activity", .terminal)
            case .terminalClaudeTUI: expected = ("terminal-claude-tui", .terminal)
            case .terminalCodexTUI: expected = ("terminal-codex-tui", .terminal)
            case .terminalCollaboration: expected = ("terminal-collaboration", .terminal)
            case .terminalSoloPresence: expected = ("terminal-solo-presence", .terminal)
            case .terminalReconnecting: expected = ("terminal-reconnecting", .terminal)
            case .terminalRecoveryFailed: expected = ("terminal-recovery-failed", .terminal)
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
            case .conversationSoloPresence:
                expected = ("conversation-solo-presence", .conversation)
            case .conversationCollaboration:
                expected = ("conversation-collaboration", .conversation)
            case .conversationContentTypes: expected = ("conversation-content-types", .conversation)
            case .conversationKeyboard: expected = ("conversation-keyboard", .conversation)
            case .conversationReconnectStress:
                expected = ("conversation-reconnect-stress", .conversation)
            case .conversationQuestion: expected = ("conversation-question", .conversation)
            case .conversationQuestionReadonly: expected = ("conversation-question-readonly", .conversation)
            case .conversationRichContent: expected = ("conversation-rich-content", .conversation)
            case .conversationRunPlan: expected = ("conversation-run-plan", .conversation)
            case .conversationRunPlanExpanded:
                expected = ("conversation-run-plan-expanded", .conversation)
            case .conversationScrollStress: expected = ("conversation-scroll-stress", .conversation)
            case .conversationStreaming: expected = ("conversation-streaming", .conversation)
            case .conversationToolExpanded: expected = ("conversation-tool-expanded", .conversation)
            case .attentionRequest: expected = ("attention-request", .attentionRequest)
            case .pairingStorageRecovery: expected = ("pairing-storage-recovery", .pairingStorageRecovery)
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
            case .appDiagnosticsSettings:
                expected = ("app-diagnostics-settings", .appDiagnosticsSettings(isEnabled: false))
            case .appDiagnosticsSettingsOn:
                expected = ("app-diagnostics-settings-on", .appDiagnosticsSettings(isEnabled: true))
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
            case .newSessionIdentityPicker:
                expected = ("new-session-identity-picker", .newSession)
            case .newSessionIdentityPickerFull:
                expected = ("new-session-identity-picker-full", .newSession)
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
            case .projectTerminalOpeningStarting:
                expected = (
                    "project-terminal-opening-starting",
                    .projectTerminalOpening(.starting)
                )
            case .projectTerminalOpeningConnecting:
                expected = (
                    "project-terminal-opening-connecting",
                    .projectTerminalOpening(.connecting)
                )
            case .workspace: expected = ("workspace", .workspace)
            case .browserPermission: expected = ("browser-permission", .browserPermission)
            case .browserPreview: expected = ("browser-preview", .browserPreview)
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
            case .usageLimitDense: expected = ("usage-limit-dense", .shippingRoot)
            case .usageLimitDenseWeek: expected = ("usage-limit-dense-week", .shippingRoot)
            case .usageLimitDenseQuarter: expected = ("usage-limit-dense-quarter", .shippingRoot)
            case .usageTotals: expected = ("usage-totals", .shippingRoot)
            case .usageStale: expected = ("usage-stale", .shippingRoot)
            case .sessions: expected = ("sessions", .shippingRoot)
            case .sessionsConnecting: expected = ("sessions-connecting", .shippingRoot)
            case .sessionsOffline: expected = ("sessions-offline", .shippingRoot)
            case .sessionsScrollStress:
                expected = ("sessions-scroll-stress", .shippingRoot)
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
            "terminal-attachment-notice",
            "terminal-browser-activity",
            "terminal-claude-tui",
            "terminal-codex-tui",
            "terminal-collaboration",
            "terminal-compose",
            "terminal-reconnecting",
            "terminal-recovery-failed",
            "terminal-scrollback",
            "terminal-selection",
            "terminal-solo-presence",
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

    @MainActor
    private static func eventually(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
#endif
