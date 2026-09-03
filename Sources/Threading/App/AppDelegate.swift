@preconcurrency import AppKit
import QuartzCore
import SwiftTerm
import ThreadingExtensionKit
import ThreadingRemoteKit

/// Launch Services calls the application delegate before the Dock's drag-completion transaction
/// has unwound. Application or window mutations therefore cross one main-queue turn first.
@MainActor
enum AppIconDropDelivery {
    static func afterDragCompletion(_ operation: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            operation()
        }
    }
}

/// Opt-in phase clock for the noninteractive cold-launch capture.
///
/// Kept outside `PerformanceRecorder`: the first timestamp is taken before `NSApplication`
/// exists, while the recorder's always-on `app.launch` span remains the semantic interval that
/// Instruments correlates after the delegate begins.
private struct StartupProfileMeasurement: Sendable {
    let processMainEntryNanoseconds: UInt64
    let delegateEntryNanoseconds: UInt64
    var ledgerOpenNanoseconds: UInt64 = 0
    var stateReadyNanoseconds: UInt64 = 0
    var preAppearanceReadyNanoseconds: UInt64 = 0
    var appearanceReadyNanoseconds: UInt64 = 0
    var menuReadyNanoseconds: UInt64 = 0
    var windowConstructedNanoseconds: UInt64 = 0
    var windowOrderedNanoseconds: UInt64 = 0

    func writeResult(
        firstReadyTurnNanoseconds: UInt64,
        settleLayoutNanoseconds: UInt64,
        settleDisplayNanoseconds: UInt64,
        firstFrameNanoseconds: UInt64,
        mode: String,
        projectCount: Int,
        sessionCount: Int,
        window: MainWindowStartupPerformance
    ) {
#if DEBUG
        let configuration = "debug"
#else
        let configuration = "release"
#endif
        let line = "THREADING_PERF app-startup "
            + "configuration=\(configuration) mode=\(mode) "
            + "projects=\(projectCount) sessions=\(sessionCount) "
            + "main_to_delegate_ms=\(milliseconds(processMainEntryNanoseconds, delegateEntryNanoseconds)) "
            + "ledger_open_ms=\(milliseconds(ledgerOpenNanoseconds)) "
            + "state_ms=\(milliseconds(delegateEntryNanoseconds, stateReadyNanoseconds)) "
            + "preappearance_ms=\(milliseconds(stateReadyNanoseconds, preAppearanceReadyNanoseconds)) "
            + "appearance_ms=\(milliseconds(preAppearanceReadyNanoseconds, appearanceReadyNanoseconds)) "
            + "menu_ms=\(milliseconds(appearanceReadyNanoseconds, menuReadyNanoseconds)) "
            + "window_construct_ms=\(milliseconds(menuReadyNanoseconds, windowConstructedNanoseconds)) "
            + "window_order_ms=\(milliseconds(windowConstructedNanoseconds, windowOrderedNanoseconds)) "
            + "first_turn_ms=\(milliseconds(windowOrderedNanoseconds, firstReadyTurnNanoseconds)) "
            + "delegate_to_ready_ms=\(milliseconds(delegateEntryNanoseconds, firstReadyTurnNanoseconds)) "
            + "total_ms=\(milliseconds(processMainEntryNanoseconds, firstReadyTurnNanoseconds)) "
            + "settle_layout_ms=\(milliseconds(settleLayoutNanoseconds)) "
            + "settle_display_ms=\(milliseconds(settleDisplayNanoseconds)) "
            + "total_to_frame_ms=\(milliseconds(processMainEntryNanoseconds, firstFrameNanoseconds)) "
            + "mw_create_ms=\(milliseconds(window.createWindowNanoseconds)) "
            + "mw_base_ms=\(milliseconds(window.baseInitializationNanoseconds)) "
            + "mw_split_ms=\(milliseconds(window.splitTotalNanoseconds)) "
            + "mw_sidebar_ms=\(milliseconds(window.splitSidebarNanoseconds)) "
            + "mw_content_ms=\(milliseconds(window.splitContentNanoseconds)) "
            + "mw_display_tools_ms=\(milliseconds(window.splitDisplayAndToolsNanoseconds)) "
            + "mw_content_install_ms=\(milliseconds(window.splitContentInstallNanoseconds)) "
            + "mw_toolbar_ms=\(milliseconds(window.splitToolbarNanoseconds)) "
            + "mw_toolbar_construct_ms=\(milliseconds(window.splitToolbarConstructionNanoseconds)) "
            + "mw_toolbar_attach_ms=\(milliseconds(window.splitToolbarAttachmentNanoseconds)) "
            + "mw_toolbar_items_ms=\(milliseconds(window.splitToolbarItemNanoseconds)) "
            + "mw_toolbar_style_ms=\(milliseconds(window.splitToolbarStyleNanoseconds)) "
            + "mw_header_ms=\(milliseconds(window.splitHeaderNanoseconds)) "
            + "mw_finalize_ms=\(milliseconds(window.splitFinalizeNanoseconds)) "
            + "mw_chrome_ms=\(milliseconds(window.chromeCoordinatorNanoseconds)) "
            + "mw_frame_ms=\(milliseconds(window.initialFrameNanoseconds)) "
            + "mw_title_ms=\(milliseconds(window.initialTitleNanoseconds))\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    private func milliseconds(_ start: UInt64, _ end: UInt64) -> String {
        let elapsed = end >= start ? end - start : 0
        return String(format: "%.3f", Double(elapsed) / 1_000_000)
    }

    private func milliseconds(_ elapsed: UInt64) -> String {
        String(format: "%.3f", Double(elapsed) / 1_000_000)
    }
}

/// AppKit's Edit actions live on `NSWindow`'s Objective-C responder surface and are not imported
/// as Swift methods. They take a sender (`undo:` / `redo:`); `UndoManager.undo` and `.redo` are
/// different, zero-argument selectors, so sending either of those through the responder chain
/// finds no target even while the focused editor's manager has work waiting.
@MainActor
enum AppKitEditActions {
    static let undo = NSSelectorFromString("undo:")
    static let redo = NSSelectorFromString("redo:")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate,
    RemoteSessionCommands {

    // MARK: - Singleton

    static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private let processMainEntryNanoseconds: UInt64
    /// Kept lazy so `ProjectStore.shared` is first constructed after `RecoveryMode.enter` fixes
    /// the write policy for this launch. Building the live environment in `init` made every
    /// recovery launch open the store under the normal-launch default.
    private lazy var environment: AppEnvironment = .live
    private var runsStartupProfile = false

    override init() {
        processMainEntryNanoseconds = DispatchTime.now().uptimeNanoseconds
        super.init()
    }

    init(processMainEntryNanoseconds: UInt64) {
        self.processMainEntryNanoseconds = processMainEntryNanoseconds
        super.init()
    }

    // MARK: - Properties

    private var mainWindowController: MainWindowController?
    private let issueReportEvents = AppEventObservations()
    private let remoteSessionEvents = AppEventObservations()
    private var activeTurnSleepInhibitor: ActiveTurnSleepInhibitor?
    private var onboardingWindowController: OnboardingWindowController?
    /// True while first-launch onboarding is deferring the main window. Gates session restore
    /// and routes Dock-click reopens to the onboarding window instead of the hidden main one.
    private var isOnboardingActive = false
    /// Session restore needs both the MCP listener and a visible main window; whichever
    /// arrives second performs it. See `restoreSelectedSessionIfReady`.
    private var mcpServerHasStarted = false
    /// A durable checkout fence may still be copying Claude's transcript when the MCP listener
    /// becomes ready. No restore path may launch that conversation against its old project.
    private var pendingCheckoutMovesHaveSettled = false
    private var componentGalleryWindowController: ComponentGalleryWindowController?
    private var aboutWindowController: AboutWindowController?
    private var componentCustomizationRegistry: ComponentCustomizationRegistry?
    private var hostFactPipeline: HostFactPipeline?
    private var workspaceNavigatorMenu: NSMenu?
    private var commandPaletteController: CommandPaletteViewController?
    private var navigationSearchIndexStore: NavigationSearchIndexStore?
    private var transcriptSearchIndexStore: TranscriptSearchIndexStore?
    private var remoteUniversalSearchService: RemoteUniversalSearchService?
    private var universalSearchController: UniversalSearchSessionController?
    private var agentCLIUpdateCoordinator: AgentCLIUpdateCoordinator?

    /// The same semantic catalog and invocation route feeds menus, shortcuts and the palette.
    /// It deliberately re-resolves window context each time either closure runs.
    private lazy var hostCommandPlane = HostCommandPlane(
        catalog: { [weak self] in self?.hostCommandCatalog() ?? [] },
        inputOptions: { [weak self] commandID, input in
            self?.hostCommandInputOptions(commandID: commandID, input: input) ?? []
        },
        invokeRequest: { [weak self] request in
            self?.performHostCommand(request)
                ?? .refused(
                    commandID: request.commandID,
                    reason: L10n.string("The application is unavailable.")
                )
        }
    )

    /// Whether this process won the single-instance lock and therefore owns the state.
    private var ownsSingleInstanceLock = false

    /// What a takeover ended, held between the takeover and `beginLaunch`.
    ///
    /// The takeover necessarily happens *before* the journal opens — nothing may write into the
    /// state directory until this process owns it — so the record cannot be written where it
    /// happens. It is carried the few lines to where the journal exists.
    private var singleInstanceTakeover: SingleInstanceTakeoverRecord?

    /// What the launch history said about this launch, decided once at the top of the launch and
    /// held.
    ///
    /// Three things read it and none of them can re-derive it: the journal has already recorded
    /// it, the support report is written much later, and the unclean-exit notice goes up behind a
    /// gate that can fire twice. Deciding again would also mean reading the ledger again, after
    /// this launch has written into it.
    private(set) var launchDecision: CrashLoopDecision = .launchNormally(.available)

    /// The ledger read the decision was made from, for the support report's own field. A decision
    /// with nothing behind it and a decision made on a history that could not be read are the
    /// same recommendation, and a report has to be able to tell them apart.
    private(set) var launchLedgerRead: LaunchLedgerRead = .missing

    /// What this launch is allowed to start, decided once from the decision above and read at
    /// each step below. A value rather than a mode test at twenty call sites: the whole rule is
    /// then one table a test can assert without an application, a window or a store.
    private(set) var launchPlan = LaunchPlan(
        resolution: .normalLaunch,
        decision: .launchNormally(.available),
        extensionsDisabledOnce: false,
        needsOnboarding: false
    )

    /// The `.ips` the recovery surface can point at, held because the marker's answer is
    /// consumed once and the surface is built after that.
    private var launchCrashReport: URL?

    /// The three restore paths, and what an unclean previous exit does to two of them.
    ///
    /// Built lazily against the window controller rather than holding it: this object outlives
    /// nothing and is asked for the window only when a restore actually happens.
    private lazy var launchRestoration = LaunchRestoration(
        actions: LaunchRestoration.Actions(
            restoreSelectedSession: { [weak self] in
                self?.mainWindowController?.restoreSelectedSession()
            },
            // Behind the same two gates for the same reasons — every launch reads the MCP port —
            // and after the selected session, which the user is about to look at and which the
            // relaunch therefore leaves out. The record is consumed even when the setting is
            // off, so enabling it later cannot act on a list from some earlier quit.
            relaunchSessionsFromLastQuit: { [weak self] in
                self?.mainWindowController?.relaunchSessionsFromLastQuit()
            },
            // After both session-restore paths, so a window whose session is coming back anyway
            // is not built twice — `restoreDetachedBrowserWindows` skips ids it already holds.
            restoreDetachedBrowserWindows: { [weak self] in
                self?.mainWindowController?.restoreDetachedBrowserWindowsAtLaunch()
            },
            presentNotice: { [weak self] crashReport, escalation, restore in
                EventLog.shared.record(.app, EventLogDefaults.heldBackWorkspaceMessage, [
                    "crashReport": crashReport?.path ?? "none",
                    "escalated": escalation == .none ? "no" : "yes"
                ])
                self?.mainWindowController?.presentUncleanExitNotice(
                    crashReport: crashReport,
                    escalation: escalation,
                    restore: restore
                )
            }
        )
    )

    /// Whether the system, rather than the user, started this quit.
    ///
    /// `applicationShouldTerminate` is the same entry point for Cmd+Q and for a logout, restart
    /// or shutdown — and a modal on the second path is what makes macOS report "Threading
    /// prevented logout" and hand the user a dialog they did not ask for about an app they were
    /// not looking at. `willPowerOffNotification` arrives before the termination request, so the
    /// flag is set by the time the confirmation would go up. Read `NSWorkspace`'s own signal
    /// rather than the quit Apple Event's reason: the notification is one documented name, and
    /// getting the event's descriptor keywords subtly wrong fails silently in the direction of
    /// blocking a shutdown.
    private var isSystemInitiatedQuit = false

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host their bundle in this app, so `main()` runs before them. Skip the real
        // startup then: the tests exercise types directly and must not spawn agents, start the MCP
        // server, or touch the user's stores.
        if NSClassFromString("XCTestCase") != nil { return }

        switch SimulatorCompatibilityProbeArguments.resolve(CommandLine.arguments) {
        case .notRequested:
            break
        case .refused(let reason):
            FileHandle.standardError.write(Data("error: \(reason)\n".utf8))
            NSApp.terminate(nil)
            return
        case .requested(let request):
            Task {
                let report = await SimulatorCompatibilityProbe.run(request: request)
                do {
                    try SimulatorCompatibilityProbe.write(report, to: request.reportURL)
                } catch {
                    FileHandle.standardError.write(Data(
                        "error: Could not write Simulator compatibility report: "
                            .appending(error.localizedDescription)
                            .appending("\n")
                            .utf8
                    ))
                }
                NSApp.terminate(nil)
            }
            return
        }

        var startupProfile = ProcessInfo.processInfo.environment["THREADING_STARTUP_PROFILE"] == "1"
            ? StartupProfileMeasurement(
                processMainEntryNanoseconds: processMainEntryNanoseconds,
                delegateEntryNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            : nil
        runsStartupProfile = startupProfile != nil

        configureSwiftTermDiagnostics()

        let launchSpan = PerformanceRecorder.shared.begin(
            "app.launch",
            category: "lifecycle"
        )
        defer { launchSpan.end() }

        // Before anything can touch the stores: a second instance must never get far enough
        // to write projects.json, or the two silently overwrite each other's state.
        //
        // Losing the lock is no longer the end of the launch. `resolveLostSingleInstanceLock`
        // reads who holds it and either switches to that instance, offers to end an unresponsive
        // one, or puts up the alert this always had. Only a takeover that actually took the lock
        // comes back true, and everything below is then reached exactly as if the first acquire
        // had won.
        if !SingleInstanceLock.acquire() {
            guard resolveLostSingleInstanceLock() else {
                NSApp.terminate(nil)
                return
            }
        }
        ownsSingleInstanceLock = true

        // Immediately after the lock and only in the process that holds it: a heartbeat from an
        // instance that lost is a lie about who owns the state. In recovery too — a wedged
        // recovery instance locks the user out exactly as a wedged normal one does.
        SingleInstanceHeartbeat.shared.start()

        // The first thing this instance does once it owns the state, because until the marker is
        // down a launch that dies leaves nothing behind to say so. It is deliberately *ahead* of
        // the adoption below, which used to sit in that blind window and is the one part of a
        // launch that moves someone's database around. Nothing between the lock and here can
        // fail, so the whole of `applicationDidFinishLaunching` is now covered.
        //
        // Safe to precede the adoption because the adoption keys on the legacy directory, on its
        // own `.adopted-from-skalman` marker and on the *database* here — none of which this
        // writes — and the directory it needs was already created by the lock above. The one
        // thing that did interact is that the adoption used to copy the legacy `Logs` over the
        // top of this journal; it leaves them behind now. See `docs/architecture/persistence.md`.
        //
        // After the lock, so only the instance that owns the state writes the journal.
        EventLog.shared.beginLaunch()

        // The first thing this launch says, if it got here over something else's body.
        //
        // **It is deliberately after `beginLaunch`, and that has a consequence worth naming**:
        // the killed owner's marker is still on disk, so this launch consumes it and reads the
        // previous launch as `.unclean`. Held-back restoration and the crash-loop counter then
        // apply to the wedged instance — which is right. It *was* an instance that did not come
        // back, and a launch that had to step over it is the last one that should be relaunching
        // its workspace automatically. `SIGKILL` writes no `.ips`, and the report matcher pins
        // candidates to the marker's pid, so nothing stray can be attached to it either.
        recordSingleInstanceTakeoverIfNeeded()

        // Beside the marker and immediately after it, because the two mean the same launch by the
        // same id: the marker knows *how* the previous launch ended and only the ledger knows how
        // far it got, so the ledger is told the marker's answer rather than deriving a second one
        // that could disagree with it. What comes back is the history as the tombstones it just
        // wrote left it, which is what the policy then reads.
        //
        // **Opening and beginning are two steps now**, because the `begin` record carries the
        // mode and the mode is decided from what the opening returns. Everything between them
        // reads and decides; nothing between them writes.
        let ledgerOpenStart = startupProfile.map { _ in DispatchTime.now().uptimeNanoseconds }
        let opening = LaunchLedger.shared.openLaunch(
            previousOutcome: EventLog.shared.previousLaunchOutcome
        )
        if let ledgerOpenStart {
            startupProfile?.ledgerOpenNanoseconds =
                DispatchTime.now().uptimeNanoseconds - ledgerOpenStart
        }
        let decision = CrashLoopPolicy.decide(opening.read)
        launchDecision = decision
        launchLedgerRead = opening.read
        if case .unclean(let report) = EventLog.shared.previousLaunchOutcome {
            launchCrashReport = report
        }

        // Spent whichever branch wins, so a one-shot outranked by an explicit request is still
        // one-shot. Reading it is also the last thing that happens before the mode is known.
        let flags = LaunchFlagsStore.shared.consume(launchID: EventLog.shared.currentLaunchID)
        let resolution = LaunchModeResolver.resolve(
            decision: decision,
            optionHeld: Self.isOptionHeldAtLaunch(),
            arguments: CommandLine.arguments,
            forceNormalOnce: flags.forceNormalNextLaunch
        )
        RecoveryMode.enter(resolution)
        LaunchLedger.shared.beginLaunch(
            opening,
            id: EventLog.shared.currentLaunchID,
            mode: resolution.mode
        )
        journal(decision, ledger: opening.read, resolution: resolution, flags: flags)

        // The plan is built after the mode and before the first step reads it. `needsOnboarding`
        // touches `ProjectStore`, which is why the store's write policy is settled by the mode
        // already being in force rather than by a flag set on it afterwards.
        launchPlan = LaunchPlan(
            resolution: resolution,
            decision: decision,
            extensionsDisabledOnce: flags.disableExtensionsNextLaunch,
            needsOnboarding: OnboardingState.needsOnboarding
        )
        let plan = launchPlan

        // Before any store is opened: the app was renamed, and with it its Application Support
        // directory, so the first launch after that came up on an empty store with everything
        // still in the old one. Runs once, and only while the new store has no projects in it.
        //
        // Recovery weighs this one rather than refusing it — see `LaunchPlan`: an empty sidebar
        // after the rename reads as data loss, and that is the worst possible message here.
        var adoption = LegacyApplicationSupportMigration.Outcome()
        if plan.runsLegacyMigration {
            adoption = LegacyApplicationSupportMigration.runIfNeeded()
        }
#if DEBUG
        switch UIScenarioBootstrap.installIfRequested() {
        case .notRequested, .installed:
            break
        case .refused(let reason):
            ThreadingLogger.app.error("UI scenario bootstrap refused: \(reason, privacy: .public)")
            NSApp.terminate(nil)
            return
        }
#endif
        LaunchLedger.shared.record(.migrationDone, detail: [
            StartupCheckpointDefaults.migrationField: plan.runsLegacyMigration
                ? StartupCheckpointDefaults.migrationRan
                : StartupCheckpointDefaults.migrationSkippedInRecovery
        ])
        startupProfile?.stateReadyNanoseconds = DispatchTime.now().uptimeNanoseconds

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemInitiatedQuit = true
            }
        }

