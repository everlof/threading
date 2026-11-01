import SwiftUI
import ThreadingRemoteKit
import UIKit
import WebKit

// MARK: - Presenter

/// Owns the stage while it is on screen: its own window above everything the app shows, so the
/// screen beneath — a sheet, a chat, a half-written draft — is exactly where it was on exit.
@MainActor
final class MobileMirrorStagePresenter {
    var onEnd: (() -> Void)?
    var onTouching: ((Bool) -> Void)?
    var onDismissed: (() -> Void)?
    var macName: String {
        get { model.macName }
        set { model.macName = newValue }
    }

    private let model: MobileMirrorStageModel
    private let guide: MobileMirrorGuideStore
    private var window: MobileMirrorStageWindow?
    private var controller: MobileMirrorStageViewController?
    private var standbyTask: Task<Void, Never>?
    private var endedTask: Task<Void, Never>?

    init(macName: String, guide: MobileMirrorGuideStore) {
        model = MobileMirrorStageModel(macName: macName)
        self.guide = guide
        model.onEnd = { [weak self] in self?.onEnd?() }
        model.onGuideFinished = { guide.completeGuide() }
    }

    func present() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let controller = MobileMirrorStageViewController(model: model)
        let window = MobileMirrorStageWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = controller
        window.backgroundColor = .black
        // Media chrome over arbitrary pages: dark whatever the system appearance.
        window.overrideUserInterfaceStyle = .dark
        window.alpha = 0
        window.onTouching = { [weak self] touching in
            self?.onTouching?(touching)
            self?.noteActivity()
        }
        self.window = window
        self.controller = controller
        window.makeKeyAndVisible()
        UIApplication.shared.isIdleTimerDisabled = true
        UIView.animate(withDuration: 0.25) { window.alpha = 1 }
        noteActivity()
    }

    func showConnecting(sourceTitle: String?) {
        endedTask?.cancel()
        model.sourceTitle = sourceTitle
        model.phase = .connecting
        model.showPill(reminder: false, dwells: false)
    }

    func apply(_ state: RemoteMirrorStateDTO, client: RemoteClient?, isNewMirror: Bool, reloads: Bool) {
        endedTask?.cancel()
        let isFirstContent = model.phase != .live || isNewMirror
        model.sourceTitle = state.sourceTitle
        model.revision = state.mirrorRevision
        model.mode = state.mode
        noteActivity()
        guard reloads || isFirstContent else { return }
        controller?.webStage.load(
            state.render,
            revision: state.mirrorRevision,
            client: client
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .shown:
                guard isFirstContent else { return }
                self.model.phase = .live
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                if !self.guide.hasCompletedGuide {
                    self.model.guide = .gesture
                    self.model.hidePill()
                } else {
                    self.model.showPill(reminder: self.guide.takeGestureReminder(), dwells: true)
                }
            case let .failed(message):
                if self.model.phase != .live { self.model.phase = .failed(message) }
            }
        }
    }

    #if DEBUG
    /// A demo fixture: the stage over a local prototype page, without a Mac.
    func showDemo(title: String, step: MobileMirrorStageModel.GuideStep?) {
        model.sourceTitle = title
        model.revision = 15
        controller?.webStage.loadDemo { [weak self] in
            guard let self else { return }
            self.model.phase = .live
            if !self.guide.hasCompletedGuide {
                self.model.guide = .gesture
                self.model.hidePill()
                if step == .controls { self.model.revealControls() }
            } else {
                self.model.showPill(reminder: true, dwells: false)
            }
        }
    }
    #endif

    /// Says why the stage is closing, for a moment, then closes it.
    func showEnded(_ message: String) {
        model.phase = .ended(message)
        model.showsControls = false
        model.guide = nil
        endedTask?.cancel()
        endedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        endedTask?.cancel()
        standbyTask?.cancel()
        guard let window else {
            onDismissed?()
            return
        }
        self.window = nil
        controller?.webStage.tearDown()
        controller = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }, completion: { _ in
            window.isHidden = true
            MobileInteractionMonitor.shared.appWindow?.makeKey()
        })
        onDismissed?()
    }

    /// A touch or a revision keeps the stage awake; fifteen quiet minutes dim it to standby and
    /// give the screen back its idle timer.
    private func noteActivity() {
        if model.isStandby {
            model.isStandby = false
            UIApplication.shared.isIdleTimerDisabled = true
        }
        standbyTask?.cancel()
        standbyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MobileMirrorDefaults.standbyAfter))
            guard !Task.isCancelled, let self else { return }
            self.model.isStandby = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

