import AppKit
import ThreadingRemoteKit

struct PanelTabsPayload: Encodable {
  struct Tab: Encodable {
    let index: Int
    let id: String
    let kind: String
    let title: String
    let active: Bool
  }

  let count: Int
  let tabs: [Tab]
}

struct BrowserAnnotationsPayload: Encodable {
  struct Annotation: Encodable {
    struct Element: Encodable {
      let provenance: String
      let path: String?
      let role: String?
      let name: String?
    }

    let id: Int
    let note: String
    let element: Element?
    let x: Double
    let y: Double
  }

  let provenance: String
  let url: String
  let count: Int
  let annotations: [Annotation]
}

struct BrowserPageLease {
  let browser: BrowserViewController
  let tabID: UUID
  let page: BrowserPageIdentity
}

/// Process-wide services used by agent commands, assembled once at the application boundary.
///
/// Keeping these references together prevents capability handlers from becoming service
/// locators. Tests can build an isolated set and a future module split has one dependency
/// surface to replace instead of global lookups spread across every command file.
@MainActor
struct AgentToolDependencies {
  let projects: ProjectStore
  let attachments: SessionAttachmentStore
  let displayStore: DisplayPaneStore
  let extensions: ExtensionManager
  let externalTools: MCPExternalToolRegistry
  let remoteMirror: RemoteSessionMirrorRegistry
  let settings: AppSettings
  let notifications: RemoteNotificationService
  let notificationTargets: NotificationTargetRegistry
  let archiveScheduler: SessionArchiveScheduler
  let sessionCommands: AgentSessionCommandService
  let extensionInstallation: AgentExtensionInstallService
  let extensionAuthoring: ExtensionAuthoringCommandService
  let browserStorage: BrowserStorageCommandService
  let settingsCatalogue: SettingsCatalogueService
  /// The typed session control plane — scope and refusal rules for every cross-session
  /// operation, whoever the caller is. Handlers own wording only.
  let control: WorkspaceControlPlane
  let mobileDiagnosticsInspection: MobileDiagnosticsInspectionService
  /// The project's durable visual baselines. Injected rather than reached for as a singleton from
  /// the handler, so a test drives its own directory instead of the developer's.
  let baselines: BrowserBaselineStore
  /// This Mac's agent-mail store. Defaulted so existing compositions keep compiling; a test
  /// passes a mailbox in a scratch directory.
  var mail: MacMailbox = .shared

  static let live = AgentToolDependencies(
    projects: .shared,
    attachments: .shared,
    displayStore: .shared,
    extensions: .shared,
    externalTools: .shared,
    remoteMirror: .shared,
    settings: .shared,
    notifications: .shared,
    notificationTargets: .shared,
    archiveScheduler: .shared,
    sessionCommands: AgentSessionCommandService(
      projects: .shared,
      archiveScheduler: .shared,
      usesAgentTitleInSidebar: { AppSettings.usesAgentTitleInSidebar }
    ),
    extensionInstallation: AgentExtensionInstallService(
      projects: .shared, extensions: .shared, trust: .shared
    ),
    extensionAuthoring: ExtensionAuthoringCommandService(
      projects: .shared,
      sdkSnapshotURL: {
        Bundle.main.resourceURL?.appendingPathComponent(
          "ExtensionSDK/ThreadingExtensionKit",
          isDirectory: true
        )
      }
    ),
    browserStorage: BrowserStorageCommandService(),
    settingsCatalogue: SettingsCatalogueService(),
    control: .live,
    mobileDiagnosticsInspection: MobileDiagnosticsInspectionService(captures: .shared),
    baselines: .shared
  )
}

// MARK: - Agent Tool Coordinator

/// Serves the tool calls agents make against Threading's own MCP server.
///
/// Owns tool behavior without owning the window: the window supplies the narrow capabilities
/// tools actually need, while its chrome, layout, and navigation remain outside this type.
/// Called on the main queue by `MCPServer`.
@MainActor
final class AgentToolCoordinator: AgentCommandHandling, MCPBuiltInToolExecuting {

