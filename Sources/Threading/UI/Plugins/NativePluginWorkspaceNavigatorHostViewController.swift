import AppKit
import ThreadingPluginKit

/// Hosts one native plugin navigator after its statically discovered route crosses the ordinary
/// signature and approval boundary.
///
/// The plugin owns the interior view. Threading retains the context, authors every update, checks
/// every activation/mutation again, owns theme delivery, and falls back to its own navigator if
/// the selected build or capability is unavailable.
@MainActor
final class NativePluginWorkspaceNavigatorHostViewController: NSViewController {
    typealias LoadPlugin =
        (NativeWorkspaceNavigatorDescriptor) -> Result<ThreadingNativePlugin, PluginLoadFailure>

    let descriptor: NativeWorkspaceNavigatorDescriptor
    private(set) var loaded: ThreadingNativePlugin?
    private(set) var refusal: PluginLoadFailure?

    private let context: PluginWorkspaceNavigatorContext
    private let loadPlugin: LoadPlugin?
    private let onUnavailable: (PluginLoadFailure) -> Void
    private let appEvents = AppEventObservations()
    private var loadTask: Task<Void, Never>?
    private var hasReportedUnavailable = false
    private lazy var toasts = ToastPresenter(host: view, above: view.bottomAnchor)

    init(
        descriptor: NativeWorkspaceNavigatorDescriptor,
        initialSnapshot: PluginWorkspaceSnapshot,
        activate: @escaping (PluginWorkspaceItemIdentity) -> Bool,
        perform: @escaping (PluginWorkspaceAction, PluginWorkspaceItemIdentity) -> Bool,
        loadPlugin: LoadPlugin? = nil,
        onUnavailable: @escaping (PluginLoadFailure) -> Void
    ) {
        self.descriptor = descriptor
        context = PluginWorkspaceNavigatorContext(
            navigatorIdentifier: descriptor.navigatorID,
            initialSnapshot: initialSnapshot,
            activate: activate,
            perform: perform
        )
        self.loadPlugin = loadPlugin
        self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let plugin = self?.loaded else { return }
            plugin.apply(theme: NativePluginCatalog.theme())
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        MainActor.assumeIsolated { context.stopObservingUpdates() }
    }

    override func loadView() {
        view = NSView()
        beginLoading()
    }

    func receive(_ update: PluginWorkspaceUpdate) {
        context.receiveHostUpdate(update)
    }

    func presentToast(_ toast: ToastRequest) {
        toasts.present(toast)
    }

    func takePresentedToastsForTransfer() -> [ToastRequest] {
        toasts.takeRequestsForTransfer()
    }

    private func beginLoading() {
        if let loadPlugin {
            finish(loadPlugin(descriptor))
            return
        }

        if let identity = descriptor.verifiedInstalledIdentity,
           let cached = NativePluginCatalog.cachedInstalledCandidate(identity: identity) {
            finish(NativePluginCatalog.load(
                cached,
                expectedInstalledIdentity: identity
            ))
            return
        }

        let descriptor = descriptor
        loadTask = Task { [weak self] in
            let verification = await Task.detached(priority: .userInitiated) {
                NativePluginCatalog.verify(
                    descriptor.bundleURL,
                    isBundled: descriptor.isBundled
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            switch verification {
            case .failure(let failure):
                finish(.failure(failure))
            case .success(let candidate):
                finish(NativePluginCatalog.load(
                    candidate,
                    expectedInstalledIdentity: descriptor.verifiedInstalledIdentity
                ))
            }
        }
    }

    private func finish(_ result: Result<ThreadingNativePlugin, PluginLoadFailure>) {
        loadTask = nil
        switch result {
        case .failure(let failure):
            refuse(failure)
        case .success(let plugin):
            guard plugin.pluginIdentifier == descriptor.pluginIdentifier else {
                refuse(.capabilityUnavailable(name: "declared navigator identity"))
                return
            }
            guard let navigator = plugin.makeWorkspaceNavigatorView?(
                identifier: descriptor.navigatorID,
                context: context
            ) else {
                refuse(.capabilityUnavailable(name: "workspace navigator"))
                return
            }
            loaded = plugin
            refusal = nil
            install(navigator)
            // Initial application belongs to the host, exactly as it does for pane presentations.
            plugin.apply(theme: NativePluginCatalog.theme())
        }
    }

    private func refuse(_ failure: PluginLoadFailure) {
        loaded = nil
        refusal = failure
        guard !hasReportedUnavailable else { return }
        hasReportedUnavailable = true
        // `loadView` can finish synchronously for a bundled plugin while the container is midway
        // through adopting this controller. Report on the next main turn so failback cannot be
        // overwritten by the outer `show` call completing afterwards.
        Task { @MainActor [weak self] in self?.onUnavailable(failure) }
    }

    private func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
