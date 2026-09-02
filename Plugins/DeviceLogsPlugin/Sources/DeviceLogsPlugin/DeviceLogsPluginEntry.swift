import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// The bundle's principal class.
///
/// `@objc` with an explicit name because `NSBundle` matches the principal class through the
/// Objective-C runtime, and a Swift-mangled name is not what the Info.plist can spell.
@objc(DeviceLogsPlugin)
public final class DeviceLogsPlugin: NSObject, ThreadingNativePlugin {

    private var pane: DeviceLogPaneViewController?

    public override required init() { super.init() }

    public static var pluginAPIVersion: Int { ThreadingPluginAPI.version }

    public var pluginIdentifier: String { "codes.threading.plugin.devicelogs" }

    public func makePaneView(context: PluginContext) -> NSView {
        // The host builds panes on the main actor; the contract is `@objc` and so cannot say so.
        MainActor.assumeIsolated {
            let pane = DeviceLogPaneViewController(owningSessionID: context.argument("session"))
            apply(theme: context.theme)
            self.pane = pane
            return pane.view
        }
    }

    public func apply(theme: PluginTheme) {
        try? HostThemeHandoff.install(encoded: theme.encodedTheme)
        MainActor.assumeIsolated { pane?.view.needsDisplay = true }
    }
}