        MetricKitDiagnostics.shared.start()
        // Recorded after the journal opens rather than inside the migration, so the one launch
        // that adopted the old directory says so in the same place every other launch fact goes.
        if adoption.didAdoptAnything {
            EventLog.shared.record(.app, "Adopted the pre-rename Application Support directory", [
                "files": String(adoption.adoptedFileCount),
                "database": adoption.adoptedDatabase ? "yes" : "no"
            ])
        }
        MacRemoteDiagnostics.record(.appLaunched, fields: [
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ])

        // The transcript recovery record is one fixed app-owned file, so this does no provider
        // directory scan. Run it after the journal can report an ambiguous promotion and before
        // anything can resume a conversation against a destination it may need to restore.
        TranscriptCopyRecovery.runLaunchRecovery()

        // After the journal, so the sweep has somewhere to report to; before anything can start
        // a conversation, because it decides by pid and a pid is only unambiguous while nothing
        // new has been spawned. Only this instance runs it: it is below both the hosted-test
        // bail-out and the single-instance lock, and a launch that owns neither must not signal
        // processes another one is using.
        OrphanedAgentChildSweep.run()
        startupProfile?.preAppearanceReadyNanoseconds = DispatchTime.now().uptimeNanoseconds

        // Before the first window is built, so everything is created already themed and nothing
        // has to be repainted at launch. `AppThemeRefresh` exists for the *later* changes.
        // Extension-contributed themes and fonts are pure package data, so they register first
        // — a restore that resolves a contributed theme must find it already in the library.
        //
        // Neither runs in recovery: contributions are an extension's, and the restore is pinned
        // to System in memory. A stored contributed theme therefore falls back for this launch,
        // which `contributedThemesDidChange` already heals the moment the tier comes back.
        if plan.startsExtensions {
            ExtensionManager.shared.prepareAppearanceContributions()
        }
        AppThemeLibrary.restore(plan.mode)
        LaunchLedger.shared.record(.themeRestored, detail: [
            StartupCheckpointDefaults.themeField: plan.isRecovery
                ? StartupCheckpointDefaults.themeRecoveryStock
                : StartupCheckpointDefaults.themeStored
        ])
        AppThemeRefresh.startObservingAccessibilityDisplayOptions()
        AppThemeRefresh.startObservingSystemAppearance()
        AppThemeRefresh.startObservingFontOverrides()

        // After the restore, so the first Dock tile is the theme the user actually launched
        // into rather than System's for one frame.
        AppIconPresenter.install()
        startupProfile?.appearanceReadyNanoseconds = DispatchTime.now().uptimeNanoseconds

        setupMenuBar()
        startupProfile?.menuReadyNanoseconds = DispatchTime.now().uptimeNanoseconds

        // Optional MCP systems are installed at the composition root. The MCP server itself
        // knows only its replaceable provider seam and works unchanged when this remains nil —
        // which is exactly what recovery leaves it as. All three are extension seams, and an
        // unfilled slot means every component draws its own answer rather than a package's.
        if plan.startsExtensions {
            MCPExternalToolRegistry.shared.register(ExtensionMCPToolProvider())
            MCPExternalToolRegistry.shared.register(NativePluginMCPToolProvider())
            installComponentCustomizationProvider()
            ExtensionIdentityResolverProviderSlot.shared.provider =
                ExtensionIdentityResolverRegistry.shared
        }

        let mainWindowController = MainWindowController(
            environment: environment,
            initialFramePlan: MainWindowInitialFramePlan(
                previousLaunch: EventLog.shared.previousLaunchOutcome
            )
        )
        mainWindowController.issueReportSubmitter = MacIssueReportSubmitter(
            diagnosticsProvider: { [weak self] in
                guard let self else { throw MacIssueReportError.invalidPackage }
                return try await self.publicIssueReportDiagnostics()
            }
        )
        self.mainWindowController = mainWindowController
        let navigationSearchIndexStore = NavigationSearchIndexStore(
            projectStore: environment.projectStore
        )
        self.navigationSearchIndexStore = navigationSearchIndexStore
        let transcriptSearchIndexStore = TranscriptSearchIndexStore(
            projectStore: environment.projectStore
        )
        self.transcriptSearchIndexStore = transcriptSearchIndexStore
        let remoteUniversalSearchService = RemoteUniversalSearchService(
            navigationIndex: navigationSearchIndexStore,
            transcriptIndex: transcriptSearchIndexStore,
            projectStore: environment.projectStore,
            workspaceMetadata: { [weak mainWindowController] in
                mainWindowController?.workspaceMetadataSearchRecords() ?? []
            }
        )
        self.remoteUniversalSearchService = remoteUniversalSearchService
        RemoteAccessCoordinator.shared.installUniversalSearch(remoteUniversalSearchService)
        universalSearchController = UniversalSearchSessionController(
            navigationIndex: navigationSearchIndexStore,
            transcriptIndex: transcriptSearchIndexStore,
            catalog: { [weak self] in self?.hostCommandPlane.commands() ?? [] },
            projects: { [weak self] in self?.environment.projectStore.projects ?? [] },
            projectContext: { [weak mainWindowController] in
                mainWindowController?.currentProjectID
            },
            viewContext: { [weak mainWindowController] in
                mainWindowController?.currentSearchViewContext
            },
            workspaceMetadata: { [weak mainWindowController] in
                mainWindowController?.workspaceMetadataSearchRecords() ?? []
            },
            activate: { [weak self] locator in
                await self?.activateSearchLocator(locator) == true
            }
        )
        // A checkout move requested by the turn that preceded a crash is a durable input fence.
        // Settle it only after the window has installed its relaunch observer, but before session
        // restoration is allowed to start the provider in the old checkout.
        SessionCheckoutCoordinator.shared.resumePendingMovesAtLaunch { [weak self] in
            // A committed move publishes its relaunch event onto the main queue. Open the
            // ordinary restore gate one turn later so those already-enqueued replacements run
            // first; otherwise startup can launch the same provider once from restore and once
            // from the checkout observer.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pendingCheckoutMovesHaveSettled = true
                restoreSelectedSessionIfReady()
            }
        }
        if plan.startsBackgroundServices {
            Task { await MacIssueReportOutbox.shared.flush() }
            issueReportEvents.observe(NSApplication.didBecomeActiveNotification) {
                Task { await MacIssueReportOutbox.shared.flush() }
            }
        }
        LaunchLedger.shared.record(.mainWindowConstructed)
        startupProfile?.windowConstructedNanoseconds = DispatchTime.now().uptimeNanoseconds
        // The bridge's only client is the remote server, which recovery never starts, and it is
        // the seam a phone drives this window through.
        if plan.startsBackgroundServices {
            RemoteWorkspaceBridge.install(mainWindowController)
        }

        // First launch defers the main window behind the onboarding walkthrough. Everything
        // else in this launch sequence still runs: every downstream consumer needs the
        // controller *instance*, not a visible window. Session restore is the one exception,
        // gated in `restoreSelectedSessionIfReady`.
        if plan.showsOnboarding {
            isOnboardingActive = true
            let onboarding = OnboardingWindowController { [weak self] in
                self?.onboardingDidFinish()
            }
            onboardingWindowController = onboarding
            onboarding.showWindow(nil)
        } else {
            mainWindowController.showWindow(nil)
        }
        startupProfile?.windowOrderedNanoseconds = DispatchTime.now().uptimeNanoseconds
        noteFirstWindowVisible(armsStability: plan.armsStabilityCheckpoint)
        if plan.isRecovery {
            presentRecoveryMode(on: mainWindowController)
        }
        MainThreadStallMonitor.shared.start()
#if DEBUG
        installMainThreadStallHUD(on: mainWindowController)
