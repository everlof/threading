import Foundation
import ThreadingPluginKit

/// The public Simulator snapshot broker used by first-party and approved external native panes.
/// It only reads devices that were already booted; the host keeps boot leases and input consent.
final class NativePluginSimulatorServices: PluginSimulatorServices, Sendable {
    // Share the workspace's routed control instance. Its iOS command queue serializes this
    // capture with public install/launch/screenshot work already in progress for that device.
    static let shared = NativePluginSimulatorServices(control: PlatformRoutingSimulatorControl.shared)
    static let maximumReturnedDevices = 64

    private let control: any SimulatorControlling

    init(control: any SimulatorControlling) {
        self.control = control
    }

    func runningDevices() async throws -> PluginSimulatorInventory {
        let available = try await control.availableDevices()
        let running = available.filter {
            $0.platform == .iOSSimulator && $0.state.isBooted && $0.isAdoptable
        }
        let selected = running.prefix(Self.maximumReturnedDevices).map {
            PluginSimulatorDevice(id: $0.id.rawValue, name: $0.name, runtimeName: $0.runtimeName)
        }
        return PluginSimulatorInventory(
            devices: selected, omittedCount: running.count - selected.count
        )
    }

    func screenshot(of deviceID: String) async throws -> Data {
        guard let id = SimulatorDeviceID(deviceID), id.platform == .iOSSimulator else {
            throw SimulatorControlError.invalidResponse("Choose an iOS Simulator from the running-device list.")
        }
        let available = try await control.availableDevices()
        guard available.contains(where: { $0.id == id && $0.state.isBooted && $0.isAdoptable }) else {
            throw SimulatorControlError.deviceUnavailable(id, detail: "The Simulator is not running.")
        }
        // A visible workspace may hold the private framebuffer helper for this same device.
        // Public simctl capture must use the workspace's transaction gate or CoreSimulator can
        // leave both connections waiting. The gate stops those viewers on the main actor; the
        // bounded screenshot itself stays on SimctlSimulatorControl's worker.
        await MainActor.run { SimulatorDeviceTransactions.shared.begin(on: id) }
        do {
            let data = try await control.screenshot(of: id)
            await MainActor.run { SimulatorDeviceTransactions.shared.end(on: id) }
            return data
        } catch {
            await MainActor.run { SimulatorDeviceTransactions.shared.end(on: id) }
            throw error
        }
    }
}
