import AppKit
import ThreadingDesignKit
import WebKit

enum BluetoothProfileDownloadPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    static func accepts(_ response: URLResponse, filename: String) -> Bool {
        guard allows(response.url), let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              response.expectedContentLength <= BluetoothProfileInstaller.maximumProfileBytes else { return false }
        return filename.lowercased() == "iosbluetoothlogging.mobileconfig"
    }
}

/// A dedicated Apple sign-in surface, separate from the agent-controlled Browser. WebKit owns
/// ephemeral cookies and credentials. No scripts, DOM inspection or network capture are attached.
@MainActor
final class BluetoothProfileDownloadView: NSView, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private let webView: WKWebView
    private let origin = NSTextField(labelWithString: "developer.apple.com")
    private let onComplete: (Result<URL, Error>) -> Void
    private var download: WKDownload?
    private var destination: URL?
    private var generation = 0
    private var progressObservation: NSKeyValueObservation?
    private var deadline: Task<Void, Never>?
    private var finished = false

    init(onComplete: @escaping (Result<URL, Error>) -> Void) {
        self.onComplete = onComplete
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        origin.font = Design.Typography.caption()
        origin.textColor = Design.Text.secondary
        let cancel = ThemedButton(title: L10n.string("Cancel"), target: self, action: #selector(cancelDownload))
        let toolbar = NSStackView(views: [origin, NSView(), cancel])
        toolbar.spacing = Design.Spacing.small
        toolbar.alignment = .centerY
        let content = NSStackView(views: [toolbar, webView])
        content.orientation = .vertical
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: content.widthAnchor),
            webView.widthAnchor.constraint(equalTo: content.widthAnchor),
            webView.heightAnchor.constraint(equalToConstant: 360),
        ])
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
        let allowed = BluetoothProfileDownloadPolicy.allows(action.request.url)
            || action.request.url?.absoluteString == "about:blank"
        decisionHandler(allowed ? (action.shouldPerformDownload ? .download : .allow) : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard BluetoothProfileDownloadPolicy.allows(response.response.url) else {
            decisionHandler(.cancel)
            return
        }
        let isProfile = response.response.mimeType == "application/x-apple-aspen-config"
            || response.response.suggestedFilename?.lowercased() == "iosbluetoothlogging.mobileconfig"
        decisionHandler(isProfile || !response.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        origin.stringValue = webView.url?.host ?? "developer.apple.com"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, BluetoothProfileDownloadPolicy.allows(action.request.url) {
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
        download.delegate = self
        progressObservation = download.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            let count = progress.completedUnitCount
            Task { @MainActor in
                if count > BluetoothProfileInstaller.maximumProfileBytes { self?.finish(.failure(URLError(.dataLengthExceedsMaximum))) }
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !finished, download === self.download,
              BluetoothProfileDownloadPolicy.accepts(response, filename: suggestedFilename) else {
            completionHandler(nil)
            finish(.failure(URLError(.badServerResponse)))
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
        decisionHandler(BluetoothProfileDownloadPolicy.allows(request.url) ? .allow : .cancel)
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
