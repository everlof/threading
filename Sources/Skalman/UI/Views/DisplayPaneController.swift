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

// MARK: - Display Pane Controller

/// The panel beside the terminal, showing content an agent asked Skalman to display.
///
/// Content is held per session rather than globally. A background session that displays an
/// image does not take over the panel from the session on screen; its image is waiting when
/// that session is selected, exactly as its scrollback is.
final class DisplayPaneController: NSViewController {

    // MARK: - Properties

    private var headerView: NSView!
    private var titleLabel: NSTextField!
    private var closeButton: NSButton!
    private var imageView: NSImageView!
    private var webView: WKWebView!
    private var captionLabel: NSTextField!
    private var contentMenuButton: NSButton!
    private var placeholderLabel: NSTextField!

    private var contentBySession: [UUID: DisplayContent] = [:]

    /// Not private: the actions in `DisplayPaneMenu` name the session they write files for.
    private(set) var currentSessionID: UUID?

    /// What the panel is showing, if anything. Read by the actions in `DisplayPaneMenu`,
    /// which is why the backing store stays private but this does not.
    var currentContent: DisplayContent? {
        currentSessionID.flatMap { contentBySession[$0] }
    }

    /// Called when the user dismisses the panel.
    var onClose: (() -> Void)?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
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
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false

        headerView.addSubview(titleLabel)
        headerView.addSubview(closeButton)
        view.addSubview(headerView)
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
        webView.underPageBackgroundColor = .windowBackgroundColor

        captionLabel = NSTextField(labelWithString: "")
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .monospacedSystemFont(
            ofSize: DisplayPaneDefaults.captionFontSize,
            weight: .regular
        )
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingMiddle
        captionLabel.alignment = .right

        // An explicit button beside the caption rather than a click target on the text or the
        // image: nothing about a caption advertises that it is clickable, and a button is the
        // only one of the three that can be seen before it is tried.
        contentMenuButton = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Image actions")!,
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
        placeholderLabel.textColor = .tertiaryLabelColor
        placeholderLabel.alignment = .center

        view.addSubview(imageView)
        view.addSubview(webView)
        view.addSubview(captionLabel)
        view.addSubview(contentMenuButton)
        view.addSubview(placeholderLabel)
    }

    private func setupConstraints() {
        let padding = DisplayPaneDefaults.padding

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

    // MARK: - Public Methods

    /// Stores content for a session, replacing whatever it was showing before.
    func setContent(_ content: DisplayContent, for sessionID: UUID) {
        contentBySession[sessionID] = content

        if sessionID == currentSessionID {
            render()
        }
    }

    /// Switches the panel to a session's content. Passing nil empties it.
    func showSession(_ sessionID: UUID?) {
        currentSessionID = sessionID
        render()
    }

    /// Whether a session has anything to show, which is what decides if the panel opens.
    func hasContent(for sessionID: UUID) -> Bool {
        contentBySession[sessionID] != nil
    }

    /// Drops content for every session not in the given set, so deleted sessions do not hold
    /// their images forever.
    func retainOnly(sessionIDs: Set<UUID>) {
        contentBySession = contentBySession.filter { sessionIDs.contains($0.key) }

        if let currentSessionID, !sessionIDs.contains(currentSessionID) {
            self.currentSessionID = nil
        }

        render()
    }

    // MARK: - Private Methods

    /// Not private: the Reload action in `DisplayPaneMenu` re-runs it.
    func render() {
        // The panel starts collapsed, so its views may not exist yet when content arrives.
        // Nothing is lost by skipping: `viewDidLoad` renders once they do.
        guard isViewLoaded else { return }

        let content = currentSessionID.flatMap { contentBySession[$0] }

        switch content?.body {
        case .image(let image, _):
            imageView.image = image
            imageView.isHidden = false
            webView.isHidden = true

        case .html(let html):
            imageView.image = nil
            imageView.isHidden = true
            webView.isHidden = false
            webView.loadHTMLString(Self.themed(html), baseURL: nil)

        case nil:
            imageView.image = nil
            imageView.isHidden = true
            webView.isHidden = true
            // Dropped rather than left loaded, so a hidden panel is not still running the
            // last page's timers and animations.
            webView.loadHTMLString("", baseURL: nil)
        }

        captionLabel.stringValue = content?.subtitle ?? ""
        captionLabel.isHidden = content == nil
        contentMenuButton.isHidden = content == nil

        titleLabel.stringValue = content?.title ?? "Display"
        placeholderLabel.isHidden = content != nil
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
    /// Following a link would leave a 380pt-wide browser with no back button, no address bar
    /// and no way home — so links are handed to the real browser instead, which has all three.
    /// Subresources do not come through here, so scripts, styles and images still load.
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
