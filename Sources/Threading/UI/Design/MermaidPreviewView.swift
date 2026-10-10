import AppKit
import CoreText
import WebKit

/// A native reader around a bundled, isolated Mermaid renderer. One selected file, one canvas.
///
/// The canvas outlives a change of file: selecting another diagram, or the selected one changing
/// on disk, renders into the page already loaded instead of launching a content process and
/// parsing the bundle again. Hiding or detaching the reader releases the canvas, and keeps what
/// the reader chose — the file, Diagram or Source, and where the canvas was looking — for when it
/// comes back.
@MainActor
final class MermaidPreviewView: NSView, ThemedComponent, ThemeDerivedContent, WKNavigationDelegate {
    enum State: Equatable { case empty, loading, ready, sourceOnly }

    /// Where the canvas was looking, as the page last reported it.
    struct Viewport: Equatable {
        var fitting: Bool
        var scale: Double
        var x: Double
        var y: Double
    }

    private(set) var state: State = .empty
    private(set) var source = ""
    private(set) var renderMetrics: [String: Double] = [:]
    private(set) var rendererFailureForTesting: String?
    private(set) var rendererInstallMillisecondsForTesting = 0.0
    private(set) var rendererLaunchCountForTesting = 0
    private(set) var deniedNavigationCountForTesting = 0
    private(set) var isRendering = false
    private(set) var currentURL: URL?
    private(set) var viewport: Viewport?
    var onStateChange: ((State) -> Void)?

    // MARK: - Private Properties

    /// Why the reader is showing source instead of a diagram.
    private enum Fallback: Equatable {
        case unreadable
        case tooLarge
        case notText
        case invalidDiagram
        /// The canvas did not answer: a timeout, an exited content process or a failed load.
        case rendererUnavailable

        var message: String {
            switch self {
            case .unreadable: L10n.string("This file could not be previewed.")
            case .tooLarge: L10n.string("This diagram is too large to render. Showing source.")
            case .notText: L10n.string("This diagram is not UTF-8 text. Showing source.")
            case .invalidDiagram, .rendererUnavailable:
                L10n.string("The diagram could not be rendered. Showing source.")
            }
        }

        var metricName: String {
            switch self {
            case .unreadable: "unreadable"
            case .tooLarge: "too_large"
            case .notText: "not_text"
            case .invalidDiagram: "invalid"
            case .rendererUnavailable: "renderer_unavailable"
            }
        }
    }

    /// What a render does with the canvas's scale and scroll.
    private enum ViewportRequest {
        /// A new document: fit it to the width.
        case fit
        /// The same reader repainting — a theme change or the file changing in place.
        case preserve
        /// The reader coming back after its canvas was released.
        case restore(Viewport)
    }

    /// Everything a render takes from the theme. Compared, so a theme event that changes nothing
    /// the diagram draws with does not repaint it.
    private struct Style: Equatable {
        var ground: String
        var face: String
        var ink: String
        var border: String
        var fontFamilies: String
        var fontSize: Double
        var inset: Double
        var dark: Bool
        /// A process-registered theme face, which WebKit's content process cannot see unless the
        /// page is handed its bytes.
        var embeddedFont: EmbeddedFont?
    }

    private struct EmbeddedFont: Equatable {
        var family: String
        var file: URL
    }

    private enum Constants {
        static let viewportMessage = "threadingViewport"
        static let systemFontFamilies = "-apple-system, sans-serif"
    }

    private let mode = ThemedSegmentedControl()
    private lazy var zoomButtons: [ThemedIconButton] = [
        zoomButton(symbol: "minus.magnifyingglass", label: L10n.string("Zoom out"), operation: "out"),
        zoomButton(symbol: "plus.magnifyingglass", label: L10n.string("Zoom in"), operation: "in"),
        zoomButton(symbol: "arrow.left.and.right", label: L10n.string("Fit diagram to width"), operation: "fit")
    ]
    private lazy var toolbar = ControlRowView(
        scale: .compact,
        leading: [mode],
        trailing: [ControlButtonGroupView(buttons: zoomButtons)]
    )
    private let body = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var sourceScroll: ThemedTextScrollView?
    private var web: WKWebView?
    private lazy var viewportRelay = MermaidViewportRelay(owner: self)
    private var entryURL: URL?
    private var title = ""
    /// The reader was hidden or detached and owes the file a read when it is shown again.
    private var needsResume = false
    private var generation = UUID()
    private var renderRequest = UUID()
    /// Echoed by the page with every viewport report, so a report about an earlier document in a
    /// reused canvas is not taken for this one's.
    private var renderTicket = 0
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let appEvents = AppEventObservations()
    private var pageReady = false
    private var pendingRender: ViewportRequest?
    private var document: MermaidPreviewLoader.Document?
    private var displayedSourceFingerprint: [UInt8]?
    private var fallback: Fallback?
    private var prefersSource = false
    /// Saved when the canvas is released, applied by the first render after it comes back.
    private var pendingViewport: Viewport?
    private var suspendedFingerprint: [UInt8]?
    private var lastStyle: Style?
    private var deliveredFont: EmbeddedFont?
    private var rendererRetries = 0
    private var span: PerformanceSpan?
    private var spanMetadata: [String: String] = [:]

