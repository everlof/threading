import Foundation

/// The packet pane's existing controls and decoder report, without reading the definitions file.
public struct DeviceLogBluetoothState: Codable, Sendable {
    public let packets: String
    public let definitions: Definitions

    public struct Definitions: Codable, Sendable {
        public let status: String
        public let path: String?
        public let message: String?
    }

    init(packets: BluetoothPacketFilter, status: BluetoothDefinitionStatus?) {
        self.packets = packets.toolName
        let name: String
        switch status {
        case nil: name = "loading"
        case .noCheckout?: name = "no_checkout"
        case .missing?: name = "missing"
        case .loaded?: name = "loaded"
        case .failed?: name = "failed"
        }
        definitions = Definitions(status: name, path: status?.url?.path, message: status?.summary)
    }
}
