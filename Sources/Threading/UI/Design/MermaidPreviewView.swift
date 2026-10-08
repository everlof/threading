import AppKit
import WebKit

/// A native reader around a bundled, isolated Mermaid renderer. One selected file, one canvas.
@MainActor
final class MermaidPreviewView: NSView, ThemedComponent, ThemeDerivedContent, WKNavigationDelegate {
    enum State: Equatable { case empty, loading, ready, sourceOnly }
    private(set) var state: State = .empty
    private(set) var source = ""
    private(set) var renderMetrics: [String: Double] = [:]
    private(set) var rendererFailureForTesting: String?
    private(set) var rendererInstallMillisecondsForTesting = 0.0
    private(set) var deniedNavigationCountForTesting = 0
    private(set) var isRendering = false
    var onStateChange: ((State) -> Void)?

    private let mode = ThemedSegmentedControl()
    private let toolbar = NSStackView()
    private let body = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var sourceScroll: ThemedTextScrollView?
    private var web: WKWebView?
    private var entryURL: URL?
    private var title = ""
    private(set) var currentURL: URL?
    private var suspendedURL: URL?
    private var generation = UUID()
    private var renderRequest = UUID()
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let appEvents = AppEventObservations()
    private var zoomButtons: [ThemedButton] = []
    private var pageReady = false
    private var lastPalette: [String: Any]?
    private var sourceFingerprint: [UInt8] = []
    private var displayedSourceFingerprint: [UInt8]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.refreshTheme() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in self?.refreshTheme() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
        timeoutTask?.cancel()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("attachments.mermaid-preview")
        mode.configure(titles: [L10n.string("Diagram"), L10n.string("Source")])
        mode.sizesToTitles = true
        mode.onSelect = { [weak self] _ in self?.updateMode() }
        toolbar.orientation = .horizontal
        toolbar.spacing = Design.Spacing.small
        toolbar.alignment = .centerY
        toolbar.addArrangedSubview(mode)
        let spacer = NSView()
        toolbar.addArrangedSubview(spacer)
        for (symbol, label, operation) in [
            ("minus.magnifyingglass", L10n.string("Zoom out"), "out"),
            ("plus.magnifyingglass", L10n.string("Zoom in"), "in"),
            ("arrow.left.and.right", L10n.string("Fit diagram to width"), "fit")
        ] {
            let button = ThemedButton(symbol: symbol, accessibility: label, target: nil, action: nil)
            button.toolTip = label
            button.identifier = NSUserInterfaceItemIdentifier(operation)
            button.target = self
            button.action = #selector(zoomPressed(_:))
            toolbar.addArrangedSubview(button)
            zoomButtons.append(button)
        }
        message.applyFont(.caption)
        message.textColor = Design.Text.tertiary
        message.setAccessibilityIdentifier("attachments.mermaid-status")
        let stack = NSStackView(views: [toolbar, message, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateMode()
    }

    func display(_ url: URL) {
        clear()
        currentURL = url
        title = url.lastPathComponent
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            currentURL = nil
            suspendedURL = url
            return
        }
        setState(.loading)
        message.stringValue = L10n.string("Loading…")
        updateMode()
        requestSource(at: url, onlyIfChanged: false)
    }

    /// Attachment-list changes must not reboot an unchanged diagram or reset its viewport.
    func refreshFile() {
        guard let currentURL else { return }
        requestSource(at: currentURL, onlyIfChanged: true)
    }

    private func requestSource(at url: URL, onlyIfChanged: Bool) {
        loadTask?.cancel()
        let token = generation
        loadTask = Task { [weak self] in
            do {
                let document = try await MermaidPreviewLoader.shared.document(at: url)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if onlyIfChanged, self.sourceFingerprint == document.fingerprint,
                   self.state != .loading || self.web != nil { return }
                if onlyIfChanged {
                    self.generation = UUID()
                    self.timeoutTask?.cancel()
                    self.discardRenderer()
                    self.lastPalette = nil
                    self.rendererFailureForTesting = nil
                    self.renderMetrics = [:]
                    if self.state == .sourceOnly { self.mode.selectedIndex = 0 }
                    self.setState(.loading)
                    self.message.stringValue = L10n.string("Loading…")
                }
                self.source = document.source
                self.sourceFingerprint = document.fingerprint
                self.updateMode()
                guard document.canRender else {
                    self.showSourceOnly(L10n.string("This diagram is too large to render. Showing source."))
                    return
                }
                self.loadRenderer()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.source = ""
                self.sourceFingerprint = []
                self.showSourceOnly(L10n.string("This file could not be previewed."))
            }
        }
    }

    func clear() {
        generation = UUID()
        loadTask?.cancel()
        timeoutTask?.cancel()
        loadTask = nil
        timeoutTask = nil
        currentURL = nil
        suspendedURL = nil
        discardRenderer()
        source = ""
        sourceFingerprint = []
        displayedSourceFingerprint = nil
        sourceScroll?.textView.string = ""
        renderMetrics = [:]
        rendererInstallMillisecondsForTesting = 0
        rendererFailureForTesting = nil
        lastPalette = nil
        mode.selectedIndex = 0
        setState(.empty)
        message.stringValue = ""
        updateMode()
    }

