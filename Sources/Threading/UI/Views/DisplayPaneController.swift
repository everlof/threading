import AppKit
import ThreadingExtensionKit
@preconcurrency import WebKit

// MARK: - Display Panel Toggle

/// The one control that opens and shuts the display panel, wherever it is currently drawn.
///
/// **There is exactly one, and it does not move.** It sits at the trailing end of the session
/// header's group while the panel is shut, and in the panel's own corner while it is open — the
/// same glyph, the same size, the same distance from the window's trailing edge — so a press
/// opens the pane *underneath* it rather than handing the corner to a different control. The
/// corner used to hold an ✕, which said "close" where the toolbar said "toggle" and left the
/// toggle itself pushed a pane's width to the left of where the eye had just been.
///
/// **One control means one view.** The two homes hold the same `ThemedIconButton` between them —
/// the window moves it from the group into the panel's corner and back — rather than each keeping
/// a copy that hides while the other shows. That is not tidiness: AppKit sends every click after
/// the first of a chain to the view that took the first one, so a control that removes itself as
/// part of its own press loses every press that follows, and the toggle answered one click and
/// then nothing at all until the pointer moved far enough to end the chain. See
/// `MainWindowController.updatePaneToggleSelection`, and `DisplayPanelTogglePressTests` for the
/// property that keeps it: a press leaves the same view under the pointer, at the same point.
@MainActor
enum DisplayPanelToggle {

  /// The panel is the window's trailing pane, and the glyph is that pane filled in.
  static let symbolName = "sidebar.trailing"

  /// Names what it acts on rather than which way it will act: the button is a switch, and
  /// `isSelected` — which `ThemedIconButton` publishes as the accessibility value — is what
  /// says whether the panel is on.
  static var accessibility: String { L10n.string("Display panel") }

  static var toolTip: String { L10n.string("Show or Hide the Display Panel") }
}

// MARK: - Display Pane Controller

/// The panel beside the terminal, showing content an agent asked Threading to display.
///
/// Content is held per session rather than globally, and each session keeps a *set* of tabs that
/// coexist: images, documents, and live browsers share the pane, switched between by
/// a strip along the top. A background session that displays something does not take over the
/// panel from the session on screen; its tabs are waiting when it is selected, as its scrollback is.
@MainActor
final class DisplayPaneController: NSViewController {

  // MARK: - Properties

  private lazy var headerView = PaneHeaderView(margin: .paneEdge)

  /// Opens a new tab. It sits at the trailing edge of the tab row rather than inside the
  /// scrolling strip, so a pane full of tabs scrolls sideways *under* it instead of carrying
  /// the one control that adds another off the edge with them.
  ///
  /// A `.toolbar` icon button, like the toggle beside it and like the session header's own `+`
  /// across the split. The two headers are one band — their hairlines land on a single line —
  /// and this row's controls were six points shorter than that row's, which reads as two rows
  /// pretending to be one.
  private lazy var newTabButton: ThemedIconButton = {
    let button = ThemedIconButton(
      symbolName: "plus",
      accessibility: L10n.string("New tab"),
      inkSource: .chrome
    )
    button.toolTip = L10n.string("New tab")
    // It offers a menu rather than doing something, so the menu opens on the press and the
    // button reads as held for as long as the menu is up — the platform's gesture, and the one
    // the component guarantees survives a view being rebuilt under a held mouse.
    button.presentsMenu = true
    button.onPress = { [weak self, weak button] in
      guard let self, let button else { return }
      self.presentNewTabMenu(from: button)
    }
    return button
  }()

  /// Where the panel's toggle stands while the panel is open — see `DisplayPanelToggle`.
  ///
  /// **A slot rather than a button, because there is only one toggle and it moves here.** The
  /// session header's group holds it while the panel is shut and this corner holds it while the
  /// panel is open, at the same size and the same margin from the window's trailing edge, so the
  /// pane arrives underneath a control that never moved.
  ///
  /// It used to be a second button that appeared as the group's copy hid, and that cost the
  /// gesture: AppKit sends every click after the first of a *chain* to the view that took the
  /// first one, so a control that removes itself as part of its own press throws away every
  /// press that follows — the toggle answered one click and then nothing until the pointer moved
  /// far enough to end the chain. See `MainWindowController.updatePaneToggleSelection`.
  ///
  /// The slot keeps the toggle's size whether or not it is holding it, so the `+` measuring from
  /// it never moves as the panel opens. Exposed so a fixture can measure the corner without a
  /// whole window to put a toggle in it.
  private(set) lazy var panelToggleSlot: NSView = {
    let slot = NSView()
    slot.translatesAutoresizingMaskIntoConstraints = false
    let size = ThemedIconButton.Target.toolbar.size
    NSLayoutConstraint.activate([
      slot.widthAnchor.constraint(equalToConstant: size.width),
      slot.heightAnchor.constraint(equalToConstant: size.height)
    ])
    return slot
  }()

  /// Takes the window's one panel toggle into the corner, and gives it the ground it now stands
  /// on: this pane paints itself in the app theme's surface, while the session header it came
  /// from floats over the terminal's palette. Same control, same place, inked for what is behind
  /// it — which is what `hostGround` is for.
  func adoptPanelToggle(_ toggle: ThemedIconButton) {
    guard toggle.superview !== panelToggleSlot else { return }
    toggle.translatesAutoresizingMaskIntoConstraints = false
    panelToggleSlot.addSubview(toggle)
    NSLayoutConstraint.activate([
      toggle.leadingAnchor.constraint(equalTo: panelToggleSlot.leadingAnchor),
      toggle.trailingAnchor.constraint(equalTo: panelToggleSlot.trailingAnchor),
      toggle.topAnchor.constraint(equalTo: panelToggleSlot.topAnchor),
      toggle.bottomAnchor.constraint(equalTo: panelToggleSlot.bottomAnchor)
    ])
    toggle.hostGround = .chrome
  }

