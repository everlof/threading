import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// A navigator-only native plugin. The host still owns discovery, approval, placement, theme,
/// workspace truth, and every mutation; this bundle owns the presentation inside its assigned
/// sidebar rectangle and builds it from Threading's public design-system components.
@MainActor
@objc(T3NavigatorPlugin)
public final class T3NavigatorPlugin: NSObject, ThreadingNativePlugin {
    private var navigatorStore: T3NavigatorStore?
    private weak var navigatorView: T3NavigatorView?

    public override required init() {
        super.init()
    }

    // This is the generation the bundle was compiled against, not the host's live value.
    public static let pluginAPIVersion = 5

    public var pluginIdentifier: String { "codes.threading.plugin.t3navigator" }

    public func makeWorkspaceNavigatorView(
        identifier: String,
        context: PluginWorkspaceNavigatorContext
    ) -> NSView {
        guard identifier == "t3-native" else {
            let label = NSTextField(labelWithString: "Unknown navigator")
            label.applyFont(.body)
            label.textColor = Design.Text.label
            return label
        }
        let store = T3NavigatorStore(context: context)
        let view = T3NavigatorView(store: store)
        navigatorStore = store
        navigatorView = view
        return view
    }

    public func apply(theme: PluginTheme) {
        // The seven PluginTheme tokens remain the no-dependency floor. This bundled proof uses
        // the full handoff so every DesignKit component resolves the host's exact palette,
        // typography, radii, bevels and interaction material on each live theme change.
        _ = try? HostThemeHandoff.install(encoded: theme.encodedTheme)
        if let navigatorView {
            AppThemeRefresh.repaint(navigatorView)
        }
    }
}