#endif

        // A command-line startup capture measures the normal path through the first usable
        // window, then stops before session restoration, extension processes, polling and other
        // post-visible services can mutate the workspace or keep the fixture alive. The next
        // main-queue turn is the same readiness proof the launch ledger uses above. Terminating
        // through AppKit records a clean launch; it does not leave a crash marker behind.
        if let startupProfile {
            let projects = ProjectStore.shared.projects
            let projectCount = projects.count
            let sessionCount = projects.reduce(0) { $0 + $1.sessions.count }
            let windowPerformance = mainWindowController.startupPerformance
            DispatchQueue.main.async {
                let firstReadyTurnNanoseconds = DispatchTime.now().uptimeNanoseconds
                let layoutStartNanoseconds = DispatchTime.now().uptimeNanoseconds
                let window = mainWindowController.window
                window?.contentView?.layoutSubtreeIfNeeded()
                let layoutReadyNanoseconds = DispatchTime.now().uptimeNanoseconds
                // `NSView.displayIfNeeded()` does not force a layer-backed window's pending draw;
                // neither does the window call commit the implicit Core Animation transaction.
                // Without both, the work slips into `NSApplication.terminate` and the alleged
                // first-frame number ends before the first frame.
                window?.displayIfNeeded()
                CATransaction.flush()
                let firstFrameNanoseconds = DispatchTime.now().uptimeNanoseconds
                startupProfile.writeResult(
                    firstReadyTurnNanoseconds: firstReadyTurnNanoseconds,
                    settleLayoutNanoseconds: layoutReadyNanoseconds - layoutStartNanoseconds,
                    settleDisplayNanoseconds: firstFrameNanoseconds - layoutReadyNanoseconds,
                    firstFrameNanoseconds: firstFrameNanoseconds,
                    mode: plan.isRecovery ? "recovery" : "normal",
                    projectCount: projectCount,
                    sessionCount: sessionCount,
                    window: windowPerformance
                )
                NSApp.terminate(nil)
            }
            return
        }

        // After the window exists, so a clicked notification always has somewhere to land.
        // Never under tests: only `start()` touches `UNUserNotificationCenter`.
        //
        // Neither runs in recovery. The alert centre can raise a permission dialog, and nothing
        // in recovery can produce an alert to justify one; the workload monitor watches agents,
        // and there are none.
        if plan.startsBackgroundServices {
            // Registered before attention alerts so an important activity edge wakes a snoozed
            // session before the alert centre decides whether that same edge may notify.
            SessionSnoozeCenter.shared.start()
            // Beside Snooze because it is the same kind of thing — one process timer over
            // persisted deadlines, materializing what was missed while the app was shut. It
            // refuses to start under a hosted test bundle for its own reason: it types.
            SessionCurfewCenter.shared.start()
            AttentionAlertCenter.shared.start()
            AgentWorkloadMonitor.shared.start()

            let runtime = environment.agentRuntime
            let settings = environment.settings
            let inhibitor = ActiveTurnSleepInhibitor(
                currentInFlightSessionIDs: {
                    Set(runtime.runningSessionIDs.filter {
                        runtime.activity(sessionID: $0).hasTurnInFlight
                    })
                },
                activity: { runtime.activity(sessionID: $0) },
                isEnabled: { settings.preventsIdleSystemSleepWhileAgentsWork }
            )
            inhibitor.start()
            activeTurnSleepInhibitor = inhibitor
        }

        if plan.startsExtensions {
            let factPipeline = installHostFactPipeline()
            mainWindowController.installWorkspaceNavigatorFactRegistry(factPipeline.registry)
            ExtensionHostService.shared.installSessionRuntimeShellRootProvider {
                [weak mainWindowController] sessionID in
                mainWindowController?.extensionShellRootPid(for: sessionID)
            }

            // Installed extensions get a separate, tokenized host-data/service channel. It must
            // be ready before a host-capable process starts, because that process receives the
            // short-lived endpoint and bearer token only in its launch environment.
            ExtensionHostService.shared.start(
                registry: componentCustomizationRegistry,
                factRegistry: factPipeline.registry,
                identityRegistry: .shared
            ) {
                ExtensionManager.shared.startEnabledExtensions()
                LaunchLedger.shared.record(.extensionsStarted)
            }
        } else if !plan.isRecovery {
            // A normal launch that was asked, once, to come up without extensions. The pane says
            // so, because a user who armed that yesterday and forgot must not conclude their
            // extensions have been uninstalled.
            mainWindowController.presentExtensionsHeldBackNotice()
        }

        // Both delete: one removes history files whose sessions are gone, the other clears a
        // legacy key. A recovery launch removes nothing.
        if plan.startsBackgroundServices {
            cleanupOrphanedHistoryFiles()
            cleanupOrphanedTurnCheckpoints()
            StateManager.shared.clearLegacySessionState()
        }

        // Everything below is optional background machinery, and recovery starts none of it: the
        // three that write into the store or the support directory (icon discovery, branch
        // following, name backfill), the three that spawn subprocesses or reach the network
        // (usage prefetch, the email probe, the code count), the one that starts a real agent
        // turn on a schedule (the usage-window poker), the one that watches live sessions
        // (limit recovery), the remote listener and its tunnel child, and the disk survey.
        // The launch ends here in recovery. A `guard` rather than a wrapper around the rest,
        // because the rest is a single run of starts with no ordering left to preserve: the MCP
        // listener is the last thing above that anything waited on, and its callback is where
        // restoration and the scheduled-message services live.
        guard plan.startsBackgroundServices else { return }

        // The PTY host's launchd agent, aligned with `AppSettings.ptyHostEnabled`. Deliberately
        // here: after the single-instance lock, after the launch-mode decision, and below the
        // recovery guard — a launch that came up because the last one did not must not install
        // something that outlives it. Started unconditionally and gated on its own key, like the
        // branch follower and the usage poker, so turning the key on takes effect without a
        // restart; with the key off — which is every launch until R1 in `permissions.md` is
        // answered on a SIP-enabled Mac — it short-circuits before touching launchd. Registration
        // is attempted and never required: every failure leaves sessions on the in-process PTY.
        PTYHostRegistrationCoordinator.shared.start(settings: environment.settings)

        // The shim directory that makes `~/.local/bin/threading-ptyd` survive a bundle move.
        // Every launch, because the bundle is exactly what moves: the autoinstall hook replaces
        // `/Applications/Threading.app` wholesale and a Debug build runs from DerivedData, so a
        // link written yesterday names a path that may no longer hold a helper. Beside the
        // registration above because it publishes the same daemon, and below the recovery guard
        // for the same reason: a launch that came up because the last one did not should change
        // as little as possible about the machine. Off-main and idempotent — an unchanged
        // directory is one `readlink` per tool and no writes.
        Task.detached(priority: .utility) {
            ThreadingCommandLineTools.refreshAtLaunch()
        }

        // One sweep of the runtime inventory, at most once a day and re-checked while the app
        // keeps running. Process and network work stay off-main; a found result waits for a
        // visible, active main window before its toast clock starts.
        let agentCLIUpdateCoordinator = AgentCLIUpdateCoordinator(
            canPresent: { [weak self, weak mainWindowController] in
                guard let self else { return false }
                return NSApp.isActive
                    && !self.isOnboardingActive
                    && mainWindowController?.window?.isVisible == true
            },
            present: { [weak mainWindowController] updates, updatesDidStart in
                mainWindowController?.presentAgentCLIUpdates(updates, didStart: updatesDidStart)
            }
        )
        self.agentCLIUpdateCoordinator = agentCLIUpdateCoordinator
        agentCLIUpdateCoordinator.start()

        // Fills empty icon slots in the background; it observes the store from here on, so
        // projects added later are swept as they appear.
        ProjectIconDiscovery.shared.start()

        // Keeps dormant sessions' branch records following their checkout. Started
        // unconditionally: it gates itself on the setting and re-checks on every change,
        // which is how toggling it on mid-run takes effect.
        CheckoutBranchFollower.shared.start()

        // One throttled sweep, so the first account menu opened in a launch already carries
        // each login's usage rather than filling in only on a second look.
        AccountUsageMenu.prefetch()

        // Opens the day's usage window at the planned moment. Started unconditionally and gated
        // on its own schedule, like the branch follower above: the alternative is a service that
        // only exists if the setting was on at launch, which is the version where turning it on
        // does nothing until the next restart.
        UsageWindowPoker.shared.start()

        // Tells the user when one of their own limits crosses a line they asked about. Started
        // unconditionally for the same reason as the two services around it: the rules are read
        // at the moment a reading arrives, so adding one needs no restart. It refuses under a
        // test bundle on its own account.
        UsageAlertCenter.shared.start()

        // Watches live sessions for a usage-limit refusal and carries out the user's chosen
        // recovery. Started unconditionally for the poker's reason — the policy is read at the
        // moment a refusal is found, so flipping it on needs no restart.
        LimitRecoveryCoordinator.shared.start()

        // The same idea for *who* each login is. Only accounts whose address is not already on
        // disk are asked, and the answer is cached across launches, so this is normally a
        // no-op — the default Claude login is the one it exists for.
        AccountEmailProbe.prefetch(AgentAccountDiscovery.accounts(for: .claude)) {
            NotificationCenter.default.post(AccountPreferencesDidChange())
        }

        // Session restore waits for the listener, because a launch reads the port to build the
        // session's `--mcp-config`. The callback runs whether the server came up or not, so a
        // failed listener costs the restored session its display panel and nothing else.
        MCPServer.shared.handler = mainWindowController.agentToolCoordinator
        mainWindowController.installPermissionPresenter()

        // Installed here rather than on the window, because a lifecycle report is about a
        // running session and stays meaningful whether or not anything is showing it.
        HookLifecycleRelay.observe = { report in
            AgentRuntime.shared.applyLifecycle(report)
        }
        HookRunProgressRelay.observe = { report in
            AgentRuntime.shared.applyRunProgress(report)
        }

        // Codex is the one runtime with a reversible provider archive. Reconcile before the
        // startup restore is released where possible, then again whenever Threading regains
        // focus after an archive or restore performed in another client.
        ProviderArchiveSync.shared.start()

        // A published managed session owns its opaque remote branch until the change request is
        // merged or closed. Reconcile that provider lifecycle independently of the archived
        // conversation: deletion is lease-protected and never needs the disposed worktree.
        ManagedWorkspaceRemoteCleanupCoordinator.shared.start()

        if plan.startsMCPListener {
            MCPServer.shared.start { [weak self] in
                LaunchLedger.shared.record(.mcpListenerStarted)
                self?.mcpServerHasStarted = true
                self?.restoreSelectedSessionIfReady()
            }
        }

        // Remote access is a separate loopback server behind a tunnel, independent of the MCP
        // listener — no ordering dependency, and it starts only if the user has turned it on.
        let remoteAccess = RemoteAccessCoordinator.shared
        remoteAccess.installTerminalApplication(environment.remoteTerminals)
        remoteAccess.sessionCommands = self
        remoteSessionEvents.observe(SessionArchivedStateDidChange.self) { [weak self] event in
            self?.refreshAfterRemoteSessionMutation(
                sessionID: event.sessionID,
                archived: event.isArchived
            )
        }
        remoteAccess.startIfEnabled()

        // Who takes the marks made on an image nobody else claimed. Installed here rather than
        // reached for from the design system: `MediaInspector` draws pictures and knows nothing
        // about sessions or composers, and this is the one place that knows both. A test host
        // never reaches this line, so a fixture that opens an image is offered no annotation
        // mode and needs no session.
        MediaInspectorPresenter.defaultAnnotationHost = { window in
            guard let controller = window?.windowController as? MainWindowController else {
                return nil
            }
            guard let sessionID = controller.currentSessionID else { return nil }
            return ChatImageAnnotationHost(sessionID: sessionID)
        }

        // The disk survey runs itself from here on, at background priority and on its own
        // delay — it is the least urgent thing the app does, and the Storage page is only ever
        // reading what it has already found.
        ArtifactScanService.shared.startPassiveScanning()

        // Project composition and bounded Git activity run on independent utility queues. They
        // are cheap enough to prepare shortly after launch and never hold the main actor.
        ProjectStatsService.shared.startPassiveScanning()

        // Replaces names the old agent-name scheme left behind ("Claude Code 2") with what
        // transcripts still hold, then reconciles Codex rows with its canonical session index.
        // The latter also catches a rename made while Threading was closed.
        SessionNaming.backfillLegacyNames()
        SessionNaming.refreshProviderTitlesAtLaunch()
    }

    /// Bridges the vendored terminal engine into the app's privacy-enforced logging boundary.
    /// SwiftTerm events carry only stable codes and structural integers; terminal bytes, rendered
    /// text, titles, paths and arbitrary errors cannot be represented by the event type.
    private func configureSwiftTermDiagnostics() {
        SwiftTermDiagnostics.installHandler { event in
            let code = event.code.rawValue
            let facts = String(describing: event.facts)
            let suppressed = event.suppressedCount

            switch event.severity {
            case .debug:
                ThreadingLogger.terminal.debug(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            case .info:
                ThreadingLogger.terminal.info(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            case .notice:
                ThreadingLogger.terminal.notice(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            case .warning:
                ThreadingLogger.terminal.warning(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            case .error:
                ThreadingLogger.terminal.error(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            case .fault:
                ThreadingLogger.terminal.fault(
                    "SwiftTerm code=\(code, privacy: .public) facts=\(facts, privacy: .public) suppressed=\(suppressed, privacy: .public)"
                )
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A lock-losing instance quits without touching the stores: even *instantiating*
        // ProjectStore writes projects.json once, which is the exact clobber the lock exists
        // to prevent. The launch marker is the same shape of hazard in the other direction —
        // removing it here would tell the *running* instance's next launch that its crash was a
        // clean quit — so `EventLog` enforces that one too, by refusing to end a launch this
        // process never began.
        guard ownsSingleInstanceLock else { return .terminateNow }

        // Stopped on every path out of the owning process, including the startup fixture's:
        // a beat written while the app is tearing down says the main thread is turning for a
        // launch that is nearly gone.
        SingleInstanceHeartbeat.shared.stop()

        // The startup fixture returns before any agent, extension or background service is
        // started. Running their ordinary shutdown graph would construct idle singletons and
        // wait on stop paths solely to exit a measurement process. Close only the launch facts
        // it did open; AppKit still performs an orderly process termination and releases the
        // single-instance lock.
        if runsStartupProfile {
            MainThreadStallMonitor.shared.stop()
            MetricKitDiagnostics.shared.stop()
            EventLog.shared.endLaunch(detail: ["runningSessions": "0"])
            LaunchLedger.shared.endLaunch(.clean, systemInitiated: false)
            return .terminateNow
        }

        let quitAnswer = confirmQuitIfAgentsRunning()
        guard quitAnswer.quits else { return .terminateCancel }

        // Projects are persisted by ProjectStore as they change, but a coalesced write may
        // still be pending, so it is flushed before the agents are torn down.
        //
        // **Neither happens in recovery, and the second is the one that matters.** Nothing was
        // running, so the list this would write is empty — and writing an empty list over the
        // record left by the last clean quit is how a user who dropped into recovery to look at
        // something loses the sessions the *next* normal launch was going to bring back. The
        // record is not consumed in recovery either (`relaunchSessionsFromLastQuit` hangs off the
        // MCP listener's callback, which never runs), so leaving it untouched is what preserves
        // it end to end.
        var runningSessionIDs: [SessionID] = []
        var preservedRunningSessionRecord = false
        if launchPlan.recordsRunningSessionsOnQuit {
            ProjectStore.shared.flushPendingSave()
            // What is live right now, recorded for the next launch to bring back — necessarily
            // ahead of `terminateAll`, after which nothing is. `AppRelaunch` exits without
            // running this on purpose: a reset comes back to nothing running.
            runningSessionIDs = Array(AgentRuntime.shared.runningSessionIDs)
            // The same hazard the recovery note above describes, through a different door: a
            // launch that quits again before it ever read the record has nothing running *and*
            // nothing to say, and writing its emptiness over a real list is how the sessions from
            // the last real quit stop coming back for good. An empty write is only honest once
            // this launch has spent the record it is replacing.
            if !runningSessionIDs.isEmpty || StateManager.shared.hasConsumedRunningSessionIDs {
                StateManager.shared.saveRunningSessionIDs(runningSessionIDs)
            } else {
                preservedRunningSessionRecord = true
            }
        }
        activeTurnSleepInhibitor?.stop()
        activeTurnSleepInhibitor = nil
        // Host-backed sessions are handed to `threading-ptyd` rather than ended: their children
        // belong to the daemon and outlive this process, and the screen and mode seeds only this
        // process can compute are what make the next launch's replay exact rather than a cut.
        // Necessarily ahead of `terminateAll`, which would otherwise kill exactly these children,
        // and after the record above, which stays the truth for the degraded path.
        //
        // Unless the user answered "stop them and quit", which is the whole point of the third
        // button: the children are ended here, so the detach below finds nothing left to hand
        // over. It runs *after* the running-sessions record above on purpose — a session the user
        // stopped at the quit is still a session the next launch should offer to bring back, and
        // that is exactly what the record is for.
        if quitAnswer == .stopEverything {
            AgentRuntime.shared.terminateHostBackedSessions()
        }
        AgentRuntime.shared.detachHostBackedSessions()
        AgentRuntime.shared.terminateAll()
        ExtensionManager.shared.terminateAll()
        // Stops the tunnel child and closes remote sockets before the listeners go, so nothing
        // spawned for remote access outlives the app.
        RemoteAccessCoordinator.shared.stop()
        ExtensionHostService.shared.stop()
        MCPServer.shared.stop()

        // Last, and only on this path: the marker it removes is what distinguishes a quit
        // from a launch that never came back. The count it carries is the one number that says
        // whether the next launch has anything to bring back — a quit that recorded nothing and
        // a launch that relaunched nothing are indistinguishable from either side otherwise,
        // which is how a whole feature stayed invisibly broken.
        MainThreadStallMonitor.shared.stop()
        MetricKitDiagnostics.shared.stop()
        EventLog.shared.endLaunch(detail: [
            "runningSessions": String(runningSessionIDs.count),
            // Said out loud because the two empty quits differ: one records that nothing was
            // running, the other declines to record anything at all.
            "recordPreserved": preservedRunningSessionRecord ? "yes" : "no"
        ])
        // The same fact in the ledger, and the ten-minute stability timer cancelled with it: a
        // timer left armed on a queue that is about to stop being drained would either never fire
        // or fire into a half-torn-down app, and neither is a launch certifying itself stable.
        // `systemInitiated` is carried because a logout that outran the quit is the one clean
        // ending that can also look abrupt.
        LaunchLedger.shared.endLaunch(.clean, systemInitiated: isSystemInitiatedQuit)

        return .terminateNow
    }

    /// Whether the quit may go ahead.
    ///
    /// A session outliving its terminal is the app's premise, so quitting is nearer to closing
    /// a session than to deleting one: the conversations are kept and resume on the next launch,
    /// and only the turn in flight is lost. That is what makes the prompt suppressible, and it is
    /// also why it stays quiet when nothing is running — a confirmation on every quit would be
    /// asking about nothing most of the time, which is how a prompt teaches people to dismiss it.
    @MainActor
    private func confirmQuitIfAgentsRunning() -> QuitAnswer {
        guard !isSystemInitiatedQuit else { return .leaveRunning }

        // A host-backed session keeps running through the quit, so counting it among what closes
        // would have this sheet announce a loss that does not happen — that message says every
        // open session closes and only work in flight is lost, and neither is true of one the
        // daemon keeps. It is counted separately, and the question grows a third answer.
        let background = AgentRuntime.shared.hostBackedSessionIDs
        let ending = AgentRuntime.shared.runningSessionIDs.subtracting(background)
        guard !ending.isEmpty || !background.isEmpty else { return .leaveRunning }

        return ask(Self.quitConfirmation(
            runningSessionCount: ending.count,
            inFlightTurnCount: AgentRuntime.shared.inFlightTurnCount(among: ending),
            backgroundSessionCount: background.count
        ))
    }

    /// Puts the question up and reads the answer back.
    ///
    /// The choice is not suppressible — a remembered answer has to be *an* answer, and a box
    /// beside three of them says nothing about which one it would repeat — but the switch the
    /// user already has, on the two-answer question, covers this moment too and is honoured here:
    /// it resolves to `.leaveRunning`, the answer that ends nothing. Somebody who asked not to be
    /// interrupted at a quit did not ask for their agents to be stopped, and the one thing a
    /// suppressed prompt must never do is pick the destructive branch on their behalf.
    @MainActor
    private func ask(_ question: QuitQuestion) -> QuitAnswer {
        switch question {
        case .confirms(let request):
            return ConfirmationAlert.ask(request) ? .leaveRunning : .cancel
        case .chooses(let request):
            guard AppSettings.shared.asks(before: .quitWithRunningAgents) else {
                return .leaveRunning
            }
            return question.answer(atIndex: ConfirmationAlert.choose(request))
        }
    }

    /// Built separately from being asked, so a test can hold the wording to what quitting does
    /// without a modal — the seam `SessionCoordinator`'s lifecycle requests already offer.
    ///
    /// **The count and the noun are separate decisions**, and saying "6 agents still running"
    /// got the first right and the second wrong. Every one of those six was a live process, and
    /// the sidebar agreed — but four were idle at their prompt and two were merely unread, so
    /// nothing was in flight and the sheet was announcing a loss that did not exist. A session
    /// outliving its terminal is the premise here; what a quit actually costs is the turns being
    /// written, which is what the title leads with when there are any.
    static func quitConfirmation(
        runningSessionCount: Int,
        inFlightTurnCount: Int
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .quitWithRunningAgents,
            title: quitTitle(
                runningSessionCount: runningSessionCount,
                inFlightTurnCount: inFlightTurnCount
            ),
            message: inFlightTurnCount == 0
                ? L10n.string(
                    "Nothing is in flight. The sessions close, and their conversations are kept "
                        + "and can be resumed on the next launch."
                )
                : L10n.string(
                    "Every open session closes. The conversations are kept and can be resumed "
                        + "on the next launch; only work in flight is lost."
                ),
            confirmTitle: L10n.string("Quit")
        )
    }

    /// The same seam once `threading-ptyd` is in the picture, and the reason it is an overload
    /// rather than a third parameter with a default: with no host-backed session this **calls**
    /// the two-answer builder above, so "the wording did not change for a launch without the
    /// background host" is true by construction rather than by two copies being kept in step.
    ///
    /// `runningSessionCount` is the sessions that *close* — the daemon cannot host them, or the
    /// session opted out, or there is no daemon — and `inFlightTurnCount` counts turns among
    /// those only. A turn being written in a session the daemon keeps is not lost by quitting.
    static func quitConfirmation(
        runningSessionCount: Int,
        inFlightTurnCount: Int,
        backgroundSessionCount: Int
    ) -> QuitQuestion {
        guard backgroundSessionCount > 0 else {
            return .confirms(quitConfirmation(
                runningSessionCount: runningSessionCount,
                inFlightTurnCount: inFlightTurnCount
            ))
        }
        return .chooses(QuitChoiceCopy.request(
            backgroundSessionCount: backgroundSessionCount,
            closingSessionCount: runningSessionCount,
            inFlightTurnCount: inFlightTurnCount
        ))
    }

    /// Names the turns when there are any, and the sessions otherwise — the two facts cost the
    /// user different things, so one title cannot carry both without overstating the quieter one.
    private static func quitTitle(runningSessionCount: Int, inFlightTurnCount: Int) -> String {
        if inFlightTurnCount > 0 {
            return inFlightTurnCount == 1
                ? L10n.string("Quit with one turn in flight?")
                : L10n.format("Quit with %lld turns in flight?", Int64(inFlightTurnCount))
        }

        return runningSessionCount == 1
            ? L10n.string("Quit with one session open?")
            : L10n.format("Quit with %lld sessions open?", Int64(runningSessionCount))
    }

    // MARK: - Onboarding

    /// Completion in load-bearing order: record, **show the main window, then close the
    /// walkthrough**. During first launch the walkthrough is the last window, and
    /// `applicationShouldTerminateAfterLastWindowClosed` answers true — closing it first
    /// would quit the app on the final click of its own setup.
    private func onboardingDidFinish() {
        OnboardingState.markCompleted()
        EventLog.shared.record(.app, "Onboarding completed")

        mainWindowController?.showWindow(nil)
        onboardingWindowController?.close()
        onboardingWindowController = nil
        isOnboardingActive = false
        NSApp.activate(ignoringOtherApps: true)

        agentCLIUpdateCoordinator?.presentationMayBeReady()
        restoreSelectedSessionIfReady()
    }

    /// Restores the selected session once *both* prerequisites hold: the MCP listener (a
    /// launch reads its port for `--mcp-config`) and a main window actually on screen (a
    /// terminal must be installed in a laid-out, visible view — restoring into the window
    /// onboarding is still deferring would launch a PTY into a never-shown pane).
    ///
    /// The gate answers *when*; `LaunchRestoration` answers **how much**. After an unclean
    /// previous exit the two workspace paths are held back and offered in a notice instead —
    /// and because the offer hangs off this same gate, it cannot appear over the walkthrough,
    /// in a hosted test bundle, or in an instance that lost the single-instance lock, none of
    /// which ever reach here.
    private func restoreSelectedSessionIfReady() {
        // Recovery never reaches here today — its only two callers are the MCP listener's start
        // callback, which recovery does not start, and the walkthrough's completion, which
        // recovery does not run. Stated anyway, because this is where a future third caller would
        // arrive, and what hangs off this gate is every restoration path plus both
        // scheduled-message services.
        guard launchPlan.restoresWorkspace else { return }
        guard mcpServerHasStarted,
              pendingCheckoutMovesHaveSettled,
              !isOnboardingActive else { return }
        let plan = launchRestoration.run(
            previousLaunch: EventLog.shared.previousLaunchOutcome,
            escalation: UncleanExitEscalation(decision: launchDecision)
        )
        LaunchLedger.shared.record(.selectedSessionRestored, detail: [
            StartupCheckpointDefaults.restorationField: plan == .restoresEverything
                ? StartupCheckpointDefaults.restorationRestored
                : StartupCheckpointDefaults.restorationHeldBack
        ])

        // Behind this gate rather than in `applicationDidFinishLaunching`, and for the same two
        // reasons the relaunch is: a scheduled start reads the MCP port for `--mcp-config`, and
        // one that fired into the window onboarding is still deferring would put a PTY in a pane
        // nobody will ever see. Its first act is to settle what the clock passed while the app
        // was not running — which it reports, and never sends.
        ScheduledMessageNotifier.shared.start()
        ScheduledMessageScheduler.shared.start()
    }

    /// The walkthrough on request — Settings ▸ Advanced. The main window is already visible,
    /// so completion's `showWindow` is a no-op and nothing needs deferring; `isOnboardingActive`
    /// stays false and the import page simply offers whatever is not yet tracked.
    func presentOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController { [weak self] in
                self?.onboardingDidFinish()
            }
        }
        onboardingWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A hosted XCTest bundle runs inside the real application and creates short-lived
        // windows for rendering and chrome tests. Closing one must not terminate the host
        // process underneath whatever test XCTest scheduled next.
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // There is a window only in an instance that actually started up — and two that never
        // do still run a real `NSApplication` with a real delegate: a hosted test bundle, and a
        // second instance that lost the single-instance lock. The system sends this whenever the
        // Dock icon is clicked, so the force-unwrap that used to be here was a crash waiting for
        // a click. It found one, in the middle of a test run that was pumping the main run loop.
        guard let mainWindowController else { return true }

        // Mid-walkthrough, a Dock click re-fronts the walkthrough. Without this it would
        // surface the deferred main window over the setup that is not finished with it.
        if isOnboardingActive {
            onboardingWindowController?.showWindow(nil)
            return true
        }

        // The main window's own visibility, not `flag`. The system's flag answers "is *any*
        // window visible", which stops being the same question the moment the app has a second
        // one: with the main window miniaturized behind a visible auxiliary window — the
        // component gallery today, a detached browser window later — a Dock click reported
        // `flag == true` and did nothing at all, which is the one gesture whose whole purpose is
        // to bring the app back. A miniaturized window reports `isVisible == false`, which is
        // exactly the case that should re-front it.
        if mainWindowController.window?.isVisible != true {
            mainWindowController.showWindow(nil)
        }
        return true
    }

    /// What the app icon does with what is dropped on it: a folder becomes a project, and a
    /// picture opens the report sheet on it (`DroppedScreenshotReport`).
    ///
    /// Two meanings for one target, told apart by what the file *is* rather than by a mode. They
    /// do not compete: nobody drops a screenshot meaning to add its enclosing folder, and a
    /// screenshot is the one file type this app has a second obvious thing to do with.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Same reachability, worse consequence: *instantiating* `ProjectStore` writes
        // projects.json, which is the exact clobber the lock exists to prevent — so an instance
        // that does not own the state does not adopt folders into it either.
        guard ownsSingleInstanceLock else { return }

        // Launch Services delivers a Dock-icon drop from inside CoreDrag's completion callback.
        // Activating the app or presenting a sheet before that callback unwinds re-enters the
        // process drag manager; on macOS 26 one such re-entry leaves later drags reporting a
        // completed transaction and no usable drag reference. Cross the run-loop boundary once
        // so CoreDrag can finish before any dropped URL mutates application or window state.
        AppIconDropDelivery.afterDragCompletion { [weak self] in
            guard let self, self.ownsSingleInstanceLock else { return }
            self.openDroppedURLs(urls)
        }
    }

    private func openDroppedURLs(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                ProjectStore.shared.addProject(folderURL: url)
                continue
            }
            guard DroppedScreenshotReport.isReportable(url) else { continue }
            // A drop on the Dock icon usually arrives while Threading is behind whatever the
            // person just photographed, and a sheet nobody can see is not a report being filed.
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.presentDroppedScreenshotReport(at: url, from: .appIcon)
        }
    }

    /// Brings a remotely selected dormant session back on its configured surface. Going
    /// through the window's ordinary selection path preserves the one-live-process invariant,
    /// but deliberately does not activate the app: a phone should not steal focus from whoever
    /// is using the Mac merely because it reopened a session.
    @MainActor
    func resumeRemoteSession(_ sessionID: SessionID) -> Bool {
        guard ownsSingleInstanceLock,
              ProjectStore.shared.session(withID: sessionID) != nil,
              let mainWindowController else {
            return false
        }
        mainWindowController.resumeRemoteSession(sessionID)
        return true
    }

    @MainActor
    func resumeRemoteTerminal(_ terminalID: TerminalID) -> Bool {
        guard ownsSingleInstanceLock,
              ProjectStore.shared.terminal(withID: terminalID) != nil,
              let mainWindowController else {
            return false
        }
        mainWindowController.resumeRemoteTerminal(terminalID)
        return true
    }

    @MainActor
    func moveRemoteSession(
        _ sessionID: SessionID,
        to accountHandle: AccountHandle
    ) -> Result<Void, RemoteSessionAccountMoveFailure> {
        guard ownsSingleInstanceLock, let mainWindowController else {
            return .failure(.appUnavailable)
        }
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            return .failure(.sessionNotFound)
        }
        guard session.kind.supportsAccounts else {
            return .failure(.unsupportedRuntime)
        }
        guard session.accountHandle != accountHandle else { return .success(()) }
        guard let account = AgentAccountDiscovery.accounts(for: session.kind).first(where: {
            $0.handle == accountHandle
        }) else {
            return .failure(.accountNotFound)
        }

        switch SessionMigration.move(sessionID: sessionID, to: account) {
        case .success:
            mainWindowController.refreshAfterRemoteSurfaceMutation(sessionID: sessionID)
            return .success(())
        case .failure(let error):
            return .failure(.moveRefused(error.code))
        }
    }

    /// Continues a conversation on another provider on behalf of a paired iPhone.
    ///
    /// Unlike the Mac's own menu path this never selects the destination: a phone asking for a
    /// new chat must not move the selection of whoever is using the Mac. The source's pane is
    /// reopened either way, because freezing its transcript stopped its process — the same
    /// reconciliation the account move performs, and for the same reason.
    ///
    /// Nothing seeds the destination's opening turn here. That bootstrap is regenerated from the
    /// session's own lineage when it first launches, so a chat created from a phone and opened
    /// hours later on either device still reads its snapshot.
    @MainActor
    func continueRemoteSession(
        _ sessionID: SessionID,
        with destination: RemoteContinuationTarget,
        completion: @escaping @MainActor @Sendable (
            Result<SessionID, RemoteSessionContinuationFailure>
        ) -> Void
    ) {
        guard ownsSingleInstanceLock, mainWindowController != nil else {
            completion(.failure(.appUnavailable))
            return
        }
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            completion(.failure(.sessionNotFound))
            return
        }
        guard let account = RemoteContinuationBridge.account(
            for: destination,
            continuing: session
        ) else {
            completion(.failure(.destinationNotFound))
            return
        }

        ConversationContinuation.create(from: sessionID, to: account) { [weak self] result in
            self?.mainWindowController?.refreshAfterRemoteSurfaceMutation(sessionID: sessionID)
            switch result {
            case let .success(created):
                completion(.success(created.id))
            case let .failure(error):
                completion(.failure(.continuationRefused(error.code)))
            }
        }
    }

    @MainActor
    func startRemoteSession(_ launch: RemoteSessionLaunch) -> SessionID? {
        guard ownsSingleInstanceLock, let mainWindowController else { return nil }
        return mainWindowController.startRemoteSession(
            in: launch.projectID,
            kind: launch.kind,
            accountHandle: launch.accountHandle,
            model: launch.model,
            reasoningEffort: launch.reasoningEffort,
            fastMode: launch.fastMode,
            permissionMode: launch.permissionMode,
            usesNativeUI: launch.usesNativeUI,
            managedWorkspacePlan: launch.managedWorkspacePlan,
            role: launch.role,
            openingAttachmentPaths: launch.openingAttachmentPaths,
            prompt: launch.prompt
        )?.id
    }

    @MainActor
    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool) {
        guard ownsSingleInstanceLock, let mainWindowController else { return }
        mainWindowController.refreshAfterRemoteSessionMutation(
            sessionID: sessionID,
            archived: archived
        )
    }

    @MainActor
    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID) {
        guard ownsSingleInstanceLock, let mainWindowController else { return }
        mainWindowController.refreshAfterRemoteSurfaceMutation(sessionID: sessionID)
    }

    // MARK: - Private Methods — The Launch Ledger

    /// Records the readiness checkpoint, once the run loop has proved the launch survived it.
    ///
    /// **A window is on screen plus one run-loop turn.** Ordering a window front is a call that
    /// returns whether or not anything comes of it; what says the app got up is the run loop
    /// draining the next turn, and a block enqueued here is the cheapest honest proof of that —
    /// a launch that dies inside its own turn never reaches this handler. Whichever window it
    /// was: on a first launch the walkthrough is the app, and an app showing its walkthrough
    /// started successfully.
    ///
    /// It is also where the ten-minute stability timer is armed, because that is the clock this
    /// checkpoint starts — **except in recovery**. `stable` is a claim that the app works, and a
    /// launch that started nothing has not made it; arming it there would mean sitting in
    /// recovery for ten minutes erases the crash-loop count that put the user in it.
    private func noteFirstWindowVisible(armsStability: Bool) {
        DispatchQueue.main.async {
            LaunchLedger.shared.record(.firstWindowVisible)
            guard armsStability else { return }
            LaunchLedger.shared.armStabilityCheckpoint()
        }
    }

    /// Whether Option is held right now.
    ///
    /// The class property rather than an event: at `applicationDidFinishLaunching` no key event
    /// has been delivered to the app, so there is nothing to inspect — this is the documented way
    /// to ask what is held at this instant. It also needs no accessibility grant, unlike a
    /// `CGEventTap`, so the manual way into recovery costs the user no new permission.
    ///
    /// Read once and passed to the resolver, never re-read: the answer must be a fact about the
    /// launch rather than about whenever something happened to ask.
    private static func isOptionHeldAtLaunch() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// Puts the recovery surface in the window, and records that it got there.
    ///
    /// One run-loop turn after the window, the readiness checkpoint's own proof: a launch that
    /// dies drawing this screen never reaches the handler, which is precisely the case the
    /// checkpoint exists to make visible.
    @MainActor
    private func presentRecoveryMode(on windowController: MainWindowController) {
        MacRemoteDiagnostics.record(.recoveryModeEntered, level: .warning, fields: [
            .reason: launchPlan.reason.rawValue,
            .surface: "recoveryMode",
        ])
        windowController.presentRecoveryMode(
            reason: launchPlan.reason,
            checkpoint: launchDecision.lastReachedCheckpoint,
            crashReport: launchCrashReport,
            extensionsDisabledNextLaunch: LaunchFlagsStore.shared
                .read()
                .disableExtensionsNextLaunch,
            actions: recoveryActions(on: windowController)
        )
        DispatchQueue.main.async {
            LaunchLedger.shared.record(.recoverySurfaceShown)
        }
    }

    /// Each offer wired to the primitive that performs it, and nothing else.
    ///
    /// Built here because this is where the launch's own facts are, and handed to the window as
    /// closures so the screen can be pressed in a test without relaunching the app or moving
    /// anybody's data.
    @MainActor
    private func recoveryActions(on windowController: MainWindowController) -> RecoveryModeActions {
        RecoveryModeActions(
            tryNormalLaunchOnce: { [weak self] in
                self?.tryNormalLaunchOnce()
            },
            continueInRecoveryMode: { [weak windowController] in
                // Not a relaunch: nothing needs restarting to carry on doing less. The band
                // stays, so the surface is one press away for the rest of the launch.
                windowController?.dismissRecoverySurface()
            },
            toggleExtensionsForNextLaunch: { [weak self] in
                self?.toggleExtensionsForNextLaunch(on: windowController)
            },
            resetWindowLayout: {
                WindowLayoutReset.perform()
            },
            createSupportReport: { [weak self] in
                self?.createRemoteSupportReport()
            },
            moveAppDataAside: { [weak self] in
                self?.moveAppDataAsideFromRecovery()
            },
            revealCrashReport: { [weak self] in
                guard let report = self?.launchCrashReport else { return }
                NSWorkspace.shared.activateFileViewerSelecting([report])
            }
        )
    }

    /// Arms the one-shot and restarts. The flag is what the *next* launch reads; nothing about
    /// this process changes, because a mode is decided at launch and stays decided.
    @MainActor
    private func tryNormalLaunchOnce() {
        let relaunch: AppRelaunch.PreparedRelaunch
        do {
            relaunch = try AppRelaunch.prepare()
        } catch {
            presentRelaunchFailure(error)
            return
        }

        LaunchFlagsStore.shared.set(
            .forceNormalNextLaunch,
            armed: true,
            launchID: EventLog.shared.currentLaunchID
        )
        do {
            try relaunch.commit(reason: .recoveryRelaunch)
        } catch {
            // The one-shot belongs to the relaunch this button requested. If that relaunch did
            // not get out of this process, leaving it armed would make some later ordinary
            // launch unexpectedly bypass recovery mode.
            LaunchFlagsStore.shared.set(
                .forceNormalNextLaunch,
                armed: false,
                launchID: EventLog.shared.currentLaunchID
            )
            presentRelaunchFailure(error)
        }
    }

    @MainActor
    private func presentRelaunchFailure(_ error: Error) {
        ThreadingLogger.agent.error(
            "Relaunch failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
        )
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Try Normal Launch Once")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.string("OK"))
        alert.runModal()
    }

    /// Arms or disarms the second one-shot, and rebuilds the surface so its button says which.
    ///
    /// **It never touches `enabledIdentifiers`.** That is what makes "for the next launch only"
    /// true by construction rather than by a promise: no extension is disabled, so there is no
    /// state for a later launch to inherit.
    @MainActor
    private func toggleExtensionsForNextLaunch(on windowController: MainWindowController) {
        let store = LaunchFlagsStore.shared
        let armed = !store.read().disableExtensionsNextLaunch
        store.set(
            .disableExtensionsNextLaunch,
            armed: armed,
            launchID: EventLog.shared.currentLaunchID
        )
        windowController.installRecoverySurface(
            reason: launchPlan.reason,
            checkpoint: launchDecision.lastReachedCheckpoint,
            crashReport: launchCrashReport,
            extensionsDisabledNextLaunch: store.read().disableExtensionsNextLaunch,
            actions: recoveryActions(on: windowController)
        )
    }

    /// The recoverable reset, from the crash screen rather than from a settings page.
    ///
    /// The same flow Advanced takes, wording and all: a reset performed here has exactly the
    /// blast radius it has there, and a second sentence describing it would eventually describe
    /// something else.
    @MainActor
    private func moveAppDataAsideFromRecovery() {
        let request = ConfirmationRequest(
            prompt: .resetAppData,
            title: AdvancedStrings.confirmEverythingTitle,
            message: AdvancedStrings.confirmEverythingBody,
            confirmTitle: AdvancedStrings.resetEverythingButton,
            cancelTitle: L10n.string("Cancel")
        )
        guard ConfirmationAlert.ask(request) else { return }

        do {
            try AppDataResetFlow.perform(.everything)
        } catch {
            ThreadingLogger.app.error(
                "Reset failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            let alert = ThemedAlert()
            alert.alertStyle = .warning
            alert.messageText = AdvancedStrings.resetFailedTitle
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        }
    }


    /// Puts the launch's own verdict in the journal, beside the crash it is about.
    ///
    /// Journalled rather than merely held, for the reason every other launch fact here is: a
    /// support report that says the app decided it was in a crash loop is a different report from
    /// one that says it decided nothing, and by the time anyone asks, the ledger has this
    /// launch's records in it too.
    /// The mode and its reason go in the *same* record as the decision, deliberately: what a
    /// report is asked afterwards is "why did it come up like that", and a decision in one line
    /// with the mode in another is two facts a reader has to join by timestamp.
    private func journal(
        _ decision: CrashLoopDecision,
        ledger: LaunchLedgerRead,
        resolution: LaunchModeResolution,
        flags: LaunchFlags
    ) {
        var detail = [
            CrashLoopDefaults.decisionField: decision.token,
            CrashLoopDefaults.ledgerField: ledger.token,
            LaunchModeDefaults.resolutionField: resolution.mode.rawValue,
            LaunchModeDefaults.reasonField: resolution.reason.rawValue,
            LaunchModeDefaults.flagsField: flags.token
        ]
        if let checkpoint = decision.lastReachedCheckpoint {
            detail[CrashLoopDefaults.checkpointField] = checkpoint.rawValue
        }
        EventLog.shared.record(.app, CrashLoopDefaults.decisionMessage, detail)
    }

    // MARK: - Private Methods

    /// Installs the optional UI customization seam before the first sidebar row is built.
    ///
    /// The registry starts empty. The tokenized extension host service writes accepted process
    /// publications into it; tests and the Component Gallery use the same provider boundary
    /// without opening IPC.
    @MainActor
    private func installComponentCustomizationProvider() {
        let registry = ComponentCustomizationRegistry(selectionDefaults: .standard)
        do {
            for contract in HostComponentContracts.all {
                try registry.register(contract)
            }
        } catch {
            ThreadingLogger.extensions.fault(
                "Host component contract registration failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            assertionFailure("Invalid host component contract: \(error)")
            ComponentCustomizationProviderSlot.shared.provider = nil
            return
        }

        componentCustomizationRegistry = registry
        ComponentCustomizationProviderSlot.shared.provider = registry
        ComponentCustomizationProviderSlot.shared.actionHandler = { action in
            ExtensionManager.shared.invokeComponentAction(action)
        }
    }

    /// Creates the public navigator fact plane only for launches that allow extensions. The
    /// caller is below the startup-profile return and after the first window has been ordered;
    /// the pipeline crosses one more main-queue turn before doing its bounded initial snapshot.
    @MainActor
    private func installHostFactPipeline() -> HostFactPipeline {
        let source = LiveHostFactProjectionSource.live(
            projectStore: environment.projectStore,
            agentRuntime: environment.agentRuntime
        )
        let pipeline = HostFactPipeline(
            publisherDependencies: source.publisherDependencies()
        )
        hostFactPipeline = pipeline
        pipeline.startAfterFirstWindowVisible()
        return pipeline
    }

    // MARK: - Single Instance Triage

    /// What this launch does about a lock it could not take.
    ///
    /// Returns `true` only when a takeover actually acquired the lock, in which case the caller
    /// carries on with an ordinary launch. Every other path either quits quietly, because the
    /// owner has been brought to the front and there is nothing to say, or puts up an alert
    /// first. See `docs/architecture/crash-recovery.md`.
    private func resolveLostSingleInstanceLock() -> Bool {
        let card = SingleInstanceLock.readOwnerCard()
        let verdict = SingleInstanceTriage.verdict(
            card: card,
            ownerIdentity: card.map { SingleInstanceTriage.identity(of: $0) } ?? .unreadable,
            heartbeatAge: SingleInstanceHeartbeat.age()
        )

        switch verdict {
        case .activateOwner(let pid, let bundlePath):
            guard !Self.activateOwner(pid: pid) else { return false }
            presentAlreadyRunningAlert(ownerBundlePath: bundlePath)
            return false

        case .orphanedLockHolders(let ownerPID, let bundlePath):
            return releaseOrphanedSingleInstanceLock(ownerPID: ownerPID, bundlePath: bundlePath)

        case .alertOnly(let refusal):
            ThreadingLogger.app.notice(
                "Single-instance triage refused a takeover: \(refusal.rawValue, privacy: .public)"
            )
            // An owner from before this mechanism existed says nothing about itself, so the
            // courtesy is the one thing the *system* can still answer: bring whatever else is
            // running under our identifier to the front. It is not evidence of anything — the
            // stray copy in DerivedData shares the identifier too — so nothing destructive
            // hangs off it.
            if refusal == .noOwnerCard, Self.activateOwnerByBundleIdentifier() { return false }
            presentAlreadyRunningAlert(ownerBundlePath: card?.bundlePath)
            return false

        case .offerTakeover(let pid, let bundlePath, let staleness):
            guard let card, confirmSingleInstanceTakeover(staleness: staleness) else {
                return false
            }
            return performSingleInstanceTakeover(
                card: card,
                pid: pid,
                bundlePath: bundlePath,
                staleness: staleness
            )
        }
    }

    private func performSingleInstanceTakeover(
        card: SingleInstanceOwnerCard,
        pid: pid_t,
        bundlePath: String,
        staleness: TimeInterval
    ) -> Bool {
        switch SingleInstanceTakeover.run(owner: card, actions: SingleInstanceTakeover.live) {
        case .acquired(let escalated):
            singleInstanceTakeover = SingleInstanceTakeoverRecord(
                pid: pid,
                bundlePath: bundlePath,
                staleness: staleness,
                escalated: escalated
            )
            return true

        case .ownerRecovered:
            // It beat while the alert was on screen. Nothing was signalled, and the user's
            // original intent — open Threading — is served by the instance that is already here.
            guard !Self.activateOwner(pid: pid) else { return false }
            presentAlreadyRunningAlert(ownerBundlePath: bundlePath)
            return false

        case .identityUnverified, .lockStillHeld:
            presentTakeoverFailedAlert(ownerBundlePath: bundlePath)
            return false
        }
    }

    /// The dead-owner case: the process that took the lock is gone and the lock is still held.
    ///
    /// Only one thing can do that — a duplicate of its descriptor living on in a child it
    /// spawned — and the previous launch's own agent-child ledger is the only record of which
    /// processes those are. It is read **without consuming**: the sweep that would ordinarily
    /// consume it runs after the lock is acquired, which is precisely the deadlock here, and a
    /// launch that is about to quit must not empty the list the launch that gets in will need.
    private func releaseOrphanedSingleInstanceLock(
        ownerPID: pid_t,
        bundlePath: String
    ) -> Bool {
        let holders = SingleInstanceTakeover.verifiedHolders(
            in: AgentChildLedger.shared.inheritedRecords().value
        )
        guard !holders.isEmpty else {
            presentOrphanedLockAlert(ownerPID: ownerPID, bundlePath: bundlePath)
            return false
        }
        guard ConfirmationAlert.ask(Self.orphanedLockReleaseConfirmation(holders: holders)) else {
            return false
        }

        let outcome = SingleInstanceTakeover.releaseOrphanedLock(records: holders) {
            SingleInstanceTakeover.pollForLock(upTo: $0)
        }

        switch outcome {
        case .acquired(let ended):
            singleInstanceTakeover = SingleInstanceTakeoverRecord(
                pid: ownerPID,
                bundlePath: bundlePath,
                staleness: 0,
                escalated: true,
                endedChildren: ended
            )
            return true
        case .nothingToEnd, .lockStillHeld:
            // Deliberately not the takeover's alert: that one says another Threading is still
            // holding the state, and the one thing known here is that no Threading is running.
            presentOrphanedLockAlert(ownerPID: ownerPID, bundlePath: bundlePath)
            return false
        }
    }

    /// Built separately from being asked, so a test can hold the wording to what ending those
    /// processes actually costs.
    static func orphanedLockReleaseConfirmation(
        holders: [AgentChildRecord]
    ) -> ConfirmationRequest {
        let names = holders.map(\.executable).sorted()
        return ConfirmationRequest(
            prompt: .endOrphanedAgentProcesses,
            title: L10n.string("Threading is not running, but its session state is still locked"),
            message: L10n.format(
                """
                A previous Threading did not shut down, and %1$lld of the agent processes it \
                started are still holding the lock on your projects: %2$@. Ending them lets this \
                Threading start. Anything they were in the middle of is lost.
                """,
                holders.count,
                ListFormatter.localizedString(byJoining: names)
            ),
            confirmTitle: L10n.string("End Them and Continue"),
            cancelTitle: L10n.string("Quit"),
            style: .critical
        )
    }

    /// The same situation with nothing left to name. Better than "already running", which is the
    /// one thing that is definitely not true here.
    private func presentOrphanedLockAlert(ownerPID: pid_t, bundlePath: String) {
        ThreadingLogger.app.error(
            "Single-instance lock is held by a descriptor its owner left behind (pid=\(ownerPID, privacy: .public)), and nothing in the child ledger still checks out"
        )
        let alert = ThemedAlert()
        alert.messageText = L10n.string(
            "Threading is not running, but its session state is still locked"
        )
        var informative = L10n.string("""
            A previous Threading did not shut down and something it started is still holding the \
            lock on your projects. Quitting those processes, or restarting the Mac, lets \
            Threading open again.
            """)
        if bundlePath != Bundle.main.bundlePath {
            informative += "\n\n" + L10n.format("The copy holding it is at %@.", bundlePath)
        }
        alert.informativeText = informative
        alert.alertStyle = .critical
        alert.runModal()
    }

    private func recordSingleInstanceTakeoverIfNeeded() {
        guard let takeover = singleInstanceTakeover else { return }
        EventLog.shared.record(
            .app,
            SingleInstanceDefaults.takeoverMessage,
            takeover.journalDetail
        )
    }

    private static func activateOwner(pid: pid_t) -> Bool {
        guard let owner = NSRunningApplication(processIdentifier: pid) else { return false }
        return owner.activate(options: [.activateAllWindows])
    }

    private static func activateOwnerByBundleIdentifier() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let ours = ProcessInfo.processInfo.processIdentifier
        guard let owner = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ours }) else { return false }
        return owner.activate(options: [.activateAllWindows])
    }

    /// The dead end this always had, now able to name the copy that is holding the lock.
    ///
    /// A path is only worth a sentence when it is not ours: "another Threading" is unhelpful
    /// when the other Threading is a Debug build sitting in DerivedData that the user has no
    /// idea is running.
    private func presentAlreadyRunningAlert(ownerBundlePath: String? = nil) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Threading is already running")
        var informative = L10n.string("""
            Another Threading is open and owns the session state. Running two at once would \
            silently overwrite each other's projects, so this one will quit.
            """)
        if let ownerBundlePath, ownerBundlePath != Bundle.main.bundlePath {
            informative += "\n\n" + L10n.format("The copy holding it is at %@.", ownerBundlePath)
        }
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// The one destructive choice this surface offers.
    ///
    /// Framed as what it costs rather than as what it fixes: the other instance is ended
    /// outright, and whatever it had in flight goes with it. Through the confirmation register
    /// like every other question the user can answer wrongly, which also puts Return on Quit.
    private func confirmSingleInstanceTakeover(staleness: TimeInterval) -> Bool {
        ConfirmationAlert.ask(Self.singleInstanceTakeoverConfirmation(staleness: staleness))
    }

    /// Built separately from being asked, so a test can hold the wording to what the takeover
    /// actually does without a modal.
    static func singleInstanceTakeoverConfirmation(
        staleness: TimeInterval
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .takeOverSingleInstanceLock,
            title: L10n.string("Threading is running but not responding"),
            message: L10n.format(
                """
                The Threading that owns the session state has not answered for %lld seconds. \
                You can end it and start this one instead. Anything it was in the middle of is \
                lost.
                """,
                Int(staleness.rounded())
            ),
            confirmTitle: L10n.string("End It and Continue"),
            cancelTitle: L10n.string("Quit"),
            style: .critical
        )
    }

    private func presentTakeoverFailedAlert(ownerBundlePath: String) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Threading could not take over the session state")
        var informative = L10n.string("""
            The other Threading is still holding the state, so this one will quit rather than \
            risk two of them writing to it.
            """)
        if ownerBundlePath != Bundle.main.bundlePath {
            informative += "\n\n" + L10n.format("The copy holding it is at %@.", ownerBundlePath)
        }
        alert.informativeText = informative
        alert.alertStyle = .critical
        alert.runModal()
    }

    /// Removes history files belonging to sessions that no longer exist.
    @MainActor
    private func cleanupOrphanedHistoryFiles() {
        // An empty project list caused by a failed load is not evidence that every history
        // file is orphaned. Preserve all histories for this launch so recovery stays possible.
        guard ProjectStore.shared.didLoadStateSuccessfully else {
            ThreadingLogger.agent.error(
                "Skipping orphaned history cleanup because project state failed to load"
            )
            return
        }

        let projects = ProjectStore.shared.projects
        let activeIdentities = Set(projects.flatMap { project in
            project.sessions.flatMap { session in
                [
                    TerminalInstanceIdentity.agentSession(session.id),
                    TerminalInstanceIdentity.sessionShell(session.id),
                ]
            } + project.terminals.map { terminal in
                TerminalInstanceIdentity.projectTerminal(terminal.id)
            }
        })
        HistoryManager.cleanupOrphanedHistoryFiles(activeIdentities: activeIdentities)
    }

    /// Retries ref collection for records whose permanent deletion was interrupted by exit.
    /// A failed project load is not evidence that every checkpoint is orphaned, just as it is
    /// not evidence that every terminal history is.
    @MainActor
    private func cleanupOrphanedTurnCheckpoints() {
        guard ProjectStore.shared.didLoadStateSuccessfully else {
            ThreadingLogger.git.error(
                "Skipping orphaned turn checkpoint cleanup because project state failed to load"
            )
            return
        }
        let projects = ProjectStore.shared.projects
        let sessionIDs = Set(projects.flatMap { $0.sessions.map(\.id) })
        let store = GitTurnBaselineStore.shared
        store.retainOnly(sessionIDs: sessionIDs)

        var checkouts = projects.map { URL(fileURLWithPath: $0.folderPath) }
        checkouts.append(contentsOf: sessionIDs.compactMap {
            ProjectStore.shared.executionProject(forSessionID: $0)
                .map { URL(fileURLWithPath: $0.folderPath) }
        })
        store.garbageCollectOrphanedRefs(in: checkouts)
    }

    // MARK: - Menu Setup

    // MARK: - Command Bindings

    /// The menu items whose key equivalent comes from `CommandRegistry`, kept so a rebinding can be
    /// applied to them directly.
    ///
    /// Re-applying beats rebuilding the menu bar: `setupMenuBar` also re-points `NSApp.windowsMenu`
    /// and `NSApp.helpMenu`, and running all of that again to change one character is both more
    /// work and more ways to be wrong.
    private var commandItems: [String: NSMenuItem] = [:]
    private var extensionMenu: NSMenu?
    private var projectScriptsSeparator: NSMenuItem?
    private var projectScriptsItem: NSMenuItem?
    private var projectExtensionSeparator: NSMenuItem?
    private var projectExtensionItem: NSMenuItem?
    private var viewExtensionSeparator: NSMenuItem?
    private var viewExtensionItem: NSMenuItem?
    private var currentThemeMenuItem: NSMenuItem?

    /// Holds the shortcut-change subscription for the process lifetime.
    private let menuEvents = AppEventObservations()

    /// Builds a menu item that takes its shortcut from the command table instead of a literal.
    private func commandItem(_ id: String, action: Selector) -> NSMenuItem {
        guard let command = CommandRegistry.shared.command(id: id) else {
            return NSMenuItem(title: id, action: action, keyEquivalent: "")
        }

        let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
        // Stamped so `validateMenuItem` can ask the recovery policy by id in one lookup. The
        // extension items already carry theirs the same way, and our actions differ from
        // `performExtensionCommand`, so the two uses cannot be confused for each other.
        item.representedObject = id
        apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
        commandItems[id] = item
        return item
    }

    private func apply(_ shortcut: KeyboardShortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    /// Re-reads every bound item. Called on the change event, so a shortcut edited in Settings
    /// works immediately rather than after a relaunch.
    func applyShortcutBindings() {
        for (id, item) in commandItems {
            guard let command = CommandRegistry.shared.command(id: id) else { continue }
            apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
        }
    }

    /// Internal so the hosted app tests can verify the real AppKit menu tree. Production calls
    /// this exactly once during launch.
    func setupMenuBar() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeApplicationMenuItem())
        mainMenu.addItem(makeProjectMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeExtensionsMenuItem())

        let windowMenuItem = makeWindowMenuItem()
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenuItem.submenu

        let helpMenuItem = makeHelpMenuItem()
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenuItem.submenu

        NSApp.mainMenu = mainMenu

        // The menu is built once, so a rebinding has to be pushed into the items that already
        // exist — otherwise a shortcut changed in Settings would not work until the next launch.
        menuEvents.observe(KeyboardShortcutsDidChange.self) { [weak self] _ in
            self?.applyShortcutBindings()
        }
        menuEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.rebuildExtensionMenus()
        }
        menuEvents.observe(ProjectScriptsDidChange.self) { [weak self] _ in
            self?.rebuildProjectScriptsMenu()
        }
        menuEvents.observe(AppSettingsDidChange.self) { [weak self] _ in
            self?.updateCurrentThemeMenuVisibility()
        }
    }

    private func makeExtensionsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L10n.string("Extensions"))
        extensionMenu = menu
        rebuildExtensionMenus()

        let item = NSMenuItem()
        item.title = L10n.string("Extensions")
        item.submenu = menu
        return item
    }

    /// Rebuilds only the dynamic menu. The Window and Help menu identities remain untouched.
    private func rebuildExtensionMenus() {
        guard let menu = extensionMenu else { return }
        menu.removeAllItems()
        for id in Array(commandItems.keys) where id.hasPrefix("extension.") {
            commandItems.removeValue(forKey: id)
        }

        let allCommands = CommandRegistry.shared.extensionCommands
        populate(
            menu,
            commands: allCommands,
            placement: .extensions
        )
        populate(
            projectExtensionItem?.submenu,
            commands: allCommands,
            placement: .project
        )
        populate(
            viewExtensionItem?.submenu,
            commands: allCommands,
            placement: .view
        )

        let hasVisibleCommands = !menu.items.isEmpty
        if !hasVisibleCommands {
            let empty = NSMenuItem(
                title: L10n.string("No Extension Commands Here"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        }

        updatePlacementVisibility(
            item: projectExtensionItem,
            separator: projectExtensionSeparator
        )
        updatePlacementVisibility(
            item: viewExtensionItem,
            separator: viewExtensionSeparator
        )

        // A command may deliberately omit every menu-bar placement — no placements at all,
        // or row placements only — and still receive a user-assigned shortcut. AppKit
        // dispatches key equivalents through menu items, so retain one hidden host-owned
        // item instead of installing a global event monitor.
        for command in allCommands
            where ExtensionCommandMenuLayout.needsHiddenShortcutCarrier(command) {
            let item = extensionCommandMenuItem(command, bindsShortcut: true)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }

        rebuildProjectScriptsMenu()
    }

    private func rebuildProjectScriptsMenu() {
        guard let menu = projectScriptsItem?.submenu else { return }
        menu.removeAllItems()
        for id in Array(commandItems.keys) where id.hasPrefix("project.script.") {
            commandItems.removeValue(forKey: id)
        }

        for command in CommandRegistry.shared.projectScriptCommands {
            let item = NSMenuItem(
                title: command.title,
                action: #selector(performProjectScript(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = command.id
            item.toolTip = command.detail
            if let iconName = command.iconName {
                item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            }
            commandItems[command.id] = item
            menu.addItem(item)
        }

        if let catalog = ProjectScriptService.shared.activeCatalog,
           !catalog.diagnostics.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for diagnostic in catalog.diagnostics.prefix(ProjectScriptDefaults.maximumDiagnostics) {
                let item = NSMenuItem(
                    title: diagnostic.message,
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let visible = !menu.items.isEmpty
        projectScriptsItem?.isHidden = !visible
        projectScriptsSeparator?.isHidden = !visible
    }

    private func populate(
        _ menu: NSMenu?,
        commands: [AppCommand],
        placement: ExtensionMenuPlacement
    ) {
        guard let menu else { return }
        menu.removeAllItems()

        for group in ExtensionCommandMenuLayout.groups(
            commands: commands,
            placement: placement
        ) {
            let submenu = NSMenu(title: group.extensionName)
            for command in group.commands {
                submenu.addItem(extensionCommandMenuItem(
                    command,
                    bindsShortcut:
                        ExtensionCommandMenuLayout.canonicalPlacement(for: command)
                            == placement
                ))
            }

            let groupItem = NSMenuItem()
            groupItem.title = group.extensionName
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }
    }

    private func updatePlacementVisibility(
        item: NSMenuItem?,
        separator: NSMenuItem?
    ) {
        let isVisible = item?.submenu?.items.isEmpty == false
        item?.isHidden = !isVisible
        separator?.isHidden = !isVisible
    }

    private func extensionCommandMenuItem(
        _ command: AppCommand,
        bindsShortcut: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: #selector(performExtensionCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = command.id
        if bindsShortcut {
            apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
            commandItems[command.id] = item
        }
        return item
    }

    private func makeApplicationMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu()

        // Our own window rather than `orderFrontStandardAboutPanel`, which is the one surface the
        // app still showed in system chrome — and the only one answering "which build is this?"
        // with a version pair and nowhere to go from there. See `AboutWindowController`.
        menu.addItem(
            withTitle: L10n.format("About %@", appName),
            action: #selector(showAboutWindow),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(commandItem(
            "system.preferences",
            action: #selector(performHostMenuCommand(_:))
        ))
        // Beside Settings rather than under View: the gate is the app's own voice, not a view
        // of anything, and the app menu is the one place it can be found with no window open.
        // Its check is stamped in `validateMenuItem`, which AppKit asks on every open.
        menu.addItem(commandItem(
            AppCommands.ID.silenceSounds,
            action: #selector(toggleSilenceSounds)
        ))
        menu.addItem(.separator())
        menu.addItem(commandItem(
            "system.hide",
            action: #selector(performHostMenuCommand(_:))
        ))

        let hideOthersItem = NSMenuItem(
            title: L10n.string("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(
            withTitle: L10n.string("Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(commandItem(
            "system.quit",
            action: #selector(performHostMenuCommand(_:))
        ))

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeProjectMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.projectMenu)

        // Opens the project's composer rather than creating anything: agent, account, model
        // and checkout are chosen there. The per-agent entries that used to sit here answered
        // all four silently, which is the friction this menu should not remove.
        menu.addItem(commandItem(AppCommands.ID.newSession, action: #selector(newSession)))

        menu.addItem(.separator())

        // Two ways to a project, matching the sidebar's `+` menu: create the folder, or
        // adopt one that exists. Add Project keeps its shortcut and its meaning.
        menu.addItem(commandItem(AppCommands.ID.newProject, action: #selector(newProject)))
        menu.addItem(commandItem(AppCommands.ID.addProject, action: #selector(addProject)))

        menu.addItem(.separator())
        // The checkout's way out to a real editor, on the platform's own ⌘O. The pane header
        // carries the same action beside a chevron that picks the app; this is the menu-bar
        // half of it, and the reason the chord exists at all.
        menu.addItem(commandItem(AppCommands.ID.openIn, action: #selector(openInExternalApp)))
        menu.addItem(commandItem(
            AppCommands.ID.renameSession,
            action: #selector(performHostMenuCommand(_:))
        ))

        let scriptsSeparator = NSMenuItem.separator()
        scriptsSeparator.isHidden = true
        menu.addItem(scriptsSeparator)
        projectScriptsSeparator = scriptsSeparator

        let scriptsItem = NSMenuItem()
        scriptsItem.title = L10n.string("Scripts")
        scriptsItem.submenu = NSMenu(title: L10n.string("Project Scripts"))
        scriptsItem.isHidden = true
        menu.addItem(scriptsItem)
        projectScriptsItem = scriptsItem

        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.closeTab, action: #selector(closeActiveTab)))
        menu.addItem(commandItem(AppCommands.ID.closeSession, action: #selector(closeSession)))

        let extensionSeparator = NSMenuItem.separator()
        extensionSeparator.isHidden = true
        menu.addItem(extensionSeparator)
        projectExtensionSeparator = extensionSeparator

        let extensionItem = NSMenuItem()
        extensionItem.title = L10n.string("Extensions")
        extensionItem.submenu = NSMenu(title: L10n.string("Project Extensions"))
        extensionItem.isHidden = true
        menu.addItem(extensionItem)
        projectExtensionItem = extensionItem

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.editMenu)

        menu.addItem(commandItem("system.undo", action: AppKitEditActions.undo))
        menu.addItem(withTitle: L10n.string("Redo"), action: AppKitEditActions.redo, keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(commandItem("system.cut", action: #selector(performHostMenuCommand(_:))))
        menu.addItem(commandItem("system.copy", action: #selector(performHostMenuCommand(_:))))
        menu.addItem(commandItem("system.paste", action: #selector(performHostMenuCommand(_:))))
        menu.addItem(commandItem("system.selectAll", action: #selector(performHostMenuCommand(_:))))
        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.find, action: #selector(showFind)))
        menu.addItem(commandItem(
            AppCommands.ID.searchEverywhere,
            action: #selector(showSearchEverywhere)
        ))

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.viewMenu)

        menu.addItem(commandItem(AppCommands.ID.commandPalette, action: #selector(openCommandPalette)))
        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.toggleSidebar, action: #selector(toggleSidebar)))

        let navigatorMenu = NSMenu(title: L10n.string("Navigator"))
        navigatorMenu.delegate = self
        let navigatorItem = NSMenuItem(
            title: L10n.string("Navigator"),
            action: nil,
            keyEquivalent: ""
        )
        navigatorItem.submenu = navigatorMenu
        menu.addItem(navigatorItem)
        workspaceNavigatorMenu = navigatorMenu

        // Selection history — the toolbar's < > pair, on Xcode's chords. Enablement is
        // stamped in `validateMenuItem`, since a Back with nowhere to go should read that way.
        menu.addItem(commandItem(AppCommands.ID.navigateBack, action: #selector(navigateBack)))
        menu.addItem(commandItem(AppCommands.ID.navigateForward, action: #selector(navigateForward)))
        menu.addItem(commandItem(AppCommands.ID.previousTurn, action: #selector(previousTurn)))
        menu.addItem(commandItem(AppCommands.ID.nextTurn, action: #selector(nextTurn)))
        menu.addItem(commandItem(AppCommands.ID.previousStep, action: #selector(previousStep)))
        menu.addItem(commandItem(AppCommands.ID.nextStep, action: #selector(nextStep)))

        // The sidebar's own arrangement, beside its toggle: what the list groups and how it
        // sorts are View concerns, and the two toggles need a home a shortcut can live in.
        // Their checkmarks are stamped in `validateMenuItem`, which AppKit asks on every open.
        menu.addItem(commandItem(AppCommands.ID.groupByBranch, action: #selector(toggleBranchGrouping)))
        menu.addItem(commandItem(AppCommands.ID.loneBranchHeadings, action: #selector(toggleLoneBranchHeadings)))
        menu.addItem(commandItem(AppCommands.ID.compactTree, action: #selector(toggleCompactTree)))

        menu.addItem(.separator())

        // The display pane's family. Their defaults live in `AppCommands`, which is also where
        // the reasoning for each now sits — ⇧⌘R rather than ⇧⌘G (the platform's Find Previous),
        // ⇧⌘I rather than ⌘I (Get Info) or ⌥⌘I (the element inspector), and ⌃` for the shell,
        // free because ⌘` is the platform's cycle-windows.
        menu.addItem(commandItem(AppCommands.ID.newTerminalTab, action: #selector(openTerminalTab)))
        menu.addItem(commandItem(AppCommands.ID.browser, action: #selector(openBrowser)))
        menu.addItem(commandItem(AppCommands.ID.files, action: #selector(openFilesTab)))
        menu.addItem(commandItem(AppCommands.ID.review, action: #selector(openReview)))
        menu.addItem(commandItem(
            AppCommands.ID.jumpToReviewFile,
            action: #selector(jumpToReviewFile)
        ))
        menu.addItem(commandItem(AppCommands.ID.saveBaseline, action: #selector(saveBrowserBaseline)))
        menu.addItem(commandItem(AppCommands.ID.sessionInfo, action: #selector(openInfo)))
        menu.addItem(commandItem(AppCommands.ID.shell, action: #selector(toggleShell)))
        menu.addItem(commandItem(AppCommands.ID.displayPanel, action: #selector(toggleDisplayPanel)))
        menu.addItem(commandItem(AppCommands.ID.statusCard, action: #selector(toggleStatusCard)))

        menu.addItem(.separator())

        let currentTheme = commandItem(
            AppCommands.ID.currentTheme,
            action: #selector(toggleCurrentTheme)
        )
        currentThemeMenuItem = currentTheme
        menu.addItem(currentTheme)
        menu.addItem(commandItem(AppCommands.ID.componentGallery, action: #selector(showComponentGallery)))
        updateCurrentThemeMenuVisibility()

        menu.addItem(.separator())

        menu.addItem(commandItem(
            "system.fullScreen",
            action: #selector(performHostMenuCommand(_:))
        ))

        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.biggerText, action: #selector(increaseFontSize)))
        menu.addItem(commandItem(AppCommands.ID.smallerText, action: #selector(decreaseFontSize)))

        menu.addItem(.separator())

        // Tab traversal, wherever tabs are: the commands land on the focused tab host.
        menu.addItem(commandItem(AppCommands.ID.previousTab, action: #selector(selectPreviousTab)))
        menu.addItem(commandItem(AppCommands.ID.nextTab, action: #selector(selectNextTab)))

        // ⌘1–⌘9 ride hidden items: AppKit dispatches key equivalents through menu items, and
        // nine visible rows would say little a strip does not already show. Same carrier trick
        // the extension commands use.
        for number in AppCommands.ID.selectTabNumbers {
            let item = commandItem(
                AppCommands.ID.selectTab(number),
                action: #selector(selectTabByNumber(_:))
            )
            item.tag = number
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // ⌥⌘I — the browser devtools shortcut, for the same gesture: point at the thing on
        // screen and get something you can paste into a conversation about it. One item, not
        // two: element and freeflow are decided by what is held while pointing, so ⌥⇧⌘I still
        // opens freeflow without a second menu entry claiming to be a different feature.
        menu.addItem(commandItem(AppCommands.ID.inspectElement, action: #selector(inspectElement)))

        let extensionSeparator = NSMenuItem.separator()
        extensionSeparator.isHidden = true
        menu.addItem(extensionSeparator)
        viewExtensionSeparator = extensionSeparator

        let extensionItem = NSMenuItem()
        extensionItem.title = L10n.string("Extensions")
        extensionItem.submenu = NSMenu(title: L10n.string("View Extensions"))
        extensionItem.isHidden = true
        menu.addItem(extensionItem)
        viewExtensionItem = extensionItem

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === workspaceNavigatorMenu else { return }
        menu.removeAllItems()

        let effective = mainWindowController?.effectiveWorkspaceNavigatorSelection ?? .native
        let native = NSMenuItem(
            title: L10n.string("Native"),
            action: #selector(selectWorkspaceNavigator(_:)),
            keyEquivalent: ""
        )
        native.target = self
        native.representedObject = WorkspaceNavigatorSelection.native
        native.state = effective == .native ? .on : .off
        menu.addItem(native)

        let inventory = ExtensionManager.shared.extensionWorkspaceNavigatorInventory
        guard !inventory.isEmpty else { return }
        menu.addItem(.separator())
        for item in inventory {
            let selection = WorkspaceNavigatorSelection.extensionNavigator(
                extensionIdentifier: item.extensionIdentifier,
                navigatorID: item.navigator.id
            )
            let menuItem = NSMenuItem(
                title: L10n.format("%@ — %@", item.navigator.title, item.extensionName),
                action: #selector(selectWorkspaceNavigator(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = selection
            menuItem.state = selection == effective ? .on : .off
            menu.addItem(menuItem)
        }
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.windowMenu)

        menu.addItem(commandItem(
            "system.minimize",
            action: #selector(performHostMenuCommand(_:))
        ))
        menu.addItem(
            withTitle: L10n.string("Zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: MenuIdentifiers.helpMenu)

        menu.addItem(
            withTitle: L10n.format("%@ Help", appName),
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )

        menu.addItem(.separator())

        // Under Help rather than the app menu, beside the support report: both are "something is
        // wrong, or might be" errands, and neither is a preference. A command item like the
        // rest, so the Keyboard page lists it and can bind it a chord.
        menu.addItem(commandItem(AppCommands.ID.checkForUpdates, action: #selector(checkForUpdates)))

        // Above the support report on purpose: filing a ticket is what someone came to this
        // menu to do, and exporting a diagnostics file is what they do when asked to.
        let issueItem = NSMenuItem(
            title: L10n.string("Report a Problem…"),
            action: #selector(reportProblem),
            keyEquivalent: ""
        )
        issueItem.target = self
        menu.addItem(issueItem)

        let reportItem = NSMenuItem(
            title: L10n.string("Create Remote Support Report…"),
            action: #selector(createRemoteSupportReport),
            keyEquivalent: ""
        )
        reportItem.target = self
        menu.addItem(reportItem)

        let logItem = NSMenuItem(
            title: L10n.string("Reveal Diagnostics Log"),
            action: #selector(revealDiagnosticsLog),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Menu Actions

    @MainActor @objc private func performExtensionCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        _ = hostCommandPlane.invoke(commandID: id)
    }

    /// The complete repository-authored command, in a bounded viewport rather than bounded text.
    ///
    /// Commands are accepted up to `ProjectScriptDefaults.maximumCommandBytes`. Truncating one
    /// here made the consent dishonest: a repository could put 600 plausible characters first
    /// and the action the terminal would actually run after them. The viewport may be short, but
    /// its selectable document is the exact command and every byte remains reachable by scrolling.
    @MainActor
    static func projectScriptConfirmation(
        for invocation: ProjectScriptInvocation
    ) -> ConfirmationRequest {
        let preview = ThemedSurfaceView()
        preview.frame = NSRect(x: 0, y: 0, width: 500, height: 160)
        preview.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )

        let scroll = ThemedTextView.scrolling()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.verticalScrollElasticity = .none
        preview.addSubview(scroll)

        let text = scroll.textView
        text.string = invocation.script.command
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = false
        text.applyFont(.code())
        text.textContainerInset = NSSize(
            width: Design.Spacing.small,
            height: Design.Spacing.small
        )
        text.setAccessibilityLabel(L10n.string("Command"))

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: preview.topAnchor, constant: Design.Spacing.tight),
            scroll.bottomAnchor.constraint(
                equalTo: preview.bottomAnchor,
                constant: -Design.Spacing.tight
            ),
            scroll.leadingAnchor.constraint(
                equalTo: preview.leadingAnchor,
                constant: Design.Spacing.tight
            ),
            scroll.trailingAnchor.constraint(
                equalTo: preview.trailingAnchor,
                constant: -Design.Spacing.tight
            )
        ])

        return ConfirmationRequest(
            prompt: .runProjectScript,
            title: L10n.format("Run “%@”?", invocation.script.name),
            message: L10n.format(
                "This repository defines the command below. It will run in %@ only after you choose Run.",
                invocation.workingDirectory.path
            ),
            confirmTitle: L10n.string("Run in Terminal"),
            accessory: preview
        )
    }

    @MainActor @objc private func performProjectScript(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let invocation = ProjectScriptService.shared
                .availability(commandID: id).invocation else { return }

        let request = Self.projectScriptConfirmation(for: invocation)

        let window = mainWindowController?.window
        ConfirmationAlert.ask(request, in: window) { [weak self] accepted in
            guard accepted,
                  let current = ProjectScriptService.shared
                    .availability(commandID: id).invocation,
                  current == invocation else { return }

            guard self?.mainWindowController?.runProjectScript(current) != nil else {
                let failure = ThemedAlert()
                failure.messageText = L10n.string("The project script did not start")
                failure.informativeText = L10n.string(
                    "Its checkout or working directory changed before a terminal could accept the command."
                )
                failure.alertStyle = .critical
                if let window { failure.beginSheetModal(for: window) } else { failure.runModal() }
                return
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Recovery first, and only for items that carry a command id. Items outside the command
        // plane — About and the Help entries — carry none and stay enabled by construction.
        // A refused command reads as unavailable rather than beeping at an advertised chord,
        // which is the treatment a checkout-less Open In already gets below.
        if RecoveryMode.isActive,
           let commandID = menuItem.representedObject as? String,
           !RecoveryModeCommandPolicy.allows(commandID: commandID) {
            return false
        }

        // The arrangement toggles carry state, so their checks are stamped here — validation
        // runs on every menu open, which is the one moment the check has to be true.
        if menuItem.action == #selector(toggleBranchGrouping) {
            menuItem.state = NativeSidebarPipelineOptions.branchGrouping ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleLoneBranchHeadings) {
            menuItem.state = NativeSidebarPipelineOptions.loneBranchHeadings ? .on : .off
            // The refinement has nothing to refine while grouping is off.
            return NativeSidebarPipelineOptions.branchGrouping
        }
        if menuItem.action == #selector(toggleCompactTree) {
            menuItem.state = NativeSidebarPipelineOptions.compactTree ? .on : .off
            return true
        }
        // The silence gate carries state too, and it is always available: it needs no window,
        // no session and no checkout, which is most of the point of having it in the menu bar.
        if menuItem.action == #selector(toggleSilenceSounds) {
            menuItem.state = AppSettings.shared.silencesAllSounds ? .on : .off
            return true
        }
        // Settings and an empty window carry no checkout, so the item reads as unavailable
        // rather than beeping at a chord the menu said would work.
        if menuItem.action == #selector(openInExternalApp) {
            return mainWindowController?.currentFolderURL != nil
        }
        if menuItem.action == #selector(navigateBack) {
            return mainWindowController?.canGoBack ?? false
        }
        if menuItem.action == #selector(navigateForward) {
            return mainWindowController?.canGoForward ?? false
        }
        // A terminal session, the settings window and an empty window have no exchanges to move
        // between, so these read as unavailable rather than beeping at an advertised chord.
        if [
            #selector(previousTurn), #selector(nextTurn),
            #selector(previousStep), #selector(nextStep)
        ].contains(where: { menuItem.action == $0 }) {
            return mainWindowController?.isShowingConversation ?? false
        }
        if menuItem.action == #selector(toggleCurrentTheme) {
            menuItem.isHidden = !MCPToolCatalog.hasEnabledThemeTools
            menuItem.state = mainWindowController?.isCurrentThemeVisible == true ? .on : .off
            return MCPToolCatalog.hasEnabledThemeTools
        }
        // Sparkle refuses re-entrant checks, and it also refuses everything when the updater
        // failed to start — either way the item reads as unavailable instead of doing nothing.
        if menuItem.action == #selector(checkForUpdates) {
            return AppUpdater.shared.canCheckForUpdates
        }

        // A repository-defined script explains itself in the item: its reason is specific
        // ("no longer in the active checkout") in a way a scope guess could not be.
        if menuItem.action == #selector(performProjectScript(_:)),
           let id = menuItem.representedObject as? String {
            let availability = ProjectScriptService.shared.availability(commandID: id)
            menuItem.toolTip = availability.reason
                ?? CommandRegistry.shared.command(id: id)?.detail
            return availability.invocation != nil
        }

        guard let id = menuItem.representedObject as? String,
              let command = CommandRegistry.shared.command(id: id) else { return true }
        return commandIsAvailable(command)
    }

    private func commandIsAvailable(_ command: AppCommand) -> Bool {
        hostCommandState(for: command).availability.isAvailable
    }

    private func hostCommandCatalog() -> [HostCommandDescriptor] {
        CommandRegistry.shared.all.map { command in
            let state = hostCommandState(for: command)
            return command.hostDescriptor(
                shortcut: ShortcutOverrideStore.shared.shortcut(for: command)?.displayString,
                availability: state.availability,
                nextInput: state.nextInput
            )
        } + settingsDestinations().map { $0.hostDescriptor() }
    }

    /// Every page and row in Settings, offered beside the commands.
    ///
    /// Appended rather than registered: these navigate rather than run, so they belong in the
    /// palette and nowhere else — see `SettingsDestination`. Enumerated on each catalog read for
    /// the same reason commands are: an extension can be enabled or removed between one palette
    /// and the next, taking its pages and rows with it.
    private func settingsDestinations() -> [SettingsDestination] {
        guard mainWindowController != nil else { return [] }
        return SettingsPages.destinations
    }

    private func hostCommandInputOptions(
        commandID: String,
        input: HostCommandInputRequest
    ) -> [HostCommandInputOption] {
        switch input.kind {
        case .session:
            return mainWindowController?.commandSessionOptions(for: commandID) ?? []
        case .project:
            return ProjectStore.shared.projects.map { project in
                HostCommandInputOption(
                    id: project.id.uuidString.lowercased(),
                    title: project.name,
                    detail: project.folderPath
                )
            }
        }
    }

    private struct HostCommandState {
        let availability: HostCommandDescriptor.Availability
        let nextInput: HostCommandInputRequest?

        static let available = HostCommandState(availability: .available, nextInput: nil)

        static func unavailable(_ reason: String) -> HostCommandState {
            HostCommandState(availability: .unavailable(reason: reason), nextInput: nil)
        }

        static func needsSession() -> HostCommandState {
            HostCommandState(
                availability: .unavailable(reason: L10n.string("Select a session first.")),
                nextInput: HostCommandInputRequest(
                    kind: .session,
                    prompt: L10n.string("Choose a session to continue."),
                    searchPlaceholder: L10n.string("Choose a session")
                )
            )
        }

        static func declaredInput(
            _ input: ExtensionCommandInput,
            availability: HostCommandDescriptor.Availability
        ) -> HostCommandState {
            let kind: HostCommandInputRequest.Kind
            switch input.kind {
            case .project: kind = .project
            }
            return HostCommandState(
                availability: availability,
                nextInput: HostCommandInputRequest(
                    kind: kind,
                    prompt: input.prompt,
                    searchPlaceholder: input.searchPlaceholder
                )
            )
        }
    }

    /// Resolves both menu availability and the palette's optional next input. Commands that
    /// need more than a semantic target (a visible browser or review, for example) keep that
    /// specific refusal. Session identity can become a second step when it is the only missing
    /// prerequisite; declared extension project input always becomes a second Quick Open step
    /// while menus keep using their current host context.
    private func hostCommandState(for command: AppCommand) -> HostCommandState {
        if RecoveryMode.isActive, !RecoveryModeCommandPolicy.allows(commandID: command.id) {
            return .unavailable(L10n.string("This command is unavailable in Recovery Mode."))
        }
        // A script is available exactly while its declaration still resolves to something
        // runnable in the active checkout; the service's reason beats any scope inference.
        if case .projectScript = command.origin {
            let availability = ProjectScriptService.shared.availability(commandID: command.id)
            guard availability.invocation != nil else {
                return .unavailable(
                    availability.reason ?? L10n.string("This command is unavailable.")
                )
            }
        }

        // These commands require a particular active surface, not merely any session. Name the
        // real prerequisite before the scope gate so the palette never offers an input that
        // cannot make the command runnable by itself.
        switch command.id {
        case AppCommands.ID.jumpToReviewFile:
            guard mainWindowController?.canJumpToReviewFile == true else {
                return .unavailable(L10n.string("Show a Git Review with changed files first."))
            }
        case AppCommands.ID.previousTurn, AppCommands.ID.nextTurn,
             AppCommands.ID.previousStep, AppCommands.ID.nextStep:
            guard mainWindowController?.isShowingConversation == true else {
                return .unavailable(L10n.string("The active surface is not a conversation."))
            }
        case AppCommands.ID.saveBaseline:
            guard mainWindowController?.canSaveVisibleBrowserBaseline == true else {
                return .unavailable(L10n.string("Show a browser before saving a baseline."))
            }
        case AppCommands.ID.biggerText, AppCommands.ID.smallerText:
            guard mainWindowController?.canAdjustTerminalText == true else {
                return .unavailable(L10n.string("The active surface is not a terminal."))
            }
        case AppCommands.ID.currentTheme:
            guard MCPToolCatalog.hasEnabledThemeTools else {
                return .unavailable(L10n.string("Theme tools are disabled."))
            }
        default:
            break
        }

        if let input = command.extensionInput {
            switch input.kind {
            case .project:
                guard !ProjectStore.shared.projects.isEmpty else {
                    return .unavailable(L10n.string("Add a project first."))
                }
                let availability: HostCommandDescriptor.Availability =
                    mainWindowController?.currentProjectID == nil
                        ? .unavailable(reason: L10n.string("Select a project first."))
                        : .available
                return .declaredInput(input, availability: availability)
            }
        }

        switch command.scope {
        case .application: break
        case .project where mainWindowController?.currentProjectID == nil:
            return .unavailable(L10n.string("Select a project first."))
        case .session where mainWindowController?.currentSessionID == nil:
            return .needsSession()
        case .project, .session: break
        }

        switch command.id {
        case AppCommands.ID.closeTab:
            guard mainWindowController?.canCloseActiveTab == true else {
                return .unavailable(L10n.string("There is no tab to close."))
            }
        case AppCommands.ID.find:
            guard mainWindowController?.canShowFind == true else {
                return .unavailable(L10n.string("Find is unavailable on the active surface."))
            }
        case AppCommands.ID.openIn:
            guard mainWindowController?.currentFolderURL != nil else {
                return .unavailable(L10n.string("The current surface has no checkout."))
            }
        case AppCommands.ID.navigateBack:
            guard mainWindowController?.canGoBack == true else {
                return .unavailable(L10n.string("There is no previous location."))
            }
        case AppCommands.ID.navigateForward:
            guard mainWindowController?.canGoForward == true else {
                return .unavailable(L10n.string("There is no next location."))
            }
        case AppCommands.ID.loneBranchHeadings:
            guard NativeSidebarPipelineOptions.branchGrouping else {
                return .unavailable(L10n.string("Turn on Group Sessions by Branch first."))
            }
        case AppCommands.ID.previousTab, AppCommands.ID.nextTab:
            guard mainWindowController?.canSelectAdjacentTab == true else {
                return .unavailable(L10n.string("There is no other tab to select."))
            }
        case AppCommands.ID.checkForUpdates:
            guard AppUpdater.shared.canCheckForUpdates else {
                return .unavailable(L10n.string("An update check is already running."))
            }
        case AppCommands.ID.newManager:
            guard mainWindowController?.currentProjectID != nil else {
                return .unavailable(L10n.string("Select a project first."))
            }
        case AppCommands.ID.makeManager:
            guard let sessionID = mainWindowController?.currentSessionID else { return .needsSession() }
            guard !ControlGrantStore.shared.isManager(sessionID) else {
                return .unavailable(L10n.string("The selected chat is already a manager."))
            }
        case AppCommands.ID.revokeManager:
            guard let sessionID = mainWindowController?.currentSessionID else { return .needsSession() }
            guard ControlGrantStore.shared.isManager(sessionID) else {
                return .unavailable(L10n.string("The selected chat is not a manager."))
            }
        default:
            break
        }
        if let number = Int(command.id.replacingOccurrences(of: "tab.select.", with: "")),
           AppCommands.ID.selectTabNumbers.contains(number),
           mainWindowController?.canSelectTab(atIndex: number - 1) != true {
            return .unavailable(L10n.format("Tab %lld is not available.", Int64(number)))
        }
        return .available
    }

    /// Authoritative command implementation. Selectors below are adapters for AppKit's menu and
    /// responder chain; the palette calls this same function through `HostCommandPlane`.
    private func performHostCommand(
        _ request: HostCommandInvocationRequest
    ) -> HostCommandInvocationOutcome {
        let id = request.commandID
        if SettingsDestinationCatalog.isDestinationID(id) {
            return showSettingsDestination(id: id)
        }
        guard let command = CommandRegistry.shared.command(id: id) else {
            return .refused(commandID: id, reason: L10n.string("This command is no longer available."))
        }

        if let input = request.input {
            switch input.kind {
            case .project:
                guard command.extensionInput?.kind == .project,
                      case .extensionCommand = command.origin,
                      let projectID = ProjectID(uuidString: input.id),
                      ProjectStore.shared.project(withID: projectID) != nil else {
                    return .refused(
                        commandID: id,
                        reason: L10n.string("That project is no longer available.")
                    )
                }
                let opaqueID = projectID.uuidString.lowercased()
                ExtensionCommandInvoker.perform(
                    command,
                    context: ExtensionCommandContext(projectID: opaqueID),
                    input: ExtensionCommandInputValue(kind: .project, id: opaqueID),
                    window: mainWindowController?.window
                )
                return .invoked(commandID: id)

            case .session:
                guard input.kind == .session,
                      command.scope == .session,
                      let sessionID = SessionID(uuidString: input.id),
                      let controller = mainWindowController,
                      controller.isCommandTargetSessionAvailable(sessionID) else {
                    return .refused(
                        commandID: id,
                        reason: L10n.string("That session is no longer available.")
                    )
                }

                if case .extensionCommand = command.origin {
                    let context = ExtensionCommandContext(
                        projectID: controller.projectID(forCommandTarget: sessionID)?
                            .uuidString.lowercased(),
                        sessionID: sessionID.uuidString.lowercased()
                    )
                    ExtensionCommandInvoker.perform(
                        command,
                        context: context,
                        window: controller.window
                    )
                    return .invoked(commandID: id)
                }

                switch id {
            case AppCommands.ID.closeSession:
                controller.closeSession(sessionID)
                return .invoked(commandID: id)
            case AppCommands.ID.renameSession:
                controller.renameSession(sessionID)
                return .invoked(commandID: id)
            case AppCommands.ID.makeManager:
                guard !ControlGrantStore.shared.isManager(sessionID) else {
                    return .refused(
                        commandID: id,
                        reason: L10n.string("The selected chat is already a manager.")
                    )
                }
                controller.makeSessionManager(sessionID)
                return .invoked(commandID: id)
            case AppCommands.ID.revokeManager:
                guard ControlGrantStore.shared.isManager(sessionID) else {
                    return .refused(
                        commandID: id,
                        reason: L10n.string("The selected chat is not a manager.")
                    )
                }
                controller.revokeManagerRole(for: sessionID)
                return .invoked(commandID: id)
            default:
                guard controller.performAfterSelectingSession(sessionID, action: { [weak self] in
                    _ = self?.performHostCommand(
                        HostCommandInvocationRequest(commandID: id)
                    )
                }) else {
                    return .refused(
                        commandID: id,
                        reason: L10n.string("That session is no longer available.")
                    )
                }
                return .invoked(commandID: id)
                }
            }
        }

        let availability = hostCommandState(for: command).availability
        guard availability.isAvailable else {
            return .refused(
                commandID: id,
                reason: availability.disabledReason ?? L10n.string("This command is unavailable.")
            )
        }

        if case .extensionCommand = command.origin {
            let context = ExtensionCommandContext(
                projectID: mainWindowController?.currentProjectID?.uuidString.lowercased(),
                sessionID: mainWindowController?.currentSessionID?.uuidString.lowercased()
            )
            ExtensionCommandInvoker.perform(
                command,
                context: context,
                window: mainWindowController?.window
            )
            return .invoked(commandID: id)
        }

        switch id {
        case AppCommands.ID.commandPalette: showCommandPalette()
        case AppCommands.ID.newSession: mainWindowController?.newSession()
        case AppCommands.ID.newManager: mainWindowController?.newManager()
        case AppCommands.ID.makeManager: mainWindowController?.makeCurrentSessionManager()
        case AppCommands.ID.revokeManager: mainWindowController?.revokeCurrentManagerRole()
        case AppCommands.ID.newProject: mainWindowController?.newProject()
        case AppCommands.ID.addProject: mainWindowController?.addProject()
        case AppCommands.ID.renameSession: mainWindowController?.renameCurrentSession()
        case AppCommands.ID.closeSession: mainWindowController?.closeCurrentSession()
        case AppCommands.ID.closeTab: mainWindowController?.closeActiveTab()
        case AppCommands.ID.find:
            if mainWindowController?.showFind() != true { showUniversalSearch(everywhere: false) }
        case AppCommands.ID.findNext:
            if universalSearchController?.repeatSelection(backwards: false) != true {
                _ = mainWindowController?.repeatFind(backwards: false)
            }
        case AppCommands.ID.findPrevious:
            if universalSearchController?.repeatSelection(backwards: true) != true {
                _ = mainWindowController?.repeatFind(backwards: true)
            }
        case AppCommands.ID.searchEverywhere: showUniversalSearch(everywhere: true)
        case AppCommands.ID.openIn: mainWindowController?.openInPreferredApp()
        case AppCommands.ID.toggleSidebar: mainWindowController?.toggleSidebar()
        case AppCommands.ID.groupByBranch:
            NativeSidebarPipelineOptions.toggleBranchGrouping()
            NotificationCenter.default.post(ProjectsDidChange())
        case AppCommands.ID.loneBranchHeadings:
            NativeSidebarPipelineOptions.toggleLoneBranchHeadings()
            NotificationCenter.default.post(ProjectsDidChange())
        case AppCommands.ID.compactTree: NativeSidebarPipelineOptions.toggleCompactTree()
        // No extra post: the setter's own settings event is what the sidebar's footer control
        // and the Settings row both follow, which is what keeps the three surfaces one state.
        case AppCommands.ID.silenceSounds: AppSettings.shared.silencesAllSounds.toggle()
        case AppCommands.ID.newTerminalTab: mainWindowController?.showTerminalTab()
        case AppCommands.ID.browser: mainWindowController?.showBrowser()
        case AppCommands.ID.files: mainWindowController?.showFilesTab()
        case AppCommands.ID.review: mainWindowController?.showReview()
        case AppCommands.ID.jumpToReviewFile: mainWindowController?.showReviewFileJump()
        case AppCommands.ID.saveBaseline: mainWindowController?.saveVisibleBrowserBaseline()
        case AppCommands.ID.sessionInfo: mainWindowController?.showInfo()
        case AppCommands.ID.shell: mainWindowController?.toggleShellDrawer()
        case AppCommands.ID.displayPanel: mainWindowController?.toggleDisplayPane()
        case AppCommands.ID.statusCard: mainWindowController?.toggleStatusCard()
        case AppCommands.ID.currentTheme: mainWindowController?.toggleCurrentTheme()
        case AppCommands.ID.componentGallery: showComponentGalleryImplementation()
        case AppCommands.ID.biggerText: mainWindowController?.increaseFontSize()
        case AppCommands.ID.smallerText: mainWindowController?.decreaseFontSize()
        case AppCommands.ID.navigateBack: mainWindowController?.goBack()
        case AppCommands.ID.navigateForward: mainWindowController?.goForward()
        case AppCommands.ID.previousTurn: mainWindowController?.moveConversation(byTurn: false)
        case AppCommands.ID.nextTurn: mainWindowController?.moveConversation(byTurn: true)
        case AppCommands.ID.previousStep: mainWindowController?.moveConversation(byStep: false)
        case AppCommands.ID.nextStep: mainWindowController?.moveConversation(byStep: true)
        case AppCommands.ID.previousTab: mainWindowController?.selectAdjacentTab(offset: -1)
        case AppCommands.ID.nextTab: mainWindowController?.selectAdjacentTab(offset: 1)
        case AppCommands.ID.inspectElement: mainWindowController?.toggleElementInspector()
        case AppCommands.ID.checkForUpdates: AppUpdater.shared.checkForUpdates()
        case "system.preferences": mainWindowController?.toggleSettingsFromCommand()
        case "system.hide": NSApp.hide(nil)
        case "system.quit": NSApp.terminate(nil)
        case "system.undo":
            NSApp.sendAction(AppKitEditActions.undo, to: nil, from: nil)
        case "system.cut": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "system.copy": NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "system.paste": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "system.selectAll": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "system.fullScreen": mainWindowController?.window?.toggleFullScreen(nil)
        case "system.minimize": mainWindowController?.window?.miniaturize(nil)
        default:
            if let number = Int(id.replacingOccurrences(of: "tab.select.", with: "")),
               AppCommands.ID.selectTabNumbers.contains(number) {
                mainWindowController?.selectTab(atIndex: number - 1)
            } else {
                return .refused(commandID: id, reason: L10n.string("This command has no host implementation."))
            }
        }
        return .invoked(commandID: id)
    }

    /// Opens Settings on a destination's page and reveals its row.
    ///
    /// Resolved against the catalogue as it stands rather than by taking the id apart: a page an
    /// extension contributed can be gone by the time its palette row is confirmed, and a
    /// navigation to a page that no longer exists should refuse rather than open Settings on
    /// whatever is first.
    private func showSettingsDestination(id: String) -> HostCommandInvocationOutcome {
        guard let controller = mainWindowController,
              let destination = SettingsDestinationCatalog.destination(
                  id: id,
                  in: SettingsPages.destinations
              ) else {
            return .refused(
                commandID: id,
                reason: L10n.string("That settings page is no longer available.")
            )
        }
        controller.showSettingsPage(id: destination.pageID, revealing: destination.rowTitle)
        return .invoked(commandID: id)
    }

    private func showUniversalSearch(everywhere: Bool) {
        guard let window = mainWindowController?.window else { return }
        let preferredScope: SearchScope
        if !everywhere, let view = mainWindowController?.currentSearchViewContext {
            preferredScope = .view(view)
        } else {
            // Command-F reaches this branch only when the active surface has no honest provider.
            preferredScope = .everywhere
        }
        universalSearchController?.present(in: window, preferredScope: preferredScope)
    }

    private func activateSearchLocator(_ locator: SearchLocator) async -> Bool {
        guard let controller = mainWindowController else { return false }
        switch locator {
        case .project(let projectID):
            return controller.openSearchProject(projectID)
        case .session(let projectID, let sessionID):
            return controller.openSearchSession(sessionID, projectID: projectID)
        case .projectTerminal(let projectID, let terminalID):
            return controller.openSearchTerminal(terminalID, projectID: projectID)
        case .archivedSession(let projectID, let sessionID):
            return controller.openArchivedSearchSession(sessionID, projectID: projectID)
        case .command(let commandID):
            if case .invoked = hostCommandPlane.invoke(commandID: commandID) { return true }
            return false
        case .setting(let destinationID):
            if case .invoked = hostCommandPlane.invoke(commandID: destinationID) { return true }
            return false
        case .workspaceFile(let projectID, _, let location):
            if location.line != nil {
                guard let project = environment.projectStore.project(withID: projectID) else {
                    return false
                }
                do {
                    let textWindow = try await ProjectTextWindowLoader.load(
                        projectID: projectID,
                        root: project.folderURL,
                        location: location
                    )
                    guard !Task.isCancelled else { return false }
                    return controller.openSearchProjectTextWindow(textWindow)
                } catch {
                    return false
                }
            }
            return controller.openSearchWorkspaceFile(projectID: projectID, location: location)
        case .attachment(let projectID, let sessionID, let attachmentID):
            return controller.openSearchAttachment(
                projectID: projectID,
                sessionID: sessionID,
                attachmentID: attachmentID
            )
        case .browserTab(let projectID, let sessionID, let tabID):
            return controller.openSearchBrowserTab(
                projectID: projectID,
                sessionID: sessionID,
                tabID: tabID
            )
        case .conversation(let conversation):
            guard let loader = transcriptSearchIndexStore?.conversationWindowLoader() else {
                return false
            }
            do {
                let window = try await loader.load(centeredOn: conversation)
                guard !Task.isCancelled else { return false }
                return controller.openSearchConversationWindow(window)
            } catch {
                return false
            }
        case .gitReview:
            return false
        }
    }

    @objc private func showCommandPalette() {
        guard commandPaletteController == nil, let window = mainWindowController?.window else { return }
        let controller = CommandPaletteViewController(
            catalog: { [weak self] in self?.hostCommandPlane.commands() ?? [] },
            inputOptions: { [weak self] commandID in
                self?.hostCommandPlane.inputOptions(commandID: commandID) ?? []
            },
            invokeRequest: { [weak self] request in
                self?.hostCommandPlane.invoke(request)
                    ?? .refused(
                        commandID: request.commandID,
                        reason: L10n.string("The application is unavailable.")
                    )
            },
            shortcutEditing: CommandPaletteShortcutEditing(
                shortcut: { commandID in
                    CommandRegistry.shared.command(id: commandID).flatMap {
                        ShortcutOverrideStore.shared.shortcut(for: $0)
                    }
                },
                record: { commandID, shortcut in
                    guard let command = CommandRegistry.shared.command(id: commandID),
                          command.isEditable else {
                        return L10n.string("This command is unavailable.")
                    }
                    if let shortcut,
                       let owner = ShortcutOverrideStore.shared.conflict(
                           for: shortcut,
                           excluding: command
                       ) {
                        return L10n.format("Already used by %@", owner.title)
                    }
                    ShortcutOverrideStore.shared.setShortcut(shortcut, for: command)
                    return nil
                }
            )
        )
        commandPaletteController = controller
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.commandPaletteController === controller else { return }
            self?.commandPaletteController = nil
        }
        controller.present(in: window)
    }

    private func showComponentGalleryImplementation() {
        let controller = componentGalleryWindowController ?? ComponentGalleryWindowController()
        componentGalleryWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateCurrentThemeMenuVisibility() {
        currentThemeMenuItem?.isHidden = !MCPToolCatalog.hasEnabledThemeTools
    }

    // MARK: - Menu Actions

    /// Every action below routes through `mainWindowController?`, deliberately.
    ///
    /// Two processes run a real `NSApplication` with this delegate and never build a window: a
    /// hosted test bundle, and a second instance that lost the single-instance lock. A command
    /// arriving in either — a menu item validated a moment early, a key equivalent, a test that
    /// pumps the run loop — has *nothing to act on*, and the honest answer to that is to do
    /// nothing. It used to be a trap, which is how the same force-unwrap in
    /// `applicationShouldHandleReopen` took a test run down.
    @objc private func showPreferences() {
        _ = hostCommandPlane.invoke(commandID: "system.preferences")
    }

    @objc private func performHostMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        _ = hostCommandPlane.invoke(commandID: id)
    }

    @objc private func openCommandPalette() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.commandPalette)
    }

    @objc private func openTerminalTab() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.newTerminalTab)
    }

    @objc private func closeActiveTab() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.closeTab)
    }

    @objc private func navigateBack() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.navigateBack)
    }

    @objc private func navigateForward() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.navigateForward)
    }

    @objc private func previousTurn() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.previousTurn)
    }

    @objc private func nextTurn() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.nextTurn)
    }

    @objc private func previousStep() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.previousStep)
    }

    @objc private func nextStep() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.nextStep)
    }

    @objc private func selectPreviousTab() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.previousTab)
    }

    @objc private func selectNextTab() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.nextTab)
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.selectTab(sender.tag))
    }

    @objc private func openFilesTab() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.files)
    }

    /// Reveals today's journal rather than opening it: `.jsonl` has no owning app, and what
    /// is usually wanted is the folder, where the previous days sit alongside it.
    @objc private func revealDiagnosticsLog() {
        let journal = EventLog.shared.currentJournalURL

        guard FileManager.default.fileExists(atPath: journal.path) else {
            NSWorkspace.shared.open(EventLog.shared.directory)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([journal])
    }

    /// Creates the share-safe report, not a copy of the owner-local journal. The latter may
    /// contain prompts, commands and paths and remains available separately for local diagnosis.
    @MainActor @objc private func checkForUpdates() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.checkForUpdates)
    }

    /// One About window, kept and raised. Reopening replays the mark's draw-in, which is the only
    /// reason to open this window a second time.
    @MainActor @objc private func showAboutWindow() {
        let controller = aboutWindowController ?? AboutWindowController()
        aboutWindowController = controller
        controller.showWindow(nil)
    }

    /// Presented on the main window rather than in one of its own: the ticket is about the app
    /// the user is looking at, and a sheet cannot be left open behind it and forgotten.
    @MainActor @objc private func reportProblem() {
        mainWindowController?.presentReportProblem()
    }

    /// The grants are read first because two of them arrive through a callback, and a report
    /// missing the notification row is missing the answer to the most common question about it.
    @MainActor @objc private func createRemoteSupportReport() {
        SystemPrivacyStatusReader().load { [weak self] statuses in
            self?.writeSupportReport(privacyStatuses: statuses)
        }
    }

    @MainActor
    private func writeSupportReport(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus]
    ) {
        let details = supportReportDetails(privacyStatuses: privacyStatuses)

        do {
            let report = try MacRemoteDiagnostics.supportReport(
                additionalDetails: details.fields
            )
            NSWorkspace.shared.activateFileViewerSelecting([report])
        } catch {
            ThreadingLogger.remote.error(
                "Support report creation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            let alert = ThemedAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Couldn’t create support report")
            alert.informativeText = L10n.string(
                "Threading could not prepare the remote diagnostics file."
            )
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        }
    }

    private func publicIssueReportDiagnostics() async throws -> PublicIssueReportDiagnosticsDTO {
        let statuses = await withCheckedContinuation { continuation in
            SystemPrivacyStatusReader().load { statuses in
                continuation.resume(returning: statuses)
            }
        }
        let details = supportReportDetails(privacyStatuses: statuses)
        return PublicIssueReportDiagnosticsDTO(
            bounding: MacRemoteDiagnostics.report(additionalDetails: details.fields)
        )
    }

    private func supportReportDetails(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus]
    ) -> MacSupportReportDetails {
        let projects = ProjectStore.shared.projects
        let extensions = ExtensionManager.shared.installedExtensions
        let accounts = AgentKind.allCases.reduce(into: [String: Int]()) { counts, kind in
            counts[kind.rawValue] = AgentAccountDiscovery.allAccounts(for: kind).count
        }

        return MacSupportReportDetails(
            privacyStatuses: privacyStatuses,
            remoteAccessEnabled: AppSettings.shared.remoteAccessEnabled,
            automaticUpdateChecksEnabled: AppUpdater.shared.automaticChecksEnabled,
            appThemeID: AppThemeLibrary.current.id.rawValue,
            projectCount: projects.count,
            sessionCount: projects.reduce(0) { $0 + $1.sessions.count },
            extensionCount: extensions.count,
            companionCount: extensions.reduce(0) { $0 + $1.companions.count },
            agentAccounts: accounts,
            previousLaunchWasClean: EventLog.shared.previousLaunchEndedCleanly,
            // Held from the top of the launch rather than read again: the ledger has this
            // launch's own records in it by now, so a second read would answer a different
            // question from the one the app acted on.
            crashLoopDecision: launchDecision,
            launchLedgerRead: launchLedgerRead,
            // Read here rather than kept resident: the payloads are Apple's delayed record of
            // this and previous launches, and nothing else in the app asks about them. The read
            // is bounded by `MetricKitReadBudget`, which is what makes it safe to do inline on a
            // menu command that is already writing a file.
            metricKitDiagnostics: MetricKitDiagnosticReader().read(),
            // Unlike MetricKit's delayed delivery, this is present immediately after the
            // watchdog fires — including when the user force-quit before main recovered.
            mainThreadStallIncidents: MainThreadStallIncidentStore.shared.read(),
            simulatorStreaming: SimulatorStreamDiagnostics.shared.reportToken
        )
    }

    @objc private func openBrowser() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.browser)
    }

    @objc private func openReview() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.review)
    }

    @objc private func saveBrowserBaseline() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.saveBaseline)
    }

    @objc private func openInfo() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.sessionInfo)
    }

    @objc private func toggleShell() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.shell)
    }

    @objc private func toggleDisplayPanel() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.displayPanel)
    }

    @objc private func toggleStatusCard() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.statusCard)
    }

    @objc private func toggleCurrentTheme() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.currentTheme)
    }

    @objc private func showComponentGallery() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.componentGallery)
    }

    @objc private func newSession() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.newSession)
    }

    @objc private func addProject() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.addProject)
    }

    @objc private func newProject() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.newProject)
    }

    @objc private func openInExternalApp() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.openIn)
    }

    @objc private func closeSession() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.closeSession)
    }

    @objc private func toggleSidebar() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.toggleSidebar)
    }

    @objc private func selectWorkspaceNavigator(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? WorkspaceNavigatorSelection else {
            return
        }
        mainWindowController?.selectWorkspaceNavigator(selection)
    }

    // The two sidebar-arrangement toggles act on settings, not on the window, so they work
    // even before a window exists — and they post `ProjectsDidChange` because that is what
    // the sidebar rebuilds its tree on, the same route its own menus take.
    @MainActor @objc private func toggleBranchGrouping() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.groupByBranch)
    }

    @MainActor @objc private func toggleLoneBranchHeadings() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.loneBranchHeadings)
    }

    // Density changes no node, so it posts nothing extra: the setter's own settings event is
    // what the sidebar re-lays out on. See `ProjectSidebarViewController.applyTreeDensity`.
    @MainActor @objc private func toggleCompactTree() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.compactTree)
    }

    @MainActor @objc private func toggleSilenceSounds() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.silenceSounds)
    }

    @objc private func showFind() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.find)
    }

    @objc private func showSearchEverywhere() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.searchEverywhere)
    }

    @objc private func jumpToReviewFile() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.jumpToReviewFile)
    }

    @objc private func inspectElement() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.inspectElement)
    }

    @objc private func increaseFontSize() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.biggerText)
    }

    @objc private func decreaseFontSize() {
        _ = hostCommandPlane.invoke(commandID: AppCommands.ID.smallerText)
    }

