import AppKit
import XCTest
@testable import Threading

/// The wording behind "Close" and "Archive" on a running session.
///
/// The two actions read as near-synonyms in a menu, and for a while they behaved almost
/// unrelatedly: Close stopped the agent and kept the row, Archive hid the row and left the
/// agent running with nothing listing it. Neither verb says any of that, so the surface each
/// one puts up is where the difference is actually said — an alert *before* the close, a toast
/// *after* the archive — and these tests hold both to naming what a user cannot guess: that the
/// agent stops, where the session ends up, and that its conversation survives. Built separately
/// from being shown — the same seam the sidebar's menu builders offer — so no modal and no
/// window are involved.
@MainActor
final class SessionLifecycleConfirmationTests: XCTestCase {

    private func session(_ title: String = "Refactor the parser") -> AgentSession {
        AgentSession(kind: .claude, title: title)
    }

    func testTheCloseAlertSaysTheSessionStaysAndCanBeResumed() {
        let request = SessionCoordinator.closeConfirmation(for: session())

        XCTAssertTrue(request.title.contains("Close"))
        XCTAssertTrue(request.title.contains("Refactor the parser"))
        XCTAssertTrue(
            request.message.contains("stays in the sidebar"),
            "closing keeps the row; the alert is where that is said"
        )
        XCTAssertTrue(request.message.contains("resumed"))
    }

    func testDiskFullStartFailureKeepsTheBriefVisibleAndOffersVerifiedRetry() throws {
        var retried = false
        let toast = SessionCoordinator.sessionStartFailureToast(
            reason: .storageExhausted,
            retry: { retried = true }
        )

        XCTAssertTrue(toast.message.contains("disk full"))
        XCTAssertTrue(try XCTUnwrap(toast.detail).contains("brief is still here"))
        XCTAssertEqual(toast.actionTitle, "Retry")
        XCTAssertTrue(toast.persistsUntilDismissed)
        toast.action?()
        XCTAssertTrue(retried)
    }

    func testUnknownWriteFailureDoesNotOfferUnsafeRecovery() {
        let toast = SessionCoordinator.sessionStartFailureToast(
            reason: .failedWrite,
            retry: nil
        )

        XCTAssertFalse(toast.hasAction)
        XCTAssertTrue(toast.persistsUntilDismissed)
        XCTAssertTrue(toast.detail?.contains("restart Threading") == true)
    }

    func testMissingProjectFolderKeepsTheBriefAndNamesTheFolder() throws {
        let path = "/tmp/removed-worktree"
        let toast = SessionCoordinator.sessionStartFolderFailureToast(.missing(path: path))

        XCTAssertEqual(toast.message, "Session not started")
        let detail = try XCTUnwrap(toast.detail)
        XCTAssertTrue(detail.contains(path))
        XCTAssertTrue(detail.contains("brief is still here"))
        XCTAssertTrue(toast.persistsUntilDismissed)
        XCTAssertFalse(toast.hasAction)
    }

    /// Archiving asks nothing, so everything the alert used to say has to survive in the
    /// receipt: which session, what stopped with it, and where it went — the sidebar lists no
    /// archived session at all, so nothing else on screen would say.
    func testTheArchiveToastNamesTheSessionAndWhereItWent() throws {
        let toast = SessionCoordinator.archiveToast(
            for: session(),
            wasRunning: true,
            undo: {}
        )

        XCTAssertTrue(toast.message.contains("Archived"))
        XCTAssertTrue(toast.message.contains("Refactor the parser"))

        let detail = try XCTUnwrap(toast.detail)
        XCTAssertTrue(
            detail.contains("agent stopped"),
            "archiving a running session stops its agent, and the receipt must say so"
        )
        XCTAssertTrue(
            detail.contains("Settings ▸ Archived"),
            "the receipt names where an archived session can be found again"
        )
    }

