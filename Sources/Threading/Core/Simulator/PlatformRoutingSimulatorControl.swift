import Foundation

/// The one `SimulatorControlling` a workspace talks to, routing each exact device to the control
/// plane that owns it: CoreSimulator for iOS, the Android SDK for emulators and USB devices.
///
/// Routing is by identity (`SimulatorDeviceID.platform`), never by a device's current state, so
/// a member cannot drift to another backend. The catalogue asks every plane concurrently and one
/// plane failing never hides another's devices: a Mac without the Android SDK keeps exactly its
/// iOS list, and a wedged `adb` cannot blank the iOS Simulators beside it.
final class PlatformRoutingSimulatorControl: SimulatorControlling, @unchecked Sendable {
    static let shared = PlatformRoutingSimulatorControl()

    private let iOS: any SimulatorControlling
    private let android: (any SimulatorControlling)?

    init(
        iOS: any SimulatorControlling = SimctlSimulatorControl(),
        android: (any SimulatorControlling)? = AndroidDeviceControl.shared
    ) {
        self.iOS = iOS
        self.android = android
    }

    var supportsAndroid: Bool { android != nil }

    func createDevice(_ request: SimulatorDeviceCreationRequest) async throws -> SimulatorDevice {
        try await iOS.createDevice(request)
    }

    func availableDevices() async throws -> [SimulatorDevice] {
        guard let android else { return try await iOS.availableDevices() }
        async let iOSDevices = Self.result { try await self.iOS.availableDevices() }
        async let androidDevices = Self.result { try await android.availableDevices() }
        let (iOSResult, androidResult) = await (iOSDevices, androidDevices)
        switch (iOSResult, androidResult) {
        case (.success(let iOS), .success(let android)): return iOS + android
        case (.success(let iOS), .failure(let error)):
            ThreadingLogger.simulator.error("Android device discovery failed: \(error.localizedDescription, privacy: .private)")
            return iOS
        case (.failure(let error), .success(let android)):
            // An empty Android list must still surface the iOS failure: it is the only answer.
            guard !android.isEmpty else { throw error }
            ThreadingLogger.simulator.error("iOS device discovery failed: \(error.localizedDescription, privacy: .private)")
            return android
        case (.failure(let error), .failure):
            throw error
        }
    }

    /// With no device named, preparation keeps its historical meaning: an iOS Simulator. Callers
    /// that want Android choose an exact device from the catalogue first.
    func prepare(deviceID: SimulatorDeviceID?) async throws -> SimulatorDeviceLease {
        guard let deviceID else { return try await iOS.prepare(deviceID: nil) }
        return try await control(for: deviceID).prepare(deviceID: deviceID)
    }

    func installAndLaunch(
        applicationURL: URL, bundleIdentifier: String, on deviceID: SimulatorDeviceID, arguments: [String]
    ) async throws -> SimulatorLaunchReceipt {
        try await control(for: deviceID).installAndLaunch(
            applicationURL: applicationURL, bundleIdentifier: bundleIdentifier, on: deviceID, arguments: arguments
        )
    }

    func screenshot(of deviceID: SimulatorDeviceID) async throws -> Data {
        try await control(for: deviceID).screenshot(of: deviceID)
    }

    func setAppearance(dark: Bool, on deviceID: SimulatorDeviceID) async throws {
        try await control(for: deviceID).setAppearance(dark: dark, on: deviceID)
    }

    func release(_ lease: SimulatorDeviceLease) async throws {
        try await control(for: lease.device.id).release(lease)
    }

    func launchApp(_ launch: SimulatorAppLaunch, on deviceID: SimulatorDeviceID) async throws -> SimulatorLaunchReceipt {
        try await control(for: deviceID).launchApp(launch, on: deviceID)
    }

    func openAppLink(_ link: SimulatorAppLink, on deviceID: SimulatorDeviceID) async throws {
        try await control(for: deviceID).openAppLink(link, on: deviceID)
    }

    private static func result<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func control(for deviceID: SimulatorDeviceID) throws -> any SimulatorControlling {
        guard deviceID.platform.isAndroid else { return iOS }
        guard let android else { throw SimulatorControlError.deviceNotFound(deviceID) }
        return android
    }
}

/// The stream counterpart: iOS devices go to the signed direct helper, Android devices to the
/// Android transports. Each keeps its own app-wide budget, since one is helper processes and the
/// other gRPC/adb connections, and neither may starve the other.
struct PlatformRoutingStreamCoordinator: SimulatorLiveStreamCoordinating {
    static let shared = PlatformRoutingStreamCoordinator()

    private let iOS: any SimulatorLiveStreamCoordinating
    private let android: any SimulatorLiveStreamCoordinating

    init(
        iOS: any SimulatorLiveStreamCoordinating = SimulatorLiveStreamCoordinator.shared,
        android: any SimulatorLiveStreamCoordinating = AndroidStreamCoordinator.shared
    ) {
        self.iOS = iOS
        self.android = android
    }

    func openStream(for deviceID: SimulatorDeviceID) async throws -> any SimulatorLiveStreamSession {
        try await (deviceID.platform.isAndroid ? android : iOS).openStream(for: deviceID)
    }
}