/// The stage's window reports whether a finger is on it, for the Mac's *Interacting*.
final class MobileMirrorStageWindow: UIWindow {
    var onTouching: ((Bool) -> Void)?
    private var isTouching = false

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        guard event.type == .touches, let touches = event.allTouches else { return }
        let touching = touches.contains { $0.phase != .ended && $0.phase != .cancelled }
        guard touching != isTouching else { return }
        isTouching = touching
        MainActor.assumeIsolated { onTouching?(touching) }
    }
}

// MARK: - State

@MainActor
final class MobileMirrorStageModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
        case ended(String)
    }

    enum GuideStep: Equatable {
        /// Hold two fingers: advances only when the person does it.
        case gesture
        /// The real capsule, with three numbered callouts.
        case controls
    }

    @Published var macName: String
    @Published var sourceTitle: String?
    @Published var revision: UInt64 = 0
    @Published var phase: Phase = .connecting
    @Published var isShowingPill = false
    @Published var pillReminds = false
    @Published var showsControls = false
    @Published var guide: GuideStep?
    @Published var mode: RemoteMirrorMode = .interactive
    @Published var isRotationLocked = false
    @Published var isStandby = false

    var onEnd: (() -> Void)?
    var onReload: (() -> Void)?
    var onRotationLockChanged: ((Bool) -> Void)?
    var onGuideFinished: (() -> Void)?
    private var pillTask: Task<Void, Never>?
    private var controlsTask: Task<Void, Never>?

    init(macName: String) {
        self.macName = macName
    }

    func showPill(reminder: Bool, dwells: Bool) {
        pillReminds = reminder
        isShowingPill = true
        pillTask?.cancel()
        guard dwells else { return }
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MobileMirrorDefaults.pillDwell + (reminder ? 1.2 : 0)))
            guard !Task.isCancelled else { return }
            self?.isShowingPill = false
        }
    }

    func hidePill() {
        pillTask?.cancel()
        isShowingPill = false
    }

    /// The two-finger hold, the VoiceOver escape, or a tap in view-only mode.
    func revealControls() {
        if guide == .gesture { guide = .controls }
        showsControls = true
        hidePill()
        scheduleControlsHide()
    }

    func toggleControls() {
        if showsControls, guide == nil {
            showsControls = false
        } else {
            revealControls()
        }
    }

    /// Any touch on the capsule keeps it up for another dwell.
    func scheduleControlsHide() {
        controlsTask?.cancel()
        guard guide == nil else { return }
        controlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MobileMirrorDefaults.controlsDwell))
            guard !Task.isCancelled, let self, self.guide == nil else { return }
            self.showsControls = false
        }
    }

    func finishGuide() {
        guide = nil
        onGuideFinished?()
        showsControls = false
    }

    func replayGuide() {
        showsControls = false
        guide = .gesture
    }

    func toggleMode() {
        mode = mode == .viewOnly ? .interactive : .viewOnly
        scheduleControlsHide()
    }

    func toggleRotationLock() {
        isRotationLocked.toggle()
        onRotationLockChanged?(isRotationLocked)
        scheduleControlsHide()
    }

    func reload() {
        onReload?()
        scheduleControlsHide()
    }

    func end() {
        showsControls = false
        onEnd?()
    }
}

// MARK: - Controller

/// The stage itself: the page, edge to edge, with nothing of the phone's own chrome over it.
final class MobileMirrorStageViewController: UIViewController, UIGestureRecognizerDelegate {
    let webStage = MobileMirrorWebStage()
    private let model: MobileMirrorStageModel
    private let viewOnlyShield = UIView()
    private let overlayHost = MobileMirrorPassthroughView()
    private var overlay: UIHostingController<MobileMirrorStageOverlay>?
    private var lockedOrientation: UIInterfaceOrientationMask?
    private var observation: Any?

