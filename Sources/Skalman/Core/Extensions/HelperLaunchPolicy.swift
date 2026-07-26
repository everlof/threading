import Darwin
import Foundation
import SkalmanExtensionKit

enum ExtensionHelperError: LocalizedError {
    case helperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let name):
            return "Skalman's contained extension launcher (\(name)) is missing from the "
                + "application bundle."
        }
    }
}

/// The supported containment: a signed, App Sandboxed helper the extension is executed out of.
///
/// The app spawns the helper with every descriptor already installed, including the host broker
/// on `ExtensionHostDescriptorConnection.childDescriptorNumber`; the helper validates what it
/// was asked to run and `execve`s the extension **in place**. The pid Skalman spawned is
/// therefore the pid the extension runs as, which is why this needs none of the ownership,
/// exit-reporting or orphan-cleanup machinery an out-of-process runner would.
///
/// Measured, not assumed — see `docs/extensions/SANDBOX_RUNNER.md`: App Sandbox survives the
/// `execve`, the home-relative read-only exception is what permits it at all, and the exec'd
/// extension reads its package while being denied its home, `/tmp`, and writes to its own
/// package.
struct HelperLaunchPolicy: ExtensionLaunchPolicy {
    /// Descriptor mode: the helper can install a socket the child inherits, so the broker needs
    /// no loopback port and the sandbox needs no network authority to reach it.
    let hostTransport: ExtensionHostTransport = .descriptor

    static let helperName = "skalman-extension-helper"
    static let networkHelperName = "skalman-extension-helper-network"

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The two variants differ only in `com.apple.security.network.client`, which App Sandbox
    /// can express only at signing time. Every finer distinction stays with the host broker.
    static func helperName(for capabilities: Set<ExtensionCapability>) -> String {
        capabilities.contains(.networkClient) ? networkHelperName : helperName
    }

    func helperURL(for capabilities: Set<ExtensionCapability>) -> URL? {
        let name = Self.helperName(for: capabilities)
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func spawn(_ request: ExtensionLaunchRequest) throws -> ExtensionChildProcess {
        let capabilities = request.bundle.manifest.capabilities
        guard let helper = helperURL(for: capabilities) else {
            throw ExtensionHelperError.helperUnavailable(Self.helperName(for: capabilities))
        }

        var descriptors: [Int32: Int32] = [
            0: try descriptor(for: request.standardInput, end: .child),
            1: try descriptor(for: request.standardOutput, end: .host),
            2: try descriptor(for: request.standardError, end: .host)
        ]
        descriptors.merge(request.extraDescriptors) { _, extra in extra }

        // Attempting the spawn *consumes* the request's descriptors, whether or not it
        // succeeds. Anything else leaves the caller guessing whether it still owns them, and a
        // guess in either direction is a bug: leaked, or closed twice onto a recycled number.
        defer { closeChildEnds(of: request) }

        return try ExtensionChildSpawner.spawn(
            executableURL: helper,
            arguments: [
                request.bundle.rootURL.path,
                request.bundle.executableURL.path
            ] + request.arguments,
            environment: ExtensionLaunchEnvironment.composed(
                with: request.additionalEnvironment
            ),
            workingDirectory: request.bundle.rootURL,
            descriptors: descriptors
        )
    }

    /// Which end of a pipe the child is given.
    ///
    /// A pipe is directional and the mapping is not symmetric: the child *reads* stdin and
    /// *writes* stdout and stderr, so handing it the wrong end produces a process that hangs
    /// rather than one that fails.
    private enum PipeEnd {
        case child
        case host
    }

    private func descriptor(for stream: ExtensionChildStream, end: PipeEnd) throws -> Int32 {
        switch stream {
        case .nullDevice:
            return FileHandle.nullDevice.fileDescriptor
        case .pipe(let pipe):
            switch end {
            case .child:
                return pipe.fileHandleForReading.fileDescriptor
            case .host:
                return pipe.fileHandleForWriting.fileDescriptor
            }
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
        // The broker socket especially: while this side holds a copy, the host end never sees
        // end-of-file when the extension exits, so a dead extension would look merely quiet.
        for descriptor in request.extraDescriptors.values {
            close(descriptor)
        }
    }
}
