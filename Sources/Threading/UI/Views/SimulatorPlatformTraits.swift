import Foundation
import ThreadingSimulatorKit

/// What a workspace member's pane offers for the platform of the device it holds. One value,
/// chosen from the device identity, so every iOS-only control, glyph and string asks the same
/// question instead of assuming an iPhone.
struct SimulatorPlatformTraits: Equatable {
    let platform: SimulatorDevicePlatform
    /// The device's own buttons, in the order the hardware row shows them.
    let buttons: [SimulatorBridgeButton]
    /// Device Logs reads the unified log of a CoreSimulator device; Android's logcat is not wired.
    let hasDeviceLogs: Bool
    let placeholderName: String

    static func traits(for platform: SimulatorDevicePlatform) -> SimulatorPlatformTraits {
        switch platform {
        case .iOSSimulator:
            return SimulatorPlatformTraits(
                platform: platform, buttons: SimulatorBridgeButton.iOS, hasDeviceLogs: true,
                placeholderName: L10n.string("iPhone")
            )
        case .androidEmulator:
            return SimulatorPlatformTraits(
                platform: platform,
                buttons: [.back, .home, .overview, .lock, .volumeDown, .volumeUp, .rotateLeft, .rotateRight],
                hasDeviceLogs: false, placeholderName: L10n.string("Android Emulator")
            )
        case .androidDevice:
            // A phone is turned by hand; its rotation sensor is not Threading's to set.
            return SimulatorPlatformTraits(
                platform: platform, buttons: [.back, .home, .overview, .lock, .volumeDown, .volumeUp],
                hasDeviceLogs: false, placeholderName: L10n.string("Android Device")
            )
        }
    }

    static func symbolName(for family: SimulatorDeviceFamily?, platform: SimulatorDevicePlatform) -> String {
        switch (platform, family) {
        case (.iOSSimulator, .iPad?): return "ipad"
        case (.iOSSimulator, _): return "iphone"
        case (_, .androidTablet?): return "rectangle.portrait"
        case (_, _): return "candybarphone"
        }
    }

    /// The pane's controls and messages name what it shows: an iOS Simulator is a Simulator; an
    /// emulator or a phone is a device. Each is a whole string so it translates as one.
    enum Wording {
        case refresh, options, screen, unavailable, unreachable, streamEnded
        case connectingControl, enableControl, retryControl, controlReady, reconnectControl
    }

    func string(_ wording: Wording) -> String {
        platform.isAndroid ? Self.deviceString(wording) : Self.simulatorString(wording)
    }

    func controlDenied(for deviceName: String) -> String {
        platform.isAndroid ? L10n.format("Device control was not allowed for %@.", deviceName)
            : L10n.format("Simulator control was not allowed for %@.", deviceName)
    }

    private static func simulatorString(_ wording: Wording) -> String {
        switch wording {
        case .refresh: L10n.string("Refresh Simulator")
        case .options: L10n.string("Simulator Options")
        case .screen: L10n.string("Simulator screen")
        case .unavailable: L10n.string("Simulator unavailable")
        case .unreachable: L10n.string("Threading can’t reach this Simulator. Retry or choose another device.")
        case .streamEnded: L10n.string("The direct Simulator stream ended.")
        case .connectingControl: L10n.string("Connecting Simulator control…")
        case .enableControl: L10n.string("Enable Simulator Control")
        case .retryControl: L10n.string("Retry Simulator Control")
        case .controlReady: L10n.string("Simulator control ready")
        case .reconnectControl: L10n.string("Reconnect Simulator Control")
        }
    }

    private static func deviceString(_ wording: Wording) -> String {
        switch wording {
        case .refresh: L10n.string("Refresh Device")
        case .options: L10n.string("Device Options")
        case .screen: L10n.string("Device screen")
        case .unavailable: L10n.string("Device unavailable")
        case .unreachable: L10n.string("Threading can’t reach this device. Retry or choose another device.")
        case .streamEnded: L10n.string("The device stream ended.")
        case .connectingControl: L10n.string("Connecting device control…")
        case .enableControl: L10n.string("Enable Device Control")
        case .retryControl: L10n.string("Retry Device Control")
        case .controlReady: L10n.string("Device control ready")
        case .reconnectControl: L10n.string("Reconnect Device Control")
        }
    }

    /// Lock on an iOS Simulator is Power on Android: the same bridge button, named for the device.
    func title(for button: SimulatorBridgeButton) -> String? {
        guard platform.isAndroid, button == .lock else { return nil }
        return L10n.string("Power")
    }
}