  private lazy var headerCustomizationView = DisplayPaneHeaderCustomizationView(
    lookup: customizationLookup,
    onAction: { [weak self] action in
      guard let self else { return }
      if let onCustomizationAction {
        onCustomizationAction(action)
      } else {
        ComponentCustomizationProviderSlot.shared.perform(action)
      }
    }
  )
  private var newTabMenuSession: AnyObject?
  /// Holds the footer's content dropdown while it is up; released from its own dismissal.
  var contentMenuSession: AnyObject?
  private var regularTabBarTrailingConstraint: NSLayoutConstraint?
  private var globalTabBarTrailingConstraint: NSLayoutConstraint?
  private lazy var tabBar: DisplayTabBar = {
    let bar = DisplayTabBar(
      frame: .zero,
      customizationLookup: customizationLookup
    )
    bar.onSelect = { [weak self] id in self?.userActivatedTab(id) }
    bar.onClose = { [weak self] id in self?.userClosedTab(id) }
    bar.onReorder = { [weak self] id, index in
      guard let self, let sessionID = self.currentSessionID else { return }
      self.moveTab(id: id, toIndex: index, for: sessionID)
    }
    bar.contextEntries = { [weak self] id in
      self?.tabContextEntries(for: id) ?? []
    }
    bar.externalDropTarget = { [weak self] id, windowPoint in
      self?.dragOutDestination?(id, windowPoint) ?? false
    }
    bar.onDropOut = { [weak self] id, windowPoint in
      self?.performDragOut?(id, windowPoint)
    }
    bar.onDragEnded = { [weak self] id in
      self?.dragOutEnded?(id)
    }
    return bar
  }()
  private lazy var imageView = ThemedImagePreview()
  /// The document renderer exists only after an HTML tab is actually shown. Constructing a
  /// `WKWebView` launches WebKit services; doing that from `viewDidLoad` made the first reveal of
  /// an empty pane pay ~46 ms for a renderer and a blank page it did not use.
  private var documentWebView: WKWebView?
  private var documentWebViewHasContent = false
  /// `loadHTMLString` enters the navigation delegate as `.other`, just like script navigation.
  /// Arm exactly the host load we issue; its policy callback consumes this permission before any
  /// script in the document can run.
  private var allowsInitialDocumentNavigation = false
  private lazy var hostedView: NSView = {
    let hosted = NSView()
    hosted.translatesAutoresizingMaskIntoConstraints = false
    hosted.wantsLayer = true
    hosted.isHidden = true
    return hosted
  }()
  private lazy var captionLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.applyFont(.compactCode)
    label.textColor = Design.Text.tertiary
    label.lineBreakMode = .byTruncatingMiddle
    label.alignment = .right
    label.setContentCompressionResistancePriority(
      Design.Priority.belowFittingSize,
      for: .horizontal
    )
    return label
  }()
  private lazy var contentMenuButton: ThemedButton = {
    let button = ThemedButton(
      symbol: "ellipsis.circle",
      accessibility: L10n.string("Content actions"),
      target: self,
      action: #selector(contentMenuButtonClicked)
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.toolTip = L10n.string("Actions")
    return button
  }()
  private lazy var placeholderLabel: NSTextField = {
    let label = NSTextField(labelWithString: L10n.string("Nothing to show yet."))
    label.translatesAutoresizingMaskIntoConstraints = false
    label.applyFont(.detail())
    label.textColor = Design.Text.tertiary
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(
      Design.Priority.belowFittingSize,
      for: .horizontal
    )
    return label
  }()
  private let appEvents = AppEventObservations()

  /// The live tab's view controller currently parented into `hostedView` — the browser or a
  /// review — so switching tabs can swap it out without rebuilding its state.
  private weak var installedController: NSViewController?
  private weak var presentedSimulator: SimulatorPaneViewController?

  /// The hosted controller *this pane* built, when the tab holds a value rather than a
  /// controller.
  ///
  /// A chart and a semantic scene are rendered from data the tab owns, so their controller is
  /// constructed here and owned by nobody else. `installedController` is deliberately weak —
  /// it points at controllers the tab keeps alive — so without this strong reference such a
  /// controller deallocates the moment it is installed, its weak entry becomes nil, and the
  /// next `installHosted` finds nothing to remove: the view stays parented forever and the
  /// tab that replaced it draws on top of it. That is exactly what a chart tab did.
  private var ownedController: NSViewController?

  /// One app-wide document that temporarily occupies the panel without joining any session's
  /// tab list. It is deliberately not persisted or transferable: changing chats must not clone,
  /// close, or retarget the theme being inspected.
  private lazy var currentThemeController: CurrentThemeViewController = {
    let controller = CurrentThemeViewController()
    addChild(controller)
    return controller
  }()
  private(set) var isShowingCurrentTheme = false
  private static let currentThemeTabID = UUID(
    uuidString: "846E2D46-2DF4-43A7-A591-91A384582D39"
  )!

  /// The honest first surface when the user opens a session's otherwise empty panel by hand.
  /// It is not in `tabsBySession`, is never returned to an agent and is never persisted. A
  /// deliberate surface command materializes an ordinary Overview tab instead.
  private var syntheticOverview: (sessionID: SessionID, tab: DisplayTab)?

  private var tabsBySession: [SessionID: [DisplayTab]] = [:]
  private var activeTabIDBySession: [SessionID: UUID] = [:]
  /// Monotonic, in-memory identity for what one session's panel has to present.
  ///
  /// The window snapshots this when the user hides the panel. A session switch can then keep
  /// the same material hidden without mistaking a later chart, browser navigation, or attachment
  /// for the content the user already dismissed. This is deliberately not persisted: the
  /// dismissal it is compared with belongs to this window lifetime too.
  private var contentRevisionBySession: [SessionID: UInt64] = [:]
  /// The browser the agent and user most recently selected. Kept separately from the visible
  /// panel tab because displaying a screenshot or document must not silently retarget the next
  /// browser action to the first browser in the strip.
  private var activeBrowserTabIDBySession: [SessionID: UUID] = [:]
  private let extensionPanels: ExtensionPanelRouting
  private let customizationLookup: ComponentCustomizationHost.Lookup
  private let browserFactory: @MainActor (BrowserContextKind) -> BrowserViewController
  private let simulatorControl: any SimulatorControlling
  private let simulatorLeaseManager: any SimulatorLeaseManaging
  private let simulatorStreamCoordinator: any SimulatorLiveStreamCoordinating
  private let simulatorInputAuthorizer: any SimulatorInputAuthorizing

  /// Test and embedding seam for extension actions. Production routes through the shared
  /// provider slot when no explicit receiver is installed.
  var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

  /// Not private: the actions in `DisplayPaneMenu` name the session they write files for.
  private(set) var currentSessionID: SessionID?

  /// The content of the active tab, if it is an image or a document. Read by `DisplayPaneMenu`,
  /// which acts on the file behind it — a browser tab has no such file, so this is nil for it.
  var currentContent: DisplayContent? {
    guard !isShowingCurrentTheme else { return nil }
    return activeTab(for: currentSessionID)?.content
  }

  /// The browser actually visible in the selected session, if the active display tab is one.
  /// This deliberately differs from the most recently targeted browser: user commands such as
  /// Find must not act on a hidden browser behind an image or terminal tab.
  var currentBrowser: BrowserViewController? {
    guard !isShowingCurrentTheme else { return nil }
    return activeTab(for: currentSessionID)?.browser
  }

  /// The Git Review surface actually visible in the selected session. Window commands route to
  /// this owner rather than adding chrome over the full-size window content view.
  var currentReview: GitReviewViewController? {
    guard !isShowingCurrentTheme else { return nil }
    return activeTab(for: currentSessionID)?.review
  }

  /// Called when the panel should shut: the corner's ✕, or the user closing the pane's last
  /// content tab. One way out for both, because collapsing the split item is the window's to do
  /// and neither caller wants anything else done differently.
  var onClose: (() -> Void)?

  /// The window's way in for the `+` menu's Current Theme entry: it uncollapses this pane and
  /// steps out of Settings first, neither of which this controller can see. Unset, the entry
  /// falls back to showing the document in place.
  var onShowCurrentTheme: (() -> Void)?

  /// Routes child selection back to the renderer that owns provider transcript loading.
  var onSubagentSelection: ((SessionID, String) -> Void)?

  /// Asks for a new invitation to this chat. The sharing pane offers the button; the sheet, its
  /// grant choice and its copy behaviour stay where the sidebar's Share Chat… already put them.
  var onShareSession: ((SessionID) -> Void)?

  var onOpenSupervisedChat: ((SessionID) -> Void)?
  var onMessageSupervisedChat: ((SessionID) -> Void)?
  var onArchiveSupervisedChat: ((SessionID) -> Void)?
  var onReleaseSupervisedChat: ((SessionID) -> Void)?

  /// Reports an active review's background read and main-thread render as one operation.
  var onReviewLoadingChange: ((SessionID, Bool) -> Void)?

  /// Resolves a session's shell-drawer root pid, so the info panel can attribute a port to the
  /// shell rather than to the agent. The drawer belongs to the terminal container, which the
  /// window owns — this is wired from there rather than reached for across the split.
  var shellRootResolver: ((SessionID) -> pid_t?)?

  // MARK: - Lifecycle

  init(
    extensionPanels: ExtensionPanelRouting? = nil,
    customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
      ComponentCustomizationProviderSlot.shared.customization(for: $0)
    },
    browserFactory: @escaping @MainActor (BrowserContextKind) -> BrowserViewController = {
      BrowserViewController(contextKind: $0)
    },
    simulatorControl: any SimulatorControlling = SimctlSimulatorControl(),
    simulatorStreamCoordinator: any SimulatorLiveStreamCoordinating = SimulatorLiveStreamCoordinator.shared,
    simulatorInputAuthorizer: any SimulatorInputAuthorizing = SimulatorInputConsentController.shared
  ) {
    self.extensionPanels = extensionPanels ?? ExtensionManager.shared
    self.customizationLookup = customizationLookup
    self.browserFactory = browserFactory
    self.simulatorControl = simulatorControl
    if simulatorControl is SimctlSimulatorControl {
      self.simulatorLeaseManager = SimulatorLeaseManager.shared
    } else {
      self.simulatorLeaseManager = SimulatorLeaseManager(control: simulatorControl)
    }
    self.simulatorStreamCoordinator = simulatorStreamCoordinator
    self.simulatorInputAuthorizer = simulatorInputAuthorizer
    super.init(nibName: nil, bundle: nil)

    appEvents.observe(SessionAttachmentsDidChange.self) { [weak self] event in
      self?.advanceContentRevision(for: event.sessionID)
      self?.ensureAttachmentsTab(for: event.sessionID)
    }
    appEvents.observe(ControlGrantsDidChange.self) { [weak self] event in
      guard let self, event.sessionID == self.currentSessionID else { return }
      self.reconcileSupervisionTab(for: event.sessionID)
      self.render()
    }
    appEvents.observe(SupervisionDidChange.self) { [weak self] event in
      self?.tabsBySession[event.managerID]?.first(where: { $0.supervision != nil })?
        .supervision?.refresh()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    view = NSView()
    view.wantsLayer = true
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupBackdrop()
    setupHeader()
    setupTabBar()
    setupContent()
    setupConstraints()
    render()
  }

  /// The pane's own ground, in the chrome's colour.
  ///
  /// This pane sits on the *window's* backdrop, which a terminal pane paints with the terminal
  /// palette — a colour the app theme does not own and this pane's chrome-inked tabs and
  /// labels cannot read on. An unpainted pane therefore showed whatever the window happened to
  /// be: white beside a dark chrome, a stray tint beside a styled one. A `ThemedSurfaceView`
  /// is the component for exactly this — it is re-resolved by the theme sweep and re-resolves
  /// itself on a system light/dark switch.
  private func setupBackdrop() {
    let backdrop = ThemedSurfaceView()
    backdrop.applySurface(
      fill: Design.Surface.ground,
      radius: .fixed(0),
      pattern: .backdrop
    )
    view.addSubview(backdrop)

    NSLayoutConstraint.activate([
      backdrop.topAnchor.constraint(equalTo: view.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  // MARK: - Setup

  /// The pane's one top row: its tabs, the control that adds another, and the panel's toggle.
  ///
  /// There was a titled header above the strip, which spent a row of a narrow pane restating
  /// the name of the tab directly beneath it — and the toolbar already names the page. The
  /// tabs *are* the header now, with `+` at the trailing edge where a browser puts it, which
  /// is also what closes the gap between this pane and the rest of the window's chrome.
  private func setupHeader() {
    headerView.addSubview(headerCustomizationView)
    headerView.addSubview(newTabButton)
    headerView.addSubview(panelToggleSlot)

    view.addSubview(headerView)
  }

  private func presentNewTabMenu(from sender: NSView) {
    guard let sessionID = currentSessionID else { return }

    newTabMenuSession = ThemedMenuPresenter.present(
      ThemedMenuPresentation(entries: newTabEntries(for: sessionID), minimumWidth: 160),
      from: sender,
      selectedEntryIndex: nil,
      onChoose: { _, item in item.onChoose?() },
      onDismiss: { [weak self] in self?.newTabMenuSession = nil }
    )
  }

  /// What the `+` offers, in three bands: this chat's own surfaces, then the app-wide theme
  /// document, then whatever extensions contribute.
  ///
  /// The theme document is *here* rather than in the sidebar because this is the panel it opens
  /// into, and a door belongs beside the room it opens. It is still not a tab — choosing it takes
  /// the whole panel and joins no persisted list — so it sits behind its own separator instead of
  /// among the session surfaces it would be mistaken for. It appears only while at least one
  /// theme tool is exposed, matching the command in View.
  ///
  /// Not private: the entries are the menu's contract and are asserted directly, since presenting
  /// one needs a window on screen.
  func newTabEntries(for sessionID: SessionID) -> [ThemedMenuEntry] {
    let canAddBrowser =
      tabs(for: sessionID).lazy.filter { $0.browser != nil }.count
      < DisplayPaneDefaults.maximumBrowserTabs

    var choices: [(String, String, String?, Bool, () -> Void)] = [
      (
        "Terminal", "terminal", AppCommands.ID.newTerminalTab, true,
        {
          [weak self] in _ = self?.addTerminalTab(for: sessionID)
        }
      ),
      (
        L10n.string("iOS Simulator"), "iphone", nil, true,
        {
          [weak self] in _ = self?.activateSimulator(for: sessionID)
        }
      ),
      (
        L10n.string("Device logs"), "list.bullet.rectangle", nil, true,
        {
          [weak self] in _ = self?.activateDeviceLog(for: sessionID)
        }
      ),
      (
        L10n.string("Execution audit"), "checklist.checked", nil, canAddBrowser,
        {
          [weak self] in _ = self?.addAuditTab(for: sessionID)
        }
      ),
      (
        "Browser", "globe", nil, canAddBrowser,
        {
          [weak self] in _ = self?.addBrowserTab(for: sessionID)
        }
      ),
      (
        "Private Browser", "hand.raised.fill", nil, canAddBrowser,
        {
          [weak self] in
          _ = self?.addBrowserTab(for: sessionID, contextKind: .private)
        }
      ),
      (
        L10n.string("Overview"), "rectangle.grid.1x2", nil, true,
        {
          [weak self] in _ = self?.activateOverview(for: sessionID)
        }
      ),
      (
        "Review", "plus.forwardslash.minus", AppCommands.ID.review, true,
        {
          [weak self] in _ = self?.activateReview(for: sessionID)
        }
      ),
      (
        "Compare Files…", "rectangle.on.rectangle", nil, true,
        {
          [weak self] in self?.chooseFilesToCompare(for: sessionID)
        }
      ),
      (
        "Attachments", "paperclip", nil, true,
        {
          [weak self] in _ = self?.activateAttachments(for: sessionID)
        }
      ),
    ]
    if ControlGrantStore.shared.isManager(sessionID) {
      choices.insert(
        (
          L10n.string("Chats"), "person.3", nil, true,
          { [weak self] in _ = self?.activateSupervision(for: sessionID) }
        ),
        at: 0
      )
    }
    var entries = choices.map { title, symbol, commandID, isEnabled, action in
      ThemedMenuEntry.item(
        ThemedMenuItem(
          title: title,
          shortcut: commandID.flatMap {
            ShortcutOverrideStore.shared.shortcut(forID: $0)
          },
          image: ThemedMenuIcon.symbol(symbol),
          isEnabled: isEnabled,
          onChoose: action
        ))
    }
    if MCPToolCatalog.hasEnabledThemeTools {
      entries.append(.separator)
      entries.append(
        .item(
          ThemedMenuItem(
            title: L10n.string("Current Theme"),
            shortcut: ShortcutOverrideStore.shared.shortcut(
              forID: AppCommands.ID.currentTheme
            ),
            image: ThemedMenuIcon.symbol("paintbrush.pointed"),
            onChoose: { [weak self] in
              guard let self else { return }
              // The window's route also uncollapses the panel and leaves Settings, neither of
              // which this controller can see. Showing directly is the standalone fallback.
              if let onShowCurrentTheme {
                onShowCurrentTheme()
              } else {
                showCurrentTheme()
              }
            }
          )))
    }

    let contributedPanels = extensionPanels.extensionPanelInventory
    if !contributedPanels.isEmpty {
      entries.append(.separator)
      entries.append(
        contentsOf: contributedPanels.map { item in
          ThemedMenuEntry.item(
            ThemedMenuItem(
              title: item.panel.title,
              subtitle: item.extensionName,
              image: ThemedMenuIcon.symbol("puzzlepiece.extension"),
              onChoose: { [weak self] in
                _ = self?.activateExtensionPanel(
                  extensionIdentifier: item.extensionIdentifier,
                  panelID: item.panel.id,
                  title: item.panel.title,
                  for: sessionID
                )
              }
            ))
        })
    }

    return entries
  }

  private func setupTabBar() {
    headerView.addSubview(tabBar)
  }

  private func setupContent() {
    // A `ThemedImagePreview` rather than an `NSImageView`, for two reasons that both belong
    // to this pane: the picture must not lend the panel its own dimensions (an image view
    // does, and flooring its priorities only stopped that from *winning* — the size stayed
    // in the layout and stayed what `fittingSize` answered), and the picture is the thing
    // the user wants to inspect properly, with zoom and pan. See the type's own note.
    // An explicit button beside the caption rather than a click target on the text or the
    // image: nothing about a caption advertises that it is clickable, and a button is the
    // only one of the three that can be seen before it is tried.
    // **Neither label is a measurement.** Both are held inside the pane with a `>=` — the
    // caption off the leading edge, the placeholder either side of the centre — and a label
    // like that still charges the pane its whole text, through the compression resistance
    // every `NSTextField` carries. A pane's width is the *window's* minimum
    // (`DisplayPaneDefaults.slimmestWidth`), so "Nothing to show yet." and a long file name
    // each quietly decided how small the window was allowed to be: 259pt of it, for text
    // both line-break modes here already say may be shortened. Below
    // `.fittingSizeCompression` they truncate instead of pushing, and the panel goes on
    // costing the window its own chrome and nothing else.
    view.addSubview(imageView)
    view.addSubview(captionLabel)
    view.addSubview(contentMenuButton)
    view.addSubview(placeholderLabel)

    // Added last so it layers above the image/web surfaces; it is opaque when shown.
    view.addSubview(hostedView)
  }

  private func setupConstraints() {
    let padding = DisplayPaneDefaults.padding

    // The strip the toolbar reserves is the header's — the same shape as the terminal
    // pane's header, and for the same reason: pinned *below* the safe area instead, the
    // pane's tabs sat a full row lower than the tab naming the session beside them, under
    // an empty band the toolbar had already reserved. AppKit briefly reports a zero-height
    // safe area while the window is attached, so the equality sits just below required and
    // the floor keeps the row sane in a fixture with no toolbar to inset it.
    let headerBottom = headerView.bottomAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.topAnchor
    )
    headerBottom.priority = .init(999)
    let gap = DisplayPaneDefaults.controlGap
    let regularTabBarTrailing = tabBar.trailingAnchor.constraint(
      equalTo: headerCustomizationView.leadingAnchor,
      constant: -gap
    )
    regularTabBarTrailingConstraint = regularTabBarTrailing
    globalTabBarTrailingConstraint = tabBar.trailingAnchor.constraint(
      equalTo: panelToggleSlot.leadingAnchor,
      constant: -gap
    )

    // **Where the strip ends is not a requirement.** The pane's floor is its two trailing
    // controls and the margin around them (`DisplayPaneDefaults.slimmestWidth`), and at that
    // width there is nothing left for the strip: required, this constraint would ask the strip
    // for a negative width and AppKit would break *something* to grant it. Just below required
    // it yields instead, and the strip — which scrolls, and already refuses to be read as a
    // measurement of its host (see `ThemedTabStripView`) — closes to nothing while `+` and the
    // toggle stay whole. Both trailing constraints yield, since either may be the active one.
    [regularTabBarTrailing, globalTabBarTrailingConstraint].forEach {
      $0?.priority = .init(999)
    }

    NSLayoutConstraint.activate([
      headerView.topAnchor.constraint(equalTo: view.topAnchor),
      headerBottom,
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      // The strip takes the row and gives up only what the trailing controls need, so a pane
      // full of tabs scrolls sideways rather than pushing the control that adds one, or the
      // one that shuts the pane, off the edge. It never takes a negative width for them.
      // The two buttons state their own size: a `.toolbar` icon button is the role's
      // measurement, and a width constraint here would be this pane deciding it again.
      tabBar.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
      tabBar.topAnchor.constraint(equalTo: headerView.topAnchor),
      tabBar.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
      tabBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
      regularTabBarTrailing,

      headerCustomizationView.trailingAnchor.constraint(
        equalTo: newTabButton.leadingAnchor,
        constant: -gap
      ),
      headerCustomizationView.centerYAnchor.constraint(
        equalTo: headerView.contentCenterYAnchor
      ),
      headerCustomizationView.heightAnchor.constraint(
        lessThanOrEqualTo: headerView.heightAnchor
      ),
      newTabButton.trailingAnchor.constraint(
        equalTo: panelToggleSlot.leadingAnchor, constant: -gap),
      newTabButton.centerYAnchor.constraint(equalTo: headerView.contentCenterYAnchor),

      // The toggle in the corner, the margin its own — `+` measures from it, and the strip and
      // the customization slot from `+`, so the row is one chain from the pane's edge inwards.
      //
      // **The margin is the session header's, not this pane's `padding`.** The same toggle is
      // drawn at the trailing end of that header while the panel is shut, pinned there by
      // `PaneHeaderDefaults.inset`; measuring this one from anything else would make the
      // button jump as the pane it opens arrives underneath it.
      panelToggleSlot.trailingAnchor.constraint(
        equalTo: headerView.trailingAnchor, constant: -PaneHeaderDefaults.inset),
      panelToggleSlot.centerYAnchor.constraint(equalTo: headerView.contentCenterYAnchor),

      // Content anchors under the one header row.
      imageView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: padding),
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
      imageView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -padding),

      // A live surface fills the whole content region, over the caption footer, since it
      // carries its own chrome and needs no caption beneath it.
      hostedView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      // Caption and its actions button sit together as one footer, right-aligned so the
      // button lands under the image's edge rather than floating in the middle.
      captionLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor,
        constant: padding
      ),
      captionLabel.trailingAnchor.constraint(
        equalTo: contentMenuButton.leadingAnchor,
        constant: -4
      ),
      captionLabel.centerYAnchor.constraint(equalTo: contentMenuButton.centerYAnchor),

      contentMenuButton.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: -padding
      ),
      contentMenuButton.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -padding
      ),
      contentMenuButton.widthAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),
      contentMenuButton.heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),

      placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      placeholderLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor,
        constant: padding
      ),
    ])
  }

  // MARK: - Public — Content Tabs

  /// Adds an image or document as a new tab and brings it to the front. Existing tabs stay, so
  /// the pane accumulates what the agent shows; the oldest content tab is dropped past the cap.
  func addContentTab(_ content: DisplayContent, for sessionID: SessionID) {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    let tab = DisplayTab(body: .content(content))
    if case .image(let image, _) = content.body {
      tab.cacheFile = DisplayPaneStore.shared.cacheImage(image, tabID: tab.id, for: sessionID)
    }
    tabs.append(tab)

    // Cap rendered content independently from live browsers: a session that keeps drawing
    // charts should not grow an unbounded strip, while browser tabs have their own hard cap.
    let contentCount = tabs.filter { $0.content != nil }.count
    if contentCount > DisplayPaneDefaults.maximumContentTabs,
      let oldest = tabs.first(where: { $0.content != nil })
    {
      if let cacheFile = oldest.cacheFile {
        DisplayPaneStore.shared.removeCachedImage(cacheFile, for: sessionID)
      }
      tabs.removeAll { $0.id == oldest.id }
    }

    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
  }

  // MARK: - Public — Extension Panels

  /// Opens one registered extension panel as a normal per-session display tab.
  ///
  /// One tab exists per extension/panel pair in a session. Its controller keeps the stable
  /// identifiers even while the provider is disabled, so the tab can recover on re-enable and
  /// can be restored before extension processes finish starting.
  @discardableResult
  func activateExtensionPanel(
    extensionIdentifier: String,
    panelID: String,
    title: String,
    for sessionID: SessionID
  ) -> ExtensionPanelViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: {
      $0.extensionPanel?.extensionIdentifier == extensionIdentifier
        && $0.extensionPanel?.panelID == panelID
    }), let panel = existing.extensionPanel {
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return panel
    }

    let controller = makeExtensionPanel(
      extensionIdentifier: extensionIdentifier,
      panelID: panelID,
      title: title,
      for: sessionID
    )
    let tab = DisplayTab(body: .extensionPanel(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  private func makeExtensionPanel(
    extensionIdentifier: String,
    panelID: String,
    title: String,
    for sessionID: SessionID
  ) -> ExtensionPanelViewController {
    let projectID = ProjectStore.shared.project(forSessionID: sessionID)?.id
    let controller = ExtensionPanelViewController(
      extensionIdentifier: extensionIdentifier,
      panelID: panelID,
      title: title,
      context: .init(
        projectID: projectID?.uuidString.lowercased(),
        sessionID: sessionID.uuidString.lowercased()
      ),
      router: extensionPanels
    )
    addChild(controller)
    controller.onChange = { [weak self, weak controller] in
      guard let self, controller != nil else { return }
      self.persist(sessionID)
      if self.currentSessionID == sessionID { self.render() }
    }
    return controller
  }

  // MARK: - Public — Browser Tabs

  /// Returns the active browser tab, or activates the first existing browser, creating one only
  /// when the session has none. The agent's navigate tool calls this so a page always has a tab.
  @discardableResult
  func activateBrowser(for sessionID: SessionID) -> BrowserViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let activeID = activeTabIDBySession[sessionID],
      let activeTab = tabs.first(where: { $0.id == activeID }),
      activeTab.holdsAgentDrivableBrowser,
      let active = activeTab.browser
    {
      activeBrowserTabIDBySession[sessionID] = activeID
      return active
    }
    if let existing = tabs.first(where: \.holdsAgentDrivableBrowser),
      let browser = existing.browser
    {
      activeTabIDBySession[sessionID] = existing.id
      activeBrowserTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return browser
    }

    let controller = makeBrowser(for: sessionID)
    let tab = DisplayTab(body: .browser(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    activeBrowserTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Adds and activates a distinct browser tab. Nil means the per-session browser cap was
  /// reached; unlike content tabs, a live browser is never silently evicted because it may hold
  /// an authenticated workflow or unsaved form state.
  @discardableResult
  func addBrowserTab(
    for sessionID: SessionID,
    contextKind: BrowserContextKind = .shared
  ) -> BrowserViewController? {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []
    // Across every host, not this pane's own: see `sessionBrowserCount`.
    let existing = sessionBrowserCount?(sessionID)
      ?? tabs.lazy.filter { $0.browser != nil }.count
    guard existing < DisplayPaneDefaults.maximumBrowserTabs else {
      return nil
    }

    let controller = makeBrowser(for: sessionID, contextKind: contextKind)
    let tab = DisplayTab(body: .browser(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    activeBrowserTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Adds the factual execution ledger. It owns one live browser so its alternate mode can put
  /// browser actions and the page they affected beside each other without rebuilding either.
  @discardableResult
  func addAuditTab(for sessionID: SessionID) -> ExecutionAuditViewController? {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []
    if let existing = tabs.first(where: { $0.audit != nil }), let audit = existing.audit {
      activeTabIDBySession[sessionID] = existing.id
      activeBrowserTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return audit
    }
    guard tabs.lazy.filter({ $0.browser != nil }).count < DisplayPaneDefaults.maximumBrowserTabs
    else { return nil }

    let controller = makeAudit(for: sessionID)
    let tab = DisplayTab(body: .audit(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    activeBrowserTabIDBySession[sessionID] = tab.id
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Reveals this session's live device log pane, creating it the first time.
  ///
  /// One per session on purpose: a second tab would be a second child process reading the same
  /// firehose, and the filter belongs to the pane rather than to the source.
  @discardableResult
  func activateDeviceLog(for sessionID: SessionID) -> DeviceLogPaneViewController? {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []
    if let existing = tabs.first(where: {
      if case .deviceLog = $0.body { return true }
      return false
    }) {
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      if case .deviceLog(let logs) = existing.body { return logs }
      return nil
    }

    let controller = DeviceLogPaneViewController(owningSessionID: sessionID)
    let tab = DisplayTab(body: .deviceLog(controller), owningSessionID: sessionID)
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Builds a browser view controller wired to persist and re-render when its page changes, so a
  /// navigation — the agent's or the user's — is saved and reflected in the tab strip.
  private func makeBrowser(
    for sessionID: SessionID,
    contextKind: BrowserContextKind = .shared
  ) -> BrowserViewController {
    let controller = browserFactory(contextKind)
    addChild(controller)
    controller.baselineSessionID = sessionID
    controller.onPageChange = { [weak self] in
      guard let self else { return }
      self.persist(sessionID)
      if sessionID == self.currentSessionID { self.render() }
    }
    return controller
  }

  private func makeAudit(
    for sessionID: SessionID,
    mode: ExecutionAuditViewController.Mode = .audit
  ) -> ExecutionAuditViewController {
    let browser = browserFactory(.shared)
    let controller = ExecutionAuditViewController(
      sessionID: sessionID,
      browser: browser,
      initialMode: mode
    )
    addChild(controller)
    browser.onPageChange = { [weak self] in
      guard let self else { return }
      self.persist(sessionID)
      if sessionID == self.currentSessionID { self.render() }
    }
    controller.onModeChange = { [weak self] _ in
      self?.persist(sessionID)
    }
    return controller
  }

  /// The panel's own most recently selected browser. A content tool may put a screenshot or
  /// document in front of it, but that output must not change which independent browser
  /// receives the next browser action.
  ///
  /// Host-local on purpose: a browser the user moved to another pane is found by
  /// `SessionBrowserResolver`, which asks every host. This answers only for the panel, so the
  /// two cannot disagree about what "the panel holds" the way a fallback living here did.
  func browser(for sessionID: SessionID) -> BrowserViewController? {
    preferredBrowserTabID(for: sessionID).flatMap { id in
      (tabsBySession[sessionID] ?? []).first { $0.id == id }?.browser
    }
  }

  // MARK: - Public — Review Tab

  /// Returns the session's git review tab, creating and activating one if it has none. Review
  /// remains a singleton because one session has one working-tree comparison.
  @discardableResult
  func activateReview(for sessionID: SessionID) -> GitReviewViewController? {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.review != nil }) {
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return existing.review
    }

    guard let controller = makeReview(for: sessionID, mode: .uncommitted) else { return nil }
    let tab = DisplayTab(body: .review(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// A session that just stopped working probably changed the tree; its review, if on
  /// screen, should say so without being asked. Overview gets the same treatment for the same
  /// reason: a turn may have changed either its files or the server processes it is running.
  func noteSessionStoppedWorking(_ sessionID: SessionID) {
    guard sessionID == currentSessionID else { return }

    activeTab(for: sessionID)?.review?.refreshModePresentation()
    activeTab(for: sessionID)?.review?.refresh(force: false)
    activeTab(for: sessionID)?.overview?.sessionDidStopWorking()
    if syntheticOverview?.sessionID == sessionID {
      syntheticOverview?.tab.overview?.sessionDidStopWorking()
    }
    // A comparison on screen through a turn is probably of files the turn was rewriting.
    activeTab(for: sessionID)?.compare?.refresh(force: true)
  }

  /// Entering a turn changes Last Turn's meaning to This Turn before the first checkout write.
  /// Renaming the chip is enough; the checkout watcher will refresh content as files move.
  func noteSessionStartedWorking(_ sessionID: SessionID) {
    guard sessionID == currentSessionID else { return }
    activeTab(for: sessionID)?.review?.refreshModePresentation()
  }

  // MARK: - Public — Overview Tab

  /// Returns the session's Overview, creating and activating its one tab if needed.
  @discardableResult
  func activateOverview(
    for sessionID: SessionID,
    section: SessionOverviewSection = .info
  ) -> SessionOverviewViewController? {
    restoreIfNeeded(sessionID)
    if syntheticOverview?.sessionID == sessionID { discardSyntheticOverview() }
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.overview != nil }),
      let overview = existing.overview
    {
      overview.select(section)
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return overview
    }

    guard let controller = makeOverview(for: sessionID, initialSection: section) else { return nil }
    let tab = DisplayTab(body: .overview(controller), owningSessionID: sessionID)
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Compatibility route for **View ▸ Session Info**. It now focuses Info inside Overview.
  @discardableResult
  func activateInfo(for sessionID: SessionID) -> SessionInfoViewController? {
    activateOverview(for: sessionID, section: .info)?.selectInfo()
  }

  /// Builds the two-section surface without loading either section's view. Returns nil for a
  /// session with no project — neither the filesystem nor its runtime has a directory context.
  private func makeOverview(
    for sessionID: SessionID,
    initialSection: SessionOverviewSection
  ) -> SessionOverviewViewController? {
    guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else { return nil }

    let controller = SessionOverviewViewController(
      sessionID: sessionID,
      initialSection: initialSection,
      activityFactory: {
        FileTreeViewController(
          folderPath: project.folderPath,
          workTarget: .session(
            projectID: project.id,
            sessionID: sessionID,
            rootPath: project.folderPath,
            detailed: true
          )
        )
      },
      infoFactory: { [weak self] in
        let info = SessionInfoViewController(
          sessionID: sessionID,
          folderPath: project.folderPath
        )

        // The shell drawer lives on the terminal container, which the window owns and this pane
        // does not see; the resolver is wired in from there.
        info.shellRootProvider = { [weak self] in self?.shellRootResolver?(sessionID) }

        // A port the user clicks lands in this session's browser tab, which is the surface that
        // already exists for showing a page.
        info.onOpenURL = { [weak self] url in
          self?.activateBrowser(for: sessionID).navigate(to: url.absoluteString)
        }
        return info
      }
    )
    addChild(controller)
    controller.onSectionChange = { [weak self] _ in self?.persist(sessionID) }
    return controller
  }

  // MARK: - Public — Compare Tab

  /// Shows a comparison of two files, reusing the tab already holding this pair — the agent
  /// asking again about the same pair most likely just rewrote one side, so the reuse also
  /// re-reads.
  @discardableResult
  func addCompareTab(
    for sessionID: SessionID,
    oldPath: String,
    newPath: String,
    oldTitle: String? = nil,
    newTitle: String? = nil
  ) -> CompareViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: {
      $0.compare?.oldPath == oldPath && $0.compare?.newPath == newPath
    }), let compare = existing.compare {
      compare.refresh(force: true)
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return compare
    }

    let controller = makeCompare(
      for: sessionID,
      oldPath: oldPath,
      newPath: newPath,
      oldTitle: oldTitle,
      newTitle: newTitle,
      mode: .wipeHorizontal
    )
    let tab = DisplayTab(body: .compare(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Shows a baseline against the page as it is now.
  ///
  /// One comparison tab per session, reused: a session comparing a page repeatedly wants the newest
  /// answer where the last one was, not a strip of stale ones. The tab is never persisted — see
  /// `BrowserComparisonViewController` for why a comparison is a moment rather than a document.
  @discardableResult
  func presentBrowserComparison(
    for sessionID: SessionID,
    content: BrowserComparisonViewController.Content,
    onAcceptRevision: @escaping (BrowserComparisonViewController.Approval) -> Void
  ) -> BrowserComparisonViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.browserComparison != nil }),
      let comparison = existing.browserComparison {
      comparison.onAcceptRevision = onAcceptRevision
      comparison.update(content)
      activeTabIDBySession[sessionID] = existing.id
      if sessionID == currentSessionID { render() }
      return comparison
    }

    let controller = BrowserComparisonViewController(sessionID: sessionID, content: content)
    controller.onAcceptRevision = onAcceptRevision
    addChild(controller)
    let tab = DisplayTab(body: .browserComparison(controller), owningSessionID: sessionID)
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    // Deliberately no `persist`: the layout would name a tab whose bytes do not survive a relaunch.
    if sessionID == currentSessionID { render() }
    return controller
  }

  /// The `+` menu's route in: the system open panel, two files. The first chosen is the old
  /// side — the panel cannot say which is which, and the compare surface's tags make any
  /// mistake visible immediately.
  private func chooseFilesToCompare(for sessionID: SessionID) {
    let panel = NSOpenPanel()
    panel.message = L10n.string("Choose two files to compare")
    panel.prompt = L10n.string("Compare")
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    guard let window = view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, panel.urls.count == 2 else { return }
      _ = self?.addCompareTab(
        for: sessionID,
        oldPath: panel.urls[0].path,
        newPath: panel.urls[1].path
      )
    }
  }

  /// Builds a compare view controller, wired to persist its mode. No project guard: the pair
  /// is absolute paths, and a session with no project can still be shown a comparison.
  private func makeCompare(
    for sessionID: SessionID,
    oldPath: String,
    newPath: String,
    oldTitle: String?,
    newTitle: String?,
    mode: ImageCompareMode
  ) -> CompareViewController {
    let controller = CompareViewController(
      sessionID: sessionID,
      oldPath: oldPath,
      newPath: newPath,
      oldTitle: oldTitle,
      newTitle: newTitle,
      mode: mode
    )
    addChild(controller)
    controller.onChange = { [weak self] in self?.persist(sessionID) }
    controller.onLoadingChange = { [weak self] isLoading in
      self?.onReviewLoadingChange?(sessionID, isLoading)
    }
    return controller
  }

  /// Builds a review view controller for the session's project folder, wired to persist its
  /// mode. Returns nil for a session with no project — nothing to diff.
  private func makeReview(for sessionID: SessionID, mode: GitReviewMode) -> GitReviewViewController?
  {
    guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else { return nil }

    let controller = GitReviewViewController(
      sessionID: sessionID,
      folderPath: project.folderPath,
      mode: mode
    )
    addChild(controller)
    controller.onModeChange = { [weak self] in self?.persist(sessionID) }
    controller.onLoadingChange = { [weak self] isLoading in
      self?.onReviewLoadingChange?(sessionID, isLoading)
    }
    return controller
  }

  // MARK: - Public — Terminal Tab

  /// Adds a terminal tab and brings it to the front.
  ///
  /// Multi-instance like browsers, unlike review and info tabs. Shells are another surface
  /// where two independent states are useful — one running a server, one to type in.
  @discardableResult
  func addTerminalTab(for sessionID: SessionID) -> ShellDrawerViewController? {
    restoreIfNeeded(sessionID)
    guard let controller = makeTerminal(for: sessionID) else { return nil }

    var tabs = tabsBySession[sessionID] ?? []
    let tab = DisplayTab(body: .terminal(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Builds a terminal for the session's project folder. Nil for a session with no project —
  /// there is no directory to open a shell in.
  ///
  /// It opens in the project folder rather than where the agent has wandered to: the pane
  /// cannot see the terminal container that owns the PTY to ask it over OSC 7, and the folder
  /// is the same fallback the shell drawer already documents.
  private func makeTerminal(for sessionID: SessionID) -> ShellDrawerViewController? {
    guard let project = ProjectStore.shared.executionProject(forSessionID: sessionID) else { return nil }

    let folder = project.folderPath
    let controller = ShellDrawerViewController(
      sessionID: sessionID,
      directory: { URL(fileURLWithPath: folder) }
    )
    addChild(controller)
    // Redraw only — see the drawer host's copy: a shell renames itself far too often to write
    // through to the payload, which discards a terminal's title on the way back in regardless.
    controller.onTitleChange = { [weak self] in
      guard let self, sessionID == self.currentSessionID else { return }
      self.render()
    }
    return controller
  }

  // MARK: - Public — Simulator Tab

  /// Reveals the session's one adopted iOS Simulator device in the right panel.
  ///
  /// Singleton by session: agents and people always converge on one stable tab and lease instead
  /// of accumulating framebuffer viewers that disagree about which device a build targets.
  @discardableResult
  func activateSimulator(
    for sessionID: SessionID,
    deviceID: SimulatorDeviceID? = nil
  ) -> SimulatorPaneViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []
    if let existing = tabs.first(where: { $0.simulator != nil }),
      let controller = existing.simulator
    {
      if let deviceID { controller.selectDevice(deviceID) }
      activeTabIDBySession[sessionID] = existing.id
      persist(sessionID)
      if sessionID == currentSessionID { render() }
      return controller
    }

    let controller = makeSimulator(
      for: sessionID,
      preferredDeviceID: deviceID
    )
    let tab = DisplayTab(
      body: .simulator(controller),
      owningSessionID: sessionID
    )
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return controller
  }

  private func makeSimulator(
    for sessionID: SessionID,
    preferredDeviceID: SimulatorDeviceID?
  ) -> SimulatorPaneViewController {
    let controller = SimulatorPaneViewController(
      preferredDeviceID: preferredDeviceID,
      control: simulatorControl,
      leaseManager: simulatorLeaseManager,
      streamCoordinator: simulatorStreamCoordinator,
      inputAuthorizer: simulatorInputAuthorizer
    )
    addChild(controller)
    controller.onSelectedDeviceChange = { [weak self] _ in
      self?.persist(sessionID)
    }
    return controller
  }

  // MARK: - Public — Activity Section

  /// Compatibility route for **View ▸ Activity**. It now focuses Activity inside Overview.
  @discardableResult
  func activateFiles(for sessionID: SessionID) -> FileTreeViewController? {
    activateOverview(for: sessionID, section: .activity)?.selectActivity()
  }

  // MARK: - Public — Attachments Tab

  /// Returns the visual-file list, creating and activating its singleton tab when needed.
  @discardableResult
  func activateAttachments(for sessionID: SessionID) -> SessionAttachmentsViewController? {
    guard let controller = ensureAttachmentsTab(for: sessionID) else { return nil }
    guard let tab = tabsBySession[sessionID]?.first(where: { $0.attachments === controller })
    else { return controller }

    activeTabIDBySession[sessionID] = tab.id
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return controller
  }

  /// A newly detected file adds a quiet tab without stealing selection from what the user is
  /// reading. If the pane was empty, the new tab naturally becomes its first active surface.
  @discardableResult
  private func ensureAttachmentsTab(
    for sessionID: SessionID
  ) -> SessionAttachmentsViewController? {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.attachments != nil }) {
      existing.attachments?.refresh()
      return existing.attachments
    }

    guard let controller = makeAttachments(for: sessionID) else { return nil }
    let tab = DisplayTab(body: .attachments(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    if activeTabIDBySession[sessionID] == nil {
      activeTabIDBySession[sessionID] = tab.id
    }
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return controller
  }

  private func makeAttachments(
    for sessionID: SessionID
  ) -> SessionAttachmentsViewController? {
    guard ProjectStore.shared.project(forSessionID: sessionID) != nil else { return nil }
    let controller = SessionAttachmentsViewController(sessionID: sessionID)
    addChild(controller)

    // Two of the list's own files, held against each other. It goes through the same door an
    // agent's `display_compare_files` does — the tab that already holds this pair is reused and
    // re-read — so asking twice from the list does not grow a second tab saying the same thing.
    controller.onCompare = { [weak self] old, new in
      self?.addCompareTab(
        for: sessionID,
        oldPath: old.url.path,
        newPath: new.url.path,
        oldTitle: old.name,
        newTitle: new.name
      )
    }
    return controller
  }

  // MARK: - Public — Sharing Tab

  /// Opens the session's sharing surface: who can reach this chat and who is on it right now.
  ///
  /// Not persisted, for the same reason the Subagents tab is not: every row is live state owned
  /// by the remote server, and a restored tab would come back describing an audience that
  /// dispersed when the app quit.
  @discardableResult
  func activateSharing(for sessionID: SessionID) -> SessionSharingViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.sharing != nil }),
      let controller = existing.sharing
    {
      controller.refresh()
      activeTabIDBySession[sessionID] = existing.id
      if sessionID == currentSessionID { render() }
      return controller
    }

    let controller = SessionSharingViewController(sessionID: sessionID)
    controller.onShare = { [weak self] in self?.onShareSession?(sessionID) }
    addChild(controller)

    let tab = DisplayTab(body: .sharing(controller), owningSessionID: sessionID)
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id

    if sessionID == currentSessionID { render() }
    return controller
  }

  // MARK: - Public — Supervision Tab

  /// The host-owned fleet view. It is ephemeral and exists only while the durable grant does;
  /// unlike an agent-created document, revoking the role removes this surface immediately.
  @discardableResult
  func activateSupervision(for sessionID: SessionID) -> SupervisionListViewController? {
    restoreIfNeeded(sessionID)
    reconcileSupervisionTab(for: sessionID)
    guard let tab = tabsBySession[sessionID]?.first(where: { $0.supervision != nil }),
          let controller = tab.supervision else { return nil }
    activeTabIDBySession[sessionID] = tab.id
    controller.refresh()
    if sessionID == currentSessionID { render() }
    return controller
  }

  private func reconcileSupervisionTab(for sessionID: SessionID) {
    var tabs = tabsBySession[sessionID] ?? []
    if ControlGrantStore.shared.isManager(sessionID) {
      if let existing = tabs.first(where: { $0.supervision != nil }) {
        existing.supervision?.refresh()
        return
      }
      let controller = SupervisionListViewController(managerID: sessionID)
      controller.onOpen = { [weak self] in self?.onOpenSupervisedChat?($0) }
      controller.onMessage = { [weak self] in self?.onMessageSupervisedChat?($0) }
      controller.onArchive = { [weak self] in self?.onArchiveSupervisedChat?($0) }
      controller.onRelease = { [weak self] in self?.onReleaseSupervisedChat?($0) }
      addChild(controller)
      let tab = DisplayTab(body: .supervision(controller), owningSessionID: sessionID)
      tabs.insert(tab, at: 0)
      tabsBySession[sessionID] = tabs
      if activeTabIDBySession[sessionID] == nil { activeTabIDBySession[sessionID] = tab.id }
      advanceContentRevision(for: sessionID)
      return
    }

    let removed = tabs.filter { $0.supervision != nil }
    guard !removed.isEmpty else { return }
    removed.forEach(teardownHosted)
    let removedIDs = Set(removed.map(\.id))
    tabs.removeAll { removedIDs.contains($0.id) }
    tabsBySession[sessionID] = tabs
    if let active = activeTabIDBySession[sessionID], removedIDs.contains(active) {
      activeTabIDBySession[sessionID] = tabs.first?.id
    }
    advanceContentRevision(for: sessionID)
  }

  // MARK: - Public — Subagents Tab

  /// Opens the session's ephemeral child-agent transcript surface and selects one child.
  ///
  /// The tab is not persisted: its rows are live app-server state owned by the parent
  /// conversation, unlike a browser URL or file tree that can be reconstructed after launch.
  @discardableResult
  func activateSubagent(
    _ agent: SubagentTimeline.Agent,
    for sessionID: SessionID
  ) -> SubagentTranscriptViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.subagents != nil }),
      let controller = existing.subagents
    {
      controller.update(agent)
      wireSubagentSelection(controller, sessionID: sessionID)
      activeTabIDBySession[sessionID] = existing.id
      if sessionID == currentSessionID { render() }
      return controller
    }

    let controller = SubagentTranscriptViewController(sessionID: sessionID)
    addChild(controller)
    wireSubagentSelection(controller, sessionID: sessionID)
    controller.update(agent)

    let tab = DisplayTab(body: .subagents(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Opens the session-level Subagents surface: the compact navigator and one selected
  /// transcript live together in the side pane rather than taking space above the main chat.
  @discardableResult
  func activateSubagents(
    _ timeline: SubagentTimeline,
    selectedThreadID: String?,
    for sessionID: SessionID
  ) -> SubagentTranscriptViewController {
    restoreIfNeeded(sessionID)
    var tabs = tabsBySession[sessionID] ?? []

    if let existing = tabs.first(where: { $0.subagents != nil }),
      let controller = existing.subagents
    {
      wireSubagentSelection(controller, sessionID: sessionID)
      controller.update(timeline, selectedThreadID: selectedThreadID)
      activeTabIDBySession[sessionID] = existing.id
      if sessionID == currentSessionID { render() }
      return controller
    }

    let controller = SubagentTranscriptViewController(sessionID: sessionID)
    addChild(controller)
    wireSubagentSelection(controller, sessionID: sessionID)
    controller.update(timeline, selectedThreadID: selectedThreadID)

    let tab = DisplayTab(body: .subagents(controller))
    tabs.append(tab)
    tabsBySession[sessionID] = tabs
    activeTabIDBySession[sessionID] = tab.id

    if sessionID == currentSessionID { render() }
    return controller
  }

  /// Refreshes an already-open detail without creating, selecting, or revealing its tab.
  ///
  /// That distinction lets a user close the live view while a child keeps working: the next
  /// activity event must not reopen a pane they just dismissed.
  func updateSubagent(
    _ agent: SubagentTimeline.Agent,
    for sessionID: SessionID
  ) {
    guard
      let controller = tabsBySession[sessionID]?
        .first(where: { $0.subagents != nil })?
        .subagents,
      controller.representedThreadID == agent.descriptor.threadID
    else { return }
    controller.update(agent)
  }

  /// Refreshes a side pane that is already open without revealing one the user closed.
  func updateSubagents(
    _ timeline: SubagentTimeline,
    selectedThreadID: String?,
    for sessionID: SessionID
  ) {
    guard
      let controller = tabsBySession[sessionID]?
        .first(where: { $0.subagents != nil })?
        .subagents
    else { return }
    wireSubagentSelection(controller, sessionID: sessionID)
    controller.update(timeline, selectedThreadID: selectedThreadID)
  }

  private func wireSubagentSelection(
    _ controller: SubagentTranscriptViewController,
    sessionID: SessionID
  ) {
    controller.onSelectAgent = { [weak self] threadID in
      self?.onSubagentSelection?(sessionID, threadID)
    }
  }

  // MARK: - Public — Tab List (for the agent)

  /// The session's tabs in strip order, so the agent can list them and pick one.
  func tabs(for sessionID: SessionID) -> [DisplayTab] {
    restoreIfNeeded(sessionID)
    return tabsBySession[sessionID] ?? []
  }

  /// The already-materialized catalogue only. Search snapshots use this rather than restoring
  /// every dormant session's controller tree merely to discover browser metadata.
  func loadedTabs(for sessionID: SessionID) -> [DisplayTab] {
    tabsBySession[sessionID] ?? []
  }

  func activeTabID(for sessionID: SessionID) -> UUID? {
    restoreIfNeeded(sessionID)
    return activeTab(for: sessionID)?.id
  }

  /// Activates a tab by id. Returns false if the session has no such tab.
  @discardableResult
  func activateTab(id: UUID, for sessionID: SessionID) -> Bool {
    restoreIfNeeded(sessionID)
    guard let tabs = tabsBySession[sessionID], tabs.contains(where: { $0.id == id }) else {
      return false
    }
    activeTabIDBySession[sessionID] = id
    if tabs.first(where: { $0.id == id })?.browser != nil {
      activeBrowserTabIDBySession[sessionID] = id
    }
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return true
  }

  /// Activates a tab by its position in the strip.
  @discardableResult
  func activateTab(index: Int, for sessionID: SessionID) -> Bool {
    restoreIfNeeded(sessionID)
    guard let tabs = tabsBySession[sessionID], tabs.indices.contains(index) else { return false }
    return activateTab(id: tabs[index].id, for: sessionID)
  }

  /// Closes a tab by id. Returns false when the id is stale or belongs to another session.
  ///
  /// Which neighbour inherits the selection is `TabListState`'s rule, shared with every other
  /// tab host; the panel's own concerns — ending what the tab held, the cached image, the
  /// agent's browser target — stay here.
  @discardableResult
  func closeTab(id: UUID, for sessionID: SessionID) -> Bool {
    restoreIfNeeded(sessionID)
    var state = TabListState(
      tabs: tabsBySession[sessionID] ?? [],
      activeTabID: activeTabIDBySession[sessionID]
    )
    guard let (removed, index) = state.remove(id: id) else { return false }

    teardownHosted(removed)
    if let cacheFile = removed.cacheFile {
      DisplayPaneStore.shared.removeCachedImage(cacheFile, for: sessionID)
    }
    tabsBySession[sessionID] = state.tabs
    activeTabIDBySession[sessionID] = state.activeTabID

    if activeBrowserTabIDBySession[sessionID] == id {
      activeBrowserTabIDBySession[sessionID] =
        state.nearest(to: index) {
          $0.browser != nil
        }?.id
    }
    persist(sessionID)

    if sessionID == currentSessionID { render() }
    if state.tabs.isEmpty { onClose?() }
    return true
  }

  /// Moves a tab within the session's strip; `index` is its position after the move. Order is
  /// the user's where a hand has touched it — persisted with the tabs themselves.
  @discardableResult
  func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID) -> Bool {
    restoreIfNeeded(sessionID)
    var state = TabListState(
      tabs: tabsBySession[sessionID] ?? [],
      activeTabID: activeTabIDBySession[sessionID]
    )
    guard state.move(id: id, toIndex: index) else { return false }
    tabsBySession[sessionID] = state.tabs
    persist(sessionID)
    if sessionID == currentSessionID { render() }
    return true
  }

  /// Extra context-menu entries for a tab — the window appends "Move to …" here, because
  /// where else a tab could live is the window's knowledge, not this pane's.
  var transferEntries: ((UUID) -> [ThemedMenuEntry])?

  /// The drag half of the same wiring: whether a window point is over another pane that
  /// would adopt the tab, the move itself when the drop lands there, and the drag's end —
  /// dropped or not — so the window can settle what it arranged for the gesture. The
  /// context menu stays the gesture's pointerless twin.
  var dragOutDestination: ((UUID, NSPoint) -> Bool)?
  var performDragOut: ((UUID, NSPoint) -> Void)?
  var dragOutEnded: ((UUID) -> Void)?

  /// Whether a window point lands where a dropped tab would join this pane — the header
  /// band, full width, since an emptier strip is narrower than the drop it invites.
  /// Not gated on the window being *visible*: screen coordinates already answer that. A
  /// hidden or off-screen window's band simply does not contain the pointer's screen point,
  /// and requiring visibility as well would refuse a drop on a fixture window that is built
  /// but never shown — which is how every test here is required to build one.
  var isDropBandVisible: Bool {
    isViewLoaded && view.window != nil && !isShowingCurrentTheme
  }

  func dropBandContains(screenPoint: NSPoint) -> Bool {
    guard isDropBandVisible, let point = windowPoint(from: screenPoint) else { return false }
    return headerView.bounds.contains(headerView.convert(point, from: nil))
  }

  /// A screen point in this pane's own window, or nil when it has none to convert into.
  private func windowPoint(from screenPoint: NSPoint) -> NSPoint? {
    view.window.map { $0.convertPoint(fromScreen: screenPoint) }
  }

  /// The wash on this pane's strip while another pane's chip would land here.
  func setDropTargetHighlighted(_ highlighted: Bool) {
    guard isViewLoaded else { return }
    tabBar.isDropTarget = highlighted
  }

  func dropInsertionIndex(screenPoint: NSPoint) -> Int {
    guard isViewLoaded, let point = windowPoint(from: screenPoint) else { return 0 }
    return tabBar.insertionIndex(forWindowPoint: point)
  }

  /// What else can be done with a tab, offered by the strip on secondary click and through
  /// accessibility — the pointerless route to reordering and to movement.
  func tabContextEntries(for id: UUID) -> [ThemedMenuEntry] {
    guard id != Self.currentThemeTabID else { return [] }
    guard syntheticOverview?.tab.id != id else { return [] }
    // A proxy's menu is about the window it points at, not about a tab this pane holds — so it
    // replaces the standard entries rather than joining them. "Close Other Tabs" beside a chip
    // that is not one of the tabs would be answering a different question.
    if let proxy = detachedWindowProxy(id) {
      return [
        .item(ThemedMenuItem(
          title: L10n.string("Focus Window"),
          onChoose: proxy.onFocus
        )),
        .item(ThemedMenuItem(
          title: L10n.string("Bring Back to Panel"),
          onChoose: proxy.onBringBack
        ))
      ]
    }
    guard let sessionID = currentSessionID else { return [] }
    var entries = standardTabEntries(for: id, sessionID: sessionID)
    guard !entries.isEmpty else { return [] }
    // What the tab *holds* comes before what can be done to the tab: a comparison is exported
    // far more often than a tab is closed to the right, and the closes are the run everything
    // else in this menu is measured against.
    if let compare = tabs(for: sessionID).first(where: { $0.id == id })?.compare,
      compare.canExportComparison
    {
      entries.insert(.separator, at: 0)
      entries.insert(
        .item(
          ThemedMenuItem(
            title: L10n.string("Export Comparison…"),
            onChoose: { [weak compare] in compare?.exportComparison() }
          )), at: 0)
    }
    if let transfers = transferEntries?(id), !transfers.isEmpty {
      entries.append(.separator)
      entries.append(contentsOf: transfers)
    }
    return entries
  }

  // MARK: - Public — Session Lifecycle

  /// Shows the app-wide theme document without adding it to the selected session. Calls from
  /// that session continue to update the same `AppThemeLibrary.current` the inspector observes.
  func showCurrentTheme() {
    guard !isShowingCurrentTheme else { return }
    isShowingCurrentTheme = true
    render()
  }

  /// Returns the panel to the selected session's own tabs.
  func hideCurrentTheme() {
    guard isShowingCurrentTheme else { return }
    isShowingCurrentTheme = false
    render()
  }

  /// An explicit session-surface command (Browser, Review, Activity, and their peers) leaves the
  /// global inspector first. Ordinary session selection uses `showSession` and intentionally
  /// preserves it.
  func showSessionTabs(_ sessionID: SessionID?) {
    discardSyntheticOverview()
    currentSessionID = sessionID
    if let sessionID {
      restoreIfNeeded(sessionID)
      reconcileSupervisionTab(for: sessionID)
    }
    isShowingCurrentTheme = false
    render()
  }

  /// Switches the panel to a session's tabs. Passing nil empties it.
  func showSession(_ sessionID: SessionID?) {
    discardSyntheticOverview()
    currentSessionID = sessionID
    if let sessionID {
      restoreIfNeeded(sessionID)
      reconcileSupervisionTab(for: sessionID)
    }
    render()
  }

  /// Opens a session by hand, supplying Overview when its persisted strip is empty.
  ///
  /// This is intentionally a different route from session selection: the window still closes
  /// for an empty session selected in the sidebar, while pressing the panel toggle has something
  /// useful to reveal. The synthetic tab joins neither persistence nor the agent-facing tab list.
  func showSessionWithDefaultOverview(_ sessionID: SessionID?) {
    discardSyntheticOverview()
    currentSessionID = sessionID
    guard let sessionID else {
      render()
      return
    }

    restoreIfNeeded(sessionID)
    reconcileSupervisionTab(for: sessionID)
    if tabsBySession[sessionID]?.isEmpty == true,
      let overview = makeOverview(for: sessionID, initialSection: .info)
    {
      overview.onSectionChange = nil
      syntheticOverview = (
        sessionID,
        DisplayTab(body: .overview(overview), owningSessionID: sessionID)
      )
    }
    isShowingCurrentTheme = false
    render()
  }

  /// Whether a session has any tab, which is what decides if the panel opens.
  func hasContent(for sessionID: SessionID) -> Bool {
    restoreIfNeeded(sessionID)
    reconcileSupervisionTab(for: sessionID)
    return !(tabsBySession[sessionID]?.isEmpty ?? true)
  }

  /// O(1) identity for the panel content currently associated with a session.
  ///
  /// `hasContent(for:)` is called first on the session-switch path, so any lazy restore has
  /// already completed before the window reads this value.
  func contentRevision(for sessionID: SessionID) -> UInt64 {
    contentRevisionBySession[sessionID] ?? 0
  }

  /// Drops every session not in the given set, tearing down any live surface it held, so
  /// deleted sessions do not keep their tabs — and their web content processes — alive forever.
  func retainOnly(sessionIDs: Set<SessionID>) {
    if let syntheticOverview, !sessionIDs.contains(syntheticOverview.sessionID) {
      discardSyntheticOverview()
    }
    for (sessionID, tabs) in tabsBySession where !sessionIDs.contains(sessionID) {
      tabs.forEach { teardownHosted($0) }
    }

    tabsBySession = tabsBySession.filter { sessionIDs.contains($0.key) }
    activeTabIDBySession = activeTabIDBySession.filter { sessionIDs.contains($0.key) }
    contentRevisionBySession = contentRevisionBySession.filter {
      sessionIDs.contains($0.key)
    }
    activeBrowserTabIDBySession = activeBrowserTabIDBySession.filter {
      sessionIDs.contains($0.key)
    }
    SessionAttachmentStore.shared.retainOnly(sessionIDs: sessionIDs)

    if let currentSessionID, !sessionIDs.contains(currentSessionID) {
      self.currentSessionID = nil
    }

    // Drop the persisted layouts and image caches of the same removed sessions.
    DisplayPaneStore.shared.retainOnly(sessionIDs: sessionIDs)

    render()
  }

  /// Tears down one deleted session without filtering every resident panel.
  func removeSession(_ sessionID: SessionID) {
    if syntheticOverview?.sessionID == sessionID { discardSyntheticOverview() }
    tabsBySession.removeValue(forKey: sessionID)?.forEach { teardownHosted($0) }
    activeTabIDBySession.removeValue(forKey: sessionID)
    contentRevisionBySession.removeValue(forKey: sessionID)
    activeBrowserTabIDBySession.removeValue(forKey: sessionID)
    if currentSessionID == sessionID { currentSessionID = nil }
    render()
  }

  // MARK: - Tab Interaction

  private func userActivatedTab(_ id: UUID) {
    guard id != Self.currentThemeTabID else { return }
    if syntheticOverview?.tab.id == id { return }
    if let proxy = detachedWindowProxy(id) {
      proxy.onFocus()
      return
    }
    guard let currentSessionID else { return }
    activateTab(id: id, for: currentSessionID)
  }

  private func userClosedTab(_ id: UUID) {
    if id == Self.currentThemeTabID {
      hideCurrentTheme()
      onClose?()
      return
    }
    if syntheticOverview?.tab.id == id {
      discardSyntheticOverview()
      onClose?()
      return
    }
    // A proxy draws no ✕, so this cannot arrive for one — and if it ever did, standing for a
    // window is not holding it, and closing it here would end pages this chip only points at.
    guard detachedWindowProxy(id) == nil else { return }
    guard let sessionID = currentSessionID else { return }
    closeTab(id: id, for: sessionID)
  }

  // MARK: - Detached Window Proxies

  /// A chip standing in for a page that is now in a window of its own.
  ///
  /// Supplied by the window, because which windows exist is the window's knowledge. Deliberately
  /// **not** a `PaneTab`: the panel does not hold this page, and `panel_list_tabs` must keep
  /// saying so — a tab moved out disappears from the agent's list exactly as a closed one does.
  /// This is the answer to "where did it go", which is a question the *user* asks.
  struct DetachedWindowProxy {
    let windowID: UUID
    let title: String
    let onFocus: () -> Void
    let onBringBack: () -> Void
  }

  /// How many browsers the session has across every host — supplied by the window, which is the
  /// only thing that sees them all. Nil falls back to this pane's own count.
  var sessionBrowserCount: ((SessionID) -> Int)?

  var detachedWindowProxies: ((SessionID) -> [DetachedWindowProxy])? {
    didSet { render() }
  }

  /// Redraws the strip because the set of detached windows changed. Deliberately *not*
  /// `showSessionTabs`, which also puts the app-theme document away.
  func refreshDetachedWindowProxies() {
    render()
  }

  private func proxies(for sessionID: SessionID?) -> [DetachedWindowProxy] {
    guard !isShowingCurrentTheme, let sessionID else { return [] }
    return detachedWindowProxies?(sessionID) ?? []
  }

  private func detachedWindowProxy(_ id: UUID) -> DetachedWindowProxy? {
    proxies(for: currentSessionID).first { $0.windowID == id }
  }

  /// Detaches a live tab's view controller. Content tabs need nothing.
  ///
  /// A terminal is the one kind holding something a detach does not release: closing its tab
  /// has to kill the shell, or the process outlives every view that could reach it.
  private func teardownHosted(_ tab: DisplayTab) {
    tab.terminal?.terminate()
    tab.simulator?.terminate()
    if presentedSimulator === tab.simulator { presentedSimulator = nil }

    guard let controller = tab.hostedController else { return }
    if installedController === controller { installHosted(nil) }
    controller.view.removeFromSuperview()
    controller.removeFromParent()
  }

  private func discardSyntheticOverview() {
    guard let syntheticOverview else { return }
    self.syntheticOverview = nil
    teardownHosted(syntheticOverview.tab)
  }

  // MARK: - Rendering

  private func activeTab(for sessionID: SessionID?) -> DisplayTab? {
    guard let sessionID, let tabs = tabsBySession[sessionID], !tabs.isEmpty else { return nil }
    if let id = activeTabIDBySession[sessionID], let tab = tabs.first(where: { $0.id == id }) {
      return tab
    }
    return tabs.last
  }

  /// Not private: the Reload action in `DisplayPaneMenu` re-runs it.
  func render() {
    // The panel starts collapsed, so its views may not exist yet when content arrives.
    // Nothing is lost by skipping: `viewDidLoad` renders once they do.
    guard isViewLoaded else { return }

    let persistedTabs = isShowingCurrentTheme
      ? []
      : currentSessionID.flatMap { tabsBySession[$0] } ?? []
    if !persistedTabs.isEmpty { discardSyntheticOverview() }
    let fallback = currentSessionID.flatMap { sessionID in
      syntheticOverview?.sessionID == sessionID ? syntheticOverview?.tab : nil
    }
    let tabs = persistedTabs.isEmpty ? fallback.map { [$0] } ?? [] : persistedTabs
    let active = isShowingCurrentTheme
      ? nil
      : activeTab(for: currentSessionID) ?? fallback
    updateSimulatorPresentation(active?.simulator)
    let performanceSpan = PerformanceRecorder.shared.begin(
      "display-pane.render",
      category: "display-pane.ui",
      metadata: [
        "tabs": String(tabs.count),
        "kind": isShowingCurrentTheme ? "current-theme" : Self.performanceKind(of: active),
      ]
    )
    defer { performanceSpan.end() }

    updateHeaderForCurrentTheme()
    if isShowingCurrentTheme {
      headerCustomizationView.showSession(nil)
      renderCurrentThemeTab()
      renderCurrentThemeContent()
      placeholderLabel.isHidden = true
      return
    }

    headerCustomizationView.showSession(
      currentSessionID?.uuidString.lowercased()
    )
    renderTabBar(tabs: tabs, active: active)
    renderContent(active: active)

    placeholderLabel.isHidden = active != nil
  }

  /// The global document owns the whole row. Session-only extension decoration and `+` both
  /// disappear, and the strip takes their space rather than leaving a blank reservation behind.
  ///
  /// The toggle is not theirs to take. The two that go are the ones that act on *this chat's*
  /// tabs, which the global document is not one of; the toggle acts on the pane, and the pane
  /// is on screen either way.
  private func updateHeaderForCurrentTheme() {
    if isShowingCurrentTheme {
      regularTabBarTrailingConstraint?.isActive = false
      globalTabBarTrailingConstraint?.isActive = true
    } else {
      globalTabBarTrailingConstraint?.isActive = false
      regularTabBarTrailingConstraint?.isActive = true
    }
    headerCustomizationView.isHidden = isShowingCurrentTheme
    newTabButton.isHidden = isShowingCurrentTheme
  }

  private func renderCurrentThemeTab() {
    tabBar.update(items: [
      DisplayTabBarItem(
        id: Self.currentThemeTabID,
        title: L10n.string("Current Theme"),
        symbolName: "paintbrush.pointed",
        isActive: true,
        customizationTarget: .displayTabHeader(sessionID: nil)
      )
    ])
  }

  private func renderCurrentThemeContent() {
    imageView.image = nil
    imageView.isHidden = true
    hideHTML()
    captionLabel.isHidden = true
    contentMenuButton.isHidden = true
    installHosted(currentThemeController)
  }

  /// The strip is the pane's header, so it is always drawn — a lone tab names the pane, which
  /// is the job the title label above it used to do twice.
  private func renderTabBar(tabs: [DisplayTab], active: DisplayTab?) {
    let target = ExtensionComponentTarget.displayTabHeader(
      sessionID: currentSessionID?.uuidString.lowercased()
    )
    // Proxies last, after the pane's own tabs: they are not tabs of this pane, and putting one
    // among them would read as the page still being here.
    let ownItems = tabs.map {
      DisplayTabBarItem(
        id: $0.id,
        title: $0.title,
        symbolName: $0.symbolName,
        isActive: $0.id == active?.id,
        customizationTarget: target
      )
    }
    let proxyItems = proxies(for: currentSessionID).map {
      DisplayTabBarItem(
        id: $0.windowID,
        title: $0.title,
        // The window glyph, not the globe: this chip is about *where* the page is, and a second
        // globe beside the pane's own browser tabs would say there are two pages here.
        symbolName: "macwindow",
        isActive: false,
        customizationTarget: target,
        showsClose: false
      )
    }
    tabBar.update(items: ownItems + proxyItems)
  }

  private func renderContent(active: DisplayTab?) {
    switch active?.body {
    case .content(let content):
      installHosted(nil)
      switch content.body {
      case .image(let image, let url):
        imageView.image = image
        imageView.fileURL = url
        imageView.isHidden = false
        hideHTML()
      case .html(let html):
        imageView.image = nil
        imageView.isHidden = true
        let webView = installDocumentWebViewIfNeeded()
        webView.isHidden = false
        documentWebViewHasContent = true
        webView.stopLoading()
        allowsInitialDocumentNavigation = true
        webView.loadHTMLString(Self.themed(html), baseURL: nil)
      case .chart(let spec):
        // The chart draws its own caption *and* its own actions, so both of the panel's stand
        // down. The menu button is not merely redundant here — it is unreachable: `hostedView`
        // is added last, runs to the foot of the pane, and a chart's ground is opaque, so the
        // `⋯` was underneath it and the copy it offered could never be clicked. See
        // `ChartPaneViewController`, which is where those two actions now live.
        imageView.image = nil
        imageView.isHidden = true
        hideHTML()
        captionLabel.isHidden = true
        contentMenuButton.isHidden = true
        installHosted(
          ChartPaneViewController(spec: spec, subtitle: content.subtitle),
          owned: true
        )
        return

      case .semanticScene(let scene):
        imageView.image = nil
        imageView.isHidden = true
        hideHTML()
        captionLabel.isHidden = true
        contentMenuButton.isHidden = true
        var children: [ExtensionNode] = []
        if !content.subtitle.isEmpty {
          children.append(.text(content.subtitle, role: .detail))
        }
        children.append(.scene(scene))
        installHosted(
          SemanticDocumentViewController(
            root: .stack(
              axis: .vertical,
              spacing: .medium,
              children: children
            )
          ),
          owned: true
        )
        return
      }
      captionLabel.stringValue = content.subtitle
      captionLabel.isHidden = false
      contentMenuButton.isHidden = false

    case .browser(let browser):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(browser)

    case .audit(let audit):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(audit)
      if audit.browser.currentURL == nil, let url = audit.browser.restoredURL {
        audit.browser.restoredURL = nil
        audit.browser.navigate(to: url)
      }

    case .review(let review):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(review)
      // Loads only when actually shown, the same deferred rule as the browser's page.
      review.refresh(force: false)

    case .overview(let overview):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(overview)
      overview.refreshSelectedSection()

    case .compare(let compare):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(compare)
      // The same deferred rule: a restored comparison reads its two files when looked at.
      compare.refresh(force: false)

    case .browserComparison(let comparison):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      // No deferred read: its bytes are already in hand, which is the whole reason this tab is
      // ephemeral rather than persisted.
      installHosted(comparison)

    case .terminal(let terminal):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(terminal)
      // The same deferred rule the browser's page and the review's git call follow: a
      // restored terminal tab costs no process until it is actually looked at.
      terminal.startIfNeeded()

    case .attachments(let attachments):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(attachments)
      attachments.refresh()

    case .subagents(let subagents):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(subagents)

    case .sharing(let sharing):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(sharing)
      sharing.refresh()

    case .supervision(let supervision):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(supervision)
      supervision.refresh()

    case .simulator(let simulator):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(simulator)

    case .deviceLog(let logs):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(logs)

    case .extensionPanel(let panel):
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
      installHosted(panel)

    case nil:
      installHosted(nil)
      imageView.image = nil
      imageView.isHidden = true
      hideHTML()
      captionLabel.isHidden = true
      contentMenuButton.isHidden = true
    }
  }

  private func updateSimulatorPresentation(_ simulator: SimulatorPaneViewController?) {
    guard presentedSimulator !== simulator else { return }
    presentedSimulator?.setPresented(false)
    presentedSimulator = simulator
    simulator?.setPresented(true)
  }

  /// Hides the shared web view and drops its page, so a switched-away document is not still
  /// running its timers and animations behind the tab now on screen.
  private func hideHTML() {
    guard let documentWebView else { return }
    documentWebView.isHidden = true
    guard documentWebViewHasContent else { return }
    documentWebViewHasContent = false
    documentWebView.stopLoading()
    allowsInitialDocumentNavigation = true
    documentWebView.loadHTMLString("", baseURL: nil)
  }

  /// Installs the one shared HTML renderer at the same z-position and geometry the former eager
  /// child occupied. A document brings its own margins, so unlike the image preview it reaches
  /// the pane edges; the caption footer remains below it.
  private func installDocumentWebViewIfNeeded() -> WKWebView {
    if let documentWebView { return documentWebView }

    let webView = WKWebView()
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    webView.underPageBackgroundColor = Design.Surface.ground
    view.addSubview(webView, positioned: .below, relativeTo: hostedView)

    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(
        equalTo: captionLabel.topAnchor,
        constant: -DisplayPaneDefaults.padding
      ),
    ])
    documentWebView = webView
    return webView
  }

  /// Parents (or clears) a live tab's view controller into the host, reusing the installed one
  /// so switching tabs never rebuilds its state.
  /// - Parameter owned: `true` when this pane built the controller and nothing else retains it.
  private func installHosted(_ controller: NSViewController?, owned: Bool = false) {
    let performanceSpan = PerformanceRecorder.shared.begin(
      "display-pane.install-hosted",
      category: "display-pane.ui",
      metadata: ["changed": installedController === controller ? "false" : "true"]
    )
    defer { performanceSpan.end() }

    guard installedController !== controller else {
      hostedView.isHidden = controller == nil
      return
    }

    // Order matters: releasing the outgoing owned controller before its view is unparented
    // deallocates it, which empties the weak `installedController` and leaves the view behind —
    // the very bug this ownership exists to prevent.
    installedController?.view.removeFromSuperview()
    installedController = controller
    ownedController = owned ? controller : nil

    guard let controller else {
      hostedView.isHidden = true
      return
    }

    controller.view.translatesAutoresizingMaskIntoConstraints = false
    hostedView.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.topAnchor.constraint(equalTo: hostedView.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: hostedView.bottomAnchor),
      controller.view.leadingAnchor.constraint(equalTo: hostedView.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: hostedView.trailingAnchor),
    ])

    // Settings and session changes detach a tab controller without releasing it. A theme sweep
    // only walks window content, so that cached tree can miss the switch and return with frozen
    // layer colours from the theme it left under. The generation check keeps an ordinary tab
    // switch O(1) while repairing only a tree that was actually away for a sweep.
    AppThemeRefresh.repaintIfNeeded(controller.view)
    hostedView.isHidden = false

    // A restored browser carries its page URL but has not loaded it — the load is deferred to
    // the moment it is actually shown, so a background session's browser costs nothing until
    // selected.
    if let browser = controller as? BrowserViewController,
      browser.currentURL == nil, let url = browser.restoredURL
    {
      browser.restoredURL = nil
      browser.navigate(to: url)
    }
  }

  /// Stable tab kinds for traces. Controller types are implementation details and session IDs
  /// are user state, so neither is serialized into performance data.
  private static func performanceKind(of tab: DisplayTab?) -> String {
    switch tab?.body {
    case .content(let content):
      switch content.body {
      case .image: return "image"
      case .html: return "html"
      case .semanticScene: return "semantic-scene"
      case .chart: return "chart"
      }
    case .browser: return "browser"
    case .audit: return "audit"
    case .review: return "review"
    case .overview: return "overview"
    case .terminal: return "terminal"
    case .attachments: return "attachments"
    case .subagents: return "subagents"
    case .sharing: return "sharing"
    case .supervision: return "supervision"
    case .simulator: return "simulator"
    case .deviceLog: return "device-log"
    case .extensionPanel: return "extension-panel"
    case .compare: return "compare"
    case .browserComparison: return "browser-comparison"
    case nil: return "empty"
    }
  }

  // MARK: - Persistence

  /// Rebuilds a session's tabs from disk the first time it is touched this run, so the panel
  /// comes back after a relaunch. A no-op once loaded; an empty marker is left for a session with
  /// nothing stored, so its layout file is not re-read on every access.
  private func restoreIfNeeded(_ sessionID: SessionID) {
    guard tabsBySession[sessionID] == nil else { return }
    guard let panel = DisplayPaneStore.shared.loadLayout(for: sessionID) else {
      tabsBySession[sessionID] = []
      return
    }

    var tabs: [DisplayTab] = []
    // Image tabs written before a shown image became a row in the Attachments list. They are
    // converted rather than reopened, and the conversion is deferred to *after* the session's
    // tabs are in place: recording announces synchronously, this controller answers that
    // announcement with `ensureAttachmentsTab`, and that call re-enters `restoreIfNeeded` — which
    // is only a no-op once `tabsBySession` holds something. Recording inside this loop restores
    // the same layout again on every file, which recurses until the stack is gone.
    var imagesToConvert: [(source: URL?, cacheFile: String?, wasActive: Bool)] = []
    let storedOverviewTabs = panel.panelTabs.filter {
      $0.kind == .files || $0.kind == .info
    }
    // Old layouts may contain both singleton tabs. The active one wins; otherwise Activity is
    // the useful default. Exactly one identity and strip position survive the merge.
    let storedOverview = storedOverviewTabs.first { $0.id == panel.activeTabID }
      ?? storedOverviewTabs.first { $0.kind == .files }
      ?? storedOverviewTabs.first
    for persisted in panel.panelTabs {
      let id = UUID(uuidString: persisted.id) ?? UUID()
      switch persisted.kind {
      case .browser:
        let controller = makeBrowser(for: sessionID)
        controller.restoredURL = persisted.url
        tabs.append(DisplayTab(id: id, body: .browser(controller)))

      case .audit:
        let mode = persisted.mode.flatMap(ExecutionAuditViewController.Mode.init(rawValue:))
          ?? .audit
        let controller = makeAudit(for: sessionID, mode: mode)
        controller.restoredURL = persisted.url
        tabs.append(DisplayTab(id: id, body: .audit(controller)))

      case .html:
        guard let html = persisted.html else { continue }
        let content = DisplayContent(
          body: .html(html), title: persisted.title, subtitle: persisted.subtitle)
        tabs.append(DisplayTab(id: id, body: .content(content)))

      case .image:
        // A session with a project has an Attachments list, and that list is where a shown
        // image belongs — so the tab converts into a row and the PNG copy beside the layout is
        // dropped. A session without one has nowhere to convert *to*: it is the same fallback
        // `display_image` takes, so its tab is restored exactly as it was written.
        if ProjectStore.shared.project(forSessionID: sessionID) != nil {
          imagesToConvert.append((
            source: persisted.url.flatMap(URL.init(string:)),
            cacheFile: persisted.cacheFile,
            wasActive: persisted.id == panel.activeTabID
          ))
          continue
        }
        guard let cacheFile = persisted.cacheFile,
          let image = DisplayPaneStore.shared.loadImage(cacheFile, for: sessionID)
        else { continue }
        let url = persisted.url.flatMap(URL.init(string:)) ?? URL(fileURLWithPath: "/")
        let content = DisplayContent(
          body: .image(image, url: url), title: persisted.title, subtitle: persisted.subtitle)
        let tab = DisplayTab(id: id, body: .content(content))
        tab.cacheFile = cacheFile
        tabs.append(tab)

      case .chart:
        // Validated again on the way back in: the file is user-writable, and a spec whose
        // series no longer line up with its categories would draw a chart that lies.
        guard let spec = try? persisted.chart?.validated() else { continue }
        let content = DisplayContent(
          body: .chart(spec),
          title: persisted.title,
          subtitle: persisted.subtitle
        )
        tabs.append(DisplayTab(id: id, body: .content(content)))

      case .semanticScene:
        guard let scene = persisted.semanticScene else { continue }
        let content = DisplayContent(
          body: .semanticScene(scene),
          title: persisted.title,
          subtitle: persisted.subtitle
        )
        tabs.append(DisplayTab(id: id, body: .content(content)))

      case .review:
        // Restored in its saved mode; no git runs until the tab is actually shown.
        let mode = persisted.mode.flatMap(GitReviewMode.init(rawValue:)) ?? .uncommitted
        guard let controller = makeReview(for: sessionID, mode: mode) else { continue }
        tabs.append(DisplayTab(id: id, body: .review(controller)))

      case .info:
        guard persisted.id == storedOverview?.id,
          let controller = makeOverview(for: sessionID, initialSection: .info)
        else { continue }
        tabs.append(DisplayTab(
          id: id,
          body: .overview(controller),
          owningSessionID: sessionID
        ))

      case .terminal:
        // The tab comes back, the process does not — a shell's state was never on disk.
        // No child is spawned until the tab is shown (`startIfNeeded`).
        guard let controller = makeTerminal(for: sessionID) else { continue }
        tabs.append(DisplayTab(id: id, body: .terminal(controller)))

      case .files:
        guard persisted.id == storedOverview?.id,
          let controller = makeOverview(for: sessionID, initialSection: .activity)
        else { continue }
        tabs.append(DisplayTab(
          id: id,
          body: .overview(controller),
          owningSessionID: sessionID
        ))

      case .attachments:
        guard let controller = makeAttachments(for: sessionID) else { continue }
        tabs.append(DisplayTab(id: id, body: .attachments(controller)))

      case .deviceLog:
        tabs.append(DisplayTab(
          id: id,
          body: .deviceLog(DeviceLogPaneViewController(owningSessionID: sessionID)),
          owningSessionID: sessionID
        ))

      case .simulator:
        let deviceID = persisted.simulatorDeviceID.flatMap(SimulatorDeviceID.init)
        let controller = makeSimulator(
          for: sessionID,
          preferredDeviceID: deviceID
        )
        tabs.append(DisplayTab(
          id: id,
          body: .simulator(controller),
          owningSessionID: sessionID
        ))

      case .extensionPanel:
        guard let extensionIdentifier = persisted.extensionIdentifier,
          let panelID = persisted.extensionPanelID
        else { continue }
        let controller = makeExtensionPanel(
          extensionIdentifier: extensionIdentifier,
          panelID: panelID,
          title: persisted.title ?? "Extension Panel",
          for: sessionID
        )
        tabs.append(DisplayTab(id: id, body: .extensionPanel(controller)))

      case .compare:
        // Restored in its saved mode; neither file is read until the tab is shown.
        guard let oldPath = persisted.compareOldPath,
          let newPath = persisted.compareNewPath
        else { continue }
        let controller = makeCompare(
          for: sessionID,
          oldPath: oldPath,
          newPath: newPath,
          oldTitle: persisted.compareOldTitle,
          newTitle: persisted.compareNewTitle,
          mode: persisted.mode.flatMap(ImageCompareMode.init(rawValue:)) ?? .wipeHorizontal
        )
        tabs.append(DisplayTab(id: id, body: .compare(controller)))
      }
    }

    // Finish the migration in storage as well as memory. Transform the stored payload rather
    // than serializing the restored controllers: an extension panel can legitimately be
    // unavailable this early, and merging Overview must not erase unrelated tabs with it.
    if storedOverviewTabs.count > 1, let storedOverview {
      let migratedPanelTabs = panel.panelTabs.filter { tab in
        (tab.kind != .files && tab.kind != .info) || tab.id == storedOverview.id
      }
      DisplayPaneStore.shared.saveLayout(
        tabs: migratedPanelTabs,
        activeID: panel.activeTabID,
        for: sessionID
      )
    }

    tabsBySession[sessionID] = tabs

    if let activeString = panel.activeTabID,
      let activeID = UUID(uuidString: activeString),
      tabs.contains(where: { $0.id == activeID })
    {
      activeTabIDBySession[sessionID] = activeID
    } else {
      activeTabIDBySession[sessionID] = tabs.last?.id
    }
    let activeID = activeTabIDBySession[sessionID]
    activeBrowserTabIDBySession[sessionID] =
      tabs.first {
        $0.id == activeID && $0.browser != nil
      }?.id ?? tabs.first(where: { $0.browser != nil })?.id

    convertPersistedImages(imagesToConvert, for: sessionID)
  }

  /// Files a relaunch's image tabs into the session's Attachments list and forgets the tabs.
  ///
  /// Safe to announce from here only because the session's tabs are already in place: the
  /// recorder posts synchronously, this controller answers with `ensureAttachmentsTab`, and that
  /// is what puts the list in the strip — so the pane keeps a surface for what it just took off
  /// it. A source that has since been deleted files nothing; the cached PNG goes either way,
  /// since the tab that owned it is gone.
  private func convertPersistedImages(
    _ images: [(source: URL?, cacheFile: String?, wasActive: Bool)],
    for sessionID: SessionID
  ) {
    guard !images.isEmpty,
      let project = ProjectStore.shared.executionProject(forSessionID: sessionID)
    else { return }

    var wasShowingOne = false
    for image in images {
      if let source = image.source,
        source.isFileURL,
        FileManager.default.fileExists(atPath: source.path)
      {
        SessionAttachmentStore.shared.record(
          declared: source,
          sessionID: sessionID,
          projectRoot: project.folderURL,
          origin: .agent
        )
      }
      if let cacheFile = image.cacheFile {
        DisplayPaneStore.shared.removeCachedImage(cacheFile, for: sessionID)
      }
      wasShowingOne = wasShowingOne || image.wasActive
    }

    // The panel may not point at a tab that is no longer there. The list is where that image
    // went, so it is what the user who left the app looking at it comes back to.
    if wasShowingOne,
      let attachments = tabsBySession[sessionID]?.first(where: { $0.attachments != nil })
    {
      activeTabIDBySession[sessionID] = attachments.id
    }
    persist(sessionID)
    if sessionID == currentSessionID { render() }
  }

  /// Writes the session's current tabs and selection to disk.
  private func persist(_ sessionID: SessionID) {
    advanceContentRevision(for: sessionID)
    let tabs = tabsBySession[sessionID] ?? []
    let persistedTabs = tabs.compactMap(persisted)
    let active =
      activeTabIDBySession[sessionID]
      .flatMap { activeID in
        persistedTabs.contains { $0.id == activeID.uuidString }
          ? activeID.uuidString
          : nil
      }
      ?? persistedTabs.first?.id
    DisplayPaneStore.shared.saveLayout(tabs: persistedTabs, activeID: active, for: sessionID)
  }

  private func advanceContentRevision(for sessionID: SessionID) {
    contentRevisionBySession[sessionID, default: 0] &+= 1
  }

  private func persisted(_ tab: DisplayTab) -> PersistedTab? {
    if let audit = tab.audit {
      return PersistedTab(
        id: tab.id.uuidString,
        kind: .audit,
        title: tab.title,
        subtitle: "",
        url: audit.browser.contextKind == .shared ? audit.restoredURL : nil,
        html: nil,
        cacheFile: nil,
        mode: audit.mode.rawValue
      )
    }

    if let browser = tab.browser {
      // Private contexts are runtime-only by definition. Persisting their URL would both
      // misrepresent the missing ephemeral state and leave a browsing-history trace.
      guard browser.contextKind == .shared else { return nil }
      // An empty browser (never navigated) has nothing worth restoring.
      guard let url = browser.currentURL?.absoluteString ?? browser.restoredURL else { return nil }
      return PersistedTab(
        id: tab.id.uuidString, kind: .browser, title: tab.title,
        subtitle: "", url: url, html: nil, cacheFile: nil
      )
    }

    if let review = tab.review {
      return PersistedTab(
        id: tab.id.uuidString, kind: .review, title: tab.title,
        subtitle: "", url: nil, html: nil, cacheFile: nil,
        mode: review.mode.rawValue
      )
    }

    if tab.terminal != nil {
      return PersistedTab(
        id: tab.id.uuidString, kind: .terminal, title: tab.title,
        subtitle: "", url: nil, html: nil, cacheFile: nil
      )
    }

    if let overview = tab.overview {
      return PersistedTab(
        id: tab.id.uuidString,
        kind: overview.selectedSection == .activity ? .files : .info,
        title: tab.title,
        subtitle: "", url: nil, html: nil, cacheFile: nil
      )
    }

    if tab.attachments != nil {
      return PersistedTab(
        id: tab.id.uuidString, kind: .attachments, title: tab.title,
        subtitle: "", url: nil, html: nil, cacheFile: nil
      )
    }

    if let simulator = tab.simulator {
      return PersistedTab(
        id: tab.id.uuidString,
        kind: .simulator,
        title: tab.title,
        subtitle: "",
        url: nil,
        html: nil,
        cacheFile: nil,
        simulatorDeviceID: simulator.selectedDeviceID?.rawValue
      )
    }

    if let panel = tab.extensionPanel {
      return PersistedTab(
        id: tab.id.uuidString,
        kind: .extensionPanel,
        title: panel.panelTitle,
        subtitle: "",
        url: nil,
        html: nil,
        cacheFile: nil,
        extensionIdentifier: panel.extensionIdentifier,
        extensionPanelID: panel.panelID
      )
    }

    if let compare = tab.compare {
      return PersistedTab(
        id: tab.id.uuidString, kind: .compare, title: tab.title,
        subtitle: "", url: nil, html: nil, cacheFile: nil,
        mode: compare.compareMode.rawValue,
        compareOldPath: compare.oldPath,
        compareNewPath: compare.newPath,
        compareOldTitle: compare.oldTitle,
        compareNewTitle: compare.newTitle
      )
    }

    guard let content = tab.content else { return nil }
    switch content.body {
    case .html(let html):
      return PersistedTab(
        id: tab.id.uuidString, kind: .html, title: content.title,
        subtitle: content.subtitle, url: nil, html: html, cacheFile: nil
      )
    case .image(_, let url):
      return PersistedTab(
        id: tab.id.uuidString, kind: .image, title: content.title,
        subtitle: content.subtitle, url: url.absoluteString, html: nil, cacheFile: tab.cacheFile
      )
    case .semanticScene(let scene):
      return PersistedTab(
        id: tab.id.uuidString,
        kind: .semanticScene,
        title: content.title,
        subtitle: content.subtitle,
        url: nil,
        html: nil,
        cacheFile: nil,
        semanticScene: scene
      )
    case .chart(let spec):
      return PersistedTab(
        id: tab.id.uuidString,
        kind: .chart,
        title: content.title,
        subtitle: content.subtitle,
        url: nil,
        html: nil,
        cacheFile: nil,
        chart: spec
      )
    }
  }

  /// Adds a `color-scheme` declaration to documents that do not carry one.
  ///
  /// The panel sits beside a dark terminal, and unstyled HTML would otherwise render on the
  /// browser's default white. Declaring support for both lets WebKit pick its dark canvas
  /// and text colours to match the app. A document that already says something about
  /// `color-scheme` is left alone — it has an opinion, and it outranks this one.
  private static func themed(_ html: String) -> String {
    guard !html.contains("color-scheme") else { return html }
    return "<meta name=\"color-scheme\" content=\"light dark\">\n" + html
  }

}

// MARK: - WKNavigationDelegate

extension DisplayPaneController: WKNavigationDelegate {

  /// Keeps the panel showing the document it was given.
  ///
  /// Following a link would leave a 380pt-wide renderer with no back button, no address bar
  /// and no way home — so ordinary web links are handed to the real browser instead, which has
  /// all three. Every other top-level navigation is refused. (An agent who wants a navigable page
  /// uses the browser tab, not a document.) Subresources do not come through here, and embedded
  /// frames keep their own navigation, so scripts, styles, images and framed content still load.
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let decision = DisplayDocumentNavigationPolicy.decision(
      navigationType: navigationAction.navigationType,
      url: navigationAction.request.url,
      targetsMainFrame: navigationAction.targetFrame?.isMainFrame,
      allowsInitialDocumentLoad: allowsInitialDocumentNavigation
    )
    switch decision {
    case .allow:
      decisionHandler(.allow)
    case .allowInitialDocumentLoad:
      allowsInitialDocumentNavigation = false
      decisionHandler(.allow)
    case .openExternal(let url):
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
    case .cancel:
      decisionHandler(.cancel)
    }
  }

  /// A page whose renderer died leaves the panel blank with no explanation, so it is
  /// re-rendered once. A document that reliably crashes WebKit will loop visibly rather
  /// than silently, which is the more debuggable failure.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ThreadingLogger.mcp.warning("Display panel web content process terminated; re-rendering")
    render()
  }
}

