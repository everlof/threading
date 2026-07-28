import AppKit
import SkalmanExtensionKit
import WebKit

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
    }

    let body: Body

    /// The agent's own caption, when it supplied one.
    let title: String?

    /// What was shown, in the app's words rather than the agent's.
    let subtitle: String
}

// MARK: - Display Tab

/// One tab in the display pane. A tab is either a piece of rendered content — an image or an HTML
/// document — or a live surface (the browser, the git review), which is a whole view controller
/// rather than a value.
///
/// A reference type, because a live tab owns a view controller whose state — a browser's page
/// and history, a review's mode and scroll position — must survive the tab being switched off
/// screen and back.
@MainActor
final class DisplayTab {

    enum Body {
        case content(DisplayContent)
        case browser(BrowserViewController)
        case review(GitReviewViewController)
        case info(SessionInfoViewController)
        case terminal(ShellDrawerViewController)
        case files(FileTreeViewController)
        case attachments(SessionAttachmentsViewController)
        case extensionPanel(ExtensionPanelViewController)
        case compare(CompareViewController)
    }

    let id: UUID
    var body: Body

    /// For an image tab: the PNG filename cached on disk, kept so it can be removed when the tab
    /// closes and re-loaded when the session is restored.
    var cacheFile: String?

    init(id: UUID = UUID(), body: Body) {
        self.id = id
        self.body = body
    }

    var content: DisplayContent? {
        if case .content(let content) = body { return content }
        return nil
    }

    var browser: BrowserViewController? {
        if case .browser(let browser) = body { return browser }
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
        case .review(let review): return review
        case .info(let info): return info
        case .terminal(let terminal): return terminal
        case .files(let files): return files
        case .attachments(let attachments): return attachments
        case .extensionPanel(let panel): return panel
        case .compare(let compare): return compare
        }
    }

    /// The glyph the tab strip draws — the terminal-familiar vocabulary of the surface kind.
    var symbolName: String {
        switch body {
        case .content(let content):
            if case .image = content.body { return "photo" }
            return "doc.richtext"
        case .browser(let browser):
            return browser.contextKind == .private ? "hand.raised.fill" : "globe"
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
            return "Document"
        case .browser(let browser):
            if let title = browser.currentTitle, !title.isEmpty { return title }
            return browser.currentURL?.host
                ?? (browser.contextKind == .private ? "Private Browser" : "Browser")
        case .review:
            return "Review"
        case .info:
            return "Info"
        case .terminal:
            return "Terminal"
        case .files:
            return "Files"
        case .attachments:
            return "Attachments"
        case .extensionPanel(let panel):
            return panel.panelTitle
        case .compare:
            return "Compare"
        }
    }
}

// MARK: - Display Pane Controller

/// The panel beside the terminal, showing content an agent asked Skalman to display.
///
/// Content is held per session rather than globally, and each session keeps a *set* of tabs that
/// coexist: images, documents, and live browsers share the pane, switched between by
/// a strip along the top. A background session that displays something does not take over the
/// panel from the session on screen; its tabs are waiting when it is selected, as its scrollback is.
@MainActor
final class DisplayPaneController: NSViewController {

    // MARK: - Properties

    private var headerView: NSView!

    /// Opens a new tab. It sits at the trailing edge of the tab row rather than inside the
    /// scrolling strip, so a pane full of tabs scrolls sideways *under* it instead of carrying
    /// the one control that adds another off the edge with them.
    private var newTabButton: ThemedButton!
    private var headerCustomizationView: DisplayPaneHeaderCustomizationView!
    private var newTabMenuSession: AnyObject?
    private var tabBar: DisplayTabBar!
    private var imageView: NSImageView!
    private var webView: WKWebView!
    private var hostedView: NSView!
    private var captionLabel: NSTextField!
    private var contentMenuButton: ThemedButton!
    private var placeholderLabel: NSTextField!
    private let appEvents = AppEventObservations()

