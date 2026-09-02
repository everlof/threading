import AppKit
import ThreadingPluginKit

/// The bundle's principal class.
///
/// `@objc` with an explicit name because `NSBundle` matches the principal class through the
/// Objective-C runtime, and a Swift-mangled name is not what the Info.plist can spell.
@objc(DeviceLogsPlugin)
public final class DeviceLogsPlugin: NSObject, ThreadingNativePlugin {

    private var pane: DeviceLogsPane?

    public override required init() { super.init() }

    public static var pluginAPIVersion: Int { ThreadingPluginAPI.version }

    public var pluginIdentifier: String { "codes.threading.plugin.devicelogs" }

    public func makePaneView(context: PluginContext) -> NSView {
        let pane = DeviceLogsPane(frame: .zero)
        pane.apply(context.theme)
        self.pane = pane
        return pane
    }

    public func apply(theme: PluginTheme) {
        pane?.apply(theme)
    }
}
