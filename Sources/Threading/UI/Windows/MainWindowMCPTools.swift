import AppKit

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
  let archiveScheduler: SessionArchiveScheduler
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
    archiveScheduler: .shared,
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
  let visibleSessionID: () -> SessionID?
  let setPaneVisible: (Bool) -> Void
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
    visibleSessionID: @escaping () -> SessionID?,
    setPaneVisible: @escaping (Bool) -> Void,
    windowProvider: @escaping () -> NSWindow?,
    browserAccessDecisionProvider: BrowserAccessDecisionProvider? = nil,
    browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider? = nil,
    playwrightRunner: PlaywrightAutomationRunner = PlaywrightAutomationRunner(),
    chromeAutomationProfile: ChromeAutomationProfile = .shared,
    activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }
  ) {
    self.init(
      displayPaneController: displayPaneController,
      visibleSessionID: visibleSessionID,
      setPaneVisible: setPaneVisible,
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
    visibleSessionID: @escaping () -> SessionID?,
    setPaneVisible: @escaping (Bool) -> Void,
    windowProvider: @escaping () -> NSWindow?,
    browserAccessDecisionProvider: BrowserAccessDecisionProvider?,
    browserSiteDataDecisionProvider: BrowserSiteDataDecisionProvider?,
    playwrightRunner: PlaywrightAutomationRunner,
    chromeAutomationProfile: ChromeAutomationProfile = .shared,
    activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
    dependencies: AgentToolDependencies
  ) {
    self.displayPaneController = displayPaneController
    self.visibleSessionID = visibleSessionID
    self.setPaneVisible = setPaneVisible
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
      ? displayPaneController.browser(for: sessionID)
      : nil
    let workspaceEffect = browserWorkspaceEffect(for: call)
    // A tool that reads or changes the panel means the agent's transcript now reflects it, so
    // record that: a later resume only re-describes the panel if the user changed it in between.
    let observed: @MainActor @Sendable (MCPToolResult) -> Void = { [weak self] result in
      if shouldTrace {
        let browser =
          self?.displayPaneController.browser(for: sessionID)
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
    guard dependencies.settings.remoteAccessEnabled else {
      return .failure("Remote Access is off, so no paired device can be notified.")
    }
    switch dependencies.notifications.notifyRequested(
      sessionID: sessionID,
      title: arguments.title,
      body: message,
      recipient: arguments.recipient
    ) {
    case .delivered(let recipient):
      return .success("Notification queued for \(recipient).")
    case .unavailable(let reason):
      return .failure(reason)
    }
  }

}
