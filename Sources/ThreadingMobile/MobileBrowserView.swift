import Network
import SafariServices
import SwiftUI
import ThreadingRemoteKit
import WebKit

/// Host-owned browser chrome. WebKit owns the page, scrolling, selection, keyboard and zoom.
struct MobileBrowserView: View {
    @StateObject private var model: MobileBrowserModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme

    init(client: RemoteClient, sessionID: String, tabID: String, loadsRemotely: Bool = true) {
        _model = StateObject(wrappedValue: MobileBrowserModel(
            client: client, sessionID: sessionID, tabID: tabID, loadsRemotely: loadsRemotely
        ))
    }

    var body: some View {
        ZStack {
            if let url = model.publicURL {
                MobileSystemBrowser(url: url)
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                localBrowser
            }
        }
        .task { await model.open() }
        .onDisappear { model.close() }
    }

    private var localBrowser: some View {
        VStack(spacing: 0) {
            VStack(spacing: MobileDesign.Spacing.tight) {
                Text(model.displayAddress)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MobileL10n.string(model.isLocal ? "Connected through your Mac · Separate browsing" : "Separate browsing on your iPhone"))
                    .font(.caption)
            }
            .foregroundStyle(theme.secondaryLabel)
            .frame(maxWidth: .infinity)
            .padding(MobileDesign.Spacing.medium)
            .background(theme.surface)
            if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn’t open page", systemImage: "globe")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.open() } }
                }
            } else if let webView = model.webView {
                MobileBrowserPage(webView: webView)
            } else {
                MobileLoadingPlaceholder(MobileL10n.string("Opening browser…"))
            }
        }
        .background(theme.ground)
        .navigationTitle("Browse on iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar, .bottomBar)
        .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(MobileL10n.string("Close browser"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if model.isLoading { model.webView?.stopLoading() }
                    else { model.webView?.reload() }
                } label: { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise") }
                .disabled(model.webView == nil)
                .accessibilityLabel(MobileL10n.string(model.isLoading ? "Stop loading" : "Reload page"))
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel(MobileL10n.string("Back"))
                Spacer()
                Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel(MobileL10n.string("Forward"))
            }
        }
        .themedAlert(
            model.dialog?.title ?? MobileL10n.string("Website message"),
            message: model.dialog?.message ?? "",
            isPresented: Binding(
                get: { model.dialog != nil },
                set: { if !$0 { model.finishDialog(nil) } }
            ),
            textField: model.dialog?.isPrompt == true
                ? ThemedDialogTextField("Response", text: $model.dialogInput) : nil,
            actions: dialogActions
        )
    }

    private var dialogActions: [ThemedDialogAction] {
        guard let dialog = model.dialog else { return [] }
        let accept = ThemedDialogAction("OK") {
            model.finishDialog(model.dialogInput, id: dialog.id)
        }
        return dialog.canCancel
            ? [ThemedDialogAction("Cancel", role: .cancel) { model.finishDialog(nil, id: dialog.id) }, accept]
            : [accept]
    }
}

/// Safari owns public-site navigation, authentication and browser chrome.
private struct MobileSystemBrowser: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onClose: { dismiss() }) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onClose() }
    }
}