    /// A dormant session had nothing to stop, and a receipt that says otherwise is reporting an
    /// interruption that never happened.
    func testTheArchiveToastOnlyReportsAStopWhenSomethingWasRunning() throws {
        let dormant = SessionCoordinator.archiveToast(
            for: session(),
            wasRunning: false,
            undo: {}
        )

        let detail = try XCTUnwrap(dormant.detail)
        XCTAssertFalse(detail.contains("stopped"))
        XCTAssertTrue(detail.contains("Settings ▸ Archived"))
    }

    func testArchiveFailureReportsAStopOnlyIfItHappenedBeforeTheFailure() throws {
        let preflight = SessionCoordinator.archiveFailureToast(
            for: session(),
            failure: .persistenceUnavailable(processStopped: false),
            wasRunning: true
        )
        XCTAssertFalse(try XCTUnwrap(preflight.detail).contains("stopped"))

        let afterProviderStarted = SessionCoordinator.archiveFailureToast(
            for: session(),
            failure: .commandCouldNotLaunch(
                provider: "Codex",
                archives: true,
                detail: "fixture"
            ),
            wasRunning: true
        )
        XCTAssertTrue(try XCTUnwrap(afterProviderStarted.detail).contains("stopped"))
    }

    /// The undo is the whole reason the question is gone. A receipt that reports an archive and
    /// offers no way back is strictly worse than the alert it replaced.
    func testTheArchiveToastCarriesTheWayBack() {
        var undone = 0
        let toast = SessionCoordinator.archiveToast(
            for: session(),
            wasRunning: false,
            undo: { undone += 1 }
        )

        XCTAssertTrue(toast.hasAction)
        XCTAssertEqual(toast.actionTitle, "Undo")
        toast.action?()
        XCTAssertEqual(undone, 1)
    }