    /// The live tab's view controller currently parented into `hostedView` — the browser or a
    /// review — so switching tabs can swap it out without rebuilding its state.
    private weak var installedController: NSViewController?

    private var tabsBySession: [SessionID: [DisplayTab]] = [:]
    private var activeTabIDBySession: [SessionID: UUID] = [:]
    /// The browser the agent and user most recently selected. Kept separately from the visible
    /// panel tab because displaying a screenshot or document must not silently retarget the next
    /// browser action to the first browser in the strip.
    private var activeBrowserTabIDBySession: [SessionID: UUID] = [:]
    private let extensionPanels: ExtensionPanelRouting
    private let customizationLookup: ComponentCustomizationHost.Lookup
    private let browserFactory: @MainActor (BrowserContextKind) -> BrowserViewController

    /// Test and embedding seam for extension actions. Production routes through the shared
    /// provider slot when no explicit receiver is installed.
    var onCustomizationAction: ((ComponentCustomizationAction) -> Void)?

    /// Not private: the actions in `DisplayPaneMenu` name the session they write files for.
    private(set) var currentSessionID: SessionID?

    /// The content of the active tab, if it is an image or a document. Read by `DisplayPaneMenu`,
    /// which acts on the file behind it — a browser tab has no such file, so this is nil for it.
    var currentContent: DisplayContent? {
        activeTab(for: currentSessionID)?.content
    }

