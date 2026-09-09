import AppKit
import ThreadingPluginKit

/// Hosts one native plugin's view.
///
/// The host owns placement, lifetime, trust and the theme; the plugin owns everything inside the
/// rectangle it is given. That split is the whole tier, and it is the same one `.media` already
/// uses for content whose pixels move on their own.
///
/// A plugin that will not load is a *state*, not an absence: the pane says which refusal happened,
/// because "the plugin did not appear" is not a diagnosis and this is the one tier where the
/// operating system offers no error of its own.
@MainActor
final class NativePluginPaneViewController: NSViewController {

    typealias VerifyPlugin = @Sendable (URL) -> Result<
        NativePluginCatalog.VerifiedCandidate,
        PluginLoadFailure
    >

    private enum Metrics {
        static let messageWidth: CGFloat = 320
    }

    let bundleURL: URL
    let owningSessionID: SessionID?
    private(set) var loaded: ThreadingNativePlugin?
    private(set) var refusal: PluginLoadFailure?
    private let appEvents = AppEventObservations()
    private let loadPlugin: ((URL) -> Result<ThreadingNativePlugin, PluginLoadFailure>)?
    private let verifyPlugin: VerifyPlugin
    private var verifiedCandidate: NativePluginCatalog.VerifiedCandidate?
    private var loadTask: Task<Void, Never>?
    var onTitleChange: (() -> Void)?

    /// The plugin's own identity once it loads, so a crash-quarantine policy can name it rather
    /// than pointing at a path.
    var pluginIdentifier: String? { loaded?.pluginIdentifier }

    /// What the tab calls it. Verified bundle metadata replaces the filename once inspection
    /// finishes, so a refusal is still named without rereading a mutable install path on main.
    var displayName: String {
        verifiedCandidate?.bundle.displayName ?? L10n.string("Plugin")
    }

    struct ApprovalRequest: Equatable {
        let identity: PluginLoader.PluginIdentity
        let displayName: String
    }

    /// The identity and name are a pair from one verified build. Keeping this derivation separate
    /// also makes the replacement-between-verification-and-approval regression observable.
    var approvalRequest: ApprovalRequest? {
        guard let bundle = verifiedCandidate?.bundle,
              let identity = bundle.identity else { return nil }
        return ApprovalRequest(
            identity: identity,
            displayName: bundle.displayName
        )
    }

    /// Injected so a test can place a pane in a project without reaching the shared store, and
    /// defaulted so no call site has to care. `nil` from the closure means "not resolvable", which
    /// is a pane with no project rather than an error: a plugin that only draws needs neither.
    private let resolveStore: () -> ProjectStore?

    init(
        bundleURL: URL,
        owningSessionID: SessionID?,
        resolveStore: @escaping () -> ProjectStore? = { ProjectStore.shared },
        loadPlugin: ((URL) -> Result<ThreadingNativePlugin, PluginLoadFailure>)? = nil,
        verifyPlugin: @escaping VerifyPlugin = { url in
            NativePluginCatalog.verify(
                url,
                isBundled: NativePluginCatalog.isBundled(url)
            )
        }
    ) {
        self.bundleURL = bundleURL
        self.owningSessionID = owningSessionID
        self.resolveStore = resolveStore
        self.loadPlugin = loadPlugin
        self.verifyPlugin = verifyPlugin
        super.init(nibName: nil, bundle: nil)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let plugin = self?.loaded else { return }
            plugin.apply(theme: NativePluginCatalog.theme())
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        // The tools go with the pane: they act on a stream and a view that are about to be gone.
        MainActor.assumeIsolated { NativePluginRuntime.shared.deregister(self) }
    }

    override func loadView() {
        view = NSView()
        loadViewContents()
    }

    private func loadViewContents() {
        if let loadPlugin {
            finish(loadPlugin(bundleURL))
            return
        }
        if let verifiedCandidate {
            load(verifiedCandidate)
            return
        }

        let bundleURL = bundleURL
        let verifyPlugin = verifyPlugin
        loadTask = Task { [weak self] in
            let verification = await Task.detached(priority: .userInitiated) {
                verifyPlugin(bundleURL)
            }.value
            guard let self, !Task.isCancelled else { return }
            switch verification {
            case .failure(let failure):
                finish(.failure(failure))
            case .success(let candidate):
                load(candidate)
            }
        }
    }