  let displayPaneController: DisplayPaneController
  var conversationRepairHandler: ConversationRepairHandler?  // see MainWindowLaunchRecovery
  var problemReporter: AgentProblemReportService?
  /// Where this session's browser actually is, across every pane that can hold one. The panel
  /// stays a separate dependency because `display_*` and `panel_*` are panel-scoped by
  /// contract; only the `browser_*` family follows the browser.
  let browserResolver: SessionBrowserResolver
  let visibleSessionID: () -> SessionID?
  let setPaneVisible: (Bool) -> Void
  /// Opens the pane that holds a given host, so a tool that drove a browser can show the user
  /// the page it drove rather than whichever pane the panel happens to be. Supplied by the
  /// window, which is the only thing that can open a pane it does not own; a coordinator built
  /// without one opens the panel and leaves other hosts alone, which is the old behaviour.
  let revealBrowserHost: (TabHostID) -> Void
  /// Bringing Threading forward, as its own seam because a password takeover has to do it and a
  /// test must not: universal autofill fills the frontmost app's focused field, so this is real
  /// behaviour rather than polish, and `NSApp.activate` in a test host steals the developer's
  /// focus for a fact no assertion could read back anyway.
  let activateApp: () -> Void
  let windowProvider: () -> NSWindow?
  let browserAccessDecisionProvider: BrowserAccessDecisionProvider?
  let browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider?
  let browserNetworkCaptureSettings: BrowserNetworkCaptureSettings
  var browserNetworkCaptureDecision: ((BrowserNetworkCaptureOptions, @escaping @MainActor (Bool) -> Void) -> Void)?
  let playwrightRunner: PlaywrightAutomationRunner
  let chromeAutomationProfile: ChromeAutomationProfile
  let dependencies: AgentToolDependencies
  var extensionInstallDecision: ((ChoiceRequest, @escaping @MainActor (Int?) -> Void) -> Void)?
  let browserAccessStore = BrowserAccessStore()
  var temporaryBrowserOrigins: [SessionID: Set<BrowserOrigin>] = [:]
  /// Each chat's latest requested notification, for its Push Test tab.
  let notificationTests = NotificationTestLedger()

