import AppKit
import SwiftUI
import ThreadingPluginKit

/// A navigator-only native plugin. The host still owns discovery, approval, placement, theme,
/// workspace truth, and every mutation; this bundle owns the SwiftUI presentation inside its
/// assigned sidebar rectangle.
@MainActor
@objc(T3NavigatorPlugin)
public final class T3NavigatorPlugin: NSObject, ThreadingNativePlugin {
    private let themeState = T3NavigatorTheme()
    private var navigatorStore: T3NavigatorStore?

    public override required init() {
        super.init()
    }

    // This is the generation the bundle was compiled against, not the host's live value.
    public static let pluginAPIVersion = 4

    public var pluginIdentifier: String { "codes.threading.plugin.t3navigator" }

    public func makeWorkspaceNavigatorView(
        identifier: String,
        context: PluginWorkspaceNavigatorContext
    ) -> NSView {
        guard identifier == "t3-native" else {
            return NSHostingView(rootView: Text("Unknown navigator"))
        }
        let store = T3NavigatorStore(context: context)
        navigatorStore = store
        return NSHostingView(rootView: T3NavigatorView(store: store, theme: themeState))
    }

    public func apply(theme: PluginTheme) {
        themeState.apply(theme)
    }
}