    private func load(_ candidate: NativePluginCatalog.VerifiedCandidate) {
        let previousDisplayName = displayName
        let result = NativePluginCatalog.load(candidate)

        // Mapping reserves one canonical candidate for an installed identity. Reopened panes may
        // have verified a redundant staging copy before finding it; retain the canonical object
        // and let the redundant copy schedule its cleanup off-main. An unapproved candidate is
        // deliberately retained because its exact identity and name back the approval prompt.
        if !candidate.isBundled,
           let identity = candidate.bundle.identity,
           let canonical = NativePluginCatalog.cachedInstalledCandidate(identity: identity) {
            verifiedCandidate = canonical
        } else if candidate.isBundled || requiresApproval(result) {
            verifiedCandidate = candidate
        } else {
            verifiedCandidate = nil
        }
        if displayName != previousDisplayName { onTitleChange?() }
        finish(result)
    }

    private func requiresApproval(
        _ result: Result<ThreadingNativePlugin, PluginLoadFailure>
    ) -> Bool {
        guard case .failure(let failure) = result,
              case .notApproved = failure else { return false }
        return true
    }

    private func finish(_ result: Result<ThreadingNativePlugin, PluginLoadFailure>) {
        loadTask = nil
        switch result {
        case .success(let plugin):
            guard let pane = plugin.makePaneView?(context: context()) else {
                let failure = PluginLoadFailure.capabilityUnavailable(name: "pane")
                loaded = nil
                refusal = failure
                install(refusalView(failure))
                return
            }
            loaded = plugin
            refusal = nil
            NativePluginRuntime.shared.register(plugin, controller: self, sessionID: owningSessionID)
            install(pane)
            plugin.apply(theme: NativePluginCatalog.theme())
        case .failure(let failure):
            loaded = nil
            refusal = failure
            install(refusalView(failure))
        }
    }

    /// Rebuilds through the full loader boundary. Used after an approval and kept internal so a
    /// regression test can prove a successful retry replaces both the refusal view and its state.
    func reloadPresentation() {
        loadTask?.cancel()
        loadTask = nil
        NativePluginRuntime.shared.deregister(self)
        loaded = nil
        refusal = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        loadViewContents()
    }

    /// What the plugin is told. Narrow and versioned on purpose: never a session, a project, a
    /// store or a window. If a plugin needs to know something, it gets a name here first.
    ///
    /// The names live in `NativePluginPlacement` rather than being spelled here, so the host and a
    /// plugin author read them from one place.
    private func context() -> PluginContext {
        PluginContext(theme: NativePluginCatalog.theme(), arguments: placement().arguments)
    }

    /// Where the pane is, resolved from the session that owns it.
    ///
    /// The checkout comes from the session's *working* directory rather than its project's folder,
    /// because the two differ exactly when the session opted into a managed workspace. A plugin
    /// handed the project folder would read the wrong tree for every draft-worktree session, which
    /// presents as stale content rather than as a wrong path.
    private func placement() -> NativePluginPlacement {
        guard let owningSessionID else { return NativePluginPlacement() }
        let store = resolveStore()
        let project = store?.project(forSessionID: owningSessionID)
        return NativePluginPlacement(
            sessionID: owningSessionID,
            projectID: project?.id,
            projectName: project?.name,
            checkoutPath: store?.workingDirectory(forSessionID: owningSessionID)
        )
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

    private func refusalView(_ failure: PluginLoadFailure) -> NSView {
        let label = NSTextField(wrappingLabelWithString: L10n.format(
            "This plugin was not loaded: %@",
            failure.description
        ))
        label.alignment = .center
        label.textColor = Design.Text.secondary
        label.applyFont(.detail())
        label.preferredMaxLayoutWidth = Metrics.messageWidth

        let host = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.messageWidth),
        ])

        // A gate with nothing that opens it is a locked door. "Not approved" is the one refusal the
        // user can answer, so it is the one that comes with a way to answer it — here, where they
        // are already looking, rather than in a settings page they would have to be told about.
        if case .notApproved = failure {
            let allow = ThemedButton()
            allow.title = L10n.string("Allow This Plugin…")
            allow.emphasis = .primary
            allow.target = self
            allow.action = #selector(askAboutThisPlugin)
            allow.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(allow)
            NSLayoutConstraint.activate([
                allow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Design.Spacing.medium),
                allow.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            ])
        }
        return host
    }

    /// Asks, records, and reloads if the answer was yes.
    ///
    /// The question is asked against the *identity* the loader read, not the path: approving a
    /// plugin has to mean the bytes that were described, or an update inherits an answer nobody
    /// gave it.
    @objc private func askAboutThisPlugin() {
        // The default loading path already read and signature-validated this identity on its
        // worker. Never repeat Security-framework or bundle I/O from a button action on main.
        guard let request = approvalRequest else { return }
        NativePluginApprovalPrompt.ask(
            about: request.identity,
            named: request.displayName,
            in: view.window
        ) { [weak self] approved in
            guard let self, approved else { return }
            // Rebuild the pane the ordinary way rather than patching it: loading is what registers
            // the plugin's tools, and half-loading it would advertise tools nothing can run.
            self.reloadPresentation()
        }
    }
}