    init(model: MobileMirrorStageModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        lockedOrientation ?? .allButUpsideDown
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for subview in [webStage, viewOnlyShield, overlayHost] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: view.topAnchor),
                subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        viewOnlyShield.backgroundColor = .clear
        viewOnlyShield.isHidden = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(viewOnlyTap))
        viewOnlyShield.addGestureRecognizer(tap)

        let overlay = UIHostingController(rootView: MobileMirrorStageOverlay(model: model))
        overlay.view.backgroundColor = .clear
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(overlay)
        overlayHost.addSubview(overlay.view)
        overlayHost.hostedView = overlay.view
        NSLayoutConstraint.activate([
            overlay.view.topAnchor.constraint(equalTo: overlayHost.topAnchor),
            overlay.view.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
            overlay.view.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
            overlay.view.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
        ])
        overlay.didMove(toParent: self)
        self.overlay = overlay

        // Two fingers held still: no prototype and no forwarded single-contact input uses it.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(twoFingerHold(_:)))
        hold.numberOfTouchesRequired = 2
        hold.minimumPressDuration = MobileMirrorDefaults.controlsHoldDuration
        hold.allowableMovement = MobileMirrorDefaults.controlsHoldMovement
        hold.delegate = self
        view.addGestureRecognizer(hold)

        model.onReload = { [weak self] in self?.webStage.reload() }
        model.onRotationLockChanged = { [weak self] locked in self?.setRotationLocked(locked) }
        observation = model.$mode.sink { [weak self] mode in
            self?.viewOnlyShield.isHidden = mode != .viewOnly
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        model.revealControls()
        return true
    }

    @objc private func twoFingerHold(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        model.revealControls()
    }

    @objc private func viewOnlyTap() {
        model.toggleControls()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func setRotationLocked(_ locked: Bool) {
        if locked {
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            lockedOrientation = switch orientation {
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: .portrait
            }
        } else {
            lockedOrientation = nil
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Passes a touch through wherever the overlay draws nothing, so the page under it stays live.
final class MobileMirrorPassthroughView: UIView {
    weak var hostedView: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === hostedView ? nil : hit
    }
}

// MARK: - Web stage

/// The page, rendered by the phone's own WebKit because the phone is the target.
///
/// Two web views at most. A revision loads into the one behind, waits until it has drawn, puts
/// the reader back where they were and fades the old one away, so the visible page never blanks
/// and never jumps.
final class MobileMirrorWebStage: UIView, WKNavigationDelegate {
    enum LoadResult {
        case shown
        case failed(String)
    }

    private struct Tunnel {
        let lease: RemoteBrowserTunnelDTO
        let originKey: String
        let sessionID: String
        let tabID: String
        let store: WKWebsiteDataStore
    }

    private var visible: WKWebView?
    private var incoming: WKWebView?
    private var pending: ((LoadResult) -> Void)?
    private var generation = 0
    private var publicStore: WKWebsiteDataStore?
    private var tunnel: Tunnel?
    private var proxy: MobileBrowserProxy?
    private var proxyUpstream: URL?
    private var client: RemoteClient?
    private var currentURL: URL?

    func load(
        _ render: RemoteMirrorRenderDTO,
        revision: UInt64,
        client: RemoteClient?,
        completion: @escaping (LoadResult) -> Void
    ) {
        generation += 1
        let attempt = generation
        self.client = client ?? self.client
        guard render.kind == .web,
              let url = URL(string: render.url),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            completion(.failed(MobileL10n.string("This page cannot be shown on iPhone.")))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await self.store(for: url, render: render)
                guard attempt == self.generation else { return }
                self.startLoad(url, store: store, completion: completion)
            } catch let error as MobileMirrorStageError {
                guard attempt == self.generation else { return }
                completion(.failed(error.message))
            } catch {
                guard attempt == self.generation else { return }
                completion(.failed(error.localizedDescription))
            }
        }
    }

    #if DEBUG
    func loadDemo(_ shown: @escaping () -> Void) {
        generation += 1
        startLoad(
            URL(string: "https://festina-prototype.example/")!,
            store: .nonPersistent(),
            html: Self.demoPage
        ) { _ in shown() }
    }

    private static let demoPage = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        body{margin:0;background:#f5efe6;color:#2b2118;font:17px -apple-system,sans-serif}
        nav{display:flex;justify-content:space-between;align-items:center;padding:64px 22px 12px}
        nav b{font-size:24px;letter-spacing:-.02em}nav i{width:24px;height:14px;border-top:3px solid;border-bottom:3px solid}
        .hero{margin:8px 16px 16px;height:320px;border-radius:24px;position:relative;
          background:linear-gradient(150deg,#e7a06f,#c8553d 55%,#6b2e2a)}
        .hero h1{position:absolute;left:22px;bottom:64px;margin:0;color:#fff;font-size:34px;line-height:1.05}
        .hero span{position:absolute;left:22px;bottom:22px;color:#fff;background:rgba(255,255,255,.22);
          padding:6px 14px;border-radius:99px;font-size:15px}
        .item{margin:0 16px 12px;height:76px;border-radius:18px;background:#fff;display:flex;align-items:center;gap:14px;padding:0 14px}
        .item s{width:46px;height:46px;border-radius:12px;background:#efe4d6;display:block}
        .item u{display:block;height:11px;width:150px;border-radius:6px;background:#e2d6c6}
        .item u+u{width:90px;margin-top:8px;background:#eee5da}
        </style></head><body>
        <nav><b>Festina</b><i></i></nav>
        <div class="hero"><h1>Kvällar<br>värda att minnas</h1><span>Boka bord</span></div>
        <div class="item"><s></s><div><u></u><u></u></div></div>
        <div class="item"><s></s><div><u></u><u></u></div></div>
        <div class="item"><s></s><div><u></u><u></u></div></div>
        <div class="item"><s></s><div><u></u><u></u></div></div>
        </body></html>
        """
    #endif

    /// **Reload** in the controls: the same page, through the same fluent swap.
    func reload() {
        guard let url = currentURL, let store = visible?.configuration.websiteDataStore else { return }
        generation += 1
        startLoad(url, store: store) { _ in }
    }

    func tearDown() {
        generation += 1
        for webView in [visible, incoming].compactMap({ $0 }) {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
        }
        visible = nil
        incoming = nil
        pending = nil
        proxy?.stop()
        proxy = nil
        if let tunnel, let client {
            let lease = tunnel.lease
            Task { try? await client.closeBrowserTunnel(sessionID: tunnel.sessionID, tabID: tunnel.tabID, token: lease.token) }
        }
        tunnel = nil
    }

    // MARK: Data stores

    private func store(for url: URL, render: RemoteMirrorRenderDTO) async throws -> WKWebsiteDataStore {
        guard let host = url.host, RemoteBrowserLocalOrigin.isLoopback(host) else {
            if let publicStore { return publicStore }
            // One non-persistent store per mirror: no Mac cookie or credential ever reaches it.
            let store = WKWebsiteDataStore.nonPersistent()
            publicStore = store
            return store
        }
        guard let origin = RemoteBrowserLocalOrigin(url: url) else { throw MobileMirrorStageError.unavailable }
        guard let client else { throw MobileMirrorStageError.unavailable }
        guard client.endpointKind != .relay else { throw MobileMirrorStageError.needsDirectConnection }
        if let tunnel, tunnel.originKey == origin.key,
           tunnel.sessionID == render.sessionID, tunnel.tabID == render.browserTabID,
           tunnel.lease.expiresAt.timeIntervalSinceNow > MobileMirrorDefaults.tunnelRenewalMargin {
            return tunnel.store
        }
        let lease = try await client.browserTunnel(sessionID: render.sessionID, tabID: render.browserTabID, origin: origin)
        if proxy == nil || proxyUpstream != client.link.baseURL {
            proxy?.stop()
            let proxy = MobileBrowserProxy(upstreamURL: client.link.baseURL)
            self.proxy = proxy
            proxyUpstream = client.link.baseURL
        }
        guard let proxy else { throw MobileMirrorStageError.unavailable }
        let port = try await proxy.start()
        let store = try MobileBrowserModel.previewDataStore(origin: origin, proxyPort: port, token: lease.token)
        if let previous = tunnel {
            let token = previous.lease.token
            Task { try? await client.closeBrowserTunnel(sessionID: previous.sessionID, tabID: previous.tabID, token: token) }
        }
        tunnel = Tunnel(
            lease: lease, originKey: origin.key,
            sessionID: render.sessionID, tabID: render.browserTabID, store: store
        )
        return store
    }

    // MARK: Loading and the swap

    private func startLoad(
        _ url: URL,
        store: WKWebsiteDataStore,
        html: String? = nil,
        completion: @escaping (LoadResult) -> Void
    ) {
        if let incoming {
            incoming.stopLoading()
            incoming.navigationDelegate = nil
            incoming.removeFromSuperview()
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        // Behind the visible page, fully drawn before it is seen.
        if let visible {
            insertSubview(webView, belowSubview: visible)
        } else {
            webView.alpha = 0
            addSubview(webView)
        }
        incoming = webView
        pending = completion
        currentURL = url
        if let html {
            webView.loadHTMLString(html, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === incoming else { return }
        let attempt = generation
        Task { [weak self] in
            guard let self else { return }
            let anchor = await self.captureAnchor(matching: webView.url)
            await Self.waitUntilDrawn(webView)
            if let anchor { await Self.restore(anchor, in: webView) }
            guard attempt == self.generation, webView === self.incoming else { return }
            self.swap(to: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === visible { reload() }
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        guard webView === incoming else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        incoming = nil
        pending?(.failed(error.localizedDescription))
        pending = nil
    }

    private func swap(to webView: WKWebView) {
        let old = visible
        visible = webView
        incoming = nil
        let completion = pending
        pending = nil
        if let old {
            bringSubviewToFront(old)
            UIView.animate(withDuration: MobileMirrorDefaults.swapFade, animations: { old.alpha = 0 }, completion: { _ in
                old.stopLoading()
                old.navigationDelegate = nil
                old.removeFromSuperview()
            })
        } else {
            UIView.animate(withDuration: 0.25) { webView.alpha = 1 }
        }
        completion?(.shown)
    }

    // MARK: Scroll anchor

    /// The element at the top of the viewport and its offset, so a new revision of the same page
    /// opens where the reader was. Only for the same address: a navigation starts at the top.
    private func captureAnchor(matching url: URL?) async -> [String: Any]? {
        guard let visible, let url, let shown = visible.url,
              Self.sameDocument(shown, url) else { return nil }
        let result = try? await visible.callAsyncJavaScript(
            Self.captureScript, arguments: [:], in: nil, contentWorld: .defaultClient
        )
        return result as? [String: Any]
    }

    private static func restore(_ anchor: [String: Any], in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            restoreScript, arguments: ["anchor": anchor], in: nil, contentWorld: .defaultClient
        )
    }

    /// Fonts loaded and two animation frames drawn, or a short bound for a page that never says.
    private static func waitUntilDrawn(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            readinessScript, arguments: [:], in: nil, contentWorld: .defaultClient
        )
    }

    private static func sameDocument(_ lhs: URL, _ rhs: URL) -> Bool {
        var left = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
        var right = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        left?.fragment = nil
        right?.fragment = nil
        return left?.url == right?.url
    }

    private static let readinessScript = """
        const ready = (async () => {
          if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
          await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        })();
        await Promise.race([ready, new Promise(r => setTimeout(r, 1500))]);
        return true;
        """

    private static let captureScript = """
        const element = document.elementFromPoint(innerWidth / 2, 2) || document.body;
        const path = (node) => {
          const parts = [];
          while (node && node.nodeType === 1 && node !== document.documentElement) {
            if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
            let index = 1, sibling = node;
            while ((sibling = sibling.previousElementSibling)) { if (sibling.tagName === node.tagName) index++; }
            parts.unshift(node.tagName.toLowerCase() + ':nth-of-type(' + index + ')');
            node = node.parentElement;
          }
          return parts.join('>');
        };
        const range = Math.max(1, document.documentElement.scrollHeight - innerHeight);
        return { path: path(element), offset: element.getBoundingClientRect().top, ratio: scrollY / range };
        """

    private static let restoreScript = """
        let element = null;
        try { element = anchor.path ? document.querySelector(anchor.path) : null; } catch (e) {}
        if (element) {
          scrollTo(0, scrollY + element.getBoundingClientRect().top - anchor.offset);
        } else {
          const range = Math.max(1, document.documentElement.scrollHeight - innerHeight);
          scrollTo(0, anchor.ratio * range);
        }
        return true;
        """
}

enum MobileMirrorStageError: Error {
    case unavailable
    case needsDirectConnection

    var message: String {
        switch self {
        case .unavailable:
            return MobileL10n.string("This page cannot be shown on iPhone.")
        case .needsDirectConnection:
            return MobileL10n.string("Local previews need a direct connection to your Mac. Connect using Threading Direct, Wi-Fi, or Tailscale.")
        }
    }
}
