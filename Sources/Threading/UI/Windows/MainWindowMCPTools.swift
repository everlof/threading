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

struct BrowserTabsPayload: Encodable {
  struct Viewport: Encodable {
    let width: Int
    let height: Int
  }

  struct Tab: Encodable {
    let index: Int
    let id: String
    let title: String
    let url: String?
    let active: Bool
    let restricted: Bool
    let popupDepth: Int
    let viewport: Viewport?
    let colorScheme: String
    let userAgent: String?
    let mediaType: String
    let context: String

    private enum CodingKeys: String, CodingKey {
      case index, id, title, url, active, restricted, viewport, context
      case popupDepth = "popup_depth"
      case colorScheme = "color_scheme"
      case userAgent = "user_agent"
      case mediaType = "media_type"
    }
  }

  let count: Int
  let tabs: [Tab]
}

struct BrowserCapabilitiesPayload: Encodable {
  struct ActiveTab: Encodable {
    let backend: String
    let context: String
    let viewport: BrowserTabsPayload.Viewport?
    let colorScheme: String
    let userAgent: String?
    let mediaType: String

    private enum CodingKeys: String, CodingKey {
      case backend, context, viewport
      case colorScheme = "color_scheme"
      case userAgent = "user_agent"
      case mediaType = "media_type"
    }
  }

  struct Backend: Encodable {
    let id: String
    let status: String
    let engine: String
    let intendedUse: String
    let contexts: [String]
    let emulation: [String: Bool]
    let automation: [String: Bool]
    let limits: [String]

    private enum CodingKeys: String, CodingKey {
      case id, status, engine, contexts, emulation, automation, limits
      case intendedUse = "intended_use"
    }
  }

  /// Whether `browser_fill_credentials` can do anything on this machine, so an agent can find
  /// out before it asks rather than discovering it through a refusal.
  ///
  /// It reports the *provider* and whether the vault holds anything at all — never which origins
  /// have entries, which would let a page enumerate where the user keeps test accounts.
  struct SignIn: Encodable {
    let provider: String
    let fillsWithoutUser: Bool
    let hasStoredCredentials: Bool
    let vaultReachableFromShell: Bool

    private enum CodingKeys: String, CodingKey {
      case provider
      case fillsWithoutUser = "fills_without_user"
      case hasStoredCredentials = "has_stored_credentials"
      case vaultReachableFromShell = "vault_reachable_from_shell"
    }
  }

  let schemaVersion: Int
  let defaultBackend: String
  let activeTab: ActiveTab?
  let signIn: SignIn
  let backends: [Backend]

  private enum CodingKeys: String, CodingKey {
    case backends
    case schemaVersion = "schema_version"
    case defaultBackend = "default_backend"
    case activeTab = "active_tab"
    case signIn = "sign_in"
  }
}

struct BrowserAnnotationsPayload: Encodable {
  struct Annotation: Encodable {
    let id: Int
    let note: String
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
  /// The typed session control plane — scope and refusal rules for every cross-session
  /// operation, whoever the caller is. Handlers own wording only.
  let control: WorkspaceControlPlane
  /// The project's durable visual baselines. Injected rather than reached for as a singleton from
  /// the handler, so a test drives its own directory instead of the developer's.
  let baselines: BrowserBaselineStore

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
    control: .live,
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
final class AgentToolCoordinator: AgentCommandHandling {

  private enum BrowserWorkspaceEffect {
    case none
    case invalidate
    case announce
  }

  let displayPaneController: DisplayPaneController
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
  let playwrightRunner: PlaywrightAutomationRunner
  let chromeAutomationProfile: ChromeAutomationProfile
  let dependencies: AgentToolDependencies
  let browserAccessStore = BrowserAccessStore()
  var temporaryBrowserOrigins: [SessionID: Set<BrowserOrigin>] = [:]

  convenience init(
    displayPaneController: DisplayPaneController,
    browserResolver: SessionBrowserResolver? = nil,
    visibleSessionID: @escaping () -> SessionID?,
    setPaneVisible: @escaping (Bool) -> Void,
    revealBrowserHost: ((TabHostID) -> Void)? = nil,
    windowProvider: @escaping () -> NSWindow?,
    browserAccessDecisionProvider: BrowserAccessDecisionProvider? = nil,
    browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider? = nil,
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
    self.playwrightRunner = playwrightRunner
    self.chromeAutomationProfile = chromeAutomationProfile
    self.dependencies = dependencies
  }

  var presentationWindow: NSWindow? { windowProvider() }