  convenience init(
    displayPaneController: DisplayPaneController,
    browserResolver: SessionBrowserResolver? = nil,
    visibleSessionID: @escaping () -> SessionID?,
    setPaneVisible: @escaping (Bool) -> Void,
    revealBrowserHost: ((TabHostID) -> Void)? = nil,
    windowProvider: @escaping () -> NSWindow?,
    browserAccessDecisionProvider: BrowserAccessDecisionProvider? = nil,
    browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider? = nil,
    browserNetworkCaptureSettings: BrowserNetworkCaptureSettings = .shared,
    playwrightRunner: PlaywrightAutomationRunner = PlaywrightAutomationRunner(),
    chromeAutomationProfile: ChromeAutomationProfile = .shared,
    activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }
  ) {
    self.init(
      displayPaneController: displayPaneController,
      browserResolver: browserResolver,
      visibleSessionID: visibleSessionID,
      setPaneVisible: setPaneVisible,
      revealBrowserHost: revealBrowserHost,
      windowProvider: windowProvider,
      browserAccessDecisionProvider: browserAccessDecisionProvider,
      browserSiteDataDecisionProvider: browserSiteDataDecisionProvider,
      browserNetworkCaptureSettings: browserNetworkCaptureSettings,
      playwrightRunner: playwrightRunner,
      chromeAutomationProfile: chromeAutomationProfile,
      activateApp: activateApp,
      dependencies: .live
    )
  }

  init(
    displayPaneController: DisplayPaneController,
    browserResolver: SessionBrowserResolver? = nil,
    visibleSessionID: @escaping () -> SessionID?,
    setPaneVisible: @escaping (Bool) -> Void,
    revealBrowserHost: ((TabHostID) -> Void)? = nil,
    windowProvider: @escaping () -> NSWindow?,
    browserAccessDecisionProvider: BrowserAccessDecisionProvider?,
    browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider?,
    browserNetworkCaptureSettings: BrowserNetworkCaptureSettings = .shared,
    playwrightRunner: PlaywrightAutomationRunner,
    chromeAutomationProfile: ChromeAutomationProfile = .shared,
    activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
    dependencies: AgentToolDependencies
  ) {
    self.displayPaneController = displayPaneController
    // Panel-only when the caller names no other host: a coordinator built without a window has
    // no other host to name, which is exactly the shape every test uses.
    self.browserResolver = browserResolver ?? SessionBrowserResolver(panel: displayPaneController)
    self.visibleSessionID = visibleSessionID
    self.setPaneVisible = setPaneVisible
    self.revealBrowserHost = revealBrowserHost ?? { hostID in
      guard hostID == .displayPanel else { return }
      setPaneVisible(true)
    }
    self.activateApp = activateApp
    self.windowProvider = windowProvider
    self.browserAccessDecisionProvider = browserAccessDecisionProvider
    self.browserSiteDataDecisionProvider = browserSiteDataDecisionProvider
    self.browserNetworkCaptureSettings = browserNetworkCaptureSettings
    self.playwrightRunner = playwrightRunner
    self.chromeAutomationProfile = chromeAutomationProfile
    self.dependencies = dependencies
    displayPaneController.notificationTestHost = self
  }

  var presentationWindow: NSWindow? { windowProvider() }

  /// Compatibility entry point for synchronous application callers. It still executes through
  /// the declaration and the shared observation wrapper; asynchronous tools return an explicit
  /// failure instead of pretending their result was ready.
  func handle(_ call: MCPToolCall, for sessionID: SessionID) -> MCPToolResult {
    var result: MCPToolResult?
    executeBuiltIn(call, for: sessionID) { result = $0 }
    return result ?? .failure("\(call.name) completes asynchronously.")
  }

  func handle(
    _ call: MCPToolCall,
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    executeBuiltIn(call, for: sessionID, completion: completion)
  }

  /// Applies privacy-preserving tracing, remote projection, panel observation, and optional
  /// before-capture around the declaration's typed implementation.
  func executeBuiltIn(
    _ call: MCPToolCall, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    let traceStartedAt = Date()
    let shouldTrace =
      call.builtInTool?.family == .browser
      && call.builtInTool != .browserTrace
    let traceDetail = shouldTrace ? call.browserTraceDetail : nil
    let initialTraceBrowser =
      shouldTrace
      ? browserResolver.browser(for: sessionID)
      : nil
    let workspaceEffect = call.browserWorkspaceEffect
    // A tool that reads or changes the panel means the agent's transcript now reflects it, so
    // record that: a later resume only re-describes the panel if the user changed it in between.
    let observed: @MainActor @Sendable (MCPToolResult) -> Void = { [weak self] result in
      if shouldTrace {
        let browser =
          self?.browserResolver.browser(for: sessionID)
          ?? initialTraceBrowser
        browser?.recordAgentToolTrace(
          name: call.name,
          detail: traceDetail,
          startedAt: traceStartedAt,
          succeeded: !result.isError
        )
      }
      if !result.isError {
        switch workspaceEffect {
        case .none:
          break
        case .invalidate:
          self?.dependencies.remoteMirror.workspaceBrowserChanged(
            sessionID,
            announcesActivity: false
          )
        case .announce:
          self?.dependencies.remoteMirror.workspaceBrowserChanged(
            sessionID,
            announcesActivity: true
          )
        }
      }
      self?.markPanelObserved(sessionID)
      completion(result)
    }

    // The page as it stands *before* an agent changes it, when the user has asked for that. It
    // has to happen here rather than inside each command: this is the one place that sees the call
    // before it runs, and a before-shot taken after the fact is not a before-shot.
    if let tool = call.builtInTool,
      BrowserAutoCaptureDefaults.mutatingTools.contains(tool),
      dependencies.settings.capturesPageBeforeAgentActions,
      let browser = loadedBrowser(for: sessionID) {
      captureBeforeAgentAction(tool, in: browser, for: sessionID) { [weak self] in
        self?.dispatch(call, for: sessionID, completion: observed, plain: completion)
      }
      return
    }
    dispatch(call, for: sessionID, completion: observed, plain: completion)
  }

  /// Takes the before-shot and then runs the action, whatever the capture did.
  ///
  /// A failed capture never blocks the tool. The history is a convenience, and refusing to click
  /// because a screenshot did not come back would trade a real capability for an optional one.
  private func captureBeforeAgentAction(
    _ tool: MCPBuiltInTool,
    in browser: BrowserViewController,
    for sessionID: SessionID,
    then run: @escaping @MainActor () -> Void
  ) {
    Task { @MainActor in
      if let capture = try? await browser.captureBaseline(kind: .viewport) {
        BrowserAutoCaptureRing.shared.record(
          action: tool.rawValue,
          pngData: capture.pngData,
          conditions: capture.conditions,
          for: sessionID
        )
      }
      run()
    }
  }

  private func dispatch(
    _ call: MCPToolCall,
    for sessionID: SessionID,
    completion observed: @escaping @MainActor @Sendable (MCPToolResult) -> Void,
    plain completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    call.execute(
      with: self,
      for: sessionID,
      completion: call.observesPanel ? observed : completion
    )
  }

  func handleExternalTool(
    named name: String,
    arguments: MCPJSONValue,
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    let routed = dependencies.externalTools.invokeTool(
      named: name,
      arguments: arguments,
      for: sessionID
    ) { response in
      completion(response.isError ? .failure(response.text) : .success(response.text))
    }
    if !routed {
      completion(.failure("Unknown tool: \(name)"))
    }
  }

  // MARK: Panel State

  /// Describes the session's display panel for the `initialize` instructions — but only when it
  /// changed since the agent last saw it, so a resume does not repeat what the transcript shows.
  func panelState(for sessionID: SessionID) -> String {
    guard let panel = dependencies.displayStore.loadLayout(for: sessionID),
      !panel.tabs.isEmpty
    else {
      return ""
    }

    let signature = panel.signature
    guard signature != dependencies.displayStore.observedSignature(for: sessionID) else {
      return ""
    }

    // The agent is being told now, so the panel counts as observed — an unchanged later resume
    // then stays quiet.
    dependencies.displayStore.setObserved(signature, for: sessionID)
    return "\n\n" + panel.agentDescription
  }

  private func markPanelObserved(_ sessionID: SessionID) {
    dependencies.displayStore.setObserved(
      dependencies.displayStore.signature(for: sessionID),
      for: sessionID
    )
  }

  func copyToClipboard(
    _ arguments: CopyToClipboardArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    dependencies.remoteMirror.copyToClipboard(
      text: arguments.text, target: arguments.target,
      sessionID: sessionID,
      participantID: dependencies.notifications.clipboardParticipantID(for: sessionID),
      completion: completion
    )
  }
}