    // MARK: - Initialization

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
        renderTask?.cancel()
        timeoutTask?.cancel()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("attachments.mermaid-preview")
        mode.configure(titles: [L10n.string("Diagram"), L10n.string("Source")])
        mode.sizesToTitles = true
        mode.onSelect = { [weak self] index in
            self?.prefersSource = index == 1
            self?.updateMode()
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

    private func zoomButton(symbol: String, label: String, operation: String) -> ThemedIconButton {
        let button = ThemedIconButton(symbolName: symbol, accessibility: label, target: .inline, inkSource: .chrome)
        button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(operation)
        button.setAccessibilityIdentifier("attachments.mermaid-zoom-\(operation)")
        button.onPress = { [weak self] in self?.zoom(operation) }
        return button
    }

    // MARK: - Public Methods

    /// A new selection. Resets what the reader chose and keeps a loaded canvas for it.
    func display(_ url: URL) {
        resetReader()
        currentURL = url
        title = url.lastPathComponent
        web?.setAccessibilityLabel(title)
        guard isPresented else {
            discardRenderer()
            needsResume = true
            return
        }
        beginReading(url, reason: "display")
    }

    /// Attachment-list changes must not reboot an unchanged diagram or reset its viewport.
    func refreshFile() {
        guard let currentURL, !needsResume, isPresented else { return }
        requestSource(at: currentURL, isRefresh: true)
    }

    /// Leaving Mermaid for another kind of preview: everything goes, the canvas included.
    func clear() {
        resetReader()
        discardRenderer()
        currentURL = nil
        title = ""
    }

    func showSource(_ show: Bool) {
        prefersSource = show
        updateMode()
    }

    func rederiveThemedContent() { refreshTheme() }

    // MARK: - Reading

    private var isPresented: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    private func beginReading(_ url: URL, reason: String) {
        setState(.loading)
        message.stringValue = L10n.string("Loading…")
        updateMode()
        beginSpan(reason: reason)
        // The read is inside the budget too: a file on a stalled mount must not hold the pane on
        // "Loading…" forever.
        armTimeout(onExpiry: .unreadable)
        requestSource(at: url, isRefresh: false)
    }

    private func requestSource(at url: URL, isRefresh: Bool) {
        loadTask?.cancel()
        let token = generation
        let started = DispatchTime.now().uptimeNanoseconds
        loadTask = Task { [weak self] in
            let result: Result<MermaidPreviewLoader.Document, Error>
            do {
                result = .success(try await MermaidPreviewLoader.document(at: url))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.spanMetadata["read_ms"] = Self.milliseconds(since: started)
            switch result {
            case .success(let document):
                self.adopt(document, isRefresh: isRefresh)
            case .failure:
                self.document = nil
                self.source = ""
                self.fail(.unreadable)
            }
        }
    }

    private func adopt(_ document: MermaidPreviewLoader.Document, isRefresh: Bool) {
        let previous = self.document
        if isRefresh, let previous, previous.fingerprint == document.fingerprint {
            // Unchanged bytes. Only a canvas that failed to answer is worth asking again, and only
            // a bounded number of times — a refresh arrives whenever the list changes.
            guard fallback == .rendererUnavailable,
                  rendererRetries < MermaidPreviewLimits.maximumRendererRetries else { return }
            rendererRetries += 1
            beginSpan(reason: "retry")
            startRendering(.fit)
            return
        }
        let request: ViewportRequest
        if isRefresh, previous != nil {
            // The file changed in place: an agent rewriting the diagram the reader is looking at.
            request = state == .ready ? .preserve : .fit
            rendererRetries = 0
            beginSpan(reason: "update")
        } else if let pendingViewport, suspendedFingerprint == document.fingerprint {
            request = .restore(pendingViewport)
        } else {
            request = .fit
        }
        if case .restore = request {} else { pendingViewport = nil }
        suspendedFingerprint = nil
        self.document = document
        source = document.source
        fallback = nil
        updateMode()
        switch document.admission {
        case .tooLarge: fail(.tooLarge)
        case .notText: fail(.notText)
        case .render: startRendering(request)
        }
    }

    // MARK: - Rendering

    private func startRendering(_ request: ViewportRequest) {
        if state != .ready {
            setState(.loading)
            message.stringValue = L10n.string("Loading…")
        }
        updateMode()
        if web != nil, pageReady {
            render(request)
        } else {
            pendingRender = request
            if web == nil {
                loadRenderer()
            } else {
                armTimeout(onExpiry: .rendererUnavailable)
            }
        }
    }

    private func loadRenderer() {
        guard let entry = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid") else {
            fail(.rendererUnavailable)
            return
        }
        entryURL = entry
        let started = DispatchTime.now().uptimeNanoseconds
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(viewportRelay, name: Constants.viewportMessage)
        let canvas = WKWebView(frame: .zero, configuration: configuration)
        canvas.navigationDelegate = self
        canvas.setAccessibilityLabel(title)
        canvas.setAccessibilityIdentifier("attachments.mermaid-canvas")
        web = canvas
        rendererLaunchCountForTesting += 1
        install(canvas)
        refreshBackground()
        canvas.loadFileURL(entry, allowingReadAccessTo: entry.deletingLastPathComponent())
        rendererInstallMillisecondsForTesting = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        spanMetadata["renderer_install_ms"] = String(format: "%.2f", rendererInstallMillisecondsForTesting)
        armTimeout(onExpiry: .rendererUnavailable)
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

    private func render(_ request: ViewportRequest) {
        guard pageReady, web != nil, let document, document.admission == .render else { return }
        let style = currentStyle()
        lastStyle = style
        isRendering = true
        let requestID = UUID()
        renderRequest = requestID
        armTimeout(onExpiry: .rendererUnavailable)
        renderTask?.cancel()
        guard let font = style.embeddedFont, font != deliveredFont else {
            send(document.source, style: style, request: request, fontData: nil, requestID: requestID)
            return
        }
        let token = generation
        renderTask = Task { [weak self] in
            // An unreadable face is not a failed diagram: the family list falls back to the system's.
            let data = try? await MermaidPreviewLoader.fontData(at: font.file)
            guard let self, !Task.isCancelled, self.generation == token, self.renderRequest == requestID else { return }
            self.send(document.source, style: style, request: request, fontData: data, requestID: requestID)
        }
    }

    private func send(
        _ source: String,
        style: Style,
        request: ViewportRequest,
        fontData: String?,
        requestID: UUID
    ) {
        guard let web else { return }
        let token = generation
        let ticket = renderTicket
        var palette: [String: Any] = [
            "ground": style.ground, "face": style.face, "ink": style.ink, "border": style.border,
            "font": style.fontFamilies, "fontSize": style.fontSize, "inset": style.inset,
            "dark": style.dark, "title": title
        ]
        if let font = style.embeddedFont, let fontData {
            palette["fontFace"] = ["family": font.family, "key": font.file.path, "data": fontData]
        }
        let viewport: Any
        switch request {
        case .fit: viewport = "fit"
        case .preserve: viewport = "preserve"
        case .restore(let saved):
            viewport = ["fitting": saved.fitting, "scale": saved.scale, "x": saved.x, "y": saved.y]
        }
        web.callAsyncJavaScript(
            "return await window.threadingRender(source, palette, limits, viewport, ticket);",
            arguments: ["source": source, "palette": palette, "viewport": viewport, "ticket": ticket,
                        "limits": ["bytes": MermaidPreviewLimits.maximumRenderBytes,
                                   "edges": MermaidPreviewLimits.maximumEdges]],
            in: nil, in: .page
        ) { [weak self, weak web] result in
            guard let self, let web, self.web === web, self.generation == token,
                  self.renderRequest == requestID else { return }
            self.isRendering = false
            self.timeoutTask?.cancel()
            switch result {
            case .success(let value):
                if fontData != nil { self.deliveredFont = style.embeddedFont }
                self.renderMetrics = value as? [String: Double] ?? [:]
                self.fallback = nil
                self.pendingViewport = nil
                self.message.stringValue = ""
                self.spanMetadata["engine_ms"] = self.renderMetrics["renderMilliseconds"].map {
                    String(format: "%.2f", $0)
                }
                self.endSpan(outcome: "ready")
                self.setState(.ready)
                self.updateMode()
                // A theme change that landed while this render was in flight.
                self.refreshStyle()
            case .failure(let error):
                self.rendererFailureForTesting = String(describing: error)
                self.fail(.invalidDiagram)
            }
        }
    }

    private func fail(_ reason: Fallback) {
        timeoutTask?.cancel()
        renderTask?.cancel()
        isRendering = false
        pendingRender = nil
        // A page that did not answer is not trusted with the next document. One that answered
        // "this is not a diagram" is healthy and stays loaded, hidden, for the next selection.
        if reason == .rendererUnavailable { discardRenderer() }
        fallback = reason
        message.stringValue = reason.message
        endSpan(outcome: reason.metricName)
        setState(.sourceOnly)
        updateMode()
    }

    private func armTimeout(onExpiry reason: Fallback) {
        timeoutTask?.cancel()
        let token = generation
        let request = renderRequest
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MermaidPreviewLimits.renderTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.generation == token, self.renderRequest == request else { return }
            self.loadTask?.cancel()
            self.fail(reason)
        }
    }

    private func discardRenderer() {
        pageReady = false
        isRendering = false
        pendingRender = nil
        deliveredFont = nil
        renderTask?.cancel()
        guard let web else { return }
        web.configuration.userContentController.removeScriptMessageHandler(forName: Constants.viewportMessage)
        web.navigationDelegate = nil
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        web.removeFromSuperview()
        self.web = nil
    }

    /// Forgets the document and what the reader chose, and invalidates every pending result. A
    /// loaded canvas stays; `clear()` and `suspend()` decide whether it goes.
    private func resetReader() {
        generation = UUID()
        renderRequest = UUID()
        renderTicket += 1
        loadTask?.cancel()
        renderTask?.cancel()
        timeoutTask?.cancel()
        loadTask = nil
        renderTask = nil
        timeoutTask = nil
        isRendering = false
        pendingRender = nil
        needsResume = false
        document = nil
        source = ""
        displayedSourceFingerprint = nil
        sourceScroll?.textView.string = ""
        renderMetrics = [:]
        rendererInstallMillisecondsForTesting = 0
        rendererFailureForTesting = nil
        fallback = nil
        prefersSource = false
        viewport = nil
        pendingViewport = nil
        suspendedFingerprint = nil
        lastStyle = nil
        rendererRetries = 0
        endSpan(outcome: "cancelled")
        setState(.empty)
        message.stringValue = ""
        updateMode()
    }

    // MARK: - Presentation

    private func setState(_ value: State) {
        state = value
        onStateChange?(value)
    }

    private func updateMode() {
        let showsSource = prefersSource || state == .sourceOnly
        toolbar.isHidden = state == .sourceOnly
        mode.selectedIndex = prefersSource ? 1 : 0
        if showsSource, sourceScroll == nil {
            let scroll = ThemedTextView.scrolling()
            scroll.textView.isEditable = false
            scroll.textView.applyFont(.previewCode)
            scroll.textView.setAccessibilityLabel(L10n.string("Diagram source"))
            install(scroll)
            sourceScroll = scroll
        }
        let fingerprint = document?.fingerprint ?? []
        if showsSource, displayedSourceFingerprint != fingerprint {
            sourceScroll?.textView.string = source
            displayedSourceFingerprint = fingerprint
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

    // MARK: - Theme

    private func currentStyle() -> Style {
        var style: Style?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let font = Design.Typography.body()
            let family = font.familyName ?? ""
            let isSystemFace = family.isEmpty || family.hasPrefix(".")
            style = Style(
                ground: Design.Surface.ground.hexString,
                face: Design.Surface.controlResting.hexString,
                ink: Design.Text.label.hexString,
                border: Design.Surface.border.hexString,
                fontFamilies: isSystemFace
                    ? Constants.systemFontFamilies
                    : "\(Self.cssString(family)), \(Constants.systemFontFamilies)",
                fontSize: font.pointSize,
                inset: Design.Spacing.medium,
                dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
                embeddedFont: isSystemFace ? nil : Self.processLocalFontFile(for: font).map {
                    EmbeddedFont(family: family, file: $0)
                }
            )
        }
        return style!
    }

    /// A CSS string literal. Unquoted, a family with a word that starts with a digit — "Font
    /// Awesome 6 Free", "3270 Nerd Font" — made the whole declaration invalid, and labels fell
    /// back to the page's serif.
    static func cssString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"", "\\": escaped += "\\" + String(scalar)
            case _ where scalar.properties.generalCategory == .control:
                escaped += "\\" + String(scalar.value, radix: 16) + " "
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "\""
    }

    /// A face this process registered — a bundled theme font, one a theme carries, one an
    /// extension's appearance declares — lives only here; WebKit's content process sees installed
    /// fonts alone. macOS offers no per-scope listing (`CTFontManagerCopyRegisteredFontDescriptors`
    /// is iOS-only), so the answer is where the file lives: every process registration Threading
    /// makes is of a file inside its bundle or its own Application Support folder.
    static func processLocalFontFile(for font: NSFont) -> URL? {
        guard let url = (CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL)?
            .standardizedFileURL else { return nil }
        return processFontRoots.contains { url.path.hasPrefix($0) } ? url : nil
    }

    private static let processFontRoots: [String] = [
        Bundle.main.bundleURL,
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName, isDirectory: true)
    ].map { $0.standardizedFileURL.path + "/" }

