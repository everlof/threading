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

    private enum Metrics {
        static let messageWidth: CGFloat = 320
    }

    let bundleURL: URL
    let owningSessionID: SessionID?
    private(set) var loaded: ThreadingNativePlugin?
    private(set) var refusal: PluginLoadFailure?

    /// The plugin's own identity once it loads, so a crash-quarantine policy can name it rather
    /// than pointing at a path.
    var pluginIdentifier: String? { loaded?.pluginIdentifier }

    /// What the tab calls it. Read from the bundle rather than from the loaded plugin, so a
    /// refusal is still a named tab instead of an anonymous one.
    var displayName: String? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    /// Injected so a test can place a pane in a project without reaching the shared store, and
    /// defaulted so no call site has to care. `nil` from the closure means "not resolvable", which
    /// is a pane with no project rather than an error: a plugin that only draws needs neither.
    private let resolveStore: () -> ProjectStore?

    init(
        bundleURL: URL,
        owningSessionID: SessionID?,
        resolveStore: @escaping () -> ProjectStore? = { ProjectStore.shared }
    ) {
        self.bundleURL = bundleURL
        self.owningSessionID = owningSessionID
        self.resolveStore = resolveStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        // The tools go with the pane: they act on a stream and a view that are about to be gone.
        MainActor.assumeIsolated { NativePluginRuntime.shared.deregister(self) }
    }

    override func loadView() {
        view = NSView()
        loadViewContents()
    }

    private func loadViewContents() {
        switch NativePluginCatalog.load(bundleURL) {
        case .success(let plugin):
            loaded = plugin
            NativePluginRuntime.shared.register(plugin, controller: self, sessionID: owningSessionID)
            install(plugin.makePaneView(context: context()))
        case .failure(let failure):
            refusal = failure
            install(refusalView(failure))
        }
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
        guard let identity = try? PluginLoader.identity(of: bundleURL) else {
            return
        }
        NativePluginApprovalPrompt.ask(
            about: identity,
            named: displayName ?? identity.bundleIdentifier,
            in: view.window
        ) { [weak self] approved in
            guard let self, approved else { return }
            // Rebuild the pane the ordinary way rather than patching it: loading is what registers
            // the plugin's tools, and half-loading it would advertise tools nothing can run.
            self.view.subviews.forEach { $0.removeFromSuperview() }
            self.loadViewContents()
        }
    }
}
