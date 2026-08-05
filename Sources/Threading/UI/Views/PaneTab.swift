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
    case info(SessionInfoViewController)
    case terminal(ShellDrawerViewController)
    case files(FileTreeViewController)
    case attachments(SessionAttachmentsViewController)
    case subagents(SubagentTranscriptViewController)
    case sharing(SessionSharingViewController)
    case extensionPanel(ExtensionPanelViewController)
    case compare(CompareViewController)
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

  var audit: ExecutionAuditViewController? {
    if case .audit(let audit) = body { return audit }
    return nil
  }

  var review: GitReviewViewController? {
    if case .review(let review) = body { return review }
    return nil
  }

  var info: SessionInfoViewController? {
    if case .info(let info) = body { return info }
    return nil
  }

  var terminal: ShellDrawerViewController? {
    if case .terminal(let terminal) = body { return terminal }
    return nil
  }

  var files: FileTreeViewController? {
    if case .files(let files) = body { return files }
    return nil
  }

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

  var extensionPanel: ExtensionPanelViewController? {
    if case .extensionPanel(let panel) = body { return panel }
    return nil
  }

  var compare: CompareViewController? {
    if case .compare(let compare) = body { return compare }
    return nil
  }

  /// The tab's view controller, when its body is a live surface rather than rendered content.
  var hostedController: NSViewController? {
    switch body {
    case .content: return nil
    case .browser(let browser): return browser
    case .audit(let audit): return audit
    case .review(let review): return review
    case .info(let info): return info
    case .terminal(let terminal): return terminal
    case .files(let files): return files
    case .attachments(let attachments): return attachments
    case .subagents(let subagents): return subagents
    case .sharing(let sharing): return sharing
    case .extensionPanel(let panel): return panel
    case .compare(let compare): return compare
    }
  }

  /// The glyph the tab strip draws — the terminal-familiar vocabulary of the surface kind.
  var symbolName: String {
    switch body {
    case .content(let content):
      if case .image = content.body { return "photo" }
      if case .semanticScene = content.body { return "square.grid.3x3" }
      return "doc.richtext"
    case .browser(let browser):
      return browser.contextKind == .private ? "hand.raised.fill" : "globe"
    case .audit:
      return "checklist.checked"
    case .review:
      return "plus.forwardslash.minus"
    case .info:
      return "info.circle"
    case .terminal:
      return "terminal"
    case .files:
      return "folder"
    case .attachments:
      return "paperclip"
    case .subagents:
      return "person.2"
    case .sharing:
      // The same eye the corner card's row leads with: this pane is who is looking.
      return "eye"
    case .extensionPanel:
      return "puzzlepiece.extension"
    case .compare:
      return "rectangle.on.rectangle"
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
      return "Document"
    case .browser(let browser):
      if let title = browser.currentTitle, !title.isEmpty { return title }
      return browser.currentURL?.host
        ?? (browser.contextKind == .private ? "Private Browser" : "Browser")
    case .audit:
      return L10n.string("Execution audit")
    case .review:
      return "Review"
    case .info:
      return "Info"
    case .terminal(let terminal):
      return terminal.currentTitle
    case .files:
      return "Files"
    case .attachments:
      return "Attachments"
    case .subagents:
      return "Subagents"
    case .sharing:
      return "Sharing"
    case .extensionPanel(let panel):
      return panel.panelTitle
    case .compare:
      return "Compare"
    }
  }
}

/// The display panel named this type while it was the only tab host; the drawer now hosts the
/// same tabs, so the type lives host-neutrally as `PaneTab`.
typealias DisplayTab = PaneTab