/// Separates WebKit's opaque action objects from the policy they carry, so every navigation shape
/// can be tested without launching an application or depending on a live web content process.
enum DisplayDocumentNavigationPolicy {
  enum Decision: Equatable {
    case allow
    case allowInitialDocumentLoad
    case openExternal(URL)
    case cancel
  }

  static func decision(
    navigationType: WKNavigationType,
    url: URL?,
    targetsMainFrame: Bool?,
    allowsInitialDocumentLoad: Bool
  ) -> Decision {
    if navigationType == .linkActivated {
      guard let url, let accepted = AgentAuthoredURLPolicy.externalWebURL(url) else {
        return .cancel
      }
      return .openExternal(accepted)
    }

    // A frame inside the document is content, not a replacement for the document. A nil target
    // is a new browsing context (for example `window.open`) and therefore does not pass here.
    if targetsMainFrame == false { return .allow }

    if navigationType == .other,
      targetsMainFrame == true,
      allowsInitialDocumentLoad
    {
      return .allowInitialDocumentLoad
    }
    return .cancel
  }
}

// MARK: - Tab Hosting

/// The display panel through the host-neutral contract, so tab commands and transfers can act
/// on it without knowing which pane they reached. The panel's own methods keep their
/// non-optional session signatures; this bridges the "current scope" spelling onto them.
extension DisplayPaneController: TabHosting {

