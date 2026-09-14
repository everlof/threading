import Foundation

/// Records the device screen with `simctl io recordVideo` — a pristine, Apple-supported capture.
///
/// It cannot include our touch overlay (that needs the stream recorder), but it is the
/// highest-fidelity path. Stopping sends SIGINT, which is how `simctl` finalizes the file; the file
/// is ready once the process exits, reported through `onFinalized`.
@MainActor
final class SimulatorSimctlRecorder {
    private var process: Process?
    private(set) var outputURL: URL?

    /// The `simctl` argument vector, exposed for testing without spawning anything.
    static func arguments(deviceID: String, output: URL) -> [String] {
        ["simctl", "io", deviceID, "recordVideo", "--codec", "h264", "--force", output.path]
    }

    var isRecording: Bool { process != nil }

    func start(
        deviceID: String,
        to url: URL,
        executable: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        onFinalized: @escaping @MainActor @Sendable (URL) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(deviceID: deviceID, output: url)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task { @MainActor in onFinalized(url) }
        }
        try process.run()
        self.process = process
        self.outputURL = url
    }

    /// Interrupt the recorder; `onFinalized` fires when the file is complete.
    func stop() {
        process?.interrupt()
        process = nil
        outputURL = nil
    }
}