#if DEBUG
    /// Puts the main-thread readout in the window's bottom-trailing corner.
    ///
    /// Installed from here rather than from inside the window's own view tree, for two reasons:
    /// no shipping controller then carries a diagnostic child it has to know about, and the
    /// readout is switched on beside the watchdog whose events it draws, so the pair cannot drift
    /// apart. Ordered explicitly above its siblings — panes are added to this same content view,
    /// and a readout the app can cover is a readout that is not telling you anything.
    private func installMainThreadStallHUD(on controller: MainWindowController) {
        guard let content = controller.window?.contentView else { return }

        let hud = MainThreadStallHUDView()
        content.addSubview(hud, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            hud.trailingAnchor.constraint(
                equalTo: content.trailingAnchor,
                constant: -MainThreadStallHUDDefaults.margin
            ),
            hud.bottomAnchor.constraint(
                equalTo: content.bottomAnchor,
                constant: -MainThreadStallHUDDefaults.margin
            )
        ])
    }
#endif
}

#if DEBUG
/// The only whole-app fixture entry point.
///
/// A UI scenario is allowed to replace one provider process only when every mutable artifact
/// resolves below the disposable Cocoa home created by the test runner, and the executable is
/// the helper sealed inside this app bundle. A partial or tampered contract terminates before
/// the window can restore a session, which is the fail-closed boundary that prevents a broken
/// test from launching the developer's real Codex installation.
@MainActor
private enum UIScenarioBootstrap {
    enum Result {
        case notRequested
        case installed
        case refused(String)
    }