  var hostID: TabHostID { .displayPanel }

  private func resolvedSession(_ sessionID: SessionID?) -> SessionID? {
    sessionID ?? currentSessionID
  }

  func tabs(for sessionID: SessionID?) -> [PaneTab] {
    guard !isShowingCurrentTheme else { return [] }
    return resolvedSession(sessionID).map { tabs(for: $0) } ?? []
  }

  func activeTabID(for sessionID: SessionID?) -> UUID? {
    guard !isShowingCurrentTheme else { return nil }
    return resolvedSession(sessionID).flatMap { activeTabID(for: $0) }
  }

  @discardableResult
  func activateTab(id: UUID, for sessionID: SessionID?) -> Bool {
    guard !isShowingCurrentTheme else { return false }
    guard let session = resolvedSession(sessionID) else { return false }
    return activateTab(id: id, for: session)
  }

  @discardableResult
  func closeTab(id: UUID, for sessionID: SessionID?) -> Bool {
    guard !isShowingCurrentTheme else { return false }
    guard let session = resolvedSession(sessionID) else { return false }
    return closeTab(id: id, for: session)
  }

  @discardableResult
  func moveTab(id: UUID, toIndex index: Int, for sessionID: SessionID?) -> Bool {
    guard !isShowingCurrentTheme else { return false }
    guard let session = resolvedSession(sessionID) else { return false }
    return moveTab(id: id, toIndex: index, for: session)
  }

