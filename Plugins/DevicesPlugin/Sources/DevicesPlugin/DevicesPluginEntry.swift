import Foundation
import ThreadingPluginKit

/// The first-party device bundle's entry point. The initial bundle carries a separately
/// signed Simulator helper in Contents/Helpers; the host verifies and launches that helper
/// without mapping this class. Later device views can use this same install identity.
@MainActor
@objc(DevicesPlugin)
public final class DevicesPlugin: NSObject, ThreadingNativePlugin {
    public override required init() { super.init() }

    public static let pluginAPIVersion = 5

    public var pluginIdentifier: String { "codes.threading.plugin.devices" }

    public func apply(theme: PluginTheme) {}
}