    func testArchiveFencesADoublePressAndRoutesItsReceiptAndUndoFailureThroughTheOwner()
        throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-archive-intent-fence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let store = ProjectStore(stateManager: manager)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "One archive"
        ))
        let sidebar = ProjectSidebarViewController(projectStore: store)
        let terminal = TerminalContainerViewController(recovery: true)
        var archiveCalls = 0
        var archiveCompletion: ProviderArchiveSync.Completion?
        var receipts: [ToastRequest] = []
        let coordinator = SessionCoordinator(
            sidebar: sidebar,
            container: terminal,
            environment: AppEnvironment(
                projectStore: store,
                agentRuntime: AgentRuntime(
                    currentSessionProjection: CurrentSessionProjection { _ in nil }
                ),
                settings: AppSettings(defaults: UserDefaults.standard),
                eventLog: EventLog(directory: directory.appendingPathComponent("Logs"))
            ),
            onPresentationChanged: {},
            archiveStateSetter: { archived, sessionID, completion in
                XCTAssertEqual(sessionID, session.id)
                if archived {
                    archiveCalls += 1
                    archiveCompletion = completion
                } else {
                    completion(.failure(.persistenceUnavailable(processStopped: false)))
                }
            },
            toastPresenter: { receipts.append($0) }
        )

        XCTAssertTrue(coordinator.setArchived(true, for: session.id))
        XCTAssertTrue(coordinator.setArchived(true, for: session.id))
        XCTAssertEqual(archiveCalls, 1)
        XCTAssertTrue(receipts.isEmpty)

        try XCTUnwrap(archiveCompletion)(.success(()))
        let archiveReceipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(archiveReceipt.actionTitle, "Undo")
        archiveReceipt.action?()

        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts[1].message.contains("restore"))
    }

    /// Provider-backed archive finishes asynchronously. A chat selected during that wait owns
    /// the pane; the completion for the older chat must not replace it with the empty state.
    func testDelayedArchiveCompletionDoesNotClearANewerSessionSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-archive-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = StateManager(appSupportDirectory: directory)
        defer { manager.closeDatabase() }
        let store = ProjectStore(stateManager: manager)
        let project = try XCTUnwrap(store.addProject(folderURL: directory))
        let archiving = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Finishing archive"
        ))
        let selected = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            title: "Still selected"
        ))

        let sidebar = ProjectSidebarViewController(projectStore: store)
        let container = TerminalContainerViewController(recovery: true)
        var archiveCompletion: ProviderArchiveSync.Completion?
        let coordinator = SessionCoordinator(
            sidebar: sidebar,
            container: container,
            environment: AppEnvironment(
                projectStore: store,
                agentRuntime: AgentRuntime(
                    currentSessionProjection: CurrentSessionProjection { _ in nil }
                ),
                settings: AppSettings(defaults: UserDefaults.standard),
                eventLog: EventLog(directory: directory.appendingPathComponent("Logs"))
            ),
            onPresentationChanged: {},
            archiveStateSetter: { archived, sessionID, completion in
                XCTAssertTrue(archived)
                XCTAssertEqual(sessionID, archiving.id)
                archiveCompletion = completion
            }
        )

        container.show(sessionID: archiving.id)
        store.selectedSessionID = archiving.id
        coordinator.setArchived(true, for: archiving.id)

        XCTAssertNil(
            container.currentSessionID,
            "the visible archive waited for the provider command before leaving the UI"
        )

        container.show(sessionID: selected.id)
        store.selectedSessionID = selected.id
        archiveCompletion?(.success(()))

        XCTAssertEqual(
            container.currentSessionID,
            selected.id,
            "a stale archive completion emptied the chat selected while the provider was working"
        )
    }

    func testArchivePresentationResolutionPreservesUndoWithoutOverridingNewerNavigation() {
        let archived = SessionID()
        let replacement = SessionID()

        let stillVisible = SessionCoordinator.archivePresentationResolution(
            archivedSessionID: archived,
            visibleSessionID: archived,
            selectedSessionID: archived
        )
        XCTAssertTrue(stillVisible.clearsVisibleSession)
        XCTAssertTrue(stillVisible.reselectsOnUndo)

        let clearedByArchiveEvent = SessionCoordinator.archivePresentationResolution(
            archivedSessionID: archived,
            visibleSessionID: nil,
            selectedSessionID: archived
        )
        XCTAssertFalse(clearedByArchiveEvent.clearsVisibleSession)
        XCTAssertTrue(clearedByArchiveEvent.reselectsOnUndo)

        let newerSelection = SessionCoordinator.archivePresentationResolution(
            archivedSessionID: archived,
            visibleSessionID: replacement,
            selectedSessionID: replacement
        )
        XCTAssertFalse(newerSelection.clearsVisibleSession)
        XCTAssertFalse(newerSelection.reselectsOnUndo)
    }

    // MARK: - The archive the agent performs

    /// A row that leaves the sidebar on its own is the one report that has to name an actor:
    /// "Archived “X”" beside a window that rearranged itself answers what happened and not who
    /// did it, and who did it is the first thing anybody asks — and the only part that says this
    /// was not a misclick.
    func testTheAgentsArchiveToastNamesTheAgentAndWhatItFinished() throws {
        let toast = SessionCoordinator.agentArchiveToast(
            for: session(),
            reason: "committed and pushed the parser fix",
            wasRunning: true,
            undo: {}
        )

        XCTAssertTrue(
            toast.message.contains("Claude Code"),
            "the receipt for an archive nobody clicked has to say who did"
        )
        XCTAssertTrue(toast.message.contains("Refactor the parser"))

        let detail = try XCTUnwrap(toast.detail)
        XCTAssertTrue(
            detail.hasPrefix("Committed and pushed the parser fix."),
            "the agent's own account of what it finished leads, as one sentence"
        )
        XCTAssertTrue(detail.contains("The agent stopped."))
        XCTAssertTrue(detail.contains("Settings ▸ Archived"))
    }

    /// The reason is a fragment an agent wrote, not copy: it is set beside the app's own
    /// sentences without being rewritten, and without being punctuated twice.
    func testTheAgentsReasonIsSetAsOneSentenceOrLeftOut() throws {
        let punctuated = SessionCoordinator.agentArchiveToast(
            for: session(),
            reason: "Committed and pushed.",
            wasRunning: false,
            undo: {}
        )
        XCTAssertEqual(
            try XCTUnwrap(punctuated.detail),
            "Committed and pushed. Restore it from Settings ▸ Archived."
        )

        let silent = SessionCoordinator.agentArchiveToast(
            for: session(),
            reason: nil,
            wasRunning: false,
            undo: {}
        )
        XCTAssertEqual(
            try XCTUnwrap(silent.detail),
            "Restore it from Settings ▸ Archived.",
            "an agent that gave no reason must not leave an empty sentence on the band"
        )
    }

    /// The six seconds behind the clicked archive are measured from the click. There was none
    /// here: the user asked for this a turn ago, in words, and has been reading something else
    /// since — so this receipt has to survive them looking up. It still offers the same way back.
    func testTheAgentsArchiveToastHoldsLongerAndStillOffersTheWayBack() {
        var undone = 0
        let toast = SessionCoordinator.agentArchiveToast(
            for: session(),
            reason: nil,
            wasRunning: true,
            undo: { undone += 1 }
        )

        XCTAssertEqual(toast.dwell, ToastDefaults.unattendedDwell)
        XCTAssertNil(
            SessionCoordinator.archiveToast(for: session(), wasRunning: true, undo: {}).dwell,
            "the clicked archive takes the pane's own dwell"
        )
        XCTAssertNotEqual(
            toast.identifier,
            SessionCoordinator.archiveToast(for: session(), wasRunning: true, undo: {}).identifier
        )

        XCTAssertTrue(toast.hasAction)
        toast.action?()
        XCTAssertEqual(undone, 1)
    }

    /// Archiving is deliberately not in the register. Left as a case it would ship a Settings
    /// row for a question nobody asks; the point of removing it is that the way back replaced
    /// the way out.
    func testArchivingNoLongerCarriesAConfirmationPrompt() {
        XCTAssertFalse(
            ConfirmationPrompt.allCases.map(\.rawValue).contains("archiveRunningSession"),
            "an archive prompt is back in the register; the toast is the surface for this action"
        )

        // Deleting an *archived* session keeps its prompt, and must: that one is the end of the
        // conversation, which is the case a way back cannot be offered for.
        XCTAssertTrue(ConfirmationPrompt.allCases.contains(.deleteArchivedSession))
    }

    /// Cancel stays the way out: interrupting a running agent is never the only button on
    /// offer. Structural now that the request carries exactly one confirm title and one cancel
    /// title, so what is worth asserting is that the built alert still says so.
    func testTheCloseAlertOffersCancelLast() {
        let alert = ConfirmationAlert.makeAlert(SessionCoordinator.closeConfirmation(for: session()))

        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertEqual(alert.buttons.last?.title, "Cancel")
    }

    /// The lifecycle prompts were one setting, and switching off the one you meant used to
    /// switch off its neighbour. Each carries its own registered prompt now, and each one's
    /// settings copy has to name what the action does to the session — that is what someone
    /// deciding whether to stop being asked needs to know.
    func testEachLifecyclePromptHasItsOwnRowAndSaysWhatItInterrupts() throws {
        let close = try XCTUnwrap(ConfirmationPrompt.closeRunningSession.suppression)
        let move = try XCTUnwrap(ConfirmationPrompt.moveRunningSessionToAccount.suppression)

        XCTAssertTrue(close.settingsSubtitle.contains("sidebar"))
        XCTAssertTrue(move.settingsSubtitle.contains("account"))
        XCTAssertNotEqual(
            close.settingsTitle,
            move.settingsTitle,
            "one row each, or switching off the one you meant switches off the other"
        )
    }

    func testCrossProviderContinuationSaysItCreatesANewSessionAndKeepsTheOriginal() {
        let request = SessionCoordinator.continuationConfirmation(
            for: session(),
            destination: .codex
        )

        XCTAssertTrue(request.title.contains("Codex"))
        XCTAssertTrue(request.message.contains("new session"))
        XCTAssertTrue(request.message.contains("read-only snapshot"))
        XCTAssertTrue(request.message.contains("original session stays"))
        XCTAssertEqual(request.prompt, .continueRunningSessionWithAnotherProvider)
    }
}