  /// The panel shows every tab kind there is — it is where each of them was built to live.
  func canAdopt(_ tab: PaneTab) -> Bool {
    true
  }

  func detachTab(id: UUID, for sessionID: SessionID?) -> PaneTab? {
    guard let session = resolvedSession(sessionID) else { return nil }
    restoreIfNeeded(session)
    var state = TabListState(
      tabs: tabsBySession[session] ?? [],
      activeTabID: activeTabIDBySession[session]
    )
    guard let (removed, index) = state.remove(id: id) else { return nil }

    // Unparent without ending: the whole point of a detach is that the browser keeps its
    // page and the shell its process, for whichever host adopts them next.
    if let controller = removed.hostedController {
      if installedController === controller { installHosted(nil) }
      controller.view.removeFromSuperview()
      controller.removeFromParent()
    }

    tabsBySession[session] = state.tabs
    activeTabIDBySession[session] = state.activeTabID
    if activeBrowserTabIDBySession[session] == id {
      activeBrowserTabIDBySession[session] =
        state.nearest(to: index) {
          $0.browser != nil
        }?.id
    }
    persist(session)
    if session == currentSessionID { render() }
    return removed
  }

  func adopt(_ tab: PaneTab, at index: Int?, for sessionID: SessionID?) {
    guard let session = resolvedSession(sessionID) else { return }
    restoreIfNeeded(session)
    // See `DetachedBrowserHostViewController.adoptPageHook`: a browser's page hook captures the
    // host that built it, so an adopted one has to be re-pointed here or navigations are
    // reported to — and persisted by — whichever pane it came from.
    tab.browser?.onPageChange = { [weak self] in
      guard let self else { return }
      persist(session)
      if session == currentSessionID { render() }
    }
    var state = TabListState(
      tabs: tabsBySession[session] ?? [],
      activeTabID: activeTabIDBySession[session]
    )
    state.insert(tab, at: index)
    state.activate(id: tab.id)
    tabsBySession[session] = state.tabs
    activeTabIDBySession[session] = state.activeTabID
    if tab.browser != nil {
      activeBrowserTabIDBySession[session] = tab.id
    }
    persist(session)
    if session == currentSessionID { render() }
  }
}

