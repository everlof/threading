import AppKit
import ThreadingExtensionKit

// MARK: - Tab Host Identity

/// Which pane of the window hosts a tab.
///
/// A tab's host is stated *beside* the tab rather than stored in it: the tab describes what it
/// shows, and whichever host currently holds it decides where that appears. Multi-window support
/// would wrap this in a reference that also names a window — nothing in the tab model needs a
/// window today, which is exactly what keeps one possible tomorrow.
enum TabHostID: Hashable {
  /// The display panel on the right split item.
  case displayPanel
  /// The drawer strip at the content pane's bottom edge.
  case drawer
  /// A browser window detached from the main window, named by its own id because a session may
  /// have more than one. Unlike the two panes, this host is *pinned* to one session rather than
  /// following the selection — see `DetachedBrowserHostViewController`.
  case detachedWindow(UUID)
}

// MARK: - Display Content

/// One piece of content shown in the panel.
struct DisplayContent {

  /// What is being shown, which decides both the view used and the actions offered.
  enum Body {
    /// An image on disk. The URL is kept so the panel can act on the file itself —
    /// reveal it, copy its path, open it elsewhere.
    case image(NSImage, url: URL)

    /// A self-contained HTML document the agent generated.
    case html(String)

    /// A bounded semantic visualization rendered entirely by Threading's native design system.
    case semanticScene(ExtensionScene)

    /// Measured values an agent asked Threading to chart. The tab keeps the *values*: the
    /// scale, the axes and every colour are resolved by the design system when it is shown,
    /// so a restored chart follows the theme it is restored into rather than the one it was
    /// drawn in.
    case chart(ChartSpec)
  }

  let body: Body

  /// The agent's own caption, when it supplied one.
  let title: String?

  /// What was shown, in the app's words rather than the agent's.
  let subtitle: String
}

// MARK: - Pane Tab

/// One tab in a tab-hosting pane. A tab is either a piece of rendered content — an image or an
/// HTML document — or a live surface (the browser, the git review), which is a whole view
/// controller rather than a value.
///
/// A reference type, because a live tab owns a view controller whose state — a browser's page
/// and history, a review's mode and scroll position — must survive the tab being switched off
/// screen and back. The same object also survives the tab *moving between hosts*: a transfer
/// reparents the hosted controller, it never rebuilds it.
@MainActor
final class PaneTab {

  enum Body {
    case content(DisplayContent)
    case browser(BrowserViewController)
    case audit(ExecutionAuditViewController)
    case review(GitReviewViewController)
    case overview(SessionOverviewViewController)
    case terminal(ShellDrawerViewController)
    case attachments(SessionAttachmentsViewController)
    case subagents(SubagentTranscriptViewController)
    case sharing(SessionSharingViewController)
    case supervision(SupervisionListViewController)
    case simulator(SimulatorPaneViewController)
    case notificationTest(NotificationTestViewController)
    case nativePlugin(NativePluginPaneViewController)
    case extensionPanel(ExtensionPanelViewController)
    case compare(CompareViewController)
    case browserComparison(BrowserComparisonViewController)
  }

  let id: UUID
  var body: Body

  /// The session a tab belongs to, kept on the tab because a *moved* tab must still know:
  /// its shell and browser context stay the session's, and the session's deletion is what
  /// ends it, wherever it is hosted.
  var owningSessionID: SessionID?

  /// For an image tab: the PNG filename cached on disk, kept so it can be removed when the tab
  /// closes and re-loaded when the session is restored.
  var cacheFile: String?

  init(id: UUID = UUID(), body: Body, owningSessionID: SessionID? = nil) {
    self.id = id
    self.body = body
    self.owningSessionID = owningSessionID
  }

  var content: DisplayContent? {
    if case .content(let content) = body { return content }
    return nil
  }

  var browser: BrowserViewController? {
    if case .browser(let browser) = body { return browser }
    if case .audit(let audit) = body { return audit.browser }
    return nil
  }

  /// Whether an agent's `browser_*` tools should be pointed at this tab's browser.
  ///
  /// Not the same question as `browser != nil`, and the difference is a bug that shipped. An
  /// audit tab owns a live browser so its split mode can put tool calls beside the page they
  /// affected — but in plain audit mode that browser is hidden and has never loaded anything.
  /// Opening the Execution audit made it the panel's *active* tab, so it became the session's
  /// preferred browser, and every lease-gated tool then answered "No authorized page is loaded"
  /// about a page still sitting in the browser tab beside it.
  ///
  /// Enumeration deliberately still counts an audit tab as browser-bearing (`browser`): a lease
  /// re-checking where its browser lives must find it whatever kind of tab holds it. Only
  /// *preference* — which browser a new action reaches for — is narrowed here.
  var holdsAgentDrivableBrowser: Bool {
    if case .audit(let audit) = body { return audit.mode == .browserSplit }
    return browser != nil
  }

  var audit: ExecutionAuditViewController? {
    if case .audit(let audit) = body { return audit }
    return nil
  }

  var review: GitReviewViewController? {
    if case .review(let review) = body { return review }
    return nil
  }

  var overview: SessionOverviewViewController? {
    if case .overview(let overview) = body { return overview }
    return nil
  }

  /// Compatibility accessors for callers that need the selected section's existing controller.
  /// They never create the other section merely because a tab list is being inspected.
  var info: SessionInfoViewController? { overview?.infoControllerIfLoaded }