    private enum Key {
        static let home = "THREADING_UI_SCENARIO_HOME"
        static let project = "THREADING_UI_SCENARIO_PROJECT"
        static let targetProject = "THREADING_UI_SCENARIO_TARGET_PROJECT"
        static let freshTape = "THREADING_UI_SCENARIO_FRESH_TAPE"
        static let resumeTape = "THREADING_UI_SCENARIO_RESUME_TAPE"
        static let title = "THREADING_UI_SCENARIO_TITLE"
    }

    private static let markerName = ".threading-ui-scenario-home"
    private static let sessionID = SessionID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    )

    static func installIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Result {
        let fixtureKeys = [Key.project, Key.freshTape, Key.resumeTape, Key.title]
        guard fixtureKeys.contains(where: { environment[$0] != nil }) else {
            return .notRequested
        }
        guard let homePath = environment[Key.home],
              environment["HOME"] == homePath,
              environment["CFFIXED_USER_HOME"] == homePath else {
            return .refused("scenario home does not own HOME and CFFIXED_USER_HOME")
        }
        guard let title = environment[Key.title]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              title.utf8.count <= 128,
              !title.contains("\n"),
              !title.contains("\r") else {
            return .refused("scenario title is missing or invalid")
        }

        let root = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileManager.fileExists(
            atPath: root.appendingPathComponent(markerName).path
        ) else {
            return .refused("scenario home marker is missing")
        }
        guard let project = artifact(
            Key.project,
            environment: environment,
            root: root,
            expectsDirectory: true,
            executable: false,
            fileManager: fileManager
        ), let freshTape = artifact(
            Key.freshTape,
            environment: environment,
            root: root,
            expectsDirectory: false,
            executable: false,
            fileManager: fileManager
        ), let resumeTape = artifact(
            Key.resumeTape,
            environment: environment,
            root: root,
            expectsDirectory: false,
            executable: false,
            fileManager: fileManager
        ) else {
            return .refused("one or more fixture artifacts are missing or outside scenario home")
        }
        let targetProject: URL?
        if environment[Key.targetProject] != nil {
            guard let target = artifact(
                Key.targetProject,
                environment: environment,
                root: root,
                expectsDirectory: true,
                executable: false,
                fileManager: fileManager
            ) else {
                return .refused("the target checkout is missing or outside scenario home")
            }
            targetProject = target
        } else {
            targetProject = nil
        }
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/threading-scenario")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard executable.deletingLastPathComponent() == helpers,
              fileManager.isExecutableFile(atPath: executable.path) else {
            return .refused("the signed UI scenario helper is not embedded")
        }

        switch UIScenarioEvidenceCapture.installIfRequested(
            environment: environment,
            scenarioRoot: root,
            fileManager: fileManager
        ) {
        case .installed:
            break
        case .refused(let reason):
            return .refused(reason)
        }

        guard let storedProject = ProjectStore.shared.addProject(folderURL: project) else {
            return .refused("could not persist the synthetic project")
        }
        if let targetProject,
           ProjectStore.shared.addProject(folderURL: targetProject) == nil {
            return .refused("could not persist the synthetic target checkout")
        }
        let session: AgentSession
        if let existing = ProjectStore.shared.session(withID: sessionID) {
            guard existing.usesNativeUI,
                  existing.title == title,
                  ProjectStore.shared.project(forSessionID: sessionID)?.id == storedProject.id else {
                return .refused("fixed fixture session collides with incompatible state")
            }
            session = existing
        } else {
            guard let created = ProjectStore.shared.addSession(
                to: storedProject.id,
                kind: .codex,
                usesNativeUI: true,
                title: title,
                id: sessionID
            ) else {
                return .refused("could not persist the fixture conversation")
            }
            session = created
        }

        ProjectStore.shared.selectedSessionID = sessionID
        let rootPath = root.path
        guard AgentRuntime.shared.installFixtureLaunchPlan(
            for: sessionID,
            provider: { _, _, _ in
                let current = ProjectStore.shared.session(withID: sessionID) ?? session
                let tape = current.resumeState.isResumable ? resumeTape : freshTape
                return AgentLaunchPlan(
                    executable: executable.path,
                    arguments: ["replay", tape.path, "--scenario-root", rootPath],
                    resumeState: current.resumeState
                )
            }
        ) else {
            return .refused("could not install the fixture process")
        }
        return .installed
    }

    private static func artifact(
        _ key: String,
        environment: [String: String],
        root: URL,
        expectsDirectory: Bool,
        executable: Bool,
        fileManager: FileManager
    ) -> URL? {
        guard let path = environment[key], !path.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: path, isDirectory: expectsDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue == expectsDirectory,
              !executable || fileManager.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }
}
#endif
