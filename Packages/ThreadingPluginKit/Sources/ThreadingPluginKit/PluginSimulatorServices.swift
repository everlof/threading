import Foundation

/// A bounded catalogue of already running iOS Simulators. Reading this does not boot a device.
public struct PluginSimulatorInventory: Sendable {
    public let devices: [PluginSimulatorDevice]
    public let omittedCount: Int

    public init(devices: [PluginSimulatorDevice], omittedCount: Int) {
        self.devices = devices
        self.omittedCount = omittedCount
    }
}

public struct PluginSimulatorDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let runtimeName: String

    public init(id: String, name: String, runtimeName: String) {
        self.id = id
        self.name = name
        self.runtimeName = runtimeName
    }
}

/// Read-only Simulator operations available to every approved native pane plugin.
///
/// Threading validates the exact device and runs CoreSimulator commands on its bounded worker.
/// No boot, input, app installation, process path or private-helper handle crosses this contract.
/// A caller receives this service only through `PluginContext` after the normal plugin trust gate.
public protocol PluginSimulatorServices: AnyObject, Sendable {
    func runningDevices() async throws -> PluginSimulatorInventory
    func screenshot(of deviceID: String) async throws -> Data
}