  var terminal: ShellDrawerViewController? {
    if case .terminal(let terminal) = body { return terminal }
    return nil
  }

  var files: FileTreeViewController? { overview?.activityControllerIfLoaded }

  var attachments: SessionAttachmentsViewController? {
    if case .attachments(let attachments) = body { return attachments }
    return nil
  }

  var subagents: SubagentTranscriptViewController? {
    if case .subagents(let subagents) = body { return subagents }
    return nil
  }

  var sharing: SessionSharingViewController? {
    if case .sharing(let sharing) = body { return sharing }
    return nil
  }

  var supervision: SupervisionListViewController? {
    if case .supervision(let supervision) = body { return supervision }
    return nil
  }

  var simulator: SimulatorPaneViewController? {
    if case .simulator(let simulator) = body { return simulator }
    return nil
  }

  var notificationTest: NotificationTestViewController? {
    if case .notificationTest(let controller) = body { return controller }
    return nil
  }

  var extensionPanel: ExtensionPanelViewController? {
    if case .extensionPanel(let panel) = body { return panel }
    return nil
  }

  var compare: CompareViewController? {
    if case .compare(let compare) = body { return compare }
    return nil
  }

  /// The live baseline-versus-current surface. Deliberately absent from `persistedTab`: its bytes
  /// are held by the controller and nothing on disk outlives it. See
  /// `BrowserComparisonViewController`.
  var browserComparison: BrowserComparisonViewController? {
    if case .browserComparison(let comparison) = body { return comparison }
    return nil
  }

  /// The tab's view controller, when its body is a live surface rather than rendered content.
  var hostedController: NSViewController? {
    switch body {
    case .content: return nil
    case .browser(let browser): return browser
    case .audit(let audit): return audit
    case .review(let review): return review
    case .overview(let overview): return overview
    case .terminal(let terminal): return terminal
    case .attachments(let attachments): return attachments
    case .subagents(let subagents): return subagents
    case .sharing(let sharing): return sharing
    case .supervision(let supervision): return supervision
    case .simulator(let simulator): return simulator
    case .notificationTest(let controller): return controller
    case .extensionPanel(let panel): return panel
    case .compare(let compare): return compare
    case .browserComparison(let comparison): return comparison
    case .nativePlugin(let plugin): return plugin
    }
  }

  /// The glyph the tab strip draws — the terminal-familiar vocabulary of the surface kind.
  var symbolName: String {
    switch body {
    case .content(let content):
      if case .image = content.body { return "photo" }
      if case .semanticScene = content.body { return "square.grid.3x3" }
      if case .chart = content.body { return "chart.bar" }
      return "doc.richtext"
    case .browser(let browser):
      return browser.contextKind == .private ? "hand.raised.fill" : "globe"
    case .audit:
      return "checklist.checked"
    case .review:
      return "plus.forwardslash.minus"
    case .overview:
      return "rectangle.grid.1x2"
    case .terminal:
      return "terminal"
    case .attachments:
      return "paperclip"
    case .subagents:
      return "person.2"
    case .sharing:
      // The same eye the corner card's row leads with: this pane is who is looking.
      return "eye"
    case .supervision:
      return "person.3"
    case .simulator:
      return "iphone"
    case .notificationTest:
      return "bell.badge"
    case .extensionPanel:
      return "puzzlepiece.extension"
    case .compare:
      return "rectangle.on.rectangle"
    case .browserComparison:
      return "square.on.square.dashed"
    case .nativePlugin:
      return "puzzlepiece.extension"
    }
  }

  /// What the strip and header call the tab: the agent's caption, else the file, the kind, or
  /// the live page's own title.
  var title: String {
    switch body {
    case .content(let content):
      if let title = content.title, !title.isEmpty { return title }
      if case .image(_, let url) = content.body { return url.lastPathComponent }
      if case .semanticScene = content.body { return "Scene" }
      if case .chart(let spec) = content.body {
        return spec.title.isEmpty ? L10n.string("Chart") : spec.title
      }
      return "Document"
    case .browser(let browser):
      if let title = browser.currentTitle, !title.isEmpty { return title }
      return browser.currentURL?.host
        ?? (browser.contextKind == .private ? "Private Browser" : "Browser")
    case .audit:
      return L10n.string("Execution audit")
    case .review:
      return "Review"
    case .overview:
      return L10n.string("Overview")
    case .terminal(let terminal):
      return terminal.currentTitle
    case .attachments:
      return "Attachments"
    case .subagents:
      return "Subagents"
    case .sharing:
      return "Sharing"
    case .supervision:
      return L10n.string("Chats")
    case .simulator:
      return L10n.string("iOS Simulator")
    case .notificationTest:
      return L10n.string("Test Notification")
    case .extensionPanel(let panel):
      return panel.panelTitle
    case .compare:
      return "Compare"
    case .browserComparison:
      return L10n.string("Visual diff")
    case .nativePlugin(let plugin):
      // The bundle's own display name, so Threading's Device Logs plugin still reads as
      // "Device logs" rather than as its identifier. A refusal is still a named tab.
      return plugin.displayName
    }
  }
}

/// The display panel named this type while it was the only tab host; the drawer now hosts the
/// same tabs, so the type lives host-neutrally as `PaneTab`.
typealias DisplayTab = PaneTab