  /// A trace is useful only if it explains the kind of operation, but target text and form
  /// values can be sensitive. Keep this deliberately structural: refs are safe identifiers;
  /// selectors, semantic names, URLs, typed values and baseline paths are never copied here.
  private func browserTraceDetail(for call: MCPToolCall) -> String? {
    func target(
      ref: String?,
      selector: String?,
      locator: BrowserSemanticLocator?
    ) -> String {
      if let ref, !ref.isEmpty { return "target ref \(String(ref.prefix(40)))" }
      if selector?.isEmpty == false { return "strict selector target" }
      if locator != nil { return "semantic locator target" }
      return "page"
    }

    switch call {
    case .browserNavigate(let arguments):
      return "navigate; wait=\(arguments.waitUntil ?? "load")"
    case .browserHistory(let arguments):
      return "\(arguments.action ?? "unknown"); wait=\(arguments.waitUntil ?? "load")"
    case .browserStop:
      return "stop outstanding resources"
    case .browserTabs(let arguments):
      return "action=\(arguments.action ?? "unknown"); context=\(arguments.context ?? "shared")"
    case .browserStorage(let arguments):
      return "action=\(arguments.action ?? "unknown")"
    case .browserUpload(let arguments):
      return "\(arguments.paths?.count ?? 0) suggested paths; "
        + target(
          ref: arguments.ref,
          selector: arguments.selector,
          locator: arguments.locator
        )
    case .browserDownload(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      )
    case .browserResize(let arguments):
      if let width = arguments.width, let height = arguments.height {
        return "viewport \(width)×\(height)"
      }
      return "reset viewport"
    case .browserEmulate(let arguments):
      var changes: [String] = []
      if arguments.colorScheme != nil { changes.append("color scheme") }
      if arguments.mediaType != nil { changes.append("media") }
      if arguments.userAgent != nil { changes.append("user agent") }
      return changes.isEmpty ? "no condition" : changes.joined(separator: ", ")
    case .browserCapabilities:
      return "backend capability matrix"
    case .browserRunIsolated(let arguments):
      return "\(arguments.steps?.count ?? 0) isolated Playwright steps"
    case .browserAttachChrome(let arguments):
      return "\(arguments.steps?.count ?? 0) attached Chrome steps across "
        + "\(arguments.allowedOrigins?.count ?? 0) authorized origins"
    case .browserSnapshot(let arguments):
      return target(ref: arguments.ref, selector: arguments.selector, locator: nil)
    case .browserAnnotations:
      return "user-authored page notes"
    case .browserScreenshot(let arguments):
      if arguments.fullPage == true { return "full page" }
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      )
    case .browserVisualCompare(let arguments):
      if arguments.fullPage == true { return "full-page visual comparison" }
      return "visual comparison; "
        + target(
          ref: arguments.ref,
          selector: arguments.selector,
          locator: arguments.locator
        )
    // Names the action and how the baseline was addressed, never the baseline's own name: a
    // name is the user's words, and the trace is deliberately structural.
    case .browserBaselines(let arguments):
      let addressed = arguments.baselineID != nil ? "by id" : "by name"
      return "\(arguments.action ?? "list"); \(addressed)"
    case .browserQuery:
      return "CSS query"
    case .browserClick(let arguments):
      if arguments.x != nil { return "viewport coordinates" }
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      )
    case .browserHover(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      )
    case .browserDrag(let arguments):
      let source = target(
        ref: arguments.sourceRef,
        selector: arguments.sourceSelector,
        locator: arguments.sourceLocator
      )
      let destination = target(
        ref: arguments.targetRef,
        selector: arguments.targetSelector,
        locator: arguments.targetLocator
      )
      return "\(source) to \(destination)"
    case .browserType(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      ) + "; \(arguments.text?.count ?? 0) characters"
    case .browserFillForm(let arguments):
      return "\(arguments.fields?.count ?? 0) fields"
    // The trace deliberately records that a credential fill happened and nothing about which
    // one: it already omits locator names and field values, and an account label is the user's
    // own words about an account.
    case .browserFillCredentials(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      ) + "; stored credential"
    case .browserSelect(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      ) + (arguments.label != nil ? "; by label" : "; by value")
    case .browserSetChecked(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      ) + "; checked=\(arguments.checked.map(String.init) ?? "missing")"
    case .browserPressKey(let arguments):
      return target(
        ref: arguments.ref,
        selector: arguments.selector,
        locator: arguments.locator
      ) + "; key category=\((arguments.key?.count ?? 0) == 1 ? "character" : "named")"
    case .browserScroll(let arguments):
      return "\(arguments.direction ?? "down"); "
        + target(
          ref: arguments.ref,
          selector: arguments.selector,
          locator: arguments.locator
        )
    case .browserWait(let arguments):
      if arguments.time != nil { return "fixed duration" }
      if arguments.text != nil { return "page text present" }
      if arguments.textGone != nil { return "page text absent" }
      if arguments.url != nil { return "exact URL" }
      if arguments.urlContains != nil { return "partial URL" }
      if arguments.urlMatches != nil { return "URL regex" }
      if arguments.title != nil { return "exact title" }
      if arguments.titleContains != nil { return "partial title" }
      if arguments.responseURLContains != nil || arguments.responseStatus != nil {
        return "network response"
      }
      if arguments.count != nil { return "selector count" }
      return "element condition"
    case .browserConsole:
      return "console metadata"
    case .browserNetwork:
      return "network metadata"
    case .browserPerformance(let arguments):
      return
        "up to \(arguments.maximumResources ?? BrowserAgentDefaults.defaultPerformanceResources) resources"
    case .browserAccessibilityAudit(let arguments):
      return
        "up to \(arguments.maximumIssues ?? BrowserAgentDefaults.defaultAccessibilityAuditIssues) issues"
    default:
      return nil
    }
  }