    private func loadRenderer() {
        guard let entry = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid") else {
            showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
            return
        }
        entryURL = entry
        let started = DispatchTime.now().uptimeNanoseconds
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let canvas = WKWebView(frame: .zero, configuration: configuration)
        canvas.navigationDelegate = self
        canvas.setAccessibilityLabel(title)
        canvas.setAccessibilityIdentifier("attachments.mermaid-canvas")
        web = canvas
        install(canvas)
        refreshBackground()
        canvas.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        rendererInstallMillisecondsForTesting = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let token = generation
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MermaidPreviewLimits.renderTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.generation == token, self.state == .loading else { return }
            self.showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
        }
        updateMode()
    }

    private func install(_ surface: NSView) {
        surface.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            surface.topAnchor.constraint(equalTo: body.topAnchor),
            surface.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }

    private func render(preserveViewport: Bool = false) {
        guard pageReady, let web else { return }
        let token = generation
        var palette: [String: Any] = [:]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let family = Design.Typography.body().familyName ?? ""
            let font = family.hasPrefix(".") || family.isEmpty
                ? "-apple-system, sans-serif" : "\(family), -apple-system, sans-serif"
            palette = ["ground": Design.Surface.ground.hexString, "face": Design.Surface.controlResting.hexString,
             "ink": Design.Text.label.hexString, "border": Design.Surface.border.hexString,
             "font": font, "title": title,
             "fontSize": Design.Typography.body().pointSize,
             "inset": Design.Spacing.medium,
             "dark": effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua]
        }
        if preserveViewport, let lastPalette, NSDictionary(dictionary: palette).isEqual(to: lastPalette) { return }
        lastPalette = palette
        isRendering = true
        let request = UUID()
        renderRequest = request
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MermaidPreviewLimits.renderTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.generation == token,
                  self.renderRequest == request, self.web != nil else { return }
            self.showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
        }
        web.callAsyncJavaScript(
            "return await window.threadingRender(source, palette, limits, preserveViewport);",
            arguments: ["source": source, "palette": palette,
                        "preserveViewport": preserveViewport,
                        "limits": ["bytes": MermaidPreviewLimits.maximumRenderBytes,
                                   "edges": MermaidPreviewLimits.maximumEdges]],
            in: nil, in: .page
        ) { [weak self, weak web] result in
            guard let self, let web, self.web === web, self.generation == token,
                  self.renderRequest == request else { return }
            self.isRendering = false
            self.timeoutTask?.cancel()
            switch result {
            case .success(let value):
                self.renderMetrics = value as? [String: Double] ?? [:]
                self.message.stringValue = ""
                self.setState(.ready)
                self.updateMode()
            case .failure(let error):
                self.rendererFailureForTesting = String(describing: error)
                self.showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
            }
        }
    }

    private func showSourceOnly(_ reason: String) {
        timeoutTask?.cancel()
        discardRenderer()
        message.stringValue = reason
        mode.selectedIndex = 1
        setState(.sourceOnly)
        updateMode()
    }

    private func discardRenderer() {
        pageReady = false
        isRendering = false
        web?.navigationDelegate = nil
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
        web?.removeFromSuperview()
        web = nil
    }

    private func setState(_ value: State) {
        state = value
        onStateChange?(value)
    }

    func showSource(_ show: Bool) {
        mode.selectedIndex = show ? 1 : 0
        updateMode()
    }

    private func updateMode() {
        toolbar.isHidden = state == .sourceOnly
        let showsSource = mode.selectedIndex == 1 || state == .sourceOnly
        if showsSource, sourceScroll == nil {
            let scroll = ThemedTextView.scrolling()
            scroll.textView.isEditable = false
            scroll.textView.applyFont(.previewCode)
            scroll.textView.setAccessibilityLabel(L10n.string("Diagram source"))
            install(scroll)
            sourceScroll = scroll
        }
        if showsSource, displayedSourceFingerprint != sourceFingerprint {
            sourceScroll?.textView.string = source
            displayedSourceFingerprint = sourceFingerprint
        }
        sourceScroll?.isHidden = !showsSource
        web?.isHidden = showsSource || state != .ready
        message.isHidden = message.stringValue.isEmpty
        zoomButtons.forEach { $0.isEnabled = !showsSource && state == .ready }
    }

    private func zoom(_ operation: String) {
        guard state == .ready else { return }
        web?.callAsyncJavaScript("window.threadingZoom(operation);", arguments: ["operation": operation],
                                in: nil, in: .page, completionHandler: nil)
    }

    @objc private func zoomPressed(_ sender: ThemedButton) {
        guard let operation = sender.identifier?.rawValue else { return }
        zoom(operation)
    }

    private func refreshBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            web?.underPageBackgroundColor = Design.Surface.ground
            message.textColor = Design.Text.tertiary
        }
    }

    private func refreshTheme() {
        refreshBackground()
        if state == .ready { render(preserveViewport: true) }
    }

    func rederiveThemedContent() { refreshTheme() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { suspend() }
        else if !isHiddenOrHasHiddenAncestor { resume() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        suspend()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if window != nil { resume() }
    }

    private func suspend() {
        guard let url = currentURL else { return }
        clear()
        suspendedURL = url
    }

    private func resume() {
        guard let url = suspendedURL else { return }
        display(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        pageReady = true
        render()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Bundle entry only. Source is passed as data and gains no local or network navigation.
        guard navigationAction.request.url == entryURL else {
            deniedNavigationCountForTesting += 1
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        showSourceOnly(L10n.string("The diagram could not be rendered. Showing source."))
    }

    var webViewForTesting: WKWebView? { web }
    func waitForSourceReadForTesting() async { await loadTask?.value }
}
