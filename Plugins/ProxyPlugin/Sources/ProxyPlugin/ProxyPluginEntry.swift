import Foundation
import ThreadingPluginKit

/// Carries the signed proxy helper and its public-certificate setup script. Threading retains
/// capture leases, client consent and CA custody; loading this class grants none of them.
@MainActor
@objc(ProxyPlugin)
public final class ProxyPlugin: NSObject, ThreadingNativePlugin {
    public override required init() { super.init() }

    public static let pluginAPIVersion = 7

    public var pluginIdentifier: String { "codes.threading.plugin.proxy" }

    public func apply(theme: PluginTheme) {}
}