  private func browserWorkspaceEffect(for call: MCPToolCall) -> BrowserWorkspaceEffect {
    switch call {
    case .browserNavigate, .browserHistory:
      return .announce
    case .browserTabs(let arguments):
      switch arguments.action?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      {
      case "new":
        return .announce
      case "activate", "close":
        return .invalidate
      default:
        return .none
      }
    case .browserStop, .browserStorage, .browserUpload, .browserDownload,
      .browserResize, .browserEmulate, .browserClick, .browserHover,
      .browserDrag, .browserType, .browserFillForm, .browserSelect,
      .browserSetChecked, .browserPressKey, .browserScroll:
      return .invalidate
    default:
      return .none
    }
  }

  func handle(_ call: MCPToolCall, for sessionID: SessionID) -> MCPToolResult {
    switch call {
    case .displayImage(let arguments):
      return displayImage(arguments, for: sessionID)
    case .displayChart(let arguments):
      return displayChart(arguments, for: sessionID)
    case .displayScene(let arguments):
      return displayScene(arguments, for: sessionID)
    case .displayHTML(let arguments):
      return displayHTML(arguments, for: sessionID)
    case .displayCompareFiles(let arguments):
      return displayCompareFiles(arguments, for: sessionID)
    case .conversationHistory:
      return .failure("Conversation history is loaded asynchronously; retry the tool call.")
    default:
      return .failure("Unknown tool: \(call.name)")
    }
  }

