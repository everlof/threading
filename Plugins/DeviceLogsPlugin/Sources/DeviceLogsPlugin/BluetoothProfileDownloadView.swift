import AppKit
import ThreadingDesignKit
import WebKit

enum BluetoothProfileDownloadPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    static func accepts(_ response: URLResponse, filename: String,
                        allowsURL: (URL?) -> Bool = allows) -> Bool {
        guard allowsURL(response.url), let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              response.expectedContentLength <= BluetoothProfileInstaller.maximumProfileBytes else { return false }
        return filename.lowercased() == "iosbluetoothlogging.mobileconfig"
    }
}

/// A dedicated Apple sign-in surface, separate from the agent-controlled Browser. WebKit owns
/// its isolated website data. No scripts, DOM inspection or network capture are attached.
@MainActor
final class BluetoothProfileDownloadView: NSView, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    enum Metrics {
        static let preferredSize = NSSize(width: 640, height: 740)
        static let screenMargin: CGFloat = 80
        static let transferTimeout: UInt64 = 60_000_000_000
        static let interruptedByPolicy = 102
    }

    let webView: WKWebView
    private let origin = NSTextField(labelWithString: "developer.apple.com")
    private let onComplete: (Result<URL, Error>) -> Void
    private var download: WKDownload?
    private var destination: URL?
    private var generation = 0
    private var progressObservation: NSKeyValueObservation?
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var handingOffDownload = false
    private let allowsURL: (URL?) -> Bool
    private var clearingSignIn = false
    private lazy var forget = ThemedButton(
        title: L10n.string("Forget Sign-In"), target: self, action: #selector(forgetSignIn)
    )

    init(dataStore: WKWebsiteDataStore? = nil,
         allowsURL: @escaping (URL?) -> Bool = BluetoothProfileDownloadPolicy.allows,
         onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onComplete = onComplete
        self.allowsURL = allowsURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? BluetoothProfileWebsiteData.store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        origin.applyFont(.caption)
        origin.textColor = Design.Text.secondary
        let cancel = ThemedButton(title: L10n.string("Cancel"), target: self, action: #selector(cancelDownload))
        cancel.setAccessibilityIdentifier("bluetooth-profile-cancel")
        let toolbar = NSStackView(views: [origin, NSView(), cancel])
        toolbar.spacing = Design.Spacing.small
        toolbar.alignment = .centerY
        let remembered = NSTextField(wrappingLabelWithString: configuration.websiteDataStore.isPersistent
            ? L10n.string("Apple sign-in is remembered on this Mac, separately from the Browser.")
            : L10n.string("Apple sign-in is remembered until Threading quits, separately from the Browser."))
        remembered.applyFont(.caption)
        remembered.textColor = Design.Text.secondary
        remembered.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        forget.setAccessibilityIdentifier("bluetooth-profile-forget-sign-in")
        let footer = NSStackView(views: [remembered, forget])
        footer.spacing = Design.Spacing.small
        footer.alignment = .centerY
        let content = NSStackView(views: [toolbar, webView, footer])
        content.orientation = .vertical
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.medium),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.medium),
            toolbar.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            webView.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        toolbar.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        setAccessibilityIdentifier("bluetooth-profile-browser")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        deadline?.cancel()
        let active = download
        let partial = destination
        Task { @MainActor in
            active?.delegate = nil
            if let active {
                active.cancel { _ in if let partial { Self.removeDownload(partial) } }
            } else if let partial { Self.removeDownload(partial) }
        }
    }

    func start() { webView.load(URLRequest(url: BluetoothProfileInstaller.profileDownloadURL)) }

    @objc private func forgetSignIn() {
        guard !finished, !clearingSignIn, !handingOffDownload, download == nil else { return }
        clearingSignIn = true
        forget.isEnabled = false
        webView.stopLoading()
        webView.isHidden = true
        BluetoothProfileWebsiteData.forget(in: webView.configuration.websiteDataStore) { [weak self] in
            guard let self, !self.finished else { return }
            self.clearingSignIn = false
            self.forget.isEnabled = true
            self.webView.isHidden = false
            self.start()
        }
    }

    func cancel() {
        guard !finished else { return }
        finish(.failure(URLError(.cancelled)))
    }

    @objc private func cancelDownload() { cancel() }

    override func cancelOperation(_ sender: Any?) { cancel() }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        generation += 1
        deadline?.cancel()
        deadline = nil
        progressObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Cancellation completion precedes deletion: WebKit may still be writing the file.
        if let download {
            let partial = destination
            download.delegate = nil
            download.cancel { _ in if let partial { Self.removeDownload(partial) } }
        }
        download = nil
        destination = nil
        onComplete(result)
    }

    static func removeDownload(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = allowsURL(action.request.url)
            || action.request.url?.absoluteString == "about:blank"
        guard allowed else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame != false { finish(.failure(BluetoothProfileDownloadFailure.blockedNavigation)) }
            return
        }
        if action.shouldPerformDownload { handingOffDownload = true }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.response.url?.absoluteString == "about:blank", response.canShowMIMEType {
            decisionHandler(.allow)
            return
        }
        guard allowsURL(response.response.url) else {
            decisionHandler(.cancel)
            if response.isForMainFrame { finish(.failure(BluetoothProfileDownloadFailure.blockedNavigation)) }
            return
        }
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            finish(.failure(BluetoothProfileDownloadFailure.httpStatus(http.statusCode)))
            return
        }
        let isProfile = response.response.mimeType == "application/x-apple-aspen-config"
            || response.response.suggestedFilename?.lowercased() == "iosbluetoothlogging.mobileconfig"
        if isProfile || !response.canShowMIMEType {
            handingOffDownload = true
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        origin.stringValue = webView.url?.host ?? "developer.apple.com"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        // A successful response-to-download handoff interrupts the old navigation. The
        // WKDownload callbacks now own completion, including real transfer failures.
        if handingOffDownload, error.domain == "WebKitErrorDomain",
           error.code == Metrics.interruptedByPolicy { return }
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(BluetoothProfileDownloadFailure.webProcessTerminated))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, allowsURL(action.request.url) {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        attach(download)
    }

    private func attach(_ download: WKDownload) {
        guard !finished, self.download == nil else { download.cancel(nil); return }
        self.download = download
        handingOffDownload = true
        forget.isEnabled = false
        download.delegate = self
        progressObservation = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let count = progress.completedUnitCount
            Task { @MainActor in
                if count > BluetoothProfileInstaller.maximumProfileBytes { self?.finish(.failure(URLError(.dataLengthExceedsMaximum))) }
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Metrics.transferTimeout) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !finished, download === self.download,
              BluetoothProfileDownloadPolicy.accepts(response, filename: suggestedFilename, allowsURL: allowsURL) else {
            completionHandler(nil)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                finish(.failure(BluetoothProfileDownloadFailure.httpStatus(http.statusCode)))
            } else if response.expectedContentLength > BluetoothProfileInstaller.maximumProfileBytes {
                finish(.failure(URLError(.dataLengthExceedsMaximum)))
            } else {
                finish(.failure(BluetoothProfileDownloadFailure.unexpectedProfile))
            }
            return
        }
        let generation = generation
        Task { [weak self] in
            let url = await Task.detached(priority: .utility) { () -> URL? in
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                guard (try? FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )) != nil else { return nil }
                return folder.appendingPathComponent("iOSBluetoothLogging.mobileconfig")
            }.value
            guard let self, !self.finished, self.generation == generation else {
                completionHandler(nil)
                if let url { Self.removeDownload(url) }
                return
            }
            self.destination = url
            completionHandler(url)
            if url == nil { self.finish(.failure(URLError(.cannotCreateFile))) }
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        let allowed = allowsURL(request.url)
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { finish(.failure(BluetoothProfileDownloadFailure.blockedNavigation)) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard download === self.download, let destination else { return }
        // Ownership passes to the setup flow, which removes the download after validation/send.
        self.download = nil
        self.destination = nil
        finish(.success(destination))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === self.download else { return }
        finish(.failure(error))
    }
}
