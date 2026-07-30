import Darwin
import Foundation
import ThreadingExtensionKit

enum ExtensionWasmRunnerError: LocalizedError {
    case runnerUnavailable(String)
    case wrongRuntime
    case unsupportedMode
    case reservedDescriptor(Int32)
    case moduleOpenFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .runnerUnavailable(let name):
            return L10n.format(
                "Threading’s WebAssembly extension runner (%@) is missing from the application bundle.",
                name
            )
        case .wrongRuntime:
            return L10n.string("A non-WebAssembly extension was sent to the WebAssembly runner.")
        case .unsupportedMode:
            return L10n.string(
                "The WebAssembly runner only accepts registration and serve entry modes."
            )
        case .reservedDescriptor(let descriptor):
            return L10n.format(
                "Extension descriptor %lld conflicts with the WebAssembly module.",
                Int64(descriptor)
            )
        case .moduleOpenFailed(let path, let code):
            return L10n.format(
                "The WebAssembly module at %@ could not be opened: %@",
                path,
                String(cString: strerror(code))
            )
        }
    }
}

/// Launches a Swift-compiled WebAssembly extension in Threading's signed interpreter process.
///
/// The runner receives the module as inherited descriptor 4 rather than a path. It can
/// therefore be App Sandboxed without a package-directory entitlement. The guest gets no WASI
/// filesystem preopens and no network API; its only Threading import forwards one authenticated
/// request over descriptor 3.
struct WasmLaunchPolicy: ExtensionLaunchPolicy {
    static let runnerName = "threading-wasm-extension-runner"
    static let moduleDescriptorNumber: Int32 = 4

    let hostTransport: ExtensionHostTransport = .descriptor

    private let bundle: Bundle
    private let explicitRunnerURL: URL?

    init(bundle: Bundle = .main, runnerURL: URL? = nil) {
        self.bundle = bundle
        self.explicitRunnerURL = runnerURL
    }

    func runnerURL() -> URL? {
        let candidate = explicitRunnerURL ?? bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(Self.runnerName, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: candidate.path)
            ? candidate
            : nil
    }

    func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
        guard request.bundle.manifest.runtime == .webAssembly else {
            throw ExtensionWasmRunnerError.wrongRuntime
        }
        guard request.arguments == ["--threading-register"]
                || request.arguments == ["--threading-serve"] else {
            throw ExtensionWasmRunnerError.unsupportedMode
        }
        guard request.extraDescriptors[Self.moduleDescriptorNumber] == nil else {
            throw ExtensionWasmRunnerError.reservedDescriptor(Self.moduleDescriptorNumber)
        }

        // A launch policy consumes all child ends once spawn is attempted, whether it succeeds
        // or not. This keeps broker revocation and pipe EOF deterministic.
        defer { closeChildEnds(of: request) }

        guard let runner = runnerURL() else {
            throw ExtensionWasmRunnerError.runnerUnavailable(Self.runnerName)
        }
        let moduleDescriptor = Darwin.open(
            request.bundle.executableURL.path,
            O_RDONLY | O_CLOEXEC
        )
        guard moduleDescriptor >= 0 else {
            throw ExtensionWasmRunnerError.moduleOpenFailed(
                request.bundle.manifest.executable,
                errno
            )
        }
        defer { Darwin.close(moduleDescriptor) }

        var descriptors: [Int32: Int32] = [
            0: descriptor(for: request.standardInput, childReads: true),
            1: descriptor(for: request.standardOutput, childReads: false),
            2: descriptor(for: request.standardError, childReads: false),
            Self.moduleDescriptorNumber: moduleDescriptor
        ]
        descriptors.merge(request.extraDescriptors) { _, extra in extra }

        return try ExtensionChildSpawner.spawn(
            executableURL: runner,
            arguments: request.arguments,
            environment: ExtensionLaunchEnvironment.composed(
                with: request.additionalEnvironment
            ),
            workingDirectory: nil,
            descriptors: descriptors
        )
    }

    private func descriptor(
        for stream: ExtensionChildStream,
        childReads: Bool
    ) -> Int32 {
        switch stream {
        case .nullDevice:
            return FileHandle.nullDevice.fileDescriptor
        case .pipe(let pipe):
            return childReads
                ? pipe.fileHandleForReading.fileDescriptor
                : pipe.fileHandleForWriting.fileDescriptor
        }
    }

    private func closeChildEnds(of request: ExtensionLaunchRequest) {
        if case .pipe(let pipe) = request.standardInput {
            try? pipe.fileHandleForReading.close()
        }
        if case .pipe(let pipe) = request.standardOutput {
            try? pipe.fileHandleForWriting.close()
        }
        if case .pipe(let pipe) = request.standardError {
            try? pipe.fileHandleForWriting.close()
        }
        for descriptor in request.extraDescriptors.values {
            Darwin.close(descriptor)
        }
    }
}

/// Keeps legacy native packages usable while making WebAssembly the supported boundary.
struct RuntimeSelectingLaunchPolicy: ExtensionLaunchPolicy {
    private let native: ExtensionLaunchPolicy
    private let webAssembly: ExtensionLaunchPolicy

    /// Only callers that do not yet ask per bundle observe this. Product routing always calls
    /// `hostTransport(for:)`.
    let hostTransport: ExtensionHostTransport = .descriptor

    init(
        native: ExtensionLaunchPolicy = SandboxExecLaunchPolicy(),
        webAssembly: ExtensionLaunchPolicy = WasmLaunchPolicy()
    ) {
        self.native = native
        self.webAssembly = webAssembly
    }

    func hostTransport(for bundle: ThreadingExtensionBundle) -> ExtensionHostTransport {
        policy(for: bundle).hostTransport(for: bundle)
    }

    func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
        try policy(for: request.bundle).spawn(request)
    }

    private func policy(for bundle: ThreadingExtensionBundle) -> ExtensionLaunchPolicy {
        switch bundle.manifest.runtime {
        case .native:
            return native
        case .webAssembly:
            return webAssembly
        }
    }
}
