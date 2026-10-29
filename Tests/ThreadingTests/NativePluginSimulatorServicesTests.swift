import XCTest
@testable import Threading

final class NativePluginSimulatorServicesTests: XCTestCase {
    func testOnlyRunningIOSDevicesAreOfferedAndTheCatalogueIsBounded() async throws {
        let devices = (0..<70).map { device($0, state: .booted) }
            + [device(70, state: .shutdown), androidDevice()]
        let control = SimulatorSnapshotControl(devices: devices)
        let inventory = try await NativePluginSimulatorServices(control: control).runningDevices()

        XCTAssertEqual(inventory.devices.count, 64)
        XCTAssertEqual(inventory.omittedCount, 6)
        XCTAssertEqual(inventory.devices.first?.name, "Phone 0")
        XCTAssertFalse(inventory.devices.contains { $0.id == devices[70].id.rawValue })
    }

    func testCaptureRejectsInvalidOrStoppedDeviceBeforeCallingControl() async throws {
        let running = device(1, state: .booted)
        let stopped = device(2, state: .shutdown)
        let control = SimulatorSnapshotControl(devices: [running, stopped])
        let service = NativePluginSimulatorServices(control: control)

        let image = try await service.screenshot(of: running.id.rawValue)
        XCTAssertEqual(image, Data("image".utf8))
        for invalid in [stopped.id.rawValue, UUID().uuidString, "android-usb:phone", "bad;id"] {
            do {
                _ = try await service.screenshot(of: invalid)
                XCTFail("Captured from \(invalid)")
            } catch { }
        }
        let captures = await control.captureCalls
        XCTAssertEqual(captures, [running.id])
    }

    private func device(_ number: Int, state: SimulatorDeviceState) -> SimulatorDevice {
        let suffix = String(format: "%012d", number)
        let id = SimulatorDeviceID("AAAAAAAA-AAAA-AAAA-AAAA-\(suffix)")!
        return SimulatorDevice(
            id: id, name: "Phone \(number)", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5", deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
            family: .iPhone, state: state, lastBootedAt: nil
        )
    }

    private func androidDevice() -> SimulatorDevice {
        SimulatorDevice(
            id: SimulatorDeviceID("android-usb:phone")!, name: "Android",
            runtimeIdentifier: "android", runtimeName: "Android",
            deviceTypeIdentifier: "android-phone", family: .androidPhone,
            state: .booted, lastBootedAt: nil
        )
    }
}

private actor SimulatorSnapshotControl: SimulatorControlling {
    let devices: [SimulatorDevice]
    private(set) var captureCalls: [SimulatorDeviceID] = []

    init(devices: [SimulatorDevice]) { self.devices = devices }
    func availableDevices() async throws -> [SimulatorDevice] { devices }
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        throw SimulatorControlError.unsupportedPlatformRequest
    }
    func installAndLaunch(
        applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID,
        arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        throw SimulatorControlError.unsupportedPlatformRequest
    }
    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        captureCalls.append(deviceID)
        return Data("image".utf8)
    }
    func release(_ lease: SimulatorDeviceLease) async throws {}
}
