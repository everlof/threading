import AppKit
import WebKit

// MARK: - Browser View Controller

/// A real, navigable browser surface — distinct from `DisplayPaneController`, which stays the
/// read-only renderer for HTML an agent hands to the display panel.
///
/// It carries browser chrome (back / forward / reload and an editable address bar) over a live
/// `WKWebView` that follows links, keeps history, and exposes the Web Inspector. Its methods are
/// the surface the MCP browser tools drive: navigate, screenshot, query and click the DOM — so
/// an agent reaches the same page the user sees.
final class BrowserViewController: NSViewController {

    // MARK: - Chrome

    private let backButton = BrowserViewController.navButton("chevron.backward", "Back")
    private let forwardButton = BrowserViewController.navButton("chevron.forward", "Forward")
    private let reloadButton = BrowserViewController.navButton("arrow.clockwise", "Reload")
    private let addressField = NSTextField()
    private let progressBar = NSProgressIndicator()

    // MARK: - Web View

    private(set) var webView: WKWebView!

    private var observations: [NSKeyValueObservation] = []

    /// Fired when the page's title or address changes, so a host (the display pane's tab strip and
    /// header) can re-label the tab without polling. Not fired for progress, which ticks constantly.
    var onPageChange: (() -> Void)?

    /// A page URL restored from disk but not yet loaded, so a background session's browser stays
    /// idle until it is actually shown. The display pane navigates to it on first appearance.
    var restoredURL: String?

    /// Fired when the page a caller asked for finishes (or fails, or times out), so an agent's
    /// navigate tool can wait for the page before querying it.
    private var loadCompletion: ((Bool, String) -> Void)?
    private var navigationToken = 0

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Design.Surface.ground.cgColor
        setupWebView()
        setupChrome()
        observeWebView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if webView.url == nil {
            view.window?.makeFirstResponder(addressField)
        }
    }

    // MARK: - Setup

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        // A persistent store keeps logins and cookies across visits, which is the point of a
        // browser rather than the display panel's opaque, throwaway origin.
        configuration.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = Design.Surface.ground

        // Right-click → Inspect Element brings up the full Web Inspector — the element-pinpointing
        // tool WebKit already ships, no code of our own.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
    }

    private func setupChrome() {
        for (button, action) in [(backButton, #selector(goBack)),
                                  (forwardButton, #selector(goForward)),
                                  (reloadButton, #selector(reload))] {
            button.target = self
            button.action = action
        }

        addressField.placeholderString = BrowserDefaults.addressPlaceholder
        addressField.font = Design.Typography.body()
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .none
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = Design.Spacing.small
        bar.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small, left: Design.Spacing.medium,
            bottom: Design.Spacing.small, right: Design.Spacing.medium
        )
        bar.translatesAutoresizingMaskIntoConstraints = false

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(bar)
        view.addSubview(progressBar)
        view.addSubview(separator)
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2),

            separator.topAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        updateNavButtons()
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.syncAddress()
                self?.onPageChange?()
            },
            webView.observe(\.title) { [weak self] _, _ in self?.onPageChange?() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.updateNavButtons() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.updateNavButtons() },
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                self?.updateProgress(webView.estimatedProgress)
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                if !webView.isLoading { self?.updateProgress(1) }
            }
        ]
    }

    // MARK: - Public — Navigation

    /// Loads a URL or search query typed anywhere (address bar, an agent tool), normalising it.
    func navigate(to input: String) {
        navigate(to: input) { _, _ in }
    }

    /// Navigates and calls back when the page finishes, fails, or times out — the form the
    /// agent's navigate tool uses so it can act on a loaded page.
    func navigate(to input: String, onLoad: @escaping (_ success: Bool, _ message: String) -> Void) {
        guard let url = BrowserViewController.normalizedURL(from: input) else {
            onLoad(false, "Not a valid URL or search query.")
            return
        }

        _ = view   // Forces `loadView` if the surface has not been shown yet (an agent may drive
                   // navigation before the user opens the browser). `loadViewIfNeeded` is 14+.

        loadCompletion?(false, "Superseded by a newer navigation.")
        loadCompletion = onLoad
        navigationToken += 1
        let token = navigationToken

        webView.load(URLRequest(url: url))
        syncAddress(url: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + BrowserDefaults.loadTimeout) { [weak self] in
            guard let self, self.navigationToken == token, self.loadCompletion != nil else { return }
            self.finishLoad(true, "Still loading after \(Int(BrowserDefaults.loadTimeout))s; returning what has rendered.")
        }
    }

    private func finishLoad(_ success: Bool, _ message: String) {
        let completion = loadCompletion
        loadCompletion = nil
        completion?(success, message)
    }

    var currentURL: URL? { webView.url }
    var currentTitle: String? { webView.title }

    // MARK: - Public — Agent Bridge

    /// Runs JavaScript in the page and returns its result, the primitive the DOM-query and
    /// click tools build on.
    func evaluate(_ javascript: String) async throws -> Any? {
        try await webView.evaluateJavaScript(javascript)
    }

    /// A PNG snapshot of the current page — what the agent "sees".
    @MainActor
    func screenshot() async -> Data? {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image?.pngData)
            }
        }
    }

    // MARK: - Actions

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }

    @objc private func addressEntered() {
        navigate(to: addressField.stringValue)
    }

    // MARK: - Chrome Sync

    private func syncAddress(url: URL? = nil) {
        let shown = url ?? webView.url
        // Leave the field alone while the user is editing it, so a background load does not yank
        // the text out from under the cursor.
        if view.window?.firstResponder !== addressField.currentEditor() {
            addressField.stringValue = shown?.absoluteString ?? ""
        }
    }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func updateProgress(_ value: Double) {
        progressBar.doubleValue = value
        progressBar.isHidden = value >= 1 || value <= 0
    }

    // MARK: - Helpers

    private static func navButton(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
            target: nil,
            action: nil
        )
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = Design.Text.secondary
        return button
    }

    /// Turns whatever was typed into a URL: an explicit scheme is honoured, a bare domain gets
    /// `https://`, and anything else becomes a search — so the bar accepts URLs and queries alike.
    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil || url.scheme == "about" {
            return url
        }

        if trimmed.contains("."), !trimmed.contains(" "), let url = URL(string: "https://\(trimmed)") {
            return url
        }

        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "\(BrowserDefaults.searchPrefix)\(query)")
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {

    /// A browser follows links, unlike the read-only display panel that hands them off.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncAddress()
        updateNavButtons()
        finishLoad(true, "")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(false, error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoad(false, error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SkalmanLogger.mcp.error("Browser web content process terminated; reloading")
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserViewController: WKUIDelegate {

    /// `target=_blank` and `window.open` navigate in place rather than opening a window this
    /// surface has no chrome for.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - NSImage PNG

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Browser Defaults

enum BrowserDefaults {
    static let addressPlaceholder = "Search or enter address"
    static let searchPrefix = "https://duckduckgo.com/?q="

    /// How long an agent's navigate waits before returning whatever has rendered, so a hung or
    /// endlessly-streaming page does not block the tool call forever.
    static let loadTimeout: TimeInterval = 20
}
