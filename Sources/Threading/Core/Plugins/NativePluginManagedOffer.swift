import Foundation

/// First-party native plugins that the host can offer before their bundles are installed.
/// The path is fixed here; the signed release manifest still decides which build may be fetched.
struct NativePluginManagedOffer: Sendable {
    enum DeviceLogsSection {
        static let regular = "regular"
        static let bluetooth = "bluetooth"
    }

    enum DeviceLogsRoute {
        static let fromDevice = "from-device"
    }

    enum PanePlacement: String, Sendable, Equatable {
        case panel
        case drawer
    }

    enum PaneContext: String, Sendable { case selectedDevice = "selected-device" }

    struct PaneRoute: Sendable {
        let identifier: String
        let section: String
        let placement: PanePlacement
        let context: PaneContext
    }

    struct PaneSection: Sendable {
        let identifier: String
        let titleKey: String
        /// A host command remains available before this on-demand bundle is installed.
        let command: PaneCommand?

        var title: String { L10n.string(titleKey) }

        init(identifier: String, titleKey: String, command: PaneCommand? = nil) {
            self.identifier = identifier
            self.titleKey = titleKey
            self.command = command
        }
    }

    struct PaneCommand: Sendable {
        let id: String
        let titleKey: String
        let symbol: String
        let detailKey: String?

        init(id: String, titleKey: String, symbol: String, detailKey: String? = nil) {
            self.id = id
            self.titleKey = titleKey
            self.symbol = symbol
            self.detailKey = detailKey
        }
    }

    let identifier: String
    let bundleName: String
    let nameKey: String
    let summaryKey: String
    let approximateDownloadSize: String
    /// False when the host already owns a dedicated command or the plugin has no pane.
    let showsGenericPaneCommand: Bool
    /// Stable, host-owned section chrome. The first section is the primary pane.
    let paneSections: [PaneSection]
    /// Contextual entry points; the host keeps the tab's actual placement and lifetime.
    let paneRoutes: [PaneRoute]

    var name: String { L10n.string(nameKey) }
    var summary: String { L10n.string(summaryKey) }
    var primaryPaneSection: String? { paneSections.first?.identifier }

    func containsPaneSection(_ identifier: String) -> Bool {
        paneSections.contains { $0.identifier == identifier }
    }

    func paneRoute(_ identifier: String) -> PaneRoute? {
        paneRoutes.first { $0.identifier == identifier && containsPaneSection($0.section) }
    }

    static let deviceLogs = Self(
        identifier: "codes.threading.plugin.devicelogs",
        bundleName: "DeviceLogsPlugin.bundle",
        nameKey: "Device Logs",
        summaryKey: "Device and Bluetooth logs",
        approximateDownloadSize: "0.7 MB",
        showsGenericPaneCommand: false,
        paneSections: [
            .init(identifier: DeviceLogsSection.regular, titleKey: "Device Logs",
                command: .init(id: "panel.deviceLogs", titleKey: "Device logs",
                    symbol: "list.bullet.rectangle")),
            .init(identifier: DeviceLogsSection.bluetooth, titleKey: "Bluetooth",
                command: .init(id: "panel.bluetoothLogs", titleKey: "Bluetooth logs",
                    symbol: "antenna.radiowaves.left.and.right",
                    detailKey: "Capture a paired iPhone's Bluetooth packets"))
        ],
        paneRoutes: [
            .init(identifier: DeviceLogsRoute.fromDevice,
                section: DeviceLogsSection.regular, placement: .drawer,
                context: .selectedDevice)
        ]
    )

    static let devices = Self(
        identifier: "codes.threading.plugin.devices",
        bundleName: "DevicesPlugin.bundle",
        nameKey: "Devices",
        summaryKey: "iOS Simulator control and snapshots",
        approximateDownloadSize: "0.3 MB",
        showsGenericPaneCommand: false,
        paneSections: [
            .init(identifier: "snapshots", titleKey: "Simulator Snapshots",
                command: .init(id: "panel.simulatorSnapshots", titleKey: "Simulator snapshots",
                    symbol: "camera.viewfinder"))
        ],
        paneRoutes: [
            .init(identifier: "from-device", section: "snapshots", placement: .panel,
                context: .selectedDevice)
        ]
    )

    static let t3Navigator = Self(
        identifier: "codes.threading.plugin.t3navigator",
        bundleName: "T3NavigatorPlugin.bundle",
        nameKey: "T3 Native Threads",
        summaryKey: "T3 workspace navigator",
        approximateDownloadSize: "0.1 MB",
        showsGenericPaneCommand: false,
        paneSections: [],
        paneRoutes: []
    )

    static let proxy = Self(
        identifier: "codes.threading.plugin.proxy",
        bundleName: "ProxyPlugin.bundle",
        nameKey: "Network Proxy",
        summaryKey: "HTTP and TLS traffic capture",
        approximateDownloadSize: "0.7 MB",
        showsGenericPaneCommand: false,
        paneSections: [],
        paneRoutes: []
    )

    static let all: [Self] = [deviceLogs, devices, t3Navigator, proxy]

    /// Only a catalogue-owned top-level install address can show a one-click install action.
    /// A manual bundle elsewhere cannot borrow the first-party manifest's approval path.
    static func at(_ bundleURL: URL, directory: URL = NativePluginManagedPaths.directory) -> Self? {
        guard bundleURL.deletingLastPathComponent().standardizedFileURL.path ==
                directory.standardizedFileURL.path else { return nil }
        return all.first { $0.bundleName == bundleURL.lastPathComponent }
    }

    /// The same fixed offer address in an installed release or an embedded development build.
    /// No filesystem read is needed on the pane activation path.
    static func paneOffer(at bundleURL: URL) -> Self? {
        if let installed = at(bundleURL) { return installed }
        guard let embeddedDirectory = Bundle.main.builtInPlugInsURL,
              bundleURL.deletingLastPathComponent().standardizedFileURL.path ==
                embeddedDirectory.standardizedFileURL.path else { return nil }
        return all.first { $0.bundleName == bundleURL.lastPathComponent }
    }
}
