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

    init(bundleURL: URL, owningSessionID: SessionID?) {
        self.bundleURL = bundleURL
        self.owningSessionID = owningSessionID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        switch NativePluginCatalog.load(bundleURL) {
        case .success(let plugin):
            loaded = plugin
            install(plugin.makePaneView(context: context()))
        case .failure(let failure):
            refusal = failure
            install(refusalView(failure))
        }
    }

    /// What the plugin is told. Narrow and versioned on purpose: never a session, a project, a
    /// store or a window. If a plugin needs to know something, it gets a name here first.
    private func context() -> PluginContext {
        var arguments: [String: String] = [:]
        if let owningSessionID { arguments["sessionID"] = owningSessionID.rawValue.uuidString }
        return PluginContext(theme: NativePluginCatalog.theme(), arguments: arguments)
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
        label.font = Design.Typography.detail()
        label.preferredMaxLayoutWidth = Metrics.messageWidth

        let host = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.messageWidth),
        ])
        return host
    }
}