  /// Async entry point: the browser tools finish on a page load, a DOM query, or a snapshot;
  /// everything else answers synchronously and is forwarded to `handle(_:for:)`.
  func handle(
    _ call: MCPToolCall, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    let traceStartedAt = Date()
    let shouldTrace =
      call.builtInTool?.family == .browser
      && call.builtInTool != .browserTrace
    let traceDetail = shouldTrace ? browserTraceDetail(for: call) : nil
    let initialTraceBrowser =
      shouldTrace
      ? browserResolver.browser(for: sessionID)
      : nil
    let workspaceEffect = browserWorkspaceEffect(for: call)
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
    switch call {
    case .conversationHistory(let arguments):
      ConversationContinuation.loadHistoryPage(
        for: sessionID,
        cursor: arguments.cursor
      ) { result in
        switch result {
        case .success(let page): completion(.success(page))
        case .failure(let error): completion(.failure(error.message))
        }
      }
    case .browserNavigate(let arguments):
      browserNavigate(arguments, for: sessionID, completion: observed)
    case .browserHistory(let arguments):
      browserHistory(arguments, for: sessionID, completion: observed)
    case .browserStop:
      browserStop(for: sessionID, completion: observed)
    case .browserTabs(let arguments):
      observed(browserTabs(arguments, for: sessionID))
    case .browserStorage(let arguments):
      browserStorage(arguments, for: sessionID, completion: observed)
    case .browserTrace(let arguments):
      observed(browserTrace(arguments, for: sessionID))
    case .browserUpload(let arguments):
      browserUpload(arguments, for: sessionID, completion: observed)
    case .browserDownload(let arguments):
      browserDownload(arguments, for: sessionID, completion: observed)
    case .browserResize(let arguments):
      browserResize(arguments, for: sessionID, completion: observed)
    case .browserEmulate(let arguments):
      browserEmulate(arguments, for: sessionID, completion: observed)
    case .browserCapabilities:
      observed(browserCapabilities(for: sessionID))
    case .browserRunIsolated(let arguments):
      browserRunIsolated(arguments, for: sessionID, completion: observed)
    case .browserAttachChrome(let arguments):
      browserAttachChrome(arguments, for: sessionID, completion: observed)
    case .browserSnapshot(let arguments):
      browserSnapshot(arguments, for: sessionID, completion: observed)
    case .browserAnnotations:
      browserAnnotations(for: sessionID, completion: observed)
    case .browserQuery(let arguments):
      browserQuery(arguments, for: sessionID, completion: observed)
    case .browserClick(let arguments):
      browserClick(arguments, for: sessionID, completion: observed)
    case .browserHover(let arguments):
      browserHover(arguments, for: sessionID, completion: observed)
    case .browserDrag(let arguments):
      browserDrag(arguments, for: sessionID, completion: observed)
    case .browserType(let arguments):
      browserType(arguments, for: sessionID, completion: observed)
    case .browserFillForm(let arguments):
      browserFillForm(arguments, for: sessionID, completion: observed)
    case .browserFillCredentials(let arguments):
      browserFillCredentials(arguments, for: sessionID, completion: observed)
    case .browserSelect(let arguments):
      browserSelect(arguments, for: sessionID, completion: observed)
    case .browserSetChecked(let arguments):
      browserSetChecked(arguments, for: sessionID, completion: observed)
    case .browserPressKey(let arguments):
      browserPressKey(arguments, for: sessionID, completion: observed)
    case .browserScroll(let arguments):
      browserScroll(arguments, for: sessionID, completion: observed)
    case .browserWait(let arguments):
      browserWait(arguments, for: sessionID, completion: observed)
    case .browserConsole(let arguments):
      browserConsole(arguments, for: sessionID, completion: observed)
    case .browserNetwork(let arguments):
      browserNetwork(arguments, for: sessionID, completion: observed)
    case .browserPerformance(let arguments):
      browserPerformance(arguments, for: sessionID, completion: observed)
    case .browserAccessibilityAudit(let arguments):
      browserAccessibilityAudit(arguments, for: sessionID, completion: observed)
    case .browserScreenshot(let arguments):
      browserScreenshot(arguments, for: sessionID, completion: observed)
    case .browserVisualCompare(let arguments):
      browserVisualCompare(arguments, for: sessionID, completion: observed)
    case .browserBaselines(let arguments):
      browserBaselines(arguments, for: sessionID, completion: observed)
    case .panelListTabs:
      observed(panelListTabs(for: sessionID))
    case .panelActivateTab(let arguments):
      observed(panelActivateTab(arguments, for: sessionID))
    case .setProjectIcon(let arguments):
      setProjectIcon(arguments, for: sessionID, completion: completion)
    case .archiveSession(let arguments):
      completion(archiveSession(arguments, for: sessionID))
    case .cancelSessionArchive:
      completion(cancelSessionArchive(for: sessionID))
    case .setSessionName(let arguments):
      completion(setSessionName(arguments, for: sessionID))
    case .listSessions:
      // Not `observed`: a listing is not panel content, and marking the panel seen here
      // would suppress the description a later resume owes the agent.
      completion(listProjectSessions(for: sessionID))
    case .sendToSession(let arguments):
      // Answers only once the delivery is confirmed or honestly unconfirmed — a terminal
      // send waits on the target's own turn-started receipt.
      sendToSession(arguments, for: sessionID, completion: completion)
    case .watchSession(let arguments):
      completion(watchSession(arguments, for: sessionID))
    case .listReclaimableStorage:
      completion(listReclaimableStorage())
    case .listSettings:
      // Not `observed`: the catalogue is not panel content, and marking the panel seen here
      // would suppress the description a later resume owes the agent.
      completion(listSettings())
    case .proposeStorageCleanup(let arguments):
      // Answers only once the user has decided, so the agent's next turn knows the
      // outcome rather than assuming one.
      proposeStorageCleanup(arguments, completion: completion)
    case .notifyUser(let arguments):
      completion(notifyUser(arguments, for: sessionID))
    case .listThemes:
      // Not `observed`: a theme is not panel content, and marking the panel seen here
      // would suppress the description a later resume owes the agent.
      completion(listThemes(for: sessionID))
    case .setTheme(let arguments):
      completion(setTheme(arguments, for: sessionID))
    case .createTheme(let arguments):
      completion(createTheme(arguments, for: sessionID))
    case .listAppThemes:
      completion(listAppThemes())
    case .getAppTheme(let arguments):
      completion(getAppTheme(arguments))
    case .setAppTheme(let arguments):
      completion(setAppTheme(arguments))
    case .createAppTheme(let arguments):
      completion(createAppTheme(arguments))
    case .duplicateAppTheme(let arguments):
      completion(duplicateAppTheme(arguments))
    case .updateAppTheme(let arguments):
      completion(updateAppTheme(arguments))
    case .extensionListComponents:
      completion(extensionListComponents())
    case .extensionScaffoldProject(let arguments):
      completion(extensionScaffoldProject(arguments))
    case .extensionProposeInstall(let arguments):
      extensionProposeInstall(arguments, completion: completion)
    case .extensionDescribeComponent(let arguments):
      completion(extensionDescribeComponent(arguments))
    case .extensionValidateComponentPatch(let arguments):
      completion(extensionValidateComponentPatch(arguments))
    case .extensionPreviewComponentPatch(let arguments):
      observed(extensionPreviewComponentPatch(arguments, for: sessionID))
    case .unknown(let name, let arguments):
      let routed = dependencies.externalTools.invokeTool(
        named: name,
        arguments: arguments,
        for: sessionID
      ) { response in
        completion(
          response.isError
            ? .failure(response.text)
            : .success(response.text))
      }
      if !routed {
        completion(.failure("Unknown tool: \(name)"))
      }
    default:
      observed(handle(call, for: sessionID))
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

  private func notifyUser(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> MCPToolResult {
    guard
      let message = arguments.message?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else {
      return .failure("message is required.")
    }
    guard message.utf8.count <= RemoteAccessDefaults.maximumNotificationBodyBytes else {
      return .failure("message is too long for a notification.")
    }
    if let title = arguments.title,
      title.utf8.count > RemoteAccessDefaults.maximumNotificationTitleBytes
    {
      return .failure("title is too long for a notification.")
    }
    let delivery = RequestedNotificationDelivery(arguments.delivery)
    guard let delivery else {
      return .failure("delivery must be auto, mac, ios, or both.")
    }

    let destination: RemoteNotificationDestinationDTO
    if let rawReference = arguments.targetRef?
      .trimmingCharacters(in: .whitespacesAndNewlines), !rawReference.isEmpty {
      guard let resolved = dependencies.notificationTargets.resolve(
        rawReference,
        for: sessionID
      ) else {
        return .failure(
          "target_ref is unknown, expired, or belongs to another session. "
            + "Use the reference returned by the display or browser tool in this chat."
        )
      }
      destination = resolved
    } else {
      destination = .session
    }

    let eventID = UUID().uuidString.lowercased()
    var receipts: [String] = []
    var failures: [String] = []

    if delivery.includesMac {
      if dependencies.notifications.requestedRecipientIncludesOwner(
        sessionID: sessionID,
        recipient: arguments.recipient
      ) {
        let queued = AttentionAlertCenter.shared.postRequestedUpdate(
          eventID: eventID,
          sessionID: sessionID,
          title: arguments.title,
          body: message,
          destination: destination
        )
        if queued {
          receipts.append("the Mac")
        } else {
          failures.append("Mac notifications are disabled or this chat is muted")
        }
      } else {
        failures.append("the selected recipient is not the Mac owner")
      }
    }

    if delivery.includesIOS {
      guard dependencies.settings.remoteAccessEnabled else {
        failures.append("Remote Access is off")
        if receipts.isEmpty { return .failure(failures.joined(separator: "; ") + ".") }
        return .success(
          "Notification queued for \(receipts.joined(separator: " and ")); "
            + failures.joined(separator: "; ") + "."
        )
      }
      switch dependencies.notifications.notifyRequested(
        sessionID: sessionID,
        title: arguments.title,
        body: message,
        recipient: arguments.recipient,
        destination: destination
      ) {
      case .delivered(let recipient):
        receipts.append(recipient)
      case .unavailable(let reason):
        failures.append(reason)
      }
    }

    guard !receipts.isEmpty else {
      return .failure(failures.joined(separator: "; "))
    }
    let partial = failures.isEmpty ? "" : "; " + failures.joined(separator: "; ")
    return .success("Notification queued for \(receipts.joined(separator: " and "))\(partial).")
  }

}

private enum RequestedNotificationDelivery: Equatable {
  case mac
  case ios
  case both

  init?(_ rawValue: String?) {
    switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "", "auto", "both": self = .both
    case "mac": self = .mac
    case "ios", "iphone", "phone": self = .ios
    default: return nil
    }
  }

  var includesMac: Bool { self == .mac || self == .both }
  var includesIOS: Bool { self == .ios || self == .both }
}
