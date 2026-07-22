import AppKit
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
final class DisplayTab {

    enum Body {
        case content(DisplayContent)
        case browser(BrowserViewController)
        case review(GitReviewViewController)
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

    /// The tab's view controller, when its body is a live surface rather than rendered content.
    var hostedController: NSViewController? {
        switch body {
        case .content: return nil
        case .browser(let browser): return browser
        case .review(let review): return review
        }
    }

    /// The glyph the tab strip draws — the terminal-familiar vocabulary of the surface kind.
    var symbolName: String {
        switch body {
        case .content(let content):
            if case .image = content.body { return "photo" }
            return "doc.richtext"
        case .browser:
            return "globe"
        case .review:
            return "plus.forwardslash.minus"
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
            return browser.currentURL?.host ?? "Browser"
        case .review:
            return "Review"
        }
    }
}

// MARK: - Display Pane Controller

/// The panel beside the terminal, showing content an agent asked Skalman to display.
///
/// Content is held per session rather than globally, and each session keeps a *set* of tabs that
/// coexist: every image, every document, and one live browser share the pane, switched between by
/// a strip along the top. A background session that displays something does not take over the
/// panel from the session on screen; its tabs are waiting when it is selected, as its scrollback is.
final class DisplayPaneController: NSViewController {

    // MARK: - Properties

    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var tabBar: DisplayTabBar!
    private var tabBarHeight: NSLayoutConstraint!
    private var imageView: NSImageView!
    private var webView: WKWebView!
    private var hostedView: NSView!
    private var captionLabel: NSTextField!
    private var contentMenuButton: NSButton!
    private var placeholderLabel: NSTextField!

    /// The live tab's view controller currently parented into `hostedView` — the browser or a
    /// review — so switching tabs can swap it out without rebuilding its state.
    private weak var installedController: NSViewController?

    private var tabsBySession: [SessionID: [DisplayTab]] = [:]
    private var activeTabIDBySession: [SessionID: UUID] = [:]

    /// Not private: the actions in `DisplayPaneMenu` name the session they write files for.
    private(set) var currentSessionID: SessionID?

    /// The content of the active tab, if it is an image or a document. Read by `DisplayPaneMenu`,
    /// which acts on the file behind it — a browser tab has no such file, so this is nil for it.
    var currentContent: DisplayContent? {
        activeTab(for: currentSessionID)?.content
    }

    /// Called when the user dismisses the panel, or closes its last tab.
    var onClose: (() -> Void)?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        setupTabBar()
        setupContent()
        setupConstraints()
        render()
    }

    // MARK: - Setup

