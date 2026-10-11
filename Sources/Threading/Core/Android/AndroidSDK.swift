import Darwin
import Foundation
import ThreadingAndroidKit

/// Where the Android SDK's two tools live on this Mac. Resolved once, from the variables Android
/// Studio and the SDK document, then the default install location; only absolute executables are
/// accepted, so a `PATH` lookup can never pick up a different `adb` than the one we checked.
struct AndroidSDK: Equatable, Sendable {
    let root: URL
    let adb: URL
    let emulator: URL
    let avdHome: URL

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AndroidSDK? {
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            + [home.appendingPathComponent("Library/Android/sdk", isDirectory: true)]
        for root in candidates {
            let adb = root.appendingPathComponent("platform-tools/adb")
            let emulator = root.appendingPathComponent("emulator/emulator")
            guard isExecutable(adb.path) else { continue }
            let avdHome = environment["ANDROID_AVD_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".android/avd", isDirectory: true)
            return AndroidSDK(root: root, adb: adb, emulator: emulator, avdHome: avdHome)
        }
        return nil
    }

    var hasEmulator: Bool { FileManager.default.isExecutableFile(atPath: emulator.path) }
}

enum AndroidControlDefaults {
    static let commandQueueLabel = "codes.threading.android-command"
    static let maximumAVDCount = 512
    static let maximumADBDevices = 64
    static let maximumConfigBytes = 64 * 1024
    static let maximumCommandOutputBytes = 256 * 1024
    static let maximumScreenshotBytes = 64 * 1024 * 1024
    static let maximumLaunchArgumentCount = 64
    static let maximumLaunchArgumentCharacters = 4_096
    static let maximumPackageNameCharacters = 255
    static let listTimeout: TimeInterval = 15
    static let propertyTimeout: TimeInterval = 5
    static let bootTimeout: TimeInterval = 180
    static let discoveryTimeout: TimeInterval = 45
    static let installTimeout: TimeInterval = 180
    static let launchTimeout: TimeInterval = 30
    static let screenshotTimeout: TimeInterval = 15
    static let shutdownTimeout: TimeInterval = 30
    static let pollInterval: TimeInterval = 1
    /// The extras an `am start` launch argument is delivered under: `threading.argument.0`, …
    static let launchArgumentExtraPrefix = "threading.argument."
}

/// What Threading knows about one Android device it can reach right now.
struct AndroidTarget: Equatable, Sendable {
    let deviceID: SimulatorDeviceID
    /// The adb serial (`emulator-5554`, or a phone's USB serial).
    let serial: String
    /// The emulator's own discovery record, when it advertises one (gRPC port and key directory).
    let emulator: RunningEmulatorRecord?
    /// True when Threading started this emulator with its own allowlist, so its tokens use the
    /// `threading` issuer rather than the audience-scoped one.
    let usesThreadingAllowlist: Bool
}

/// The process-wide registry of Android devices Threading started, shared by the lifecycle control
/// and the stream coordinator so both resolve an identity to the same running device.
final class AndroidDeviceDirectory: @unchecked Sendable {
    static let shared = AndroidDeviceDirectory(sdk: AndroidSDK.locate())

    struct BootedEmulator {
        let process: SpawnedChildProcess
        let grpcPort: UInt16
    }

    let sdk: AndroidSDK?
    private let lock = NSLock()
    private var booted: [String: BootedEmulator] = [:]
    let allowlistURL: URL
    let signer = EmulatorTokenSigner()

    init(sdk: AndroidSDK?, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.sdk = sdk
        self.allowlistURL = temporaryDirectory.appendingPathComponent(
            "codes.threading.android-\(getpid())-allowlist.json"
        )
    }

    func recordBoot(avdName: String, process: SpawnedChildProcess, grpcPort: UInt16) {
        lock.withLock { booted[avdName] = BootedEmulator(process: process, grpcPort: grpcPort) }
        process.observeExit { [weak self] _ in
            self?.lock.withLock {
                if self?.booted[avdName]?.process === process { self?.booted[avdName] = nil }
            }
        }
    }

    func bootedEmulator(_ avdName: String) -> BootedEmulator? {
        lock.withLock { booted[avdName] }
    }

    /// Writes the allowlist an emulator Threading starts is given; idempotent.
    func ensureAllowlist() throws -> URL {
        let data = EmulatorTokenSigner.allowlist()
        if (try? Data(contentsOf: allowlistURL)) != data {
            try data.write(to: allowlistURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: allowlistURL.path)
        }
        return allowlistURL
    }

    /// The running emulators, by AVD identifier, from their discovery files.
    func runningEmulatorRecords() -> [String: RunningEmulatorRecord] {
        Dictionary(RunningEmulatorRecord.scan().map { ($0.avdName, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// POSIX single-quoting for an argument that `adb shell` will hand to the device's `sh`. adb joins
/// its arguments with spaces and runs them through the shell, so every caller-supplied value is
/// quoted, never interpolated.
enum AndroidShellQuoting {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Picks an unused loopback TCP port by asking the kernel for one. The gap between closing the
/// probe and the emulator binding it is a race, but a lost one fails the boot loudly rather than
/// connecting to the wrong service: the emulator refuses to start on a taken port.
enum LoopbackPort {
    static func unused() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
