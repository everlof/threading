import Foundation

/// Host operations a native plugin may request for a paired iPhone.
///
/// The host chooses and owns the transport and its executable. These are deliberately finite
/// operations rather than an arbitrary command runner or an executable path in `PluginContext`.
/// An approved third-party pane plugin receives the same service as a bundled pane plugin.
public protocol PluginDeviceServices: AnyObject, Sendable {
    /// A bounded, worker-side availability check. Call it during source discovery, never while
    /// drawing a view or responding to a click on the main actor.
    func hasStructuredSystemLog() -> Bool

    /// Streams newline-delimited JSON from the selected paired phone. `onLine` runs off main and
    /// receives at most one bounded line per call. The host pushes the requested level down to
    /// the device so a hidden firehose is not still read and decoded.
    func startStructuredSystemLog(
        deviceID: String,
        minimumSeverity: Int,
        onLine: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) -> (any PluginDeviceLogStream)?

    /// Sends a Bluetooth logging profile to one paired phone. The host validates the profile,
    /// limits its size, serializes mutations, and lets iOS present its own installation consent.
    /// This call blocks its caller's worker until the bounded operation ends.
    func installBluetoothLoggingProfile(
        _ profile: Data,
        deviceID: String
    ) -> PluginDeviceOperationResult
}

/// The plugin's only authority over a host-owned log reader is to end its own stream.
public protocol PluginDeviceLogStream: AnyObject, Sendable {
    func stop()
}

public enum PluginDeviceOperationResult: Equatable, Sendable {
    case sent
    case busy
    case invalidDevice
    case invalidProfile
    case expiredProfile
    case toolUnavailable
    case incomplete
    case rejected(String)
}