// MARK: - Session Browser Hosting

extension DisplayPaneController: SessionBrowserHosting {

  /// Ungated by `isShowingCurrentTheme`, unlike the strip's `tabs(for:)`: the panel showing the
  /// app-theme document draws no session tabs and still holds the browser the agent is driving.
  /// Answering "none" here would have handed that browser to the next host in line.
  func browserTabs(for sessionID: SessionID) -> [PaneTab] {
    restoreIfNeeded(sessionID)
    return (tabsBySession[sessionID] ?? []).filter { $0.browser != nil }
  }

  func preferredBrowserTabID(for sessionID: SessionID) -> UUID? {
    restoreIfNeeded(sessionID)
    let tabs = tabsBySession[sessionID] ?? []

    if let activeID = activeTabIDBySession[sessionID],
      tabs.first(where: { $0.id == activeID })?.holdsAgentDrivableBrowser == true
    {
      activeBrowserTabIDBySession[sessionID] = activeID
      return activeID
    }
    if let browserID = activeBrowserTabIDBySession[sessionID],
      tabs.first(where: { $0.id == browserID })?.holdsAgentDrivableBrowser == true
    {
      return browserID
    }
    return tabs.first(where: \.holdsAgentDrivableBrowser)?.id
  }
}

// MARK: - Drop Band Hosting

extension DisplayPaneController: TabDropBandHosting {}