    private func refreshBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            web?.underPageBackgroundColor = Design.Surface.ground
            message.textColor = Design.Text.tertiary
        }
    }

    private func refreshTheme() {
        refreshBackground()
        refreshStyle()
    }

    /// Repaints a settled diagram whose ink changed. A render still in flight checks again when it
    /// lands, and a page still loading renders with the theme of the moment it finishes.
    private func refreshStyle() {
        guard state == .ready, !isRendering, let lastStyle, lastStyle != currentStyle() else { return }
        render(.preserve)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    // MARK: - Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { suspend() } else { resume() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        suspend()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        resume()
    }

    /// Releases the canvas and every pending result, and keeps the reader's choices.
    private func suspend() {
        guard currentURL != nil, !needsResume else { return }
        if state == .ready, let viewport { pendingViewport = viewport }
        suspendedFingerprint = pendingViewport == nil ? nil : document?.fingerprint
        generation = UUID()
        renderRequest = UUID()
        loadTask?.cancel()
        timeoutTask?.cancel()
        discardRenderer()
        endSpan(outcome: "suspended")
        needsResume = true
        fallback = nil
        message.stringValue = ""
        setState(.empty)
        updateMode()
    }

    private func resume() {
        guard needsResume, let currentURL, isPresented else { return }
        needsResume = false
        rendererRetries = 0
        beginReading(currentURL, reason: "resume")
    }

    // MARK: - Instrumentation

    private func beginSpan(reason: String) {
        endSpan(outcome: "superseded")
        span = PerformanceRecorder.shared.begin("Mermaid Preview", category: "attachments", crossesQueues: true)
        spanMetadata = ["reason": reason]
    }

    private func endSpan(outcome: String) {
        guard let span else { return }
        spanMetadata["outcome"] = outcome
        span.end(metadata: spanMetadata)
        self.span = nil
        spanMetadata = [:]
    }

    private static func milliseconds(since started: UInt64) -> String {
        String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    // MARK: - Viewport Reports

    fileprivate func receiveViewport(_ message: WKScriptMessage) {
        guard message.webView === web,
              let body = message.body as? [String: Any],
              (body["ticket"] as? NSNumber)?.intValue == renderTicket,
              let fitting = body["fitting"] as? Bool,
              let scale = (body["scale"] as? NSNumber)?.doubleValue,
              let x = (body["x"] as? NSNumber)?.doubleValue,
              let y = (body["y"] as? NSNumber)?.doubleValue else { return }
        viewport = Viewport(fitting: fitting, scale: scale, x: x, y: y)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        pageReady = true
        guard let request = pendingRender else { return }
        pendingRender = nil
        render(request)
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
        fail(.rendererUnavailable)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === web else { return }
        fail(.rendererUnavailable)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        fail(.rendererUnavailable)
    }

    // MARK: - Testing

    var webViewForTesting: WKWebView? { web }
    func waitForSourceReadForTesting() async { await loadTask?.value }
}

/// The page's viewport reports, held weakly: a user content controller retains its handlers, and
/// the reader owns the web view that owns the controller.
@MainActor
private final class MermaidViewportRelay: NSObject, WKScriptMessageHandler {
    private weak var owner: MermaidPreviewView?

    init(owner: MermaidPreviewView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receiveViewport(message)
    }
}
