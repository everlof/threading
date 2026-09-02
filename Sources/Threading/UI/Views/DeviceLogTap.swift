import Foundation

/// Builds the log tap an app links so its `print()` output becomes readable.
///
/// `print()` never reaches the unified log, so an app's own console output is invisible to every
/// host-side reader. The tap copies `stdout` and `stderr` into `os_log` while still writing them
/// through, which is the only way to see them from the Mac. Measured evidence is in
/// [`device-and-simulator-logs.md`](../../../../docs/feature-drafts/device-and-simulator-logs.md).
///
/// The C source is embedded rather than read from the repository so an installed Threading can
/// build it without a checkout. It compiles in well under a second.
@MainActor
enum DeviceLogTap {

    enum Platform: String, CaseIterable {
        case device
        case simulator
        case macOS

        var sdk: String {
            switch self {
            case .device: return "iphoneos"
            case .simulator: return "iphonesimulator"
            case .macOS: return "macosx"
            }
        }

        var target: String {
            switch self {
            case .device: return "arm64-apple-ios17.0"
            case .simulator: return "arm64-apple-ios17.0-simulator"
            case .macOS: return "arm64-apple-macos13.0"
            }
        }

        /// A device cannot have a dylib inserted at launch, so its tap is a static archive the
        /// linker compiles into the app. Everything else is injected without touching the build.
        var isLinked: Bool { self == .device }
    }

    enum Failure: Error, CustomStringConvertible {
        case noSDK(String)
        case compilerFailed(String)

        var description: String {
            switch self {
            case .noSDK(let sdk): return "no \(sdk) SDK is installed"
            case .compilerFailed(let detail): return "the tap did not compile: \(detail)"
            }
        }
    }

    struct Built {
        let path: URL
        let platform: Platform

        /// What an agent adds to its own build or launch. Deliberately a value the caller pastes
        /// rather than something Threading runs: building someone's project is their command to
        /// approve, exactly as `simulator-pane.md` keeps `xcodebuild` out of the tool surface.
        var instruction: String {
            if platform.isLinked {
                return "OTHER_LDFLAGS='$(inherited) -Wl,-force_load,\(path.path)'"
            }
            let variable = platform == .simulator
                ? "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
                : "DYLD_INSERT_LIBRARIES"
            return "\(variable)=\(path.path)"
        }
    }

    /// The tap's C source, shipped as a resource rather than embedded in a Swift literal.
    ///
    /// The extension is `.c.txt` deliberately: a `.c` under `Sources/` would be added to the app
    /// target by the synchronized folder and compiled into Threading itself, which would install
    /// the tap in the wrong process. It also keeps the logging boundary lint from reading the C
    /// file's own `os_log` calls as Threading's.
    private static var source: String {
        guard let url = Bundle.main.url(forResource: "threading_log_tap", withExtension: "c.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("codes.threading", isDirectory: true)
            .appendingPathComponent("logtap", isDirectory: true)
    }

    /// Compile the tap for one platform, reusing a previous build when the source has not changed.
    static func build(for platform: Platform) throws -> Built {
        let directory = cacheDirectory.appendingPathComponent(platform.sdk, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let product = directory.appendingPathComponent(
            platform.isLinked ? "libthreadingtap.a" : "libthreadingtap.dylib"
        )
        let sourceFile = directory.appendingPathComponent("threading_log_tap.c")
        let existing = try? String(contentsOf: sourceFile, encoding: .utf8)
        if existing == source, FileManager.default.fileExists(atPath: product.path) {
            return Built(path: product, platform: platform)
        }
        try source.write(to: sourceFile, atomically: true, encoding: .utf8)

        guard !source.isEmpty else { throw Failure.compilerFailed("the tap source is missing") }
        guard let sdk = run("/usr/bin/xcrun", ["--sdk", platform.sdk, "--show-sdk-path"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sdk.isEmpty
        else { throw Failure.noSDK(platform.sdk) }

        if platform.isLinked {
            let object = directory.appendingPathComponent("threading_log_tap.o")
            guard run("/usr/bin/xcrun", [
                "-sdk", platform.sdk, "clang", "-c", "-target", platform.target,
                "-isysroot", sdk, "-O2", sourceFile.path, "-o", object.path,
            ]) != nil else { throw Failure.compilerFailed("clang -c") }
            guard run("/usr/bin/xcrun", [
                "-sdk", platform.sdk, "ar", "rcs", product.path, object.path,
            ]) != nil else { throw Failure.compilerFailed("ar") }
        } else {
            guard run("/usr/bin/xcrun", [
                "-sdk", platform.sdk, "clang", "-dynamiclib", "-target", platform.target,
                "-isysroot", sdk, "-O2", sourceFile.path, "-o", product.path,
            ]) != nil else { throw Failure.compilerFailed("clang -dynamiclib") }
        }
        guard FileManager.default.fileExists(atPath: product.path) else {
            throw Failure.compilerFailed("no product was written")
        }
        return Built(path: product, platform: platform)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