    /// Called when the user closes the pane's last content tab.
    var onClose: (() -> Void)?

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
        }
    ) {
        self.extensionPanels = extensionPanels ?? ExtensionManager.shared
        self.customizationLookup = customizationLookup
        self.browserFactory = browserFactory
        super.init(nibName: nil, bundle: nil)

        appEvents.observe(SessionAttachmentsDidChange.self) { [weak self] event in
            self?.ensureAttachmentsTab(for: event.sessionID)
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
        backdrop.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        view.addSubview(backdrop)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Setup

    /// The pane's one top row: its tabs, and the control that adds another.
    ///
    /// There was a titled header above the strip, which spent a row of a narrow pane restating
    /// the name of the tab directly beneath it — and the toolbar already names the page. The
    /// tabs *are* the header now, with `+` at the trailing edge where a browser puts it, which
    /// is also what closes the gap between this pane and the rest of the window's chrome.
    private func setupHeader() {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        newTabButton = ThemedButton(
            symbol: "plus",
            accessibility: "New tab",
            target: self,
            action: #selector(newTabButtonClicked(_:))
        )
        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.isBordered = false
        newTabButton.toolTip = "New tab"

        headerCustomizationView = DisplayPaneHeaderCustomizationView(
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

        headerView.addSubview(headerCustomizationView)
        headerView.addSubview(newTabButton)

        // The rule under the header belongs to the header, not to the tab strip inside it: the
        // strip ends where the customization slot and `+` begin, and a rule pinned there
        // stopped short of the pane's edge.
        let separator = SeparatorView()
        headerView.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor)
        ])

        view.addSubview(headerView)
    }

    @objc private func newTabButtonClicked(_ sender: NSView) {
        guard let sessionID = currentSessionID else { return }
        let canAddBrowser = tabs(for: sessionID).lazy.filter { $0.browser != nil }.count
            < DisplayPaneDefaults.maximumBrowserTabs

        let choices: [(String, String, Bool, () -> Void)] = [
            ("Terminal", "terminal", true, {
                [weak self] in _ = self?.addTerminalTab(for: sessionID)
            }),
            ("Browser", "globe", canAddBrowser, {
                [weak self] in _ = self?.addBrowserTab(for: sessionID)
            }),
            ("Private Browser", "hand.raised.fill", canAddBrowser, {
                [weak self] in
                _ = self?.addBrowserTab(for: sessionID, contextKind: .private)
            }),
            ("Files", "folder", true, {
                [weak self] in _ = self?.activateFiles(for: sessionID)
            }),
            ("Review", "plus.forwardslash.minus", true, {
                [weak self] in _ = self?.activateReview(for: sessionID)
            }),
            ("Compare Files…", "rectangle.on.rectangle", true, {
                [weak self] in self?.chooseFilesToCompare(for: sessionID)
            }),
            ("Info", "info.circle", true, {
                [weak self] in _ = self?.activateInfo(for: sessionID)
            }),
            ("Attachments", "paperclip", true, {
                [weak self] in _ = self?.activateAttachments(for: sessionID)
            })
        ]
        var entries = choices.map { title, symbol, isEnabled, action in
            ThemedMenuEntry.item(ThemedMenuItem(
                title: title,
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: title),
                isEnabled: isEnabled,
                onChoose: action
            ))
        }
        let contributedPanels = extensionPanels.extensionPanelInventory
        if !contributedPanels.isEmpty {
            entries.append(.separator)
            entries.append(contentsOf: contributedPanels.map { item in
                ThemedMenuEntry.item(ThemedMenuItem(
                    title: item.panel.title,
                    subtitle: item.extensionName,
                    image: NSImage(
                        systemSymbolName: "puzzlepiece.extension",
                        accessibilityDescription: "Extension panel"
                    ),
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

        newTabMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 160),
            from: sender,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.newTabMenuSession = nil }
        )
    }

    private func setupTabBar() {
        tabBar = DisplayTabBar(
            frame: .zero,
            customizationLookup: customizationLookup
        )
        tabBar.onSelect = { [weak self] id in self?.userActivatedTab(id) }
        tabBar.onClose = { [weak self] id in self?.userClosedTab(id) }
        headerView.addSubview(tabBar)
    }

    private func setupContent() {
        imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // Top-aligned, not centred. The view fills the pane's height, so a wide image centred
        // in it floats in the middle with dead space above; anchored to the top it sits under
        // the header where the eye already is.
        imageView.imageAlignment = .alignTop

        // An NSImageView reports the image's own dimensions as its intrinsic content size, so
        // left alone it drives the layout: the split view sizes the pane to fit the picture,
        // and a 900px image opens a 900pt panel. Dropping both priorities to the floor means
        // the pane decides its width and the image scales into whatever it is given.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentHuggingPriority(.init(1), for: axis)
            imageView.setContentCompressionResistancePriority(.init(1), for: axis)
        }

        webView = WKWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self

        // Overscroll and the gap before the page paints match the panel rather than flashing
        // white, which is jarring against a dark terminal.
        webView.underPageBackgroundColor = Design.Surface.ground

        // A live tab's full view controller — browser or review — is parented into this on
        // activation; empty and hidden otherwise.
        hostedView = NSView()
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.wantsLayer = true
        hostedView.isHidden = true

        captionLabel = NSTextField(labelWithString: "")
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.applyFont(.compactCode)
        captionLabel.textColor = Design.Text.tertiary
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.alignment = .right

        // An explicit button beside the caption rather than a click target on the text or the
        // image: nothing about a caption advertises that it is clickable, and a button is the
        // only one of the three that can be seen before it is tried.
        contentMenuButton = ThemedButton(symbol: "ellipsis.circle", accessibility: "Content actions", target: self, action: #selector(contentMenuButtonClicked)
        )
        contentMenuButton.translatesAutoresizingMaskIntoConstraints = false
        contentMenuButton.isBordered = false
        contentMenuButton.toolTip = "Actions"

        placeholderLabel = NSTextField(labelWithString: "Nothing to show yet.")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.applyFont(.detail())
        placeholderLabel.textColor = Design.Text.tertiary
        placeholderLabel.alignment = .center

        view.addSubview(imageView)
        view.addSubview(webView)
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

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerBottom,
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: DisplayPaneDefaults.tabBarHeight
            ),

            // The strip takes the row and gives up only what `+` needs, so a pane full of tabs
            // scrolls sideways rather than pushing the control that adds one off the edge.
            tabBar.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            tabBar.topAnchor.constraint(equalTo: headerView.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            tabBar.trailingAnchor.constraint(
                equalTo: headerCustomizationView.leadingAnchor,
                constant: -4
            ),

            headerCustomizationView.trailingAnchor.constraint(
                equalTo: newTabButton.leadingAnchor,
                constant: -4
            ),
            headerCustomizationView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerCustomizationView.heightAnchor.constraint(
                lessThanOrEqualTo: headerView.heightAnchor
            ),
            newTabButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -padding),
            newTabButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),
            newTabButton.heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),

            // Content anchors under the one header row.
            imageView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: padding),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            imageView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -padding),

            // The web view occupies the same region, minus the padding: an HTML document
            // brings its own margins and inset it twice looks like a mistake.
            webView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -padding),

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
            )
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
           let oldest = tabs.first(where: { $0.content != nil }) {
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
           let active = tabs.first(where: { $0.id == activeID })?.browser {
            activeBrowserTabIDBySession[sessionID] = activeID
            return active
        }
        if let existing = tabs.first(where: { $0.browser != nil }) {
            activeTabIDBySession[sessionID] = existing.id
            activeBrowserTabIDBySession[sessionID] = existing.id
            persist(sessionID)
            if sessionID == currentSessionID { render() }
            return existing.browser!
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
        guard tabs.lazy.filter({ $0.browser != nil }).count
                < DisplayPaneDefaults.maximumBrowserTabs else {
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

    /// Builds a browser view controller wired to persist and re-render when its page changes, so a
    /// navigation — the agent's or the user's — is saved and reflected in the tab strip.
    private func makeBrowser(
        for sessionID: SessionID,
        contextKind: BrowserContextKind = .shared
    ) -> BrowserViewController {
        let controller = browserFactory(contextKind)
        addChild(controller)
        controller.onPageChange = { [weak self] in
            guard let self else { return }
            self.persist(sessionID)
            if sessionID == self.currentSessionID { self.render() }
        }
        return controller
    }

    /// The most recently selected browser. A content tool may put a screenshot or document in
    /// front of it, but that output must not change which independent browser receives the next
    /// browser action.
    func browser(for sessionID: SessionID) -> BrowserViewController? {
        restoreIfNeeded(sessionID)
        let tabs = tabsBySession[sessionID] ?? []
        if let activeID = activeTabIDBySession[sessionID],
           let active = tabs.first(where: { $0.id == activeID })?.browser {
            activeBrowserTabIDBySession[sessionID] = activeID
            return active
        }
        if let browserID = activeBrowserTabIDBySession[sessionID],
           let recent = tabs.first(where: { $0.id == browserID })?.browser {
            return recent
        }
        return tabs.first(where: { $0.browser != nil })?.browser
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
    /// screen, should say so without being asked. The info panel gets the same treatment for the
    /// same reason: a turn that ends is a turn that may have just started or killed a server.
    func noteSessionStoppedWorking(_ sessionID: SessionID) {
        guard sessionID == currentSessionID else { return }

        activeTab(for: sessionID)?.review?.refresh(force: false)
        activeTab(for: sessionID)?.info?.refresh()
        // A comparison on screen through a turn is probably of files the turn was rewriting.
        activeTab(for: sessionID)?.compare?.refresh(force: true)
    }

    // MARK: - Public — Info Tab

    /// Returns the session's info tab, creating and activating one if it has none. Info remains a
    /// singleton because it describes the session rather than a navigable resource.
    @discardableResult
    func activateInfo(for sessionID: SessionID) -> SessionInfoViewController? {
        restoreIfNeeded(sessionID)
        var tabs = tabsBySession[sessionID] ?? []

        if let existing = tabs.first(where: { $0.info != nil }) {
            activeTabIDBySession[sessionID] = existing.id
            persist(sessionID)
            if sessionID == currentSessionID { render() }
            return existing.info
        }

        guard let controller = makeInfo(for: sessionID) else { return nil }
        let tab = DisplayTab(body: .info(controller))
        tabs.append(tab)
        tabsBySession[sessionID] = tabs
        activeTabIDBySession[sessionID] = tab.id
        persist(sessionID)

        if sessionID == currentSessionID { render() }
        return controller
    }

    /// Builds an info view controller for the session's project folder. Returns nil for a session
    /// with no project — there is no directory to describe.
    private func makeInfo(for sessionID: SessionID) -> SessionInfoViewController? {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return nil }

        let controller = SessionInfoViewController(sessionID: sessionID, folderPath: project.folderPath)
        addChild(controller)

        // The shell drawer lives on the terminal container, which the window owns and this pane
        // does not see; the resolver is wired in from there.
        controller.shellRootProvider = { [weak self] in self?.shellRootResolver?(sessionID) }

        // A port the user clicks lands in this session's browser tab, which is the surface that
        // already exists for showing a page.
        controller.onOpenURL = { [weak self] url in
            self?.activateBrowser(for: sessionID).navigate(to: url.absoluteString)
        }

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

    /// The `+` menu's route in: the system open panel, two files. The first chosen is the old
    /// side — the panel cannot say which is which, and the compare surface's tags make any
    /// mistake visible immediately.
    private func chooseFilesToCompare(for sessionID: SessionID) {
        let panel = NSOpenPanel()
        panel.message = "Choose two files to compare"
        panel.prompt = "Compare"
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
    private func makeReview(for sessionID: SessionID, mode: GitReviewMode) -> GitReviewViewController? {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return nil }

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
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return nil }

        let folder = project.folderPath
        let controller = ShellDrawerViewController(
            sessionID: sessionID,
            directory: { URL(fileURLWithPath: folder) }
        )
        addChild(controller)
        return controller
    }

    // MARK: - Public — Files Tab

    /// Returns the session's file tree, creating and activating one if it has none. One project
    /// has one tree; a second would show the same directory twice.
    @discardableResult
    func activateFiles(for sessionID: SessionID) -> FileTreeViewController? {
        restoreIfNeeded(sessionID)
        var tabs = tabsBySession[sessionID] ?? []

        if let existing = tabs.first(where: { $0.files != nil }) {
            activeTabIDBySession[sessionID] = existing.id
            persist(sessionID)
            if sessionID == currentSessionID { render() }
            return existing.files
        }

        guard let controller = makeFiles(for: sessionID) else { return nil }
        let tab = DisplayTab(id: UUID(), body: .files(controller))
        tabs.append(tab)
        tabsBySession[sessionID] = tabs
        activeTabIDBySession[sessionID] = tab.id
        persist(sessionID)

        if sessionID == currentSessionID { render() }
        return controller
    }

    /// Builds a file tree rooted at the session's project folder. Nil for a session with no
    /// project — there is no directory to show.
    private func makeFiles(for sessionID: SessionID) -> FileTreeViewController? {
        guard let project = ProjectStore.shared.project(forSessionID: sessionID) else { return nil }

        let controller = FileTreeViewController(folderPath: project.folderPath)
        addChild(controller)
        return controller
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
        return controller
    }

    // MARK: - Public — Tab List (for the agent)

    /// The session's tabs in strip order, so the agent can list them and pick one.
    func tabs(for sessionID: SessionID) -> [DisplayTab] {
        restoreIfNeeded(sessionID)
        return tabsBySession[sessionID] ?? []
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
    @discardableResult
    func closeTab(id: UUID, for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        guard var tabs = tabsBySession[sessionID],
              let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

        let removed = tabs.remove(at: index)
        teardownHosted(removed)
        if let cacheFile = removed.cacheFile {
            DisplayPaneStore.shared.removeCachedImage(cacheFile, for: sessionID)
        }
        tabsBySession[sessionID] = tabs

        // Move selection to the neighbour that slid into this slot, else the new last tab.
        if activeTabIDBySession[sessionID] == id {
            let neighbour = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabIDBySession[sessionID] = neighbour?.id
        }
        if activeBrowserTabIDBySession[sessionID] == id {
            let nextBrowser = tabs.enumerated()
                .filter { $0.element.browser != nil }
                .min { abs($0.offset - index) < abs($1.offset - index) }?
                .element
            activeBrowserTabIDBySession[sessionID] = nextBrowser?.id
        }
        persist(sessionID)

        if sessionID == currentSessionID { render() }
        if tabs.isEmpty { onClose?() }
        return true
    }

    // MARK: - Public — Session Lifecycle

    /// Switches the panel to a session's tabs. Passing nil empties it.
    func showSession(_ sessionID: SessionID?) {
        currentSessionID = sessionID
        if let sessionID { restoreIfNeeded(sessionID) }
        render()
    }

    /// Whether a session has any tab, which is what decides if the panel opens.
    func hasContent(for sessionID: SessionID) -> Bool {
        restoreIfNeeded(sessionID)
        return !(tabsBySession[sessionID]?.isEmpty ?? true)
    }

    /// Drops every session not in the given set, tearing down any live surface it held, so
    /// deleted sessions do not keep their tabs — and their web content processes — alive forever.
    func retainOnly(sessionIDs: Set<SessionID>) {
        for (sessionID, tabs) in tabsBySession where !sessionIDs.contains(sessionID) {
            tabs.forEach { teardownHosted($0) }
        }

        tabsBySession = tabsBySession.filter { sessionIDs.contains($0.key) }
        activeTabIDBySession = activeTabIDBySession.filter { sessionIDs.contains($0.key) }
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

    // MARK: - Tab Interaction

    private func userActivatedTab(_ id: UUID) {
        guard let currentSessionID else { return }
        activateTab(id: id, for: currentSessionID)
    }

    private func userClosedTab(_ id: UUID) {
        guard let sessionID = currentSessionID else { return }
        closeTab(id: id, for: sessionID)
    }

    /// Detaches a live tab's view controller. Content tabs need nothing.
    ///
    /// A terminal is the one kind holding something a detach does not release: closing its tab
    /// has to kill the shell, or the process outlives every view that could reach it.
    private func teardownHosted(_ tab: DisplayTab) {
        tab.terminal?.terminate()

        guard let controller = tab.hostedController else { return }
        if installedController === controller { installHosted(nil) }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
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

        let tabs = currentSessionID.flatMap { tabsBySession[$0] } ?? []
        let active = activeTab(for: currentSessionID)

        headerCustomizationView.showSession(
            currentSessionID?.uuidString.lowercased()
        )
        renderTabBar(tabs: tabs, active: active)
        renderContent(active: active)

        placeholderLabel.isHidden = active != nil
    }

    /// The strip is the pane's header, so it is always drawn — a lone tab names the pane, which
    /// is the job the title label above it used to do twice.
    private func renderTabBar(tabs: [DisplayTab], active: DisplayTab?) {
        let target = ExtensionComponentTarget.displayTabHeader(
            sessionID: currentSessionID?.uuidString.lowercased()
        )
        tabBar.update(items: tabs.map {
            DisplayTabBarItem(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isActive: $0.id == active?.id,
                customizationTarget: target
            )
        })
    }

    private func renderContent(active: DisplayTab?) {
        switch active?.body {
        case .content(let content):
            installHosted(nil)
            switch content.body {
            case .image(let image, _):
                imageView.image = image
                imageView.isHidden = false
                webView.isHidden = true
            case .html(let html):
                imageView.image = nil
                imageView.isHidden = true
                webView.isHidden = false
                webView.loadHTMLString(Self.themed(html), baseURL: nil)
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

        case .review(let review):
            imageView.image = nil
            imageView.isHidden = true
            hideHTML()
            captionLabel.isHidden = true
            contentMenuButton.isHidden = true
            installHosted(review)
            // Loads only when actually shown, the same deferred rule as the browser's page.
            review.refresh(force: false)

        case .compare(let compare):
            imageView.image = nil
            imageView.isHidden = true
            hideHTML()
            captionLabel.isHidden = true
            contentMenuButton.isHidden = true
            installHosted(compare)
            // The same deferred rule: a restored comparison reads its two files when looked at.
            compare.refresh(force: false)

        case .info(let info):
            imageView.image = nil
            imageView.isHidden = true
            hideHTML()
            captionLabel.isHidden = true
            contentMenuButton.isHidden = true
            installHosted(info)
            // The panel's own on-screen gate starts its polling; this is the immediate first
            // reading, so switching to the tab does not show a two-second-stale one.
            info.refresh()

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

        case .files(let files):
            imageView.image = nil
            imageView.isHidden = true
            hideHTML()
            captionLabel.isHidden = true
            contentMenuButton.isHidden = true
            installHosted(files)
            // Reads the root on first show and re-reads what is open on later ones, so a file an
            // agent just wrote is there without the folder being collapsed and reopened.
            files.refresh()

        case .attachments(let attachments):
            imageView.image = nil
            imageView.isHidden = true
            hideHTML()
            captionLabel.isHidden = true
            contentMenuButton.isHidden = true
            installHosted(attachments)
            attachments.refresh()

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

    /// Hides the shared web view and drops its page, so a switched-away document is not still
    /// running its timers and animations behind the tab now on screen.
    private func hideHTML() {
        webView.isHidden = true
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Parents (or clears) a live tab's view controller into the host, reusing the installed one
    /// so switching tabs never rebuilds its state.
    private func installHosted(_ controller: NSViewController?) {
        guard installedController !== controller else {
            hostedView.isHidden = controller == nil
            return
        }

        installedController?.view.removeFromSuperview()
        installedController = controller

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
            controller.view.trailingAnchor.constraint(equalTo: hostedView.trailingAnchor)
        ])
        hostedView.isHidden = false

        // A restored browser carries its page URL but has not loaded it — the load is deferred to
        // the moment it is actually shown, so a background session's browser costs nothing until
        // selected.
        if let browser = controller as? BrowserViewController,
           browser.currentURL == nil, let url = browser.restoredURL {
            browser.restoredURL = nil
            browser.navigate(to: url)
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
        for persisted in panel.tabs {
            let id = UUID(uuidString: persisted.id) ?? UUID()
            switch persisted.kind {
            case .browser:
                let controller = makeBrowser(for: sessionID)
                controller.restoredURL = persisted.url
                tabs.append(DisplayTab(id: id, body: .browser(controller)))

            case .html:
                guard let html = persisted.html else { continue }
                let content = DisplayContent(body: .html(html), title: persisted.title, subtitle: persisted.subtitle)
                tabs.append(DisplayTab(id: id, body: .content(content)))

            case .image:
                guard let cacheFile = persisted.cacheFile,
                      let image = DisplayPaneStore.shared.loadImage(cacheFile, for: sessionID) else { continue }
                let url = persisted.url.flatMap(URL.init(string:)) ?? URL(fileURLWithPath: "/")
                let content = DisplayContent(body: .image(image, url: url), title: persisted.title, subtitle: persisted.subtitle)
                let tab = DisplayTab(id: id, body: .content(content))
                tab.cacheFile = cacheFile
                tabs.append(tab)

            case .review:
                // Restored in its saved mode; no git runs until the tab is actually shown.
                let mode = persisted.mode.flatMap(GitReviewMode.init(rawValue:)) ?? .uncommitted
                guard let controller = makeReview(for: sessionID, mode: mode) else { continue }
                tabs.append(DisplayTab(id: id, body: .review(controller)))

            case .info:
                // Nothing is read until the tab is shown: the panel polls off its own visibility.
                guard let controller = makeInfo(for: sessionID) else { continue }
                tabs.append(DisplayTab(id: id, body: .info(controller)))

            case .terminal:
                // The tab comes back, the process does not — a shell's state was never on disk.
                // No child is spawned until the tab is shown (`startIfNeeded`).
                guard let controller = makeTerminal(for: sessionID) else { continue }
                tabs.append(DisplayTab(id: id, body: .terminal(controller)))

            case .files:
                // No directory is read until the tab is shown, so a background session's tree
                // costs nothing but the controller.
                guard let controller = makeFiles(for: sessionID) else { continue }
                tabs.append(DisplayTab(id: id, body: .files(controller)))

            case .attachments:
                guard let controller = makeAttachments(for: sessionID) else { continue }
                tabs.append(DisplayTab(id: id, body: .attachments(controller)))

            case .extensionPanel:
                guard let extensionIdentifier = persisted.extensionIdentifier,
                      let panelID = persisted.extensionPanelID else { continue }
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
                      let newPath = persisted.compareNewPath else { continue }
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

        tabsBySession[sessionID] = tabs

        if let activeString = panel.activeTabID,
           let activeID = UUID(uuidString: activeString),
           tabs.contains(where: { $0.id == activeID }) {
            activeTabIDBySession[sessionID] = activeID
        } else {
            activeTabIDBySession[sessionID] = tabs.last?.id
        }
        let activeID = activeTabIDBySession[sessionID]
        activeBrowserTabIDBySession[sessionID] = tabs.first {
            $0.id == activeID && $0.browser != nil
        }?.id ?? tabs.first(where: { $0.browser != nil })?.id
    }

    /// Writes the session's current tabs and selection to disk.
    private func persist(_ sessionID: SessionID) {
        let tabs = tabsBySession[sessionID] ?? []
        let persistedTabs = tabs.compactMap(persisted)
        let active = activeTabIDBySession[sessionID]
            .flatMap { activeID in
                persistedTabs.contains { $0.id == activeID.uuidString }
                    ? activeID.uuidString
                    : nil
            }
            ?? persistedTabs.first?.id
        DisplayPaneStore.shared.saveLayout(tabs: persistedTabs, activeID: active, for: sessionID)
    }

    private func persisted(_ tab: DisplayTab) -> PersistedTab? {
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

        if tab.info != nil {
            return PersistedTab(
                id: tab.id.uuidString, kind: .info, title: tab.title,
                subtitle: "", url: nil, html: nil, cacheFile: nil
            )
        }

        if tab.terminal != nil {
            return PersistedTab(
                id: tab.id.uuidString, kind: .terminal, title: tab.title,
                subtitle: "", url: nil, html: nil, cacheFile: nil
            )
        }

        if tab.files != nil {
            return PersistedTab(
                id: tab.id.uuidString, kind: .files, title: tab.title,
                subtitle: "", url: nil, html: nil, cacheFile: nil
            )
        }

        if tab.attachments != nil {
            return PersistedTab(
                id: tab.id.uuidString, kind: .attachments, title: tab.title,
                subtitle: "", url: nil, html: nil, cacheFile: nil
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
    /// and no way home — so links are handed to the real browser instead, which has all three.
    /// (An agent who wants a navigable page uses the browser tab, not a document.) Subresources
    /// do not come through here, so scripts, styles and images still load.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    /// A page whose renderer died leaves the panel blank with no explanation, so it is
    /// re-rendered once. A document that reliably crashes WebKit will loop visibly rather
    /// than silently, which is the more debuggable failure.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SkalmanLogger.mcp.error("Display panel web content process terminated; re-rendering")
        render()
    }
}
