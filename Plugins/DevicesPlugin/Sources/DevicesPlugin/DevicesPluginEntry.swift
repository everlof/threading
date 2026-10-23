import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// The first-party device bundle's entry point. Its read-only Simulator snapshot pane uses
/// exactly the public PluginKit service available to an approved external native plugin.
@MainActor
@objc(DevicesPlugin)
public final class DevicesPlugin: NSObject, ThreadingNativePlugin {
    private var snapshots: SimulatorSnapshotsViewController?
    public override required init() { super.init() }

    public static let pluginAPIVersion = 7

    public var pluginIdentifier: String { "codes.threading.plugin.devices" }

    public func makePaneView(context: PluginContext) -> NSView {
        let pane = SimulatorSnapshotsViewController(
            service: context.simulatorServices,
            preferredDeviceID: context.argument("deviceID"),
            hostOwnsVisibility: context.argument("hostPaneSections") == "true"
        )
        snapshots = pane
        return pane.view
    }

    public func activatePane(context: PluginContext) {
        guard let deviceID = context.argument("deviceID") else { return }
        snapshots?.selectDevice(deviceID)
    }

    public func setPaneSectionPresented(identifier: String, presented: Bool) {
        guard identifier == "snapshots" else { return }
        snapshots?.setPresented(presented)
    }

    public func apply(theme: PluginTheme) {
        _ = try? HostThemeHandoff.install(encoded: theme.encodedTheme)
        snapshots?.repaint()
    }
}
