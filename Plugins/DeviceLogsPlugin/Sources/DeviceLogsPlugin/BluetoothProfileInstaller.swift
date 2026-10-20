import Darwin
import Foundation
import Security

/// A deliberate, finite device operation. Apple owns the download and iOS owns installation
/// approval. Never bundle the profile or use MCInstall's supervised/silent installation route.
enum BluetoothProfileInstaller {
    static let downloadURL = URL(string: "https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth")!
    static let profileDownloadURL = URL(string: "https://developer.apple.com/services-account/download?path=%2FiOS%2FiOS_Logs%2FiOSBluetoothLogging.mobileconfig")!
    static let maximumProfileBytes = 1_048_576
    private static let installationLock = NSLock()

    enum Failure: Error, Equatable {
        case busy
        case invalidProfile
        case expiredProfile
        case missingTool
        case incomplete
        case rejected(String)
    }

    /// Called on a worker. Admission is shared across panes: never queue device mutations.
    static func install(
        profileURL: URL,
        deviceID: String,
        preferredToolPath: String?,
        deadline: TimeInterval = 90
    ) -> Result<Void, Failure> {
        guard installationLock.try() else { return .failure(.busy) }
        defer { installationLock.unlock() }
        guard !deviceID.isEmpty else { return .failure(.incomplete) }
        do {
            let data = try readProfile(profileURL)
            try validate(data)
            let paths = DeviceLogSourceCatalog.structuredSyslogCandidatePaths(
                preferredPath: preferredToolPath, environment: ProcessInfo.processInfo.environment
            )
            guard let tool = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return .failure(.missingTool)
            }

            // Snapshot precisely the bytes inspected above; the chosen file can change while a
            // device waits for its owner. Private staging is removed on every completion path.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = directory.appendingPathComponent("Bluetooth.mobileconfig")
            try data.write(to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let result = BoundedDeviceLogCommand.runResult(
                tool, arguments(deviceID: deviceID, profilePath: staged.path), deadline: deadline,
                environment: StructuredPairedDeviceLogRowSource.environment(udid: deviceID),
                includeStandardError: true, maximumOutputBytes: 8_192
            )
            guard let result else { return .failure(.incomplete) }
            guard result.exitStatus == 0 else {
                let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.rejected(String(detail.suffix(1_024))))
            }
            // InstallProfile acknowledgement is not evidence of completed on-device approval.
            return .success(())
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.incomplete)
        }
    }

    static func arguments(deviceID: String, profilePath: String) -> [String] {
        ["--no-color", "profile", "install", "--udid", deviceID, "--", profilePath]
    }

    private static func readProfile(_ url: URL) throws -> Data {
        // A chooser can return a special file. Open nonblocking, then inspect that same descriptor
        // before reading so a FIFO or an oversized file cannot monopolize the worker.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidProfile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumProfileBytes,
              let data = try handle.read(upToCount: maximumProfileBytes + 1),
              data.count <= maximumProfileBytes else { throw Failure.invalidProfile }
        return data
    }

    static func validate(_ data: Data, now: Date = Date()) throws {
        guard !data.isEmpty, data.count <= maximumProfileBytes else { throw Failure.invalidProfile }
        let content: Data
        if let plain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            try validatePayload(plain, now: now)
            return
        }
        // Decode the signed envelope for type/expiry checks. iOS checks the profile's signing
        // identity and presents its consent; metadata here is not a claim of signature trust.
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { throw Failure.invalidProfile }
        let status = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, $0.count) }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw Failure.invalidProfile
        }
        var decoded: CFData?
        guard CMSDecoderCopyContent(decoder, &decoded) == errSecSuccess, let decoded else {
            throw Failure.invalidProfile
        }
        content = decoded as Data
        guard let payload = try? PropertyListSerialization.propertyList(from: content, format: nil) as? [String: Any] else {
            throw Failure.invalidProfile
        }
        try validatePayload(payload, now: now)
    }

    private static func validatePayload(_ payload: [String: Any], now: Date) throws {
        guard payload["PayloadType"] as? String == "Configuration",
              payload["PayloadIdentifier"] as? String == "com.apple.bluetooth.logging",
              let content = payload["PayloadContent"] as? [[String: Any]], !content.isEmpty else {
            throw Failure.invalidProfile
        }
        if let removal = payload["RemovalDate"] as? Date, removal <= now { throw Failure.expiredProfile }
    }
}