private struct MobileBrowserPage: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class MobileBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var publicURL: URL?
    @Published private(set) var error: String?
    @Published private(set) var displayAddress = ""
    @Published private(set) var isLocal = false
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var dialog: WebsiteDialog?
    @Published var dialogInput = ""
    private let client: RemoteClient
    private let sessionID: String
    private let tabID: String
    private let loadsRemotely: Bool
    private var proxy: MobileBrowserProxy?
    private var lease: RemoteBrowserTunnelDTO?
    private var localOrigin: RemoteBrowserLocalOrigin?
    private var observations: [NSKeyValueObservation] = []
    private var generation = 0
    private var expiryTask: Task<Void, Never>?

    init(client: RemoteClient, sessionID: String, tabID: String, loadsRemotely: Bool = true) {
        self.client = client
        self.sessionID = sessionID
        self.tabID = tabID
        self.loadsRemotely = loadsRemotely
    }

    func open() async {
        close()
        let attempt = generation
        error = nil
        do {
            #if DEBUG
            if !loadsRemotely {
                let url = URL(string: "https://preview.example/")!
                let browser = makeBrowser(configuration: WKWebViewConfiguration())
                isLocal = true
                displayAddress = url.absoluteString
                browser.loadHTMLString(Self.evidenceHTML, baseURL: url)
                return
            }
            #endif
            var url = try await client.browserLink(sessionID: sessionID, tabID: tabID)
            guard attempt == generation, !Task.isCancelled else { return }
            let configuration = WKWebViewConfiguration()
            if let host = url.host, RemoteBrowserLocalOrigin.isLoopback(host) {
                guard let expectedOrigin = RemoteBrowserLocalOrigin(url: url) else { throw RemoteClientError.invalidResponse }
                guard client.endpointKind != .relay else {
                    error = MobileL10n.string("Local previews need a direct connection to your Mac. Connect using Threading Direct, Wi-Fi, or Tailscale.")
                    return
                }
                let lease = try await client.browserTunnel(sessionID: sessionID, tabID: tabID, origin: expectedOrigin)
                guard attempt == generation, !Task.isCancelled else {
                    release(lease); return
                }
                self.lease = lease
                expiryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, lease.expiresAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self else { return }
                    self.close()
                    self.error = MobileL10n.string("This local preview expired. Open it again to reconnect to your Mac.")
                }
                guard let origin = RemoteBrowserLocalOrigin(url: lease.url) else {
                    throw RemoteClientError.invalidResponse
                }
                localOrigin = origin
                url = lease.url
                let proxy = MobileBrowserProxy(upstreamURL: client.link.baseURL)
                self.proxy = proxy
                let port = try await proxy.start()
                guard attempt == generation, !Task.isCancelled else { proxy.stop(); return }
                configuration.websiteDataStore = try Self.previewDataStore(
                    origin: origin, proxyPort: port, token: lease.token
                )
            } else {
                publicURL = url
                return
            }
            isLocal = localOrigin != nil
            displayAddress = Self.displayAddress(url)
            makeBrowser(configuration: configuration).load(URLRequest(url: url))
        } catch {
            guard attempt == generation, !Task.isCancelled else { return }
            close()
            self.error = error.localizedDescription
        }
    }

    func close() {
        generation += 1
        expiryTask?.cancel()
        expiryTask = nil
        finishDialog(nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        publicURL = nil
        observations.removeAll()
        proxy?.stop()
        proxy = nil
        if let lease { release(lease) }
        lease = nil
        localOrigin = nil
        isLocal = false
        isLoading = false
        canGoBack = false
        canGoForward = false
    }

    private func release(_ lease: RemoteBrowserTunnelDTO) {
        Task { try? await client.closeBrowserTunnel(sessionID: sessionID, tabID: tabID, token: lease.token) }
    }

    static func previewDataStore(origin: RemoteBrowserLocalOrigin, proxyPort: UInt16, token: String) throws -> WKWebsiteDataStore {
        guard let port = NWEndpoint.Port(rawValue: proxyPort) else { throw RemoteClientError.invalidResponse }
        var settings = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        settings.matchDomains = [origin.host]
        settings.allowFailover = false
        settings.applyCredential(username: "threading-preview", password: token)
        // Localhost logins must never leak between separately paired Macs.
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [settings]
        return store
    }

    private func makeBrowser(configuration: WKWebViewConfiguration) -> WKWebView {
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        observations = [
            browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            browser.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            browser.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            browser.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
        ]
        webView = browser
        return browser
    }

    private func refreshState() {
        isLoading = webView?.isLoading ?? false
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        if let url = webView?.url { displayAddress = Self.displayAddress(url) }
    }

    static func displayAddress(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.host ?? ""
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.absoluteString == "about:blank" { return .allow }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .cancel }
        if let host = url.host, RemoteBrowserLocalOrigin.isLoopback(host),
           RemoteBrowserLocalOrigin(url: url) != localOrigin {
            error = MobileL10n.string("This local address is not part of the open preview. Open its tab from Follow Mac.")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = MobileL10n.string("The browser stopped. Try opening the page again.")
    }

    struct WebsiteDialog {
        let id = UUID()
        let title: String
        let message: String
        let canCancel: Bool
        let isPrompt: Bool
        let finish: (String?) -> Void
    }

    func finishDialog(_ answer: String?, id: UUID? = nil) {
        guard let dialog, id == nil || id == dialog.id else { return }
        self.dialog = nil
        dialog.finish(answer)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await websiteDialog(message, frame: frame, canCancel: false)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await websiteDialog(message, frame: frame, canCancel: true) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await websiteDialog(prompt, frame: frame, canCancel: true, defaultText: defaultText ?? "", isPrompt: true)
    }

    private func websiteDialog(_ message: String, frame: WKFrameInfo, canCancel: Bool,
                               defaultText: String = "", isPrompt: Bool = false) async -> String? {
        finishDialog(nil)
        dialogInput = defaultText
        return await withCheckedContinuation { continuation in
            dialog = WebsiteDialog(
                title: frame.securityOrigin.host,
                message: String(message.prefix(8_192)), canCancel: canCancel, isPrompt: isPrompt,
                finish: { continuation.resume(returning: $0) }
            )
        }
    }

    #if DEBUG
    static let evidenceHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px -apple-system;margin:0;background:#f4f7f9;color:#102e3e}header{padding:32px 24px;background:#166b76;color:white}main{padding:24px}button,input{font:inherit;padding:12px;border:1px solid #789;border-radius:8px}button{background:#166b76;color:white}article{padding:20px;background:white;border-radius:12px;margin:20px 0}a{color:#166b76}</style>
    </head><body><header><p>LOCAL DEVELOPMENT</p><h1>A live page on your iPhone</h1></header><main>
    <p>Scroll, follow links, and try the controls. This page runs in the phone’s browser.</p>
    <article><label for="name">Preview name</label><p><input id="name" placeholder="Type here"></p>
    <button id="increment" onclick="document.getElementById('count').textContent=++window.count">Try interaction</button>
    <p>Interactions: <strong id="count">0</strong></p></article><a href="#details">Jump to details</a>
    <article style="margin-top:500px" id="details"><h2>Details</h2><p>Your Mac’s tab stays where it was.</p></article>
    </main><script>window.count=0</script></body></html>
    """
    #endif
}