    private func setupHeader() {
        headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "Display")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: DisplayPaneDefaults.titleFontSize, weight: .semibold)
        titleLabel.textColor = Design.Text.secondary
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.toolTip = "Hide panel"

        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)
        view.addSubview(headerView)
    }

    private func setupTabBar() {
        tabBar = DisplayTabBar(frame: .zero)
        tabBar.onSelect = { [weak self] id in self?.userActivatedTab(id) }
        tabBar.onClose = { [weak self] id in self?.userClosedTab(id) }
        view.addSubview(tabBar)
    }

    private func setupContent() {
        imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown

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
        captionLabel.font = .monospacedSystemFont(
            ofSize: DisplayPaneDefaults.captionFontSize,
            weight: .regular
        )
        captionLabel.textColor = Design.Text.tertiary
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.alignment = .right

        // An explicit button beside the caption rather than a click target on the text or the
        // image: nothing about a caption advertises that it is clickable, and a button is the
        // only one of the three that can be seen before it is tried.
        contentMenuButton = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Content actions")!,
            target: self,
            action: #selector(contentMenuButtonClicked)
        )
        contentMenuButton.translatesAutoresizingMaskIntoConstraints = false
        contentMenuButton.bezelStyle = .accessoryBarAction
        contentMenuButton.isBordered = false
        contentMenuButton.toolTip = "Actions"

        placeholderLabel = NSTextField(labelWithString: "Nothing to show yet.")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .systemFont(ofSize: DisplayPaneDefaults.titleFontSize)
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
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Pinned to the safe area, which the toolbar insets. Pinning to the view's own top
            // would slide the header under the toolbar.
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.headerHeight),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: padding),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -padding
            ),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -padding),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),
            closeButton.heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize),

            // The strip sits between the header and the content; its height collapses to zero
            // when there are too few tabs to be worth a row (see `render`).
            tabBar.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarHeight,

            // Content anchors to the strip's bottom, so a hidden strip (height 0) leaves it
            // directly under the header, and a shown one pushes it down without swapping anchors.
            imageView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: padding),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            imageView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -padding),

            // The web view occupies the same region, minus the padding: an HTML document
            // brings its own margins and inset it twice looks like a mistake.
            webView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: captionLabel.topAnchor, constant: -padding),

            // A live surface fills the whole content region, over the caption footer, since it
            // carries its own chrome and needs no caption beneath it.
            hostedView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
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

        // Cap the content tabs, never the browser: a session that keeps drawing charts should
        // not grow an unbounded strip, but its one browser is a working surface, not clutter.
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

    // MARK: - Public — Browser Tab

    /// Returns the session's browser tab, creating and activating one if it has none. The agent's
    /// navigate tool calls this so a page always has a tab to land in.
    @discardableResult
    func activateBrowser(for sessionID: SessionID) -> BrowserViewController {
        restoreIfNeeded(sessionID)
        var tabs = tabsBySession[sessionID] ?? []

        if let existing = tabs.first(where: { $0.browser != nil }) {
            activeTabIDBySession[sessionID] = existing.id
            persist(sessionID)
            if sessionID == currentSessionID { render() }
            return existing.browser!
        }

        let controller = makeBrowser(for: sessionID)
        let tab = DisplayTab(body: .browser(controller))
        tabs.append(tab)
        tabsBySession[sessionID] = tabs
        activeTabIDBySession[sessionID] = tab.id
        persist(sessionID)

        if sessionID == currentSessionID { render() }
        return controller
    }

    /// Builds a browser view controller wired to persist and re-render when its page changes, so a
    /// navigation — the agent's or the user's — is saved and reflected in the tab strip.
    private func makeBrowser(for sessionID: SessionID) -> BrowserViewController {
        let controller = BrowserViewController()
        addChild(controller)
        controller.onPageChange = { [weak self] in
            guard let self else { return }
            self.persist(sessionID)
            if sessionID == self.currentSessionID { self.render() }
        }
        return controller
    }

    /// The session's browser tab if it has one, without creating it — for tools that should fail
    /// rather than silently open a blank page.
    func browser(for sessionID: SessionID) -> BrowserViewController? {
        restoreIfNeeded(sessionID)
        return tabsBySession[sessionID]?.first(where: { $0.browser != nil })?.browser
    }

    // MARK: - Public — Review Tab

    /// Returns the session's git review tab, creating and activating one if it has none — the
    /// same one-per-session shape as the browser.
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
    /// screen, should say so without being asked.
    func noteSessionStoppedWorking(_ sessionID: SessionID) {
        guard sessionID == currentSessionID,
              let review = activeTab(for: sessionID)?.review else { return }
        review.refresh(force: false)
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
        guard let sessionID = currentSessionID,
              var tabs = tabsBySession[sessionID],
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }

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
        persist(sessionID)

        render()

        // Closing the final tab collapses the pane, the same as the header's close button.
        if tabs.isEmpty { onClose?() }
    }

    /// Detaches a live tab's view controller. Content tabs need nothing.
    private func teardownHosted(_ tab: DisplayTab) {
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

        renderTabBar(tabs: tabs, active: active)
        renderContent(active: active)

        titleLabel.stringValue = active?.title ?? "Display"
        placeholderLabel.isHidden = active != nil
    }

    private func renderTabBar(tabs: [DisplayTab], active: DisplayTab?) {
        let show = tabs.count >= DisplayPaneDefaults.tabBarMinimumTabs
        tabBar.isHidden = !show
        tabBarHeight.constant = show ? DisplayPaneDefaults.tabBarHeight : 0

        guard show else { return }
        tabBar.update(items: tabs.map {
            DisplayTabBarItem(id: $0.id, title: $0.title, symbolName: $0.symbolName, isActive: $0.id == active?.id)
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
    }

    /// Writes the session's current tabs and selection to disk.
    private func persist(_ sessionID: SessionID) {
        let tabs = tabsBySession[sessionID] ?? []
        let persistedTabs = tabs.compactMap(persisted)
        let active = activeTabIDBySession[sessionID]?.uuidString
        DisplayPaneStore.shared.saveLayout(tabs: persistedTabs, activeID: active, for: sessionID)
    }

    private func persisted(_ tab: DisplayTab) -> PersistedTab? {
        if let browser = tab.browser {
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

    @objc private func closeTapped() {
        onClose?()
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
